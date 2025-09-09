-- teleport_controller.lua
local M = {}

function M.Init(tabs, featureManager, utils)
    local TabTeleport = tabs.TabTeleport
    local teleisland_dd = TabTeleport:Dropdown({
        Title = "Select Island",
        Values = {
            "Fisherman Island","Esoteric Depths","Enchant Altar","Kohana","Kohana Volcano",
            "Tropical Grove","Crater Island","Coral Reefs","Sisyphus Statue","Treasure Room"
        },
        Value = "Fisherman Island",
        Callback = function(option) end
    })
    local autoTeleIslandFeature = nil
    TabTeleport:Button({ Title = "Teleport To Island", Desc = "", Locked = false, Callback = function()
        if not autoTeleIslandFeature then autoTeleIslandFeature = featureManager.LoadFeature("AutoTeleportIsland", { dropdown = teleisland_dd }) end
        if autoTeleIslandFeature then
            pcall(function() if autoTeleIslandFeature.SetIsland then autoTeleIslandFeature:SetIsland(teleisland_dd.Value) end end)
            pcall(function() if autoTeleIslandFeature.Teleport then autoTeleIslandFeature:Teleport(teleisland_dd.Value) end end)
        else
            utils.Notify("Error","AutoTeleportIsland feature could not be loaded","x",3)
        end
    end})
end

return M
