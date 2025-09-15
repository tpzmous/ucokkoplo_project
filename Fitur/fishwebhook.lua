-- ===========================
-- FishWebhook feature (UI-compatible, minimal fixes)
-- - Compatible with FeatureManager (expects Init/Start/Stop)
-- - Accepts controls: { urlInput, fishTypesDropdown, testButton, toggle }
-- - Tries common HTTP backends (syn.request/http.request/http_request/request) with HttpService fallback
-- ===========================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local FishWebhookFeature = {}
FishWebhookFeature.__index = FishWebhookFeature

-- state
local controls = {}
local isRunning = false
local webhookUrl = ""
local selectedFishTypes = {}
local connections = {}         -- holds RBX connections for cleanup
local lastInbound = {}
local recentAdds = {}
local rareWatchUntil = 0
local onCatchWindowBusy = false
local debounceSend = 0

-- config (kept minimal)
local CONFIG = {
    DEBUG = false,
    WEIGHT_DECIMALS = 2,
    CATCH_WINDOW_SEC = 2.5,
    RARE_WINDOW_SEC = 10.0,
    DEDUP_TTL_SEC = 12.0,
    THUMB_SIZE = "150x150",
    INBOUND_EVENTS = { "RE/ObtainedNewFishNotification", "ObtainedNewFishNotification", "RE/FishCaught", "FishCaught" },
    INBOUND_PATTERNS = { "fish", "catch", "obtained", "notification", "legend", "myth", "secret", "reward" },
    ID_NAME_MAP = {},
}

local TIER_NAME_MAP = { [1]="Common",[2]="Uncommon",[3]="Rare",[4]="Epic",[5]="Legendary",[6]="Mythic",[7]="Secret" }

-- simple caches
local thumbCache = {}
local sentCache = {}

-- ===== utilities =====
local function now() return os.clock() end
local function log(...) if CONFIG.DEBUG then warn("[FishWebhook]", ...) end end
local function toIdStr(v) local n = tonumber(v) return n and tostring(n) or (v and tostring(v) or nil) end
local function safeClear(t) if table and table.clear then table.clear(t) else for k in pairs(t) do t[k] = nil end end end

-- try to set toggle state on passed control (works with various UI libs)
local function trySetToggleState(toggleObj, state)
    if not toggleObj then return end
    pcall(function()
        if toggleObj.SetValue then toggleObj:SetValue(state); return end
        if toggleObj.SetState then toggleObj:SetState(state); return end
        if toggleObj.Set then toggleObj:Set(state); return end
        -- last resort: if toggle has Value property
        if toggleObj.Value ~= nil and type(toggleObj.Value) ~= "function" then toggleObj.Value = state end
    end)
end

-- ===== HTTP helpers =====
local function getRequestFn()
    if syn and type(syn.request) == "function" then return syn.request end
    if http and type(http.request) == "function" then return http.request end
    if type(http_request) == "function" then return http_request end
    if type(request) == "function" then return request end
    if fluxus and type(fluxus.request) == "function" then return fluxus.request end
    return nil
end

local function sendWebhookPayload(payload)
    if not webhookUrl or webhookUrl == "" then
        log("Webhook URL empty; skipping send")
        return false, "no_webhook"
    end

    local req = getRequestFn()
    local body = HttpService:JSONEncode(payload)

    if req then
        local ok, res = pcall(req, {
            Url = webhookUrl,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = body
        })
        if not ok then
            log("HTTP backend error:", res)
            return false, tostring(res)
        end
        -- try to get status
        local code = tonumber(res.StatusCode or res.Status) or 0
        if code < 200 or code >= 300 then
            log("Webhook HTTP status:", code)
            return false, "status:"..tostring(code)
        end
        return true
    end

    -- fallback to HttpService.PostAsync if enabled (server context)
    if pcall(function() return HttpService.HttpEnabled end) and HttpService.HttpEnabled and type(HttpService.PostAsync) == "function" then
        local ok, err = pcall(function()
            HttpService:PostAsync(webhookUrl, body, Enum.HttpContentType.ApplicationJson, false)
        end)
        if not ok then
            log("HttpService.PostAsync failed:", err)
            return false, tostring(err)
        end
        return true
    end

    log("No HTTP request function available")
    return false, "no_request_fn"
end

-- wrapper to build payload
local function sendWebhook(username, embed)
    local payload = { username = username or "FishNotifier", embeds = { embed } }
    local ok, err = sendWebhookPayload(payload)
    if not ok then log("sendWebhook error:", err) end
    return ok, err
end

