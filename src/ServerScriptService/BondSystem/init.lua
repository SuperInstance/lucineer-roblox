--!strict
--[[
    BondSystem — Lucineer's Bond Progression
    =========================================
    Tracks the player-Lucineer relationship through 5 bond stages
    as defined in FABLE_CHARACTER_BIBLE.md §3.

    The bond is the ONLY progression meter that matters. Per POLISH_PLAN §5.1,
    it is never shown as a number to the player. Progression is expressed
    entirely through Lucineer's behavior changes.

    XP Sources:
        - Each build:     +1 XP
        - Each conversation: +1 XP
        - Each quest:     +5 XP

    Level Thresholds:
        Level 1 (The Client):     0 XP
        Level 2 (The Hands):     50 XP
        Level 3 (The Argument):  150 XP
        Level 4 (The Bench-Mate):400 XP
        Level 5 (The Partner):  1000 XP

    Each level-up triggers:
        1. A Lucineer voice line (stage-appropriate)
        2. Behavior change signal (for other systems to react to)
        3. AchievementManager hook
        4. Persistence to D1 player_profiles.bond_level

    Usage:
        local BondSystem = require(ServerScriptService.BondSystem)
        BondSystem.init()

        BondSystem.addBuildXP(playerId)
        BondSystem.addConversationXP(playerId)
        BondSystem.addQuestXP(playerId)
        BondSystem.getBondLevel(playerId)  -- 1-5
        BondSystem.getXP(playerId)         -- raw number
        BondSystem.getStage(playerId)      -- stage name string

    Dependencies:
        - ReplicatedStorage.Lucineer.Http
        - ReplicatedStorage.Lucineer.VoiceLines
        - ServerScriptService.AchievementManager
]]

local Http = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("Http"))
local VoiceLines = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("VoiceLines"))

local Players = game:GetService("Players")

-- Memory worker URL for bond level persistence
local MEMORY_URL = "https://lucineer-memory.casey-digennaro.workers.dev"

-- ═══════════════════════════════════════════════════════════════════════════
-- BOND LEVEL CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Level thresholds: cumulative XP required to reach each level.
-- Level 1 starts at 0. These are intentionally steep — the bond is earned.
local LEVEL_THRESHOLDS = {
    [1] = 0,     -- The Client:      "You're late."
    [2] = 50,    -- The Hands:       "Grab that end."
    [3] = 150,   -- The Argument:    "No. Tell me why I'm wrong."
    [4] = 400,   -- The Bench-Mate:  "Bench is long enough for two."
    [5] = 1000,  -- The Partner:     "It was always yours."
}

-- Maximum bond level
local MAX_LEVEL = 5

-- Stage names from the Character Bible
local STAGE_NAMES = {
    [1] = "The Client",
    [2] = "The Hands",
    [3] = "The Argument",
    [4] = "The Bench-Mate",
    [5] = "The Partner",
}

-- Stage descriptions (for internal reference, not shown to player)
local STAGE_DESCRIPTIONS = {
    [1] = "Cold. Transactional. He builds what's asked, competently, without flourish. Testing whether you're a shopper.",
    [2] = "He starts handing you things. You're labor now, which is a promotion. Assigns real sub-tasks mid-build.",
    [3] = "He argues with you — his love language. First use of 'we'. Begins telling logbook stories voluntarily.",
    [4] = "Shared workspace. He clears half his bench. Asks your opinion first. Leaves builds unfinished for you.",
    [5] = "Co-signs builds. The forge stays lit when you're offline. You get the Named Hammer.",
}

-- XP rewards per event type
local XP_REWARDS = {
    build = 1,
    conversation = 1,
    quest = 5,
    hook_completed = 3,    -- player finished one of Lucineer's deliberate gaps
    argued_well = 2,       -- player gave a real reason during an argument
    returned = 2,          -- player returned after being away
}

-- ═══════════════════════════════════════════════════════════════════════════
-- LEVEL-UP VOICE LINES
-- ═══════════════════════════════════════════════════════════════════════════
-- These fire ONCE per level-up. They're the moment the player notices
-- the relationship has changed. No UI notification — just Lucineer
-- acting different.

