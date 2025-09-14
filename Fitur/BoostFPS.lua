-- BoostFPS.lua
-- Aggressive, persistent, toggleable "press" (non-destructive by default & GUI-safe)
-- Applies aggressively to current + newly streamed instances; supports restore.

local boostfpsFeature = {}
boostfpsFeature.__index = boostfpsFeature

-- Services
local Players         = game:GetService("Players")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")
local RunService      = game:GetService("RunService")

local LocalPlayer     = Players.LocalPlayer

-- ====== Tunable flags ======
local FORCE_LOW_GLOBAL_QUALITY = true    -- try to force engine quality low
local KEEP_SURFACE_DETAIL_MAPS  = true    -- true = preserve Normal/Metalness/Roughness maps
local AGGRESSIVE_GUI_PIXELATE   = false   -- pixelate non-protected GUI images
local WATER_MAKE_INVISIBLE      = false   -- if true, set Terrain.WaterTransparency = 1 (destructive visual)
local PROCESS_YIELD_EVERY       = 2000    -- yield after processing this many instances to avoid hitches

-- ====== Internal state ======
local enabled = false
local connections = {}
local backups = {
    lighting = {},
    terrain  = {},
    materials = {},    -- material variant backups per instance
    instances = {},    -- per-instance property backups: backups.instances[inst] = { Prop = value, ... }
    guis = {},
}

-- ====== Utilities (safe get/set) ======
local function safeGet(obj, prop)
    local ok, v = pcall(function() if obj and obj[prop] ~= nil then return obj[prop] end end)
    return ok and v or nil
end

local function safeSet(obj, prop, val)
    pcall(function()
        if obj and obj[prop] ~= nil then
            obj[prop] = val
        end
    end)
end

-- ====== GUI protection check (do not touch WindUI / UcokKoplo / your menu) ======
local function nameMatchesLower(n)
    if not n or type(n) ~= "string" then return false end
    local nl = n:lower()
    return nl:find("windui") or nl:find("ucokkoplo") or nl:find("ucokkoploicongui") or nl:find("ucokkoplopenbutton") or nl:find("ucokkoploopen")
end

local function isMenuGui(inst)
    if not inst or typeof(inst) ~= "Instance" then return false end
    -- If the instance or any ancestor name matches our UI identifiers, protect it
    if nameMatchesLower(inst.Name) then return true end
    local anc = inst.Parent
    while anc and typeof(anc) == "Instance" do
        if nameMatchesLower(anc.Name) then return true end
        anc = anc.Parent
    end

    -- Protect local player's PlayerGui descendants (common host for our UI)
    if LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui") and inst:IsDescendantOf(LocalPlayer.PlayerGui) then
        anc = inst
        while anc and typeof(anc) == "Instance" do
            if nameMatchesLower(anc.Name) then return true end
            anc = anc.Parent
        end
    end

    -- Protect CoreGui descendants unless they explicitly contain our name
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core and inst:IsDescendantOf(core) then
        anc = inst
        while anc and typeof(anc) == "Instance" do
            if nameMatchesLower(anc.Name) then return true end
            anc = anc.Parent
        end
    end

    return false
end

local function isLocalCharacterDesc(x)
    local ch = LocalPlayer and LocalPlayer.Character
    return ch and x:IsDescendantOf(ch)
end

-- ====== Force engine low quality (best-effort) ======
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

-- ====== Backup helpers for instances ======
local function ensureInstanceBackup(inst)
    if backups.instances[inst] == nil then backups.instances[inst] = {} end
end

local function backupProp(inst, propName)
    if not inst or not propName then return end
    ensureInstanceBackup(inst)
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

