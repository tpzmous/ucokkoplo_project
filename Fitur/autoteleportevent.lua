--========================================================
-- Feature: AutoTeleportEvent + AutoFly (Fixed v5)
--========================================================

local AutoTeleportEvent = {}
AutoTeleportEvent.__index = AutoTeleportEvent

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- ===== State =====
local running          = false
local hbConn           = nil
local charConn         = nil
local propsAddedConn   = nil
local propsRemovedConn = nil
local workspaceConn    = nil
local eventsFolder     = nil

local selectedPriorityList = {}
local selectedSet           = {}
local hoverHeight           = 15
local savedPosition         = nil
local currentTarget         = nil
local lastKnownActiveProps  = {}

-- ===== Auto Fly State =====
local flying  = false
local flyConn = nil

-- ===== Utils =====
local function normName(s)
    s = string.lower(s or "")
    s = s:gsub("%W", "")
    return s
end

local function waitChild(parent, name, timeout)
    local t0 = os.clock()
    local obj = parent:FindFirstChild(name)
    while not obj and (os.clock() - t0) < (timeout or 5) do
        parent.ChildAdded:Wait()
        obj = parent:FindFirstChild(name)
    end
    return obj
end

local function ensureCharacter()
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local hrp  = char:FindFirstChild("HumanoidRootPart") or waitChild(char, "HumanoidRootPart", 5)
    local hum  = char:FindFirstChildOfClass("Humanoid")
    return char, hrp, hum
end

local function setCFrameSafely(hrp, targetPos, keepLookAt)
    local look = keepLookAt or (hrp.CFrame.LookVector + hrp.Position)
    hrp.AssemblyLinearVelocity = Vector3.new()
    hrp.AssemblyAngularVelocity = Vector3.new()
    hrp.CFrame = CFrame.lookAt(targetPos, Vector3.new(look.X, targetPos.Y, look.Z))
end

