--[[
    WorldGenerator/Config.lua
    Slackwater — World Generation Configuration

    Defines game-mode presets, biome parameters, resource tables,
    noise constants, and all tunable values used by the terrain
    generator, resource distributor, and tide system.

    Usage:
        local Config = require(script.Parent.Config)
        local preset = Config.GetMode("single")
]]

local Config = {}

--==========================================================================
-- GAME MODE PRESETS
--==========================================================================

Config.modes = {
    single = {
        size = 400,
        biomes = "all",
        resources = "rich",
        tideSpeed = 1.0,
        allErasUnlocked = false,
        mentorMode = false,
    },
    multiplayer = {
        size = 800,
        biomes = "all",
        resources = "normal",
        tideSpeed = 1.5,
        allErasUnlocked = false,
        mentorMode = false,
    },
    coop_novice_expert = {
        size = 600,
        biomes = "all",
        resources = "rich",
        tideSpeed = 0.8,
        allErasUnlocked = false,
        mentorMode = true,
    },
    creative = {
        size = 1000,
        biomes = "all",
        resources = "infinite",
        tideSpeed = 0,
        allErasUnlocked = true,
        mentorMode = false,
    },
}

--==========================================================================
-- TERRAIN NOISE PARAMETERS
--==========================================================================

Config.noise = {
    -- Base elevation octave
    elevation = {
        scale = 0.012,   -- frequency: lower = smoother hills
        amplitude = 1.0, -- height multiplier
        octaves = 4,
        persistence = 0.5,
        lacunarity = 2.0,
        seedOffset = 0,
    },
    -- Mountain detail
    mountain = {
        scale = 0.008,
        amplitude = 1.5,
        octaves = 5,
        persistence = 0.55,
        lacunarity = 2.1,
        seedOffset = 1000,
        ridgePower = 1.8, -- ridged noise for sharp peaks
    },
    -- Temperature layer (determines biome classification)
    temperature = {
        scale = 0.004,
        amplitude = 1.0,
        octaves = 2,
        persistence = 0.5,
        lacunarity = 2.0,
        seedOffset = 2000,
    },
    -- Humidity / moisture layer
    humidity = {
        scale = 0.005,
        amplitude = 1.0,
        octaves = 2,
        persistence = 0.5,
        lacunarity = 2.0,
        seedOffset = 3000,
    },
    -- River carving
    river = {
        scale = 0.01,
        amplitude = 1.0,
        octaves = 2,
        persistence = 0.5,
        lacunarity = 2.0,
        seedOffset = 4000,
        depth = 12,      -- how deep rivers carve below terrain
        threshold = 0.06, -- how narrow / frequent rivers are (lower = fewer rivers)
    },
    -- General
    waterLevel = 0,      -- base sea level (studs, relative)
    baseHeight = 20,     -- base ground height above 0
    islandFalloff = 0.85,-- 0..1 — how aggressively terrain falls into ocean at edges
}

--==========================================================================
-- BIOME DEFINITIONS
--==========================================================================

-- Biome thresholds on temperature (T) and humidity (H), both normalised ~[-1, 1].
-- The first matching rule (checked top-to-bottom) wins.

Config.biomes = {
    coastline = {
        id = "coastline",
        color = { 194, 178, 128 },       -- sandy
        terrainMaterial = Enum.Material.Sand,
        maxElevation = 8,                 -- studs above water level
        rule = function(t, h)
            return true -- fallback; coastline is the default low-elevation biome
        end,
        resourceMultiplier = 1.2,
    },
    forest = {
        id = "forest",
        color = { 34, 89, 46 },
        terrainMaterial = Enum.Material.Grass,
        rule = function(t, h)
            return h > 0.0 and t > -0.3 and t < 0.5
        end,
        resourceMultiplier = 1.0,
    },
    mountains = {
        id = "mountains",
        color = { 120, 113, 108 },
        terrainMaterial = Enum.Material.Rock,
        rule = function(t, h)
            return true -- fallback for high elevation (handled separately)
        end,
        resourceMultiplier = 0.8,
    },
    plains = {
        id = "plains",
        color = { 96, 128, 56 },
        terrainMaterial = Enum.Material.Grass,
        rule = function(t, h)
            return h <= 0.0 and t > -0.3
        end,
        resourceMultiplier = 0.9,
    },
    wetlands = {
        id = "wetlands",
        color = { 52, 71, 61 },
        terrainMaterial = Enum.Material.Ground,
        rule = function(t, h)
            return h > 0.4 and t <= -0.1
        end,
        resourceMultiplier = 1.1,
    },
    underground = {
        id = "underground",
        color = { 50, 45, 41 },
        terrainMaterial = Enum.Material.Slate,
        rule = function(t, h)
            return false -- underground is carved below surface, not selected by T/H
        end,
        resourceMultiplier = 1.0,
    },
}

