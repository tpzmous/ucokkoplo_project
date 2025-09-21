local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local PlayerStats = {}

function PlayerStats.Init(self, controls)
    local stats_para = controls.StatsParagraph

    -- === Helper ambil Gold Label dari GUI ===
    local function findGoldLabel()
        local best, bestVal = nil, 0
        for _, obj in ipairs(LocalPlayer.PlayerGui:GetDescendants()) do
            if obj:IsA("TextLabel") and obj.Name == "Counter" then
                local raw = obj.Text
                local num = tonumber((raw:gsub(",", "")):match("%d+%.?%d*")) or 0
                if raw:find("K") then num = num * 1e3
                elseif raw:find("M") then num = num * 1e6
                elseif raw:find("B") then num = num * 1e9 end
                if num > bestVal then
                    bestVal = num
                    best = obj
                end
            end
        end
        return best
    end

    -- simpan state
    local currentCaught = 0
    local currentRarest = "None"
    local currentGold = "0"
    local playerName = LocalPlayer.Name  -- <<-- Tambahkan nama pemain

    local function refreshStats()
        stats_para:SetDesc(
            "Player : " .. tostring(playerName) ..
            "\nCaught : " .. tostring(currentCaught) ..
            "\nRarest Fish : " .. tostring(currentRarest) ..
            "\nGold : " .. tostring(currentGold)
        )
    end

    -- === Connectors ===
    local function connectCaught()
        local stats = LocalPlayer:WaitForChild("leaderstats")
        local val = stats:WaitForChild("Caught")
        currentCaught = val.Value
        refreshStats()
        val:GetPropertyChangedSignal("Value"):Connect(function()
            currentCaught = val.Value
            refreshStats()
        end)
    end

    local function connectRarest()
        local stats = LocalPlayer:WaitForChild("leaderstats")
        local val = stats:WaitForChild("Rarest Fish")
        currentRarest = val.Value
        refreshStats()
        val:GetPropertyChangedSignal("Value"):Connect(function()
            currentRarest = val.Value
            refreshStats()
        end)
    end

    local function connectGold()
        local goldObj = findGoldLabel()
        if goldObj then
            currentGold = goldObj.Text
            refreshStats()
            goldObj:GetPropertyChangedSignal("Text"):Connect(function()
                currentGold = goldObj.Text
                refreshStats()
            end)
        end
    end

    -- === Start ===
    connectCaught()
    connectRarest()
    connectGold()
    refreshStats()
end

return PlayerStats
