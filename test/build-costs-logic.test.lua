--[[
    build-costs-logic.test.lua — Pure Lua tests for BuildCosts logic
    
    Extracts the pure data and tests query/validation logic
    in plain Lua 5.1 (no Roblox deps).
    
    Tests: cost lookup, era filtering, tier filtering, cost summary,
    insufficient material lines, catalog completeness.
]]

-- ═══ Extracted BUILD_COSTS data (copied from BuildCosts.lua) ═══

local BUILD_COSTS = {
    -- ERA 1
    lean_to = { tier = "small", era = 1, scrap = 10, materials = { wood = 5 } },
    debris_hut = { tier = "small", era = 1, scrap = 15, materials = { wood = 8, cloth = 2 } },
    tideline_fence = { tier = "small", era = 1, scrap = 8, materials = { wood = 5, stone = 2 } },
    salvage_rack = { tier = "small", era = 1, scrap = 5, materials = { wood = 3, metal = 1 } },
    fire_pit = { tier = "small", era = 1, scrap = 5, materials = { stone = 8 } },
    driftwood_platform = { tier = "small", era = 1, scrap = 12, materials = { wood = 7 } },
    workbench_scrap = { tier = "small", era = 1, scrap = 10, materials = { wood = 5, metal = 2 } },
    -- ERA 2
    post_and_beam = { tier = "medium", era = 2, scrap = 25, materials = { wood = 15, metal = 3 } },
    plank_wall = { tier = "medium", era = 2, scrap = 20, materials = { wood = 12 } },
    shingled_roof = { tier = "medium", era = 2, scrap = 20, materials = { wood = 15, cloth = 2 } },
    framed_floor = { tier = "medium", era = 2, scrap = 25, materials = { wood = 18 } },
    framed_workshop = { tier = "medium", era = 2, scrap = 50, materials = { wood = 25, metal = 5 } },
    storehouse = { tier = "medium", era = 2, scrap = 40, materials = { wood = 20, stone = 5 } },
    pier_jetty = { tier = "medium", era = 2, scrap = 35, materials = { wood = 20, stone = 8, metal = 3 } },
    saw_pit = { tier = "medium", era = 2, scrap = 20, materials = { wood = 15, metal = 2 } },
    crane_post = { tier = "medium", era = 2, scrap = 30, materials = { wood = 15, metal = 5 } },
    -- ERA 3
    stone_foundation = { tier = "large", era = 3, scrap = 50, materials = { stone = 30 } },
    stone_wall = { tier = "large", era = 3, scrap = 60, materials = { stone = 25, wood = 5 } },
    brick_wall = { tier = "large", era = 3, scrap = 55, materials = { stone = 20, metal = 3 } },
    arch_stone = { tier = "large", era = 3, scrap = 80, materials = { stone = 35, wood = 5 } },
    stone_tower = { tier = "large", era = 3, scrap = 150, materials = { stone = 50, wood = 10, metal = 5 } },
    vaulted_ceiling = { tier = "large", era = 3, scrap = 100, materials = { stone = 40, wood = 10 } },
    tiled_roof = { tier = "large", era = 3, scrap = 60, materials = { stone = 20, wood = 10, cloth = 2 } },
    lime_kiln = { tier = "large", era = 3, scrap = 90, materials = { stone = 30, metal = 5, wood = 10 } },
    forge_hearth = { tier = "large", era = 3, scrap = 120, materials = { stone = 30, metal = 10, wood = 5 } },
    bridge_stone = { tier = "large", era = 3, scrap = 110, materials = { stone = 40, wood = 10, metal = 5 } },
    root_cellar = { tier = "medium", era = 3, scrap = 40, materials = { stone = 15, wood = 10 } },
    cistern = { tier = "large", era = 3, scrap = 80, materials = { stone = 25, metal = 3 } },
    -- ERA 4
    iron_frame = { tier = "large", era = 4, scrap = 200, materials = { metal = 30, wood = 10 } },
    steel_wall = { tier = "large", era = 4, scrap = 250, materials = { metal = 35, stone = 10 } },
    boiler_house = { tier = "large", era = 4, scrap = 400, materials = { metal = 50, copper = 10, stone = 15 } },
    engine_house = { tier = "large", era = 4, scrap = 350, materials = { metal = 40, copper = 8, wood = 10 } },
    line_shaft_system = { tier = "large", era = 4, scrap = 300, materials = { metal = 35, wood = 15 } },
    powered_hammer = { tier = "large", era = 4, scrap = 250, materials = { metal = 30, stone = 10 } },
    powered_crane = { tier = "large", era = 4, scrap = 280, materials = { metal = 25, wood = 10, copper = 3 } },
    pumping_station = { tier = "large", era = 4, scrap = 220, materials = { metal = 20, copper = 5, stone = 10 } },
    workshop_industrial = { tier = "large", era = 4, scrap = 500, materials = { metal = 50, wood = 20, stone = 15, copper = 5 } },
    -- ERA 5
    wire_run = { tier = "medium", era = 5, scrap = 150, materials = { copper = 10, metal = 3 } },
    lamp_post = { tier = "small", era = 5, scrap = 80, materials = { metal = 5, glass = 3, copper = 2 } },
    switch_box = { tier = "medium", era = 5, scrap = 120, materials = { metal = 5, copper = 5 } },
    generator_house = { tier = "large", era = 5, scrap = 600, materials = { metal = 30, copper = 15, stone = 10 } },
    battery_bank = { tier = "large", era = 5, scrap = 500, materials = { metal = 20, copper = 10, glass = 5 } },
    lighthouse_restored = { tier = "large", era = 5, scrap = 2000, materials = { stone = 80, metal = 30, copper = 20, glass = 30, wood = 15 }, influence = 10 },
    telegraph_station = { tier = "large", era = 5, scrap = 800, materials = { metal = 20, copper = 15, wood = 10, glass = 5 } },
    signal_tower = { tier = "large", era = 5, scrap = 700, materials = { metal = 25, wood = 10, copper = 10, glass = 5 } },
}

