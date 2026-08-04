--!strict
--[[
    OceanGenerator.lua — Open Ocean Generation
    Extends the world beyond the island with navigable water.

    Features:
    - Depth map using Perlin noise (shelves, channels, trenches, shoals)
    - Navigation hazards (rocks, kelp beds, shoals, wreck sites)
    - Fish spawn zones (species, density, depth range, seasonal)
    - Channel from open ocean to dock (guaranteed depth, buoy markers)
    - Open water expanse (2000 studs radius)
]]

local OceanGenerator = {}

-- Service references (injected or resolved at runtime)
local CollectionService
local RunService
local Terrain

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local Config = {
    oceanRadius    = 2000,
    floorDepth     = -200,
    surfaceLevel   = 0,
    islandRadius   = 250,
    channelWidth   = 80,
    channelDepth   = -15,
    voxelSize      = 4,

    -- Navigation hazards
    rocks    = { count = 40, minSize = 3,  maxSize = 15 },
    kelpBeds = { count = 8,  radius = 30,  slowFactor = 0.5 },
    shoals   = { count = 12 },
    wrecks   = { count = 3 },

    -- Fish zone definitions
    fishZones = {
        kelpBeds        = { count = 5, species = { "herring", "cod" }, depthRange = { -5, -15 } },
        halibutGrounds  = { count = 3, species = { "halibut"       }, depthRange = { -30, -80 } },
        salmonRun       = { count = 2, species = { "salmon"        }, depthRange = { 0,  -10 }, seasonal = true },
        crabGrounds     = { count = 4, species = { "crab"          }, depthRange = { -5, -20 } },
        openOcean       = {               species = { "cod", "salmon", "tuna" }, depthRange = { -20, -100 } },
    },

    -- Noise seeds (offsets so layers differ)
    shelfSeed   = 12345,
    channelSeed = 67890,
    trenchSeed  = 24680,
    shoalSeed   = 13579,
}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

local generated      = false
local generatedZones = {}
local generatedHazards = {}
local channelPath    = {}       -- list of Vector3 waypoints from ocean to dock
local dockPosition   = Vector3.new(0, 0, 0)

-- Simple deterministic PRNG so generation is reproducible per seed
local function makeRng(seed)
    local state = seed
    return function()
        -- xorshift32
        state = bit32.bxor(state, bit32.lshift(state, 13))
        state = bit32.bxor(state, bit32.rshift(state, 17))
        state = bit32.bxor(state, bit32.lshift(state, 5))
        return state / 4294967296
    end
end

-- ---------------------------------------------------------------------------
-- Perlin-like noise (lightweight, deterministic)
-- ---------------------------------------------------------------------------

local function fade(t)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(a, b, t)
    return a + t * (b - a)
end

local function grad(hash, x, y)
    local h = hash % 8
    local u = (h < 4) and x or y
    local v = (h < 4) and y or x
    local signU = ((h % 2) == 0) and u or -u
    local signV = ((math.floor(h / 2) % 2) == 0) and v or -v
    return signU + signV
end

-- Pre-built permutation table (Ken Perlin reference)
local perm = {}
do
    local base = {}
    for i = 0, 255 do base[i + 1] = i end
    -- shuffle with fixed seed for determinism
    local rng = makeRng(987654321)
    for i = 256, 2, -1 do
        local j = math.floor(rng() * i) + 1
        base[i], base[j] = base[j], base[i]
    end
    for i = 0, 511 do perm[i] = base[(i % 256) + 1] end
end

local function noise2D(x, y)
    local xi = math.floor(x) % 256
    local yi = math.floor(y) % 256
    xi = xi >= 0 and xi or (256 + xi)
    yi = yi >= 0 and yi or (256 + yi)

    local xf = x - math.floor(x)
    local yf = y - math.floor(y)

    local u = fade(xf)
    local v = fade(yf)

    local aa = perm[(perm[xi] + yi) % 256]
    local ab = perm[(perm[xi] + yi + 1) % 256]
    local ba = perm[(perm[xi + 1] + yi) % 256]
    local bb = perm[(perm[xi + 1] + yi + 1) % 256]

    local x1 = lerp(grad(aa, xf, yf),     grad(ba, xf - 1, yf),     u)
    local x2 = lerp(grad(ab, xf, yf - 1), grad(bb, xf - 1, yf - 1), u)
    return lerp(x1, x2, v) -- range roughly [-1, 1]
