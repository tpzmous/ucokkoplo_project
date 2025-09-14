-- BoostFPS.lua
-- Aggressive, persistent, toggleable "press" (non-destructive & GUI-safe)
-- Applies aggressively to current + newly streamed instances; supports restore.
local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local RunService      = game:GetService("RunService")

local LocalPlayer     = Players.LocalPlayer

-- Tuning
local FORCE_LOW_GLOBAL_QUALITY = true
local KEEP_SURFACE_DETAIL_MAPS  = true  -- jika false, hapus normal/metal/roughness pada MaterialVariant (non-destructive better = true)
local AGGRESSIVE_GUI_PIXELATE   = false -- optional pixelate UI (keputusan visual saja)

-- Internal state
local enabled = false
local connections = {}
local backups = {
    lighting = {},
    terrain  = {},
    instances = {}, -- { [instance] = {prop = value, ...} }
    guis = {},
    materials = {},
}

-- Safety: jangan ganggu GUI menu tertentu
local function isMenuGui(inst)
    if not inst or typeof(inst) ~= "Instance" then return false end
    local function nameMatches(n)
        if not n or type(n) ~= "string" then return false end
        local nl = n:lower()
        return nl:find("windui") or nl:find("ucokkoplo") or nl:find("ucokkoploicongui") or nl:find("ucokkoplopenbutton")
    end
    if nameMatches(inst.Name) then return true end
    local anc = inst.Parent
    while anc and typeof(anc) == "Instance" do
        if nameMatches(anc.Name) then return true end
        anc = anc.Parent
    end
    -- also protect CoreGui descendants unless they explicitly contain our name
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core and inst:IsDescendantOf(core) then
        anc = inst
        while anc and typeof(anc) == "Instance" do
            if nameMatches(anc.Name) then return true end
            anc = anc.Parent
        end
    end
    -- also protect PlayerGui of local player (common place for our UI)
    if LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui") and inst:IsDescendantOf(LocalPlayer.PlayerGui) then
        -- check ancestors for our UI names
        anc = inst
        while anc and typeof(anc) == "Instance" do
            if nameMatches(anc.Name) then return true end
            anc = anc.Parent
        end
    end

    return false
end

local function isLocalCharacterDesc(x)
    local ch = LocalPlayer and LocalPlayer.Character
    return ch and x:IsDescendantOf(ch)
end

-- Try force engine low-quality (best-effort)
local function tryForceEngineLowQuality()
    if not FORCE_LOW_GLOBAL_QUALITY then return end
    pcall(function()
        local ugs = UserSettings():GetService("UserGameSettings")
        if ugs.AutoGraphicsQuality ~= nil then pcall(function() ugs.AutoGraphicsQuality = false end) end
        if ugs.SavedQualityLevel ~= nil then pcall(function() ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1 end) end
        if ugs.GraphicsQualityLevel ~= nil then pcall(function() ugs.GraphicsQualityLevel = 1 end) end
    end)
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

-- Backup & apply helpers
local function backupProp(inst, propName)
    if not inst or not propName then return end
    -- create table
    backups.instances[inst] = backups.instances[inst] or {}
    if backups.instances[inst][propName] == nil then
        local ok, val = pcall(function() return inst[propName] end)
        if ok then backups.instances[inst][propName] = val end
    end
end

local function restoreProp(inst, propName)
    if not inst or not propName then return end
    local entry = backups.instances[inst]
    if entry and entry[propName] ~= nil then
        pcall(function() inst[propName] = entry[propName] end)
    end
end

local function clearBackupForInstance(inst)
    backups.instances[inst] = nil
end

