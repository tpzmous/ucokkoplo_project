--========================================================
-- Feature: AutoTeleportEvent (Merged v5)
-- Combines v3 (hover BodyPosition + smart water teleport)
-- with v4 (TextNotification listener + better event fuzzy matching + logger)
--========================================================

local AutoTeleportEvent = {}
AutoTeleportEvent.__index = AutoTeleportEvent

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- ===== State =====
local running          = false
local hbConn           = nil
local charConn         = nil
local propsAddedConn   = nil
local propsRemovedConn = nil
local workspaceConn    = nil
local notificationConn = nil
local eventsFolder     = nil

local monitoredPropsConns = {} -- map propsFolder -> RBXScriptConnection (for its ChildAdded)

local selectedPriorityList = {}
local selectedSet           = {}
local hoverHeight           = 15
local savedPosition         = nil
local currentTarget         = nil -- { model, name, nameKey, pos, propsName }
local lastKnownActiveProps  = {}
local notifiedEvents        = {} -- map normName -> { name, timestamp }
local validEventName = {}

local HOVER_BP_NAME = "AutoTeleport_HoverBP"

-- ===== Logger (v4-style with fallback) =====
local logger = nil
if _G.Logger and type(_G.Logger.new) == "function" then
    local ok, l = pcall(_G.Logger.new, "AutoTeleportEvent")
    if ok and l then logger = l end
end
if not logger then
    logger = {
        debug = function() end,
        info = function() end,
        warn = function() end,
        error = function() end
    }
end

-- Small helper to safely concat args for print-based fallback if needed
local function fmtArgs(...)
    local t = {}
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        table.insert(t, tostring(v))
    end
    return table.concat(t, " ")
end

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

-- ===== Hover BodyPosition helpers (from v3) =====
local function ensureHoverBP(hrp)
    if not hrp then return nil end
    local bp = hrp:FindFirstChild(HOVER_BP_NAME)
    if bp and bp:IsA("BodyPosition") then
        return bp
    end
    -- Create BodyPosition
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
        pcall(function() bp:Destroy() end)
    end
end

-- ===== Smart water-finding helpers (from v3) =====
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
    if char then
        params.FilterDescendantsInstances = {char}
    else
        params.FilterDescendantsInstances = {}
    end
    params.IgnoreWater = false

    for _, r in ipairs(radii) do
        if r > maxRadius then break end
        local stepCount = (r == 0) and 1 or samplesPerRadius
        for i = 0, stepCount - 1 do
            local offset = Vector3.new(0,0,0)
            if r == 0 then
                offset = Vector3.new(0,0,0)
            else
                local theta = (i / stepCount) * math.pi * 2
                offset = Vector3.new(math.cos(theta) * r, 0, math.sin(theta) * r)
            end

            local origin = Vector3.new(centerPos.X + offset.X, centerPos.Y + rayUp, centerPos.Z + offset.Z)
            local direction = Vector3.new(0, -rayDown, 0)
            local result = Workspace:Raycast(origin, direction, params)
            if result and result.Position then
                local mat = result.Material
                if mat == Enum.Material.Water then
                    local candidate = result.Position
                    local d = (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(centerPos.X, 0, centerPos.Z)).Magnitude
                    if d < bestDist then
                        best = candidate
                        bestDist = d
                    end
                else
                    -- fallback checks could go here if needed
                end
            end
        end
        if best then
            return best
        end
    end

    return centerPos
end

-- ===== Save Position Before First Teleport =====
local function saveCurrentPosition()
    if savedPosition then return end
    local _, hrp = ensureCharacter()
    if hrp then
        savedPosition = hrp.CFrame
        logger:info("Position saved at:", tostring(savedPosition.Position))
    end
end

-- ===== Index Events from ReplicatedStorage.Events (v3/v4) =====
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

