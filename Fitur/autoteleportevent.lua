--========================================================
-- Feature: AutoTeleportEvent (Fixed v4)
--========================================================

local AutoTeleportEvent = {}
AutoTeleportEvent.__index = AutoTeleportEvent

local logger = _G.Logger and _G.Logger.new("AutoTeleportEvent") or {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end
}

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- ===== State =====
local running          = false
local hbConn           = nil         -- polling ringan
local charConn         = nil
local propsAddedConn   = nil         -- jika Props di-recreate
local propsRemovedConn = nil         -- detect props removal
local workspaceConn    = nil         -- scan workspace changes
local notificationConn = nil         -- listener untuk event notification
local eventsFolder     = nil         -- ReplicatedStorage.Events

local selectedPriorityList = {}      -- <<< urutan prioritas (array)
local selectedSet           = {}     -- untuk cocokkan cepat (dict)
local hoverHeight           = 15
local savedPosition         = nil    -- HARD save position before any teleport
local currentTarget         = nil    -- { model, name, nameKey, pos, propsName }
local lastKnownActiveProps  = {}     -- track active props for cleanup detection
local notifiedEvents        = {}     -- track events dari notifikasi

-- Cache nama event valid (dari ReplicatedStorage.Events)
local validEventName = {}            -- set of normName

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

-- ===== Save Position Before First Teleport =====
local function saveCurrentPosition()
    if savedPosition then return end -- already saved
    local _, hrp = ensureCharacter()
    if hrp then
        savedPosition = hrp.CFrame
        logger:info("Position saved at:", tostring(savedPosition.Position))
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
end

-- ===== Setup Event Notification Listener =====
local function setupEventNotificationListener()
    if notificationConn then notificationConn:Disconnect() end
    
    -- Cari RE/TextNotification
    local textNotificationRE = nil
    local packagesFolder = ReplicatedStorage:FindFirstChild("Packages")
    
    if packagesFolder then
        -- Cari path: Packages._Index["sleitnick_net@0.2.0"].net["RE/TextNotification"]
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
        logger:info("Found TextNotification RE, setting up listener")
        notificationConn = textNotificationRE.OnClientEvent:Connect(function(data)
            if type(data) == "table" and data.Type == "Event" and data.Text then
                local eventName = data.Text
                local eventKey = normName(eventName)
                
                logger:info("Event notification received:", eventName)
                
                -- Simpan ke notified events untuk membantu matching
                notifiedEvents[eventKey] = {
                    name = eventName,
                    timestamp = os.clock()
                }
                
                -- Clean up old notifications (older than 5 minutes)
                for key, info in pairs(notifiedEvents) do
                    if os.clock() - info.timestamp > 300 then
                        notifiedEvents[key] = nil
                    end
                end
                
                -- Trigger immediate scan jika sedang running
                if running then
                    task.spawn(function()
                        task.wait(1) -- Wait a bit for the event to spawn in workspace
                        -- Force scan on next heartbeat
                    end)
                end
            end
        end)
    else
        logger:warn("Could not find TextNotification RE")
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

-- ===== Enhanced Event Detection =====
local function isEventModel(model, propsName)
    if not model:IsA("Model") then return false end
    
    local modelName = model.Name
    local modelKey = normName(modelName)
    
    -- 1. Check against ReplicatedStorage.Events
    if validEventName[modelKey] then
        return true, modelName, modelKey
    end
    
    -- 2. Check against recent notifications dengan fuzzy matching
    for notifKey, notifInfo in pairs(notifiedEvents) do
        -- Exact match
        if modelKey == notifKey then
            return true, notifInfo.name, modelKey
        end
        
        -- Fuzzy matching - check if either contains the other
        if modelKey:find(notifKey, 1, true) or notifKey:find(modelKey, 1, true) then
            return true, notifInfo.name, modelKey
        end
        
        -- Special cases for common name variations
        -- "Model" -> could be any recent event
        if modelName == "Model" and os.clock() - notifInfo.timestamp < 30 then
            return true, notifInfo.name, modelKey
        end
    end
    
    -- 3. Common event patterns
    local eventPatterns = {
        "hunt", "boss", "raid", "event", "invasion", "attack", 
        "storm", "hole", "meteor", "comet", "shark", "worm"
    }
    
    for _, pattern in ipairs(eventPatterns) do
        if modelKey:find(pattern, 1, true) then
            return true, modelName, modelKey
        end
    end
    
    return false
