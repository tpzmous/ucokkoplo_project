-- Boost FPS - Low-Res "Press" (one-shot reapplicable on streaming/teleport)
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

-- ====== Internal state & connections ======
local applied = false
local connections = {}

-- ====== Helpers ======
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

-- Minimal GUI protection: hindari mengubah WindUI menu (nama instance mengandung "WindUI")
local function isProtectedGuiInstance(inst)
    if not inst then return false end
    local ok, s = pcall(function() return tostring(inst) end)
    if ok and type(s) == "string" then
        if s:lower():find("windui") then return true end
    end
    -- check ancestors too
    local anc = inst
    while anc and typeof(anc) == "Instance" do
        local ok2, n = pcall(function() return tostring(anc.Name) end)
        if ok2 and type(n) == "string" and n:lower():find("windui") then
            return true
        end
        anc = anc.Parent
    end
    return false
end

-- Apply logic to a single instance (extracted from pressWorldTextures)
local function applyToInstance(inst)
    if not inst or typeof(inst) ~= "Instance" then return end
    if isLocalCharacterDesc(inst) then return end

    -- MeshPart → paksa LOD perf
    if inst:IsA("MeshPart") then
        pcall(function()
            inst.RenderFidelity = Enum.RenderFidelity.Performance
            inst.UsePartColor   = true
        end)
        return
    end

    -- SurfaceAppearance → optional clear detail maps
    if inst:IsA("SurfaceAppearance") then
        if not KEEP_SURFACE_DETAIL_MAPS then
            pcall(function()
                inst.NormalMap    = ""
                inst.MetalnessMap = ""
                inst.RoughnessMap = ""
            end)
        end
        return
    end

    -- Texture → coarser tiling
    if inst:IsA("Texture") then
        pcall(function()
            inst.StudsPerTileU = math.max(inst.StudsPerTileU, 8)
            inst.StudsPerTileV = math.max(inst.StudsPerTileV, 8)
        end)
        return
    end

    -- Particle / Light / Trail / Beam → disable
    if inst:IsA("ParticleEmitter") then
        pcall(function() inst.Enabled = false; inst.Rate = 0 end)
        return
    elseif inst:IsA("Beam") or inst:IsA("Trail") then
        pcall(function() inst.Enabled = false end)
        return
    elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
        pcall(function() inst.Enabled = false; inst.Brightness = 0 end)
        return
    end

    -- BasePart shading simpler
    if inst:IsA("BasePart") then
        pcall(function()
            inst.Material    = Enum.Material.Plastic
            inst.Reflectance = 0
            inst.CastShadow  = false
        end)
        return
    end

    -- GUI pixelation (skip protected GUI)
    if AGGRESSIVE_GUI_PIXELATE and (inst:IsA("ImageLabel") or inst:IsA("ImageButton")) then
        if not isProtectedGuiInstance(inst) then
            pcall(function()
                if inst.ResampleMode then
                    inst.ResampleMode = Enum.ResamplerMode.Pixelated
                end
            end)
        end
        return
    end
end

-- Apply to all current descendants (same logic as original pressWorldTextures)
local function pressWorldTextures()
    local processed = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        processed += 1
        if (processed % 4000) == 0 then task.wait() end
        applyToInstance(inst)
    end
end

-- Event handlers to re-apply to newly streamed objects
local function onDescendantAdded(inst)
    -- small defer so properties exist
    task.defer(function()
        -- apply to the instance and its descendants
        pcall(function()
            applyToInstance(inst)
            for _, c in ipairs(inst:GetDescendants()) do
                applyToInstance(c)
            end
        end)
    end)
end

local function onWorkspaceChildAdded(child)
    -- if Terrain added later, reapply terrain tweak
    if child and (child:IsA("Terrain") or child.ClassName == "Terrain") then
        task.defer(function()
            pcall(applyTerrainLite)
        end)
    end
end

local function onLightingChildAdded(child)
    -- if post effect added later, disable it
    if child and child:IsA("PostEffect") then
        task.defer(function()
            pcall(function() child.Enabled = false end)
        end)
    end
end

-- Connect / disconnect helper
local function connectListeners()
    if connections.DescendantAdded == nil then
        connections.DescendantAdded = Workspace.DescendantAdded:Connect(onDescendantAdded)
    end
    if connections.WorkspaceChildAdded == nil then
        connections.WorkspaceChildAdded = Workspace.ChildAdded:Connect(onWorkspaceChildAdded)
    end
    if connections.LightingChildAdded == nil then
        connections.LightingChildAdded = Lighting.ChildAdded:Connect(onLightingChildAdded)
    end
end

local function disconnectListeners()
    for k,v in pairs(connections) do
        if v and v.Disconnect then
            pcall(function() v:Disconnect() end)
        end
        connections[k] = nil
    end
end

-- pixelate2DImages kept but protected
local function pixelate2DImages()
    if not AGGRESSIVE_GUI_PIXELATE then return end
    for _, gui in ipairs(game:GetDescendants()) do
        if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
            if isProtectedGuiInstance(gui) then
                continue
            end
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
    -- mark applied so listeners re-apply on new objects
    if applied then
        return
    end
    applied = true

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

    -- 4) connect listeners so new streamed objects are also pressed
    connectListeners()

    -- 5) (opsional) fps cap kalau ada
    if typeof(setfpscap) == "function" then pcall(function() setfpscap(60) end) end
end

function boostfpsFeature:Cleanup()
    -- stop re-applying to newly spawned instances
    applied = false
    disconnectListeners()
    -- note: original script was non-destructive and didn't restore; we also keep it simple (no restore)
end

return boostfpsFeature