-- ===== Event Notification Listener (v4) =====
local function setupEventNotificationListener()
    if notificationConn then notificationConn:Disconnect(); notificationConn = nil end

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

    if textNotificationRE and textNotificationRE.OnClientEvent then
        logger:info("Found TextNotification RE, setting up listener")
        notificationConn = textNotificationRE.OnClientEvent:Connect(function(data)
            if type(data) == "table" and data.Type == "Event" and data.Text then
                local eventName = data.Text
                local eventKey = normName(eventName)
                notifiedEvents[eventKey] = { name = eventName, timestamp = os.clock() }
                -- Cleanup old notifications
                for key, info in pairs(notifiedEvents) do
                    if os.clock() - info.timestamp > 300 then
                        notifiedEvents[key] = nil
                    end
                end
                -- small delay to let props spawn
                if running then
                    task.spawn(function()
                        task.wait(0.8)
                        -- next loop iteration will pick up new props
                    end)
                end
            end
        end)
    else
        logger:warn("Could not find TextNotification RE (optional)")
    end
end

-- ===== Resolve Model Pivot =====
local function resolveModelPivotPos(model)
    local ok, cf = pcall(function() return model:GetPivot() end)
    if ok and typeof(cf) == "CFrame" then return cf.Position end
    local ok2, cf2 = pcall(function() return model.WorldPivot end)
    if ok2 and typeof(cf2) == "CFrame" then return cf2.Position end
    return nil
end

-- ===== Enhanced Event Detection (merge v3+v4) =====
local eventPatterns = {
    "hunt", "boss", "raid", "event", "invasion", "attack",
    "storm", "hole", "meteor", "comet", "shark", "worm"
}

local function isEventModel(model, propsName)
    if not model or not model:IsA("Model") then return false end

    local modelName = model.Name or ""
    local modelKey = normName(modelName)

    -- 1. Check against ReplicatedStorage.Events
    if validEventName[modelKey] then
        return true, modelName, modelKey
    end

    -- 2. Check notifications (fuzzy)
    for notifKey, notifInfo in pairs(notifiedEvents) do
        if modelKey == notifKey then
            return true, notifInfo.name, modelKey
        end
        if modelKey:find(notifKey, 1, true) or notifKey:find(modelKey, 1, true) then
            return true, notifInfo.name, modelKey
        end
        if modelName == "Model" and os.clock() - notifInfo.timestamp < 30 then
            return true, notifInfo.name, modelKey
        end
    end

    -- 3. Common patterns
    for _, pattern in ipairs(eventPatterns) do
        if modelKey:find(pattern, 1, true) then
            return true, modelName, modelKey
        end
    end

    return false
end

