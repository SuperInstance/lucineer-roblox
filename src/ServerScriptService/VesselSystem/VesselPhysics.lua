--[[
    VesselSystem/VesselPhysics.lua
    Slackwater — Real Boat Physics Engine

    "The sea doesn't care about your code. It pushes, it pulls, it takes.
     A boat that doesn't respect the water is a boat that ends up underwater.
     This module makes the water matter."

    ───────────────────────────────────────────────
    PHYSICS MODEL:

    1. BUOYANCY (multi-point)
       Each vessel has 5-16 buoyancy probe points distributed along the hull.
       Each probe calculates submersion depth below the water surface and
       applies an upward force proportional to displaced volume. This gives
       realistic pitch and roll because bow probes hit waves before stern probes.

    2. WAVE RESPONSE
       Wave height at each probe point is sampled from WeatherSystem's wave
       field. During storms, probes at different hull positions experience
       different wave heights, causing the boat to pitch and roll naturally.

    3. MOMENTUM
       Boats have mass (from VesselTypes). Drag coefficients control how
       quickly they slow when throttle is cut. A longliner coasts for a
       long time. A skiff stops fast.

    4. WIND ON SUPERSTRUCTURE
       Wind from WeatherSystem pushes against the vessel's windArea. When
       the boat isn't moving, this causes drift. Storms push hard.

    5. SHALLOW WATER RESISTANCE
       When the water depth below the keel is less than 1.5x draft, drag
       increases exponentially. This naturally slows boats near shore.

    6. GROUNDING
       When the keel touches the bottom, the boat stops hard and takes
       damage proportional to impact speed.

    7. CAPSIZE
       If the boat's roll angle exceeds capsizeThreshold (from waves + wind),
       it flips. Small boats capsize easier. Large boats are stable.

    This module uses REAL Roblox physics — BodyVelocity, BodyGyro, and
    ApplyImpulse. No CFrame manipulation for movement. The physics engine
    handles collision, momentum, and force integration.

    INTEGRATION:
        WeatherSystem  → wave intensity, wind direction/speed
        TideSystem     → water level (affects buoyancy calculation depth)
        VesselTypes    → physical parameters per vessel
        VesselDamage   → grounding damage application

    API:
        VesselPhysics.init(vesselModel, vesselConfig, ownerId)
        VesselPhysics.update(dt)         — called every Heartbeat
        VesselPhysics.setThrottle(value) — -1.0 to 1.0
        VesselPhysics.setRudder(value)   — -1.0 to 1.0
        VesselPhysics.getSpeed()         — current speed in studs/sec
        VesselPhysics.isGrounded()       — keel touching bottom
        VesselPhysics.isCapsized()       — boat has flipped
        VesselPhysics.applyImpact(damage, position)
        VesselPhysics.destroy()
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local VesselPhysics = {}

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

local GRAVITY = Workspace.Gravity  -- typically 196.2 studs/s²

-- Buoyancy tuning
local BUOYANCY_FORCE_MULT = 2.5     -- how strongly water pushes back
local BUOYANCY_DAMPING = 0.8        -- vertical oscillation damping
local MAX_BUOYANCY_DEPTH = 6        -- beyond this, probe is fully submerged

-- Wave sampling
local WAVE_LENGTH = 40              -- studs between wave crests
local WAVE_BASE_AMP = 0.5           -- calm water ripple amplitude
local WAVE_STORM_MULT = 8.0         -- storm multiplier on amplitude

-- Shallow water
local SHALLOW_THRESHOLD_MULT = 1.5  -- depth < draft * this = shallow effect
local SHALLOW_DRAG_EXP = 2.5        -- exponential drag increase in shallow water

-- Grounding
local GROUNDING_SPEED_THRESHOLD = 8 -- below this speed, grounding is gentle
local GROUNDING_DAMAGE_MULT = 5.0   -- damage per stud/sec over threshold

-- Capsize
local CAPSIZE_RECOVERY_TIME = 8.0   -- seconds before auto-recovery attempt (if upright enough)

-- Wind
local WIND_FORCE_MULT = 0.4         -- how much wind affects the boat

----------------------------------------------------------------
-- STATE (per active vessel)
----------------------------------------------------------------

-- Each active vessel gets a state table. Keyed by the vessel's PrimaryPart.
local activeVessels = {}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

--[[
    Get the current water level from TideSystem.
    Falls back to 0 if TideSystem isn't available.
    @return number
]]
local function getWaterLevel()
    local tideSystem = Workspace:FindFirstChild("__TideSystem")
    if tideSystem and tideSystem:GetAttribute("WaterLevel") then
        return tideSystem:GetAttribute("WaterLevel")
    end
    -- Try the TideSystem module directly
    local ok, TideSystem = pcall(function()
        return require(game:GetService("ServerScriptService").WorldGenerator.TideSystem)
    end)
    if ok and TideSystem.GetWaterLevel then
        return TideSystem.GetWaterLevel()
    end
    return 0
end

--[[
    Get wave height at a given world position.
    Combines a sine-wave field with WeatherSystem intensity.
    @param position Vector3
    @param waveIntensity number (0-1 from WeatherSystem)
    @param windDirection Vector3
    @param windSpeed number
    @return number wave height offset at this position
]]
local function getWaveHeight(position, waveIntensity, windDirection, windSpeed)
    -- Base wave field: two overlapping sine waves at different angles
    local amp = WAVE_BASE_AMP + waveIntensity * WAVE_STORM_MULT

    -- Primary wave: aligned with wind direction
    local dir1X, dir1Z = windDirection.X, windDirection.Z
    local phase1 = (position.X * dir1X + position.Z * dir1Z) / WAVE_LENGTH
    local wave1 = math.sin(phase1 * math.pi * 2 + tick() * 0.8)

    -- Secondary wave: cross-angle, shorter wavelength
    local crossX, crossZ = -windDirection.Z, windDirection.X
    local phase2 = (position.X * crossX + position.Z * crossZ) / (WAVE_LENGTH * 0.6)
    local wave2 = math.sin(phase2 * math.pi * 2 + tick() * 1.3) * 0.6

    -- Tertiary chop: small high-frequency (prominent in storms)
    local phase3 = (position.X + position.Z) / (WAVE_LENGTH * 0.25)
    local wave3 = math.sin(phase3 * math.pi * 2 + tick() * 2.5) * 0.3 * waveIntensity

    return (wave1 + wave2 + wave3) * amp
end

--[[
    Get the weather system safely.
    @return table|nil
]]
local function getWeatherSystem()
    local ok, ws = pcall(function()
        return require(game.ServerScriptService.WeatherSystem)
    end)
    if ok then return ws end
    return nil
end

--[[
    Sample terrain/bottom depth at a world position.
    Uses raycasting downward from above the water to find the sea floor.
    @param position Vector3 (XZ position to sample)
    @param waterLevel number
    @return number depth below water surface, or math.huge if no bottom found
]]
local function getBottomDepth(position, waterLevel)
    -- Raycast parameters: ignore the vessel itself
    local rayOrigin = Vector3.new(position.X, waterLevel + 5, position.Z)
    local rayDirection = Vector3.new(0, -50, 0)  -- 50 studs down

    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude

    -- We'll let the caller set filter; default: just terrain
    local result = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
    if result then
        return waterLevel - result.Position.Y
    end

    -- No bottom found within range → deep water
    return math.huge
end

--[[
    Create a buoyancy probe attachment on the vessel.
    @param vesselState table
    @param offset Vector3 local offset
    @return table probe data
]]
local function createBuoyancyProbe(vesselState, offset)
    local primaryPart = vesselState.primaryPart
    local attachment = Instance.new("Attachment")
    attachment.Name = "BuoyancyProbe"
    attachment.Position = offset
    attachment.Parent = primaryPart

    -- VectorForce for buoyancy (points up)
    local vectorForce = Instance.new("VectorForce")
    vectorForce.Name = "BuoyancyForce"
    vectorForce.Attachment0 = attachment
    vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
    vectorForce.Force = Vector3.zero
    vectorForce.Parent = primaryPart

    return {
        attachment = attachment,
        vectorForce = vectorForce,
        offset = offset,
        submergedDepth = 0,
    }
end

----------------------------------------------------------------
-- VESSEL STATE MANAGEMENT
----------------------------------------------------------------

--[[
    Initialize physics for a vessel model.
    Creates buoyancy probes, drag forces, and registers the vessel for updates.
    @param vesselModel Model — the vessel (must have a PrimaryPart)
    @param vesselConfig table — from VesselTypes
    @param ownerId string — player who owns this vessel
    @return table vesselState
]]
function VesselPhysics.init(vesselModel, vesselConfig, ownerId)
    if not vesselModel or not vesselModel.PrimaryPart then
        error("[VesselPhysics] Vessel model must have a PrimaryPart")
    end

    local primaryPart = vesselModel.PrimaryPart

    -- Ensure the hull is physical
    for _, part in ipairs(vesselModel:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = true
            -- Don't anchor — we want physics
            part.Anchored = false
        end
    end
    primaryPart.Anchored = false

    -- Set mass
    local assemblyMass = vesselConfig.mass
    -- We can't directly set AssemblyMass, but we can set CustomPhysicalProperties
    -- density on parts to achieve the target mass. For simplicity, we use a
    -- BodyVelocity approach and let natural mass work, adjusting force mults.
    primaryPart:SetCustomPropertiesDeferred and primaryPart:SetAttribute("TargetMass", assemblyMass)

    -- Create vessel state
    local state = {
        model = vesselModel,
        primaryPart = primaryPart,
        config = vesselConfig,
        ownerId = ownerId,

        -- Control inputs
        throttle = 0,        -- -1.0 (full reverse) to 1.0 (full forward)
        rudder = 0,          -- -1.0 (hard left) to 1.0 (hard right)
        anchorSet = false,

        -- Physical state
        speed = 0,           -- current forward speed (studs/sec)
        heading = 0,         -- current heading in degrees
        velocity = Vector3.zero,
        angularVelocity = Vector3.zero,

        -- Buoyancy probes
        probes = {},

        -- Forces (created below)
        propulsionForce = nil,    -- BodyVelocity for thrust
        steeringGyro = nil,       -- BodyGyro for turning
        dragForce = nil,          -- VectorForce for drag
        windForce = nil,          -- VectorForce for wind

        -- Status flags
        grounded = false,
        capsized = false,
        capsizeTimer = 0,
        shallowFactor = 1.0,

        -- Ground impact tracking
        lastGroundDamageTime = 0,

        -- Heartbeat connection (per-vessel for clean teardown)
        connection = nil,

        -- Water level cache (updated each frame)
        waterLevel = 0,

        -- Performance: bottom depth cache (don't raycast every frame)
        bottomDepthCache = math.huge,
        bottomDepthCacheTime = 0,
    }

    -- Create buoyancy probes
    for _, offset in ipairs(vesselConfig.buoyancyPoints) do
        local probe = createBuoyancyProbe(state, offset)
        table.insert(state.probes, probe)
    end

    -- Create propulsion force (BodyVelocity — drives the boat forward)
    -- We use BodyVelocity for forward thrust because it gives smooth,
    -- momentum-respecting movement that fights drag naturally.
    local propAttachment = Instance.new("Attachment")
    propAttachment.Name = "PropulsionPoint"
    propAttachment.Position = Vector3.new(0, 0, -vesselConfig.proportions.length * 0.4)
    propAttachment.Parent = primaryPart

    local propulsion = Instance.new("BodyVelocity")
    propulsion.Name = "PropulsionVelocity"
    -- BodyVelocity applies to its parent part; it has no Attachment0 property
    propulsion.MaxForce = Vector3.new(
        assemblyMass * GRAVITY * 0.5,  -- X: moderate
        0,                               -- Y: no vertical from propulsion
        assemblyMass * GRAVITY * 0.5   -- Z: main thrust axis
    )
    propulsion.Velocity = Vector3.zero
    propulsion.Parent = primaryPart

    state.propulsionForce = propulsion
    state.propAttachment = propAttachment

    -- Create steering gyro (BodyGyro — controls heading)
    local helmAttachment = Instance.new("Attachment")
    helmAttachment.Name = "HelmPoint"
    helmAttachment.Position = Vector3.new(0, vesselConfig.proportions.height * 0.5, 0)
    helmAttachment.Parent = primaryPart

    local steering = Instance.new("BodyGyro")
    steering.Name = "SteeringGyro"
    -- BodyGyro applies to its parent part; it has no Attachment0 property
    steering.MaxTorque = Vector3.new(
        assemblyMass * 20,   -- X: roll resistance
        assemblyMass * 80,   -- Y: yaw (primary steering)
        assemblyMass * 20    -- Z: pitch resistance
    )
    steering.P = 2500
    steering.D = 200
    steering.CFrame = primaryPart.CFrame
    steering.Parent = primaryPart

    state.steeringGyro = steering
    state.helmAttachment = helmAttachment

    -- Create wind force (VectorForce — wind on superstructure)
    local windAttachment = Instance.new("Attachment")
    windAttachment.Name = "WindPoint"
    windAttachment.Position = Vector3.new(0, vesselConfig.proportions.height * 0.7, 0)
    windAttachment.Parent = primaryPart

    local windVec = Instance.new("VectorForce")
    windVec.Name = "WindForce"
    windVec.Attachment0 = windAttachment
    windVec.RelativeTo = Enum.ActuatorRelativeTo.World
    windVec.Force = Vector3.zero
    windVec.Parent = primaryPart

    state.windForce = windVec
    state.windAttachment = windAttachment

    -- Create drag force (VectorForce — water resistance on the hull)
    local dragAttachment = Instance.new("Attachment")
    dragAttachment.Name = "DragPoint"
    dragAttachment.Position = Vector3.zero
    dragAttachment.Parent = primaryPart

    local dragVec = Instance.new("VectorForce")
    dragVec.Name = "DragForce"
    dragVec.Attachment0 = dragAttachment
    dragVec.RelativeTo = Enum.ActuatorRelativeTo.World
    dragVec.Force = Vector3.zero
    dragVec.Parent = primaryPart

    state.dragForce = dragVec
    state.dragAttachment = dragAttachment

    -- Store heading from initial CFrame
    local lookDir = primaryPart.CFrame.LookVector
    state.heading = math.deg(math.atan2(-lookDir.X, lookDir.Z))

    -- Register vessel
    activeVessels[primaryPart] = state

    -- Connect heartbeat for this vessel
    state.connection = RunService.Heartbeat:Connect(function(dt)
        VesselPhysics._updateVessel(state, dt)
    end)

    print(string.format("[VesselPhysics] Initialized %s for %s (%d buoyancy probes)",
        vesselConfig.displayName, ownerId or "?", #state.probes))

    return state
end

----------------------------------------------------------------
-- CORE UPDATE
----------------------------------------------------------------

--[[
    Internal: per-vessel physics update. Called every Heartbeat.
    @param state table vessel state
    @param dt number delta time
]]
function VesselPhysics._updateVessel(state, dt)
    local primaryPart = state.primaryPart
    if not primaryPart or not primaryPart.Parent then
        -- Vessel destroyed
        VesselPhysics.destroy(state)
        return
    end

    local config = state.config

    -- ──────────────────────────────────────────────────────────────
    -- 1. GET ENVIRONMENT DATA
    -- ──────────────────────────────────────────────────────────────

    state.waterLevel = getWaterLevel()

    local weather = getWeatherSystem()
    local waveIntensity = 0.1  -- default calm
    local windDir = Vector3.new(1, 0, 0)
    local windSpeed = 5

    if weather then
        waveIntensity = weather.getWeatherIntensity() or 0.1
        windDir = weather.getWindDirection() or Vector3.new(1, 0, 0)
        windSpeed = weather.getWindSpeed() or 5
    end

    -- Storm boost to waves
    if weather and weather.isStormActive and weather.isStormActive() then
        waveIntensity = math.max(waveIntensity, 0.9)
    end

    -- ──────────────────────────────────────────────────────────────
    -- 2. BUOYANCY (multi-point)
    -- ──────────────────────────────────────────────────────────────

    local vesselPos = primaryPart.Position
    local vesselCF = primaryPart.CFrame

    for _, probe in ipairs(state.probes) do
        -- World position of this probe
        local worldPos = vesselCF:PointToWorldSpace(probe.offset)

        -- Wave height at this probe's XZ position
        local waveH = getWaveHeight(worldPos, waveIntensity, windDir, windSpeed)
        local effectiveWaterSurface = state.waterLevel + waveH

        -- How deep is this probe below the effective water surface?
        local depth = effectiveWaterSurface - worldPos.Y

        if depth > 0 then
            -- Probe is submerged: apply buoyancy force
            local submersion = math.clamp(depth / MAX_BUOYANCY_DEPTH, 0, 1)
            local forceMag = submersion * config.mass * GRAVITY * BUOYANCY_FORCE_MULT / #state.probes

            -- Damping: reduce force if probe was already moving up fast
            local velAtPoint = primaryPart.AssemblyLinearVelocity
            local dampingForce = -velAtPoint.Y * BUOYANCY_DAMPING * config.mass / #state.probes

            local totalForce = forceMag + dampingForce
            probe.vectorForce.Force = Vector3.new(0, totalForce, 0)
            probe.submergedDepth = depth
        else
            -- Probe is in air: no buoyancy
            probe.vectorForce.Force = Vector3.zero
            probe.submergedDepth = 0
        end
    end

    -- ──────────────────────────────────────────────────────────────
    -- 3. PROPULSION (throttle → forward velocity)
    -- ──────────────────────────────────────────────────────────────

    if not state.anchorSet and not state.grounded and not state.capsized then
        -- Target velocity based on throttle
        local targetSpeed
        if state.throttle >= 0 then
            targetSpeed = state.throttle * config.topSpeed
        else
            targetSpeed = state.throttle * config.reverseSpeed
        end

        -- Acceleration curve: ease into target speed
        -- The acceleration parameter controls how fast we approach target
        local accelRate = config.acceleration * dt * 2.0
        state.speed = state.speed + (targetSpeed - state.speed) * accelRate

        -- Apply shallow water resistance
        state.shallowFactor = VesselPhysics._computeShallowFactor(state)
        local effectiveSpeed = state.speed * state.shallowFactor

        -- Forward direction (along the hull's Z axis — LookVector for our orientation)
        local forwardDir = primaryPart.CFrame.LookVector
        -- Flatten Y component for surface movement
        forwardDir = Vector3.new(forwardDir.X, 0, forwardDir.Z).Unit

        -- Set propulsion velocity
        local propVel = forwardDir * math.abs(effectiveSpeed)
        if state.speed < 0 then
            propVel = -propVel
        end

        -- BodyVelocity target — we want the boat to move at propVel
        -- But we allow the physics engine to handle momentum via MaxForce limits
        state.propulsionForce.Velocity = propVel

        -- Current actual velocity (from physics engine)
        local actualVel = primaryPart.AssemblyLinearVelocity
        state.velocity = actualVel
        local actualSpeed = Vector3.new(actualVel.X, 0, actualVel.Z).Magnitude
        state.speed = math.clamp(
            state.speed + (actualSpeed - math.abs(state.speed)) * 0.3,
            -config.reverseSpeed, config.topSpeed
        )
    else
        -- No propulsion (anchor, ground, or capsized)
        state.propulsionForce.Velocity = Vector3.zero

        -- Coast: gradual speed reduction
        if state.grounded or state.anchorSet then
            state.speed = state.speed * (1 - dt * 3.0)  -- decelerate fast
        else
            state.speed = state.speed * (1 - dt * 0.3)  -- coast slowly
        end
    end

    -- ──────────────────────────────────────────────────────────────
    -- 4. STEERING (rudder → heading change)
    -- ──────────────────────────────────────────────────────────────

    if not state.capsized then
        -- Turn rate is proportional to speed through water
        -- No speed = no steering (a real boat principle)
        local speedFactor = math.clamp(math.abs(state.speed) / config.topSpeed, 0, 1)
        local effectiveTurnRate = config.turnRate * (
            (1 - config.turnSpeedFactor) +  -- base turn rate (always available)
            config.turnSpeedFactor * speedFactor  -- speed-dependent bonus
        )

        -- Apply rudder
        local turnDelta = state.rudder * effectiveTurnRate * dt

        -- Reverse steering: when going backward, rudder inverts (like a real boat)
        if state.speed < -0.5 then
            turnDelta = -turnDelta
        end

        state.heading = state.heading + turnDelta

        -- Normalize heading to 0-360
        while state.heading < 0 do state.heading = state.heading + 360 end
        while state.heading >= 360 do state.heading = state.heading - 360 end

        -- Apply heading via BodyGyro (with wave-induced roll and pitch)
        -- Sample wave-induced angles at bow and stern for pitch
        local bowPos = vesselCF:PointToWorldSpace(Vector3.new(0, 0, config.proportions.length * 0.4))
        local sternPos = vesselCF:PointToWorldSpace(Vector3.new(0, 0, -config.proportions.length * 0.4))
        local portPos = vesselCF:PointToWorldSpace(Vector3.new(config.proportions.beam * 0.4, 0, 0))
        local starPos = vesselCF:PointToWorldSpace(Vector3.new(-config.proportions.beam * 0.4, 0, 0))

        local bowWave = getWaveHeight(bowPos, waveIntensity, windDir, windSpeed)
        local sternWave = getWaveHeight(sternPos, waveIntensity, windDir, windSpeed)
        local portWave = getWaveHeight(portPos, waveIntensity, windDir, windSpeed)
        local starWave = getWaveHeight(starPos, waveIntensity, windDir, windSpeed)

        -- Pitch: difference between bow and stern wave heights
        local lengthFactor = config.proportions.length * 0.8
        if lengthFactor > 0 then
            local pitchAngle = math.atan2(bowWave - sternWave, lengthFactor)
            -- Clamp pitch to reasonable limits
            pitchAngle = math.clamp(pitchAngle, math.rad(-25), math.rad(25))

            -- Roll: difference between port and starboard wave heights
            local beamFactor = config.proportions.beam * 0.8
            local rollAngle = math.atan2(portWave - starWave, beamFactor)

            -- Add wind-induced lean (boat leans away from wind direction)
            local windLean = 0
            if windSpeed > 5 then
                local rightVec = vesselCF.RightVector
                local windDotRight = windDir.X * rightVec.X + windDir.Z * rightVec.Z
                windLean = -windDotRight * windSpeed * 0.002 * (50 / config.mass)
            end

            rollAngle = rollAngle + windLean
            -- Clamp roll
            rollAngle = math.clamp(rollAngle, math.rad(-40), math.rad(40))

            -- Build target CFrame with heading + wave-induced pitch/roll
            local targetCFrame = CFrame.fromOrientation(0, math.rad(-state.heading), 0)
            targetCFrame = targetCFrame * CFrame.fromOrientation(pitchAngle, 0, rollAngle)

            state.steeringGyro.CFrame = targetCFrame

            -- ──────────────────────────────────────────────────────
            -- 7. CAPSIZE CHECK
            -- ──────────────────────────────────────────────────────

            local rollDeg = math.deg(math.abs(rollAngle))
            if rollDeg > config.capsizeThreshold then
                state.capsized = true
                state.capsizeTimer = 0

                -- Fire capsize event
                local vesselModel = state.model
                vesselModel:SetAttribute("Capsized", true)

                print(string.format("[VesselPhysics] %s CAPSIZED at %.1f° (threshold: %.1f°)",
                    config.displayName, rollDeg, config.capsizeThreshold))
            end
        end

        -- Capsize recovery: if the boat self-rights (roll back under threshold)
        if state.capsized then
            state.capsizeTimer = state.capsizeTimer + dt
            -- Check if roll has naturally recovered
            local currentRoll = math.deg(math.abs(math.atan2(
                vesselCF.RightVector.Y,
                Vector3.new(vesselCF.RightVector.X, 0, vesselCF.RightVector.Z).Magnitude
            )))
            if currentRoll < 15 and state.capsizeTimer > CAPSIZE_RECOVERY_TIME then
                state.capsized = false
                state.capsizeTimer = 0
                state.model:SetAttribute("Capsized", false)
                print(string.format("[VesselPhysics] %s recovered from capsize", config.displayName))
            end
        end
    end

    -- ──────────────────────────────────────────────────────────────
    -- 5. WIND ON SUPERSTRUCTURE
    -- ──────────────────────────────────────────────────────────────

    if not state.anchorSet and not state.grounded then
        -- Wind pushes the boat when not under power or even when moving
        local windForceVec = windDir * windSpeed * config.windArea * WIND_FORCE_MULT
        state.windForce.Force = windForceVec
    else
        state.windForce.Force = Vector3.zero
    end

    -- ──────────────────────────────────────────────────────────────
    -- 6. SHALLOW WATER & GROUNDING
    -- ──────────────────────────────────────────────────────────────

    -- Cache bottom depth (raycast every ~0.5s, not every frame)
    state.bottomDepthCacheTime = state.bottomDepthCacheTime + dt
    if state.bottomDepthCacheTime > 0.5 then
        state.bottomDepthCacheTime = 0
        -- Raycast at the keel position
        local keelPos = vesselCF:PointToWorldSpace(Vector3.new(0, -config.draft, 0))
        local depth = getBottomDepth(keelPos, state.waterLevel)

        -- Account for the actual keel position
        local keelDepth = state.waterLevel - (keelPos.Y - depth + state.waterLevel)
        -- Simplify: depth is how far below water surface the bottom is
        -- keelDepth is how far below water surface the keel is
        state.bottomDepthCache = depth
    end

    local bottomDepth = state.bottomDepthCache
    local keelDepth = config.draft

    -- Check for grounding
    if bottomDepth <= keelDepth + 0.5 then
        -- Keel is at or below the bottom → grounded
        if not state.grounded and math.abs(state.speed) > GROUNDING_SPEED_THRESHOLD then
            -- Hard grounding at speed!
            local impactSpeed = math.abs(state.speed)
            local damage = (impactSpeed - GROUNDING_SPEED_THRESHOLD) * GROUNDING_DAMAGE_MULT * (100 / config.hullHP)

            -- Fire grounding event for VesselDamage
            state.model:SetAttribute("GroundingImpact", impactSpeed)
            state.model:SetAttribute("GroundingDamage", damage)

            print(string.format("[VesselPhysics] GROUNDING! %s hit bottom at %.1f studs/s",
                config.displayName, impactSpeed))

            -- Hard stop
            state.speed = 0
            state.propulsionForce.Velocity = Vector3.zero

            -- Physical jolt
            primaryPart:ApplyImpulse(-primaryPart.AssemblyLinearVelocity * primaryPart.AssemblyMass * 0.8)
        end

        state.grounded = true
        state.model:SetAttribute("Grounded", true)

        -- Prevent forward motion when grounded
        state.propulsionForce.Velocity = Vector3.zero
        state.speed = state.speed * (1 - dt * 5)
    else
        if state.grounded then
            -- Check if we've floated free (water rose or boat backed off)
            if bottomDepth > keelDepth + 1.5 then
                state.grounded = false
                state.model:SetAttribute("Grounded", false)
                print(string.format("[VesselPhysics] %s floated free", config.displayName))
            end
        end
    end
end

--[[
    Compute the shallow water speed reduction factor.
    When depth < draft * SHALLOW_THRESHOLD_MULT, speed is reduced.
    @param state table vessel state
    @return number 0.1 to 1.0
]]
function VesselPhysics._computeShallowFactor(state)
    local depth = state.bottomDepthCache
    if depth == math.huge then return 1.0 end

    local threshold = state.config.draft * SHALLOW_THRESHOLD_MULT
    if depth > threshold then return 1.0 end

    -- Exponential drag increase
    local ratio = depth / threshold  -- 0 to 1
    if ratio < 0.1 then ratio = 0.1 end

    local factor = ratio ^ SHALLOW_DRAG_EXP
    return math.clamp(factor, 0.05, 1.0)
end

----------------------------------------------------------------
-- PUBLIC CONTROL API
----------------------------------------------------------------

--[[
    Set the throttle for a vessel.
    @param state table vessel state
    @param value number -1.0 (full reverse) to 1.0 (full forward)
]]
function VesselPhysics.setThrottle(state, value)
    value = math.clamp(value, -1.0, 1.0)
    state.throttle = value
end

--[[
    Set the rudder angle for a vessel.
    @param state table vessel state
    @param value number -1.0 (hard to port) to 1.0 (hard to starboard)
]]
function VesselPhysics.setRudder(state, value)
    value = math.clamp(value, -1.0, 1.0)
    state.rudder = value
end

--[[
    Set anchor state. When anchored, the boat stops and holds position.
    @param state table vessel state
    @param set boolean — true to set anchor, false to raise
]]
function VesselPhysics.setAnchor(state, set)
    state.anchorSet = set
    if set then
        -- Cancel all propulsion
        state.throttle = 0
        state.propulsionForce.Velocity = Vector3.zero
    end
    state.model:SetAttribute("Anchored", set)
end

--[[
    Get the current speed of the vessel.
    @param state table vessel state
    @return number speed in studs/sec (positive = forward, negative = reverse)
]]
function VesselPhysics.getSpeed(state)
    return state.speed
end

--[[
    Check if the vessel is currently grounded.
    @param state table vessel state
    @return boolean
]]
function VesselPhysics.isGrounded(state)
    return state.grounded
end

--[[
    Check if the vessel has capsized.
    @param state table vessel state
    @return boolean
]]
function VesselPhysics.isCapsized(state)
    return state.capsized
end

--[[
    Get the current shallow water factor (how much speed is reduced).
    @param state table vessel state
    @return number 0.05 to 1.0
]]
function VesselPhysics.getShallowFactor(state)
    return state.shallowFactor
end

--[[
    Get the current heading in degrees (0-360).
    @param state table vessel state
    @return number
]]
function VesselPhysics.getHeading(state)
    return state.heading
end

--[[
    Apply an external impact to the vessel (e.g., collision with rock).
    @param state table vessel state
    @param impulse Vector3
    @param damagePosition Vector3 world position of impact
]]
function VesselPhysics.applyImpact(state, impulse, damagePosition)
    state.primaryPart:ApplyImpulse(impulse)
    state.model:SetAttribute("ImpactPosition", damagePosition)
    state.model:SetAttribute("ImpactTime", tick())
end

--[[
    Destroy physics for a vessel. Cleans up all forces and connections.
    @param state table vessel state
]]
function VesselPhysics.destroy(state)
    if not state then return end

    -- Disconnect heartbeat
    if state.connection then
        state.connection:Disconnect()
        state.connection = nil
    end

    -- Clean up probes
    for _, probe in ipairs(state.probes or {}) do
        if probe.vectorForce then probe.vectorForce:Destroy() end
        if probe.attachment then probe.attachment:Destroy() end
    end

    -- Clean up forces
    if state.propulsionForce then state.propulsionForce:Destroy() end
    if state.steeringGyro then state.steeringGyro:Destroy() end
    if state.windForce then state.windForce:Destroy() end
    if state.propAttachment then state.propAttachment:Destroy() end
    if state.helmAttachment then state.helmAttachment:Destroy() end
    if state.windAttachment then state.windAttachment:Destroy() end

    -- Unregister
    activeVessels[state.primaryPart] = nil
end

return VesselPhysics
