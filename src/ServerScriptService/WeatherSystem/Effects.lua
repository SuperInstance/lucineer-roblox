--[[
    WeatherSystem/Effects.lua
    Slackwater — Weather Visual & Audio Effects

    "Fog banks that swallow the float by noon, rain that comes in
     sideways and leaves everything varnished, the rare violent blow
     that rings the storm bell."

    All visual effect systems for the WeatherSystem:
      • Rain — ParticleEmitter sky-dome with wind-angled falling
      • Fog  — Translucent gray edge planes that intensify/dissipate
      • Lightning — Full-bright flash + Neon beam from sky to strike point
      • Thunder — Delayed 3D positioned sound based on strike distance
      • Aurora — ColorCorrection green/purple shift + sky particle ribbons
      • Storm Sky — Darker ClockTime, increased fog, dramatic mood
      • Debris — Spawn small broken parts when structures are destroyed

    All effects are created/destroyed on demand. The module keeps
    references to persistent effect containers and cleans them up
    on stop calls.

    API:
        Effects.init()
        Effects.startRain(intensity)   -- 0.0–1.0
        Effects.stopRain()
        Effects.updateRainAngle(windDir, windSpeed)
        Effects.setFogIntensity(level) -- 0.0–1.0
        Effects.startStormSky()
        Effects.stopStormSky()
        Effects.spawnLightning(strikePoint)
        Effects.playThunder(position)
        Effects.startAurora()
        Effects.stopAurora()
        Effects.spawnDebris(position)
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local Effects = {}

----------------------------------------------------------------
-- STATE / REFERENCES
----------------------------------------------------------------

Effects._initialized     = false

-- Rain
Effects._rainContainer   = nil  -- Part holding ParticleEmitters
Effects._rainEmitter     = nil
Effects._rainIntensity   = 0    -- current target intensity (0/0.5/1.0)

-- Fog
Effects._fogPlanes       = nil  -- Folder of edge fog parts
Effects._fogIntensity    = 0

-- Storm sky
Effects._stormSkyActive  = false
Effects._stormColorCorrection = nil

-- Aurora
Effects._auroraActive    = false
Effects._auroraParticles = nil  -- Part holding aurora particle emitters
Effects._auroraCC        = nil  -- ColorCorrectionEffect for aurora
Effects._auroraBlur      = nil  -- BlurEffect for aurora softness

-- Thunder sound IDs (free assets)
local THUNDER_SOUNDS = {
    "rbxassetid://540321734",
    "rbxassetid://540321742",
    "rbxassetid://540321751",
}

-- Rain particle configuration
local RAIN_PARTICLE = {
    texture = "rbxassetid://3787172071",  -- rain drop texture
    rate = 0,
    lifetime = 2.5,
    speed = 50,
    spreadAngleX = 5,
    spreadAngleY = 5,
    rotation = 0,
    size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.5),
        NumberSequenceKeypoint.new(1, 0.8),
    }),
    transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(1, 0.5),
    }),
    color = ColorSequence.new(Color3.fromRGB(180, 200, 230)),
    acceleration = Vector3.new(0, -30, 0),  -- gravity bias
}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

--[[
    Safely tween a property on an instance.
]]
local function tween(instance, duration, props, style)
    style = style or Enum.EasingStyle.Sine
    local ti = TweenInfo.new(duration, style, Enum.EasingDirection.Out)
    local t = TweenService:Create(instance, ti, props)
    t:Play()
    return t
end

--[[
    Find or create a container folder under Workspace.
]]
local function ensureFolder(name)
    local folder = Workspace:FindFirstChild(name)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = name
        folder.Parent = Workspace
    end
    return folder
end

----------------------------------------------------------------
-- RAIN
----------------------------------------------------------------

