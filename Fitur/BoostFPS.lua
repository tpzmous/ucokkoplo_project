-- Boost FPS - Low-Res (toggleable)
-- Versi ini menambahkan kemampuan ON/OFF (Apply/Cleanup/Toggle) dengan
-- menyimpan state asli sebelum diubah, lalu mengembalikannya saat dimatikan.
-- Catatan: beberapa change (UserSettings/FFlags/sethiddenproperty) bersifat
-- executor-dependent dan mungkin tidak sepenuhnya bisa di-restore di semua env.

local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

-- ====== Tuning flags ======
local FORCE_LOW_GLOBAL_QUALITY = true
local KEEP_SURFACE_DETAIL_MAPS  = true
local AGGRESSIVE_GUI_PIXELATE   = false

-- Internal saved state for restore
local savedState = {
    enabled = false,
    lighting = {},
    terrain = {},
    userSettings = {},
    instances = {},       -- [instance] = { propName = oldVal, ... }
    materialVariants = {},-- [instance] = { NormalMap=..., MetalnessMap=..., RoughnessMap=... }
}

-- Helpers: safe get/set and save
local function safeGet(inst, prop)
    local ok, val = pcall(function() return inst[prop] end)
    if ok then return val end
    return nil
end

local function safeSet(inst, prop, val)
    pcall(function() inst[prop] = val end)
end

local function saveProp(inst, prop)
    if not inst then return end
    if not savedState.instances[inst] then savedState.instances[inst] = {} end
    if savedState.instances[inst][prop] == nil then
        local old = safeGet(inst, prop)
        savedState.instances[inst][prop] = old
    end
end

local function saveLightingProp(prop)
    if savedState.lighting[prop] == nil then
        savedState.lighting[prop] = safeGet(Lighting, prop)
    end
end

local function saveTerrainProp(prop)
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    if savedState.terrain[prop] == nil then
        savedState.terrain[prop] = safeGet(t, prop)
    end
end

local function saveMaterialVariant(mv)
    if not mv then return end
    if savedState.materialVariants[mv] then return end
    savedState.materialVariants[mv] = {
        NormalMap = safeGet(mv, "NormalMap"),
        MetalnessMap = safeGet(mv, "MetalnessMap"),
        RoughnessMap = safeGet(mv, "RoughnessMap"),
    }
end

-- Try force low quality, but save previous values to restore later
local function tryForceEngineLowQuality()
    if not FORCE_LOW_GLOBAL_QUALITY then return end
    local ok, _ = pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        -- save previous
        if ugs.AutoGraphicsQuality ~= nil then savedState.userSettings.AutoGraphicsQuality = ugs.AutoGraphicsQuality end
        if ugs.SavedQualityLevel ~= nil then savedState.userSettings.SavedQualityLevel = ugs.SavedQualityLevel end
        if ugs.GraphicsQualityLevel ~= nil then savedState.userSettings.GraphicsQualityLevel = ugs.GraphicsQualityLevel end

        -- set to low
        if ugs.AutoGraphicsQuality ~= nil then ugs.AutoGraphicsQuality = false end
        if ugs.SavedQualityLevel ~= nil then ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1 end
        if ugs.GraphicsQualityLevel ~= nil then ugs.GraphicsQualityLevel = 1 end
    end)

    -- executor-specific fallbacks (also attempt to save then restore using hidden props if available)
    if typeof(getfenv) == "function" then
        pcall(function()
            if typeof(sethiddenproperty) == "function" then
                local ugs = UserSettings():GetService("UserGameSettings")
                -- save using safeGet if possible
                local ok1, prevAuto = pcall(function() return ugs.AutoGraphicsQuality end)
                if ok1 then savedState.userSettings.AutoGraphicsQuality = prevAuto end
                local ok2, prevSaved = pcall(function() return ugs.SavedQualityLevel end)
                if ok2 then savedState.userSettings.SavedQualityLevel = prevSaved end

                pcall(function()
                    sethiddenproperty(ugs, "AutoGraphicsQuality", false)
                    sethiddenproperty(ugs, "SavedQualityLevel", Enum.SavedQualitySetting.QualityLevel1)
                end)
            end
        end)

        pcall(function()
            if typeof(setfflag) == "function" then
                -- We cannot reliably read previous fflag values, so we won't attempt to restore them.
                -- Just set common flags that tend to push engine to low-quality.
                pcall(function() setfflag("DFFlagDebugForceLowTargetQualityLevel", "True") end)
                pcall(function() setfflag("FFlagDebugGraphicsPreferLowQualityTextures", "True") end)
            end
        end)
    end
