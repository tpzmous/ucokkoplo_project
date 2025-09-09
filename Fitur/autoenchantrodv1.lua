--========================================================
-- autoenchantrodFeature.lua
--========================================================
-- Fitur:
--  - Filter Enchant Stones dari inventory (via InventoryWatcher)
--  - Equip ke Hotbar -> Equip tool dari slot -> Activate altar
--  - Listen RE/RollEnchant (OnClientEvent) -> baca Id -> cocokkan target
--  - Berhenti otomatis saat dapet target (atau toggle off / kehabisan stone)
--
-- Kebutuhan:
--  - InventoryWatcher (typed/akurat) -> di‑pass lewat options.watcher
--    atau set options.attemptAutoWatcher = true (coba require sendiri)
--  - ReplicatedStorage.Enchants (ModuleScripts berisi Data.Id & Data.Name)
--========================================================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = Players.LocalPlayer

-- ==== Remotes (pakai sleitnick_net) ====
local REMOTE_NAMES = {
    EquipItem               = "RE/EquipItem",
    EquipToolFromHotbar     = "RE/EquipToolFromHotbar",
    ActivateEnchantingAltar = "RE/ActivateEnchantingAltar",
    RollEnchant             = "RE/RollEnchant", -- inbound
}

-- ==== Util: cari folder net sleitnick ====
local function findNetRoot()
    local Packages = ReplicatedStorage:FindFirstChild("Packages")
    if not Packages then return end
    local _Index = Packages:FindFirstChild("_Index")
    if not _Index then return end
    for _, pkg in ipairs(_Index:GetChildren()) do
        if pkg:IsA("Folder") and pkg.Name:match("^sleitnick_net@") then
            local net = pkg:FindFirstChild("net")
            if net then return net end
        end
    end
end

local function getRemote(name)
    local net = findNetRoot()
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    -- fallback cari global
    return ReplicatedStorage:FindFirstChild(name, true)
end

-- ==== Map Enchants (Id <-> Name) ====
local function buildEnchantsIndex()
    local mapById, mapByName = {}, {}
    local enchFolder = ReplicatedStorage:FindFirstChild("Enchants")
    if enchFolder then
        for _, child in ipairs(enchFolder:GetChildren()) do
            if child:IsA("ModuleScript") then
                local ok, mod = pcall(require, child)
                if ok and type(mod) == "table" and mod.Data then
                    local id   = tonumber(mod.Data.Id)
                    local name = tostring(mod.Data.Name or child.Name)
                    if id then
                        mapById[id] = name
                        mapByName[name] = id
                    end
                end
            end
        end
    end
    return mapById, mapByName
end

-- ==== Deteksi "Enchant Stone" di inventory ====
-- Kita cari item di kategori "Items" (typed) yang datanya mengindikasikan EnchantStone
local function safeItemData(id)
    local ok, ItemUtility = pcall(function() return require(ReplicatedStorage.Shared.ItemUtility) end)
    if not ok or not ItemUtility then return nil end

    local d = nil
    -- coba resolusi paling akurat dulu
    if ItemUtility.GetItemDataFromItemType then
        local ok2, got = pcall(function() return ItemUtility:GetItemDataFromItemType("Items", id) end)
        if ok2 and got then d = got end
    end
    if not d and ItemUtility.GetItemData then
        local ok3, got = pcall(function() return ItemUtility:GetItemData(id) end)
        if ok3 and got then d = got end
    end
    return d and d.Data
end

local function isEnchantStoneEntry(entry)
    if type(entry) ~= "table" then return false end
    local id    = entry.Id or entry.id
    local name  = nil
    local dtype = nil

    local data = safeItemData(id)
    if data then
        dtype = tostring(data.Type or data.Category or "")
        name  = tostring(data.Name or "")
    end

    -- heuristik aman:
    -- - type "EnchantStones" / "Enchant Stone(s)"
    -- - atau namanya mengandung "Enchant Stone"
    if dtype and dtype:lower():find("enchant") and dtype:lower():find("stone") then
        return true
    end
    if name and name:lower():find("enchant") and name:lower():find("stone") then
        return true
    end

    -- fallback: cek tag khusus pada entry (kalau server isi)
    if entry.Metadata and entry.Metadata.IsEnchantStone then
        return true
    end

    return false
