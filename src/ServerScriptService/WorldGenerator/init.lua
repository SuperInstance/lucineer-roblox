--[[
    WorldGenerator/init.lua
    Slackwater — Procedural Terrain Generator

    The core world generation module. Uses Perlin noise (math.noise) with
    multiple octaves to create natural terrain across 6 biomes.

    Biomes: Coastline, Forest, Mountains, Plains, Wetlands, Underground

    Usage:
        local WorldGenerator = require(script.ServerScriptService.WorldGenerator)
        WorldGenerator.Generate("single", seed)

    Pipeline:
        1. Initialize noise functions with seed
        2. For each (x, z) in world grid:
           a. Compute elevation (multi-octave Perlin)
           b. Compute temperature
           c. Compute humidity
           d. Determine biome from elevation + T/H
           e. Fill terrain voxel with appropriate material
        3. Carve rivers
        4. Fill ocean water around island
        5. Generate underground caverns + ore veins
        6. Spawn resource nodes per biome
        7. Place tree / rock / salvage models
        8. Initialize tide system
        9. Fire world-ready event
]]

-- Services
local Terrain = workspace.Terrain

-- Modules
local Config = require(script.Config)
local Resources = require(script.Resources)
local TideSystem = require(script.TideSystem)

-- Forward declaration of the module
local WorldGenerator = {}

--==========================================================================
-- CONSTANTS
--==========================================================================

local VOXEL_SIZE = 4          -- Roblox Terrain voxel size in studs
local COLUMN_STEP = VOXEL_SIZE -- we process one column every VOXEL_SIZE studs

--==========================================================================
-- STATE
--==========================================================================

WorldGenerator._seed = 0
WorldGenerator._worldConfig = nil
WorldGenerator._terrain = nil
WorldGenerator._ready = false
WorldGenerator._heightMap = nil  -- 2D array [x][z] = height
WorldGenerator._biomeMap = nil   -- 2D array [x][z] = biomeId
WorldGenerator._size = 400       -- world size in studs

--==========================================================================
-- NOISE FUNCTIONS
--==========================================================================

--- Multi-octave Perlin noise (fractal Brownian motion).
--- @param params table   Noise parameter set from Config.noise
--- @param x number       World X
--- @param z number       World Z
--- @param seed number    Global world seed
--- @return number        Noise value roughly in [-1, 1]
local function fbm(params, x, z, seed)
    local total = 0
    local frequency = params.scale
    local amplitude = params.amplitude
    local maxValue = 0

    for octave = 1, params.octaves do
        local sampleX = (x * frequency) + (seed + params.seedOffset) * 0.001
        local sampleZ = (z * frequency) + (seed + params.seedOffset) * 0.001

        local n = math.noise(sampleX, sampleZ, 0)
        total = total + n * amplitude
        maxValue = maxValue + amplitude

        amplitude = amplitude * params.persistence
        frequency = frequency * params.lacunarity
    end

    if maxValue == 0 then return 0 end
    return total / maxValue
end

--- Ridged noise variant for mountain peaks.
--- Produces sharp ridges instead of smooth hills.
--- @param params table   Noise parameters
--- @param x number
--- @param z number
--- @param seed number
--- @return number
local function ridgedFbm(params, x, z, seed)
    local total = 0
    local frequency = params.scale
    local amplitude = params.amplitude
    local maxValue = 0
    local power = params.ridgePower or 1.8

    for octave = 1, params.octaves do
        local sampleX = (x * frequency) + (seed + params.seedOffset) * 0.001
        local sampleZ = (z * frequency) + (seed + params.seedOffset) * 0.001

        local n = math.noise(sampleX, sampleZ, 0)
        -- Ridge: invert and sharpen
        n = 1 - math.abs(n)
        n = n ^ power

        total = total + n * amplitude
        maxValue = maxValue + amplitude

        amplitude = amplitude * params.persistence
        frequency = frequency * params.lacunarity
    end

    if maxValue == 0 then return 0 end
    return total / maxValue
end

--==========================================================================
-- ISLAND FALLOFF
--==========================================================================

