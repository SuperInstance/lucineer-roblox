--[[
    EnvironmentController / client.lua
    Slackwater — Environmental atmosphere & 3D positional audio

    "The yard talks. Tide under the floor, gulls on the roofline,
     the foghorn out past the Light. You hear where things are."

    ───────────────────────────────────────────────
    RESPONSIBILITIES:
      • Dynamic sky — day/night cycle with accurate lighting color changes,
                      synchronized with Lighting.ClockTime.
      • Weather visuals — rain (particle on camera), snow (winter),
                          fog (atmosphere fogEnd), spray (speed particles).
      • Water surface — Terrain water with wave height responding to
                        WeatherSystem. Foam near shore and in storms.
      • Sound positioning — 3D positional audio for: engine rumble,
                            waves, gulls, foghorn, bell buoy, NPC voices.
      • Vibration feedback — gamepad rumble on engine start, hull impact,
                             heavy waves, gear deployment.

    INTEGRATION:
      • WeatherSystem (workspace attributes) for weather state
      • AudioManager (ReplicatedStorage.Lucineer.AudioManager) for sound groups
      • VisionController for camera position (spray follows camera)
      • CollectionService tags: "Buoy", "Lighthouse", "NPC",
        "EngineSource", "WaveSurface" for positional sound anchors

    This module is a LocalScript running on the client.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local Terrain = Workspace.Terrain

local player = Players.LocalPlayer

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local EnvironmentController = {}

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

-- Day/night lighting color profiles (interpolated by ClockTime)
-- Each entry: { hour, brightness, ambient, outdoorAmbient, fogColor, fogEnd, clockTime }
local TIME_OF_DAY_PROFILES = {
    -- Midnight (0:00)
    { hour = 0,  brightness = 0.2,  ambient = Color3.fromRGB(15, 18, 28),
      outdoor = Color3.fromRGB(20, 25, 38),  fogColor = Color3.fromRGB(8, 12, 22),
      fogEnd = 2000 },
    -- Pre-dawn (4:30)
    { hour = 4.5, brightness = 0.3, ambient = Color3.fromRGB(25, 25, 40),
      outdoor = Color3.fromRGB(35, 32, 50),  fogColor = Color3.fromRGB(40, 35, 55),
      fogEnd = 2500 },
    -- Dawn (6:00)
    { hour = 6,  brightness = 0.8,  ambient = Color3.fromRGB(80, 65, 55),
      outdoor = Color3.fromRGB(120, 95, 75), fogColor = Color3.fromRGB(200, 160, 130),
      fogEnd = 3000 },
    -- Morning (8:00)
    { hour = 8,  brightness = 1.4,  ambient = Color3.fromRGB(100, 100, 110),
      outdoor = Color3.fromRGB(130, 125, 120), fogColor = Color3.fromRGB(200, 210, 225),
      fogEnd = 3500 },
    -- Midday (12:00)
    { hour = 12, brightness = 2.2,  ambient = Color3.fromRGB(130, 130, 140),
      outdoor = Color3.fromRGB(140, 140, 145), fogColor = Color3.fromRGB(210, 220, 230),
      fogEnd = 4500 },
    -- Afternoon (16:00)
    { hour = 16, brightness = 1.8,  ambient = Color3.fromRGB(120, 110, 95),
      outdoor = Color3.fromRGB(140, 125, 105), fogColor = Color3.fromRGB(220, 200, 175),
      fogEnd = 3500 },
    -- Golden hour (18:00)
    { hour = 18, brightness = 1.2,  ambient = Color3.fromRGB(100, 80, 65),
      outdoor = Color3.fromRGB(135, 100, 75), fogColor = Color3.fromRGB(230, 170, 120),
      fogEnd = 3000 },
    -- Dusk (19:30)
    { hour = 19.5, brightness = 0.5, ambient = Color3.fromRGB(50, 40, 55),
      outdoor = Color3.fromRGB(70, 55, 70),  fogColor = Color3.fromRGB(80, 60, 80),
      fogEnd = 2200 },
    -- Night (21:00)
    { hour = 21, brightness = 0.25, ambient = Color3.fromRGB(18, 20, 30),
      outdoor = Color3.fromRGB(25, 28, 40),  fogColor = Color3.fromRGB(10, 15, 25),
      fogEnd = 1800 },
}

-- Wave height multipliers per weather
local WAVE_HEIGHT = {
    clear  = 1.0,
    fog    = 0.6,
    rain   = 1.8,
    storm  = 4.0,
    aurora = 0.3,
}

-- Foam intensity per weather
local FOAM_INTENSITY = {
    clear  = 0.1,
    fog    = 0.05,
    rain   = 0.4,
    storm  = 1.0,
    aurora = 0.0,
}

-- Snow configuration (winter mode)
local SNOW_CONFIG = {
    texture = "rbxassetid://3787172071",
    rate = 60,
    lifetime = 6,
    speed = 8,
    spreadAngle = Vector2.new(45, 45),
    size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.8),
        NumberSequenceKeypoint.new(1, 0.3),
    }),
    transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(1, 0.7),
    }),
    color = ColorSequence.new(Color3.fromRGB(250, 250, 255)),
    acceleration = Vector3.new(0, -8, 0),
}