end

-- Apply lite lighting while saving old state
local function applyLightingLite()
    saveLightingProp("GlobalShadows")
    saveLightingProp("EnvironmentSpecularScale")
    saveLightingProp("EnvironmentDiffuseScale")
    saveLightingProp("Ambient")
    saveLightingProp("OutdoorAmbient")

    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale  = 0 end)
    pcall(function() Lighting.Ambient        = Color3.fromRGB(170,170,170) end)
    pcall(function() Lighting.OutdoorAmbient = Color3.fromRGB(170,170,170) end)

    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") then
            if savedState.lighting.PostEffects == nil then savedState.lighting.PostEffects = {} end
            savedState.lighting.PostEffects[ch] = safeGet(ch, "Enabled")
            pcall(function() ch.Enabled = false end)
        end
    end
end

local function applyTerrainLite()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    saveTerrainProp("Decoration")
    saveTerrainProp("WaterWaveSize")
    saveTerrainProp("WaterWaveSpeed")
    saveTerrainProp("WaterReflectance")

    pcall(function() t.Decoration        = false end)
    pcall(function() t.WaterWaveSize     = 0     end)
    pcall(function() t.WaterWaveSpeed    = 0     end)
    pcall(function() t.WaterReflectance  = 0     end)
end

local function downgradeMaterialService()
    -- save
    savedState.materialService = savedState.materialService or {}
    savedState.materialService.Use2022Materials = safeGet(MaterialService, "Use2022Materials")

    pcall(function() MaterialService.Use2022Materials = false end)

    if not KEEP_SURFACE_DETAIL_MAPS then
        for _, mv in ipairs(MaterialService:GetChildren()) do
            if mv.ClassName == "MaterialVariant" then
                saveMaterialVariant(mv)
                pcall(function() mv.NormalMap    = "" end)
                pcall(function() mv.MetalnessMap = "" end)
                pcall(function() mv.RoughnessMap = "" end)
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

        if isLocalCharacterDesc(inst) then
            continue
        end

        if inst:IsA("MeshPart") then
            -- save
            saveProp(inst, "RenderFidelity")
            saveProp(inst, "UsePartColor")
            pcall(function()
                inst.RenderFidelity = Enum.RenderFidelity.Performance
                inst.UsePartColor   = true
            end)
        end

        if inst:IsA("SurfaceAppearance") then
            if not KEEP_SURFACE_DETAIL_MAPS then
                saveProp(inst, "NormalMap")
                saveProp(inst, "MetalnessMap")
                saveProp(inst, "RoughnessMap")
                pcall(function()
                    inst.NormalMap    = ""
                    inst.MetalnessMap = ""
                    inst.RoughnessMap = ""
                end)
            end
        end

        if inst:IsA("Texture") then
            saveProp(inst, "StudsPerTileU")
            saveProp(inst, "StudsPerTileV")
            pcall(function()
                inst.StudsPerTileU = math.max(inst.StudsPerTileU or 0, 8)
                inst.StudsPerTileV = math.max(inst.StudsPerTileV or 0, 8)
            end)
        end

        if inst:IsA("ParticleEmitter") then
            saveProp(inst, "Enabled")
            saveProp(inst, "Rate")
            pcall(function() inst.Enabled = false; inst.Rate = 0 end)
        elseif inst:IsA("Beam") or inst:IsA("Trail") then
            saveProp(inst, "Enabled")
            pcall(function() inst.Enabled = false end)
        elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            saveProp(inst, "Enabled")
            saveProp(inst, "Brightness")
            pcall(function() inst.Enabled = false; inst.Brightness = 0 end)
        end

        if inst:IsA("BasePart") then
            saveProp(inst, "Material")
            saveProp(inst, "Reflectance")
            saveProp(inst, "CastShadow")
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
            saveProp(gui, "ResampleMode")
            pcall(function()
                if gui.ResampleMode then gui.ResampleMode = Enum.ResamplerMode.Pixelated end
            end)
        end
    end
