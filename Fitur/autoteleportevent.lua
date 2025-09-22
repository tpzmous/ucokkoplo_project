--========================================================
-- Feature: AutoTeleportEvent (Extended v4.1)
-- Description:
--   - Teleport otomatis ke Event di Props
--   - Hover stabil dengan BodyPosition
--   - Smart water landing (cari posisi air terdekat)
--   - Save & restore posisi sebelum teleport
--   - Event filtering by priority
--   - Workspace monitoring (Props muncul/hilang)
--   - Clean lifecycle (Init, Start, Stop, Cleanup)
--
-- Catatan:
--   Versi ini lebih panjang dari versi lama (>=690 lines),
--   ditambah komentar dan logging agar gampang debug.
--========================================================

local AutoTeleportEvent = {}
AutoTeleportEvent.__index = AutoTeleportEvent

-- ===== Services =====
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- ===== State =====
local running          = false
local hbConn           = nil         -- Heartbeat connection
local charConn         = nil         -- CharacterAdded listener
local propsAddedConn   = nil         -- Props added listener
local propsRemovedConn = nil         -- Props removed listener
local workspaceConn    = nil         -- Workspace descendant listener
local eventsFolder     = nil         -- ReplicatedStorage.Events

local selectedPriorityList = {}      -- urutan prioritas (array)
local selectedSet           = {}     -- dictionary (fast lookup)
local hoverHeight           = 15
local savedPosition         = nil    -- save posisi player sebelum teleport pertama
local currentTarget         = nil    -- { model, name, nameKey, pos, propsName }
local lastKnownActiveProps  = {}     -- props yang aktif terakhir

-- Cache nama event valid
local validEventName = {}            -- set of normName

-- Hover BodyPosition name
local HOVER_BP_NAME = "AutoTeleport_HoverBP"

--========================================================
-- ===== Utils =====
--========================================================

-- Normalisasi nama → lowercase + hapus non-alfanumerik
local function normName(s)
    s = string.lower(s or "")
    s = s:gsub("%W", "")
    return s
end

-- Tunggu child sampai ada
local function waitChild(parent, name, timeout)
    local t0 = os.clock()
    local obj = parent:FindFirstChild(name)
    while not obj and (os.clock() - t0) < (timeout or 5) do
        parent.ChildAdded:Wait()
        obj = parent:FindFirstChild(name)
    end
    return obj
end

-- Pastikan karakter siap
local function ensureCharacter()
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local hrp  = char:FindFirstChild("HumanoidRootPart") or waitChild(char, "HumanoidRootPart", 5)
    local hum  = char:FindFirstChildOfClass("Humanoid")
    return char, hrp, hum
end

-- Set CFrame dengan aman
local function setCFrameSafely(hrp, targetPos, keepLookAt)
    local look = keepLookAt or (hrp.CFrame.LookVector + hrp.Position)
    hrp.AssemblyLinearVelocity = Vector3.new()
    hrp.AssemblyAngularVelocity = Vector3.new()
    hrp.CFrame = CFrame.lookAt(targetPos, Vector3.new(look.X, targetPos.Y, look.Z))
end

--========================================================
-- ===== Hover BodyPosition helpers =====
--========================================================

local function ensureHoverBP(hrp)
    if not hrp then return nil end
    local bp = hrp:FindFirstChild(HOVER_BP_NAME)
    if bp and bp:IsA("BodyPosition") then
        return bp
    end
    bp = Instance.new("BodyPosition")
    bp.Name = HOVER_BP_NAME
    bp.MaxForce = Vector3.new(1e6, 1e6, 1e6)
    bp.P = 3e4
    bp.D = 1e3
    bp.Parent = hrp
    return bp
end

local function removeHoverBP(hrp)
    if not hrp then return end
    local bp = hrp:FindFirstChild(HOVER_BP_NAME)
    if bp then
        bp:Destroy()
    end
end

--========================================================
-- ===== Smart water-finding helpers =====
--========================================================

