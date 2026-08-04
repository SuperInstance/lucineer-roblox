--!strict
--[[
    MissionBoard — Quest Distribution from NPCs
    ===========================================
    The heartbeat of Slackwater's economy loop.

    Each NPC offers missions themed to their character:

    EARL — Fishing Quotas
        "Need 15 salmon by 1700. 300 scrap."
        Catch-and-deliver fishing missions with deadlines.

    BEA — Build & Navigation Missions
        "Build a signal tower on north point."
        Construction, exploration, and infrastructure quests.

    HERMES — Delivery, Tow & Salvage
        Channel-based missions: deliver goods, tow vessels,
        salvage wrecks from the fog.

    SPARK — Material Gathering
        "I need six bolts, three sheets, and a working hinge."
        Scavenging, crafting, and material collection.

    MISSION SCALING:
        Missions scale with era, bond level, and player history.
        Higher bond = more complex, higher-reward missions.
        Higher era = bigger asks, better pay.

    REWARDS:
        All missions give Influence + Scrap + sometimes materials.
        Influence is the key reward — it gates progression unlocks.

    Dependencies:
        - ServerScriptService.EconomySystem.Currency
        - ServerScriptService.EconomySystem.EraGates
        - ServerScriptService.BondSystem (for bond-gated content)
        - ServerScriptService.EraSystem (for era scaling)
]]

local Players = game:GetService("Players")

-- ═══════════════════════════════════════════════════════════════════════════
-- MISSION TEMPLATES
-- Each template has: id, giver, title, description, type, requirements,
-- rewards, minEra, minBond, weight (selection probability weight)
-- ═══════════════════════════════════════════════════════════════════════════

