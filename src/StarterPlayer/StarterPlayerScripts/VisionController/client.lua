--[[
    VisionController / client.lua
    Slackwater — First-person & third-person vessel camera

    "The camera is the player's eyes. Every wave, every fog bank,
     every sunrise should be felt in the stomach, not just seen."

    ───────────────────────────────────────────────
    CONTEXT MODES:
      • on_foot    — Standard third-person Roblox camera, slightly raised.
                     Used when walking in the yard.
      • at_helm    — Over-the-shoulder vessel view: bow, water ahead,
                     chart, wheel. Boat roll/pitch translates to camera.
                     Used when steering a vessel.
      • cinematic  — Temporarily overridden by SceneDirector. The
                     VisionController yields camera control entirely.

    WEATHER RESPONSE:
      • Fog     — Far-clip plane pulls in (50 studs heavy, 20 pea-soup).
                  Depth sounder becomes critical; the world shrinks.
      • Storm   — Camera shakes with wave impacts. Rain particles on lens.
                  Spray off the bow when underway.
      • Night   — Dark. Spread lights, nav lights, moonlight, stars.
      • Aurora  — Camera slowly tilts upward. Everything softens.

    INTEGRATION:
      • WeatherSystem (ReplicatedStorage → server attributes) for state
      • Vessel seat detection via CollectionService tag "HelmSeat"
      • SceneDirector for cinematic handoff
      • AudioManager for 3D positional vessel sounds

    This module is a LocalScript running on the client.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local VisionController = {}

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

-- Camera mode enum
local MODE = {
    ON_FOOT  = "on_foot",
    AT_HELM  = "at_helm",
    CINEMATIC = "cinematic",
}

-- On-foot camera offsets (slightly raised third person)
local ON_FOOT_OFFSET = Vector3.new(0, 3.5, 8)

-- Helm camera offsets relative to the helm seat
local HELM_OFFSET = Vector3.new(2.5, 4.5, 8)  -- behind, above, slightly right
local HELM_LOOK_OFFSET = Vector3.new(0, 1.5, -15)  -- where the camera looks toward

-- Camera smoothing factors (higher = snappier)
local HELM_SMOOTH = 0.12
local ON_FOOT_SMOOTH = 0.20

-- Far-clip plane defaults per weather
local FAR_CLIP = {
    clear  = 10000,
    rain   = 4000,
    fog    = 300,    -- heavy fog
    storm  = 500,
    aurora = 8000,
    night  = 5000,
}

-- Pea-soup fog (rare, triggered by extreme fog intensity)
local PEA_SOUP_FAR_CLIP = 20

-- Camera shake parameters per weather
local SHAKE_PARAMS = {
    clear  = { frequency = 0,  amplitude = 0 },
    fog    = { frequency = 0,  amplitude = 0 },
    rain   = { frequency = 0.5, amplitude = 0.08 },
    storm  = { frequency = 2.5, amplitude = 0.35 },
    aurora = { frequency = 0,  amplitude = 0 },
}

-- Night visibility thresholds
local NIGHT_CLOCK_THRESHOLD = 18.5  -- after this, night lighting kicks in
local DAWN_CLOCK_THRESHOLD = 5.5    -- before this, still night

-- Field of view
local DEFAULT_FOV = 70
local HELM_FOV = 68  -- slightly tighter at helm for focus
local STORM_FOV_PUNCH = 75  -- brief FOV widen on wave impact

-- Spray particle configuration (off the bow when underway)
local SPRAY_CONFIG = {
    texture = "rbxassetid://3787172071",
    rate = 0,
    lifetime = 0.6,
    speed = 25,
    spreadAngle = Vector2.new(35, 35),
    size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1.5),
        NumberSequenceKeypoint.new(1, 0.2),
    }),
    transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.4),
        NumberSequenceKeypoint.new(1, 1.0),
    }),
    color = ColorSequence.new(Color3.fromRGB(220, 235, 245)),
    acceleration = Vector3.new(0, -15, 0),
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

