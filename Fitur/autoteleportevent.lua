--========================================================
-- AutoTeleportEvent (compat-safe final)
-- - safer table.clear, clamp
-- - robust resolveEventCenterPos (marker-first)
-- - smart water search
-- - priority + nearest selection
-- - stable hover with BodyPosition
--========================================================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- Safe helpers for compatibility
local function safe_table_clear(t)
    if type(t) ~= "table" then return end
    for k in pairs(t) do t[k] = nil end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Logger (safe)
local logger = _G.Logger and _G.Logger.new("AutoTeleportEvent") or {
    debug = function(...) print("[AutoTeleportEvent][DEBUG]", ...) end,
    info  = function(...) print("[AutoTeleportEvent][INFO]", ...) end,
    warn  = function(...) print("[AutoTeleportEvent][WARN]", ...) end,
    error = function(...) print("[AutoTeleportEvent][ERROR]", ...) end
}

-- State
local AutoTeleportEvent = {}
AutoTeleportEvent.__index = AutoTeleportEvent

local running          = false
local hbConn           = nil
local charConn         = nil
local propsAddedConn   = nil
local propsRemovedConn = nil
local workspaceConn    = nil
local notificationConn = nil
local eventsFolder     = nil

local selectedPriorityList = {}
local selectedSet = {}
local hoverHeight = 15
local savedPosition = nil -- CFrame
local currentTarget = nil -- table {model,name,nameKey,pos,propsName}
local lastKnownActiveProps = {}
local notifiedEvents = {}

local validEventName = {}

-- Utilities
local function normName(s)
    s = tostring(s or "")
    s = string.lower(s)
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

local function setCFrameSafely(hrp, targetPos, lookAt)
    -- lookAt is world Vector3 or nil
    local look = lookAt or (hrp.CFrame.LookVector + hrp.Position)
    hrp.AssemblyLinearVelocity = Vector3.new()
    hrp.AssemblyAngularVelocity = Vector3.new()
    local lookPoint = Vector3.new(look.X, targetPos.Y, look.Z)
    hrp.CFrame = CFrame.lookAt(targetPos, lookPoint)
end

-- Hover BodyPosition
local HOVER_BP_NAME = "AutoTeleport_HoverBP"
local function ensureHoverBP(hrp)
    if not hrp then return nil end
    local bp = hrp:FindFirstChild(HOVER_BP_NAME)
    if bp and bp:IsA("BodyPosition") then return bp end
    bp = Instance.new("BodyPosition")
    bp.Name = HOVER_BP_NAME
    bp.MaxForce = Vector3.new(1e6,1e6,1e6)
    bp.P = 30000
    bp.D = 1000
    bp.Parent = hrp
    return bp
end
local function removeHoverBP(hrp)
    if not hrp then return end
    local bp = hrp:FindFirstChild(HOVER_BP_NAME)
    if bp then pcall(function() bp:Destroy() end) end
end

-- Save/restore
local function saveCurrentPosition()
    if savedPosition then return end
    local _, hrp = ensureCharacter()
    if hrp then
        savedPosition = hrp.CFrame
        logger.info("Position saved at:", tostring(savedPosition.Position))
    end
end

local function restoreToSavedPosition()
    if not savedPosition then
        logger.info("No saved position to restore")
        return
    end
    local _, hrp = ensureCharacter()
    if hrp then
        removeHoverBP(hrp)
        -- restore full look using saved CFrame.LookVector
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        hrp.AssemblyLinearVelocity = Vector3.new()
        hrp.AssemblyAngularVelocity = Vector3.new()
        logger.info("Restored to saved position:", tostring(savedPosition.Position))
    end
end

-- Index events from ReplicatedStorage.Events (if present)
local function indexEvents()
    safe_table_clear(validEventName)
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
    pcall(scan, eventsFolder)
    -- debug
    local keys = {}
    for k,_ in pairs(validEventName) do table.insert(keys,k) end
    logger.debug("Indexed event names:", table.concat(keys, ", "))
end

