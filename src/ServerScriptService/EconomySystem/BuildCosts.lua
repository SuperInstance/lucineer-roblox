--!strict
--[[
    BuildCosts — Material Costs for Construction
    ============================================
    Defines and validates material costs for every structure type.

    Build tiers map to the Building Era system:
        Small  (tower, wall, fence):         5–10 wood/stone
        Medium (dock, shed, workshop):       15–30 wood + 5 metal
        Large  (warehouse, lighthouse):      50+ mixed materials
        Vessel upgrades:                     significant investment (handled by VesselUpgrades)

    When a player can't afford a build, Lucineier says:
        "I need more [material]."

    Dependencies:
        - ServerScriptService.EconomySystem.Currency
        - ServerScriptService.EraSystem (for era-appropriate materials)
]]

-- ═══════════════════════════════════════════════════════════════════════════
-- BUILD COST CATALOG
-- Each entry: { scrap=N, materials={ wood=N, metal=N, ... }, influence=N? }
-- Costs are balanced so that early game is accessible and late game
-- requires sustained engagement with both fishing AND building.
-- ═══════════════════════════════════════════════════════════════════════════

local BUILD_COSTS: { [string]: { [string]: any } } = {
    -- ═══════════════════════════════════════════════════════════════
    -- ERA 1: DRIFTWOOD AND SALVAGE (small builds, cheap)
    -- ═══════════════════════════════════════════════════════════════

    -- Small builds: 5-10 wood/stone
    lean_to = {
        tier = "small", era = 1,
        scrap = 10, materials = { wood = 5 },
    },
    debris_hut = {
        tier = "small", era = 1,
        scrap = 15, materials = { wood = 8, cloth = 2 },
    },
    tideline_fence = {
        tier = "small", era = 1,
        scrap = 8, materials = { wood = 5, stone = 2 },
    },
    salvage_rack = {
        tier = "small", era = 1,
        scrap = 5, materials = { wood = 3, metal = 1 },
    },
    fire_pit = {
        tier = "small", era = 1,
        scrap = 5, materials = { stone = 8 },
    },
    driftwood_platform = {
        tier = "small", era = 1,
        scrap = 12, materials = { wood = 7 },
    },
    workbench_scrap = {
        tier = "small", era = 1,
        scrap = 10, materials = { wood = 5, metal = 2 },
    },

    -- ═══════════════════════════════════════════════════════════════
    -- ERA 2: FRAME AND PLANK (medium builds, moderate cost)
    -- ═══════════════════════════════════════════════════════════════

    -- Medium builds: 15-30 wood + 5 metal
    post_and_beam = {
        tier = "medium", era = 2,
        scrap = 25, materials = { wood = 15, metal = 3 },
    },
    plank_wall = {
        tier = "medium", era = 2,
        scrap = 20, materials = { wood = 12 },
    },
    shingled_roof = {
        tier = "medium", era = 2,
        scrap = 20, materials = { wood = 15, cloth = 2 },
    },
    framed_floor = {
        tier = "medium", era = 2,
        scrap = 25, materials = { wood = 18 },
    },
    framed_workshop = {
        tier = "medium", era = 2,
        scrap = 50, materials = { wood = 25, metal = 5 },
    },
    storehouse = {
        tier = "medium", era = 2,
        scrap = 40, materials = { wood = 20, stone = 5 },
    },
    pier_jetty = {
        tier = "medium", era = 2,
        scrap = 35, materials = { wood = 20, stone = 8, metal = 3 },
    },
    saw_pit = {
        tier = "medium", era = 2,
        scrap = 20, materials = { wood = 15, metal = 2 },
    },
    crane_post = {
        tier = "medium", era = 2,
        scrap = 30, materials = { wood = 15, metal = 5 },
    },

    -- ═══════════════════════════════════════════════════════════════
    -- ERA 3: STONE AND MORTAR (large builds, expensive)
    -- ═══════════════════════════════════════════════════════════════

    -- Large builds: 50+ mixed
    stone_foundation = {
        tier = "large", era = 3,
        scrap = 50, materials = { stone = 30 },
    },
    stone_wall = {
        tier = "large", era = 3,
        scrap = 60, materials = { stone = 25, wood = 5 },
    },
    brick_wall = {
        tier = "large", era = 3,
        scrap = 55, materials = { stone = 20, metal = 3 },
    },
    arch_stone = {
        tier = "large", era = 3,
        scrap = 80, materials = { stone = 35, wood = 5 },
    },
    stone_tower = {
        tier = "large", era = 3,
        scrap = 150, materials = { stone = 50, wood = 10, metal = 5 },
    },
    vaulted_ceiling = {
        tier = "large", era = 3,
        scrap = 100, materials = { stone = 40, wood = 10 },
    },
    tiled_roof = {
        tier = "large", era = 3,
        scrap = 60, materials = { stone = 20, wood = 10, cloth = 2 },
    },
    lime_kiln = {
        tier = "large", era = 3,
        scrap = 90, materials = { stone = 30, metal = 5, wood = 10 },
    },
    forge_hearth = {
        tier = "large", era = 3,
        scrap = 120, materials = { stone = 30, metal = 10, wood = 5 },
    },
    bridge_stone = {
        tier = "large", era = 3,
        scrap = 110, materials = { stone = 40, wood = 10, metal = 5 },
    },
    root_cellar = {
        tier = "medium", era = 3,
        scrap = 40, materials = { stone = 15, wood = 10 },
    },
    cistern = {
        tier = "large", era = 3,
        scrap = 80, materials = { stone = 25, metal = 3 },
    },

    -- ═══════════════════════════════════════════════════════════════
    -- ERA 4: METAL AND MACHINE (industrial scale)
    -- ═══════════════════════════════════════════════════════════════

    iron_frame = {
        tier = "large", era = 4,
        scrap = 200, materials = { metal = 30, wood = 10 },
    },
    steel_wall = {
        tier = "large", era = 4,
        scrap = 250, materials = { metal = 35, stone = 10 },
    },
    boiler_house = {
        tier = "large", era = 4,
        scrap = 400, materials = { metal = 50, copper = 10, stone = 15 },
    },
    engine_house = {
        tier = "large", era = 4,
        scrap = 350, materials = { metal = 40, copper = 8, wood = 10 },
    },
    line_shaft_system = {
        tier = "large", era = 4,
        scrap = 300, materials = { metal = 35, wood = 15 },
    },
    powered_hammer = {
        tier = "large", era = 4,
        scrap = 250, materials = { metal = 30, stone = 10 },
    },
    powered_crane = {
        tier = "large", era = 4,
        scrap = 280, materials = { metal = 25, wood = 10, copper = 3 },
    },
    pumping_station = {
        tier = "large", era = 4,
        scrap = 220, materials = { metal = 20, copper = 5, stone = 10 },
    },
    workshop_industrial = {
        tier = "large", era = 4,
        scrap = 500, materials = { metal = 50, wood = 20, stone = 15, copper = 5 },
    },

    -- ═══════════════════════════════════════════════════════════════
    -- ERA 5: LIGHT AND SIGNAL (restoration, premium)
    -- ═══════════════════════════════════════════════════════════════

    wire_run = {
        tier = "medium", era = 5,
        scrap = 150, materials = { copper = 10, metal = 3 },
    },
    lamp_post = {
        tier = "small", era = 5,
        scrap = 80, materials = { metal = 5, glass = 3, copper = 2 },
    },
    switch_box = {
        tier = "medium", era = 5,
        scrap = 120, materials = { metal = 5, copper = 5 },
    },
    generator_house = {
        tier = "large", era = 5,
        scrap = 600, materials = { metal = 30, copper = 15, stone = 10 },
    },
    battery_bank = {
        tier = "large", era = 5,
        scrap = 500, materials = { metal = 20, copper = 10, glass = 5 },
    },
    lighthouse_restored = {
        tier = "large", era = 5,
        scrap = 2000, materials = { stone = 80, metal = 30, copper = 20, glass = 30, wood = 15 },
        influence = 10,
    },
    telegraph_station = {
        tier = "large", era = 5,
        scrap = 800, materials = { metal = 20, copper = 15, wood = 10, glass = 5 },
    },
    signal_tower = {
        tier = "large", era = 5,
        scrap = 700, materials = { metal = 25, wood = 10, copper = 10, glass = 5 },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- LUCINEIER INSUFFICIENT MATERIAL LINES
-- ═══════════════════════════════════════════════════════════════════════════

local INSUFFICIENT_LINES = {
    scrap = "I need more scrap. Can't build for free — not even for you.",
    wood = "I need more wood. Bring me stock and we'll get this up.",
    metal = "I need more metal. Stock, not salvage-bent.",
    cloth = "I need more cloth. Heavy weave, not the beach-torn stuff.",
    glass = "I need more glass. Fog glass works. Pane glass is better.",
    copper = "I need more copper. Wire, sheet, pipe — I'll take any of it.",
    stone = "I need more stone. Cut block, not field rubble.",
    influence = "This needs more than materials. You need standing on this island. Do work people remember.",
}

local GENERIC_INSUFFICIENT = "I need more materials. Bring me stock and we'll talk."

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

local Currency
local initialized = false

local BuildCosts = {}

--[[
    Bind the Currency subsystem.
    @param currencyModule table
]]
function BuildCosts.bindCurrency(currencyModule)
    Currency = currencyModule
end

--[[
    Initialize the system.
]]
function BuildCosts.init()
    if initialized then return end
    initialized = true
    print(string.format("[BuildCosts] Initialized — %d build types costed", 0))
    local count = 0
    for _ in pairs(BUILD_COSTS) do count = count + 1 end
    print(string.format("[BuildCosts] %d build types in catalog", count))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COST QUERIES
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get the cost for a specific build type.
    @param buildType string — key into BUILD_COSTS
    @return table? — cost table or nil if unknown
]]
function BuildCosts.getCost(buildType: string): { [string]: any }?
    local cost = BUILD_COSTS[buildType]
    if not cost then return nil end
    -- Return a copy so caller can't mutate the catalog
    local copy = {
        scrap = cost.scrap or 0,
        materials = {},
    }
    for mat, amount in pairs(cost.materials or {}) do
        copy.materials[mat] = amount
    end
    if cost.influence then
        copy.influence = cost.influence
    end
    return copy
