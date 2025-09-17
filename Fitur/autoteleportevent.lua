--========================================================
-- AutoTeleportEvent vFINAL (Optimized, longer thinking)
-- - Prioritize marker/indicator position (bulatan/efek) over ship pivot
-- - Robust fallback logic (GetPivot / PrimaryPart / BoundingBox)
-- - Smart water finding with radius sampling
-- - Prioritized + nearest selection, notifications support
-- - Stable hover using BodyPosition, proper cleanup
--========================================================

local AutoTeleportEvent = {}
AutoTeleportEvent.__index = AutoTeleportEvent

-- Services
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

-- Logger (optional global)
local logger = _G.Logger and _G.Logger.new("AutoTeleportEvent") or {
    debug = function(...) print("[AutoTeleportEvent][DEBUG]", ...) end,
    info  = function(...) print("[AutoTeleportEvent][INFO]", ...) end,
    warn  = function(...) print("[AutoTeleportEvent][WARN]", ...) end,
    error = function(...) print("[AutoTeleportEvent][ERROR]", ...) end,
}

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

local selectedPriorityList = {}   -- ordered priorities
local selectedSet           = {}  -- fast lookup
local hoverHeight           = 15
local savedPosition         = nil -- CFrame saved
local currentTarget         = nil -- { model, name, nameKey, pos, propsName }
local lastKnownActiveProps  = {}
local notifiedEvents        = {}  -- recent notifications (key -> {name, timestamp})

local validEventName = {} -- cached event names from ReplicatedStorage.Events

-- ===== Utils =====
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

local function setCFrameSafely(hrp, targetPos, keepLookAt)
    -- keepLookAt expected to be a Vector3 position (world)
    local look = keepLookAt or (hrp.CFrame.LookVector + hrp.Position)
    hrp.AssemblyLinearVelocity = Vector3.new()
    hrp.AssemblyAngularVelocity = Vector3.new()
    -- keep Y of look at same as targetPos for level facing
    local lookPoint = Vector3.new(look.X, targetPos.Y, look.Z)
    hrp.CFrame = CFrame.lookAt(targetPos, lookPoint)
end

-- ===== Hover BodyPosition helpers =====
local HOVER_BP_NAME = "AutoTeleport_HoverBP"

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

-- ===== Save Position =====
local function saveCurrentPosition()
    if savedPosition then return end
    local _, hrp = ensureCharacter()
    if hrp then
        -- Save full CFrame to restore orientation and position later
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
        -- Use saved CFrame for full restoration
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        hrp.AssemblyLinearVelocity = Vector3.new()
        hrp.AssemblyAngularVelocity = Vector3.new()
        logger.info("Restored to saved position:", tostring(savedPosition.Position))
    end
end

-- ===== Index Events from ReplicatedStorage.Events =====
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
    logger.debug("Indexed events:", table.concat((function()
        local t = {}
        for k,_ in pairs(validEventName) do table.insert(t,k) end
        return t
    end)(), ", "))
end

-- ===== Setup Event Notification Listener =====
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
        logger.info("Found TextNotification RE, setting up listener")
        notificationConn = textNotificationRE.OnClientEvent:Connect(function(data)
            if type(data) == "table" and data.Type == "Event" and data.Text then
                local eventName = data.Text
                local eventKey = normName(eventName)
                logger.info("Event notification received:", eventName)
                notifiedEvents[eventKey] = { name = eventName, timestamp = os.clock() }
                -- clean old
                for key, info in pairs(notifiedEvents) do
                    if os.clock() - info.timestamp > 300 then
                        notifiedEvents[key] = nil
                    end
                end
                -- quick scan next tick (heartbeat loop handles it)
            end
        end)
    else
        logger.warn("Could not find TextNotification RE")
    end
end