-- ===== thumbnail helper (best-effort) =====
local function extractAssetId(icon)
    if not icon then return nil end
    if type(icon) == "number" then return tostring(icon) end
    if type(icon) == "string" then
        local m = icon:match("rbxassetid://(%d+)")
        if m then return m end
        local n = icon:match("(%d+)$")
        if n then return n end
    end
    return nil
end

local function resolveIconUrl(icon)
    local id = extractAssetId(icon)
    if not id then return nil end
    if thumbCache[id] then return thumbCache[id] end
    local url = string.format("https://www.roblox.com/asset-thumbnail/image?assetId=%s&width=420&height=420&format=png", id)
    thumbCache[id] = url
    return url
end

-- ===== item/meta helpers (kept minimal; optional) =====
local itemsRoot, indexBuilt, moduleById, metaById, scannedSet = nil, false, {}, {}, {}

local function detectItemsRoot()
    if itemsRoot and itemsRoot.Parent then return itemsRoot end
    local hints = {"Items", "GameData/Items", "Data/Items"}
    for _, h in ipairs(hints) do
        local cur = ReplicatedStorage
        for part in string.gmatch(h, "[^/]+") do cur = cur and cur:FindFirstChild(part) end
        if cur then itemsRoot = cur; break end
    end
    itemsRoot = itemsRoot or ReplicatedStorage:FindFirstChild("Items") or ReplicatedStorage
    return itemsRoot
end

local function safeRequire(ms)
    local ok, data = pcall(require, ms)
    if not ok or type(data) ~= "table" then return nil end
    local D = data.Data or {}
    if D.Type ~= "Fishes" then return nil end
    local chance = nil
    if type(data.Probability) == "table" then chance = data.Probability.Chance end
    return { id = toIdStr(D.Id), name = D.Name, tier = D.Tier, chance = chance, icon = D.Icon, desc = D.Description, _ms = ms }
end

local function buildLightIndex()
    if indexBuilt then return end
    local root = detectItemsRoot()
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA and d:IsA("ModuleScript") then
            local n = tonumber(d.Name)
            if n then moduleById[toIdStr(n)] = moduleById[toIdStr(n)] or d end
        end
    end
    indexBuilt = true
end

local function ensureMetaById(idStr)
    idStr = toIdStr(idStr)
    if not idStr then return nil end
    if metaById[idStr] then return metaById[idStr] end
    buildLightIndex()
    local ms = moduleById[idStr]
    if ms and not scannedSet[ms] then
        local meta = safeRequire(ms); scannedSet[ms] = true
        if meta and meta.id == idStr then metaById[idStr] = meta; return meta end
    end
    local root = detectItemsRoot()
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA and d:IsA("ModuleScript") and not scannedSet[d] then
            local meta = safeRequire(d); scannedSet[d] = true
            if meta and meta.id then moduleById[meta.id] = moduleById[meta.id] or d; metaById[meta.id] = metaById[meta.id] or meta
                if meta.id == idStr then return meta end
            end
        end
    end
    return nil
end

-- ===== decoding inbound events (kept compatible) =====
local function toAttrMap(inst)
    local a = {}
    if not inst or not inst.GetAttributes then return a end
    for k,v in pairs(inst:GetAttributes()) do a[k] = v end
    for _, ch in ipairs(inst:GetChildren()) do if ch:IsA and ch:IsA("ValueBase") then a[ch.Name] = ch.Value end end
    return a
end

local function absorbQuick(info, t)
    if type(t) ~= "table" then return end
    info.id = info.id or t.Id or t.ItemId or t.TypeId or t.FishId
    info.weight = info.weight or t.Weight or t.Mass or t.Kg or t.WeightKg
    info.chance = info.chance or t.Chance or t.Probability
    info.tier = info.tier or t.Tier
    info.icon = info.icon or t.Icon
    info.mutations = info.mutations or t.Mutations or t.Modifiers or t.Variants
    info.variantId = info.variantId or t.VariantId or t.Variant
    info.variantSeed = info.variantSeed or t.VariantSeed
    info.shiny = info.shiny or t.Shiny
    info.uuid = info.uuid or t.UUID or t.Uuid
    if t.Data and type(t.Data) == "table" then absorbQuick(info, t.Data) end
    if t.Metadata and type(t.Metadata) == "table" then absorbQuick(info, t.Metadata) end
end

