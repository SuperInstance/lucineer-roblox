--!strict
--[[
    Mechanical — Mechanical Power Transmission System
    ==================================================
    For Era 0-1, power is mechanical, not electrical.
    Shafts transfer rotational energy, gearboxes change RPM,
    belts connect shafts at a distance, and flywheels smooth fluctuations.

    This module integrates with PowerGrid as a separate mechanical network
    that eventually feeds electrical generators in Era 2+.

    Key Concepts:
    ─────────────
    • Mechanical power is measured in kW (same unit as electrical).
    • Each shaft has an RPM and torque (power = torque × angular velocity).
    • Gearboxes trade speed for torque at a fixed ratio.
    • Belts connect shafts with some slip (efficiency loss).
    • Flywheels store rotational energy, smoothing out intermittent sources.
    • Mechanical networks can feed generators → electrical networks.

    Mechanical Network Model:
    ────────────────────────
    Sources (waterwheel, windmill, steam engine) →
      Shafts → Gearboxes → Belts → Consumers (trip hammer, bellows, generator)

    The mechanical system wraps the PowerGrid's shaft/belt connections,
    adding RPM tracking, torque calculations, flywheel buffering, and
    gearbox ratio transformations.

    API:
        Mechanical.init(powerGrid)
        Mechanical.tick(devices, networks, adjacency)

        Mechanical.registerShaftNode(deviceId, position, isSource, power_kW)
        Mechanical.setGearRatio(deviceId, inputRPM, outputRPM)
        Mechanical.attachFlywheel(deviceId, mass, radius)
        Mechanical.attachGenerator(deviceId, generatorDeviceId)
        Mechanical.getShaftRPM(deviceId) → number
        Mechanical.getShaftTorque(deviceId) → number
        Mechanical.getMechanicalNetwork(deviceId) → network data
        Mechanical.removeShaftNode(deviceId)
]]

local RunService = game:GetService("RunService")

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

-- Base RPM for mechanical sources
local BASE_RPM = {
    waterwheel = 8,       -- slow, steady
    windmill = 15,        -- moderate, variable
    steam_engine = 60,    -- fast, consistent
    water_turbine = 120,  -- fast (enclosed flow)
    steam_turbine = 1800, -- very fast
    hand_crank = 30,      -- manual
}

-- Efficiency of mechanical components (fraction of power preserved)
local EFFICIENCY = {
    shaft = 0.98,      -- 2% friction loss per shaft segment
    belt = 0.92,       -- 8% slip loss per belt
    gearbox = 0.90,    -- 10% meshing loss per gearbox
    chain = 0.96,      -- 4% loss per chain drive
    coupling = 0.99,   -- 1% loss per coupling
    universal_joint = 0.95, -- 5% loss per U-joint
}

-- Flywheel energy storage constant (kJ per kg·m² at 1 RPM)
local FLYWHEEL_CONSTANT = 0.0055

-- RPM limits (for structural integrity)
local MAX_SHAFT_RPM = 3000
local MAX_WOODEN_SHAFT_RPM = 200
local MAX_BELT_RPM = 800

-- Tick interval for mechanical simulation
local MECH_TICK_INTERVAL = 0.25

-- ═══════════════════════════════════════════════════════════════════════════
-- DATA STRUCTURES
-- ═══════════════════════════════════════════════════════════════════════════

-- deviceId → mechanical node data
-- Node = {
--   id = string,
--   position = Vector3,
--   isSource = boolean,
--   sourceType = string | nil,
--   basePower_kW = number,
--   currentPower_kW = number,
--   rpm = number,
--   targetRPM = number,
--   torque = number,          -- N·m equivalent (power / angular velocity)
--   gearRatio = number,       -- output_rpm / input_rpm (1 = direct)
--   flywheel = { mass, radius, storedEnergy, maxEnergy } | nil,
--   generatorLink = string | nil,  -- deviceId of linked electrical generator
--   material = "wood" | "metal",
--   maxRPM = number,
--   connections = { { to = deviceId, type = string, efficiency = number }, ... },
--   networkId = number | nil,
--   overloaded = boolean,
--   rpmHistory = { number, ... }, -- recent RPM values for smoothing
-- }
local nodes = {}