--[[
    Create the rain container (a large invisible part above the map
    that holds ParticleEmitters). The part follows the world origin.
]]
local function createRainContainer()
    if Effects._rainContainer then return Effects._rainContainer end

    local part = Instance.new("Part")
    part.Name = "__RainDome"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.Material = Enum.Material.Air
    part.Size = Vector3.new(1024, 1, 1024)
    part.Position = Vector3.new(0, 200, 0)
    part.Parent = Workspace

    -- Create the rain ParticleEmitter
    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = "RainEmitter"
    emitter.Texture = RAIN_PARTICLE.texture
    emitter.Lifetime = NumberRange.new(RAIN_PARTICLE.lifetime, RAIN_PARTICLE.lifetime * 1.3)
    emitter.Speed = NumberRange.new(RAIN_PARTICLE.speed, RAIN_PARTICLE.speed * 1.2)
    emitter.SpreadAngle = Vector2.new(RAIN_PARTICLE.spreadAngleX, RAIN_PARTICLE.spreadAngleY)
    emitter.Rotation = NumberRange.new(0, 360)
    emitter.RotSpeed = NumberRange.new(0, 0)
    emitter.Size = RAIN_PARTICLE.size
    emitter.Transparency = RAIN_PARTICLE.transparency
    emitter.Color = RAIN_PARTICLE.color
    emitter.Acceleration = RAIN_PARTICLE.acceleration
    emitter.Rate = 0  -- starts dormant
    emitter.Parent = part

    Effects._rainContainer = part
    Effects._rainEmitter = emitter
    return part
end

--[[
    Start rain at a given intensity level.
    @param intensity number 0.0–1.0 (0.5 = rain, 1.0 = storm)
]]
function Effects.startRain(intensity)
    intensity = math.clamp(intensity, 0, 1)
    Effects._rainIntensity = intensity

    if not Effects._rainContainer then
        createRainContainer()
    end

    -- Particle rate scales with intensity
    -- Rain: ~80 particles/sec, Storm: ~200 particles/sec
    local targetRate = intensity * 200

    -- Smoothly tween the rate
    local currentRate = Effects._rainEmitter.Rate
    Effects._rainEmitter.Rate = targetRate  -- ParticleEmitter.Rate isn't tweenable, set directly

    -- Size/speed scale slightly with storm intensity
    if intensity >= 0.9 then
        Effects._rainEmitter.Speed = NumberRange.new(70, 90)
        Effects._rainEmitter.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.6),
            NumberSequenceKeypoint.new(1, 1.2),
        })
    else
        Effects._rainEmitter.Speed = NumberRange.new(40, 55)
        Effects._rainEmitter.Size = RAIN_PARTICLE.size
    end
end

--[[
    Stop rain entirely.
]]
function Effects.stopRain()
    Effects._rainIntensity = 0
    if Effects._rainEmitter then
        Effects._rainEmitter.Rate = 0
    end
    -- Keep the container around for quick restart (cleaned up on shutdown)
end

--[[
    Update the rain particle angle/acceleration based on wind.
    @param windDir Vector3 unit direction
    @param windSpeed number studs/sec
]]
function Effects.updateRainAngle(windDir, windSpeed)
    if not Effects._rainEmitter then return end

    -- Calculate the horizontal acceleration from wind.
    -- Stronger wind = more slanted rain.
    local windFactor = math.clamp(windSpeed / 50, 0, 1)
    local horizontalAccel = windDir * (windFactor * 25)

    Effects._rainEmitter.Acceleration = Vector3.new(
        horizontalAccel.X,
        -30,
        horizontalAccel.Z
    )

    -- Rotate the emitter's emission to lean with the wind
    -- SpreadAngle can't fully control direction, so we use the
    -- emitter's parent part orientation as a proxy. We rotate
    -- the rain dome slightly.
    if Effects._rainContainer then
        local targetTilt = windFactor * math.rad(20)
        local yaw = math.atan2(windDir.X, windDir.Z)
        Effects._rainContainer.CFrame = CFrame.new(0, 200, 0)
            * CFrame.Angles(math.cos(yaw) * targetTilt, yaw, math.sin(yaw) * targetTilt)
    end
end

----------------------------------------------------------------
-- FOG (EDGE PLANES)
----------------------------------------------------------------

