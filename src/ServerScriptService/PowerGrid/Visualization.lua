--!strict
--[[
    Visualization — Power Grid Visual Feedback
    ===========================================
    Provides visual feedback for the power system in the Roblox world.

    Features:
    • Wires glow when power flows (brightness proportional to load)
    • Shafts rotate when transmitting mechanical power
    • Belts visually move with speed proportional to power
    • Devices dim/slow when underpowered
    • Spark particles when a connection fails
    • Power grid overlay view (toggle to see all connections)

    This module is loaded by PowerGrid/init.lua via require().
    It receives callbacks from the PowerGrid tick loop.

    API (called by PowerGrid):
        Visualization.init(powerGrid)
        Visualization.tick(devices, networks, adjacency)
        Visualization.onConnect(deviceA, deviceB, edgeType, loss)
        Visualization.onDisconnect(deviceA, deviceB)
        Visualization.onRemoveDevice(deviceId)

    API (called externally):
        Visualization.setOverlayEnabled(enabled)
        Visualization.createWireVisual(deviceA, deviceB)
        Visualization.createShaftVisual(deviceA, deviceB)
        Visualization.createBeltVisual(deviceA, deviceB)
        Visualization.createSparkEffect(position)
]]

-- Services
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

-- Visual container (folder in Workspace for all power grid visuals)
local visualFolder

-- ═══════════════════════════════════════════════════════════════════════════
-- CONFIG
-- ═══════════════════════════════════════════════════════════════════════════

local WIRE_THICKNESS = 0.15
local SHAFT_THICKNESS = 0.25
local BELT_THICKNESS = 0.12

local WIRE_COLOR_OFF = Color3.fromRGB(40, 40, 40)
local WIRE_COLOR_LOW = Color3.fromRGB(80, 60, 30)
local WIRE_COLOR_MID = Color3.fromRGB(200, 150, 50)
local WIRE_COLOR_MAX = Color3.fromRGB(255, 230, 100)

local SHAFT_COLOR = Color3.fromRGB(120, 100, 80)
local SHAFT_COLOR_ACTIVE = Color3.fromRGB(160, 140, 100)

local BELT_COLOR = Color3.fromRGB(50, 35, 25)
local BELT_COLOR_ACTIVE = Color3.fromRGB(80, 55, 35)

local SPARK_COLOR = Color3.fromRGB(255, 200, 50)

local OVERLAY_COLOR_SUPPLY = Color3.fromRGB(50, 200, 100)
local OVERLAY_COLOR_DEMAND = Color3.fromRGB(200, 100, 50)
local OVERLAY_COLOR_BALANCED = Color3.fromRGB(100, 150, 255)
local OVERLAY_TRANSPARENCY = 0.4

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

local Visualization = {}

local powerGrid     -- reference to PowerGrid module
local overlayEnabled = false
local connectionVisuals = {}  -- "devA|devB" → visual data
local deviceVisuals = {}      -- deviceId → visual data
local overlayParts = {}       -- array of parts for the overlay view

-- Rotation state for shafts
local rotationAccumulator = 0

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════

local function edgeKey(a, b)
    if a < b then return a .. "|" .. b
    else return b .. "|" .. a end
end

local function lerpColor(c1, c2, t)
    return Color3.new(
        c1.r + (c2.r - c1.r) * t,
        c1.g + (c2.g - c1.g) * t,
        c1.b + (c2.b - c1.b) * t
    )
end

local function getWireColor(ratio)
    -- ratio: 0 = off, 0.5 = low, 0.8 = mid, 1.0 = max
    if ratio < 0.05 then return WIRE_COLOR_OFF end
    if ratio < 0.5 then
        return lerpColor(WIRE_COLOR_OFF, WIRE_COLOR_LOW, ratio * 2)
    elseif ratio < 0.8 then
        return lerpColor(WIRE_COLOR_LOW, WIRE_COLOR_MID, (ratio - 0.5) / 0.3)
    else
        return lerpColor(WIRE_COLOR_MID, WIRE_COLOR_MAX, (ratio - 0.8) / 0.2)
    end