-- ===== Resolve Model Pivot (fallbacks) =====
local function resolveModelPivotPos(model)
    if not model then return nil end
    local ok, cf = pcall(function() return model:GetPivot() end)
    if ok and typeof(cf) == "CFrame" then return cf.Position end
    local ok2, cf2 = pcall(function() return model.WorldPivot end)
    if ok2 and typeof(cf2) == "CFrame" then return cf2.Position end
    if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
        return model.PrimaryPart.Position
    end
    -- fallback to bounding box centre
    local ok3, cframe, size = pcall(function() return model:GetBoundingBox() end)
    if ok3 and typeof(cframe) == "CFrame" then
        return cframe.Position
    end
    return nil
end

-- ===== Enhanced Resolve Event Center (marker-first) =====
local function resolveEventCenterPos(model)
    if not model then return nil end

    local function hasVisualIndicator(part)
        -- choose parts that likely represent the event center
        local name = tostring(part.Name):lower()
        if name:find("ring") or name:find("circle") or name:find("indicator") or name:find("marker")
        or name:find("center") or name:find("hitbox") or name:find("spawn") or name:find("area") then
            return true
        end
        -- presence of particle emitters, lights, or guis attached to this part is also a good sign
        if part:FindFirstChildOfClass("ParticleEmitter") or part:FindFirstChildOfClass("PointLight") then
            return true
        end
        if part:FindFirstChild("BillboardGui") or part:FindFirstChild("SurfaceGui") then
            return true
        end
        return false
    end

    -- 1) Search descendants for well-named/visual indicator BasePart
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") then
            if hasVisualIndicator(desc) then
                return (desc:GetPivot and desc:GetPivot().Position) or desc.Position
            end
        elseif desc:IsA("Attachment") then
            local nm = tostring(desc.Name):lower()
            if nm:find("center") or nm:find("marker") or nm:find("spawn") then
                return desc.WorldPosition
            end
        end
    end

    -- 2) Check immediate parent folder siblings (sometimes marker is sibling of model)
    local parent = model.Parent
    if parent then
        for _, sib in ipairs(parent:GetChildren()) do
            if sib ~= model then
                if sib:IsA("BasePart") and hasVisualIndicator(sib) then
                    return (sib.GetPivot and sib:GetPivot().Position) or sib.Position
                end
                if sib:IsA("Model") then
                    -- check first-level children only
                    for _, c in ipairs(sib:GetChildren()) do
                        if c:IsA("BasePart") and hasVisualIndicator(c) then
                            return (c.GetPivot and c:GetPivot().Position) or c.Position
                        end
                    end
                end
            end
        end
    end

    -- 3) If we have a recent notification matching model name, use model pivot (it is likely the right one)
    local mKey = normName(model.Name)
    if notifiedEvents[mKey] then
        local pivot = resolveModelPivotPos(model)
        if pivot then return pivot end
    end

    -- 4) fallback to pivot/bounding box primary part
    return resolveModelPivotPos(model)
end

-- ===== Smart Water-finding helpers =====
local function findBestWaterPosition(centerPos)
    -- radius search with raycasts downward, prefer water material
    local maxRadius = 30
    local radii = {0, 2, 4, 6, 10, 15, 20, 30}
    local samplesPerRadius = 8
    local rayUp = 60
    local rayDown = 300
    local best = nil
    local bestDist = math.huge

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    -- avoid hitting local character
    local char = LocalPlayer.Character
    if char then
        params.FilterDescendantsInstances = {char}
    else
        params.FilterDescendantsInstances = {}
    end
    params.IgnoreWater = false

    for _, r in ipairs(radii) do
        local stepCount = (r == 0) and 1 or samplesPerRadius
        for i = 0, stepCount - 1 do
            local offset = Vector3.new(0,0,0)
            if r ~= 0 then
                local theta = (i / stepCount) * math.pi * 2
                offset = Vector3.new(math.cos(theta) * r, 0, math.sin(theta) * r)
            end
            local origin = Vector3.new(centerPos.X + offset.X, centerPos.Y + rayUp, centerPos.Z + offset.Z)
            local dir = Vector3.new(0, -rayDown, 0)
            local res = Workspace:Raycast(origin, dir, params)
            if res and res.Position then
                local mat = res.Material
                if mat == Enum.Material.Water then
                    local candidate = res.Position
                    local d = (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(centerPos.X, 0, centerPos.Z)).Magnitude
                    if d < bestDist then
                        best = candidate
                        bestDist = d
                    end
                else
                    -- On terrain, raycast may still return water-like info occasionally; skip other materials
                end
            end
        end
        if best then return best end
    end

    -- if not found, fallback to centerPos (safe)
    return centerPos