VisionController._mode = MODE.ON_FOOT
VisionController._currentWeather = "clear"
VisionController._weatherIntensity = 0
VisionController._isNight = false
VisionController._helmSeat = nil        -- the seat part the player is sitting in
VisionController._vesselRoot = nil       -- PrimaryPart of the vessel model
VisionController._heartbeatConn = nil
VisionController._seatChangedConn = nil
VisionController._weatherConn = nil
VisionController._sprayEmitter = nil
VisionController._rainLensEmitter = nil
VisionController._stars = nil
VisionController._moonLight = nil
VisionController._cameraShakeOffset = Vector3.zero
VisionController._shakeTime = 0
VisionController._vesselRoll = 0        -- current roll angle from vessel motion
VisionController._vesselPitch = 0       -- current pitch angle from vessel motion
VisionController._waveImpactImpulse = 0 -- transient impulse from wave hits
VisionController._auroraTilt = 0        -- slow upward tilt during aurora
VisionController._yieldedToCinematic = false

----------------------------------------------------------------
-- INTERNAL: WEATHER AWARENESS
----------------------------------------------------------------

--[[
    Read the current weather from workspace attributes (set by WeatherSystem).
    Falls back to "clear" if the attribute is missing.
]]
local function readWeatherState()
    local weather = Workspace:GetAttribute("CurrentWeather")
    if weather then
        VisionController._currentWeather = weather
    end

    local intensity = Workspace:GetAttribute("WeatherIntensity")
    if intensity then
        VisionController._weatherIntensity = intensity
    end

    -- Aurora is a special case
    if Workspace:GetAttribute("AuroraActive") then
        VisionController._currentWeather = "aurora"
    elseif Workspace:GetAttribute("StormActive") then
        VisionController._currentWeather = "storm"
    end
end

--[[
    Determine if it's currently night based on Lighting.ClockTime.
]]
local function updateNightState()
    local clockTime = Lighting.ClockTime
    VisionController._isNight = (clockTime > NIGHT_CLOCK_THRESHOLD or clockTime < DAWN_CLOCK_THRESHOLD)
end

----------------------------------------------------------------
-- INTERNAL: FAR-CLIP / FOG MANAGEMENT
----------------------------------------------------------------

--[[
    Adjust the camera's far-clip plane based on weather and fog intensity.
    Heavy fog: 50 studs. Pea-soup: 20 studs.
]]
local function updateFarClip()
    local weather = VisionController._currentWeather

    if weather == "fog" then
        -- Scale fog clip from intensity
        local intensity = VisionController._weatherIntensity
        if intensity > 0.85 then
            -- Pea-soup fog
            camera.FarPlane = PEA_SOUP_FAR_CLIP
        else
            -- Heavy fog: scale between 300 and 50
            local t = intensity or 0.6
            camera.FarPlane = math.floor(300 - (300 - 50) * t)
        end
    elseif weather == "storm" then
        camera.FarPlane = FAR_CLIP.storm
    elseif weather == "rain" then
        camera.FarPlane = FAR_CLIP.rain
    elseif weather == "aurora" then
        camera.FarPlane = FAR_CLIP.aurora
    elseif VisionController._isNight then
        camera.FarPlane = FAR_CLIP.night
    else
        camera.FarPlane = FAR_CLIP.clear
    end
end

----------------------------------------------------------------
-- INTERNAL: CAMERA SHAKES
----------------------------------------------------------------

--[[
    Generate a procedural camera shake offset based on weather state
    and wave impact impulses. Uses layered sine waves for organic motion.
    @return Vector3 offset to add to camera position
]]
local function computeShakeOffset()
    local params = SHAKE_PARAMS[VisionController._currentWeather] or SHAKE_PARAMS.clear
    if params.amplitude == 0 and VisionController._waveImpactImpulse < 0.01 then
        return Vector3.zero
    end

    local t = VisionController._shakeTime
    local freq = params.frequency
    local amp = params.amplitude

    -- Wave impact impulse adds a brief, decaying jolt
    local impulseAmp = VisionController._waveImpactImpulse
    amp = amp + impulseAmp

    -- Layered sines for organic shake
    local offsetX = math.sin(t * freq * 1.7) * amp * 0.6
    local offsetY = math.sin(t * freq * 2.3 + 1.3) * amp
    local offsetZ = math.sin(t * freq * 1.1 + 0.7) * amp * 0.4

    -- Add random noise for storm chaos
    if VisionController._currentWeather == "storm" then
        offsetX += (math.random() - 0.5) * amp * 0.3
        offsetY += (math.random() - 0.5) * amp * 0.3
    end

    return Vector3.new(offsetX, offsetY, offsetZ)
