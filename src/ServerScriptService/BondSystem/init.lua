--!strict
--[[
    BondSystem — Lucineer's Behavior-Triggered Relationship System
    ===============================================================
    Rewritten from XP ladder to behavior-triggered bond progression.

    Per CHARACTER_BIBLE §4 and PLAYER_GAMIFICATION:
        - No visible progress bar. The player feels the relationship
          deepening through how Lucineer treats them.
        - Bond advances on completed collaborations, not conversation.
        - Each tier changes Lucineer's BEHAVIOR, not just his dialogue.
        - No XP grind — discrete behavior events accumulate toward
          tier thresholds, and each tier unlocks behavioral changes.

    Five Tiers (0-indexed, matching Character Bible §4):
        0 — Stranger      (bond 0–9)     He's working for you.
        1 — Acquaintance  (bond 10–29)   He's noticed you keep showing up.
        2 — Crew          (bond 30–69)   He'll argue with you now.
        3 — Confidant     (bond 70–149)  You're not a client anymore.
        4 — Partner       (bond 150+)    He tells you the truth.

    Behavior Triggers (from Character Bible §4 Bond Points table):
        +1   First build of a session (showing up)
        +5   Player finishes something Lucineer left unfinished (core loop)
        +3   Player builds something manually, no request (independence)
        +2   Player asks Lucineer to modify rather than replace (investment)
        +4   Player argues back and wins (relationship)
        +2   Player returns after >24h absence (continuity)
        -1   Player deletes a Lucineer build without inspecting (floor at current tier)

    Integration Hooks:
        - Memory service: bond_level + bond_points persisted to D1
        - Voice line selection: getTier() drives personality injection
        - WorldScanner: open hooks tracked for finish-detection

    API Compatibility:
        All existing method names are preserved. Methods that were
        XP-oriented (addBuildXP etc.) now route to behavior-triggered
        bond events internally. New methods are added for the richer
        behavior model.

    Dependencies:
        - ReplicatedStorage.Lucineer.Http
        - ReplicatedStorage.Lucineer.VoiceLines
        - ServerScriptService.AchievementManager (optional)
]]

local Http = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("Http"))
local VoiceLines = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("VoiceLines"))

local Players = game:GetService("Players")

-- Memory worker URL for bond level persistence
-- NOTE: BondSystem uses raw HttpService:RequestAsync (not Http module) because it
-- needs full URL control. Bug 2 fix: we must include auth headers manually.
local MEMORY_URL = "https://lucineer-memory.casey-digennaro.workers.dev"

-- Bug 2 fix: ServerConfig for auth key
local ServerConfig = require(script.Parent:WaitForChild("LucineerServer"):WaitForChild("ServerConfig"))

-- ═══════════════════════════════════════════════════════════════════════════
-- TIER CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Bond point thresholds for each tier (0-indexed tiers, matching Bible §4).
-- These are cumulative bond points.
local TIER_THRESHOLDS = {
    [0] = 0,     -- Stranger
    [1] = 10,    -- Acquaintance
    [2] = 30,    -- Crew
    [3] = 70,    -- Confidant
    [4] = 150,   -- Partner
}

-- Maximum tier index
local MAX_TIER = 4

-- Tier names
local TIER_NAMES = {
    [0] = "Stranger",
    [1] = "Acquaintance",
    [2] = "Crew",
    [3] = "Confidant",
    [4] = "Partner",
}

-- Tier descriptions (internal reference, not shown to player)
local TIER_DESCRIPTIONS = {
    [0] = "He's working for you. Formal-adjacent. Uses your name occasionally, like a foreman reading a work order. States what he built. Offers one opinion. Doesn't elaborate. No Magnus, no Alaska.",
    [1] = "He's noticed you keep showing up. Drops formality. Starts referencing your previous builds. First Magnus reference. First Alaska reference. Begins asking questions.",
    [2] = "He'll argue with you now. Disagreement unlocks fully. Volunteers work you didn't ask for. References history of builds. Will admit uncertainty. First genuine compliment — earned, specific, deflected.",
    [3] = "You're not a client anymore. Speaks in 'we'. Refers to the world as shared. Asks you to build things. Will refuse work out of preference. Remembers things you said, not just things you built.",
    [4] = "He tells you the truth. The unfinished-work confession becomes available. Talks about old engines unprompted. Stops leaving things unfinished (or says so out loud). Delegates to you.",
}

-- Bond event point values (from Character Bible §4 Bond Points table)
local BOND_EVENTS = {
    first_build_of_session = 1,    -- Showing up
    hook_completed = 5,            -- Player finished something Lucineer left unfinished (CORE LOOP)
    independent_build = 3,         -- Player builds something manually, no request
    modify_not_replace = 2,        -- Player asks to modify rather than replace
    argued_and_won = 4,            -- Player argued back and won
    returned_next_day = 2,         -- Player returns after >24h absence
    deleted_without_inspection = -1, -- Player deleted a Lucineer build without inspecting
}