-- Lighting backup + apply/restore
local function applyLightingLite()
    -- save few important lighting props (if not saved)
    local function save(k)
        if backups.lighting[k] == nil then
            local ok, v = pcall(function() return Lighting[k] end)
            if ok then backups.lighting[k] = v end
        end
    end

    save("GlobalShadows"); save("EnvironmentSpecularScale"); save("EnvironmentDiffuseScale")
    save("Ambient"); save("OutdoorAmbient"); save("Brightness"); save("FogStart"); save("FogEnd")

    pcall(function() Lighting.GlobalShadows = false end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0 end)
    pcall(function() Lighting.EnvironmentDiffuseScale = 0 end)
    pcall(function() Lighting.Ambient = Color3.fromRGB(170,170,170) end)
    pcall(function() Lighting.OutdoorAmbient = Color3.fromRGB(170,170,170) end)
    -- disable post effects
    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") then
            -- backup individual posteffect enabled state
            if backups.lighting["post_"..tostring(ch)] == nil then
                local ok, en = pcall(function() return ch.Enabled end)
                if ok then backups.lighting["post_"..tostring(ch)] = en end
            end
            pcall(function() ch.Enabled = false end)
        end
    end
end

local function restoreLighting()
    for k, v in pairs(backups.lighting) do
        if tostring(k):sub(1,5) == "post_" then
            local ref = k:sub(6)
            -- find instance by tostring reference (best-effort)
            for _, ch in ipairs(Lighting:GetChildren()) do
                if tostring(ch) == ref then
                    pcall(function() ch.Enabled = v end)
                    break
                end
            end
        else
            pcall(function() Lighting[k] = v end)
        end
    end
    backups.lighting = {}
end

-- Terrain backup + apply/restore
local function applyTerrainLite()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    if backups.terrain.Decoration == nil then backups.terrain.Decoration = t.Decoration end
    if backups.terrain.WaterWaveSize == nil then backups.terrain.WaterWaveSize = t.WaterWaveSize end
    if backups.terrain.WaterWaveSpeed == nil then backups.terrain.WaterWaveSpeed = t.WaterWaveSpeed end
    if backups.terrain.WaterReflectance == nil then backups.terrain.WaterReflectance = t.WaterReflectance end
    if backups.terrain.WaterTransparency == nil then backups.terrain.WaterTransparency = t.WaterTransparency end

    pcall(function() t.Decoration = false end)
    pcall(function() t.WaterWaveSize = 0 end)
    pcall(function() t.WaterWaveSpeed = 0 end)
    pcall(function() t.WaterReflectance = 0 end)
    -- keep WaterTransparency unless we want invisible; we set to current to avoid destructive behavior
    -- but we will make it a bit more opaque to reduce expensive rendering (optional)
    pcall(function() t.WaterTransparency = math.max(t.WaterTransparency or 0, 0.6) end)
end

local function restoreTerrain()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end
    pcall(function() if backups.terrain.Decoration ~= nil then t.Decoration = backups.terrain.Decoration end end)
    pcall(function() if backups.terrain.WaterWaveSize ~= nil then t.WaterWaveSize = backups.terrain.WaterWaveSize end end)
    pcall(function() if backups.terrain.WaterWaveSpeed ~= nil then t.WaterWaveSpeed = backups.terrain.WaterWaveSpeed end end)
    pcall(function() if backups.terrain.WaterReflectance ~= nil then t.WaterReflectance = backups.terrain.WaterReflectance end end)
    pcall(function() if backups.terrain.WaterTransparency ~= nil then t.WaterTransparency = backups.terrain.WaterTransparency end end)
    backups.terrain = {}
end

-- MaterialService: apply lighter fallback (non-destructive unless flag false)
local function applyMaterialLite()
    if backups.materials.Use2022Materials == nil then
        local ok, v = pcall(function() return MaterialService.Use2022Materials end)
        if ok then backups.materials.Use2022Materials = v end
    end
    pcall(function() MaterialService.Use2022Materials = false end)

    if not KEEP_SURFACE_DETAIL_MAPS then
        for _, mv in ipairs(MaterialService:GetChildren()) do
            if mv.ClassName == "MaterialVariant" then
                if backups.materials[mv] == nil then
                    backups.materials[mv] = {
                        NormalMap = mv.NormalMap,
                        MetalnessMap = mv.MetalnessMap,
                        RoughnessMap = mv.RoughnessMap,
                    }
                end
                pcall(function()
                    mv.NormalMap = ""
                    mv.MetalnessMap = ""
                    mv.RoughnessMap = ""
                end)
            end
        end
    end
