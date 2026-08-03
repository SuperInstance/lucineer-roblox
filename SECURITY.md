# Security — API Key Handling

## Status: KEY ROTATION REQUIRED

The previous API key was committed to git history across multiple repositories and
embedded in a distributable `.rbxlx` place file. **Treat the old key as public/compromised.**
It must be rotated before any public release.

## What Changed

### Before (vulnerable)
`Config.lua` lived in `ReplicatedStorage` — which replicates to every connected client.
It contained `WORKER_URL` and `AUTH_KEY` in plaintext. Any player with an executor
could extract the key in one line and gain full authenticated access to Worker endpoints.

The same key was hardcoded in 4+ locations:
- `lucineer-roblox/src/ReplicatedStorage/Lucineer/Config.lua`
- `lucineer-worker/process_v2.py`
- `lucineer-worker/process.py`
- `lucineer-worker/process-jobs.sh`
- `vibe-world/lucineer-ready.rbxlx` (compiled place file)

### After (fixed)
- **Config.lua** (ReplicatedStorage) now contains ONLY presentation values: UI colors,
  bot name, poll intervals, session ID. No secrets, no URLs, no keys.
- **ServerConfig.lua** (ServerScriptService) contains `WORKER_URL` and resolves
  `AUTH_KEY` at runtime from `ServerStorage.LucineerSecret`. ServerScriptService does
  NOT replicate to clients.
- **Http.lua** receives credentials via `Http.configure(url, key)` at server init time.
  It does not read from Config. If `configure()` is never called, all HTTP calls fail
  safely.
- **process_v2.py** reads `AUTH_KEY` from `os.environ.get("LUCINEER_KEY", "")`. No
  hardcoded fallback.

## How to Set Up the ServerStorage Secret

After deploying to Roblox Studio:

1. In the Explorer, navigate to `ServerStorage`
2. Right-click → Insert Object → `StringValue`
3. Name it `LucineerSecret` (exact name)
4. Set its `Value` property to your Worker API key

The ServerConfig module will automatically find and use it:
```lua
ServerStorage:WaitForChild("LucineerSecret", 5)
```

If the value is missing in Studio (dev mode), a warning is printed and an empty key
is used. In production, the warning indicates a misconfiguration.

## How to Rotate the Key

1. **Generate a new key** — any sufficiently random string (32+ chars recommended)
2. **Update the Worker** — set the new key as the `LUCINEER_AUTH_KEY` secret in
   Cloudflare Workers (via dashboard or `wrangler secret put LUCINEER_AUTH_KEY`)
3. **Update Roblox** — set `ServerStorage.LucineerSecret.Value` to the new key in Studio
4. **Update the processor** — set `LUCINEER_KEY` environment variable:
   ```bash
   export LUCINEER_KEY="your-new-key-here"
   ```
   Or add to the systemd service file / `.env` file used by `process_v2.py`
5. **Re-publish the Roblox place** — the old `.rbxlx` with the embedded key is now dead
6. **Squash git history** (optional but recommended) — use `git filter-repo` or BFG Repo
   Cleaner to purge the old key from history

## Environment Variables

| Variable | Used by | Purpose |
|----------|---------|---------|
| `LUCINEER_KEY` | `process_v2.py` | Worker API authentication |
| `LUCINEER_MEMORY_URL` | `process_v2.py` | Memory D1 Worker URL |
| `LUCINEER_VECTOR_URL` | `process_v2.py` | Vectorize Worker URL |
| `DEEPINFRA_API_KEY` | `process_v2.py`, `brain.py` | Model inference API |

## Future Improvement: Per-Server Tokens

The current design uses a shared static key. A single leak compromises everything with
no revocation path. The recommended follow-up is:

- Worker mints a short-lived JWT scoped to `sessionId` at server startup
- Roblox server exchanges a place-level credential for the JWT
- JWT expires after ~24h and is renewed automatically
- Revocation is instant: the Worker simply stops honoring the token

This turns a catastrophic leak into an annoying-but-recoverable incident.

## Files Modified for This Fix

| File | Change |
|------|--------|
| `src/ReplicatedStorage/Lucineer/Config.lua` | Removed WORKER_URL, AUTH_KEY; presentation values only |
| `src/ServerScriptService/LucineerServer/ServerConfig.lua` | **NEW** — server-only config, reads secret from ServerStorage |
| `src/ReplicatedStorage/Lucineer/Http.lua` | Credentials injected via `Http.configure()`, not read from Config |
| `src/ServerScriptService/LucineerServer/init.lua` | Requires ServerConfig, calls `Http.configure()` at init |
| `default.project.json` | LucineerServer is now a Folder with init.lua + ServerConfig.lua |
| `process_v2.py` | AUTH_KEY reads from `LUCINEER_KEY` env var, no hardcoded fallback |