local MISSION_TEMPLATES = {
    -- ═══════════════════════════════════════════════════════════════
    -- EARL — FISHING QUOTAS
    -- ═══════════════════════════════════════════════════════════════

    {
        id = "earl_salmon_15",
        giver = "Earl",
        title = "Fifteen Salmon by 1700",
        description = "Need fifteen salmon on the dock by five o'clock. Not trout, not cod — salmon. They're running and I've got a manifest that says we should have them.",
        type = "fishing_quota",
        requirements = { fishType = "salmon", amount = 15, deadlineHours = 8 },
        rewards = { scrap = 300, influence = 2 },
        minEra = 1, minBond = 0, weight = 10,
    },
    {
        id = "earl_cod_30",
        giver = "Earl",
        title = "Cod Run — Thirty Fish",
        description = "Cod's thick on the north grounds. Thirty fish, whole, on ice. Don't give me that look — I graded the manifest, not the ocean.",
        type = "fishing_quota",
        requirements = { fishType = "cod", amount = 30, deadlineHours = 12 },
        rewards = { scrap = 500, influence = 3 },
        minEra = 2, minBond = 0, weight = 8,
    },
    {
        id = "earl_tuna_10",
        giver = "Earl",
        title = "Deep Water — Ten Tuna",
        description = "Tuna. Ten of them. They're past the third narrows and they don't come easy. Your boat needs to handle weather. Check your hull before you go.",
        type = "fishing_quota",
        requirements = { fishType = "tuna", amount = 10, deadlineHours = 24 },
        rewards = { scrap = 1200, influence = 5, materials = { metal = 3 } },
        minEra = 3, minBond = 1, weight = 5,
    },
    {
        id = "earl_stormcatch_5",
        giver = "Earl",
        title = "Storm Catch — Five Marlins",
        description = "Marlin only run before a storm. Five of them. This is the hardest manifest I've ever written, and I've written a lot of manifests.",
        type = "fishing_quota",
        requirements = { fishType = "marlin", amount = 5, deadlineHours = 6 },
        rewards = { scrap = 2500, influence = 8, materials = { copper = 5 } },
        minEra = 4, minBond = 2, weight = 3,
    },
    {
        id = "earl_channel_haul",
        giver = "Earl",
        title = "Full Channel Haul — 100 Mixed",
        description = "One hundred fish. Any kind. I don't care what — I care that they're on my dock before the ferry comes. This is the big one.",
        type = "fishing_quota",
        requirements = { fishType = "any", amount = 100, deadlineHours = 48 },
        rewards = { scrap = 5000, influence = 12, materials = { wood = 20, metal = 10 } },
        minEra = 4, minBond = 2, weight = 2,
    },

    -- ═══════════════════════════════════════════════════════════════
    -- BEA — BUILD & NAVIGATION
    -- ═══════════════════════════════════════════════════════════════

    {
        id = "bea_signal_tower",
        giver = "Bea",
        title = "Signal Tower — North Point",
        description = "The north point is dark at night. I need a signal tower there. The Light doesn't reach that far, and what's past the beam needs its own perimeter. Build it and I'll key you in.",
        type = "build",
        requirements = { buildType = "signal_tower", location = "north_point" },
        rewards = { scrap = 800, influence = 5, materials = { glass = 5 } },
        minEra = 3, minBond = 1, weight = 6,
    },
    {
        id = "bea_lighthouse_restore",
        giver = "Bea",
        title = "Restore the Lighthouse",
        description = "You know what this is. The Light needs to come back. The full structure — Fresnel lens, copper wiring, stone foundation. Everything. When it's done, the perimeter holds. The dark stays out.",
        type = "build",
        requirements = { buildType = "lighthouse_restored" },
        rewards = { scrap = 5000, influence = 25, materials = { copper = 20, glass = 15 } },
        minEra = 5, minBond = 3, weight = 2,
    },
    {
        id = "bea_dock_extension",
        giver = "Bea",
        title = "Extend the South Dock",
        description = "Hermes needs more mooring. The south dock's too short — he's been rafting boats and that's not sustainable. Extend it. Stone and timber, proper pylons.",
        type = "build",
        requirements = { buildType = "pier_jetty", location = "south_dock" },
        rewards = { scrap = 400, influence = 3, materials = { wood = 10 } },
        minEra = 2, minBond = 0, weight = 7,
    },
    {
        id = "bea_nav_route",
        giver = "Bea",
        title = "Chart the Western Approach",
        description = "There's a route through the western shoals that nobody's mapped. I need you to sail it, mark the hazards, and report back. The fog comes in from that direction and I want to know what's under it.",
        type = "navigation",
        requirements = { destination = "western_shoals", waypoints = 5 },
        rewards = { scrap = 600, influence = 4, materials = { cloth = 5 } },
        minEra = 2, minBond = 1, weight = 5,
    },
    {
        id = "bea_fog_watch",
        giver = "Bea",
        title = "Fog Watch — Twelve Hours",
        description = "Fog's coming in tonight. I need someone on the tower for twelve hours. You'll hear things in the static — that's normal. Report what you hear. Don't go into the fog.",
        type = "watch",
        requirements = { durationHours = 12, location = "watch_tower" },
        rewards = { scrap = 350, influence = 3, materials = { glass = 3 } },
        minEra = 3, minBond = 1, weight = 4,
    },

    -- ═══════════════════════════════════════════════════════════════
    -- HERMES — DELIVERY, TOW & SALVAGE
    -- ═══════════════════════════════════════════════════════════════

    {
        id = "hermes_supply_run",
        giver = "Hermes",
        title = "Supply Run to the Capitaine",
        description = "I've got crates on the dock that need to reach the Capitaine at anchor. Simple run. Out and back before the tide turns. The Channel's calm right now — that won't last.",
        type = "delivery",
        requirements = { cargo = "crates", destination = "capitaine_anchor", deadlineHours = 3 },
        rewards = { scrap = 200, influence = 2 },
        minEra = 1, minBond = 0, weight = 8,
    },
    {
        id = "hermes_tow_drifter",
        giver = "Hermes",
        title = "Tow the Drifter In",
        description = "There's a hull drifting on the eastern current. No lights, no signal. I need you to put a line on it and bring it in. What's inside — that's between you and Earl's manifest.",
        type = "tow",
        requirements = { target = "drifting_hull", location = "eastern_current" },
        rewards = { scrap = 450, influence = 3, materials = { metal = 5, wood = 5 } },
        minEra = 2, minBond = 0, weight = 6,
    },
    {
        id = "hermes_salvage_wreck",
        giver = "Hermes",
        title = "Salvage the South Wreck",
        description = "Wreck on the south shoal. Went down in the last gale — wooden hull, copper fittings, maybe an engine block. It's breaking up. Get what you can before the next storm finishes it.",
        type = "salvage",
        requirements = { target = "south_wreck", location = "south_shoal" },
        rewards = { scrap = 700, influence = 4, materials = { metal = 10, copper = 5, wood = 8 } },
        minEra = 2, minBond = 1, weight = 5,
    },
    {
        id = "hermes_deep_salvage",
        giver = "Hermes",
        title = "Deep Channel Salvage",
        description = "Something large on the channel floor, past the third narrows. Sonar contact — could be an engine, could be a hull. You'll need depth gear and a strong line. This is the one I told you about.",
        type = "salvage",
        requirements = { target = "channel_floor_contact", location = "deep_channel", requiresSonar = true },
        rewards = { scrap = 2000, influence = 7, materials = { metal = 15, copper = 8, glass = 5 } },
        minEra = 4, minBond = 2, weight = 3,
    },
    {
        id = "hermes_relay_earl",
        giver = "Hermes",
        title = "Relay Earl's Manifest to Bea",
        description = "Earl's manifest needs to reach Bea at the lighthouse before the fog comes in. She won't answer the radio — she never does before fog. Sail it up there. Quick and quiet.",
        type = "delivery",
        requirements = { cargo = "manifest", destination = "lighthouse", deadlineHours = 2 },
        rewards = { scrap = 300, influence = 3, materials = { cloth = 3 } },
        minEra = 2, minBond = 1, weight = 5,
    },

    -- ═══════════════════════════════════════════════════════════════
    -- SPARK — MATERIAL GATHERING
    -- ═══════════════════════════════════════════════════════════════

    {
        id = "spark_bolts_6",
        giver = "Spark",
        title = "Six Bolts for the Forge",
        description = "*tilts lens-eye, nudges a diagram toward you* — Six bolts. Medium thread. They're in the salvage piles south of the forge. Spark's lost three this week.",
        type = "gather",
        requirements = { material = "metal", amount = 6, source = "salvage_piles" },
        rewards = { scrap = 150, influence = 2, materials = { metal = 2 } },
        minEra = 1, minBond = 0, weight = 9,
    },
    {
        id = "spark_copper_wire",
        giver = "Spark",
        title = "Copper Wire — Twenty Strands",
        description = "*holds up a melted coil, emits descending servo tone* — Copper wire. Twenty strands. The Channel's been bringing in insulation-stripped coils. Check the tideline.",
        type = "gather",
        requirements = { material = "copper", amount = 20, source = "tideline" },
        rewards = { scrap = 350, influence = 3, materials = { copper = 3 } },
        minEra = 2, minBond = 0, weight = 7,
    },
    {
        id = "spark_glass_panels",
        giver = "Spark",
        title = "Fog Glass Panels",
        description = "*spins once, sparks trailing, holds up a cracked lens* — Glass. Fog glass. Five panels. Bea needs them for the signal lamps. Tide pools after the ebb.",
        type = "gather",
        requirements = { material = "glass", amount = 5, source = "tide_pools" },
        rewards = { scrap = 400, influence = 4, materials = { glass = 2 } },
        minEra = 3, minBond = 1, weight = 5,
    },
    {
        id = "spark_hardwood_planks",
        giver = "Spark",
        title = "Hardwood Planks — Fifteen",
        description = "*beep-beep, taps welding mask excitedly* — Good wood. Not beach wood. Fifteen planks, straight-grained. The old pier pilings have water-cured hardwood inside. Strip them carefully.",
        type = "gather",
        requirements = { material = "wood", amount = 15, source = "old_pilings" },
        rewards = { scrap = 500, influence = 4, materials = { wood = 5 } },
        minEra = 3, minBond = 0, weight = 6,
    },
    {
        id = "spark_stone_block",
        giver = "Spark",
        title = "Cut Stone — Twenty Blocks",
        description = "*low servo hum, displays a precise geometric shape* — Stone. Cut. Twenty blocks uniform. The north quarry face has been spalling — usable blocks, just need hauling.",
        type = "gather",
        requirements = { material = "stone", amount = 20, source = "north_quarry" },
        rewards = { scrap = 600, influence = 4, materials = { stone = 5 } },
        minEra = 3, minBond = 1, weight = 5,
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- RUNTIME STATE
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → mission state
-- {
--   active = { [missionInstanceId] = { templateId, status, startTime, progress } },
--   completed = { [missionId] = true },  -- completed template IDs (for history)
--   completedCount = number,
--   availableCache = { [string] = table }, -- cached available missions
-- }
local playerMissions: { [string]: { [string]: any } } = {}

local Currency
local EraGates
local initialized = false

-- ═══════════════════════════════════════════════════════════════════════════
-- INTERNAL HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function getMissionState(playerName: string): { [string]: any }
    if not playerMissions[playerName] then
        playerMissions[playerName] = {
            active = {},
            completed = {},
            completedCount = 0,
            availableCache = {},
        }
    end
    return playerMissions[playerName]
end

--[[
    Get the EraSystem building era for a player.
    @param playerName string
    @return number
]]
local function getBuildingEra(playerName: string): number
    local EraSystem = require(game:GetService("ServerScriptService"):WaitForChild("EraSystem"))
    return EraSystem.getBuildingEra(playerName)
end

--[[
    Get the BondSystem bond tier for a player.
    @param playerName string
    @return number
]]
local function getBondTier(playerName: string): number
    local BondSystem = require(game:GetService("ServerScriptService"):WaitForChild("BondSystem"))
    return BondSystem.getBondLevel(playerName)
end

--[[
    Generate a unique mission instance ID.
    @param templateId string
    @return string
]]
local function generateInstanceId(templateId: string): string
    return templateId .. "_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
end

--[[
    Check if a mission template is available for a player.
    @param playerName string
    @param template table — mission template
    @return boolean
]]
local function isTemplateAvailable(playerName: string, template: { [string]: any }): boolean
    local state = getMissionState(playerName)

    -- Check era requirement
    local era = getBuildingEra(playerName)
    if era < (template.minEra or 1) then
        return false
    end

    -- Check bond requirement
    local bond = getBondTier(playerName)
    if bond < (template.minBond or 0) then
        return false
    end

    -- Check if already completed (no repeat unless designed for it)
    if state.completed[template.id] then
        return false
    end

    -- Check if already active
    for _, active in pairs(state.active) do
        if active.templateId == template.id then
            return false
        end
    end

    return true
end

--[[
    Get all available mission templates for a player, filtered and weighted.
    @param playerName string
    @return table — array of available templates
]]
local function getAvailableTemplates(playerName: string): { [string]: any }
    local available = {}
    for _, template in ipairs(MISSION_TEMPLATES) do
        if isTemplateAvailable(playerName, template) then
            table.insert(available, template)
        end
    end
    return available
end

--[[
    Get available templates from a specific giver.
    @param playerName string
    @param giver string — "Earl", "Bea", "Hermes", "Spark"
    @return table
]]
local function getAvailableFromGiver(playerName: string, giver: string): { [string]: any }
    local result = {}
    for _, template in ipairs(MISSION_TEMPLATES) do
        if template.giver == giver and isTemplateAvailable(playerName, template) then
            table.insert(result, template)
        end
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

local MissionBoard = {}

--[[
    Bind the Currency subsystem (for reward distribution).
    @param currencyModule table
]]
function MissionBoard.bindCurrency(currencyModule)
    Currency = currencyModule
end

--[[
    Bind the EraGates subsystem (for era-aware scaling).
    @param eraGatesModule table
]]
function MissionBoard.bindEraGates(eraGatesModule)
    EraGates = eraGatesModule
end

--[[
    Initialize the MissionBoard.
]]
function MissionBoard.init()
    if initialized then return end
    initialized = true

    Players.PlayerAdded:Connect(function(player)
        getMissionState(player.Name)
    end)

    print(string.format("[MissionBoard] Initialized — %d mission templates", #MISSION_TEMPLATES))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MISSION OFFERING
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get available missions from a specific NPC for a player.
    Weighted random selection of up to `count` missions.
    @param playerName string
    @param giver string — NPC name
    @param count number? — max missions to return (default 3)
    @return table — array of mission templates
]]
function MissionBoard.getMissionsFrom(playerName: string, giver: string, count: number?): { [string]: any }
    count = count or 3
    local available = getAvailableFromGiver(playerName, giver)

    if #available <= count then
        return available
    end

    -- Weighted selection
    local selected = {}
    local pool = {}
    local totalWeight = 0

    for _, template in ipairs(available) do
        table.insert(pool, template)
        totalWeight = totalWeight + (template.weight or 5)
    end

    for _ = 1, count do
        if #pool == 0 then break end

        local roll = math.random() * totalWeight
        local cumulative = 0
        local pickedIdx = 1

        for i, template in ipairs(pool) do
            cumulative = cumulative + (template.weight or 5)
            if roll <= cumulative then
                pickedIdx = i
                break
            end
        end

        table.insert(selected, pool[pickedIdx])
        totalWeight = totalWeight - (pool[pickedIdx].weight or 5)
        table.remove(pool, pickedIdx)
    end

    return selected
end

--[[
    Get all available missions across all NPCs.
    @param playerName string
    @return table — grouped by giver
]]
function MissionBoard.getAllAvailable(playerName: string): { [string]: any }
    local result = {}
    for _, giver in ipairs({ "Earl", "Bea", "Hermes", "Spark" }) do
        result[giver] = getAvailableFromGiver(playerName, giver)
    end
    return result
end

--[[
    Accept a mission. Creates an active instance.
    @param playerName string
    @param missionId string — template ID
    @return boolean, string? — success, instanceId or error
]]
function MissionBoard.acceptMission(playerName: string, missionId: string): (boolean, string?)
    local state = getMissionState(playerName)

    -- Find template
    local template
    for _, t in ipairs(MISSION_TEMPLATES) do
        if t.id == missionId then
            template = t
            break
        end
    end

    if not template then
        return false, "unknown_mission"
    end

    if not isTemplateAvailable(playerName, template) then
        return false, "not_available"
    end

    local instanceId = generateInstanceId(missionId)
    state.active[instanceId] = {
        templateId = missionId,
        giver = template.giver,
        title = template.title,
        status = "active",
        startTime = os.time(),
        deadline = template.requirements.deadlineHours and (os.time() + template.requirements.deadlineHours * 3600) or nil,
        progress = {},
    }

    print(string.format("[MissionBoard] %s accepted: %s (%s)", playerName, template.title, instanceId))

    return true, instanceId
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MISSION PROGRESS & COMPLETION
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Update progress on a mission.
    @param playerName string
    @param instanceId string
    @param progressKey string — e.g. "fishCaught", "built"
    @param progressValue any
]]
function MissionBoard.updateProgress(playerName: string, instanceId: string, progressKey: string, progressValue: any)
    local state = getMissionState(playerName)
    local mission = state.active[instanceId]
    if not mission then return end

    mission.progress[progressKey] = progressValue