local function startFly()
    if flying then return end
    flying = true
    local char, hrp = ensureCharacter()
    if not hrp then return end
    flyConn = RunService.Heartbeat:Connect(function()
        if not Character or not Character:FindFirstChild("HumanoidRootPart") then return end
        local hrp = Character.HumanoidRootPart
        local dir = Vector3.new()
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir = dir + Vector3.new(0,0,-1) end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir = dir + Vector3.new(0,0,1) end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir = dir + Vector3.new(-1,0,0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir = dir + Vector3.new(1,0,0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0,1,0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir + Vector3.new(0,-1,0) end
        hrp.Velocity = (hrp.CFrame.LookVector * dir.Z + hrp.CFrame.RightVector * dir.X + Vector3.new(0,dir.Y,0)) * 60
    end)
end

local function stopFly()
    if not flying then return end
    flying = false
    if flyConn then flyConn:Disconnect(); flyConn = nil end
    local char, hrp = ensureCharacter()
    if hrp then
        hrp.Velocity = Vector3.new(0,0,0)
    end
end

-- ===== Save / Restore position =====
local function saveCurrentPosition()
    if savedPosition then return end
    local _, hrp = ensureCharacter()
    if hrp then
        savedPosition = hrp.CFrame
        print("[AutoTeleportEvent] Position saved at:", tostring(savedPosition.Position))
    end
end

local function restoreToSavedPosition()
    if not savedPosition then return end
    local _, hrp = ensureCharacter()
    if hrp then
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        print("[AutoTeleportEvent] Restored to saved position:", tostring(savedPosition.Position))
    end
end

-- ===== Events Indexing / Scanning =====
local validEventName = {}

local function indexEvents()
    table.clear(validEventName)
    if not eventsFolder then return end
    local function scan(folder)
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("ModuleScript") then
                local ok, data = pcall(require, child)
                if ok and type(data) == "table" and data.Name then
                    validEventName[normName(data.Name)] = true
                end
                validEventName[normName(child.Name)] = true
            elseif child:IsA("Folder") then
                scan(child)
            end
        end
    end
    scan(eventsFolder)
end

local function resolveModelPivotPos(model)
    local ok, cf = pcall(function() return model:GetPivot() end)
    if ok and typeof(cf) == "CFrame" then return cf.Position end
    local ok2, cf2 = pcall(function() return model.WorldPivot end)
    if ok2 and typeof(cf2) == "CFrame" then return cf2.Position end
    return nil
end

local function scanAllActiveProps()
    local activePropsList = {}
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            local childName = child.Name
            if childName == "Props" or childName:find("Props") then
                for _, desc in ipairs(child:GetDescendants()) do
                    if desc:IsA("Model") then
                        local model = desc
                        local mKey = normName(model.Name)
                        local pKey = model.Parent and normName(model.Parent.Name) or nil
                        local isEventish = (validEventName[mKey] == true) or (pKey and validEventName[pKey] == true)
                        if isEventish then
                            local pos = resolveModelPivotPos(model)
                            if pos then
                                local repName = model.Parent and model.Parent.Name or model.Name
                                table.insert(activePropsList, {
                                    model     = model,
                                    name      = repName,
                                    nameKey   = normName(repName),
                                    pos       = pos,
                                    propsName = childName
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    return activePropsList
end

-- ===== Selection Helpers =====
local function matchesSelection(nameKey)
    if #selectedPriorityList == 0 then return true end
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

local function chooseBestActiveEvent()
    local actives = scanAllActiveProps()
    if #actives == 0 then return nil end

    local filtered = {}
    if #selectedPriorityList > 0 then
        for _, a in ipairs(actives) do
            if matchesSelection(a.nameKey) then
                table.insert(filtered, a)
            end
        end
        actives = filtered
        if #actives == 0 then
            return nil
        end
    end

    for _, a in ipairs(actives) do
        a.rank = rankOf(a.nameKey)
    end

    table.sort(actives, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)

    return actives[1]
end

-- ===== Teleport + AutoFly =====
local function isCloseEnough(pos1, pos2, threshold)
    return (pos1 - pos2).Magnitude <= threshold
end

local function teleportToTarget(target)
    local _, hrp = ensureCharacter()
    if not hrp then return false, "NO_HRP" end
    saveCurrentPosition()
    local tpPos = target.pos + Vector3.new(0, hoverHeight, 0)
    setCFrameSafely(hrp, tpPos)
    startFly() -- Auto fly triggered immediately after teleport
    print("[AutoTeleportEvent] Teleported to:", target.name, "at", tostring(target.pos))
    return true
end

local function maintainHover()
    local _, hrp = ensureCharacter()
    if hrp and currentTarget then
        if not currentTarget.model or not currentTarget.model.Parent then
            print("[AutoTeleportEvent] Current target no longer exists, clearing")
            currentTarget = nil
            stopFly()
            return
        end
        local desired = currentTarget.pos + Vector3.new(0, hoverHeight, 0)
        if (hrp.Position - desired).Magnitude > 1.2 then
            setCFrameSafely(hrp, desired)
        else
            hrp.AssemblyLinearVelocity = Vector3.new()
            hrp.AssemblyAngularVelocity = Vector3.new()
        end
    end
end

-- ===== Main Loop =====
local function startLoop()
    if hbConn then hbConn:Disconnect() end
    local lastTick = 0
    hbConn = RunService.Heartbeat:Connect(function()
        if not running then return end
        local now = os.clock()
        maintainHover()
        if now - lastTick < 0.3 then return end
        lastTick = now

        local activeEvents = scanAllActiveProps()
        local best = chooseBestActiveEvent()
        if not best then
            if currentTarget then
                print("[AutoTeleportEvent] No valid events found, clearing current target")
                currentTarget = nil
            end
            restoreToSavedPosition()
            stopFly()
            return
        end

        local _, hrp = ensureCharacter()
        local targetPos = best.pos + Vector3.new(0, hoverHeight, 0)
        if not currentTarget 
           or currentTarget.model ~= best.model 
           or currentTarget.propsName ~= best.propsName
           or not isCloseEnough(hrp.Position, targetPos, 2) then
            print("[AutoTeleportEvent] Switching to new target:", best.name)
            teleportToTarget(best)
            currentTarget = best
        end
    end)
end

-- ===== Workspace Monitoring =====
local function setupWorkspaceMonitoring()
    if propsAddedConn then propsAddedConn:Disconnect() end
    if propsRemovedConn then propsRemovedConn:Disconnect() end
    if workspaceConn then workspaceConn:Disconnect() end

    propsAddedConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            task.wait(0.5)
        end
    end)

    propsRemovedConn = Workspace.ChildRemoved:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            if lastKnownActiveProps[child.Name] then
                lastKnownActiveProps[child.Name] = nil
                if currentTarget and currentTarget.propsName == child.Name then
                    currentTarget = nil
                    stopFly()
                end
            end
        end
    end)
end

-- ===== Lifecycle =====
function AutoTeleportEvent:Init(gui)
    eventsFolder = ReplicatedStorage:FindFirstChild("Events") or waitChild(ReplicatedStorage, "Events", 5)
    indexEvents()
    if charConn then charConn:Disconnect() end
    charConn = LocalPlayer.CharacterAdded:Connect(function()
        savedPosition = nil
        if running and currentTarget then
            task.defer(function()
                task.wait(0.5)
                if currentTarget then
                    teleportToTarget(currentTarget)
                end
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
    local best = chooseBestActiveEvent()
    if best then
        teleportToTarget(best)
        currentTarget = best
    end
    startLoop()
    return true
end

function AutoTeleportEvent:Stop()
    if not running then return true end
    running = false
    if hbConn then hbConn:Disconnect(); hbConn = nil end
    stopFly()
    if savedPosition then restoreToSavedPosition() end
    currentTarget = nil
    table.clear(lastKnownActiveProps)
    return true
end

function AutoTeleportEvent.new()
    local self = setmetatable({}, AutoTeleportEvent)
    return self
end

return AutoTeleportEvent