-- ====== Lighting apply & restore ======
local function applyLightingLite()
    local function save(k)
        if backups.lighting[k] == nil then
            local ok, v = pcall(function() return Lighting[k] end)
            if ok then backups.lighting[k] = v end
        end
    end

    save("GlobalShadows"); save("EnvironmentSpecularScale"); save("EnvironmentDiffuseScale")
    save("Ambient"); save("OutdoorAmbient"); save("Brightness"); save("FogStart"); save("FogEnd")

    safeSet(Lighting, "GlobalShadows", false)
    safeSet(Lighting, "EnvironmentSpecularScale", 0)
    safeSet(Lighting, "EnvironmentDiffuseScale", 0)
    safeSet(Lighting, "Ambient", Color3.fromRGB(170,170,170))
    safeSet(Lighting, "OutdoorAmbient", Color3.fromRGB(170,170,170))

    -- disable post effects but backup each one's Enabled state
    for _, ch in ipairs(Lighting:GetChildren()) do
        if ch:IsA("PostEffect") then
            local key = "post_" .. tostring(ch)
            if backups.lighting[key] == nil then
                local ok, en = pcall(function() return ch.Enabled end)
                if ok then backups.lighting[key] = en end
            end
            pcall(function() ch.Enabled = false end)
        end
    end
end

local function restoreLighting()
    for k, v in pairs(backups.lighting) do
        if tostring(k):sub(1,5) == "post_" then
            local ref = k:sub(6)
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

-- ====== Terrain apply & restore (robust) ======
backups.terrain = backups.terrain or {}

local function applyTerrainLite()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then return end

    if backups.terrain.Decoration == nil then backups.terrain.Decoration = safeGet(t, "Decoration") end
    if backups.terrain.WaterWaveSize == nil then backups.terrain.WaterWaveSize = safeGet(t, "WaterWaveSize") end
    if backups.terrain.WaterWaveSpeed == nil then backups.terrain.WaterWaveSpeed = safeGet(t, "WaterWaveSpeed") end
    if backups.terrain.WaterReflectance == nil then backups.terrain.WaterReflectance = safeGet(t, "WaterReflectance") end
    if backups.terrain.WaterTransparency == nil then backups.terrain.WaterTransparency = safeGet(t, "WaterTransparency") end

    safeSet(t, "Decoration", false)
    safeSet(t, "WaterWaveSize", 0)
    safeSet(t, "WaterWaveSpeed", 0)
    safeSet(t, "WaterReflectance", 0)
    if WATER_MAKE_INVISIBLE then
        safeSet(t, "WaterTransparency", 1)
    else
        -- make water less expensive (increase transparency to at least 0.6)
        local cur = safeGet(t, "WaterTransparency")
        if cur ~= nil then safeSet(t, "WaterTransparency", math.max(cur, 0.6)) end
    end
end

local function restoreTerrain()
    local t = Workspace:FindFirstChildOfClass("Terrain")
    if not t then
        backups.terrain = {}
        return
    end

    if backups.terrain.Decoration ~= nil then safeSet(t, "Decoration", backups.terrain.Decoration) end
    if backups.terrain.WaterWaveSize ~= nil then safeSet(t, "WaterWaveSize", backups.terrain.WaterWaveSize) end
    if backups.terrain.WaterWaveSpeed ~= nil then safeSet(t, "WaterWaveSpeed", backups.terrain.WaterWaveSpeed) end
    if backups.terrain.WaterReflectance ~= nil then safeSet(t, "WaterReflectance", backups.terrain.WaterReflectance) end
    if backups.terrain.WaterTransparency ~= nil then safeSet(t, "WaterTransparency", backups.terrain.WaterTransparency) end

    backups.terrain = {}
end

-- Workspace child added handler to re-apply when new Terrain or world appears
local function onWorkspaceChildAdded(child)
    if not child then return end
    if child:IsA("Terrain") or child.ClassName == "Terrain" then
        task.defer(function()
            task.wait(0.05)
            pcall(applyTerrainLite)
        end)
    end
end

