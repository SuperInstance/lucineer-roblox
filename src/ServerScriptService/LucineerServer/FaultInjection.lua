--!strict
--[[
    FaultInjection.lua — Diagnostic Fault Injection for Lucineer Server
    ==================================================================
    "The sea doesn't break things to be cruel. It breaks things so you
     learn what matters. This module is the sea, on a schedule."

    A diagnostic module that simulates network faults, model timeouts,
    and degraded responses so the server can be tested under adverse
    conditions without actually taking the Worker offline.

    Faults:
      1. LATENCY: inject artificial delay before forwarding build responses
      2. TIMEOUT: simulate model timeout — return error after N seconds
      3. FAILURE_LOG: record every fault with timestamps for post-mortem

    Toggle via ServerConfig or runtime API. Off by default in production.

    Usage:
        local FaultInjection = require(script.Parent.FaultInjection)
        FaultInjection.init()

        -- Runtime control
        FaultInjection.setEnabled(true)
        FaultInjection.setLatency(2.5)       -- 2.5s delay on responses
        FaultInjection.setTimeout(15)        -- 15s timeout simulation
        FaultInjection.logFault("CUSTOM", "something weird happened")

        -- Wrap a response before delivering to the player
        local modifiedResponse = FaultInjection.processResponse(player, response)
]]

local Players = game:GetService("Players")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local FaultInjection = {}

-- Configuration (defaults — override via ServerConfig or runtime setters)
FaultInjection._enabled = false
FaultInjection._latencySeconds = 0        -- 0 = no injected latency
FaultInjection._timeoutSeconds = 0        -- 0 = no timeout simulation
FaultInjection._failureRate = 0           -- 0.0–1.0 probability of random failure
FaultInjection._log = {}                  -- { {timestamp, type, detail}, ... }
FaultInjection._maxLogEntries = 200       -- ring buffer cap
FaultInjection._initialized = false

-- Random seed for failure rate simulation
local _rng = Random.new()

----------------------------------------------------------------
-- LOGGING
----------------------------------------------------------------

--[[
    Log a fault event with timestamp.
    Keeps a ring buffer of the last _maxLogEntries entries.

    @param faultType string -- e.g. "LATENCY", "TIMEOUT", "FAILURE", "CUSTOM"
    @param detail string -- human-readable description
]]
function FaultInjection.logFault(faultType: string, detail: string)
    local entry = {
        timestamp = os.time(),
        osTime = os.date("%Y-%m-%d %H:%M:%S"),
        type = faultType,
        detail = detail or "",
    }
    table.insert(FaultInjection._log, entry)

    -- Trim if over cap (FIFO)
    while #FaultInjection._log > FaultInjection._maxLogEntries do
        table.remove(FaultInjection._log, 1)
    end

    -- Also warn to console for visibility during testing
    warn(string.format("[FaultInjection] %s: %s — %s",
        entry.osTime, faultType, detail or ""))
end

--[[
    Get the fault log (newest first).
    @return {table} -- array of log entries
]]
function FaultInjection.getLog(): {table}
    -- Return reversed copy (newest first)
    local reversed = {}
    for i = #FaultInjection._log, 1, -1 do
        table.insert(reversed, FaultInjection._log[i])
    end
    return reversed
end

--[[
    Clear the fault log.
]]
function FaultInjection.clearLog()
    FaultInjection._log = {}
end

----------------------------------------------------------------
-- CONFIGURATION
----------------------------------------------------------------

--[[
    Enable or disable fault injection at runtime.
    @param enabled boolean
]]
function FaultInjection.setEnabled(enabled: boolean)
    FaultInjection._enabled = enabled
    FaultInjection.logFault("CONFIG", string.format("Fault injection %s",
        enabled and "ENABLED" or "DISABLED"))
end

--[[
    Set artificial latency in seconds.
    @param seconds number -- 0 to disable
]]
function FaultInjection.setLatency(seconds: number)
    FaultInjection._latencySeconds = math.max(0, seconds)
    if seconds > 0 then
        FaultInjection.logFault("CONFIG", string.format("Latency set to %.2fs", seconds))
    end
end

--[[
    Set simulated timeout in seconds. Responses that would take longer
    than this are replaced with a timeout error.
    @param seconds number -- 0 to disable
]]
function FaultInjection.setTimeout(seconds: number)
    FaultInjection._timeoutSeconds = math.max(0, seconds)
    if seconds > 0 then
        FaultInjection.logFault("CONFIG", string.format("Timeout simulation set to %.2fs", seconds))
    end
end

--[[
    Set random failure rate (0.0–1.0).
    Each processed response has this probability of being replaced with an error.
    @param rate number -- 0.0 to 1.0
]]
function FaultInjection.setFailureRate(rate: number)
    FaultInjection._failureRate = math.clamp(rate, 0, 1)
    if rate > 0 then
        FaultInjection.logFault("CONFIG", string.format("Failure rate set to %.0f%%", rate * 100))
    end
end

--[[
    Check if fault injection is currently active.
    @return boolean
]]
function FaultInjection.isEnabled(): boolean
    return FaultInjection._enabled
end

----------------------------------------------------------------
-- RESPONSE PROCESSING
----------------------------------------------------------------

