-- Fish-It/autofavoritefish.lua
local AutoFavoriteFish = {}
AutoFavoriteFish.__index = AutoFavoriteFish

-- Services
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Dependencies
local InventoryWatcher = loadstring(game:HttpGet("https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/debug-script/inventdetectfishit.lua"))()

-- State
local running = false
local hbConn = nil
local inventoryWatcher = nil

-- Configuration
local selectedTiers = {} -- set: { [tierNumber] = true }
local TICK_STEP = 0.5 -- throttle interval
local FAVORITE_DELAY = 0.3 -- delay between favorite calls

-- Cache
local fishDataCache = {} -- { [fishId] = fishData }
local tierDataCache = {} -- { [tierNumber] = tierInfo }
local lastFavoriteTime = 0
local favoriteQueue = {} -- queue of fish UUIDs to favorite
local pendingFavorites = {}  -- [uuid] = lastActionTick (cooldown
local FAVORITE_COOLDOWN = 2.0

-- Remotes
local favoriteRemote = nil

-- === Helper Functions ===

local function loadTierData()
    local success, tierModule = pcall(function()
        return RS:WaitForChild("Tiers", 5)
    end)
    
    if not success or not tierModule then
        warn("[AutoFavoriteFish] Failed to find Tiers module")
        return false
    end
    
    local success2, tierList = pcall(function()
        return require(tierModule)
    end)
    
    if not success2 or not tierList then
        warn("[AutoFavoriteFish] Failed to load Tiers data")
        return false
    end
    
    -- Cache tier data
    for _, tierInfo in ipairs(tierList) do
        tierDataCache[tierInfo.Tier] = tierInfo
    end
    
    return true
end

local function scanFishData()
    local itemsFolder = RS:FindFirstChild("Items")
    if not itemsFolder then
        warn("[AutoFavoriteFish] Items folder not found")
        return false
    end
    
    local function scanRecursive(folder)
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("ModuleScript") then
                local success, data = pcall(function()
                    return require(child)
                end)
                
                if success and data and data.Data then
                    local fishData = data.Data
                    if fishData.Type == "Fishes" and fishData.Id and fishData.Tier then
                        fishDataCache[fishData.Id] = fishData
                    end
                end
            elseif child:IsA("Folder") then
                scanRecursive(child)
            end
        end
    end
    
    scanRecursive(itemsFolder)
    return next(fishDataCache) ~= nil
end

local function findFavoriteRemote()
    local success, remote = pcall(function()
        return RS:WaitForChild("Packages", 5)
                  :WaitForChild("_Index", 5)
                  :WaitForChild("sleitnick_net@0.2.0", 5)
                  :WaitForChild("net", 5)
                  :WaitForChild("RE/FavoriteItem", 5)
    end)
    
    if success and remote then
        favoriteRemote = remote
        return true
    end
    
    warn("[AutoFavoriteFish] Failed to find FavoriteItem remote")
    return false
end

local function shouldFavoriteFish(fishEntry)
    if not fishEntry then return false end
    
    local fishId = fishEntry.Id or fishEntry.id
    if not fishId then return false end
    
    local fishData = fishDataCache[fishId]
    if not fishData then return false end
    
    local tier = fishData.Tier
    if not tier then return false end
    
    -- Check if this tier is selected
    return selectedTiers[tier] == true
end

local function favoriteFish(uuid)
    if not favoriteRemote or not uuid then return false end
    
    local success = pcall(function()
        favoriteRemote:FireServer(uuid)
    end)
    
    if success then
        print("[AutoFavoriteFish] Favorited fish:", uuid)
    else
        warn("[AutoFavoriteFish] Failed to favorite fish:", uuid)
    end
    
    return success
end

local function getUUID(entry)
    return entry.UUID or entry.Uuid or entry.uuid
end

local function getFishId(entry)
    return entry.Id or entry.id
end

local function isFavorited(entry)
    -- cover common placements / casings
    if entry.Favorited ~= nil then return entry.Favorited end
    if entry.favorited ~= nil then return entry.favorited end
    if entry.Metadata and entry.Metadata.Favorited ~= nil then return entry.Metadata.Favorited end
    if entry.Metadata and entry.Metadata.favorited ~= nil then return entry.Metadata.favorited end
    return false
end

local function cooldownActive(uuid, now)
    local t = pendingFavorites[uuid]
    return t and (now - t) < FAVORITE_COOLDOWN
end
local function processInventory()
    if not inventoryWatcher then return end

    local fishes = inventoryWatcher:getSnapshotTyped("Fishes")
    if not fishes or #fishes == 0 then return end

    local now = tick()

    for _, fishEntry in ipairs(fishes) do
        -- Only favorite if tier matches AND it's not already favorited
        if shouldFavoriteFish(fishEntry) and not isFavorited(fishEntry) then
            local uuid = getUUID(fishEntry)
            if uuid and not cooldownActive(uuid, now) and not table.find(favoriteQueue, uuid) then
                table.insert(favoriteQueue, uuid)
            end
        end
    end
end

local function processFavoriteQueue()
    if #favoriteQueue == 0 then return end

    local currentTime = tick()
    if currentTime - lastFavoriteTime < FAVORITE_DELAY then return end

    local uuid = table.remove(favoriteQueue, 1)
    if uuid then
        if favoriteFish(uuid) then
            -- mark cooldown so we don't immediately toggle it back
            pendingFavorites[uuid] = currentTime
        end
        lastFavoriteTime = currentTime
    end
end


local function mainLoop()
    if not running then return end
    
    processInventory()
    processFavoriteQueue()
end

-- === Lifecycle Methods ===

function AutoFavoriteFish:Init(guiControls)
    -- Load tier data
    if not loadTierData() then
        return false
    end
    
    -- Scan fish data
    if not scanFishData() then
        return false
    end
    
    -- Find favorite remote
    if not findFavoriteRemote() then
        return false
    end
    
    -- Initialize inventory watcher
    inventoryWatcher = InventoryWatcher.new()
    
    -- Wait for inventory watcher to be ready
    inventoryWatcher:onReady(function()
        print("[AutoFavoriteFish] Inventory watcher ready")
    end)
    
    -- Populate GUI dropdown if provided
    if guiControls and guiControls.tierDropdown then
        local tierNames = {}
        for tierNum = 1, 7 do
            if tierDataCache[tierNum] then
                table.insert(tierNames, tierDataCache[tierNum].Name)
            end
        end
        
        -- Reload dropdown with tier names
        pcall(function()
            guiControls.tierDropdown:Reload(tierNames)
        end)
    end
    
    return true
end

function AutoFavoriteFish:Start(config)
    if running then return end
    
    -- Apply config if provided
    if config and config.tierList then
        self:SetTiers(config.tierList)
    end
    
    running = true
    
    -- Start main loop
    hbConn = RunService.Heartbeat:Connect(function()
        local success = pcall(mainLoop)
        if not success then
            warn("[AutoFavoriteFish] Error in main loop")
        end
    end)
    
    print("[AutoFavoriteFish] Started")
end

function AutoFavoriteFish:Stop()
    if not running then return end
    
    running = false
    
    -- Disconnect heartbeat
    if hbConn then
        hbConn:Disconnect()
        hbConn = nil
    end
    
    print("[AutoFavoriteFish] Stopped")
end

function AutoFavoriteFish:Cleanup()
    self:Stop()
    
    -- Clean up inventory watcher
    if inventoryWatcher then
        inventoryWatcher:destroy()
        inventoryWatcher = nil
    end
    
    -- Clear caches and queues
    table.clear(fishDataCache)
    table.clear(tierDataCache)
    table.clear(selectedTiers)
    table.clear(favoriteQueue)
    
    favoriteRemote = nil
    lastFavoriteTime = 0
    
    print("[AutoFavoriteFish] Cleaned up")
end

-- === Setters ===

function AutoFavoriteFish:SetTiers(tierInput)
    if not tierInput then return false end
    
    -- Clear current selection
    table.clear(selectedTiers)
    
    -- Handle both array and set formats
    if type(tierInput) == "table" then
        -- If it's an array of tier names
        if #tierInput > 0 then
            for _, tierName in ipairs(tierInput) do
                -- Find tier number by name
                for tierNum, tierInfo in pairs(tierDataCache) do
                    if tierInfo.Name == tierName then
                        selectedTiers[tierNum] = true
                        break
                    end
                end
            end
        else
            -- If it's a set/dict format
            for tierName, enabled in pairs(tierInput) do
                if enabled then
                    -- Find tier number by name
                    for tierNum, tierInfo in pairs(tierDataCache) do
                        if tierInfo.Name == tierName then
                            selectedTiers[tierNum] = true
                            break
                        end
                    end
                end
            end
        end
    end
    
    print("[AutoFavoriteFish] Selected tiers:", selectedTiers)
    return true
end

function AutoFavoriteFish:SetFavoriteDelay(delay)
    if type(delay) == "number" and delay >= 0.1 then
        FAVORITE_DELAY = delay
        return true
    end
    return false
end

function AutoFavoriteFish:SetDesiredTiersByNames(tierInput)
    return self:SetTiers(tierInput)
end

function AutoFavoriteFish:GetTierNames()
    local names = {}
    for tierNum = 1, 7 do
        if tierDataCache[tierNum] then
            table.insert(names, tierDataCache[tierNum].Name)
        end
    end
    return names
end

function AutoFavoriteFish:GetSelectedTiers()
    local selected = {}
    for tierNum, enabled in pairs(selectedTiers) do
        if enabled and tierDataCache[tierNum] then
            table.insert(selected, tierDataCache[tierNum].Name)
        end
    end
    return selected
end

function AutoFavoriteFish:GetQueueSize()
    return #favoriteQueue
end

-- Debug helper untuk lihat status favorit
function AutoFavoriteFish:DebugFishStatus(limit)
    if not inventoryWatcher then return end
    
    local fishes = inventoryWatcher:getSnapshotTyped("Fishes")
    if not fishes or #fishes == 0 then return end
    
    print("=== DEBUG FISH STATUS ===")
    for i, fishEntry in ipairs(fishes) do
        if limit and i > limit then break end
        
        local fishId = fishEntry.Id or fishEntry.id
        local uuid = fishEntry.UUID or fishEntry.Uuid or fishEntry.uuid
        local fishData = fishDataCache[fishId]
        local fishName = fishData and fishData.Name or "Unknown"
        
        -- Check various favorited field locations
        local favorited1 = fishEntry.Favorited
        local favorited2 = fishEntry.favorited  
        local favorited3 = fishEntry.Metadata and fishEntry.Metadata.Favorited
        local favorited4 = fishEntry.Metadata and fishEntry.Metadata.favorited
        
        print(string.format("%d. %s (%s)", i, fishName, uuid or "no-uuid"))
        print("   Favorited fields:", favorited1, favorited2, favorited3, favorited4)
        
        if fishData then
            local tierInfo = tierDataCache[fishData.Tier]
            local tierName = tierInfo and tierInfo.Name or "Unknown"
            print("   Tier:", tierName, "- Should favorite:", shouldFavoriteFish(fishEntry))
        end
        print("")
    end
end

return AutoFavoriteFish
