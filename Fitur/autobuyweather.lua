-- ===========================
-- AUTO BUY WEATHER FEATURE
-- File: autobuyweather.lua
-- ===========================
-- AUTO BUY WEATHER (multi-select)
-- Lifecycle: :Init(guiControls?), :Start(config?), :Stop(), :Cleanup()
-- Setters  : :SetWeathers({ "Shark Hunt", ... }), :SetInterPurchaseDelay(number)
-- Helpers  : :GetBuyableWeathers() -> {names}
-- ===========================

local AutoBuyWeather = {}
AutoBuyWeather.__index = AutoBuyWeather

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local EventsFolder      = ReplicatedStorage:WaitForChild("Events")
local NetPath, PurchaseWeatherRF

-- State
local isRunning            = false
local conn                 = nil
local remotesReady         = false

local buyableMap           = nil             -- [name] = moduleData
local selectedWeathers     = {}              -- array of names (max 3)
local nextIdx              = 1               -- round-robin pointer

-- anti-spam per weather (use expiry timestamp = now + (QueueTime+Duration))
local cooldownUntil        = {}              -- [name] = unixTime

-- inter-purchase guard antar InvokeServer (global)
local interPurchaseDelay   = 0.75            -- seconds, configurable
local lastGlobalPurchaseAt = 0

-- pacing
local TICK_STEP            = 0.15
local _lastTick            = 0

-- ========= helpers =========
local function initRemotes()
    return pcall(function()
        NetPath = ReplicatedStorage:WaitForChild("Packages", 5)
            :WaitForChild("_Index", 5)
            :WaitForChild("sleitnick_net@0.2.0", 5)
            :WaitForChild("net", 5)
        PurchaseWeatherRF = NetPath:WaitForChild("RF/PurchaseWeatherEvent", 5)
    end)
end

local function _collectBuyables(root, map)
    for _, ch in ipairs(root:GetChildren()) do
        if ch:IsA("ModuleScript") then
            local ok, data = pcall(require, ch)
            if ok and type(data) == "table"
               and data.WeatherMachine
               and type(data.Name) == "string" then
                map[data.Name] = data
            end
        elseif ch:IsA("Folder") then
            _collectBuyables(ch, map)
        end
    end
end

local function scanBuyables()
    local map = {}
    local events = ReplicatedStorage:FindFirstChild("Events")
    if events then _collectBuyables(events, map) end
    return map
end


function AutoBuyWeather:GetBuyableWeathers()
    buyableMap = scanBuyables()
    local names = {}
    for n in pairs(buyableMap) do table.insert(names, n) end
    table.sort(names)
    return names
end

local function purchaseOnce(name)
    if not PurchaseWeatherRF then return false end
    local ok, err = pcall(function()
        return PurchaseWeatherRF:InvokeServer(name)
    end)
    if not ok then
        warn("[AutoBuyWeather] Purchase failed for '"..tostring(name).."': "..tostring(err))
    end
    return ok
end

local function nowSec()
    return tick()
end