-- Biome evaluation order for surface biomes.
-- Coastline is assigned by low elevation; Mountains by high elevation.
-- Forest / Plains / Wetlands are decided by T/H rules.

Config.biomeEvalOrder = {
    "wetlands",
    "forest",
    "plains",
    "coastline", -- fallback
}

-- Elevation thresholds (studs above water level) for elevation-driven biomes
Config.elevation = {
    coastlineMax = 6,    -- below this near water → coastline
    mountainMin = 45,    -- above this → mountains
    undergroundDepth = 25, -- how far below surface underground layer extends
}

--==========================================================================
-- RESOURCE DEFINITIONS (per biome, per era)
--==========================================================================

-- Resource types and their properties.
-- yield = total harvestable units before depletion
-- respawn = seconds to fully respawn (0 = never)
-- tool = minimum era index required to harvest (1-based)

Config.resourceTypes = {
    -- Era 1 resources
    wood = {
        displayName = "Timber",
        era = 1,
        baseYield = 8,
        respawnTime = 180,
        model = "TreeModel",
        color = { 101, 67, 33 },
    },
    stone = {
        displayName = "Stone",
        era = 1,
        baseYield = 12,
        respawnTime = 300,
        model = "RockModel",
        color = { 128, 128, 128 },
    },
    fiber = {
        displayName = "Fiber",
        era = 1,
        baseYield = 6,
        respawnTime = 120,
        model = "BushModel",
        color = { 60, 100, 40 },
    },
    -- Coastline salvage (era 1 but rare materials later)
    salvage = {
        displayName = "Salvage",
        era = 1,
        baseYield = 4,
        respawnTime = 240,
        model = "SalvageModel",
        color = { 140, 120, 80 },
    },
    kelp = {
        displayName = "Kelp",
        era = 1,
        baseYield = 5,
        respawnTime = 150,
        model = "KelpModel",
        color = { 50, 80, 50 },
    },
    shells = {
        displayName = "Shells",
        era = 1,
        baseYield = 3,
        respawnTime = 200,
        model = "ShellModel",
        color = { 240, 230, 210 },
    },
    -- Era 3 resources (minerals / ores)
    copper = {
        displayName = "Copper Ore",
        era = 3,
        baseYield = 10,
        respawnTime = 420,
        model = "OreVeinModel",
        color = { 184, 115, 51 },
    },
    iron = {
        displayName = "Iron Ore",
        era = 3,
        baseYield = 10,
        respawnTime = 420,
        model = "OreVeinModel",
        color = { 100, 95, 90 },
    },
    coal = {
        displayName = "Coal",
        era = 3,
        baseYield = 12,
        respawnTime = 360,
        model = "OreVeinModel",
        color = { 40, 40, 40 },
    },
    -- Wetlands
    peat = {
        displayName = "Peat",
        era = 2,
        baseYield = 8,
        respawnTime = 300,
        model = "PeatModel",
        color = { 80, 60, 40 },
    },
    -- Era 5 resources (rare / advanced)
    silicon = {
        displayName = "Silicon Deposit",
        era = 5,
        baseYield = 6,
        respawnTime = 600,
        model = "CrystalModel",
        color = { 180, 200, 220 },
    },
    rareEarth = {
        displayName = "Rare Earth Elements",
        era = 5,
        baseYield = 4,
        respawnTime = 720,
        model = "CrystalModel",
        color = { 150, 100, 180 },
    },
    gems = {
        displayName = "Gems",
        era = 4,
        baseYield = 3,
        respawnTime = 600,
        model = "GemModel",
        color = { 80, 200, 200 },
    },
    ancientTech = {
        displayName = "Ancient Technology Fragment",
        era = 5,
        baseYield = 1,
        respawnTime = 0, -- never respawns
        model = "RuinModel",
        color = { 200, 180, 100 },
    },
}

-- Which resources spawn in each biome
Config.biomeResources = {
    coastline = { "salvage", "kelp", "shells", "wood" },
    forest = { "wood", "fiber", "stone" },
    mountains = { "stone", "iron", "coal", "copper" },
    plains = { "fiber", "wood" },
    wetlands = { "peat", "kelp", "fiber" },
    underground = { "stone", "iron", "coal", "copper", "silicon", "rareEarth", "gems", "ancientTech" },
}

-- Resource density per biome (nodes per 100x100 studs, before multiplier)
Config.biomeDensity = {
    coastline = 14,
    forest = 22,
    mountains = 16,
    plains = 8,
    wetlands = 12,
    underground = 18,
}

--==========================================================================
-- OCEAN / WATER WORLD
--==========================================================================

