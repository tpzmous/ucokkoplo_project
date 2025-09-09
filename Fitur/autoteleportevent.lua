--========================================================
-- Feature: AutoTeleportEvent (Fixed v3)
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
local hbConn           = nil         -- polling ringan
local charConn         = nil
local propsAddedConn   = nil         -- jika Props di-recreate
local propsRemovedConn = nil         -- detect props removal
local workspaceConn    = nil         -- scan workspace changes
local eventsFolder     = nil         -- ReplicatedStorage.Events

local selectedPriorityList = {}      -- <<< urutan prioritas (array)
local selectedSet           = {}     -- untuk cocokkan cepat (dict)
local hoverHeight           = 15
local savedPosition         = nil    -- HARD save position before any teleport
local currentTarget         = nil    -- { model, name, nameKey, pos, propsName }
local lastKnownActiveProps  = {}     -- track active props for cleanup detection

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
        print("[AutoTeleportEvent] Position saved at:", tostring(savedPosition.Position))
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

-- ===== Resolve Model Pivot =====
local function resolveModelPivotPos(model)
    local ok, cf = pcall(function() return model:GetPivot() end)
    if ok and typeof(cf) == "CFrame" then return cf.Position end
    local ok2, cf2 = pcall(function() return model.WorldPivot end)
    if ok2 and typeof(cf2) == "CFrame" then return cf2.Position end
    return nil
end

