--[[
    Lucineer Configuration
    Central settings for the Roblox client.
    Adjust WORKER_URL and AUTH_KEY to match your Cloudflare Worker deployment.
]]

local Config = {}

-- Worker endpoint (Cloudflare Worker URL)
Config.WORKER_URL = "https://lucineer-relay.casey-digennaro.workers.dev"

-- Authentication key (set this to match your Worker's LUCINEER_AUTH_KEY)
Config.AUTH_KEY = "feba836ba409a7e959d957c7c4051fa6243a3436367073e52c567f979f49c9a7"

-- Polling
Config.POLL_INTERVAL = 0.5      -- seconds between job status polls
Config.POLL_TIMEOUT = 60         -- seconds before a job is considered timed out

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
