-- shop_controller.lua
local M = {}
local HttpService = game:GetService("HttpService")

local FeatureManager
local Utils

function M.Init(tabs, featureManager, utils)
    FeatureManager = featureManager
    Utils = utils
    local TabShop = tabs.TabShop

    -- Rods section
    local shoprod_sec = TabShop:Section({ Title = "🎣 Rod", TextXAlignment = "Left", TextSize = 17 })
    local selectedRods = {}
    local autobuyrod = nil
    local shoprod_ddm = TabShop:Dropdown({
        Title = "Select Rod",
        Values = { "Luck Rod","Carbon Rod","Grass Rod","Demascus Rod","Ice Rod","Lucky Rod","Midnight Rod","Steampunk Rod","Chrome Rod","Astral Rod","Ares Rod","Angler Rod"},
        Value = {},
        Multi = true,
        AllowNone = true,
        Callback = function(options)
            selectedRods = options or {}
            if autobuyrod and autobuyrod.SetSelectedRodsByName then pcall(function() autobuyrod:SetSelectedRodsByName(selectedRods) end) end
        end
    })
    TabShop:Button({ Title="💰 Buy Rod", Desc="Purchase selected rods (one-time buy)", Locked=false, Callback=function()
        if not autobuyrod then
            autobuyrod = FeatureManager.LoadFeature("AutoBuyRod", { rodsDropdown = shoprod_ddm })
        end
        if not autobuyrod then Utils.Notify("Error","AutoBuyRod feature not available","x",3); return end
        if not selectedRods or #selectedRods==0 then Utils.Notify("Info","Select at least 1 Rod first","info",3); return end
        pcall(function()
            if autobuyrod.SetSelectedRodsByName then autobuyrod:SetSelectedRodsByName(selectedRods) end
            if autobuyrod.Start then autobuyrod:Start({ rodList = selectedRods, interDelay = 0.5 }) end
            Utils.Notify("Success","Rod purchase completed!","check",3)
        end)
    end})

    -- Baits section
    local shopbait_sec = TabShop:Section({ Title = "🪱 Baits", TextXAlignment = "Left", TextSize = 17 })
    local selectedBaits = {}
    local autobuybait = nil
    local shopbait_ddm = TabShop:Dropdown({
        Title = "Select Bait",
        Values = {"Topwater Bait","Luck Bait","Midnight Bait","Nature Bait","Chroma Bait","Dark Matter Bait","Corrupt Bait","Aether Bait"},
        Value = {},
        Multi = true,
        AllowNone = true,
        Callback = function(options) selectedBaits = options or {} end
    })
    TabShop:Button({ Title="💰 Buy Bait", Desc="Purchase selected baits (one-time buy)", Locked=false, Callback=function()
        if not autobuybait then autobuybait = FeatureManager.LoadFeature("AutoBuyBait", { dropdown = shopbait_ddm }) end
        if not autobuybait then Utils.Notify("Error","AutoBuyBait feature not available","x",3); return end
        if not selectedBaits or #selectedBaits==0 then Utils.Notify("Info","Select at least 1 Bait first","info",3); return end
        pcall(function()
            if autobuybait.SetSelectedBaitsByName then autobuybait:SetSelectedBaitsByName(selectedBaits) end
            if autobuybait.Start then autobuybait:Start({ baitList = selectedBaits, interDelay = 0.5 }) end
            Utils.Notify("Success","Bait purchase completed!","check",3)
        end)
    end})

    -- Weather section
    local shopweather_sec = TabShop:Section({ Title = "🌦 Weather", TextXAlignment = "Left", TextSize = 17 })
    local weatherFeature = nil
    local selectedWeather = {}
    local BUYABLE_WEATHER = {"Shark Hunt","Wind","Snow","Radiant","Storm","Cloudy"}
    local shopweather_ddm = TabShop:Dropdown({ Title="Select Weather", Values=BUYABLE_WEATHER, Value={}, Multi=true, AllowNone=true, Callback=function(opts)
        selectedWeather = {}
        for _,o in ipairs(opts) do selectedWeather[o]=true end
    end})
    TabShop:Toggle({ Title="Auto Buy Weather", Default=false, Callback=function(state)
        if state then
            if not weatherFeature then
                weatherFeature = FeatureManager.LoadFeature("AutoBuyWeather", { weatherDropdownMulti = shopweather_ddm })
            end
            if not weatherFeature then Utils.Notify("Failed","Could not load AutoBuyWeather","x",3); return end
            if next(selectedWeather)==nil then Utils.Notify("Info","Select atleast 1 Weather","info",3); return end
            pcall(function() if weatherFeature.Start then weatherFeature:Start({ weatherList = selectedWeather }) end end)
        else
            if weatherFeature and weatherFeature.Stop then pcall(function() weatherFeature:Stop() end) end
        end
    end})
end

return M