-- Pick next eligible weather (round-robin) that is buyable & off cooldown
local function pickNextWeather()
    if #selectedWeathers == 0 then return nil end
    local start = nextIdx
    for _ = 1, #selectedWeathers do
        local name = selectedWeathers[nextIdx]
        nextIdx = (nextIdx % #selectedWeathers) + 1

        if not buyableMap or not buyableMap[name] then
            buyableMap = scanBuyables()
        end
        local data = buyableMap and buyableMap[name]
        if data then
            local tnow = nowSec()
            if not cooldownUntil[name] or tnow >= cooldownUntil[name] then
                return name, data
            end
        end
        -- continue checking others
    end
    return nil
end

-- ========= lifecycle =========
function AutoBuyWeather:Init(guiControls)
    local ok = initRemotes()
    remotesReady = ok and true or false
    if not remotesReady then
        warn("[AutoBuyWeather] remotes not ready")
        return false
    end

    -- initial scan
    buyableMap = scanBuyables()

    -- jika GUI multi-dropdown disuplai, isi opsinya
    if guiControls and guiControls.weatherDropdownMulti then
        local dd = guiControls.weatherDropdownMulti
        local names = self:GetBuyableWeathers()
        if dd.Reload then dd:Reload(names)
        elseif dd.SetOptions then dd:SetOptions(names) end

        -- refresh sekali lagi setelah 1–2 detik (buat timing replicate)
        task.delay(1.5, function()
            local names2 = self:GetBuyableWeathers()
            if dd.Reload then dd:Reload(names2)
            elseif dd.SetOptions then dd:SetOptions(names2) end
        end)

        if dd.OnChanged then
            dd:OnChanged(function(list)
                if typeof(list) ~= "table" then list = {list} end
                self:SetWeathers(list)
            end)
        end
    end

    return true
end


-- config: { weatherList = { "Shark Hunt", "..." }, interDelay = 0.75 }
function AutoBuyWeather:Start(config)
    if isRunning then return end
    if not remotesReady then
        warn("[AutoBuyWeather] Start blocked: remotes not ready")
        return
    end

    if config then
        if type(config.interDelay) == "number" then self:SetInterPurchaseDelay(config.interDelay) end
        if type(config.weatherList) == "table" then self:SetWeathers(config.weatherList)
        elseif type(config.weatherList) == "string" then self:SetWeathers({config.weatherList}) end
    end

    if #selectedWeathers == 0 then
        warn("[AutoBuyWeather] No weather selected")
        return
    end

    isRunning = true
    conn = RunService.Heartbeat:Connect(function()
        if not isRunning then return end
        local t = nowSec()
        if t - _lastTick < TICK_STEP then return end
        _lastTick = t

        -- respect global inter-purchase delay
        if t - lastGlobalPurchaseAt < interPurchaseDelay then return end

        local name, data = pickNextWeather()
        if not name or not data then return end

        if purchaseOnce(name) then
            lastGlobalPurchaseAt = t
            local total = (data.QueueTime or 0) + (data.Duration or 0)
            if total > 0 then
                cooldownUntil[name] = t + total
            else
                -- minimal cooldown untuk jaga-jaga
                cooldownUntil[name] = t + 2
            end
        end
    end)
end

function AutoBuyWeather:Stop()
    if not isRunning then return end
    isRunning = false
    if conn then conn:Disconnect() conn = nil end
end

function AutoBuyWeather:Cleanup()
    self:Stop()
    buyableMap           = nil
    cooldownUntil        = {}
    selectedWeathers     = {}
    nextIdx              = 1
    lastGlobalPurchaseAt = 0
end

-- ========= setters =========
-- list: table of strings (akan di-unique + clamp 3 + filter only buyable)
function AutoBuyWeather:SetWeathers(listOrSet)
    if typeof(listOrSet) ~= "table" then return false end
    -- koersi: dukung array {"A","B"} atau set {A=true,B=true}
    local arr = {}
    if #listOrSet > 0 then
        -- array
        for _, v in ipairs(listOrSet) do
            if type(v) == "string" and v ~= "" then table.insert(arr, v) end
        end
    else
        -- set/dict
        for k, v in pairs(listOrSet) do
            if v and type(k) == "string" and k ~= "" then table.insert(arr, k) end
        end
    end
    -- unique + clamp 3 + filter buyable
    if not buyableMap then buyableMap = scanBuyables() end
    local seen, out = {}, {}
    for _, name in ipairs(arr) do
        if buyableMap[name] and not seen[name] then
            table.insert(out, name)
            seen[name] = true
            if #out >= 3 then break end
        end
    end
    selectedWeathers = out
    nextIdx = 1
    return #selectedWeathers > 0
end


function AutoBuyWeather:SetInterPurchaseDelay(sec)
    if type(sec) ~= "number" then return false end
    -- clamp biar aman (hindari flood maupun terlalu lama)
    interPurchaseDelay = math.clamp(sec, 0.2, 5)
    return true
end

return AutoBuyWeather
