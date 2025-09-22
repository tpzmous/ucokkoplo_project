--========================================================
-- AutoTeleportEvent (Final Version)
--========================================================
-- Fitur:
--  - Deteksi event aktif di Workspace Props
--  - Validasi dengan ReplicatedStorage.Events
--  - Teleport player ke event terdekat/prioritas
--  - Hover mode agar tidak jatuh ke air
--  - Bisa restore ke posisi awal
--  - Full cleanup saat Stop()
--========================================================

--========================================================
-- Services
--========================================================
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local Workspace          = game:GetService("Workspace")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

--========================================================
-- Variables
--========================================================
local LocalPlayer        = Players.LocalPlayer
local hbConn             = nil
local propsAddedConn     = nil
local propsRemovedConn   = nil
local workspaceConn      = nil
local charConn           = nil

local eventsFolder       = nil
local validEventName     = {}
local savedPosition      = nil
local currentTarget      = nil
local lastKnownActiveProps = {}
local running            = false

local selectedPriorityList = {}
local selectedSet          = {}

local hoverHeight = 25

--========================================================
-- Utils
--========================================================
local function normName(s)
    s = string.lower(s or "")
    s = s:gsub("%W", "")
    return s
end

local function waitChild(parent, name)
    local c = parent:FindFirstChild(name)
    while not c do
        parent.ChildAdded:Wait()
        c = parent:FindFirstChild(name)
    end
    return c
end

local function ensureCharacter()
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local hrp  = char:WaitForChild("HumanoidRootPart")
    return char, hrp
end

local function setCFrameSafely(part, pos, lookAt)
    if not part then return end
    local cf = CFrame.new(pos, lookAt)
    part.CFrame = cf
end

local function ensureHoverBP(hrp)
    local existing = hrp:FindFirstChild("AutoHoverBV")
    if existing then return existing end
    local bv = Instance.new("BodyVelocity")
    bv.Name = "AutoHoverBV"
    bv.MaxForce = Vector3.new(4000,4000,4000)
    bv.P = 10000
    bv.Velocity = Vector3.new(0,0,0)
    bv.Parent = hrp
    return bv
end

local function removeHoverBP(hrp)
    local bv = hrp:FindFirstChild("AutoHoverBV")
    if bv then bv:Destroy() end
end

local function findBestWaterPosition(basePos)
    -- dummy fallback, bisa dibuat lebih pintar (raycast cek water)
    return basePos + Vector3.new(0, hoverHeight, 0)
end

local function saveCurrentPosition()
    local _, hrp = ensureCharacter()
    if hrp then
        savedPosition = hrp.CFrame
        print("[AutoTeleportEvent] Saved position:", tostring(savedPosition.Position))
    end
end

local function restoreToSavedPosition()
    if not savedPosition then
        warn("[AutoTeleportEvent] No saved position → skip restore")
        return
    end
    local _, hrp = ensureCharacter()
    if hrp then
        removeHoverBP(hrp)
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        hrp.AssemblyLinearVelocity = Vector3.new()
        hrp.AssemblyAngularVelocity = Vector3.new()
        print("[AutoTeleportEvent] Restored to saved position:", tostring(savedPosition.Position))
    end
end

--========================================================
-- Event Validation
--========================================================
local function buildValidEventNames()
    local eventsFolder = ReplicatedStorage:FindFirstChild("Events")
    if not eventsFolder then
        warn("[AutoTeleportEvent] Tidak ada folder 'Events' di ReplicatedStorage")
        return {}
    end

    local valid = {}

    local function scan(folder)
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("ModuleScript") then
                local ok, data = pcall(require, child)
                local name = nil
                if ok and data and data.Name then
                    name = data.Name
                else
                    name = child.Name
                end
                valid[normName(name)] = true
            elseif child:IsA("Folder") then
                scan(child)
            end
        end
    end

    scan(eventsFolder)
    return valid
end

local function resolveModelPivotPos(model)
    local ok, cf = pcall(function() return model:GetPivot() end)
    if ok and typeof(cf) == "CFrame" then return cf.Position end
    local ok2, cf2 = pcall(function() return model.WorldPivot end)
    if ok2 and typeof(cf2) == "CFrame" then return cf2.Position end
    return nil
end

