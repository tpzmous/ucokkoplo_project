-- 🧪 Respawn + Stop Fishing + Restore Pos
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local lastPos = nil

local function log(msg)
    print(("[%s] %s"):format(os.date("%X"), msg))
end

-- simpan posisi terakhir
local function savePos()
    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
        lastPos = LocalPlayer.Character.HumanoidRootPart.CFrame
        log("📍 Saved position")
    end
end

-- restore posisi setelah respawn
local function restorePos()
    if lastPos then
        local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
        task.wait(1) -- jeda biar karakter fully load
        if char:FindFirstChild("HumanoidRootPart") then
            char:WaitForChild("HumanoidRootPart").CFrame = lastPos
            log("📍 Restored position after respawn")
        end
    else
        log("⚠ No position saved, cannot restore")
    end
end

-- coba kirim remote FishingStopped
local function tryStopFishing()
    local stopRemote = nil
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("RemoteEvent") and string.find(obj.Name, "FishingStopped") then
            stopRemote = obj
            break
        end
    end
    if stopRemote then
        log("🛑 Sending FishingStopped before respawn...")
        pcall(function()
            stopRemote:FireServer()
        end)
    else
        log("⚠ No FishingStopped remote found")
    end
end

-- proses respawn anti nyantol
local function testRespawn()
    savePos()
    tryStopFishing()
    task.wait(0.5)

    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
        log("🔄 Killing humanoid for respawn...")
        LocalPlayer.Character.Humanoid.Health = 0
    end

    LocalPlayer.CharacterAdded:Wait()
    log("✅ Respawned")

    restorePos()
end

return {
	Start = function()
		print("[Autorespawn] Ready. Panggil :Respawn() kapan saja.")
	end,
	Respawn = testRespawn
}
