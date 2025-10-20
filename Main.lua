--=========================
-- Loader Outdated Warning
--=========================

local function showUpdateGui()
	local ScreenGui = Instance.new("ScreenGui")
	ScreenGui.IgnoreGuiInset = true
	ScreenGui.ResetOnSpawn = false
	ScreenGui.DisplayOrder = 9999
	ScreenGui.Name = "LoaderUpdateWarning"
	ScreenGui.Parent = game.CoreGui

	local Frame = Instance.new("Frame")
	Frame.Size = UDim2.new(0, 420, 0, 220)
	Frame.Position = UDim2.new(0.5, -210, 0.5, -110)
	Frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	Frame.BorderSizePixel = 0
	Frame.BackgroundTransparency = 0.05
	Frame.Parent = ScreenGui

	local UICorner = Instance.new("UICorner")
	UICorner.CornerRadius = UDim.new(0, 12)
	UICorner.Parent = Frame

	local Title = Instance.new("TextLabel")
	Title.Size = UDim2.new(1, 0, 0, 50)
	Title.BackgroundTransparency = 1
	Title.Text = "⚠️ Loader Telah Diperbarui!"
	Title.TextColor3 = Color3.fromRGB(255, 230, 100)
	Title.TextScaled = true
	Title.Font = Enum.Font.GothamBold
	Title.Parent = Frame

	local Body = Instance.new("TextLabel")
	Body.Size = UDim2.new(1, -20, 1, -90)
	Body.Position = UDim2.new(0, 10, 0, 60)
	Body.BackgroundTransparency = 1
	Body.TextWrapped = true
	Body.TextColor3 = Color3.fromRGB(255, 255, 255)
	Body.Text = "Silakan hubungi owner langsung untuk mendapatkan versi terbaru loader ini."
	Body.TextScaled = true
	Body.Font = Enum.Font.Gotham
	Body.Parent = Frame

	task.wait(7)
	game.Players.LocalPlayer:Kick("Loader telah diperbarui!\nSilakan hubungi owner untuk mendapatkan versi terbaru.")
end

showUpdateGui()