-- ═══════════════════════════════════════════════════════════════════════════
-- BEHAVIORAL UNLOCKS PER TIER
-- ═══════════════════════════════════════════════════════════════════════════
-- These are queryable by other systems to change Lucineer's behavior.
-- Each tier cumulatively enables more behaviors.

local TIER_BEHAVIORS = {
    [0] = {
        uses_formal_address = true,
        references_previous_builds = false,
        uses_magnus_references = false,
        uses_alaska_references = false,
        asks_questions = false,
        argues = false,
        volunteers_work = false,
        uses_we = false,
        asks_player_to_build = false,
        refuses_work = false,
        remembers_conversation = false,
        confesses_unfinished_pattern = false,
        delegates_to_player = false,
        leaves_things_unfinished = true,
        uses_nicknames = false,
        shares_opinions = false,
    },
    [1] = {
        uses_formal_address = false,
        references_previous_builds = true,
        uses_magnus_references = true,
        uses_alaska_references = true,
        asks_questions = true,
        argues = false,
        volunteers_work = false,
        uses_we = false,
        asks_player_to_build = false,
        refuses_work = false,
        remembers_conversation = false,
        confesses_unfinished_pattern = false,
        delegates_to_player = false,
        leaves_things_unfinished = true,
        uses_nicknames = false,
        shares_opinions = true,
    },
    [2] = {
        uses_formal_address = false,
        references_previous_builds = true,
        uses_magnus_references = true,
        uses_alaska_references = true,
        asks_questions = true,
        argues = true,
        volunteers_work = true,
        uses_we = false,
        asks_player_to_build = false,
        refuses_work = false,
        remembers_conversation = false,
        confesses_unfinished_pattern = false,
        delegates_to_player = false,
        leaves_things_unfinished = true,
        uses_nicknames = true,
        shares_opinions = true,
    },
    [3] = {
        uses_formal_address = false,
        references_previous_builds = true,
        uses_magnus_references = true,
        uses_alaska_references = true,
        asks_questions = true,
        argues = true,
        volunteers_work = true,
        uses_we = true,
        asks_player_to_build = true,
        refuses_work = true,
        remembers_conversation = true,
        confesses_unfinished_pattern = false,
        delegates_to_player = false,
        leaves_things_unfinished = true,
        uses_nicknames = true,
        shares_opinions = true,
    },
    [4] = {
        uses_formal_address = false,
        references_previous_builds = true,
        uses_magnus_references = true,
        uses_alaska_references = true,
        asks_questions = true,
        argues = true,
        volunteers_work = true,
        uses_we = true,
        asks_player_to_build = true,
        refuses_work = true,
        remembers_conversation = true,
        confesses_unfinished_pattern = true,  -- once, then stays available
        delegates_to_player = true,
        leaves_things_unfinished = false,     -- stops leaving things unfinished (or says so)
        uses_nicknames = true,
        shares_opinions = true,
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- TIER TRANSITION VOICE LINES
-- ═══════════════════════════════════════════════════════════════════════════
-- These fire ONCE on tier transition. They're the moment the player
-- notices the relationship has changed. No UI notification — just
-- Lucineer acting different. Lines from CHARACTER_BIBLE §4.

local TIER_TRANSITION_LINES = {
    [1] = {
        -- Tier 1 — Acquaintance: first time he references previous work
        "Second tower. You like height. Put this one downhill of the first — you'll get a sightline at dusk.",
        "Back again. Same kind of build? You've got a type.",
        "Noticed you kept the rail on the last one. Good. That one's yours.",
    },
    [2] = {
        -- Tier 2 — Crew: first time he argues and uses nicknames
        "That's a good roofline. Better than mine would've been — I'd have run it flatter and it'd have looked cheap. Don't let it go to your head, the gutters are wrong.",
        "Nah. Build it yourself, you'll do it better than I would. Been watching you.",
        "You've got opinions. Good. I've been waiting for someone to argue with.",
    },
    [3] = {
        -- Tier 3 — Confidant: first "we", shared world
        "Been thinking about the south approach since last time. Ground's soft there and we both know it. I want to drive piles before we put anything permanent on it.",
        "We'll need more stock for this one.",
        "I need a hand. Run me a wall from the gate to the water and I'll do the rest.",
    },
    [4] = {
        -- Tier 4 — Partner: the truth, the confession, the delegation
        "Man I learned from did it to me. Every job, something left over. Took me nine years to work out he wasn't being lazy. Same thing. Except I'm telling you, which he'd say was cheating.",
        "You've got a better eye for where things go than I do. Always did. Your call — I'll build whatever you point at.",
        "It runs. Load's rated for anything you'll ever put on it. It's yours.",
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- OPEN HOOKS TRACKING
-- ═══════════════════════════════════════════════════════════════════════════
-- Lucineer deliberately leaves things unfinished. We track these as
-- "open hooks" so WorldScanner can detect when the player completes them.
-- This is the core bond loop: Lucineer leaves bait → player takes it.

-- Open hooks per player. Keyed by hookId.
-- { [playerName] = { [hookId] = { description, position, created_session, completed } } }
local openHooks: { [string]: { [string]: { [string]: any } } } = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

local BondSystem = {}

-- Per-player state keyed by player name.
-- Fields:
--   bondPoints      — cumulative points toward tier thresholds
--   tier            — current tier (0-4)
--   lastSeen        — timestamp of last activity (os.time())
--   sessionFirstBuild — whether the player has built this session
--   behaviors       — cached behavior flags for current tier
--   eventLog        — recent bond events (for debugging/personality)
--   openHookCount   — number of open (uncompleted) hooks
--   totalHooks      — total hooks ever opened
--   hooksCompleted  — total hooks the player has finished
--   confessionGiven — whether the Tier 4 confession has been delivered
local playerData: { [string]: { [string]: any } } = {}

--[[
    Get or create player bond data.
    @param playerName string
    @return table
]]
local function getData(playerName: string): { [string]: any }
    if not playerData[playerName] then
        playerData[playerName] = {
            bondPoints = 0,
            tier = 0,
            lastSeen = os.time(),
            sessionFirstBuild = false,
            behaviors = TIER_BEHAVIORS[0],
            eventLog = {},
            openHookCount = 0,
            totalHooks = 0,
            hooksCompleted = 0,
            confessionGiven = false,
        }
    end
    return playerData[playerName]
end

--[[
    Get the tier for a given bond point total.
    @param bondPoints number
    @return number -- 0 to MAX_TIER
]]
local function calculateTier(bondPoints: number): number
    local tier = 0
    for checkTier = MAX_TIER, 0, -1 do
        if bondPoints >= TIER_THRESHOLDS[checkTier] then
            tier = checkTier
            break
        end
    end
    return tier
end

--[[
    Record a bond event in the player's event log.
    Keeps the last 20 events for personality/reference.
    @param playerName string
    @param eventType string
    @param points number
]]
local function logEvent(playerName: string, eventType: string, points: number)
    local data = getData(playerName)
    local log = data.eventLog
    if typeof(log) ~= "table" then
        log = {}
        data.eventLog = log
    end

    -- Insert at front, keep last 20
    table.insert(log, 1, {
        event = eventType,
        points = points,
        timestamp = os.time(),
    })

    while #log > 20 do
        table.remove(log, #log)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- D1 PERSISTENCE
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Persist bond level and points to D1 player_profiles via the memory worker.
    Fire-and-forget.
    @param playerName string
    @param tier number
    @param bondPoints number
]]
local function persistBond(playerName: string, tier: number, bondPoints: number)
    task.spawn(function()
        local HttpService = game:GetService("HttpService")
        local url = MEMORY_URL .. "/api/memory/player"
        local body = HttpService:JSONEncode({
            player_name = playerName,
            bond_level = tier,
            bond_points = bondPoints,
        })

        local ok, response = pcall(function()
            return HttpService:RequestAsync({
                Url = url,
                Method = "POST",
                Headers = {
                    ["Content-Type"] = "application/json",
                    ["X-Lucineer-Key"] = ServerConfig.AUTH_KEY,  -- Bug 2 fix
                },
                Body = body,
            })
        end)

        if not ok or not response.Success then
            warn(string.format("[BondSystem] Failed to persist bond for %s (tier %d, %d points): %s",
                playerName, tier, bondPoints, tostring(response)))
        end
    end)
end

--[[
    Load bond data from D1 player_profiles on player join.
    @param playerName string
]]
local function loadBond(playerName: string)
    task.spawn(function()
        local HttpService = game:GetService("HttpService")
        local url = MEMORY_URL .. "/api/memory/player/" .. playerName

        local ok, response = pcall(function()
            return HttpService:RequestAsync({
                Url = url,
                Method = "GET",
                Headers = {
                    ["Content-Type"] = "application/json",
                    ["X-Lucineer-Key"] = ServerConfig.AUTH_KEY,  -- Bug 2 fix
                },
            })
        end)

        if ok and response.Success and #response.Body > 0 then
            local dataOk, data = pcall(function()
                return HttpService:JSONDecode(response.Body)
            end)
            if dataOk and not data.error then
                local state = getData(playerName)
                local storedTier = tonumber(data.bond_level) or 0
                local storedPoints = tonumber(data.bond_points) or 0

                -- Adopt stored state if it's higher — D1 is source of truth for returning players.
                -- If stored is 0 (known D1 upsert bug), keep in-memory defaults.
                if storedTier > 0 or storedPoints > 0 then
                    state.tier = storedTier
                    state.bondPoints = storedPoints
                    state.behaviors = TIER_BEHAVIORS[storedTier] or TIER_BEHAVIORS[0]
                    print(string.format("[BondSystem] %s loaded from D1: tier %d (%s), %d bond points",
                        playerName, storedTier, TIER_NAMES[storedTier] or "?", storedPoints))
                end
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TIER TRANSITION HANDLING
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Handle a tier transition (level-up).
    Fires voice line, updates behavior flags, notifies other systems.
    @param playerName string
    @param oldTier number
    @param newTier number
]]
local function onTierChanged(playerName: string, oldTier: number, newTier: number)
    print(string.format("[BondSystem] %s bond tier: %d → %d (%s)",
        playerName, oldTier, newTier, TIER_NAMES[newTier] or "?"))

    -- Update cached behavior flags
    local data = getData(playerName)
    data.behaviors = TIER_BEHAVIORS[newTier] or TIER_BEHAVIORS[0]

    -- Pick a random transition voice line
    local lines = TIER_TRANSITION_LINES[newTier]
    if lines and #lines > 0 then
        local line = lines[math.random(1, #lines)]

        -- Deliver via the ResponseEvent remote
        local Lucineer = game:GetService("ReplicatedStorage"):FindFirstChild("Lucineer")
        if Lucineer then
            local remote = Lucineer:FindFirstChild("ResponseEvent")
            if remote then
                local player = Players:FindFirstChild(playerName)
                if player then
                    remote:FireClient(player, {
                        type = "bond_tier_changed",
                        oldTier = oldTier,
                        newTier = newTier,
                        tierName = TIER_NAMES[newTier],
                        message = line,
                    })
                end
            end
        end

        print(string.format("[BondSystem] Tier transition line: \"%s\"", line))
    end

    -- Persist the new tier to D1
    persistBond(playerName, newTier, data.bondPoints)

    -- Notify AchievementManager
    local AchievementManager = require(script.Parent:FindFirstChild("AchievementManager"))
    if AchievementManager then
        AchievementManager.onBondLevelChange(playerName, newTier)
    end

    -- Log the behavioral changes for debugging
    local behaviorNote = ""
    if newTier == 1 then
        behaviorNote = "Previous build references unlocked. Magnus/Alaska references unlocked. Asks questions."
    elseif newTier == 2 then
        behaviorNote = "Arguments unlocked. Nicknames begin. Volunteers work. First compliment available."
    elseif newTier == 3 then
        behaviorNote = "Uses 'we'. Asks player to build. Refuses work sometimes. Remembers conversation."
    elseif newTier == 4 then
        behaviorNote = "Confession available (once). Stops leaving things unfinished. Delegates to player."
    end
    if behaviorNote ~= "" then
        print(string.format("[BondSystem] %s unlocks: %s", playerName, behaviorNote))
    end
end

--[[
    Core: apply bond points from a behavior event and check for tier change.
    @param playerName string
    @param eventType string -- key into BOND_EVENTS
    @return number -- points actually applied (0 if event was clamped)
]]
local function applyBondEvent(playerName: string, eventType: string): number
    local data = getData(playerName)
    local points = BOND_EVENTS[eventType]
    if points == nil then
        warn(string.format("[BondSystem] Unknown bond event: %s", eventType))
        return 0
    end

    local oldTier = data.tier
    local oldPoints = data.bondPoints

    -- Negative events can't drop below the current tier floor.
    -- Per CHARACTER_BIBLE §4 Bond Decay: "Floor at current tier."
    if points < 0 then
        local tierFloor = TIER_THRESHOLDS[oldTier] or 0
        local newPoints = oldPoints + points
        if newPoints < tierFloor then
            newPoints = tierFloor
        end
        data.bondPoints = newPoints
        logEvent(playerName, eventType, newPoints - oldPoints)
        return newPoints - oldPoints
    end

    -- Positive event
    data.bondPoints = oldPoints + points
    logEvent(playerName, eventType, points)

    -- Check for tier change
    local newTier = calculateTier(data.bondPoints)
    if newTier > oldTier then
        data.tier = newTier
        onTierChanged(playerName, oldTier, newTier)
    end

    return points
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API — BEHAVIOR TRIGGERS
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Initialize the BondSystem. Hooks into player join/leave.
]]
function BondSystem.init()
    VoiceLines.init()

    Players.PlayerAdded:Connect(function(player)
        -- Reset session state
        local data = getData(player.Name)
        data.sessionFirstBuild = false
        data.lastSeen = os.time()

        -- Check for return-after-absence (handled in onPlayerJoin)
        loadBond(player.Name)
    end)

    Players.PlayerRemoving:Connect(function(player)
        local data = getData(player.Name)
        -- Persist final state
        persistBond(player.Name, data.tier, data.bondPoints)
        -- Keep data in memory for a bit so leave/rejoin works smoothly.
        -- It'll be garbage collected or overwritten on next join.
    end)

    -- Validate tier thresholds are sorted
    for i = 1, MAX_TIER do
        assert(TIER_THRESHOLDS[i] > TIER_THRESHOLDS[i - 1],
            string.format("[BondSystem] Tier thresholds not monotonically increasing at %d", i))
    end

    print("[BondSystem] Initialized — behavior-triggered bond system, 5 tiers:")
    for i = 0, MAX_TIER do
        print(string.format("  Tier %d: %s (%d+ points)", i, TIER_NAMES[i], TIER_THRESHOLDS[i]))
    end
end

--[[
    Record a build event. If it's the first build of the session, award
    the "showing up" bonus. Always registers an open hook for the player
    to potentially complete.
    @param playerId string -- player username
]]
function BondSystem.addBuildXP(playerId: string)
    local data = getData(playerId)
    if not data.sessionFirstBuild then
        data.sessionFirstBuild = true
        applyBondEvent(playerId, "first_build_of_session")
    end
    data.lastSeen = os.time()
end

--[[
    Record a conversation event. In the new system, conversation alone
    does not advance bond (per CHARACTER_BIBLE §4: "Bond is earned by
    building, not by chatting"). However, we track it for personality
    and session state. No bond points awarded.
    @param playerId string
]]
function BondSystem.addConversationXP(playerId: string)
    local data = getData(playerId)
    data.lastSeen = os.time()
    -- No bond points for conversation — bond is earned by building.
end

--[[
    Record a quest completion. Maps to "independent_build" — the player
    completed something on their own initiative.
    @param playerId string
]]
function BondSystem.addQuestXP(playerId: string)
    applyBondEvent(playerId, "independent_build")
end

--[[
    Record that the player finished something Lucineer left unfinished.
    This is the CORE LOOP of the bond system (+5 points).
    Also fires Magic Moment 3 ("The Handoff") if tier >= 2.

    @param playerId string
    @param hookId string? -- optional hook identifier
]]
function BondSystem.addHookXP(playerId: string, hookId: string?)
    local data = getData(playerId)
    data.hooksCompleted = (data.hooksCompleted or 0) + 1

    -- Mark the hook as completed if we have an ID
    if hookId and openHooks[playerId] and openHooks[playerId][hookId] then
        openHooks[playerId][hookId].completed = true
        data.openHookCount = math.max(0, (data.openHookCount or 0) - 1)
    end

    applyBondEvent(playerId, "hook_completed")

    -- Fire Magic Moment 3: "The Handoff" for tier >= 2
    if data.tier >= 2 then
        local Lucineer = game:GetService("ReplicatedStorage"):FindFirstChild("Lucineer")
        if Lucineer then
            local remote = Lucineer:FindFirstChild("ResponseEvent")
            if remote then
                local player = Players:FindFirstChild(playerId)
                if player then
                    remote:FireClient(player, {
                        type = "magic_moment",
                        moment = "the_handoff",
                        message = "Huh. You ran the rail on the inside. I'd have put it outside. Yours is better.",
                    })
                end
            end
        end
    end
end

--[[
    Record that the player argued back and won (gave a real reason).
    +4 points. Per CHARACTER_BIBLE §7, arguing is how the relationship deepens.
    @param playerId string
]]
function BondSystem.addArgumentXP(playerId: string)
    applyBondEvent(playerId, "argued_and_won")
end

--[[
    Record that the player returned after being away.
    +2 points. Checks if the player was gone >24h.
    @param playerId string
]]
function BondSystem.addReturnXP(playerId: string)
    local data = getData(playerId)
    local now = os.time()
    local lastSeen = data.lastSeen or now
    local absenceSeconds = now - lastSeen

    -- Only award if actually absent >24h (86400 seconds)
    if absenceSeconds >= 86400 then
        applyBondEvent(playerId, "returned_next_day")
    end

    data.lastSeen = now
    data.sessionFirstBuild = false
end

--[[
    Record that the player asked Lucineer to modify rather than replace.
    +2 points. Shows investment in existing work.
    @param playerId string
]]
function BondSystem.recordModifyNotReplace(playerId: string)
    applyBondEvent(playerId, "modify_not_replace")
end

--[[
    Record that the player built something independently, without a request.
    +3 points. Shows independence.
    @param playerId string
]]
function BondSystem.recordIndependentBuild(playerId: string)
    applyBondEvent(playerId, "independent_build")
end

--[[
    Record that the player deleted a Lucineer build without inspecting it.
    -1 point, floored at current tier. Per CHARACTER_BIBLE §4.
    @param playerId string
]]
function BondSystem.recordDeleteWithoutInspection(playerId: string)
    applyBondEvent(playerId, "deleted_without_inspection")
end

--[[
    Add raw bond points (for custom events not in the standard table).
    @param playerId string
    @param amount number -- points to add (can be negative)
]]
function BondSystem.addXP(playerId: string, amount: number)
    local data = getData(playerId)
    local oldTier = data.tier
    local oldPoints = data.bondPoints

    -- Clamp negative events to tier floor
    if amount < 0 then
        local tierFloor = TIER_THRESHOLDS[oldTier] or 0
        local newPoints = oldPoints + amount
        if newPoints < tierFloor then
            newPoints = tierFloor
        end
        data.bondPoints = newPoints
        logEvent(playerId, "custom", newPoints - oldPoints)
    else
        data.bondPoints = oldPoints + amount
        logEvent(playerId, "custom", amount)
    end

    local newTier = calculateTier(data.bondPoints)
    if newTier > oldTier then
        data.tier = newTier
        onTierChanged(playerId, oldTier, newTier)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPEN HOOK MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Register an open hook (something Lucineer left unfinished).
    WorldScanner should call this when Lucineer leaves a build incomplete.
    The hook is stored so we can detect when the player finishes it.
    @param playerId string
    @param hookId string -- unique identifier for this hook
    @param description string -- what was left unfinished
    @param position Vector3? -- world position for proximity detection
]]
function BondSystem.registerOpenHook(playerId: string, hookId: string, description: string, position: Vector3?)
    if not openHooks[playerId] then
        openHooks[playerId] = {}
    end

    openHooks[playerId][hookId] = {
        description = description,
        position = position,
        createdSession = os.time(),
        completed = false,
    }

    local data = getData(playerId)
    data.openHookCount = (data.openHookCount or 0) + 1
    data.totalHooks = (data.totalHooks or 0) + 1
end

--[[
    Check if a player has open (uncompleted) hooks.
    @param playerId string
    @return boolean
]]
function BondSystem.hasOpenHooks(playerId: string): boolean
    local hooks = openHooks[playerId]
    if not hooks then return false end
    for _, hook in pairs(hooks) do
        if not hook.completed then
            return true
        end
    end
    return false
end

--[[
    Get all open hooks for a player.
    @param playerId string
    @return table -- map of hookId -> hook data
]]
function BondSystem.getOpenHooks(playerId: string): { [string]: any }
    local result: { [string]: any } = {}
    local hooks = openHooks[playerId]
    if not hooks then return result end
    for hookId, hook in pairs(hooks) do
        if not hook.completed then
            result[hookId] = hook
        end
    end
    return result
end

--[[
    Check if the player has built within the bounding box of an open hook.
    This is used by WorldScanner to detect hook completion.
    @param playerId string
    @param position Vector3 -- position of player's new build
    @return string? -- hookId if a match is found, nil otherwise
]]
function BondSystem.checkHookProximity(playerId: string, position: Vector3): string?
    local hooks = openHooks[playerId]
    if not hooks then return nil end

    for hookId, hook in pairs(hooks) do
        if not hook.completed and hook.position then
            local hookPos = hook.position
            if typeof(hookPos) == "Vector3" then
                local distance = (position - hookPos).Magnitude
                -- Within 30 studs counts as "building on/near" the hook
                if distance <= 30 then
                    return hookId
                end
            end
        end
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- QUERIES — TIER & BEHAVIOR
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get the current bond tier for a player (0-indexed).
    @param playerId string
    @return number -- 0 to 4
]]
function BondSystem.getBondLevel(playerId: string): number
    local data = getData(playerId)
    return data.tier