--- Returns a 0..1 factor that smoothly falls to 0 at the world edges,
--- creating an island effect.
--- @param x number  World X
--- @param z number  World Z
--- @param halfSize number  Half the world size
--- @return number
local function islandFalloff(x, z, halfSize)
    local dx = math.abs(x) / halfSize
    local dz = math.abs(z) / halfSize
    local d = math.max(dx, dz) -- square falloff
    -- Smoothstep falloff
    local falloffPower = 2.5
    local result = 1 - math.clamp(d, 0, 1) ^ falloffPower
    return result
end

--==========================================================================
-- BIOME CLASSIFICATION
--==========================================================================

--- Determine biome for a given position based on elevation, temperature, humidity.
--- @param elevation number   Height above water level (studs)
--- @param temp number        Temperature noise [-1, 1]
--- @param humid number       Humidity noise [-1, 1]
--- @return string biomeId, table biomeDef
local function classifyBiome(elevation, temp, humid)
    local elevThresholds = Config.elevation

    -- High elevation → Mountains
    if elevation > elevThresholds.mountainMin then
        return "mountains", Config.biomes.mountains
    end

    -- Very low elevation near water → Coastline
    if elevation <= elevThresholds.coastlineMax then
        return "coastline", Config.biomes.coastline
    end

    -- Mid elevation: use T/H rules
    for _, biomeId in ipairs(Config.biomeEvalOrder) do
        local biomeDef = Config.biomes[biomeId]
        if biomeDef and biomeDef.rule(temp, humid) then
            return biomeId, biomeDef
        end
    end

    -- Fallback: plains
    return "plains", Config.biomes.plains
end

--==========================================================================
-- TERRAIN HEIGHT FUNCTION
--==========================================================================

--- Compute terrain elevation at world position (x, z).
--- @param x number
--- @param z number
--- @return number height (studs above 0), string biomeId
local function computeHeight(x, z, seed)
    local halfSize = WorldGenerator._size / 2

    -- Base elevation noise
    local baseNoise = fbm(Config.noise.elevation, x, z, seed)

    -- Mountain noise (ridged, only significant at higher elevations)
    local mountainNoise = ridgedFbm(Config.noise.mountain, x, z, seed)

    -- Blend: mountains dominate when base elevation is already high
    local mountainBlend = math.clamp((baseNoise + 0.3) * 1.5, 0, 1)
    local blended = baseNoise * (1 - mountainBlend) + mountainNoise * mountainBlend

    -- Apply island falloff
    local falloff = islandFalloff(x, z, halfSize)
    local islanded = blended * falloff

    -- Temperature and humidity for biome selection
    local tempNoise = fbm(Config.noise.temperature, x, z, seed)
    local humidNoise = fbm(Config.noise.humidity, x, z, seed)

    -- Convert noise to elevation in studs
    local waterLevel = Config.noise.waterLevel
    local baseHeight = Config.noise.baseHeight
    local elevationRange = 80 -- total elevation swing in studs

    local elevation = (islanded * elevationRange * 0.5) + baseHeight - (1 - falloff) * (baseHeight + 10)

    -- Wetlands: lower elevation slightly in high-humidity cold areas
    if humidNoise > 0.4 and tempNoise <= -0.1 then
        elevation = elevation - 3
    end

    -- Compute height relative to water level for biome classification
    local relElev = elevation - waterLevel

    local biomeId = classifyBiome(relElev, tempNoise, humidNoise)

    return elevation, biomeId
end

--==========================================================================
-- RIVER CARVING
--==========================================================================

--- Check if a river should be carved at (x, z).
--- Returns the depth adjustment (negative = carve down).
--- @param x number
--- @param z number
--- @param seed number
--- @return number adjustment
local function riverCarve(x, z, seed)
    local riverNoise = math.noise(
        x * Config.noise.river.scale + (seed + Config.noise.river.seedOffset) * 0.001,
        z * Config.noise.river.scale + (seed + Config.noise.river.seedOffset) * 0.001,
        0
    )
    local threshold = Config.noise.river.threshold
    if math.abs(riverNoise) < threshold then
        -- Near zero crossing of river noise → carve a channel
        local factor = 1 - (math.abs(riverNoise) / threshold)
        return -Config.noise.river.depth * factor
    end
    return 0