end

--[[
    Get all build types available in a specific era.
    @param era number — building era (1-5)
    @return table — array of build type strings
]]
function BuildCosts.getBuildsForEra(era: number): { [string]: any }
    local result = {}
    for buildType, cost in pairs(BUILD_COSTS) do
        if cost.era == era then
            table.insert(result, buildType)
        end
    end
    return result
end

--[[
    Get all build types of a specific tier.
    @param tier string — "small", "medium", "large"
    @return table
]]
function BuildCosts.getBuildsByTier(tier: string): { [string]: any }
    local result = {}
    for buildType, cost in pairs(BUILD_COSTS) do
        if cost.tier == tier then
            table.insert(result, buildType)
        end
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- VALIDATION & CHARGING
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Check if a player can afford a specific build type.
    @param playerName string
    @param buildType string
    @return boolean, string? — canAfford, missing currency name if not
]]
function BuildCosts.canAffordBuild(playerName: string, buildType: string): (boolean, string?)
    local cost = BuildCosts.getCost(buildType)
    if not cost then
        return false, "unknown_build"
    end
    if not Currency then
        return true  -- no currency system, allow everything (testing mode)
    end
    return Currency.validateCost(playerName, cost)
end

--[[
    Check if a player can afford a raw cost table.
    @param playerName string
    @param cost table — { scrap=N, materials={...}, influence=N }
    @return boolean, string?
]]
function BuildCosts.canAfford(playerName: string, cost: { [string]: any }): (boolean, string?)
    if not Currency then return true end
    return Currency.validateCost(playerName, cost)