local function decode_RE_ObtainedNewFishNotification(packed)
    local info = {}
    for i = 1, packed.n or #packed do
        local arg = packed[i]
        if type(arg) == "table" then absorbQuick(info, arg)
        elseif type(arg) == "number" or type(arg) == "string" then if not info.id then info.id = toIdStr(arg) end
        elseif typeof and typeof(arg) == "Instance" then absorbQuick(info, toAttrMap(arg)) end
    end
    if info.id then local meta = ensureMetaById(toIdStr(info.id)); if meta then info.name = info.name or meta.name info.tier = info.tier or meta.tier info.chance = info.chance or meta.chance info.icon = info.icon or meta.icon end end
    local idS = info.id and toIdStr(info.id)
    if idS and not info.name and CONFIG.ID_NAME_MAP[idS] then info.name = CONFIG.ID_NAME_MAP[idS] end
    return next(info) and info or nil
end

local function decode_RE_FishCaught(packed)
    local info = {}
    local a1, a2 = packed[1], packed[2]
    if type(a1) == "table" then absorbQuick(info, a1) if type(a2) == "table" then absorbQuick(info, a2) end
    elseif type(a1) == "number" or type(a1) == "string" then info.id = toIdStr(a1) if type(a2) == "table" then absorbQuick(info, a2) end
    elseif typeof and typeof(a1) == "Instance" then absorbQuick(info, toAttrMap(a1)) if type(a2) == "table" then absorbQuick(info, a2) end end
    if info.id then local meta = ensureMetaById(toIdStr(info.id)); if meta then info.name = info.name or meta.name info.tier = info.tier or meta.tier info.chance = info.chance or meta.chance info.icon = info.icon or meta.icon end end
    local idS = info.id and toIdStr(info.id)
    if idS and not info.name and CONFIG.ID_NAME_MAP[idS] then info.name = CONFIG.ID_NAME_MAP[idS] end
    return next(info) and info or nil
end

local function decodeInboundEvent(eventName, packed)
    local en = tostring(eventName or "")
    if en == "RE/ObtainedNewFishNotification" or en == "ObtainedNewFishNotification" then return decode_RE_ObtainedNewFishNotification(packed)
    elseif en == "RE/FishCaught" or en == "FishCaught" then return decode_RE_FishCaught(packed)
    else
        local info = decode_RE_ObtainedNewFishNotification(packed)
        if not info then info = decode_RE_FishCaught(packed) end
        return info
    end
end

-- ===== formatting, dedup, embed =====
local function roundWeight(w) local n = tonumber(w) if not n then return "?" end local fmt = "%0." .. tostring(CONFIG.WEIGHT_DECIMALS) .. "f" return string.format(fmt,n) end

local function sigFromInfo(info)
    local id = info.id and tostring(info.id) or "?"
    local wt = roundWeight(info.weight)
    local tier = tostring(info.tier or "?")
    local ch = tostring(info.chance or "?")
    local variant = tostring(info.variantId or "")
    local shiny = tostring(info.shiny or false)
    local uuid = tostring(info.uuid or "")
    local mut = ""
    if type(info.mutations) == "table" then
        local keys = {} for k in pairs(info.mutations) do table.insert(keys, tostring(k)) end; table.sort(keys)
        local parts = {} for _,k in ipairs(keys) do table.insert(parts, k.."="..tostring(info.mutations[k])) end; mut = table.concat(parts,"&")
    else mut = tostring(info.mutation or "") end
    return table.concat({id,wt,tier,ch,variant,shiny,uuid,mut},"|")
end

local function shouldSend(sig)
    local t = now()
    for k, ts in pairs(sentCache) do if (t - ts) > CONFIG.DEDUP_TTL_SEC then sentCache[k] = nil end end
    if sentCache[sig] then return false end
    sentCache[sig] = t
    return true
end

local function getTierName(tier) return (tier and TIER_NAME_MAP[tier]) or (tier and tostring(tier)) or "Unknown" end

local function shouldSendFish(info)
    if not info.name then return false end
    if not selectedFishTypes or next(selectedFishTypes) == nil then return true end
    for selectedType, _ in pairs(selectedFishTypes) do
        if (info.name and info.name:lower():find(selectedType:lower())) or getTierName(info.tier):lower() == selectedType:lower() then return true end
    end
    return false
end

local function escapeTripleBacktick(s) if not s then return "" end return s:gsub("```","`\226\128\139``") end
local function box(v) v = v==nil and "Unknown" or tostring(v); v = escapeTripleBacktick(v); return string.format("```%s```", v) end
local function hide(v) v = v==nil and "Unknown" or tostring(v); v = v:gsub("||","| |"); return string.format("||%s||", v) end

