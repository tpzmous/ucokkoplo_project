-- ui_core.lua
local M = {}

local success, WindUI = pcall(function()
    return loadstring(game:HttpGet(
        "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"
    ))()
end)

if not success or not WindUI then
    error("Failed loading WindUI")
end

WindUI:SetFont("rbxasset://12187373592")

local function createIconGui(iconId)
    local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    local getUiRoot = (gethui and gethui()) or game:GetService("CoreGui") or PlayerGui

    local iconGui = getUiRoot:FindFirstChild("UcokKoploIconGui") or Instance.new("ScreenGui")
    iconGui.Name = "UcokKoploIconGui"
    iconGui.IgnoreGuiInset = true
    iconGui.ResetOnSpawn = false
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(iconGui) end end)
    iconGui.Parent = getUiRoot

    local iconButton = iconGui:FindFirstChild("UcokKoploOpenButton") or Instance.new("ImageButton")
    iconButton.Name = "UcokKoploOpenButton"
    iconButton.Size = UDim2.fromOffset(40, 40)
    iconButton.Position = UDim2.new(0, 10, 0.5, -20)
    iconButton.BackgroundTransparency = 1
    iconButton.Image = iconId or "rbxassetid://73063950477508"
    iconButton.Parent = iconGui
    iconButton.Visible = false

    return iconGui, iconButton
end

function M.CreateWindow(opts)
    local Window = WindUI:CreateWindow(opts or {})
    -- Basic tags
    Window:Tag({ Title = "v0.0.0", Color = Color3.fromHex("#000000") })
    Window:Tag({ Title = "Dev Version", Color = Color3.fromHex("#000000") })

    -- topbar changelog helper
    local CHANGELOG = table.concat({
        "[+] Auto Fishing",
        "[+] Auto Teleport Island",
        "[+] Auto Buy Weather",
        "[+] Auto Sell Fish",
        "[+] Webhook",
    }, "\n")
    local DISCORD = "https://discord.gg/3AzvRJFT3M"
    local function ShowChangelog()
        Window:Dialog({
            Title   = "Changelog",
            Content = CHANGELOG,
            Buttons = {
                {
                    Title   = "Discord",
                    Icon    = "copy",
                    Variant = "Secondary",
                    Callback = function()
                        if typeof(setclipboard) == "function" then
                            setclipboard(DISCORD)
                            WindUI:Notify({ Title = "Copied", Content = "Changelog copied", Icon = "check", Duration = 2 })
                        else
                            WindUI:Notify({ Title = "Info", Content = "Clipboard not available", Icon = "info", Duration = 3 })
                        end
                    end
                },
                { Title = "Close", Variant = "Primary" }
            }
        })
    end
    Window:CreateTopbarButton("changelog", "newspaper", ShowChangelog, 995)

    -- create icon GUI integration (simple)
    local iconGui, iconButton = createIconGui(opts and opts.Icon)
    -- connect open/close with icon
    iconButton.MouseButton1Click:Connect(function()
        pcall(function() Window:Toggle() end)
    end)
    -- keep icon in sync when window opens/closes
    if Window.Open then
        local oldOpen = Window.Open
        Window.Open = function(self)
            local r = oldOpen(self)
            pcall(function() iconButton.Visible = false end)
            return r
        end
    end
    if Window.Close then
        local oldClose = Window.Close
        Window.Close = function(self)
            local r = oldClose(self)
            pcall(function() iconButton.Visible = true end)
            return r
        end
    end

    return Window
end

return M