-- ====== MaterialService apply & restore (non-destructive by default) ======
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
                        NormalMap = safeGet(mv, "NormalMap"),
                        MetalnessMap = safeGet(mv, "MetalnessMap"),
                        RoughnessMap = safeGet(mv, "RoughnessMap"),
                    }
                end
                pcall(function()
                    if mv.NormalMap ~= nil then mv.NormalMap = "" end
                    if mv.MetalnessMap ~= nil then mv.MetalnessMap = "" end
                    if mv.RoughnessMap ~= nil then mv.RoughnessMap = "" end
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
        if typeof(inst) == "Instance" and inst.ClassName == "MaterialVariant" and data then
            pcall(function()
                if data.NormalMap ~= nil then inst.NormalMap = data.NormalMap end
                if data.MetalnessMap ~= nil then inst.MetalnessMap = data.MetalnessMap end
                if data.RoughnessMap ~= nil then inst.RoughnessMap = data.RoughnessMap end
            end)
        end
    end
    backups.materials = {}
end

-- Handler when a MaterialVariant is added later
local function onMaterialVariantAdded(inst)
    if not inst or inst.ClassName ~= "MaterialVariant" then return end
    if not KEEP_SURFACE_DETAIL_MAPS then
        backups.materials[inst] = {
            NormalMap = safeGet(inst, "NormalMap"),
            MetalnessMap = safeGet(inst, "MetalnessMap"),
            RoughnessMap = safeGet(inst, "RoughnessMap"),
        }
        pcall(function()
            if inst.NormalMap ~= nil then inst.NormalMap = "" end
            if inst.MetalnessMap ~= nil then inst.MetalnessMap = "" end
            if inst.RoughnessMap ~= nil then inst.RoughnessMap = "" end
        end)
    end
end

-- Lighting child added handler for future PostEffects
local function onLightingChildAdded(inst)
    if not inst then return end
    if inst:IsA("PostEffect") then
        local key = "post_"..tostring(inst)
        if backups.lighting[key] == nil then
            local ok, en = pcall(function() return inst.Enabled end)
            if ok then backups.lighting[key] = en end
        end
        pcall(function() inst.Enabled = false end)
    end
end

-- ====== Single-instance apply (non-destructive backup) ======
local function applyToInstance(inst)
    if not inst or typeof(inst) ~= "Instance" then return end
    if isMenuGui(inst) then return end
    if isLocalCharacterDesc(inst) then return end

    -- Particles
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
        pcall(function() if inst.Material ~= nil then inst.Material = Enum.Material.Plastic end end)
        pcall(function() if inst.Reflectance ~= nil then inst.Reflectance = 0 end end)
        pcall(function() if inst.CastShadow ~= nil then inst.CastShadow = false end end)
        return
    end

    -- BasePart fallback
    if inst:IsA("BasePart") then
        backupProp(inst, "Material")
        backupProp(inst, "Reflectance")
        backupProp(inst, "CastShadow")
        pcall(function() if inst.Material ~= nil then inst.Material = Enum.Material.Plastic end end)
        pcall(function() if inst.Reflectance ~= nil then inst.Reflectance = 0 end end)
        pcall(function() if inst.CastShadow ~= nil then inst.CastShadow = false end end)
        return
    end

    -- SurfaceAppearance: optionally remove detail maps (non-destructive if KEEP_SURFACE_DETAIL_MAPS==false)
    if inst:IsA("SurfaceAppearance") then
        if not KEEP_SURFACE_DETAIL_MAPS then
            backupProp(inst, "NormalMap")
            backupProp(inst, "MetalnessMap")
            backupProp(inst, "RoughnessMap")
            pcall(function() if inst.NormalMap ~= nil then inst.NormalMap = "" end end)
            pcall(function() if inst.MetalnessMap ~= nil then inst.MetalnessMap = "" end end)
            pcall(function() if inst.RoughnessMap ~= nil then inst.RoughnessMap = "" end end)
        end
        return
    end

    -- Texture tiling tweak
    if inst:IsA("Texture") then
        backupProp(inst, "StudsPerTileU")
        backupProp(inst, "StudsPerTileV")
        pcall(function()
            inst.StudsPerTileU = math.max(inst.StudsPerTileU or 1, 8)
            inst.StudsPerTileV = math.max(inst.StudsPerTileV or 1, 8)
        end)
        return
    end

    -- GUI pixelation
    if AGGRESSIVE_GUI_PIXELATE then
        if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
            if not isMenuGui(inst) then
                backupProp(inst, "ResampleMode")
                pcall(function() if inst.ResampleMode then inst.ResampleMode = Enum.ResamplerMode.Pixelated end end)
            end
        end
    end
end

-- Restore single instance
local function restoreInstance(inst)
    if not inst then return end
    local entry = backups.instances[inst]
    if not entry then return end
    for prop, val in pairs(entry) do
        pcall(function() inst[prop] = val end)
    end
    backups.instances[inst] = nil
end

-- Apply to all existing descendants (safe)
local function applyToAllExisting()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed = processed + 1
        pcall(function() applyToInstance(inst) end)
        if processed % PROCESS_YIELD_EVERY == 0 then task.wait() end
    end
end

-- DescendantAdded handler (apply to new instances)
local function onDescendantAdded(inst)
    -- apply to the new instance and its descendants (best-effort)
    pcall(function()
        applyToInstance(inst)
        for _, child in ipairs(inst:GetDescendants()) do
            applyToInstance(child)
        end
    end)
end

-- ====== Listeners management ======
local function connectListeners()
    if connections.DescendantAdded == nil then
        connections.DescendantAdded = Workspace.DescendantAdded:Connect(onDescendantAdded)
    end
    if connections.WorkspaceChild == nil then
        connections.WorkspaceChild = Workspace.ChildAdded:Connect(onWorkspaceChildAdded)
    end
    if connections.LightingChild == nil then
        connections.LightingChild = Lighting.ChildAdded:Connect(onLightingChildAdded)
    end
    if connections.MaterialAdded == nil then
        connections.MaterialAdded = MaterialService.ChildAdded:Connect(onMaterialVariantAdded)
    end
    -- Protect against local player's character spawns (we intentionally don't press local character)
    if LocalPlayer and connections.CharacterAdded == nil then
        connections.CharacterAdded = LocalPlayer.CharacterAdded:Connect(function(char)
            -- small wait to let character fully instantiate if needed
            task.wait(0.1)
        end)
    end
