--========================================================
-- AutoTeleportEvent (Final Full)
-- - Validasi ke ReplicatedStorage.Events
-- - Resolve EventName dari attribute / StringValue
-- - Normalisasi nama sebelum matching
-- - Save position on Start
-- - Hover with BodyPosition
-- - Smart water detection (raycast)
-- - Workspace Props monitoring
-- - Debug helpers included
--========================================================

local AutoTeleportEvent = {}
AutoTeleportEvent.__index = AutoTeleportEvent

-- Services
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local LocalPlayer       = Players.LocalPlayer

-- ===== State =====
local running            = false
local hbConn             = nil
local charConn           = nil
local propsAddedConn     = nil
local propsRemovedConn   = nil
local workspaceConn      = nil

local eventsFolder       = nil
local validEventName     = {}         -- cache valid names (normName -> true)

local selectedPriorityList = {}       -- ordered priorities (normName)
local selectedSet           = {}      -- set/dict for quick match
local hoverHeight           = 15
local savedPosition         = nil     -- CFrame saved at Start
local currentTarget         = nil     -- { model, name, nameKey, pos, propsName }
local lastKnownActiveProps  = {}      -- track active Props by name

local HOVER_BP_NAME = "AutoTeleport_HoverBP"

-- ===== Utils =====
local function normName(s)
    s = string.lower(s or "")
    s = s:gsub("%W", "") -- remove non-alphanumeric
    return s
end

local function waitChild(parent, name, timeout)
    local t0 = os.clock()
    local obj = parent:FindFirstChild(name)
    while not obj and (os.clock() - t0) < (timeout or 5) do
        parent.ChildAdded:Wait()
        obj = parent:FindFirstChild(name)
    end
    return obj
end

local function ensureCharacter()
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local hrp  = char:FindFirstChild("HumanoidRootPart") or waitChild(char, "HumanoidRootPart", 5)
    local hum  = char:FindFirstChildOfClass("Humanoid")
    return char, hrp, hum
end

local function setCFrameSafely(hrp, targetPos, keepLookAt)
    if not hrp then return end
    local look = keepLookAt or (hrp.CFrame.LookVector + hrp.Position)
    -- reset velocity to avoid weirdness
    if pcall(function() hrp.AssemblyLinearVelocity = Vector3.new() end) then end
    if pcall(function() hrp.AssemblyAngularVelocity = Vector3.new() end) then end
    hrp.CFrame = CFrame.lookAt(targetPos, Vector3.new(look.X, targetPos.Y, look.Z))
end

-- ===== Hover BodyPosition helpers =====
local function ensureHoverBP(hrp)
    if not hrp then return nil end
    local bp = hrp:FindFirstChild(HOVER_BP_NAME)
    if bp and bp:IsA("BodyPosition") then
        return bp
    end
    local ok, newBp = pcall(function()
        local b = Instance.new("BodyPosition")
        b.Name = HOVER_BP_NAME
        b.MaxForce = Vector3.new(1e6, 1e6, 1e6)
        b.P = 3e4
        b.D = 1e3
        b.Parent = hrp
        return b
    end)
    if ok then return newBp end
    return nil
end

local function removeHoverBP(hrp)
    if not hrp then return end
    local bp = hrp:FindFirstChild(HOVER_BP_NAME)
    if bp then
        pcall(function() bp:Destroy() end)
    end
end

-- ===== Smart water-finding helpers =====
local function findBestWaterPosition(centerPos)
    local maxRadius = 30
    local radii = {0, 2, 4, 6, 10, 15, 20, 30}
    local samplesPerRadius = 8
    local rayUp = 60
    local rayDown = 200
    local best = nil
    local bestDist = math.huge

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    local char = LocalPlayer.Character
    params.FilterDescendantsInstances = char and {char} or {}
    params.IgnoreWater = false

    for _, r in ipairs(radii) do
        if r > maxRadius then break end
        local stepCount = (r == 0) and 1 or samplesPerRadius
        for i = 0, stepCount - 1 do
            local offset
            if r == 0 then
                offset = Vector3.new(0, 0, 0)
            else
                local theta = (i / stepCount) * math.pi * 2
                offset = Vector3.new(math.cos(theta) * r, 0, math.sin(theta) * r)
            end
            local origin = Vector3.new(centerPos.X + offset.X, centerPos.Y + rayUp, centerPos.Z + offset.Z)
            local direction = Vector3.new(0, -rayDown, 0)
            local result = Workspace:Raycast(origin, direction, params)
            if result and result.Position then
                if result.Material == Enum.Material.Water then
                    local candidate = result.Position
                    local d = (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(centerPos.X, 0, centerPos.Z)).Magnitude
                    if d < bestDist then
                        best = candidate
                        bestDist = d
                    end
                else
                    local inst = result.Instance
                    if inst and inst:IsA("Terrain") then
                        -- some terrains may not set Material.Water — skip for now
                    end
                end
            end
        end
        if best then return best end
    end

    -- fallback: return centerPos (no water found)
    return centerPos
