--[[
    Lucineer Job Poller
    Tracks active jobs by ID, polls GET /api/job/:jobId at the configured interval,
    fires callbacks on completion or error, and times out after Config.POLL_TIMEOUT seconds.
]]

local Config = require(script.Parent.Config)
local Http = require(script.Parent.Http)

--[[
    Structure of a tracked job:
    {
        id: string,
        startedAt: number (os.clock()),
        onComplete: (response: { [string]: any }) -> (),
        onError: (error: string) -> (),
    }
]]

export type Job = {
    id: string,
    startedAt: number,
    onComplete: (response: { [string]: any }) -> (),
    onError: (err: string) -> (),
}

local Poller = {}
Poller._jobs = {} :: { [string]: Job }
Poller._inFlight = {} :: { [string]: boolean }  -- GAP #10/A6: prevent overlapping polls per job
Poller._accumulator = 0 :: number
Poller._timeoutAccumulator = 0 :: number  -- GAP #10/A6: throttle checkTimeouts to poll interval
Poller._initialized = false

--[[
    Register a new job for polling.
    @param jobId string -- the job ID returned by the Worker
    @param onComplete (table) -> () -- called when the job completes successfully
    @param onError (string) -> () -- called on error or timeout
]]
function Poller.register(jobId: string, onComplete: (table) -> (), onError: (string) -> ())
    local job: Job = {
        id = jobId,
        startedAt = os.clock(),
        onComplete = onComplete,
        onError = onError,
    }
    Poller._jobs[jobId] = job
    print(string.format("[Lucineer] Poller: registered job %s", jobId))
end

--[[
    Remove a job from active tracking.
    @param jobId string
]]
function Poller.unregister(jobId: string)
    Poller._jobs[jobId] = nil
    Poller._inFlight[jobId] = nil  -- GAP #10/A6: clean up in-flight flag
end

--[[
    Get count of currently active jobs.
    @return number
]]
function Poller.activeCount(): number
    local count = 0
    for _ in pairs(Poller._jobs) do
        count += 1
    end
    return count
end

--[[
    Poll a single job by ID.
    Fires the appropriate callback and unregisters on terminal status.
    @param job Job
]]
local function pollJob(job: Job)
    -- GAP #10/A6: in-flight guard so overlapping polls don't stack
    if Poller._inFlight[job.id] then
        return
    end
    Poller._inFlight[job.id] = true

    local response, err = Http.get("/api/job/" .. job.id)

    Poller._inFlight[job.id] = nil

    if err then
        print(string.format("[Lucineer] Poller: HTTP error for job %s: %s", job.id, err))
        return -- will retry on next tick (unless timed out)
    end

    local status = response.status or response.state or "unknown"
    status = string.lower(status)

    if status == "complete" or status == "completed" or status == "done" then
        print(string.format("[Lucineer] Poller: job %s completed", job.id))
        local ok, cbErr = pcall(job.onComplete, response)
        if not ok then
            warn(string.format("[Lucineer] Poller: onComplete callback error for job %s: %s", job.id, tostring(cbErr)))
        end
        Poller.unregister(job.id)

    elseif status == "error" or status == "failed" then
        local errMsg = response.error or response.message or "Job failed"
        print(string.format("[Lucineer] Poller: job %s failed: %s", job.id, errMsg))
        local ok = pcall(job.onError, errMsg)
        Poller.unregister(job.id)

    elseif status == "processing" or status == "pending" or status == "queued" then
        -- Still in progress, do nothing
    end
end

--[[
    Check all tracked jobs for timeout.
    Fires onError with timeout message and unregisters.
]]
local function checkTimeouts()
    local now = os.clock()
    for jobId, job in pairs(Poller._jobs) do
        if now - job.startedAt >= Config.POLL_TIMEOUT then
            print(string.format("[Lucineer] Poller: job %s timed out after %ds", jobId, Config.POLL_TIMEOUT))
            local ok = pcall(job.onError, "Job timed out after " .. tostring(Config.POLL_TIMEOUT) .. " seconds")
            Poller.unregister(jobId)
        end
    end
end

--[[
    Heartbeat tick. Call this from RunService.Heartbeat.
    Accumulates time and polls all active jobs at Config.POLL_INTERVAL.
    @param dt number -- delta time from Heartbeat
]]
function Poller.tick(dt: number)
    Poller._accumulator += dt

    -- GAP #10/A6: Move checkTimeouts from every Heartbeat (60×/s) to inside
    -- the poll interval. The timeout table only changes on poll cycles,
    -- so checking every tick is wasted work.
    Poller._timeoutAccumulator += dt
    if Poller._timeoutAccumulator >= Config.POLL_INTERVAL then
        Poller._timeoutAccumulator = 0
        checkTimeouts()
    end

    -- Only poll at the configured interval
    if Poller._accumulator < Config.POLL_INTERVAL then
        return
    end

    Poller._accumulator = 0

    -- Snapshot job IDs to avoid mutation-during-iteration issues
    local jobsToPoll = {}
    for jobId, job in pairs(Poller._jobs) do
        table.insert(jobsToPoll, job)
    end

    for _, job in ipairs(jobsToPoll) do
        task.spawn(function()
            pollJob(job)
        end)
    end
end

--[[
    Initialize the Poller. Call once at startup.
]]
function Poller.init()
    if Poller._initialized then
        warn("[Lucineer] Poller: already initialized")
        return
    end
    Poller._initialized = true
    Poller._jobs = {}
    Poller._inFlight = {}
    Poller._accumulator = 0
    Poller._timeoutAccumulator = 0
    print("[Lucineer] Poller: initialized")
end

return Poller
