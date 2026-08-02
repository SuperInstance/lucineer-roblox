--!strict
--[[
    Lucineer Server Bootstrap
    Main server entry point. Initializes all modules, wires events,
    runs the Poller on Heartbeat, and handles AI response routing.

    This script is a Script (server-side) placed in ServerScriptService.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Load modules
local Lucineer = game:GetService("ReplicatedStorage"):WaitForChild("Lucineer")
local Config = require(Lucineer:WaitForChild("Config"))
local Http = require(Lucineer:WaitForChild("Http"))
local Poller = require(Lucineer:WaitForChild("Poller"))
local ChatHandler = require(Lucineer:WaitForChild("ChatHandler"))
local CommandExecutor = require(Lucineer:WaitForChild("CommandExecutor"))
local WorldScanner = require(Lucineer:WaitForChild("WorldScanner"))

-- Create RemoteEvents for client ↔ server communication
local function createRemote(name: string): RemoteEvent
    local existing = Lucineer:FindFirstChild(name)
    if existing then return existing end
    local remote = Instance.new("RemoteEvent")
    remote.Name = name
    remote.Parent = Lucineer
    return remote
end

local ResponseRemote = createRemote("ResponseEvent")    -- server → client: AI response
local ThinkingRemote = createRemote("ThinkingEvent")    -- server → client: thinking state
local CommandRemote = createRemote("CommandEvent")      -- server → client: command updates

-- State sync accumulator
local stateSyncAccumulator = 0

--[[
    Handle AI response: execute commands, send results to client.
    @param player Player -- the player who initiated the chat
    @param response table -- the job response from the Worker
]]
local function handleResponse(player: Player, response: table)
    print(string.format("[Lucineer] Server: received response for %s", player.Name))

    if response.error then
        ResponseRemote:FireClient(player, {
            type = "error",
            message = response.message or "Unknown error",
        })
        ThinkingRemote:FireClient(player, { thinking = false })
        return
    end

    -- If the response contains commands, execute them
    local commands = response.commands or response.actions or {}
    if #commands > 0 then
        print(string.format("[Lucineer] Server: executing %d commands for %s", #commands, player.Name))

        -- Notify client of progress
        ThinkingRemote:FireClient(player, {
            thinking = true,
            text = string.format("Building %d actions...", #commands),
        })

        local results = CommandExecutor.executeBatch(commands)

        -- Send results to client
        ResponseRemote:FireClient(player, {
            type = "commands",
            results = results,
        })

        -- If there's a sendMessage command, extract and display it.
        -- Commands are envelopes: { type = "sendMessage", params = { message = ... } }.
        -- The execute() result for sendMessage contains { message = ... }.
        for i, result in ipairs(results) do
            if result.success and result.result and result.result.type == "sendMessage" then
                ResponseRemote:FireClient(player, {
                    type = "message",
                    message = result.result.message,
                })
            end
        end
    end

    -- If the response has a direct message (Worker returns 'reply', not 'message')
    local replyText = response.reply or response.message
    if replyText then
        ResponseRemote:FireClient(player, {
            type = "message",
            message = replyText,
        })
    end

    -- runLua removed (BUG #9): loadstring is unsafe and disabled by default.
    -- if response.lua then ... end

    -- Done thinking
    ThinkingRemote:FireClient(player, { thinking = false })
end

--[[
    Periodic state sync: sends lightweight world state to the Worker
    so the AI has context even without a player message.
]]
local function syncState()
    for _, player in ipairs(Players:GetPlayers()) do
        local state = WorldScanner.quickScan(player)
        task.spawn(function()
            local _, err = Http.post("/api/state", {
                sessionId     = Config.SESSION_ID,
                worldSnapshot = state,
            })
            if err then
                -- Silent fail for state sync — not critical
                warn(string.format("[Lucineer] Server: state sync failed for %s: %s", player.Name, err))
            end
        end)
    end
end

--[[
    Initialize everything.
]]
local function init()
    print("[Lucineer] Server: initializing...")

    -- Core modules
    Poller.init()
    ChatHandler.init()

    -- Wire AI responses
    ChatHandler.onResponse(handleResponse)

    -- Heartbeat: run Poller + state sync
    RunService.Heartbeat:Connect(function(dt: number)
        Poller.tick(dt)

        stateSyncAccumulator += dt
        if stateSyncAccumulator >= Config.STATE_SYNC_INTERVAL then
            stateSyncAccumulator = 0
            syncState()
        end
    end)

    -- Handle player removal
    Players.PlayerRemoving:Connect(function(player: Player)
        print(string.format("[Lucineer] Server: player %s leaving, cleaning up", player.Name))
    end)

    print("[Lucineer] Server: initialized ✓")
    print(string.format("[Lucineer] Server: worker URL = %s", Config.WORKER_URL))
    print(string.format("[Lucineer] Server: poll interval = %.1fs, timeout = %ds", Config.POLL_INTERVAL, Config.POLL_TIMEOUT))
    print(string.format("[Lucineer] Server: state sync interval = %ds", Config.STATE_SYNC_INTERVAL))
end

-- Run it
init()