end

-- ===== Save Position Before First Teleport =====
local function saveCurrentPosition()
    if savedPosition then return end -- already saved
    local _, hrp = ensureCharacter()
    if hrp then
        local ok, cf = pcall(function() return hrp.CFrame end)
        if ok and cf then
            savedPosition = cf
            print("[AutoTeleportEvent] Position saved at:", tostring(savedPosition.Position))
        end
    end
end

-- ===== Event Name Indexing from ReplicatedStorage =====
local function buildValidEventNames()
    table.clear(validEventName)
    local folder = ReplicatedStorage:FindFirstChild("Events")
    if not folder then
        warn("[AutoTeleportEvent] ReplicatedStorage.Events not found")
        return validEventName
    end
    local function scan(f)
        for _, child in ipairs(f:GetChildren()) do
            if child:IsA("ModuleScript") then
                local ok, data = pcall(require, child)
                local name = nil
                if ok and data and type(data) == "table" and data.Name then
                    name = data.Name
                else
                    name = child.Name
                end
                validEventName[normName(name)] = true
            elseif child:IsA("Folder") then
                scan(child)
            end
        end
    end
    scan(folder)
    return validEventName
end

-- ===== Resolve Model Pivot (already in your original) =====
local function resolveModelPivotPos(model)
    local ok, cf = pcall(function() return model:GetPivot() end)
    if ok and typeof(cf) == "CFrame" then return cf.Position end
    local ok2, cf2 = pcall(function() return model.WorldPivot end)
    if ok2 and typeof(cf2) == "CFrame" then return cf2.Position end
    return nil
end

-- ===== Resolve Event Name from Model =====
local function resolveEventNameFromModel(model)
    if not model or not model.Name then return "Unknown" end
    -- 1. attribute
    if model:GetAttribute("EventName") then
        return model:GetAttribute("EventName")
    end
    -- 2. string value children (StringValue, ValueBase)
    for _, v in ipairs(model:GetChildren()) do
        if v:IsA("StringValue") then
            if v.Value and v.Value ~= "" then
                return v.Value
            end
        elseif v:IsA("ValueBase") then
            -- generic value types with Value property (NumberValue, BoolValue, etc.)
            if v.Value and type(v.Value) == "string" and v.Value ~= "" then
                return v.Value
            end
        end
    end
    -- 3. fallback: use model name
    return model.Name
end

-- ===== Scan All Props in Workspace =====
local function scanAllActiveProps()
    local activePropsList = {}
    -- rebuild valid list each scan (keamanan, juga bisa dipanggil di Init)
    buildValidEventNames()

    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            if string.find(string.lower(child.Name), "props") then
                for _, desc in ipairs(child:GetDescendants()) do
                    if desc:IsA("Model") then
                        local eventName = resolveEventNameFromModel(desc)
                        local normKey = normName(eventName)
                        local pos = resolveModelPivotPos(desc)
                        if pos then
                            if validEventName[normKey] then
                                table.insert(activePropsList, {
                                    model     = desc,
                                    name      = eventName,
                                    nameKey   = normKey,
                                    pos       = pos,
                                    propsName = child.Name
                                })
                                print(string.format("[AutoTeleportEvent] Event VALID: %s @ Vector3(%.2f, %.2f, %.2f)",
                                    eventName, pos.X, pos.Y, pos.Z))
                            else
                                -- warn for visibility; many admin events intentionally won't be in Events
                                warn(string.format("[AutoTeleportEvent] Event di Props '%s' -> '%s' NOT in ReplicatedStorage.Events",
                                    desc.Name, eventName))
                            end
                        end
                    end
                end
            end
        end
    end

    return activePropsList