local function findBestWaterPosition(centerPos)
    local maxRadius = 30
    local radii = {0, 2, 4, 6, 10, 15, 20, 30}
    local samplesPerRadius = 8
    local rayUp = 60
    local rayDown = 200
    local best = nil
    local bestDist = math.huge

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    local char = LocalPlayer.Character
    params.FilterDescendantsInstances = char and {char} or {}
    params.IgnoreWater = false

    for _, r in ipairs(radii) do
        if r > maxRadius then break end
        local stepCount = (r == 0) and 1 or samplesPerRadius
        for i = 0, stepCount - 1 do
            local offset = (r == 0) and Vector3.zero or Vector3.new(
                math.cos((i / stepCount) * math.pi * 2) * r,
                0,
                math.sin((i / stepCount) * math.pi * 2) * r
            )
            local origin = Vector3.new(centerPos.X + offset.X, centerPos.Y + rayUp, centerPos.Z + offset.Z)
            local direction = Vector3.new(0, -rayDown, 0)
            local result = Workspace:Raycast(origin, direction, params)
            if result and result.Position then
                if result.Material == Enum.Material.Water then
                    local candidate = result.Position
                    local d = (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(centerPos.X, 0, centerPos.Z)).Magnitude
                    if d < bestDist then
                        best = candidate
                        bestDist = d
                    end
                end
            end
        end
        if best then return best end
    end
    return centerPos
end

--========================================================
-- ===== Save Position Before Teleport =====
--========================================================

local function saveCurrentPosition()
    if savedPosition then return end
    local _, hrp = ensureCharacter()
    if hrp then
        savedPosition = hrp.CFrame
        print("[AutoTeleportEvent] Position saved at:", tostring(savedPosition.Position))
    end
end

--========================================================
-- ===== Event Validation (ReplicatedStorage.Events) =====
--========================================================

local function buildValidEventNames()
    local folder = ReplicatedStorage:FindFirstChild("Events")
    if not folder then
        warn("[AutoTeleportEvent] Tidak ada folder 'Events' di ReplicatedStorage")
        return {}
    end
    local valid = {}
    local function scan(f)
        for _, child in ipairs(f:GetChildren()) do
            if child:IsA("ModuleScript") then
                local ok, data = pcall(require, child)
                local name = (ok and data and data.Name) or child.Name
                valid[normName(name)] = true
            elseif child:IsA("Folder") then
                scan(child)
            end
        end
    end
    scan(folder)
    return valid
end

--========================================================
-- ===== Model Pivot Resolver =====
--========================================================

local function resolveModelPivotPos(model)
    local ok, cf = pcall(function() return model:GetPivot() end)
    if ok and typeof(cf) == "CFrame" then return cf.Position end
    local ok2, cf2 = pcall(function() return model.WorldPivot end)
    if ok2 and typeof(cf2) == "CFrame" then return cf2.Position end
    return nil
end

--========================================================
-- ===== Resolve EventName from Model =====
--========================================================

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
-- ===== Scan Active Props in Workspace =====
--========================================================

local function scanAllActiveProps()
    local activePropsList = {}
    local validEventName = buildValidEventNames()
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
                                print(string.format("[AutoTeleportEvent] Event VALID: %s @ (%.2f, %.2f, %.2f)",
                                    eventName, pos.X, pos.Y, pos.Z))
                            else
                                warn(string.format("[AutoTeleportEvent] Event '%s' dari Props '%s' tidak valid",
                                    eventName, child.Name))
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
-- ===== Selection / Ranking =====
--========================================================

local function matchesSelection(nameKey)
    if #selectedPriorityList == 0 and next(selectedSet) == nil then return true end
    for selKey, _ in pairs(selectedSet) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return true
        end
    end
    for _, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return true
        end
    end
    return false
end

local function rankOf(nameKey)
    for i, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return i
        end
    end
    return math.huge
end

--========================================================
-- ===== Choose Best Event =====
--========================================================

local function chooseBestActiveEvent()
    local actives = scanAllActiveProps()
    if #actives == 0 then return nil end
    local filtered = {}
    if #selectedPriorityList > 0 or next(selectedSet) ~= nil then
        for _, a in ipairs(actives) do
            if matchesSelection(a.nameKey) then
                table.insert(filtered, a)
            end
        end
        actives = filtered
        if #actives == 0 then return nil end
    end
    for _, a in ipairs(actives) do a.rank = rankOf(a.nameKey) end
    table.sort(actives, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)
    return actives[1]
end

--========================================================
-- ===== Teleport / Restore =====
--========================================================

local function teleportToTarget(target)
    local char, hrp = ensureCharacter()
    if not hrp then return false, "NO_HRP" end
    saveCurrentPosition()
    local landing = findBestWaterPosition(target.pos)
    local tpPos = landing + Vector3.new(0, hoverHeight, 0)
    setCFrameSafely(hrp, tpPos)
    local bp = ensureHoverBP(hrp)
    if bp then bp.Position = tpPos end
    print("[AutoTeleportEvent] Teleported to:", target.name, "at", tostring(landing))
    return true
end

local function restoreToSavedPosition()
    if not savedPosition then return end
    local _, hrp = ensureCharacter()
    if hrp then
        removeHoverBP(hrp)
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        hrp.AssemblyLinearVelocity = Vector3.new()
        hrp.AssemblyAngularVelocity = Vector3.new()
        print("[AutoTeleportEvent] Restored to saved position:", tostring(savedPosition.Position))
    end
