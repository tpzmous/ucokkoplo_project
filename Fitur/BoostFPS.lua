-- Boost FPS - Extreme Clean (hapus efek berat, preserve GUI & textures)
local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

-- Helper: apakah instance termasuk GUI/menu kita (jangan sentuh)
local function isMenuGui(inst)
    if not inst or typeof(inst) ~= "Instance" then return false end

    -- Cek nama instance & ancestor names untuk "WindUI" / "UcokKoplo"
    local function nameMatches(n)
        if not n or type(n) ~= "string" then return false end
        local nl = n:lower()
        return nl:find("windui") or nl:find("ucokkoplo") or nl:find("ucokkoploicongui") or nl:find("ucokkoplopenbutton")
    end

    if nameMatches(inst.Name) then return true end

    local anc = inst.Parent
    while anc and typeof(anc) == "Instance" do
        if nameMatches(anc.Name) then
            return true
        end
        anc = anc.Parent
    end

    return false
end

-- Paksa kualitas serendah mungkin (fallbacks jika tersedia)
local function tryForceEngineLowQuality()
    pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        if ugs.AutoGraphicsQuality ~= nil then pcall(function() ugs.AutoGraphicsQuality = false end) end
        if ugs.SavedQualityLevel ~= nil then pcall(function() ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1 end) end
        if ugs.GraphicsQualityLevel ~= nil then pcall(function() ugs.GraphicsQualityLevel = 1 end) end
    end)

    -- executor fallbacks (harus di-wrap pcall)
    pcall(function()
        if typeof(sethiddenproperty) == "function" then
            local ugs = UserSettings():GetService("UserGameSettings")
            pcall(function() sethiddenproperty(ugs, "AutoGraphicsQuality", false) end)
            pcall(function() sethiddenproperty(ugs, "SavedQualityLevel", Enum.SavedQualitySetting.QualityLevel1) end)
        end
    end)

    pcall(function()
        if typeof(setfflag) == "function" then
            pcall(function() setfflag("DFFlagDebugForceLowTargetQualityLevel", "True") end)
            pcall(function() setfflag("FFlagDebugGraphicsPreferLowQualityTextures", "True") end)
        end
    end)
end

-- Lighting: matikan efek berat tetapi jangan hapus Sky/Atmosphere instances (cukup disable)
local function applyLightingExtreme()
    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale  = 0 end)
    pcall(function() Lighting.Ambient        = Color3.fromRGB(170,170,170) end)
    pcall(function() Lighting.OutdoorAmbient = Color3.fromRGB(170,170,170) end)

    for _, ch in ipairs(Lighting:GetChildren()) do
        -- disable post processing effects; keep Sky/Atmosphere but set them minimal (don't destroy)
        if ch:IsA("PostEffect") then
            pcall(function() ch.Enabled = false end)
        end
    end
end

-- Terrain: nonaktifkan dekorasi + buat air tidak bergerak dan (opsional) invisible
local function applyTerrainExtreme()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    pcall(function() t.Decoration        = false end)
    pcall(function() t.WaterWaveSize     = 0 end)
    pcall(function() t.WaterWaveSpeed    = 0 end)
    pcall(function() t.WaterReflectance  = 0 end)
    -- Buat air invisible supaya tidak render gerakan/efek (sesuai permintaan "hilangkan semua efek air")
    pcall(function() t.WaterTransparency = 1 end)
end

-- Material: paksa fallback lebih ringan (hapus detail maps tapi jaga ColorMap)
local function applyMaterialExtreme()
    pcall(function() MaterialService.Use2022Materials = false end)
    for _, mv in ipairs(MaterialService:GetChildren()) do
        if mv:IsA("MaterialVariant") then
            pcall(function()
                -- hapus detail maps untuk performance; biarkan ColorMap agar tampilan tetap valid
                if mv.NormalMap    ~= nil then mv.NormalMap    = "" end
                if mv.MetalnessMap ~= nil then mv.MetalnessMap = "" end
                if mv.RoughnessMap ~= nil then mv.RoughnessMap = "" end
            end)
        end
    end
end

-- Strip world effects (particles, beams, trails, lights) & simplify parts
local function stripWorldEffects()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed = processed + 1
        if (processed % 4000) == 0 then task.wait() end

        -- jangan ganggu GUI / menu yang keliru ter-parented (safety)
        if isMenuGui(inst) then
            continue
        end

        -- Particle / Beam / Trail
        if inst:IsA("ParticleEmitter") then
            pcall(function() inst.Enabled = false end)
            pcall(function() if inst.Rate then inst.Rate = 0 end end)
        elseif inst:IsA("Beam") or inst:IsA("Trail") then
            pcall(function() inst.Enabled = false end)
        -- Lights
        elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            pcall(function() inst.Enabled = false end)
            pcall(function() if inst.Brightness then inst.Brightness = 0 end end)
        -- MeshPart / BasePart simplification
        elseif inst:IsA("MeshPart") then
            pcall(function()
                inst.RenderFidelity = Enum.RenderFidelity.Performance
                inst.UsePartColor   = true
                inst.Material       = Enum.Material.Plastic
                if inst.Reflectance ~= nil then inst.Reflectance = 0 end
                if inst.CastShadow ~= nil then inst.CastShadow = false end
            end)
        elseif inst:IsA("BasePart") then
            pcall(function()
                inst.Material    = Enum.Material.Plastic
                if inst.Reflectance ~= nil then inst.Reflectance = 0 end
                if inst.CastShadow ~= nil then inst.CastShadow = false end
            end)
        end
    end
end

function boostfpsFeature:Init()
    return true
end

function boostfpsFeature:Apply()
    -- 0) paksa kualitas global low
    tryForceEngineLowQuality()

    -- 1) lighting & terrain (air non-moving & invisible)
    applyLightingExtreme()
    applyTerrainExtreme()

    -- 2) material fallback
    applyMaterialExtreme()

    -- 3) hilangkan semua efek dunia (particle, lights, beams) & simplifikasi parts
    stripWorldEffects()

    -- 4) optional fps cap jika tersedia
    if typeof(setfpscap) == "function" then
        pcall(function() setfpscap(60) end)
    end
end

function boostfpsFeature:Cleanup()
    -- Extreme-clean ini bersifat one-shot / non-restorable in-place.
    -- Jika kamu ingin restore, harus menyimpan state sebelum Apply().
    warn("[BoostFPS] Cleanup not implemented for extreme-clean mode. Restart the game to restore visuals.")
end

return boostfpsFeature
