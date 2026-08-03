--[[
    Lucineer BuildAnimator
    ───────────────────────────────────────────────
    "Builds never pop — they arrive in work order."
    "Latency is animation. Persistence is memory. Load order is craftsmanship."

    Cinematic part reveal system. Sits between command receipt and the
    CommandExecutor's instant part creation. Instead of parts popping into
    existence, each part drops from above and settles with a Bounce ease,
    fades and scales in with a Back-ease bounce, emits a colored spark burst,
    and plays a material-appropriate sound — staggered so a 17-part castle
    streams in over ~1.4s like Lucineer is actively building it.

    Spatial ordering: parts are revealed foundation-up / center-out so the
    animation sweeps across the build rather than jumping around.

    INTEGRATION
    ───────────────────────────────────────────────
    CommandExecutor.executeBatch() collects created parts during batch
    execution, then calls BuildAnimator.animateBatch(parts, center) for
    the staggered cinematic reveal.

    animateBatch also accepts raw command tables (with a CommandExecutor
    reference) for standalone use — it will execute commands internally
    and animate the resulting parts.

    Server-safe: ParticleEmitter, Sound, Attachment, and TweenService all
    work on the server. Camera focus helpers are client-side only (guarded
    by RunService:IsClient()).
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Players = game:GetService("Players")

local BuildAnimator = {}

-- Shared musical clock. If uninitialized we fall back to 72 BPM (Andante).
local BeatClock = require(script.Parent.BeatClock)

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

-- The legacy stagger constant. Kept for backward compatibility.
-- New code should use BuildAnimator.getStagger(bpm) instead, which
-- derives the stagger from the musical 32nd-note grid.
local DEFAULT_STAGGER = 0.08

local CONFIG = {
    -- Per-part fade/scale tween
    PART_TWEEN_TIME = 0.32,
    SIZE_EASING_STYLE = Enum.EasingStyle.Back,
    SIZE_EASING_DIRECTION = Enum.EasingDirection.Out,
    TRANS_EASING_STYLE = Enum.EasingStyle.Quad,
    TRANS_EASING_DIRECTION = Enum.EasingDirection.Out,

    -- "scale"  = parts grow in place (classic pop-in replacement)
    -- "drop"   = parts fall from above and settle with a bounce
    ANIMATION_STYLE = "drop",

    -- Drop-in trajectory
    DROP_HEIGHT = 10,                         -- studs above final position
    DROP_EASING_STYLE = Enum.EasingStyle.Bounce,
    DROP_EASING_DIRECTION = Enum.EasingDirection.Out,

    -- Rise-in trajectory (parts emerge from below the ground / sea level)
    RISE_HEIGHT = 8,

    -- Cascade style: elastic scale for wave-ripple feel
    CASCADE_EASING_STYLE = Enum.EasingStyle.Elastic,
    CASCADE_EASING_DIRECTION = Enum.EasingDirection.Out,

    -- Staggered streaming (legacy constant; overridden by getStagger when BPM is known)
    STAGGER_DELAY = DEFAULT_STAGGER,

    -- Performance: cap concurrent in-flight animations
    MAX_CONCURRENT_ANIMATIONS = 30,

    -- Particle burst (per-part landing)
    LANDING_PARTICLE_COUNT = 8,
    LANDING_PARTICLE_LIFETIME = 0.35,
    LANDING_PARTICLE_SPEED = 4,
    LANDING_PARTICLE_SPREAD = 0.15,
    LANDING_PARTICLE_SIZE = 0.08,

    -- Weather style: dust/spray burst on each part appearance
    WEATHER_DUST_COUNT = 14,
    WEATHER_DUST_LIFETIME = 0.7,
    WEATHER_DUST_SPEED = 2.5,
    WEATHER_DUST_SIZE = 0.18,
    WEATHER_DUST_SPREAD = 0.3,

    -- Completion burst (last part in batch)
    COMPLETION_PARTICLE_COUNT = 28,
    COMPLETION_PARTICLE_LIFETIME = 0.9,
    COMPLETION_PARTICLE_SPEED = 8,
    COMPLETION_PARTICLE_SIZE = 0.12,

    -- Camera focus (client-side, opt-in via player parameter)
    CAMERA_FOCUS_RANGE = 80,       -- studs — only focus if player within this distance
    CAMERA_FOCUS_TIME = 0.7,
    CAMERA_RETURN_DELAY = 1.5,

    -- Spatial ordering: how parts are sequenced in a batch
    -- "height_then_distance" = foundation up, then outward (most architectural)
    -- "distance"             = center-out wave
    -- "none"                 = preserve command order
    BATCH_SORT_MODE = "height_then_distance",
}

----------------------------------------------------------------
-- SOUND IDS — distinct sound per material family
----------------------------------------------------------------

local SOUND_IDS = {
    -- Stone family: low thud
    THUD = "rbxassetid://314428418",

    -- Wood family: woody knock
    WOOD_KNOCK = "rbxassetid://9120149793",

    -- Metal family: metallic clang
    METAL_CLANG = "rbxassetid://8685257501",

    -- Neon family: soft chime
    CHIME = "rbxassetid://9116245410",

    -- Glass family: crystal tap
    CRYSTAL_TAP = "rbxassetid://18269528686",

    -- Completion settle sound
    SETTLE = "rbxassetid://314428418",
}

----------------------------------------------------------------
-- MATERIAL → SOUND MAPPING
----------------------------------------------------------------

-- Material families for sound selection
local STONE_MATERIALS = {
    [Enum.Material.Slate] = true,
    [Enum.Material.Concrete] = true,
    [Enum.Material.Brick] = true,
    [Enum.Material.Cobblestone] = true,
    [Enum.Material.Rock] = true,
    [Enum.Material.Sand] = true,
    [Enum.Material.Marble] = true,
    [Enum.Material.Granite] = true,
    [Enum.Material.Asphalt] = true,
    [Enum.Material.Basalt] = true,
    [Enum.Material.CrackedLava] = true,
    [Enum.Material.Ground] = true,
    [Enum.Material.Mud] = true,
    [Enum.Material.LeafyGrass] = true,
}

local WOOD_MATERIALS = {
    [Enum.Material.Wood] = true,
    [Enum.Material.WoodPlanks] = true,
    [Enum.Material.Bamboo] = true,
}

local METAL_MATERIALS = {
    [Enum.Material.Metal] = true,
    [Enum.Material.DiamondPlate] = true,
    [Enum.Material.Foil] = true,
    [Enum.Material.CorrodedMetal] = true,
    [Enum.Material.AluminumNitride] = true,
}

local GLASS_MATERIALS = {
    [Enum.Material.Glass] = true,
    [Enum.Material.Ice] = true,
    [Enum.Material.ForceField] = true,
}

local NEON_MATERIALS = {
    [Enum.Material.Neon] = true,
}

----------------------------------------------------------------
-- MATERIAL → PITCH MAPPING
----------------------------------------------------------------

local MATERIAL_PITCHES = {
    -- Stone: low
    [Enum.Material.Slate]       = 0.80,
    [Enum.Material.Concrete]    = 0.80,
    [Enum.Material.Brick]       = 0.82,
    [Enum.Material.Cobblestone] = 0.78,
    [Enum.Material.Rock]        = 0.80,
    [Enum.Material.Sand]        = 0.85,
    [Enum.Material.Marble]      = 0.82,
    [Enum.Material.Granite]     = 0.78,
    [Enum.Material.Asphalt]     = 0.80,
    [Enum.Material.Basalt]      = 0.76,

    -- Wood: mid
    [Enum.Material.Wood]        = 1.00,
    [Enum.Material.WoodPlanks]  = 1.05,
    [Enum.Material.Bamboo]      = 1.10,

    -- Metal: sharp
    [Enum.Material.Metal]       = 1.30,
    [Enum.Material.DiamondPlate] = 1.35,
    [Enum.Material.Foil]        = 1.40,
    [Enum.Material.CorrodedMetal] = 1.15,

    -- Neon: bright
    [Enum.Material.Neon]        = 1.50,

    -- Glass: high
    [Enum.Material.Glass]       = 1.55,
    [Enum.Material.Ice]         = 1.45,
    [Enum.Material.ForceField]  = 1.60,
}

local DEFAULT_PITCH = 0.90

----------------------------------------------------------------
-- CONCURRENCY TRACKING
----------------------------------------------------------------

local activeAnimationCount = 0
local pendingQueue: { () -> () } = {}

--[[
    Try to acquire an animation slot. If we're at the cap, the animation
    is queued and will run when a slot frees.

    @param callback function -- the animation work to perform
]]
local function acquireSlot(callback: () -> ())
    if activeAnimationCount < CONFIG.MAX_CONCURRENT_ANIMATIONS then
        activeAnimationCount += 1
        callback()
    else
        table.insert(pendingQueue, callback)
    end
end

--[[
    Release an animation slot and pump the next queued item if any.
]]
local function releaseSlot()
    activeAnimationCount = math.max(0, activeAnimationCount - 1)

    if #pendingQueue > 0 and activeAnimationCount < CONFIG.MAX_CONCURRENT_ANIMATIONS then
        local next_cb = table.remove(pendingQueue, 1)
        activeAnimationCount += 1
        next_cb()
    end
end

----------------------------------------------------------------
-- INTERNAL HELPERS
----------------------------------------------------------------

--[[
    Get the pitch for a given material with random ±0.1 variation.
    @param material Enum.Material
    @return number playback speed
]]
local function getPitchForMaterial(material: Enum.Material): number
    local base = MATERIAL_PITCHES[material] or DEFAULT_PITCH
    local variation = (math.random() - 0.5) * 0.2 -- ±0.1
    return math.max(0.5, base + variation)
end

--[[
    Determine which sound to use for a given material.
    @param material Enum.Material
    @return string soundId
]]
local function getSoundIdForMaterial(material: Enum.Material): string
    if NEON_MATERIALS[material] then
        return SOUND_IDS.CHIME
    elseif GLASS_MATERIALS[material] then
        return SOUND_IDS.CRYSTAL_TAP
    elseif METAL_MATERIALS[material] then
        return SOUND_IDS.METAL_CLANG
    elseif WOOD_MATERIALS[material] then
        return SOUND_IDS.WOOD_KNOCK
    else
        -- Stone and everything else: thud
        return SOUND_IDS.THUD
    end
end

--[[
    Read target size/transparency stored on a part by CommandExecutor.
    Returns the target values and removes the attributes so they don't
    linger on the instance. If no attributes exist, returns current values.
]]
local function readTargetAttributes(part: BasePart): (Vector3, number)
    local tx = part:GetAttribute("BA_TargetSizeX")
    local ty = part:GetAttribute("BA_TargetSizeY")
    local tz = part:GetAttribute("BA_TargetSizeZ")
    local targetSize = if tx and ty and tz
        then Vector3.new(tx, ty, tz)
        else part.Size
    local targetTransparency = part:GetAttribute("BA_TargetTransparency") or part.Transparency

    part:RemoveAttribute("BA_TargetSizeX")
    part:RemoveAttribute("BA_TargetSizeY")
    part:RemoveAttribute("BA_TargetSizeZ")
    part:RemoveAttribute("BA_TargetTransparency")

    return targetSize, targetTransparency
end

--[[
    Compute the axis-aligned bounding box of an array of BaseParts.
    Uses target-size attributes if present (parts may be in pre-animation
    shrunken state), otherwise uses current Size.
    Returns min, max, center, and size.
]]
local function calculateBounds(parts: { BasePart }): (Vector3, Vector3, Vector3, Vector3)
    local function getPartSize(p: BasePart): Vector3
        local tx = p:GetAttribute("BA_TargetSizeX")
        local ty = p:GetAttribute("BA_TargetSizeY")
        local tz = p:GetAttribute("BA_TargetSizeZ")
        if tx and ty and tz then
            return Vector3.new(tx, ty, tz)
        end
        return p.Size
    end

    local minVec = parts[1].Position
    local maxVec = parts[1].Position
    for i = 2, #parts do
        local p = parts[i]
        minVec = Vector3.new(
            math.min(minVec.X, p.Position.X),
            math.min(minVec.Y, p.Position.Y),
            math.min(minVec.Z, p.Position.Z)
        )
        maxVec = Vector3.new(
            math.max(maxVec.X, p.Position.X),
            math.max(maxVec.Y, p.Position.Y),
            math.max(maxVec.Z, p.Position.Z)
        )
    end
    -- Include part extents (Position is center, not corner)
    for _, p in ipairs(parts) do
        local half = getPartSize(p) * 0.5
        minVec = Vector3.new(
            math.min(minVec.X, p.Position.X - half.X),
            math.min(minVec.Y, p.Position.Y - half.Y),
            math.min(minVec.Z, p.Position.Z - half.Z)
        )
        maxVec = Vector3.new(
            math.max(maxVec.X, p.Position.X + half.X),
            math.max(maxVec.Y, p.Position.Y + half.Y),
            math.max(maxVec.Z, p.Position.Z + half.Z)
        )
    end
    local center = (minVec + maxVec) * 0.5
    local size = maxVec - minVec
    return minVec, maxVec, center, size
end

--[[
    Sort parts into a cinematic build order.
    "height_then_distance" lays foundations first, then rises, then expands outward.
    "distance" radiates from the build center in waves.
    "none" leaves the array unchanged.
]]
local function sortPartsSpatially(parts: { BasePart }, center: Vector3): { BasePart }
    if CONFIG.BATCH_SORT_MODE == "none" then
        return parts
    end

    local sorted = table.clone(parts)
    if CONFIG.BATCH_SORT_MODE == "distance" then
        table.sort(sorted, function(a, b)
            return (a.Position - center).Magnitude < (b.Position - center).Magnitude
        end)
    else
        -- height_then_distance: ascending Y, then horizontal distance
        table.sort(sorted, function(a, b)
            local dy = a.Position.Y - b.Position.Y
            if math.abs(dy) > 0.1 then
                return dy < 0
            end
            local ah = Vector3.new(a.Position.X, 0, a.Position.Z)
            local bh = Vector3.new(b.Position.X, 0, b.Position.Z)
            local ch = Vector3.new(center.X, 0, center.Z)
            return (ah - ch).Magnitude < (bh - ch).Magnitude
        end)
    end
    return sorted
end

--[[
    Musical stagger: use the shared BeatClock when available, otherwise
    fall back to the legacy constant.
]]
local function getCurrentStagger(): number
    local bpm = BeatClock.getBPM()
    if bpm and bpm > 0 then
        return BuildAnimator.getStagger(bpm)
    end
    return CONFIG.STAGGER_DELAY
end

--[[
    Create a one-shot particle burst at a world position.

    Creates an invisible carrier part with an Attachment + ParticleEmitter,
    emits once, and schedules cleanup via Debris.

    @param position Vector3 -- world position
    @param color Color3 -- particle color
    @param count number -- particles to emit
    @param lifetime number -- how long particles live (seconds)
    @param speed number -- emission speed
    @param size number -- particle size
    @return ParticleEmitter? -- the emitter (or nil on failure)
]]
local function createParticleBurst(
    position: Vector3,
    color: Color3,
    count: number,
    lifetime: number,
    speed: number,
    size: number
): ParticleEmitter?
    local ok, err = pcall(function()
        local carrier = Instance.new("Part")
        carrier.Name = "BurstCarrier"
        carrier.Size = Vector3.new(0.1, 0.1, 0.1)
        carrier.Position = position
        carrier.Transparency = 1
        carrier.CanCollide = false
        carrier.CanQuery = false
        carrier.Anchored = true
        carrier.Parent = workspace

        local attachment = Instance.new("Attachment")
        attachment.Parent = carrier

        local emitter = Instance.new("ParticleEmitter")
        emitter.Name = "BurstEmitter"
        emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
        emitter.Color = ColorSequence.new(color)
        emitter.Size = NumberSequence.new(size)
        emitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1),
        })
        emitter.Lifetime = NumberRange.new(lifetime * 0.5, lifetime)
        emitter.Speed = NumberRange.new(
            speed * (1 - CONFIG.LANDING_PARTICLE_SPREAD),
            speed * (1 + CONFIG.LANDING_PARTICLE_SPREAD)
        )
        emitter.SpreadAngle = Vector2.new(45, 45)
        emitter.Rotation = NumberRange.new(0, 360)
        emitter.Rate = 0
        emitter.EmitCount = count
        emitter.Parent = attachment

        emitter:Emit(count)

        Debris:AddItem(carrier, lifetime + 0.5)
    end)

    if not ok then
        warn(string.format("[Lucineer] BuildAnimator: particle burst failed: %s", tostring(err)))
    end

    return nil