end

--[[
    Apply a wave-impact impulse to the camera. Called when the vessel
    hits a large wave or experiences hull impact.
    @param magnitude number 0–1 scale of the impact
]]
function VisionController.addWaveImpact(magnitude)
    VisionController._waveImpactImpulse = math.clamp(
        VisionController._waveImpactImpulse + magnitude,
        0, 0.8
    )
end

----------------------------------------------------------------
-- INTERNAL: STARS & MOONLIGHT (NIGHT)
----------------------------------------------------------------

--[[
    Create or retrieve a starfield part high above the world.
    Stars are a ParticleEmitter on a large invisible part.
]]
local function ensureStars()
    if VisionController._stars then return VisionController._stars end

    local part = Workspace:FindFirstChild("__VisionStars")
    if not part then
        part = Instance.new("Part")
        part.Name = "__VisionStars"
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.Transparency = 1
        part.Material = Enum.Material.Air
        part.Size = Vector3.new(4096, 1, 4096)
        part.Position = Vector3.new(0, 800, 0)
        part.Parent = Workspace

        local emitter = Instance.new("ParticleEmitter")
        emitter.Name = "StarEmitter"
        emitter.Texture = "rbxassetid://243660364"  -- soft glow
        emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 240))
        emitter.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.5),
            NumberSequenceKeypoint.new(0.5, 1.2),
            NumberSequenceKeypoint.new(1, 0.5),
        })
        emitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.3, 0.3),
            NumberSequenceKeypoint.new(0.7, 0.3),
            NumberSequenceKeypoint.new(1, 1),
        })
        emitter.Lifetime = NumberRange.new(9999, 9999)  -- effectively permanent
        emitter.Speed = NumberRange.new(0, 0)
        emitter.SpreadAngle = Vector2.new(180, 180)
        emitter.Rotation = NumberRange.new(0, 360)
        emitter.RotSpeed = NumberRange.new(0, 0)
        emitter.Acceleration = Vector3.zero
        emitter.Rate = 0  -- dormant during day
        emitter.Parent = part
    end

    VisionController._stars = part
    return part
end

--[[
    Create or retrieve a moonlight PointLight high above the world.
    Provides subtle directional light at night.
]]
local function ensureMoonLight()
    if VisionController._moonLight then return VisionController._moonLight end

    local sun = Lighting:FindFirstChild("__MoonLight")
    if not sun then
        sun = Instance.new("PointLight")
        sun.Name = "__MoonLight"
        sun.Brightness = 0
        sun.Range = 500
        sun.Color = Color3.fromRGB(180, 200, 230)
        sun.Shadows = false  -- too expensive at this range
        sun.Parent = Workspace.Terrain  -- parent to terrain so it's in the world
    end

    VisionController._moonLight = sun
    return sun
end

--[[
    Update star visibility and moonlight brightness based on time of day
    and weather.
]]
local function updateNightVisuals()
    local part = ensureStars()
    local emitter = part:FindFirstChild("StarEmitter")
    local moon = ensureMoonLight()

    local starsVisible = VisionController._isNight
        and VisionController._currentWeather ~= "storm"
        and VisionController._currentWeather ~= "fog"

    if emitter then
        if starsVisible then
            emitter.Rate = 300
        else
            emitter.Rate = 0
        end
    end

    -- Moonlight
    if VisionController._isNight and VisionController._currentWeather ~= "storm" then
        local targetBrightness = 0.4
        if VisionController._currentWeather == "aurora" then
            targetBrightness = 0.2  -- aurora provides its own light
        end
        TweenService:Create(moon, TweenInfo.new(3), { Brightness = targetBrightness }):Play()
    else
        TweenService:Create(moon, TweenInfo.new(3), { Brightness = 0 }):Play()
    end
