--!strict
--[[
    EraProgression.lua — 5-Era Building Progression System
    ======================================================
    Driftwood → Wood → Stone → Metal → Light

    Players advance eras by completing builds. Each era unlocks:
      - new materials
      - new build commands
      - new island areas

    Session storage persists per-player progress in memory and can be
    synced to DataStores via SaveSystem.

    Usage:
        local EraProgression = require(script.Parent.EraProgression)
        EraProgression.init()

        -- After a build completes
        EraProgression.onBuild(player.Name, buildType)
        if EraProgression.checkBuildingEraAdvancement(player.Name) then
            EraProgression.advanceBuildingEra(player.Name)
        end
]]

local Players = game:GetService("Players")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local EraProgression = {}

----------------------------------------------------------------
-- ERA DEFINITIONS
----------------------------------------------------------------

EraProgression.ERAS = {
    "driftwood",
    "wood",
    "stone",
    "metal",
    "light",
}

local ERA_DATA: { [string]: EraDefinition } = {
    driftwood = {
        index = 1,
        name = "Driftwood",
        description = "Scavenged scraps washed ashore. Basic shelters and simple shapes.",
        requiredBuilds = 0,
        cost = {},
        materials = { "Wood", "WoodPlanks", "Sand", "Fabric" },
        commands = { "createPart", "createModel", "movePart", "deletePart", "addLight" },
        areas = { "shore", "tide_pools" },
        color = Color3.fromRGB(139, 90, 43),
        flavor = "Everything starts with what the sea gives back.",
    },
    wood = {
        index = 2,
        name = "Wood",
        description = "Cut timber and proper joints. Walls, docks, and small boats.",
        requiredBuilds = 5,
        cost = { wood = 20 },
        materials = { "Wood", "WoodPlanks", "Fabric", "Grass", "Slate" },
        commands = { "createPart", "createModel", "movePart", "deletePart", "addLight", "addSound", "setTerrain" },
        areas = { "shore", "tide_pools", "inland_grove", "small_dock" },
        color = Color3.fromRGB(160, 120, 80),
        flavor = "The forest bends toward your hands.",
    },
    stone = {
        index = 3,
        name = "Stone",
        description = "Quarried rock and mortar. Towers, roads, and lasting foundations.",
        requiredBuilds = 15,
        cost = { wood = 50, stone = 30 },
        materials = { "Wood", "WoodPlanks", "Fabric", "Grass", "Slate", "Brick", "Cobblestone", "Concrete", "Marble" },
        commands = { "createPart", "createModel", "movePart", "deletePart", "addLight", "addSound", "setTerrain", "createWall", "createTower" },
        areas = { "shore", "tide_pools", "inland_grove", "small_dock", "quarry", "high_cliffs" },
        color = Color3.fromRGB(120, 120, 120),
        flavor = "The island trusts what outlasts the tide.",
    },
    metal = {
        index = 4,
        name = "Metal",
        description = "Forged iron and brass. Machines, railings, and reinforced hulls.",
        requiredBuilds = 35,
        cost = { wood = 80, stone = 60, metal = 40 },
        materials = { "Wood", "WoodPlanks", "Fabric", "Grass", "Slate", "Brick", "Cobblestone", "Concrete", "Marble", "Metal", "DiamondPlate", "CorrodedMetal", "Foil" },
        commands = { "createPart", "createModel", "movePart", "deletePart", "addLight", "addSound", "setTerrain", "createWall", "createTower", "createMachine", "addScript" },
        areas = { "shore", "tide_pools", "inland_grove", "small_dock", "quarry", "high_cliffs", "foundry", "deep_mines" },
        color = Color3.fromRGB(80, 90, 100),
        flavor = "Fire and hammer give the island a new voice.",
    },
    light = {
        index = 5,
        name = "Light",
        description = "Prismatic architecture and resonant energy. The island remembers you.",
        requiredBuilds = 70,
        cost = { wood = 120, stone = 100, metal = 80, crystal = 40 },
        materials = { "Wood", "WoodPlanks", "Fabric", "Grass", "Slate", "Brick", "Cobblestone", "Concrete", "Marble", "Metal", "DiamondPlate", "CorrodedMetal", "Foil", "Neon", "Glass", "ForceField" },
        commands = { "createPart", "createModel", "movePart", "deletePart", "addLight", "addSound", "setTerrain", "createWall", "createTower", "createMachine", "addScript", "createBeacon", "warp" },
        areas = { "shore", "tide_pools", "inland_grove", "small_dock", "quarry", "high_cliffs", "foundry", "deep_mines", "lighthouse", "aether_tower" },
        color = Color3.fromRGB(255, 240, 180),
        flavor = "You are not just building anymore. You are remembering.",
    },
}