-- Notification listener (optional)
local function setupEventNotificationListener()
    if notificationConn then notificationConn:Disconnect() end

    local textNotificationRE = nil
    local packagesFolder = ReplicatedStorage:FindFirstChild("Packages")
    if packagesFolder then
        local indexFolder = packagesFolder:FindFirstChild("_Index")
        if indexFolder then
            for _, child in ipairs(indexFolder:GetChildren()) do
                if child.Name:find("sleitnick_net") then
                    local netFolder = child:FindFirstChild("net")
                    if netFolder then
                        textNotificationRE = netFolder:FindFirstChild("RE/TextNotification")
                        if textNotificationRE then break end
                    end
                end
            end
        end
    end

    if textNotificationRE then
        notificationConn = textNotificationRE.OnClientEvent:Connect(function(data)
            if type(data) == "table" and data.Type == "Event" and data.Text then
                local key = normName(data.Text)
                notifiedEvents[key] = { name = data.Text, timestamp = os.clock() }
                -- cleanup older than 5 min
                for k,info in pairs(notifiedEvents) do
                    if os.clock() - info.timestamp > 300 then notifiedEvents[k] = nil end
                end
                logger.info("Notified event stored:", data.Text)
            end
        end)
    else
        logger.debug("TextNotification RE not found, notifications disabled")
    end
end

-- Resolve pivot / bounding box
local function resolveModelPivotPos(model)
    if not model then return nil end
    local ok, cf = pcall(function() return model:GetPivot() end)
    if ok and typeof(cf) == "CFrame" then return cf.Position end
    local ok2, cf2 = pcall(function() return model.WorldPivot end)
    if ok2 and typeof(cf2) == "CFrame" then return cf2.Position end
    if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
        return model.PrimaryPart.Position
    end
    local ok3, cframe, size = pcall(function() return model:GetBoundingBox() end)
    if ok3 and typeof(cframe) == "CFrame" then return cframe.Position end
    return nil
end

-- Resolve event center better than pivot
local function resolveEventCenterPos(model)
    if not model then return nil end

    local function hasVisualIndicator(part)
        if not part or not part.Name then return false end
        local name = tostring(part.Name):lower()
        if name:find("ring") or name:find("circle") or name:find("indicator")
        or name:find("marker") or name:find("center") or name:find("hitbox")
        or name:find("spawn") or name:find("area") then
            return true
        end
        if part:FindFirstChildOfClass("ParticleEmitter") or part:FindFirstChildOfClass("PointLight") then
            return true
        end
        if part:FindFirstChild("BillboardGui") or part:FindFirstChild("SurfaceGui") then
            return true
        end
        return false
    end

    -- 1) search descendants for a matching BasePart or Attachment
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") then
            if hasVisualIndicator(desc) then
                local ok, pivot = pcall(function() return desc:GetPivot() end)
                if ok and typeof(pivot) == "CFrame" then return pivot.Position end
                return desc.Position
            end
        elseif desc:IsA("Attachment") then
            local nm = tostring(desc.Name):lower()
            if nm:find("center") or nm:find("marker") or nm:find("spawn") then
                return desc.WorldPosition
            end
        end
    end

    -- 2) check siblings (some markers are sibling to the model in same folder)
    local parent = model.Parent
    if parent then
        for _, sib in ipairs(parent:GetChildren()) do
            if sib ~= model then
                if sib:IsA("BasePart") and hasVisualIndicator(sib) then
                    local ok, pivot = pcall(function() return sib:GetPivot() end)
                    if ok and typeof(pivot) == "CFrame" then return pivot.Position end
                    return sib.Position
                end
                if sib:IsA("Model") then
                    for _, c in ipairs(sib:GetChildren()) do
                        if c:IsA("BasePart") and hasVisualIndicator(c) then
                            local ok, pivot = pcall(function() return c:GetPivot() end)
                            if ok and typeof(pivot) == "CFrame" then return pivot.Position end
                            return c.Position
                        end
                    end
                end
            end
        end
    end

    -- 3) if recently notified matching, prefer pivot
    local mKey = normName(model.Name)
    if notifiedEvents[mKey] then
        local pivot = resolveModelPivotPos(model)
        if pivot then return pivot end
    end

    -- 4) fallback to pivot/bbox
    return resolveModelPivotPos(model)
end

