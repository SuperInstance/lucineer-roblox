--[[
    WorldGenerator/Resources.lua
    Slackwater — Resource Distribution System

    Manages all harvestable resource nodes in the world.
    Works with Config.lua for definitions and the Terrain Generator
    for placement positions.

    API:
        Resources.Init(worldConfig, seed)
        Resources.SpawnForBiome(biomeId, region, era)
        Resources.GetNearby(position, radius)
        Resources.Harvest(nodeId, amount)
        Resources.RespawnAll(dt)
        Resources.SpawnTideLoot(positions)
        Resources.GetAllNodes()
        Resources.GetNodeCount()
]]

local Resources = {}

-- Dependencies (required at call time to avoid circular deps)
local Config

-- State
Resources._nodes = {}        -- id -> node table
Resources._nextId = 1
Resources._seed = 1
Resources._worldConfig = nil
Resources._initialized = false

-- A resource node looks like:
-- {
--   id        = number,
--   type      = string (key into Config.resourceTypes),
--   position  = Vector3,
--   biome     = string,
--   yield     = number (remaining harvestable units),
--   maxYield   = number (original yield for respawn),
--   respawnTime = number (seconds, 0 = never),
--   respawnTimer = number (counts down when depleted, nil when active),
--   era       = number (era this resource belongs to),
--   depleted  = bool,
--   model     = Instance or nil (visual prop/model reference),
-- }

--==========================================================================
-- LOCAL HELPERS
--==========================================================================

local function rand(seed)
    -- Deterministic PRNG using math.noise (Roblox has no math.randomseed reproducibility across clients easily)
    -- We use a simple LCG seeded from world seed for reproducible placements.
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed, (seed / 2147483648)
end

local function makeRNG(seed)
    local state = seed
    return function()
        state, rand = nil, nil -- placeholder to satisfy linter
        state = (state * 1103515245 + 12345) % 2147483648
        return state / 2147483648
    end
end

--==========================================================================
-- INITIALIZATION
--==========================================================================

--- Initialize the resource system.
--- @param worldConfig table  The active game-mode config table.
--- @param seed number        World seed for deterministic generation.
function Resources.Init(worldConfig, seed)
    Config = Config or require(script.Parent.Config)

    Resources._nodes = {}
    Resources._nextId = 1
    Resources._seed = seed or 1
    Resources._worldConfig = worldConfig
    Resources._initialized = true

    print("[WorldGenerator.Resources] Initialized. Seed=" .. tostring(seed) .. " Mode resources=" .. tostring(worldConfig.resources))
end

--==========================================================================
-- SPAWNING
--==========================================================================