end

local function disconnectListeners()
    for k, c in pairs(connections) do
        if c and type(c.Disconnect) == "function" then
            pcall(function() c:Disconnect() end)
        end
        connections[k] = nil
    end
end

-- ====== Public API: Apply & Cleanup (toggle) ======
function boostfpsFeature:Apply()
    if enabled then return true end
    enabled = true

    tryForceEngineLowQuality()
    applyLightingLite()
    applyTerrainLite()
    applyMaterialLite()

    applyToAllExisting()
    connectListeners()

    if typeof(setfpscap) == "function" then
        pcall(function() setfpscap(60) end)
    end

    return true
end

function boostfpsFeature:Cleanup()
    if not enabled then return true end
    enabled = false

    -- Disconnect listeners so we don't re-apply while restoring
    disconnectListeners()

    -- Restore instances (best-effort). Collect keys first to avoid mutation issues.
    local insts = {}
    for inst, _ in pairs(backups.instances) do
        table.insert(insts, inst)
    end
    for _, inst in ipairs(insts) do
        if inst and inst.Parent then
            pcall(function() restoreInstance(inst) end)
        else
            backups.instances[inst] = nil
        end
    end

    -- Restore MaterialService, Terrain, Lighting
    restoreMaterialService()
    restoreTerrain()
    restoreLighting()

    -- Clear any remaining backup containers
    backups.instances = {}
    backups.materials = {}
    backups.lighting = {}
    backups.terrain = {}

    return true
end

function boostfpsFeature:Init()
    return true
end

return boostfpsFeature
