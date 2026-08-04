--[[
    VesselSystem/VesselTypes.lua
    Slackwater — Vessel Configuration Catalog

    "A skiff is a prayer. A cutter is a living. A longliner is a home.
     A seiner is a harvest. A factory trawler is a town that floats."

    ───────────────────────────────────────────────
    Each vessel type defines every physical and gameplay parameter.
    VesselPhysics reads these to configure buoyancy, drag, and handling.
    VesselSpawner reads these to build the boat model.
    HelmController reads these for throttle/rudder response curves.
    VesselDamage reads these for per-section hull HP.

    ERA GATING:
      Era 1 — Skiff       (start of game)
      Era 2 — Cutter      (after first vessel upgrade)
      Era 3 — Longliner   (mid-game)
      Era 4 — Seine Boat  (late-game)
      Era 5 — Factory Trawler (end-game)

    API:
        VesselTypes.get(era) -> VesselConfig
        VesselTypes.getAll() -> table<int, VesselConfig>
        VesselTypes.getByKey(key) -> VesselConfig
        VesselTypes.getEraRequirement(era) -> number (building era needed)
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local VesselTypes = {}

----------------------------------------------------------------
-- VESSEL DEFINITIONS
----------------------------------------------------------------

-- Each vessel has:
--   key            — string identifier
--   era            — building era that unlocks this vessel (1-5)
--   displayName    — pretty name for UI
--   description    — flavor text
--   hullMesh       — asset ID string for the hull mesh
--   mass           — total mass in Roblox units (affects physics)
--   topSpeed       — max speed in studs/sec at full throttle
--   reverseSpeed   — max reverse speed in studs/sec
--   acceleration   — throttle response curve multiplier (0-1, higher = snappier)
--   turnRate       — max rudder deflection effect (degrees/sec at speed)
--   turnSpeedFactor— how much speed affects turning (0 = turns same at any speed, 1 = fully speed-dependent)
--   hullHP         — total hull hit points
--   sectionHP      — { bow=N, port=N, starboard=N, stern=N, keel=N }
--   draft          — how deep the keel sits below waterline (studs)
--   cargoCapacity  — units of fish/cargo the hold can carry
--   passengers     — max player seats
--   buoyancyPoints — array of Vector3 offsets (relative to hull center) for buoyancy probes
--   dragCoeff      — water resistance coefficient (higher = more drag)
--   lateralDrag    — sideways resistance (prevents excessive sideways sliding)
--   windArea       — frontal area exposed to wind (affects wind drift)
--   maxLeanAngle   — max safe heel/roll angle before capsize risk (degrees)
--   capsizeThreshold — wave angle at which capsize becomes possible (degrees from vertical)
--   shallowDraft   — if true, boat can enter shallow water without grounding
--   gearMounts     — what fishing gear can be mounted
--   helmOffset     — Vector3 offset from hull center to helm seat
--   spawnOffset    — Vector3 world offset from pier origin for spawning

----------------------------------------------------------------

local VESSELS = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 1: SKIFF
-- Small, fast, fragile. 1-2 passengers. A prayer on the water.
-- ═══════════════════════════════════════════════════════════════════════════

VESSELS[1] = {
    key = "skiff",
    era = 1,
    displayName = "Skiff",
    description = "A flat-bottomed skiff. Light enough to drag across mud, fast enough to outrun weather you should've seen coming. She leaks. She's yours.",
    hullMesh = "rbxassetid://0",  -- placeholder; VesselSpawner builds from primitives
    mass = 800,
    topSpeed = 25,
    reverseSpeed = 8,
    acceleration = 0.85,    -- snappy throttle response
    turnRate = 45,          -- turns on a dime
    turnSpeedFactor = 0.5,  -- still turns at low speed (flat bottom)
    hullHP = 100,
    sectionHP = {
        bow = 30,
        port = 25,
        starboard = 25,
        stern = 20,
        keel = 15,
    },
    draft = 1.5,
    cargoCapacity = 50,
    passengers = 2,
    buoyancyPoints = {
        Vector3.new(0, -0.5, 4),    -- bow
        Vector3.new(0, -0.5, 0),    -- amidships
        Vector3.new(0, -0.5, -4),   -- stern
        Vector3.new(0.5, -0.5, 2),  -- bow-port
        Vector3.new(-0.5, -0.5, 2), -- bow-starboard
    },
    dragCoeff = 0.8,
    lateralDrag = 2.5,
    windArea = 12,          -- small profile
    maxLeanAngle = 35,
    capsizeThreshold = 55,
    shallowDraft = true,
    gearMounts = { "handline", "pot_trap" },
    helmOffset = Vector3.new(0, 1.5, -2),
    spawnOffset = Vector3.new(0, 0, 0),

    -- Visual/proportions for VesselSpawner
    proportions = {
        length = 16,
        beam = 5,
        height = 3,
        color = Color3.fromRGB(120, 90, 60),
        material = Enum.Material.WoodPlanks,
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 2: CUTTER
-- Medium, versatile. 2-4 passengers. A living.
-- ═══════════════════════════════════════════════════════════════════════════

VESSELS[2] = {
    key = "cutter",
    era = 2,
    displayName = "Cutter",
    description = "A workboat cutter. Beamy enough to carry a load, stiff enough to stand in a blow. The first boat that feels like a boat.",
    hullMesh = "rbxassetid://0",
    mass = 2500,
    topSpeed = 20,
    reverseSpeed = 6,
    acceleration = 0.6,
    turnRate = 30,
    turnSpeedFactor = 0.75,  -- needs way on to steer well
    hullHP = 200,
    sectionHP = {
        bow = 60,
        port = 50,
        starboard = 50,
        stern = 40,
        keel = 45,
    },
    draft = 3.0,
    cargoCapacity = 200,
    passengers = 4,
    buoyancyPoints = {
        Vector3.new(0, -0.8, 6),     -- bow
        Vector3.new(0, -0.8, 2),     -- forward amidships
        Vector3.new(0, -0.8, -2),    -- aft amidships
        Vector3.new(0, -0.8, -6),    -- stern
        Vector3.new(1, -0.8, 3),     -- port bow
        Vector3.new(-1, -0.8, 3),    -- starboard bow
        Vector3.new(1, -0.8, -3),    -- port stern
        Vector3.new(-1, -0.8, -3),   -- starboard stern
    },
    dragCoeff = 1.2,
    lateralDrag = 3.5,
    windArea = 25,
    maxLeanAngle = 45,
    capsizeThreshold = 65,
    shallowDraft = false,
    gearMounts = { "handline", "pot_trap", "trawl_net", "longline_short" },
    helmOffset = Vector3.new(0, 2.5, -4),
    spawnOffset = Vector3.new(0, 0, 0),

    proportions = {
        length = 28,
        beam = 9,
        height = 5,
        color = Color3.fromRGB(90, 80, 70),
        material = Enum.Material.WoodPlanks,
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 3: LONGLINER
-- Large, slow, powerful. 4-8 passengers. A home.
-- ═══════════════════════════════════════════════════════════════════════════

VESSELS[3] = {
    key = "longliner",
    era = 3,
    displayName = "Longliner",
    description = "A longline fishing vessel. Slow to answer the helm, steady in a sea, with a hold that swallows a season's work. Men have lived half their lives on boats like this.",
    hullMesh = "rbxassetid://0",
    mass = 6000,
    topSpeed = 15,
    reverseSpeed = 4,
    acceleration = 0.35,   -- heavy, takes time to get moving
    turnRate = 18,
    turnSpeedFactor = 0.9,  -- barely turns without way on
    hullHP = 400,
    sectionHP = {
        bow = 120,
        port = 90,
        starboard = 90,
        stern = 80,
        keel = 100,
    },
    draft = 5.0,
    cargoCapacity = 500,
    passengers = 8,
    buoyancyPoints = {
        Vector3.new(0, -1.0, 10),    -- bow
        Vector3.new(0, -1.0, 5),     -- forward
        Vector3.new(0, -1.0, 0),     -- amidships
        Vector3.new(0, -1.0, -5),    -- aft
        Vector3.new(0, -1.0, -10),   -- stern
        Vector3.new(1.5, -1.0, 6),   -- port bow
        Vector3.new(-1.5, -1.0, 6),  -- starboard bow
        Vector3.new(1.5, -1.0, -4),  -- port stern
        Vector3.new(-1.5, -1.0, -4), -- starboard stern
        Vector3.new(2, -1.0, 0),     -- port beam
        Vector3.new(-2, -1.0, 0),    -- starboard beam
    },
    dragCoeff = 2.0,
    lateralDrag = 5.0,
    windArea = 50,
    maxLeanAngle = 55,
    capsizeThreshold = 75,  -- very stable
    shallowDraft = false,
    gearMounts = { "longline", "trawl_net", "pot_trap", "handline" },
    helmOffset = Vector3.new(0, 4, -7),
    spawnOffset = Vector3.new(0, 0, 0),

    proportions = {
        length = 44,
        beam = 13,
        height = 8,
        color = Color3.fromRGB(60, 55, 50),
        material = Enum.Material.Metal,
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 4: SEINE BOAT
-- Large, crane-equipped. The harvest.
-- ═══════════════════════════════════════════════════════════════════════════

VESSELS[4] = {
    key = "seine_boat",
    era = 4,
    displayName = "Seine Boat",
    description = "A purse-seine vessel with a hydraulic drum and a crane arm that swings the net like a fist. When the ball is in the water, the whole ocean holds its breath.",
    hullMesh = "rbxassetid://0",
    mass = 9000,
    topSpeed = 14,
    reverseSpeed = 4,
    acceleration = 0.3,
    turnRate = 15,
    turnSpeedFactor = 0.9,
    hullHP = 550,
    sectionHP = {
        bow = 150,
        port = 110,
        starboard = 110,
        stern = 100,
        keel = 130,
    },
    draft = 5.5,
    cargoCapacity = 800,
    passengers = 8,
    buoyancyPoints = {
        Vector3.new(0, -1.2, 12),
        Vector3.new(0, -1.2, 6),
        Vector3.new(0, -1.2, 0),
        Vector3.new(0, -1.2, -6),
        Vector3.new(0, -1.2, -12),
        Vector3.new(2, -1.2, 8),
        Vector3.new(-2, -1.2, 8),
        Vector3.new(2, -1.2, -2),
        Vector3.new(-2, -1.2, -2),
        Vector3.new(2.5, -1.2, 0),
        Vector3.new(-2.5, -1.2, 0),
        Vector3.new(2, -1.2, -10),
        Vector3.new(-2, -1.2, -10),
    },
    dragCoeff = 2.5,
    lateralDrag = 6.0,
    windArea = 65,
    maxLeanAngle = 50,
    capsizeThreshold = 70,
    shallowDraft = false,
    gearMounts = { "purse_seine", "trawl_net", "longline" },
    helmOffset = Vector3.new(0, 5, -8),
    spawnOffset = Vector3.new(0, 0, 0),

    proportions = {
        length = 50,
        beam = 15,
        height = 9,
        color = Color3.fromRGB(50, 50, 55),
        material = Enum.Material.Metal,
    },

    -- Special: crane arm configuration
    craneConfig = {
        boomLength = 15,
        liftCapacity = 2000,
        swingRange = 270,  -- degrees
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 5: FACTORY TRAWLER
-- Massive, processes catch at sea. A town that floats.
-- ═══════════════════════════════════════════════════════════════════════════

VESSELS[5] = {
    key = "factory_trawler",
    era = 5,
    displayName = "Factory Trawler",
    description = "A factory trawler. She doesn't just catch fish — she processes, freezes, and stores them. A cannery that goes to sea. The town follows the fish now.",
    hullMesh = "rbxassetid://0",
    mass = 18000,
    topSpeed = 12,
    reverseSpeed = 3,
    acceleration = 0.2,    -- very slow to accelerate
    turnRate = 10,
    turnSpeedFactor = 0.95,
    hullHP = 800,
    sectionHP = {
        bow = 220,
        port = 160,
        starboard = 160,
        stern = 140,
        keel = 200,
    },
    draft = 7.0,
    cargoCapacity = 2000,
    passengers = 12,
    buoyancyPoints = {
        Vector3.new(0, -1.5, 16),
        Vector3.new(0, -1.5, 10),
        Vector3.new(0, -1.5, 4),
        Vector3.new(0, -1.5, -2),
        Vector3.new(0, -1.5, -8),
        Vector3.new(0, -1.5, -14),
        Vector3.new(3, -1.5, 12),
        Vector3.new(-3, -1.5, 12),
        Vector3.new(3, -1.5, 4),
        Vector3.new(-3, -1.5, 4),
        Vector3.new(3, -1.5, -4),
        Vector3.new(-3, -1.5, -4),
        Vector3.new(3, -1.5, -12),
        Vector3.new(-3, -1.5, -12),
        Vector3.new(3.5, -1.5, 0),
        Vector3.new(-3.5, -1.5, 0),
    },
    dragCoeff = 3.5,
    lateralDrag = 8.0,
    windArea = 100,
    maxLeanAngle = 60,
    capsizeThreshold = 80,  -- extremely stable
    shallowDraft = false,
    gearMounts = { "factory_trawl", "purse_seine", "longline" },
    helmOffset = Vector3.new(0, 7, -12),
    spawnOffset = Vector3.new(0, 0, 0),

    proportions = {
        length = 64,
        beam = 18,
        height = 12,
        color = Color3.fromRGB(40, 45, 50),
        material = Enum.Material.Metal,
    },

    -- Special: onboard processing plant
    factoryConfig = {
        processRate = 50,       -- units of fish processed per minute
        freezeCapacity = 500,   -- frozen storage units
        fuelConsumption = 2.0,  -- fuel per minute while operating
    },
}

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Get the vessel configuration for a given era.
    @param era number (1-5)
    @return table vessel config or nil
]]
function VesselTypes.get(era)
    return VESSELS[era]
end

--[[
    Get all vessel configurations.
    @return table<int, VesselConfig>
]]
function VesselTypes.getAll()
    return VESSELS
end

--[[
    Get a vessel configuration by its string key.
    @param key string (e.g. "skiff", "cutter")
    @return table vessel config or nil
]]
function VesselTypes.getByKey(key)
    for _, vessel in pairs(VESSELS) do
        if vessel.key == key then
            return vessel
        end
    end
    return nil
end

--[[
    Get the building era required to unlock a vessel.
    @param era number (1-5)
    @return number building era
]]
function VesselTypes.getEraRequirement(era)
    local vessel = VESSELS[era]
    return vessel and vessel.era or 1
end

--[[
    Get a list of all vessel keys for iteration.
    @return table<string> ordered keys
]]
function VesselTypes.getKeys()
    local keys = {}
    for i = 1, 5 do
        if VESSELS[i] then
            table.insert(keys, VESSELS[i].key)
        end
    end
    return keys
end

return VesselTypes
