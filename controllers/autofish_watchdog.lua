-- autofish_watchdog.lua
local M = {}
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local AutoFishController
local Utils
local Window

local watchdog = {
    enabled = false,
    timeout = 20,
    checkInterval = 3,
    thread = nil,
    lastHeartbeat = 0,
    lastSnapshot = nil,
    retryCount = 0,
    maxRetriesBeforeRespawn = 2,
}

local function safeRead(tbl, key)
    local ok, res = pcall(function()
        if type(tbl[key]) == "function" then return tbl[key](tbl) else return tbl[key] end
    end)
    if ok then return res else return nil end
end

local function snapshotCounters(feature)
    if not feature then return nil end
    local keys = {"catchCount","caught","catches","casts","castCount","totalCaught"}
    local snap = {}
    for _,k in ipairs(keys) do
        local v = safeRead(feature, k)
        if type(v)=="number" then snap[k]=v end
    end
    if feature and feature.settings and type(feature.settings)=="table" then
        for k,v in pairs(feature.settings) do if type(v)=="number" then snap["settings."..k]=v end end
    end
    return snap
end

local function snapshotChanged(a,b)
    if not a or not b then return false end
    for k,v in pairs(a) do if b[k] and b[k]~=v then return true end end
    for k,v in pairs(b) do if a[k] and a[k]~=v then return true end end
    return false
end

local function isRodLikelyStuck()
    local char = Players.LocalPlayer.Character
    if not char then return false end
    for _,c in ipairs(char:GetChildren()) do
        if c:IsA("Tool") and c.Name:lower():find("rod") then
            for _,d in ipairs(c:GetDescendants()) do
                if d.Name:lower():find("bobber") or d.Name:lower():find("line") or d.Name:lower():find("hook") then
                    return true
                end
            end
        end
    end
    return false
end

local function lightweightRestart(reason)
    pcall(function()
        AutoFishController.ForceUnstuckFishing()
        task.wait(0.6)
        AutoFishController.StopAutoFish()
        task.wait(0.35)
        AutoFishController.StartAutoFish()
    end)
end

local function escalateRespawn(reason)
    pcall(function()
        AutoFishController.HardRespawnAndReturn()
        task.wait(1.5)
        AutoFishController.StartAutoFish()
    end)
end

local function startWatchdog()
    if watchdog.thread then return end
    watchdog.enabled = true
    watchdog.lastHeartbeat = tick()
    watchdog.lastSnapshot = snapshotCounters(AutoFishController.GetFeature())
    watchdog.retryCount = 0
    watchdog.thread = task.spawn(function()
        while watchdog.enabled do
            task.wait(watchdog.checkInterval)
            if not watchdog.enabled then break end
            local feature = AutoFishController.GetFeature()
            if not feature then
                watchdog.lastHeartbeat = tick()
                watchdog.lastSnapshot = snapshotCounters(feature)
                continue
            end
            -- attempt to detect heartbeat from feature
            local hb = safeRead(feature, "__ucokk_last_heartbeat") or safeRead(feature, "lastCatchTime") or safeRead(feature, "lastActionTime")
            if hb and type(hb)=="number" then
                watchdog.lastHeartbeat = hb
            end
            -- snapshot check
            local snap = snapshotCounters(feature)
            if snap and watchdog.lastSnapshot and snapshotChanged(watchdog.lastSnapshot, snap) then
                watchdog.lastHeartbeat = tick()
                watchdog.lastSnapshot = snap
                watchdog.retryCount = 0
            elseif snap then
                watchdog.lastSnapshot = snap
            end
            local rodStuck = pcall(isRodLikelyStuck)
            if rodStuck == nil then rodStuck = false end
            local elapsed = tick() - (watchdog.lastHeartbeat or 0)
            if elapsed >= watchdog.timeout or rodStuck then
                watchdog.retryCount = watchdog.retryCount + 1
                local reasonStr = "no activity for "..tostring(math.floor(elapsed)).."s"
                if rodStuck then reasonStr = reasonStr.." (rod heuristics)" end
                lightweightRestart(reasonStr)
                if watchdog.retryCount > watchdog.maxRetriesBeforeRespawn then
                    escalateRespawn(reasonStr)
                    watchdog.retryCount = 0
                end
                watchdog.lastHeartbeat = tick()
                watchdog.lastSnapshot = snapshotCounters(feature)
            end
        end
        watchdog.thread = nil
    end)
end

local function stopWatchdog()
    watchdog.enabled = false
    watchdog.thread = nil
    watchdog.retryCount = 0
end

function M.Init(afController, utils, window)
    AutoFishController = afController
    Utils = utils
    Window = window
    -- start/stop hooks: simple polling to see if AutoFishing is active by checking feature existence
    task.spawn(function()
        local lastActive = false
        while true do
            task.wait(0.6)
            local feature = AutoFishController.GetFeature()
            local active = feature ~= nil
            if active ~= lastActive then
                lastActive = active
                if active then startWatchdog() else stopWatchdog() end
            end
        end
    end)
end

function M.Start() startWatchdog() end
function M.Stop() stopWatchdog() end

return M