local function resolveEventNameFromModel(model)
    if not model or not model.Name then return "Unknown" end
    local name = model.Name
    local sv = model:FindFirstChild("EventName")
    if sv and sv:IsA("StringValue") and sv.Value ~= "" then
        name = sv.Value
    elseif model:GetAttribute("EventName") then
        name = model:GetAttribute("EventName")
    end
    return name
end

--========================================================
-- Active Props Scanner
--========================================================
local function scanAllActiveProps()
    local activePropsList = {}
    validEventName = buildValidEventNames()

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
                                print(string.format("[AutoTeleportEvent] Event VALID: %s @ (%.1f, %.1f, %.1f)", eventName, pos.X, pos.Y, pos.Z))
                            else
                                warn(string.format("[AutoTeleportEvent] Event '%s' di Props tidak cocok daftar resmi", eventName))
                            end
                        end
                    end
                end
            end
        end
    end

    return activePropsList
end

--========================================================
-- Target Selection
--========================================================
local function chooseBestActiveEvent()
    local active = scanAllActiveProps()
    lastKnownActiveProps = active

    if #active == 0 then return nil end

    if #selectedPriorityList > 0 then
        for _, prio in ipairs(selectedPriorityList) do
            for _, evt in ipairs(active) do
                if evt.nameKey == prio then
                    return evt
                end
            end
        end
    end

    return active[1]
end

--========================================================
-- Teleport
--========================================================
local function teleportToTarget(evt)
    if not evt then return end
    local _, hrp = ensureCharacter()
    if not hrp then return end

    saveCurrentPosition()
    local targetPos = findBestWaterPosition(evt.pos)
    setCFrameSafely(hrp, targetPos, targetPos + Vector3.new(0,0,-1))
    ensureHoverBP(hrp)
    print("[AutoTeleportEvent] Teleported to:", evt.name, targetPos)
end

--========================================================
-- Main Loop
--========================================================
local function startLoop()
    if hbConn then hbConn:Disconnect() end
    hbConn = RunService.Heartbeat:Connect(function()
        if not running then return end
        local _, hrp = ensureCharacter()
        if hrp then ensureHoverBP(hrp) end
        local best = chooseBestActiveEvent()
        if best and (not currentTarget or currentTarget.nameKey ~= best.nameKey) then
            teleportToTarget(best)
            currentTarget = best
        end
    end)
end

--========================================================
-- API
--========================================================
local AutoTeleportEvent = {}
AutoTeleportEvent.__index = AutoTeleportEvent

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

    currentTarget = nil
    savedPosition = nil
    table.clear(lastKnownActiveProps)

    -- ✅ langsung simpan posisi awal
    saveCurrentPosition()

    print("[AutoTeleportEvent] Starting with events:", table.concat(selectedPriorityList, ", "))

    local best = chooseBestActiveEvent()
    if best then
        teleportToTarget(best)
        currentTarget = best
    else
        print("[AutoTeleportEvent] No valid events found")
    end

    startLoop()
    return true
end

function AutoTeleportEvent:Stop()
    if not running then return end
    running = false
    if hbConn then hbConn:Disconnect() hbConn = nil end
    if propsAddedConn then propsAddedConn:Disconnect() propsAddedConn = nil end
    if propsRemovedConn then propsRemovedConn:Disconnect() propsRemovedConn = nil end
    if workspaceConn then workspaceConn:Disconnect() workspaceConn = nil end
    if charConn then charConn:Disconnect() charConn = nil end
    restoreToSavedPosition()
    print("[AutoTeleportEvent] Stopped")
end

function AutoTeleportEvent:SetSelectedEvents(names)
    local list = {}
    local set  = {}
    if type(names) == "table" then
        for _, n in ipairs(names) do
            local key = normName(n)
            if key ~= "" then
                table.insert(list, key)
                set[key] = true
            end
        end
    elseif type(names) == "string" then
        local key = normName(names)
        if key ~= "" then
            table.insert(list, key)
            set[key] = true
        end
    end
    selectedPriorityList = list
    selectedSet          = set
    print("[AutoTeleportEvent] Selected events set to:", table.concat(selectedPriorityList, ", "))
end

function AutoTeleportEvent:Cleanup()
    self:Stop()
    eventsFolder = nil
    currentTarget = nil
    validEventName = {}
    savedPosition = nil
    table.clear(selectedPriorityList)
    table.clear(selectedSet)
    table.clear(lastKnownActiveProps)
    print("[AutoTeleportEvent] Cleanup done")
end

--========================================================
-- Export
--========================================================
return AutoTeleportEvent