end

-- ===== Scan All Props in Workspace (FIXED: Direct children only) =====
local function scanAllActiveProps()
    local activePropsList = {}
    
    -- Scan semua child di Workspace yang nama mengandung "Props" atau langsung bernama Props
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            local childName = child.Name
            if childName == "Props" or childName:find("Props") then
                -- Ini adalah Props folder, scan DIRECT CHILDREN saja (bukan descendants)
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
                                    propsName = childName -- track which props this belongs to
                                })
                                logger:info("Found event:", eventName, "in", childName)
                            end
                        end
                    end
                end
            end
        end
    end
    
    return activePropsList
end

-- ===== Match terhadap pilihan user =====
local function matchesSelection(nameKey, displayName)
    if #selectedPriorityList == 0 then return true end -- user tidak memilih apa-apa -> semua boleh
    
    -- Check against both nameKey and displayName
    for _, selKey in ipairs(selectedPriorityList) do
        -- Match dengan nameKey
        if nameKey:find(selKey, 1, true) or selKey:find(nameKey, 1, true) then
            return true
        end
        
        -- Match dengan display name
        local displayKey = normName(displayName)
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
        
        local displayKey = normName(displayName)
        if displayKey:find(selKey, 1, true) or selKey:find(displayKey, 1, true) then
            return i
        end
    end
    return math.huge
end

-- ===== Choose Best =====
local function chooseBestActiveEvent()
    local actives = scanAllActiveProps()
    if #actives == 0 then return nil end

    -- filter sesuai pilihan user jika ada
    local filtered = {}
    if #selectedPriorityList > 0 then
        for _, a in ipairs(actives) do
            if matchesSelection(a.nameKey, a.name) then
                table.insert(filtered, a)
            end
        end
        actives = filtered
        if #actives == 0 then
            -- tidak ada event TERPILIH yang aktif -> jangan teleport ke event lain
            return nil
        end
    end

    for _, a in ipairs(actives) do
        a.rank = rankOf(a.nameKey, a.name)
    end

    table.sort(actives, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        -- stabil
        return a.name < b.name
    end)

    return actives[1]
end

-- ===== Teleport / Return =====
local function teleportToTarget(target)
    local _, hrp = ensureCharacter()
    if not hrp then return false, "NO_HRP" end
    
    -- Save position before first teleport
    saveCurrentPosition()
    
    local tpPos = target.pos + Vector3.new(0, hoverHeight, 0)
    setCFrameSafely(hrp, tpPos)
    logger:info("Teleported to:", target.name, "at", tostring(target.pos))
    return true
end

local function restoreToSavedPosition()
    if not savedPosition then 
        logger:info("No saved position to restore")
        return 
    end
    
    local _, hrp = ensureCharacter()
    if hrp then
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        logger:info("Restored to saved position:", tostring(savedPosition.Position))
    end
end

local function maintainHover()
    local _, hrp = ensureCharacter()
    if hrp and currentTarget then
        -- Check if target still exists
        if not currentTarget.model or not currentTarget.model.Parent then
            logger:info("Current target no longer exists, clearing")
            currentTarget = nil
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

-- ===== Track Active Props =====
local function updateActivePropsTracking()
    local newActiveProps = {}
    local activeEvents = scanAllActiveProps()
    
    for _, event in ipairs(activeEvents) do
        newActiveProps[event.propsName] = true
    end
    
    -- Check for removed props
    for propsName, _ in pairs(lastKnownActiveProps) do
        if not newActiveProps[propsName] then
            logger:info("Props removed:", propsName)
            -- If current target was from this props, clear it
            if currentTarget and currentTarget.propsName == propsName then
                logger:info("Current target props removed, clearing target")
                currentTarget = nil
            end
        end
    end
    
    lastKnownActiveProps = newActiveProps