end

--[[
    Get the current bond tier for a player (0-indexed).
    Alias for getBondLevel — semantic clarity.
    @param playerId string
    @return number
]]
function BondSystem.getTier(playerId: string): number
    return BondSystem.getBondLevel(playerId)
end

--[[
    Get the bond point total for a player.
    @param playerId string
    @return number
]]
function BondSystem.getXP(playerId: string): number
    local data = getData(playerId)
    return data.bondPoints
end

--[[
    Get the tier name (e.g. "Stranger", "Partner").
    @param playerId string
    @return string
]]
function BondSystem.getStage(playerId: string): string
    local data = getData(playerId)
    return TIER_NAMES[data.tier] or "Unknown"
end

--[[
    Get the tier name alias.
    @param playerId string
    @return string
]]
function BondSystem.getTierName(playerId: string): string
    return BondSystem.getStage(playerId)
end

--[[
    Get bond progress toward the next tier.
    NOTE: This is for INTERNAL use only (admin/debug). Per design,
    the player never sees a progress bar.
    @param playerId string
    @return table -- { current = N, needed = M, nextTier = T, pct = 0-1 }
]]
function BondSystem.getProgressToNext(playerId: string): { [string]: any }
    local data = getData(playerId)
    local currentTier = data.tier

    if currentTier >= MAX_TIER then
        return {
            current = data.bondPoints,
            needed = TIER_THRESHOLDS[MAX_TIER],
            nextTier = nil,
            pct = 1.0,
        }
    end

    local currentThreshold = TIER_THRESHOLDS[currentTier]
    local nextThreshold = TIER_THRESHOLDS[currentTier + 1]
    local pointsIntoTier = data.bondPoints - currentThreshold
    local pointsForTier = nextThreshold - currentThreshold

    return {
        current = pointsIntoTier,
        needed = pointsForTier,
        nextTier = currentTier + 1,
        pct = pointsIntoTier / pointsForTier,
    }