end

-- Layered fractal noise
local function fbm(x, y, octaves, persistence, lacunarity)
    local total    = 0
    local frequency = 1
    local amplitude = 1
    local maxVal   = 0
    for _ = 1, octaves do
        total    = total + noise2D(x * frequency, y * frequency) * amplitude
        maxVal   = maxVal + amplitude
        amplitude = amplitude * persistence
        frequency = frequency * lacunarity
    end
    return total / maxVal
end

-- ---------------------------------------------------------------------------
-- Public API: Depth queries
-- ---------------------------------------------------------------------------

--- Get the ocean depth at a world XZ position.
-- @param x number  World X
-- @param z number  World Z
-- @return number   Depth (negative). 0 = surface, -200 = deep floor.
function OceanGenerator.getDepth(x, z)
    local dist = math.sqrt(x * x + z * z)

    -- On or inside the island: no ocean depth
    if dist < Config.islandRadius then
        return 0
    end

    -- Normalised distance from island edge into ocean (0 .. 1+)
    local t = (dist - Config.islandRadius) / (Config.oceanRadius - Config.islandRadius)
    t = math.clamp(t, 0, 1)

    -- Continental shelf: gradual slope that steepens
    local shelf = -(20 + t * t * 160) -- -20 near shore, -180 far out

    -- Noise variation: shelves, ridges, bumps
    local n1 = fbm(x * 0.0015 + Config.shelfSeed, z * 0.0015, 4, 0.5, 2.0) * 25
    local n2 = fbm(x * 0.006   + Config.shelfSeed, z * 0.006,   3, 0.5, 2.0) * 8

    -- Trenches: deep cuts in the far ocean
    local trenchNoise = fbm(x * 0.0008 + Config.trenchSeed, z * 0.0008, 2, 0.5, 2.5)
    local trench = 0
    if t > 0.4 and trenchNoise < -0.3 then
        trench = trenchNoise * 40
    end

    -- Shoals: raised areas near shore
    local shoalNoise = fbm(x * 0.003 + Config.shoalSeed, z * 0.003, 3, 0.5, 2.0)
    local shoal = 0
    if t < 0.3 and shoalNoise > 0.35 then
        shoal = shoalNoise * 15
    end

    local depth = shelf + n1 + n2 + trench + shoal

    -- Channel guarantee: if we are inside the channel corridor, enforce minimum depth
    if OceanGenerator.isInChannel(x, z) then
        depth = math.min(depth, Config.channelDepth)
    end

    -- Clamp
    depth = math.clamp(depth, Config.floorDepth, Config.surfaceLevel)
    return depth
end

-- ---------------------------------------------------------------------------
-- Channel helpers
-- ---------------------------------------------------------------------------

local channelAngle = 0       -- radians, set during generate()
local channelHalfWidth = Config.channelWidth * 0.5

--- Check whether a position lies inside the navigable channel.
function OceanGenerator.isInChannel(x, z)
    -- Channel is a straight corridor from dock (origin) outward at channelAngle
    local dist = math.sqrt(x * x + z * z)
    if dist < Config.islandRadius - 20 then return false end
    if dist > Config.oceanRadius then return false end

    -- Project position onto channel direction vector
    local dirX = math.cos(channelAngle)
    local dirZ = math.sin(channelAngle)
    -- Perpendicular distance from the channel centre line
    local perp = math.abs(-dirZ * x + dirX * z)
    return perp <= channelHalfWidth
end

-- ---------------------------------------------------------------------------
-- Spawn helpers
-- ---------------------------------------------------------------------------

--- Resolve Roblox services safely.
local function resolveServices(ws)
    Terrain = ws:FindFirstChildOfClass("Terrain")
    if not Terrain then
        warn("[OceanGenerator] No Terrain found in workspace")
    end
    local ok1, rs = pcall(function() return game:GetService("RunService") end)
    if ok1 then RunService = rs end
    local ok2, cs = pcall(function() return game:GetService("CollectionService") end)
    if ok2 then CollectionService = cs end
end

--- Tag an instance using CollectionService if available.
local function tag(instance, tagName)
    if CollectionService then
        CollectionService:AddTag(instance, tagName)
    end
end

--- Add an attribute safely.
local function setAttr(instance, name, value)
    instance:SetAttribute(name, value)
end

