-- Feature: AutoGearOxyRadar
-- Purpose: Toggle Oxygen Tank/Diving Gear & Fish Radar via RF InvokeServer
-- Contract: Init/Start/Stop/Cleanup; idempotent; pcall; throttle; no UI here.

local Feature = {}
Feature.__index = Feature

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

--// ====== Config (default) ======
local cfg = {
  -- oxygen id discovery:
  resolveOxygenFromItems = true,         -- scan ReplicatedStorage.Items for Type=="Gears"
  preferredNameRegex     = "[Oo]xygen|[Dd]iving", -- name hint
  fallbackOxygenId       = 105,          -- fallback kalau gagal resolve
  minInvokeInterval      = 0.75,         -- anti-spam per RF
}

--// ====== State ======
local running = false
local hbConn  = nil
local lastInvoke = {}  -- map rfName -> time
local netFolder = nil
local RF = {
  EquipOxygen = nil,     -- "RF/EquipOxygenTank" (RemoteFunction)
  UnequipOxy  = nil,     -- "RF/UnequipOxygenTank" (RemoteFunction)
  RadarToggle = nil,     -- "RF/UpdateFishingRadar" (RemoteFunction)
}
local oxygenId = nil
local oxygenOn = false
local radarOn  = false
local genToken = 0       -- cancel token

--// ====== Utils ======

local function now() return os.clock() end

local function readyToInvoke(key)
  local t = now()
  if not lastInvoke[key] or (t - lastInvoke[key]) >= cfg.minInvokeInterval then
    lastInvoke[key] = t
    return true
  end
  return false
end