end

----------------------------------------------------------------
-- INTERNAL: SPRAY & RAIN-ON-LENS PARTICLES
----------------------------------------------------------------

--[[
    Create a spray particle emitter attached to the camera for when
    the vessel is underway. Spray rate scales with vessel speed.
]]
local function ensureSprayEmitter()
    if VisionController._sprayEmitter then return end

    -- Attach to the camera's subject (the vessel or character)
    local part = Instance.new("Part")
    part.Name = "__VisionSpray"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.Material = Enum.Material.Air
    part.Size = Vector3.new(1, 1, 1)
    part.Position = Vector3.new(0, 5, 0)
    part.Parent = Workspace

    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = "SprayEmitter"
    emitter.Texture = SPRAY_CONFIG.texture
    emitter.Lifetime = NumberRange.new(SPRAY_CONFIG.lifetime, SPRAY_CONFIG.lifetime * 1.5)
    emitter.Speed = NumberRange.new(SPRAY_CONFIG.speed, SPRAY_CONFIG.speed * 1.5)
    emitter.SpreadAngle = SPRAY_CONFIG.spreadAngle
    emitter.Size = SPRAY_CONFIG.size
    emitter.Transparency = SPRAY_CONFIG.transparency
    emitter.Color = SPRAY_CONFIG.color
    emitter.Acceleration = SPRAY_CONFIG.acceleration
    emitter.Rate = 0  -- dormant
    emitter.Parent = part

    VisionController._sprayEmitter = emitter
end

--[[
    Create a rain-on-lens emitter for storm weather.
    Attaches near the camera and emits toward it.
]]
local function ensureRainLensEmitter()
    if VisionController._rainLensEmitter then return end

    local part = Instance.new("Part")
    part.Name = "__VisionRainLens"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.Material = Enum.Material.Air
    part.Size = Vector3.new(1, 1, 1)
    part.Position = Vector3.new(0, 5, 0)
    part.Parent = Workspace

    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = "RainLensEmitter"
    emitter.Texture = "rbxassetid://3787172071"
    emitter.Color = ColorSequence.new(Color3.fromRGB(180, 200, 230))
    emitter.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(1, 0.1),
    })
    emitter.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.6),
        NumberSequenceKeypoint.new(1, 1.0),
    })
    emitter.Lifetime = NumberRange.new(0.3, 0.5)
    emitter.Speed = NumberRange.new(10, 20)
    emitter.SpreadAngle = Vector2.new(45, 45)
    emitter.Acceleration = Vector3.new(0, -20, 0)
    emitter.Rate = 0
    emitter.Parent = part

    VisionController._rainLensEmitter = emitter
end

--[[
    Update spray and rain-on-lens based on weather and vessel speed.
    @param vesselSpeed number studs/sec
]]
local function updateParticleEffects(vesselSpeed)
    -- Spray off the bow when underway
    if VisionController._sprayEmitter then
        local sprayRate = 0
        if VisionController._mode == MODE.AT_HELM and vesselSpeed > 5 then
            -- Scale spray with speed and weather
            local base = (vesselSpeed / 50) * 40
            if VisionController._currentWeather == "storm" then
                base = base * 2.5
            elseif VisionController._currentWeather == "rain" then
                base = base * 1.5
            end
            sprayRate = math.clamp(base, 0, 120)
        end
        VisionController._sprayEmitter.Rate = sprayRate

        -- Position the spray emitter ahead of the vessel
        if VisionController._vesselRoot then
            local root = VisionController._vesselRoot
            local sprayPart = VisionController._sprayEmitter.Parent
            sprayPart.Position = root.Position + root.CFrame.LookVector * 8 + Vector3.new(0, 2, 0)
        end
    end

    -- Rain-on-lens during storms
    if VisionController._rainLensEmitter then
        local lensRate = 0
        if VisionController._currentWeather == "storm" then
            lensRate = 30
        elseif VisionController._currentWeather == "rain" then
            lensRate = 10
        end
        VisionController._rainLensEmitter.Rate = lensRate

        -- Position near camera
        if VisionController._rainLensEmitter.Parent then
            VisionController._rainLensEmitter.Parent.Position = camera.CFrame.Position + camera.CFrame.LookVector * 3
        end
    end
