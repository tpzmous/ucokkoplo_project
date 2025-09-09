-- WindUI Library
local WindUI = loadstring(game:HttpGet(
    "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"
))()

-- ===========================
-- GLOBAL SERVICES & VARIABLES
-- ===========================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

-- Make global for features to access
_G.GameServices = {
    Players = Players,
    ReplicatedStorage = ReplicatedStorage,
    RunService = RunService,
    LocalPlayer = LocalPlayer,
    HttpService = HttpService
}

-- Safe network path access
local NetPath = nil
pcall(function()
    NetPath = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("_Index"):WaitForChild("sleitnick_net@0.2.0"):WaitForChild("net")
end)
_G.NetPath = NetPath

-- ===========================
-- FEATURE MANAGER
-- ===========================
local FeatureManager = {}
FeatureManager.LoadedFeatures = {}

local FEATURE_URLS = {
    AutoFish           = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/autofish.lua", 
    AutoSellFish       = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/autosellfish.lua",
    AutoTeleportIsland = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/autoteleportisland.lua",
    FishWebhook        = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/fishwebhook.lua",
    AutoBuyWeather     = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/autobuyweather.lua",
    AutoBuyBait        = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/autobuybait.lua",
    AutoBuyRod         = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/autobuyrod.lua",
    AutoTeleportEvent  = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/autoteleportevent.lua",
    AutoGearOxyRadar   = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/autogearoxyradar.lua",
    AntiAfk            = "https://raw.githubusercontent.com/hailazra/devlogic/refs/heads/main/Fish-It/antiafk.lua"
}

function FeatureManager:LoadFeature(featureName, controls)
    local url = FEATURE_URLS[featureName]
    if not url then 
        WindUI:Notify({
            Title = "Error",
            Content = "Feature " .. featureName .. " URL not found",
            Icon = "x",
            Duration = 3
        })
        return nil 
    end

    local success, feature = pcall(function()
        return loadstring(game:HttpGet(url))()
    end)

    if success and type(feature) == "table" and feature.Init then
        local initSuccess = pcall(feature.Init, feature, controls)
        if initSuccess then
            self.LoadedFeatures[featureName] = feature
            WindUI:Notify({
                Title = "Success",
                Content = featureName .. " loaded successfully",
                Icon = "check",
                Duration = 2
            })
            return feature
        end
    end
    
    WindUI:Notify({
        Title = "Load Failed",
        Content = "Could not load " .. featureName,
        Icon = "x",
        Duration = 3
    })
    return nil
end

function FeatureManager:GetFeature(name)
    return self.LoadedFeatures[name]
end

--========== WINDOW ==========
local Window = WindUI:CreateWindow({
    Title         = ".UcokKoplo",
    Icon          = "rbxassetid://73063950477508",
    Author        = "Fish It",
    Folder        = ".UcokKoplohub",
    Size          = UDim2.fromOffset(250, 250),
    Theme         = "Dark",
    Resizable     = false,
    SideBarWidth  = 120,
    HideSearchBar = true,
})

WindUI:SetFont("rbxasset://12187373592")

-- CUSTOM ICON INTEGRATION - Disable default open button
Window:EditOpenButton({ Enabled = false })

-- Services for custom icon
local PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local TweenService = game:GetService("TweenService")

-- Root UI yang lebih tahan reset (prioritas: gethui/CoreGui; fallback ke PlayerGui)
local function getUiRoot()
    return (gethui and gethui()) or game:GetService("CoreGui") or PlayerGui
end

-- Reuse kalau sudah ada (hindari duplikasi saat re-exec)
local iconGui = getUiRoot():FindFirstChild("UcokKoploIconGui") or Instance.new("ScreenGui")
iconGui.Name = "UcokKoploIconGui"
iconGui.IgnoreGuiInset = true
iconGui.ResetOnSpawn = false   -- <- kunci: jangan hilang saat respawn

-- (Opsional) proteksi GUI (beberapa executor support)
pcall(function() if syn and syn.protect_gui then syn.protect_gui(iconGui) end end)

iconGui.Parent = getUiRoot()

local iconButton = Instance.new("ImageButton")
iconButton.Name = "UcokKoploOpenButton"
iconButton.Size = UDim2.fromOffset(40, 40)
iconButton.Position = UDim2.new(0, 10, 0.5, -20)
iconButton.BackgroundTransparency = 1
iconButton.Image = "rbxassetid://73063950477508"
iconButton.Parent = iconGui
iconButton.Visible = false -- Start hidden because window is open

-- Variable untuk track status
local isWindowOpen = true
local windowDestroyed = false

-- NEW: flags to avoid race
local ignoreHeartbeat = false
local toggleDebounce = false
local lastVisible = nil

-- Helper: cari frame utama WindUI (Frame atau Main) di PlayerGui/CoreGui
local function findWindUIMainFrame()
    local roots = {
        PlayerGui,
        getUiRoot(),
    }
    for _, root in ipairs(roots) do
        if root then
            local windUI = root:FindFirstChild("WindUI")
            if windUI then
                local mainFrame = windUI:FindFirstChild("Frame") or windUI:FindFirstChild("Main")
                if mainFrame then
                    return mainFrame
                end
                for _, child in ipairs(windUI:GetChildren()) do
                    if child:IsA("Frame") then
                        return child
                    end
                end
            end
        end
    end
    return nil
end

-- Robust open/close that prefers setting Visible when possible
local function safeCloseWindow()
    local frame = findWindUIMainFrame()
    if frame then
        pcall(function()
            frame.Visible = false
        end)
        iconButton.Visible = true
        isWindowOpen = false
        lastVisible = false
        return true
    else
        local ok = pcall(function() Window:Close() end)
        if ok then
            iconButton.Visible = true
            isWindowOpen = false
            lastVisible = false
            return true
        end
    end
    return false
end

local function safeOpenWindow()
    local frame = findWindUIMainFrame()
    if frame then
        pcall(function()
            frame.Visible = true
        end)
        iconButton.Visible = false
        isWindowOpen = true
        lastVisible = true
        return true
    else
        local ok = pcall(function() Window:Open() end)
        if ok then
            iconButton.Visible = false
            isWindowOpen = true
            lastVisible = true
            return true
        end
    end
    return false
end

local function toggleWindow()
    if windowDestroyed or toggleDebounce then
        return
    end
    toggleDebounce = true
    ignoreHeartbeat = true

    -- Immediate UI feedback (prevent race): update icon & state early
    if isWindowOpen then
        iconButton.Visible = true
        isWindowOpen = false
    else
        iconButton.Visible = false
        isWindowOpen = true
    end

    -- perform safe open/close
    if isWindowOpen then
        local ok = safeOpenWindow()
        if not ok then
            pcall(function() Window:Open() end)
        end
    else
        local ok = safeCloseWindow()
        if not ok then
            pcall(function() Window:Close() end)
        end
    end

    task.delay(0.12, function()
        ignoreHeartbeat = false
        toggleDebounce = false
    end)
end