end

local function getNeonBrightness(ratio)
    return 0.2 + ratio * 1.5
end

-- Create a cylinder between two points
local function createCylinderBetween(pointA, pointB, thickness, color, name)
    local distance = (pointB - pointA).Magnitude
    if distance < 0.01 then return nil end

    local cylinder = Instance.new("Part")
    cylinder.Name = name or "PowerCylinder"
    cylinder.Shape = Enum.PartType.Cylinder
    cylinder.Material = Enum.Material.SmoothPlastic
    cylinder.Color = color
    cylinder.Size = Vector3.new(distance, thickness, thickness)
    cylinder.Anchored = true
    cylinder.CanCollide = false
    cylinder.CanQuery = false
    cylinder.CastShadow = false

    -- Position at midpoint
    local midpoint = (pointA + pointB) / 2
    cylinder.CFrame = CFrame.lookAt(midpoint, pointB) * CFrame.Angles(0, math.rad(90), 0)
    cylinder.CFrame = CFrame.new(midpoint) * CFrame.Angles(0, 0, math.atan2(
        pointB.Y - pointA.Y, math.sqrt((pointB.X - pointA.X)^2 + (pointB.Z - pointA.Z)^2)
    ))

    -- Better orientation: use the lookAt approach for cylinders
    local direction = (pointB - pointA).Unit
    local up = Vector3.new(0, 1, 0)
    if math.abs(direction:Dot(up)) > 0.99 then
        up = Vector3.new(1, 0, 0)
    end
    local right = direction:Cross(up).Unit
    up = right:Cross(direction).Unit

    cylinder.CFrame = CFrame.new(
        midpoint.X, midpoint.Y, midpoint.Z,
        right.X, up.X, direction.X,
        right.Y, up.Y, direction.Y,
        right.Z, up.Z, direction.Z
    )
    -- Rotate for cylinder orientation (cylinder axis is along X)
    cylinder.CFrame = cylinder.CFrame * CFrame.Angles(0, math.rad(90), 0)

    cylinder.Parent = visualFolder
    return cylinder
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WIRE VISUALS
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.createWireVisual(deviceA, deviceB)
    local key = edgeKey(deviceA, deviceB)
    if connectionVisuals[key] then return connectionVisuals[key] end

    local wirePart = Instance.new("Part")
    wirePart.Name = "Wire_" .. deviceA .. "_" .. deviceB
    wirePart.Material = Enum.Material.Neon
    wirePart.Color = WIRE_COLOR_OFF
    wirePart.Anchored = true
    wirePart.CanCollide = false
    wirePart.CanQuery = false
    wirePart.CastShadow = false
    wirePart.Shape = Enum.PartType.Cylinder
    wirePart.Size = Vector3.new(1, WIRE_THICKNESS, WIRE_THICKNESS)
    wirePart.Parent = visualFolder

    local data = {
        type = "wire",
        part = wirePart,
        deviceA = deviceA,
        deviceB = deviceB,
        key = key,
    }

    connectionVisuals[key] = data
    return data
end

