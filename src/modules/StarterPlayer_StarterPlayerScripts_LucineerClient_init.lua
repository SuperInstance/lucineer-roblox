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

-- GAP #9e: Wait for the server to create RemoteEvents instead of fabricating
-- client-side phantom copies. A client-created RemoteEvent can never be fired
-- by the server, so the client would listen to a dead event forever.
local ResponseRemote = Lucineer:WaitForChild("ResponseEvent", 30)
local ThinkingRemote = Lucineer:WaitForChild("ThinkingEvent", 30)

if not (ResponseRemote and ThinkingRemote) then
	warn("[Lucineer] Client: server RemoteEvents never appeared after 30s — aborting")
	return
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
ThinkingRemote.OnClientEvent:Connect(function(data: { [string]: any })
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
ResponseRemote.OnClientEvent:Connect(function(data: { [string]: any })
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

        -- Server sends the brain reply (markUnfinished / VoiceLines BRAIN_REPLY)
        -- for successful builds, so the client only handles mixed/failure cases.
        if succeeded > 0 and failed > 0 then
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