-- ===== Scan Props (balanced between v3 & v4) =====
local function scanAllActiveProps()
    local activePropsList = {}

    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            local childName = child.Name
            if childName == "Props" or childName:find("Props") then
                -- scan direct children first (lightweight)
                for _, directChild in ipairs(child:GetChildren()) do
                    if directChild:IsA("Model") then
                        local model = directChild
                        local isEvent, eventName, eventKey = isEventModel(model, childName)
                        if isEvent then
                            local pos = resolveModelPivotPos(model)
                            if pos then
                                table.insert(activePropsList, {
                                    model     = model,
                                    name      = eventName,
                                    nameKey   = eventKey,
                                    pos       = pos,
                                    propsName = childName
                                })
                            end
                        end
                    end
                    -- also check if directChild contains models (one level deeper)
                    for _, maybeModel in ipairs(directChild:GetChildren()) do
                        if maybeModel:IsA("Model") then
                            local model = maybeModel
                            local isEvent, eventName, eventKey = isEventModel(model, childName)
                            if isEvent then
                                local pos = resolveModelPivotPos(model)
                                if pos then
                                    table.insert(activePropsList, {
                                        model     = model,
                                        name      = eventName,
                                        nameKey   = eventKey,
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
    end

    return activePropsList
end

-- ===== Matching & Ranking (merge behaviors) =====
local function matchesSelection(nameKey, displayName)
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
        local displayKey = normName(displayName or "")
        if displayKey:find(selKey, 1, true) or selKey:find(displayKey, 1, true) then
            return true
        end
    end

    return false
end

local function rankOf(nameKey, displayName)
    for i, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return i
        end
        local displayKey = normName(displayName or "")
        if displayKey:find(selKey, 1, true) or selKey:find(displayKey, 1, true) then
            return i
        end
    end
    return math.huge
end

local function chooseBestActiveEvent()
    local actives = scanAllActiveProps()
    if #actives == 0 then return nil end

    local filtered = {}
    if #selectedPriorityList > 0 or next(selectedSet) ~= nil then
        for _, a in ipairs(actives) do
            if matchesSelection(a.nameKey, a.name) then
                table.insert(filtered, a)
            end
        end
        actives = filtered
        if #actives == 0 then
            return nil
        end
    end

    for _, a in ipairs(actives) do
        a.rank = rankOf(a.nameKey, a.name)
    end

    table.sort(actives, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)

    return actives[1]
end

-- ===== Teleport / Return (merge smart-water + hover BP) =====
local function teleportToTarget(target)
    local char, hrp, hum = ensureCharacter()
    if not hrp then return false, "NO_HRP" end

    saveCurrentPosition()

    local landing = findBestWaterPosition(target.pos)
    local tpPos = landing + Vector3.new(0, hoverHeight, 0)

    -- Instant teleport, then BodyPosition handles smoothing
    setCFrameSafely(hrp, tpPos)
    local bp = ensureHoverBP(hrp)
    if bp then
        bp.Position = tpPos
    end

    logger:info("Teleported to:", target.name, tostring(landing))
    currentTarget = target
    return true
end

local function restoreToSavedPosition()
    if not savedPosition then
        logger:info("No saved position to restore")
        return
    end

    local _, hrp = ensureCharacter()
    if hrp then
        removeHoverBP(hrp)
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        hrp.AssemblyLinearVelocity = Vector3.new()
        hrp.AssemblyAngularVelocity = Vector3.new()
        logger:info("Restored to saved position:", tostring(savedPosition.Position))
    end
end

local function maintainHover()
    local _, hrp = ensureCharacter()
    if not hrp then return end

    if hrp and currentTarget then
        if not currentTarget.model or not currentTarget.model.Parent then
            logger:info("Current target model removed, clearing target")
            currentTarget = nil
            removeHoverBP(hrp)
            return
        end

        local desired = currentTarget.pos + Vector3.new(0, hoverHeight, 0)
        local bp = ensureHoverBP(hrp)
        if bp then
            bp.Position = desired
        else
            if (hrp.Position - desired).Magnitude > 5 then
                setCFrameSafely(hrp, desired)
            end
        end

        if (hrp.Position - desired).Magnitude <= 1.2 then
            hrp.AssemblyLinearVelocity = Vector3.new()
            hrp.AssemblyAngularVelocity = Vector3.new()
        end
    else
        -- no current target -> ensure no hover BP
        removeHoverBP(hrp)
    end
end

-- ===== Track Active Props =====
local function updateActivePropsTracking()
    local newActiveProps = {}
    local activeEvents = scanAllActiveProps()
    for _, event in ipairs(activeEvents) do
        newActiveProps[event.propsName] = true
    end

    for propsName, _ in pairs(lastKnownActiveProps) do
        if not newActiveProps[propsName] then
            logger:info("Props removed:", propsName)
            if currentTarget and currentTarget.propsName == propsName then
                logger:info("Current target props removed, clearing target")
                currentTarget = nil
            end
        end
    end

    lastKnownActiveProps = newActiveProps
end

-- ===== Workspace Monitoring (avoid double connections) =====
local function onPropsFolderAdded(propsFolder)
    if not propsFolder then return end
    local name = propsFolder.Name
    logger:info("New Props detected:", name)

    -- Attach listener for direct children (one-level) only; store connection so we can disconnect later
    if monitoredPropsConns[propsFolder] then
        -- already monitoring
        return
    end

    local conn
    conn = propsFolder.ChildAdded:Connect(function(propsChild)
        if propsChild:IsA("Model") then
            task.wait(0.08)
            logger:info("New model added to", propsFolder.Name, propsChild.Name)
        end
    end)

    monitoredPropsConns[propsFolder] = conn
end

local function onPropsFolderRemoved(propsFolder)
    if not propsFolder then return end
    local conn = monitoredPropsConns[propsFolder]
    if conn then
        conn:Disconnect()
        monitoredPropsConns[propsFolder] = nil
    end
end

local function setupWorkspaceMonitoring()
    if propsAddedConn then propsAddedConn:Disconnect(); propsAddedConn = nil end
    if propsRemovedConn then propsRemovedConn:Disconnect(); propsRemovedConn = nil end

    propsAddedConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            task.wait(0.5)
            onPropsFolderAdded(child)
        end
    end)

    propsRemovedConn = Workspace.ChildRemoved:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            logger:info("Props removed (folder):", child.Name)
            onPropsFolderRemoved(child)
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

    -- Start monitoring already present Props folders
    for _, child in ipairs(Workspace:GetChildren()) do
        if child.Name == "Props" or child.Name:find("Props") then
            onPropsFolderAdded(child)
        end
    end
end

-- ===== Loop =====
local function startLoop()
    if hbConn then hbConn:Disconnect() end
    local lastTick = 0
    hbConn = RunService.Heartbeat:Connect(function()
        if not running then return end
        -- maintain hover every heartbeat
        maintainHover()

        local now = os.clock()
        if now - lastTick < 0.35 then return end
        lastTick = now

        updateActivePropsTracking()
        local best = chooseBestActiveEvent()

        if not best then
            if currentTarget then
                logger:info("No valid events found, clearing current target")
                currentTarget = nil
            end
            restoreToSavedPosition()
            return
        end

        if (not currentTarget) or (currentTarget.model ~= best.model) or (currentTarget.propsName ~= best.propsName) then
            logger:info("Switching to new target:", best.name)
            teleportToTarget(best)
        end
    end)
end

-- ===== Lifecycle =====
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
                    teleportToTarget(currentTarget)
                end
            end)
        end
    end)

    setupWorkspaceMonitoring()
    logger:info("Initialized successfully")
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

    logger:info("Starting with events:", table.concat(selectedPriorityList, ", "))

    local best = chooseBestActiveEvent()
    if best then
        teleportToTarget(best)
    else
        logger:info("No initial target found")
    end

    startLoop()
    logger:info("Started successfully")
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
    table.clear(lastKnownActiveProps)
    logger:info("Stopped and restored position")
    return true
