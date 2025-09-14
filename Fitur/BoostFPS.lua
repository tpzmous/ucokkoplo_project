-- Boost FPS - Ultra Extreme (hapus SEMUA efek, preserve GUI)
local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

-- Helper: skip GUI/menu
local function isMenuGui(inst)
    if not inst or typeof(inst) ~= "Instance" then return false end
    local function nameMatches(n)
        if not n or type(n) ~= "string" then return false end
        local nl = n:lower()
        return nl:find("windui") or nl:find("ucokkoplo")
    end
    if nameMatches(inst.Name) then return true end
    local anc = inst.Parent
    while anc and typeof(anc) == "Instance" do
        if nameMatches(anc.Name) then return true end
        anc = anc.Parent
    end
    return false
end

-- Force engine low quality
local function tryForceEngineLowQuality()
    pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        ugs.AutoGraphicsQuality = false
        ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
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

-- Lighting → full flat
local function applyLightingNuke()
    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale  = 0 end)
    pcall(function() Lighting.Ambient        = Color3.fromRGB(200,200,200) end)
    pcall(function() Lighting.OutdoorAmbient = Color3.fromRGB(200,200,200) end)

    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") or ch:IsA("Sky") or ch:IsA("Atmosphere") then
            pcall(function() ch.Enabled = false end)
        end
    end
end

-- Terrain → air hilang total
local function applyTerrainNuke()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    pcall(function() t.Decoration        = false end)
    pcall(function() t.WaterWaveSize     = 0 end)
    pcall(function() t.WaterWaveSpeed    = 0 end)
    pcall(function() t.WaterReflectance  = 0 end)
    pcall(function() t.WaterTransparency = 1 end) -- 100% invisible
end

-- Material → kosongkan SEMUA maps
local function applyMaterialNuke()
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

-- Dunia → hapus semua efek + simplify parts
local function stripWorldNuke()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed += 1
        if (processed % 4000) == 0 then task.wait() end

        if isMenuGui(inst) then continue end

        -- Semua efek off
        if inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail") then
            pcall(function() inst.Enabled = false end)
            if inst:IsA("ParticleEmitter") then pcall(function() inst.Rate = 0 end) end
        elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            pcall(function() inst.Enabled = false; inst.Brightness = 0 end)
        elseif inst:IsA("MeshPart") or inst:IsA("BasePart") then
            pcall(function()
                inst.Material     = Enum.Material.Plastic
                inst.CastShadow   = false
                inst.Reflectance  = 0
                if inst:IsA("MeshPart") then
                    inst.RenderFidelity = Enum.RenderFidelity.Performance
                    inst.UsePartColor   = true
                    inst.TextureID      = "" -- buang texture
                end
            end)
        elseif inst:IsA("SurfaceAppearance") then
            pcall(function()
                inst.ColorMap     = ""
                inst.NormalMap    = ""
                inst.MetalnessMap = ""
                inst.RoughnessMap = ""
            end)
        elseif inst:IsA("Texture") or inst:IsA("Decal") then
            pcall(function() inst.Texture = "" end)
        end
    end
end

function boostfpsFeature:Init() return true end

function boostfpsFeature:Apply()
    tryForceEngineLowQuality()
    applyLightingNuke()
    applyTerrainNuke()
    applyMaterialNuke()
    stripWorldNuke()

    if typeof(setfpscap) == "function" then
        pcall(function() setfpscap(60) end)
    end
end

function boostfpsFeature:Cleanup()
    warn("[BoostFPS] Cleanup not supported (restart game to restore).")
end

return boostfpsFeature
