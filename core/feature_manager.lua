-- feature_manager.lua 
-- feature_manager.lua
local M = {}
M.LoadedFeatures = {}

local FEATURE_URLS = {
    AutoFish           = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/antiafk.lua", 
    AutoSellFish       = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/autosellfish.lua",
    AutoTeleportIsland = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/autoteleportisland.lua",
    FishWebhook        = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/fishwebhook.lua",
    AutoBuyWeather     = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/autobuyweather.lua",
    AutoBuyBait        = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/autobuybait.lua",
    AutoBuyRod         = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/autobuyrod.lua",
    AutoTeleportEvent  = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/autoteleportevent.lua",
    AutoGearOxyRadar   = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/autogearoxyradar.lua",
    AntiAfk            = "https://raw.githubusercontent.com/tpzmous/ucokkoplo_project/refs/heads/main/Fitur/antiafk.lua"
}

local function notify(title, content, icon, dur)
    pcall(function()
        local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
        WindUI:Notify({ Title = title, Content = content, Icon = icon or "info", Duration = dur or 3 })
    end)
end

function M.LoadFeature(featureName, controls)
    local url = FEATURE_URLS[featureName]
    if not url then
        notify("Error", "Feature URL not found: "..tostring(featureName), "x", 3)
        return nil
    end
    local success, feature = pcall(function()
        return loadstring(game:HttpGet(url))()
    end)
    if success and type(feature) == "table" and feature.Init then
        local okInit = pcall(feature.Init, feature, controls)
        if okInit then
            M.LoadedFeatures[featureName] = feature
            notify("Success", featureName.." loaded", "check", 2)
            return feature
        end
    end
    notify("Load Failed", "Could not load "..featureName, "x", 3)
    return nil
end

function M.GetFeature(name)
    return M.LoadedFeatures[name]
end

return M