-- IMPROVED DRAG SYSTEM (ke iconButton)
local function makeDraggable(gui)
    local isDragging = false
    local dragStart = nil
    local startPos = nil
    local dragDistance = 0
    local hasDraggedFar = false
    local dragStartTime = 0
    
    local MIN_DRAG_DISTANCE = 8     
    local TOGGLE_MAX_DISTANCE = 5   
    local TOGGLE_MAX_TIME = 0.5     

    local inputChangedConnection = nil
    local inputEndedConnection = nil

    local function updateInput(input)
        if not isDragging or not dragStart then return end
        local Delta = input.Position - dragStart
        dragDistance = math.sqrt(Delta.X^2 + Delta.Y^2)
        if dragDistance > MIN_DRAG_DISTANCE then
            hasDraggedFar = true
        end
        if hasDraggedFar and startPos then
            local Position = UDim2.new(
                startPos.X.Scale, 
                startPos.X.Offset + Delta.X, 
                startPos.Y.Scale, 
                startPos.Y.Offset + Delta.Y
            )
            pcall(function() gui.Position = Position end)
        end
    end

    gui.InputBegan:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
            isDragging = true
            dragDistance = 0
            hasDraggedFar = false
            dragStart = input.Position
            startPos = gui.Position
            dragStartTime = tick()
            if inputChangedConnection then
                inputChangedConnection:Disconnect()
                inputChangedConnection = nil
            end
            if inputEndedConnection then
                inputEndedConnection:Disconnect()
                inputEndedConnection = nil
            end
            inputChangedConnection = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    local dragEndTime = tick()
                    local dragDuration = dragEndTime - dragStartTime
                    isDragging = false
                    local isClick = (dragDistance < TOGGLE_MAX_DISTANCE) and 
                                  (dragDuration < TOGGLE_MAX_TIME) and 
                                  (not hasDraggedFar)
                    if isClick then
                        task.spawn(function()
                            toggleWindow()
                        end)
                    end
                    if inputChangedConnection then
                        inputChangedConnection:Disconnect()
                        inputChangedConnection = nil
                    end
                    if inputEndedConnection then
                        inputEndedConnection:Disconnect()
                        inputEndedConnection = nil
                    end
                end
            end)
        end
    end)

    gui.InputChanged:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            if isDragging then
                updateInput(input)
            end
        end
    end)
    
    UserInputService.InputEnded:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
            if isDragging then
                isDragging = false
                if inputChangedConnection then
                    inputChangedConnection:Disconnect()
                    inputChangedConnection = nil
                end
                if inputEndedConnection then
                    inputEndedConnection:Disconnect()
                    inputEndedConnection = nil
                end
            end
        end
    end)
end

makeDraggable(iconButton)
iconButton.MouseButton1Click:Connect(function()
    toggleWindow()
end)

-- Monitor WindUI visibility with robust reparent/restore logic
RunService.Heartbeat:Connect(function()
    if windowDestroyed or ignoreHeartbeat then return end
    
    local mainFrame = findWindUIMainFrame()
    if mainFrame then
        -- restore parent if accidentally removed
        if not mainFrame.Parent then
            pcall(function() mainFrame.Parent = getUiRoot():FindFirstChild("WindUI") or getUiRoot() end)
        end

        -- sync icon & state
        local visible = true
        pcall(function() visible = mainFrame.Visible end)
        if visible ~= lastVisible then
            lastVisible = visible
            if visible then
                iconButton.Visible = false
                isWindowOpen = true
            else
                iconButton.Visible = true
                isWindowOpen = false
            end
        end
    else
        -- WindUI main frame not found
        if isWindowOpen then
            if lastVisible ~= true then
                pcall(function() Window:Open() end)
                lastVisible = true
                iconButton.Visible = false
            end
        else
            iconButton.Visible = true
            lastVisible = false
        end
    end
end)

-- Override Window methods to keep icon in sync (preserve original behavior)
if Window.Toggle then
    local originalToggle = Window.Toggle
    Window.Toggle = function(self)
        local result = originalToggle(self)
        if not windowDestroyed and iconButton then
            local mainFrame = findWindUIMainFrame()
            if mainFrame then
                local ok, vis = pcall(function() return mainFrame.Visible end)
                if ok and vis ~= nil then
                    iconButton.Visible = not vis
                    isWindowOpen = vis
                    lastVisible = vis
                else
                    iconButton.Visible = not iconButton.Visible
                    isWindowOpen = not isWindowOpen
                end
            else
                iconButton.Visible = not iconButton.Visible
                isWindowOpen = not isWindowOpen
            end
        end
        return result
    end
end

if Window.Close then
    local originalClose = Window.Close
    Window.Close = function(self)
        local result = originalClose(self)
        if not windowDestroyed and iconButton then
            iconButton.Visible = true
            isWindowOpen = false
            lastVisible = false
        end
        return result
    end
end

if Window.Open then
    local originalOpen = Window.Open
    Window.Open = function(self)
        local result = originalOpen(self)
        if not windowDestroyed and iconButton then
            iconButton.Visible = false
            isWindowOpen = true
            lastVisible = true
        end
        return result
    end
end

-- END CUSTOM ICON INTEGRATION

Window:Tag({
    Title = "v0.0.0",
    Color = Color3.fromHex("#000000")
})

Window:Tag({
    Title = "Dev Version",
    Color = Color3.fromHex("#000000")
})

-- === Topbar Changelog (simple) ===
local CHANGELOG = table.concat({
    "[+] Auto Fishing",
    "[+] Auto Teleport Island",
    "[+] Auto Buy Weather",
    "[+] Auto Sell Fish",
    "[+] Webhook",
}, "\n")
local DISCORD = table.concat({
    "https://discord.gg/3AzvRJFT3M",
}, "\n")
    
local function ShowChangelog()
    Window:Dialog({
        Title   = "Changelog",
        Content = CHANGELOG,
        Buttons = {
            {
                Title   = "Discord",
                Icon    = "copy",
                Variant = "Secondary",
                Callback = function()
                    if typeof(setclipboard) == "function" then
                        setclipboard(DISCORD)
                        WindUI:Notify({ Title = "Copied", Content = "Changelog copied", Icon = "check", Duration = 2 })
                    else
                        WindUI:Notify({ Title = "Info", Content = "Clipboard not available", Icon = "info", Duration = 3 })
                    end
                end
            },
            { Title = "Close", Variant = "Primary" }
        }
    })
end

-- name, icon, callback, order
Window:CreateTopbarButton("changelog", "newspaper", ShowChangelog, 995)

--========== TABS ==========
-- NOTE: Home tab removed per request; Anti AFK moved to Main.
local TabMain     = Window:Tab({ Title = "Main",     Icon = "gamepad" })
local TabBackpack = Window:Tab({ Title = "Backpack", Icon = "backpack" })
local TabShop     = Window:Tab({ Title = "Shop",     Icon = "shopping-bag" })
local TabTeleport = Window:Tab({ Title = "Teleport", Icon = "map" })
local TabMisc     = Window:Tab({ Title = "Misc",     Icon = "cog" })

--- === Main === ---
-- Utilities section (moved Anti AFK here)
local utilities_sec = TabMain:Section({
    Title = "⚡ Utilities",
    TextXAlignment = "Left",
    TextSize = 17,
})

local antiafkFeature = nil

