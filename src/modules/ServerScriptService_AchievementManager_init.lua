--!strict
--[[
    AchievementManager — Lucineer's Achievement System
    ==================================================
    49 achievements across 5 tiers, matching Magnus's Scrapcraft count.

    Design philosophy (POLISH_PLAN §5.1): Lucineer's progression is a
    relationship, not a checklist. Achievements are HIDDEN — never shown as
    a grid with "(3/10)" progress bars. Players discover them only by
    triggering them, and each unlock is delivered as a Lucineer voice line,
    not a generic toast notification.

    The system tracks state locally in-memory and persists unlocks to the
    D1 achievements table via the memory worker HTTP API.

    Usage:
        local AchievementManager = require(ServerScriptService.AchievementManager)
        AchievementManager.init()

        AchievementManager.checkBuild(playerId, "tower", 15, false)
        AchievementManager.unlock(playerId, "first_build")
        local unlocked = AchievementManager.getUnlocked(playerId)
        local progress = AchievementManager.getProgress(playerId)

    Dependencies:
        - ReplicatedStorage.Lucineer.Http (for D1 persistence)
        - ReplicatedStorage.Lucineer.VoiceLines (for unlock flavor)
        - ServerScriptService.BondSystem (for bond-level checks)
]]

local Http = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("Http"))
local VoiceLines = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("VoiceLines"))

local Players = game:GetService("Players")

-- Memory worker URL for achievement persistence
local MEMORY_URL = "https://lucineer-memory.casey-digennaro.workers.dev"

-- ═══════════════════════════════════════════════════════════════════════════
-- ACHIEVEMENT DEFINITIONS (49 total)
-- ═══════════════════════════════════════════════════════════════════════════

local ACHIEVEMENTS = {}

-- Helper to register an achievement
local function def(id, name, tier, desc, voiceLine)
    ACHIEVEMENTS[id] = {
        id = id,
        name = name,
        tier = tier,
        description = desc,
        voiceLine = voiceLine or desc,
    }
end

-- ── TIER 1: FIRST STEPS (10) ──────────────────────────────────────────────
def("first_build",        "First Build",       1, "Built your first structure.")
def("first_tower",        "First Tower",       1, "Raised your first tower.")
def("first_house",        "First House",       1, "Raised your first house.")
def("first_castle",       "First Castle",      1, "Raised your first castle.")
def("first_bridge",       "First Bridge",      1, "Raised your first bridge.")
def("first_garden",       "First Garden",      1, "Raised your first garden.")
def("first_dock",         "First Dock",        1, "Raised your first dock.")
def("first_lighthouse",   "First Lighthouse",  1, "Raised your first lighthouse.")
def("first_wall",         "First Wall",        1, "Raised your first wall.")
def("first_road",         "First Road",        1, "Raised your first road.")

-- ── TIER 2: BUILDER (10) ──────────────────────────────────────────────────
def("built_10",           "Getting the Hang of It", 2, "Built 10 structures.")
def("built_25",           "Steady Hand",         2, "Built 25 structures.")
def("built_50",           "Fifty Strong",        2, "Built 50 structures.")
def("built_100",          "Centurion",           2, "Built 100 structures.")
def("used_5_materials",   "Material Girl",       2, "Used 5 different materials.")
def("used_all_materials", "Jack of All Trades",  2, "Used all available materials.")
def("built_at_night",     "Night Shift",         2, "Built something after dark.")
def("built_in_storm",     "Storm Chaser",        2, "Built during a storm.")
def("first_deep_build",   "Beyond the Template", 2, "First build using the deep brain pipeline.")
def("persisted_against",  "Stubborn",            2, "Built something Lucineer argued against.")

