--[[
    Lucineer Client Bootstrap
    Client-side UI + local chat handling. Listens for server RemoteEvents
    and updates the UI accordingly.

    This is a LocalScript placed in StarterPlayerScripts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- Wait for Lucineer modules to load
local Lucineer = ReplicatedStorage:WaitForChild("Lucineer")
local Config = require(Lucineer:WaitForChild("Config"))
local UIManager = require(Lucineer:WaitForChild("UIManager"))

-- Get RemoteEvents (created by server)
-- Wait for server to create RemoteEvents (with timeout fallback)
local ResponseRemote = Lucineer:FindFirstChild("ResponseEvent")
local ThinkingRemote = Lucineer:FindFirstChild("ThinkingEvent")

if not ResponseRemote then
	ResponseRemote = Instance.new("RemoteEvent")
	ResponseRemote.Name = "ResponseEvent"
	ResponseRemote.Parent = Lucineer
end
if not ThinkingRemote then
	ThinkingRemote = Instance.new("RemoteEvent")
	ThinkingRemote.Name = "ThinkingEvent"
	ThinkingRemote.Parent = Lucineer
end

--[[
    Initialize the UI.
]]
UIManager.init()

print("[Lucineer] Client: initialized for " .. player.Name)

----------------------------------------------------------------
-- EVENT HANDLERS
----------------------------------------------------------------

--[[
    Handle thinking state changes from the server.
    Shows/hides the "Lucineer is thinking..." bar.
]]
ThinkingRemote.OnClientEvent:Connect(function(data: table)
    if data.thinking then
        UIManager.showThinking(data.text)
    else
        UIManager.hideThinking()
    end
end)

--[[
    Handle AI responses from the server.
    Routes by type: message, commands, error.
]]
ResponseRemote.OnClientEvent:Connect(function(data: table)
    if not data or type(data) ~= "table" then
        warn("[Lucineer] Client: received malformed response")
        return
    end

    if data.type == "message" then
        UIManager.displayChatResponse(data.message)
        print(string.format("[Lucineer] Client: displayed message (%d chars)", #data.message))

    elseif data.type == "commands" then
        -- Command results — summarize for the player
        local succeeded = 0
        local failed = 0
        for _, result in ipairs(data.results or {}) do
            if result.success then
                succeeded += 1
            else
                failed += 1
            end
        end

        if succeeded > 0 and failed == 0 then
            -- "Done! I built %d action(s)" is dead. Lucineer speaks in voice.
            local VoiceLines = require(Lucineer:WaitForChild("VoiceLines"))
            VoiceLines.init()
            local line = VoiceLines.getWeighted()
            UIManager.displayChatResponse(line)
        elseif succeeded > 0 and failed > 0 then
            local VoiceLines = require(Lucineer:WaitForChild("VoiceLines"))
            VoiceLines.init()
            UIManager.displayChatResponse(VoiceLines.getByTrigger("wrong") or "Some of it held. Some didn't.")
        elseif failed > 0 then
            UIManager.displayChatResponse("Hmm, I ran into trouble building that. Try describing it differently?")
        end

        print(string.format("[Lucineer] Client: command results — %d ok, %d failed", succeeded, failed))

    elseif data.type == "error" then
        UIManager.displayChatResponse(data.message or "Something went wrong.")
        print(string.format("[Lucineer] Client: error — %s", data.message or "unknown"))

    else
        warn(string.format("[Lucineer] Client: unknown response type '%s'", tostring(data.type)))
    end
end)

--[[
    Quick-start hint: show a welcome message when the player joins.
]]
task.delay(3, function()
    UIManager.displayChatResponse("Hi! I'm Lucineer. Tell me what to build and I'll make it happen.")
end)

print("[Lucineer] Client: ready ✓")