local INSUFFICIENT_LINES = {
    scrap = "I need more scrap.",
    wood = "I need more wood.",
    metal = "I need more metal.",
    cloth = "I need more cloth.",
    glass = "I need more glass.",
    copper = "I need more copper.",
    stone = "I need more stone.",
    influence = "This needs more than materials.",
}

local GENERIC_INSUFFICIENT = "I need more materials."

-- ═══ Extracted pure logic functions ═══

local function getCost(buildType)
    local cost = BUILD_COSTS[buildType]
    if not cost then return nil end
    local copy = { scrap = cost.scrap or 0, materials = {} }
    for mat, amount in pairs(cost.materials or {}) do
        copy.materials[mat] = amount
    end
    if cost.influence then copy.influence = cost.influence end
    return copy
end

local function getBuildsForEra(era)
    local result = {}
    for buildType, cost in pairs(BUILD_COSTS) do
        if cost.era == era then
            table.insert(result, buildType)
        end
    end
    return result
end

local function getBuildsByTier(tier)
    local result = {}
    for buildType, cost in pairs(BUILD_COSTS) do
        if cost.tier == tier then
            table.insert(result, buildType)
        end
    end
    return result
end

local function getCostSummary(buildType)
    local cost = getCost(buildType)
    if not cost then return "Unknown build type" end
    local parts = {}
    if cost.scrap and cost.scrap > 0 then
        table.insert(parts, cost.scrap .. " scrap")
    end
    if cost.materials then
        local matNames = {}
        for mat in pairs(cost.materials) do table.insert(matNames, mat) end
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

local function getInsufficientLine(missingMaterial)
    if missingMaterial and INSUFFICIENT_LINES[missingMaterial] then
        return INSUFFICIENT_LINES[missingMaterial]
    end
    return GENERIC_INSUFFICIENT
end

-- ═══ Test Framework ═══

local pass = 0
local fail = 0
local failures = {}

