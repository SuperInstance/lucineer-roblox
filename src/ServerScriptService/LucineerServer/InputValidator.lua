--!strict
--[[
    InputValidator.lua — Player Input Validation & Sanitization
    ============================================================
    "The dockmaster checks every manifest. Not because she doesn't
     trust you — because the ocean doesn't forgive sloppy paperwork."

    Validates, sanitizes, and rate-limits player messages before they
    reach the Worker. Protects against:
      - Empty / whitespace-only messages
      - Overly long messages (truncated with context preserved)
      - Rate limiting (max 10 requests/minute per player)
      - Code injection (Lua keywords, script tags, escape sequences)

    Usage:
        local InputValidator = require(script.Parent.InputValidator)

        -- Validate a message before sending to Worker
        local result = InputValidator.validate(player, message)
        if result.rejected then
            -- Show rejection message to player
            ResponseRemote:FireClient(player, {
                type = "message",
                message = result.reason,
            })
            return
        end
        -- Use result.sanitized for the actual request
]]

local Players = game:GetService("Players")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local InputValidator = {}

----------------------------------------------------------------
-- CONFIGURATION
----------------------------------------------------------------

InputValidator.MAX_MESSAGE_LENGTH = 500       -- characters
InputValidator.RATE_LIMIT_PER_MINUTE = 10     -- max requests per player per minute
InputValidator.RATE_LIMIT_WINDOW = 60         -- seconds (rolling window)

