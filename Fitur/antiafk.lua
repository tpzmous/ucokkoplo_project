-- Anti-AFK (Safe Mode: IdledHook only)
-- File: Fish-It/antiafkFeature.lua
local antiafkFeature = {}
antiafkFeature.__index = antiafkFeature

--// Services
local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

--// Short refs
local LocalPlayer = Players.LocalPlayer

--// State
local inited   = false
local running  = false
local idleConn = nil
local VirtualUser = nil

-- === lifecycle ===
function antiafkFeature:Init(guiControls)
	-- VirtualUser mungkin belum siap, ambil dengan pcall
	local ok, vu = pcall(function()
		return game:GetService("VirtualUser")
	end)
	if not ok or not vu then
		warn("[antiafkFeature] VirtualUser tidak tersedia.")
		return false
	end
	VirtualUser = vu
	inited = true
	return true
end

function antiafkFeature:Start(config)
	if running then return end
	if not inited then
		local ok = self:Init()
		if not ok then return end
	end
	running = true

	-- Hook bawaan Roblox: dipanggil ketika player dianggap idle.
	-- Hanya satu koneksi; tidak ada loop/heartbeat supaya tidak bentrok dengan fitur lain.
	if not idleConn then
		idleConn = LocalPlayer.Idled:Connect(function()
			-- Sedikit kehati-hatian: jangan "klik" kalau user lagi ngetik (meski event ini mestinya tak ter-trigger saat aktif input).
			if UserInputService:GetFocusedTextBox() then return end
			-- Emulasi input ringan untuk membatalkan AFK default.
			-- Panggilan singkat & aman; tidak menyentuh kamera/karakter.
			pcall(function()
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.new()) -- right-click tap
			end)
		end)
	end
end

function antiafkFeature:Stop()
	if not running then return end
	running = false
	if idleConn then idleConn:Disconnect(); idleConn = nil end
end

function antiafkFeature:Cleanup()
	self:Stop()
	-- reset state ringan (opsional)
end

-- Tidak ada setters—fitur ini cukup plug-and-play.
return antiafkFeature