end

-- ===== Match terhadap pilihan user =====
local function matchesSelection(nameKey)
    -- no selection => all allowed
    if #selectedPriorityList == 0 and next(selectedSet) == nil then return true end

    for selKey, _ in pairs(selectedSet) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return true
        end
    end

    for _, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return true
        end
    end

    return false
end

local function rankOf(nameKey)
    for i, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return i
        end
    end
    return math.huge
end

-- ===== Choose Best =====
local function chooseBestActiveEvent()
    local actives = scanAllActiveProps()
    if #actives == 0 then return nil end

    -- filter sesuai selection user
    local filtered = {}
    if #selectedPriorityList > 0 or next(selectedSet) ~= nil then
        for _, a in ipairs(actives) do
            if matchesSelection(a.nameKey) then
                table.insert(filtered, a)
            end
        end
        actives = filtered
        if #actives == 0 then
            -- no chosen event active
            return nil
        end
    end

    for _, a in ipairs(actives) do
        a.rank = rankOf(a.nameKey)
    end

    table.sort(actives, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)

    return actives[1]
end

-- ===== Teleport / Return =====
local function teleportToTarget(target)
    local char, hrp, hum = ensureCharacter()
    if not hrp then return false, "NO_HRP" end

    -- Save position before first teleport
    saveCurrentPosition()

    -- Find best water position (or fallback to pivot)
    local landing = findBestWaterPosition(target.pos)
    local tpPos = landing + Vector3.new(0, hoverHeight, 0)

    -- Instant teleport once
    setCFrameSafely(hrp, tpPos)
    -- Ensure BodyPosition hover exists and set it
    local bp = ensureHoverBP(hrp)
    if bp then
        bp.Position = tpPos
    end

    print("[AutoTeleportEvent] Teleported to:", target.name, "at", tostring(landing))
    return true
end

local function restoreToSavedPosition()
    if not savedPosition then
        warn("[AutoTeleportEvent] No saved position → skip restore")
        return
    end

    local char, hrp, hum = ensureCharacter()
    if hrp then
        removeHoverBP(hrp)
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        hrp.AssemblyLinearVelocity = Vector3.new()
        hrp.AssemblyAngularVelocity = Vector3.new()
        print("[AutoTeleportEvent] Restored to saved position:", tostring(savedPosition.Position))
    end
end

local function maintainHover()
    local char, hrp, hum = ensureCharacter()
    if hrp and currentTarget then
        if not currentTarget.model or not currentTarget.model.Parent then
            print("[AutoTeleportEvent] Current target no longer exists, clearing")
            currentTarget = nil
            removeHoverBP(hrp)
            return
        end

        local desired = currentTarget.pos + Vector3.new(0, hoverHeight, 0)
        local bp = ensureHoverBP(hrp)
        if bp then
            bp.Position = desired
        else
            if (hrp.Position - desired).Magnitude > 5 then
                setCFrameSafely(hrp, desired)
            end
        end

        if (hrp.Position - desired).Magnitude <= 1.2 then
            hrp.AssemblyLinearVelocity = Vector3.new()
            hrp.AssemblyAngularVelocity = Vector3.new()
        end
    else
        if hrp then removeHoverBP(hrp) end
    end
end

-- ===== Track Active Props (cleanup detection) =====
local function updateActivePropsTracking()
    local newActiveProps = {}
    local activeEvents = scanAllActiveProps()
    for _, event in ipairs(activeEvents) do
        newActiveProps[event.propsName] = true
    end

    for propsName, _ in pairs(lastKnownActiveProps) do
        if not newActiveProps[propsName] then
            print("[AutoTeleportEvent] Props removed:", propsName)
            if currentTarget and currentTarget.propsName == propsName then
                print("[AutoTeleportEvent] Current target props removed, clearing target")
                currentTarget = nil
                local _, hrp = ensureCharacter()
                if hrp then removeHoverBP(hrp) end
            end
        end
    end

    lastKnownActiveProps = newActiveProps
end

