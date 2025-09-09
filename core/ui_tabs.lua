-- ui_tabs.lua
local M = {}

function M.CreateTabs(Window)
    local TabMain     = Window:Tab({ Title = "Main",     Icon = "gamepad" })
    local TabBackpack = Window:Tab({ Title = "Backpack", Icon = "backpack" })
    local TabShop     = Window:Tab({ Title = "Shop",     Icon = "shopping-bag" })
    local TabTeleport = Window:Tab({ Title = "Teleport", Icon = "map" })
    local TabMisc     = Window:Tab({ Title = "Misc",     Icon = "cog" })

    return {
        TabMain = TabMain,
        TabBackpack = TabBackpack,
        TabShop = TabShop,
        TabTeleport = TabTeleport,
        TabMisc = TabMisc,
    }
end

return M
