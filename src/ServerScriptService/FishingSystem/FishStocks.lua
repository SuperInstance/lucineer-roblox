--!strict
--[[
    FishStocks — Slackwater's Living Ocean
    ═══════════════════════════════════════════════════════════════
    "The ocean isn't a loot table. It's a population. You take
     too much and the bay goes quiet. You give it a season and
     it comes back. That's not game design — that's fishing."

    Simulates dynamic fish populations across multiple species,
    zones, and depth layers. Stocks regenerate over time, deplete
    under fishing pressure, and shift with the seasons.

    SPECIES:
      • Salmon    — migratory, seasonal runs, surface to mid-water
      • Halibut   — bottom-dwelling, slow-moving, high value
      • Herring   — schools, fast-moving, low value but abundant
      • Crab      — pot-caught, near shore, steady supply
      • Cod       — mid-water, schools, moderate value

    ZONES:
      • Bay         — sheltered, near dock, shallow
      • Channel     — Hermes's territory, moderate depth, migratory route
      • OpenOcean   — deep water, far from shore, big fish
      • KelpBeds    — near shore, biologically rich, shallow

    DEPTHS:
      • Surface     — 0-15 ft below waterline
      • MidWater    — 15-60 ft
      • Bottom      — 60+ ft

    SEASONS (based on in-game Lighting.ClockTime day/night cycle
    and a separate seasonal offset tracked internally):
      • Spring — salmon arriving, herring spawning, cod active
      • Summer — halibut peak, crab molting (soft shell = low grade)
      • Fall   — salmon runs peak, cod migrating, best all-around
      • Winter — low stocks across the board, halibut deep

    API:
      FishStocks.init()
      FishStocks.getAbundance(species, zone, depth) -> number (0..1)
      FishStocks.getSpeciesInZone(zone) -> {species, ...}
      FishStocks.reportCatch(species, zone, depth, count)
      FishStocks.tick(dt) — call from a heartbeat loop
      FishStocks.getSeason() -> string
      FishStocks.getSeasonalMultiplier(species) -> number
      FishStocks.getState() -> table (for save/persistence)
      FishStocks.setState(state)
      FishStocks.getZoneAtPosition(position) -> string
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local FishStocks = {}

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

-- How often population dynamics tick (seconds between sim updates).
local TICK_INTERVAL = 5.0

-- Carrying capacity per species per zone (max fish "units").
local CARRYING_CAPACITY = 1000

-- Regeneration rate per tick as fraction of carrying capacity.
local BASE_REGEN_RATE = 0.003  -- 0.3% per tick → ~21% per minute

-- Overfishing threshold: below this fraction of capacity, regen slows.
local OVERFISH_THRESHOLD = 0.25

-- When below overfishing threshold, regen is multiplied by this.
local OVERFISH_REGEN_PENALTY = 0.4

-- Minimum stock level (never quite zero — tiny residual for recovery).
local MIN_STOCK = 5

-- Zone boundaries (defined as center position + radius).
-- These should align with the WorldGenerator's water terrain.
local ZONES = {
    Bay = {
        center = Vector3.new(0, 0, -30),
        radius = 120,
        minDepth = 0,
        maxDepth = 40,
        description = "Sheltered bay near the dock. Shallow, calm.",
    },
    Channel = {
        center = Vector3.new(0, 0, -200),
        radius = 150,
        minDepth = 20,
        maxDepth = 80,
        description = "Hermes's channel. The between-place. Migratory route.",
    },
    OpenOcean = {
        center = Vector3.new(0, 0, -450),
        radius = 300,
        minDepth = 60,
        maxDepth = 200,
        description = "Deep water. Far from shore. Big fish live here.",
    },
    KelpBeds = {
        center = Vector3.new(80, 0, -50),
        radius = 80,
        minDepth = 5,
        maxDepth = 30,
        description = "Biologically rich shallows. Everything comes here to eat.",
    },
}

----------------------------------------------------------------
-- SPECIES DEFINITIONS
----------------------------------------------------------------

local SPECIES = {
    ----------------------------------------------------------------
    Salmon = {
        displayName = "Chum Salmon",
        baseValue = 3.50,           -- per pound, grade A
        avgWeight = 8,              -- pounds
        maxWeight = 15,
        behavior = "migratory",
        depthPreference = { "Surface", "MidWater" },
        zones = { Bay = 0.6, Channel = 1.0, OpenOcean = 0.3, KelpBeds = 0.4 },
        seasonality = {
            spring = 1.2,   -- arriving
            summer = 0.7,
            fall   = 1.8,   -- peak runs
            winter = 0.2,   -- gone
        },
        catchDifficulty = 0.6,  -- 0=easy, 1=hard
        schoolSize = { min = 3, max = 12 },
        description = "Migratory runner. Comes through in fall. Surface to mid-water.",
    },

    ----------------------------------------------------------------
    Halibut = {
        displayName = "Pacific Halibut",
        baseValue = 8.00,
        avgWeight = 25,
        maxWeight = 80,
        behavior = "bottom",
        depthPreference = { "Bottom" },
        zones = { Bay = 0.1, Channel = 0.5, OpenOcean = 1.0, KelpBeds = 0.0 },
        seasonality = {
            spring = 0.8,
            summer = 1.5,   -- peak
            fall   = 1.0,
            winter = 0.4,   -- gone deep
        },
        catchDifficulty = 0.85,
        schoolSize = { min = 1, max = 3 },
        description = "Bottom dweller. Slow, heavy, valuable. Summer peak.",
    },

    ----------------------------------------------------------------
    Herring = {
        displayName = "Pacific Herring",
        baseValue = 0.40,
        avgWeight = 0.3,
        maxWeight = 0.6,
        behavior = "school",
        depthPreference = { "Surface", "MidWater" },
        zones = { Bay = 1.0, Channel = 0.7, OpenOcean = 0.3, KelpBeds = 0.9 },
        seasonality = {
            spring = 1.5,   -- spawning
            summer = 1.0,
            fall   = 0.9,
            winter = 0.6,
        },
        catchDifficulty = 0.1,  -- very easy
        schoolSize = { min = 20, max = 100 },
        description = "Abundant, fast-moving schools. Low value, high volume.",
    },

    ----------------------------------------------------------------
    Crab = {
        displayName = "Dungeness Crab",
        baseValue = 5.00,
        avgWeight = 1.5,
        maxWeight = 3,
        behavior = "pot",
        depthPreference = { "Bottom" },
        zones = { Bay = 1.0, Channel = 0.4, OpenOcean = 0.1, KelpBeds = 0.8 },
        seasonality = {
            spring = 0.7,
            summer = 0.5,   -- molting season, soft shell
            fall   = 1.3,   -- hard shell, good quality
            winter = 1.1,
        },
        catchDifficulty = 0.3,  -- pot-caught, patience not skill
        schoolSize = { min = 1, max = 6 },
        description = "Pot-caught near shore. Steady supply. Soft shell in summer.",
    },

    ----------------------------------------------------------------
    Cod = {
        displayName = "Pacific Cod",
        baseValue = 2.50,
        avgWeight = 5,
        maxWeight = 20,
        behavior = "school",
        depthPreference = { "MidWater" },
        zones = { Bay = 0.3, Channel = 0.8, OpenOcean = 1.0, KelpBeds = 0.2 },
        seasonality = {
            spring = 1.1,
            summer = 0.8,
            fall   = 1.2,   -- migrating, active feeding
            winter = 0.7,
        },
        catchDifficulty = 0.4,
        schoolSize = { min = 5, max = 30 },
        description = "Mid-water schooling fish. Moderate value, steady producer.",
    },
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

FishStocks._initialized = false
FishStocks._tickAccumulator = 0

-- Season system: 1 in-game day cycle through 4 seasons.
-- We track season based on accumulated time. Each season = ~15 min real-time.
-- Full year = 60 minutes. This keeps seasonal play meaningful per session.
local SEASON_DURATION = 900  -- 15 minutes per season
local SEASON_ORDER = { "spring", "summer", "fall", "winter" }

FishStocks._seasonTime = 0
FishStocks._seasonIndex = 1   -- start in spring

--[[
    Stock levels: stock[species][zone] = number (current population units)
    Represents the "biomass" available. Range: MIN_STOCK..CARRYING_CAPACITY
]]
FishStocks._stocks = {}

-- Track recent catch pressure per zone (decays over time).
-- pressure[zone] = number (higher = more fished recently)
FishStocks._pressure = {}

-- Tracks total catches per species for economy tracking.
FishStocks._totalCaught = {}

----------------------------------------------------------------
-- INTERNAL: SEASON MANAGEMENT
----------------------------------------------------------------

local function getCurrentSeason(): string
    return SEASON_ORDER[FishStocks._seasonIndex]
end

local function updateSeason(dt: number)
    FishStocks._seasonTime += dt
    if FishStocks._seasonTime >= SEASON_DURATION then
        FishStocks._seasonTime = 0
        FishStocks._seasonIndex = FishStocks._seasonIndex + 1
        if FishStocks._seasonIndex > #SEASON_ORDER then
            FishStocks._seasonIndex = 1
        end
        local newSeason = getCurrentSeason()
        print("[FishStocks] Season changed to:", newSeason)
        -- Signal other systems
        Workspace:SetAttribute("CurrentSeason", newSeason)
    end
end

----------------------------------------------------------------
-- INTERNAL: STOCK INITIALIZATION
----------------------------------------------------------------

local function initializeStocks()
    for speciesName, _ in pairs(SPECIES) do
        FishStocks._stocks[speciesName] = {}
        FishStocks._totalCaught[speciesName] = 0
        for zoneName, _ in pairs(ZONES) do
            -- Start at ~60-80% of carrying capacity for each species/zone
            local zoneFactor = SPECIES[speciesName].zones[zoneName] or 0
            local initial = CARRYING_CAPACITY * zoneFactor * (0.6 + math.random() * 0.2)
            FishStocks._stocks[speciesName][zoneName] = math.max(MIN_STOCK, initial)
        end
    end

    -- Initialize pressure
    for zoneName, _ in pairs(ZONES) do
        FishStocks._pressure[zoneName] = 0
    end
end

----------------------------------------------------------------
-- INTERNAL: POPULATION DYNAMICS TICK
----------------------------------------------------------------

local function tickPopulations()
    local season = getCurrentSeason()

    for speciesName, speciesData in pairs(SPECIES) do
        local seasonalMult = speciesData.seasonality[season] or 1.0

        for zoneName, zoneData in pairs(ZONES) do
            local zoneFactor = speciesData.zones[zoneName] or 0
            if zoneFactor > 0 then
                local current = FishStocks._stocks[speciesName][zoneName] or MIN_STOCK
                local capacity = CARRYING_CAPACITY * zoneFactor

                -- Logistic growth model: dN/dt = r * N * (1 - N/K)
                -- Simplified to discrete steps
                local fractionOfCapacity = current / capacity

                -- Regeneration rate is boosted by seasonality
                local regenRate = BASE_REGEN_RATE * seasonalMult

                -- Overfishing penalty: below threshold, regen slows significantly
                if fractionOfCapacity < OVERFISH_THRESHOLD then
                    regenRate = regenRate * OVERFISH_REGEN_PENALTY
                end

                -- Logistic growth
                local growth = regenRate * current * (1 - fractionOfCapacity)
                local newStock = current + growth

                -- Natural clamp
                newStock = math.clamp(newStock, MIN_STOCK, capacity)

                FishStocks._stocks[speciesName][zoneName] = newStock
            end
        end
    end

    -- Decay fishing pressure
    for zoneName, _ in pairs(ZONES) do
        FishStocks._pressure[zoneName] = FishStocks._pressure[zoneName] * 0.95
    end
end

----------------------------------------------------------------
-- INTERNAL: ZONE DETECTION
----------------------------------------------------------------

--[[
    Determine which fishing zone a world position falls within.
    @param position Vector3 — world position (typically boat position)
    @return string — zone name, or "OpenOcean" as fallback
]]
local function findZoneAtPosition(position: Vector3): string
    local bestZone = "OpenOcean"
    local bestDist = math.huge

    for zoneName, zoneData in pairs(ZONES) do
        -- Project to XZ plane
        local zoneCenter = Vector3.new(zoneData.center.X, 0, zoneData.center.Z)
        local pos2D = Vector3.new(position.X, 0, position.Z)
        local dist = (pos2D - zoneCenter).Magnitude

        if dist < zoneData.radius and dist < bestDist then
            bestDist = dist
            bestZone = zoneName
        end
    end

    return bestZone
end

----------------------------------------------------------------
-- INTERNAL: DEPTH LAYER DETERMINATION
----------------------------------------------------------------

--[[
    Determine the depth layer based on water depth at a position.
    Uses terrain water height vs. ocean floor. Falls back to
    zone-based defaults if terrain data is unavailable.
    @param position Vector3
    @param zoneName string
    @return string — "Surface", "MidWater", or "Bottom"
]]
local function estimateDepthLayer(position: Vector3, zoneName: string): string
    local zoneData = ZONES[zoneName]
    if not zoneData then return "MidWater" end

    -- Try reading from terrain
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        -- Sample terrain column at position
        local waterY = 0
        local tideAttr = Workspace:GetAttribute("WaterLevel")
        if tideAttr then waterY = tideAttr end

        -- Read terrain to find ocean floor depth
        local raycastParams = RaycastParams.new()
        raycastParams.FilterType = Enum.RaycastFilterType.Exclude
        local result = Workspace:Raycast(
            Vector3.new(position.X, waterY + 5, position.Z),
            Vector3.new(0, -200, 0),
            raycastParams
        )

        if result then
            local depth = waterY - result.Position.Y
            if depth < 15 then return "Surface"
            elseif depth < 60 then return "MidWater"
            else return "Bottom"
            end
        end
    end

    -- Fallback: use zone default depth
    local avgDepth = (zoneData.minDepth + zoneData.maxDepth) / 2
    if avgDepth < 15 then return "Surface"
    elseif avgDepth < 60 then return "MidWater"
    else return "Bottom"
    end
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the fish stock system. Must be called once on server start.
]]
function FishStocks.init()
    if FishStocks._initialized then
        warn("[FishStocks] Already initialized.")
        return
    end

    initializeStocks()
    FishStocks._seasonTime = 0
    FishStocks._seasonIndex = 1
    FishStocks._tickAccumulator = 0

    Workspace:SetAttribute("CurrentSeason", getCurrentSeason())

    FishStocks._initialized = true
    print("[FishStocks] Initialized — 5 species across 4 zones. Season:", getCurrentSeason())
end

--[[
    Get the current season string.
    @return string — "spring", "summer", "fall", or "winter"
]]
function FishStocks.getSeason(): string
    return getCurrentSeason()
end

--[[
    Get the seasonal abundance multiplier for a species.
    @param species string — species name
    @return number — multiplier (0.0 = absent, 1.0 = normal, 2.0 = peak)
]]
function FishStocks.getSeasonalMultiplier(species: string): number
    local speciesData = SPECIES[species]
    if not speciesData then return 1.0 end
    local season = getCurrentSeason()
    return speciesData.seasonality[season] or 1.0
end

--[[
    Get the abundance of a species at a specific zone and depth.
    This is the core query for the HarvestController.
    @param species string — species name
    @param zone string — zone name
    @param depth string? — "Surface", "MidWater", "Bottom" (optional)
    @return number — abundance 0.0 to 1.0
]]
function FishStocks.getAbundance(species: string, zone: string, depth: string?): number
    local speciesData = SPECIES[species]
    if not speciesData then return 0 end

    local zoneFactor = speciesData.zones[zone]
    if not zoneFactor or zoneFactor == 0 then return 0 end

    -- Check depth preference
    if depth then
        local depthMatch = false
        for _, preferredDepth in ipairs(speciesData.depthPreference) do
            if preferredDepth == depth then
                depthMatch = true
                break
            end
        end
        if not depthMatch then
            -- Species doesn't live at this depth — return very low
            return 0.02
        end
    end

    local stock = FishStocks._stocks[species]
    if not stock then return 0 end

    local currentStock = stock[zone] or 0
    local capacity = CARRYING_CAPACITY * zoneFactor
    if capacity <= 0 then return 0 end

    -- Abundance = stock as fraction of capacity, scaled to 0-1
    local abundance = math.clamp(currentStock / capacity, 0, 1)

    return abundance
end

--[[
    Get all species present in a zone (zoneFactor > 0).
    @param zone string — zone name
    @return table — array of species names
]]
function FishStocks.getSpeciesInZone(zone: string): { string }
    local result = {}
    for speciesName, speciesData in pairs(SPECIES) do
        local zoneFactor = speciesData.zones[zone]
        if zoneFactor and zoneFactor > 0 then
            table.insert(result, speciesName)
        end
    end
    return result
end

--[[
    Get the species definition data (weight, value, behavior, etc.)
    @param species string
    @return table?
]]
function FishStocks.getSpeciesData(species: string)
    return SPECIES[species]
end

--[[
    Get all species names.
    @return table — array of species name strings
]]
function FishStocks.getAllSpecies(): { string }
    local result = {}
    for name in pairs(SPECIES) do
        table.insert(result, name)
    end
    return result
end

--[[
    Get zone data.
    @param zone string
    @return table?
]]
function FishStocks.getZoneData(zone: string)
    return ZONES[zone]
end

--[[
    Get all zone names.
    @return table — array of zone name strings
]]
function FishStocks.getAllZones(): { string }
    local result = {}
    for name in pairs(ZONES) do
        table.insert(result, name)
    end
    return result
end

--[[
    Report a catch (or multiple catches) to deplete the stock.
    Called by HarvestController when fish are caught.
    @param species string
    @param zone string
    @param depth string?
    @param count number — number of fish caught
]]
function FishStocks.reportCatch(species: string, zone: string, depth: string?, count: number)
    local stock = FishStocks._stocks[species]
    if not stock then return end

    local current = stock[zone] or MIN_STOCK

    -- Each fish reduces stock by its relative weight.
    -- We use a simplified model: each catch removes ~1 unit per avgWeight/10.
    local speciesData = SPECIES[species]
    local removalPerFish = math.max(1, (speciesData.avgWeight / 10))
    local totalRemoval = removalPerFish * count

    local newStock = math.max(MIN_STOCK, current - totalRemoval)
    stock[zone] = newStock

    -- Increase pressure on this zone
    FishStocks._pressure[zone] = (FishStocks._pressure[zone] or 0) + totalRemoval

    -- Track total caught
    FishStocks._totalCaught[species] = (FishStocks._totalCaught[species] or 0) + count
end

--[[
    Get the current stock level for a species in a zone.
    @param species string
    @param zone string
    @return number — raw stock units
]]
function FishStocks.getStockLevel(species: string, zone: string): number
    local stock = FishStocks._stocks[species]
    if not stock then return 0 end
    return stock[zone] or 0
end

--[[
    Get fishing pressure on a zone (0 = unfished, higher = heavily fished).
    @param zone string
    @return number
]]
function FishStocks.getPressure(zone: string): number
    return FishStocks._pressure[zone] or 0
end

--[[
    Get total caught for a species (all-time this session).
    @param species string
    @return number
]]
function FishStocks.getTotalCaught(species: string): number
    return FishStocks._totalCaught[species] or 0
end

--[[
    Determine zone from a world position.
    @param position Vector3
    @return string — zone name
]]
function FishStocks.getZoneAtPosition(position: Vector3): string
    return findZoneAtPosition(position)
end

--[[
    Determine depth layer from a world position.
    @param position Vector3
    @param zoneName string? — optional pre-computed zone
    @return string — "Surface", "MidWater", or "Bottom"
]]
function FishStocks.getDepthAtPosition(position: Vector3, zoneName: string?): string
    local zone = zoneName or findZoneAtPosition(position)
    return estimateDepthLayer(position, zone)
end

----------------------------------------------------------------
-- TICK — Call from a Heartbeat/Stepped loop
----------------------------------------------------------------

--[[
    Advance the fish stock simulation. Call with delta time.
    @param dt number — seconds since last tick
]]
function FishStocks.tick(dt: number)
    if not FishStocks._initialized then return end

    updateSeason(dt)

    FishStocks._tickAccumulator += dt
    if FishStocks._tickAccumulator >= TICK_INTERVAL then
        FishStocks._tickAccumulator = 0
        tickPopulations()
    end
end

----------------------------------------------------------------
-- SERIALIZATION
----------------------------------------------------------------

--[[
    Get the full state for persistence.
    @return table
]]
function FishStocks.getState(): { [string]: any }
    return {
        stocks = FishStocks._stocks,
        pressure = FishStocks._pressure,
        totalCaught = FishStocks._totalCaught,
        seasonTime = FishStocks._seasonTime,
        seasonIndex = FishStocks._seasonIndex,
        tickAccumulator = FishStocks._tickAccumulator,
    }
end

--[[
    Restore state from saved data.
    @param state table
]]
function FishStocks.setState(state: { [string]: any })
    if not state then return end
    FishStocks._stocks = state.stocks or FishStocks._stocks
    FishStocks._pressure = state.pressure or FishStocks._pressure
    FishStocks._totalCaught = state.totalCaught or FishStocks._totalCaught
    FishStocks._seasonTime = state.seasonTime or 0
    FishStocks._seasonIndex = state.seasonIndex or 1
    FishStocks._tickAccumulator = state.tickAccumulator or 0

    -- Ensure all species/zones exist (for migration safety)
    for speciesName in pairs(SPECIES) do
        if not FishStocks._stocks[speciesName] then
            FishStocks._stocks[speciesName] = {}
            for zoneName in pairs(ZONES) do
                FishStocks._stocks[speciesName][zoneName] = MIN_STOCK
            end
        end
    end

    Workspace:SetAttribute("CurrentSeason", getCurrentSeason())
end

----------------------------------------------------------------
-- DEBUG / INSPECTION
----------------------------------------------------------------

--[[
    Get a formatted stock report for debugging/UI.
    @return string
]]
function FishStocks.getStockReport(): string
    local season = getCurrentSeason()
    local lines = {
        string.format("=== Fish Stock Report [%s season] ===", season),
    }

    for speciesName, speciesData in pairs(SPECIES) do
        table.insert(lines, string.format("\n%s (%s):", speciesData.displayName, speciesName))
        for zoneName in pairs(ZONES) do
            local abundance = FishStocks.getAbundance(speciesName, zoneName)
            local zoneFactor = speciesData.zones[zoneName] or 0
            if zoneFactor > 0 then
                local bar = string.rep("█", math.floor(abundance * 20))
                table.insert(lines, string.format("  %-12s %s %.0f%%", zoneName, bar, abundance * 100))
            end
        end
    end

    return table.concat(lines, "\n")
end

return FishStocks
