-- Fish-It/AutoBuyBait.lua
-- AutoBuyBait Feature mengikuti Fish-It Feature Script Contract

local AutoBuyBait = {}
AutoBuyBait.__index = AutoBuyBait

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Constants
local INTER_PURCHASE_DELAY = 0.5 -- Anti-spam delay antar pembelian

-- State variables
local running = false
local baitsFolder = nil
local purchaseBaitRemote = nil
local guiControls = {}

-- Storage untuk tracking bait yang sudah dibeli (persistent)
local purchasedBaits = {}
local selectedBaits = {} -- Bait yang dipilih dari dropdown multi
local lastPurchaseTime = 0

-- ========== LIFECYCLE METHODS ==========

function AutoBuyBait:Init(gui)
    -- Store GUI controls reference
    guiControls = gui or {}
    
    -- Initialize ReplicatedStorage references with timeout
    local success1, baits = pcall(function()
        return ReplicatedStorage:WaitForChild("Baits", 5)
    end)
    
    local success2, remote = pcall(function()
        return ReplicatedStorage:WaitForChild("Packages", 5)
            :WaitForChild("_Index", 5)
            :WaitForChild("sleitnick_net@0.2.0", 5)
            :WaitForChild("net", 5)
            :WaitForChild("RF/PurchaseBait", 5)
    end)
    
    if not success1 or not baits then
        warn("[AutoBuyBait] Failed to find ReplicatedStorage.Baits")
        return false
    end
    
    if not success2 or not remote then
        warn("[AutoBuyBait] Failed to find PurchaseBait remote")
        return false
    end
    
    baitsFolder = baits
    purchaseBaitRemote = remote
    
    -- Pre-populate dropdown if GUI control exists
    if guiControls.baitsDropdown and guiControls.baitsDropdown.Reload then
        local baitOptions = {}
        local allBaits = self:_scanAllBaits()
        
        for _, bait in ipairs(allBaits) do
            local displayText = string.format("%s (T%d - %d coins)", bait.name, bait.tier, bait.price)
            table.insert(baitOptions, displayText)
        end
        
        guiControls.baitsDropdown:Reload(baitOptions)
    end
    
    return true
end

function AutoBuyBait:Start(config)
    if not running then
        running = true
        
        -- Parse config jika ada
        if config then
            if config.baitList then
                self:SetSelectedBaits(config.baitList)
            end
            if config.interDelay then
                INTER_PURCHASE_DELAY = math.max(0.1, config.interDelay)
            end
        end
    end
    
    -- Langsung lakukan pembelian (one-time) kemudian stop
    print("[AutoBuyBait] Starting purchase process...")
    local success = self:PurchaseSelectedBaits()
    
    -- Stop setelah purchase
    self:Stop()
    return success
end

function AutoBuyBait:Stop()
    if not running then return end
    running = false
end

function AutoBuyBait:Cleanup()
    self:Stop()
    
    -- Reset state
    selectedBaits = {}
    guiControls = {}
    lastPurchaseTime = 0
    
    -- Don't reset purchasedBaits - ini harus persistent
end

-- ========== SETTERS & ACTIONS (Feature-Specific) ==========

-- Setter untuk bait yang dipilih dari dropdown multi
function AutoBuyBait:SetSelectedBaits(baitList)
    if not baitList then return false end
    
    selectedBaits = {}
    
    -- Normalisasi input: terima array atau set/dict
    if type(baitList) == "table" then
        if #baitList > 0 then
            -- Array format
            for _, baitName in ipairs(baitList) do
                if type(baitName) == "string" then
                    table.insert(selectedBaits, baitName)
                end
            end
        else
            -- Set/dict format
            for baitName, enabled in pairs(baitList) do
                if enabled and type(baitName) == "string" then
                    table.insert(selectedBaits, baitName)
                end
            end
        end
    end
    
    return true
end