-- Spawn a bell buoy at the harbour entrance.
local function createBellBuoy(position)
    local buoy = Instance.new("Part")
    buoy.Name       = "BellBuoy"
    buoy.Shape      = Enum.PartType.Cylinder
    buoy.Size       = Vector3.new(4, 4, 4)
    buoy.Color      = Color3.fromRGB(220, 200, 50)
    buoy.Material   = Enum.Material.Metal
    buoy.Anchored   = true
    buoy.CanCollide = true
    buoy.Position   = position
    buoy.Parent     = workspace

    -- Bell sphere on top
    local bell = Instance.new("Part")
    bell.Name       = "Bell"
    bell.Shape      = Enum.PartType.Ball
    bell.Size       = Vector3.new(2.5, 2.5, 2.5)
    bell.Color      = Color3.fromRGB(200, 170, 30)
    bell.Material   = Enum.Material.Metal
    bell.Anchored   = true
    bell.CanCollide = false
    bell.Position   = position + Vector3.new(0, 4, 0)
    bell.Parent     = buoy

    -- Point light
    local light = Instance.new("PointLight")
    light.Range   = 40
    light.Brightness = 2
    light.Color   = Color3.fromRGB(255, 240, 200)
    light.Parent  = bell

    -- Flash via attribute (systems can read this at night)
    setAttr(buoy, "Flashes", true)
    setAttr(buoy, "FlashInterval", 4)

    tag(buoy, "NavigationMarker")
    setAttr(buoy, "Type", "Bell")
    return buoy
end

-- Spawn a channel marker buoy (red = port / left returning, green = starboard / right returning).
local function createChannelBuoy(position, color3)
    local buoy = Instance.new("Part")
    buoy.Name       = "ChannelBuoy"
    buoy.Shape      = Enum.PartType.Cylinder
    buoy.Size       = Vector3.new(3, 3, 3)
    buoy.Color      = color3
    buoy.Material   = Enum.Material.SmoothPlastic
    buoy.Anchored   = true
    buoy.CanCollide = true
    buoy.Position   = position
    buoy.Parent     = workspace

    local light = Instance.new("PointLight")
    light.Range    = 30
    light.Brightness = 1.5
    light.Color    = color3
    light.Parent   = buoy

    setAttr(buoy, "Flashes", true)
    setAttr(buoy, "FlashInterval", 2)

    tag(buoy, "NavigationMarker")
    local side = (color3 == Color3.fromRGB(200, 30, 30)) and "Port" or "Starboard"
    setAttr(buoy, "Side", side)
    return buoy
end

-- Spawn a rock hazard.
local function createRock(position, size)
    local rock = Instance.new("Part")
    rock.Name       = "Rock"
    rock.Shape      = Enum.PartType.Ball
    rock.Size       = Vector3.new(size, size * 0.7, size)
    rock.Color      = Color3.fromRGB(90, 88, 85)
    rock.Material   = Enum.Material.Slate
    rock.Anchored   = true
    rock.CanCollide = true
    rock.Position   = position
    rock.Parent     = workspace

    tag(rock, "NavigationHazard")
    tag(rock, "Rock")
    setAttr(rock, "HazardType", "rock")
    setAttr(rock, "Size", size)

    table.insert(generatedHazards, {
        position = position,
        size     = size,
        type     = "rock",
    })
    return rock
end

-- Spawn a shoal area (shallow water hazard).
local function createShoal(center, radius)
    local marker = Instance.new("Part")
    marker.Name        = "Shoal"
    marker.Shape       = Enum.PartType.Cylinder
    marker.Size        = Vector3.new(radius * 2, 1, radius * 2)
    marker.Color       = Color3.fromRGB(180, 170, 130)
    marker.Material    = Enum.Material.Sand
    marker.Transparency= 0.6
    marker.Anchored    = true
    marker.CanCollide  = false
    marker.Position    = center
    marker.Parent      = workspace

    tag(marker, "NavigationHazard")
    tag(marker, "Shoal")
    setAttr(marker, "HazardType", "shoal")
    setAttr(marker, "Radius", radius)

    table.insert(generatedHazards, {
        position = center,
        size     = radius,
        type     = "shoal",
    })
    return marker
end

