-- Boost FPS - Low-Res "Press" (one-shot, no restore, no deletion)
-- Fokus: turunkan LOD/quality tanpa menghapus Decal/Texture/ColorMap
local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

-- ====== Tuning flags ======
local FORCE_LOW_GLOBAL_QUALITY = true   -- coba paksa SavedQualityLevel=1 via hidden props/fflags (jika tersedia)
local KEEP_SURFACE_DETAIL_MAPS  = true  -- true: JANGAN hapus Normal/Metalness/RoughnessMap (full preserve)
                                         -- false: buang detail maps (tetap simpan ColorMap) -> lebih ringan tapi bukan "press murni"

-- OPTIONAL (UI 2D, tidak memengaruhi world texture VRAM secara signifikan)
local AGGRESSIVE_GUI_PIXELATE   = false -- set ResampleMode=Pixelated pada ImageLabel/Button untuk kesan low-res UI

-- ====== Helper: pengecualian GUI agar WindUI / UcokKoplo tetap aman ======
local function isProtectedGui(inst)
    if not inst then return false end
    -- langsung cek nama instance (sederhana & cepat). 
    -- Melindungi WindUI, ikon UcokKoplo, atau GUI lain yang menyertakan string "WindUI" / "UcokKoplo"
    local s = tostring(inst)
    if s:find("WindUI") or s:find("UcokKoplo") or s:find("UcokKoploIconGui") then
        return true
    end

    -- cek ancestor names (mis. ImageLabel yang berada di dalam WindUI frame)
    local anc = inst
    while anc and typeof(anc) == "Instance" do
        local aname = tostring(anc)
        if aname:find("WindUI") or aname:find("UcokKoplo") then
            return true
        end
        anc = anc.Parent
    end

    -- juga skip CoreGui-protected GUI yang kemungkinan milik executor (extra safety)
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core and inst:IsDescendantOf(core) then
        -- jika descendant of CoreGui, only protect if ancestor name contains UcokKoplo/WindUI
        anc = inst
        while anc and typeof(anc) == "Instance" do
            local aname = tostring(anc)
            if aname:find("WindUI") or aname:find("UcokKoplo") then
                return true
            end
            anc = anc.Parent
        end
    end

    return false
end

local function tryForceEngineLowQuality()
    if not FORCE_LOW_GLOBAL_QUALITY then return end
    local ok1, _ = pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        -- matikan auto, set level serendah mungkin
        if ugs.AutoGraphicsQuality ~= nil then ugs.AutoGraphicsQuality = false end
        if ugs.SavedQualityLevel ~= nil then
            ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
        end
        -- Beberapa build pakai "GraphicsQualityLevel" (deprecated, tapi coba saja)
        if ugs.GraphicsQualityLevel ~= nil then
            ugs.GraphicsQualityLevel = 1
        end
    end)

    -- Executor-specific fallbacks
    if typeof(getfenv) == "function" then
        local ok2, _ = pcall(function()
            if typeof(sethiddenproperty) == "function" then
                local ugs = UserSettings():GetService("UserGameSettings")
                sethiddenproperty(ugs, "AutoGraphicsQuality", false)
                sethiddenproperty(ugs, "SavedQualityLevel", Enum.SavedQualitySetting.QualityLevel1)
            end
        end)

        local ok3, _ = pcall(function()
            if typeof(setfflag) == "function" then
                -- FFlag names bisa berubah; kita jaga-jaga beberapa commonly-used ones
                setfflag("DFFlagDebugForceLowTargetQualityLevel", "True")
                setfflag("FFlagDebugGraphicsPreferLowQualityTextures", "True")
                -- Beberapa executor support DFInt untuk target quality; kalau tidak, diabaikan
                -- setfflag("DFIntTaskSchedulerTargetFps", "60") -- opsional (fps behavior), bukan texture
            end
        end)
        return ok1 or ok2 or ok3
    end
    return ok1
end

local function applyLightingLite()
    -- Jangan hapus Sky/Atmosphere; cuma turunkan efek yang mahal (tanpa delete)
    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale  = 0 end)
    -- Naikkan ambient supaya gak gelap walau shadow off
    pcall(function() Lighting.Ambient        = Color3.fromRGB(170,170,170) end)
    pcall(function() Lighting.OutdoorAmbient = Color3.fromRGB(170,170,170) end)
    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") then
            pcall(function() ch.Enabled = false end)
        end
    end