end

----------------------------------------------------------------
-- INTERNAL: HELM SEAT DETECTION
----------------------------------------------------------------

--[[
    Detect if the player is sitting in a helm seat.
    Helm seats are tagged "HelmSeat" via CollectionService.
    Updates VisionController._helmSeat and VisionController._vesselRoot.
]]
local function detectHelmSeat()
    local character = player.Character
    if not character then return end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    local seatPart = humanoid.SeatPart
    if seatPart and CollectionService:HasTag(seatPart, "HelmSeat") then
        VisionController._helmSeat = seatPart

        -- Find the vessel root: walk up the model hierarchy
        local model = seatPart:FindFirstAncestorOfClass("Model")
        if model and model.PrimaryPart then
            VisionController._vesselRoot = model.PrimaryPart
        elseif model then
            -- Try to find a reasonable root part
            VisionController._vesselRoot = model:FindFirstChild("Hull") or seatPart
        else
            VisionController._vesselRoot = seatPart
        end

        VisionController._mode = MODE.AT_HELM
    else
        -- Not in a helm seat
        if VisionController._mode == MODE.AT_HELM then
            VisionController._helmSeat = nil
            VisionController._vesselRoot = nil
            VisionController._mode = MODE.ON_FOOT
        end
    end
end

----------------------------------------------------------------
-- INTERNAL: VESSEL MOTION TRACKING
----------------------------------------------------------------

--[[
    Track the vessel's roll and pitch by comparing its CFrame over time.
    This translates boat motion into camera motion.
]]
local _lastVesselCFrame = nil

local function updateVesselMotion()
    if not VisionController._vesselRoot then
        VisionController._vesselRoll = 0
        VisionController._vesselPitch = 0
        _lastVesselCFrame = nil
        return
    end

    local currentCFrame = VisionController._vesselRoot.CFrame

    if _lastVesselCFrame then
        -- Extract roll (rotation around LookVector/Z axis)
        -- and pitch (rotation around RightVector/X axis)
        local delta = _lastVesselCFrame:ToObjectSpace(currentCFrame)
        local rx, ry, rz = delta:ToEulerAnglesYXZ()
        VisionController._vesselPitch = rx
        VisionController._vesselRoll = rz
    end

    _lastVesselCFrame = currentCFrame
end

----------------------------------------------------------------
-- CAMERA UPDATE: ON FOOT
----------------------------------------------------------------

--[[
    Update camera for on-foot mode. Standard Roblox third-person but
    slightly raised. We let Roblox handle this mostly, just nudge the
    CameraSubject higher.
]]
local function updateOnFootCamera(dt)
    local character = player.Character
    if not character then return end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    -- Ensure standard camera type
    if camera.CameraType ~= Enum.CameraType.Custom then
        camera.CameraType = Enum.CameraType.Custom
    end

    -- Set FOV
    if math.abs(camera.FieldOfView - DEFAULT_FOV) > 0.5 then
        camera.FieldOfView = DEFAULT_FOV
    end

    -- CameraSubject stays as the Humanoid for standard third-person.
    -- The "slightly raised" feel comes from a small hip-height offset
    -- applied via the Humanoid's CameraOffset.
    humanoid.CameraOffset = humanoid.CameraOffset:Lerp(
        Vector3.new(0, 1.5, 0),
        dt * 5
    )
end

----------------------------------------------------------------
-- CAMERA UPDATE: AT HELM
----------------------------------------------------------------