local LEVEL_UP_LINES = {
    [2] = {
        -- Stage 2: The Hands — first time he includes you in the work
        "Grab that end. Deck's yours — I'll take the frame.",
        "You're not a customer anymore. That's not a compliment, it's a job assignment.",
        "Hands. You've got a pair. Use them — I need someone on the other end of this plank.",
    },
    [3] = {
        -- Stage 3: The Argument — first time he says "we"
        "We'll need more tin.",
        "No. Tell me why I'm wrong. If you can't, I'm building it my way.",
        "You've got opinions. Good. I've been waiting for someone to argue with.",
    },
    [4] = {
        -- Stage 4: The Bench-Mate — shared workspace
        "Bench is long enough for two. Your tools are on the left.",
        "Two roads for the roofline. You call it.",
        "I cleared a space. Don't make a thing of it.",
    },
    [5] = {
        -- Stage 5: The Partner — the deepest commitment
        "It was always yours. I was just holding it.",
        "The forge stays lit when you're gone. That's not sentiment — that's practice.",
        "L and you. That plate goes on everything we build from here.",
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

local BondSystem = {}

-- Per-player state: [playerName] = {
--   xp = number,
--   level = number (1-5),
--   builds = number,
--   conversations = number,
--   quests = number,
-- }
local playerData = {}

--[[
    Get or create player bond data.
]]
local function getData(playerName)
    if not playerData[playerName] then
        playerData[playerName] = {
            xp = 0,
            level = 1,
            builds = 0,
            conversations = 0,
            quests = 0,
        }
    end
    return playerData[playerName]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- D1 PERSISTENCE
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Persist bond level to D1 player_profiles via the memory worker.
    Fire-and-forget.
]]
local function persistBondLevel(playerName, bondLevel)
    task.spawn(function()
        local HttpService = game:GetService("HttpService")
        local url = MEMORY_URL .. "/api/memory/player"
        local body = HttpService:JSONEncode({
            player_name = playerName,
            bond_level = bondLevel,
        })

        local ok, response = pcall(function()
            return HttpService:RequestAsync({
                Url = url,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body,
            })
        end)

        if not ok or not response.Success then
            warn(string.format("[BondSystem] Failed to persist bond level %d for %s: %s",
                bondLevel, playerName, tostring(response)))
        end
    end)
end

--[[
    Load bond level from D1 player_profiles on player join.
]]
local function loadBondLevel(playerName)
    task.spawn(function()
        local HttpService = game:GetService("HttpService")
        local url = MEMORY_URL .. "/api/memory/player/" .. playerName

        local ok, response = pcall(function()
            return HttpService:RequestAsync({
                Url = url,
                Method = "GET",
                Headers = { ["Content-Type"] = "application/json" },
            })
        end)

        if ok and response.Success and #response.Body > 0 then
            local dataOk, data = pcall(function()
                return HttpService:JSONDecode(response.Body)
            end)
            if dataOk and not data.error then
                local data_state = getData(playerName)
                local storedLevel = tonumber(data.bond_level) or 0

                -- If stored level is higher than what we have, adopt it.
                -- If it's 0 (the known D1 upsert bug from GAP_ANALYSIS #4),
                -- we keep our in-memory level since it's more accurate.
                if storedLevel > data_state.level then
                    data_state.level = storedLevel
                    -- Estimate XP from the level threshold
                    data_state.xp = LEVEL_THRESHOLDS[storedLevel] or 0
                    print(string.format("[BondSystem] %s loaded at bond level %d from D1",
                        playerName, storedLevel))
                end
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- LEVEL CALCULATION
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Calculate the bond level for a given XP total.
    Returns the highest level whose threshold the XP meets.
]]
local function calculateLevel(xp)
    local level = 1
    for checkLevel = MAX_LEVEL, 1, -1 do
        if xp >= LEVEL_THRESHOLDS[checkLevel] then
            level = checkLevel
            break
        end
    end
    return level
end