end

--[[
    Charge a player for a build. Validates first; nothing charged if invalid.
    @param playerName string
    @param cost table — { scrap=N, materials={...}, influence=N }
    @param reason string?
    @return boolean, string?
]]
function BuildCosts.charge(playerName: string, cost: { [string]: any }, reason: string?): (boolean, string?)
    if not Currency then return true end
    return Currency.chargeCost(playerName, cost, reason or "build")
end

--[[
    Charge a player for a specific build type.
    @param playerName string
    @param buildType string
    @return boolean, string? — success, reason if failed
]]
function BuildCosts.chargeBuild(playerName: string, buildType: string): (boolean, string?)
    local cost = BuildCosts.getCost(buildType)
    if not cost then
        return false, "unknown_build"
    end
    return BuildCosts.charge(playerName, cost, "build_" .. buildType)
end

--[[
    Get the Lucineier line for when a player can't afford something.
    @param missingMaterial string? — the missing currency name
    @return string
]]
function BuildCosts.getInsufficientLine(missingMaterial: string?): string
    if missingMaterial and INSUFFICIENT_LINES[missingMaterial] then
        return INSUFFICIENT_LINES[missingMaterial]
    end
    return GENERIC_INSUFFICIENT
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COST SUMMARIES (for UI/Lucineier dialogue)
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get a human-readable cost summary.
    @param buildType string
    @return string — e.g. "150 scrap, 30 stone, 10 wood, 5 metal"
]]
function BuildCosts.getCostSummary(buildType: string): string
    local cost = BuildCosts.getCost(buildType)
    if not cost then return "Unknown build type" end

    local parts = {}
    if cost.scrap and cost.scrap > 0 then
        table.insert(parts, cost.scrap .. " scrap")
    end
    if cost.materials then
        -- Sort materials alphabetically for consistent output
        local matNames = {}
        for mat in pairs(cost.materials) do
            table.insert(matNames, mat)
        end
        table.sort(matNames)
        for _, mat in ipairs(matNames) do
            table.insert(parts, cost.materials[mat] .. " " .. mat)
        end
    end
    if cost.influence and cost.influence > 0 then
        table.insert(parts, cost.influence .. " influence")
    end

    return table.concat(parts, ", ")
end

--[[
    Get the full build costs catalog (for external reference).
    @return table
]]
function BuildCosts.getCatalog(): { [string]: any }
    return BUILD_COSTS
end

print("[BuildCosts] Module loaded — construction cost catalog")

return BuildCosts