end

-- ===== Loop =====
local function startLoop()
    if hbConn then hbConn:Disconnect() end
    local lastTick = 0
    hbConn = RunService.Heartbeat:Connect(function()
        if not running then return end
        local now = os.clock()
        
        -- Maintain hover more frequently
        maintainHover()
        
        if now - lastTick < 0.3 then -- throttle main logic
            return
        end
        lastTick = now

        -- Update tracking and scan for events
        updateActivePropsTracking()
        local best = chooseBestActiveEvent()

        if not best then
            -- tidak ada event terpilih (atau tidak ada event sama sekali)
            if currentTarget then
                logger:info("No valid events found, clearing current target")
                currentTarget = nil
            end
            -- Always return to saved position when no valid events
            restoreToSavedPosition()
            return
        end

        -- Check if we need to switch targets
        if (not currentTarget) or (currentTarget.model ~= best.model) or (currentTarget.propsName ~= best.propsName) then
            logger:info("Switching to new target:", best.name)
            teleportToTarget(best)
            currentTarget = best
        end
    end)
end

-- ===== Setup Workspace Monitoring =====
local function setupWorkspaceMonitoring()
    -- Clean up existing connections
    if propsAddedConn then propsAddedConn:Disconnect() end
    if propsRemovedConn then propsRemovedConn:Disconnect() end
    if workspaceConn then workspaceConn:Disconnect() end
    
    -- Monitor for new Props being added
    propsAddedConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            logger:info("New Props detected:", child.Name)
            task.wait(0.5) -- Wait a bit for props to be fully loaded
            -- Force immediate scan on next loop iteration
        end
    end)
    
    -- Monitor for Props being removed
    propsRemovedConn = Workspace.ChildRemoved:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            logger:info("Props removed:", child.Name)
            -- Update tracking immediately
            if lastKnownActiveProps[child.Name] then
                lastKnownActiveProps[child.Name] = nil
                if currentTarget and currentTarget.propsName == child.Name then
                    logger:info("Current target props removed")
                    currentTarget = nil
                end
            end
        end
    end)
    
    -- Monitor for direct children added to Props (FIXED: bukan descendants)
    workspaceConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            local propsFolder = child
            -- Monitor direct children of this props folder
            propsFolder.ChildAdded:Connect(function(propsChild)
                if propsChild:IsA("Model") then
                    task.wait(0.1) -- Small delay to let it fully load
                    logger:info("New model added to", propsFolder.Name, ":", propsChild.Name)
                end
            end)
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
        -- Reset saved position on character respawn
        savedPosition = nil
        if running and currentTarget then
            task.defer(function()
                task.wait(0.5) -- Wait for character to fully load
                -- Re-save position and teleport if we have a target
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

    -- Reset state
    currentTarget = nil
    savedPosition = nil
    table.clear(lastKnownActiveProps)
    
    logger:info("Starting with events:", table.concat(selectedPriorityList, ", "))
    
    -- Try to find and teleport to initial target
    local best = chooseBestActiveEvent()
    if best then
        teleportToTarget(best)
        currentTarget = best
        logger:info("Initial target found:", best.name)
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

    -- Always restore to saved position when stopping
    if savedPosition then
        restoreToSavedPosition()
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
            -- ARRAY: pertahankan urutan prioritas
            for _, v in ipairs(selected) do
                local key = normName(v)
                table.insert(selectedPriorityList, key)
                selectedSet[key] = true
            end
            logger:info("Priority events set:", table.concat(selectedPriorityList, ", "))
        else
            -- DICT/SET: tanpa urutan → pakai set saja
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
                setCFrameSafely(hrp, desired)
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