end

local function maintainHover()
    local _, hrp = ensureCharacter()
    if hrp and currentTarget then
        if not currentTarget.model or not currentTarget.model.Parent then
            print("[AutoTeleportEvent] Current target gone → clear")
            currentTarget = nil
            removeHoverBP(hrp)
            return
        end
        local desired = currentTarget.pos + Vector3.new(0, hoverHeight, 0)
        local bp = ensureHoverBP(hrp)
        if bp then
            bp.Position = desired
        elseif (hrp.Position - desired).Magnitude > 5 then
            setCFrameSafely(hrp, desired)
        end
        if (hrp.Position - desired).Magnitude <= 1.2 then
            hrp.AssemblyLinearVelocity = Vector3.new()
            hrp.AssemblyAngularVelocity = Vector3.new()
        end
    elseif hrp then
        removeHoverBP(hrp)
    end
end

--========================================================
-- ===== Track Active Props =====
--========================================================

local function updateActivePropsTracking()
    local newActiveProps = {}
    local activeEvents = scanAllActiveProps()
    for _, event in ipairs(activeEvents) do
        newActiveProps[event.propsName] = true
    end
    for propsName, _ in pairs(lastKnownActiveProps) do
        if not newActiveProps[propsName] then
            print("[AutoTeleportEvent] Props removed:", propsName)
            if currentTarget and currentTarget.propsName == propsName then
                print("[AutoTeleportEvent] Clearing target due to props removal")
                currentTarget = nil
                local _, hrp = ensureCharacter()
                if hrp then removeHoverBP(hrp) end
            end
        end
    end
    lastKnownActiveProps = newActiveProps
end

--========================================================
-- ===== Loop =====
--========================================================

local function startLoop()
    if hbConn then hbConn:Disconnect() end
    local lastTick = 0
    hbConn = RunService.Heartbeat:Connect(function()
        if not running then return end
        maintainHover()
        local now = os.clock()
        if now - lastTick < 0.3 then return end
        lastTick = now
        updateActivePropsTracking()
        local best = chooseBestActiveEvent()
        if not best then
            if currentTarget then
                print("[AutoTeleportEvent] No valid events, clearing target")
                currentTarget = nil
            end
            restoreToSavedPosition()
            return
        end
        if (not currentTarget) or (currentTarget.model ~= best.model) or (currentTarget.propsName ~= best.propsName) then
            print("[AutoTeleportEvent] Switching target →", best.name)
            teleportToTarget(best)
            currentTarget = best
        end
    end)
end

--========================================================
-- ===== Workspace Monitoring =====
--========================================================

local function setupWorkspaceMonitoring()
    if propsAddedConn then propsAddedConn:Disconnect() end
    if propsRemovedConn then propsRemovedConn:Disconnect() end
    if workspaceConn then workspaceConn:Disconnect() end
    propsAddedConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name:lower():find("props") then
            print("[AutoTeleportEvent] New Props detected:", child.Name)
            task.wait(0.5)
        end
    end)
    propsRemovedConn = Workspace.ChildRemoved:Connect(function(child)
        if child.Name:lower():find("props") then
            print("[AutoTeleportEvent] Props removed:", child.Name)
            if lastKnownActiveProps[child.Name] then
                lastKnownActiveProps[child.Name] = nil
                if currentTarget and currentTarget.propsName == child.Name then
                    currentTarget = nil
                    local _, hrp = ensureCharacter()
                    if hrp then removeHoverBP(hrp) end
                end
            end
        end
    end)
    workspaceConn = Workspace.DescendantAdded:Connect(function(desc)
        if desc:IsA("Model") and desc.Parent and desc.Parent.Name:lower():find("props") then
            task.wait(0.1)
        end
    end)
end

--========================================================
-- ===== Lifecycle =====
--========================================================

function AutoTeleportEvent:Init(gui)
    eventsFolder = ReplicatedStorage:FindFirstChild("Events") or waitChild(ReplicatedStorage, "Events", 5)
    validEventName = buildValidEventNames()
    if charConn then charConn:Disconnect() end
    charConn = LocalPlayer.CharacterAdded:Connect(function()
        savedPosition = nil
        if running and currentTarget then
            task.defer(function()
                task.wait(0.5)
                if currentTarget then teleportToTarget(currentTarget) end
            end)
        end
    end)
    setupWorkspaceMonitoring()
    print("[AutoTeleportEvent] Initialized successfully")
    return true
end

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
