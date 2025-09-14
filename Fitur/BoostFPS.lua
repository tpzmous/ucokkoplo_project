-- Boost FPS - Low-Res "Press" (toggleable: Apply + Cleanup)
-- Fokus: turunkan LOD/quality tanpa menghapus Decal/Texture/ColorMap
local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local LocalPlayer     = Players.LocalPlayer

-- ====== Tuning flags ======
local FORCE_LOW_GLOBAL_QUALITY = true   -- paksa SavedQualityLevel=1
local KEEP_SURFACE_DETAIL_MAPS  = true  -- true = simpan Normal/Metal/RoughnessMap
local AGGRESSIVE_GUI_PIXELATE   = false -- pixelate UI (opsional)

-- ====== Backup state (supaya bisa restore) ======
local backupState = {
    lighting   = {},
    terrain    = {},
    materials  = {},
    parts      = {},
    surfaces   = {},
    textures   = {},
    guis       = {},
}

local function tryForceEngineLowQuality()
    if not FORCE_LOW_GLOBAL_QUALITY then return end
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
end

local function applyLightingLite()
    -- backup
    backupState.lighting.GlobalShadows = Lighting.GlobalShadows
    backupState.lighting.Ambient = Lighting.Ambient
    backupState.lighting.OutdoorAmbient = Lighting.OutdoorAmbient
    backupState.lighting.EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale
    backupState.lighting.EnvironmentDiffuseScale  = Lighting.EnvironmentDiffuseScale

    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale  = 0 end)
    pcall(function() Lighting.Ambient        = Color3.fromRGB(170,170,170) end)
    pcall(function() Lighting.OutdoorAmbient = Color3.fromRGB(170,170,170) end)
    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") then
            backupState.lighting[ch] = ch.Enabled
            pcall(function() ch.Enabled = false end)
        end
    end
end

local function restoreLighting()
    for k, v in pairs(backupState.lighting) do
        if typeof(k) == "Instance" and k:IsA("PostEffect") then
            pcall(function() k.Enabled = v end)
        else
            pcall(function() Lighting[k] = v end)
        end
    end
end

local function applyTerrainLite()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    backupState.terrain.Decoration       = t.Decoration
    backupState.terrain.WaterWaveSize    = t.WaterWaveSize
    backupState.terrain.WaterWaveSpeed   = t.WaterWaveSpeed
    backupState.terrain.WaterReflectance = t.WaterReflectance

    pcall(function() t.Decoration        = false end)
    pcall(function() t.WaterWaveSize     = 0     end)
    pcall(function() t.WaterWaveSpeed    = 0     end)
    pcall(function() t.WaterReflectance  = 0     end)
end

local function restoreTerrain()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    for k, v in pairs(backupState.terrain) do
        pcall(function() t[k] = v end)
    end
end

local function downgradeMaterialService()
    backupState.materials.Use2022Materials = MaterialService.Use2022Materials
    pcall(function() MaterialService.Use2022Materials = false end)

    if not KEEP_SURFACE_DETAIL_MAPS then
        for _, mv in ipairs(MaterialService:GetChildren()) do
            if mv.ClassName == "MaterialVariant" then
                backupState.materials[mv] = {
                    NormalMap = mv.NormalMap,
                    MetalnessMap = mv.MetalnessMap,
                    RoughnessMap = mv.RoughnessMap
                }
                pcall(function()
                    mv.NormalMap    = ""
                    mv.MetalnessMap = ""
                    mv.RoughnessMap = ""
                end)
            end
        end
    end
end