-- Smart water finder (radius sampling)
local function findBestWaterPosition(centerPos)
    if not centerPos then return nil end
    local radii = {0,2,4,6,10,15,20,30}
    local samplesPerRadius = 8
    local rayUp = 60
    local rayDown = 300
    local best, bestDist = nil, math.huge

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    local char = LocalPlayer.Character
    params.FilterDescendantsInstances = char and {char} or {}

    params.IgnoreWater = false

    for _, r in ipairs(radii) do
        local step = (r == 0) and 1 or samplesPerRadius
        for i = 0, step - 1 do
            local offset = Vector3.new(0,0,0)
            if r ~= 0 then
                local theta = (i / step) * math.pi * 2
                offset = Vector3.new(math.cos(theta) * r, 0, math.sin(theta) * r)
            end
            local origin = Vector3.new(centerPos.X + offset.X, centerPos.Y + rayUp, centerPos.Z + offset.Z)
            local dir = Vector3.new(0, -rayDown, 0)
            local ok, res = pcall(function() return Workspace:Raycast(origin, dir, params) end)
            if ok and res and res.Position then
                if res.Material == Enum.Material.Water then
                    local candidate = res.Position
                    local d = (Vector3.new(candidate.X,0,candidate.Z) - Vector3.new(centerPos.X,0,centerPos.Z)).Magnitude
                    if d < bestDist then
                        best = candidate
                        bestDist = d
                    end
                end
            end
        end
        if best then return best end
    end

    -- fallback to centerPos
    return centerPos
end

-- Enhanced event detection (v4 logic)
local function isEventModel(model, propsName)
    if not model or not model:IsA("Model") then return false end
    local modelName = model.Name
    local modelKey = normName(modelName)

    if validEventName[modelKey] then
        return true, modelName, modelKey
    end

    for notifKey, notifInfo in pairs(notifiedEvents) do
        if modelKey == notifKey then return true, notifInfo.name, modelKey end
        if modelKey:find(notifKey,1,true) or notifKey:find(modelKey,1,true) then return true, notifInfo.name, modelKey end
        if modelName == "Model" and os.clock() - notifInfo.timestamp < 30 then return true, notifInfo.name, modelKey end
    end

    local eventPatterns = {"hunt","boss","raid","event","invasion","attack","storm","hole","meteor","comet","shark","worm"}
    for _, p in ipairs(eventPatterns) do
        if modelKey:find(p,1,true) then return true, modelName, modelKey end
    end

    return false
end

-- Scan Props (direct children only)
local function scanAllActiveProps()
    local active = {}
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            local childName = child.Name
            if childName == "Props" or childName:find("Props") then
                for _, directChild in ipairs(child:GetChildren()) do
                    if directChild:IsA("Model") then
                        local model = directChild
                        local ok, isEvent, eventName, eventKey = pcall(function() return isEventModel(model, childName) end)
                        if ok and isEvent then
                            local pos = resolveEventCenterPos(model)
                            if pos then
                                table.insert(active, {
                                    model = model,
                                    name = eventName,
                                    nameKey = eventKey,
                                    pos = pos,
                                    propsName = childName
                                })
                                logger.debug("Found event:", eventName, "pos:", tostring(pos), "in", childName)
                            end
                        end
                    end
                end
            end
        end
    end
    return active
end

-- Selection matching & ranking
local function matchesSelection(nameKey, displayName)
    if #selectedPriorityList == 0 and next(selectedSet) == nil then return true end
    local displayKey = normName(displayName or "")
    for _, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey,1,true) or selKey:find(nameKey,1,true) then return true end
        if displayKey:find(selKey,1,true) or selKey:find(displayKey,1,true) then return true end
    end
    for selKey, on in pairs(selectedSet) do
        if on and (nameKey:find(selKey,1,true) or selKey:find(nameKey,1,true) or displayKey:find(selKey,1,true)) then return true end
    end
    return false
end

local function rankOf(nameKey, displayName)
    for i, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey,1,true) or selKey:find(nameKey,1,true) then return i end
        local displayKey = normName(displayName or "")
        if displayKey:find(selKey,1,true) or selKey:find(displayKey,1,true) then return i end
    end
    return math.huge
end