end

-- ==== Feature Class ====
local Auto = {}
Auto.__index = Auto

function Auto.new(opts)
    opts = opts or {}

    -- InventoryWatcher
    local watcher = opts.watcher
    if not watcher and opts.attemptAutoWatcher then
        -- coba ambil dari global / require loader kamu
        local ok, Mod = pcall(function()
            -- sesuaikan path kalau kamu punya file lokalnya
            return loadstring(game:HttpGet("https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/debug-script/inventdetectfishit.lua"))()
        end)
        if ok and Mod then
            local w = Mod.new()
            watcher = w
        end
    end

    local self = setmetatable({
        _watcher       = watcher,       -- disarankan inject watcher kamu
        _enabled       = false,
        _running       = false,
        _slot          = tonumber(opts.hotbarSlot or 3), -- default 3 (2..5 biasanya aman)
        _delay         = tonumber(opts.rollDelay or 0.35),
        _timeout       = tonumber(opts.rollResultTimeout or 6.0),
        _targetsById   = {},            -- set[int] = true
        _targetsByName = {},            -- set[name] = true (display)
        _mapId2Name    = {},
        _mapName2Id    = {},
        _evRoll        = Instance.new("BindableEvent"), -- signal untuk hasil roll (Id)
        _conRoll       = nil,
    }, Auto)

    -- Enchant index
    self._mapId2Name, self._mapName2Id = buildEnchantsIndex()

    -- listen inbound RE/RollEnchant
    self:_attachRollListener()

    return self
end

-- ---- Public API ----

function Auto:setTargetsByNames(namesTbl)
    self._targetsById = {}
    self._targetsByName = {}
    for _, name in ipairs(namesTbl or {}) do
        local id = self._mapName2Id[name]
        if id then
            self._targetsById[id] = true
            self._targetsByName[name] = true
        else
            warn("[autoenchantrod] unknown enchant name:", name)
        end
    end
end

function Auto:setTargetsByIds(idsTbl)
    self._targetsById = {}
    self._targetsByName = {}
    for _, id in ipairs(idsTbl or {}) do
        id = tonumber(id)
        if id then
            self._targetsById[id] = true
            local nm = self._mapId2Name[id]
            if nm then self._targetsByName[nm] = true end
        end
    end
end

function Auto:setHotbarSlot(n)
    n = tonumber(n)
    if n and n >= 2 and n <= 5 then
        self._slot = n
    else
        warn("[autoenchantrod] invalid slot, keep:", self._slot)
    end
end

function Auto:isEnabled() return self._enabled end

function Auto:start()
    if self._enabled then return end
    self._enabled = true
    task.spawn(function() self:_runLoop() end)
end

function Auto:stop()
    self._enabled = false
end

function Auto:destroy()
    self._enabled = false
    if self._conRoll then
        self._conRoll:Disconnect()
        self._conRoll = nil
    end
    if self._evRoll then
        self._evRoll:Destroy()
        self._evRoll = nil
    end
end

-- ---- Internals ----

function Auto:_attachRollListener()
    if self._conRoll then self._conRoll:Disconnect() end
    local re = getRemote(REMOTE_NAMES.RollEnchant)
    if not re or not re:IsA("RemoteEvent") then
        warn("[autoenchantrod] RollEnchant remote not found (will retry when run)")
        return
    end
    self._conRoll = re.OnClientEvent:Connect(function(...)
        -- Arg #2 = Id enchant (sesuai file listener kamu)
        local args = table.pack(...)
        local id = tonumber(args[2]) -- hati‑hati: beberapa game pakai #1, disesuaikan kalau perlu
        if id then
            self._evRoll:Fire(id)
        end
    end)