function Visualization.updateWireVisual(key, data, posA, posB, power)
    local dist = (posB - posA).Magnitude
    if dist < 0.01 then return end

    local part = data.part
    part.Size = Vector3.new(dist, WIRE_THICKNESS, WIRE_THICKNESS)

    -- Orient cylinder between the two points
    local direction = (posB - posA).Unit
    local up = Vector3.new(0, 1, 0)
    if math.abs(direction:Dot(up)) > 0.99 then
        up = Vector3.new(1, 0, 0)
    end
    local right = direction:Cross(up).Unit
    up = right:Cross(direction).Unit

    local mid = (posA + posB) / 2
    part.CFrame = CFrame.new(
        mid.X, mid.Y, mid.Z,
        right.X, up.X, -direction.X,
        right.Y, up.Y, -direction.Y,
        right.Z, up.Z, -direction.Z
    ) * CFrame.Angles(0, math.rad(90), 0)

    -- Color based on power ratio
    local ratio = math.max(0, math.min(1, power))
    part.Color = getWireColor(ratio)
    part.Material = ratio > 0.05 and Enum.Material.Neon or Enum.Material.SmoothPlastic

    local light = part:FindFirstChildWhichIsA("PointLight")
    if ratio > 0.1 then
        if not light then
            light = Instance.new("PointLight")
            light.Name = "WireGlow"
            light.Range = 4
            light.Parent = part
        end
        light.Brightness = getNeonBrightness(ratio) * 0.3
        light.Color = part.Color
    elseif light then
        light.Enabled = false
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SHAFT VISUALS
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.createShaftVisual(deviceA, deviceB)
    local key = edgeKey(deviceA, deviceB)
    if connectionVisuals[key] then return connectionVisuals[key] end

    local shaftPart = Instance.new("Part")
    shaftPart.Name = "Shaft_" .. deviceA .. "_" .. deviceB
    shaftPart.Material = Enum.Material.WoodPlanks
    shaftPart.Color = SHAFT_COLOR
    shaftPart.Anchored = true
    shaftPart.CanCollide = false
    shaftPart.CanQuery = false
    shaftPart.CastShadow = false
    shaftPart.Shape = Enum.PartType.Cylinder
    shaftPart.Size = Vector3.new(1, SHAFT_THICKNESS, SHAFT_THICKNESS)
    shaftPart.Parent = visualFolder

    -- Gear accent at each end
    local gearA = Instance.new("Part")
    gearA.Name = "ShaftGear_A"
    gearA.Shape = Enum.PartType.Cylinder
    gearA.Size = Vector3.new(0.3, SHAFT_THICKNESS * 1.6, SHAFT_THICKNESS * 1.6)
    gearA.Color = Color3.fromRGB(100, 85, 60)
    gearA.Material = Enum.Material.WoodPlanks
    gearA.Anchored = true
    gearA.CanCollide = false
    gearA.CanQuery = false
    gearA.CastShadow = false
    gearA.Parent = visualFolder

    local gearB = gearA:Clone()
    gearB.Name = "ShaftGear_B"
    gearB.Parent = visualFolder

    local data = {
        type = "shaft",
        part = shaftPart,
        gearA = gearA,
        gearB = gearB,
        deviceA = deviceA,
        deviceB = deviceB,
        key = key,
        rotation = 0,
    }

    connectionVisuals[key] = data
    return data
end

function Visualization.updateShaftVisual(key, data, posA, posB, power)
    local dist = (posB - posA).Magnitude
    if dist < 0.01 then return end

    local part = data.part
    part.Size = Vector3.new(dist, SHAFT_THICKNESS, SHAFT_THICKNESS)

    local direction = (posB - posA).Unit
    local up = Vector3.new(0, 1, 0)
    if math.abs(direction:Dot(up)) > 0.99 then
        up = Vector3.new(1, 0, 0)
    end
    local right = direction:Cross(up).Unit
    up = right:Cross(direction).Unit

    local baseCF = CFrame.new(
        (posA + posB) / 2,
        (posA + posB) / 2 + direction
    ) * CFrame.Angles(0, math.rad(90), 0)

    -- Rotate the shaft when powered
    local spinSpeed = power * 3.0 -- radians per second equivalent
    data.rotation = data.rotation + spinSpeed * 0.1
    part.CFrame = baseCF * CFrame.Angles(data.rotation, 0, 0)

    -- Color shift when active
    local ratio = math.max(0, math.min(1, power))
    part.Color = ratio > 0.1 and SHAFT_COLOR_ACTIVE or SHAFT_COLOR

    -- Position gears at endpoints
    data.gearA.CFrame = CFrame.new(posA) * CFrame.Angles(0, math.rad(90), 0)
        * CFrame.Angles(data.rotation, 0, 0)
    data.gearB.CFrame = CFrame.new(posB) * CFrame.Angles(0, math.rad(90), 0)
        * CFrame.Angles(data.rotation, 0, 0)
    data.gearA.Color = part.Color
    data.gearB.Color = part.Color
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BELT VISUALS
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.createBeltVisual(deviceA, deviceB)
    local key = edgeKey(deviceA, deviceB)
    if connectionVisuals[key] then return connectionVisuals[key] end

    -- Belt is two pulleys connected by a flat band
    local pulleyA = Instance.new("Part")
    pulleyA.Name = "Pulley_A_" .. deviceA
    pulleyA.Shape = Enum.PartType.Cylinder
    pulleyA.Size = Vector3.new(0.3, BELT_THICKNESS * 2, BELT_THICKNESS * 2)
    pulleyA.Color = Color3.fromRGB(80, 60, 40)
    pulleyA.Material = Enum.Material.Wood
    pulleyA.Anchored = true
    pulleyA.CanCollide = false
    pulleyA.CanQuery = false
    pulleyA.CastShadow = false
    pulleyA.Parent = visualFolder

    local pulleyB = pulleyA:Clone()
    pulleyB.Name = "Pulley_B_" .. deviceB
    pulleyB.Parent = visualFolder

    -- Belt band (thin box)
    local beltPart = Instance.new("Part")
    beltPart.Name = "Belt_" .. deviceA .. "_" .. deviceB
    beltPart.Material = Enum.Material.Leather
    beltPart.Color = BELT_COLOR
    beltPart.Anchored = true
    beltPart.CanCollide = false
    beltPart.CanQuery = false
    beltPart.CastShadow = false
    beltPart.Size = Vector3.new(1, BELT_THICKNESS, 0.05)
    beltPart.Parent = visualFolder

    local data = {
        type = "belt",
        part = beltPart,
        pulleyA = pulleyA,
        pulleyB = pulleyB,
        deviceA = deviceA,
        deviceB = deviceB,
        key = key,
        rotation = 0,
    }

    connectionVisuals[key] = data
    return data
