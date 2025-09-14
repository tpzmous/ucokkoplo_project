-- BoostFPS - PRESS Total Edition
-- Fokus: ringankan render dengan menghapus detail maps, ColorMap, dan Decals
-- One-shot (sekali Apply, tanpa restore)

local BoostFPS = {}
BoostFPS.__index = BoostFPS

-- ==== Services ====
local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

-- ==== Config ====
local FORCE_LOW_QUALITY = true
local PIXELATE_GUI      = false

-- ==== Helpers ====
local function forceLowQuality()
    if not FORCE_LOW_QUALITY then return end
    pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        ugs.AutoGraphicsQuality = false
        ugs.SavedQualityLevel   = Enum.SavedQualitySetting.QualityLevel1
        ugs.GraphicsQualityLevel = 1
    end)
end

local function tweakLighting()
    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale  = 0 end)
    pcall(function() Lighting.Ambient = Color3.fromRGB(170,170,170) end)
    for _, fx in ipairs(Lighting:GetChildren()) do
        if fx:IsA("PostEffect") then pcall(function() fx.Enabled = false end) end
    end
end

local function tweakTerrain()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    pcall(function() t.Decoration = false end)
    pcall(function() t.WaterWaveSize = 0 end)
    pcall(function() t.WaterWaveSpeed = 0 end)
    pcall(function() t.WaterReflectance = 0 end)
end

local function tweakMaterials()
    pcall(function() MaterialService.Use2022Materials = false end)
    for _, mv in ipairs(MaterialService:GetChildren()) do
        if mv:IsA("MaterialVariant") then
            pcall(function()
                mv.ColorMap     = ""
                mv.NormalMap    = ""
                mv.MetalnessMap = ""
                mv.RoughnessMap = ""
            end)
        end
    end
end

local function pressWorkspace()
    local skipChar = LocalPlayer and LocalPlayer.Character
    local count = 0
    for _, obj in ipairs(Workspace:GetDescendants()) do
        count += 1
        if count % 4000 == 0 then task.wait() end
        if skipChar and obj:IsDescendantOf(skipChar) then continue end

        if obj:IsA("MeshPart") then
            pcall(function()
                obj.RenderFidelity = Enum.RenderFidelity.Performance
                obj.UsePartColor   = true
                obj.TextureID      = "" -- hapus texture
            end)

        elseif obj:IsA("SurfaceAppearance") then
            pcall(function()
                obj.ColorMap     = ""
                obj.NormalMap    = ""
                obj.MetalnessMap = ""
                obj.RoughnessMap = ""
            end)

        elseif obj:IsA("Decal") or obj:IsA("Texture") then
            pcall(function()
                obj.Texture = "" -- hapus decal/texture
            end)

        elseif obj:IsA("ParticleEmitter") or obj:IsA("Beam") or obj:IsA("Trail") then
            pcall(function() obj.Enabled = false end)

        elseif obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight") then
            pcall(function() obj.Enabled = false; obj.Brightness = 0 end)

        elseif obj:IsA("BasePart") then
            pcall(function()
                obj.Material    = Enum.Material.Plastic
                obj.CastShadow  = false
                obj.Reflectance = 0
            end)
        end
    end
end

local function pixelateGui()
    if not PIXELATE_GUI then return end
    for _, gui in ipairs(game:GetDescendants()) do
        if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
            pcall(function() gui.ResampleMode = Enum.ResamplerMode.Pixelated end)
        end
    end
end

-- ==== API ====
function BoostFPS:Init() return true end

function BoostFPS:Apply()
    forceLowQuality()
    tweakLighting()
    tweakTerrain()
    tweakMaterials()
    pressWorkspace()
    pixelateGui()
    pcall(function() if setfpscap then setfpscap(60) end end)
end

function BoostFPS:Cleanup() end

-- ==== Auto-register ke FeatureManager ====
pcall(function()
    if type(FeatureManager) == "table" then
        if type(FeatureManager.Register) == "function" then
            FeatureManager:Register("BoostFPS", BoostFPS)
            FeatureManager:Register("boostfps", BoostFPS)
        elseif type(FeatureManager.LoadedFeatures) == "table" then
            FeatureManager.LoadedFeatures["BoostFPS"] = BoostFPS
            FeatureManager.LoadedFeatures["boostfps"] = BoostFPS
        end
    end
end)

return BoostFPS