-- cari folder "net" yang punya anak "RF/EquipOxygenTank" dkk.
local function findNetFolder()
  -- Prioritas: _Index/* yang namanya mengandung sleitnick_net@*
  local packages = ReplicatedStorage:FindFirstChild("Packages")
  local index = packages and packages:FindFirstChild("_Index")
  if index then
    for _, child in ipairs(index:GetChildren()) do
      if child:IsA("Folder") and string.find(child.Name, "sleitnick_net@", 1, true) then
        local nf = child:FindFirstChild("net")
        if nf and nf:FindFirstChild("RF/UpdateFishingRadar") then
          return nf
        end
      end
    end
    -- kalau tidak ketemu via nama, ambil folder 'net' pertama yang punya RF kita
    for _, child in ipairs(index:GetChildren()) do
      if child:IsA("Folder") then
        local nf = child:FindFirstChild("net")
        if nf and nf:FindFirstChild("RF/UpdateFishingRadar") then
          return nf
        end
      end
    end
  end
  -- Fallback: cari global
  for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
    if d:IsA("Folder") and d.Name == "net" then
      if d:FindFirstChild("RF/UpdateFishingRadar") or d:FindFirstChild("RF/EquipOxygenTank") then
        return d
      end
    end
  end
  return nil
end

local function ensureRF()
  if netFolder then return true end
  netFolder = findNetFolder()
  if not netFolder then return false end

  RF.EquipOxygen = netFolder:FindFirstChild("RF/EquipOxygenTank")
  RF.UnequipOxy  = netFolder:FindFirstChild("RF/UnequipOxygenTank")
  RF.RadarToggle = netFolder:FindFirstChild("RF/UpdateFishingRadar")
  return RF.EquipOxygen and RF.UnequipOxy and RF.RadarToggle
end

-- Scan ReplicatedStorage.Items.* ModuleScript -> require -> table { Id=XX, Type="Gears" }
local function resolveOxygenId()
  if not cfg.resolveOxygenFromItems then
    return cfg.fallbackOxygenId
  end
  local items = ReplicatedStorage:FindFirstChild("Items")
  if not items then return cfg.fallbackOxygenId end

  local candidates = {}
  for _, m in ipairs(items:GetChildren()) do
    if m:IsA("ModuleScript") then
      local ok, data = pcall(require, m)
      if ok and type(data) == "table" and data.Id and data.Type == "Gears" then
        if string.find(m.Name, cfg.preferredNameRegex) then
          table.insert(candidates, {name=m.Name, id=data.Id})
        end
      end
    end
  end
  -- pilih kandidat pertama (bisa diubah ke heuristik lain: nama terpanjang, id terbesar, dll.)
  if #candidates > 0 then
    return candidates[1].id
  end
  return cfg.fallbackOxygenId
end

--// ====== Core Invokes (pcall + throttle) ======
local function invokeEquipOxygen(id)
  if not ensureRF() then
    warn("[AutoGear] net RF not found")
    return false
  end
  if not readyToInvoke("EquipOxy") then return false end
  local ok, res = pcall(function()
    return RF.EquipOxygen:InvokeServer(id)
  end)
  if not ok then
    warn("[AutoGear] EquipOxygen error: ", res)
    return false
  end
  return true
end

local function invokeUnequipOxygen()
  if not ensureRF() then
    warn("[AutoGear] net RF not found")
    return false
  end
  if not readyToInvoke("UnequipOxy") then return false end
  local ok, res = pcall(function()
    return RF.UnequipOxy:InvokeServer()
  end)
  if not ok then
    warn("[AutoGear] UnequipOxygen error: ", res)
    return false
  end
  return true
end

local function invokeRadar(stateBool)
  if not ensureRF() then
    warn("[AutoGear] net RF not found")
    return false
  end
  if not readyToInvoke("Radar") then return false end
  local ok, res = pcall(function()
    return RF.RadarToggle:InvokeServer(stateBool)
  end)
  if not ok then
    warn("[AutoGear] UpdateFishingRadar error: ", res)
    return false
  end
  return true
end

--// ====== Lifecycle ======
function Feature:Init(_gui)
  ensureRF()
  oxygenId = resolveOxygenId()
  return true
end

-- Start bisa diberi config:
-- {
--   oxygenId = 105,             -- override, kalau mau fix
--   resolveOxygenFromItems = true/false,
--   preferredNameRegex = "O2|Diving",
--   minInvokeInterval = 0.75,
--   oxygenOn = false, radarOn = false, -- initial states (optional)
-- }
function Feature:Start(config)
  if running then return end
  running = true
  genToken = genToken + 1
  -- apply cfg override
  if type(config) == "table" then
    if type(config.oxygenId) == "number" then oxygenId = config.oxygenId end
    if type(config.resolveOxygenFromItems) == "boolean" then cfg.resolveOxygenFromItems = config.resolveOxygenFromItems end
    if type(config.preferredNameRegex) == "string" then cfg.preferredNameRegex = config.preferredNameRegex end
    if type(config.minInvokeInterval) == "number" then cfg.minInvokeInterval = math.max(0.1, config.minInvokeInterval) end
    if type(config.oxygenOn) == "boolean" then self:EnableOxygen(config.oxygenOn) end
    if type(config.radarOn)  == "boolean" then self:EnableRadar(config.radarOn) end
  end

  -- Tidak perlu Heartbeat untuk mode toggle sederhana; 
  -- kita keep hbConn = nil supaya lightweight dan patuh spec.
end

function Feature:Stop()
  if not running then return end
  running = false
  genToken = genToken + 1
  if hbConn then hbConn:Disconnect(); hbConn = nil end
end

function Feature:Cleanup()
  self:Stop()
  lastInvoke = {}
  -- jangan reset oxygenOn/radarOn agar idempotent vs GUI (state tetap dikenal)
end

--// ====== Public API for GUI Toggles ======

-- true -> Equip (by id); false -> Unequip
function Feature:EnableOxygen(state)
  if state == oxygenOn then return true end
  if state then
    if not oxygenId then oxygenId = resolveOxygenId() end
    local ok = invokeEquipOxygen(oxygenId)
    if ok then oxygenOn = true end
    return ok
  else
    local ok = invokeUnequipOxygen()
    if ok then oxygenOn = false end
    return ok
  end
end

-- true -> Radar ON; false -> Radar OFF
function Feature:EnableRadar(state)
  if state == radarOn then return true end
  local ok = invokeRadar(state)
  if ok then radarOn = state end
  return ok
end

-- optional helper kalau kamu mau ganti oxygen id runtime
function Feature:SetOxygenId(id)
  if type(id) == "number" then
    oxygenId = id
    return true
  end
  return false
end

return Feature