-- Spawn a kelp bed (slow zone + fish zone).
local function createKelpBed(center, radius)
    local zone = Instance.new("Part")
    zone.Name         = "KelpBed"
    zone.Shape        = Enum.PartType.Cylinder
    zone.Size         = Vector3.new(radius * 2, 1, radius * 2)
    zone.Color        = Color3.fromRGB(40, 90, 40)
    zone.Material     = Enum.Material.Grass
    zone.Transparency = 0.8
    zone.Anchored     = true
    zone.CanCollide   = false
    zone.Position     = center
    zone.Parent       = workspace

    tag(zone, "SlowZone")
    tag(zone, "FishZone")
    setAttr(zone, "SlowFactor", Config.kelpBeds.slowFactor)
    setAttr(zone, "Radius", radius)

    table.insert(generatedHazards, {
        position = center,
        size     = radius,
        type     = "kelp",
    })
    return zone
end

-- Spawn a hidden wreck site.
local function createWreck(position)
    local wreck = Instance.new("Model")
    wreck.Name   = "WreckSite"
    wreck.Parent = workspace

    -- Hull
    local hull = Instance.new("Part")
    hull.Name       = "Hull"
    hull.Size       = Vector3.new(20, 6, 8)
    hull.Color      = Color3.fromRGB(60, 50, 35)
    hull.Material   = Enum.Material.WoodPlanks
    hull.Anchored   = true
    hull.CanCollide = false
    hull.Position   = position
    hull.Parent     = wreck

    -- Mast
    local mast = Instance.new("Part")
    mast.Name       = "Mast"
    mast.Size       = Vector3.new(1, 30, 1)
    mast.Color      = Color3.fromRGB(70, 55, 35)
    mast.Material   = Enum.Material.Wood
    mast.Anchored   = true
    mast.CanCollide = false
    mast.CFrame     = CFrame.new(position + Vector3.new(0, 12, 0)) * CFrame.Angles(0.3, 0, 0.4)
    mast.Parent     = wreck

    tag(wreck, "WreckSite")
    setAttr(wreck, "HasSalvage", true)
    setAttr(wreck, "RareFish", true)

    table.insert(generatedZones, {
        center     = position,
        radius     = 25,
        species    = { "rare_cod", "bass", "eel" },
        depthRange = { -30, -80 },
        density    = 0.3,
        zoneType   = "wreck",
    })
    return wreck
end

-- Spawn a fish zone marker (invisible, holds data for FishingSystem).
local function createFishZone(center, radius, speciesList, depthRange, density, zoneType)
    local zone = Instance.new("Part")
    zone.Name         = "FishZone"
    zone.Transparency = 1
    zone.Anchored     = true
    zone.CanCollide   = false
    zone.Size         = Vector3.new(radius * 2, 1, radius * 2)
    zone.Position     = center
    zone.Parent       = workspace

    tag(zone, "FishZone")

    -- Store species as a comma-joined attribute (attributes are simple values)
    setAttr(zone, "Species", table.concat(speciesList, ","))
    setAttr(zone, "Radius", radius)
    setAttr(zone, "DepthMin", depthRange[1])
    setAttr(zone, "DepthMax", depthRange[2])
    setAttr(zone, "Density", density)
    setAttr(zone, "ZoneType", zoneType)

    table.insert(generatedZones, {
        center     = center,
        radius     = radius,
        species    = speciesList,
        depthRange = depthRange,
        density    = density,
        zoneType   = zoneType,
    })
    return zone
end

-- ---------------------------------------------------------------------------
-- Terrain helpers
-- ---------------------------------------------------------------------------

--- Fill a block of water terrain.
local function fillWater(terrain, cf, size)
    if terrain then
        terrain:FillBlock(cf, size, Enum.Material.Water)
    end
end

--- Carve ocean floor by reading depth and setting terrain height.
local function sculptOceanFloor(terrain, originX, originZ, step)
    if not terrain then return end
    for x = originX, originX + Config.oceanRadius, step do
        for z = originZ - Config.oceanRadius, originZ + Config.oceanRadius, step do
            local dist = math.sqrt(x * x + z * z)
            if dist > Config.islandRadius and dist <= Config.oceanRadius then
                local depth = OceanGenerator.getDepth(x, z)
                -- Write a small terrain column from depth to surface as water
                local height = Config.surfaceLevel - depth
                if height > 0 then
                    local pos = CFrame.new(x, depth + height * 0.5, z)
                    terrain:FillBlock(pos, Vector3.new(step, height, step), Enum.Material.Water)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Channel generation
-- ---------------------------------------------------------------------------

