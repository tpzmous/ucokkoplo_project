-- autofish_controller.lua
local M = {}
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local FeatureManager
local Utils
local Window

local autoFishFeature = nil
local currentFishingMode = "Perfect"
local currentSpeedMode = "Normal"
local lastFishingPos = nil

local function SaveFishingSpot()
    local player = Players.LocalPlayer
    local char = player.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        lastFishingPos = char.HumanoidRootPart.CFrame
    end
end

local function ForceUnstuckFishing()
    local player = Players.LocalPlayer
    local char = player.Character
    if not char then return end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end
    pcall(function() humanoid:UnequipTools() end)
    task.wait(0.5)
    pcall(function()
        local animator = humanoid:FindFirstChildOfClass("Animator")
        if animator then
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                pcall(function() track:Stop() end)
            end
        end
    end)
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
    Utils.Notify("Fishing Reset", "Tried to reset rod & animation", "refresh-cw", 3)
end

local function HardRespawnAndReturn()
    local player = Players.LocalPlayer
    local oldPos = lastFishingPos
    player:LoadCharacter()
    local char = player.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart", 10)
    if hrp and oldPos then
        task.wait(1)
        pcall(function() hrp.CFrame = oldPos + Vector3.new(0,3,0) end)
        Utils.Notify("AutoFish", "Respawned & returned to fishing spot 🎣", "check", 4)
    else
        Utils.Notify("AutoFish", "Respawned (no saved spot)", "info", 3)
    end
end

function M.ApplyFishSpeedTweak(feature, speedMode)
    if not feature or type(feature) ~= "table" then return false end
    local cfg = { reactionDelay=0.12, castDelay=0.25, reelDelay=0.08 }
    if speedMode == "Fast" then cfg.reactionDelay=0.08; cfg.castDelay=0.18; cfg.reelDelay=0.05 end
    if speedMode == "Very Fast" then cfg.reactionDelay=0.05; cfg.castDelay=0.15; cfg.reelDelay=0.035 end
    pcall(function()
        if feature.SetConfig then feature:SetConfig(cfg) end
        if feature.SetOptions then feature:SetOptions(cfg) end
    end)
    pcall(function()
        if feature.reactionDelay ~= nil then feature.reactionDelay = cfg.reactionDelay end
        if feature.castDelay ~= nil then feature.castDelay = cfg.castDelay end
        if feature.reelDelay ~= nil then feature.reelDelay = cfg.reelDelay end
    end)
    pcall(function()
        if feature.settings and type(feature.settings)=="table" then
            if feature.settings.reactionDelay ~= nil then feature.settings.reactionDelay = cfg.reactionDelay end
            if feature.settings.castDelay ~= nil then feature.settings.castDelay = cfg.castDelay end
            if feature.settings.reelDelay ~= nil then feature.settings.reelDelay = cfg.reelDelay end
        end
    end)
    pcall(function()
        if feature.Start and not feature.__start_wrapped then
            local originalStart = feature.Start
            feature.Start = function(self, params)
                pcall(SaveFishingSpot)
                params = params or {}
                if params.speedConfig == nil then params.speedConfig = cfg end
                if not params.mode and currentFishingMode then params.mode = currentFishingMode end
                return originalStart(self, params)
            end
            feature.__start_wrapped = true
        end
    end)
    return true
end

function M.StartAutoFish(params)
    params = params or {}
    if not autoFishFeature then
        autoFishFeature = FeatureManager.LoadFeature("AutoFish", {
            modeDropdown = nil,
            toggle = nil
        })
    end
    if autoFishFeature and autoFishFeature.Start then
        M.ApplyFishSpeedTweak(autoFishFeature, currentSpeedMode or "Normal")
        pcall(function()
            autoFishFeature:Start({ mode = currentFishingMode })
        end)
    end
end

function M.StopAutoFish()
    if autoFishFeature and autoFishFeature.Stop then
        pcall(function() autoFishFeature:Stop() end)
    end
end

function M.GetFeature()
    return autoFishFeature
end

function M.ForceUnstuckFishing()
    return ForceUnstuckFishing()
end

function M.HardRespawnAndReturn()
    return HardRespawnAndReturn()
end

function M.SetFeatureManager(fm) FeatureManager = fm end
function M.SetUtils(u) Utils = u end
function M.SetWindow(w) Window = w end

function M.Init(tabs, featureManager, utils, window)
    FeatureManager = featureManager
    Utils = utils
    Window = window
    -- create UI controls inside tabs.TabMain (basic)
    local TabMain = tabs.TabMain
    local sec = TabMain:Section({ Title = "🎣 Fishing", TextXAlignment = "Left", TextSize = 17 })
    local mode_dd = TabMain:Dropdown({ Title="Fishing Mode", Values={"Perfect","OK","Mid"}, Value="Perfect", Callback=function(v) currentFishingMode=v end })
    local speed_dd = TabMain:Dropdown({ Title="Speed Mode", Values={"Normal","Fast","Very Fast"}, Value="Normal", Callback=function(v) currentSpeedMode=v end })
    local tgl = TabMain:Toggle({ Title="Auto Fishing", Desc="Automatic fishing", Default=false, Callback=function(state)
        if state then
            M.StartAutoFish()
        else
            M.StopAutoFish()
        end
    end})
end

return M