--[[
    Create or retrieve the fog plane folder.
    Fog planes are translucent gray parts placed at the world edges
    that become more opaque during fog/storm weather.
]]
local function createFogPlanes()
    if Effects._fogPlanes then return Effects._fogPlanes end

    local folder = ensureFolder("__WeatherFogPlanes")
    Effects._fogPlanes = folder

    -- Create 4 edge planes (N, S, E, W) around the island
    local edgeDistance = 350
    local planeSize = 700
    local height = 100

    local directions = {
        { pos = Vector3.new(0, height / 2, -edgeDistance), size = Vector3.new(planeSize, height, 10), name = "FogSouth" },
        { pos = Vector3.new(0, height / 2, edgeDistance),  size = Vector3.new(planeSize, height, 10), name = "FogNorth" },
        { pos = Vector3.new(-edgeDistance, height / 2, 0), size = Vector3.new(10, height, planeSize), name = "FogWest"  },
        { pos = Vector3.new(edgeDistance, height / 2, 0),  size = Vector3.new(10, height, planeSize), name = "FogEast"  },
    }

    for _, dir in ipairs(directions) do
        local plane = Instance.new("Part")
        plane.Name = dir.name
        plane.Anchored = true
        plane.CanCollide = false
        plane.CanQuery = false
        plane.CanTouch = false
        plane.Material = Enum.Material.SmoothPlastic
        plane.Transparency = 1  -- invisible at intensity 0
        plane.Color = Color3.fromRGB(190, 195, 200)
        plane.Size = dir.size
        plane.Position = dir.pos
        plane.Parent = folder
    end

    return folder
end

--[[
    Set fog edge plane intensity.
    @param level number 0.0–1.0 (0 = invisible, 1 = thick)
]]
function Effects.setFogIntensity(level)
    level = math.clamp(level, 0, 1)
    Effects._fogIntensity = level

    if not Effects._fogPlanes then
        createFogPlanes()
    end

    -- Transparency: 1.0 = invisible, 0.3 = thick
    local targetTransparency = 1.0 - (level * 0.7)

    for _, plane in ipairs(Effects._fogPlanes:GetChildren()) do
        if plane:IsA("BasePart") then
            tween(plane, 3.0, { Transparency = targetTransparency })
        end
    end
end

----------------------------------------------------------------
-- STORM SKY
----------------------------------------------------------------

--[[
    Activate storm sky: darker ClockTime, increased fog,
    dramatic ColorCorrection.
    The ClockTime is managed by the WeatherSystem lighting profiles,
    but we add an extra ColorCorrection here for storm-specific drama.
]]
function Effects.startStormSky()
    if Effects._stormSkyActive then return end
    Effects._stormSkyActive = true

    -- Create or retrieve storm ColorCorrection
    if not Effects._stormColorCorrection then
        local existing = Lighting:FindFirstChild("__StormColorCorrection")
        if existing then
            Effects._stormColorCorrection = existing
        else
            Effects._stormColorCorrection = Instance.new("ColorCorrectionEffect")
            Effects._stormColorCorrection.Name = "__StormColorCorrection"
            Effects._stormColorCorrection.Brightness = 0
            Effects._stormColorCorrection.Contrast = 0
            Effects._stormColorCorrection.Saturation = 0
            Effects._stormColorCorrection.TintColor = Color3.fromRGB(255, 255, 255)
            Effects._stormColorCorrection.Parent = Lighting
        end
    end

    tween(Effects._stormColorCorrection, 3.0, {
        Contrast = 0.1,
        Saturation = -0.15,
        TintColor = Color3.fromRGB(150, 160, 180),
    })

    -- Intensify fog planes during storm
    Effects.setFogIntensity(0.8)
end

--[[
    Deactivate storm sky, restore normal ColorCorrection.
]]
function Effects.stopStormSky()
    if not Effects._stormSkyActive then return end
    Effects._stormSkyActive = false

    if Effects._stormColorCorrection then
        tween(Effects._stormColorCorrection, 4.0, {
            Contrast = 0,
            Saturation = 0,
            TintColor = Color3.fromRGB(255, 255, 255),
        })
    end
end