-- ===== Scan All Props in Workspace =====
local function scanAllActiveProps()
    local activePropsList = {}
    
    -- Scan semua child di Workspace yang nama mengandung "Props" atau langsung bernama Props
    for _, child in ipairs(Workspace:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            local childName = child.Name
            if childName == "Props" or childName:find("Props") then
                -- Ini adalah Props folder, scan isinya
                for _, desc in ipairs(child:GetDescendants()) do
                    if desc:IsA("Model") then
                        local model = desc
                        local mKey = normName(model.Name)
                        local pKey = model.Parent and normName(model.Parent.Name) or nil
                        
                        local isEventish = 
                            (validEventName[mKey] == true) or
                            (pKey and validEventName[pKey] == true)
                        
                        if isEventish then
                            local pos = resolveModelPivotPos(model)
                            if pos then
                                local repName = model.Parent and model.Parent.Name or model.Name
                                table.insert(activePropsList, {
                                    model     = model,
                                    name      = repName,
                                    nameKey   = normName(repName),
                                    pos       = pos,
                                    propsName = childName -- track which props this belongs to
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

-- ===== Match terhadap pilihan user =====
local function matchesSelection(nameKey)
    if #selectedPriorityList == 0 then return true end -- user tidak memilih apa-apa -> semua boleh
    -- "contains" match dua arah supaya toleran variasi nama
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

-- ===== Choose Best =====
local function chooseBestActiveEvent()
    local actives = scanAllActiveProps()
    if #actives == 0 then return nil end

    -- filter sesuai pilihan user jika ada
    local filtered = {}
    if #selectedPriorityList > 0 then
        for _, a in ipairs(actives) do
            if matchesSelection(a.nameKey) then
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
        a.rank = rankOf(a.nameKey)
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
    print("[AutoTeleportEvent] Teleported to:", target.name, "at", tostring(target.pos))
    return true
end

local function restoreToSavedPosition()
    if not savedPosition then 
        print("[AutoTeleportEvent] No saved position to restore")
        return 
    end
    
    local _, hrp = ensureCharacter()
    if hrp then
        setCFrameSafely(hrp, savedPosition.Position, savedPosition.Position + savedPosition.LookVector)
        print("[AutoTeleportEvent] Restored to saved position:", tostring(savedPosition.Position))
    end
end

local function maintainHover()
    local _, hrp = ensureCharacter()
    if hrp and currentTarget then
        -- Check if target still exists
        if not currentTarget.model or not currentTarget.model.Parent then
            print("[AutoTeleportEvent] Current target no longer exists, clearing")
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
            print("[AutoTeleportEvent] Props removed:", propsName)
            -- If current target was from this props, clear it
            if currentTarget and currentTarget.propsName == propsName then
                print("[AutoTeleportEvent] Current target props removed, clearing target")
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
                print("[AutoTeleportEvent] No valid events found, clearing current target")
                currentTarget = nil
            end
            -- Always return to saved position when no valid events
            restoreToSavedPosition()
            return
        end

        -- Check if we need to switch targets
        if (not currentTarget) or (currentTarget.model ~= best.model) or (currentTarget.propsName ~= best.propsName) then
            print("[AutoTeleportEvent] Switching to new target:", best.name)
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
            print("[AutoTeleportEvent] New Props detected:", child.Name)
            task.wait(0.5) -- Wait a bit for props to be fully loaded
            -- Force immediate scan on next loop iteration
        end
    end)
    
    -- Monitor for Props being removed
    propsRemovedConn = Workspace.ChildRemoved:Connect(function(child)
        if child.Name == "Props" or child.Name:find("Props") then
            print("[AutoTeleportEvent] Props removed:", child.Name)
            -- Update tracking immediately
            if lastKnownActiveProps[child.Name] then
                lastKnownActiveProps[child.Name] = nil
                if currentTarget and currentTarget.propsName == child.Name then
                    print("[AutoTeleportEvent] Current target props removed")
                    currentTarget = nil
                end
            end
        end
    end)
    
    -- General workspace monitoring for any changes
    workspaceConn = Workspace.DescendantAdded:Connect(function(desc)
        if desc:IsA("Model") and desc.Parent and (desc.Parent.Name == "Props" or desc.Parent.Name:find("Props")) then
            -- New event model added
            task.wait(0.1) -- Small delay to let it fully load
        end
    end)
end

-- ===== Lifecycle =====
function AutoTeleportEvent:Init(gui)
    eventsFolder = ReplicatedStorage:FindFirstChild("Events") or waitChild(ReplicatedStorage, "Events", 5)
    indexEvents()

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

    -- Reset state
    currentTarget = nil
    savedPosition = nil
    table.clear(lastKnownActiveProps)
    
    print("[AutoTeleportEvent] Starting with events:", table.concat(selectedPriorityList, ", "))
    
    -- Try to find and teleport to initial target
    local best = chooseBestActiveEvent()
    if best then
        teleportToTarget(best)
        currentTarget = best
        print("[AutoTeleportEvent] Initial target found:", best.name)
    else
        print("[AutoTeleportEvent] No initial target found")
    end

    startLoop()
    print("[AutoTeleportEvent] Started successfully")
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
    print("[AutoTeleportEvent] Stopped and restored position")
    return true
end

function AutoTeleportEvent:Cleanup()
    self:Stop()
    if charConn         then charConn:Disconnect();         charConn = nil end
    if propsAddedConn   then propsAddedConn:Disconnect();   propsAddedConn = nil end
    if propsRemovedConn then propsRemovedConn:Disconnect(); propsRemovedConn = nil end
    if workspaceConn    then workspaceConn:Disconnect();    workspaceConn = nil end
    
    eventsFolder = nil
    table.clear(validEventName)
    table.clear(selectedPriorityList)
    table.clear(selectedSet)
    table.clear(lastKnownActiveProps)
    savedPosition = nil
    currentTarget = nil
    
    print("[AutoTeleportEvent] Cleanup completed")
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
            print("[AutoTeleportEvent] Priority events set:", table.concat(selectedPriorityList, ", "))
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
        running     = running,
        hover       = hoverHeight,
        hasSavedPos = savedPosition ~= nil,
        target      = currentTarget and currentTarget.name or nil,
        activeProps = lastKnownActiveProps
    }
end

function AutoTeleportEvent.new()
    local self = setmetatable({}, AutoTeleportEvent)
    return self
end

return AutoTeleportEvent