local function generateChannel(rng)
    -- Pick a channel angle that avoids the main island mass (offset slightly)
    channelAngle = math.rad(35)  -- fixed angle for determinism

    local dirX = math.cos(channelAngle)
    local dirZ = math.sin(channelAngle)

    -- Build waypoint list from dock to open ocean
    local startDist = Config.islandRadius - 10
    local endDist   = Config.oceanRadius - 20
    local steps     = 12
    for i = 0, steps do
        local d = startDist + (endDist - startDist) * (i / steps)
        table.insert(channelPath, Vector3.new(dirX * d, 0, dirZ * d))
    end

    dockPosition = Vector3.new(dirX * (Config.islandRadius - 30), 0, dirZ * (Config.islandRadius - 30))

    -- Place channel buoys along both sides, spaced every ~150 studs
    local buoySpacing = 150
    for d = startDist, endDist, buoySpacing do
        -- Port side (left when returning) = red
        local px = dirX * d + (-dirZ) * channelHalfWidth
        local pz = dirZ * d + ( dirX) * channelHalfWidth
        createChannelBuoy(Vector3.new(px, 1, pz), Color3.fromRGB(200, 30, 30))

        -- Starboard side = green
        local sx = dirX * d + ( dirZ) * channelHalfWidth
        local sz = dirZ * d + (-dirX) * channelHalfWidth
        createChannelBuoy(Vector3.new(sx, 1, sz), Color3.fromRGB(30, 200, 60))
    end

    -- Bell buoy at the ocean entrance of the channel
    local entranceX = dirX * endDist
    local entranceZ = dirZ * endDist
    createBellBuoy(Vector3.new(entranceX, 2, entranceZ))
end

-- ---------------------------------------------------------------------------
-- Main generation
-- ---------------------------------------------------------------------------

