-- Boost FPS - Extreme Mode (destroy all visual effects, textures, decals, lights, particles)
local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

local function tryForceEngineLowQuality()
    pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        if ugs.AutoGraphicsQuality ~= nil then ugs.AutoGraphicsQuality = false end
        if ugs.SavedQualityLevel ~= nil then
            ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
        end
        if ugs.GraphicsQualityLevel ~= nil then
            ugs.GraphicsQualityLevel = 1
        end
    end)
    if typeof(setfflag) == "function" then
        pcall(function()
            setfflag("DFFlagDebugForceLowTargetQualityLevel", "True")
            setfflag("FFlagDebugGraphicsPreferLowQualityTextures", "True")
        end)
    end
end

local function applyLightingExtreme()
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.Brightness = 0
        Lighting.EnvironmentSpecularScale = 0
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.FogEnd = 9e9
        Lighting.FogStart = 9e9
        Lighting.OutdoorAmbient = Color3.new(1,1,1)
        Lighting.Ambient = Color3.new(1,1,1)
    end)
    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") or ch:IsA("Sky") or ch:IsA("Atmosphere") then
            pcall(function() ch:Destroy() end)
        end
    end
end

local function applyTerrainExtreme()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    pcall(function()
        t.Decoration = false
        t.WaterWaveSize = 0
        t.WaterWaveSpeed = 0
        t.WaterReflectance = 0
        t.WaterTransparency = 1
    end)
end

local function applyMaterialServiceExtreme()
    pcall(function() MaterialService.Use2022Materials = false end)
    for _, mv in ipairs(MaterialService:GetChildren()) do
        if mv.ClassName == "MaterialVariant" then
            pcall(function()
                mv.ColorMap = ""
                mv.NormalMap = ""
                mv.MetalnessMap = ""
                mv.RoughnessMap = ""
            end)
        end
    end
end

local function isLocalCharacterDesc(x)
    local ch = LocalPlayer and LocalPlayer.Character
    return ch and x:IsDescendantOf(ch)
end

local function pressWorldExtreme()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed += 1
        if (processed % 4000) == 0 then task.wait() end
        if isLocalCharacterDesc(inst) then continue end

        -- MeshPart / BasePart
        if inst:IsA("BasePart") then
            pcall(function()
                inst.Material    = Enum.Material.Plastic
                inst.Reflectance = 0
                inst.CastShadow  = false
                if inst:IsA("MeshPart") then
                    inst.RenderFidelity = Enum.RenderFidelity.Performance
                    inst.TextureID = ""
                    inst.UsePartColor = true
                end
            end)
        end

        -- SurfaceAppearance
        if inst:IsA("SurfaceAppearance") then
            pcall(function()
                inst.ColorMap    = ""
                inst.NormalMap   = ""
                inst.MetalnessMap= ""
                inst.RoughnessMap= ""
            end)
        end

        -- Texture / Decal
        if inst:IsA("Texture") or inst:IsA("Decal") then
            pcall(function() inst.Texture = "" end)
        end

        -- Particle / Trail / Beam / Smoke / Fire
        if inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail")
            or inst:IsA("Smoke") or inst:IsA("Fire") then
            pcall(function() inst.Enabled = false; inst.Rate = 0 end)
        end

        -- Lights
        if inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            pcall(function() inst.Enabled = false; inst.Brightness = 0 end)
        end
    end
end

local function applyUIExtreme()
    for _, gui in ipairs(game:GetDescendants()) do
        if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
            pcall(function() gui.Image = "" end)
        elseif gui:IsA("ViewportFrame") then
            pcall(function() gui:ClearAllChildren() end)
        end
    end
end

function boostfpsFeature:Init() return true end

function boostfpsFeature:Apply()
    tryForceEngineLowQuality()
    applyLightingExtreme()
    applyTerrainExtreme()
    applyMaterialServiceExtreme()
    pressWorldExtreme()
    applyUIExtreme()
    if typeof(setfpscap) == "function" then pcall(function() setfpscap(60) end) end
end

function boostfpsFeature:Cleanup()
    -- Extreme mode = irreversible (cannot restore deleted data)
    warn("[BoostFPS Extreme] Cleanup is not supported. Restart game to restore graphics.")
end

return boostfpsFeature
