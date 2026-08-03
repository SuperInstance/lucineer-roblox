--!strict
--[[
    Lucineer Server Bootstrap
    Main server entry point. Initializes all modules, wires events,
    runs the Poller on Heartbeat, and handles AI response routing.

    This script is a Script (server-side) placed in ServerScriptService.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

--[[
    filterText (alias: filterFor): Wraps TextService:FilterStringAsync for
    Roblox policy compliance. Uses PublicChat context as required for any
    user-influenced text broadcast to other players.

    Fail-closed: on any error, returns "..." (never the unfiltered text).
    Every AI-generated string must pass through this before reaching a client.
]]
local function filterFor(text: string, player: Player): string
    if not text or text == "" then
        return text
    end
    local ok, filterResult = pcall(function()
        return TextService:FilterStringAsync(
            text,
            player.UserId,
            Enum.TextFilterContext.PublicChat
        )
    end)
    if not ok or not filterResult then
        warn("[Lucineer] filterFor: FilterStringAsync failed, suppressing message")
        return "..."  -- fail closed: never show unfiltered text
    end
    local ok2, filtered = pcall(function()
        return filterResult:GetChatForUserAsync(player.UserId)
    end)
    if not ok2 or not filtered then
        warn("[Lucineer] filterFor: GetChatForUserAsync failed, suppressing message")
        return "..."  -- fail closed
    end
    return filtered
end

-- Backward-compatible alias
local function filterText(text: string, playerId: number): string
    -- Wrapper for legacy call sites that only have the userId.
    -- Prefer filterFor() which takes the Player object directly.
    if not text or text == "" then
        return text
    end
    local ok, filterResult = pcall(function()
        return TextService:FilterStringAsync(
            text,
            playerId,
            Enum.TextFilterContext.PublicChat
        )
    end)
    if not ok or not filterResult then
        warn("[Lucineer] filterText: FilterStringAsync failed, suppressing message")
        return "..."
    end
    local ok2, filtered = pcall(function()
        return filterResult:GetChatForUserAsync(playerId)
    end)
    if not ok2 or not filtered then
        warn("[Lucineer] filterText: GetChatForUserAsync failed, suppressing message")
        return "..."
    end
    return filtered
end

-- Load server-only config FIRST (contains secrets — not replicated to clients)
local ServerConfig = require(script:WaitForChild("ServerConfig"))

-- Load shared modules
local Lucineer = game:GetService("ReplicatedStorage"):WaitForChild("Lucineer")
local Config = require(Lucineer:WaitForChild("Config"))
local Http = require(Lucineer:WaitForChild("Http"))

-- Inject server-only credentials into Http module.
-- This must happen before any Http.get/post calls.
Http.configure(ServerConfig.WORKER_URL, ServerConfig.AUTH_KEY)
local Poller = require(Lucineer:WaitForChild("Poller"))
local ChatHandler = require(Lucineer:WaitForChild("ChatHandler"))
local CommandExecutor = require(Lucineer:WaitForChild("CommandExecutor"))
local WorldScanner = require(Lucineer:WaitForChild("WorldScanner"))
local AudioManager = require(Lucineer:WaitForChild("AudioManager"))
local BuildAnimator = require(Lucineer:WaitForChild("BuildAnimator"))

-- Server-side managers (live in ServerScriptService)
local NPCManager = require(script.Parent:WaitForChild("NPCManager"))
local AchievementManager = require(script.Parent:WaitForChild("AchievementManager"))
local BondSystem = require(script.Parent:WaitForChild("BondSystem"))
local EraSystem = require(script.Parent:WaitForChild("EraSystem"))
local PowerGrid = require(script.Parent:WaitForChild("PowerGrid"))
local SaveSystem = require(script.Parent:WaitForChild("SaveSystem"))
local TutorialSystem = require(script.Parent:WaitForChild("TutorialSystem"))
local WeatherSystem = require(script.Parent:WaitForChild("WeatherSystem"))

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

-- Progressive thinking messages — rotate every ~5s while a job is pending
local THINKING_MESSAGES = {
    "Looking at the ground...",
    "Checking what's already here...",
    "Working on it...",
    "Almost there...",
}

-- Track active thinking rotation threads per player
local thinkingRotations: { [Player]: thread } = {}

--[[
    Start rotating thinking messages for a player while their job is pending.
    Fires a new thinking text update every ~5 seconds.
]]
local function startThinkingRotation(player: Player)
    -- Stop any existing rotation for this player
    local existing = thinkingRotations[player]
    if existing then
        task.cancel(existing)
    end

    local msgIndex = 1
    thinkingRotations[player] = task.spawn(function()
        -- Immediate first message (beyond the initial "Lucineer is thinking...")
        task.wait(5)
        while thinkingRotations[player] == coroutine.running() do
            ThinkingRemote:FireClient(player, {
                thinking = true,
                text = THINKING_MESSAGES[msgIndex],
            })
            msgIndex = (msgIndex % #THINKING_MESSAGES) + 1
            task.wait(5)
        end
    end)
end

--[[
    Stop the thinking message rotation for a player.
]]
local function stopThinkingRotation(player: Player)
    local thread = thinkingRotations[player]
    if thread then
        task.cancel(thread)
        thinkingRotations[player] = nil
    end
end

--[[
    Handle AI response: execute commands, send results to client.
    @param player Player -- the player who initiated the chat
    @param response table -- the job response from the Worker
]]
local function handleResponse(player: Player, response: { [string]: any })
    print(string.format("[Lucineer] Server: received response for %s", player.Name))

    -- Stop any progressive thinking rotation — the job is done
    stopThinkingRotation(player)

    if response.error then
        -- Play error UI sound
        AudioManager.playUi("error")
        -- Stop thinking vocal cue if active
        AudioManager.stopThinking()

        ResponseRemote:FireClient(player, {
            type = "error",
            message = filterFor(response.message or "Unknown error", player),
        })
        ThinkingRemote:FireClient(player, { thinking = false })
        return
    end

    -- Play thinking vocal cue while processing
    AudioManager.playCue("thinking")

    -- If the response contains commands, execute them
    local commands = response.commands or response.actions or {}
    if #commands > 0 then
        print(string.format("[Lucineer] Server: executing %d commands for %s", #commands, player.Name))

        -- Switch to build music
        AudioManager.setMusic("build")

        -- Notify client of progress
        ThinkingRemote:FireClient(player, {
            thinking = true,
            text = string.format("Building %d actions...", #commands),
        })

        -- Start progressive thinking rotation for the build phase
        startThinkingRotation(player)

        -- Execute via CommandExecutor (internally routes through BuildAnimator
        -- for staggered cinematic reveal of created parts)
        -- GAP #8: Pass onProgress callback to update thinking text during build.
        local function onBuildProgress(current: number, total: number, _: any)
            ThinkingRemote:FireClient(player, {
                thinking = true,
                text = string.format("Placing piece %d of %d...", current, total),
            })
        end

        local results = CommandExecutor.executeBatch(commands, onBuildProgress)

        -- Stop thinking cue — build is done
        AudioManager.stopThinking()

        -- Play completion vocal cue
        AudioManager.playCue("complete")

        -- Return to hub music
        AudioManager.setMusic("hub")

        -- Send results to client
        ResponseRemote:FireClient(player, {
            type = "commands",
            results = results,
        })

        -- If there's a sendMessage command (including the automatic
        -- markUnfinished message from CHARACTER_BIBLE §6), extract and display it.
        -- Commands are envelopes: { type = "sendMessage", params = { message = ... } }.
        -- The execute() result for sendMessage contains { message = ... }.
        for i, result in ipairs(results) do
            if result.success and result.result and result.result.type == "sendMessage" then
                ResponseRemote:FireClient(player, {
                    type = "message",
                    message = filterFor(result.result.message, player),
                })
            end
        end
    else
        -- No commands — just a conversational response.
        -- Stop thinking cue.
        AudioManager.stopThinking()
    end

    -- If the response has a direct message (Worker returns 'reply', not 'message')
    local replyText = response.reply or response.message
    if replyText then
        -- Play chat receive UI sound
        AudioManager.playUi("chat_receive")

        ResponseRemote:FireClient(player, {
            type = "message",
            message = filterFor(replyText, player),
        })
    end

    -- runLua removed (BUG #9): loadstring is unsafe and disabled by default.
    -- if response.lua then ... end

    -- Done thinking
    stopThinkingRotation(player)
    ThinkingRemote:FireClient(player, { thinking = false })
end

--[[
    Periodic state sync: sends lightweight world state to the Worker
    so the AI has context even without a player message.
]]
local function syncState()
    -- State sync: lightweight world snapshot sent to the Worker every Config.STATE_SYNC_INTERVAL seconds.
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

    -- Audio system
    AudioManager.init()
    AudioManager.setMusic("hub")

    -- Server-side game systems (per UNIFIED_INTEGRATION_PLAN §4)
    NPCManager.init()
    AchievementManager.init()
    BondSystem.init()
    EraSystem.init()
    PowerGrid.init()
    SaveSystem.init()
    TutorialSystem.init()

    -- INTEGRATION: Generate the world before WeatherSystem starts so that
    -- terrain, resource nodes, spawn points, and ProximityPrompts exist
    -- before weather can damage structures.
    local WorldGenerator = require(script.Parent:WaitForChild("WorldGenerator"))
    WorldGenerator.Generate("single")

    WeatherSystem.init()

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
        ChatHandler._lastSubmitTime[player.UserId] = nil
        ChatHandler._pendingThinking[player.UserId] = nil
    end)

    print("[Lucineer] Server: initialized ✓")
    print(string.format("[Lucineer] Server: worker URL = %s", ServerConfig.WORKER_URL))
    print(string.format("[Lucineer] Server: poll interval = %.1fs, timeout = %ds", Config.POLL_INTERVAL, Config.POLL_TIMEOUT))
    print(string.format("[Lucineer] Server: state sync interval = %ds", Config.STATE_SYNC_INTERVAL))
end

-- Run it
init()