-- ── TIER 3: CRAFTSMAN (10) ────────────────────────────────────────────────
def("mastered_type",      "Mastered",            3, "Built the same type 5 times.")
def("big_build_20",       "Twenty Commands Deep",3, "Built something with 20+ commands.")
def("creative_pipeline",  "Creative Eye",        3, "Built something with the creative pipeline.")
def("talked_all_npcs",    "Social Butterfly",    3, "Talked to all 5 NPCs.")
def("earl_quests_5",      "Earl's Errands",      3, "Completed 5 quests for Earl.")
def("visited_7_days",     "Regular",             3, "Visited Slackwater 7 days in a row.")
def("built_in_aurora",    "Aurora Builder",      3, "Built during an aurora event.")
def("first_coop_build",   "Partnered",           3, "First cooperative build with another player.")
def("reached_bond_3",     "Trusted Hand",        3, "Reached Bond Level 3.")
def("built_100_total",    "A Hundred Builds",    3, "100 total builds.")

-- ── TIER 4: MASTER (10) ───────────────────────────────────────────────────
def("reached_bond_5",     "Named Partner",       4, "Reached Bond Level 5 (Partner).")
def("impressed_lucineer", "Earned It",           4, "Built something Lucineer called good.")
def("built_500",          "Five Hundred",        4, "Built 500 structures.")
def("all_weather",        "All Weather",         4, "Built in all weather types.")
def("hidden_skill",       "Skill Hunter",        4, "Discovered a hidden skill (Vectorize > 0.8).")
def("all_earl_quests",    "Earl's Best Friend",  4, "Completed all of Earl's quests.")
def("streak_30",          "Thirty Day Tide",     4, "30-day visiting streak.")
def("hardest_template",   "Castle Architect",    4, "Built the hardest template (castle).")
def("refused_5_times",    "Thick Skinned",       4, "Made Lucineer refuse 5 times and kept playing.")
def("first_viral_share",  "Word of Mouth",       4, "First viral share.")

-- ── TIER 5: LEGEND (9) ────────────────────────────────────────────────────
def("built_1000",         "Thousand Builder",    5, "Built 1000 structures.")
def("max_bond",           "Bonded",              5, "Reached the maximum bond level.")
def("storm_and_aurora",   "Stormlight",          5, "Built during a storm AND aurora simultaneously.")
def("tier_complete",      "Completionist",       5, "All achievements in a tier unlocked.")
def("named_hammer",       "Named Hammer",        5, "Earned the Named Hammer at Bond Level 5.")
def("logbook_secret",     "The Logbook",         5, "Discovered the Logbook secret.")
def("referenced_later",   "Echoes",              5, "First build Lucineer references in later sessions.")
def("all_npc_quests",     "Friend to All",       5, "All NPC quests completed.")
def("the_ark",            "The Ark",             5, "Built one of everything.")

-- ═══════════════════════════════════════════════════════════════════════════
-- TIER LOOKUP
-- ═══════════════════════════════════════════════════════════════════════════

local TIER_NAMES = {
    [1] = "First Steps",
    [2] = "Builder",
    [3] = "Craftsman",
    [4] = "Master",
    [5] = "Legend",
}

-- Count achievements per tier (for tier completion checks)
local TIER_COUNTS = {}
for _, ach in pairs(ACHIEVEMENTS) do
    TIER_COUNTS[ach.tier] = (TIER_COUNTS[ach.tier] or 0) + 1
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BUILD TYPE → ACHIEVEMENT MAPPING
-- ═══════════════════════════════════════════════════════════════════════════

local BUILD_TYPE_TO_ACHIEVEMENT = {
    ["tower"]      = "first_tower",
    ["house"]      = "first_house",
    ["cabin"]      = "first_house",
    ["cottage"]    = "first_house",
    ["castle"]     = "first_castle",
    ["fortress"]   = "first_castle",
    ["bridge"]     = "first_bridge",
    ["garden"]     = "first_garden",
    ["park"]       = "first_garden",
    ["dock"]       = "first_dock",
    ["pier"]       = "first_dock",
    ["lighthouse"] = "first_lighthouse",
    ["wall"]       = "first_wall",
    ["road"]       = "first_road",
    ["path"]       = "first_road",
}