end

local function restoreMaterialService()
    if backups.materials.Use2022Materials ~= nil then
        pcall(function() MaterialService.Use2022Materials = backups.materials.Use2022Materials end)
    end
    for inst, data in pairs(backups.materials) do
        if typeof(inst) == "Instance" and inst.ClassName == "MaterialVariant" then
            pcall(function()
                inst.NormalMap = data.NormalMap
                inst.MetalnessMap = data.MetalnessMap
                inst.RoughnessMap = data.RoughnessMap
            end)
        end
    end
    backups.materials = {}
end

-- Apply modifications to a single instance (non-destructive: backup old props)
local function applyToInstance(inst)
    if not inst or not typeof(inst) == "Instance" then return end
    if isMenuGui(inst) then return end
    if isLocalCharacterDesc(inst) then return end

    -- ParticleEmitter
    if inst:IsA("ParticleEmitter") then
        backupProp(inst, "Enabled")
        backupProp(inst, "Rate")
        pcall(function() inst.Enabled = false end)
        pcall(function() if inst.Rate ~= nil then inst.Rate = 0 end end)
        return
    end

    -- Beam / Trail
    if inst:IsA("Beam") or inst:IsA("Trail") then
        backupProp(inst, "Enabled")
        pcall(function() inst.Enabled = false end)
        return
    end

    -- Lights
    if inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
        backupProp(inst, "Enabled")
        backupProp(inst, "Brightness")
        pcall(function() inst.Enabled = false end)
        pcall(function() if inst.Brightness ~= nil then inst.Brightness = 0 end end)
        return
    end

    -- MeshPart
    if inst:IsA("MeshPart") then
        backupProp(inst, "RenderFidelity")
        backupProp(inst, "UsePartColor")
        backupProp(inst, "Material")
        backupProp(inst, "Reflectance")
        backupProp(inst, "CastShadow")
        pcall(function() inst.RenderFidelity = Enum.RenderFidelity.Performance end)
        pcall(function() inst.UsePartColor = true end)
        pcall(function() inst.Material = Enum.Material.Plastic end)
        pcall(function() if inst.Reflectance ~= nil then inst.Reflectance = 0 end end)
        pcall(function() if inst.CastShadow ~= nil then inst.CastShadow = false end end)
        return
    end

    -- BasePart (covers MeshPart fallback too)
    if inst:IsA("BasePart") then
        backupProp(inst, "Material")
        backupProp(inst, "Reflectance")
        backupProp(inst, "CastShadow")
        pcall(function() inst.Material = Enum.Material.Plastic end)
        pcall(function() if inst.Reflectance ~= nil then inst.Reflectance = 0 end end)
        pcall(function() if inst.CastShadow ~= nil then inst.CastShadow = false end end)
        return
    end

    -- SurfaceAppearance (do NOT clear ColorMap if present)
    if inst:IsA("SurfaceAppearance") then
        if not KEEP_SURFACE_DETAIL_MAPS then
            -- backup detail maps
            backupProp(inst, "NormalMap")
            backupProp(inst, "MetalnessMap")
            backupProp(inst, "RoughnessMap")
            pcall(function() inst.NormalMap = "" end)
            pcall(function() inst.MetalnessMap = "" end)
            pcall(function() inst.RoughnessMap = "" end)
        end
        return
    end

    -- Texture tiling tweaks
    if inst:IsA("Texture") then
        backupProp(inst, "StudsPerTileU")
        backupProp(inst, "StudsPerTileV")
        pcall(function()
            inst.StudsPerTileU = math.max(inst.StudsPerTileU or 1, 8)
            inst.StudsPerTileV = math.max(inst.StudsPerTileV or 1, 8)
        end)
        return
    end

    -- GUI pixelation (skip protected GUIs)
    if AGGRESSIVE_GUI_PIXELATE then
        if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
            if not isMenuGui(inst) then
                backupProp(inst, "ResampleMode")
                pcall(function() if inst.ResampleMode then inst.ResampleMode = Enum.ResamplerMode.Pixelated end end)
            end
        end
    end