end

--[[
    Create a one-shot dust/spray particle burst for the "weather" animation style.

    Similar to createParticleBurst but uses wider spread, slower/larger particles,
    and desaturated colors to simulate dust, debris, or sea spray.

    @param position Vector3 -- world position
    @param color Color3 -- base color (will be desaturated for dust look)
]]
local function createWeatherBurst(position: Vector3, color: Color3)
    local ok, err = pcall(function()
        local carrier = Instance.new("Part")
        carrier.Name = "WeatherCarrier"
        carrier.Size = Vector3.new(0.1, 0.1, 0.1)
        carrier.Position = position
        carrier.Transparency = 1
        carrier.CanCollide = false
        carrier.CanQuery = false
        carrier.Anchored = true
        carrier.Parent = workspace

        local attachment = Instance.new("Attachment")
        attachment.Parent = carrier

        local dustH, dustS, dustV = color:ToHSV()
        local dustColor = Color3.fromHSV(dustH, dustS * 0.4, dustV * 0.7)

        local emitter = Instance.new("ParticleEmitter")
        emitter.Name = "WeatherEmitter"
        emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
        emitter.Color = ColorSequence.new(dustColor)
        emitter.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, CONFIG.WEATHER_DUST_SIZE * 0.5),
            NumberSequenceKeypoint.new(1, CONFIG.WEATHER_DUST_SIZE * 1.5),
        })
        emitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.3),
            NumberSequenceKeypoint.new(1, 1),
        })
        emitter.Lifetime = NumberRange.new(
            CONFIG.WEATHER_DUST_LIFETIME * 0.5,
            CONFIG.WEATHER_DUST_LIFETIME
        )
        emitter.Speed = NumberRange.new(
            CONFIG.WEATHER_DUST_SPEED * (1 - CONFIG.WEATHER_DUST_SPREAD),
            CONFIG.WEATHER_DUST_SPEED * (1 + CONFIG.WEATHER_DUST_SPREAD)
        )
        emitter.SpreadAngle = Vector2.new(60, 60)
        emitter.Rotation = NumberRange.new(0, 360)
        emitter.Rate = 0
        emitter.EmitCount = CONFIG.WEATHER_DUST_COUNT
        emitter.Parent = attachment

        emitter:Emit(CONFIG.WEATHER_DUST_COUNT)

        Debris:AddItem(carrier, CONFIG.WEATHER_DUST_LIFETIME + 0.5)
    end)

    if not ok then
        warn(string.format("[Lucineer] BuildAnimator: weather burst failed: %s", tostring(err)))
    end

    return nil
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Animate a single part fading and scaling in.

    The part should already be parented to the workspace with its target
    Size and Transparency set. This function:
      1. Records the target size and transparency.
      2. Shrinks to near-zero and sets transparency to 1.
      3. Tweens size (Back ease) and transparency (Quad ease) over 0.3s.
      4. On completion, fires a particle burst and material sound.

    Error-safe: if TweenService fails, the part is immediately restored
    to its target values so it still appears.

    @param part BasePart -- the part to animate (must be parented)
    @param targetTransparency number? -- final transparency (defaults to part's current value)
]]
function BuildAnimator.animatePart(part: BasePart, targetTransparency: number?, style: string?)
    if not part or typeof(part) ~= "Instance" or not part:IsA("BasePart") then
        warn("[Lucineer] BuildAnimator.animatePart: expected a BasePart, got " .. tostring(part))
        return
    end

    -- Read target values stored by CommandExecutor (or current values as fallback)
    local targetSize, targetTrans = readTargetAttributes(part)
    if targetTransparency then
        targetTrans = targetTransparency
    end
    local partColor = part.Color
    local partMaterial = part.Material
    local landingPos = part.Position
    local animStyle = style or CONFIG.ANIMATION_STYLE

    acquireSlot(function()
        -- Snap to invisible / tiny
        part.Transparency = 1
        part.Size = Vector3.new(0.1, 0.1, 0.1)

        local startPos = landingPos
        local positionTween: Tween? = nil
        if animStyle == "drop" then
            startPos = landingPos + Vector3.new(0, CONFIG.DROP_HEIGHT, 0)
            part.CFrame = CFrame.new(startPos) * (part.CFrame - part.CFrame.Position)
        elseif animStyle == "rise" then
            startPos = landingPos + Vector3.new(0, -CONFIG.RISE_HEIGHT, 0)
            part.CFrame = CFrame.new(startPos) * (part.CFrame - part.CFrame.Position)
        end

        local completed = false

        -- Per-style size easing: cascade uses elastic for a wave-ripple feel
        local sizeEasing = CONFIG.SIZE_EASING_STYLE
        local sizeEasingDir = CONFIG.SIZE_EASING_DIRECTION
        if animStyle == "cascade" then
            sizeEasing = CONFIG.CASCADE_EASING_STYLE
            sizeEasingDir = CONFIG.CASCADE_EASING_DIRECTION
        end

        -- Size tween
        local sizeInfo = TweenInfo.new(
            CONFIG.PART_TWEEN_TIME,
            sizeEasing,
            sizeEasingDir
        )
        local sizeTween = TweenService:Create(part, sizeInfo, { Size = targetSize })

        -- Transparency tween (Quad ease — smooth fade)
        local transInfo = TweenInfo.new(
            CONFIG.PART_TWEEN_TIME,
            CONFIG.TRANS_EASING_STYLE,
            CONFIG.TRANS_EASING_DIRECTION
        )
        local transTween = TweenService:Create(part, transInfo, { Transparency = targetTrans })

        -- Optional drop trajectory (Bounce ease — weighty landing)
        if animStyle == "drop" then
            local dropInfo = TweenInfo.new(
                CONFIG.PART_TWEEN_TIME * 1.1,
                CONFIG.DROP_EASING_STYLE,
                CONFIG.DROP_EASING_DIRECTION
            )
            positionTween = TweenService:Create(part, dropInfo, { Position = landingPos })
        elseif animStyle == "rise" then
            local riseInfo = TweenInfo.new(
                CONFIG.PART_TWEEN_TIME * 1.1,
                Enum.EasingStyle.Quad,
                Enum.EasingDirection.Out
            )
            positionTween = TweenService:Create(part, riseInfo, { Position = landingPos })
        end

        -- Landing effects when the size tween completes
        sizeTween.Completed:Connect(function(playbackState)
            if completed then return end
            completed = true
            releaseSlot()

            if playbackState == Enum.PlaybackState.Completed then
                -- Ensure final CFrame is exact
                pcall(function()
                    part.CFrame = CFrame.new(landingPos) * (part.CFrame - part.CFrame.Position)
                    part.Size = targetSize
                    part.Transparency = targetTrans
                end)

                -- Particle burst at the part's center
                createParticleBurst(
                    landingPos,
                    partColor,
                    CONFIG.LANDING_PARTICLE_COUNT,
                    CONFIG.LANDING_PARTICLE_LIFETIME,
                    CONFIG.LANDING_PARTICLE_SPEED,
                    CONFIG.LANDING_PARTICLE_SIZE
                )

                -- Placement sound
                BuildAnimator.playPlacementSound(partMaterial, landingPos)
            end
        end)

        -- Safety net: if the tween never fires (e.g. part destroyed),
        -- restore target values after a timeout so the part is still visible.
        task.delay(CONFIG.PART_TWEEN_TIME + 0.5, function()
            if not completed then
                completed = true
                releaseSlot()
                pcall(function()
                    if part and part.Parent then
                        part.CFrame = CFrame.new(landingPos) * (part.CFrame - part.CFrame.Position)
                        part.Size = targetSize
                        part.Transparency = targetTrans
                    end
                end)
            end
        end)

        -- Play tweens with pcall guard
        local ok1 = pcall(function() sizeTween:Play() end)
        local ok2 = pcall(function() transTween:Play() end)
        if positionTween then
            pcall(function() positionTween:Play() end)
        end

        if not ok1 or not ok2 then
            -- TweenService failed — restore immediately
            if not completed then
                completed = true
                releaseSlot()
                pcall(function()
                    part.CFrame = CFrame.new(landingPos) * (part.CFrame - part.CFrame.Position)
                    part.Size = targetSize
                    part.Transparency = targetTrans
                end)
            end
        end
    end)
