-- ===========================
-- AUTO FISH FEATURE - SPAM METHOD
-- File: autofish.lua
-- ===========================

local AutoFishFeature = {}
AutoFishFeature.__index = AutoFishFeature

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")  
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

-- Network setup
local NetPath = nil
local EquipTool, ChargeFishingRod, RequestFishing, FishingCompleted

local function initializeRemotes()
    local success = pcall(function()
        NetPath = ReplicatedStorage:WaitForChild("Packages", 5)
            :WaitForChild("_Index", 5)
            :WaitForChild("sleitnick_net@0.2.0", 5)
            :WaitForChild("net", 5)
        
        EquipTool = NetPath:WaitForChild("RE/EquipToolFromHotbar", 5)
        ChargeFishingRod = NetPath:WaitForChild("RF/ChargeFishingRod", 5)
        RequestFishing = NetPath:WaitForChild("RF/RequestFishingMinigameStarted", 5)
        FishingCompleted = NetPath:WaitForChild("RE/FishingCompleted", 5)
        
        return true
    end)
    
    return success
end

-- Feature state
local isRunning = false
local currentMode = "Perfect"
local connection = nil
local spamConnection = nil
local controls = {}
local fishingInProgress = false
local lastFishTime = 0
local remotesInitialized = false

-- Spam and completion tracking
local spamActive = false
local completionCheckActive = false
local lastBackpackCount = 0

-- Rod-specific configs
local FISHING_CONFIGS = {
    ["Perfect"] = {
        chargeTime = 1.0,
        waitBetween = 0,
        rodSlot = 1,
        spamDelay = 0.05,      -- Spam every 100ms
        maxSpamTime = 3      -- Stop spam after 10s
    },
    ["OK"] = {
        chargeTime = 0.9,
        waitBetween = 0.3,
        rodSlot = 1,
        spamDelay = 0.1,
        maxSpamTime = 8
    },
    ["Mid"] = {
        chargeTime = 0.5,
        waitBetween = 0.2,
        rodSlot = 1,
        spamDelay = 0.1,
        maxSpamTime = 6
    }
}

-- Initialize
function AutoFishFeature:Init(guiControls)
    controls = guiControls or {}
    remotesInitialized = initializeRemotes()
    
    if not remotesInitialized then
        warn("[AutoFish] Failed to initialize remotes")
        return false
    end
    
    -- Initialize backpack count for completion detection
    self:UpdateBackpackCount()
    
    print("[AutoFish] Initialized with SPAM method")
    return true
end

-- Start fishing
function AutoFishFeature:Start(config)
    if isRunning then return end
    
    if not remotesInitialized then
        warn("[AutoFish] Cannot start - remotes not initialized")
        return
    end
    
    isRunning = true
    currentMode = config.mode or "Perfect"
    fishingInProgress = false
    spamActive = false
    lastFishTime = 0
    
    print("[AutoFish] Started SPAM method - Mode:", currentMode)
    
    -- Main fishing loop
    connection = RunService.Heartbeat:Connect(function()
        if not isRunning then return end
        self:SpamFishingLoop()
    end)
end

-- Stop fishing
function AutoFishFeature:Stop()
    if not isRunning then return end
    
    isRunning = false
    fishingInProgress = false
    spamActive = false
    completionCheckActive = false
    
    if connection then
        connection:Disconnect()
        connection = nil
    end
    
    if spamConnection then
        spamConnection:Disconnect()
        spamConnection = nil
    end
    
    print("[AutoFish] Stopped SPAM method")
end

-- Main spam-based fishing loop
function AutoFishFeature:SpamFishingLoop()
    if fishingInProgress or spamActive then return end
    
    local currentTime = tick()
    local config = FISHING_CONFIGS[currentMode]
    
    -- Wait between cycles
    if currentTime - lastFishTime < config.waitBetween then
        return
    end
    
    -- Start fishing sequence
    fishingInProgress = true
    lastFishTime = currentTime
    
    spawn(function()
        local success = self:ExecuteSpamFishingSequence()
        fishingInProgress = false
        
        if success then
            print("[AutoFish] SPAM cycle completed!")
        end
    end)
end