end

--[[
    Check if a mission's requirements are met.
    @param playerName string
    @param instanceId string
    @return boolean
]]
function MissionBoard.checkCompletion(playerName: string, instanceId: string): boolean
    local state = getMissionState(playerName)
    local mission = state.active[instanceId]
    if not mission or mission.status ~= "active" then return false end

    -- Find template
    local template
    for _, t in ipairs(MISSION_TEMPLATES) do
        if t.id == mission.templateId then
            template = t
            break
        end
    end
    if not template then return false end

    -- Check deadline
    if mission.deadline and os.time() > mission.deadline then
        mission.status = "expired"
        return false
    end

    -- Type-specific completion checks
    local req = template.requirements
    local progress = mission.progress

    if template.type == "fishing_quota" then
        local caught = progress.fishCaught or 0
        if caught >= (req.amount or 0) then
            return true
        end
    elseif template.type == "build" then
        if progress.built == true then
            return true
        end
    elseif template.type == "delivery" then
        if progress.delivered == true then
            return true
        end
    elseif template.type == "tow" then
        if progress.towed == true then
            return true
        end
    elseif template.type == "salvage" then
        if progress.salvaged == true then
            return true
        end
    elseif template.type == "navigation" then
        local visited = progress.waypointsVisited or 0
        if visited >= (req.waypoints or 0) then
            return true
        end
    elseif template.type == "watch" then
        local watched = progress.hoursWatched or 0
        if watched >= (req.durationHours or 0) then
            return true
        end
    elseif template.type == "gather" then
        local gathered = progress.materialGathered or 0
        if gathered >= (req.amount or 0) then
            return true
        end
    end

    return false