-- Choose best active (priority -> nearest)
local function chooseBestActiveEvent()
    local actives = scanAllActiveProps()
    if #actives == 0 then return nil end

    local filtered = {}
    for _, a in ipairs(actives) do
        if matchesSelection(a.nameKey, a.name) then table.insert(filtered, a) end
    end
    actives = filtered
    if #actives == 0 then return nil end

    local char, hrp = ensureCharacter()
    local playerPos = hrp and hrp.Position or Vector3.new()
    for _, a in ipairs(actives) do
        a.rank = rankOf(a.nameKey, a.name)
        a.dist = (a.pos - playerPos).Magnitude
    end

    table.sort(actives, function(a,b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.dist ~= b.dist then return a.dist < b.dist end
        return a.name < b.name
    end)

    return actives[1]
end

-- Teleport to target
local function teleportToTarget(target)
    local _, hrp = ensureCharacter()
    if not hrp then return false, "NO_HRP" end

    saveCurrentPosition()

    local center = target.pos
    local landing = nil
    pcall(function() landing = findBestWaterPosition(center) end)
    landing = landing or center
    local tpPos = landing + Vector3.new(0, hoverHeight, 0)

    -- face landing so throw will aim at water
    pcall(function() setCFrameSafely(hrp, tpPos, landing) end)

    local bp = ensureHoverBP(hrp)
    if bp then
        pcall(function() bp.Position = tpPos end)
    end

    logger.info("Teleported to:", target.name, "center:", tostring(center), "landing:", tostring(landing))
    return true
end

-- Maintain hover
local function maintainHover()
    local _, hrp = ensureCharacter()
    if not hrp then return end
    if currentTarget and currentTarget.pos then
        if not currentTarget.model or not currentTarget.model.Parent then
            logger.info("Current target disappeared, clearing")
            currentTarget = nil
            removeHoverBP(hrp)
            return
        end
        local desired = currentTarget.pos + Vector3.new(0, hoverHeight, 0)
        local bp = ensureHoverBP(hrp)
        if bp then
            bp.Position = desired
        else
            if (hrp.Position - desired).Magnitude > 2 then
                setCFrameSafely(hrp, desired)
            end
        end
        if (hrp.Position - desired).Magnitude <= 1.2 then
            hrp.AssemblyLinearVelocity = Vector3.new()
            hrp.AssemblyAngularVelocity = Vector3.new()
        end
    else
        removeHoverBP(hrp)
    end
end

-- Active props tracking
local function updateActivePropsTracking()
    local newActive = {}
    local activeEvents = scanAllActiveProps()
    for _, ev in ipairs(activeEvents) do newActive[ev.propsName] = true end
    for propsName,_ in pairs(lastKnownActiveProps) do
        if not newActive[propsName] then
            logger.info("Props removed:", propsName)
            if currentTarget and currentTarget.propsName == propsName then
                logger.info("Clearing current target due to props removal")
                currentTarget = nil
            end
        end
    end
    lastKnownActiveProps = newActive
end

-- Main loop
local function startLoop()
    if hbConn then hbConn:Disconnect() end
    local lastTick = 0
    hbConn = RunService.Heartbeat:Connect(function()
        if not running then return end
        local now = os.clock()
        pcall(maintainHover)
        if now - lastTick < 0.35 then return end
        lastTick = now

        pcall(updateActivePropsTracking)
        local ok, best = pcall(chooseBestActiveEvent)
        if not ok then
            logger.error("chooseBestActiveEvent failed")
            best = nil
        end

        if not best then
            if currentTarget then
                logger.info("No valid events found, clearing current target")
                currentTarget = nil
            end
            pcall(restoreToSavedPosition)
            return
        end

        if (not currentTarget) or (currentTarget.model ~= best.model) or (currentTarget.propsName ~= best.propsName) then
            logger.info("Switching to new target:", best.name)
            local ok2, err = pcall(function() teleportToTarget(best) end)
            if not ok2 then
                logger.error("Teleport failed:", tostring(err))
            else
                currentTarget = best
            end
        end
    end)
end

-- Workspace monitoring
local function setupWorkspaceMonitoring()
    if propsAddedConn then propsAddedConn:Disconnect() end
    if propsRemovedConn then propsRemovedConn:Disconnect() end
    if workspaceConn then workspaceConn:Disconnect() end

    propsAddedConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            logger.info("New Props detected:", child.Name)
            task.wait(0.5)
        end
    end)

    propsRemovedConn = Workspace.ChildRemoved:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            logger.info("Props removed:", child.Name)
            if lastKnownActiveProps[child.Name] then
                lastKnownActiveProps[child.Name] = nil
                if currentTarget and currentTarget.propsName == child.Name then
                    logger.info("Current target props removed")
                    currentTarget = nil
                end
            end
        end
    end)

    workspaceConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            local propsFolder = child
            propsFolder.ChildAdded:Connect(function(propsChild)
                if propsChild:IsA("Model") then
                    task.wait(0.1)
                    logger.debug("New model added to", propsFolder.Name, ":", propsChild.Name)
                end
            end)
        end
    end)