-- Execute spam-based fishing sequence
function AutoFishFeature:ExecuteSpamFishingSequence()
    local config = FISHING_CONFIGS[currentMode]
    
    -- Step 1: Equip rod
    if not self:EquipRod(config.rodSlot) then
        return false
    end
    
    task.wait(0.1)

    -- Step 2: Charge rod
    if not self:ChargeRod(config.chargeTime) then
        return false
    end
    
    -- Step 3: Cast rod
    if not self:CastRod() then
        return false
    end
    
    -- Step 4: Start completion spam
    self:StartCompletionSpam(config.spamDelay, config.maxSpamTime)
    
    return true
end

-- Equip rod
function AutoFishFeature:EquipRod(slot)
    if not EquipTool then return false end
    
    local success = pcall(function()
        EquipTool:FireServer(slot)
    end)
    
    return success
end

-- Charge rod
function AutoFishFeature:ChargeRod(chargeTime)
    if not ChargeFishingRod then return false end
    
    local success = pcall(function()
        local chargeValue = tick() + (chargeTime * 1000)
        return ChargeFishingRod:InvokeServer(chargeValue)
    end)
    
    return success
end

-- Cast rod
function AutoFishFeature:CastRod()
    if not RequestFishing then return false end
    
    local success = pcall(function()
        local x = -1.233184814453125
        local z =  0.9999120558411321
        return RequestFishing:InvokeServer(x, z)
    end)
    
    return success
end

-- Start spamming FishingCompleted
function AutoFishFeature:StartCompletionSpam(delay, maxTime)
    if spamActive then return end
    
    spamActive = true
    completionCheckActive = true
    local spamStartTime = tick()
    
    print("[AutoFish] Starting completion SPAM...")
    
    -- Update backpack count before spam
    self:UpdateBackpackCount()
    
    spawn(function()
        while spamActive and isRunning and (tick() - spamStartTime) < maxTime do
            -- Fire completion
            local fired = self:FireCompletion()
            
            -- Check if fishing completed
            if self:CheckFishingCompleted() then
                print("[AutoFish] Fish caught via SPAM method!")
                break
            end
            
            wait(delay)
        end
        
        -- Stop spam
        spamActive = false
        completionCheckActive = false
        
        if (tick() - spamStartTime) >= maxTime then
            print("[AutoFish] SPAM timeout after", maxTime, "seconds")
        end
    end)
end

-- Fire FishingCompleted
function AutoFishFeature:FireCompletion()
    if not FishingCompleted then return false end
    
    local success = pcall(function()
        FishingCompleted:FireServer()
    end)
    
    return success
end

-- Check if fishing completed successfully
function AutoFishFeature:CheckFishingCompleted()
    -- Method 1: Check backpack item count increase
    local currentCount = self:GetBackpackItemCount()
    if currentCount > lastBackpackCount then
        lastBackpackCount = currentCount
        return true
    end
    
    -- Method 2: Check character tool state
    if LocalPlayer.Character then
        local tool = LocalPlayer.Character:FindFirstChildOfClass("Tool")
        if not tool then
            -- Tool unequipped = fishing might be done
            return false -- Don't rely on this alone
        end
    end
    
    -- Method 3: Check player stats (if game has fishing stats)
    -- This is game-specific, might need adjustment
    
    return false
end

-- Update backpack count
function AutoFishFeature:UpdateBackpackCount()
    lastBackpackCount = self:GetBackpackItemCount()
end

-- Get current backpack item count
function AutoFishFeature:GetBackpackItemCount()
    local count = 0
    
    if LocalPlayer.Backpack then
        count = count + #LocalPlayer.Backpack:GetChildren()
    end
    
    if LocalPlayer.Character then
        for _, child in pairs(LocalPlayer.Character:GetChildren()) do
            if child:IsA("Tool") then
                count = count + 1
            end
        end
    end
    
    return count
end

-- Get status
function AutoFishFeature:GetStatus()
    return {
        running = isRunning,
        mode = currentMode,
        inProgress = fishingInProgress,
        spamming = spamActive,
        lastCatch = lastFishTime,
        backpackCount = lastBackpackCount,
        remotesReady = remotesInitialized
    }
end

-- Update mode
function AutoFishFeature:SetMode(mode)
    if FISHING_CONFIGS[mode] then
        currentMode = mode
        print("[AutoFish] SPAM mode changed to:", mode)
        return true
    end
    return false
end

-- Cleanup
function AutoFishFeature:Cleanup()
    print("[AutoFish] Cleaning up SPAM method...")
    self:Stop()
    controls = {}
    remotesInitialized = false
end

return AutoFishFeature