end

function boostfpsFeature:Init()
    return true
end

function boostfpsFeature:Apply()
    if savedState.enabled then return false, "already_enabled" end
    savedState.enabled = true

    -- 0) Force engine low
    tryForceEngineLowQuality()

    -- 1) Lighting/Terrain/Material
    applyLightingLite()
    applyTerrainLite()
    downgradeMaterialService()

    -- 2) World textures
    pressWorldTextures()

    -- 3) GUI pixelate
    pixelate2DImages()

    -- 4) optional fps cap
    if typeof(setfpscap) == "function" then pcall(function() setfpscap(60) end) end

    return true
end

function boostfpsFeature:Cleanup()
    if not savedState.enabled then return false, "not_enabled" end

    -- Restore instance properties
    for inst, props in pairs(savedState.instances) do
        if typeof(inst) == "Instance" and inst.Parent ~= nil then
            for propName, oldVal in pairs(props) do
                pcall(function() inst[propName] = oldVal end)
            end
        end
    end

    -- Restore material variants
    for mv, tbl in pairs(savedState.materialVariants) do
        if typeof(mv) == "Instance" and mv.Parent ~= nil then
            pcall(function() mv.NormalMap    = tbl.NormalMap    end)
            pcall(function() mv.MetalnessMap = tbl.MetalnessMap end)
            pcall(function() mv.RoughnessMap = tbl.RoughnessMap end)
        end
    end

    -- Restore lighting
    for k, v in pairs(savedState.lighting) do
        if k == "PostEffects" and type(v) == "table" then
            for ch, enabledVal in pairs(v) do
                if typeof(ch) == "Instance" and ch.Parent ~= nil then
                    pcall(function() ch.Enabled = enabledVal end)
                end
            end
        else
            pcall(function() Lighting[k] = v end)
        end
    end

    -- Restore terrain
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if t then
        for k, v in pairs(savedState.terrain) do
            pcall(function() t[k] = v end)
        end
    end

    -- Restore material service
    if savedState.materialService and savedState.materialService.Use2022Materials ~= nil then
        pcall(function() MaterialService.Use2022Materials = savedState.materialService.Use2022Materials end)
    end

    -- Restore user settings if possible
    pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        if savedState.userSettings.AutoGraphicsQuality ~= nil then
            pcall(function() ugs.AutoGraphicsQuality = savedState.userSettings.AutoGraphicsQuality end)
        end
        if savedState.userSettings.SavedQualityLevel ~= nil then
            pcall(function() ugs.SavedQualityLevel = savedState.userSettings.SavedQualityLevel end)
        end
        if savedState.userSettings.GraphicsQualityLevel ~= nil then
            pcall(function() ugs.GraphicsQualityLevel = savedState.userSettings.GraphicsQualityLevel end)
        end
    end)

    -- NOTE: we do NOT attempt to revert any setfflag calls because previous values were not captured

    -- Clear saved state
    savedState = {
        enabled = false,
        lighting = {},
        terrain = {},
        userSettings = {},
        instances = {},
        materialVariants = {},
    }

    return true
end

function boostfpsFeature:Toggle()
    if savedState.enabled then
        return self:Cleanup()
    else
        return self:Apply()
    end
end

function boostfpsFeature:IsEnabled()
    return savedState.enabled
end

return boostfpsFeature