end

-- ===== Enhanced Event Detection (from v4) =====
local function isEventModel(model, propsName)
    if not model or not model:IsA("Model") then return false end
    local modelName = model.Name
    local modelKey = normName(modelName)

    -- 1. Check against ReplicatedStorage.Events
    if validEventName[modelKey] then
        return true, modelName, modelKey
    end

    -- 2. Check against notifiedEvents fuzzy
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
    local eventPatterns = {
        "hunt","boss","raid","event","invasion","attack",
        "storm","hole","meteor","comet","shark","worm"
    }
    for _, pattern in ipairs(eventPatterns) do
        if modelKey:find(pattern, 1, true) then
            return true, modelName, modelKey
        end
    end

    return false
end

-- ===== Scan All Props in Workspace (direct children of Props) =====
local function scanAllActiveProps()
    local activePropsList = {}

    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            local childName = child.Name
            if childName == "Props" or childName:find("Props") then
                for _, directChild in ipairs(child:GetChildren()) do
                    if directChild:IsA("Model") then
                        local model = directChild
                        local isEvent, eventName, eventKey = isEventModel(model, childName)
                        if isEvent then
                            local pos = resolveEventCenterPos(model)
                            if pos then
                                table.insert(activePropsList, {
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

    return activePropsList
end

-- ===== User selection matching & ranking =====
local function matchesSelection(nameKey, displayName)
    if #selectedPriorityList == 0 and next(selectedSet) == nil then return true end
    local displayKey = normName(displayName or "")
    for _, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return true
        end
        if displayKey:find(selKey, 1, true) or selKey:find(displayKey, 1, true) then
            return true
        end
    end
    for selKey, on in pairs(selectedSet) do
        if on and (nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) or displayKey:find(selKey, 1, true)) then
            return true
        end
    end
    return false
end

local function rankOf(nameKey, displayName)
    for i, selKey in ipairs(selectedPriorityList) do
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then return i end
        local displayKey = normName(displayName or "")
        if displayKey:find(selKey, 1, true) or selKey:find(displayKey, 1, true) then return i end
    end
    return math.huge
end

-- ===== Choose Best Active Event (prioritize selected then nearest to player) =====
local function chooseBestActiveEvent()
    local actives = scanAllActiveProps()
    if #actives == 0 then return nil end

    -- filter by selection
    local filtered = {}
    for _, a in ipairs(actives) do
        if matchesSelection(a.nameKey, a.name) then
            table.insert(filtered, a)
        end
    end
    actives = filtered
    if #actives == 0 then return nil end

    -- add rank (from priority list) and distance
    local char, hrp = ensureCharacter()
    local playerPos = hrp and hrp.Position or (char and char:GetModelCFrame().p) or Vector3.new()
    for _, a in ipairs(actives) do
        a.rank = rankOf(a.nameKey, a.name)
        a.dist = (a.pos - playerPos).Magnitude
    end

    -- sort: by rank first, then distance, then name stable
    table.sort(actives, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.dist ~= b.dist then return a.dist < b.dist end
        return a.name < b.name
    end)

    return actives[1]
end

-- ===== Teleport / Hover behavior =====
local function teleportToTarget(target)
    local _, hrp = ensureCharacter()
    if not hrp then return false, "NO_HRP" end

    -- save before first teleport
    saveCurrentPosition()

    -- robust target center: target.pos already resolved earlier
    local center = target.pos
    -- find water landing (prefer water under/near the indicator)
    local landing = findBestWaterPosition(center) or center
    local tpPos = landing + Vector3.new(0, hoverHeight, 0)

    -- set CFrame and face the landing (water/center) so throws aim at water
    setCFrameSafely(hrp, tpPos, landing)

    -- ensure hover BP to maintain stable hover
    local bp = ensureHoverBP(hrp)
    if bp then bp.Position = tpPos end

    logger.info("Teleported to:", target.name, "center:", tostring(center), "landing:", tostring(landing))
    return true
end

-- ===== Maintain Hover each heartbeat =====
local function maintainHover()
    local _, hrp = ensureCharacter()
    if not hrp then return end
    if currentTarget and currentTarget.pos then
        -- if model disappears, clear target
        if not currentTarget.model or not currentTarget.model.Parent then
            logger.info("Current target missing, clearing")
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

-- ===== Track Active Props (for cleanup) =====
local function updateActivePropsTracking()
    local newActive = {}
    local activeEvents = scanAllActiveProps()
    for _, ev in ipairs(activeEvents) do
        newActive[ev.propsName] = true
    end
    for propsName, _ in pairs(lastKnownActiveProps) do
        if not newActive[propsName] then
            logger.info("Props removed:", propsName)
            if currentTarget and currentTarget.propsName == propsName then
                logger.info("Current target removed, clearing target")
                currentTarget = nil
            end
        end
    end
    lastKnownActiveProps = newActive
end

-- ===== Main loop (Heartbeat) =====
local function startLoop()
    if hbConn then hbConn:Disconnect() end
    local lastTick = 0
    hbConn = RunService.Heartbeat:Connect(function()
        if not running then return end
        local now = os.clock()
        -- maintain hover frequently
        pcall(maintainHover)
        if now - lastTick < 0.35 then return end
        lastTick = now

        pcall(updateActivePropsTracking)
        local best = pcall(function() return chooseBestActiveEvent() end) and chooseBestActiveEvent() or nil
        if not best then
            if currentTarget then
                logger.info("No valid events, clearing current target")
                currentTarget = nil
            end
            -- always return to saved when nothing active
            pcall(restoreToSavedPosition)
            return
        end

        if (not currentTarget) or (currentTarget.model ~= best.model) or (currentTarget.propsName ~= best.propsName) then
            logger.info("Switching to new target:", best.name)
            local ok, err = pcall(function() teleportToTarget(best) end)
            if not ok then
                logger.error("Teleport failed:", tostring(err))
            else
                currentTarget = best
            end
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

    -- Monitor direct children added to Props
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

-- ===== Lifecycle functions =====
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

    logger.info("Starting with events:", table.concat(selectedPriorityList, ", "))
    -- initial attempt
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
    table.clear(lastKnownActiveProps)
    logger.info("Stopped and restored position")
    return true
end

function AutoTeleportEvent:Cleanup()
    self:Stop()
    if charConn         then charConn:Disconnect();         charConn = nil end
    if propsAddedConn   then propsAddedConn:Disconnect();   propsAddedConn = nil end
    if propsRemovedConn then propsRemovedConn:Disconnect(); propsRemovedConn = nil end
    if workspaceConn    then workspaceConn:Disconnect();    workspaceConn = nil end
    if notificationConn then notificationConn:Disconnect(); notificationConn = nil end

    eventsFolder = nil
    table.clear(validEventName)
    table.clear(selectedPriorityList)
    table.clear(selectedSet)
    table.clear(lastKnownActiveProps)
    table.clear(notifiedEvents)
    savedPosition = nil
    currentTarget = nil

    logger.info("Cleanup completed")
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
            logger.info("Priority events set:", table.concat(selectedPriorityList, ", "))
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
        notifications = notifiedEvents,
    }
end

function AutoTeleportEvent.new()
    local self = setmetatable({}, AutoTeleportEvent)
    return self
end

return AutoTeleportEvent