--[[
    Process a response before it's delivered to the player.
    Applies latency, timeout, and random failure injection.

    This is an ASYNC function — it yields before returning the (possibly
    modified) response. Call from a task.spawn context.

    @param player Player -- the player who will receive the response
    @param response table -- the original response from the Worker
    @return table -- the response to deliver (may be modified or errored)
]]
function FaultInjection.processResponse(player: Player, response: table): table
    if not FaultInjection._enabled then
        return response
    end

    -- ── Random failure injection ──
    if FaultInjection._failureRate > 0 then
        if _rng:NextNumber() < FaultInjection._failureRate then
            FaultInjection.logFault("FAILURE",
                string.format("Random failure injected for %s", player.Name))
            return {
                error = true,
                message = "Connection to the shipyard was lost. Try again.",
                faultInjected = true,
            }
        end
    end

    -- ── Timeout simulation ──
    if FaultInjection._timeoutSeconds > 0 then
        FaultInjection.logFault("TIMEOUT",
            string.format("Simulating %ds timeout for %s",
                FaultInjection._timeoutSeconds, player.Name))

        task.wait(FaultInjection._timeoutSeconds)

        return {
            error = true,
            message = string.format(
                "The build request timed out after %d seconds. The shipyard may be overloaded.",
                FaultInjection._timeoutSeconds
            ),
            faultInjected = true,
            timeoutDuration = FaultInjection._timeoutSeconds,
        }
    end

    -- ── Latency injection ──
    if FaultInjection._latencySeconds > 0 then
        FaultInjection.logFault("LATENCY",
            string.format("Injecting %.2fs delay for %s",
                FaultInjection._latencySeconds, player.Name))

        task.wait(FaultInjection._latencySeconds)
    end

    -- Tag the response as having passed through fault injection
    response.faultChecked = true
    return response
end

----------------------------------------------------------------
-- BUILT-IN TEST SCENARIOS
----------------------------------------------------------------

--[[
    Run a predefined test scenario.
    Useful for QA playtests — set scenario, then interact normally.

    @param scenarioName string -- one of: "clean", "slow", "timeout",
                                 "flaky", "stress"
]]
function FaultInjection.runScenario(scenarioName: string)
    FaultInjection.setEnabled(true)

    if scenarioName == "clean" then
        FaultInjection.setLatency(0)
        FaultInjection.setTimeout(0)
        FaultInjection.setFailureRate(0)
        FaultInjection.logFault("SCENARIO", "Clean run — no faults")

    elseif scenarioName == "slow" then
        FaultInjection.setLatency(3)
        FaultInjection.setTimeout(0)
        FaultInjection.setFailureRate(0)
        FaultInjection.logFault("SCENARIO", "Slow network — 3s latency")

    elseif scenarioName == "timeout" then
        FaultInjection.setLatency(0)
        FaultInjection.setTimeout(10)
        FaultInjection.setFailureRate(0)
        FaultInjection.logFault("SCENARIO", "Timeout — 10s to failure")

    elseif scenarioName == "flaky" then
        FaultInjection.setLatency(1)
        FaultInjection.setTimeout(0)
        FaultInjection.setFailureRate(0.3)
        FaultInjection.logFault("SCENARIO", "Flaky — 1s latency, 30% failures")

    elseif scenarioName == "stress" then
        FaultInjection.setLatency(2)
        FaultInjection.setTimeout(8)
        FaultInjection.setFailureRate(0.5)
        FaultInjection.logFault("SCENARIO", "Stress — 2s latency, 8s timeout, 50% failures")

    else
        warn(string.format("[FaultInjection] Unknown scenario: %s", scenarioName))
        warn("Available scenarios: clean, slow, timeout, flaky, stress")
    end
end

----------------------------------------------------------------
-- INITIALIZATION
----------------------------------------------------------------

--[[
    Initialize fault injection. Reads ServerConfig flags if present.
    Safe to call multiple times.

    ServerConfig may define:
      ServerConfig.FAULT_INJECTION_ENABLED = true/false
      ServerConfig.FAULT_LATENCY = number (seconds)
      ServerConfig.FAULT_TIMEOUT = number (seconds)
      ServerConfig.FAULT_FAILURE_RATE = number (0.0–1.0)
]]
function FaultInjection.init()
    if FaultInjection._initialized then return end
    FaultInjection._initialized = true

    -- Try to read config from ServerConfig
    local ok, ServerConfig = pcall(function()
        return require(script.Parent:WaitForChild("ServerConfig"))
    end)

    if ok and ServerConfig then
        if ServerConfig.FAULT_INJECTION_ENABLED then
            FaultInjection._enabled = true
        end
        if ServerConfig.FAULT_LATENCY then
            FaultInjection._latencySeconds = ServerConfig.FAULT_LATENCY
        end
        if ServerConfig.FAULT_TIMEOUT then
            FaultInjection._timeoutSeconds = ServerConfig.FAULT_TIMEOUT
        end
        if ServerConfig.FAULT_FAILURE_RATE then
            FaultInjection._failureRate = ServerConfig.FAULT_FAILURE_RATE
        end
    end

    -- If any config value is set, log the startup state
    if FaultInjection._enabled then
        FaultInjection.logFault("INIT",
            string.format("Fault injection active — latency: %.1fs, timeout: %.1fs, failure rate: %.0f%%",
                FaultInjection._latencySeconds,
                FaultInjection._timeoutSeconds,
                FaultInjection._failureRate * 100))
    else
        print("[FaultInjection] Initialized — dormant (enable via setEnabled(true))")
    end
end

----------------------------------------------------------------
-- RETURN
----------------------------------------------------------------

return FaultInjection