-- Mechanical network table (separate from electrical)
-- networkId → { supply, demand, rpm, torque, nodes = {}, flywheelEnergy }
local mechNetworks = {}

local nextMechNetworkId = 1
local powerGridRef
local tickAccumulator = 0

local Mechanical = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function smoothRPM(node, newRPM)
    -- Rolling average for RPM smoothing (simulates mechanical inertia)
    if not node.rpmHistory then
        node.rpmHistory = {}
    end
    table.insert(node.rpmHistory, newRPM)
    -- Keep last 5 samples
    while #node.rpmHistory > 5 do
        table.remove(node.rpmHistory, 1)
    end
    local sum = 0
    for _, v in ipairs(node.rpmHistory) do
        sum = sum + v
    end
    return sum / #node.rpmHistory
end

local function powerToRPM(power_kW, sourceType)
    local baseRPM = BASE_RPM[sourceType] or 30
    -- Scale RPM with power level relative to base
    return clamp(baseRPM * (power_kW > 0 and 1 or 0), 0, MAX_SHAFT_RPM)
end

local function rpmToTorque(power_kW, rpm)
    -- Simplified: torque = power / angular_velocity
    if rpm < 0.1 then return 0 end
    -- Angular velocity in rad/s = rpm × 2π/60
    local omega = rpm * 2 * math.pi / 60
    -- Power in kW → W = power_kW × 1000
    -- Torque = Power / omega (in N·m)
    return (power_kW * 1000) / omega
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MECHANICAL NETWORK COMPUTATION
-- ═══════════════════════════════════════════════════════════════════════════

local function computeMechNetworks()
    -- Build adjacency from PowerGrid's shaft/belt connections
    -- We treat any PowerGrid edge of type "shaft" or "belt" as mechanical
    if not powerGridRef then return end

    -- Reset networks
    mechNetworks = {}
    nextMechNetworkId = 1

    local visited = {}
    local queue = {}

    for nodeId, _ in pairs(nodes) do
        if not visited[nodeId] then
            local netId = nextMechNetworkId
            nextMechNetworkId = nextMechNetworkId + 1

            local net = {
                id = netId,
                supply = 0,
                demand = 0,
                rpm = 0,
                torque = 0,
                nodeIds = {},
                sourceCount = 0,
                consumerCount = 0,
                flywheelEnergy = 0,
                maxFlywheelEnergy = 0,
                weightedRPM = 0,  -- RPM weighted by power
                totalPower = 0,
            }

            -- BFS flood fill through mechanical connections
            queue = { nodeId }
            local head = 1
            while head <= #queue do
                local current = queue[head]
                head = head + 1

                if not visited[current] then
                    visited[current] = true
                    local node = nodes[current]
                    if node then
                        node.networkId = netId
                        net.nodeIds[current] = true

                        if node.isSource then
                            net.supply = net.supply + node.currentPower_kW
                            net.sourceCount = net.sourceCount + 1
                            net.totalPower = net.totalPower + node.currentPower_kW
                            net.weightedRPM = net.weightedRPM + node.rpm * node.currentPower_kW
                        else
                            net.demand = net.demand + (node.basePower_kW or 0)
                            net.consumerCount = net.consumerCount + 1
                        end

                        -- Flywheel storage
                        if node.flywheel then
                            net.flywheelEnergy = net.flywheelEnergy + node.flywheel.storedEnergy
                            net.maxFlywheelEnergy = net.maxFlywheelEnergy + node.flywheel.maxEnergy
                        end

                        -- Traverse mechanical connections
                        if node.connections then
                            for _, conn in ipairs(node.connections) do
                                if not visited[conn.to] and nodes[conn.to] then
                                    table.insert(queue, conn.to)
                                end
                            end
                        end
                    end
                end
            end

            -- Calculate network RPM (weighted average of sources)
            if net.totalPower > 0 then
                net.rpm = net.weightedRPM / net.totalPower
            else
                net.rpm = 0
            end

            -- Apply gear ratio effects (the network runs at a consensus RPM
            -- modified by the aggregate gear ratio)
            net.balance = net.supply - net.demand
            net.ratio = net.demand > 0 and clamp(net.supply / net.demand, 0, 1) or 1

            -- Torque from RPM and power
            net.torque = rpmToTorque(net.supply, net.rpm)

            mechNetworks[netId] = net
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FLYWHEEL ENERGY MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

