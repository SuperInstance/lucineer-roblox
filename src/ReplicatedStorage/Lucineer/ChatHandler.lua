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
local AudioManager = require(script.Parent.AudioManager)

local Lucineer = game:GetService("ReplicatedStorage"):WaitForChild("Lucineer")

local ChatHandler = {}

-- Callback type: called when a job completes or errors
export type ResponseCallback = (player: Player, response: { [string]: any }) -> ()

ChatHandler._initialized = false
ChatHandler._onResponse = nil

-- ─── Rate Limiting ────────────────────────────────────────────────────────
-- Per-player cooldown (seconds between job submissions)
local PLAYER_COOLDOWN = 3

-- Per-server concurrent job cap
local MAX_CONCURRENT_JOBS = 3

-- Track last submission time per player
ChatHandler._lastSubmitTime = {} :: { [number]: number }

-- Track active (pending) jobs per server
ChatHandler._activeJobCount = 0

-- GAP #8b: Track which players have active thinking message rotation
ChatHandler._pendingThinking = {} :: { [number]: boolean }

--[[
    Set the callback for when an AI response is ready.
    @param callback (player: Player, response: { [string]: any }) -> ()
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

    -- ─── Rate Limit: per-player cooldown ───
    local now = os.clock()
    local lastTime = ChatHandler._lastSubmitTime[player.UserId]
    if lastTime and (now - lastTime) < PLAYER_COOLDOWN then
        local remaining = PLAYER_COOLDOWN - (now - lastTime)
        print(string.format("[Lucineer] ChatHandler: %s rate-limited (%.1fs remaining)",
            player.Name, remaining))
        -- In-voice rejection: still show the message via thinking remote
        local thinkingRemote = Lucineer:FindFirstChild("ThinkingEvent")
        if thinkingRemote then
            thinkingRemote:FireClient(player, {
                thinking = true,
                text = "Give me a second, still working.",
            })
            task.delay(1.5, function()
                if thinkingRemote then
                    thinkingRemote:FireClient(player, { thinking = false })
                end
            end)
        end
        return
    end

    -- ─── Rate Limit: per-server concurrent job cap ───
    if ChatHandler._activeJobCount >= MAX_CONCURRENT_JOBS then
        print(string.format("[Lucineer] ChatHandler: server at job cap (%d/%d), rejecting %s",
            ChatHandler._activeJobCount, MAX_CONCURRENT_JOBS, player.Name))
        local thinkingRemote = Lucineer:FindFirstChild("ThinkingEvent")
        if thinkingRemote then
            thinkingRemote:FireClient(player, {
                thinking = true,
                text = "Give me a second, still working.",
            })
            task.delay(2, function()
                if thinkingRemote then
                    thinkingRemote:FireClient(player, { thinking = false })
                end
            end)
        end
        return
    end

    -- ─── Inbound text filtering (Roblox policy) ───
    -- Filter player message before sending to AI. Even though we filter
    -- outbound, the inbound text goes off-platform to DeepInfra — we should
    -- still pass it through the Roblox filter for broadcast context.
    local TextService = game:GetService("TextService")
    local filteredMessage = message
    pcall(function()
        local filterResult = TextService:FilterStringAsync(
            message,
            player.UserId,
            Enum.TextFilterContext.PublicChat
        )
        filteredMessage = filterResult:GetChatForUserAsync(player.UserId)
    end)
    -- If filter fails, use original — we still need to process the message,
    -- and outbound filtering will catch anything problematic in the reply.

    -- ─── Inbound prompt-injection detection ───
    -- Strip obvious attempts to hijack the AI system prompt.
    local lowerMsg = string.lower(message)
    local INJECTION_PATTERNS = {
        "ignore previous instructions",
        "ignore all previous",
        "you are now",
        "new instructions:",
        "system prompt",
        "forget your instructions",
        "disregard the above",
        "act as",
        "pretend you are",
        "override",
    }
    local isInjection = false
    for _, pattern in ipairs(INJECTION_PATTERNS) do
        if string.find(lowerMsg, pattern, 1, true) then
            isInjection = true
            break
        end
    end
    if isInjection then
        print(string.format("[Lucineer] ChatHandler: prompt injection detected from %s", player.Name))
        local thinkingRemote = Lucineer:FindFirstChild("ThinkingEvent")
        if thinkingRemote then
            thinkingRemote:FireClient(player, {
                thinking = true,
                text = "Nice try. I don't take orders from the back of the room.",
            })
            task.delay(2.5, function()
                if thinkingRemote then
                    thinkingRemote:FireClient(player, { thinking = false })
                end
            end)
        end
        return
    end

    -- Mark submission time and increment active job count
    ChatHandler._lastSubmitTime[player.UserId] = now
    ChatHandler._activeJobCount += 1

    -- Play chat send UI sound
    AudioManager.playUi("chat_send")

    -- Play acknowledgment vocal cue (Lucineer heard you)
    AudioManager.playCue("acknowledge")

    -- Show "Lucineer is thinking..." indicator on the client
    local thinkingRemote = Lucineer:FindFirstChild("ThinkingEvent")
    if thinkingRemote then
        thinkingRemote:FireClient(player, {
            thinking = true,
            text = "Lucineer is thinking...",
        })
    end

    -- GAP #8b: Start progressive thinking message rotation.
    -- While the job is pending (brain is working), rotate thinking messages
    -- every ~5 seconds so the player sees active progress instead of dead air.
    local THINKING_MESSAGES = {
        "Looking at the ground...",
        "Checking what's already here...",
        "Working on it...",
        "Almost there...",
    }
    if thinkingRemote then
        task.spawn(function()
            local msgIndex = 1
            -- Wait before first rotation (initial message already shown)
            task.wait(5)
            -- Keep rotating until the response handler stops us.
            -- We use a flag on the player to track if the job is still pending.
            local playerId = player.UserId
            while ChatHandler._pendingThinking[playerId] do
                thinkingRemote:FireClient(player, {
                    thinking = true,
                    text = THINKING_MESSAGES[msgIndex],
                })
                msgIndex = (msgIndex % #THINKING_MESSAGES) + 1
                task.wait(5)
            end
        end)
    end
    ChatHandler._pendingThinking[player.UserId] = true

    -- Gather world state
    local worldState = WorldScanner.scan(player)

    -- Build the request — must match Worker's expected contract:
    -- { sessionId, playerName, message, ... }
    local payload = {
        sessionId   = Config.SESSION_ID,
        playerName  = player.Name,
        message     = filteredMessage,
        playerState = {
            userId   = player.UserId,
            position = worldState.player and worldState.player.position or nil,
        },
        worldSnapshot = worldState,
    }

    -- Fire and forget — the Poller will track the job
    task.spawn(function()
        local response, err = Http.post("/api/message", payload)
        if err then
            warn(string.format("[Lucineer] ChatHandler: POST /api/message failed: %s", err))
            ChatHandler._pendingThinking[player.UserId] = nil
            AudioManager.playUi("error")
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
            function(jobResponse: { [string]: any })
                ChatHandler._activeJobCount = math.max(0, ChatHandler._activeJobCount - 1)
                -- GAP #8b: Stop progressive thinking rotation
                ChatHandler._pendingThinking[player.UserId] = nil
                if ChatHandler._onResponse then
                    task.spawn(ChatHandler._onResponse, player, jobResponse)
                end
            end,
            function(jobErr: string)
                ChatHandler._activeJobCount = math.max(0, ChatHandler._activeJobCount - 1)
                -- GAP #8b: Stop progressive thinking rotation
                ChatHandler._pendingThinking[player.UserId] = nil
                warn(string.format("[Lucineer] ChatHandler: job %s error: %s", jobId, jobErr))
                AudioManager.playUi("error")
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
