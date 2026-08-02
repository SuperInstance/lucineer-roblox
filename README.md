# 🎮 Lucineer Roblox Client

The in-game Lua companion system for Lucineer — a persistent AI builder that lives inside Roblox.

## What This Is

When a player types in Roblox chat, Lucineer:
1. Captures the message with world context (player position, nearby objects)
2. Sends it to the [Cloudflare Worker relay](https://github.com/SuperInstance/lucineer-relay)
3. The Worker forwards it to OpenClaw (Lucineer's brain)
4. Lucineer generates build commands and a reply
5. The client polls, receives the reply + commands, and executes them in-game

## Modules

| Module | Purpose |
|--------|---------|
| Config.lua | Worker URL, auth key, timing settings |
| Http.lua | HttpService wrapper with retry/backoff |
| Poller.lua | Job polling state machine (0.5s interval, 60s timeout) |
| ChatHandler.lua | Captures player chat, sends to Worker |
| CommandExecutor.lua | Executes build commands (createPart, addLight, runLua, etc.) |
| WorldScanner.lua | Collects world state for AI context |
| UIManager.lua | In-game chat display for Lucineer responses |

## Setup

1. Enable HTTP Requests in Game Settings → Security
2. Sync files via Argon or open the .rbxlx place file
3. Set player count to 1, hit Play
4. Type in chat and Lucineer responds

Part of the [Lucineer system](https://github.com/SuperInstance/lucineer-system).