end

--[[
    Animate a batch of parts (or commands) with staggered timing.

    Parts are revealed one at a time, STAGGER_DELAY seconds apart. A
    10-part build streams in over ~0.8s; a 17-part castle over ~1.4s.

    The last part to appear triggers a completion burst: 20-30 multi-colored
    particles at the build center plus a satisfying low settle sound.

    Two calling conventions:
      animateBatch(parts: { BasePart }, centerPosition: Vector3?)
        — Parts already created (by CommandExecutor). Each part's current
          Size/Transparency is treated as the target.

      animateBatch(commands: { [string]: any }, centerPosition: Vector3, player: Player?, executor: { [string]: any })
        — Raw commands. If an executor (CommandExecutor) is provided,
          each command is executed first, and the resulting parts are
          collected and animated.

    @param partsOrCommands table -- array of BasePart instances or command tables
    @param centerPosition Vector3? -- build center for completion burst & camera
    @param player Player? -- if provided and client-side, focus camera on build
    @param executor table? -- CommandExecutor module (required when passing commands)
]]
function BuildAnimator.animateBatch(
    partsOrCommands: any,
    centerPosition: Vector3?,
    player: Player?,
    executor: any?
)
    if not partsOrCommands or typeof(partsOrCommands) ~= "table" then
        warn("[Lucineer] BuildAnimator.animateBatch: expected a table, got " .. typeof(partsOrCommands))
        return
    end

    -- If the first element looks like a command (has .type), execute them
    local isFirstCommand = (partsOrCommands[1] and type(partsOrCommands[1]) == "table" and partsOrCommands[1].type) ~= nil
    local parts: { BasePart } = {}

    if isFirstCommand then
        if not executor then
            warn("[Lucineer] BuildAnimator.animateBatch: commands passed but no executor provided")
            return
        end

        -- Execute each command and collect resulting parts
        for _, command in ipairs(partsOrCommands) do
            local result, err = executor.execute(command)
            if not err and result and typeof(result) == "Instance" and result:IsA("BasePart") then
                table.insert(parts, result)
            end
        end

        -- Compute center from collected parts if not provided
        if not centerPosition and #parts > 0 then
            local sum = Vector3.new(0, 0, 0)
            for _, p in ipairs(parts) do
                sum += p.Position
            end
            centerPosition = sum / #parts
        end
    else
        parts = partsOrCommands
    end

    local count = #parts
    if count == 0 then
        return
    end

    -- Compute the real bounding box so we can frame the camera and center
    -- the completion burst on the build's actual volume, not just the
    -- arithmetic mean of part centers.
    local _, _, boundsCenter, boundsSize = calculateBounds(parts)
    centerPosition = centerPosition or boundsCenter

    -- Sort parts into a cinematic build order (foundation first, then up/out)
    parts = sortPartsSpatially(parts, centerPosition)

    -- Camera focus (client-side, only if player is within range)
    if player and RunService:IsClient() then
        BuildAnimator._focusCamera(centerPosition, player, boundsSize)
    end

    -- Stagger each part's reveal, driven by the musical clock
    local stagger = getCurrentStagger()
    for i, part in ipairs(parts) do
        local delay = (i - 1) * stagger

        task.delay(delay, function()
            local isLast = (i == count)

            if isLast then
                BuildAnimator._animatePartWithCompletion(part, centerPosition)
            else
                BuildAnimator.animatePart(part)
            end
        end)
    end