end

--==========================================================================
-- VOXEL TERRAIN GENERATION
--==========================================================================

--- Generate the terrain by filling voxel columns.
--- This is the main generation loop.
local function generateTerrain()
    local size = WorldGenerator._size
    local halfSize = size / 2
    local seed = WorldGenerator._seed
    local step = COLUMN_STEP

    local totalColumns = ((size / step) + 1) ^ 2
    local processed = 0

    -- Prepare heightmap and biomemap
    WorldGenerator._heightMap = {}
    WorldGenerator._biomeMap = {}

    -- We'll fill terrain in batches using Region3 + FillRegion for efficiency.
    -- Group voxels by material to minimize FillRegion calls.

    -- Material regions: biomeId -> list of {region3, height}
    local materialRegions = {}
    for biomeId, biomeDef in pairs(Config.biomes) do
        materialRegions[biomeId] = {}
    end

    for x = -halfSize, halfSize, step do
        local xIdx = math.floor((x + halfSize) / step) + 1
        WorldGenerator._heightMap[xIdx] = {}
        WorldGenerator._biomeMap[xIdx] = {}

        for z = -halfSize, halfSize, step do
            local zIdx = math.floor((z + halfSize) / step) + 1

            local elevation, biomeId = computeHeight(x, z, seed)

            -- Apply river carving
            local carve = riverCarve(x, z, seed)
            elevation = elevation + carve

            -- Clamp elevation
            elevation = math.max(-10, math.min(120, elevation))

            -- Store in maps
            WorldGenerator._heightMap[xIdx][zIdx] = elevation
            WorldGenerator._biomeMap[xIdx][zIdx] = biomeId

            -- Fill terrain voxel
            local biomeDef = Config.biomes[biomeId]
            local material = biomeDef and biomeDef.terrainMaterial or Enum.Material.Grass

            -- Determine column height in voxels
            local colHeight = math.floor(elevation / VOXEL_SIZE) * VOXEL_SIZE
            if colHeight < Config.noise.waterLevel - VOXEL_SIZE then
                colHeight = Config.noise.waterLevel - VOXEL_SIZE
            end

            -- Fill from bedrock up to surface
            local region = Region3.new(
                Vector3.new(x, -VOXEL_SIZE, z),
                Vector3.new(x + step, colHeight, z + step)
            )
            region = region:ExpandToGrid(VOXEL_SIZE)

            table.insert(materialRegions[biomeId], {
                region = region,
                height = colHeight,
            })

            -- Fill water below water level
            if elevation < Config.noise.waterLevel then
                local waterRegion = Region3.new(
                    Vector3.new(x, colHeight, z),
                    Vector3.new(x + step, Config.noise.waterLevel, z + step)
                )
                waterRegion = waterRegion:ExpandToGrid(VOXEL_SIZE)
                Terrain:FillRegion(waterRegion, VOXEL_SIZE, Enum.Material.Water)
            end

            processed = processed + 1
        end
    end

    -- Apply material regions (batch by biome/material)
    for biomeId, regions in pairs(materialRegions) do
        local biomeDef = Config.biomes[biomeId]
        local material = biomeDef and biomeDef.terrainMaterial or Enum.Material.Grass
        for _, entry in ipairs(regions) do
            Terrain:FillRegion(entry.region, VOXEL_SIZE, material)
        end
        materialRegions[biomeId] = nil -- free memory
    end

    print(string.format("[WorldGenerator] Terrain generated: %d columns, size %dx%d", processed, size, size))
end

--==========================================================================
-- UNDERGROUND GENERATION
--==========================================================================