-- All recognized build types for "The Ark" check
local ALL_BUILD_TYPES = {
    "tower", "house", "castle", "bridge", "garden",
    "dock", "lighthouse", "wall", "road",
}

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

local AchievementManager = {}

-- Per-player state: [playerName] = {
--   unlocked = { [achievementId] = true },
--   buildCounts = { total = N, [type] = N },
--   materialsUsed = { [materialName] = true },
--   buildTypesUsed = { [type] = true },
--   npcsTalkedTo = { [npcName] = true },
--   earlQuestsCompleted = N,
--   visitDates = { [dateStr] = true },
--   refusalCount = N,
--   weatherBuiltIn = { [weatherType] = true },
--   deepBuilds = N,
--   coopBuilds = N,
--   impressedCount = N,
--   viralShares = N,
--   hasCreativePipeline = bool,
--   hasNightBuild = bool,
--   hasStormBuild = bool,
--   hasAuroraBuild = bool,
-- }
local playerState = {}

--[[
    Get or create player state.
]]
local function getState(playerName)
    if not playerState[playerName] then
        playerState[playerName] = {
            unlocked = {},
            buildCounts = { total = 0 },
            materialsUsed = {},
            buildTypesUsed = {},
            npcsTalkedTo = {},
            earlQuestsCompleted = 0,
            visitDates = {},
            refusalCount = 0,
            weatherBuiltIn = {},
            deepBuilds = 0,
            coopBuilds = 0,
            impressedCount = 0,
            viralShares = 0,
            hasCreativePipeline = false,
            hasNightBuild = false,
            hasStormBuild = false,
            hasAuroraBuild = false,
        }
    end
    return playerState[playerName]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HTTP PERSISTENCE
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Persist an achievement unlock to D1 via the memory worker.
    Fire-and-forget — failure logs but doesn't block gameplay.
]]
local function persistAchievement(playerName, achievementId)
    task.spawn(function()
        local url = MEMORY_URL .. "/api/achievements/unlock"
        local body = Http.encode({
            player_name = playerName,
            achievement_id = achievementId,
            unlocked_at = os.time(),
        })

        -- Use Http.request directly since the memory worker has a different base URL
        local HttpService = game:GetService("HttpService")
        local ok, response = pcall(function()
            return HttpService:RequestAsync({
                Url = url,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body,
            })
        end)

        if not ok or not response.Success then
            warn(string.format("[AchievementManager] Failed to persist %s for %s: %s",
                achievementId, playerName, tostring(response)))
        end
    end)
end