--- Spawn resource nodes for a biome within a rectangular region.
--- @param biomeId string   Biome key (e.g. "forest", "mountains")
--- @param region table     {x0, z0, x1, z1} — world-space bounds
--- @param era number       Current max era (1..7) — gates which resources can spawn.
--- @param densityScale number  Multiplier on base density (default 1.0)
function Resources.SpawnForBiome(biomeId, region, era, densityScale)
    if not Resources._initialized then
        warn("[WorldGenerator.Resources] Not initialized. Call Resources.Init() first.")
        return
    end

    Config = Config or require(script.Parent.Config)
    densityScale = densityScale or 1.0
    era = era or 1

    local resourceTypes = Config.GetBiomeResources(biomeId)
    if #resourceTypes == 0 then
        return
    end

    -- Determine node count from density config
    local baseDensity = Config.GetBiomeDensity(biomeId)
    local areaWidth = math.abs(region.x1 - region.x0)
    local areaDepth = math.abs(region.z1 - region.z0)
    local areaInHundreds = (areaWidth * areaDepth) / 10000
    local nodeCount = math.floor(baseDensity * areaInHundreds * densityScale + 0.5)

    -- Adjust for game-mode resource setting
    local modeResource = Resources._worldConfig.resources
    if modeResource == "rich" then
        nodeCount = math.floor(nodeCount * 1.5)
    elseif modeResource == "infinite" then
        nodeCount = math.floor(nodeCount * 3.0)
    elseif modeResource == "normal" then
        -- as-is
    end

    -- Deterministic RNG for this biome region
    local rngState = (Resources._seed + region.x0 * 73856093 + region.z0 * 19349663 + biomeId:len() * 83492791) % 2147483648
    if rngState <= 0 then rngState = rngState + 2147483647 end

    local biomeMultiplier = 1.0
    local biomeDef = Config.biomes[biomeId]
    if biomeDef then
        biomeMultiplier = biomeDef.resourceMultiplier
    end

    for i = 1, nodeCount do
        -- Advance PRNG
        rngState = (rngState * 1103515245 + 12345) % 2147483648
        local r1 = rngState / 2147483648

        rngState = (rngState * 1103515245 + 12345) % 2147483648
        local r2 = rngState / 2147483648

        rngState = (rngState * 1103515245 + 12345) % 2147483648
        local r3 = rngState / 2147483648

        -- Pick a resource type for this node
        -- Filter by era: skip resources the current era can't access
        local availableTypes = {}
        for _, resType in ipairs(resourceTypes) do
            local resDef = Config.resourceTypes[resType]
            if resDef and resDef.era <= era then
                local scarcity = Config.GetScarcity(resType, era)
                if scarcity > 0 then
                    -- Weight by scarcity (higher = more likely)
                    for _ = 1, math.max(1, math.floor(scarcity * 10 + 0.5)) do
                        table.insert(availableTypes, resType)
                    end
                end
            end
        end

        if #availableTypes == 0 then
            break -- no resources available for this era in this biome
        end

        local chosenType = availableTypes[math.floor(r1 * #availableTypes) + 1]
        local resDef = Config.resourceTypes[chosenType]
        if not resDef then
            break
        end

        -- Position within region
        local px = region.x0 + r2 * (region.x1 - region.x0)
        local pz = region.z0 + r3 * (region.z1 - region.z0)

        -- Yield with scarcity and biome multiplier
        local scarcity = Config.GetScarcity(chosenType, era)
        local yieldAmount = math.max(1, math.floor(resDef.baseYield * scarcity * biomeMultiplier + 0.5))

        if modeResource == "infinite" then
            yieldAmount = 99999
        end

        -- Vertical position: place slightly above terrain (caller adjusts if needed)
        local py = 0 -- The terrain generator or caller will set the Y based on terrain height

        -- Skip if too close to an existing node of same type (min spacing)
        local tooClose = false
        local minSpacing = 4 -- studs
        for _, existing in pairs(Resources._nodes) do
            if existing.type == chosenType then
                local dx = existing.position.X - px
                local dz = existing.position.Z - pz
                if dx * dx + dz * dz < minSpacing * minSpacing then
                    tooClose = true
                    break
                end
            end
        end

        if not tooClose then
            local node = {
                id = Resources._nextId,
                type = chosenType,
                position = Vector3.new(px, py, pz),
                biome = biomeId,
                yield = yieldAmount,
                maxYield = yieldAmount,
                respawnTime = resDef.respawnTime,
                respawnTimer = nil,
                era = resDef.era,
                depleted = false,
                model = nil,
            }
            Resources._nodes[Resources._nextId] = node
            Resources._nextId = Resources._nextId + 1
        end
    end

    print(string.format("[WorldGenerator.Resources] Spawned %d nodes for biome '%s' (era %d)", nodeCount, biomeId, era))
end

--- Set the Y position of all nodes based on terrain height.
--- Call this after terrain generation completes.
--- @param getHeightFunc function(x, z) -> number  Returns terrain height at x,z
function Resources.AdjustHeights(getHeightFunc)
    for _, node in pairs(Resources._nodes) do
        local h = getHeightFunc(node.position.X, node.position.Z)
        -- Place resource 1 stud above terrain surface
        node.position = Vector3.new(node.position.X, h + 1, node.position.Z)
    end
end

--==========================================================================
-- QUERYING
--==========================================================================

--- Get all resource nodes within `radius` studs of `position`.
--- @param position Vector3
--- @param radius number  Search radius in studs
--- @return table array of node tables
function Resources.GetNearby(position, radius)
    local result = {}
    local r2 = radius * radius
    for _, node in pairs(Resources._nodes) do
        local offset = node.position - position
        if offset.X * offset.X + offset.Z * offset.Z <= r2 then
            table.insert(result, node)
        end
    end
    return result
end

--- Get a single node by id.
--- @param nodeId number
--- @return table|nil
function Resources.GetNode(nodeId)
    return Resources._nodes[nodeId]
end

--- Get all nodes (for saving / debugging).
--- @return table
function Resources.GetAllNodes()
    return Resources._nodes
end

--- Total count of active (non-depleted) nodes.
--- @return number
function Resources.GetNodeCount()
    local count = 0
    for _, node in pairs(Resources._nodes) do
        if not node.depleted then
            count = count + 1
        end
    end
    return count
end

--==========================================================================
-- HARVESTING
--==========================================================================

--- Harvest `amount` units from a resource node.
--- Returns actual amount harvested (may be less if node is nearly depleted).
--- @param nodeId number
--- @param amount number  How many units to harvest
--- @return number harvested, string resourceType
function Resources.Harvest(nodeId, amount)
    local node = Resources._nodes[nodeId]
    if not node then
        return 0, nil
    end
    if node.depleted then
        return 0, node.type
    end

    local harvested = math.min(amount, node.yield)
    node.yield = node.yield - harvested

    if node.yield <= 0 then
        node.depleted = true
        if node.respawnTime > 0 then
            node.respawnTimer = node.respawnTime
        end
        -- Remove visual model if present
        if node.model then
            node.model:Destroy()
            node.model = nil
        end
    end

    return harvested, node.type
end

--==========================================================================
-- RESPAWN
--==========================================================================

--- Advance respawn timers by `dt` seconds. Respawn depleted nodes whose timer expired.
--- Call this from RunService.Heartbeat or a fixed update loop.
--- @param dt number  Delta time in seconds
function Resources.RespawnAll(dt)
    for _, node in pairs(Resources._nodes) do
        if node.depleted and node.respawnTimer then
            node.respawnTimer = node.respawnTimer - dt
            if node.respawnTimer <= 0 then
                node.depleted = false
                node.yield = node.maxYield
                node.respawnTimer = nil
                -- Visual model recreation is handled by the rendering layer
                -- (Terrain Generator's prop placer).  We just mark it active.
            end
        end
    end
end

--==========================================================================
-- TIDE LOOT
--==========================================================================

--- Spawn tide loot at given positions (called by TideSystem on high tide).
--- @param positions table  Array of Vector3 positions
--- @param seed number      RNG seed for deterministic loot
function Resources.SpawnTideLoot(positions, seed)
    if not Resources._initialized then return end

    Config = Config or require(script.Parent.Config)

    local lootTypes = Config.tide.tideLoot
    local minCount = Config.tide.tideLootCount.min
    local maxCount = Config.tide.tideLootCount.max

    local rngState = (seed or Resources._seed) + os.time()
    rngState = rngState % 2147483648
    if rngState <= 0 then rngState = rngState + 2147483647 end

    local count = minCount + math.floor((rngState / 2147483648) * (maxCount - minCount + 1))
    count = math.min(count, #positions)

    for i = 1, count do
        -- Advance PRNG
        rngState = (rngState * 1103515245 + 12345) % 2147483648
        local r1 = rngState / 2147483648

        rngState = (rngState * 1103515245 + 12345) % 2147483648
        local r2 = rngState / 2147483648

        local posIdx = math.floor(r1 * #positions) + 1
        local lootType = lootTypes[math.floor(r2 * #lootTypes) + 1]
        local resDef = Config.resourceTypes[lootType]
        if resDef then
            local node = {
                id = Resources._nextId,
                type = lootType,
                position = positions[posIdx],
                biome = "coastline",
                yield = resDef.baseYield,
                maxYield = resDef.baseYield,
                respawnTime = resDef.respawnTime,
                respawnTimer = nil,
                era = resDef.era,
                depleted = false,
                model = nil,
            }
            Resources._nodes[Resources._nextId] = node
            Resources._nextId = Resources._nextId + 1
        end
    end

    print(string.format("[WorldGenerator.Resources] Spawned %d tide loot items", count))
end

--==========================================================================
-- SERIALIZATION (for saving/loading world state)
--==========================================================================

--- Serialize all nodes for persistence.
--- @return table
function Resources.Serialize()
    local data = {}
    data.nextId = Resources._nextId
    data.seed = Resources._seed
    data.nodes = {}
    for id, node in pairs(Resources._nodes) do
        data.nodes[tostring(id)] = {
            type = node.type,
            x = node.position.X,
            y = node.position.Y,
            z = node.position.Z,
            biome = node.biome,
            yield = node.yield,
            maxYield = node.maxYield,
            respawnTime = node.respawnTime,
            respawnTimer = node.respawnTimer,
            era = node.era,
            depleted = node.depleted,
        }
    end
    return data
end

--- Restore nodes from serialized data.
--- @param data table  Output of Resources.Serialize()
function Resources.Deserialize(data)
    if not data then return end
    Resources._nextId = data.nextId or 1
    Resources._seed = data.seed or 1
    Resources._nodes = {}
    for idStr, nd in pairs(data.nodes or {}) do
        local id = tonumber(idStr)
        Resources._nodes[id] = {
            id = id,
            type = nd.type,
            position = Vector3.new(nd.x, nd.y, nd.z),
            biome = nd.biome,
            yield = nd.yield,
            maxYield = nd.maxYield,
            respawnTime = nd.respawnTime,
            respawnTimer = nd.respawnTimer,
            era = nd.era,
            depleted = nd.depleted,
            model = nil,
        }
    end
    print("[WorldGenerator.Resources] Deserialized " .. #Resources._nodes .. " nodes")
end

return Resources