end

--[[
    Complete a mission. Awards rewards and records completion.
    @param playerName string
    @param instanceId string
    @return boolean, table? — success, rewards table
]]
function MissionBoard.completeMission(playerName: string, instanceId: string): (boolean, { [string]: any }?)
    local state = getMissionState(playerName)
    local mission = state.active[instanceId]
    if not mission or mission.status ~= "active" then
        return false, nil
    end

    -- Verify completion
    if not MissionBoard.checkCompletion(playerName, instanceId) then
        return false, nil
    end

    -- Find template for rewards
    local template
    for _, t in ipairs(MISSION_TEMPLATES) do
        if t.id == mission.templateId then
            template = t
            break
        end
    end
    if not template then return false, nil end

    -- Mark completed
    mission.status = "completed"
    mission.completedTime = os.time()
    state.completed[mission.templateId] = true
    state.completedCount = (state.completedCount or 0) + 1

    -- Award rewards
    local rewards = template.rewards or {}
    if Currency then
        Currency.award(playerName, rewards, "mission_" .. mission.templateId)
    end

    -- Notify BondSystem (missions advance bond)
    local BondSystem = require(game:GetService("ServerScriptService"):WaitForChild("BondSystem"))
    if BondSystem then
        BondSystem.addQuestXP(playerName)
    end

    -- Remove from active
    state.active[instanceId] = nil

    print(string.format("[MissionBoard] %s completed: %s (+%d scrap, +%d influence)",
        playerName, template.title, rewards.scrap or 0, rewards.influence or 0))

    return true, rewards