-- Action untuk membeli semua bait yang dipilih (one-time purchase)
function AutoBuyBait:PurchaseSelectedBaits()
    if not running then
        warn("[AutoBuyBait] Feature not started")
        return false
    end
    
    if #selectedBaits == 0 then
        warn("[AutoBuyBait] No baits selected")
        return false
    end
    
    local currentTime = tick()
    if currentTime - lastPurchaseTime < INTER_PURCHASE_DELAY then
        warn("[AutoBuyBait] Purchase cooldown active")
        return false
    end
    
    local purchasedCount = 0
    local skippedCount = 0
    local errorCount = 0
    
    -- Scan semua bait untuk mendapatkan data
    local allBaits = self:_scanAllBaits()
    local baitDataMap = {}
    for _, bait in ipairs(allBaits) do
        baitDataMap[bait.name] = bait
    end
    
    -- Proses pembelian untuk setiap bait yang dipilih
    for _, baitName in ipairs(selectedBaits) do
        local baitData = baitDataMap[baitName]
        
        if not baitData then
            warn("[AutoBuyBait] Bait data not found: " .. baitName)
            errorCount = errorCount + 1
        elseif self:IsBaitPurchased(baitData.id) then
            -- Skip jika sudah dibeli
            skippedCount = skippedCount + 1
        else
            -- Coba beli bait
            local success = self:_purchaseBait(baitData.id, baitData.name)
            if success then
                purchasedCount = purchasedCount + 1
                self:_markBaitAsPurchased(baitData.id)
            else
                errorCount = errorCount + 1
            end
            
            -- Anti-spam delay
            if purchasedCount > 0 then
                task.wait(INTER_PURCHASE_DELAY)
            end
        end
    end
    
    lastPurchaseTime = currentTime
    
    -- Log hasil
    local resultMsg = string.format("[AutoBuyBait] Purchase complete: %d bought, %d skipped, %d errors", 
        purchasedCount, skippedCount, errorCount)
    print(resultMsg)
    
    return purchasedCount > 0
end

-- Getter untuk cek apakah bait sudah dibeli
function AutoBuyBait:IsBaitPurchased(baitId)
    return purchasedBaits[baitId] == true
end

-- Getter untuk mendapatkan semua bait yang tersedia
function AutoBuyBait:GetAvailableBaits()
    return self:_scanAllBaits()
end

-- Reset tracking bait yang sudah dibeli (untuk testing)
function AutoBuyBait:ResetPurchaseHistory()
    purchasedBaits = {}
    return true
end

-- ========== INTERNAL HELPER METHODS ==========

-- Scan semua bait dari ReplicatedStorage.Baits (rekursif)
function AutoBuyBait:_scanAllBaits()
    local baitsList = {}
    
    if not baitsFolder then
        return baitsList
    end
    
    -- Scan rekursif untuk semua ModuleScript di folder Baits
    local function scanFolder(folder)
        for _, child in pairs(folder:GetChildren()) do
            if child:IsA("ModuleScript") then
                local success, baitData = pcall(require, child)
                if success and baitData and baitData.Data then
                    table.insert(baitsList, {
                        name = baitData.Data.Name or "Unknown",
                        id = baitData.Data.Id or 0,
                        price = baitData.Price or 0,
                        tier = baitData.Data.Tier or 1,
                        description = baitData.Data.Description or "",
                        modifiers = baitData.Modifiers or {},
                        module = child
                    })
                end
            elseif child:IsA("Folder") then
                scanFolder(child) -- Rekursif untuk subfolder
            end
        end
    end
    
    scanFolder(baitsFolder)
    
    -- Sort berdasarkan tier dan nama
    table.sort(baitsList, function(a, b)
        if a.tier == b.tier then
            return a.name < b.name
        end
        return a.tier < b.tier
    end)
    
    return baitsList
end

-- Internal purchase function dengan error handling
function AutoBuyBait:_purchaseBait(baitId, baitName)
    if not purchaseBaitRemote then
        warn("[AutoBuyBait] Purchase remote not available")
        return false
    end
    
    local success, result = pcall(function()
        return purchaseBaitRemote:InvokeServer(baitId)
    end)
    
    if success and result then
        print("[AutoBuyBait] Successfully purchased: " .. baitName .. " (ID: " .. baitId .. ")")
        return true
    else
        warn("[AutoBuyBait] Failed to purchase " .. baitName .. ": " .. tostring(result))
        return false
    end
end

-- Mark bait sebagai sudah dibeli
function AutoBuyBait:_markBaitAsPurchased(baitId)
    purchasedBaits[baitId] = true
end

return AutoBuyBait
