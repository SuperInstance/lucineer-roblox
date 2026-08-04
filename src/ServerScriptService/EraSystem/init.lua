--!strict
--[[
    EraSystem — Slackwater's Progression Backbone
    =============================================
    Manages two parallel progression tracks:

    1. TECHNOLOGY ERAS (0–6) — from levers to autonomous agents.
       Each era unlocks recipes, components, agents, and world changes.

       0 — Simple Machines      (lever, pulley, wheel, wedge, screw)
       1 — Power Transmission   (shafts, belts, gears, fluid pressure)
       2 — Electricity          (generators, wire, switches, lamps, motors)
       3 — Control Systems      (relays, sensors, timers, logic gates)
       4 — Programmable Logic   (Arduino, ESP32, sensors, vibe-coding)
       5 — Networked Systems    (wireless, protocols, distributed sensing)
       6 — Autonomous Agents    (deep research bots, fleet management)

    2. BUILDING ERAS (1–5) — from driftwood shelters to lighthouse restoration.
       Parallel to tech eras but tracked separately. Lucineier cares about
       what you've built, not just what you can wire.

       1 — Driftwood and Salvage   (beachcomber vernacular)
       2 — Frame and Plank         (timber-frame carpentry)
       3 — Stone and Mortar        (masonry, permanence)
       4 — Metal and Machine       (industrial maritime)
       5 — Light and Signal        (electricity, lighthouse restoration)

    Usage:
        local EraSystem = require(ServerScriptService.EraSystem)
        EraSystem.init()

        -- Tech era API (existing)
        EraSystem.unlockEra(playerId, 2)
        local era = EraSystem.getCurrentEra(playerId)
        local canBuild = EraSystem.canBuild(playerId, "generator")
        EraSystem.onBuild(playerId, "waterwheel")

        -- Building era API (new)
        local bera = EraSystem.getBuildingEra(playerId)
        EraSystem.onBuildingEraBuild(playerId, "fire_pit")
        local ctx = EraSystem.getAssessmentContext(playerId)

    Dependencies:
        - ReplicatedStorage.Lucineer.Http (for D1 persistence)
        - ServerScriptService.EraSystem.Recipes
]]

local Http = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("Http"))
local Recipes = require(script:WaitForChild("Recipes"))

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ServerStorage = game:GetService("ServerStorage")