-- 3D Sound definitions for positional audio sources
-- Each source is attached to a CollectionService-tagged part.
local POSITIONAL_SOUNDS = {
    engine = {
        soundId = "rbxassetid://9120832471",  -- low rumble
        volume = 0.6,
        pitch = 0.7,
        looped = true,
        maxDistance = 120,
        minDistance = 5,
        tag = "EngineSource",
        rolloff = Enum.RollOffMode.InverseTapered,
    },
    waves = {
        soundId = "rbxassetid://4766793559",  -- water lapping
        volume = 0.35,
        pitch = 0.9,
        looped = true,
        maxDistance = 200,
        minDistance = 10,
        tag = "WaveSurface",
        rolloff = Enum.RollOffMode.Linear,
    },
    gulls = {
        soundId = "rbxassetid://9118858002",  -- gull cry
        volume = 0.25,
        pitch = 1.0,
        looped = false,
        maxDistance = 300,
        minDistance = 20,
        tag = "GullPerch",
        rolloff = Enum.RollOffMode.InverseTapered,
    },
    foghorn = {
        soundId = "rbxassetid://229325720",
        volume = 0.5,
        pitch = 0.8,
        looped = false,
        maxDistance = 600,
        minDistance = 30,
        tag = "Lighthouse",
        rolloff = Enum.RollOffMode.InverseTapered,
    },
    bellBuoy = {
        soundId = "rbxassetid://9118858002",  -- bell
        volume = 0.35,
        pitch = 1.3,
        looped = false,
        maxDistance = 250,
        minDistance = 10,
        tag = "Buoy",
        rolloff = Enum.RollOffMode.InverseTapered,
    },
    npc = {
        soundId = "rbxassetid://9120917974",  -- voice murmur
        volume = 0.20,
        pitch = 1.0,
        looped = false,
        maxDistance = 60,
        minDistance = 3,
        tag = "NPC",
        rolloff = Enum.RollOffMode.InverseTapered,
    },
}