--- Carve underground caverns and place underground resource nodes.
local function generateUnderground()
    local seed = WorldGenerator._seed
    local size = WorldGenerator._size
    local halfSize = size / 2
    local step = COLUMN_STEP
    local undergroundDepth = Config.elevation.undergroundDepth

    -- Simple cavern noise: where noise is high, remove terrain (carve cave)
    local cavernThreshold = 0.35
    local cavernScale = 0.03

    local cavernCount = 0

    for x = -halfSize, halfSize, step do
        for z = -halfSize, halfSize, step do
            local xIdx = math.floor((x + halfSize) / step) + 1
            local zIdx = math.floor((z + halfSize) / step) + 1

            local surfaceHeight = 0
            if WorldGenerator._heightMap[xIdx] and WorldGenerator._heightMap[xIdx][zIdx] then
                surfaceHeight = WorldGenerator._heightMap[xIdx][zIdx]
            else
                surfaceHeight = Config.noise.baseHeight
            end

            -- Only carve below surface
            local undergroundTop = surfaceHeight - 5
            local undergroundBottom = undergroundTop - undergroundDepth

            if undergroundBottom < -VOXEL_SIZE then
                undergroundBottom = -VOXEL_SIZE
            end

            -- Carve caverns using 3D-ish noise (use 2D noise with different z input for depth)
            local depth = undergroundTop - undergroundBottom
            local voxelsToCarve = math.floor(depth / VOXEL_SIZE)

            for v = 0, voxelsToCarve do
                local y = undergroundTop - (v * VOXEL_SIZE)
                local cavernNoise = math.noise(
                    x * cavernScale + seed * 0.001,
                    z * cavernScale + seed * 0.001,
                    y * cavernScale * 0.5
                )
                if cavernNoise > cavernThreshold then
                    -- Carve: remove terrain (replace with air)
                    local region = Region3.new(
                        Vector3.new(x, y, z),
                        Vector3.new(x + step, y + VOXEL_SIZE, z + step)
                    )
                    region = region:ExpandToGrid(VOXEL_SIZE)
                    -- Use FillBlock with Air material (Terrain doesn't have Air, so we use ReplaceMaterial = Air)
                    -- Actually in Roblox, to "remove" terrain you write with Enum.Material.Air
                    pcall(function()
                        Terrain:FillRegion(region, VOXEL_SIZE, Enum.Material.Air)
                    end)
                    cavernCount = cavernCount + 1
                end
            end
        end
    end

    -- Spawn underground resources
    local undergroundRegion = {
        x0 = -halfSize,
        z0 = -halfSize,
        x1 = halfSize,
        z1 = halfSize,
    }
    Resources.SpawnForBiome("underground", undergroundRegion, 1, 0.5)

    print(string.format("[WorldGenerator] Underground generated: %d cavern voxels carved", cavernCount))
end

--==========================================================================
-- MODEL / PROP PLACEMENT
--==========================================================================

--- Create a simple tree model part (placeholder; real game uses MeshParts from ReplicatedStorage).
--- @param position Vector3
--- @param scale number
--- @return Instance
local function createTreeModel(position, scale)
    scale = scale or 1

    -- Try to clone from ReplicatedStorage assets
    local template = game:GetService("ReplicatedStorage"):FindFirstChild("TreeModel")
    if template then
        local clone = template:Clone()
        clone:SetPrimaryPartCFrame(CFrame.new(position))
        local sf = clone:GetDescendants()
        for _, desc in ipairs(sf) do
            if desc:IsA("BasePart") then
                desc.Size = desc.Size * scale
            end
        end
        clone.Parent = workspace
        return clone
    end

    -- Fallback: create a simple trunk + foliage from parts
    local model = Instance.new("Model")
    model.Name = "Tree_" .. math.floor(position.X) .. "_" .. math.floor(position.Z)

    local trunk = Instance.new("Part")
    trunk.Name = "Trunk"
    trunk.Size = Vector3.new(1.5 * scale, 8 * scale, 1.5 * scale)
    trunk.Color = Color3.fromRGB(101, 67, 33)
    trunk.Material = Enum.Material.Wood
    trunk.Anchored = true
    trunk.CFrame = CFrame.new(position + Vector3.new(0, 4 * scale, 0))
    trunk.Parent = model

    local foliage = Instance.new("Part")
    foliage.Name = "Foliage"
    foliage.Size = Vector3.new(6 * scale, 6 * scale, 6 * scale)
    foliage.Color = Color3.fromRGB(34, 89, 46)
    foliage.Material = Enum.Material.Grass
    foliage.Shape = Enum.PartType.Ball
    foliage.Anchored = true
    foliage.CFrame = CFrame.new(position + Vector3.new(0, 9 * scale, 0))
    foliage.Parent = model

    model.PrimaryPart = trunk
    model.Parent = workspace
    return model
end

--- Create a simple rock model.
--- @param position Vector3
--- @param scale number
--- @return Instance
local function createRockModel(position, scale)
    scale = scale or 1

    local template = game:GetService("ReplicatedStorage"):FindFirstChild("RockModel")
    if template then
        local clone = template:Clone()
        clone:SetPrimaryPartCFrame(CFrame.new(position))
        clone.Parent = workspace
        return clone
    end

    -- Fallback: simple rock part
    local rock = Instance.new("Part")
    rock.Name = "Rock_" .. math.floor(position.X) .. "_" .. math.floor(position.Z)
    rock.Size = Vector3.new(3 * scale, 3 * scale, 3 * scale)
    rock.Color = Color3.fromRGB(128, 128, 128)
    rock.Material = Enum.Material.Slate
    rock.Shape = Enum.PartType.Ball
    rock.Anchored = true
    rock.CFrame = CFrame.new(position)
    rock.Parent = workspace
    return rock
end

--- Create a salvage prop (driftwood, debris).
--- @param position Vector3
--- @return Instance
local function createSalvageModel(position)
    local template = game:GetService("ReplicatedStorage"):FindFirstChild("SalvageModel")
    if template then
        local clone = template:Clone()
        clone:SetPrimaryPartCFrame(CFrame.new(position) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
        clone.Parent = workspace
        return clone
    end

    -- Fallback: simple crate
    local crate = Instance.new("Part")
    crate.Name = "Salvage_" .. math.floor(position.X) .. "_" .. math.floor(position.Z)
    crate.Size = Vector3.new(2, 2, 2)
    crate.Color = Color3.fromRGB(140, 120, 80)
    crate.Material = Enum.Material.CorrodedMetal
    crate.Anchored = true
    crate.CFrame = CFrame.new(position)
    crate.Parent = workspace
    return crate
end

--- Create an ore vein visual marker.
--- @param position Vector3
--- @param color Color3
--- @return Instance
local function createOreVeinModel(position, color)
    local vein = Instance.new("Part")
    vein.Name = "OreVein_" .. math.floor(position.X) .. "_" .. math.floor(position.Z)
    vein.Size = Vector3.new(2, 2, 2)
    vein.Color = color or Color3.fromRGB(100, 95, 90)
    vein.Material = Enum.Material.Slate
    vein.Shape = Enum.PartType.Block
    vein.Anchored = true
    vein.CFrame = CFrame.new(position)
    vein.Parent = workspace
    return vein
end

--- Place visual props for all resource nodes.
local function placeResourceProps()
    local nodes = Resources.GetAllNodes()
    for _, node in pairs(nodes) do
        if not node.model and not node.depleted then
            local resDef = Config.resourceTypes[node.type]
            if resDef then
                local modelType = resDef.model
                local pos = node.position

                if modelType == "TreeModel" then
                    -- Vary tree scale slightly
                    local rng = math.noise(pos.X * 0.1, pos.Z * 0.1, WorldGenerator._seed * 0.01)
                    local scale = 0.8 + (rng + 1) * 0.4 -- 0.8 to 1.6
                    node.model = createTreeModel(pos, scale)

                elseif modelType == "RockModel" then
                    local rng = math.noise(pos.X * 0.07, pos.Z * 0.07, WorldGenerator._seed * 0.01)
                    local scale = 0.6 + (rng + 1) * 0.5
                    node.model = createRockModel(pos, scale)

                elseif modelType == "SalvageModel" then
                    node.model = createSalvageModel(pos)

                elseif modelType == "OreVeinModel" then
                    node.model = createOreVeinModel(pos, Color3.fromRGB(resDef.color[1], resDef.color[2], resDef.color[3]))

                elseif modelType == "BushModel" then
                    local bush = Instance.new("Part")
                    bush.Name = "Bush_" .. node.id
                    bush.Size = Vector3.new(2, 2, 2)
                    bush.Color = Color3.fromRGB(resDef.color[1], resDef.color[2], resDef.color[3])
                    bush.Material = Enum.Material.Grass
                    bush.Shape = Enum.PartType.Ball
                    bush.Anchored = true
                    bush.CFrame = CFrame.new(pos)
                    bush.Parent = workspace
                    node.model = bush

                elseif modelType == "KelpModel" then
                    local kelp = Instance.new("Part")
                    kelp.Name = "Kelp_" .. node.id
                    kelp.Size = Vector3.new(0.5, 4, 0.5)
                    kelp.Color = Color3.fromRGB(resDef.color[1], resDef.color[2], resDef.color[3])
                    kelp.Material = Enum.Material.Grass
                    kelp.Anchored = true
                    kelp.CFrame = CFrame.new(pos)
                    kelp.Parent = workspace
                    node.model = kelp

                elseif modelType == "ShellModel" then
                    local shell = Instance.new("Part")
                    shell.Name = "Shell_" .. node.id
                    shell.Size = Vector3.new(0.8, 0.3, 0.8)
                    shell.Color = Color3.fromRGB(resDef.color[1], resDef.color[2], resDef.color[3])
                    shell.Material = Enum.Material.SmoothPlastic
                    shell.Anchored = true
                    shell.CFrame = CFrame.new(pos)
                    shell.Parent = workspace
                    node.model = shell

                elseif modelType == "PeatModel" then
                    local peat = Instance.new("Part")
                    peat.Name = "Peat_" .. node.id
                    peat.Size = Vector3.new(3, 1, 3)
                    peat.Color = Color3.fromRGB(resDef.color[1], resDef.color[2], resDef.color[3])
                    peat.Material = Enum.Material.Ground
                    peat.Anchored = true
                    peat.CFrame = CFrame.new(pos)
                    peat.Parent = workspace
                    node.model = peat

                elseif modelType == "CrystalModel" then
                    local crystal = Instance.new("Part")
                    crystal.Name = "Crystal_" .. node.id
                    crystal.Size = Vector3.new(1.5, 3, 1.5)
                    crystal.Color = Color3.fromRGB(resDef.color[1], resDef.color[2], resDef.color[3])
                    crystal.Material = Enum.Material.ForceField
                    crystal.Anchored = true
                    crystal.CFrame = CFrame.new(pos)
                    crystal.Parent = workspace
                    node.model = crystal

                elseif modelType == "GemModel" then
                    local gem = Instance.new("Part")
                    gem.Name = "Gem_" .. node.id
                    gem.Size = Vector3.new(1, 1, 1)
                    gem.Color = Color3.fromRGB(resDef.color[1], resDef.color[2], resDef.color[3])
                    gem.Material = Enum.Material.ForceField
                    gem.Shape = Enum.PartType.Ball
                    gem.Anchored = true
                    gem.CFrame = CFrame.new(pos)
                    gem.Parent = workspace
                    node.model = gem

                elseif modelType == "RuinModel" then
                    local ruin = Instance.new("Part")
                    ruin.Name = "AncientRuin_" .. node.id
                    ruin.Size = Vector3.new(4, 4, 4)
                    ruin.Color = Color3.fromRGB(resDef.color[1], resDef.color[2], resDef.color[3])
                    ruin.Material = Enum.Material.Metal
                    ruin.Anchored = true
                    ruin.CFrame = CFrame.new(pos)
                    ruin.Parent = workspace
                    node.model = ruin
                end

                -- Tag the model with the resource node id for interaction
                if node.model then
                    if node.model:IsA("Model") then
                        node.model:SetAttribute("ResourceNodeId", node.id)
                        node.model:SetAttribute("ResourceType", node.type)
                    else
                        node.model:SetAttribute("ResourceNodeId", node.id)
                        node.model:SetAttribute("ResourceType", node.type)
                    end
                end
            end
        end
    end
end

--==========================================================================
-- RESOURCE SPAWNING PER BIOME
--==========================================================================

--- Walk the biome map and spawn resources for each biome region.
local function spawnBiomeResources()
    local size = WorldGenerator._size
    local halfSize = size / 2
    local step = COLUMN_STEP

    -- Collect regions for each biome by scanning the biome map
    -- For efficiency, we treat the entire world as one region per biome
    -- (the Resources module handles density and spacing)

    local biomeRegions = {}
    for biomeId, _ in pairs(Config.biomes) do
        biomeRegions[biomeId] = {
            x0 = -halfSize,
            z0 = -halfSize,
            x1 = halfSize,
            z1 = halfSize,
        }
    end

    -- Spawn surface resources per biome
    for biomeId, region in pairs(biomeRegions) do
        if biomeId ~= "underground" then
            Resources.SpawnForBiome(biomeId, region, 1)
        end
    end

    -- Adjust resource Y positions to terrain height
    local heightFunc = function(x, z)
        local halfSize2 = WorldGenerator._size / 2
        local step2 = COLUMN_STEP
        local xIdx = math.floor((x + halfSize2) / step2) + 1
        local zIdx = math.floor((z + halfSize2) / step2) + 1
        if WorldGenerator._heightMap[xIdx] and WorldGenerator._heightMap[xIdx][zIdx] then
            return WorldGenerator._heightMap[xIdx][zIdx]
        end
        return Config.noise.baseHeight
    end
    Resources.AdjustHeights(heightFunc)

    -- Underground resources are spawned in generateUnderground()
end

--==========================================================================
-- PUBLIC API
--==========================================================================

--- Generate the complete world.
--- @param modeName string  Game mode key: "single", "multiplayer", "coop_novice_expert", "creative"
--- @param seed number      World seed for reproducible generation (optional, random if nil)
function WorldGenerator.Generate(modeName, seed)
    modeName = modeName or "single"

    local startTime = tick()

    -- Set seed
    WorldGenerator._seed = seed or math.random(1, 999999)
    math.randomseed(WorldGenerator._seed)

    -- Load config
    WorldGenerator._worldConfig = Config.GetMode(modeName)
    WorldGenerator._size = WorldGenerator._worldConfig.size
    WorldGenerator._terrain = Terrain

    print(string.format("========================================"))
    print(string.format("  SLACKWATER — World Generation"))
    print(string.format("  Mode: %s | Size: %dx%d | Seed: %d", modeName, WorldGenerator._size, WorldGenerator._size, WorldGenerator._seed))
    print(string.format("========================================"))

    -- 1. Initialize resources
    Resources.Init(WorldGenerator._worldConfig, WorldGenerator._seed)

    -- 2. Generate terrain
    print("[WorldGenerator] Step 1/6: Generating terrain...")
    generateTerrain()

    -- 3. Generate underground
    print("[WorldGenerator] Step 2/6: Generating underground...")
    generateUnderground()

    -- 4. Spawn surface resources
    print("[WorldGenerator] Step 3/6: Spawning resources...")
    spawnBiomeResources()

    -- 5. Place visual props
    print("[WorldGenerator] Step 4/6: Placing props...")
    placeResourceProps()

    -- 6. Initialize tide system
    print("[WorldGenerator] Step 5/6: Initializing tide system...")
    TideSystem.Init(WorldGenerator._worldConfig, WorldGenerator._seed, Terrain)

    -- Hook tide loot spawning
    TideSystem.SetOnTideLoot(function(phase)
        if phase == "low" then
            -- Expose beach resources at low tide (spawn shells, kelp on newly exposed beach)
            local halfSize = WorldGenerator._size / 2
            local beachPositions = {}
            local waterLevel = Config.noise.waterLevel
            for i = 1, 20 do
                local angle = (i / 20) * math.pi * 2
                local r = halfSize * 0.7 + math.random(-30, 30)
                local px = math.cos(angle) * r
                local pz = math.sin(angle) * r
                table.insert(beachPositions, Vector3.new(px, waterLevel - 2, pz))
            end
            Resources.SpawnTideLoot(beachPositions, WorldGenerator._seed + #Resources.GetAllNodes())
        elseif phase == "high" then
            -- Wash in new salvage from the Channel
            local halfSize = WorldGenerator._size / 2
            local coastPositions = {}
            local waterLevel = Config.noise.waterLevel
            for i = 1, 15 do
                local angle = (i / 15) * math.pi * 2
                local r = halfSize * 0.85 + math.random(-20, 20)
                local px = math.cos(angle) * r
                local pz = math.sin(angle) * r
                table.insert(coastPositions, Vector3.new(px, waterLevel + 1, pz))
            end
            Resources.SpawnTideLoot(coastPositions, WorldGenerator._seed + #Resources.GetAllNodes() + 1000)
        end
    end)

    -- 7. Start tide
    print("[WorldGenerator] Step 6/6: Starting tide...")
    TideSystem.Start()

    -- Done
    WorldGenerator._ready = true
    local elapsed = tick() - startTime

    print(string.format("========================================"))
    print(string.format("  World generation complete! (%.2fs)", elapsed))
    print(string.format("  Resource nodes: %d", Resources.GetNodeCount()))
    print(string.format("  Tide: %s", TideSystem.GetPhase()))
    print(string.format("========================================"))

    -- Fire world-ready event if it exists
    local readyEvent = game:GetService("ReplicatedStorage"):FindFirstChild("WorldReady")
    if readyEvent and readyEvent:IsA("BindableEvent") then
        readyEvent:Fire(WorldGenerator._seed, modeName)
    end

    return WorldGenerator._seed
end

--- Get terrain height at a world position (from cached heightmap).
--- @param x number
--- @param z number
--- @return number
function WorldGenerator.GetHeightAt(x, z)
    local halfSize = WorldGenerator._size / 2
    local step = COLUMN_STEP
    local xIdx = math.floor((x + halfSize) / step) + 1
    local zIdx = math.floor((z + halfSize) / step) + 1
    if WorldGenerator._heightMap and WorldGenerator._heightMap[xIdx] then
        return WorldGenerator._heightMap[xIdx][zIdx] or Config.noise.baseHeight
    end
    return Config.noise.baseHeight
end

--- Get biome at a world position (from cached biomemap).
--- @param x number
--- @param z number
--- @return string
function WorldGenerator.GetBiomeAt(x, z)
    local halfSize = WorldGenerator._size / 2
    local step = COLUMN_STEP
    local xIdx = math.floor((x + halfSize) / step) + 1
    local zIdx = math.floor((z + halfSize) / step) + 1
    if WorldGenerator._biomeMap and WorldGenerator._biomeMap[xIdx] then
        return WorldGenerator._biomeMap[xIdx][zIdx] or "plains"
    end
    return "plains"
end

--- Check if world generation has completed.
--- @return boolean
function WorldGenerator.IsReady()
    return WorldGenerator._ready
end

--- Get the world seed.
--- @return number
function WorldGenerator.GetSeed()
    return WorldGenerator._seed
end

--- Get the world size.
--- @return number
function WorldGenerator.GetSize()
    return WorldGenerator._size
end

--- Serialize world state for persistence (save game).
--- @return table
function WorldGenerator.Serialize()
    return {
        seed = WorldGenerator._seed,
        size = WorldGenerator._size,
        ready = WorldGenerator._ready,
        resources = Resources.Serialize(),
        tide = TideSystem.Serialize(),
    }
end

--- Restore world state from serialized data.
--- Note: Terrain must be regenerated or loaded separately (R2 world seed persistence).
--- @param data table
function WorldGenerator.Deserialize(data)
    if not data then return end
    WorldGenerator._seed = data.seed or 1
    WorldGenerator._size = data.size or 400
    WorldGenerator._ready = data.ready or false
    Resources.Deserialize(data.resources)
    TideSystem.Deserialize(data.tide)
end

--==========================================================================
-- AUTO-START (if WorldGenerator is placed in ServerScriptService)
--==========================================================================

-- The world will not auto-generate. The game controller should call
-- WorldGenerator.Generate(modeName, seed) when the server starts.
-- Example:
--   local WorldGenerator = require(script.Parent.WorldGenerator)
--   WorldGenerator.Generate("single", 12345)

return WorldGenerator