----------------------------------------------------------------
-- LIGHTNING
----------------------------------------------------------------

--[[
    Spawn a lightning bolt effect at a strike point.
    Visual: brief full-bright flash + Neon line from sky to ground
    + small impact glow at the strike point.
    @param strikePoint Vector3 world position to strike
]]
function Effects.spawnLightning(strikePoint)
    ----------------------------------------------------------------
    -- 1. FULL-BRIGHT FLASH
    ----------------------------------------------------------------
    local flash = Instance.new("ColorCorrectionEffect")
    flash.Name = "__LightningFlash"
    flash.Brightness = 0.8
    flash.Contrast = 0.3
    flash.Saturation = -0.4
    flash.TintColor = Color3.fromRGB(230, 235, 255)
    flash.Parent = Lighting

    -- Quick flash: peak then fade over ~0.4s
    tween(flash, 0.08, { Brightness = 1.0, Contrast = 0.5 })
    task.delay(0.15, function()
        tween(flash, 0.35, {
            Brightness = 0,
            Contrast = 0,
            Saturation = 0,
            TintColor = Color3.fromRGB(255, 255, 255),
        })
    end)
    Debris:AddItem(flash, 0.6)

    ----------------------------------------------------------------
    -- 2. NEON BOLT (sky to strike point)
    ----------------------------------------------------------------
    local skyHeight = 300
    local boltStart = Vector3.new(strikePoint.X, skyHeight, strikePoint.Z)
    local boltVec = strikePoint - boltStart
    local boltLength = boltVec.Magnitude

    -- Main bolt
    local bolt = Instance.new("Part")
    bolt.Name = "__LightningBolt"
    bolt.Anchored = true
    bolt.CanCollide = false
    bolt.CanQuery = false
    bolt.CanTouch = false
    bolt.Material = Enum.Material.Neon
    bolt.Color = Color3.fromRGB(220, 230, 255)
    bolt.Size = Vector3.new(0.8, boltLength, 0.8)
    bolt.CFrame = CFrame.lookAt(boltStart, strikePoint) * CFrame.new(0, 0, -boltLength / 2) * CFrame.Angles(math.rad(90), 0, 0)
    bolt.Transparency = 0.1
    bolt.Parent = Workspace

    -- Branches: 2-3 jagged offsets along the bolt
    local numBranches = math.random(2, 4)
    local branchParts = {}
    for i = 1, numBranches do
        local t = (i / (numBranches + 1)) * boltLength
        local branchPoint = boltStart + boltVec.Unit * t

        local branchOffset = Vector3.new(
            math.random(-15, 15),
            math.random(-20, -5),
            math.random(-15, 15)
        )
        local branchEnd = branchPoint + branchOffset
        local branchLen = branchOffset.Magnitude

        local branch = Instance.new("Part")
        branch.Name = "__LightningBranch"
        branch.Anchored = true
        branch.CanCollide = false
        branch.CanQuery = false
        branch.CanTouch = false
        branch.Material = Enum.Material.Neon
        branch.Color = Color3.fromRGB(200, 215, 255)
        branch.Size = Vector3.new(0.4, branchLen, 0.4)
        branch.CFrame = CFrame.lookAt(branchPoint, branchEnd) * CFrame.new(0, 0, -branchLen / 2) * CFrame.Angles(math.rad(90), 0, 0)
        branch.Transparency = 0.2
        branch.Parent = Workspace
        table.insert(branchParts, branch)
    end

    -- Fade out all bolt parts
    task.delay(0.12, function()
        tween(bolt, 0.15, { Transparency = 1, Size = Vector3.new(0.1, boltLength, 0.1) })
        for _, bp in ipairs(branchParts) do
            tween(bp, 0.12, { Transparency = 1 })
        end
    end)
    Debris:AddItem(bolt, 0.4)
    for _, bp in ipairs(branchParts) do
        Debris:AddItem(bp, 0.3)
    end

    ----------------------------------------------------------------
    -- 3. IMPACT GLOW at strike point
    ----------------------------------------------------------------
    local glow = Instance.new("Part")
    glow.Name = "__LightningGlow"
    glow.Anchored = true
    glow.CanCollide = false
    glow.CanQuery = false
    glow.CanTouch = false
    glow.Material = Enum.Material.Neon
    glow.Color = Color3.fromRGB(230, 240, 255)
    glow.Shape = Enum.PartType.Ball
    glow.Size = Vector3.new(2, 2, 2)
    glow.Position = strikePoint
    glow.Transparency = 0
    glow.Parent = Workspace

    tween(glow, 0.4, {
        Size = Vector3.new(12, 12, 12),
        Transparency = 1,
    })
    Debris:AddItem(glow, 0.5)

    ----------------------------------------------------------------
    -- 4. POINT LIGHT for brief illumination
    ----------------------------------------------------------------
    local pLight = Instance.new("PointLight")
    pLight.Color = Color3.fromRGB(220, 230, 255)
    pLight.Brightness = 8
    pLight.Range = 60
    pLight.Shadows = true
    pLight.Parent = glow

    tween(pLight, 0.4, { Brightness = 0 })