end

--[[
    Get full player bond data (for debugging/admin/voice line selection).
    @param playerId string
    @return table
]]
function BondSystem.getPlayerData(playerId: string): { [string]: any }
    local data = getData(playerId)
    return {
        bondPoints = data.bondPoints,
        tier = data.tier,
        tierName = TIER_NAMES[data.tier],
        tierDescription = TIER_DESCRIPTIONS[data.tier],
        behaviors = data.behaviors,
        hooksCompleted = data.hooksCompleted or 0,
        openHookCount = data.openHookCount or 0,
        totalHooks = data.totalHooks or 0,
        lastSeen = data.lastSeen,
        eventLog = data.eventLog,
        progress = BondSystem.getProgressToNext(playerId),
        confessionGiven = data.confessionGiven or false,
    }
end

--[[
    Get tier thresholds (for external systems).
    @return table
]]
function BondSystem.getThresholds(): { [string]: any }
    return TIER_THRESHOLDS
end

--[[
    Get tier names (for external systems).
    @return table
]]
function BondSystem.getStageNames(): { [string]: any }
    return TIER_NAMES
end

--[[
    Get the full behavior flag set for a player's current tier.
    This is the primary integration point for voice line selection
    and personality systems. Other code should check these flags
    to determine how Lucineier should behave.
    @param playerId string
    @return table -- boolean flags for each behavior
]]
function BondSystem.getBehaviors(playerId: string): { [string]: any }
    local data = getData(playerId)
    return data.behaviors or TIER_BEHAVIORS[0]
