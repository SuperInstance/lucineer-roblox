--[[
    WeatherSystem/init.lua
    Slackwater — Real-Time Weather Simulation

    "Weather is the world's mood engine, straight out of the Southeast:
     fog banks that swallow the float by noon, rain that comes in sideways
     and leaves everything varnished, the rare violent blow that rings the
     storm bell — and, a few nights a season, a sky-wide aurora that stops
     all work in the yard by unwritten law."

    ───────────────────────────────────────────────
    WEATHER STATES (cycle continuously):
      • Clear  (40%) — blue-gray sky, gentle breeze, normal lighting
      • Fog    (25%) — visibility reduced, fog planes intensify
      • Rain   (20%) — particle rain, darker sky, wind up
      • Storm  (10%) — heavy rain, strong wind, lightning, thunder,
                        wave damage to unreinforced shore structures
      • Aurora ( 5%) — night only, green/purple glow, all work stops

    STORM MECHANICS:
      • Wind force on unanchored parts (physics)
      • Wave damage to structures within 20 studs of shore
        (destroyed if not reinforced: stone/metal survives, wood doesn't)
      • Lightning strikes random tall structures
      • The Storm Bell: Earl rings the cannery bell → all NPCs switch
        to emergency work (hauling, lashing, shuttering)
      • Players get assigned ONE critical job during a storm
      • Post-storm: salvage washes up on beach (bonus resources)

    AURORA MECHANICS:
      • Sky-wide green/purple particle effect
      • All ambient sound fades to near-silence, then aurora music enters
      • Lucineer stops whatever he's doing and watches
      • No building, no crafting — the aurora is sacred
      • Players who witness it get "Witnessed the Light" achievement

    API:
        WeatherSystem.init()
        WeatherSystem.getCurrentWeather() -> string
        WeatherSystem.getWeatherIntensity() -> number
        WeatherSystem.forceWeather(type)
        WeatherSystem.onWeatherChange(callback)
        WeatherSystem.isStormActive() -> boolean
        WeatherSystem.isAuroraActive() -> boolean
        WeatherSystem.getWindDirection() -> Vector3
        WeatherSystem.getWindSpeed() -> number
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local WeatherSystem = {}

-- Effects submodule (sibling module)
local Effects = require(script:WaitForChild("Effects"))

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

local WEATHER_TYPES = {
    CLEAR  = "clear",
    FOG    = "fog",
    RAIN   = "rain",
    STORM  = "storm",
    AURORA = "aurora",
}

-- Probability weights for normal weather selection.
-- Aurora is handled separately (night-only, 5%).
local WEATHER_WEIGHTS = {
    clear = 40,
    fog   = 25,
    rain  = 20,
    storm = 10,
}

-- Duration range for each weather state (seconds).
local WEATHER_DURATION = {
    clear  = { min = 180, max = 360 },  -- 3–6 minutes
    fog    = { min = 120, max = 300 },  -- 2–5 minutes
    rain   = { min = 90,  max = 240 },  -- 1.5–4 minutes
    storm  = { min = 60,  max = 150 },  -- 1–2.5 minutes (intense, short)
    aurora = { min = 120, max = 180 },  -- 2–3 minutes (sacred, unhurried)
}

-- Weather intensity values passed to AudioManager.
local WEATHER_AUDIO_INTENSITY = {
    clear  = 0.0,
    fog    = 0.3,
    rain   = 0.5,
    storm  = 0.9,
    aurora = 0.0,  -- silence is the point
}

-- Wind speed ranges per weather state (studs/sec).
local WIND_SPEEDS = {
    clear  = { min = 3,  max = 8   },
    fog    = { min = 1,  max = 4   },
    rain   = { min = 10, max = 20  },
    storm  = { min = 30, max = 55  },
    aurora = { min = 0,  max = 1   },
}

-- Lighting profiles per weather state.
local LIGHTING_PROFILES = {
    clear = {
        FogEnd        = 4000,
        FogColor      = Color3.fromRGB(200, 210, 225),
        FogStart      = 500,
        ClockTime     = 14,
        Brightness    = 2.0,
        Ambient       = Color3.fromRGB(120, 120, 130),
        OutdoorAmbient = Color3.fromRGB(130, 130, 140),
        ColorCorrection_Brightness = 0,
        ColorCorrection_Contrast   = 0,
        ColorCorrection_Saturation = 0,
        ColorCorrection_TintColor  = Color3.fromRGB(255, 255, 255),
    },
    fog = {
        FogEnd        = 300,
        FogColor      = Color3.fromRGB(190, 195, 200),
        FogStart      = 50,
        ClockTime     = 14,
        Brightness    = 1.2,
        Ambient       = Color3.fromRGB(90, 95, 100),
        OutdoorAmbient = Color3.fromRGB(100, 105, 110),
        ColorCorrection_Brightness = -0.05,
        ColorCorrection_Contrast   = -0.1,
        ColorCorrection_Saturation = -0.2,
        ColorCorrection_TintColor  = Color3.fromRGB(220, 225, 235),
    },
    rain = {
        FogEnd        = 800,
        FogColor      = Color3.fromRGB(80, 85, 95),
        FogStart      = 200,
        ClockTime     = 13.5,
        Brightness    = 1.0,
        Ambient       = Color3.fromRGB(70, 75, 85),
        OutdoorAmbient = Color3.fromRGB(80, 85, 95),
        ColorCorrection_Brightness = -0.1,
        ColorCorrection_Contrast   = 0.05,
        ColorCorrection_Saturation = -0.3,
        ColorCorrection_TintColor  = Color3.fromRGB(180, 190, 210),
    },
    storm = {
        FogEnd        = 400,
        FogColor      = Color3.fromRGB(40, 45, 55),
        FogStart      = 80,
        ClockTime     = 12,
        Brightness    = 0.6,
        Ambient       = Color3.fromRGB(50, 52, 60),
        OutdoorAmbient = Color3.fromRGB(55, 58, 68),
        ColorCorrection_Brightness = -0.2,
        ColorCorrection_Contrast   = 0.15,
        ColorCorrection_Saturation = -0.4,
        ColorCorrection_TintColor  = Color3.fromRGB(140, 150, 170),
    },
    aurora = {
        FogEnd        = 6000,
        FogColor      = Color3.fromRGB(10, 15, 30),
        FogStart      = 800,
        ClockTime     = 0,    -- night
        Brightness    = 0.3,
        Ambient       = Color3.fromRGB(20, 30, 45),
        OutdoorAmbient = Color3.fromRGB(25, 35, 55),
        ColorCorrection_Brightness = -0.15,
        ColorCorrection_Contrast   = 0.1,
        ColorCorrection_Saturation = -0.1,
        ColorCorrection_TintColor  = Color3.fromRGB(100, 180, 140), -- green-ish
    },
}

-- Storm configuration
local STORM_CONFIG = {
    waveDamageRadius   = 20,    -- studs from shoreline
    waveDamage         = 40,    -- damage per tick to unreinforced structures
    waveDamageInterval = 5,     -- seconds between damage ticks
    lightningInterval  = { min = 8, max = 20 },  -- seconds between strikes
    lightningDamage    = 50,
    thunderDelayPer100 = 0.3,   -- seconds of delay per 100 studs distance
    reinforcedMaterials = {
        Slate = true, Concrete = true, Brick = true, Cobblestone = true,
        Rock = true, Sand = true, Marble = true, Granite = true,
        Metal = true, DiamondPlate = true, AluminumFoil = true,
        CorrodedMetal = true,
    },
    windForceStrength  = 60,    -- max wind force on unanchored parts
    playerJobs = {
        "batten_down_dock",
        "secure_forge",
        "check_lighthouse",
        "lash_down_salvage",
        "clear_deck",
    },
}

-- INTEGRATION: LucineerBuilt structure damage configuration.
-- These constants control how storms damage player-built structures
-- that were tagged by CommandExecutor via CollectionService.
local STRUCTURE_STORM_CONFIG = {
    -- Damage per wave tick applied to LucineerBuilt structures near shore
    structureWaveDamage    = 25,
    -- At what health fraction does a structure start showing cracks
    crackThreshold         = 0.5,
    -- At what health fraction does a structure start visibly displacing
    displacementThreshold  = 0.3,
    -- How much a damaged structure displaces (studs)
    displacementAmount     = 1.5,
    -- Below this health fraction, a structure collapses (destroyed)
    collapseThreshold      = 0.0,
    -- Structural health multiplier for reinforced builds
    reinforcedHealthMult   = 3.0,
}

-- Aurora configuration
local AURORA_CONFIG = {
    achievementName = "Witnessed the Light",
    buildLockDuration = true,   -- no building/crafting during aurora
    npcStopAll = true,          -- all NPCs stop working
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

WeatherSystem._initialized   = false
WeatherSystem._currentWeather = WEATHER_TYPES.CLEAR
WeatherSystem._previousWeather = WEATHER_TYPES.CLEAR
WeatherSystem._weatherTimer   = 0
WeatherSystem._weatherDuration = 300
WeatherSystem._windDirection  = Vector3.new(1, 0, 0)
WeatherSystem._windSpeed      = 5
WeatherSystem._windTargetSpeed = 5
WeatherSystem._windTargetDir   = Vector3.new(1, 0, 0)
WeatherSystem._windDriftTimer  = 0

WeatherSystem._stormActive     = false
WeatherSystem._auroraActive    = false
WeatherSystem._forced          = false  -- weather is force-set (no auto cycle)

WeatherSystem._lightningTimer  = 0
WeatherSystem._nextLightningAt = 15
WeatherSystem._waveDamageTimer = 0

WeatherSystem._heartbeatConn   = nil
WeatherSystem._colorCorrection = nil
WeatherSystem._onWeatherChangeCallbacks = {}

-- Players who have witnessed an aurora (persisted via attribute)
WeatherSystem._auroraWitnessed = {}

----------------------------------------------------------------
-- INTERNAL: AUDIO HOOK
----------------------------------------------------------------

--[[
    Safely call into AudioManager if it's available.
    AudioManager is expected at ReplicatedStorage.Lucineer.AudioManager.

    INTEGRATION: If AudioManager is missing, we emit a one-shot warning
    (not per-call) so logs aren't spammed. The WeatherSystem fires
    BindableEvents that AudioManager can also listen to as a fallback.
]]
local _audioWarningShown = false

local function getAudioManager()
    local ok, mod = pcall(function()
        return game.ReplicatedStorage:FindFirstChild("Lucineer")
    end)
    if not ok or not mod then
        if not _audioWarningShown then
            warn("[WeatherSystem] ReplicatedStorage.Lucineer not found — audio disabled")
            _audioWarningShown = true
        end
        return nil
    end
    local am = mod:FindFirstChild("AudioManager")
    if not am then
        if not _audioWarningShown then
            warn("[WeatherSystem] AudioManager module not found at ReplicatedStorage.Lucineer.AudioManager")
            _audioWarningShown = true
        end
        return nil
    end
    -- AudioManager is a ModuleScript; require it
    local success, audioMgr = pcall(require, am)
    if success then return audioMgr end
    if not _audioWarningShown then
        warn("[WeatherSystem] Failed to require AudioManager:", audioMgr)
        _audioWarningShown = true
    end
    return nil
end

-- INTEGRATION: Create a BindableEvent for weather audio changes.
-- AudioManager (or any consumer) can listen to this event to react
-- to weather state changes without directly coupling to WeatherSystem.
local weatherAudioEvent = Instance.new("BindableEvent")
weatherAudioEvent.Name = "WeatherAudioChange"
weatherAudioEvent.Parent = script

-- INTEGRATION: Create a BindableEvent for storm damage events.
-- Fires whenever a LucineerBuilt structure takes storm damage, carrying
-- the part, damage amount, and new health. Other systems (UI, salvage,
-- achievements) can listen to this.
local stormDamageEvent = Instance.new("BindableEvent")
stormDamageEvent.Name = "StormDamage"
stormDamageEvent.Parent = script

----------------------------------------------------------------
-- INTERNAL: WEATHER SELECTION
----------------------------------------------------------------

--[[
    Pick the next weather state using weighted random.
    Aurora is only rolled at night (ClockTime < 6 or > 19).
    @return string weather type
]]
local function selectNextWeather()
    local clockTime = Lighting.ClockTime

    -- Roll for aurora: 5% chance, night only, not two in a row
    local isNight = (clockTime < 6 or clockTime > 19)
    if isNight and WeatherSystem._previousWeather ~= WEATHER_TYPES.AURORA then
        if math.random() < 0.05 then
            return WEATHER_TYPES.AURORA
        end
    end

    -- Weighted selection from the non-aurora types
    local totalWeight = 0
    for _, w in pairs(WEATHER_WEIGHTS) do
        totalWeight = totalWeight + w
    end

    local roll = math.random() * totalWeight
    local cumulative = 0
    for weatherType, weight in pairs(WEATHER_WEIGHTS) do
        cumulative = cumulative + weight
        if roll <= cumulative then
            return weatherType
        end
    end

    return WEATHER_TYPES.CLEAR
end

--[[
    Pick a random duration for the given weather state.
    @param weatherType string
    @return number seconds
]]
local function pickDuration(weatherType)
    local range = WEATHER_DURATION[weatherType]
    if not range then return 300 end
    return range.min + math.random() * (range.max - range.min)
end

--[[
    Pick wind parameters for the given weather state.
    Sets the internal target speed and direction.
    @param weatherType string
]]
local function pickWind(weatherType)
    local range = WIND_SPEEDS[weatherType]
    if range then
        WeatherSystem._windTargetSpeed = range.min + math.random() * (range.max - range.min)
    else
        WeatherSystem._windTargetSpeed = 5
    end

    -- Wind direction: mostly from the channel (west/southwest) with variation
    local angle
    if weatherType == WEATHER_TYPES.STORM then
        -- Storms blow hard from a consistent direction
        angle = math.rad(200 + math.random(-30, 30))
    elseif weatherType == WEATHER_TYPES.AURORA then
        angle = math.rad(math.random(0, 360))
    else
        angle = math.rad(240 + math.random(-60, 60))
    end
    WeatherSystem._windTargetDir = Vector3.new(math.cos(angle), 0, math.sin(angle)).Unit
end

----------------------------------------------------------------
-- INTERNAL: LIGHTING TRANSITION
----------------------------------------------------------------

--[[
    Smoothly transition Lighting properties to a target profile.
    Uses TweenService for Color/Brightness values; instant for Fog
    since Lighting fog tweens can be jittery.
    @param profile table from LIGHTING_PROFILES
    @param tweenTime number seconds
]]
local function transitionLighting(profile, tweenTime)
    tweenTime = tweenTime or 3.0

    -- Ensure we have a ColorCorrectionEffect
    if not WeatherSystem._colorCorrection then
        WeatherSystem._colorCorrection = Lighting:FindFirstChild("__WeatherColorCorrection")
        if not WeatherSystem._colorCorrection then
            WeatherSystem._colorCorrection = Instance.new("ColorCorrectionEffect")
            WeatherSystem._colorCorrection.Name = "__WeatherColorCorrection"
            WeatherSystem._colorCorrection.Parent = Lighting
        end
    end

    local cc = WeatherSystem._colorCorrection
    local ti = TweenInfo.new(tweenTime, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

    -- Tween Lighting properties
    TweenService:Create(Lighting, ti, {
        Brightness     = profile.Brightness,
        Ambient        = profile.Ambient,
        OutdoorAmbient = profile.OutdoorAmbient,
        ClockTime      = profile.ClockTime,
    }):Play()

    -- Tween fog separately (shorter time for atmosphere snap)
    local fogTI = TweenInfo.new(tweenTime * 0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
    TweenService:Create(Lighting, fogTI, {
        FogEnd   = profile.FogEnd,
        FogStart = profile.FogStart,
        FogColor = profile.FogColor,
    }):Play()

    -- Tween ColorCorrection
    TweenService:Create(cc, ti, {
        Brightness  = profile.ColorCorrection_Brightness,
        Contrast    = profile.ColorCorrection_Contrast,
        Saturation  = profile.ColorCorrection_Saturation,
        TintColor   = profile.ColorCorrection_TintColor,
    }):Play()
end

----------------------------------------------------------------
-- INTERNAL: STORM MECHANICS
----------------------------------------------------------------

--[[
    Apply wind force to all unanchored parts in the workspace.
    Called every physics step during storms.
    @param dt number delta time
]]
local function applyWindForce(dt)
    if not WeatherSystem._stormActive then return end

    local force = WeatherSystem._windDirection * WeatherSystem._windSpeed * STORM_CONFIG.windForceStrength * dt
    local magnitude = force.Magnitude
    if magnitude < 0.01 then return end

    -- Only apply to unanchored parts tagged as "WeatherAffected" or
    -- that are small enough to be blown around.
    local parts = CollectionService:GetTagged("WeatherAffected")
    for _, part in ipairs(parts) do
        if part:IsA("BasePart") and not part.Anchored then
            part:ApplyImpulse(force * (part.AssemblyMass))
        end
    end
end

--[[
    Apply wave damage to structures near the shoreline.
    Unreinforced structures (wood, fabric, etc.) take damage.
    Reinforced structures (stone, metal) are immune.
]]
local function applyWaveDamage()
    local audioMgr = getAudioManager()
    local waterLevel = 0
    -- Try to read water level from TideSystem
    local tideSystem = Workspace:FindFirstChild("__TideSystem")
    if tideSystem and tideSystem:GetAttribute("WaterLevel") then
        waterLevel = tideSystem:GetAttribute("WaterLevel")
    end

    local structures = CollectionService:GetTagged("Structure")
    for _, structure in ipairs(structures) do
        if structure:IsA("Model") and structure.PrimaryPart then
            local pos = structure.PrimaryPart.Position
            local heightDiff = math.abs(pos.Y - waterLevel)
            if heightDiff <= STORM_CONFIG.waveDamageRadius then

                -- Check if the structure is reinforced
                local isReinforced = structure:GetAttribute("Reinforced") or false
                if not isReinforced then
                    -- Check material of PrimaryPart
                    local mat = structure.PrimaryPart.Material
                    if STORM_CONFIG.reinforcedMaterials[mat.Name] then
                        isReinforced = true
                    end
                end

                if not isReinforced then
                    -- Apply damage
                    local currentHealth = structure:GetAttribute("Health")
                    local maxHealth = structure:GetAttribute("MaxHealth")
                    if currentHealth and maxHealth then
                        local newHealth = math.max(0, currentHealth - STORM_CONFIG.waveDamage)
                        structure:SetAttribute("Health", newHealth)

                        if newHealth <= 0 then
                            structure:SetAttribute("Destroyed", true)
                            local destroyEvent = structure:FindFirstChild("OnDestroyed")
                            if destroyEvent and destroyEvent:IsA("BindableEvent") then
                                destroyEvent:Fire()
                            end
                            -- Visual: debris
                            Effects.spawnDebris(pos)
                        end
                    end
                end
            end
        end
    end
end

--[[
    Trigger a lightning strike on a random tall structure or point.
    Spawns visual effect + thunder sound (delayed by distance).
]]
local function triggerLightning()
    -- Find candidate strike points: tall structures or random points near the yard
    local strikePoint
    local strikeHeight = 0

    local structures = CollectionService:GetTagged("Structure")
    for _, structure in ipairs(structures) do
        if structure:IsA("Model") and structure.PrimaryPart then
            local pos = structure.PrimaryPart.Position
            if pos.Y > strikeHeight then
                -- Weighted random: 60% chance to pick a taller structure
                if math.random() < 0.6 or strikeHeight == 0 then
                    strikePoint = pos
                    strikeHeight = pos.Y
                end
            end
        end
    end

    -- Fallback: random point near world origin (the yard center)
    if not strikePoint then
        strikePoint = Vector3.new(math.random(-50, 50), 50, math.random(-50, 50))
    end

    -- Trigger the visual lightning effect
    Effects.spawnLightning(strikePoint)

    -- Thunder: delayed based on distance from yard center
    local distanceFromCenter = (Vector3.new(strikePoint.X, 0, strikePoint.Z) - Vector3.new(0, 0, 0)).Magnitude
    local thunderDelay = 2 + (distanceFromCenter / 100) * STORM_CONFIG.thunderDelayPer100 * 10
    thunderDelay = math.clamp(thunderDelay, 2, 5)

    task.delay(thunderDelay, function()
        Effects.playThunder(strikePoint)
    end)

    -- Apply lightning damage if we hit a structure
    for _, structure in ipairs(structures) do
        if structure:IsA("Model") and structure.PrimaryPart then
            if (structure.PrimaryPart.Position - strikePoint).Magnitude < 8 then
                local currentHealth = structure:GetAttribute("Health")
                if currentHealth then
                    structure:SetAttribute("Health", math.max(0, currentHealth - STORM_CONFIG.lightningDamage))
                end
                break
            end
        end
    end
end

--[[
    The Storm Bell: ring the cannery bell.
    Signals all NPCs to switch to emergency work and assigns players jobs.
    This is the Magic Moment #6 from the Character Bible.
]]
local function ringStormBell()
    -- Find the bell in workspace
    local bell = Workspace:FindFirstChild("StormBell", true)
    if not bell then
        -- Create a signal via attribute so NPCManager can pick it up
        Workspace:SetAttribute("StormBellRinging", true)
    else
        bell:SetAttribute("Ringing", true)
    end

    -- Signal NPC system
    Workspace:SetAttribute("StormActive", true)

    -- Assign each present player ONE critical job
    local Players = game:GetService("Players")
    local jobs = STORM_CONFIG.playerJobs
    local jobIndex = 1

    for _, player in ipairs(Players:GetPlayers()) do
        local job = jobs[jobIndex]
        player:SetAttribute("StormJob", job)
        jobIndex = jobIndex + 1
        if jobIndex > #jobs then jobIndex = 1 end
    end

    -- Bell sound
    local bellSound = Instance.new("Sound")
    bellSound.SoundId = "rbxassetid://9118858002"
    bellSound.Volume = 0.8
    bellSound.PlaybackSpeed = 0.7
    bellSound.Parent = Workspace
    bellSound:Play()
    game:GetService("Debris"):AddItem(bellSound, 5)

    -- Stop bell ringing after storm
    task.delay(WeatherSystem._weatherDuration, function()
        Workspace:SetAttribute("StormBellRinging", false)
        Workspace:SetAttribute("StormActive", false)
        for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
            player:SetAttribute("StormJob", nil)
        end
    end)
end

--[[
    Post-storm: spawn salvage on the beach.
    Calls into Resources/TideSystem if available, otherwise spawns basic parts.
]]
local function spawnPostStormSalvage()
    local beach = Workspace:FindFirstChild("BeachSalvage", true)
    local salvageCount = math.random(3, 7)

    for i = 1, salvageCount do
        local part = Instance.new("Part")
        part.Name = "StormSalvage"
        part.Size = Vector3.new(math.random(1, 3), math.random(1, 2), math.random(1, 3))
        part.Position = Vector3.new(
            math.random(-60, 60),
            2,
            math.random(-40, -20)  -- beach area (negative Z toward water)
        )
        part.Material = Enum.Material.Slate
        part.Color = Color3.fromRGB(140, 120, 80)
        part.Anchored = true
        part.Parent = Workspace

        -- Tag it as salvageable
        CollectionService:AddTag(part, "Salvage")
        part:SetAttribute("SalvageType", "storm")
        part:SetAttribute("Yield", math.random(2, 5))

        -- Add a collection tag so TideSystem or Resources can manage it
        if beach then
            part.Parent = beach
        end
    end

    print("[WeatherSystem] Post-storm salvage spawned:", salvageCount, "items")
end

----------------------------------------------------------------
-- INTERNAL: AURORA MECHANICS
----------------------------------------------------------------

--[[
    Begin aurora: stop all work, fade ambient, start aurora effects.
]]
local function beginAurora()
    WeatherSystem._auroraActive = true

    -- Signal all NPCs to stop
    Workspace:SetAttribute("AuroraActive", true)

    -- Signal build system to pause crafting
    Workspace:SetAttribute("BuildLocked", true)

    -- Fade ambient sound to near-silence via AudioManager
    local audioMgr = getAudioManager()
    if audioMgr then
        audioMgr.setGroupVolume("ambient", 0.05)
        audioMgr.setMusic("aurora")
        audioMgr.setWeatherIntensity(0.0)
    end

    -- Start visual aurora effects
    Effects.startAurora()

    -- Grant achievement to all present players
    local Players = game:GetService("Players")
    for _, player in ipairs(Players:GetPlayers()) do
        local alreadySeen = WeatherSystem._auroraWitnessed[player.UserId]
        if not alreadySeen then
            WeatherSystem._auroraWitnessed[player.UserId] = true
            player:SetAttribute("AuroraWitnessed", true)

            -- Fire achievement
            local achievementSystem = Workspace:FindFirstChild("AchievementManager")
            if achievementSystem then
                achievementSystem:SetAttribute("GrantAchievement", player.UserId .. ":" .. AURORA_CONFIG.achievementName)
            end

            -- Direct UI sound
            if audioMgr then
                audioMgr.playUi("achievement")
            end
        end
    end

    print("[WeatherSystem] 🌌 Aurora began. All work stops.")
end

--[[
    End aurora: resume normal operations.
]]
local function endAurora()
    WeatherSystem._auroraActive = false

    Workspace:SetAttribute("AuroraActive", false)
    Workspace:SetAttribute("BuildLocked", false)

    -- Restore ambient and music
    local audioMgr = getAudioManager()
    if audioMgr then
        audioMgr.setGroupVolume("ambient", 1.0)
        audioMgr.setMusic("hub")
    end

    Effects.stopAurora()

    print("[WeatherSystem] Aurora ended. The yard resumes.")
end

----------------------------------------------------------------
-- INTERNAL: WEATHER STATE TRANSITION
----------------------------------------------------------------

--[[
    Transition to a new weather state.
    Handles all setup: lighting, audio, effects, callbacks.
    @param newWeather string weather type
    @param tweenTime number transition duration (seconds)
]]
local function transitionToWeather(newWeather, tweenTime)
    tweenTime = tweenTime or 4.0

    WeatherSystem._previousWeather = WeatherSystem._currentWeather
    WeatherSystem._currentWeather = newWeather

    -- End previous weather effects
    if WeatherSystem._previousWeather == WEATHER_TYPES.AURORA then
        endAurora()
    elseif WeatherSystem._previousWeather == WEATHER_TYPES.STORM then
        WeatherSystem._stormActive = false
        Workspace:SetAttribute("StormActive", false)
        Effects.stopRain()
        Effects.stopStormSky()
        -- Post-storm salvage
        spawnPostStormSalvage()
    elseif WeatherSystem._previousWeather == WEATHER_TYPES.RAIN then
        Effects.stopRain()
    elseif WeatherSystem._previousWeather == WEATHER_TYPES.FOG then
        Effects.setFogIntensity(0.0)
    end

    -- Setup new weather
    local profile = LIGHTING_PROFILES[newWeather]
    if profile then
        transitionLighting(profile, tweenTime)
    end

    -- Pick wind for the new weather
    pickWind(newWeather)

    -- Weather-specific setup
    if newWeather == WEATHER_TYPES.CLEAR then
        Effects.setFogIntensity(0.0)
        local audioMgr = getAudioManager()
        if audioMgr then
            audioMgr.setWeatherIntensity(WEATHER_AUDIO_INTENSITY.clear)
            audioMgr.setMusic("hub")
        end

    elseif newWeather == WEATHER_TYPES.FOG then
        Effects.setFogIntensity(0.6)
        local audioMgr = getAudioManager()
        if audioMgr then
            audioMgr.setWeatherIntensity(WEATHER_AUDIO_INTENSITY.fog)
            audioMgr.setMusic("hub")
        end

    elseif newWeather == WEATHER_TYPES.RAIN then
        Effects.startRain(0.5)
        local audioMgr = getAudioManager()
        if audioMgr then
            audioMgr.setWeatherIntensity(WEATHER_AUDIO_INTENSITY.rain)
            audioMgr.setMusic("hub")
        end

    elseif newWeather == WEATHER_TYPES.STORM then
        WeatherSystem._stormActive = true
        Effects.startRain(1.0)
        Effects.startStormSky()
        local audioMgr = getAudioManager()
        if audioMgr then
            audioMgr.setWeatherIntensity(WEATHER_AUDIO_INTENSITY.storm)
            audioMgr.setMusic("storm")
        end

        -- Ring the Storm Bell
        ringStormBell()

        -- Reset lightning timer
        WeatherSystem._lightningTimer = 0
        WeatherSystem._nextLightningAt = STORM_CONFIG.lightningInterval.min +
            math.random() * (STORM_CONFIG.lightningInterval.max - STORM_CONFIG.lightningInterval.min)

        -- Reset wave damage timer
        WeatherSystem._waveDamageTimer = 0

    elseif newWeather == WEATHER_TYPES.AURORA then
        beginAurora()
    end

    -- Fire callbacks
    for _, cb in ipairs(WeatherSystem._onWeatherChangeCallbacks) do
        local ok, err = pcall(cb, newWeather, WeatherSystem._previousWeather)
        if not ok then
            warn("[WeatherSystem] Weather change callback error:", err)
        end
    end

    print(string.format("[WeatherSystem] Weather: %s → %s (duration: %.0fs)",
        WeatherSystem._previousWeather, newWeather, WeatherSystem._weatherDuration))
end

----------------------------------------------------------------
-- HEARTBEAT UPDATE
----------------------------------------------------------------

local function onHeartbeat(dt)
    -- Skip if not initialized
    if not WeatherSystem._initialized then return end

    -- Timer countdown (skip if forced)
    if not WeatherSystem._forced then
        WeatherSystem._weatherTimer = WeatherSystem._weatherTimer + dt

        if WeatherSystem._weatherTimer >= WeatherSystem._weatherDuration then
            WeatherSystem._weatherTimer = 0
            local nextWeather = selectNextWeather()
            WeatherSystem._weatherDuration = pickDuration(nextWeather)
            transitionToWeather(nextWeather)
            return
        end
    end

    -- Smoothly interpolate wind speed toward target
    WeatherSystem._windSpeed = WeatherSystem._windSpeed +
        (WeatherSystem._windTargetSpeed - WeatherSystem._windSpeed) * dt * 0.5

    -- Smoothly interpolate wind direction toward target
    WeatherSystem._windDirection = WeatherSystem._windDirection:Lerp(
        WeatherSystem._windTargetDir, dt * 0.3
    )
    if WeatherSystem._windDirection.Magnitude > 0.01 then
        WeatherSystem._windDirection = WeatherSystem._windDirection.Unit
    end

    -- Periodic wind direction drift
    WeatherSystem._windDriftTimer = WeatherSystem._windDriftTimer + dt
    if WeatherSystem._windDriftTimer > 10 then
        WeatherSystem._windDriftTimer = 0
        local angle = math.atan2(WeatherSystem._windTargetDir.Z, WeatherSystem._windTargetDir.X)
        angle = angle + math.rad(math.random(-15, 15))
        WeatherSystem._windTargetDir = Vector3.new(math.cos(angle), 0, math.sin(angle)).Unit
    end

    -- Storm mechanics
    if WeatherSystem._stormActive then
        -- Apply wind force
        applyWindForce(dt)

        -- Wave damage tick
        WeatherSystem._waveDamageTimer = WeatherSystem._waveDamageTimer + dt
        if WeatherSystem._waveDamageTimer >= STORM_CONFIG.waveDamageInterval then
            WeatherSystem._waveDamageTimer = 0
            applyWaveDamage()
        end

        -- Lightning strikes
        WeatherSystem._lightningTimer = WeatherSystem._lightningTimer + dt
        if WeatherSystem._lightningTimer >= WeatherSystem._nextLightningAt then
            WeatherSystem._lightningTimer = 0
            triggerLightning()
            WeatherSystem._nextLightningAt = STORM_CONFIG.lightningInterval.min +
                math.random() * (STORM_CONFIG.lightningInterval.max - STORM_CONFIG.lightningInterval.min)
        end
    end

    -- Update rain angle based on wind
    if WeatherSystem._currentWeather == WEATHER_TYPES.RAIN
    or WeatherSystem._currentWeather == WEATHER_TYPES.STORM then
        Effects.updateRainAngle(WeatherSystem._windDirection, WeatherSystem._windSpeed)
    end
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the weather system. Sets up initial weather state,
    lighting profile, and connects to RunService.Heartbeat.
    Call once on game start.
]]
function WeatherSystem.init()
    if WeatherSystem._initialized then
        warn("[WeatherSystem] Already initialized.")
        return
    end

    -- Start with clear weather
    WeatherSystem._currentWeather = WEATHER_TYPES.CLEAR
    WeatherSystem._previousWeather = WEATHER_TYPES.CLEAR
    WeatherSystem._weatherTimer = 0
    WeatherSystem._weatherDuration = pickDuration(WEATHER_TYPES.CLEAR)
    WeatherSystem._stormActive = false
    WeatherSystem._auroraActive = false
    WeatherSystem._forced = false

    -- Initialize wind
    pickWind(WEATHER_TYPES.CLEAR)
    WeatherSystem._windSpeed = WeatherSystem._windTargetSpeed
    WeatherSystem._windDirection = WeatherSystem._windTargetDir

    -- Apply initial lighting profile
    local profile = LIGHTING_PROFILES[WEATHER_TYPES.CLEAR]
    transitionLighting(profile, 2.0)

    -- Initialize effects
    Effects.init()

    -- Connect heartbeat
    WeatherSystem._heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

    -- Set workspace attributes for other systems
    Workspace:SetAttribute("StormActive", false)
    Workspace:SetAttribute("AuroraActive", false)
    Workspace:SetAttribute("BuildLocked", false)

    WeatherSystem._initialized = true
    print("[WeatherSystem] Initialized. Starting weather: clear")
end

--[[
    Get the current weather type.
    @return string — "clear", "fog", "rain", "storm", or "aurora"
]]
function WeatherSystem.getCurrentWeather()
    return WeatherSystem._currentWeather
end

--[[
    Get the weather intensity (0–1), used by AudioManager and visual systems.
    @return number
]]
function WeatherSystem.getWeatherIntensity()
    return WEATHER_AUDIO_INTENSITY[WeatherSystem._currentWeather] or 0
end

--[[
    Force a specific weather type. Disables automatic cycling until
    WeatherSystem.forceWeather(nil) is called.
    @param weatherType string|nil — force to this type, or nil to resume auto-cycle
]]
function WeatherSystem.forceWeather(weatherType)
    if weatherType == nil then
        WeatherSystem._forced = false
        WeatherSystem._weatherTimer = 0
        WeatherSystem._weatherDuration = pickDuration(WeatherSystem._currentWeather)
        print("[WeatherSystem] Auto-cycle resumed.")
        return
    end

    weatherType = string.lower(weatherType)
    if not WEATHER_AUDIO_INTENSITY[weatherType] and weatherType ~= WEATHER_TYPES.CLEAR then
        warn("[WeatherSystem] Unknown weather type:", weatherType)
        return
    end

    WeatherSystem._forced = true
    WeatherSystem._weatherTimer = 0
    WeatherSystem._weatherDuration = pickDuration(weatherType)
    transitionToWeather(weatherType, 2.0)
end

--[[
    Register a callback fired when weather changes.
    @param callback function(newWeather, previousWeather)
]]
function WeatherSystem.onWeatherChange(callback)
    table.insert(WeatherSystem._onWeatherChangeCallbacks, callback)
end

--[[
    Is a storm currently active?
    @return boolean
]]
function WeatherSystem.isStormActive()
    return WeatherSystem._stormActive
end

--[[
    Is an aurora currently active?
    @return boolean
]]
function WeatherSystem.isAuroraActive()
    return WeatherSystem._auroraActive
end

--[[
    Get the current wind direction (unit vector, XZ plane).
    @return Vector3
]]
function WeatherSystem.getWindDirection()
    return WeatherSystem._windDirection
end

--[[
    Get the current wind speed in studs/sec.
    @return number
]]
function WeatherSystem.getWindSpeed()
    return WeatherSystem._windSpeed
end

--[[
    Serialize weather state for persistence.
    @return table
]]
function WeatherSystem.serialize()
    return {
        currentWeather  = WeatherSystem._currentWeather,
        previousWeather = WeatherSystem._previousWeather,
        weatherTimer    = WeatherSystem._weatherTimer,
        weatherDuration = WeatherSystem._weatherDuration,
        stormActive     = WeatherSystem._stormActive,
        auroraActive    = WeatherSystem._auroraActive,
        windSpeed       = WeatherSystem._windSpeed,
        windDirX        = WeatherSystem._windDirection.X,
        windDirZ        = WeatherSystem._windDirection.Z,
        forced          = WeatherSystem._forced,
        auroraWitnessed = WeatherSystem._auroraWitnessed,
    }
end

--[[
    Restore weather state from saved data.
    @param data table
]]
function WeatherSystem.deserialize(data)
    if not data then return end
    WeatherSystem._currentWeather  = data.currentWeather or WEATHER_TYPES.CLEAR
    WeatherSystem._previousWeather = data.previousWeather or WEATHER_TYPES.CLEAR
    WeatherSystem._weatherTimer    = data.weatherTimer or 0
    WeatherSystem._weatherDuration = data.weatherDuration or 300
    WeatherSystem._stormActive     = data.stormActive or false
    WeatherSystem._auroraActive    = data.auroraActive or false
    WeatherSystem._windSpeed       = data.windSpeed or 5
    WeatherSystem._windDirection   = Vector3.new(data.windDirX or 1, 0, data.windDirZ or 0)
    WeatherSystem._forced          = data.forced or false
    WeatherSystem._auroraWitnessed = data.auroraWitnessed or {}

    -- Re-apply visual state
    local profile = LIGHTING_PROFILES[WeatherSystem._currentWeather]
    if profile then
        transitionLighting(profile, 1.0)
    end

    if WeatherSystem._currentWeather == WEATHER_TYPES.STORM then
        Effects.startRain(1.0)
        Effects.startStormSky()
    elseif WeatherSystem._currentWeather == WEATHER_TYPES.RAIN then
        Effects.startRain(0.5)
    elseif WeatherSystem._currentWeather == WEATHER_TYPES.FOG then
        Effects.setFogIntensity(0.6)
    elseif WeatherSystem._currentWeather == WEATHER_TYPES.AURORA then
        Effects.startAurora()
    end
end

return WeatherSystem
