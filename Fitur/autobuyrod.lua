-- Fish-It/AutoBuyRod.lua
-- AutoBuyRod Feature mengikuti Fish-It Feature Script Contract

local AutoBuyRod = {}
AutoBuyRod.__index = AutoBuyRod

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Constants
local INTER_PURCHASE_DELAY = 0.5 -- Anti-spam delay antar pembelian

-- State variables
local running = false
local itemsFolder = nil
local purchaseRodRemote = nil
local guiControls = {}

-- Storage untuk tracking rod yang sudah dibeli (persistent)
local purchasedRods = {}
local selectedRods = {} -- Rod yang dipilih dari dropdown multi
local lastPurchaseTime = 0

-- ========== LIFECYCLE METHODS ==========

function AutoBuyRod:Init(gui)
    -- Store GUI controls reference
    guiControls = gui or {}
    
    -- Initialize ReplicatedStorage references with timeout
    local success1, items = pcall(function()
        return ReplicatedStorage:WaitForChild("Items", 5)
    end)
    
    local success2, remote = pcall(function()
        return ReplicatedStorage:WaitForChild("Packages", 5)
            :WaitForChild("_Index", 5)
            :WaitForChild("sleitnick_net@0.2.0", 5)
            :WaitForChild("net", 5)
            :WaitForChild("RF/PurchaseFishingRod", 5)
    end)
    
    if not success1 or not items then
        warn("[AutoBuyRod] Failed to find ReplicatedStorage.Items")
        return false
    end
    
    if not success2 or not remote then
        warn("[AutoBuyRod] Failed to find PurchaseFishingRod remote")
        return false
    end
    
    itemsFolder = items
    purchaseRodRemote = remote
    
    -- Pre-populate dropdown if GUI control exists
    if guiControls.rodsDropdown and guiControls.rodsDropdown.Reload then
        local rodOptions = {}
        local allRods = self:_scanAllRods()
        
        for _, rod in ipairs(allRods) do
            local displayText = string.format("%s (T%d - %d coins)", rod.name, rod.tier, rod.price)
            table.insert(rodOptions, rod.name) -- Simpan nama asli untuk logic
        end
        
        guiControls.rodsDropdown:Reload(rodOptions)
    end
    
    return true
end

function AutoBuyRod:Start(config)
    if not running then
        running = true
        
        -- Parse config jika ada
        if config then
            if config.rodList then
                self:SetSelectedRods(config.rodList)
            end
            if config.interDelay then
                INTER_PURCHASE_DELAY = math.max(0.1, config.interDelay)
            end
        end
    end
    
    -- Langsung lakukan pembelian (one-time) kemudian stop
    print("[AutoBuyRod] Starting purchase process...")
    local success = self:PurchaseSelectedRods()
    
    -- Stop setelah purchase
    self:Stop()
    return success
end

function AutoBuyRod:Stop()
    if not running then return end
    running = false
end

function AutoBuyRod:Cleanup()
    self:Stop()
    
    -- Reset state
    selectedRods = {}
    guiControls = {}
    lastPurchaseTime = 0
    
    -- Don't reset purchasedRods - ini harus persistent
end

-- ========== SETTERS & ACTIONS (Feature-Specific) ==========

-- Method tambahan untuk kompatibilitas GUI
function AutoBuyRod:SetSelectedRods(rodList)
    if not rodList then return false end
    
    selectedRods = {}
    
    -- Normalisasi input: terima array atau set/dict
    if type(rodList) == "table" then
        if #rodList > 0 then
            -- Array format dari dropdown multi
            for _, rodName in ipairs(rodList) do
                if type(rodName) == "string" and rodName ~= "" then
                    table.insert(selectedRods, rodName)
                end
            end
        else
            -- Set/dict format: {RodName = true, ...}
            for rodName, enabled in pairs(rodList) do
                if enabled and type(rodName) == "string" then
                    table.insert(selectedRods, rodName)
                end
            end
        end
    end
    
    print("[AutoBuyRod] Selected rods updated:", table.concat(selectedRods, ", "))
    return true
end

-- Alias method untuk konsistensi dengan GUI pattern
function AutoBuyRod:SetSelectedRodsByName(rodList)
    return self:SetSelectedRods(rodList)
end

-- Method untuk refresh catalog (dipanggil dari GUI)
function AutoBuyRod:RefreshCatalog()
    -- Tidak perlu implementasi khusus, data selalu fresh dari ReplicatedStorage
    return true
end

-- Method untuk mendapatkan catalog dalam format yang dibutuhkan GUI
function AutoBuyRod:GetCatalogRows()
    local rows = {}
    local allRods = self:_scanAllRods()
    
    for _, rod in ipairs(allRods) do
        table.insert(rows, {
            Name = rod.name,
            Id = rod.id,
            Price = rod.price,
            Tier = rod.tier
        })
    end
    
    return rows