end

local function applyTerrainLite()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    pcall(function() t.Decoration        = false end)
    pcall(function() t.WaterWaveSize     = 0     end)
    pcall(function() t.WaterWaveSpeed    = 0     end)
    pcall(function() t.WaterReflectance  = 0     end)
    -- Note: WaterTransparency = 1 bikin “hilang”; kita biarkan (press fokus texture, bukan visual total)
end

local function downgradeMaterialService()
    -- Material 2022 cenderung lebih berat; matikan agar fallback lebih ringan
    pcall(function() MaterialService.Use2022Materials = false end)
    if not KEEP_SURFACE_DETAIL_MAPS then
        -- Ini bukan "press" murni, tapi menghapus detail maps (bukan ColorMap)
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

local function isLocalCharacterDesc(x)
    local ch = LocalPlayer and LocalPlayer.Character
    return ch and x:IsDescendantOf(ch)
end

local function pressWorldTextures()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed += 1
        if (processed % 4000) == 0 then task.wait() end

        -- Jangan ganggu aset milik karakter kita
        if isLocalCharacterDesc(inst) then
            continue
        end

        -- 1) MeshPart → paksa LOD perf (mirip “low-res sampling”)
        if inst:IsA("MeshPart") then
            pcall(function()
                inst.RenderFidelity = Enum.RenderFidelity.Performance
                inst.UsePartColor   = true -- pastikan shading simple
            end)
            -- JANGAN sentuh TextureID / ColorMap (kita tidak menghapus)
        end

        -- 2) SurfaceAppearance → JANGAN hapus ColorMap. Optional: buang detail maps kalau flag off
        if inst:IsA("SurfaceAppearance") then
            if not KEEP_SURFACE_DETAIL_MAPS then
                pcall(function()
                    inst.NormalMap    = ""
                    inst.MetalnessMap = ""
                    inst.RoughnessMap = ""
                end)
            end
            -- Kalau ada property sampling/alpha mode, biarkan default; engine akan pilih mip low saat quality rendah
        end

        -- 3) Texture (permukaan) → kurangi frekuensi tiling (visual tampak “lebih blur/less detail”)
        if inst:IsA("Texture") then
            pcall(function()
                -- naikkan ukuran tile supaya per-unit area tekstur keliatan lebih “low-res”
                -- math.max: hanya menaikkan ketika nilai terlalu kecil; tidak akan menurunkan jika sudah besar
                inst.StudsPerTileU = math.max(inst.StudsPerTileU, 8)
                inst.StudsPerTileV = math.max(inst.StudsPerTileV, 8)
            end)
        end

        -- 4) Particle/Light/Trail/Beam → DISABLE (tidak delete), supaya GPU fokus raster sederhana
        if inst:IsA("ParticleEmitter") then
            pcall(function() inst.Enabled = false; inst.Rate = 0 end)
        elseif inst:IsA("Beam") or inst:IsA("Trail") then
            pcall(function() inst.Enabled = false end)
        elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            pcall(function() inst.Enabled = false; inst.Brightness = 0 end)
        end

        -- 5) BasePart shading lebih sederhana (tanpa menyentuh TextureId/Decal)
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
        -- Jangan ganggu WindUI / UcokKoplo GUI (menu script / ikon)
        if isProtectedGui(gui) then
            continue
        end

        if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
            pcall(function()
                if gui.ResampleMode then
                    gui.ResampleMode = Enum.ResamplerMode.Pixelated
                end
            end)
        end
    end
end

function boostfpsFeature:Init() return true end

function boostfpsFeature:Apply()
    -- 0) Coba paksa kualitas global ke low (ini yang paling “press” beneran)
    tryForceEngineLowQuality()

    -- 1) Turunkan lighting/terrain cost tanpa menghapus aset
    applyLightingLite()
    applyTerrainLite()
    downgradeMaterialService()

    -- 2) “Press” dunia: LOD/performance path + tiling coarser (tanpa hapus tekstur/color map)
    pressWorldTextures()

    -- 3) (opsional) UI jadi pixelated (kesan low-res, bukan VRAM saver)
    pixelate2DImages()

    -- 4) (opsional) fps cap kalau ada (bukan texture-related, tapi bantu stabil)
    if typeof(setfpscap) == "function" then pcall(function() setfpscap(60) end) end
end

function boostfpsFeature:Cleanup() end

return boostfpsFeature