end

function Auto:_waitRollId(timeoutSec)
    timeoutSec = timeoutSec or self._timeout
    local gotId = nil
    local done = false
    local conn
    conn = self._evRoll.Event:Connect(function(id)
        gotId = id
        done = true
        if conn then conn:Disconnect() end
    end)
    local t0 = os.clock()
    while not done do
        task.wait(0.05)
        if os.clock() - t0 > timeoutSec then
            if conn then conn:Disconnect() end
            break
        end
    end
    return gotId
end

function Auto:_findOneEnchantStoneUuid()
    if not self._watcher then return nil end
    -- pakai typed snapshot agar robust (Items typed)
    local items = nil
    if self._watcher.getSnapshotTyped then
        items = self._watcher:getSnapshotTyped("Items")
    else
        items = self._watcher:getSnapshot("Items")
    end
    for _, entry in ipairs(items or {}) do
        if isEnchantStoneEntry(entry) then
            local uuid = entry.UUID or entry.Uuid or entry.uuid
            if uuid then return uuid end
        end
    end
    return nil
end

function Auto:_equipStoneToHotbar(uuid)
    local reEquipItem = getRemote(REMOTE_NAMES.EquipItem)
    if not reEquipItem then
        warn("[autoenchantrod] EquipItem remote not found"); return false
    end
    local ok = pcall(function()
        reEquipItem:FireServer(uuid, "EnchantStones")
    end)
    if not ok then
        warn("[autoenchantrod] EquipItem FireServer failed"); return false
    end
    task.wait(0.15)
    return true
end

function Auto:_equipFromHotbar(slot)
    local reEquipHotbar = getRemote(REMOTE_NAMES.EquipToolFromHotbar)
    if not reEquipHotbar then
        warn("[autoenchantrod] EquipToolFromHotbar remote not found"); return false
    end
    local ok = pcall(function()
        reEquipHotbar:FireServer(slot)
    end)
    if not ok then
        warn("[autoenchantrod] EquipToolFromHotbar failed"); return false
    end
    task.wait(0.1)
    return true
end

function Auto:_activateAltar()
    local reActivate = getRemote(REMOTE_NAMES.ActivateEnchantingAltar)
    if not reActivate then
        warn("[autoenchantrod] ActivateEnchantingAltar remote not found"); return false
    end
    local ok = pcall(function()
        reActivate:FireServer()
    end)
    if not ok then
        warn("[autoenchantrod] ActivateEnchantingAltar failed"); return false
    end
    return true
end

function Auto:_logStatus(msg)
    print(("[autoenchantrod] %s"):format(msg))
end

function Auto:_runOnce()
    -- 1) ambil satu Enchant Stone
    local uuid = self._findOneEnchantStoneUuid and self:_findOneEnchantStoneUuid() or nil
    if not uuid then
        self:_logStatus("no Enchant Stone found in inventory.")
        return false, "no_stone"
    end

    -- 2) taro ke hotbar (equip item)
    if not self:_equipStoneToHotbar(uuid) then
        return false, "equip_item_failed"
    end

    -- 3) pilih dari hotbar
    if not self:_equipFromHotbar(self._slot) then
        return false, "equip_hotbar_failed"
    end

    -- 4) aktifkan altar
    if not self:_activateAltar() then
        return false, "altar_failed"
    end

    -- 5) tunggu hasil RollEnchant (Id)
    local id = self:_waitRollId(self._timeout)
    if not id then
        self:_logStatus("no roll result (timeout)")
        return false, "timeout"
    end
    local name = self._mapId2Name[id] or ("Id "..tostring(id))
    self:_logStatus(("rolled: %s (Id=%d)"):format(name, id))

    -- 6) cocokkan target
    if self._targetsById[id] then
        self:_logStatus(("MATCH target: %s — stopping."):format(name))
        return true, "matched"
    end
    return false, "not_matched"
end