end

function Visualization.updateBeltVisual(key, data, posA, posB, power)
    local dist = (posB - posA).Magnitude
    if dist < 0.01 then return end

    local direction = (posB - posA).Unit
    local up = Vector3.new(0, 1, 0)
    if math.abs(direction:Dot(up)) > 0.99 then
        up = Vector3.new(1, 0, 0)
    end
    local right = direction:Cross(up).Unit
    up = right:Cross(direction).Unit

    -- Belt band
    local mid = (posA + posB) / 2
    data.part.Size = Vector3.new(dist, BELT_THICKNESS * 2, 0.06)
    data.part.CFrame = CFrame.new(
        mid.X, mid.Y, mid.Z,
        right.X, up.X, direction.X,
        right.Y, up.Y, direction.Y,
        right.Z, up.Z, direction.Z
    )

    local ratio = math.max(0, math.min(1, power))
    data.part.Color = ratio > 0.1 and BELT_COLOR_ACTIVE or BELT_COLOR

    -- Pulleys
    data.rotation = data.rotation + ratio * 0.3
    data.pulleyA.CFrame = CFrame.new(posA, posA + direction)
        * CFrame.Angles(0, math.rad(90), 0)
        * CFrame.Angles(data.rotation, 0, 0)
    data.pulleyB.CFrame = CFrame.new(posB, posB + direction)
        * CFrame.Angles(0, math.rad(90), 0)
        * CFrame.Angles(data.rotation, 0, 0)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPARK EFFECT (when connections fail / devices blackout)
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.createSparkEffect(position)
    if typeof(position) ~= "Vector3" then return end

    -- Spark emitter
    local sparkPart = Instance.new("Part")
    sparkPart.Name = "Spark"
    sparkPart.Size = Vector3.new(0.1, 0.1, 0.1)
    sparkPart.Transparency = 1
    sparkPart.Anchored = true
    sparkPart.CanCollide = false
    sparkPart.CanQuery = false
    sparkPart.CFrame = CFrame.new(position)
    sparkPart.Parent = visualFolder

    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = "Sparks"
    emitter.Texture = "rbxassetid://243660364" -- generic spark texture
    emitter.Color = ColorSequence.new(SPARK_COLOR)
    emitter.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.2),
        NumberSequenceKeypoint.new(1, 0),
    })
    emitter.Lifetime = NumberRange.new(0.2, 0.5)
    emitter.Rate = 0
    emitter.Rotation = NumberRange.new(0, 360)
    emitter.Speed = NumberRange.new(5, 15)
    emitter.SpreadAngle = Vector2.new(180, 180)
    emitter.Parent = sparkPart

    -- Burst
    emitter:Emit(15)

    -- Small flash light
    local flash = Instance.new("PointLight")
    flash.Color = SPARK_COLOR
    flash.Brightness = 5
    flash.Range = 8
    flash.Parent = sparkPart

    -- Fade and cleanup
    TweenService:Create(flash, TweenInfo.new(0.3), { Brightness = 0 }):Play()
    Debris:AddItem(sparkPart, 1.0)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- POWER GRID OVERLAY (toggleable view of all connections)
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.setOverlayEnabled(enabled)
    overlayEnabled = enabled

    if not enabled then
        -- Remove all overlay parts
        for _, part in ipairs(overlayParts) do
            if part and part.Parent then
                part:Destroy()
            end
        end
        overlayParts = {}
        return
    end

    -- Rebuild overlay (will be updated on next tick)
    Visualization.refreshOverlay()