-- In-character rejection messages (Lucineer's voice)
local REJECTION_MESSAGES = {
    empty = "I'm here. Say something — even if it's just 'hello.' I'll listen.",
    too_long = "That's a lot to take in. Give me the short version — what do you want me to build?",
    rate_limited = "Slow down. I heard you. Let me finish what I'm doing before you ask for more.",
    blocked = "I can't work with that. Try telling me what you want to build, in plain words.",
}

----------------------------------------------------------------
-- RATE LIMITING STATE
----------------------------------------------------------------

-- [userId] = { {timestamp, ...}, ... } — rolling window of request timestamps
InputValidator._rateLog: {[number]: {number}} = {}

----------------------------------------------------------------
-- DANGEROUS PATTERNS
----------------------------------------------------------------

-- Patterns that indicate code injection attempts
-- Checked against lowercase message
local DANGEROUS_PATTERNS = {
    "loadstring",
    "getfenv",
    "setfenv",
    "require%(",        -- require() calls
    "pcall%(",
    "spawn%(",
    "delay%(",
    "tickservice",
    "runservice",
    "getservice",
    "httpget",
    "httppost",
    "<script",
    "javascript:",
    "data:text/html",
    "file://",
    "..%s*/",           -- directory traversal ../
    "%${.*}",           -- template injection ${...}
    "os%.execute",
    "io%.open",
    "io%.popen",
    "0x[0-9a-f]+",      -- hex-encoded payloads (if long enough to be suspicious)
}

-- Lua keywords that are suspicious in player chat context
-- (not auto-blocked, but logged if combined with other patterns)
local SUSPICIOUS_KEYWORDS = {
    "function", "return", "end", "local", "then", "else",
    "while", "for", "do", "break", "repeat", "until",
}

----------------------------------------------------------------
-- SANITIZATION
----------------------------------------------------------------

--[[
    Sanitize a message string.
    - Trims leading/trailing whitespace
    - Collapses multiple spaces
    - Strips control characters
    - Neutralizes backslash escapes

    @param message string -- raw input
    @return string -- sanitized input
]]
local function sanitize(message: string): string
    if not message then return "" end

    -- Remove control characters (0x00–0x1F except tab/newline)
    message = string.gsub(message, "[%z\1-\8\11-\31]", "")

    -- Neutralize backslash sequences (prevent escape injection)
    message = string.gsub(message, "\\", "")

    -- Collapse multiple whitespace into single space
    message = string.gsub(message, "%s+", " ")

    -- Trim leading/trailing whitespace
    message = string.gsub(message, "^%s+", "")
    message = string.gsub(message, "%s+$", "")

    return message
end

----------------------------------------------------------------
-- CODE INJECTION DETECTION
----------------------------------------------------------------

--[[
    Check if a message contains code injection patterns.
    Returns true if the message is blocked.

    @param message string -- sanitized, lowercase message
    @return boolean -- true if blocked
    @return string? -- the matched pattern (for logging)
]]
local function detectInjection(message: string): (boolean, string?)
    for _, pattern in ipairs(DANGEROUS_PATTERNS) do
        if string.match(message, pattern) then
            return true, pattern
        end
    end

    -- Check for high density of Lua keywords (likely code, not chat)
    local keywordCount = 0
    for _, kw in ipairs(SUSPICIOUS_KEYWORDS) do
        local count = select(2, string.gsub(message, kw, ""))
        keywordCount += count
    end

    -- If more than 4 Lua keywords in one message, it's probably code
    if keywordCount > 4 then
        return true, "lua_keyword_density"
    end

    return false, nil
end

----------------------------------------------------------------
-- RATE LIMITING
----------------------------------------------------------------

--[[
    Check if a player is within their rate limit.
    Uses a rolling window of the last RATE_LIMIT_WINDOW seconds.

    @param userId number
    @return boolean -- true if within limit (allowed)
]]
local function checkRateLimit(userId: number): boolean
    local now = os.time()
    local log = InputValidator._rateLog[userId]

    if not log then
        InputValidator._rateLog[userId] = { now }
        return true
    end

    -- Remove entries outside the window
    local cutoff = now - InputValidator.RATE_LIMIT_WINDOW
    local pruned = {}
    for _, ts in ipairs(log) do
        if ts > cutoff then
            table.insert(pruned, ts)
        end
    end

    -- Check if under limit
    if #pruned >= InputValidator.RATE_LIMIT_PER_MINUTE then
        InputValidator._rateLog[userId] = pruned
        return false
    end

    -- Record this request
    table.insert(pruned, now)
    InputValidator._rateLog[userId] = pruned
    return true
end

--[[
    Get remaining requests for a player in the current window.
    @param userId number
    @return number -- remaining requests (0 if rate limited)
]]
function InputValidator.getRemainingRequests(userId: number): number
    local log = InputValidator._rateLog[userId]
    if not log then return InputValidator.RATE_LIMIT_PER_MINUTE end

    local now = os.time()
    local cutoff = now - InputValidator.RATE_LIMIT_WINDOW
    local count = 0
    for _, ts in ipairs(log) do
        if ts > cutoff then count += 1 end
    end

    return math.max(0, InputValidator.RATE_LIMIT_PER_MINUTE - count)
end

--[[
    Clear rate limit history for a player (on disconnect).
    @param userId number
]]
function InputValidator.clearRateLimit(userId: number)
    InputValidator._rateLog[userId] = nil
end

----------------------------------------------------------------
-- MAIN VALIDATION
----------------------------------------------------------------

--[[
    Validate a player message.
    Returns a result table indicating whether the message was rejected,
    and if not, the sanitized (and possibly truncated) message.

    @param player Player -- the sending player
    @param message string -- the raw message
    @return table -- {
        rejected = boolean,
        reason = string?,        -- rejection key if rejected
        message = string?,       -- in-character rejection message
        sanitized = string?,     -- sanitized message if accepted
        truncated = boolean,     -- true if message was truncated
        original_length = number,
        sanitized_length = number,
    }
]]
function InputValidator.validate(player: Player, message: string): table
    local originalLength = message and #message or 0

    -- ── Step 1: Sanitize ──
    local cleaned = sanitize(message or "")

    -- ── Step 2: Empty check ──
    if cleaned == "" then
        return {
            rejected = true,
            reason = "empty",
            message = REJECTION_MESSAGES.empty,
            original_length = originalLength,
            sanitized_length = 0,
        }
    end

    -- ── Step 3: Rate limit check ──
    local withinLimit = checkRateLimit(player.UserId)
    if not withinLimit then
        return {
            rejected = true,
            reason = "rate_limited",
            message = REJECTION_MESSAGES.rate_limited,
            original_length = originalLength,
            sanitized_length = #cleaned,
        }
    end

    -- ── Step 4: Code injection check ──
    local lower = string.lower(cleaned)
    local blocked, pattern = detectInjection(lower)
    if blocked then
        warn(string.format("[InputValidator] Blocked message from %s (pattern: %s): %.60s",
            player.Name, pattern or "?", cleaned))
        return {
            rejected = true,
            reason = "blocked",
            message = REJECTION_MESSAGES.blocked,
            original_length = originalLength,
            sanitized_length = #cleaned,
        }
    end

    -- ── Step 5: Length check — truncate if too long ──
    local truncated = false
    if #cleaned > InputValidator.MAX_MESSAGE_LENGTH then
        -- Truncate at word boundary near the limit
        local cutPoint = InputValidator.MAX_MESSAGE_LENGTH
        -- Try to find a space near the cut point
        local wordBoundary = string.find(cleaned, "%s", cutPoint - 20, true)
        if wordBoundary and wordBoundary < cutPoint + 20 then
            cutPoint = wordBoundary - 1
        end
        cleaned = string.sub(cleaned, 1, cutPoint)
        truncated = true
    end

    -- ── Return accepted message ──
    return {
        rejected = false,
        sanitized = cleaned,
        truncated = truncated,
        original_length = originalLength,
        sanitized_length = #cleaned,
    }
end

----------------------------------------------------------------
-- LIFECYCLE
----------------------------------------------------------------

--[[
    Initialize InputValidator. Wires player cleanup.
]]
function InputValidator.init()
    Players.PlayerRemoving:Connect(function(player)
        InputValidator.clearRateLimit(player.UserId)
    end)

    print(string.format("[InputValidator] Initialized — max %d chars, %d req/min per player",
        InputValidator.MAX_MESSAGE_LENGTH,
        InputValidator.RATE_LIMIT_PER_MINUTE))
end

----------------------------------------------------------------
-- RETURN
----------------------------------------------------------------

return InputValidator