-- Bug 1 fix: MEMORY_URL removed. Http.post/get already prepends the configured
-- worker URL. Passing a full URL caused double-URL construction (404s).
-- The relay worker (https://lucineer-relay.casey-digennaro.workers.dev) is
-- configured at init time via Http.configure() in LucineerServer/init.lua.

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA ADVANCEMENT CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Tech era advancement thresholds: era → { minBuilds, minBondLevel }
-- Players advance when they have enough builds in the current era AND
-- sufficient bond level with Lucineer.
local TECH_ERA_REQUIREMENTS = {
    [0] = { minBuilds = 3,  minBondLevel = 1 },   -- Simple Machines → Power Transmission
    [1] = { minBuilds = 5,  minBondLevel = 2 },   -- Power → Electricity
    [2] = { minBuilds = 7,  minBondLevel = 3 },   -- Electricity → Control Systems
    [3] = { minBuilds = 10, minBondLevel = 4 },   -- Control → Programmable
    [4] = { minBuilds = 12, minBondLevel = 5 },   -- Programmable → Networked
    [5] = { minBuilds = 15, minBondLevel = 6 },   -- Networked → Autonomous
    -- Era 6 is the final era — no advancement
}

-- Material tiers unlocked per tech era. Each era unlocks a new tier
-- of building materials for the player to use.
local MATERIAL_TIERS = {
    [0] = {
        "wood", "stone", "rope", "fiber", "leather", "cloth",
        "metal_fragment", "glass", "water", "sand", "clay_raw",
    },
    [1] = {
        "iron_bar", "copper_ore", "tin", "bronze", "tar",
        "ceramic", "pitch", "wax", "paper", "spring",
    },
    [2] = {
        "copper_wire", "magnet", "zinc", "acid", "carbon",
        "semiconductor", "crystal", "electrum",
    },
    [3] = {
        "circuit_board", "photoresistor", "infrared_sensor", "piezo",
        "diaphragm", "optocoupler", "electret", "lens",
    },
    [4] = {
        "plastic", "potentiometer", "speaker", "camera", "boiler",
    },
    [5] = {
        "fiber_optic", "lens_fresnel", "filament", "bulb_glass",
        "insulator_porc", "antenna_wire",
    },
    [6] = {
        "circuit_board", "semiconductor", "fiber_optic",
        "ai_core_crystal", "quantum_dust",
    },
}

-- Lighting and atmosphere presets per tech era for visual progression
local VISUAL_PRESETS = {
    [0] = {
        brightness = 1.0,
        ambient = Color3.fromRGB(120, 130, 140),
        outdoorAmbient = Color3.fromRGB(110, 120, 130),
        fogEnd = 500,
        timeOfDay = 8,
        colorCorrection = { brightness = -0.02, contrast = 0.05, saturation = -0.1, tint = Color3.fromRGB(245, 230, 210) },
    },
    [1] = {
        brightness = 1.05,
        ambient = Color3.fromRGB(130, 135, 145),
        outdoorAmbient = Color3.fromRGB(125, 130, 140),
        fogEnd = 600,
        timeOfDay = 9,
        colorCorrection = { brightness = 0, contrast = 0.08, saturation = -0.05, tint = Color3.fromRGB(240, 235, 220) },
    },
    [2] = {
        brightness = 1.1,
        ambient = Color3.fromRGB(140, 145, 160),
        outdoorAmbient = Color3.fromRGB(135, 140, 155),
        fogEnd = 700,
        timeOfDay = 10,
        colorCorrection = { brightness = 0.02, contrast = 0.1, saturation = 0, tint = Color3.fromRGB(230, 235, 245) },
    },
    [3] = {
        brightness = 1.15,
        ambient = Color3.fromRGB(150, 150, 170),
        outdoorAmbient = Color3.fromRGB(145, 145, 165),
        fogEnd = 800,
        timeOfDay = 11,
        colorCorrection = { brightness = 0.04, contrast = 0.15, saturation = 0.05, tint = Color3.fromRGB(220, 230, 250) },
    },
    [4] = {
        brightness = 1.2,
        ambient = Color3.fromRGB(160, 155, 180),
        outdoorAmbient = Color3.fromRGB(155, 150, 175),
        fogEnd = 900,
        timeOfDay = 12,
        colorCorrection = { brightness = 0.06, contrast = 0.2, saturation = 0.1, tint = Color3.fromRGB(210, 225, 255) },
    },
    [5] = {
        brightness = 1.25,
        ambient = Color3.fromRGB(170, 165, 190),
        outdoorAmbient = Color3.fromRGB(165, 160, 185),
        fogEnd = 1000,
        timeOfDay = 13,
        colorCorrection = { brightness = 0.08, contrast = 0.25, saturation = 0.15, tint = Color3.fromRGB(200, 220, 255) },
    },
    [6] = {
        brightness = 1.3,
        ambient = Color3.fromRGB(180, 175, 200),
        outdoorAmbient = Color3.fromRGB(175, 170, 195),
        fogEnd = 1200,
        timeOfDay = 14,
        colorCorrection = { brightness = 0.1, contrast = 0.3, saturation = 0.2, tint = Color3.fromRGB(195, 215, 255) },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════

local ERAS = {}

-- Era 0: Simple Machines
ERAS[0] = {
    number = 0,
    name = "Simple Machines",
    tagline = "Force, redirected.",
    description = "The beginning of all technology. A lever is just a stick that thinks.",
    agentSpecialization = "Mechanic",
    unlockRequirements = {
        description = "Available from the start.",
        triggers = {},
    },
    availableComponents = {
        "lever", "pulley", "wheel", "wedge", "screw", "inclined_plane",
        "fulcrum", "axle", "rope", "wooden_gear", "cam", "crank",
    },
    agentUnlocks = { "mechanic" },
    worldChanges = {
        ambientSound = "wind_and_waves",
        skyPreset = "dawn_coastal",
        particleDensity = 0.3,
    },
}

-- Era 1: Power Transmission
ERAS[1] = {
    number = 1,
    name = "Power Transmission",
    tagline = "Energy, delivered.",
    description = "Shafts, belts, and gears — moving rotational force across distance.",
    agentSpecialization = "Millwright",
    unlockRequirements = {
        description = "Build a waterwheel or windmill.",
        triggers = { "waterwheel", "windmill" },
    },
    availableComponents = {
        "driveshaft", "belt_drive", "chain_drive", "gearbox", "worm_gear",
        "piston", "flywheel", "pipe", "valve", "pressure_gauge",
        "coupling", "clutch", "differential", "escapement", "manometer",
    },
    agentUnlocks = { "millwright" },
    worldChanges = {
        ambientSound = "mechanical_rhythm",
        skyPreset = "morning_industrial",
        particleDensity = 0.4,
    },
}

-- Era 2: Electricity
ERAS[2] = {
    number = 2,
    name = "Electricity",
    tagline = "No more muscle.",
    description = "Magnets and wire change everything. Power travels at the speed of light now.",
    agentSpecialization = "Electrician",
    unlockRequirements = {
        description = "Craft a generator (requires flywheel + copper wire).",
        triggers = { "generator" },
    },
    availableComponents = {
        "generator", "wire", "switch", "lamp", "motor",
        "heating_element", "electromagnet", "transformer", "battery",
        "fuse", "circuit_breaker", "buzzer", "solenoid", "simple_relay",
        "capacitor",
    },
    agentUnlocks = { "electrician" },
    worldChanges = {
        ambientSound = "electric_hum",
        skyPreset = "evening_electric",
        particleDensity = 0.5,
        lightingEffect = "lamp_glow",
    },
}

-- Era 3: Control Systems
ERAS[3] = {
    number = 3,
    name = "Control Systems",
    tagline = "If this, then that.",
    description = "Logic gates, sensors, and timers. Machines that decide.",
    agentSpecialization = "Logician",
    unlockRequirements = {
        description = "Build a relay-based switching circuit.",
        triggers = { "logic_gate_and", "logic_gate_or", "logic_gate_not" },
    },
    availableComponents = {
        "logic_gate_and", "logic_gate_or", "logic_gate_not",
        "timer_circuit", "light_sensor", "proximity_sensor",
        "temperature_sensor", "pressure_switch", "remote_trigger",
        "counter", "flip_flop", "multiplexer", "decoder", "adc", "dac",
    },
    agentUnlocks = { "logician" },
    worldChanges = {
        ambientSound = "relay_clicks",
        skyPreset = "twight_controlled",
        particleDensity = 0.6,
        lightingEffect = "indicator_blink",
    },
}

-- Era 4: Programmable Logic
ERAS[4] = {
    number = 4,
    name = "Programmable Logic",
    tagline = "Describe it. It builds itself.",
    description = "Microcontrollers enter the world. Code replaces wiring. Vibe-coding begins.",
    agentSpecialization = "Coder",
    unlockRequirements = {
        description = "Craft an Arduino board (requires simple_relay + timer_circuit).",
        triggers = { "arduino_board" },
    },
    availableComponents = {
        "arduino_board", "breadboard", "led_module", "servo_module",
        "ultrasonic_sensor", "pir_sensor", "lcd_display", "keypad",
        "stepper_driver", "relay_module", "esp8266", "esp32",
        "rtc_module", "sd_card_module", "xbee_radio",
    },
    agentUnlocks = { "coder" },
    worldChanges = {
        ambientSound = "digital_chime",
        skyPreset = "neon_programmable",
        particleDensity = 0.7,
        lightingEffect = "rgb_programmable",
        screenVisible = true,
    },
}

-- Era 5: Networked Systems
ERAS[5] = {
    number = 5,
    name = "Networked Systems",
    tagline = "Everything talks.",
    description = "Wireless protocols connect devices across the world. Distributed sensing begins.",
    agentSpecialization = "Architect",
    unlockRequirements = {
        description = "Connect two ESP32 devices wirelessly.",
        triggers = { "wireless_link", "mesh_node" },
    },
    availableComponents = {
        "wireless_module", "mesh_node", "protocol_bridge", "data_logger",
        "cloud_gateway", "mqtt_broker", "packet_sniffer", "antenna_array",
        "signal_repeater", "network_hub", "routing_table", "encryption_module",
        "ota_updater", "dashboard_screen", "data_pipeline",
    },
    agentUnlocks = { "architect" },
    worldChanges = {
        ambientSound = "data_flow",
        skyPreset = "network_aurora",
        particleDensity = 0.8,
        lightingEffect = "data_stream",
        networkOverlay = true,
    },
}

-- Era 6: Autonomous Agents
ERAS[6] = {
    number = 6,
    name = "Autonomous Agents",
    tagline = "You direct. They build.",
    description = "Deep research agents that mine, build, explore, and coordinate on their own.",
    agentSpecialization = "Orchestrator",
    unlockRequirements = {
        description = "Deploy a fleet of 3+ networked agents.",
        triggers = { "fleet_beacon", "agent_core" },
    },
    availableComponents = {
        "agent_core", "fleet_beacon", "task_scheduler", "autonomous_miner",
        "autonomous_builder", "autonomous_scout", "orchestrator_console",
        "skill_library", "coordination_matrix", "resource_allocator",
        "self_repair_module", "swarm_controller", "priority_queue",
        "agent_communicator", "decision_engine",
    },
    agentUnlocks = { "orchestrator", "voyager", "steve", "groot", "questie" },
    worldChanges = {
        ambientSound = "orchestration_symphony",
        skyPreset = "autonomous_dawn",
        particleDensity = 1.0,
        lightingEffect = "full_autonomous",
        agentsVisible = true,
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- BUILDING ERA DEFINITIONS (parallel to tech eras)
-- These track what players BUILD (structures) rather than what they WIRE
-- (components). Lucineier's assessment is based on building era progression.
-- ═══════════════════════════════════════════════════════════════════════════

local BUILDING_ERAS = {}

BUILDING_ERAS[1] = {
    name = "Driftwood and Salvage",
    lucineerName = "salvage years",
    tagline = "You work with what the tide brings you.",
    requiredBuilds = { "fire_pit", "workbench_scrap" },
    minDistinctBuilds = 4,
    validBuilds = {
        "lean_to", "debris_hut", "tideline_fence", "salvage_rack",
        "fire_pit", "driftwood_platform", "workbench_scrap",
    },
    materials = {
        "driftwood", "salvage_plank", "rawhide", "palm_fiber",
        "kelp_dried", "sea_rope", "beach_stone", "canvas_scrap",
        "pitch", "shell", "bone",
    },
    worldChanges = {
        ambientSound = "wind_and_waves",
        skyPreset = "dawn_coastal",
        particleDensity = 0.3,
        nightLight = "fire_only",
    },
    tempo = 40,
    lucineerTransitionKey = "era1_to_era2",
}

BUILDING_ERAS[2] = {
    name = "Frame and Plank",
    lucineerName = "honest years",
    tagline = "First real carpentry. The structure has opinions about where it wants to stand.",
    requiredBuilds = { "post_and_beam", "framed_workshop" },
    minDistinctBuilds = 5,
    validBuilds = {
        "post_and_beam", "plank_wall", "shingled_roof", "framed_floor",
        "caulked_seam", "hinged_door", "glazed_window", "framed_workshop",
        "storehouse", "pier_jetty", "saw_pit", "crane_post",
    },
    materials = {
        "timber", "plank", "treenail", "tar_boiled", "oakum",
        "nail_wrought", "hinge_iron", "glass_crude", "shingle",
        "mortise_peg", "brace_timber", "sill_beam", "canvas_woven",
    },
    worldChanges = {
        ambientSound = "hammer_and_saw",
        skyPreset = "morning_clear",
        particleDensity = 0.4,
        nightLight = "oil_lamps",
    },
    tempo = 70,
    lucineerTransitionKey = "era2_to_era3",
}

BUILDING_ERAS[3] = {
    name = "Stone and Mortar",
    lucineerName = "permanent years",
    tagline = "Permanence arrives. Walls have mass. The building outlasts the builder.",
    requiredBuilds = { "stone_foundation", "lime_kiln" },
    minDistinctBuilds = 6,
    requiresHeightBuild = true,
    heightBuilds = { "vaulted_ceiling", "stone_tower" },
    validBuilds = {
        "stone_foundation", "stone_wall", "brick_wall", "arch_stone",
        "stone_tower", "vaulted_ceiling", "tiled_roof", "slate_floor",
        "stone_chimney", "root_cellar", "cistern", "lime_kiln",
        "forge_hearth", "bridge_stone",
    },
    materials = {
        "limestone", "sandstone", "fieldstone", "granite",
        "brick_fire", "mortar_lime", "concrete_crude", "clay_raw",
        "sand_fine", "tile_roof", "slate", "lead_sheet", "rebar_crude",
    },
    worldChanges = {
        ambientSound = "stone_and_chisel",
        skyPreset = "midday_solid",
        particleDensity = 0.5,
        nightLight = "forge_glow",
    },
    tempo = 85,
    lucineerTransitionKey = "era3_to_era4",
}

BUILDING_ERAS[4] = {
    name = "Metal and Machine",
    lucineerName = "iron years",
    tagline = "Iron becomes steel. The building is a machine with a roof.",
    requiredBuilds = { "workshop_industrial" },
    minDistinctBuilds = 5,
    requiresPowerChain = true,
    powerChainBuilds = {
        sources = { "boiler_house", "engine_house", "wind_turbine_mech" },
        distribution = { "line_shaft_system" },
        consumers = { "powered_hammer", "powered_crane", "pumping_station" },
    },
    validBuilds = {
        "iron_frame", "steel_wall", "boiler_house", "engine_house",
        "line_shaft_system", "powered_hammer", "powered_crane",
        "pumping_station", "copper_roof", "glass_wall",
        "workshop_industrial", "concrete_struct", "gantry_rail",
        "wind_turbine_mech",
    },
    materials = {
        "iron_bar", "steel_bar", "steel_plate", "steel_beam",
        "rivet_iron", "copper_sheet", "brass_fitting", "pipe_iron",
        "boiler_plate", "glass_sheet", "cable_steel", "girder_riveted",
        "concrete_reinforced",
    },
    worldChanges = {
        ambientSound = "steam_and_steel",
        skyPreset = "afternoon_industrial",
        particleDensity = 0.7,
        nightLight = "electric_arc",
    },
    tempo = 110,
    lucineerTransitionKey = "era4_to_era5",
}

BUILDING_ERAS[5] = {
    name = "Light and Signal",
    lucineerName = "year the light came back",
    tagline = "Electricity transforms everything. The island is no longer alone.",
    requiredBuilds = {},  -- Final era: no advancement check
    minDistinctBuilds = 0,
    validBuilds = {
        "wire_run", "lamp_post", "switch_box", "generator_house",
        "battery_bank", "lighthouse_restored", "telegraph_station",
        "signal_tower", "workshop_electrical", "grid_system",
        "intercom_system", "automated_gate", "beacon_light",
        "workshop_automation",
    },
    materials = {
        "copper_wire", "magnet", "filament", "bulb_glass",
        "insulator_porc", "brass_contact", "antenna_wire",
        "lens_fresnel", "circuit_board", "semiconductor", "fiber_optic",
    },
    worldChanges = {
        ambientSound = "data_flow",
        skyPreset = "evening_lighthouse",
        particleDensity = 0.8,
        nightLight = "lighthouse_and_grid",
    },
    tempo = 55,
    lucineerTransitionKey = nil,  -- No further transition
}

-- ═══════════════════════════════════════════════════════════════════════════
-- BUILDING ERA ADVANCEMENT REQUIREMENTS
-- Maps building era → requirements to advance to next era
-- ═══════════════════════════════════════════════════════════════════════════

local BUILDING_ERA_REQUIREMENTS = {
    [1] = {
        requiredBuilds = BUILDING_ERAS[1].requiredBuilds,
        minDistinctBuilds = BUILDING_ERAS[1].minDistinctBuilds,
        validBuilds = BUILDING_ERAS[1].validBuilds,
    },
    [2] = {
        requiredBuilds = BUILDING_ERAS[2].requiredBuilds,
        minDistinctBuilds = BUILDING_ERAS[2].minDistinctBuilds,
        validBuilds = BUILDING_ERAS[2].validBuilds,
    },
    [3] = {
        requiredBuilds = BUILDING_ERAS[3].requiredBuilds,
        minDistinctBuilds = BUILDING_ERAS[3].minDistinctBuilds,
        validBuilds = BUILDING_ERAS[3].validBuilds,
        requiresHeightBuild = true,
        heightBuilds = BUILDING_ERAS[3].heightBuilds,
    },
    [4] = {
        requiredBuilds = BUILDING_ERAS[4].requiredBuilds,
        minDistinctBuilds = BUILDING_ERAS[4].minDistinctBuilds,
        validBuilds = BUILDING_ERAS[4].validBuilds,
        requiresPowerChain = true,
        powerChainBuilds = BUILDING_ERAS[4].powerChainBuilds,
    },
    -- Era 5 is final — no advancement check
}

-- ═══════════════════════════════════════════════════════════════════════════
-- RUNTIME STATE (in-memory cache, persisted to D1)
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → era state
-- Tech era fields:     { currentEra, unlockedEras, eraXP, buildCounts }
-- Building era fields: { buildingEra, buildingEraUnlocked, buildingEraReady,
--                        buildingEraAssessed, sessionStartBuilds, lastAssessmentTime }
local playerStates = {}

-- Helper: get build counts table for a player (creates if missing)
local function getBuildCounts(playerName)
    local state = playerStates[playerName]
    if not state then return {} end
    if not state.buildCounts then state.buildCounts = {} end
    return state.buildCounts
end

-- Helper: check if player has built any from a list
local function hasBuiltAny(counts, buildList)
    for _, buildType in ipairs(buildList) do
        if counts[buildType] and counts[buildType] > 0 then
            return true
        end
    end
    return false
end

-- Helper: count total builds across all types
local function countTotalBuilds(counts)
    local t = 0
    for _, c in pairs(counts) do t = t + c end
    return t
end

-- Forward declaration for savePlayer (used by loadPlayer and other functions)
local savePlayer

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

local initialized = false

local function init()
    if initialized then return end
    initialized = true

    -- Load player era state when they join
    Players.PlayerAdded:Connect(function(player)
        EraSystem.loadPlayer(player.Name)
    end)

    -- Save player era state when they leave
    Players.PlayerRemoving:Connect(function(player)
        EraSystem.savePlayer(player.Name)
    end)

    print("[EraSystem] Initialized — 7 eras loaded, " .. #Recipes.getAll() .. " recipes available")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- D1 PERSISTENCE
-- ═══════════════════════════════════════════════════════════════════════════

-- Load player era state from D1 (falls back to default era 0)
local function loadPlayer(playerName)
    local success, result = pcall(function()
        -- Bug 1 fix: path only — Http.post prepends worker URL automatically.
        -- Bug 2 fix: auth header injected by Http module on every call.
        return Http.post("/api/era/load", {
            playerName = playerName,
        })
    end)

    if success and result and result.currentEra then
        playerStates[playerName] = {
            currentEra = result.currentEra,
            unlockedEras = {},
            eraXP = result.eraXP or {},
            buildCounts = result.buildCounts or {},
            -- Building era fields
            buildingEra = result.buildingEra or 1,
            buildingEraUnlocked = { [1] = true },
            buildingEraReady = result.buildingEraReady or false,
            buildingEraAssessed = result.buildingEraAssessed or false,
            lastAssessmentTime = result.lastAssessmentTime or 0,
        }
        -- Reconstruct unlockedEras set
        for _, eraNum in ipairs(result.unlockedEras or {0}) do
            playerStates[playerName].unlockedEras[eraNum] = true
        end
        -- Reconstruct building era unlocked set
        for _, eraNum in ipairs(result.buildingEraUnlocked or {1}) do
            playerStates[playerName].buildingEraUnlocked[eraNum] = true
        end
    else
        -- Default: tech era 0, building era 1
        playerStates[playerName] = {
            currentEra = 0,
            unlockedEras = { [0] = true },
            eraXP = {},
            buildCounts = {},
            buildingEra = 1,
            buildingEraUnlocked = { [1] = true },
            buildingEraReady = false,
            buildingEraAssessed = false,
            lastAssessmentTime = 0,
        }
    end

    -- Capture session-start snapshot for day-2 delta
    local snapshot = {}
    for buildType, count in pairs(playerStates[playerName].buildCounts or {}) do
        snapshot[buildType] = count
    end
    playerStates[playerName].sessionStartBuilds = snapshot
end

-- Save player era state to D1 (including building era fields)
local function savePlayer(playerName)
    local state = playerStates[playerName]
    if not state then return end

    local unlockedList = {}
    for eraNum in pairs(state.unlockedEras) do
        table.insert(unlockedList, eraNum)
    end
    table.sort(unlockedList)

    local buildingEraUnlockedList = {}
    for eraNum in pairs(state.buildingEraUnlocked or {}) do
        table.insert(buildingEraUnlockedList, eraNum)
    end
    table.sort(buildingEraUnlockedList)

    pcall(function()
        -- Bug 1 fix: path only — no MEMORY_URL prefix.
        Http.post("/api/era/save", {
            playerName = playerName,
            currentEra = state.currentEra,
            unlockedEras = unlockedList,
            eraXP = state.eraXP,
            -- Building era persistence
            buildingEra = state.buildingEra or 1,
            buildingEraUnlocked = buildingEraUnlockedList,
            buildingEraReady = state.buildingEraReady or false,
            buildingEraAssessed = state.buildingEraAssessed or false,
            buildCounts = state.buildCounts or {},
            lastAssessmentTime = state.lastAssessmentTime or 0,
        })
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

EraSystem = {}

-- Initialize the system (call once on server start)
EraSystem.init = init

-- Load a player's state (called on PlayerAdded, but can be called manually)
EraSystem.loadPlayer = loadPlayer

-- Save a player's state (called on PlayerRemoving)
EraSystem.savePlayer = savePlayer

-- Get the player's current era number
function EraSystem.getCurrentEra(playerName)
    local state = playerStates[playerName]
    if not state then return 0 end
    return state.currentEra
end

-- Get full era info for a specific era number
function EraSystem.getEraInfo(eraNumber)
    return ERAS[eraNumber]
end

-- Get the highest unlocked era for a player
function EraSystem.getMaxUnlockedEra(playerName)
    local state = playerStates[playerName]
    if not state then return 0 end
    local max = 0
    for eraNum in pairs(state.unlockedEras) do
        if eraNum > max then max = eraNum end
    end
    return max
end

-- Check if a player has unlocked a specific era
function EraSystem.hasUnlockedEra(playerName, eraNumber)
    local state = playerStates[playerName]
    if not state then return eraNumber == 0 end
    return state.unlockedEras[eraNumber] == true
end

-- Unlock an era for a player
function EraSystem.unlockEra(playerName, eraNumber)
    if not ERAS[eraNumber] then
        warn("[EraSystem] Cannot unlock unknown era " .. tostring(eraNumber))
        return false
    end

    local state = playerStates[playerName]
    if not state then
        loadPlayer(playerName)
        state = playerStates[playerName]
    end

    if state.unlockedEras[eraNumber] then
        return false -- already unlocked
    end

    -- Must unlock eras in order (can't skip)
    if eraNumber > 0 and not state.unlockedEras[eraNumber - 1] then
        warn(string.format("[EraSystem] Cannot unlock era %d — prerequisite era %d not unlocked",
            eraNumber, eraNumber - 1))
        return false
    end

    state.unlockedEras[eraNumber] = true
    state.currentEra = eraNumber

    local era = ERAS[eraNumber]
    print(string.format("[EraSystem] %s unlocked Era %d: %s — %s",
        playerName, eraNumber, era.name, era.tagline))

    -- ═══ Era Transition Handler ═══
    -- Announce era change to all players (server-wide event)
    EraSystem.announceEraTransition(playerName, eraNumber)

    -- Unlock new material tier for this era
    EraSystem.unlockMaterialTier(playerName, eraNumber)

    -- Apply visual era indicators (lighting, atmosphere)
    EraSystem.applyVisualEraIndicator(playerName, eraNumber)

    -- Fire events for other systems
    _G.EraSystem_UnlockFired = _G.EraSystem_UnlockFired or {}
    table.insert(_G.EraSystem_UnlockFired, {
        playerName = playerName,
        era = eraNumber,
        eraData = era,
    })

    -- Persist
    savePlayer(playerName)

    return true
end

-- Get all recipes available to a player (based on unlocked eras)
function EraSystem.getAvailableRecipes(playerName)
    local state = playerStates[playerName]
    if not state then
        loadPlayer(playerName)
        state = playerStates[playerName]
    end

    local available = {}
    for _, recipe in ipairs(Recipes.getAll()) do
        if state.unlockedEras[recipe.era] then
            table.insert(available, recipe)
        end
    end
    return available
end

-- Get recipes for a specific era
function EraSystem.getRecipesForEra(eraNumber)
    return Recipes.getByEra(eraNumber)
end

-- Get all available component types for a player
function EraSystem.getAvailableComponents(playerName)
    local state = playerStates[playerName]
    if not state then
        loadPlayer(playerName)
        state = playerStates[playerName]
    end

    local components = {}
    for eraNum in pairs(state.unlockedEras) do
        local era = ERAS[eraNum]
        if era and era.availableComponents then
            for _, comp in ipairs(era.availableComponents) do
                table.insert(components, comp)
            end
        end
    end
    return components
end

-- Check if a player can build a specific component type
function EraSystem.canBuild(playerName, componentType)
    local state = playerStates[playerName]
    if not state then
        loadPlayer(playerName)
        state = playerStates[playerName]
    end

    -- Check if the component is available in any unlocked era
    for eraNum in pairs(state.unlockedEras) do
        local era = ERAS[eraNum]
        if era and era.availableComponents then
            for _, comp in ipairs(era.availableComponents) do
                if comp == componentType then
                    return true
                end
            end
        end
    end
    return false
end

-- Get agents unlocked by the player
function EraSystem.getAvailableAgents(playerName)
    local state = playerStates[playerName]
    if not state then return { "mechanic" } end

    local agents = {}
    for eraNum in pairs(state.unlockedEras) do
        local era = ERAS[eraNum]
        if era and era.agentUnlocks then
            for _, agent in ipairs(era.agentUnlocks) do
                table.insert(agents, agent)
            end
        end
    end
    return agents
end

-- Called when a player builds something — checks for era unlock triggers
function EraSystem.onBuild(playerName, buildType)
    local state = playerStates[playerName]
    if not state then
        loadPlayer(playerName)
        state = playerStates[playerName]
    end

    -- Track build count
    local counts = getBuildCounts(playerName)
    counts[buildType] = (counts[buildType] or 0) + 1

    -- Add era XP
    local era = state.currentEra
    state.eraXP[tostring(era)] = (state.eraXP[tostring(era)] or 0) + 1

    -- Check trigger-based era unlock (existing logic)
    local nextEra = state.currentEra + 1
    local nextEraDef = ERAS[nextEra]
    if nextEraDef and nextEraDef.unlockRequirements and nextEraDef.unlockRequirements.triggers then
        for _, trigger in ipairs(nextEraDef.unlockRequirements.triggers) do
            if trigger == buildType then
                EraSystem.unlockEra(playerName, nextEra)
                break
            end
        end
    end

    -- Also check build count + bond level era advancement (new logic)
    -- This provides an alternative progression path: if the player has
    -- accumulated enough builds in the current era AND has sufficient
    -- bond level with Lucineer, advance automatically.
    if not state.unlockedEras[nextEra] and nextEraDef and TECH_ERA_REQUIREMENTS[state.currentEra] then
        EraSystem.checkTechEraAdvancement(playerName)
    end

    -- Persist
    savePlayer(playerName)
end

-- Get the world changes for a player's current era
function EraSystem.getWorldChanges(playerName)
    local era = EraSystem.getCurrentEra(playerName)
    local eraDef = ERAS[era]
    if not eraDef then return {} end
    return eraDef.worldChanges or {}
end

-- Get era XP for a specific era
function EraSystem.getEraXP(playerName, eraNumber)
    local state = playerStates[playerName]
    if not state then return 0 end
    return state.eraXP[tostring(eraNumber)] or 0
end

-- Get total XP across all eras
function EraSystem.getTotalXP(playerName)
    local state = playerStates[playerName]
    if not state then return 0 end
    local total = 0
    for _, xp in pairs(state.eraXP) do
        total = total + xp
    end
    return total
end

-- Get all era definitions (for UI display)
function EraSystem.getAllEras()
    local result = {}
    for i = 0, 6 do
        if ERAS[i] then
            table.insert(result, ERAS[i])
        end
    end
    return result
end

-- Get the recipe for a specific item
function EraSystem.getRecipe(recipeId)
    return Recipes.get(recipeId)
end

-- Find recipes by partial name match (for voice crafting)
function EraSystem.searchRecipes(query)
    return Recipes.search(query)
end

-- Export ERA definitions for external access
EraSystem.ERAS = ERAS
EraSystem.BUILDING_ERAS = BUILDING_ERAS

-- ═══════════════════════════════════════════════════════════════════════════
-- BUILDING ERA PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

-- Get the player's current building era (1–5)
function EraSystem.getBuildingEra(playerName)
    local state = playerStates[playerName]
    return state and state.buildingEra or 1
end

-- Get building era definition table
function EraSystem.getBuildingEraInfo(eraNumber)
    return BUILDING_ERAS[eraNumber]
end

-- Get build counts (public accessor)
function EraSystem.getBuildCounts(playerName)
    local state = playerStates[playerName]
    return state and state.buildCounts or {}
end

-- Check if a player meets the requirements to advance building era.
-- Returns true if ready, false if not. Does NOT advance — that requires
-- Lucineier's assessment.
function EraSystem.checkBuildingEraAdvancement(playerName)
    local state = playerStates[playerName]
    if not state then return false end

    local currentEra = state.buildingEra or 1
    local nextEra = currentEra + 1

    -- Era 5 is the final era — no advancement possible
    if not BUILDING_ERAS[nextEra] then return false end

    -- Already assessed/ready? Don't re-check.
    if state.buildingEraReady then return true end

    local req = BUILDING_ERA_REQUIREMENTS[currentEra]
    if not req then return false end

    local counts = state.buildCounts or {}

    -- Check required builds
    for _, buildType in ipairs(req.requiredBuilds) do
        if not (counts[buildType] and counts[buildType] > 0) then
            return false  -- Missing a required build
        end
    end

    -- Count distinct valid builds
    local distinctCount = 0
    for _, buildType in ipairs(req.validBuilds) do
        if counts[buildType] and counts[buildType] > 0 then
            distinctCount = distinctCount + 1
        end
    end

    if distinctCount < req.minDistinctBuilds then
        return false  -- Not enough variety
    end

    -- Check special: height build requirement (Era 3)
    if req.requiresHeightBuild then
        local hasHeight = false
        for _, buildType in ipairs(req.heightBuilds or {}) do
            if counts[buildType] and counts[buildType] > 0 then
                hasHeight = true
                break
            end
        end
        if not hasHeight then return false end
    end

    -- Check special: power chain requirement (Era 4)
    if req.requiresPowerChain then
        local pc = req.powerChainBuilds or {}
        local hasSource = hasBuiltAny(counts, pc.sources or {})
        local hasDist = hasBuiltAny(counts, pc.distribution or {})
        local hasConsumer = hasBuiltAny(counts, pc.consumers or {})
        if not (hasSource and hasDist and hasConsumer) then
            return false
        end
    end

    -- All checks passed — mark as ready
    state.buildingEraReady = true
    return true
end

-- Actually advance the building era (called after Lucineier's assessment).
-- Unlocks next era, fires world change events, persists state.
function EraSystem.advanceBuildingEra(playerName)
    local state = playerStates[playerName]
    if not state then return false end
    if not state.buildingEraReady then return false end
    if state.buildingEraAssessed then return false end

    local currentEra = state.buildingEra or 1
    local nextEra = currentEra + 1

    if not BUILDING_ERAS[nextEra] then return false end

    state.buildingEra = nextEra
    state.buildingEraUnlocked[nextEra] = true
    state.buildingEraReady = false
    state.buildingEraAssessed = false  -- Reset for next era's assessment cycle
    state.lastAssessmentTime = os.time()

    local eraDef = BUILDING_ERAS[nextEra]
    print(string.format("[EraSystem] %s advanced to Building Era %d: %s",
        playerName, nextEra, eraDef.name))

    -- Fire event for other systems (world changes, BondSystem, etc.)
    _G.EraSystem_BuildingEraAdvanced = _G.EraSystem_BuildingEraAdvanced or {}
    table.insert(_G.EraSystem_BuildingEraAdvanced, {
        playerName = playerName,
        newEra = nextEra,
        eraData = eraDef,
    })

    -- Persist
    savePlayer(playerName)

    return true
end

-- Called when a player places a building-type structure.
-- This is SEPARATE from tech-era component builds (which go through onBuild).
-- Building-type structures: lean_to, fire_pit, workbench_scrap, etc.
function EraSystem.onBuildingEraBuild(playerName, buildType)
    local state = playerStates[playerName]
    if not state then
        loadPlayer(playerName)
        state = playerStates[playerName]
    end

    -- Track build count
    local counts = state.buildCounts or {}
    counts[buildType] = (counts[buildType] or 0) + 1
    state.buildCounts = counts

    -- Check if this build completed an open hook (BondSystem bridge)
    local BondSystem = script.Parent and script.Parent:FindFirstChild("BondSystem")
    if BondSystem then
        local bs = require(BondSystem)
        local hooks = bs.getOpenHooks and bs.getOpenHooks(playerName) or {}
        for hookId, hook in pairs(hooks) do
            -- If this build type matches a hook's expected build type
            if hook.buildType == buildType or
               (hook.description and string.find(hook.description, buildType, 1, true)) then
                bs.addHookXP(playerName, hookId)
                break
            end
        end
    end

    -- Check for building era advancement
    EraSystem.checkBuildingEraAdvancement(playerName)

    -- Persist
    savePlayer(playerName)
end

-- Called when a hook is completed (by BondSystem or WorldScanner).
-- Allows hook completions to count toward era advancement.
function EraSystem.onHookCompleted(playerName, hookId, buildType)
    local state = playerStates[playerName]
    if not state then return end

    -- If the hook completion corresponds to a build type we track,
    -- and it's not already counted, count it.
    if buildType then
        local counts = state.buildCounts or {}
        -- Only count if this build type wasn't already registered
        -- (avoids double-counting if onBuildingEraBuild was also called)
        if not counts[buildType] or counts[buildType] == 0 then
            counts[buildType] = 1
            state.buildCounts = counts
            EraSystem.checkBuildingEraAdvancement(playerName)
            savePlayer(playerName)
        end
    end
end

-- Mark that Lucineier has delivered the assessment dialogue.
-- Called after assessment dialogue completes, before advanceBuildingEra.
function EraSystem.markAssessed(playerName)
    local state = playerStates[playerName]
    if not state then return end
    state.buildingEraAssessed = true
    state.lastAssessmentTime = os.time()
    savePlayer(playerName)
end

-- Get a structured context object describing the player's progression state.
-- Lucineier's brain queries this when deciding whether and how to assess.
function EraSystem.getAssessmentContext(playerName)
    local state = playerStates[playerName]
    if not state then return nil end

    local counts = state.buildCounts or {}
    local era = state.buildingEra or 1
    local eraDef = BUILDING_ERAS[era]

    -- Count distinct builds in current era
    local distinctInEra = 0
    local builtTypes = {}
    if eraDef then
        for _, buildType in ipairs(eraDef.validBuilds) do
            if counts[buildType] and counts[buildType] > 0 then
                distinctInEra = distinctInEra + 1
                table.insert(builtTypes, buildType)
            end
        end
    end

    -- Check required builds status
    local requiredMet = {}
    local allRequiredMet = true
    if eraDef then
        for _, buildType in ipairs(eraDef.requiredBuilds) do
            local has = counts[buildType] and counts[buildType] > 0
            requiredMet[buildType] = has
            if not has then allRequiredMet = false end
        end
    end

    return {
        currentEra = era,
        eraName = eraDef and eraDef.name or "Unknown",
        ready = state.buildingEraReady or false,
        assessed = state.buildingEraAssessed or false,
        distinctBuildsInEra = distinctInEra,
        minRequired = eraDef and eraDef.minDistinctBuilds or 0,
        builtTypes = builtTypes,
        requiredBuilds = requiredMet,
        allRequiredMet = allRequiredMet,
        totalBuilds = countTotalBuilds(counts),
    }
end

-- Get the player's return state for day-2 processing.
-- Called by Lucineier's brain when a player joins to generate the
-- returning-player greeting and decide what's changed in the world.
function EraSystem.getPlayerReturnState(playerName)
    local state = playerStates[playerName]
    if not state then return nil end

    -- Calculate builds since last session
    local currentCounts = state.buildCounts or {}
    local sessionStart = state.sessionStartBuilds or {}
    local newBuilds = {}
    local totalNew = 0

    for buildType, count in pairs(currentCounts) do
        local prev = sessionStart[buildType] or 0
        if count > prev then
            newBuilds[buildType] = count - prev
            totalNew = totalNew + (count - prev)
        end
    end

    return {
        buildingEra = state.buildingEra or 1,
        buildingEraReady = state.buildingEraReady or false,
        totalBuilds = countTotalBuilds(currentCounts),
        newBuildsSinceLastSession = totalNew,
        newBuildTypes = newBuilds,
        lastAssessmentTime = state.lastAssessmentTime or 0,
        assessmentAvailable = state.buildingEraReady and not state.buildingEraAssessed,
    }
end

-- Get all building era definitions (for UI display)
function EraSystem.getAllBuildingEras()
    local result = {}
    for i = 1, 5 do
        if BUILDING_ERAS[i] then
            table.insert(result, BUILDING_ERAS[i])
        end
    end
    return result
end

-- Get the world changes for the player's current building era
function EraSystem.getBuildingEraWorldChanges(playerName)
    local era = EraSystem.getBuildingEra(playerName)
    local eraDef = BUILDING_ERAS[era]
    if not eraDef then return {} end
    return eraDef.worldChanges or {}
end

-- Check if a build type is valid for the player's current building era
function EraSystem.isValidBuildingEraBuild(playerName, buildType)
    local era = EraSystem.getBuildingEra(playerName)
    local eraDef = BUILDING_ERAS[era]
    if not eraDef then return false end
    for _, validType in ipairs(eraDef.validBuilds) do
        if validType == buildType then return true end
    end
    return false
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA PROGRESSION IMPLEMENTATION
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Check if a player qualifies for tech era advancement based on
    build count in the current era + bond level with Lucineer.
    This is the ALTERNATIVE path to the trigger-based unlock.
    Both paths can fire; whichever fires first advances the era.

    @param playerName string
    @return boolean — true if advancement check passed and era was unlocked
]]
function EraSystem.checkTechEraAdvancement(playerName)
    local state = playerStates[playerName]
    if not state then return false end

    local currentEra = state.currentEra
    local nextEra = currentEra + 1

    -- Final era — no further advancement
    if not ERAS[nextEra] then return false end
    -- Already unlocked?
    if state.unlockedEras[nextEra] then return false end

    local req = TECH_ERA_REQUIREMENTS[currentEra]
    if not req then return false end

    -- Count builds in the current era
    local eraXP = state.eraXP[tostring(currentEra)] or 0
    if eraXP < req.minBuilds then
        return false  -- Not enough builds in this era
    end

    -- Check bond level (query BondSystem if available)
    local bondLevel = 0
    local BondSystem = script.Parent and script.Parent:FindFirstChild("BondSystem")
    if BondSystem then
        local ok, bs = pcall(require, BondSystem)
        if ok and bs.getBondLevel then
            bondLevel = bs.getBondLevel(playerName) or 0
        end
    end

    if bondLevel < req.minBondLevel then
        return false  -- Bond level too low
    end

    -- All requirements met — advance!
    print(string.format("[EraSystem] %s qualifies for Era %d via build count (%d≥%d) + bond (%d≥%d)",
        playerName, nextEra, eraXP, req.minBuilds, bondLevel, req.minBondLevel))

    return EraSystem.unlockEra(playerName, nextEra)
end

--[[
    Announce an era transition to all players via the chat/stigmare system.
    Fires a global event and sends a message to the player who advanced.

    @param playerName string
    @param eraNumber number
]]
function EraSystem.announceEraTransition(playerName, eraNumber)
    local era = ERAS[eraNumber]
    if not era then return end

    local player = Players:FindFirstChild(playerName)

    -- Server-wide announcement via global event queue
    _G.EraSystem_Announcements = _G.EraSystem_Announcements or {}
    table.insert(_G.EraSystem_Announcements, {
        playerName = playerName,
        era = eraNumber,
        eraName = era.name,
        tagline = era.tagline,
        description = era.description,
        timestamp = os.time(),
    })

    -- Fire a ReplicatedStorage event for client-side UI (era banner, toast)
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Lucineer = ReplicatedStorage:FindFirstChild("Lucineer")
    if Lucineer then
        local announceRemote = Lucineer:FindFirstChild("EraAnnouncementEvent")
        if not announceRemote then
            announceRemote = Instance.new("RemoteEvent")
            announceRemote.Name = "EraAnnouncementEvent"
            announceRemote.Parent = Lucineer
        end

        -- Broadcast to all players (everyone sees the era banner)
        announceRemote:FireAllClients({
            playerName = playerName,
            era = eraNumber,
            eraName = era.name,
            tagline = era.tagline,
            description = era.description,
            agentSpecialization = era.agentSpecialization,
        })
    end

    print(string.format("[EraSystem] 🌅 Era Transition: %s entered Era %d — %s (\"%s\")",
        playerName, eraNumber, era.name, era.tagline))
end

--[[
    Unlock a material tier for a player based on their tech era.
    Merges the era's material list into the player's unlocked materials set.

    @param playerName string
    @param eraNumber number
]]
function EraSystem.unlockMaterialTier(playerName, eraNumber)
    local state = playerStates[playerName]
    if not state then return end

    local materials = MATERIAL_TIERS[eraNumber]
    if not materials then return end

    -- Initialize unlocked materials set if missing
    if not state.unlockedMaterials then
        state.unlockedMaterials = {}
    end

    local newlyUnlocked = {}
    for _, material in ipairs(materials) do
        if not state.unlockedMaterials[material] then
            state.unlockedMaterials[material] = true
            table.insert(newlyUnlocked, material)
        end
    end

    if #newlyUnlocked > 0 then
        print(string.format("[EraSystem] %s unlocked %d new materials for Era %d: %s",
            playerName, #newlyUnlocked, eraNumber, table.concat(newlyUnlocked, ", ")))

        -- Notify client of new materials
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local Lucineer = ReplicatedStorage:FindFirstChild("Lucineer")
        if Lucineer then
            local materialRemote = Lucineer:FindFirstChild("MaterialUnlockEvent")
            if not materialRemote then
                materialRemote = Instance.new("RemoteEvent")
                materialRemote.Name = "MaterialUnlockEvent"
                materialRemote.Parent = Lucineer
            end

            local player = Players:FindFirstChild(playerName)
            if player then
                materialRemote:FireClient(player, {
                    era = eraNumber,
                    materials = newlyUnlocked,
                })
            end
        end
    end
end

--[[
    Apply visual era indicators: lighting, atmosphere, color grading.
    Transitions the world's lighting to match the player's new era.
    In multiplayer, this is per-client (affects only the advancing player).

    @param playerName string
    @param eraNumber number
]]
function EraSystem.applyVisualEraIndicator(playerName, eraNumber)
    local preset = VISUAL_PRESETS[eraNumber]
    if not preset then return end

    local player = Players:FindFirstChild(playerName)
    if not player then return end

    -- Apply lighting changes on the server (global for now; per-client
    -- replication can be added via a LightingDelta RemoteEvent later)
    -- We use pcall extensively because Lighting properties can fail
    -- in certain Roblox Studio states.

    -- Brightness
    pcall(function()
        Lighting.Brightness = preset.brightness
    end)

    -- Ambient
    pcall(function()
        Lighting.Ambient = preset.ambient
    end)

    -- OutdoorAmbient
    pcall(function()
        Lighting.OutdoorAmbient = preset.outdoorAmbient
    end)

    -- Fog end distance
    pcall(function()
        if Lighting:FindFirstChildOfClass("Atmosphere") then
            Lighting:FindFirstChildOfClass("Atmosphere").Decay = math.max(0.001, 1.0 / preset.fogEnd)
        else
            Lighting.FogEnd = preset.fogEnd
        end
    end)

    -- Time of day (only if ClockTime is available)
    pcall(function()
        Lighting.ClockTime = preset.timeOfDay
    end)

    -- Color correction (brightness/contrast/saturation/tint)
    pcall(function()
        local cc = Lighting:FindFirstChild("EraColorCorrection")
        if not cc then
            cc = Instance.new("ColorCorrectionEffect")
            cc.Name = "EraColorCorrection"
            cc.Parent = Lighting
        end

        local c = preset.colorCorrection
        if c then
            -- Tween for smooth transition
            local TweenService = game:GetService("TweenService")
            local tweenInfo = TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            local tween = TweenService:Create(cc, tweenInfo, {
                Brightness = c.brightness or 0,
                Contrast = c.contrast or 0,
                Saturation = c.saturation or 0,
                TintColor = c.tint or Color3.fromRGB(255, 255, 255),
            })
            tween:Play()
        end
    end)

    -- Notify client to apply per-player visual overrides
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Lucineer = ReplicatedStorage:FindFirstChild("Lucineer")
    if Lucineer then
        local visualRemote = Lucineer:FindFirstChild("EraVisualEvent")
        if not visualRemote then
            visualRemote = Instance.new("RemoteEvent")
            visualRemote.Name = "EraVisualEvent"
            visualRemote.Parent = Lucineer
        end

        visualRemote:FireClient(player, {
            era = eraNumber,
            preset = preset,
        })
    end

    -- Update ambient sound if the era defines one
    local eraDef = ERAS[eraNumber]
    if eraDef and eraDef.worldChanges and eraDef.worldChanges.ambientSound then
        _G.EraSystem_AmbientUpdate = _G.EraSystem_AmbientUpdate or {}
        _G.EraSystem_AmbientUpdate[playerName] = {
            sound = eraDef.worldChanges.ambientSound,
            era = eraNumber,
        }
    end

    print(string.format("[EraSystem] Visual era indicator applied for %s (Era %d)",
        playerName, eraNumber))
end

-- Get all unlocked materials for a player
function EraSystem.getUnlockedMaterials(playerName)
    local state = playerStates[playerName]
    if not state then
        -- Era 0 materials are always available
        return MATERIAL_TIERS[0] or {}
    end

    if not state.unlockedMaterials then
        -- Initialize with era 0 materials
        state.unlockedMaterials = {}
        for _, mat in ipairs(MATERIAL_TIERS[0] or {}) do
            state.unlockedMaterials[mat] = true
        end
    end

    local result = {}
    for material, unlocked in pairs(state.unlockedMaterials) do
        if unlocked then
            table.insert(result, material)
        end
    end
    table.sort(result)
    return result
end

-- Check if a specific material is unlocked for a player
function EraSystem.isMaterialUnlocked(playerName, material)
    local state = playerStates[playerName]
    if not state then
        -- Check era 0 defaults
        for _, m in ipairs(MATERIAL_TIERS[0] or {}) do
            if m == material then return true end
        end
        return false
    end

    if not state.unlockedMaterials then
        -- Initialize with era 0 materials
        state.unlockedMaterials = {}
        for _, mat in ipairs(MATERIAL_TIERS[0] or {}) do
            state.unlockedMaterials[mat] = true
        end
    end

    return state.unlockedMaterials[material] == true
end

-- Get the visual preset for a specific era (for UI previews)
function EraSystem.getVisualPreset(eraNumber)
    return VISUAL_PRESETS[eraNumber]
end

-- Get the tech era requirements for advancement display
function EraSystem.getTechEraRequirements(eraNumber)
    return TECH_ERA_REQUIREMENTS[eraNumber]
end

-- Get the material tier list for a specific era
function EraSystem.getMaterialTier(eraNumber)
    return MATERIAL_TIERS[eraNumber] or {}
end

print("[EraSystem] Module loaded — " .. #Recipes.getAll() .. " recipes across 7 tech eras, 5 building eras")

return EraSystem