-- ===== Loop =====
local function startLoop()
    if hbConn then hbConn:Disconnect() hbConn = nil end
    local lastTick = 0
    hbConn = RunService.Heartbeat:Connect(function()
        if not running then return end
        local now = os.clock()

        -- Maintain hover each heartbeat
        pcall(maintainHover)

        if now - lastTick < 0.3 then return end
        lastTick = now

        -- tracking + scanning
        pcall(updateActivePropsTracking)
        local best = nil
        pcall(function() best = chooseBestActiveEvent() end)

        if not best then
            if currentTarget then
                print("[AutoTeleportEvent] No valid events found, clearing current target")
                currentTarget = nil
            end
            restoreToSavedPosition()
            return
        end

        if (not currentTarget) or (currentTarget.model ~= best.model) or (currentTarget.propsName ~= best.propsName) then
            print("[AutoTeleportEvent] Switching to new target:", best.name)
            teleportToTarget(best)
            currentTarget = best
        end
    end)
end

-- ===== Setup Workspace Monitoring =====
local function setupWorkspaceMonitoring()
    if propsAddedConn then propsAddedConn:Disconnect() propsAddedConn = nil end
    if propsRemovedConn then propsRemovedConn:Disconnect() propsRemovedConn = nil end
    if workspaceConn then workspaceConn:Disconnect() workspaceConn = nil end

    propsAddedConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name and string.find(string.lower(child.Name), "props") then
            print("[AutoTeleportEvent] New Props detected:", child.Name)
            task.wait(0.5)
            -- We rely on next loop scan to pick it up
        end
    end)

    propsRemovedConn = Workspace.ChildRemoved:Connect(function(child)
        if child.Name and string.find(string.lower(child.Name), "props") then
            print("[AutoTeleportEvent] Props removed:", child.Name)
            if lastKnownActiveProps[child.Name] then
                lastKnownActiveProps[child.Name] = nil
                if currentTarget and currentTarget.propsName == child.Name then
                    print("[AutoTeleportEvent] Current target props removed")
                    currentTarget = nil
                    local _, hrp = ensureCharacter()
                    if hrp then removeHoverBP(hrp) end
                end
            end
        end
    end)

    workspaceConn = Workspace.DescendantAdded:Connect(function(desc)
        if desc:IsA("Model") and desc.Parent and desc.Parent.Name and string.find(string.lower(desc.Parent.Name), "props") then
            task.wait(0.1)
            -- let loop pick up new model
        end
    end)
end

-- ===== Lifecycle =====
function AutoTeleportEvent:Init(gui)
    eventsFolder = ReplicatedStorage:FindFirstChild("Events") or waitChild(ReplicatedStorage, "Events", 5)
    -- build cache
    buildValidEventNames()

    if charConn then charConn:Disconnect() charConn = nil end
    charConn = LocalPlayer.CharacterAdded:Connect(function()
        -- Reset saved position on respawn
        savedPosition = nil
        if running and currentTarget then
            task.defer(function()
                task.wait(0.5)
                if currentTarget then teleportToTarget(currentTarget) end
            end)
        end
    end)

    setupWorkspaceMonitoring()

    print("[AutoTeleportEvent] Initialized successfully")
    return true
end

