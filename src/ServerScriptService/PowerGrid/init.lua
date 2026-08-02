--!strict
--[[
    PowerGrid — Slackwater's Unified Power Management System
    =========================================================
    Manages all power generation, transmission, and consumption
    across the 7-era technology progression.

    Era 0-1: Mechanical power (shafts, belts, gears, water wheels)
    Era 2+:  Electrical power (generators, wire, lamps, motors)

    The grid is a graph of devices connected by edges (wires or shafts).
    Each connected component forms an isolated power network with its own
    supply, demand, and distribution logic.

    API:
        PowerGrid.init()
        PowerGrid.registerSource(deviceId, type, output_kW, position)
        PowerGrid.registerConsumer(deviceId, type, demand_kW, position)
        PowerGrid.connect(deviceA, deviceB, connectionType)
        PowerGrid.disconnect(deviceA, deviceB)
        PowerGrid.getGridStatus()           -> {supply, demand, balance, ...}
        PowerGrid.getDevicePower(deviceId)  -> {supplied, required, ratio}
        PowerGrid.removeDevice(deviceId)
        PowerGrid.tick(dt)                  — call every frame or heartbeat

    Dependencies:
        - ServerScriptService.PowerGrid.Mechanical (optional, Era 0-1)
        - ServerScriptService.PowerGrid.Visualization (optional, visual feedback)

    Design Notes:
        - Devices are identified by a string deviceId (usually "type_<guid>").
        - Each device belongs to exactly one network (connected component).
        - Networks are recomputed via flood-fill when connections change.
        - Power flows from sources to consumers within the same network.
        - Distance-based loss applies per edge (wire resistance, shaft friction).
        - Brownout at <80% supply/demand ratio; blackout at <30%.
]]

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- Optional sub-modules (loaded defensively)
local Visualization
local Mechanical

local ok_viz, vizModule = pcall(function()
    return script:WaitForChild("Visualization")
end)
if ok_viz then
    local ok2 = pcall(function()
        Visualization = require(vizModule)
    end)
end

