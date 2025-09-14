-- Boost FPS - PRESS Edition (Low-Res, one-shot, no restore)
-- Fokus: turunkan LOD/quality tanpa menghapus Decal/Texture/ColorMap

local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

-- ====== Service Refs ======
local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

-- ====== Config Flags ======
local FORCE_LOW_GLOBAL_QUALITY = true
local KEEP_SURFACE_DETAIL_MAPS = true
local AGGRESSIVE_GUI_PIXELATE  = false

-- ====== Helpers ======
local function tryForceEngineLowQuality()
    if not FORCE_LOW_GLOBAL_QUALITY then return end
    pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        ugs.AutoGraphicsQuality = false
        ugs.SavedQualityLevel   = Enum.SavedQualitySetting.QualityLevel1
        ugs.GraphicsQualityLevel = 1
    end)
    pcall(function()
        if typeof(sethiddenproperty) == "function" then
            local ugs = UserSettings():GetService("UserGameSettings")
            sethiddenproperty(ugs, "AutoGraphicsQuality", false)
            sethiddenproperty(ugs, "SavedQualityLevel", Enum.SavedQualitySetting.QualityLevel1)
        end
    end)
    pcall(function()
        if typeof(setfflag) == "function" then
            setfflag("DFFlagDebugForceLowTargetQualityLevel", "True")
            setfflag("FFlagDebugGraphicsPreferLowQualityTextures", "True")
        end
    end)
end

local function applyLightingLite()
    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale  = 0 end)
    pcall(function() Lighting.Ambient        = Color3.fromRGB(170,170,170) end)
    pcall(function() Lighting.OutdoorAmbient = Color3.fromRGB(170,170,170) end)
    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") then pcall(function() ch.Enabled = false end) end
    end
end

local function applyTerrainLite()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    pcall(function() t.Decoration = false end)
    pcall(function() t.WaterWaveSize = 0 end)
    pcall(function() t.WaterWaveSpeed = 0 end)
    pcall(function() t.WaterReflectance = 0 end)
end

local function downgradeMaterialService()
    pcall(function() MaterialService.Use2022Materials = false end)
    if not KEEP_SURFACE_DETAIL_MAPS then
        for _, mv in ipairs(MaterialService:GetChildren()) do
            if mv:IsA("MaterialVariant") then
                pcall(function()
                    mv.NormalMap    = ""
                    mv.MetalnessMap = ""
                    mv.RoughnessMap = ""
                end)
            end
        end
    end
end

local function isLocalCharacterDesc(x)
    return LocalPlayer and LocalPlayer.Character and x:IsDescendantOf(LocalPlayer.Character)
end

local function pressWorldTextures()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed += 1
        if processed % 4000 == 0 then task.wait() end
        if isLocalCharacterDesc(inst) then continue end

        if inst:IsA("MeshPart") then
            pcall(function()
                inst.RenderFidelity = Enum.RenderFidelity.Performance
                inst.UsePartColor   = true
            end)
        elseif inst:IsA("SurfaceAppearance") and not KEEP_SURFACE_DETAIL_MAPS then
            pcall(function()
                inst.NormalMap    = ""
                inst.MetalnessMap = ""
                inst.RoughnessMap = ""
            end)
        elseif inst:IsA("Texture") then
            pcall(function()
                inst.StudsPerTileU = math.max(inst.StudsPerTileU, 8)
                inst.StudsPerTileV = math.max(inst.StudsPerTileV, 8)
            end)
        elseif inst:IsA("ParticleEmitter") then
            pcall(function() inst.Enabled = false; inst.Rate = 0 end)
        elseif inst:IsA("Beam") or inst:IsA("Trail") then
            pcall(function() inst.Enabled = false end)
        elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            pcall(function() inst.Enabled = false; inst.Brightness = 0 end)
        end

        if inst:IsA("BasePart") then
            pcall(function()
                inst.Material    = Enum.Material.Plastic
                inst.Reflectance = 0
                inst.CastShadow  = false
            end)
        end
    end
end

local function pixelate2DImages()
    if not AGGRESSIVE_GUI_PIXELATE then return end
    for _, gui in ipairs(game:GetDescendants()) do
        if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
            pcall(function() gui.ResampleMode = Enum.ResamplerMode.Pixelated end)
        end
    end
end

-- ====== Feature API ======
function boostfpsFeature:Init() return true end

function boostfpsFeature:Apply()
    tryForceEngineLowQuality()
    applyLightingLite()
    applyTerrainLite()
    downgradeMaterialService()
    pressWorldTextures()
    pixelate2DImages()
    if typeof(setfpscap) == "function" then pcall(function() setfpscap(60) end) end
end

function boostfpsFeature:Cleanup() end

-- ====== Auto-register ======
local function tryAutoRegister()
    if type(FeatureManager) ~= "table" then return end
    if type(FeatureManager.Register) == "function" then
        pcall(function() FeatureManager:Register("BoostFPS", boostfpsFeature) end)
        pcall(function() FeatureManager:Register("boostfps", boostfpsFeature) end)
    elseif type(FeatureManager.register) == "function" then
        pcall(function() FeatureManager:register("BoostFPS", boostfpsFeature) end)
        pcall(function() FeatureManager:register("boostfps", boostfpsFeature) end)
    elseif type(FeatureManager.LoadedFeatures) == "table" then
        FeatureManager.LoadedFeatures["BoostFPS"] = boostfpsFeature
        FeatureManager.LoadedFeatures["boostfps"] = boostfpsFeature
    end
end

pcall(tryAutoRegister)

return boostfpsFeature