local function restoreMaterialService()
    if backupState.materials.Use2022Materials ~= nil then
        pcall(function()
            MaterialService.Use2022Materials = backupState.materials.Use2022Materials
        end)
    end
    for inst, data in pairs(backupState.materials) do
        if typeof(inst) == "Instance" and inst.ClassName == "MaterialVariant" then
            for k, v in pairs(data) do
                pcall(function() inst[k] = v end)
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
        if isLocalCharacterDesc(inst) then continue end

        -- MeshPart
        if inst:IsA("MeshPart") then
            backupState.parts[inst] = {
                RenderFidelity = inst.RenderFidelity,
                UsePartColor = inst.UsePartColor,
            }
            pcall(function()
                inst.RenderFidelity = Enum.RenderFidelity.Performance
                inst.UsePartColor   = true
            end)
        end

        -- SurfaceAppearance
        if inst:IsA("SurfaceAppearance") then
            if not KEEP_SURFACE_DETAIL_MAPS then
                backupState.surfaces[inst] = {
                    NormalMap    = inst.NormalMap,
                    MetalnessMap = inst.MetalnessMap,
                    RoughnessMap = inst.RoughnessMap,
                }
                pcall(function()
                    inst.NormalMap    = ""
                    inst.MetalnessMap = ""
                    inst.RoughnessMap = ""
                end)
            end
        end

        -- Texture
        if inst:IsA("Texture") then
            backupState.textures[inst] = {
                StudsPerTileU = inst.StudsPerTileU,
                StudsPerTileV = inst.StudsPerTileV,
            }
            pcall(function()
                inst.StudsPerTileU = math.max(inst.StudsPerTileU, 8)
                inst.StudsPerTileV = math.max(inst.StudsPerTileV, 8)
            end)
        end

        -- Particle / Light / Beam
        if inst:IsA("ParticleEmitter") then
            backupState.parts[inst] = { Enabled = inst.Enabled, Rate = inst.Rate }
            pcall(function() inst.Enabled = false; inst.Rate = 0 end)
        elseif inst:IsA("Beam") or inst:IsA("Trail") then
            backupState.parts[inst] = { Enabled = inst.Enabled }
            pcall(function() inst.Enabled = false end)
        elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            backupState.parts[inst] = { Enabled = inst.Enabled, Brightness = inst.Brightness }
            pcall(function() inst.Enabled = false; inst.Brightness = 0 end)
        end

        -- BasePart shading
        if inst:IsA("BasePart") then
            backupState.parts[inst] = {
                Material    = inst.Material,
                Reflectance = inst.Reflectance,
                CastShadow  = inst.CastShadow,
            }
            pcall(function()
                inst.Material    = Enum.Material.Plastic
                inst.Reflectance = 0
                inst.CastShadow  = false
            end)
        end
    end
end

local function restoreWorldTextures()
    for inst, props in pairs(backupState.parts) do
        if inst and inst.Parent then
            for k, v in pairs(props) do
                pcall(function() inst[k] = v end)
            end
        end
    end
    for inst, props in pairs(backupState.surfaces) do
        if inst and inst.Parent then
            for k, v in pairs(props) do
                pcall(function() inst[k] = v end)
            end
        end
    end
    for inst, props in pairs(backupState.textures) do
        if inst and inst.Parent then
            for k, v in pairs(props) do
                pcall(function() inst[k] = v end)
            end
        end
    end
end

local function pixelate2DImages()
    if not AGGRESSIVE_GUI_PIXELATE then return end
    for _, gui in ipairs(game:GetDescendants()) do
        if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
            backupState.guis[gui] = { ResampleMode = gui.ResampleMode }
            pcall(function()
                if gui.ResampleMode then
                    gui.ResampleMode = Enum.ResamplerMode.Pixelated
                end
            end)
        end
    end
end

local function restore2DImages()
    for gui, props in pairs(backupState.guis) do
        if gui and gui.Parent then
            pcall(function() gui.ResampleMode = props.ResampleMode end)
        end
    end
end

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

function boostfpsFeature:Cleanup()
    restoreLighting()
    restoreTerrain()
    restoreMaterialService()
    restoreWorldTextures()
    restore2DImages()
    -- kosongkan backup
    backupState = {lighting={}, terrain={}, materials={}, parts={}, surfaces={}, textures={}, guis={}}
end

return boostfpsFeature