local function sendEmbed(info)
    if now() - debounceSend < 0.15 then return end
    debounceSend = now()
    if not shouldSendFish(info) then log("Filtered:", info.name or "Unknown"); return end
    local sig = sigFromInfo(info)
    if not shouldSend(sig) then log("Duplicate suppressed"); return end

    local fishName = info.name or (info.id and (ensureMetaById(toIdStr(info.id)) or {}).name) or "Unknown Fish"
    local imageUrl = nil
    if info.icon then imageUrl = resolveIconUrl(info.icon) elseif info.id then imageUrl = resolveIconUrl(info.id) end

    local embed = {
        title = (info.shiny and "✨ New Shiny Catch" or "New Catch"),
        description = string.format("**Player:** %s", hide((Players.LocalPlayer and Players.LocalPlayer.Name) or "Unknown")),
        color = info.shiny and 0xFFD700 or 0x03A9F4,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        footer = { text = "FishWebhook" },
        fields = {
            { name = "Fish Name", value = box(fishName), inline = false },
            { name = "Weight", value = box(info.weight and (roundWeight(info.weight).." kg") or "Unknown"), inline = true },
            { name = "Chance", value = box(info.chance or "Unknown"), inline = true },
            { name = "Rarity", value = box(getTierName(info.tier)), inline = true },
            { name = "Variant/Shiny", value = box((info.variantId and ("Variant: "..tostring(info.variantId)) or "None") .. (info.shiny and " | ✨ SHINY" or "")), inline = false }
        }
    }
    if info.uuid and info.uuid ~= "" then table.insert(embed.fields, { name = "🆔 UUID", value = box(info.uuid), inline = true }) end
    if imageUrl then embed.thumbnail = { url = imageUrl } end

    sendWebhook("FishWebhook", embed)
    safeClear(lastInbound); safeClear(recentAdds); rareWatchUntil = 0
end

-- ===== correlation =====
local function onCatchWindow()
    if onCatchWindowBusy then return end
    onCatchWindowBusy = true
    local function finally() onCatchWindowBusy = false end

    for i = #lastInbound, 1, -1 do
        local hit = lastInbound[i]
        if now() - hit.t <= CONFIG.CATCH_WINDOW_SEC then
            local info = decodeInboundEvent(hit.name, hit.args)
            if info and (info.id or info.name) then sendEmbed(info); finally(); return end
        end
    end

    if now() <= rareWatchUntil then
        for i = #lastInbound, 1, -1 do
            local hit = lastInbound[i]
            if now() - hit.t <= CONFIG.RARE_WINDOW_SEC then
                local info = decodeInboundEvent(hit.name, hit.args)
                if info and (info.id or info.name) then sendEmbed(info); finally(); return end
            else break end
        end

        for inst, ts in pairs(recentAdds) do
            if inst.Parent and inst.Parent.Name == "Backpack" and now() - ts <= CONFIG.RARE_WINDOW_SEC then
                local a = toAttrMap(inst)
                local id = a.Id or a.ItemId or a.TypeId or a.FishId
                local meta = id and ensureMetaById(toIdStr(id)) or nil
                if meta then
                    sendEmbed({ id = id, name = meta.name, tier = meta.tier, chance = meta.chance, icon = meta.icon, weight = a.Weight or a.Mass, mutations = a.Mutations or a.Mutation, variantId = a.VariantId, variantSeed = a.VariantSeed, shiny = a.Shiny, uuid = a.UUID })
                    finally()
                    return
                end
            end
        end
    end

    if CONFIG.DEBUG then log("No info in window; skipped") end
    finally()
end

-- ===== inbound connection logic =====
local function wantByName(nm)
    if not nm then return false end
    local n = tostring(nm):lower()
    for _, ex in ipairs(CONFIG.INBOUND_EVENTS) do if tostring(ex):lower() == n then return true end end
    for _, pat in ipairs(CONFIG.INBOUND_PATTERNS or {}) do if n:find(tostring(pat):lower(), 1, true) then return true end end
    return false
end

local function connectInbound()
    local ge = ReplicatedStorage
    local function maybeConnect(d)
        if not d or not d.IsA then return end
        if d:IsA("RemoteEvent") and (wantByName(d.Name) or pcall(function() return wantByName(d:GetFullName()) end)) then
            table.insert(connections, d.OnClientEvent:Connect(function(...)
                local packed = table.pack(...)
                table.insert(lastInbound, { t = now(), name = d.Name, args = packed })
                if CONFIG.DEBUG then log("Inbound:", d.Name, "argc=", packed.n or 0) end
                task.defer(onCatchWindow)
            end))
            log("Hooked:", d:GetFullName())
        end
    end

    for _, d in ipairs(ge:GetDescendants()) do maybeConnect(d) end
    table.insert(connections, ge.DescendantAdded:Connect(maybeConnect))