type EraDefinition = {
    index: number,
    name: string,
    description: string,
    requiredBuilds: number,
    cost: { [string]: number },
    materials: { string },
    commands: { string },
    areas: { string },
    color: Color3,
    flavor: string,
}

type SessionData = {
    era: string,
    totalBuilds: number,
    buildsByType: { [string]: number },
    unlockedAreas: { [string]: boolean },
    eraChangedThisSession: boolean,
    lastBuildTime: number?,
}

----------------------------------------------------------------
-- SESSION STORAGE
----------------------------------------------------------------

-- player.UserId -> player session progress table
EraProgression._sessions = {} :: { [number]: SessionData }

local DEFAULT_SESSION: SessionData = {
    era = "driftwood",
    totalBuilds = 0,
    buildsByType = {},
    unlockedAreas = {},
    eraChangedThisSession = false,
    lastBuildTime = nil,
}

----------------------------------------------------------------
-- INTERNAL HELPERS
----------------------------------------------------------------

--[[
    Get a player object from a player name.
]]
local function getPlayerByName(playerName: string): Player?
    return Players:FindFirstChild(playerName) :: Player?
end

--[[
    Build the default set of unlocked areas for an era.
]]
local function unlockAreasForEra(session: SessionData, eraKey: string)
    local data = ERA_DATA[eraKey]
    if not data then return end
    for _, area in ipairs(data.areas) do
        session.unlockedAreas[area] = true
    end
end

----------------------------------------------------------------
-- LIFECYCLE
----------------------------------------------------------------

--[[
    Initialize the system. Wires player cleanup.
]]
function EraProgression.init()
    Players.PlayerRemoving:Connect(function(player)
        EraProgression._sessions[player.UserId] = nil
    end)
    print("[EraProgression] Initialized — 5 eras from Driftwood to Light")
end

----------------------------------------------------------------
-- SESSION STORAGE API
----------------------------------------------------------------

--[[
    Get or create a player's session data.
]]
function EraProgression.getSession(playerId: number): SessionData
    local session = EraProgression._sessions[playerId]
    if not session then
        session = table.clone(DEFAULT_SESSION) :: SessionData
        EraProgression._sessions[playerId] = session
    end
    return session
end

--[[
    Load saved data into session storage (called by SaveSystem on join).
    Invalid era keys fall back to driftwood.
]]
function EraProgression.loadSession(playerId: number, snapshot: { [string]: any }?): boolean
    if not snapshot then return false end

    local era = snapshot.era
    if era and not ERA_DATA[era :: string] then
        warn(string.format("[EraProgression] Ignoring invalid saved era '%s' for player %d", tostring(era), playerId))
        era = nil
    end

    local session = table.clone(DEFAULT_SESSION) :: SessionData
    session.era = (era :: string) or DEFAULT_SESSION.era
    session.totalBuilds = tonumber(snapshot.totalBuilds) or 0
    session.buildsByType = type(snapshot.buildsByType) == "table" and table.clone(snapshot.buildsByType) or {}
    session.unlockedAreas = type(snapshot.unlockedAreas) == "table" and table.clone(snapshot.unlockedAreas) or {}
    session.lastBuildTime = tonumber(snapshot.lastBuildTime)

    -- Ensure all areas for the loaded era are unlocked.
    unlockAreasForEra(session, session.era)

    EraProgression._sessions[playerId] = session
    return true
end