function AutoTeleportEvent:Start(config)
    if running then return true end
    running = true

    if config then
        if type(config.hoverHeight) == "number" then
            hoverHeight = math.clamp(config.hoverHeight, 5, 100)
        end
        if type(config.selectedEvents) ~= "nil" then
            self:SetSelectedEvents(config.selectedEvents)
        end
    end

    -- reset runtime state
    currentTarget = nil
    savedPosition = nil
    table.clear(lastKnownActiveProps)

    -- Save initial position immediately so restore always has something
    saveCurrentPosition()

    print("[AutoTeleportEvent] Starting with events:", (#selectedPriorityList>0 and table.concat(selectedPriorityList, ", ") or "(none)"))

    -- Try initial target
    local best = chooseBestActiveEvent()
    if best then
        teleportToTarget(best)
        currentTarget = best
        print("[AutoTeleportEvent] Initial target found:", best.name)
    else
        print("[AutoTeleportEvent] No initial target found")
    end

    startLoop()
    print("[AutoTeleportEvent] Started successfully")
    return true
end

function AutoTeleportEvent:Stop()
    if not running then return true end
    running = false

    if hbConn then hbConn:Disconnect() hbConn = nil end

    -- Always restore to saved position when stopping, if any
    if savedPosition then
        restoreToSavedPosition()
    else
        -- ensure hover removed
        local _, hrp = ensureCharacter()
        if hrp then removeHoverBP(hrp) end
    end

    currentTarget = nil
    table.clear(lastKnownActiveProps)
    print("[AutoTeleportEvent] Stopped and restored position (if available)")
    return true
end

function AutoTeleportEvent:Cleanup()
    self:Stop()
    if charConn then charConn:Disconnect() charConn = nil end
    if propsAddedConn then propsAddedConn:Disconnect() propsAddedConn = nil end
    if propsRemovedConn then propsRemovedConn:Disconnect() propsRemovedConn = nil end
    if workspaceConn then workspaceConn:Disconnect() workspaceConn = nil end

    eventsFolder = nil
    table.clear(validEventName)
    table.clear(selectedPriorityList)
    table.clear(selectedSet)
    table.clear(lastKnownActiveProps)
    savedPosition = nil
    currentTarget = nil

    print("[AutoTeleportEvent] Cleanup completed")
    return true
end

-- ===== Setters =====
function AutoTeleportEvent:SetSelectedEvents(selected)
    table.clear(selectedPriorityList)
    table.clear(selectedSet)

    if type(selected) == "table" then
        if #selected > 0 then
            for _, v in ipairs(selected) do
                local key = normName(v)
                table.insert(selectedPriorityList, key)
                selectedSet[key] = true
            end
            print("[AutoTeleportEvent] Priority events set:", table.concat(selectedPriorityList, ", "))
        else
            for k, on in pairs(selected) do
                if on then
                    local key = normName(k)
                    selectedSet[key] = true
                end
            end
        end
    elseif type(selected) == "string" then
        local key = normName(selected)
        selectedSet[key] = true
        table.insert(selectedPriorityList, key)
    end
    return true
end

function AutoTeleportEvent:SetHoverHeight(h)
    if type(h) == "number" then
        hoverHeight = math.clamp(h, 5, 100)
        if running and currentTarget then
            local _, hrp = ensureCharacter()
            if hrp then
                local desired = currentTarget.pos + Vector3.new(0, hoverHeight, 0)
                local bp = ensureHoverBP(hrp)
                if bp then
                    bp.Position = desired
                else
                    setCFrameSafely(hrp, desired)
                end
            end
        end
        return true
    end
    return false
end

function AutoTeleportEvent:Status()
    return {
        running     = running,
        hover       = hoverHeight,
        hasSavedPos = savedPosition ~= nil,
        target      = currentTarget and currentTarget.name or nil,
        activeProps = lastKnownActiveProps
    }
end

function AutoTeleportEvent.new()
    local self = setmetatable({}, AutoTeleportEvent)
    return self
end

-- ===== Debug helpers =====
-- Print all ReplicatedStorage.Events names and mark active ones (normalized match)
function AutoTeleportEvent.Debug_ListAllEventsWithStatus()
    local eventsFolder = ReplicatedStorage:FindFirstChild("Events")
    if not eventsFolder then
        warn("[AutoTeleportEvent DEBUG] No Events folder in ReplicatedStorage")
        return
    end
    local active = scanAllActiveProps()
    local activeMap = {}
    for _, a in ipairs(active) do
        activeMap[a.nameKey] = true
    end

    print("===== [DEBUG] Events (status) =====")
    local function scan(f)
        for _, child in ipairs(f:GetChildren()) do
            if child:IsA("ModuleScript") then
                local ok, data = pcall(require, child)
                local name = (ok and data and data.Name) or child.Name
                local status = activeMap[normName(name)] and "[AKTIF]" or "[NONAKTIF]"
                print(status, name)
            elseif child:IsA("Folder") then
                scan(child)
            end
        end
    end
    scan(eventsFolder)
    print("===================================")
end

-- Print active events discovered in Workspace (for quick debug)
function AutoTeleportEvent.Debug_PrintActiveWorkspaceEvents()
    local actives = scanAllActiveProps()
    print("===== [DEBUG] Active Workspace Props Events =====")
    for _, e in ipairs(actives) do
        print(string.format("[ACTIVE] %s (norm=%s) @ (%.2f, %.2f, %.2f) from Props=%s",
            e.name, e.nameKey, e.pos.X, e.pos.Y, e.pos.Z, e.propsName))
    end
    print("===============================================")
end

return AutoTeleportEvent