--[[
    Load persisted achievements from D1 on player join.
]]
local function loadPersistedAchievements(playerName)
    task.spawn(function()
        local url = MEMORY_URL .. "/api/achievements/" .. playerName
        local HttpService = game:GetService("HttpService")
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
            if dataOk and data.achievements then
                local state = getState(playerName)
                for _, ach in ipairs(data.achievements) do
                    state.unlocked[ach.achievement_id] = true
                end
                print(string.format("[AchievementManager] Loaded %d persisted achievements for %s",
                    #data.achievements, playerName))
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UNLOCK LOGIC
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Internal unlock. Returns true if newly unlocked, false if already had it.
    Delivers the voice line as a chat message to the player.
]]
local function tryUnlock(playerName, achievementId)
    local ach = ACHIEVEMENTS[achievementId]
    if not ach then
        warn(string.format("[AchievementManager] Unknown achievement: %s", achievementId))
        return false
    end

    local state = getState(playerName)
    if state.unlocked[achievementId] then
        return false
    end

    -- Unlock it
    state.unlocked[achievementId] = true

    -- Persist to D1
    persistAchievement(playerName, achievementId)

    -- Deliver the voice line in Lucineer's voice, not as a generic toast.
    -- Per POLISH_PLAN §5.2: achievements are delivered as lines from Lucineer.
    local line = ach.voiceLine or ach.description
    print(string.format("[AchievementManager] %s unlocked: %s — %s",
        playerName, ach.name, line))

    -- Fire a remote event so the client can display it in Lucineer's voice
    local Lucineer = game:GetService("ReplicatedStorage"):FindFirstChild("Lucineer")
    if Lucineer then
        local remote = Lucineer:FindFirstChild("ResponseEvent")
        if remote then
            local player = Players:FindFirstChild(playerName)
            if player then
                remote:FireClient(player, {
                    type = "achievement",
                    achievementId = achievementId,
                    achievementName = ach.name,
                    tier = ach.tier,
                    message = line,
                })
            end
        end
    end

    -- Check for tier-completion achievement (meta-achievement)
    if achievementId ~= "tier_complete" then
        AchievementManager.checkTierCompletion(playerName)
    end

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Initialize the AchievementManager.
    Hooks into player join/leave for state loading and cleanup.
]]
function AchievementManager.init()
    VoiceLines.init()

    -- Load persisted achievements when a player joins
    Players.PlayerAdded:Connect(function(player)
        loadPersistedAchievements(player.Name)
    end)

    -- Clean up state when a player leaves
    Players.PlayerRemoving:Connect(function(player)
        -- State persists in D1; just clear the in-memory cache
        playerState[player.Name] = nil
    end)

    print("[AchievementManager] Initialized — 49 achievements across 5 tiers")
end