end

--[[
    Abandon a mission. Removes it without rewards.
    @param playerName string
    @param instanceId string
]]
function MissionBoard.abandonMission(playerName: string, instanceId: string)
    local state = getMissionState(playerName)
    state.active[instanceId] = nil
    print(string.format("[MissionBoard] %s abandoned mission %s", playerName, instanceId))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- QUERY API
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get all active missions for a player.
    @param playerName string
    @return table
]]
function MissionBoard.getActiveMissions(playerName: string): { [string]: any }
    local state = getMissionState(playerName)
    return state.active
end

--[[
    Get count of completed missions.
    @param playerName string
    @return number
]]
function MissionBoard.getCompletedCount(playerName: string): number
    local state = getMissionState(playerName)
    return state.completedCount or 0
end

--[[
    Get completed mission IDs (history).
    @param playerName string
    @return table
]]
function MissionBoard.getCompletedMissions(playerName: string): { [string]: any }
    local state = getMissionState(playerName)
    return state.completed
end

--[[
    Check if a player has completed a specific mission.
    @param playerName string
    @param missionId string
    @return boolean
]]
function MissionBoard.hasCompleted(playerName: string, missionId: string): boolean
    local state = getMissionState(playerName)
    return state.completed[missionId] == true
end

--[[
    Get a mission template by ID.
    @param missionId string
    @return table?
]]
function MissionBoard.getTemplate(missionId: string): { [string]: any }?
    for _, t in ipairs(MISSION_TEMPLATES) do
        if t.id == missionId then
            return t
        end
    end
    return nil
