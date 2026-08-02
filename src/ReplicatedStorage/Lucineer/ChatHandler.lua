--[[
    Lucineer Chat Handler
    Listens to player chat, captures messages with world context,
    sends POST /api/message, and registers the resulting job with Poller.
]]

local Players = game:GetService("Players")
local ChatService = game:GetService("Chat")

local Config = require(script.Parent.Config)
local Http = require(script.Parent.Http)
local Poller = require(script.Parent.Poller)
local WorldScanner = require(script.Parent.WorldScanner)

local ChatHandler = {}

-- Callback type: called when a job completes or errors
export type ResponseCallback = (player: Player, response: table) -> ()

ChatHandler._initialized = false
ChatHandler._onResponse = nil

--[[
    Set the callback for when an AI response is ready.
    @param callback (player: Player, response: table) -> ()
]]
function ChatHandler.onResponse(callback: ResponseCallback)
    ChatHandler._onResponse = callback
end

--[[
    Process a chat message from a player.
    Captures world state and sends it to the Worker.
    @param player Player
    @param message string
]]
function ChatHandler.processMessage(player: Player, message: string)
    print(string.format("[Lucineer] ChatHandler: %s said \"%s\"", player.Name, message))

    -- Gather world state
    local worldState = WorldScanner.scan(player)

    -- Build the request
    local payload = {
        playerId = player.UserId,
        playerName = player.Name,
        message = message,
        worldState = worldState,
        placeId = game.PlaceId,
    }

    -- Fire and forget — the Poller will track the job
    task.spawn(function()
        local response, err = Http.post("/api/message", payload)
        if err then
            warn(string.format("[Lucineer] ChatHandler: POST /api/message failed: %s", err))
            if ChatHandler._onResponse then
                task.spawn(ChatHandler._onResponse, player, {
                    error = true,
                    message = "I couldn't reach my brain. Please try again in a moment.",
                })
            end
            return
        end

        local jobId = response.jobId or response.job_id or response.id
        if not jobId then
            -- Immediate response (no async job)
            if ChatHandler._onResponse then
                task.spawn(ChatHandler._onResponse, player, response)
            end
            return
        end

        -- Register with Poller
        Poller.register(
            jobId,
            function(jobResponse: table)
                if ChatHandler._onResponse then
                    task.spawn(ChatHandler._onResponse, player, jobResponse)
                end
            end,
            function(jobErr: string)
                warn(string.format("[Lucineer] ChatHandler: job %s error: %s", jobId, jobErr))
                if ChatHandler._onResponse then
                    task.spawn(ChatHandler._onResponse, player, {
                        error = true,
                        message = "My thoughts got lost. Please try again.",
                    })
                end
            end
        )
    end)
end

--[[
    Initialize the ChatHandler. Wires up player chat events.
    Call once at server startup.
]]
function ChatHandler.init()
    if ChatHandler._initialized then
        warn("[Lucineer] ChatHandler: already initialized")
        return
    end
    ChatHandler._initialized = true

    -- Wire up chat events for all existing + future players
    local function connectPlayerChat(player: Player)
        player.Chatted:Connect(function(message: string)
            ChatHandler.processMessage(player, message)
        end)
    end

    -- Existing players
    for _, player in ipairs(Players:GetPlayers()) do
        connectPlayerChat(player)
    end

    -- Future players
    Players.PlayerAdded:Connect(connectPlayerChat)

    print("[Lucineer] ChatHandler: initialized — listening to player chat")
end

return ChatHandler
