--[[
    Lucineer Configuration — CLIENT-SAFE settings only.

    This module lives in ReplicatedStorage and replicates to every client.
    NEVER put secrets, API keys, auth tokens, or server URLs here.
    Sensitive configuration lives in ServerConfig (ServerScriptService),
    which does NOT replicate to clients.
]]

local Config = {}

-- NOTE: WORKER_URL and AUTH_KEY have been moved to ServerConfig (ServerScriptService).
-- They are injected into Http at server initialization time.

-- Session identity. JobId is unique per server instance; PlaceId scopes it.
-- This is sent to the Worker so it can route jobs and state to the correct session.
Config.SESSION_ID = string.format("%d-%s", game.PlaceId,
    (game.JobId ~= "" and game.JobId or "studio"))

-- Polling
Config.POLL_INTERVAL = 0.5      -- seconds between job status polls
Config.POLL_TIMEOUT = 120        -- seconds before a job is considered timed out
-- NOTE: Must exceed the brain's DEEP_TIMEOUT (100s) so deep builds aren't abandoned.

-- State sync
Config.STATE_SYNC_INTERVAL = 10  -- seconds between full world-state syncs

-- World scanning
Config.SCAN_RADIUS = 200         -- studs around player to scan
Config.SCAN_MAX_INSTANCES = 50   -- cap on instances returned per scan

-- UI
Config.UI_THINKING_TEXT = "Lucineer is thinking..."
Config.UI_COLOR = Color3.fromRGB(0, 255, 170)       -- cyan-green
Config.UI_BG_COLOR = Color3.fromRGB(15, 25, 35)
Config.UI_TEXT_COLOR = Color3.fromRGB(240, 240, 245)

-- Chat
Config.BOT_NAME = "Lucineer"
Config.CHAT_COLOR = Color3.fromRGB(0, 255, 170)

-- Retry / backoff
Config.HTTP_MAX_RETRIES = 3
Config.HTTP_BASE_DELAY = 0.5
Config.HTTP_MAX_DELAY = 4.0

return Config
