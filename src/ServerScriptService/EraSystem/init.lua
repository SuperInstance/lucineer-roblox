--!strict
--[[
    EraSystem — Slackwater's Technology Progression Backbone
    =========================================================
    Manages the 7-era tech progression from levers to Arduino IoT.
    Each era unlocks recipes, components, agents, and world changes.

    Eras:
        0 — Simple Machines      (lever, pulley, wheel, wedge, screw)
        1 — Power Transmission   (shafts, belts, gears, fluid pressure)
        2 — Electricity          (generators, wire, switches, lamps, motors)
        3 — Control Systems      (relays, sensors, timers, logic gates)
        4 — Programmable Logic   (Arduino, ESP32, sensors, vibe-coding)
        5 — Networked Systems    (wireless, protocols, distributed sensing)
        6 — Autonomous Agents    (deep research bots, fleet management)

    Usage:
        local EraSystem = require(ServerScriptService.EraSystem)
        EraSystem.init()

        EraSystem.unlockEra(playerId, 2)
        local era = EraSystem.getCurrentEra(playerId)
        local canBuild = EraSystem.canBuild(playerId, "generator")
        EraSystem.onBuild(playerId, "waterwheel")

    Dependencies:
        - ReplicatedStorage.Lucineer.Http (for D1 persistence)
        - ServerScriptService.EraSystem.Recipes
]]

local Http = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("Http"))
local Recipes = require(script:WaitForChild("Recipes"))

local Players = game:GetService("Players")

-- Memory worker URL for era persistence
local MEMORY_URL = "https://lucineer-memory.casey-digennaro.workers.dev"

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
-- RUNTIME STATE (in-memory cache, persisted to D1)
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → era state
-- { currentEra = number, unlockedEras = {[0]=true,...}, eraXP = {["0"]=5,...}, buildCounts = {} }
local playerStates = {}

-- Tracks builds that have been counted toward era unlocks
-- playerName → { [buildType] = count }
local function getBuildCounts(playerName)
    local state = playerStates[playerName]
    if not state then return {} end
    if not state.buildCounts then state.buildCounts = {} end
    return state.buildCounts
end

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
    -- Async fetch; on failure, default to era 0
    local success, result = pcall(function()
        return Http.post(MEMORY_URL .. "/api/era/load", {
            playerName = playerName,
        })
    end)

    if success and result and result.currentEra then
        playerStates[playerName] = {
            currentEra = result.currentEra,
            unlockedEras = {},
            eraXP = result.eraXP or {},
            buildCounts = {},
        }
        -- Reconstruct unlockedEras set
        for _, eraNum in ipairs(result.unlockedEras or {0}) do
            playerStates[playerName].unlockedEras[eraNum] = true
        end
    else
        -- Default: era 0 unlocked
        playerStates[playerName] = {
            currentEra = 0,
            unlockedEras = { [0] = true },
            eraXP = {},
            buildCounts = {},
        }
    end
end

-- Save player era state to D1
local function savePlayer(playerName)
    local state = playerStates[playerName]
    if not state then return end

    local unlockedList = {}
    for eraNum in pairs(state.unlockedEras) do
        table.insert(unlockedList, eraNum)
    end
    table.sort(unlockedList)

    pcall(function()
        Http.post(MEMORY_URL .. "/api/era/save", {
            playerName = playerName,
            currentEra = state.currentEra,
            unlockedEras = unlockedList,
            eraXP = state.eraXP,
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

    -- Check if this build triggers an era unlock
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

print("[EraSystem] Module loaded — " .. #Recipes.getAll() .. " recipes across 7 eras")

return EraSystem