end

----------------------------------------------------------------
-- THUNDER
----------------------------------------------------------------

--[[
    Play thunder sound at a given position (3D positioned).
    Uses a random thunder sound from the pool.
    @param position Vector3 world position of the lightning strike
]]
function Effects.playThunder(position)
    local soundId = THUNDER_SOUNDS[math.random(1, #THUNDER_SOUNDS)]

    -- Create a carrier part for 3D sound
    local carrier = Instance.new("Part")
    carrier.Name = "__ThunderCarrier"
    carrier.Size = Vector3.new(0.5, 0.5, 0.5)
    carrier.Position = position
    carrier.Transparency = 1
    carrier.CanCollide = false
    carrier.CanQuery = false
    carrier.Anchored = true
    carrier.Parent = Workspace

    local sound = Instance.new("Sound")
    sound.SoundId = soundId
    sound.Volume = 0.7
    sound.PlaybackSpeed = 0.8 + math.random() * 0.3
    sound.Looped = false
    sound.RollOffMaxDistance = 400
    sound.RollOffMinDistance = 20
    sound.RollOffMode = Enum.RollOffMode.InverseTapered
    sound.Parent = carrier

    sound:Play()
    Debris:AddItem(carrier, 8)
end

----------------------------------------------------------------
-- AURORA
----------------------------------------------------------------

--[[
    Start aurora effects:
      • ColorCorrection shifting green/purple
      • Sky particle ribbons
      • Subtle blur for dreamlike quality
      • Slow cyclic tint animation
]]
function Effects.startAurora()
    if Effects._auroraActive then return end
    Effects._auroraActive = true

    ----------------------------------------------------------------
    -- 1. AURORA COLOR CORRECTION
    ----------------------------------------------------------------
    if not Effects._auroraCC then
        local existing = Lighting:FindFirstChild("__AuroraColorCorrection")
        if existing then
            Effects._auroraCC = existing
        else
            Effects._auroraCC = Instance.new("ColorCorrectionEffect")
            Effects._auroraCC.Name = "__AuroraColorCorrection"
            Effects._auroraCC.Brightness = 0
            Effects._auroraCC.Contrast = 0
            Effects._auroraCC.Saturation = 0
            Effects._auroraCC.TintColor = Color3.fromRGB(255, 255, 255)
            Effects._auroraCC.Parent = Lighting
        end
    end

    -- Fade in the aurora color shift
    tween(Effects._auroraCC, 8.0, {
        Saturation = 0.1,
        Contrast = 0.05,
        TintColor = Color3.fromRGB(120, 200, 160),  -- green-ish
    })

    -- Cyclic tint animation: shift between green and purple over time
    task.spawn(function()
        local greenTint = Color3.fromRGB(120, 200, 160)
        local purpleTint = Color3.fromRGB(140, 120, 200)

        while Effects._auroraActive do
            tween(Effects._auroraCC, 6.0, { TintColor = purpleTint })
            task.wait(6)
            if not Effects._auroraActive then break end
            tween(Effects._auroraCC, 6.0, { TintColor = greenTint })
            task.wait(6)
        end
    end)

    ----------------------------------------------------------------
    -- 2. AURORA BLUR (subtle)
    ----------------------------------------------------------------
    if not Effects._auroraBlur then
        local existing = Lighting:FindFirstChild("__AuroraBlur")
        if existing then
            Effects._auroraBlur = existing
        else
            Effects._auroraBlur = Instance.new("BlurEffect")
            Effects._auroraBlur.Name = "__AuroraBlur"
            Effects._auroraBlur.Size = 0
            Effects._auroraBlur.Parent = Lighting
        end
    end

    tween(Effects._auroraBlur, 6.0, { Size = 3 })

    ----------------------------------------------------------------
    -- 3. SKY PARTICLE RIBBONS
    ----------------------------------------------------------------
    if not Effects._auroraParticles then
        local part = Instance.new("Part")
        part.Name = "__AuroraDome"
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.Transparency = 1
        part.Material = Enum.Material.Air
        part.Size = Vector3.new(2048, 1, 2048)
        part.Position = Vector3.new(0, 250, 0)
        part.Parent = Workspace

        -- Ribbon emitter 1: green
        local greenEmitter = Instance.new("ParticleEmitter")
        greenEmitter.Name = "AuroraGreen"
        greenEmitter.Texture = "rbxassetid://243660364"  -- soft glow particle
        greenEmitter.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(60, 200, 120)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 220, 140)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 180, 100)),
        })
        greenEmitter.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 20),
            NumberSequenceKeypoint.new(0.3, 40),
            NumberSequenceKeypoint.new(0.7, 35),
            NumberSequenceKeypoint.new(1, 10),
        })
        greenEmitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.9),
            NumberSequenceKeypoint.new(0.2, 0.4),
            NumberSequenceKeypoint.new(0.8, 0.5),
            NumberSequenceKeypoint.new(1, 1.0),
        })
        greenEmitter.Lifetime = NumberRange.new(8, 14)
        greenEmitter.Speed = NumberRange.new(3, 8)
        greenEmitter.SpreadAngle = Vector2.new(180, 180)
        greenEmitter.Rotation = NumberRange.new(0, 360)
        greenEmitter.RotSpeed = NumberRange.new(-5, 5)
        greenEmitter.Acceleration = Vector3.new(2, 0, 0)  -- slow horizontal drift
        greenEmitter.Rate = 0
        greenEmitter.Parent = part

        -- Ribbon emitter 2: purple
        local purpleEmitter = Instance.new("ParticleEmitter")
        purpleEmitter.Name = "AuroraPurple"
        purpleEmitter.Texture = "rbxassetid://243660364"
        purpleEmitter.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 80, 200)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(150, 100, 220)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 60, 180)),
        })
        purpleEmitter.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 15),
            NumberSequenceKeypoint.new(0.4, 35),
            NumberSequenceKeypoint.new(1, 8),
        })
        purpleEmitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.95),
            NumberSequenceKeypoint.new(0.3, 0.5),
            NumberSequenceKeypoint.new(0.7, 0.6),
            NumberSequenceKeypoint.new(1, 1.0),
        })
        purpleEmitter.Lifetime = NumberRange.new(10, 16)
        purpleEmitter.Speed = NumberRange.new(2, 6)
        purpleEmitter.SpreadAngle = Vector2.new(180, 180)
        purpleEmitter.Rotation = NumberRange.new(0, 360)
        purpleEmitter.RotSpeed = NumberRange.new(-3, 3)
        purpleEmitter.Acceleration = Vector3.new(-1.5, 0, 1)  -- drift opposite
        purpleEmitter.Rate = 0
        purpleEmitter.Parent = part

        Effects._auroraParticles = part
    end

    -- Fade in particle rates
    task.spawn(function()
        local green = Effects._auroraParticles:FindFirstChild("AuroraGreen")
        local purple = Effects._auroraParticles:FindFirstChild("AuroraPurple")
        if green then green.Rate = 25 end
        if purple then purple.Rate = 18 end
    end)