--[[
    Check and unlock achievements based on a build event.
    This is the main entry point called after every build completes.

    @param playerId string -- player username
    @param buildType string -- the type of build ("tower", "house", etc.)
    @param commandCount number -- number of commands in this build
    @param isDeepBuild boolean -- whether this used the deep brain pipeline
    @param materialsUsed table? -- optional array of material names used
    @param weather string? -- current weather ("clear", "storm", "rain", "overcast")
    @param isNight boolean? -- whether it's nighttime
    @param isCoop boolean? -- whether this was a cooperative build
    @param isAurora boolean? -- whether aurora is active
]]
function AchievementManager.checkBuild(
    playerId: string,
    buildType: string,
    commandCount: number,
    isDeepBuild: boolean,
    materialsUsed: { string }?,
    weather: string?,
    isNight: boolean?,
    isCoop: boolean?,
    isAurora: boolean?
)
    local state = getState(playerId)
    local bt = buildType:lower()

    -- Track total builds
    state.buildCounts.total = state.buildCounts.total + 1
    state.buildCounts[bt] = (state.buildCounts[bt] or 0) + 1
    state.buildTypesUsed[bt] = true

    -- Track materials
    if materialsUsed then
        for _, mat in ipairs(materialsUsed) do
            state.materialsUsed[mat:lower()] = true
        end
    end

    -- Track weather
    if weather then
        state.weatherBuiltIn[weather:lower()] = true
    end

    -- Track flags
    if isDeepBuild then
        state.deepBuilds = state.deepBuilds + 1
    end
    if isNight then
        state.hasNightBuild = true
    end
    if weather and weather:lower() == "storm" then
        state.hasStormBuild = true
    end
    if isAurora then
        state.hasAuroraBuild = true
    end
    if isCoop then
        state.coopBuilds = state.coopBuilds + 1
    end

    -- ── TIER 1 CHECKS ──────────────────────────────────────
    tryUnlock(playerId, "first_build")

    local typeAchievement = BUILD_TYPE_TO_ACHIEVEMENT[bt]
    if typeAchievement then
        tryUnlock(playerId, typeAchievement)
    end

    -- ── TIER 2 CHECKS ──────────────────────────────────────
    if state.buildCounts.total >= 10 then tryUnlock(playerId, "built_10") end
    if state.buildCounts.total >= 25 then tryUnlock(playerId, "built_25") end
    if state.buildCounts.total >= 50 then tryUnlock(playerId, "built_50") end
    if state.buildCounts.total >= 100 then tryUnlock(playerId, "built_100") end

    local matCount = 0
    for _ in pairs(state.materialsUsed) do matCount = matCount + 1 end
    if matCount >= 5 then tryUnlock(playerId, "used_5_materials") end
    -- "all materials" threshold: Roblox has ~30 Material enums; we use a
    -- reasonable count of 16 common build materials.
    if matCount >= 16 then tryUnlock(playerId, "used_all_materials") end

    if state.hasNightBuild then tryUnlock(playerId, "built_at_night") end
    if state.hasStormBuild then tryUnlock(playerId, "built_in_storm") end
    if isDeepBuild then tryUnlock(playerId, "first_deep_build") end

    -- ── TIER 3 CHECKS ──────────────────────────────────────
    -- Mastered: same build type 5 times
    for typeName, count in pairs(state.buildCounts) do
        if typeName ~= "total" and count >= 5 then
            tryUnlock(playerId, "mastered_type")
            break
        end
    end

    if commandCount >= 20 then tryUnlock(playerId, "big_build_20") end
    if state.coopBuilds >= 1 then tryUnlock(playerId, "first_coop_build") end
    if state.buildCounts.total >= 100 then tryUnlock(playerId, "built_100_total") end

    -- Castle for hardest template
    if bt == "castle" then
        tryUnlock(playerId, "hardest_template")
    end

    -- ── TIER 4 CHECKS ──────────────────────────────────────
    if state.buildCounts.total >= 500 then tryUnlock(playerId, "built_500") end

    -- All weather types (clear, rain, storm, overcast, fog)
    local weatherCount = 0
    for _ in pairs(state.weatherBuiltIn) do weatherCount = weatherCount + 1 end
    if weatherCount >= 5 then tryUnlock(playerId, "all_weather") end

    -- ── TIER 5 CHECKS ──────────────────────────────────────
    if state.buildCounts.total >= 1000 then tryUnlock(playerId, "built_1000") end

    -- Storm AND aurora simultaneously
    if isAurora and weather and weather:lower() == "storm" then
        tryUnlock(playerId, "storm_and_aurora")
    end

    -- The Ark: built one of everything
    local allTypesBuilt = true
    for _, requiredType in ipairs(ALL_BUILD_TYPES) do
        if not state.buildTypesUsed[requiredType] then
            allTypesBuilt = false
            break
        end
    end
    if allTypesBuilt then
        tryUnlock(playerId, "the_ark")
    end
end

--[[
    Manually unlock an achievement for a player.
    Used for event-driven achievements (bond level reached, quest completed, etc.)

    @param playerId string -- player username
    @param achievementId string -- the achievement id to unlock
    @return boolean -- true if newly unlocked
]]
function AchievementManager.unlock(playerId: string, achievementId: string): boolean
    return tryUnlock(playerId, achievementId)
end

--[[
    Get all unlocked achievements for a player.

    @param playerId string -- player username
    @return table -- array of achievement ids
]]
function AchievementManager.getUnlocked(playerId: string): { string }
    local state = getState(playerId)
    local result = {}
    for id in pairs(state.unlocked) do
        table.insert(result, id)
    end
    return result
end

--[[
    Get progress summary for a player.
    Returns total count and per-tier breakdown.

    @param playerId string -- player username
    @return table -- { total = N, tier1 = N, tier2 = N, ... }
]]
function AchievementManager.getProgress(playerId: string): { [string]: number }
    local state = getState(playerId)
    local progress = {
        total = 0,
        tier1 = 0,
        tier2 = 0,
        tier3 = 0,
        tier4 = 0,
        tier5 = 0,
    }

    for id in pairs(state.unlocked) do
        local ach = ACHIEVEMENTS[id]
        if ach then
            progress.total = progress.total + 1
            local key = "tier" .. tostring(ach.tier)
            progress[key] = (progress[key] or 0) + 1
        end
    end

    return progress