local ok_mech, mechModule = pcall(function()
    return script:WaitForChild("Mechanical")
end)
if ok_mech then
    local ok2 = pcall(function()
        Mechanical = require(mechModule)
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local EDGE = {
    WIRE = "wire",
    SHAFT = "shaft",
    BELT = "belt",
}

-- Distance-based loss per connection (fraction lost per stud)
local LOSS_PER_STUD = {
    wire = 0.001,   -- 0.1% per stud
    shaft = 0.002,  -- 0.2% per stud (mechanical friction)
    belt = 0.003,   -- 0.3% per stud (belt slip)
}

-- Maximum connection distance (studs)
local MAX_DISTANCE = {
    wire = 200,
    shaft = 30,
    belt = 50,
}

-- Brownout/blackout thresholds
local BROWNOUT_THRESHOLD = 0.80  -- below 80% supply/demand → brownout
local BLACKOUT_THRESHOLD = 0.30  -- below 30% → blackout

-- Tick interval (seconds) for grid recalculation
local TICK_INTERVAL = 0.5

-- Source type base outputs (kW) — can be overridden in registerSource
local SOURCE_BASE_OUTPUT = {
    waterwheel = 2.0,
    windmill = 2.0,      -- varies 1-3 with weather
    steam_engine = 5.0,
    generator = 10.0,
    solar_panel = 0.5,
    water_turbine = 4.0,
    steam_turbine = 8.0,
}

-- Consumer type base demands (kW)
local CONSUMER_BASE_DEMAND = {
    lamp = 0.1,
    led = 0.02,
    motor = 1.0,         -- varies 0.5-2.0
    heater = 1.0,
    heating_element = 1.0,
    sensor = 0.05,
    light_sensor = 0.05,
    proximity_sensor = 0.05,
    temperature_sensor = 0.05,
    arduino_board = 0.01,
    esp8266 = 0.01,
    esp32 = 0.02,
    crafting_station = 1.0,
    trip_hammer = 1.5,
    bellows = 0.5,
    buzzer = 0.03,
    solenoid = 0.1,
    electromagnet = 0.3,
    lcd_display = 0.05,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- DATA STRUCTURES
-- ═══════════════════════════════════════════════════════════════════════════

-- deviceId → device table
-- Device = {
--   id = string,
--   kind = "source" | "consumer" | "hybrid",
--   type = string (e.g. "waterwheel", "lamp"),
--   output_kW = number (sources only, 0 for consumers),
--   demand_kW = number (consumers only, 0 for sources),
--   position = Vector3,
--   networkId = number | nil,
--   supplied_kW = number (calculated per tick),
--   required_kW = number (calculated per tick),
--   ratio = number (supplied/required, 1.0 = full power),
--   state = "normal" | "brownout" | "blackout",
--   instance = Instance | nil (the Roblox part/model, for visualization),
-- }
local devices = {}

-- Adjacency list: deviceId → { {to = deviceId, type = edgeType, loss = fraction}, ... }
local adjacency = {}

-- Network table: networkId → { supply = number, demand = number, deviceIds = {id=true,...} }
local networks = {}

-- Edge key lookup for fast disconnect: "devA|devB" → edge data
local edgeKeys = {}

-- Counter for network IDs
local nextNetworkId = 1

-- Counter for device IDs
local idCounter = 0

-- Accumulated tick timer
local tickAccumulator = 0

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════

local function generateId(prefix)
    idCounter = idCounter + 1
    return string.format("%s_%d_%d", prefix or "device", os.clock(), idCounter)
end

local function distance(a, b)
    if typeof(a) == "Vector3" and typeof(b) == "Vector3" then
        return (a - b).Magnitude
    end
    return 0
end

local function edgeKey(a, b)
    if a < b then return a .. "|" .. b
    else return b .. "|" .. a end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- ═══════════════════════════════════════════════════════════════════════════
-- NETWORK COMPUTATION (flood-fill connected components)
-- ═══════════════════════════════════════════════════════════════════════════

local function computeNetworks()
    -- Reset all network assignments
    networks = {}
    nextNetworkId = 1

    local visited = {}
    local queue = {}

    for deviceId, _ in pairs(devices) do
        if not visited[deviceId] then
            -- Start a new network
            local netId = nextNetworkId
            nextNetworkId = nextNetworkId + 1

            local net = {
                id = netId,
                supply = 0,
                demand = 0,
                deviceIds = {},
                sourceCount = 0,
                consumerCount = 0,
            }

            -- BFS flood fill
            queue = { deviceId }
            local head = 1
            while head <= #queue do
                local current = queue[head]
                head = head + 1

                if not visited[current] then
                    visited[current] = true
                    local dev = devices[current]
                    if dev then
                        dev.networkId = netId
                        net.deviceIds[current] = true

                        if dev.kind == "source" or dev.kind == "hybrid" then
                            net.supply = net.supply + dev.output_kW
                            net.sourceCount = net.sourceCount + 1
                        end
                        if dev.kind == "consumer" or dev.kind == "hybrid" then
                            net.demand = net.demand + dev.demand_kW
                            net.consumerCount = net.consumerCount + 1
                        end

                        -- Enqueue neighbors
                        local neighbors = adjacency[current]
                        if neighbors then
                            for _, edge in ipairs(neighbors) do
                                if not visited[edge.to] then
                                    table.insert(queue, edge.to)
                                end
                            end
                        end
                    end
                end
            end

            net.balance = net.supply - net.demand
            net.ratio = net.demand > 0 and clamp(net.supply / net.demand, 0, 1) or 1
            networks[netId] = net
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- POWER DISTRIBUTION
-- ═══════════════════════════════════════════════════════════════════════════

local function distributePower()
    for netId, net in pairs(networks) do
        -- Calculate effective supply after edge losses
        -- (Simple model: average loss across the network's edges)
        local edgeCount = 0
        local totalLoss = 0
        for devId in pairs(net.deviceIds) do
            local neighbors = adjacency[devId]
            if neighbors then
                for _, edge in ipairs(neighbors) do
                    -- Count each edge once
                    if devId < edge.to or not net.deviceIds[edge.to] then
                        -- skip (edges counted from the lower id side)
                    end
                    if devId < edge.to and net.deviceIds[edge.to] then
                        edgeCount = edgeCount + 1
                        totalLoss = totalLoss + edge.loss
                    end
                end
            end
        end

        local avgLoss = 0
        if edgeCount > 0 then
            avgLoss = totalLoss / edgeCount
        end

        local effectiveSupply = net.supply * (1 - avgLoss * 0.5) -- dampen the effect
        local ratio = net.demand > 0 and clamp(effectiveSupply / net.demand, 0, 1) or 1

        -- Determine network state
        local state = "normal"
        if ratio < BLACKOUT_THRESHOLD then
            state = "blackout"
        elseif ratio < BROWNOUT_THRESHOLD then
            state = "brownout"
        end

        -- Distribute to each device in the network
        for devId in pairs(net.deviceIds) do
            local dev = devices[devId]
            if dev then
                if dev.kind == "consumer" or dev.kind == "hybrid" then
                    dev.supplied_kW = dev.demand_kW * ratio
                    dev.required_kW = dev.demand_kW
                    dev.ratio = ratio
                    dev.state = state
                elseif dev.kind == "source" then
                    dev.supplied_kW = 0
                    dev.required_kW = 0
                    dev.ratio = 1
                    dev.state = "normal"
                end
            end
        end

        -- Store updated values on the network
        net.effectiveSupply = effectiveSupply
        net.ratio = ratio
        net.state = state
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONNECTION VALIDATION
-- ═══════════════════════════════════════════════════════════════════════════

local function validateConnection(deviceA, deviceB, connectionType)
    if not devices[deviceA] then
        return false, "Device not found: " .. tostring(deviceA)
    end
    if not devices[deviceB] then
        return false, "Device not found: " .. tostring(deviceB)
    end
    if deviceA == deviceB then
        return false, "Cannot connect a device to itself"
    end
    if not EDGE[connectionType:upper()] then
        return false, "Unknown connection type: " .. tostring(connectionType)
    end

    local edgeType = EDGE[connectionType:upper()]
    local maxDist = MAX_DISTANCE[edgeType]
    if maxDist then
        local dist = distance(devices[deviceA].position, devices[deviceB].position)
        if dist > maxDist then
            return false, string.format("Distance %.1f exceeds max %.1f for %s connections",
                dist, maxDist, edgeType)
        end
    end

    return true, edgeType
end

local function computeEdgeLoss(deviceA, deviceB, edgeType)
    local dist = distance(devices[deviceA].position, devices[deviceB].position)
    local lossRate = LOSS_PER_STUD[edgeType] or 0
    local rawLoss = dist * lossRate
    return clamp(rawLoss, 0, 0.5) -- cap at 50% loss per edge
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

local PowerGrid = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- Initialize the power grid system
-- ═══════════════════════════════════════════════════════════════════════════

local initialized = false

function PowerGrid.init()
    if initialized then return end
    initialized = true

    -- Hook into RunService heartbeat for grid updates
    RunService.Heartbeat:Connect(function(dt)
        PowerGrid.tick(dt)
    end)

    -- Initialize sub-modules
    if Mechanical and Mechanical.init then
        Mechanical.init(PowerGrid)
    end
    if Visualization and Visualization.init then
        Visualization.init(PowerGrid)
    end

    print("[PowerGrid] Initialized — managing power across all eras")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Register a power source
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.registerSource(deviceId, sourceType, output_kW, position)
    deviceId = deviceId or generateId(sourceType)
    output_kW = output_kW or SOURCE_BASE_OUTPUT[sourceType] or 1.0

    devices[deviceId] = {
        id = deviceId,
        kind = "source",
        type = sourceType,
        output_kW = output_kW,
        demand_kW = 0,
        position = position or Vector3.new(0, 0, 0),
        networkId = nil,
        supplied_kW = 0,
        required_kW = 0,
        ratio = 1,
        state = "normal",
        instance = nil,
    }

    -- Initialize adjacency entry
    if not adjacency[deviceId] then
        adjacency[deviceId] = {}
    end

    -- Recompute networks
    computeNetworks()
    distributePower()

    return deviceId
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Register a power consumer
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.registerConsumer(deviceId, consumerType, demand_kW, position)
    deviceId = deviceId or generateId(consumerType)
    demand_kW = demand_kW or CONSUMER_BASE_DEMAND[consumerType] or 0.1

    devices[deviceId] = {
        id = deviceId,
        kind = "consumer",
        type = consumerType,
        output_kW = 0,
        demand_kW = demand_kW,
        position = position or Vector3.new(0, 0, 0),
        networkId = nil,
        supplied_kW = demand_kW, -- start fully powered until grid says otherwise
        required_kW = demand_kW,
        ratio = 1,
        state = "normal",
        instance = nil,
    }

    if not adjacency[deviceId] then
        adjacency[deviceId] = {}
    end

    computeNetworks()
    distributePower()

    return deviceId
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Register a hybrid device (both source and consumer, e.g. generator needing mechanical input)
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.registerHybrid(deviceId, deviceType, output_kW, demand_kW, position)
    deviceId = deviceId or generateId(deviceType)

    devices[deviceId] = {
        id = deviceId,
        kind = "hybrid",
        type = deviceType,
        output_kW = output_kW or 0,
        demand_kW = demand_kW or 0,
        position = position or Vector3.new(0, 0, 0),
        networkId = nil,
        supplied_kW = 0,
        required_kW = demand_kW or 0,
        ratio = 1,
        state = "normal",
        instance = nil,
    }

    if not adjacency[deviceId] then
        adjacency[deviceId] = {}
    end

    computeNetworks()
    distributePower()

    return deviceId
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Connect two devices
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.connect(deviceA, deviceB, connectionType)
    local ok, edgeTypeOrErr = validateConnection(deviceA, deviceB, connectionType)
    if not ok then
        warn("[PowerGrid] Connection failed: " .. edgeTypeOrErr)
        return false, edgeTypeOrErr
    end

    local edgeType = edgeTypeOrErr -- "wire" | "shaft" | "belt"
    local loss = computeEdgeLoss(deviceA, deviceB, edgeType)

    -- Check if already connected
    local existingKey = edgeKey(deviceA, deviceB)
    if edgeKeys[existingKey] then
        -- Update existing edge
        edgeKeys[existingKey].type = edgeType
        edgeKeys[existingKey].loss = loss
    else
        edgeKeys[existingKey] = { type = edgeType, loss = loss }
    end

    -- Add to both adjacency lists (undirected)
    local function addEdge(from, to)
        if not adjacency[from] then adjacency[from] = {} end
        -- Check for duplicate
        for _, e in ipairs(adjacency[from]) do
            if e.to == to then
                e.type = edgeType
                e.loss = loss
                return
            end
        end
        table.insert(adjacency[from], { to = to, type = edgeType, loss = loss })
    end

    addEdge(deviceA, deviceB)
    addEdge(deviceB, deviceA)

    -- Recompute
    computeNetworks()
    distributePower()

    -- Notify visualization
    if Visualization and Visualization.onConnect then
        Visualization.onConnect(deviceA, deviceB, edgeType, loss)
    end

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Disconnect two devices
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.disconnect(deviceA, deviceB)
    local function removeEdge(from, to)
        local list = adjacency[from]
        if not list then return end
        for i = #list, 1, -1 do
            if list[i].to == to then
                table.remove(list, i)
            end
        end
    end

    removeEdge(deviceA, deviceB)
    removeEdge(deviceB, deviceA)

    local key = edgeKey(deviceA, deviceB)
    edgeKeys[key] = nil

    computeNetworks()
    distributePower()

    if Visualization and Visualization.onDisconnect then
        Visualization.onDisconnect(deviceA, deviceB)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Remove a device entirely
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.removeDevice(deviceId)
    if not devices[deviceId] then return end

    -- Disconnect all edges
    local neighbors = adjacency[deviceId]
    if neighbors then
        -- Copy the list since we'll be modifying adjacency during iteration
        local toDisconnect = {}
        for _, edge in ipairs(neighbors) do
            table.insert(toDisconnect, edge.to)
        end
        for _, otherId in ipairs(toDisconnect) do
            PowerGrid.disconnect(deviceId, otherId)
        end
    end

    -- Remove the device
    devices[deviceId] = nil
    adjacency[deviceId] = nil

    computeNetworks()
    distributePower()

    if Visualization and Visualization.onRemoveDevice then
        Visualization.onRemoveDevice(deviceId)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Get overall grid status
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.getGridStatus()
    local totalSupply = 0
    local totalDemand = 0
    local totalEffective = 0
    local sourceCount = 0
    local consumerCount = 0
    local networkCount = 0

    for _, net in pairs(networks) do
        networkCount = networkCount + 1
        totalSupply = totalSupply + net.supply
        totalDemand = totalDemand + net.demand
        totalEffective = totalEffective + (net.effectiveSupply or net.supply)
        sourceCount = sourceCount + net.sourceCount
        consumerCount = consumerCount + net.consumerCount
    end

    local balance = totalEffective - totalDemand
    local ratio = totalDemand > 0 and clamp(totalEffective / totalDemand, 0, 1) or 1

    local state = "normal"
    if ratio < BLACKOUT_THRESHOLD then
        state = "blackout"
    elseif ratio < BROWNOUT_THRESHOLD then
        state = "brownout"
    end

    return {
        supply = totalSupply,
        effectiveSupply = totalEffective,
        demand = totalDemand,
        balance = balance,
        ratio = ratio,
        state = state,
        sources = sourceCount,
        consumers = consumerCount,
        networks = networkCount,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Get power info for a specific device
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.getDevicePower(deviceId)
    local dev = devices[deviceId]
    if not dev then
        return nil
    end

    return {
        id = dev.id,
        type = dev.type,
        kind = dev.kind,
        supplied = dev.supplied_kW,
        required = dev.required_kW,
        output = dev.output_kW,
        ratio = dev.ratio,
        state = dev.state,
        networkId = dev.networkId,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Get all devices (optionally filtered by kind or network)
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.getDevices(filter)
    local result = {}
    for id, dev in pairs(devices) do
        if not filter or (filter.kind and dev.kind == filter.kind)
                       or (filter.type and dev.type == filter.type)
                       or (filter.networkId and dev.networkId == filter.networkId) then
            table.insert(result, {
                id = dev.id,
                type = dev.type,
                kind = dev.kind,
                output_kW = dev.output_kW,
                demand_kW = dev.demand_kW,
                position = dev.position,
                state = dev.state,
                ratio = dev.ratio,
                networkId = dev.networkId,
            })
        end
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Get all connections
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.getConnections()
    local result = {}
    local seen = {}
    for devId, neighbors in pairs(adjacency) do
        for _, edge in ipairs(neighbors) do
            local key = edgeKey(devId, edge.to)
            if not seen[key] then
                seen[key] = true
                table.insert(result, {
                    from = devId,
                    to = edge.to,
                    type = edge.type,
                    loss = edge.loss,
                })
            end
        end
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Get network info by ID
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.getNetwork(networkId)
    return networks[networkId]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Get all networks
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.getNetworks()
    local result = {}
    for _, net in pairs(networks) do
        table.insert(result, {
            id = net.id,
            supply = net.supply,
            effectiveSupply = net.effectiveSupply or net.supply,
            demand = net.demand,
            balance = (net.effectiveSupply or net.supply) - net.demand,
            ratio = net.ratio,
            state = net.state,
            sourceCount = net.sourceCount,
            consumerCount = net.consumerCount,
        })
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Update a device's output (e.g., windmill speed changes with weather)
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.setOutput(deviceId, output_kW)
    local dev = devices[deviceId]
    if not dev then return false end
    dev.output_kW = output_kW
    computeNetworks()
    distributePower()
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Update a device's demand (e.g., thermostat turning heater on/off)
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.setDemand(deviceId, demand_kW)
    local dev = devices[deviceId]
    if not dev then return false end
    dev.demand_kW = demand_kW
    dev.required_kW = demand_kW
    computeNetworks()
    distributePower()
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Update a device's position (for distance recalculation)
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.setPosition(deviceId, position)
    local dev = devices[deviceId]
    if not dev then return false end
    dev.position = position

    -- Recompute edge losses for connected edges
    local neighbors = adjacency[deviceId]
    if neighbors then
        for _, edge in ipairs(neighbors) do
            local newLoss = computeEdgeLoss(deviceId, edge.to, edge.type)
            edge.loss = newLoss
            -- Update reverse edge too
            local reverseList = adjacency[edge.to]
            if reverseList then
                for _, revEdge in ipairs(reverseList) do
                    if revEdge.to == deviceId then
                        revEdge.loss = newLoss
                    end
                end
            end
            -- Update key store
            local key = edgeKey(deviceId, edge.to)
            if edgeKeys[key] then
                edgeKeys[key].loss = newLoss
            end
        end
    end

    computeNetworks()
    distributePower()
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Attach a Roblox Instance to a device (for visualization hooks)
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.attachInstance(deviceId, instance)
    local dev = devices[deviceId]
    if not dev then return false end
    dev.instance = instance
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Generate a unique device ID (for external systems)
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.generateDeviceId(prefix)
    return generateId(prefix)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Check if a device exists
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.hasDevice(deviceId)
    return devices[deviceId] ~= nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Get the connection type constants (for external code)
-- ═══════════════════════════════════════════════════════════════════════════

PowerGrid.EDGE = EDGE
PowerGrid.LOSS_PER_STUD = LOSS_PER_STUD
PowerGrid.MAX_DISTANCE = MAX_DISTANCE
PowerGrid.BROWNOUT_THRESHOLD = BROWNOUT_THRESHOLD
PowerGrid.BLACKOUT_THRESHOLD = BLACKOUT_THRESHOLD

-- ═══════════════════════════════════════════════════════════════════════════
-- PERIODIC TICK — recalculates and applies power state to instances
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.tick(dt)
    tickAccumulator = tickAccumulator + dt
    if tickAccumulator < TICK_INTERVAL then return end
    tickAccumulator = 0

    -- Recompute and distribute
    computeNetworks()
    distributePower()

    -- Apply visual / mechanical updates
    if Visualization and Visualization.tick then
        Visualization.tick(devices, networks, adjacency)
    end
    if Mechanical and Mechanical.tick then
        Mechanical.tick(devices, networks, adjacency)
    end

    -- Apply power state to Roblox instances
    for deviceId, dev in pairs(devices) do
        if dev.instance then
            local ratio = dev.ratio or 1

            -- Adjust PointLight brightness for lamps
            local light = dev.instance:FindFirstChildWhichIsA("PointLight")
            if light then
                light.Brightness = (light:GetAttribute("baseBrightness") or light.Brightness) * ratio
                if not light:GetAttribute("baseBrightness") then
                    light:SetAttribute("baseBrightness", light.Brightness / math.max(ratio, 0.01))
                end
                light.Enabled = ratio > 0.05
            end

            -- Adjust Motor speed for motorized parts
            local motor = dev.instance:FindFirstChildWhichIsA("HingeConstraint")
            if motor and motor:IsA("HingeConstraint") then
                local baseSpeed = motor:GetAttribute("baseAngularVelocity") or motor.AngularVelocity
                if not motor:GetAttribute("baseAngularVelocity") then
                    motor:SetAttribute("baseAngularVelocity", baseSpeed)
                end
                motor.AngularVelocity = baseSpeed * ratio
                motor.MotorState = ratio > 0.05 and "Running" or "Off"
            end

            -- Adjust Part material/color for brownout/blackout indicator
            if dev.kind == "consumer" or dev.kind == "hybrid" then
                if dev.state == "blackout" then
                    dev.instance:SetAttribute("powerState", "blackout")
                elseif dev.state == "brownout" then
                    dev.instance:SetAttribute("powerState", "brownout")
                else
                    dev.instance:SetAttribute("powerState", "normal")
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DEBUG / DIAGNOSTICS
-- ═══════════════════════════════════════════════════════════════════════════

function PowerGrid.debug()
    local status = PowerGrid.getGridStatus()
    print(string.format("\n[PowerGrid] === GRID STATUS ==="))
    print(string.format("  Networks: %d | Sources: %d | Consumers: %d",
        status.networks, status.sources, status.consumers))
    print(string.format("  Supply: %.2f kW (effective: %.2f kW) | Demand: %.2f kW | Balance: %+.2f kW",
        status.supply, status.effectiveSupply, status.demand, status.balance))
    print(string.format("  Ratio: %.0f%% | State: %s", status.ratio * 100, status.state))

    for _, net in pairs(networks) do
        print(string.format("  Network #%d: supply=%.2f demand=%.2f ratio=%.0f%% state=%s devices=%d",
            net.id, net.supply, net.demand, (net.ratio or 0) * 100, net.state or "?",
            (function()
                local c = 0
                for _ in pairs(net.deviceIds) do c = c + 1 end
                return c
            end)()))
    end

    local connections = PowerGrid.getConnections()
    print(string.format("  Total connections: %d", #connections))
end

function PowerGrid.debugDevices()
    print("\n[PowerGrid] === DEVICES ===")
    for id, dev in pairs(devices) do
        print(string.format("  %s [%s/%s] out=%.2f dem=%.2f sup=%.2f ratio=%.0f%% state=%s net=%s",
            id, dev.kind, dev.type, dev.output_kW, dev.demand_kW,
            dev.supplied_kW, (dev.ratio or 0) * 100, dev.state,
            tostring(dev.networkId)))
    end
end

print("[PowerGrid] Module loaded — power management for all eras")

return PowerGrid