end

-- Lifecycle
function AutoTeleportEvent:Init(gui)
    eventsFolder = ReplicatedStorage:FindFirstChild("Events") or waitChild(ReplicatedStorage, "Events", 5)
    indexEvents()
    setupEventNotificationListener()

    if charConn then charConn:Disconnect() end
    charConn = LocalPlayer.CharacterAdded:Connect(function()
        savedPosition = nil
        if running and currentTarget then
            task.defer(function()
                task.wait(0.5)
                if currentTarget then
                    pcall(function() teleportToTarget(currentTarget) end)
                end
            end)
        end
    end)

    setupWorkspaceMonitoring()
    logger.info("Initialized successfully")
    return true
end

function AutoTeleportEvent:Start(config)
    if running then return true end
    running = true

    if config then
        if type(config.hoverHeight) == "number" then hoverHeight = clamp(config.hoverHeight, 5, 100) end
        if type(config.selectedEvents) ~= "nil" then self:SetSelectedEvents(config.selectedEvents) end
    end

    currentTarget = nil
    savedPosition = nil
    safe_table_clear(lastKnownActiveProps)

    logger.info("Starting with events:", table.concat(selectedPriorityList, ", "))
    local ok, best = pcall(chooseBestActiveEvent)
    if ok and best then
        pcall(function() teleportToTarget(best) end)
        currentTarget = best
        logger.info("Initial target found:", best.name)
    else
        logger.info("No initial target found")
    end

    startLoop()
    logger.info("Started successfully")
    return true
end

function AutoTeleportEvent:Stop()
    if not running then return true end
    running = false
    if hbConn then hbConn:Disconnect(); hbConn = nil end
    if savedPosition then
        restoreToSavedPosition()
    else
        local _, hrp = ensureCharacter()
        if hrp then removeHoverBP(hrp) end
    end
    currentTarget = nil
    safe_table_clear(lastKnownActiveProps)
    logger.info("Stopped and restored position")
    return true
end

function AutoTeleportEvent:Cleanup()
    self:Stop()
    if charConn then charConn:Disconnect(); charConn = nil end
    if propsAddedConn then propsAddedConn:Disconnect(); propsAddedConn = nil end
    if propsRemovedConn then propsRemovedConn:Disconnect(); propsRemovedConn = nil end
    if workspaceConn then workspaceConn:Disconnect(); workspaceConn = nil end
    if notificationConn then notificationConn:Disconnect(); notificationConn = nil end

    eventsFolder = nil
    safe_table_clear(validEventName)
    safe_table_clear(selectedPriorityList)
    safe_table_clear(selectedSet)
    safe_table_clear(lastKnownActiveProps)
    safe_table_clear(notifiedEvents)
    savedPosition = nil
    currentTarget = nil
    logger.info("Cleanup completed")
    return true
end

-- Setters
function AutoTeleportEvent:SetSelectedEvents(selected)
    safe_table_clear(selectedPriorityList)
    safe_table_clear(selectedSet)
    if type(selected) == "table" then
        if #selected > 0 then
            for _, v in ipairs(selected) do
                local key = normName(v)
                table.insert(selectedPriorityList, key)
                selectedSet[key] = true
            end
            logger.info("Priority events set:", table.concat(selectedPriorityList, ", "))
        else
            for k, on in pairs(selected) do
                if on then selectedSet[normName(k)] = true end
            end
        end
    end
    return true
end

function AutoTeleportEvent:SetHoverHeight(h)
    if type(h) == "number" then
        hoverHeight = clamp(h, 5, 100)
        if running and currentTarget then
            local _, hrp = ensureCharacter()
            if hrp then
                local desired = currentTarget.pos + Vector3.new(0, hoverHeight, 0)
                local bp = ensureHoverBP(hrp)
                if bp then bp.Position = desired else setCFrameSafely(hrp, desired) end
            end
        end
        return true
    end
    return false
end

function AutoTeleportEvent:Status()
    return {
        running = running,
        hover = hoverHeight,
        hasSavedPos = savedPosition ~= nil,
        target = currentTarget and currentTarget.name or nil,
        activeProps = lastKnownActiveProps,
        notifications = notifiedEvents,
    }
end

function AutoTeleportEvent.new()
    local self = setmetatable({}, AutoTeleportEvent)
    return self
end

return AutoTeleportEvent