end

--[[
    Get detailed progress including counts for display/debugging.
    (Not shown to the player per POLISH_PLAN §5.1, but useful for
    server-side logging and the BondSystem.)

    @param playerId string
    @return table -- full state snapshot
]]
function AchievementManager.getDetailedStats(playerId: string): { [string]: any }
    local state = getState(playerId)
    local progress = AchievementManager.getProgress(playerId)

    -- Count unique materials
    local matCount = 0
    for _ in pairs(state.materialsUsed) do matCount = matCount + 1 end

    -- Count weather types
    local weatherCount = 0
    for _ in pairs(state.weatherBuiltIn) do weatherCount = weatherCount + 1 end

    return {
        progress = progress,
        totalBuilds = state.buildCounts.total,
        buildTypeCounts = state.buildCounts,
        materialsCount = matCount,
        weatherCount = weatherCount,
        deepBuilds = state.deepBuilds,
        coopBuilds = state.coopBuilds,
        refusalCount = state.refusalCount,
        impressedCount = state.impressedCount,
        npcsTalkedTo = state.npcsTalkedTo,
        earlQuestsCompleted = state.earlQuestsCompleted,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPECIAL EVENT HOOKS
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Called when a player talks to an NPC.
    @param playerId string
    @param npcName string -- e.g. "Earl", "Spark", etc.
]]
function AchievementManager.onNPCTalk(playerId: string, npcName: string)
    local state = getState(playerId)
    state.npcsTalkedTo[npcName:lower()] = true

    -- Check: talked to all 5 NPCs
    local npcCount = 0
    for _ in pairs(state.npcsTalkedTo) do npcCount = npcCount + 1 end
    if npcCount >= 5 then
        tryUnlock(playerId, "talked_all_npcs")
    end
end

--[[
    Called when a player completes an Earl quest.
    @param playerId string
]]
function AchievementManager.onEarlQuestComplete(playerId: string)
    local state = getState(playerId)
    state.earlQuestsCompleted = state.earlQuestsCompleted + 1

    if state.earlQuestsCompleted >= 5 then
        tryUnlock(playerId, "earl_quests_5")
    end

    -- "all_earl_quests" — Earl has 10 quests total
    if state.earlQuestsCompleted >= 10 then
        tryUnlock(playerId, "all_earl_quests")
    end

    -- "all_npc_quests" — all NPCs have quests complete
    -- This is checked more broadly; for now we track Earl's contribution
end

--[[
    Called when a player visits on a new day.
    @param playerId string
    @param dateStr string -- "YYYY-MM-DD" format
]]
function AchievementManager.onPlayerVisit(playerId: string, dateStr: string)
    local state = getState(playerId)
    state.visitDates[dateStr] = true

    -- Check 7-day streak
    -- Parse the date and look for 7 consecutive days
    local year, month, day = dateStr:match("(%d+)-(%d+)-(%d+)")
    if year and month and day then
        -- Count consecutive days ending today
        local function dateOffset(offsetDays)
            -- Simple approach: use os.time for the calculation
            local t = os.time({
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = 12,
            })
            t = t + offsetDays * 86400
            local d = os.date("*t", t)
            return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
        end

        local streak = 1
        for i = 1, 30 do
            local checkDate = dateOffset(-i)
            if state.visitDates[checkDate] then
                streak = streak + 1
            else
                break
            end
        end

        if streak >= 7 then
            tryUnlock(playerId, "visited_7_days")
        end
        if streak >= 30 then
            tryUnlock(playerId, "streak_30")
        end
    end
end

--[[
    Called when Lucineer refuses a request.
    @param playerId string
]]
function AchievementManager.onRefusal(playerId: string)
    local state = getState(playerId)
    state.refusalCount = state.refusalCount + 1

    if state.refusalCount >= 5 then
        tryUnlock(playerId, "refused_5_times")
    end