--[[
    Update camera for at-helm mode. Over-the-shoulder vessel view.

    Camera is positioned behind and above the helm seat, offset to the
    right (starboard) side so the player can see: the bow, the water
    ahead, the chart, and the wheel. The boat's roll and pitch translate
    directly into camera movement, so the player feels every wave.
]]
local function updateHelmCamera(dt)
    if not VisionController._helmSeat or not VisionController._vesselRoot then
        return
    end

    -- Take over the camera
    if camera.CameraType ~= Enum.CameraType.Scriptable then
        camera.CameraType = Enum.CameraType.Scriptable
    end

    -- Set helm FOV
    local targetFOV = HELM_FOV

    -- Storm FOV punch from wave impacts
    if VisionController._waveImpactImpulse > 0.1 then
        targetFOV = HELM_FOV + (STORM_FOV_PUNCH - HELM_FOV) * VisionController._waveImpactImpulse
    end
    camera.FieldOfView = camera.FieldOfView + (targetFOV - camera.FieldOfView) * dt * 4

    local helmPos = VisionController._helmSeat.Position
    local vesselRoot = VisionController._vesselRoot
    local vesselCFrame = vesselRoot.CFrame

    -- Base camera position: behind and above the helm, offset to starboard
    local baseOffset = HELM_OFFSET

    -- Apply vessel roll/pitch to the offset so the camera moves with the boat
    local rollAngle = VisionController._vesselRoll
    local pitchAngle = VisionController._vesselPitch
    local motionCFrame = CFrame.Angles(pitchAngle, 0, rollAngle)

    local targetPos = vesselCFrame * motionCFrame * CFrame.new(baseOffset).Position

    -- Look-at point: ahead of the vessel, slightly down toward the water
    local lookAt = vesselCFrame * motionCFrame * CFrame.new(HELM_LOOK_OFFSET).Position

    -- Apply camera shake (storms, wave impacts)
    local shakeOffset = computeShakeOffset()
    targetPos = targetPos + shakeOffset

    -- Aurora slow upward tilt
    if VisionController._currentWeather == "aurora" then
        VisionController._auroraTilt = math.clamp(VisionController._auroraTilt + dt * 0.02, 0, 0.15)
        -- Tilt the look-at point upward
        lookAt = lookAt:Lerp(lookAt + Vector3.new(0, 50, 0), VisionController._auroraTilt)
    else
        VisionController._auroraTilt = math.max(0, VisionController._auroraTilt - dt * 0.05)
    end

    -- Smooth camera interpolation
    local smooth = HELM_SMOOTH
    camera.CFrame = camera.CFrame:Lerp(
        CFrame.lookAt(targetPos, lookAt),
        smooth
    )

    -- Decay wave impact impulse
    VisionController._waveImpactImpulse = VisionController._waveImpactImpulse * math.pow(0.92, dt * 60)
    if VisionController._waveImpactImpulse < 0.001 then
        VisionController._waveImpactImpulse = 0
    end
end

----------------------------------------------------------------
-- CAMERA UPDATE: CINEMATIC
----------------------------------------------------------------

--[[
    In cinematic mode, the VisionController does nothing — SceneDirector
    has full control. This function is a no-op placeholder.
]]
local function updateCinematicCamera(dt)
    -- SceneDirector handles everything
end

----------------------------------------------------------------
-- HEARTBEAT LOOP
----------------------------------------------------------------