end

function Visualization.isOverlayEnabled()
    return overlayEnabled
end

function Visualization.refreshOverlay()
    if not overlayEnabled or not powerGrid then return end

    -- Clear old
    for _, part in ipairs(overlayParts) do
        if part and part.Parent then
            part:Destroy()
        end
    end
    overlayParts = {}

    -- Draw network connections
    local connections = powerGrid.getConnections()
    for _, conn in ipairs(connections) do
        local devA = powerGrid.getDevicePower(conn.from)
        local devB = powerGrid.getDevicePower(conn.to)
        if devA and devB then
            local posA = devices_positions(conn.from)
            local posB = devices_positions(conn.to)
            if posA and posB then
                local color = OVERLAY_COLOR_BALANCED
                if conn.type == "wire" then
                    color = OVERLAY_COLOR_BALANCED
                elseif conn.type == "shaft" then
                    color = OVERLAY_COLOR_SUPPLY
                elseif conn.type == "belt" then
                    color = OVERLAY_COLOR_DEMAND
                end

                local dist = (posB - posA).Magnitude
                local overlay = Instance.new("Part")
                overlay.Name = "Overlay_" .. conn.from .. "_" .. conn.to
                overlay.Material = Enum.Material.ForceField
                overlay.Color = color
                overlay.Transparency = OVERLAY_TRANSPARENCY
                overlay.Anchored = true
                overlay.CanCollide = false
                overlay.CanQuery = false
                overlay.CastShadow = false
                overlay.Shape = Enum.PartType.Cylinder
                overlay.Size = Vector3.new(dist, 0.3, 0.3)

                local mid = (posA + posB) / 2
                local direction = (posB - posA).Unit
                overlay.CFrame = CFrame.new(mid, mid + direction)
                    * CFrame.Angles(0, math.rad(90), 0)
                overlay.Parent = visualFolder

                table.insert(overlayParts, overlay)
            end
        end
    end

    -- Draw device markers
    local allDevices = powerGrid.getDevices()
    for _, devInfo in ipairs(allDevices) do
        local marker = Instance.new("Part")
        marker.Name = "OverlayMarker_" .. devInfo.id
        marker.Shape = Enum.PartType.Ball
        marker.Size = Vector3.new(1, 1, 1)
        marker.Anchored = true
        marker.CanCollide = false
        marker.CanQuery = false
        marker.CastShadow = false
        marker.Material = Enum.Material.Neon
        marker.Position = devInfo.position

        if devInfo.kind == "source" then
            marker.Color = OVERLAY_COLOR_SUPPLY
        elseif devInfo.kind == "consumer" then
            marker.Color = OVERLAY_COLOR_DEMAND
        else
            marker.Color = OVERLAY_COLOR_BALANCED
        end

        marker.Transparency = OVERLAY_TRANSPARENCY
        marker.Parent = visualFolder
        table.insert(overlayParts, marker)
    end
end