end

function AutoTeleportEvent:Cleanup()
    self:Stop()
    if charConn         then charConn:Disconnect();         charConn = nil end
    if propsAddedConn   then propsAddedConn:Disconnect();   propsAddedConn = nil end
    if propsRemovedConn then propsRemovedConn:Disconnect(); propsRemovedConn = nil end
    if workspaceConn    then workspaceConn:Disconnect();    workspaceConn = nil end
    if notificationConn then notificationConn:Disconnect(); notificationConn = nil end

    for propsFolder, conn in pairs(monitoredPropsConns) do
        if conn then conn:Disconnect() end
    end
    table.clear(monitoredPropsConns)

    eventsFolder = nil
    table.clear(validEventName)
    table.clear(selectedPriorityList)
    table.clear(selectedSet)
    table.clear(lastKnownActiveProps)
    table.clear(notifiedEvents)
    savedPosition = nil
    currentTarget = nil

    logger:info("Cleanup completed")
    return true
end

-- ===== Setters =====
function AutoTeleportEvent:SetSelectedEvents(selected)
    table.clear(selectedPriorityList)
    table.clear(selectedSet)

    if type(selected) == "table" then
        if #selected > 0 then
            for _, v in ipairs(selected) do
                local key = normName(v)
                table.insert(selectedPriorityList, key)
                selectedSet[key] = true
            end
            logger:info("Priority events set:", table.concat(selectedPriorityList, ", "))
        else
            for k, on in pairs(selected) do
                if on then
                    local key = normName(k)
                    selectedSet[key] = true
                end
            end
        end
    end
    return true
end

function AutoTeleportEvent:SetHoverHeight(h)
    if type(h) == "number" then
        hoverHeight = math.clamp(h, 5, 100)
        if running and currentTarget then
            local _, hrp = ensureCharacter()
            if hrp then
                local desired = currentTarget.pos + Vector3.new(0, hoverHeight, 0)
                local bp = ensureHoverBP(hrp)
                if bp then
                    bp.Position = desired
                else
                    setCFrameSafely(hrp, desired)
                end
            end
        end
        return true
    end
    return false
end

function AutoTeleportEvent:Status()
    return {
        running       = running,
        hover         = hoverHeight,
        hasSavedPos   = savedPosition ~= nil,
        target        = currentTarget and currentTarget.name or nil,
        activeProps   = lastKnownActiveProps,
        notifications = notifiedEvents
    }
end

function AutoTeleportEvent.new()
    local self = setmetatable({}, AutoTeleportEvent)
    return self
end

return AutoTeleportEvent