local function onHeartbeat(dt)
    if VisionController._yieldedToCinematic then
        updateCinematicCamera(dt)
        return
    end

    VisionController._shakeTime = VisionController._shakeTime + dt

    -- Update state
    readWeatherState()
    updateNightState()
    detectHelmSeat()
    updateVesselMotion()

    -- Update camera based on mode
    if VisionController._mode == MODE.AT_HELM then
        updateHelmCamera(dt)
    else
        updateOnFootCamera(dt)
    end

    -- Update environment-aware visuals
    updateFarClip()
    updateNightVisuals()

    -- Estimate vessel speed for spray effects
    local vesselSpeed = 0
    if VisionController._vesselRoot and _lastVesselCFrame then
        local displacement = (VisionController._vesselRoot.Position - _lastVesselCFrame.Position)
        vesselSpeed = displacement.Magnitude / dt
    end
    updateParticleEffects(vesselSpeed)
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the VisionController. Connects heartbeat and sets up
    initial state. Call once on game start.
]]
function VisionController.init()
    if VisionController._heartbeatConn then
        warn("[VisionController] Already initialized.")
        return
    end

    -- Ensure effect containers exist
    ensureStars()
    ensureMoonLight()
    ensureSprayEmitter()
    ensureRainLensEmitter()

    -- Initial state read
    readWeatherState()
    updateNightState()
    updateFarClip()
    updateNightVisuals()

    -- Connect heartbeat
    VisionController._heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

    -- Also listen for attribute changes (weather transitions)
    Workspace:GetAttributeChangedSignal("CurrentWeather"):Connect(function()
        readWeatherState()
        updateFarClip()
        updateNightVisuals()
    end)

    Workspace:GetAttributeChangedSignal("AuroraActive"):Connect(function()
        readWeatherState()
        updateFarClip()
        updateNightVisuals()
    end)

    Workspace:GetAttributeChangedSignal("StormActive"):Connect(function()
        readWeatherState()
        updateFarClip()
    end)

    print("[VisionController] Initialized — mode:", VisionController._mode)
end

--[[
    Yield camera control to the SceneDirector for cinematics.
    The VisionController stops updating camera CFrame until
    VisionController.releaseFromCinematic() is called.
]]
function VisionController.yieldToCinematic()
    VisionController._yieldedToCinematic = true
end

--[[
    Release camera control back to the VisionController after a cinematic.
    Smoothly hands off — the next heartbeat resumes normal camera logic.
]]
function VisionController.releaseFromCinematic()
    VisionController._yieldedToCinematic = false
    -- Force a camera mode re-detection
    VisionController._mode = MODE.ON_FOOT
    detectHelmSeat()
end

--[[
    Get the current camera mode.
    @return string — "on_foot", "at_helm", or "cinematic"
]]
function VisionController.getMode()
    if VisionController._yieldedToCinematic then
        return MODE.CINEMATIC
    end
    return VisionController._mode
end

--[[
    Manually set the far-clip plane. Used for special events or testing.
    Pass nil to restore weather-based defaults.
    @param studs number? — far-clip distance in studs, or nil for auto
]]
function VisionController.setFarClip(studs)
    if studs then
        camera.FarPlane = studs
    else
        updateFarClip()
    end
end

--[[
    Get the current vessel root part (if at helm).
    @return BasePart? — the vessel's root part
]]
function VisionController.getVesselRoot()
    return VisionController._vesselRoot
end

--[[
    Get the current helm seat (if at helm).
    @return BasePart? — the seat the player is sitting in
]]
function VisionController.getHelmSeat()
    return VisionController._helmSeat
end

--[[
    Clean up all resources. Call on game shutdown or testing resets.
]]
function VisionController.shutdown()
    if VisionController._heartbeatConn then
        VisionController._heartbeatConn:Disconnect()
        VisionController._heartbeatConn = nil
    end

    -- Restore camera
    camera.CameraType = Enum.CameraType.Custom
    camera.FieldOfView = DEFAULT_FOV

    -- Clean up parts
    if VisionController._stars then
        VisionController._stars:Destroy()
        VisionController._stars = nil
    end
    if VisionController._moonLight then
        VisionController._moonLight:Destroy()
        VisionController._moonLight = nil
    end
    if VisionController._sprayEmitter then
        VisionController._sprayEmitter.Parent:Destroy()
        VisionController._sprayEmitter = nil
    end
    if VisionController._rainLensEmitter then
        VisionController._rainLensEmitter.Parent:Destroy()
        VisionController._rainLensEmitter = nil
    end

    VisionController._yieldedToCinematic = false
    VisionController._mode = MODE.ON_FOOT
    print("[VisionController] Shut down.")
end

return VisionController
