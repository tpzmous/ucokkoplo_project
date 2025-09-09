-- misc_controller.lua
local M = {}
local HttpService = game:GetService("HttpService")

local fishWebhookFeature = nil
local currentWebhookUrl = ""
local selectedWebhookFishTypes = {}

function M.Init(tabs, featureManager, utils)
    local TabMisc = tabs.TabMisc
    local webhookfish_in = TabMisc:Input({ Title = "Discord Webhook URL", Desc = "Paste your Discord webhook URL here", Value = "", Placeholder = "https://discord.com/api/webhooks/...", Type = "Input", Callback = function(input)
        currentWebhookUrl = input
        if fishWebhookFeature and fishWebhookFeature.SetWebhookUrl then pcall(function() fishWebhookFeature:SetWebhookUrl(input) end) end
    end})
    local WEBHOOK_FISH_OPTIONS = {"Common","Uncommon","Rare","Epic","Legendary","Mythic","Secret"}
    local webhookfish_ddm = TabMisc:Dropdown({ Title="Select Rarity", Values = WEBHOOK_FISH_OPTIONS, Value = {"Legendary","Mythic","Secret"}, Multi = true, AllowNone = true, Callback = function(options)
        selectedWebhookFishTypes = {}
        for _,o in ipairs(options) do selectedWebhookFishTypes[o] = true end
        if fishWebhookFeature and fishWebhookFeature.SetSelectedFishTypes then pcall(function() fishWebhookFeature:SetSelectedFishTypes(selectedWebhookFishTypes) end) end
    end})
    local webhookfish_tgl = TabMisc:Toggle({ Title="Enable Fish Webhook", Desc="Automatically send notifications when catching selected fish types", Default=false, Callback=function(state)
        if state then
            if currentWebhookUrl == "" then utils.Notify("Error","Please enter webhook URL first","x",3); return webhookfish_tgl:Set(false) end
            if not fishWebhookFeature then fishWebhookFeature = featureManager.LoadFeature("FishWebhook", { urlInput = webhookfish_in, fishTypesDropdown = webhookfish_ddm }) end
            if fishWebhookFeature and fishWebhookFeature.Start then pcall(function() fishWebhookFeature:Start({ webhookUrl = currentWebhookUrl, selectedFishTypes = selectedWebhookFishTypes }) end) end
        else
            if fishWebhookFeature and fishWebhookFeature.Stop then pcall(function() fishWebhookFeature:Stop() end); utils.Notify("Webhook Stopped","Fish notifications disabled","info",2) end
        end
    end})
    -- Vuln toggles (Equip Diving Gear / Fish Radar)
    local eqoxygentank_tgl = TabMisc:Toggle({ Title = "Equip Diving Gear", Desc = "No Need have Diving Gear", Default = false, Callback = function(state)
        local f = featureManager.GetFeature("AutoGearOxyRadar")
        if state then
            if not f then f = featureManager.LoadFeature("AutoGearOxyRadar") end
            if f and f.EnableOxygen then pcall(function() f:EnableOxygen(true) end) end
        else
            if f and f.EnableOxygen then pcall(function() f:EnableOxygen(false) end) end
        end
    end})
    local eqfishradar_tgl = TabMisc:Toggle({ Title = "Enable Fish Radar", Desc = "No Need have Fish Radar", Default = false, Callback = function(state)
        local f = featureManager.GetFeature("AutoGearOxyRadar")
        if state then
            if not f then f = featureManager.LoadFeature("AutoGearOxyRadar") end
            if f and f.EnableRadar then pcall(function() f:EnableRadar(true) end) end
        else
            if f and f.EnableRadar then pcall(function() f:EnableRadar(false) end) end
        end
    end})
end

return M