end

--[[
    Stop aurora effects: fade out all aurora visual elements.
]]
function Effects.stopAurora()
    Effects._auroraActive = false

    -- Fade out color correction
    if Effects._auroraCC then
        tween(Effects._auroraCC, 4.0, {
            Saturation = 0,
            Contrast = 0,
            TintColor = Color3.fromRGB(255, 255, 255),
        })
    end

    -- Fade out blur
    if Effects._auroraBlur then
        tween(Effects._auroraBlur, 4.0, { Size = 0 })
    end

    -- Fade out particles
    if Effects._auroraParticles then
        local green = Effects._auroraParticles:FindFirstChild("AuroraGreen")
        local purple = Effects._auroraParticles:FindFirstChild("AuroraPurple")
        if green then green.Rate = 0 end
        if purple then purple.Rate = 0 end
    end
end

----------------------------------------------------------------
-- DEBRIS (structure destruction)
----------------------------------------------------------------

--[[
    Spawn small debris parts when a structure is destroyed by weather.
    Visual flair: broken planks/scrap flying outward and fading.
    @param position Vector3 center of the destroyed structure
]]
function Effects.spawnDebris(position)
    local numDebris = math.random(4, 8)

    for i = 1, numDebris do
        local part = Instance.new("Part")
        part.Name = "__StormDebris"
        part.Size = Vector3.new(
            math.random() * 1.5 + 0.5,
            math.random() * 0.8 + 0.2,
            math.random() * 1.5 + 0.5
        )
        part.Position = position + Vector3.new(
            math.random() * 4 - 2,
            math.random() * 3 + 1,
            math.random() * 4 - 2
        )
        part.Material = Enum.Material.Wood
        part.Color = Color3.fromRGB(
            math.random(80, 120),
            math.random(60, 90),
            math.random(40, 60)
        )
        part.Anchored = false
        part.CanCollide = true
        part.Parent = Workspace

        -- Apply outward impulse
        local impulse = (part.Position - position).Unit * math.random(20, 50) + Vector3.new(0, 30, 0)
        part.AssemblyLinearVelocity = impulse
        part.AngularVelocity = Vector3.new(math.random() * 10, math.random() * 10, math.random() * 10)

        -- Fade and remove after 3-5 seconds
        task.delay(math.random(3, 5), function()
            tween(part, 1.0, { Transparency = 1 })
            Debris:AddItem(part, 1.2)
        end)
    end