function Auto:_runLoop()
    if self._running then return end
    self._running = true

    -- pastikan listener terpasang
    self:_attachRollListener()

    while self._enabled do
        -- safety: cek target
        local hasTarget = false
        for _ in pairs(self._targetsById) do hasTarget = true break end
        if not hasTarget then
            self:_logStatus("no targets set — idle. Call setTargetsByNames/Ids first.")
            break
        end

        -- safety: cek watcher ready
        if self._watcher and self._watcher.onReady then
            -- tunggu sekali saja di awal
            local ready = true
            if not self._watcher._ready then
                ready = false
                local done = false
                local conn = self._watcher:onReady(function() done = true end)
                local t0 = os.clock()
                while not done and self._enabled do
                    task.wait(0.05)
                    if os.clock()-t0 > 5 then break end
                end
                if conn and conn.Disconnect then conn:Disconnect() end
                ready = done
            end
            if not ready then
                self:_logStatus("watcher not ready — abort")
                break
            end
        end

        local ok, reason = self:_runOnce()
        if ok then
            -- ketemu target => stop otomatis
            self._enabled = false
            break
        else
            if reason == "no_stone" then
                self:_logStatus("stop: habis Enchant Stone.")
                self._enabled = false
                break
            end
            -- retry kecil
            task.wait(self._delay)
        end
    end

    self._running = false
end

-- ==== Feature wrapper ====
-- The original script exported only Auto.new, which is insufficient for our UI.
-- Here we provide a wrapper implementing Init, Start, Stop and other methods expected by fishit.lua.

local AutoEnchantRodFeature = {}
AutoEnchantRodFeature.__index = AutoEnchantRodFeature

-- Initialize the feature. Accepts optional controls table (unused here).
function AutoEnchantRodFeature:Init(controls)
    -- Attempt to use an injected watcher from controls (if provided)
    local watcher = nil
    if controls and controls.watcher then
        watcher = controls.watcher
    end
    -- Create underlying Auto instance.
    -- If no watcher is provided we allow Auto to auto create one via attemptAutoWatcher = true.
    self._auto = Auto.new({
        watcher = watcher,
        attemptAutoWatcher = watcher == nil
    })
    return true
end

-- Return a list of all available enchant names.
function AutoEnchantRodFeature:GetEnchantNames()
    local names = {}
    if not self._auto then return names end
    for name, _ in pairs(self._auto._mapName2Id) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- Set desired enchant targets by their names.
function AutoEnchantRodFeature:SetDesiredByNames(names)
    if self._auto then
        self._auto:setTargetsByNames(names)
    end
end

-- Alternate setter: set desired enchant targets by their ids.
function AutoEnchantRodFeature:SetDesiredByIds(ids)
    if self._auto then
        self._auto:setTargetsByIds(ids)
    end
end

-- Start auto enchant logic using provided config.
-- config.delay        -> number: delay between rolls
-- config.enchantNames -> table of enchant names to target
-- config.hotbarSlot   -> optional slot override
function AutoEnchantRodFeature:Start(config)
    if not self._auto then return end
    config = config or {}
    -- update delay if provided
    if config.delay then
        local d = tonumber(config.delay)
        if d then
            self._auto._delay = d
        end
    end
    -- set targets by names
    if config.enchantNames then
        self:SetDesiredByNames(config.enchantNames)
    end
    -- optional slot override
    if config.hotbarSlot then
        self._auto:setHotbarSlot(config.hotbarSlot)
    end
    -- start the automation
    self._auto:start()
end

-- Stop the automation gracefully.
function AutoEnchantRodFeature:Stop()
    if self._auto then
        self._auto:stop()
    end
end

-- Cleanup resources and destroy the underlying Auto instance.
function AutoEnchantRodFeature:Cleanup()
    if self._auto then
        self._auto:destroy()
        self._auto = nil
    end
end

-- Return the feature table with methods available via colon syntax.
return setmetatable(AutoEnchantRodFeature, AutoEnchantRodFeature)