-- Helper: get device position from PowerGrid devices table
-- (We need to go through powerGrid since devices table is local to init.lua)
function devices_positions(deviceId)
    -- Use getDevicePower which returns position? No, it doesn't.
    -- We'll use getDevices with a filter.
    -- Actually, we stored position on the device data, so we can use a
    -- workaround: the PowerGrid module stores position in the devices table,
    -- but that's local. However, Visualization.tick receives devices table.
    -- For the overlay path, we need to get it differently.
    -- We'll cache positions from tick updates.
    return deviceVisuals[deviceId] and deviceVisuals[deviceId].position
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DEVICE VISUAL UPDATES (dim/slow on brownout/blackout)
-- ═══════════════════════════════════════════════════════════════════════════

local function updateDeviceVisual(deviceId, dev)
    if not dev.instance then return end

    local ratio = dev.ratio or 1
    local inst = dev.instance

    -- Cache base values on first encounter
    local cached = deviceVisuals[deviceId]
    if not cached then
        cached = {}
        deviceVisuals[deviceId] = cached

        -- Cache light brightness
        local light = inst:FindFirstChildWhichIsA("PointLight")
        if light then
            cached.baseLightBrightness = light.Brightness
            cached.lightRef = light
        end

        -- Cache hinge constraint speed
        for _, child in ipairs(inst:GetDescendants()) do
            if child:IsA("HingeConstraint") then
                cached.baseHingeSpeed = child.AngularVelocity
                cached.hingeRef = child
                break
            end
        end

        -- Cache original material/color
        cached.baseColor = inst.Color
        cached.baseMaterial = inst.Material
    end

    cached.position = dev.position

    -- Apply power ratio to light
    if cached.lightRef then
        cached.lightRef.Brightness = (cached.baseLightBrightness or 1) * ratio
        cached.lightRef.Enabled = ratio > 0.05
    end

    -- Apply power ratio to motor
    if cached.hingeRef then
        cached.hingeRef.AngularVelocity = (cached.baseHingeSpeed or 0) * ratio
    end

    -- Visual state indicator via color tint
    if dev.kind == "consumer" or dev.kind == "hybrid" then
        if dev.state == "blackout" then
            inst.Color = Color3.fromRGB(60, 30, 30)
        elseif dev.state == "brownout" then
            local bc = cached.baseColor or Color3.fromRGB(150, 150, 150)
            inst.Color = Color3.new(
                bc.r * (0.6 + 0.2 * ratio),
                bc.g * (0.6 + 0.2 * ratio),
                bc.b * (0.4 + 0.2 * ratio)
            )
        else
            inst.Color = cached.baseColor or inst.Color
        end
    end

    -- Trigger spark on transition to blackout
    if dev.state == "blackout" and cached.lastState ~= "blackout" then
        Visualization.createSparkEffect(dev.position)
    end
    cached.lastState = dev.state
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.init(pgRef)
    powerGrid = pgRef

    -- Create visual container folder
    visualFolder = Workspace:FindFirstChild("PowerGridVisuals")
    if not visualFolder then
        visualFolder = Instance.new("Folder")
        visualFolder.Name = "PowerGridVisuals"
        visualFolder.Parent = Workspace
    end

    print("[PowerGrid:Visualization] Initialized")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TICK — called by PowerGrid every update interval
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.tick(devices, networks, adjacency)
    -- Update device visuals
    for deviceId, dev in pairs(devices) do
        updateDeviceVisual(deviceId, dev)
    end

    -- Update connection visuals
    for key, data in pairs(connectionVisuals) do
        local devA = devices[data.deviceA]
        local devB = devices[data.deviceB]
        if devA and devB then
            -- Determine power flowing through this edge
            -- Use the lower ratio of the two endpoints (bottleneck)
            local ratioA = devA.ratio or 0
            local ratioB = devB.ratio or 0
            local power = math.min(ratioA, ratioB)

            -- Only show power if they're in the same network
            if devA.networkId == devB.networkId and devA.networkId then
                local net = networks[devA.networkId]
                if net then
                    power = net.ratio or power
                end
            else
                power = 0 -- disconnected networks
            end

            if data.type == "wire" then
                Visualization.updateWireVisual(key, data, devA.position, devB.position, power)
            elseif data.type == "shaft" then
                Visualization.updateShaftVisual(key, data, devA.position, devB.position, power)
            elseif data.type == "belt" then
                Visualization.updateBeltVisual(key, data, devA.position, devB.position, power)
            end
        else
            -- One or both devices removed — clean up visual
            if data.part then data.part:Destroy() end
            if data.gearA then data.gearA:Destroy() end
            if data.gearB then data.gearB:Destroy() end
            if data.pulleyA then data.pulleyA:Destroy() end
            if data.pulleyB then data.pulleyB:Destroy() end
            connectionVisuals[key] = nil
        end
    end

    -- Update overlay if enabled
    if overlayEnabled then
        -- Refresh overlay every 2 seconds (not every tick — too expensive)
        Visualization._overlayTimer = (Visualization._overlayTimer or 0) + 0.5
        if Visualization._overlayTimer >= 2.0 then
            Visualization._overlayTimer = 0
            Visualization.refreshOverlay()
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONNECTION CALLBACKS (called by PowerGrid on connect/disconnect)
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.onConnect(deviceA, deviceB, edgeType, loss)
    local key = edgeKey(deviceA, deviceB)

    -- Create the appropriate visual
    if edgeType == "wire" then
        Visualization.createWireVisual(deviceA, deviceB)
    elseif edgeType == "shaft" then
        Visualization.createShaftVisual(deviceA, deviceB)
    elseif edgeType == "belt" then
        Visualization.createBeltVisual(deviceA, deviceB)
    end

    -- Brief glow burst to indicate new connection
    local data = connectionVisuals[key]
    if data and data.part then
        local flash = Instance.new("PointLight")
        flash.Color = Color3.fromRGB(150, 200, 255)
        flash.Brightness = 3
        flash.Range = 6
        flash.Parent = data.part
        TweenService:Create(flash, TweenInfo.new(0.5), { Brightness = 0 }):Play()
        Debris:AddItem(flash, 0.6)
    end