--[[
    Handle a level-up event.
    Fires voice line, notifies other systems.
]]
local function onLevelUp(playerName, oldLevel, newLevel)
    print(string.format("[BondSystem] %s bond level: %d → %d (%s)",
        playerName, oldLevel, newLevel, STAGE_NAMES[newLevel] or "?"))

    -- Pick a random voice line for the new level
    local lines = LEVEL_UP_LINES[newLevel]
    if lines and #lines > 0 then
        local line = lines[math.random(1, #lines)]

        -- Deliver via the ResponseEvent remote
        local Lucineer = game:GetService("ReplicatedStorage"):FindFirstChild("Lucineer")
        if Lucineer then
            local remote = Lucineer:FindFirstChild("ResponseEvent")
            if remote then
                local player = Players:FindFirstChild(playerName)
                if player then
                    -- This is a significant moment. Add a beat.
                    -- The client should display this with weight.
                    remote:FireClient(player, {
                        type = "bond_level_up",
                        oldLevel = oldLevel,
                        newLevel = newLevel,
                        stageName = STAGE_NAMES[newLevel],
                        message = line,
                    })
                end
            end
        end

        print(string.format("[BondSystem] Level-up line: \"%s\"", line))
    end

    -- Persist the new level to D1
    persistBondLevel(playerName, newLevel)

    -- Notify AchievementManager
    local AchievementManager = require(script.Parent:FindFirstChild("AchievementManager"))
    if AchievementManager then
        AchievementManager.onBondLevelChange(playerName, newLevel)
    end

    -- ── BEHAVIOR UNLOCKS ──────────────────────────────────
    -- Per POLISH_PLAN §5.3, each tier unlocks capabilities framed
    -- as Lucineer's willingness, not a locked feature.
    -- Other systems can check getBondLevel() to gate behavior.
    local BEHAVIOR_NOTES = {
        [2] = "Multi-structure requests enabled. Style modifiers unlocked.",
        [3] = "Arguments fully unlocked. Lucineer says 'we'. Logbook stories begin.",
        [4] = "Named saved patterns. Lucineer requests work from player. Shared bench.",
        [5] = "Full canvas. Co-signed builds. Named Hammer. Lucineer builds unprompted.",
    }
    if BEHAVIOR_NOTES[newLevel] then
        print(string.format("[BondSystem] %s unlocks: %s", playerName, BEHAVIOR_NOTES[newLevel]))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Initialize the BondSystem.
    Hooks into player join/leave.
]]
function BondSystem.init()
    VoiceLines.init()

    Players.PlayerAdded:Connect(function(player)
        loadBondLevel(player.Name)
    end)

    Players.PlayerRemoving:Connect(function(player)
        -- Persist final state before cleanup
        local data_state = getData(player.Name)
        persistBondLevel(player.Name, data_state.level)
        playerData[player.Name] = nil
    end)

    -- Validate level thresholds are sorted
    for i = 2, MAX_LEVEL do
        assert(LEVEL_THRESHOLDS[i] > LEVEL_THRESHOLDS[i - 1],
            string.format("[BondSystem] Level thresholds not monotonically increasing at %d", i))
    end

    print("[BondSystem] Initialized — 5 bond stages, thresholds: " ..
        table.concat({
            "1:0", "2:50", "3:150", "4:400", "5:1000"
        }, ", "))
end

--[[
    Add XP for a build event.
    @param playerId string -- player username
]]
function BondSystem.addBuildXP(playerId: string)
    local data = getData(playerId)
    data.xp = data.xp + XP_REWARDS.build
    data.builds = data.builds + 1

    local newLevel = calculateLevel(data.xp)
    if newLevel > data.level then
        local oldLevel = data.level
        data.level = newLevel
        onLevelUp(playerId, oldLevel, newLevel)
    end
end

--[[
    Add XP for a conversation event.
    @param playerId string -- player username
]]
function BondSystem.addConversationXP(playerId: string)
    local data = getData(playerId)
    data.xp = data.xp + XP_REWARDS.conversation
    data.conversations = data.conversations + 1

    local newLevel = calculateLevel(data.xp)
    if newLevel > data.level then
        local oldLevel = data.level
        data.level = newLevel
        onLevelUp(playerId, oldLevel, newLevel)
    end
end

--[[
    Add XP for a quest completion.
    @param playerId string -- player username
]]
function BondSystem.addQuestXP(playerId: string)
    local data = getData(playerId)
    data.xp = data.xp + XP_REWARDS.quest
    data.quests = data.quests + 1

    local newLevel = calculateLevel(data.xp)
    if newLevel > data.level then
        local oldLevel = data.level
        data.level = newLevel
        onLevelUp(playerId, oldLevel, newLevel)
    end
end

--[[
    Add XP for a hook completion (player finished one of Lucineer's gaps).
    This is the Stage 3→4 trigger from the Character Bible.
    @param playerId string
]]
function BondSystem.addHookXP(playerId: string)
    local data = getData(playerId)
    data.xp = data.xp + XP_REWARDS.hook_completed

    local newLevel = calculateLevel(data.xp)
    if newLevel > data.level then
        local oldLevel = data.level
        data.level = newLevel
        onLevelUp(playerId, oldLevel, newLevel)
    end
end

--[[
    Add XP for arguing well (player gave a real reason during a disagreement).
    @param playerId string
]]
function BondSystem.addArgumentXP(playerId: string)
    local data = getData(playerId)
    data.xp = data.xp + XP_REWARDS.argued_well

    local newLevel = calculateLevel(data.xp)
    if newLevel > data.level then
        local oldLevel = data.level
        data.level = newLevel
        onLevelUp(playerId, oldLevel, newLevel)
    end
end

--[[
    Add XP for returning after being away.
    @param playerId string
]]
function BondSystem.addReturnXP(playerId: string)
    local data = getData(playerId)
    data.xp = data.xp + XP_REWARDS.returned

    local newLevel = calculateLevel(data.xp)
    if newLevel > data.level then
        local oldLevel = data.level
        data.level = newLevel
        onLevelUp(playerId, oldLevel, newLevel)
    end
end

--[[
    Add raw XP (for custom events).
    @param playerId string
    @param amount number -- XP to add
]]
function BondSystem.addXP(playerId: string, amount: number)
    local data = getData(playerId)
    data.xp = data.xp + amount

    local newLevel = calculateLevel(data.xp)
    if newLevel > data.level then
        local oldLevel = data.level
        data.level = newLevel
        onLevelUp(playerId, oldLevel, newLevel)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- QUERIES
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get the current bond level for a player.
    @param playerId string
    @return number -- 1 to 5
]]
function BondSystem.getBondLevel(playerId: string): number
    local data = getData(playerId)
    return data.level