end

-- Action untuk membeli semua rod yang dipilih (one-time purchase)
function AutoBuyRod:PurchaseSelectedRods()
    if not running then
        warn("[AutoBuyRod] Feature not started")
        return false
    end
    
    if #selectedRods == 0 then
        warn("[AutoBuyRod] No rods selected")
        return false
    end
    
    local currentTime = tick()
    if currentTime - lastPurchaseTime < INTER_PURCHASE_DELAY then
        warn("[AutoBuyRod] Purchase cooldown active")
        return false
    end
    
    local purchasedCount = 0
    local skippedCount = 0
    local errorCount = 0
    
    -- Scan semua rod untuk mendapatkan data
    local allRods = self:_scanAllRods()
    local rodDataMap = {}
    for _, rod in ipairs(allRods) do
        rodDataMap[rod.name] = rod
    end
    
    -- Proses pembelian untuk setiap rod yang dipilih
    for _, rodName in ipairs(selectedRods) do
        local rodData = rodDataMap[rodName]
        
        if not rodData then
            warn("[AutoBuyRod] Rod data not found: " .. rodName)
            errorCount = errorCount + 1
        elseif self:IsRodPurchased(rodData.id) then
            -- Skip jika sudah dibeli
            skippedCount = skippedCount + 1
        else
            -- Coba beli rod
            local success = self:_purchaseRod(rodData.id, rodData.name)
            if success then
                purchasedCount = purchasedCount + 1
                self:_markRodAsPurchased(rodData.id)
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
    local resultMsg = string.format("[AutoBuyRod] Purchase complete: %d bought, %d skipped, %d errors", 
        purchasedCount, skippedCount, errorCount)
    print(resultMsg)
    
    return purchasedCount > 0
end

-- Getter untuk cek apakah rod sudah dibeli
function AutoBuyRod:IsRodPurchased(rodId)
    return purchasedRods[rodId] == true
end

-- Getter untuk mendapatkan semua rod yang tersedia
function AutoBuyRod:GetAvailableRods()
    return self:_scanAllRods()
end

-- Reset tracking rod yang sudah dibeli (untuk testing)
function AutoBuyRod:ResetPurchaseHistory()
    purchasedRods = {}
    return true
end

-- ========== INTERNAL HELPER METHODS ==========

-- Scan semua rod dari ReplicatedStorage.Items (rekursif)
function AutoBuyRod:_scanAllRods()
    local rodsList = {}
    
    if not itemsFolder then
        return rodsList
    end
    
    -- Scan rekursif untuk semua ModuleScript di folder Items
    local function scanFolder(folder)
        for _, child in pairs(folder:GetChildren()) do
            if child:IsA("ModuleScript") then
                local success, itemData = pcall(require, child)
                if success and itemData and itemData.Data then
                    -- Filter: hanya "Fishing Rods" yang memiliki Price
                    if itemData.Data.Type == "Fishing Rods" and itemData.Price then
                        table.insert(rodsList, {
                            name = itemData.Data.Name or "Unknown",
                            id = itemData.Data.Id or 0,
                            price = itemData.Price or 0,
                            tier = itemData.Data.Tier or 1,
                            description = itemData.Data.Description or "",
                            clickPower = itemData.ClickPower or 0,
                            resilience = itemData.Resilience or 0,
                            maxWeight = itemData.MaxWeight or 0,
                            rollData = itemData.RollData or {},
                            module = child
                        })
                    end
                end
            elseif child:IsA("Folder") then
                scanFolder(child) -- Rekursif untuk subfolder
            end
        end
    end
    
    scanFolder(itemsFolder)
    
    -- Sort berdasarkan tier dan nama
    table.sort(rodsList, function(a, b)
        if a.tier == b.tier then
            return a.name < b.name
        end
        return a.tier < b.tier
    end)
    
    return rodsList
end

-- Internal purchase function dengan error handling
function AutoBuyRod:_purchaseRod(rodId, rodName)
    if not purchaseRodRemote then
        warn("[AutoBuyRod] Purchase remote not available")
        return false
    end
    
    local success, result = pcall(function()
        return purchaseRodRemote:InvokeServer(rodId)
    end)
    
    if success and result then
        print("[AutoBuyRod] Successfully purchased: " .. rodName .. " (ID: " .. rodId .. ")")
        return true
    else
        warn("[AutoBuyRod] Failed to purchase " .. rodName .. ": " .. tostring(result))
        return false
    end
end

-- Mark rod sebagai sudah dibeli
function AutoBuyRod:_markRodAsPurchased(rodId)
    purchasedRods[rodId] = true
end

return AutoBuyRod