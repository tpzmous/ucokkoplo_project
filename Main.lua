-- Main.lua (Entry point)
local core = script:WaitForChild("core")
local controllers = script:WaitForChild("controllers")

local UICore = require(core:WaitForChild("ui_core"))
local TabsModule = require(core:WaitForChild("ui_tabs"))
local FeatureManager = require(core:WaitForChild("feature_manager"))
local Utils = require(core:WaitForChild("utils"))

local AutoFish = require(controllers:WaitForChild("autofish_controller"))
local Watchdog = require(controllers:WaitForChild("autofish_watchdog"))
local Shop = require(controllers:WaitForChild("shop_controller"))
local Teleport = require(controllers:WaitForChild("teleport_controller"))
local Misc = require(controllers:WaitForChild("misc_controller"))

-- Create Window
local Window = UICore.CreateWindow({
    Title         = ".UcokKoplo",
    Icon          = "rbxassetid://73063950477508",
    Author        = "Fish It",
    Folder        = ".UcokKoplohub",
    Size          = UDim2.fromOffset(250, 250),
    Theme         = "Dark",
    Resizable     = false,
    SideBarWidth  = 120,
    HideSearchBar = true,
})

-- Create Tabs
local tabs = TabsModule.CreateTabs(Window)

-- Init controllers
AutoFish.Init(tabs, FeatureManager, Utils, Window)
Watchdog.Init(AutoFish, Utils, Window)
Shop.Init(tabs, FeatureManager, Utils)
Teleport.Init(tabs, FeatureManager, Utils)
Misc.Init(tabs, FeatureManager, Utils)

print("[Main] UcokKoplo initialized")