end

--[[
    Get all mission templates (for UI/debug).
    @return table
]]
function MissionBoard.getAllTemplates(): { [string]: any }
    return MISSION_TEMPLATES
end

--[[
    Get full mission state for a player (admin/debug).
    @param playerName string
    @return table
]]
function MissionBoard.getPlayerMissionState(playerName: string): { [string]: any }
    local state = getMissionState(playerName)
    return {
        active = state.active,
        completedCount = state.completedCount or 0,
        completedIds = (function()
            local ids = {}
            for id in pairs(state.completed) do
                table.insert(ids, id)
            end
            return ids
        end)(),
    }
end

--[[
    Get available mission count per giver (for NPC prompt display).
    @param playerName string
    @return table — { Earl = 2, Bea = 1, Hermes = 3, Spark = 2 }
]]
function MissionBoard.getAvailableCounts(playerName: string): { [string]: number }
    local result = { Earl = 0, Bea = 0, Hermes = 0, Spark = 0 }
    for _, template in ipairs(MISSION_TEMPLATES) do
        if isTemplateAvailable(playerName, template) then
            result[template.giver] = (result[template.giver] or 0) + 1
        end
    end
    return result
end

print(string.format("[MissionBoard] Module loaded — %d mission templates across 4 NPCs", #MISSION_TEMPLATES))

return MissionBoard
