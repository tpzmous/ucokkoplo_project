-- utils.lua
local M = {}

function M.safeCall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return true, res else return false, res end
end

function M.Notify(title, content, icon, duration)
    pcall(function()
        local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
        WindUI:Notify({ Title = title, Content = content, Icon = icon or "info", Duration = duration or 3 })
    end)
end

function M.isValidDiscordWebhook(url)
    if type(url) ~= "string" then return false end
    return url:match("^https?://discord%.com/api/webhooks/") ~= nil
end

function M.safeRead(tbl, key)
    local ok, res = pcall(function()
        if type(tbl[key]) == "function" then
            return tbl[key](tbl)
        else
            return tbl[key]
        end
    end)
    if ok then return res else return nil end
end

return M