end

--[[
    Animate a part and fire the completion burst when it lands.

    Internal method used by animateBatch for the final part.

    @param part BasePart -- the last part in the batch
    @param centerPosition Vector3 -- center of the build for the completion burst
]]
function BuildAnimator._animatePartWithCompletion(part: BasePart, centerPosition: Vector3)
    if not part or not part:IsA("BasePart") then return end

    local targetSize, targetTrans = readTargetAttributes(part)
    local partColor = part.Color
    local partMaterial = part.Material
    local landingPos = part.Position
    local animStyle = CONFIG.ANIMATION_STYLE

    acquireSlot(function()
        -- Snap to invisible / tiny
        part.Transparency = 1
        part.Size = Vector3.new(0.1, 0.1, 0.1)

        local positionTween: Tween? = nil
        if animStyle == "drop" then
            local startPos = landingPos + Vector3.new(0, CONFIG.DROP_HEIGHT, 0)
            part.CFrame = CFrame.new(startPos) * (part.CFrame - part.CFrame.Position)
            positionTween = TweenService:Create(
                part,
                TweenInfo.new(
                    CONFIG.PART_TWEEN_TIME * 1.1,
                    CONFIG.DROP_EASING_STYLE,
                    CONFIG.DROP_EASING_DIRECTION
                ),
                { Position = landingPos }
            )
        end

        local completed = false

        local sizeTween = TweenService:Create(
            part,
            TweenInfo.new(
                CONFIG.PART_TWEEN_TIME,
                CONFIG.SIZE_EASING_STYLE,
                CONFIG.SIZE_EASING_DIRECTION
            ),
            { Size = targetSize }
        )

        local transTween = TweenService:Create(
            part,
            TweenInfo.new(
                CONFIG.PART_TWEEN_TIME,
                CONFIG.TRANS_EASING_STYLE,
                CONFIG.TRANS_EASING_DIRECTION
            ),
            { Transparency = targetTrans }
        )

        sizeTween.Completed:Connect(function(playbackState)
            if completed then return end
            completed = true
            releaseSlot()

            if playbackState == Enum.PlaybackState.Completed then
                -- Ensure final CFrame is exact
                pcall(function()
                    part.CFrame = CFrame.new(landingPos) * (part.CFrame - part.CFrame.Position)
                    part.Size = targetSize
                    part.Transparency = targetTrans
                end)

                -- Standard landing burst for this part
                createParticleBurst(
                    landingPos,
                    partColor,
                    CONFIG.LANDING_PARTICLE_COUNT,
                    CONFIG.LANDING_PARTICLE_LIFETIME,
                    CONFIG.LANDING_PARTICLE_SPEED,
                    CONFIG.LANDING_PARTICLE_SIZE
                )

                -- Placement sound
                BuildAnimator.playPlacementSound(partMaterial, landingPos)

                -- COMPLETION BURST — bigger, multi-colored, at build center
                task.wait(0.05)

                local completionColors = {
                    Color3.fromRGB(255, 220, 100), -- warm gold
                    Color3.fromRGB(100, 200, 255), -- soft blue
                    Color3.fromRGB(255, 150, 200), -- pink
                    Color3.fromRGB(150, 255, 150), -- green
                    Color3.fromRGB(255, 255, 255), -- white
                }

                local perColor = math.floor(CONFIG.COMPLETION_PARTICLE_COUNT / #completionColors)
                for _, burstColor in ipairs(completionColors) do
                    createParticleBurst(
                        centerPosition,
                        burstColor,
                        perColor,
                        CONFIG.COMPLETION_PARTICLE_LIFETIME,
                        CONFIG.COMPLETION_PARTICLE_SPEED,
                        CONFIG.COMPLETION_PARTICLE_SIZE
                    )
                end

                -- Completion settle sound — low, warm, satisfying
                local settleSound = Instance.new("Sound")
                settleSound.SoundId = SOUND_IDS.SETTLE
                settleSound.Volume = 0.6
                settleSound.PlaybackSpeed = 0.55 -- deep settle pitch
                settleSound.Parent = workspace
                settleSound:Play()
                Debris:AddItem(settleSound, 3)

                -- Camera return (client-side)
                BuildAnimator._returnCamera()
            end
        end)

        -- Safety net
        task.delay(CONFIG.PART_TWEEN_TIME + 0.5, function()
            if not completed then
                completed = true
                releaseSlot()
                pcall(function()
                    if part and part.Parent then
                        part.CFrame = CFrame.new(landingPos) * (part.CFrame - part.CFrame.Position)
                        part.Size = targetSize
                        part.Transparency = targetTrans
                    end
                end)
            end
        end)

        local ok1 = pcall(function() sizeTween:Play() end)
        local ok2 = pcall(function() transTween:Play() end)
        if positionTween then
            pcall(function() positionTween:Play() end)
        end

        if not ok1 or not ok2 then
            if not completed then
                completed = true
                releaseSlot()
                pcall(function()
                    part.CFrame = CFrame.new(landingPos) * (part.CFrame - part.CFrame.Position)
                    part.Size = targetSize
                    part.Transparency = targetTrans
                end)
            end
        end
    end)
end

--[[
    Emit a quick particle burst at a position.

    Convenience method for external callers.

    @param position Vector3 -- world position
    @param color Color3 -- particle color
    @param duration number? -- override particle lifetime (seconds)
]]
function BuildAnimator.burst(position: Vector3, color: Color3, duration: number?)
    createParticleBurst(
        position,
        color,
        CONFIG.LANDING_PARTICLE_COUNT,
        duration or CONFIG.LANDING_PARTICLE_LIFETIME,
        CONFIG.LANDING_PARTICLE_SPEED,
        CONFIG.LANDING_PARTICLE_SIZE
    )
end

--[[
    Play a placement sound for a given material at a position.

    Creates a temporary 3D spatialized Sound on a carrier part, plays it
    with material-appropriate pitch variation (±0.1), and cleans up.

    @param material Enum.Material -- the part's material
    @param position Vector3 -- where to play the sound
]]
function BuildAnimator.playPlacementSound(material: Enum.Material, position: Vector3)
    local soundId = getSoundIdForMaterial(material)
    local pitch = getPitchForMaterial(material)

    pcall(function()
        local carrier = Instance.new("Part")
        carrier.Name = "SoundCarrier"
        carrier.Size = Vector3.new(0.1, 0.1, 0.1)
        carrier.Position = position
        carrier.Transparency = 1
        carrier.CanCollide = false
        carrier.CanQuery = false
        carrier.Anchored = true
        carrier.Parent = workspace

        local sound = Instance.new("Sound")
        sound.SoundId = soundId
        sound.Volume = 0.35
        sound.PlaybackSpeed = pitch
        sound.RollOffMaxDistance = 60
        sound.RollOffMinDistance = 10
        sound.RollOffMode = Enum.RollOffMode.InverseTapered
        sound.Parent = carrier
        sound:Play()

        Debris:AddItem(carrier, 3)
    end)
end

----------------------------------------------------------------
-- CLIENT-SIDE CAMERA HELPERS
----------------------------------------------------------------

--[[
    Gently tween the camera to frame the build area.

    Only activates if the player is within CAMERA_FOCUS_RANGE studs of
    the build center. Client-side only.

    @param position Vector3 -- center of the build to frame
    @param player Player -- the player to check proximity for
]]
function BuildAnimator._focusCamera(position: Vector3, player: Player?, buildSize: Vector3?)
    if not RunService:IsClient() then return end
    if not player then
        player = Players.LocalPlayer
    end
    if not player then return end

    local character = player.Character
    if not character then return end

    local root = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChildWhichIsA("BasePart")
    if not root then return end

    -- Proximity check — only focus if player is close enough
    local distance = (root.Position - position).Magnitude
    if distance > CONFIG.CAMERA_FOCUS_RANGE then
        return
    end

    local camera = workspace.CurrentCamera
    if not camera then return end

    -- Frame the build using its real volume. A castle needs more distance
    -- than a flower box. Build a diagonal from the horizontal footprint and
    -- height, then pull back enough to keep the whole thing in view.
    local size = buildSize or Vector3.new(10, 10, 10)
    local horizontal = math.sqrt(size.X * size.X + size.Z * size.Z)
    local backDistance = math.max(25, horizontal * 1.1)
    local upDistance = math.max(15, size.Y * 0.6)
    local offset = Vector3.new(0, upDistance, backDistance)
    local targetCFrame = CFrame.lookAt(position + offset, position)

    pcall(function()
        local tween = TweenService:Create(
            camera,
            TweenInfo.new(
                CONFIG.CAMERA_FOCUS_TIME,
                Enum.EasingStyle.Quad,
                Enum.EasingDirection.Out
            ),
            { CFrame = targetCFrame }
        )
        tween:Play()
    end)
end

--[[
    Return camera control to the player after construction completes.

    Schedules a delayed camera type restoration so the completion burst
    is visible before control returns.
]]
function BuildAnimator._returnCamera()
    if not RunService:IsClient() then return end

    task.delay(CONFIG.CAMERA_RETURN_DELAY, function()
        local camera = workspace.CurrentCamera
        if not camera then return end

        -- Restore default camera so player's camera scripts take over
        pcall(function()
            camera.CameraType = Enum.CameraType.Custom
        end)
    end)
end

----------------------------------------------------------------
-- CONFIGURATION
----------------------------------------------------------------

--[[
    Override CONFIG values at runtime.

    @param overrides table -- key/value pairs to merge into CONFIG
]]
function BuildAnimator.configure(overrides: { [string]: any })
    for key, value in pairs(overrides or {}) do
        CONFIG[key] = value
    end
end

--[[
    Get a shallow copy of the current CONFIG.

    @return table
]]
function BuildAnimator.getConfig(): { [string]: any }
    local copy = {}
    for key, value in pairs(CONFIG) do
        copy[key] = value
    end
    return copy
end

----------------------------------------------------------------
-- MUSICAL TIMING — 32nd-note grid
----------------------------------------------------------------

--[[
    Calculate the per-part stagger from the current BPM.

    The Grand Plan says: "BuildAnimator re-derived onto the 32nd-note
    grid — at Allegro 120 that is ~62ms, at Andante 90 ~83ms; the tuned
    '0.08s stagger' stops being a constant and becomes a musical duration."

    32nd note = beat / 8 (eight 32nd notes per quarter note)
    At 120 BPM: 60/120/8 = 0.0625s per 32nd note
    At 90 BPM:  60/90/8  = 0.083s
    At 72 BPM:  60/72/8  = 0.104s

    This means the build's visual rhythm is derived from the shared clock,
    not hardcoded. When the tempo rises (EnergyAdapter detects player
    excitement), parts land faster — the yard quickens with the player.

    @param bpm number — current BPM from BeatClock
    @return number — seconds between part reveals (one 32nd note)
]]
function BuildAnimator.getStagger(bpm: number): number
    if typeof(bpm) ~= "number" or bpm <= 0 then
        return DEFAULT_STAGGER
    end
    return 60.0 / (bpm * 8)
end

--[[
    Animate a batch with musical timing derived from BPM.

    Same as animateBatch() but uses getStagger(bpm) for the inter-part
    delay instead of the legacy CONFIG.STAGGER_DELAY constant.

    @param parts { BasePart } -- array of parts to reveal
    @param bpm number -- current BPM from BeatClock
    @param centerPosition Vector3? -- build center for completion burst
    @param player Player? -- for camera focus (client-side)
]]
function BuildAnimator.animateBatchInTime(
    parts: { BasePart },
    bpm: number,
    centerPosition: Vector3?,
    player: Player?
)
    if not parts or #parts == 0 then return end

    local stagger = BuildAnimator.getStagger(bpm)
    local count = #parts

    local _, _, boundsCenter, boundsSize = calculateBounds(parts)
    centerPosition = centerPosition or boundsCenter

    parts = sortPartsSpatially(parts, centerPosition)

    if player and RunService:IsClient() then
        BuildAnimator._focusCamera(centerPosition, player, boundsSize)
    end

    for i, part in ipairs(parts) do
        local delay = (i - 1) * stagger

        task.delay(delay, function()
            local isLast = (i == count)
            if isLast then
                BuildAnimator._animatePartWithCompletion(part, centerPosition)
            else
                BuildAnimator.animatePart(part)
            end
        end)
    end
end

return BuildAnimator