end

----------------------------------------------------------------
-- INIT / SHUTDOWN
----------------------------------------------------------------

--[[
    Initialize the effects system. Pre-creates containers.
]]
function Effects.init()
    if Effects._initialized then return end

    -- Pre-create fog planes (invisible until needed)
    createFogPlanes()

    -- Pre-create rain container (dormant)
    createRainContainer()

    Effects._initialized = true
    print("[WeatherSystem.Effects] Initialized — fog planes and rain dome ready.")
end

--[[
    Full cleanup: remove all weather effect instances.
    Call on game shutdown or testing resets.
]]
function Effects.shutdown()
    -- Rain
    if Effects._rainContainer then
        Effects._rainContainer:Destroy()
        Effects._rainContainer = nil
        Effects._rainEmitter = nil
    end

    -- Fog
    if Effects._fogPlanes then
        Effects._fogPlanes:Destroy()
        Effects._fogPlanes = nil
    end

    -- Storm CC
    if Effects._stormColorCorrection then
        Effects._stormColorCorrection:Destroy()
        Effects._stormColorCorrection = nil
    end

    -- Aurora
    if Effects._auroraCC then
        Effects._auroraCC:Destroy()
        Effects._auroraCC = nil
    end
    if Effects._auroraBlur then
        Effects._auroraBlur:Destroy()
        Effects._auroraBlur = nil
    end
    if Effects._auroraParticles then
        Effects._auroraParticles:Destroy()
        Effects._auroraParticles = nil
    end

    Effects._stormSkyActive = false
    Effects._auroraActive = false
    Effects._initialized = false
end

return Effects