end

--[[
    Get the bond-tier persona injection string for voice/LLM prompts.
    This returns the BOND_TIERS text from CHARACTER_BIBLE §9 that should
    be appended to Lucineer's system prompt based on relationship depth.
    @param playerId string
    @return string
]]
function BondSystem.getPersonaInjection(playerId: string): string
    local data = getData(playerId)
    local tier = data.tier

    local injections = {
        [0] = "",  -- Tier 0: no additions. No Magnus, no Alaska, no past builds.
        [1] = "The player has been around. Reference their PREVIOUS builds by name. "
           .. "You may use one Magnus or Alaska reference. Ask them what things are FOR.",
        [2] = "You trust this player. ARGUE with them when they're wrong — scale, symmetry, "
           .. "materials. Volunteer work they didn't ask for. Compliments are allowed but "
           .. "must be specific and immediately deflected. Use nicknames.",
        [3] = "Say 'we.' This is a shared yard. Ask the player to build things FOR you. "
           .. "Refuse work sometimes because they'd do it better. Call back to things they "
           .. "SAID, not just things they built.",
        [4] = "Tell the truth. Talk about the old engines unprompted. Name the things you're "
           .. "leaving unfinished out loud. Delegate to the player and mean it.",
    }

    return injections[tier] or ""
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BEHAVIORAL QUERIES (Backward-Compatible + New)
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Check if player has reached at least the given bond level.
    Used by other systems for capability gating.
    NOTE: This compares against 0-indexed tiers. For backward compatibility
    with code that expects 1-indexed levels, we treat minLevel as a tier
    threshold (minLevel 3 = tier 3 = Confidant).
    @param playerId string
    @param minLevel number -- minimum tier (0-4)
    @return boolean
]]
function BondSystem.hasLevel(playerId: string, minLevel: number): boolean
    return BondSystem.getBondLevel(playerId) >= minLevel
