-- Boost FPS - Low-Res "Press" (one-shot, no restore, no deletion)
-- Fokus: turunkan LOD/quality tanpa menghapus Decal/Texture/ColorMap
-- Kompatibel sebagai feature yang dikembalikan (return table) untuk FeatureManager

local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

-- ====== Services ======
local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

-- ====== Tuning flags ======
local FORCE_LOW_GLOBAL_QUALITY = true   -- coba paksa SavedQualityLevel=1 via hidden props/fflags (jika tersedia)
local KEEP_SURFACE_DETAIL_MAPS  = true  -- true: JANGAN hapus Normal/Metalness/RoughnessMap (full preserve)
                                         -- false: buang detail maps (tetap simpan ColorMap) -> lebih ringan tapi bukan "press murni"
local AGGRESSIVE_GUI_PIXELATE   = false -- set ResampleMode=Pixelated pada ImageLabel/Button untuk kesan low-res UI
local TARGET_FPS                = 60    -- fps cap opsional (jika executor support)

-- ====== Engine-level quality helpers ======
local function tryForceEngineLowQuality()
    if not FORCE_LOW_GLOBAL_QUALITY then return false end

    local ok1 = false
    pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        -- matikan auto, set level serendah mungkin bila ada
        if ugs.AutoGraphicsQuality ~= nil then
            ugs.AutoGraphicsQuality = false
        end
        if ugs.SavedQualityLevel ~= nil then
            ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
        end
        if ugs.GraphicsQualityLevel ~= nil then
            ugs.GraphicsQualityLevel = 1
        end
        ok1 = true
    end)

    -- Executor-specific fallbacks (some executors expose these)
    local ok2 = false
    pcall(function()
        if typeof(sethiddenproperty) == "function" then
            local ugs = UserSettings():GetService("UserGameSettings")
            sethiddenproperty(ugs, "AutoGraphicsQuality", false)
            sethiddenproperty(ugs, "SavedQualityLevel", Enum.SavedQualitySetting.QualityLevel1)
            ok2 = true
        end
    end)

    local ok3 = false
    pcall(function()
        if typeof(setfflag) == "function" then
            -- beberapa FFlag umum untuk prefer low quality
            pcall(function() setfflag("DFFlagDebugForceLowTargetQualityLevel", "True") end)
            pcall(function() setfflag("FFlagDebugGraphicsPreferLowQualityTextures", "True") end)
            ok3 = true
        end
    end)

    return ok1 or ok2 or ok3
end

-- ====== Lighting tweaks (non-destructive) ======
local function applyLightingLite()
    -- jangan hapus Sky/Atmosphere; cukup matikan efek mahal
    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale  = 0 end)
    pcall(function() Lighting.Ambient        = Color3.fromRGB(170,170,170) end)
    pcall(function() Lighting.OutdoorAmbient = Color3.fromRGB(170,170,170) end)

    -- matikan post effects (Bloom, SunRays, SSAO, dll) tanpa menghapus instance
    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") then
            pcall(function() ch.Enabled = false end)
        end
    end
end

-- ====== Terrain tweaks (non-destructive) ======
local function applyTerrainLite()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    pcall(function() t.Decoration       = false end)
    pcall(function() t.WaterWaveSize    = 0 end)
    pcall(function() t.WaterWaveSpeed   = 0 end)
    pcall(function() t.WaterReflectance = 0 end)
    -- jangan set WaterTransparency jadi 1 karena itu menghilangkan air sepenuhnya
end

-- ====== MaterialService downgrade (non-destructive unless flag) ======
local function downgradeMaterialService()
    pcall(function() MaterialService.Use2022Materials = false end)

    if not KEEP_SURFACE_DETAIL_MAPS then
        -- ini menghapus hanya detail maps; ColorMap dipertahankan
        for _, mv in ipairs(MaterialService:GetChildren()) do
            if mv.ClassName == "MaterialVariant" then
                pcall(function()
                    mv.NormalMap    = ""
                    mv.MetalnessMap = ""
                    mv.RoughnessMap = ""
                end)
            end
        end
    end
end

-- ====== Utility: apakah instance adalah bagian karakter lokal ======
local function isLocalCharacterDesc(x)
    local ch = LocalPlayer and LocalPlayer.Character
    return ch and x:IsDescendantOf(ch)
end