end

-- Restore single instance from backup
local function restoreInstance(inst)
    if not inst or backups.instances[inst] == nil then return end
    for prop, val in pairs(backups.instances[inst]) do
        pcall(function() inst[prop] = val end)
    end
    backups.instances[inst] = nil
end

-- Apply to all existing descendants (safe)
local function applyToAllExisting()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed = processed + 1
        if (processed % 2000) == 0 then task.wait() end
        pcall(function() applyToInstance(inst) end)
    end
end

-- Event handlers to ensure persistency
local function onDescendantAdded(inst)
    pcall(function()
        applyToInstance(inst)
    end)
end

local function onLightingChildAdded(inst)
    pcall(function()
        if inst:IsA("PostEffect") then
            -- immediately disable heavy post effects (backup)
            if backups.lighting["post_"..tostring(inst)] == nil then
                local ok, en = pcall(function() return inst.Enabled end)
                if ok then backups.lighting["post_"..tostring(inst)] = en end
            end
            pcall(function() inst.Enabled = false end)
        end
    end)
end

local function onMaterialVariantAdded(inst)
    pcall(function()
        if inst.ClassName == "MaterialVariant" then
            if not KEEP_SURFACE_DETAIL_MAPS then
                backups.materials[inst] = {
                    NormalMap = inst.NormalMap,
                    MetalnessMap = inst.MetalnessMap,
                    RoughnessMap = inst.RoughnessMap,
                }
                pcall(function()
                    inst.NormalMap = ""
                    inst.MetalnessMap = ""
                    inst.RoughnessMap = ""
                end)
            end
        end
    end)
end

-- Connect persistent listeners
local function connectListeners()
    if connections.DescendantAdded then return end
    connections.DescendantAdded = Workspace.DescendantAdded:Connect(onDescendantAdded)
    connections.LightingChild = Lighting.ChildAdded:Connect(onLightingChildAdded)
    connections.MaterialAdded = MaterialService.ChildAdded:Connect(onMaterialVariantAdded)
    -- if players respawn local character (we skip touching local character anyway)
    connections.CharacterAdded = nil
    if LocalPlayer then
        connections.CharacterAdded = LocalPlayer.CharacterAdded:Connect(function(char)
            -- small delay to allow character to fully load; we avoid pressing local char parts
            task.wait(0.2)
            -- safety: ensure the script doesn't accidentally touch the character by reapplying to new descendants
        end)
    end
end

local function disconnectListeners()
    for k, c in pairs(connections) do
        if c and c.Disconnect then
            pcall(function() c:Disconnect() end)
        end
        connections[k] = nil
    end
end

-- Public API: Apply / Cleanup (toggle)
function boostfpsFeature:Apply()
    if enabled then return true end
    enabled = true

    tryForceEngineLowQuality()
    applyLightingLite()
    applyTerrainLite()
    applyMaterialLite()

    applyToAllExisting()
    connectListeners()

    -- optional fps cap
    if typeof(setfpscap) == "function" then pcall(function() setfpscap(60) end) end

    return true
end

function boostfpsFeature:Cleanup()
    if not enabled then return true end
    enabled = false

    -- disconnect listeners first to avoid re-applying while we restore
    disconnectListeners()

    -- Restore instances (best-effort)
    for inst, _ in pairs(backups.instances) do
        if inst and inst.Parent then
            pcall(function() restoreInstance(inst) end)
        else
            backups.instances[inst] = nil
        end
    end

    -- restore materialservice & terrain & lighting
    restoreMaterialService()
    restoreTerrain()
    restoreLighting()

    -- clear any remaining backups
    backups.instances = {}
    backups.materials = {}
    backups.lighting = {}
    backups.terrain = {}

    return true
end

function boostfpsFeature:Init() return true end

return boostfpsFeature