local antiafk_tgl = TabMain:Toggle({
    Title = "🔒 Anti AFK",
    Desc = "Prevent being kicked for idling",
    Default = false,
    Callback = function(state) 
        if state then
            if not antiafkFeature then
                antiafkFeature = FeatureManager:LoadFeature("AntiAfk")
            end
            if antiafkFeature and antiafkFeature.Start then
                pcall(function() antiafkFeature:Start() end)
                WindUI:Notify({ Title="Anti AFK", Content="Enabled", Icon="check", Duration=2 })
            else
                antiafk_tgl:Set(false)
                WindUI:Notify({ Title="Failed", Content="Could not start AntiAfk", Icon="x", Duration=3 })
            end
        else
            if antiafkFeature and antiafkFeature.Stop then
                pcall(function() antiafkFeature:Stop() end)
                WindUI:Notify({ Title="Anti AFK", Content="Disabled", Icon="info", Duration=2 })
            end
        end
    end
})

-- === Main: Fishing controls (kept in Main for easy access) ===
local autofish_sec = TabMain:Section({ 
    Title = "🎣 Fishing",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local autoFishFeature = nil
local currentFishingMode = "Perfect"
local currentSpeedMode = "Normal" -- new speed mode state

-- Keep last saved fishing spot for respawn+return
local lastFishingPos = nil

-- Save player's current HRP position as fishing spot
local function SaveFishingSpot()
    local player = Players.LocalPlayer
    local char = player.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        lastFishingPos = char.HumanoidRootPart.CFrame
    end
end

-- Force stop animations & try unequip/equip to clear client-side stuckness
local function ForceUnstuckFishing()
    local player = Players.LocalPlayer
    local char = player.Character
    if not char then return end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    -- Unequip all tools
    pcall(function()
        humanoid:UnequipTools()
    end)
    task.wait(0.5)

    -- Stop playing animation tracks
    pcall(function()
        local animator = humanoid:FindFirstChildOfClass("Animator")
        if animator then
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                pcall(function() track:Stop() end)
            end
        end
    end)

    -- Try equip a rod from backpack if available
    pcall(function()
        local bp = player:FindFirstChild("Backpack")
        if bp then
            for _, item in ipairs(bp:GetChildren()) do
                if item:IsA("Tool") and item.Name:lower():find("rod") then
                    humanoid:EquipTool(item)
                    break
                end
            end
        end
    end)

    WindUI:Notify({
        Title = "Fishing Reset",
        Content = "Tried to reset rod & animation",
        Icon = "refresh-cw",
        Duration = 3
    })
end

-- Force respawn then teleport back to last saved spot (if available)
local function HardRespawnAndReturn()
    local player = Players.LocalPlayer
    local oldPos = lastFishingPos
    -- If no saved spot, just respawn without return
    player:LoadCharacter()
    local char = player.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart", 10)
    if hrp and oldPos then
        task.wait(1) -- small delay to ensure physics ready
        pcall(function()
            hrp.CFrame = oldPos + Vector3.new(0, 3, 0)
        end)
        WindUI:Notify({
            Title = "AutoFish",
            Content = "Respawned & returned to fishing spot 🎣",
            Icon = "check",
            Duration = 4
        })
    else
        WindUI:Notify({
            Title = "AutoFish",
            Content = "Respawned (no saved spot)",
            Icon = "info",
            Duration = 3
        })
    end
end

-- ---------------------------
-- Helper: apply speed tweaks
-- ---------------------------
local function ApplyFishSpeedTweak(feature, speedMode)
    if not feature or type(feature) ~= "table" then return false end

    -- Default normal (bawaan modul / conservative)
    local cfg = {
        reactionDelay = 0.12,
        castDelay     = 0.25,
        reelDelay     = 0.08,
    }

    if speedMode == "Fast" then
        cfg.reactionDelay = 0.08
        cfg.castDelay     = 0.18
        cfg.reelDelay     = 0.05
    elseif speedMode == "Very Fast" then
        cfg.reactionDelay = 0.05
        cfg.castDelay     = 0.15
        cfg.reelDelay     = 0.035
    end

    -- Try official API if exists
    pcall(function()
        if feature.SetConfig then
            feature:SetConfig(cfg)
        elseif feature.SetOptions then
            feature:SetOptions(cfg)
        end
    end)

    -- Direct property write (best-effort, non-invasive)
    pcall(function() 
        if feature.reactionDelay ~= nil then feature.reactionDelay = cfg.reactionDelay end
        if feature.castDelay ~= nil then feature.castDelay = cfg.castDelay end
        if feature.reelDelay ~= nil then feature.reelDelay = cfg.reelDelay end
    end)

    -- If module exposes settings table
    pcall(function()
        if feature.settings and type(feature.settings) == "table" then
            if feature.settings.reactionDelay ~= nil then feature.settings.reactionDelay = cfg.reactionDelay end
            if feature.settings.castDelay ~= nil then feature.settings.castDelay = cfg.castDelay end
            if feature.settings.reelDelay ~= nil then feature.settings.reelDelay = cfg.reelDelay end
        end
    end)

    -- Wrap Start to inject config if not already wrapped; also save fishing spot on start
    pcall(function()
        if feature.Start and not feature.__start_wrapped then
            local originalStart = feature.Start
            feature.Start = function(self, params)
                -- save fishing spot before starting (best-effort)
                pcall(SaveFishingSpot)
                params = params or {}
                if params.speedConfig == nil then
                    params.speedConfig = cfg
                end
                if not params.mode and currentFishingMode then
                    params.mode = currentFishingMode
                end
                return originalStart(self, params)
            end
            feature.__start_wrapped = true
        end
    end)

    return true
end

-- ---------------------------
-- Dropdown: Fishing Mode (Perfect/OK/Mid)
-- ---------------------------
local autofishmode_dd = TabMain:Dropdown({
    Title = "Fishing Mode",
    Values = { "Perfect", "OK", "Mid" },
    Value = "Perfect",
    Callback = function(option) 
        currentFishingMode = option
        print("[GUI] Fishing mode:", option)
        if autoFishFeature and autoFishFeature.SetMode then
            pcall(function() autoFishFeature:SetMode(option) end)
        end
    end
})

-- ---------------------------
-- Dropdown: Speed Mode (Normal/Fast/Very Fast)
-- ---------------------------
local autofishspeed_dd = TabMain:Dropdown({
    Title = "Speed Mode",
    Values = { "Normal", "Fast", "Very Fast" },
    Value = "Normal",
    Callback = function(option)
        currentSpeedMode = option
        print("[GUI] Fishing speed:", option)
        if autoFishFeature then
            ApplyFishSpeedTweak(autoFishFeature, currentSpeedMode)
        end
    end
})

-- ---------------------------
-- Toggle: Auto Fishing
-- ---------------------------
local autofish_tgl = TabMain:Toggle({
    Title = "Auto Fishing",
    Desc = "Automatically fishing with selected mode and speed",
    Default = false,
    Callback = function(state)
        print("[GUI] AutoFish toggle:", state)
        
        if state then
            -- Load feature if not already loaded
            if not autoFishFeature then
                autoFishFeature = FeatureManager:LoadFeature("AutoFish", {
                    modeDropdown = autofishmode_dd,
                    toggle = autofish_tgl
                })
                if autoFishFeature then
                    ApplyFishSpeedTweak(autoFishFeature, currentSpeedMode or "Normal")
                end
            else
                ApplyFishSpeedTweak(autoFishFeature, currentSpeedMode or "Normal")
            end
            
            -- Start fishing if feature loaded successfully
            if autoFishFeature and autoFishFeature.Start then
                local ok, res = pcall(function()
                    return autoFishFeature:Start({
                        mode = currentFishingMode,
                        speedConfig = (currentSpeedMode and {
                            reactionDelay = (currentSpeedMode == "Very Fast" and 0.05) or (currentSpeedMode == "Fast" and 0.08) or 0.12,
                            castDelay     = (currentSpeedMode == "Very Fast" and 0.15) or (currentSpeedMode == "Fast" and 0.18) or 0.25,
                            reelDelay     = (currentSpeedMode == "Very Fast" and 0.035) or (currentSpeedMode == "Fast" and 0.05) or 0.08,
                        } or nil)
                    })
                end)
                if not ok or res == false then
                    pcall(function() autoFishFeature:Start({ mode = currentFishingMode }) end)
                end
            else
                WindUI:Notify({
                    Title = "Failed",
                    Content = "Could not start AutoFish",
                    Icon = "x",
                    Duration = 3
                })
                autofish_tgl:Set(false)
            end
        else
            if autoFishFeature and autoFishFeature.Stop then
                pcall(function() autoFishFeature:Stop() end)
            end
        end
    end
})

-- =========================
-- AutoFish Watchdog (stuck detector & auto-recover)
-- =========================
local AutoFishWatchdog = {
    enabled = false,
    timeout = 20,       -- jika tidak ada progress selama X detik => restart / escalate
    checkInterval = 3,  -- frekuensi pengecekan
    thread = nil,
    lastHeartbeat = 0,
    lastSnapshot = nil,
    hasWrapped = false,
    retryCount = 0,
    maxRetriesBeforeRespawn = 2,
}

-- Helper: aman pcall panggil method / baca property
local function safeRead(tbl, key)
    local ok, res = pcall(function()
        if type(tbl[key]) == "function" then
            return tbl[key](tbl)
        else
            return tbl[key]
        end
    end)
    if ok then return res else return nil end
end

-- Try wrap common event/callback names to update heartbeat
local function tryWrapCallbacks(feature)
    if not feature or type(feature) ~= "table" then return false end
    local callbackNames = {
        "OnCatch", "OnFishCaught", "OnFish", "OnReel", "OnHook", "OnComplete",
        "onCatch", "onFish", "onReel", "on_hook", "OnSuccess", "OnUpdate",
        "Catch", "CatchEvent"
    }
    local wrapped = false
    for _, name in ipairs(callbackNames) do
        if type(feature[name]) == "function" then
            if not feature.__ucokk_wrapped_callbacks then feature.__ucokk_wrapped_callbacks = {} end
            if not feature.__ucokk_wrapped_callbacks[name] then
                local original = feature[name]
                feature[name] = function(...)
                    -- update heartbeat when callback runs
                    feature.__ucokk_last_heartbeat = tick()
                    return original(...)
                end
                feature.__ucokk_wrapped_callbacks[name] = true
                wrapped = true
            end
        end
    end

    -- If feature exposes :Connect style events (object with Connect)
    for _, name in ipairs(callbackNames) do
        local possibleEvent = feature[name]
        if type(possibleEvent) == "table" and type(possibleEvent.Connect) == "function" then
            -- subscribe wrapper
            if not feature.__ucokk_wrapped_events then feature.__ucokk_wrapped_events = {} end
            if not feature.__ucokk_wrapped_events[name] then
                local conn = possibleEvent:Connect(function(...)
                    feature.__ucokk_last_heartbeat = tick()
                end)
                feature.__ucokk_wrapped_events[name] = conn
                wrapped = true
            end
        end
    end

    return wrapped
end

-- Try to detect changing numeric counters as fallback
local function snapshotFeatureCounters(feature)
    if not feature or type(feature) ~= "table" then return nil end
    local keys = { "catchCount", "caught", "catches", "casts", "castCount", "lastCatchCount", "totalCaught", "successCount" }
    local snap = {}
    for _, k in ipairs(keys) do
        local v = safeRead(feature, k)
        if type(v) == "number" then
            snap[k] = v
        end
    end
    -- also try nested settings/counters
    if feature.settings and type(feature.settings) == "table" then
        for k, v in pairs(feature.settings) do
            if type(v) == "number" then snap["settings."..k] = v end
        end
    end
    return snap
end

local function snapshotChanged(a, b)
    if not a or not b then return false end
    for k, v in pairs(a) do
        if b[k] and b[k] ~= v then
            return true
        end
    end
    for k, v in pairs(b) do
        if a[k] and a[k] ~= v then
            return true
        end
    end
    return false
end

-- Lightweight restart attempt: stop/start + ForceUnstuckFishing
local function lightweightRestart(reason)
    if not autoFishFeature then return false end
    WindUI:Notify({ Title = "AutoFish", Content = "Stuck: "..(reason or "unknown").." — trying quick reset", Icon = "alert-triangle", Duration = 3 })
    -- Try client-side reset
    pcall(ForceUnstuckFishing)
    task.wait(0.6)
    -- stop feature
    pcall(function() if autoFishFeature.Stop then autoFishFeature:Stop() end end)
    task.wait(0.35)
    -- re-apply tweaks & start
    pcall(function()
        if autoFishFeature.Start then
            ApplyFishSpeedTweak(autoFishFeature, currentSpeedMode or "Normal")
            autoFishFeature:Start({ mode = currentFishingMode })
        end
    end)
    return true
end

-- Escalation: respawn + return then restart feature
local function escalateRespawnAndReturn(reason)
    WindUI:Notify({ Title = "AutoFish", Content = "Stuck persists: "..(reason or "unknown").." — respawning", Icon = "alert-triangle", Duration = 4 })
    pcall(HardRespawnAndReturn)
    task.wait(1.5)
    -- restart autoFish after respawn/return
    pcall(function()
        if autoFishFeature and autoFishFeature.Start then
            ApplyFishSpeedTweak(autoFishFeature, currentSpeedMode or "Normal")
            autoFishFeature:Start({ mode = currentFishingMode })
        end
    end)
end

-- Start watchdog loop
local function startAutoFishWatchdog()
    if AutoFishWatchdog.thread then return end
    AutoFishWatchdog.enabled = true
    AutoFishWatchdog.lastHeartbeat = tick()
    AutoFishWatchdog.lastSnapshot = snapshotFeatureCounters(autoFishFeature)
    AutoFishWatchdog.retryCount = 0

    AutoFishWatchdog.thread = task.spawn(function()
        while AutoFishWatchdog.enabled do
            task.wait(AutoFishWatchdog.checkInterval)
            if not AutoFishWatchdog.enabled then break end
            -- if toggle turned off -> stop watchdog
            local toggledOff = false
            if autofish_tgl and autofish_tgl.Get then
                local ok, v = pcall(function() return autofish_tgl:Get() end)
                if not ok or v == false then toggledOff = true end
            end
            if toggledOff then
                AutoFishWatchdog.enabled = false
                break
            end

            -- Ensure feature exists
            if not autoFishFeature then
                -- attempt load if toggle still on
                pcall(function()
                    autoFishFeature = FeatureManager:LoadFeature("AutoFish", {
                        modeDropdown = autofishmode_dd,
                        toggle = autofish_tgl
                    })
                    if autoFishFeature then
                        ApplyFishSpeedTweak(autoFishFeature, currentSpeedMode or "Normal")
                    end
                end)
                AutoFishWatchdog.lastHeartbeat = tick()
                AutoFishWatchdog.lastSnapshot = snapshotFeatureCounters(autoFishFeature)
                continue
            end

            -- prefer explicit heartbeat if feature sets it
            local hb = safeRead(autoFishFeature, "__ucokk_last_heartbeat") or safeRead(autoFishFeature, "lastCatchTime") or safeRead(autoFishFeature, "lastCatchTimestamp") or safeRead(autoFishFeature, "lastActionTime")
            if hb and type(hb) == "number" then
                AutoFishWatchdog.lastHeartbeat = hb
            end

            -- try wrap callbacks once (best-effort)
            if not AutoFishWatchdog.hasWrapped then
                local ok = pcall(tryWrapCallbacks, autoFishFeature)
                AutoFishWatchdog.hasWrapped = ok
            end

            -- snapshot counters and compare as fallback
            local snap = snapshotFeatureCounters(autoFishFeature)
            if snap and AutoFishWatchdog.lastSnapshot then
                if snapshotChanged(AutoFishWatchdog.lastSnapshot, snap) then
                    -- progress observed
                    AutoFishWatchdog.lastHeartbeat = tick()
                    AutoFishWatchdog.lastSnapshot = snap
                    AutoFishWatchdog.retryCount = 0 -- reset retries on progress
                end
            elseif snap then
                AutoFishWatchdog.lastSnapshot = snap
            end

            -- Also check if rod appears stuck client-side (Tool reasons)
            local function IsRodLikelyStuck()
                local char = Players.LocalPlayer.Character
                if not char then return false end
                local rod = nil
                for _, c in ipairs(char:GetChildren()) do
                    if c:IsA("Tool") and c.Name:lower():find("rod") then
                        rod = c
                        break
                    end
                end
                if not rod then return false end
                -- heuristics: presence of certain parts / names that indicate bobber/line
                for _,d in ipairs(rod:GetDescendants()) do
                    if d.Name:lower():find("bobber") or d.Name:lower():find("line") or d.Name:lower():find("hook") then
                        return true
                    end
                end
                return false
            end

            local rodStuck = pcall(IsRodLikelyStuck)
            if rodStuck == nil then rodStuck = false end

            local elapsed = tick() - (AutoFishWatchdog.lastHeartbeat or 0)
            if elapsed >= AutoFishWatchdog.timeout or rodStuck then
                -- consider stuck
                AutoFishWatchdog.retryCount = (AutoFishWatchdog.retryCount or 0) + 1
                local reasonStr = "no activity for "..tostring(math.floor(elapsed)).."s"
                if rodStuck then reasonStr = reasonStr .. " (rod heuristics)" end

                -- attempt lightweight restart first
                local okRestart = pcall(function() lightweightRestart(reasonStr) end)
                if not okRestart then
                    -- if restart raised error, proceed to escalate
                    escalateRespawnAndReturn(reasonStr)
                    AutoFishWatchdog.retryCount = 0
                else
                    -- if lightweight restart attempted, wait and check again next loop
                    if AutoFishWatchdog.retryCount > AutoFishWatchdog.maxRetriesBeforeRespawn then
                        -- escalate to respawn+return
                        escalateRespawnAndReturn(reasonStr)
                        AutoFishWatchdog.retryCount = 0
                    end
                end
                -- refresh heartbeat snapshot
                AutoFishWatchdog.lastHeartbeat = tick()
                AutoFishWatchdog.lastSnapshot = snapshotFeatureCounters(autoFishFeature)
            end
        end
        AutoFishWatchdog.thread = nil
    end)
end

local function stopAutoFishWatchdog()
    AutoFishWatchdog.enabled = false
    AutoFishWatchdog.thread = nil
    AutoFishWatchdog.hasWrapped = false
    AutoFishWatchdog.retryCount = 0
end

-- Monitor toggle state and start/stop watchdog
task.spawn(function()
    local lastState = nil
    while true do
        task.wait(0.6)
        if not autofish_tgl or not autofish_tgl.Get then break end
        local ok, state = pcall(function() return autofish_tgl:Get() end)
        if not ok then break end
        if state ~= lastState then
            lastState = state
            if state then
                -- toggled on
                if autoFishFeature then
                    pcall(function()
                        autoFishFeature.__ucokk_last_heartbeat = tick()
                        tryWrapCallbacks(autoFishFeature)
                    end)
                end
                startAutoFishWatchdog()
            else
                stopAutoFishWatchdog()
            end
        end
    end
end)

-- Optional: expose a manual reset function (useful for debugging)
_G.UcokKoplo = _G.UcokKoplo or {}
_G.UcokKoplo.ResetAutoFish = function()
    if autoFishFeature and autoFishFeature.Stop then
        pcall(function() autoFishFeature:Stop() end)
    end
    task.wait(0.2)
    if autoFishFeature and autoFishFeature.Start then
        pcall(function()
            ApplyFishSpeedTweak(autoFishFeature, currentSpeedMode or "Normal")
            autoFishFeature:Start({ mode = currentFishingMode })
        end)
    end
end

--- Event Teleport
local eventtele_sec = TabMain:Section({ 
    Title = "Event Teleport",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local eventteleFeature     = nil
local selectedEventsArray = {}

local AVAIL_EVENT = {
    "Shark Hunt", "Worm Hunt", "Ghost Shark Hunt", "Admin - Blackhole", "Admin - Ghost Worm", "Admin - Meteor Rain",
    "Admin - Shocked" 
}

local AVAIL_EVENT_OPTIONS = {}
for _, event in ipairs(AVAIL_EVENT) do
    table.insert(AVAIL_EVENT_OPTIONS, event)
end

local eventtele_ddm = TabMain:Dropdown({
    Title = "Select Event",
    Values = AVAIL_EVENT_OPTIONS,
    Value = {},
    Multi = true,
    AllowNone = true,
    Callback  = function(options)
        selectedEventsArray = options or {}
        if eventteleFeature and eventteleFeature.SetSelectedEvents then
            pcall(function() eventteleFeature:SetSelectedEvents(selectedEventsArray) end)
        end
    end
})

local eventtele_tgl = TabMain:Toggle({
    Title = "Auto Event Teleport",
    Desc  = "Auto Teleport to Event when available",
    Default = false,
    Callback = function(state) 
        if state then
            if not eventteleFeature then
                eventteleFeature = FeatureManager:LoadFeature("AutoTeleportEvent", {
                    dropdown = eventtele_ddm,
                    toggle   = eventtele_tgl
                })
            end
            if eventteleFeature and eventteleFeature.Start then
                pcall(function()
                    eventteleFeature:Start({
                        selectedEvents = selectedEventsArray,
                        hoverHeight    = 12
                    })
                end)
            else
                eventtele_tgl:Set(false)
                WindUI:Notify({Title="Failed", Content="Could not start AutoTeleportEvent", Icon="x", Duration=3 })
            end
        else
            if eventteleFeature and eventteleFeature.Stop then pcall(function() eventteleFeature:Stop() end) end
        end
    end
})

--- === Backpack === ---
--- Sell Fish (tetap)
local sellfish_sec = TabBackpack:Section({ 
    Title = "Sell Fish",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local sellfishFeature        = nil
local currentSellThreshold   = "Legendary"
local currentSellLimit       = 0

local sellfish_dd = TabBackpack:Dropdown({
    Title = "Select Rarity",
    Values = { "Secret", "Mythic", "Legendary" },
    Value = "Legendary",
    Callback = function(option)
        currentSellThreshold = option
        if sellfishFeature and sellfishFeature.SetMode then
            pcall(function() sellfishFeature:SetMode(option) end)
        end
    end
})

local sellfish_in = TabBackpack:Input({
    Title = "Sell Delay",
    Placeholder = "e.g 60 (second)",
    Desc = "Input delay in seconds.",
    Value = "60",
    Numeric = true,
    Callback    = function(value)
        local n = tonumber(value) or 0
        currentSellLimit = n
        if sellfishFeature and sellfishFeature.SetLimit then
            pcall(function() sellfishFeature:SetLimit(n) end)
        end
    end
})

local sellfish_tgl = TabBackpack:Toggle({
    Title = "Auto Sell",
    Desc = "",
    Default = false,
    Callback = function(state)
        if state then
            if not sellfishFeature then
                sellfishFeature = FeatureManager:LoadFeature("AutoSellFish", {
                  thresholdDropdown = sellfish_dd,
                  limitInput        = sellfish_in,
                  toggle            = sellfish_tgl,
                })
            end
            if sellfishFeature and sellfishFeature.Start then
                pcall(function()
                    sellfishFeature:Start({
                      threshold   = currentSellThreshold,
                      limit       = currentSellLimit,
                      autoOnLimit = true,
                    })
                end)
            else
                sellfish_tgl:Set(false)
                WindUI:Notify({ Title="Failed", Content="Could not start AutoSellFish", Icon="x", Duration=3 })
            end
        else
            if sellfishFeature and sellfishFeature.Stop then pcall(function() sellfishFeature:Stop() end) end
        end
    end
})

--- === Shop === 
--- Rod
local shoprod_sec = TabShop:Section({ 
    Title = "🎣 Rod",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local autobuyrodFeature = nil
local selectedRodsSet = {} -- State untuk menyimpan pilihan user

local shoprod_ddm = TabShop:Dropdown({
    Title = "Select Rod",
    Values = {
        "Luck Rod",
        "Carbon Rod", 
        "Grass Rod",
        "Demascus Rod",
        "Ice Rod",
        "Lucky Rod",
        "Midnight Rod",
        "Steampunk Rod",
        "Chrome Rod",
        "Astral Rod",
        "Ares Rod",
        "Angler Rod"
    },
    Value = {}, -- Start with empty selection
    Multi = true,
    AllowNone = true,
    Callback = function(options) 
        selectedRodsSet = options or {}
        print("[AutoBuyRod] Selected rods:", HttpService:JSONEncode(selectedRodsSet))
        if autobuyrodFeature and autobuyrodFeature.SetSelectedRodsByName then
            pcall(function() autobuyrodFeature:SetSelectedRodsByName(selectedRodsSet) end)
        end
    end
})

local shoprod_btn = TabShop:Button({
    Title = "💰 Buy Rod",
    Desc = "Purchase selected rods (one-time buy)",
    Locked = false,
    Callback = function()
        print("[GUI] Buy Rod button clicked")
        if not autobuyrodFeature then
            print("[GUI] Loading AutoBuyRod feature...")
            autobuyrodFeature = FeatureManager:LoadFeature("AutoBuyRod", {
                rodsDropdown = shoprod_ddm,
                button = shoprod_btn
            })
            if autobuyrodFeature then
                print("[GUI] AutoBuyRod feature loaded successfully")
                task.spawn(function()
                    task.wait(0.5)
                    if autobuyrodFeature.GetAvailableRods then
                        local availableRods = autobuyrodFeature:GetAvailableRods()
                        local rodNames = {}
                        for _, rod in ipairs(availableRods) do
                            table.insert(rodNames, rod.name)
                        end
                        if shoprod_ddm.Reload then
                            shoprod_ddm:Reload(rodNames)
                            print("[AutoBuyRod] Dropdown refreshed with", #rodNames, "real rods")
                        end
                    end
                end)
            else
                print("[GUI] Failed to load AutoBuyRod feature")
                WindUI:Notify({ 
                    Title = "Error", 
                    Content = "Failed to load AutoBuyRod feature", 
                    Icon = "x", 
                    Duration = 3 
                })
                return
            end
        end
        if not selectedRodsSet or #selectedRodsSet == 0 then
            WindUI:Notify({ 
                Title = "Info", 
                Content = "Select at least 1 Rod first", 
                Icon = "info", 
                Duration = 3 
            })
            return
        end
        if not autobuyrodFeature then
            WindUI:Notify({ 
                Title = "Error", 
                Content = "AutoBuyRod feature not available", 
                Icon = "x", 
                Duration = 3 
            })
            return
        end
        print("[GUI] Starting purchase for rods:", table.concat(selectedRodsSet, ", "))
        if autobuyrodFeature.SetSelectedRodsByName then
            local okSet, setSuccess = pcall(function()
                return autobuyrodFeature:SetSelectedRodsByName(selectedRodsSet)
            end)
            if not okSet or not setSuccess then
                WindUI:Notify({ 
                    Title = "Error", 
                    Content = "Failed to set selected rods", 
                    Icon = "x", 
                    Duration = 3 
                })
                return
            end
        end
        if autobuyrodFeature.Start then
            local okStart, purchaseSuccess = pcall(function()
                return autobuyrodFeature:Start({
                    rodList = selectedRodsSet,
                    interDelay = 0.5
                })
            end)
            if okStart and purchaseSuccess then
                WindUI:Notify({ 
                    Title = "Success", 
                    Content = "Rod purchase completed!", 
                    Icon = "check", 
                    Duration = 3 
                })
                print("[GUI] Purchase completed successfully")
            else
                WindUI:Notify({ 
                    Title = "Failed", 
                    Content = "Could not complete rod purchase", 
                    Icon = "x", 
                    Duration = 3 
                })
                print("[GUI] Purchase failed")
            end
        else
            WindUI:Notify({ 
                Title = "Error", 
                Content = "Start method not available", 
                Icon = "x", 
                Duration = 3 
            })
        end
    end
})

--- Baits
local shopbait_sec = TabShop:Section({ 
    Title = "🪱 Baits",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local autobuybaitFeature = nil
local selectedBaitsSet = {} -- State untuk menyimpan pilihan user

local shopbait_ddm = TabShop:Dropdown({
    Title = "Select Bait",
    Values = {
        "Topwater Bait",
        "Luck Bait",
        "Midnight Bait", 
        "Nature Bait",
        "Chroma Bait",
        "Dark Matter Bait",
        "Corrupt Bait",
        "Aether Bait"
    },
    Value = {}, -- Start with empty selection
    Multi = true,
    AllowNone = true,
    Callback = function(options) 
        selectedBaitsSet = options or {}
        print("[AutoBuyBait] Selected baits:", HttpService:JSONEncode(selectedBaitsSet))
        if autobuybaitFeature and autobuybaitFeature.SetSelectedBaitsByName then
            pcall(function() autobuybaitFeature:SetSelectedBaitsByName(selectedBaitsSet) end)
        end
    end
})

local shopbait_btn = TabShop:Button({
    Title = "💰 Buy Bait",
    Desc = "Purchase selected baits (one-time buy)",
    Locked = false,
    Callback = function()
        print("[GUI] Buy Bait button clicked")
        if not autobuybaitFeature then
            print("[GUI] Loading AutoBuyBait feature...")
            autobuybaitFeature = FeatureManager:LoadFeature("AutoBuyBait", {
                dropdown = shopbait_ddm,
                button   = shopbait_btn
            })
            if autobuybaitFeature then
                print("[GUI] AutoBuyBait feature loaded successfully")
                task.spawn(function()
                    task.wait(0.5)
                    if autobuybaitFeature.GetAvailableBaits then
                        local availableBaits = autobuybaitFeature:GetAvailableBaits()
                        local baitNames = {}
                        for _, bait in ipairs(availableBaits) do
                            table.insert(baitNames, bait.name)
                        end
                        if shopbait_ddm.Reload then
                            shopbait_ddm:Reload(baitNames)
                            print("[AutoBuyBait] Dropdown refreshed with", #baitNames, "real baits")
                        end
                    end
                end)
            else
                print("[GUI] Failed to load AutoBuyBait feature")
                WindUI:Notify({ 
                    Title = "Error", 
                    Content = "Failed to load AutoBuyBait feature", 
                    Icon = "x", 
                    Duration = 3 
                })
                return
            end
        end
        if not selectedBaitsSet or #selectedBaitsSet == 0 then
            WindUI:Notify({ 
                Title = "Info", 
                Content = "Select at least 1 Bait first", 
                Icon = "info", 
                Duration = 3 
            })
            return
        end
        if not autobuybaitFeature then
            WindUI:Notify({ 
                Title = "Error", 
                Content = "AutoBuyBait feature not available", 
                Icon = "x", 
                Duration = 3 
            })
            return
        end
        print("[GUI] Starting purchase for baits:", table.concat(selectedBaitsSet, ", "))
        if autobuybaitFeature.SetSelectedBaitsByName then
            local okSet, setSuccess = pcall(function()
                return autobuybaitFeature:SetSelectedBaitsByName(selectedBaitsSet)
            end)
            if not okSet or not setSuccess then
                WindUI:Notify({ 
                    Title = "Error", 
                    Content = "Failed to set selected baits", 
                    Icon = "x", 
                    Duration = 3 
                })
                return
            end
        end
        if autobuybaitFeature.Start then
            local okStart, purchaseSuccess = pcall(function()
                return autobuybaitFeature:Start({
                    baitList = selectedBaitsSet,
                    interDelay = 0.5
                })
            end)
            if okStart and purchaseSuccess then
                WindUI:Notify({ 
                    Title = "Success", 
                    Content = "Bait purchase completed!", 
                    Icon = "check", 
                    Duration = 3 
                })
                print("[GUI] Purchase completed successfully")
            else
                WindUI:Notify({ 
                    Title = "Failed", 
                    Content = "Could not complete bait purchase", 
                    Icon = "x", 
                    Duration = 3 
                })
                print("[GUI] Purchase failed")
            end
        else
            WindUI:Notify({ 
                Title = "Error", 
                Content = "Start method not available", 
                Icon = "x", 
                Duration = 3 
            })
        end
    end
})

--- Weather
local shopweather_sec = TabShop:Section({ 
    Title = "🌦 Weather",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local weatherFeature          = nil
local selectedWeatherSet      = {}  -- pakai set seperti pola webhook

local BUYABLE_WEATHER = {
    "Shark Hunt", "Wind", "Snow", "Radiant", "Storm", "Cloudy" 
}

local BUYABLE_WEATHER_OPTIONS = {}
for _, weather in ipairs(BUYABLE_WEATHER) do
    table.insert(BUYABLE_WEATHER_OPTIONS, weather)
end

-- Multi dropdown (Values diisi setelah modul diload)
local shopweather_ddm = TabShop:Dropdown({
    Title     = "Select Weather",
    Desc      = "",
    Values    = BUYABLE_WEATHER_OPTIONS,
    Value     = {},
    Multi     = true,
    AllowNone = true,
    Callback  = function(options)
        selectedWeatherSet = {}
        for _, opt in ipairs(options) do
            if type(opt) == "string" and opt ~= "" then
                selectedWeatherSet[opt] = true
            end
        end
        if weatherFeature and weatherFeature.SetWeathers then
            pcall(function() weatherFeature:SetWeathers(selectedWeatherSet) end)
        end
    end
})

local shopweather_tgl = TabShop:Toggle({
    Title   = "Auto Buy Weather",
    Default = false,
    Callback = function(state)
        if state then
            if not weatherFeature then
                weatherFeature = FeatureManager:LoadFeature("AutoBuyWeather", {
                    weatherDropdownMulti = shopweather_ddm,
                    toggle               = shopweather_tgl,
                })
                if weatherFeature and weatherFeature.GetBuyableWeathers then
                    local names = weatherFeature:GetBuyableWeathers()
                    if shopweather_ddm.Reload then
                        shopweather_ddm:Reload(names)
                    elseif shopweather_ddm.SetOptions then
                        shopweather_ddm:SetOptions(names)
                    end
                    task.delay(1.5, function()
                        if weatherFeature and weatherFeature.GetBuyableWeathers then
                            local names2 = weatherFeature:GetBuyableWeathers()
                            if shopweather_ddm.Reload then
                                shopweather_ddm:Reload(names2)
                            elseif shopweather_ddm.SetOptions then
                                shopweather_ddm:SetOptions(names2)
                            end
                        end
                    end)
                end
            end

            if next(selectedWeatherSet) == nil then
                WindUI:Notify({ Title="Info", Content="Select atleast 1 Weather", Icon="info", Duration=3 })
                shopweather_tgl:Set(false)
                return
            end

            if weatherFeature and weatherFeature.Start then
                pcall(function() weatherFeature:Start({
                    weatherList = selectedWeatherSet,
                }) end)
            else
                shopweather_tgl:Set(false)
                WindUI:Notify({ Title="Failed", Content="Could not start AutoBuyWeather", Icon="x", Duration=3 })
            end
        else
            if weatherFeature and weatherFeature.Stop then pcall(function() weatherFeature:Stop() end) end
        end
    end
})

--- === Teleport === ---
local teleisland_sec = TabTeleport:Section({ 
    Title = "Islands",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local autoTeleIslandFeature = nil
local currentIsland = "Fisherman Island"

local teleisland_dd = TabTeleport:Dropdown({
    Title = "Select Island",
    Values = {
        "Fisherman Island",
        "Esoteric Depths",
        "Enchant Altar",
        "Kohana",
        "Kohana Volcano",
        "Tropical Grove",
        "Crater Island",
        "Coral Reefs",
        "Sisyphus Statue",
        "Treasure Room"
    },
    Value = currentIsland,
    Callback = function(option)
        currentIsland = option
        if autoTeleIslandFeature and autoTeleIslandFeature.SetIsland then
            pcall(function() autoTeleIslandFeature:SetIsland(option) end)
        end
    end
})

local teleisland_btn = TabTeleport:Button({
    Title = "Teleport To Island",
    Desc  = "",
    Locked = false,
    Callback = function()
        if not autoTeleIslandFeature then
            autoTeleIslandFeature = FeatureManager:LoadFeature("AutoTeleportIsland", {
                dropdown = teleisland_dd,
                button   = teleisland_btn
            })
        end
        if autoTeleIslandFeature then
            if autoTeleIslandFeature.SetIsland then
                pcall(function() autoTeleIslandFeature:SetIsland(currentIsland) end)
            end
            if autoTeleIslandFeature.Teleport then
                pcall(function() autoTeleIslandFeature:Teleport(currentIsland) end)
            end
        else
            WindUI:Notify({
                Title   = "Error",
                Content = "AutoTeleportIsland feature could not be loaded",
                Icon    = "x",
                Duration = 3
            })
        end
    end
})

--- === Misc === ---
--- Webhook
local webhookfish_sec = TabMisc:Section({ 
    Title = "Webhook",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local fishWebhookFeature = nil
local currentWebhookUrl = ""
local selectedWebhookFishTypes = {}

local FISH_TIERS = {
    "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret"
}

local WEBHOOK_FISH_OPTIONS = {}
for _, tier in ipairs(FISH_TIERS) do
    table.insert(WEBHOOK_FISH_OPTIONS, tier)
end

local webhookfish_in = TabMisc:Input({
    Title = "Discord Webhook URL",
    Desc = "Paste your Discord webhook URL here",
    Value = "",
    Placeholder = "https://discord.com/api/webhooks/...",
    Type = "Input",
    Callback = function(input)
        currentWebhookUrl = input
        print("[Webhook] URL updated:", input:sub(1, 50) .. (input:len() > 50 and "..." or ""))
        if fishWebhookFeature and fishWebhookFeature.SetWebhookUrl then
            pcall(function() fishWebhookFeature:SetWebhookUrl(input) end)
        end
    end
})

local webhookfish_ddm = TabMisc:Dropdown({
    Title = "Select Rarity",
    Desc = "Choose which fish types/rarities to send to webhook",
    Values = WEBHOOK_FISH_OPTIONS,
    Value = {"Legendary", "Mythic", "Secret"},
    Multi = true,
    AllowNone = true,
    Callback = function(options)
        selectedWebhookFishTypes = {}
        for _, option in ipairs(options) do
            selectedWebhookFishTypes[option] = true
        end
        print("[Webhook] Fish types selected:", HttpService:JSONEncode(options))
        if fishWebhookFeature and fishWebhookFeature.SetSelectedFishTypes then
            pcall(function() fishWebhookFeature:SetSelectedFishTypes(selectedWebhookFishTypes) end)
        end
    end
})

local function isValidDiscordWebhook(url)
    if type(url) ~= "string" then return false end
    return url:match("^https?://discord%.com/api/webhooks/") ~= nil
end

local webhookfish_tgl = TabMisc:Toggle({
    Title = "Enable Fish Webhook",
    Desc = "Automatically send notifications when catching selected fish types",
    Default = false,
    Callback = function(state)
        print("[Webhook] Toggle:", state)
        
        if state then
            if currentWebhookUrl == "" or not isValidDiscordWebhook(currentWebhookUrl) then
                WindUI:Notify({
                    Title = "Error", 
                    Content = "Please enter a valid Discord webhook URL",
                    Icon = "x",
                    Duration = 3
                })
                webhookfish_tgl:Set(false)
                return
            end
            
            if next(selectedWebhookFishTypes) == nil then
                WindUI:Notify({
                    Title = "Warning",
                    Content = "No fish types selected - will monitor all catches",
                    Icon = "alert-triangle",
                    Duration = 3
                })
            end
            
            if not fishWebhookFeature then
                fishWebhookFeature = FeatureManager:LoadFeature("FishWebhook", {
                    urlInput = webhookfish_in,
                    fishTypesDropdown = webhookfish_ddm,
                    testButton = nil,
                    toggle = webhookfish_tgl
                })
            end
            
            if fishWebhookFeature and fishWebhookFeature.Start then
                local ok, success = pcall(function()
                    return fishWebhookFeature:Start({
                        webhookUrl = currentWebhookUrl,
                        selectedFishTypes = selectedWebhookFishTypes
                    })
                end)
                if ok and success then
                    WindUI:Notify({
                        Title = "Webhook Active",
                        Content = "Fish notifications enabled",
                        Icon = "check",
                        Duration = 2
                    })
                else
                    webhookfish_tgl:Set(false)
                    WindUI:Notify({
                        Title = "Start Failed",
                        Content = "Could not start webhook monitoring",
                        Icon = "x", 
                        Duration = 3
                    })
                end
            else
                webhookfish_tgl:Set(false)
                WindUI:Notify({
                    Title = "Load Failed",
                    Content = "Could not load webhook feature",
                    Icon = "x",
                    Duration = 3
                })
            end
        else
            if fishWebhookFeature and fishWebhookFeature.Stop then
                pcall(function() fishWebhookFeature:Stop() end)
                WindUI:Notify({
                    Title = "Webhook Stopped",
                    Content = "Fish notifications disabled",
                    Icon = "info",
                    Duration = 2
                })
            end
        end
    end
})

--- Vuln
local vuln_sec = TabMisc:Section({ 
    Title = "Vuln",
    TextXAlignment = "Left",
    TextSize = 17, -- Default Size
})

local autoGearFeature = nil
local oxygenOn = false
local radarOn  = false

local eqoxygentank_tgl = TabMisc:Toggle({
    Title = "Equip Diving Gear",
    Desc  = "No Need have Diving Gear",
    Default = false,
    Callback = function(state)
        print("Diving Gear toggle:", state)
        oxygenOn = state
        if state then
            if not autoGearFeature then
                autoGearFeature = FeatureManager:LoadFeature("AutoGearOxyRadar")
                if autoGearFeature and autoGearFeature.Start then
                    pcall(function() autoGearFeature:Start() end)
                end
            end
            if autoGearFeature and autoGearFeature.EnableOxygen then
                pcall(function() autoGearFeature:EnableOxygen(true) end)
            end
        else
            if autoGearFeature and autoGearFeature.EnableOxygen then
                pcall(function() autoGearFeature:EnableOxygen(false) end)
            end
        end
        if autoGearFeature and (not oxygenOn) and (not radarOn) and autoGearFeature.Stop then
            pcall(function() autoGearFeature:Stop() end)
        end
    end
})

local eqfishradar_tgl = TabMisc:Toggle({
    Title = "Enable Fish Radar",
    Desc  = "No Need have Fish Radar",
    Default = false,
    Callback = function(state)
        print("Fish Radar toggle:", state)
        radarOn = state
        if state then
            if not autoGearFeature then
                autoGearFeature = FeatureManager:LoadFeature("AutoGearOxyRadar")
                if autoGearFeature and autoGearFeature.Start then
                    pcall(function() autoGearFeature:Start() end)
                end
            end
            if autoGearFeature and autoGearFeature.EnableRadar then
                pcall(function() autoGearFeature:EnableRadar(true) end)
            end
        else
            if autoGearFeature and autoGearFeature.EnableRadar then
                pcall(function() autoGearFeature:EnableRadar(false) end)
            end
        end
        if autoGearFeature and (not oxygenOn) and (not radarOn) and autoGearFeature.Stop then
            pcall(function() autoGearFeature:Stop() end)
        end
    end
})

--========== LIFECYCLE (tanpa cleanup integrasi) ==========
if type(Window.OnClose) == "function" then
    Window:OnClose(function()
        print("[GUI] Window closed")
    end)
end

if type(Window.OnDestroy) == "function" then
    Window:OnDestroy(function()
        print("[GUI] Window destroying - cleaning up")
        
        for _, feature in pairs(FeatureManager.LoadedFeatures) do
            if feature.Cleanup then
                pcall(feature.Cleanup, feature)
            end
        end
        FeatureManager.LoadedFeatures = {}
        
        if _G.UcokKoploIconCleanup then
            pcall(_G.UcokKoploIconCleanup)
            _G.UcokKoploIconCleanup = nil
        end

        windowDestroyed = true
    end)
end