end

-- light backpack listener (best-effort)
local function connectBackpackLight()
    -- try to find local player's backpack (best-effort - LocalPlayer not strictly necessary here)
    local lp = Players.LocalPlayer
    if lp then
        local bp = lp:FindFirstChild("Backpack")
        if bp then
            table.insert(connections, bp.ChildAdded:Connect(function(inst) recentAdds[inst] = now() if CONFIG.DEBUG then log("Backpack +", inst.Name) end end))
            table.insert(connections, bp.ChildRemoved:Connect(function(inst) recentAdds[inst] = nil end))
            return
        end
        -- wait for backpack appear
        table.insert(connections, lp.ChildAdded:Connect(function(child) if child and child.Name == "Backpack" then connectBackpackLight() end end))
    end
end

-- ===== public API =====
function FishWebhookFeature:Init(guiControls)
    controls = guiControls or {}
    detectItemsRoot(); buildLightIndex()
    log("Init complete")
    return true
end

function FishWebhookFeature:SetWebhookUrl(url)
    webhookUrl = url or ""
    log("Webhook URL set:", (webhookUrl ~= "" and webhookUrl:sub(1,50).."..." or "Not set"))
    -- reflect to UI input if provided
    pcall(function()
        if controls.urlInput and controls.urlInput.SetValue then controls.urlInput:SetValue(webhookUrl) end
        if controls.urlInput and controls.urlInput.Set then controls.urlInput:Set(webhookUrl) end
    end)
end

function FishWebhookFeature:SetSelectedFishTypes(tbl)
    selectedFishTypes = tbl or {}
    log("Selected fish types updated")
    -- reflect to dropdwon if provided (best-effort)
    pcall(function()
        if controls.fishTypesDropdown and controls.fishTypesDropdown.SetValue then controls.fishTypesDropdown:SetValue(selectedFishTypes) end
        if controls.fishTypesDropdown and controls.fishTypesDropdown.Set then controls.fishTypesDropdown:Set(selectedFishTypes) end
    end)
end

function FishWebhookFeature:TestWebhook(message)
    if not webhookUrl or webhookUrl == "" then warn("[FishWebhook] TestWebhook: webhook not set"); return false end
    local embed = { title = "FishWebhook Test", description = message or "Test message", color = 3447003, timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    local ok, err = sendWebhook("FishWebhook Test", embed)
    if ok then log("Test webhook sent") else warn("[FishWebhook] Test failed:", err) end
    return ok
end

function FishWebhookFeature:Start(config)
    if isRunning then return true end
    webhookUrl = (config and config.webhookUrl) or webhookUrl or ""
    selectedFishTypes = (config and config.selectedFishTypes) or selectedFishTypes or {}

    if not webhookUrl or webhookUrl == "" then
        warn("[FishWebhook] Cannot start - webhook URL not set")
        trySetToggleState(controls.toggle, false)
        return false
    end

    -- hook inbound events
    connectInbound()
    connectBackpackLight()
    isRunning = true
    log("Started (listening for events).")
    trySetToggleState(controls.toggle, true)
    return true
end

function FishWebhookFeature:Stop()
    if not isRunning then return end
    isRunning = false
    for _, conn in ipairs(connections) do pcall(function() conn:Disconnect() end) end
    connections = {}
    safeClear(lastInbound); safeClear(recentAdds); rareWatchUntil = 0
    trySetToggleState(controls.toggle, false)
    log("Stopped")
end

function FishWebhookFeature:GetStatus()
    return {
        running = isRunning,
        webhookUrl = (webhookUrl ~= "" and (webhookUrl:sub(1,50) .. (webhookUrl:len()>50 and "..." or "")) or "Not set"),
        selectedFishTypes = selectedFishTypes,
        connectionsCount = #connections,
        lastInboundCount = #lastInbound
    }
end

function FishWebhookFeature:Cleanup()
    self:Stop()
    controls = {}
    safeClear(thumbCache); safeClear(sentCache)
end

function FishWebhookFeature:EnableInboundDebug() CONFIG.DEBUG = true end
function FishWebhookFeature:DisableInboundDebug() CONFIG.DEBUG = false end

function FishWebhookFeature:SimulateFishCatch(testData)
    testData = testData or { id = "69", name = "Test Fish", weight = 1.27, tier = 5, chance = 0.001, shiny = true, variantId = "Galaxy" }
    sendEmbed(testData)
end

return FishWebhookFeature