end

--[[
    Called when Lucineer is impressed by a build.
    @param playerId string
]]
function AchievementManager.onImpressed(playerId: string)
    local state = getState(playerId)
    state.impressedCount = state.impressedCount + 1
    tryUnlock(playerId, "impressed_lucineer")
end

--[[
    Called when a player persists against Lucineer's argument.
    (They build the thing he argued against anyway.)
    @param playerId string
]]
function AchievementManager.onPersistedAgainst(playerId: string)
    tryUnlock(playerId, "persisted_against")
end

--[[
    Called when a player discovers a hidden skill via Vectorize.
    @param playerId string
    @param score number -- Vectorize match score
]]
function AchievementManager.onSkillDiscovered(playerId: string, score: number)
    if score > 0.8 then
        tryUnlock(playerId, "hidden_skill")
    end
end

--[[
    Called when a player uses the creative pipeline.
    @param playerId string
]]
function AchievementManager.onCreativePipeline(playerId: string)
    local state = getState(playerId)
    state.hasCreativePipeline = true
    tryUnlock(playerId, "creative_pipeline")
end

--[[
    Called when a player shares a build (viral).
    @param playerId string
]]
function AchievementManager.onViralShare(playerId: string)
    local state = getState(playerId)
    state.viralShares = state.viralShares + 1
    if state.viralShares >= 1 then
        tryUnlock(playerId, "first_viral_share")
    end
end

--[[
    Called when a build is referenced by Lucineer in a later session.
    @param playerId string
]]
function AchievementManager.onBuildReferenced(playerId: string)
    tryUnlock(playerId, "referenced_later")
end

--[[
    Called when the logbook secret is discovered.
    @param playerId string
]]
function AchievementManager.onLogbookDiscovered(playerId: string)
    tryUnlock(playerId, "logbook_secret")
end

--[[
    Called when all NPC quests are completed.
    @param playerId string
]]
function AchievementManager.onAllNPCQuestsComplete(playerId: string)
    tryUnlock(playerId, "all_npc_quests")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BOND SYSTEM INTEGRATION
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Called by BondSystem when a player reaches a new bond level.
    @param playerId string
    @param bondLevel number -- new bond level (1-5+)
]]
function AchievementManager.onBondLevelChange(playerId: string, bondLevel: number)
    if bondLevel >= 3 then
        tryUnlock(playerId, "reached_bond_3")
    end
    if bondLevel >= 5 then
        tryUnlock(playerId, "reached_bond_5")
        tryUnlock(playerId, "named_hammer")
        tryUnlock(playerId, "max_bond")
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TIER COMPLETION CHECK
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Check if all achievements in any single tier are unlocked.
    If so, unlock the "tier_complete" meta-achievement.
    @param playerId string
]]
function AchievementManager.checkTierCompletion(playerId: string)
    local state = getState(playerId)

    for tier = 1, 5 do
        local tierTotal = TIER_COUNTS[tier] or 0
        local tierUnlocked = 0

        for _, ach in pairs(ACHIEVEMENTS) do
            if ach.tier == tier and state.unlocked[ach.id] then
                tierUnlocked = tierUnlocked + 1
            end
        end

        if tierUnlocked >= tierTotal and tierTotal > 0 then
            -- All achievements in this tier are unlocked
            tryUnlock(playerId, "tier_complete")
            break
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DEBUG / TESTING
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get all achievement definitions (for debugging or admin tools).
    @return table -- all 49 achievement definitions keyed by id
]]
function AchievementManager.getAllDefinitions(): { [string]: any }
    return ACHIEVEMENTS
end

--[[
    Get tier names.
    @return table
]]
function AchievementManager.getTierNames(): { [string]: any }
    return TIER_NAMES
end

return AchievementManager