end

function Visualization.onDisconnect(deviceA, deviceB)
    local key = edgeKey(deviceA, deviceB)
    local data = connectionVisuals[key]
    if not data then return end

    -- Spark effect on disconnect
    if data.part then
        Visualization.createSparkEffect(data.part.Position)
    end

    -- Remove visual
    if data.part then data.part:Destroy() end
    if data.gearA then data.gearA:Destroy() end
    if data.gearB then data.gearB:Destroy() end
    if data.pulleyA then data.pulleyA:Destroy() end
    if data.pulleyB then data.pulleyB:Destroy() end
    connectionVisuals[key] = nil
end

function Visualization.onRemoveDevice(deviceId)
    -- Clean up device visual cache
    deviceVisuals[deviceId] = nil

    -- Clean up any connection visuals referencing this device
    for key, data in pairs(connectionVisuals) do
        if data.deviceA == deviceId or data.deviceB == deviceId then
            if data.part then data.part:Destroy() end
            if data.gearA then data.gearA:Destroy() end
            if data.gearB then data.gearB:Destroy() end
            if data.pulleyA then data.pulleyA:Destroy() end
            if data.pulleyB then data.pulleyB:Destroy() end
            connectionVisuals[key] = nil
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CLEANUP
-- ═══════════════════════════════════════════════════════════════════════════

function Visualization.cleanup()
    for key, data in pairs(connectionVisuals) do
        if data.part then data.part:Destroy() end
        if data.gearA then data.gearA:Destroy() end
        if data.gearB then data.gearB:Destroy() end
        if data.pulleyA then data.pulleyA:Destroy() end
        if data.pulleyB then data.pulleyB:Destroy() end
    end
    connectionVisuals = {}
    deviceVisuals = {}

    for _, part in ipairs(overlayParts) do
        if part and part.Parent then
            part:Destroy()
        end
    end
    overlayParts = {}
end

print("[PowerGrid:Visualization] Module loaded")

return Visualization