end

--[[
    Get the raw XP total for a player.
    @param playerId string
    @return number
]]
function BondSystem.getXP(playerId: string): number
    local data = getData(playerId)
    return data.xp
end

--[[
    Get the stage name (e.g. "The Client", "The Partner").
    @param playerId string
    @return string
]]
function BondSystem.getStage(playerId: string): string
    local data = getData(playerId)
    return STAGE_NAMES[data.level] or "Unknown"
end

--[[
    Get XP progress toward the next level.
    @param playerId string
    @return table -- { current = N, needed = M, nextLevel = L, pct = 0-1 }
]]
function BondSystem.getProgressToNext(playerId: string): { [string]: any }
    local data = getData(playerId)
    local currentLevel = data.level

    if currentLevel >= MAX_LEVEL then
        return {
            current = data.xp,
            needed = LEVEL_THRESHOLDS[MAX_LEVEL],
            nextLevel = nil,
            pct = 1.0,
        }
    end

    local currentThreshold = LEVEL_THRESHOLDS[currentLevel]
    local nextThreshold = LEVEL_THRESHOLDS[currentLevel + 1]
    local xpIntoLevel = data.xp - currentThreshold
    local xpForLevel = nextThreshold - currentThreshold

    return {
        current = xpIntoLevel,
        needed = xpForLevel,
        nextLevel = currentLevel + 1,
        pct = xpIntoLevel / xpForLevel,
    }
end

--[[
    Get full player bond data (for debugging/admin).
    @param playerId string
    @return table
]]
function BondSystem.getPlayerData(playerId: string): { [string]: any }
    local data = getData(playerId)
    return {
        xp = data.xp,
        level = data.level,
        stageName = STAGE_NAMES[data.level],
        stageDescription = STAGE_DESCRIPTIONS[data.level],
        builds = data.builds,
        conversations = data.conversations,
        quests = data.quests,
        progress = BondSystem.getProgressToNext(playerId),
    }
end

--[[
    Get level thresholds (for external systems that need them).
    @return table
]]
function BondSystem.getThresholds(): { [string]: any }
    return LEVEL_THRESHOLDS
end

--[[
    Get stage names (for external systems).
    @return table
]]
function BondSystem.getStageNames(): { [string]: any }
    return STAGE_NAMES
end

--[[
    Check if player has reached at least the given bond level.
    Used by other systems for capability gating.
    @param playerId string
    @param minLevel number
    @return boolean
]]
function BondSystem.hasLevel(playerId: string, minLevel: number): boolean
    return BondSystem.getBondLevel(playerId) >= minLevel
end

--[[
    Check if Lucineer should use "partner" address for this player.
    (Stage 3+ per Character Bible: "partner" feels like a medal.)
    @param playerId string
    @return boolean
]]
function BondSystem.shouldUsePartner(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 3
end

--[[
    Check if Lucineer should use "we" in dialogue.
    First "we" should be scripted and noticeable (Stage 3 trigger).
    @param playerId string
    @return boolean
]]
function BondSystem.shouldUseWe(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 3
end

--[[
    Check if arguments are fully unlocked for this player.
    @param playerId string
    @return boolean
]]
function BondSystem.argumentsUnlocked(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 3
end

--[[
    Check if the shared bench is available.
    @param playerId string
    @return boolean
]]
function BondSystem.benchShared(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 4
end

--[[
    Check if the player has reached Partner status (Stage 5).
    This gates the Named Hammer, co-signed builds, etc.
    @param playerId string
    @return boolean
]]
function BondSystem.isPartner(playerId: string): boolean
    return BondSystem.getBondLevel(playerId) >= 5
end

return BondSystem
