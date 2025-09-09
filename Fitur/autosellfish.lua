-- ===========================
-- AUTO SELL FISH FEATURE
-- File: autosellfish.lua

local AutoSellFish = {}
AutoSellFish.__index = AutoSellFish

-- Services
local Players        = game:GetService("Players")
local Replicated     = game:GetService("ReplicatedStorage")
local RunService     = game:GetService("RunService")
local LocalPlayer    = Players.LocalPlayer

-- Network objects (initialized in Init)
local NetPath = nil
local UpdateAutoSellThresholdRF, SellAllItemsRF

-- Rarity threshold enumeration. These numeric codes must match the
-- serverside expectations for UpdateAutoSellThreshold.
local THRESHOLD_ENUM = {
    Legendary = 5,
    Mythic    = 6,
    Secret    = 7,
}

local isRunning          = false
local connection         = nil
local remotesInitialized = false
local currentMode        = "Legendary" -- default rarity threshold
local lastAppliedMode    = nil         -- used to debounce threshold updates
local limitEnabled       = true        -- auto sell will run when true
local limitValue         = 0           -- delay (seconds) between sales; 0 = immediate
local lastSellTime       = 0           -- timestamp of the last sale

-- Interval between loop iterations (in seconds). A small wait
-- prevents the loop from overloading the Heartbeat event.
local WAIT_BETWEEN = 0.15
local _lastTick    = 0

--------------------------------------------------------------------------
--------------------------------------------------------------------------


-- Apply the rarity threshold on the server. This function is debounced
-- using `lastAppliedMode` to avoid sending the same value repeatedly.
function AutoSellFish:_applyThreshold(mode)
    if not UpdateAutoSellThresholdRF then return false end
    if lastAppliedMode == mode then return true end
    local code = THRESHOLD_ENUM[mode]
    if not code then return false end
    local ok = pcall(function()
        UpdateAutoSellThresholdRF:InvokeServer(code)
    end)
    if ok then
        lastAppliedMode = mode
    else
        warn("[AutoSellFish] Failed to apply threshold: " .. tostring(mode))
    end
    return ok
end

-- Trigger the remote call to sell all fish. Returns true on success.
function AutoSellFish:PerformSellAll()
    if not SellAllItemsRF then return false end
    local ok = pcall(function()
        SellAllItemsRF:InvokeServer()
    end)
    if not ok then
        warn("[AutoSellFish] SellAllItems failed")
    end
    return ok
end

-- Initialize remote references. Returns true on success.
local function initializeRemotes()
    local success, err = pcall(function()
        NetPath = Replicated:WaitForChild("Packages", 5)
            :WaitForChild("_Index", 5)
            :WaitForChild("sleitnick_net@0.2.0", 5)
            :WaitForChild("net", 5)
        UpdateAutoSellThresholdRF = NetPath:WaitForChild("RF/UpdateAutoSellThreshold", 5)
        SellAllItemsRF            = NetPath:WaitForChild("RF/SellAllItems", 5)
    end)
    return success
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

-- Init must be called before using the module. Optionally accepts a table
-- of GUI controls (not used by this module but provided for API parity).
function AutoSellFish:Init(guiControls)
    remotesInitialized = initializeRemotes()
    if not remotesInitialized then
        warn("[AutoSellFish] Failed to initialize remotes")
        return false
    end
    -- no inventory count needed for time-based selling
    return true
end

-- Start the automation. Accepts a config table:
--  threshold   : string ("Legendary", "Mythic", "Secret")
--  limit       : number (delay between automatic sales in seconds; 0 sells every loop)
--  autoOnLimit : boolean (enable/disable automatic selling)
function AutoSellFish:Start(config)
    if isRunning then return end
    if not remotesInitialized then
        warn("[AutoSellFish] Cannot start - remotes not initialized")
        return
    end
    if config then
        if THRESHOLD_ENUM[config.threshold] then
            currentMode = config.threshold
        end
        if type(config.limit) == "number" then
            limitValue = math.max(0, math.floor(config.limit))
        end
        if type(config.autoOnLimit) == "boolean" then
            limitEnabled = config.autoOnLimit
        end
    end
    -- Apply threshold once on start
    self:_applyThreshold(currentMode)
    -- Initialize last sell timestamp so the timer starts now
    lastSellTime = tick()
    isRunning = true
    connection = RunService.Heartbeat:Connect(function()
        if not isRunning then return end
        self:_loop()
    end)
end

-- Stop the automation and disconnect events.
function AutoSellFish:Stop()
    if not isRunning then return end
    isRunning = false
    if connection then
        connection:Disconnect()
        connection = nil
    end
end

-- Cleanup resets internal state. Should be called when the feature is
-- unloaded from the GUI.
function AutoSellFish:Cleanup()
    self:Stop()
    remotesInitialized = false
end

-- Set the rarity threshold ("Legendary", "Mythic", "Secret"). Returns true
-- if the threshold is valid.
function AutoSellFish:SetMode(mode)
    if not THRESHOLD_ENUM[mode] then return false end
    currentMode = mode
    -- Apply immediately; debounced internally
    return self:_applyThreshold(mode)
end

-- Set the delay between automatic sales (in seconds). Must be non-negative.
function AutoSellFish:SetLimit(n)
    if type(n) ~= "number" then return false end
    limitValue = math.max(0, math.floor(n))
    return true
end

-- Enable or disable automatic selling.
function AutoSellFish:SetAutoSellOnLimit(enabled)
    limitEnabled = not not enabled
    return true
end

--------------------------------------------------------------------------
-- Internal loop
--------------------------------------------------------------------------

-- The heartbeat loop checks whether the fish count meets the limit and
-- triggers a sell if necessary. It also reapplies the threshold as needed.
function AutoSellFish:_loop()
    local now = tick()
    if now - _lastTick < WAIT_BETWEEN then
        return
    end
    _lastTick = now
    -- Ensure threshold is applied (debounced)
    self:_applyThreshold(currentMode)
    -- Auto sell on timer. If limitValue is 0, sell on every loop. Otherwise,
    -- sell when the interval has elapsed.
    if limitEnabled then
        if limitValue <= 0 then
            -- sell immediately on each iteration
            self:PerformSellAll()
            -- no need to track lastSellTime here
        else
            if now - lastSellTime >= limitValue then
                if self:PerformSellAll() then
                    -- record the time of this sale
                    lastSellTime = now
                end
            end
        end
    end
end

return AutoSellFish