--[[
    Export session data for persistence.
]]
function EraProgression.saveSession(playerId: number): { [string]: any }?
    local session = EraProgression._sessions[playerId]
    if not session then return nil end
    return {
        era = session.era,
        totalBuilds = session.totalBuilds,
        buildsByType = table.clone(session.buildsByType),
        unlockedAreas = table.clone(session.unlockedAreas),
        lastBuildTime = session.lastBuildTime,
    }
end

--[[
    Reset a player's progression.
]]
function EraProgression.resetProgress(playerId: number)
    EraProgression._sessions[playerId] = nil
    EraProgression.getSession(playerId)
    print(string.format("[EraProgression] Reset progress for player %d", playerId))
end

----------------------------------------------------------------
-- BUILD TRACKING
----------------------------------------------------------------

--[[
    Record a completed build for a player.
    Returns the player's current era key.
]]
function EraProgression.recordBuild(playerId: number, buildType: string): string
    local session = EraProgression.getSession(playerId)
    session.totalBuilds += 1
    session.buildsByType[buildType] = (session.buildsByType[buildType] or 0) + 1
    session.lastBuildTime = os.time()
    return session.era
end

--[[
    Legacy alias used by the post-build pipeline in init.lua.
]]
function EraProgression.onBuild(playerName: string, buildType: string)
    local player = getPlayerByName(playerName)
    if not player then return end
    EraProgression.recordBuild(player.UserId, buildType)
end

--[[
    Alias kept for compatibility with the previous EraSystem API.
]]
function EraProgression.onBuildingEraBuild(playerName: string, buildType: string)
    EraProgression.onBuild(playerName, buildType)
end

----------------------------------------------------------------
-- ERA QUERIES
----------------------------------------------------------------

--[[
    Get a player's current era key.
]]
function EraProgression.getBuildingEra(playerName: string): string
    local player = getPlayerByName(playerName)
    if not player then return "driftwood" end
    return EraProgression.getSession(player.UserId).era
end

--[[
    Get a player's current era as an index (1-5).
]]
function EraProgression.getEraIndex(playerName: string): number
    local key = EraProgression.getBuildingEra(playerName)
    local data = ERA_DATA[key]
    return data and data.index or 1
end

--[[
    Get full info table for an era key.
]]
function EraProgression.getBuildingEraInfo(eraKey: string): { [string]: any }?
    local data = ERA_DATA[eraKey]
    if not data then return nil end
    -- Return a shallow clone so callers cannot mutate the canonical data.
    local copy = table.clone(data)
    copy.color = data.color
    return copy
end

--[[
    Get all era definitions.
]]
function EraProgression.getAllEraInfo(): { [string]: EraDefinition }
    return table.clone(ERA_DATA)
end

--[[
    Manually set a player's era (admin / debug / cheat).
]]
function EraProgression.setEra(playerName: string, eraKey: string): boolean
    local player = getPlayerByName(playerName)
    if not player then return false end
    local data = ERA_DATA[eraKey]
    if not data then
        warn(string.format("[EraProgression] Cannot set invalid era '%s'", eraKey))
        return false
    end
    local session = EraProgression.getSession(player.UserId)
    session.era = eraKey
    session.eraChangedThisSession = true
    unlockAreasForEra(session, eraKey)
    return true
end

----------------------------------------------------------------
-- ADVANCEMENT
----------------------------------------------------------------

--[[
    Check whether a player has met the threshold to advance.
    Returns true if advancement is possible.
]]
function EraProgression.checkBuildingEraAdvancement(playerName: string): boolean
    local player = getPlayerByName(playerName)
    if not player then return false end
    local session = EraProgression.getSession(player.UserId)
    local currentData = ERA_DATA[session.era]
    if not currentData then return false end
    local nextIndex = currentData.index + 1
    local nextEra = EraProgression.ERAS[nextIndex]
    if not nextEra then return false end
    local nextData = ERA_DATA[nextEra]
    if not nextData then return false end
    return session.totalBuilds >= nextData.requiredBuilds
end