local function updateFlywheels(netId, dt)
    local net = mechNetworks[netId]
    if not net then return end

    for nodeId in pairs(net.nodeIds) do
        local node = nodes[nodeId]
        if node and node.flywheel then
            local fw = node.flywheel

            -- Excess power charges the flywheel
            local excess = net.balance
            if excess > 0 then
                local charge = excess * dt * 0.5  -- 50% of excess goes to flywheel
                fw.storedEnergy = clamp(fw.storedEnergy + charge, 0, fw.maxEnergy)
            else
                -- Deficit draws from flywheel
                local deficit = -excess
                if deficit > 0 and fw.storedEnergy > 0 then
                    local discharge = math.min(deficit * dt, fw.storedEnergy)
                    fw.storedEnergy = fw.storedEnergy - discharge
                    -- This discharge effectively boosts supply
                    net.supply = net.supply + discharge / dt
                    net.balance = net.supply - net.demand
                    net.ratio = net.demand > 0 and clamp(net.supply / net.demand, 0, 1) or 1
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONNECTION SYNC (pull from PowerGrid's adjacency)
-- ═══════════════════════════════════════════════════════════════════════════

local function syncConnectionsFromPowerGrid()
    if not powerGridRef then return end

    local allConnections = powerGridRef.getConnections()
    for _, conn in ipairs(allConnections) do
        -- Only care about shaft and belt connections
        if conn.type == "shaft" or conn.type == "belt" or conn.type == "chain" then
            local nodeA = nodes[conn.from]
            local nodeB = nodes[conn.to]

            if nodeA and nodeB then
                -- Ensure connection exists on nodeA
                if not nodeA.connections then nodeA.connections = {} end
                local found = false
                for _, c in ipairs(nodeA.connections) do
                    if c.to == conn.to then
                        c.efficiency = EFFICIENCY[conn.type] or 0.95
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(nodeA.connections, {
                        to = conn.to,
                        type = conn.type,
                        efficiency = EFFICIENCY[conn.type] or 0.95,
                    })
                end

                -- Ensure connection exists on nodeB
                if not nodeB.connections then nodeB.connections = {} end
                found = false
                for _, c in ipairs(nodeB.connections) do
                    if c.to == conn.from then
                        c.efficiency = EFFICIENCY[conn.type] or 0.95
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(nodeB.connections, {
                        to = conn.from,
                        type = conn.type,
                        efficiency = EFFICIENCY[conn.type] or 0.95,
                    })
                end
            end
        end
    end

    -- Clean up stale connections (nodes that no longer exist in PowerGrid)
    for nodeId, node in pairs(nodes) do
        if node.connections then
            for i = #node.connections, 1, -1 do
                local c = node.connections[i]
                if not nodes[c.to] then
                    table.remove(node.connections, i)
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

local initialized = false

function Mechanical.init(pgRef)
    if initialized then return end
    initialized = true
    powerGridRef = pgRef

    print("[PowerGrid:Mechanical] Initialized — mechanical power transmission for Era 0-1")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SHAFT NODE REGISTRATION
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.registerShaftNode(deviceId, position, isSource, power_kW, sourceType)
    deviceId = deviceId or ("shaft_node_" .. tostring(os.clock()))
    sourceType = sourceType or "generic"

    local baseRPM = BASE_RPM[sourceType] or 30
    local material = "wood" -- default; metal unlocks in Era 1
    local maxRPM = material == "wood" and MAX_WOODEN_SHAFT_RPM or MAX_SHAFT_RPM

    local power = power_kW or 0

    nodes[deviceId] = {
        id = deviceId,
        position = position or Vector3.new(0, 0, 0),
        isSource = isSource or false,
        sourceType = isSource and sourceType or nil,
        basePower_kW = power,
        currentPower_kW = power,
        rpm = isSource and clamp(baseRPM, 0, maxRPM) or 0,
        targetRPM = isSource and clamp(baseRPM, 0, maxRPM) or 0,
        torque = rpmToTorque(power, baseRPM),
        gearRatio = 1.0,
        flywheel = nil,
        generatorLink = nil,
        material = material,
        maxRPM = maxRPM,
        connections = {},
        networkId = nil,
        overloaded = false,
        rpmHistory = {},
    }

    -- Also register in PowerGrid as a device
    if powerGridRef then
        if isSource then
            powerGridRef.registerSource(deviceId, sourceType, power, position)
        else
            powerGridRef.registerConsumer(deviceId, "mechanical_load", power, position)
        end
    end

    syncConnectionsFromPowerGrid()
    computeMechNetworks()

    return deviceId
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GEARBOX — set gear ratio on a node
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.setGearRatio(deviceId, inputRPM, outputRPM)
    local node = nodes[deviceId]
    if not node then
        warn("[PowerGrid:Mechanical] setGearRatio: node not found: " .. tostring(deviceId))
        return false
    end

    if inputRPM <= 0 then
        warn("[PowerGrid:Mechanical] setGearRatio: inputRPM must be > 0")
        return false
    end

    local ratio = outputRPM / inputRPM
    node.gearRatio = ratio

    -- Apply efficiency loss from the gearbox
    local efficiency = EFFICIENCY.gearbox
    node.currentPower_kW = node.basePower_kW * efficiency

    -- Adjust RPM by gear ratio (capped at maxRPM)
    node.targetRPM = clamp(node.targetRPM * ratio, 0, node.maxRPM)

    -- Recompute torque
    node.torque = rpmToTorque(node.currentPower_kW, node.rpm)

    computeMechNetworks()

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FLYWHEEL — attach rotational energy storage to a node
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.attachFlywheel(deviceId, mass, radius)
    local node = nodes[deviceId]
    if not node then
        warn("[PowerGrid:Mechanical] attachFlywheel: node not found: " .. tostring(deviceId))
        return false
    end

    mass = mass or 50     -- kg
    radius = radius or 1  -- meter

    -- Moment of inertia for a solid disc: I = 0.5 × m × r²
    local inertia = 0.5 * mass * radius * radius

    -- Max stored energy at max RPM: E = 0.5 × I × ω²
    local maxOmega = node.maxRPM * 2 * math.pi / 60
    local maxEnergy = 0.5 * inertia * maxOmega * maxOmega / 1000  -- convert to kJ

    node.flywheel = {
        mass = mass,
        radius = radius,
        inertia = inertia,
        storedEnergy = 0,
        maxEnergy = maxEnergy,
        currentRPM = 0,
    }

    computeMechNetworks()

    print(string.format("[PowerGrid:Mechanical] Flywheel attached to %s: %.1f kg, %.2f m, max energy %.2f kJ",
        deviceId, mass, radius, maxEnergy))

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GENERATOR LINK — connect mechanical source to electrical generator
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.attachGenerator(deviceId, generatorDeviceId)
    local node = nodes[deviceId]
    if not node then
        warn("[PowerGrid:Mechanical] attachGenerator: node not found: " .. tostring(deviceId))
        return false
    end

    node.generatorLink = generatorDeviceId

    print(string.format("[PowerGrid:Mechanical] Generator %s linked to mechanical source %s",
        generatorDeviceId, deviceId))

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SET MATERIAL — upgrade a shaft from wood to metal
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.setMaterial(deviceId, material)
    local node = nodes[deviceId]
    if not node then return false end

    if material == "metal" then
        node.material = "metal"
        node.maxRPM = MAX_SHAFT_RPM
    elseif material == "wood" then
        node.material = "wood"
        node.maxRPM = MAX_WOODEN_SHAFT_RPM
    else
        return false
    end

    -- Clamp current RPM
    node.rpm = clamp(node.rpm, 0, node.maxRPM)
    node.targetRPM = clamp(node.targetRPM, 0, node.maxRPM)

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GETTERS
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.getShaftRPM(deviceId)
    local node = nodes[deviceId]
    return node and node.rpm or 0
end

function Mechanical.getShaftTorque(deviceId)
    local node = nodes[deviceId]
    return node and node.torque or 0
end

function Mechanical.getShaftPower(deviceId)
    local node = nodes[deviceId]
    return node and node.currentPower_kW or 0
end

function Mechanical.getFlywheelEnergy(deviceId)
    local node = nodes[deviceId]
    if not node or not node.flywheel then return 0 end
    return node.flywheel.storedEnergy
end

function Mechanical.getFlywheelRatio(deviceId)
    local node = nodes[deviceId]
    if not node or not node.flywheel then return 0 end
    if node.flywheel.maxEnergy <= 0 then return 0 end
    return node.flywheel.storedEnergy / node.flywheel.maxEnergy
end

function Mechanical.getMechNetwork(deviceId)
    local node = nodes[deviceId]
    if not node or not node.networkId then return nil end
    return mechNetworks[node.networkId]
end

function Mechanical.getNode(deviceId)
    return nodes[deviceId]
end

function Mechanical.getAllNodes()
    local result = {}
    for id, node in pairs(nodes) do
        table.insert(result, {
            id = id,
            position = node.position,
            isSource = node.isSource,
            sourceType = node.sourceType,
            power_kW = node.currentPower_kW,
            rpm = node.rpm,
            torque = node.torque,
            gearRatio = node.gearRatio,
            material = node.material,
            maxRPM = node.maxRPM,
            hasFlywheel = node.flywheel ~= nil,
            generatorLink = node.generatorLink,
            networkId = node.networkId,
        })
    end
    return result
end

function Mechanical.getAllNetworks()
    local result = {}
    for id, net in pairs(mechNetworks) do
        table.insert(result, {
            id = id,
            supply = net.supply,
            demand = net.demand,
            balance = net.balance,
            ratio = net.ratio,
            rpm = net.rpm,
            torque = net.torque,
            sourceCount = net.sourceCount,
            consumerCount = net.consumerCount,
            flywheelEnergy = net.flywheelEnergy,
            maxFlywheelEnergy = net.maxFlywheelEnergy,
        })
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REMOVE A SHAFT NODE
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.removeShaftNode(deviceId)
    local node = nodes[deviceId]
    if not node then return end

    -- Clean up connections
    if node.connections then
        for _, conn in ipairs(node.connections) do
            local other = nodes[conn.to]
            if other and other.connections then
                for i = #other.connections, 1, -1 do
                    if other.connections[i].to == deviceId then
                        table.remove(other.connections, i)
                    end
                end
            end
        end
    end

    nodes[deviceId] = nil

    -- Also remove from PowerGrid
    if powerGridRef and powerGridRef.hasDevice(deviceId) then
        powerGridRef.removeDevice(deviceId)
    end

    computeMechNetworks()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UPDATE SOURCE POWER (e.g., wind changes, water flow stops)
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.setSourcePower(deviceId, power_kW)
    local node = nodes[deviceId]
    if not node or not node.isSource then return false end

    node.basePower_kW = power_kW
    node.currentPower_kW = power_kW

    -- Update RPM proportionally (more power = faster spin, roughly)
    local baseRPM = BASE_RPM[node.sourceType] or 30
    local powerFactor = power_kW > 0 and 1 or 0
    node.targetRPM = clamp(baseRPM * powerFactor, 0, node.maxRPM)

    -- Update PowerGrid output
    if powerGridRef then
        powerGridRef.setOutput(deviceId, power_kW)
    end

    -- Update generator link if present
    if node.generatorLink and powerGridRef then
        -- Generator output is proportional to mechanical input
        local generatorOutput = power_kW * 0.85  -- 85% conversion efficiency
        powerGridRef.setOutput(node.generatorLink, generatorOutput)
    end

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WEATHER / ENVIRONMENTAL EFFECTS
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.applyWindEffect(windSpeed)
    -- windSpeed: 0-1 scale (0 = still, 1 = gale force)
    windSpeed = clamp(windSpeed or 0, 0, 1)

    for _, node in pairs(nodes) do
        if node.isSource and node.sourceType == "windmill" then
            -- Power scales with wind speed cubed (real physics)
            local windFactor = windSpeed * windSpeed * windSpeed
            local newPower = (node.basePower_kW > 0 and node.basePower_kW or 2.0) * windFactor
            -- Keep within 1-3 kW range
            newPower = clamp(newPower, windSpeed > 0.1 and 1.0 or 0, 3.0)
            node.currentPower_kW = newPower
            node.targetRPM = clamp((BASE_RPM.windmill or 15) * windSpeed, 0, node.maxRPM)
        end
    end

    computeMechNetworks()
end

function Mechanical.applyWaterEffect(flowRate)
    -- flowRate: 0-1 scale (0 = dry, 1 = flood)
    flowRate = clamp(flowRate or 0, 0, 1)

    for _, node in pairs(nodes) do
        if node.isSource and (node.sourceType == "waterwheel" or node.sourceType == "water_turbine") then
            local newPower = (node.basePower_kW > 0 and node.basePower_kW or 2.0) * flowRate
            node.currentPower_kW = newPower
            local baseRPM = BASE_RPM[node.sourceType] or 8
            node.targetRPM = clamp(baseRPM * flowRate, 0, node.maxRPM)
        end
    end

    computeMechNetworks()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TICK — main mechanical simulation update
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.tick(devices, networks, adjacency)
    tickAccumulator = tickAccumulator + (1/6) -- approximate; called at ~0.5s intervals from PowerGrid
    if tickAccumulator < MECH_TICK_INTERVAL then return end
    tickAccumulator = 0

    -- Sync connections from PowerGrid
    syncConnectionsFromPowerGrid()

    -- Recompute networks
    computeMechNetworks()

    -- Update flywheels and power distribution
    for netId, net in pairs(mechNetworks) do
        local dt = MECH_TICK_INTERVAL
        updateFlywheels(netId, dt)

        -- Apply network state to all nodes
        for nodeId in pairs(net.nodeIds) do
            local node = nodes[nodeId]
            if node then
                -- Smooth RPM transitions (mechanical inertia)
                node.rpm = smoothRPM(node, net.rpm > 0 and net.rpm or node.targetRPM)

                -- Update torque
                node.torque = rpmToTorque(net.supply, node.rpm)

                -- Check for overload (RPM exceeds max)
                if node.rpm > node.maxRPM then
                    node.overloaded = true
                    -- Overloaded shafts lose efficiency (simulating stress)
                    node.currentPower_kW = node.basePower_kW * clamp(
                        node.maxRPM / node.rpm, 0, 1
                    )
                else
                    node.overloaded = false
                end

                -- Update flywheel RPM
                if node.flywheel then
                    node.flywheel.currentRPM = node.rpm
                end

                -- Update PowerGrid output for sources
                if node.isSource and powerGridRef then
                    powerGridRef.setOutput(nodeId, node.currentPower_kW)
                end

                -- Update generator link
                if node.generatorLink and powerGridRef and node.isSource then
                    local genOutput = node.currentPower_kW * 0.85
                    powerGridRef.setOutput(node.generatorLink, genOutput)
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DEBUG
-- ═══════════════════════════════════════════════════════════════════════════

function Mechanical.debug()
    print("\n[PowerGrid:Mechanical] === MECHANICAL NETWORKS ===")
    for netId, net in pairs(mechNetworks) do
        print(string.format("  Network #%d: supply=%.2f kW demand=%.2f kW ratio=%.0f%% RPM=%.0f torque=%.0f N·m",
            netId, net.supply, net.demand, (net.ratio or 0) * 100, net.rpm or 0, net.torque or 0))
        if net.flywheelEnergy > 0 then
            print(string.format("    Flywheel: %.2f / %.2f kJ stored",
                net.flywheelEnergy, net.maxFlywheelEnergy))
        end
    end

    print("\n[PowerGrid:Mechanical] === SHAFT NODES ===")
    for id, node in pairs(nodes) do
        local fwInfo = ""
        if node.flywheel then
            fwInfo = string.format(" flywheel=%.1f/%.1f kJ",
                node.flywheel.storedEnergy, node.flywheel.maxEnergy)
        end
        local genInfo = node.generatorLink and (" →gen:" .. node.generatorLink) or ""
        print(string.format("  %s [%s/%s] power=%.2f kW RPM=%.0f torque=%.0f ratio=%.2f%s%s net=%s",
            id, node.isSource and "SRC" or "LD", node.sourceType or node.material or "?",
            node.currentPower_kW, node.rpm, node.torque, node.gearRatio,
            fwInfo, genInfo, tostring(node.networkId)))
    end
end

print("[PowerGrid:Mechanical] Module loaded — rotational power for Era 0-1")

return Mechanical