-- ====== Core: tekan world textures (LOD / disable effects, tanpa hapus ColorMap/Decal) ======
local function pressWorldTextures()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed += 1
        -- yield sesekali untuk mencegah freeze pada loop besar
        if (processed % 4000) == 0 then task.wait() end

        -- jangan ganggu aset milik karakter kita
        if isLocalCharacterDesc(inst) then
            continue
        end

        -- 1) MeshPart → paksa LOD performance, shading sederhana
        if inst:IsA("MeshPart") then
            pcall(function()
                inst.RenderFidelity = Enum.RenderFidelity.Performance
                inst.UsePartColor   = true
                -- intentionally DO NOT modify TextureID/ColorMap here (preserve visual assets)
            end)
        end

        -- 2) SurfaceAppearance → opsional: hapus detail maps tergantung flag
        if inst:IsA("SurfaceAppearance") then
            if not KEEP_SURFACE_DETAIL_MAPS then
                pcall(function()
                    inst.NormalMap    = ""
                    inst.MetalnessMap = ""
                    inst.RoughnessMap = ""
                end)
            end
            -- biarkan ColorMap utuh (engine akan memilih mip rendah saat kualitas rendah)
        end

        -- 3) Texture (permukaan tiling) → kurangi frekuensi tiling supaya tampak blur
        if inst:IsA("Texture") then
            pcall(function()
                -- pastikan StudsPerTile minimal lebih besar agar terlihat lebih 'low-res'
                inst.StudsPerTileU = math.max((inst.StudsPerTileU or 1), 8)
                inst.StudsPerTileV = math.max((inst.StudsPerTileV or 1), 8)
            end)
        end

        -- 4) Particle/Beam/Trail/Light → disable (tidak delete)
        if inst:IsA("ParticleEmitter") then
            pcall(function() inst.Enabled = false; inst.Rate = 0 end)
        elseif inst:IsA("Beam") or inst:IsA("Trail") then
            pcall(function() inst.Enabled = false end)
        elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            pcall(function() inst.Enabled = false; inst.Brightness = 0 end)
        end

        -- 5) BasePart → shading sederhana, no reflect/shadow
        if inst:IsA("BasePart") then
            pcall(function()
                inst.Material    = Enum.Material.Plastic
                inst.Reflectance = 0
                inst.CastShadow  = false
            end)
        end
    end
end

-- ====== Optional: pixelate 2D UI (cosmetic) ======
local function pixelate2DImages()
    if not AGGRESSIVE_GUI_PIXELATE then return end
    for _, gui in ipairs(game:GetDescendants()) do
        if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
            pcall(function()
                if gui.ResampleMode then
                    gui.ResampleMode = Enum.ResamplerMode.Pixelated
                end
            end)
        end
    end
end

-- ====== Feature API (Init/Apply/Cleanup) ======
function boostfpsFeature:Init()
    -- tidak perlu inisialisasi berat di sini; kembalikan true agar loader anggap success
    return true
end

function boostfpsFeature:Apply()
    -- 0) coba paksa engine ke low quality jika tersedia
    tryForceEngineLowQuality()

    -- 1) turunkan lighting & terrain cost (tanpa menghapus aset)
    applyLightingLite()
    applyTerrainLite()
    downgradeMaterialService()

    -- 2) tekan dunia: LOD/perf path + tiling coarser (tanpa hapus ColorMap/Decal)
    pressWorldTextures()

    -- 3) (opsional) pixelate UI untuk efek low-res
    pixelate2DImages()

    -- 4) fps cap kalau ada (opsional)
    if typeof(setfpscap) == "function" then
        pcall(function() setfpscap(TARGET_FPS or 60) end)
    end
end

function boostfpsFeature:Cleanup()
    -- Versi press: tidak ada restore terperinci (one-shot). Kosong supaya loader tidak error jika dipanggil.
end

-- ====== (Optional) Auto-register helper ======
-- Jika environment memiliki FeatureManager global, coba daftarkan agar GetFeature() bisa langsung pakai nama ini.
pcall(function()
    if type(FeatureManager) ~= "table" then return end
    -- support beberapa API register yang mungkin ada
    if type(FeatureManager.Register) == "function" then
        pcall(function() FeatureManager:Register("BoostFPS", boostfpsFeature) end)
        pcall(function() FeatureManager:Register("boostfps", boostfpsFeature) end)
        return
    end
    if type(FeatureManager.register) == "function" then
        pcall(function() FeatureManager:register("BoostFPS", boostfpsFeature) end)
        pcall(function() FeatureManager:register("boostfps", boostfpsFeature) end)
        return
    end
    if type(FeatureManager.LoadedFeatures) == "table" then
        FeatureManager.LoadedFeatures["BoostFPS"] = boostfpsFeature
        FeatureManager.LoadedFeatures["boostfps"] = boostfpsFeature
    end
end)

return boostfpsFeature