--[[
    Advance a player to the next era if eligible.
    Returns the new era key, or nil if not advanced.
]]
function EraProgression.advanceBuildingEra(playerName: string): string?
    local player = getPlayerByName(playerName)
    if not player then return nil end
    if not EraProgression.checkBuildingEraAdvancement(playerName) then
        return nil
    end
    local session = EraProgression.getSession(player.UserId)
    local currentData = ERA_DATA[session.era]
    local nextIndex = (currentData and currentData.index or 0) + 1
    local nextEra = EraProgression.ERAS[nextIndex]
    if not nextEra then return nil end

    session.era = nextEra
    session.eraChangedThisSession = true
    unlockAreasForEra(session, nextEra)

    print(string.format("[EraProgression] %s advanced to era '%s'", playerName, nextEra))
    return nextEra
end

--[[
    Get progress toward the next era.
]]
function EraProgression.getProgress(playerName: string): { [string]: any }?
    local player = getPlayerByName(playerName)
    if not player then return nil end
    local session = EraProgression.getSession(player.UserId)
    local currentData = ERA_DATA[session.era]
    local nextIndex = currentData and currentData.index + 1 or nil
    local nextEra = nextIndex and EraProgression.ERAS[nextIndex]
    local nextData = nextEra and ERA_DATA[nextEra]

    return {
        era = session.era,
        eraName = currentData and currentData.name,
        totalBuilds = session.totalBuilds,
        nextEra = nextEra,
        nextEraName = nextData and nextData.name,
        requiredBuilds = nextData and nextData.requiredBuilds or 0,
        buildsRemaining = nextData and math.max(0, nextData.requiredBuilds - session.totalBuilds) or 0,
        canAdvance = EraProgression.checkBuildingEraAdvancement(playerName),
    }
end

----------------------------------------------------------------
-- UNLOCK QUERIES
----------------------------------------------------------------

--[[
    Check if a material is unlocked for a player.
]]
function EraProgression.isMaterialUnlocked(playerName: string, material: string): boolean
    local player = getPlayerByName(playerName)
    if not player then return false end
    local session = EraProgression.getSession(player.UserId)
    local data = ERA_DATA[session.era]
    if not data then return false end
    for _, m in ipairs(data.materials) do
        if m == material then return true end
    end
    return false
end

--[[
    Check if a build command is unlocked for a player.
]]
function EraProgression.isCommandUnlocked(playerName: string, command: string): boolean
    local player = getPlayerByName(playerName)
    if not player then return false end
    local session = EraProgression.getSession(player.UserId)
    local data = ERA_DATA[session.era]
    if not data then return false end
    for _, c in ipairs(data.commands) do
        if c == command then return true end
    end
    return false
end

--[[
    Check if an island area is unlocked for a player.
]]
function EraProgression.isAreaUnlocked(playerName: string, area: string): boolean
    local player = getPlayerByName(playerName)
    if not player then return false end
    local session = EraProgression.getSession(player.UserId)
    return session.unlockedAreas[area] == true
end

--[[
    Get all unlocked materials for a player.
]]
function EraProgression.getUnlockedMaterials(playerName: string): { string }
    local player = getPlayerByName(playerName)
    if not player then return {} end
    local session = EraProgression.getSession(player.UserId)
    local data = ERA_DATA[session.era]
    return data and table.clone(data.materials) or {}
end

--[[
    Get all unlocked build commands for a player.
]]
function EraProgression.getUnlockedCommands(playerName: string): { string }
    local player = getPlayerByName(playerName)
    if not player then return {} end
    local session = EraProgression.getSession(player.UserId)
    local data = ERA_DATA[session.era]
    return data and table.clone(data.commands) or {}
end

--[[
    Get all unlocked island areas for a player.
]]
function EraProgression.getUnlockedAreas(playerName: string): { string }
    local player = getPlayerByName(playerName)
    if not player then return {} end
    local session = EraProgression.getSession(player.UserId)
    local areas = {}
    for area, unlocked in pairs(session.unlockedAreas) do
        if unlocked then table.insert(areas, area) end
    end
    return areas
end

--[[
    Get the resource cost to unlock an era from scratch.
    Useful for UI and economy integration.
]]
function EraProgression.getEraCost(eraKey: string): { [string]: number }?
    local data = ERA_DATA[eraKey]
    if not data then return nil end
    return table.clone(data.cost)
end

----------------------------------------------------------------
-- RETURN
----------------------------------------------------------------

return EraProgression