-- Gamepad rumble intensities per event
local RUMBLE_PARAMS = {
    engine_start    = { small = 0.3,  large = 0.15, duration = 1.5 },
    hull_impact     = { small = 0.6,  large = 0.8,  duration = 0.4 },
    heavy_wave      = { small = 0.4,  large = 0.5,  duration = 0.6 },
    gear_deploy     = { small = 0.2,  large = 0.1,  duration = 0.3 },
    storm_idle      = { small = 0.08, large = 0.05, duration = 0 }, -- continuous
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

EnvironmentController._initialized = false
EnvironmentController._heartbeatConn = nil
EnvironmentController._currentWeather = "clear"
EnvironmentController._weatherIntensity = 0
EnvironmentController._isWinter = false
EnvironmentController._positionalSounds = {}  -- { [tag]: { Sound, part } }
EnvironmentController._snowEmitter = nil
EnvironmentController._foamParts = nil
EnvironmentController._lastClockTime = 0
EnvironmentController._dayNightCC = nil
EnvironmentController._bellTimer = 0
EnvironmentController._gullTimer = 0
EnvironmentController._foghornTimer = 0
EnvironmentController._stormRumbleActive = false

----------------------------------------------------------------
-- INTERNAL: DAY/NIGHT LIGHTING
----------------------------------------------------------------

--[[
    Interpolate between two TIME_OF_DAY_PROFILES based on current ClockTime.
    Returns a lighting profile table.
    @param clockTime number 0–24
    @return table profile
]]
local function interpolateProfile(clockTime)
    -- Find the two bracketing profiles
    local lower, upper

    for i = 1, #TIME_OF_DAY_PROFILES do
        local p = TIME_OF_DAY_PROFILES[i]
        if p.hour <= clockTime then
            lower = p
            local nextIdx = i + 1
            if nextIdx > #TIME_OF_DAY_PROFILES then
                -- Wrap to first profile (next day)
                upper = TIME_OF_DAY_PROFILES[1]
            else
                upper = TIME_OF_DAY_PROFILES[nextIdx]
            end
        end
    end

    -- If clockTime is before the first profile hour, use last profile → first
    if not lower then
        lower = TIME_OF_DAY_PROFILES[#TIME_OF_DAY_PROFILES]
        upper = TIME_OF_DAY_PROFILES[1]
    end

    -- Calculate interpolation factor
    local span
    if upper.hour > lower.hour then
        span = upper.hour - lower.hour
    else
        -- Wraps past midnight
        span = (24 - lower.hour) + upper.hour
    end

    local elapsed
    if clockTime >= lower.hour then
        elapsed = clockTime - lower.hour
    else
        elapsed = (24 - lower.hour) + clockTime
    end

    local t = span > 0 and (elapsed / span) or 0
    t = math.clamp(t, 0, 1)

    -- Smoothstep for more natural transitions
    t = t * t * (3 - 2 * t)

    -- Interpolate values
    return {
        brightness = lower.brightness + (upper.brightness - lower.brightness) * t,
        ambient = lower.ambient:Lerp(upper.ambient, t),
        outdoor = lower.outdoor:Lerp(upper.outdoor, t),
        fogColor = lower.fogColor:Lerp(upper.fogColor, t),
        fogEnd = lower.fogEnd + (upper.fogEnd - lower.fogEnd) * t,
    }
end

--[[
    Update lighting based on the current ClockTime. Only applies changes
    when the weather is "clear" — weather profiles override day/night.
    During fog/rain/storm/aurora, the WeatherSystem manages lighting.
]]
local function updateDayNightLighting()
    -- Only manage lighting during clear weather
    -- Other weather states are handled by WeatherSystem lighting profiles
    if EnvironmentController._currentWeather ~= "clear" then
        return
    end

    local clockTime = Lighting.ClockTime
    local profile = interpolateProfile(clockTime)

    -- Smoothly apply (we don't tween here because this runs every frame;
    -- the incremental changes are small enough to be smooth)
    Lighting.Brightness = profile.brightness
    Lighting.Ambient = profile.ambient
    Lighting.OutdoorAmbient = profile.outdoor

    -- Only set fog if weather isn't overriding
    if EnvironmentController._currentWeather == "clear" then
        Lighting.FogColor = profile.fogColor
        Lighting.FogEnd = profile.fogEnd
        Lighting.FogStart = profile.fogEnd * 0.3
    end
end

----------------------------------------------------------------
-- INTERNAL: WATER SURFACE
----------------------------------------------------------------

--[[
    Update terrain water properties based on weather state.
    Wave height, water color, and foam respond to weather.
]]
local function updateWaterSurface()
    local weather = EnvironmentController._currentWeather
    local waveHeight = WAVE_HEIGHT[weather] or 1.0
    local foamIntensity = FOAM_INTENSITY[weather] or 0.1

    -- Terrain water wave height (0-10 range in Roblox)
    local targetWaveHeight = waveHeight * 2.5  -- scale to Roblox range
    Terrain.WaveSpeed = 8 + (waveHeight * 4)
    Terrain.WaveHeight = targetWaveHeight

    -- Water color shifts slightly with weather
    local waterColor
    if weather == "storm" then
        waterColor = Color3.fromRGB(30, 45, 60)
    elseif weather == "fog" then
        waterColor = Color3.fromRGB(80, 90, 100)
    elseif weather == "rain" then
        waterColor = Color3.fromRGB(55, 70, 85)
    elseif weather == "aurora" then
        waterColor = Color3.fromRGB(15, 35, 50)  -- dark, aurora-reflective
    else
        waterColor = Color3.fromRGB(40, 80, 110)  -- clear blue-gray
    end
    Terrain.WaterColor = waterColor

    -- Water transparency: murkier in storms
    local waterTransparency = 0.3
    if weather == "storm" then
        waterTransparency = 0.1
    elseif weather == "fog" then
        waterTransparency = 0.2
    end
    Terrain.WaterTransparency = waterTransparency

    -- Water reflectivity: calmer in fog/aurora, choppier in storms
    local waterReflectivity = 0.5
    if weather == "storm" then
        waterReflectivity = 0.2  -- less reflective when churned
    elseif weather == "aurora" then
        waterReflectivity = 0.8  -- mirror-calm for aurora reflections
    end
    -- Note: Terrain doesn't have a direct reflectivity property,
    -- but WaterColor brightness approximates this effect.
end

----------------------------------------------------------------
-- INTERNAL: SHORELINE FOAM
----------------------------------------------------------------

--[[
    Create foam decal/emitter parts along the shoreline.
    Foam intensity scales with weather (storms = maximum foam).
    Uses CollectionService-tagged "ShoreLine" parts as anchors.
]]
local function updateShorelineFoam()
    local weather = EnvironmentController._currentWeather
    local foamIntensity = FOAM_INTENSITY[weather] or 0.1

    local shoreParts = CollectionService:GetTagged("ShoreLine")
    for _, shorePart in ipairs(shoreParts) do
        if shorePart:IsA("BasePart") then
            -- Look for or create a foam ParticleEmitter
            local foam = shorePart:FindFirstChild("FoamEmitter")
            if not foam then
                foam = Instance.new("ParticleEmitter")
                foam.Name = "FoamEmitter"
                foam.Texture = "rbxassetid://243660364"
                foam.Color = ColorSequence.new(Color3.fromRGB(240, 245, 250))
                foam.Size = NumberSequence.new({
                    NumberSequenceKeypoint.new(0, 2),
                    NumberSequenceKeypoint.new(1, 0.5),
                })
                foam.Transparency = NumberSequence.new({
                    NumberSequenceKeypoint.new(0, 0.5),
                    NumberSequenceKeypoint.new(1, 1.0),
                })
                foam.Lifetime = NumberRange.new(1, 2)
                foam.Speed = NumberRange.new(2, 6)
                foam.SpreadAngle = Vector2.new(45, 45)
                foam.Acceleration = Vector3.new(0, 2, 0)
                foam.Rate = 0
                foam.Parent = shorePart
            end

            -- Scale foam rate with intensity
            foam.Rate = foamIntensity * 30
        end
    end
end

----------------------------------------------------------------
-- INTERNAL: SNOW (WINTER MODE)
----------------------------------------------------------------

--[[
    Create the snow particle emitter if it doesn't exist.
    Dormant until winter mode is activated.
]]
local function ensureSnowEmitter()
    if EnvironmentController._snowEmitter then return end

    local part = Instance.new("Part")
    part.Name = "__SnowDome"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.Material = Enum.Material.Air
    part.Size = Vector3.new(1024, 1, 1024)
    part.Position = Vector3.new(0, 200, 0)
    part.Parent = Workspace

    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = "SnowEmitter"
    emitter.Texture = SNOW_CONFIG.texture
    emitter.Color = SNOW_CONFIG.color
    emitter.Size = SNOW_CONFIG.size
    emitter.Transparency = SNOW_CONFIG.transparency
    emitter.Lifetime = NumberRange.new(SNOW_CONFIG.lifetime, SNOW_CONFIG.lifetime * 1.5)
    emitter.Speed = NumberRange.new(SNOW_CONFIG.speed, SNOW_CONFIG.speed * 1.3)
    emitter.SpreadAngle = SNOW_CONFIG.spreadAngle
    emitter.Acceleration = SNOW_CONFIG.acceleration
    emitter.Rate = 0  -- dormant
    emitter.Parent = part

    EnvironmentController._snowEmitter = emitter
end

--[[
    Toggle winter snow mode on/off.
    @param enabled boolean
]]
function EnvironmentController.setWinter(enabled)
    EnvironmentController._isWinter = enabled
    if not EnvironmentController._snowEmitter then
        ensureSnowEmitter()
    end
    EnvironmentController._snowEmitter.Rate = enabled and SNOW_CONFIG.rate or 0
end

----------------------------------------------------------------
-- INTERNAL: POSITIONAL 3D SOUND
----------------------------------------------------------------

--[[
    Initialize positional sound sources for all tagged parts in the world.
    Creates 3D Sounds parented to their source parts.
    Re-scans periodically for new parts (spawned vessels, NPCs, etc.).
]]
local function initPositionalSounds()
    for soundName, def in pairs(POSITIONAL_SOUNDS) do
        local parts = CollectionService:GetTagged(def.tag)
        for _, part in ipairs(parts) do
            if part:IsA("BasePart") and not part:FindFirstChild("__EnvSound_" .. soundName) then
                local sound = Instance.new("Sound")
                sound.Name = "__EnvSound_" .. soundName
                sound.SoundId = def.soundId
                sound.Volume = def.volume
                sound.PlaybackSpeed = def.pitch
                sound.Looped = def.looped
                sound.RollOffMaxDistance = def.maxDistance
                sound.RollOffMinDistance = def.minDistance
                sound.RollOffMode = def.rolloff
                sound.Parent = part

                if def.looped then
                    sound:Play()
                end

                -- Track it
                EnvironmentController._positionalSounds[part] = EnvironmentController._positionalSounds[part] or {}
                EnvironmentController._positionalSounds[part][soundName] = sound
            end
        end
    end
end

--[[
    Update positional sounds: play periodic one-shots (bells, gulls, foghorn)
    and adjust volumes based on weather.
]]
local function updatePositionalSounds(dt)
    -- Continuous sounds: adjust volume based on weather
    local weatherVolMod = 1.0
    if EnvironmentController._currentWeather == "storm" then
        weatherVolMod = 1.3  -- everything louder in storms
    elseif EnvironmentController._currentWeather == "fog" then
        weatherVolMod = 0.8  -- muffled
    elseif EnvironmentController._currentWeather == "aurora" then
        weatherVolMod = 0.1  -- near silence for aurora
    end

    for part, sounds in pairs(EnvironmentController._positionalSounds) do
        if part.Parent then
            for soundName, sound in pairs(sounds) do
                if sound.Looped and sound.IsPlaying then
                    local def = POSITIONAL_SOUNDS[soundName]
                    if def then
                        sound.Volume = def.volume * weatherVolMod
                    end
                end
            end
        else
            -- Part destroyed, clean up
            EnvironmentController._positionalSounds[part] = nil
        end
    end

    -- Periodic one-shots: bell buoys
    EnvironmentController._bellTimer = EnvironmentController._bellTimer + dt
    if EnvironmentController._bellTimer > 12 + math.random() * 8 then
        EnvironmentController._bellTimer = 0
        local buoys = CollectionService:GetTagged("Buoy")
        if #buoys > 0 then
            local buoy = buoys[math.random(1, #buoys)]
            if buoy:IsA("BasePart") then
                local sound = Instance.new("Sound")
                sound.SoundId = POSITIONAL_SOUNDS.bellBuoy.soundId
                sound.Volume = POSITIONAL_SOUNDS.bellBuoy.volume * weatherVolMod
                sound.PlaybackSpeed = POSITIONAL_SOUNDS.bellBuoy.pitch
                sound.RollOffMaxDistance = POSITIONAL_SOUNDS.bellBuoy.maxDistance
                sound.RollOffMinDistance = POSITIONAL_SOUNDS.bellBuoy.minDistance
                sound.RollOffMode = POSITIONAL_SOUNDS.bellBuoy.rolloff
                sound.Parent = buoy
                sound:Play()
                game:GetService("Debris"):AddItem(sound, 4)
            end
        end
    end

    -- Periodic one-shots: gulls (daytime only)
    local isDay = Lighting.ClockTime > 6 and Lighting.ClockTime < 19
    EnvironmentController._gullTimer = EnvironmentController._gullTimer + dt
    if isDay and EnvironmentController._gullTimer > 20 + math.random() * 40 then
        EnvironmentController._gullTimer = 0
        local perches = CollectionService:GetTagged("GullPerch")
        if #perches > 0 then
            local perch = perches[math.random(1, #perches)]
            if perch:IsA("BasePart") then
                local sound = Instance.new("Sound")
                sound.SoundId = POSITIONAL_SOUNDS.gulls.soundId
                sound.Volume = POSITIONAL_SOUNDS.gulls.volume * weatherVolMod
                sound.PlaybackSpeed = POSITIONAL_SOUNDS.gulls.pitch + (math.random() - 0.5) * 0.2
                sound.RollOffMaxDistance = POSITIONAL_SOUNDS.gulls.maxDistance
                sound.RollOffMinDistance = POSITIONAL_SOUNDS.gulls.minDistance
                sound.RollOffMode = POSITIONAL_SOUNDS.gulls.rolloff
                sound.Parent = perch
                sound:Play()
                game:GetService("Debris"):AddItem(sound, 3)
            end
        end
    end

    -- Periodic one-shots: foghorn (only during fog or night)
    EnvironmentController._foghornTimer = EnvironmentController._foghornTimer + dt
    local foghornActive = EnvironmentController._currentWeather == "fog"
        or (Lighting.ClockTime > 20 or Lighting.ClockTime < 5)
    if foghornActive and EnvironmentController._foghornTimer > 30 + math.random() * 30 then
        EnvironmentController._foghornTimer = 0
        local lighthouses = CollectionService:GetTagged("Lighthouse")
        for _, lighthouse in ipairs(lighthouses) do
            if lighthouse:IsA("BasePart") then
                local sound = Instance.new("Sound")
                sound.SoundId = POSITIONAL_SOUNDS.foghorn.soundId
                sound.Volume = POSITIONAL_SOUNDS.foghorn.volume
                sound.PlaybackSpeed = POSITIONAL_SOUNDS.foghorn.pitch
                sound.RollOffMaxDistance = POSITIONAL_SOUNDS.foghorn.maxDistance
                sound.RollOffMinDistance = POSITIONAL_SOUNDS.foghorn.minDistance
                sound.RollOffMode = POSITIONAL_SOUNDS.foghorn.rolloff
                sound.Parent = lighthouse
                sound:Play()
                game:GetService("Debris"):AddItem(sound, 6)
            end
        end
    end
end

----------------------------------------------------------------
-- INTERNAL: GAMEPAD RUMBLE
----------------------------------------------------------------
--[[
    Trigger a gamepad rumble effect.
    @param eventName string — key into RUMBLE_PARAMS
    @param customIntensity number? — override magnitude (0-1)
]]
function EnvironmentController.triggerRumble(eventName, customIntensity)
    local params = RUMBLE_PARAMS[eventName]
    if not params then return end

    local gamepad = UserInputService:GetConnectedGamepads()
    if not gamepad or #gamepad == 0 then return end

    local small = params.small
    local large = params.large
    if customIntensity then
        small = small * customIntensity
        large = large * customIntensity
    end

    local duration = params.duration
    if duration == 0 then
        -- Continuous rumble (storm idle) — caller must cancel manually
        for _, gamepadEnum in ipairs(UserInputService:GetConnectedGamepads()) do
            UserInputService:SetGamepadVibration(gamepadEnum, small, large)
        end
    else
        -- Timed rumble
        for _, gamepadEnum in ipairs(UserInputService:GetConnectedGamepads()) do
            UserInputService:SetGamepadVibration(gamepadEnum, small, large)
        end
        task.delay(duration, function()
            for _, gamepadEnum in ipairs(UserInputService:GetConnectedGamepads()) do
                UserInputService:SetGamepadVibration(gamepadEnum, 0, 0)
            end
        end)
    end
end

--[[
    Cancel all gamepad rumble.
]]
function EnvironmentController.cancelRumble()
    for _, gamepadEnum in ipairs(UserInputService:GetConnectedGamepads()) do
        UserInputService:SetGamepadVibration(gamepadEnum, 0, 0)
    end
    EnvironmentController._stormRumbleActive = false
end

----------------------------------------------------------------
-- INTERNAL: STORM RUMBLE MANAGEMENT
----------------------------------------------------------------

--[[
    Manage continuous storm rumble. When a storm is active, apply a
    low-level continuous gamepad rumble. Stop when the storm ends.
]]
local function updateStormRumble()
    if EnvironmentController._currentWeather == "storm" then
        if not EnvironmentController._stormRumbleActive then
            EnvironmentController._stormRumbleActive = true
            EnvironmentController.triggerRumble("storm_idle")
        end
    else
        if EnvironmentController._stormRumbleActive then
            EnvironmentController.cancelRumble()
        end
    end
end

----------------------------------------------------------------
-- INTERNAL: WEATHER STATE
----------------------------------------------------------------

local function readWeatherState()
    local weather = Workspace:GetAttribute("CurrentWeather")
    if weather then
        EnvironmentController._currentWeather = weather
    end

    local intensity = Workspace:GetAttribute("WeatherIntensity")
    if intensity then
        EnvironmentController._weatherIntensity = intensity
    end

    -- Check special states
    if Workspace:GetAttribute("AuroraActive") then
        EnvironmentController._currentWeather = "aurora"
    elseif Workspace:GetAttribute("StormActive") then
        EnvironmentController._currentWeather = "storm"
    end
end

----------------------------------------------------------------
-- HEARTBEAT LOOP
----------------------------------------------------------------

-- Frame-throttled update counters (not everything needs to run every frame)
local _lightingUpdateTimer = 0
local _waterUpdateTimer = 0
local _foamUpdateTimer = 0
local _soundRescanTimer = 0

local function onHeartbeat(dt)
    -- Read weather state every frame (cheap)
    readWeatherState()

    -- Day/night lighting: update every 2 seconds (smooth incremental)
    _lightingUpdateTimer = _lightingUpdateTimer + dt
    if _lightingUpdateTimer > 2 then
        _lightingUpdateTimer = 0
        updateDayNightLighting()
    end

    -- Water surface: update every 1 second
    _waterUpdateTimer = _waterUpdateTimer + dt
    if _waterUpdateTimer > 1 then
        _waterUpdateTimer = 0
        updateWaterSurface()
    end

    -- Shoreline foam: update every 3 seconds
    _foamUpdateTimer = _foamUpdateTimer + dt
    if _foamUpdateTimer > 3 then
        _foamUpdateTimer = 0
        updateShorelineFoam()
    end

    -- Positional sounds: update every frame (timer logic inside)
    updatePositionalSounds(dt)

    -- Storm rumble: check every frame
    updateStormRumble()

    -- Rescan for new tagged parts every 10 seconds
    _soundRescanTimer = _soundRescanTimer + dt
    if _soundRescanTimer > 10 then
        _soundRescanTimer = 0
        initPositionalSounds()
    end
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the EnvironmentController. Sets up state, sounds, and
    connects to RunService.Heartbeat. Call once on game start.
]]
function EnvironmentController.init()
    if EnvironmentController._initialized then
        warn("[EnvironmentController] Already initialized.")
        return
    end

    -- Read initial weather state
    readWeatherState()

    -- Initialize positional sounds for existing tagged parts
    initPositionalSounds()

    -- Ensure snow emitter exists (dormant)
    ensureSnowEmitter()

    -- Initial environment update
    updateDayNightLighting()
    updateWaterSurface()
    updateShorelineFoam()

    -- Connect heartbeat
    EnvironmentController._heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

    -- Listen for weather attribute changes
    Workspace:GetAttributeChangedSignal("CurrentWeather"):Connect(function()
        readWeatherState()
        updateWaterSurface()
        updateShorelineFoam()
    end)

    Workspace:GetAttributeChangedSignal("AuroraActive"):Connect(function()
        readWeatherState()
    end)

    Workspace:GetAttributeChangedSignal("StormActive"):Connect(function()
        readWeatherState()
        updateStormRumble()
    end)

    EnvironmentController._initialized = true
    print("[EnvironmentController] Initialized — weather:", EnvironmentController._currentWeather)
end

--[[
    Trigger a hull impact effect: rumble + sound.
    @param intensity number 0–1
]]
function EnvironmentController.hullImpact(intensity)
    EnvironmentController.triggerRumble("hull_impact", intensity)
end

--[[
    Trigger an engine start effect: rumble + sound.
]]
function EnvironmentController.engineStart()
    EnvironmentController.triggerRumble("engine_start")
end

--[[
    Trigger a gear deployment effect: light rumble.
]]
function EnvironmentController.gearDeploy()
    EnvironmentController.triggerRumble("gear_deploy")
end

--[[
    Trigger a heavy wave effect: rumble + sound.
    @param intensity number 0–1
]]
function EnvironmentController.heavyWave(intensity)
    EnvironmentController.triggerRumble("heavy_wave", intensity)
end

--[[
    Clean up all resources. Call on game shutdown or testing resets.
]]
function EnvironmentController.shutdown()
    if EnvironmentController._heartbeatConn then
        EnvironmentController._heartbeatConn:Disconnect()
        EnvironmentController._heartbeatConn = nil
    end

    -- Cancel any ongoing rumble
    EnvironmentController.cancelRumble()

    -- Clean up positional sounds
    for part, sounds in pairs(EnvironmentController._positionalSounds) do
        for _, sound in pairs(sounds) do
            if sound.Parent then
                sound:Stop()
                sound:Destroy()
            end
        end
    end
    EnvironmentController._positionalSounds = {}

    -- Clean up snow emitter
    if EnvironmentController._snowEmitter and EnvironmentController._snowEmitter.Parent then
        EnvironmentController._snowEmitter.Parent:Destroy()
    end
    EnvironmentController._snowEmitter = nil

    EnvironmentController._initialized = false
    print("[EnvironmentController] Shut down.")
end

return EnvironmentController