Config.ocean = {
    size = 2000,              -- ocean extends 2000 studs in each direction from island
    depth = -200,             -- ocean floor depth
    floorMaterial = "Mud",    -- ocean floor material
    surfaceLevel = 0,         -- water surface Y position (matches tide system)

    -- Navigation hazards
    rocks = {
        count = 40,           -- submerged/partially submerged rocks
        minSize = 3,
        maxSize = 15,
        minDistFromShore = 30,
        maxDistFromShore = 500,
    },

    -- Channels and routes
    channels = {
        main = { width = 80, depth = -15 },  -- shipping channel to cannery dock
        secondary = { width = 40, depth = -8 }, -- fishing grounds access
    },

    -- Fish zones (used by FishingSystem)
    fishZones = {
        kelpBeds = { count = 5, species = {"herring", "cod"}, depth = { min = -5, max = -15 } },
        halibutGrounds = { count = 3, species = {"halibut"}, depth = { min = -30, max = -80 } },
        salmonRun = { count = 2, species = {"salmon"}, depth = { min = 0, max = -10 }, seasonal = true },
        crabGrounds = { count = 4, species = {"crab"}, depth = { min = -5, max = -20 }, nearShore = true },
        openOcean = { species = {"cod", "salmon"}, depth = { min = -20, max = -100 } },
    },
}

--==========================================================================
-- TIDE SYSTEM
--==========================================================================

Config.tide = {
    cycleLength = 20 * 60,   -- seconds for full cycle (20 min default)
    phases = {
        { name = "low",   duration = 0.20, waterOffset = -6 },  -- below baseline
        { name = "rising", duration = 0.30, waterOffset = 0 },   -- rising through baseline
        { name = "high",  duration = 0.20, waterOffset = 6 },   -- above baseline
        { name = "falling", duration = 0.30, waterOffset = 0 },  -- falling through baseline
    },
    stormChance = 0.05,      -- 5% chance per cycle
    stormDamageRadius = 20,  -- studs from shoreline
    stormDamage = 35,        -- damage to structures
    -- Loot that can wash in during high tide
    tideLoot = { "salvage", "kelp", "shells", "wood" },
    tideLootCount = { min = 2, max = 6 },
}

--==========================================================================
-- ERA SCARCITY (resource yield multiplier per current era)
--==========================================================================

-- As players unlock higher eras, basic resources become slightly scarcer
-- to encourage exploration. Key era-locked resources get more common.

Config.eraScarcity = {
    -- index = era number (1..7)
    [1] = { wood = 1.0, stone = 1.0, fiber = 1.0, salvage = 1.2, copper = 0.0, iron = 0.0, coal = 0.0 },
    [2] = { wood = 1.0, stone = 1.0, fiber = 1.0, salvage = 1.0, peat = 1.2, copper = 0.0, iron = 0.0, coal = 0.0 },
    [3] = { wood = 0.9, stone = 0.9, fiber = 0.9, salvage = 0.8, copper = 1.0, iron = 1.0, coal = 1.0, peat = 0.9 },
    [4] = { wood = 0.8, stone = 0.8, fiber = 0.8, salvage = 0.7, copper = 0.9, iron = 0.9, coal = 0.9, gems = 1.0 },
    [5] = { wood = 0.7, stone = 0.7, fiber = 0.7, salvage = 0.6, copper = 0.8, iron = 0.8, coal = 0.8, silicon = 1.0, rareEarth = 1.0, ancientTech = 0.8 },
    [6] = { wood = 0.6, stone = 0.6, fiber = 0.6, salvage = 0.5, silicon = 0.9, rareEarth = 0.9 },
    [7] = { wood = 0.5, stone = 0.5, fiber = 0.5, salvage = 0.4, silicon = 0.8, rareEarth = 0.8, ancientTech = 0.6 },
}

--==========================================================================
-- HELPER FUNCTIONS
--==========================================================================

--- Returns a deep-copied mode preset by name.
--- @param modeName string Key in Config.modes
--- @return table
function Config.GetMode(modeName)
    local mode = Config.modes[modeName]
    if not mode then
        warn("[WorldGenerator.Config] Unknown mode '" .. tostring(modeName) .. "', defaulting to 'single'")
        mode = Config.modes.single
    end
    -- Shallow copy so callers can mutate freely
    local copy = {}
    for k, v in pairs(mode) do
        copy[k] = v
    end
    return copy
end

--- Returns the scarcity multiplier for a resource type at a given era.
--- @param resourceType string
--- @param era number 1..7
--- @return number multiplier (0 means resource does not spawn)
function Config.GetScarcity(resourceType, era)
    local eraTable = Config.eraScarcity[era] or Config.eraScarcity[1]
    local mult = eraTable[resourceType]
    if mult == nil then
        -- If this resource isn't explicitly listed, assume it follows the era pattern
        -- (first appearance era = full, later = slight reduction)
        return 1.0
    end
    return mult
end

--- Returns the list of resource types valid for a biome.
--- @param biomeId string
--- @return table
function Config.GetBiomeResources(biomeId)
    return Config.biomeResources[biomeId] or {}
end

--- Returns biome density (nodes per 100x100 studs).
--- @param biomeId string
--- @return number
function Config.GetBiomeDensity(biomeId)
    return Config.biomeDensity[biomeId] or 10
end

return Config
