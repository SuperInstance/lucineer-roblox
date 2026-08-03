--[[
    Lucineer HTTP Module
    Wraps HttpService with JSON, auth, and retry-with-backoff.
    All outbound HTTP flows through here.

    SECURITY: WORKER_URL and AUTH_KEY are no longer read from Config (which
    replicates to clients). They are injected by the server at init time via
    Http.configure(). If configure() is never called, Http fails closed.
]]

local HttpService = game:GetService("HttpService")
local Config = require(script.Parent.Config)

local Http = {}

-- Server-injected credentials (set via Http.configure)
local _workerUrl: string? = nil
local _authKey: string = ""

--[[
    Configure the HTTP module with server-only credentials.
    Called once during server initialization from LucineerServer/init.lua.
    @param workerUrl string -- the Cloudflare Worker URL
    @param authKey string -- the auth key (from ServerConfig)
]]
function Http.configure(workerUrl: string, authKey: string)
    _workerUrl = workerUrl
    _authKey = authKey or ""
    print(string.format("[Lucineer] Http: configured (endpoint=%s)", workerUrl))
end

--[[
    Encode a Lua table as a JSON string.
    @param t table -- the table to encode
    @return string
]]
function Http.encode(t: { [string]: any }): string
    return HttpService:JSONEncode(t)
end

--[[
    Decode a JSON string into a Lua table.
    @param s string -- the JSON to decode
    @return table
]]
function Http.decode(s: string): { [string]: any }
    return HttpService:JSONDecode(s)
end

--[[
    Build the auth + content-type headers for every request.
    Uses the server-injected auth key, never a replicated value.
    @return table
]]
function Http.headers(): { [string]: string }
    return {
        ["Content-Type"] = "application/json",
        ["X-Lucineer-Key"] = _authKey,
    }
end

--[[
    Sleep helper for backoff delays.
    @param seconds number
]]
local function sleep(seconds: number)
    local start = os.clock()
    while os.clock() - start < seconds do
        task.wait()
    end
end

--[[
    Compute exponential backoff delay for a given attempt.
    @param attempt number -- 1-based retry number
    @return number -- delay in seconds
]]
function Http.backoffDelay(attempt: number): number
    local delay = Config.HTTP_BASE_DELAY * (2 ^ (attempt - 1))
    return math.min(delay, Config.HTTP_MAX_DELAY)
end

--[[
    Core request with retry + exponential backoff.
    Makes up to Config.HTTP_MAX_RETRIES + 1 attempts.
    @param url string -- full URL
    @param method string -- "GET" | "POST" | "PATCH" | "DELETE"
    @param body table? -- optional request body (will be JSON-encoded)
    @return table? -- decoded JSON response, or nil on failure
    @return string? -- error message on failure
]]
function Http.request(url: string, method: string, body: { [string]: any }?): (table?, string?)
    if not _workerUrl then
        return nil, "Http not configured: call Http.configure(url, key) at server init"
    end

    local lastErr: string? = nil

    for attempt = 1, Config.HTTP_MAX_RETRIES + 1 do
        local ok, result = pcall(function()
            local requestBody = body and Http.encode(body) or nil
            local response = HttpService:RequestAsync({
                Url = url,
                Method = method,
                Headers = Http.headers(),
                Body = requestBody,
            })
            return response
        end)

        if ok then
            -- RequestAsync returns { Success, StatusCode, Body, Headers }
            if result.Success then
                local decoded = nil
                if result.Body and #result.Body > 0 then
                    local dOk, dResult = pcall(Http.decode, result.Body)
                    decoded = dOk and dResult or nil
                end
                return decoded or {}, nil
            else
                lastErr = string.format("HTTP %d: %s", result.StatusCode, result.Body or "")
                -- 4xx is a contract error, not a transient failure. Fail fast.
                -- (except 429 Too Many Requests, which IS transient)
                if result.StatusCode >= 400 and result.StatusCode < 500 and result.StatusCode ~= 429 then
                    return nil, lastErr
                end
            end
        else
            lastErr = tostring(result)
        end

        -- Don't sleep after the last attempt
        if attempt <= Config.HTTP_MAX_RETRIES then
            local delay = Http.backoffDelay(attempt)
            print(string.format("[Lucineer] HTTP retry %d/%d after %.1fs: %s", attempt, Config.HTTP_MAX_RETRIES, delay, lastErr))
            sleep(delay)
        end
    end

    return nil, lastErr or "Request failed after all retries"
end

--[[
    Convenience: GET request
    @param path string -- path on the worker (e.g. "/api/job/123")
    @return table? -- decoded response
    @return string? -- error
]]
function Http.get(path: string): (table?, string?)
    if not _workerUrl then
        return nil, "Http not configured"
    end
    return Http.request(_workerUrl .. path, "GET")
end

--[[
    Convenience: POST request
    @param path string -- path on the worker
    @param body table -- request body
    @return table? -- decoded response
    @return string? -- error
]]
function Http.post(path: string, body: { [string]: any }): (table?, string?)
    if not _workerUrl then
        return nil, "Http not configured"
    end
    return Http.request(_workerUrl .. path, "POST", body)
end

return Http