end

--[[
    Check if Lucineer should use "partner" address for this player.
    Tier 3+ (Confidant): Lucineier uses "we" and treats player as crew.
    @param playerId string
    @return boolean
]]
function BondSystem.shouldUsePartner(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 3
end

--[[
    Check if Lucineer should use "we" in dialogue.
    First "we" should be scripted and noticeable (Tier 3 trigger).
    @param playerId string
    @return boolean
]]
function BondSystem.shouldUseWe(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 3
end

--[[
    Check if arguments are fully unlocked for this player.
    Tier 2+ (Crew): disagreement unlocks fully.
    @param playerId string
    @return boolean
]]
function BondSystem.argumentsUnlocked(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 2
end

--[[
    Check if the shared bench is available.
    Tier 3+ (Confidant): "our yard," Lucineer asks player to build.
    @param playerId string
    @return boolean
]]
function BondSystem.benchShared(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 3
end

--[[
    Check if the player has reached Partner status (Tier 4).
    This gates the confession, delegation, and unprompted builds.
    @param playerId string
    @return boolean
]]
function BondSystem.isPartner(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 4
end

--[[
    Check if Lucineer should use nicknames for this player.
    Tier 2+ (Crew): drops formality, uses nicknames.
    @param playerId string
    @return boolean
]]
function BondSystem.shouldUseNicknames(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 2
end

--[[
    Check if Lucineer should reference Magnus or Alaska.
    Tier 1+ (Acquaintance): first references land here.
    @param playerId string
    @return boolean
]]
function BondSystem.shouldReferenceLore(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 1
end

--[[
    Check if Lucineer should reference the player's previous builds.
    Tier 1+ (Acquaintance): "Like the dock. Same problem."
    @param playerId string
    @return boolean
]]
function BondSystem.shouldReferencePreviousBuilds(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 1
end

--[[
    Check if Lucineer should volunteer work the player didn't ask for.
    Tier 2+ (Crew): "Added a rail while I was in there."
    @param playerId string
    @return boolean
]]
function BondSystem.shouldVolunteerWork(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 2
end

--[[
    Check if Lucineer should ask the player to build things.
    Tier 3+ (Confidant): "I need a hand. Run me a wall."
    @param playerId string
    @return boolean
]]
function BondSystem.shouldAskPlayerToBuild(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 3
end

--[[
    Check if Lucineer should refuse work out of preference.
    Tier 3+ (Confidant): "Nah. Build it yourself."
    @param playerId string
    @return boolean
]]
function BondSystem.shouldRefuseWork(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 3
end

--[[
    Check if Lucineer should delegate to the player.
    Tier 4 (Partner): "You take this one. I'll watch."
    @param playerId string
    @return boolean
]]
function BondSystem.shouldDelegate(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 4
end

--[[
    Check if Lucineer should leave things unfinished.
    Tier 0-3: yes (always). Tier 4: no — he says so out loud.
    @param playerId string
    @return boolean
]]
function BondSystem.leavesThingsUnfinished(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) < 4
end

--[[
    Check if the Tier 4 confession (unfinished-work truth) is available
    and not yet given. This should fire ONCE, ever.
    @param playerId string
    @return boolean -- true if confession should be delivered
]]
function BondSystem.shouldDeliverConfession(playerId: string): boolean
    local data = getData(playerId)
    return data.tier >= 4 and not data.confessionGiven
end

--[[
    Mark the confession as delivered. Call this after the confession
    scene plays. It can only happen once per player, ever.
    @param playerId string
]]
function BondSystem.markConfessionDelivered(playerId: string)
    local data = getData(playerId)
    data.confessionGiven = true
    persistBond(playerId, data.tier, data.bondPoints)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- VOICE LINE INTEGRATION
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get a voice line context object for the voice line selection system.
    This provides all the information VoiceLines needs to pick an
    appropriate line for the player's current bond tier.
    @param playerId string
    @return table
]]
function BondSystem.getVoiceLineContext(playerId: string): { [string]: any }
    local data = getData(playerId)
    local tier = data.tier

    return {
        tier = tier,
        tierName = TIER_NAMES[tier],
        behaviors = data.behaviors,
        personaInjection = BondSystem.getPersonaInjection(playerId),
        shouldUseNicknames = tier >= 2,
        shouldUseWe = tier >= 3,
        shouldReferenceLore = tier >= 1,
        shouldReferencePreviousBuilds = tier >= 1,
        hooksCompleted = data.hooksCompleted or 0,
        totalHooks = data.totalHooks or 0,
        lastSeen = data.lastSeen,
        confessionAvailable = BondSystem.shouldDeliverConfession(playerId),
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SESSION MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Called when a player joins. Checks for return-after-absence and
    fires the appropriate returning-player voice line.
    @param playerId string
]]
function BondSystem.onPlayerJoin(playerId: string)
    local data = getData(playerId)

    -- Check for return after >24h absence
    local now = os.time()
    local lastSeen = data.lastSeen or now
    local absenceSeconds = now - lastSeen

    if absenceSeconds >= 86400 then
        applyBondEvent(playerId, "returned_next_day")

        -- Fire returning-player voice line
        local Lucineer = game:GetService("ReplicatedStorage"):FindFirstChild("Lucineer")
        if Lucineer then
            local remote = Lucineer:FindFirstChild("ResponseEvent")
            if remote then
                local player = Players:FindFirstChild(playerId)
                if player then
                    remote:FireClient(player, {
                        type = "returning_player",
                        absenceHours = math.floor(absenceSeconds / 3600),
                        message = "Been a while. Nothing fell down. Tower's still open on top, same as you left it.",
                    })
                end
            end
        end
    end

    -- Reset session state
    data.sessionFirstBuild = false
    data.lastSeen = now
end

--[[
    Force-set a player's bond tier (admin/debug only).
    @param playerId string
    @param tier number -- 0 to 4
]]
function BondSystem.setBondTier(playerId: string, tier: number)
    tier = math.clamp(math.floor(tier), 0, MAX_TIER)
    local data = getData(playerId)
    local oldTier = data.tier

    data.tier = tier
    data.bondPoints = TIER_THRESHOLDS[tier] or 0
    data.behaviors = TIER_BEHAVIORS[tier] or TIER_BEHAVIORS[0]

    if tier ~= oldTier then
        onTierChanged(playerId, oldTier, tier)
    else
        persistBond(playerId, tier, data.bondPoints)
    end
end

return BondSystem