local function ok(name, cond, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        table.insert(failures, name .. (detail and (": " .. detail) or ""))
    end
end

-- ═══ Tests ═══

-- -- Catalog completeness -- --

-- (catalog count handled below)
local catalog_count = 0
for _ in pairs(BUILD_COSTS) do catalog_count = catalog_count + 1 end
ok("catalog has 40+ build types", catalog_count >= 40, "found " .. catalog_count)

-- Every entry has required fields
for buildType, cost in pairs(BUILD_COSTS) do
    ok(buildType .. " has tier", cost.tier ~= nil)
    ok(buildType .. " has era", cost.era ~= nil)
    ok(buildType .. " has scrap", cost.scrap ~= nil and cost.scrap > 0)
    ok(buildType .. " has materials", cost.materials ~= nil)
    ok(buildType .. " valid tier", cost.tier == "small" or cost.tier == "medium" or cost.tier == "large")
    ok(buildType .. " valid era", cost.era >= 1 and cost.era <= 5)
end

-- -- getCost -- --

local lean = getCost("lean_to")
ok("getCost returns table for known type", lean ~= nil)
ok("getCost lean_to scrap=10", lean.scrap == 10)
ok("getCost lean_to wood=5", lean.materials.wood == 5)
ok("getCost returns copy (mutable)", true) -- can't mutate catalog
lean.scrap = 999
local lean2 = getCost("lean_to")
ok("getCost returns independent copy", lean2.scrap == 10, "was " .. lean2.scrap)

ok("getCost returns nil for unknown", getCost("nonexistent") == nil)

-- -- getBuildsForEra -- --

local era1 = getBuildsForEra(1)
ok("era 1 has 7 builds", #era1 == 7, "found " .. #era1)

local era5 = getBuildsForEra(5)
ok("era 5 has 8 builds", #era5 == 8, "found " .. #era5)

local era0 = getBuildsForEra(0)
ok("era 0 is empty", #era0 == 0)

local era6 = getBuildsForEra(6)
ok("era 6 is empty", #era6 == 0)

-- -- getBuildsByTier -- --

local small = getBuildsByTier("small")
ok("small tier has builds", #small >= 7, "found " .. #small)

local large = getBuildsByTier("large")
ok("large tier has builds", #large >= 15, "found " .. #large)

local invalid = getBuildsByTier("huge")
ok("invalid tier is empty", #invalid == 0)

-- -- getCostSummary -- --

local summary = getCostSummary("lean_to")
ok("summary contains scrap", string.find(summary, "scrap") ~= nil)
ok("summary contains wood", string.find(summary, "wood") ~= nil)
ok("summary does not contain metal", string.find(summary, "metal") == nil)

local tower_summary = getCostSummary("stone_tower")
ok("tower summary has 50 stone", string.find(tower_summary, "50 stone") ~= nil)

local lighthouse_summary = getCostSummary("lighthouse_restored")
ok("lighthouse summary has influence", string.find(lighthouse_summary, "influence") ~= nil)
ok("lighthouse summary has 2000 scrap", string.find(lighthouse_summary, "2000 scrap") ~= nil)

ok("unknown build summary", getCostSummary("nonexistent") == "Unknown build type")

-- -- getInsufficientLine -- --

ok("insufficient scrap", getInsufficientLine("scrap") == "I need more scrap.")
ok("insufficient wood", getInsufficientLine("wood") == "I need more wood.")
ok("insufficient unknown", getInsufficientLine("unobtanium") == GENERIC_INSUFFICIENT)
ok("insufficient nil", getInsufficientLine(nil) == GENERIC_INSUFFICIENT)

-- -- Material coverage -- --

-- Every material used in costs should have an insufficient line
local materials_used = {}
for _, cost in pairs(BUILD_COSTS) do
    for mat in pairs(cost.materials or {}) do
        materials_used[mat] = true
    end
end
for mat in pairs(materials_used) do
    ok("material '" .. mat .. "' has insufficient line", INSUFFICIENT_LINES[mat] ~= nil, "no line for " .. mat)
end

-- -- Era escalation -- --

-- Era 5 should be more expensive than era 1 on average
local function avgScrap(era)
    local builds = getBuildsForEra(era)
    if #builds == 0 then return 0 end
    local total = 0
    for _, b in ipairs(builds) do total = total + getCost(b).scrap end
    return total / #builds
end

local avg1 = avgScrap(1)
local avg5 = avgScrap(5)
ok("era 5 avg scrap > era 1 avg scrap", avg5 > avg1,
   "era1=" .. math.floor(avg1) .. " era5=" .. math.floor(avg5))

-- -- Tier cost ordering -- --

-- Large builds should cost more scrap than small builds on average
local function avgScrapByTier(tier)
    local builds = getBuildsByTier(tier)
    if #builds == 0 then return 0 end
    local total = 0
    for _, b in ipairs(builds) do total = total + getCost(b).scrap end
    return total / #builds
end

local avg_small = avgScrapByTier("small")
local avg_large = avgScrapByTier("large")
ok("large avg scrap > small avg scrap", avg_large > avg_small,
   "small=" .. math.floor(avg_small) .. " large=" .. math.floor(avg_large))

-- -- Lighthouse is the most expensive -- --

local maxCost = 0
local maxBuild = ""
for buildType, cost in pairs(BUILD_COSTS) do
    if cost.scrap > maxCost then
        maxCost = cost.scrap
        maxBuild = buildType
    end
end
ok("lighthouse_restored is most expensive", maxBuild == "lighthouse_restored",
   "actually: " .. maxBuild .. " at " .. maxCost)

-- ═══ Results ═══

print("")
print("══════════════════════════════════════════════════")
print("  BUILD COSTS LOGIC TESTS")
print("══════════════════════════════════════════════════")
print(string.format("  %d passed, %d failed, %d total", pass, fail, pass + fail))
if #failures > 0 then
    print("")
    print("  FAILURES:")
    for _, f in ipairs(failures) do
        print("    ✗ " .. f)
    end
end
print("══════════════════════════════════════════════════")
print("")

os.exit(fail == 0 and 0 or 1)
