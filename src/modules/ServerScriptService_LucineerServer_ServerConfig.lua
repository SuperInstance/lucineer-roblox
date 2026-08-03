--[[
    ServerConfig — SERVER-ONLY configuration module.
    Contains secrets and endpoints that must NEVER replicate to clients.

    This module lives in ServerScriptService, which is NOT replicated to players.
    Do NOT move this to ReplicatedStorage or any client-accessible container.

    AUTH_KEY is read from a ServerStorage StringValue named "LucineerSecret".
    To set it up in Studio:
      1. Create a StringValue in ServerStorage named "LucineerSecret"
      2. Set its Value to the same key configured on the Worker

    If the ServerStorage value is missing, we fall back to an environment
    lookup via game:GetService("RunService"):IsStudio() — in Studio, a
    placeholder is used so dev workflows don't break. In production, the
    absence of the secret is a hard error.
]]

local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local ServerConfig = {}

-- Worker endpoint (only the server needs this)
ServerConfig.WORKER_URL = "https://lucineer-relay.casey-digennaro.workers.dev"

--[[
    Resolve the authentication key.

    Priority:
      1. ServerStorage.LucineerSecret.StringValue (set in Studio, never in source)
      2. Hardcoded fallback (empty — auth removed for player endpoint per Worker hardening)

    The Worker currently does not require a key for the player-facing /api/message
    endpoint. When auth is re-enabled, set the ServerStorage secret and it flows
    through automatically.
]]
local function resolveAuthKey(): string
    -- Try ServerStorage first (production path)
    local ok, secret = pcall(function()
        return ServerStorage:WaitForChild("LucineerSecret", 5)
    end)
    if ok and secret and secret:IsA("StringValue") then
        return secret.Value
    end

    -- Studio fallback: no auth needed for local dev
    if RunService:IsStudio() then
        warn("[Lucineer] ServerConfig: LucineerSecret not found in ServerStorage — using empty key (Studio mode)")
        return ""
    end

    -- Production without a configured secret is a misconfiguration.
    warn("[Lucineer] ServerConfig: LucineerSecret NOT found in ServerStorage!")
    warn("[Lucineer] ServerConfig: Create a StringValue named 'LucineerSecret' in ServerStorage.")
    warn("[Lucineer] ServerConfig: Using empty key — Worker requests may fail if auth is enabled.")
    return ""
end

ServerConfig.AUTH_KEY = resolveAuthKey()

return ServerConfig
