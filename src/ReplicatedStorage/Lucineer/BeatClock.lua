--[[
    BeatClock — Client-side mirror of the authoritative BeatClock.
    ──────────────────────────────────────────────────────────────
    The authoritative BeatClock lives in the BuildCoordinator Durable
    Object (Layer 10). This Luau mirror runs on the client and provides
    local tick/beat queries without round-tripping to the server.

    Synchronization:
      - On WebSocket connect, the server sends the current BPM and tick.
      - Channel-15 META tempo events update the BPM.
      - Drift correction happens on every WebSocket message (≤1 tick/beat).

    The mirror computes ticks from elapsed wall-clock time between sync
    points. It is approximate by definition; the DO is authoritative.

    Usage:
        local BeatClock = require(ReplicatedStorage.Lucineer.BeatClock)
        BeatClock.init(72)               -- initialize at 72 BPM
        local tick = BeatClock.getCurrentTick()
        local beat = BeatClock.getCurrentBeat()
        BeatClock.setBPM(120)            -- META tempo change from server
]]

local BeatClock = {}

-- Default timing constants
local DEFAULT_BPM = 72
local TICKS_PER_BEAT = 8  -- 8th-note resolution in beats; 96 PPQ = 8 per beat at 32nd note

-- Internal state
BeatClock.bpm = DEFAULT_BPM
BeatClock.ticksPerBeat = TICKS_PER_BEAT
BeatClock.startTick = 0
BeatClock.startTime = 0

--[[
    Initialize the BeatClock at a given BPM.
    Sets the reference point for tick computation.

    @param bpm number? — starting BPM (defaults to 72, Andante)
]]
function BeatClock.init(bpm: number?)
    BeatClock.bpm = bpm or DEFAULT_BPM
    BeatClock.startTick = 0
    BeatClock.startTime = os.clock()
end

--[[
    Set a new BPM. Called on channel-15 META tempo change events.
    Preserves the current tick position so the clock doesn't jump.

    @param bpm number — new BPM
]]
function BeatClock.setBPM(bpm: number)
    if typeof(bpm) ~= "number" or bpm <= 0 then return end

    -- Capture the current tick before changing tempo
    local currentTick = BeatClock.getCurrentTick()

    -- Re-anchor: the new reference point is (currentTick, now)
    BeatClock.startTick = currentTick
    BeatClock.startTime = os.clock()
    BeatClock.bpm = bpm
end

--[[
    Synchronize from a server-provided tick value.
    Called when a WebSocket message arrives with an authoritative tick.

    @param serverTick number — the authoritative tick from the DO
    @param bpm number? — optional BPM update alongside the sync
]]
function BeatClock.syncFromServer(serverTick: number, bpm: number?)
    if typeof(serverTick) ~= "number" then return end

    BeatClock.startTick = serverTick
    BeatClock.startTime = os.clock()

    if bpm and typeof(bpm) == "number" and bpm > 0 then
        BeatClock.bpm = bpm
    end
end

--[[
    Get the BPM.

    @return number — current BPM
]]
function BeatClock.getBPM(): number
    return BeatClock.bpm
end

--[[
    Compute seconds since the clock was initialized (or last sync'd).
    This is wall-clock elapsed time, not musical time.

    @return number — seconds since init/sync
]]
function BeatClock.elapsed(): number
    return os.clock() - BeatClock.startTime
end

--[[
    Get the duration of a single tick in seconds at the current BPM.

    @return number — seconds per tick
]]
function BeatClock.tickDuration(): number
    -- ticksPerBeat ticks per beat, 60/BPM seconds per beat
    return 60.0 / (BeatClock.bpm * BeatClock.ticksPerBeat)
end

--[[
    Compute the current tick from elapsed time since the reference point.
    This is the core computation — everything else derives from it.

    @return number — current tick (uint32-equivalent, always >= 0)
]]
function BeatClock.getCurrentTick(): number
    local elapsedSec = BeatClock.elapsed()
    local ticksElapsed = elapsedSec / BeatClock.tickDuration()
    return math.floor(BeatClock.startTick + ticksElapsed)
end

--[[
    Get the current beat position (tick / ticksPerBeat).

    @return number — current beat (float, includes partial beats)
]]
function BeatClock.getCurrentBeat(): number
    return BeatClock.getCurrentTick() / BeatClock.ticksPerBeat
end

--[[
    Convert a tick value to a beat value.

    @param tick number
    @return number — beat position
]]
function BeatClock.tickToBeat(tick: number): number
    return tick / BeatClock.ticksPerBeat
end

--[[
    Convert a beat value to a tick value.

    @param beat number
    @return number — tick position
]]
function BeatClock.beatToTick(beat: number): number
    return math.floor(beat * BeatClock.ticksPerBeat)
end

--[[
    Get the 32nd-note grid interval at the current BPM.
    This is the musical duration that replaces the old hardcoded 0.08s stagger.

    32nd note = beat / 8 (8 thirty-second notes per quarter note beat)
    At 120 BPM: 60/120/8 = 0.0625s
    At 90 BPM:  60/90/8  = 0.083s
    At 72 BPM:  60/72/8  = 0.104s

    @return number — seconds per 32nd note at current BPM
]]
function BeatClock.get32ndNoteDuration(): number
    return 60.0 / (BeatClock.bpm * 8)
end

return BeatClock