--- Generate the full ocean. Call once during world load.
-- @param ws Instance  The Roblox workspace (or World folder).
function OceanGenerator.generate(ws)
    if generated then
        warn("[OceanGenerator] Already generated — skipping")
        return
    end

    resolveServices(ws)
    local rng = makeRng(20260803)

    -- 1. Fill water terrain from island edge to ocean radius
    if Terrain then
        local center = CFrame.new(0, Config.floorDepth * 0.5, 0)
        local size   = Vector3.new(Config.oceanRadius * 2, -Config.floorDepth, Config.oceanRadius * 2)
        fillWater(Terrain, center, size)
        -- Sculpt floor with depth variation
        sculptOceanFloor(Terrain, -Config.oceanRadius, -Config.oceanRadius, Config.voxelSize * 8)
    end

    -- 2. Channel (before hazards so we can avoid placing hazards in it)
    generateChannel(rng)

    -- 3. Rocks
    for _ = 1, Config.rocks.count do
        local angle = rng() * math.pi * 2
        local dist  = Config.islandRadius + 30 + rng() * (Config.oceanRadius - Config.islandRadius - 60)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        -- Skip if inside channel
        if not OceanGenerator.isInChannel(x, z) then
            local size    = Config.rocks.minSize + rng() * (Config.rocks.maxSize - Config.rocks.minSize)
            local depth   = OceanGenerator.getDepth(x, z)
            local surface = depth + size * 0.5 -- partially submerged
            if surface > -2 then surface = -2 end -- peek above water slightly
            createRock(Vector3.new(x, math.min(surface, 2), z), size)
        end
    end

    -- 4. Shoals
    for _ = 1, Config.shoals.count do
        local angle = rng() * math.pi * 2
        local dist  = Config.islandRadius + 40 + rng() * (Config.oceanRadius * 0.5)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        if not OceanGenerator.isInChannel(x, z) then
            local radius = 20 + rng() * 40
            local depth  = OceanGenerator.getDepth(x, z)
            createShoal(Vector3.new(x, depth + 1, z), radius)
        end
    end

    -- 5. Kelp beds
    for _ = 1, Config.kelpBeds.count do
        local angle = rng() * math.pi * 2
        local dist  = Config.islandRadius + 50 + rng() * (Config.oceanRadius * 0.4)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        local radius = Config.kelpBeds.radius * (0.7 + rng() * 0.6)
        local depth  = OceanGenerator.getDepth(x, z)
        local kelp   = createKelpBed(Vector3.new(x, depth + 2, z), radius)

        -- Also a fish zone for kelp-dwelling species
        local cfg = Config.fishZones.kelpBeds
        createFishZone(
            Vector3.new(x, depth + 2, z),
            radius,
            cfg.species,
            cfg.depthRange,
            0.7,
            "kelp"
        )
    end

    -- 6. Wreck sites
    for _ = 1, Config.wrecks.count do
        local angle = rng() * math.pi * 2
        local dist  = Config.islandRadius + 200 + rng() * (Config.oceanRadius * 0.4)
        local x = math.cos(angle) * dist
        local z = math.sin(angle) * dist
        local depth = OceanGenerator.getDepth(x, z)
        createWreck(Vector3.new(x, depth + 3, z))
    end

    -- 7. Halibut grounds (deep water zones)
    do
        local cfg = Config.fishZones.halibutGrounds
        for _ = 1, cfg.count do
            local angle = rng() * math.pi * 2
            local dist  = Config.islandRadius + 300 + rng() * (Config.oceanRadius * 0.4)
            local x     = math.cos(angle) * dist
            local z     = math.sin(angle) * dist
            local depth = OceanGenerator.getDepth(x, z)
            local r     = 40 + rng() * 40
            createFishZone(Vector3.new(x, depth + 5, z), r, cfg.species, cfg.depthRange, 0.5, "halibut")
        end
    end

    -- 8. Salmon run (near-surface, seasonal)
    do
        local cfg = Config.fishZones.salmonRun
        for _ = 1, cfg.count do
            local angle = rng() * math.pi * 2
            local dist  = Config.islandRadius + 80 + rng() * 300
            local x     = math.cos(angle) * dist
            local z     = math.sin(angle) * dist
            local r     = 50 + rng() * 30
            local zone  = createFishZone(Vector3.new(x, -2, z), r, cfg.species, cfg.depthRange, 0.6, "salmon")
            if cfg.seasonal then
                setAttr(zone, "Seasonal", true)
                setAttr(zone, "Season", "summer")
            end
        end
    end

    -- 9. Crab grounds (shallow-ish bottom)
    do
        local cfg = Config.fishZones.crabGrounds
        for _ = 1, cfg.count do
            local angle = rng() * math.pi * 2
            local dist  = Config.islandRadius + 40 + rng() * 200
            local x     = math.cos(angle) * dist
            local z     = math.sin(angle) * dist
            local depth = OceanGenerator.getDepth(x, z)
            local r     = 30 + rng() * 20
            createFishZone(Vector3.new(x, depth + 1, z), r, cfg.species, cfg.depthRange, 0.5, "crab")
        end
    end

    -- 10. Open-ocean scatter fish zones (cod, salmon, tuna)
    do
        local cfg = Config.fishZones.openOcean
        local openCount = 8
        for _ = 1, openCount do
            local angle = rng() * math.pi * 2
            local dist  = Config.islandRadius + 400 + rng() * (Config.oceanRadius - Config.islandRadius - 450)
            local x     = math.cos(angle) * dist
            local z     = math.sin(angle) * dist
            local r     = 60 + rng() * 40
            createFishZone(Vector3.new(x, -10, z), r, cfg.species, cfg.depthRange, 0.4, "openocean")
        end
    end

    generated = true
    print(("[OceanGenerator] Ocean generated: %d hazards, %d fish zones")
        :format(#generatedHazards, #generatedZones))
end

-- ---------------------------------------------------------------------------
-- Query API
-- ---------------------------------------------------------------------------

--- Return all fish zones created during generation.
-- @return table  Array of zone tables { center, radius, species, depthRange, density, zoneType }
function OceanGenerator.getFishZones()
    return generatedZones
end

--- Return navigation hazards within `radius` studs of `position`.
-- @param position Vector3
-- @param radius number
-- @return table  Array of { position, size, type }
function OceanGenerator.getHazardsNear(position, radius)
    local result = {}
    local r2 = radius * radius
    for _, hz in ipairs(generatedHazards) do
        local dx = hz.position.X - position.X
        local dz = hz.position.Z - position.Z
        if dx * dx + dz * dz <= r2 then
            table.insert(result, hz)
        end
    end
    return result
end

--- Return the channel waypoints from dock to open ocean.
-- @return table  Array of Vector3
function OceanGenerator.getChannelPath()
    return channelPath
end

--- Return the dock position where the channel meets land.
-- @return Vector3
function OceanGenerator.getDockPosition()
    return dockPosition
end

return OceanGenerator
