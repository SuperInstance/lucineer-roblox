--[[
    Lucineer BuildAnimator
    ───────────────────────────────────────────────
    "Builds never pop — they arrive in work order."
    "Latency is animation. Persistence is memory. Load order is craftsmanship."

    This module wraps part creation with cinematic, staggered reveals so that
    every build feels like Lucineer is actively constructing it — footings first,
    then frame, then sheathing, then trim. Parts fade and scale in with a subtle
    Back-ease bounce, emit a colored particle burst on landing, and play a
    material-appropriate placement sound. The final part in a batch triggers a
    completion burst and a satisfying low thunk.

    Server-safe: ParticleEmitter, Sound, Attachment, and TweenService all work
    on the server. Camera focus helpers are client-side only (guarded by
    RunService:IsClient()).
--]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local BuildAnimator = {}

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

local CONFIG = {
    -- Per-part fade/scale tween
    PART_TWEEN_TIME = 0.3,           -- seconds for a single part to appear
    SIZE_EASING_STYLE = Enum.EasingStyle.Back,
    SIZE_EASING_DIRECTION = Enum.EasingDirection.Out,
    TRANS_EASING_STYLE = Enum.EasingStyle.Quad,
    TRANS_EASING_DIRECTION = Enum.EasingDirection.Out,

    -- Staggered streaming
    STAGGER_DELAY = 0.08,            -- seconds between consecutive part reveals

    -- Particle burst (per-part landing)
    LANDING_PARTICLE_COUNT = 8,      -- 5-10 range
    LANDING_PARTICLE_LIFETIME = 0.3,
    LANDING_PARTICLE_SPEED = 4,
    LANDING_PARTICLE_SPREAD = 0.15,  -- fraction of speed as randomness
    LANDING_PARTICLE_SIZE = 0.08,

    -- Completion burst (last part)
    COMPLETION_PARTICLE_COUNT = 25,  -- 20-30 range
    COMPLETION_PARTICLE_LIFETIME = 0.8,
    COMPLETION_PARTICLE_SPEED = 8,
    COMPLETION_PARTICLE_SIZE = 0.12,

    -- Camera (client-side, optional)
    CAMERA_FOCUS_ENABLED = false,     -- opt-in; off by default
    CAMERA_FOCUS_TIME = 0.6,
    CAMERA_RETURN_DELAY = 1.5,
    CAMERA_RETURN_TIME = 1.0,
}

----------------------------------------------------------------
-- SOUND IDS (free Roblox assets)
----------------------------------------------------------------

-- We use a single versatile thunk sound and pitch-shift per material.
-- These are well-known free asset IDs.
local SOUND_IDS = {
    THUNK = "rbxassetid://314428418",   -- solid impact / thunk
    CHIME = "rbxassetid://9116245410",  -- soft chime for Neon/Glass
}

-- Material → pitch mapping
local MATERIAL_PITCHES = {
    -- Stone family: low thunk
    [Enum.Material.Slate]       = 0.8,
    [Enum.Material.Concrete]    = 0.8,
    [Enum.Material.Brick]       = 0.8,
    [Enum.Material.Cobblestone] = 0.8,
    [Enum.Material.Rock]        = 0.8,
    [Enum.Material.Sand]        = 0.8,
    [Enum.Material.Marble]      = 0.8,
    [Enum.Material.Granite]     = 0.8,

    -- Wood family: mid knock
    [Enum.Material.Wood]        = 1.0,
    [Enum.Material.WoodPlanks]  = 1.0,
    [Enum.Material.Bamboo]      = 1.0,
    [Enum.Material.CorrodedMetal] = 1.0, -- has a woody quality

    -- Metal family: sharp clink
    [Enum.Material.Metal]       = 1.3,
    [Enum.Material.DiamondPlate] = 1.3,
    [Enum.Material.Foil]        = 1.3,

    -- Glass / Neon family: soft chime
    [Enum.Material.Neon]        = 1.5,
    [Enum.Material.Glass]       = 1.5,
    [Enum.Material.Ice]         = 1.5,
    [Enum.Material.ForceField]  = 1.5,
}

-- Default pitch for materials not listed above
local DEFAULT_PITCH = 0.9

----------------------------------------------------------------
-- INTERNAL HELPERS
----------------------------------------------------------------

--[[
    Get the pitch for a given material.
    @param material Enum.Material
    @return number pitch multiplier
]]
local function getPitchForMaterial(material: Enum.Material): number
    return MATERIAL_PITCHES[material] or DEFAULT_PITCH
end

--[[
    Determine whether to use the chime sound or the thunk sound.
    Glass/Neon family uses chime; everything else uses thunk.
]]
local function getSoundIdForMaterial(material: Enum.Material): string
    if material == Enum.Material.Neon
    or material == Enum.Material.Glass
    or material == Enum.Material.Ice
    or material == Enum.Material.ForceField then
        return SOUND_IDS.CHIME
    end
    return SOUND_IDS.THUNK
end

--[[
    Create a ParticleEmitter for a burst effect.
    The emitter is configured for a one-shot burst and then cleaned up by Debris.
    @param position Vector3 -- world position for the burst
    @param color Color3 -- particle color
    @param count number -- particle count
    @param lifetime number -- how long the emitter should live after creation
    @param speed number -- particle emission speed
    @param size number -- base particle size
    @return ParticleEmitter -- the emitter (parented to an attachment on a temporary part)
]]
local function createParticleBurst(
    position: Vector3,
    color: Color3,
    count: number,
    lifetime: number,
    speed: number,
    size: number
): ParticleEmitter?
    -- Create a tiny invisible carrier part at the burst position
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
    emitter.Rate = 0                    -- manual emit
    emitter.EmitCount = count
    emitter.Parent = attachment

    -- Emit once
    emitter:Emit(count)

    -- Clean up carrier after particles have faded
    Debris:AddItem(carrier, lifetime + 0.5)

    return emitter
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Animate a single part appearing.

    The part should already be parented to the workspace. This function:
    1. Records the target size and transparency.
    2. Shrinks the part to near-zero and makes it invisible.
    3. Tweens size (Back ease) and transparency (Quad ease) simultaneously.
    4. On completion, fires a landing particle burst and placement sound.

    @param part BasePart -- the part to animate (must be parented)
    @param targetTransparency number? -- the final transparency (defaults to part's current value)
]]
function BuildAnimator.animatePart(part: BasePart, targetTransparency: number?)
    if not part or not part:IsA("BasePart") then
        warn("[Lucineer] BuildAnimator.animatePart: expected a BasePart, got " .. tostring(part))
        return
    end

    -- Record target values BEFORE we squash the part
    local targetSize = part.Size
    local targetTrans = targetTransparency or part.Transparency
    local partColor = part.Color
    local partMaterial = part.Material
    local landingPos = part.Position

    -- Snap to invisible / tiny
    part.Transparency = 1
    part.Size = Vector3.new(0.1, 0.1, 0.1)

    -- Size tween (Back ease — subtle bounce)
    local sizeTween = TweenService:Create(
        part,
        TweenInfo.new(
            CONFIG.PART_TWEEN_TIME,
            CONFIG.SIZE_EASING_STYLE,
            CONFIG.SIZE_EASING_DIRECTION
        ),
        { Size = targetSize }
    )

    -- Transparency tween (Quad ease — smooth fade)
    local transTween = TweenService:Create(
        part,
        TweenInfo.new(
            CONFIG.PART_TWEEN_TIME,
            CONFIG.TRANS_EASING_STYLE,
            CONFIG.TRANS_EASING_DIRECTION
        ),
        { Transparency = targetTrans }
    )

    -- Fire landing effects when the size tween completes
    sizeTween.Completed:Connect(function(playbackState)
        if playbackState == Enum.PlaybackState.Completed then
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

    sizeTween:Play()
    transTween:Play()
end

--[[
    Animate a batch of parts with staggered timing.

    Parts are revealed one at a time with STAGGER_DELAY between each,
    creating the cinematic "Lucineer is building" effect. A 10-part
    build takes ~0.8s; a 20-part castle takes ~1.6s.

    The last part in the batch triggers a completion burst:
    20-30 multi-colored particles with a longer lifetime, plus a
    satisfying low-pitched thunk.

    @param parts { BasePart } -- array of parts to animate (all should be parented)
    @param centerPosition Vector3? -- the center of the build area, used for completion burst and camera focus
]]
function BuildAnimator.animateBatch(parts: { BasePart }, centerPosition: Vector3?)
    if not parts or #parts == 0 then
        return
    end

    local count = #parts
    centerPosition = centerPosition or parts[1].Position

    for i, part in ipairs(parts) do
        local delay = (i - 1) * CONFIG.STAGGER_DELAY

        task.delay(delay, function()
            -- Determine if this is the last part
            local isLast = (i == count)

            if isLast then
                -- For the last part, hook the completion burst into its landing
                local targetSize = part.Size
                local targetTrans = part.Transparency
                local partColor = part.Color
                local partMaterial = part.Material
                local landingPos = part.Position

                -- Snap to invisible / tiny
                part.Transparency = 1
                part.Size = Vector3.new(0.1, 0.1, 0.1)

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

                -- Landing + completion burst on finish
                sizeTween.Completed:Connect(function(playbackState)
                    if playbackState == Enum.PlaybackState.Completed then
                        -- Standard landing burst
                        createParticleBurst(
                            landingPos,
                            partColor,
                            CONFIG.LANDING_PARTICLE_COUNT,
                            CONFIG.LANDING_PARTICLE_LIFETIME,
                            CONFIG.LANDING_PARTICLE_SPEED,
                            CONFIG.LANDING_PARTICLE_SIZE
                        )

                        -- Placement sound for this part
                        BuildAnimator.playPlacementSound(partMaterial, landingPos)

                        -- COMPLETION BURT — bigger, multi-colored, at center
                        task.wait(0.05) -- tiny delay so it reads as distinct

                        local completionColors = {
                            Color3.fromRGB(255, 220, 100), -- warm gold
                            Color3.fromRGB(100, 200, 255), -- soft blue
                            Color3.fromRGB(255, 150, 200), -- pink
                            Color3.fromRGB(150, 255, 150), -- green
                            Color3.fromRGB(255, 255, 255), -- white
                        }

                        for _, burstColor in ipairs(completionColors) do
                            createParticleBurst(
                                centerPosition,
                                burstColor,
                                math.floor(CONFIG.COMPLETION_PARTICLE_COUNT / #completionColors),
                                CONFIG.COMPLETION_PARTICLE_LIFETIME,
                                CONFIG.COMPLETION_PARTICLE_SPEED,
                                CONFIG.COMPLETION_PARTICLE_SIZE
                            )
                        end

                        -- Completion thunk — low and satisfying
                        local completionSound = Instance.new("Sound")
                        completionSound.SoundId = SOUND_IDS.THUNK
                        completionSound.Volume = 0.6
                        completionSound.PlaybackSpeed = 0.6 -- low pitch
                        completionSound.Parent = workspace
                        completionSound:Play()
                        Debris:AddItem(completionSound, 2)

                        -- Camera return (client-side, optional)
                        if CONFIG.CAMERA_FOCUS_ENABLED and RunService:IsClient() then
                            BuildAnimator._returnCamera()
                        end
                    end
                end)

                sizeTween:Play()
                transTween:Play()
            else
                -- Standard animated part
                BuildAnimator.animatePart(part)
            end
        end)
    end

    -- Camera focus (client-side, optional)
    if CONFIG.CAMERA_FOCUS_ENABLED and RunService:IsClient() then
        BuildAnimator._focusCamera(centerPosition)
    end
end

--[[
    Emit a particle burst at a given position.

    Convenience method for manual / external burst triggers.

    @param position Vector3 -- world position
    @param color Color3 -- particle color
    @param count number? -- particle count (defaults to LANDING_PARTICLE_COUNT)
]]
function BuildAnimator.burst(position: Vector3, color: Color3, count: number?)
    createParticleBurst(
        position,
        color,
        count or CONFIG.LANDING_PARTICLE_COUNT,
        CONFIG.LANDING_PARTICLE_LIFETIME,
        CONFIG.LANDING_PARTICLE_SPEED,
        CONFIG.LANDING_PARTICLE_SIZE
    )
end

--[[
    Play a placement sound appropriate for the given material.

    Creates a temporary Sound at the position, plays it, and cleans up.

    @param material Enum.Material -- the part's material
    @param position Vector3 -- where to play the sound (world position)
]]
function BuildAnimator.playPlacementSound(material: Enum.Material, position: Vector3)
    local soundId = getSoundIdForMaterial(material)
    local pitch = getPitchForMaterial(material)

    local sound = Instance.new("Sound")
    sound.SoundId = soundId
    sound.Volume = 0.35
    sound.PlaybackSpeed = pitch
    sound.RollOffMaxDistance = 60
    sound.RollOffMinDistance = 10
    sound.RollOffMode = Enum.RollOffMode.InverseTapered

    -- Attach to a temporary carrier part at the position for 3D spatialization
    local carrier = Instance.new("Part")
    carrier.Name = "SoundCarrier"
    carrier.Size = Vector3.new(0.1, 0.1, 0.1)
    carrier.Position = position
    carrier.Transparency = 1
    carrier.CanCollide = false
    carrier.CanQuery = false
    carrier.Anchored = true
    carrier.Parent = workspace

    sound.Parent = carrier
    sound:Play()

    -- Clean up after the sound finishes
    Debris:AddItem(carrier, 3)
end

----------------------------------------------------------------
-- CLIENT-SIDE CAMERA HELPERS (optional)
----------------------------------------------------------------

--[[
    Gently tween the camera to frame the build area during construction.
    Client-side only — does nothing on the server.
    @param position Vector3 -- center of the build area to frame
]]
function BuildAnimator._focusCamera(position: Vector3)
    if not RunService:IsClient() then return end

    local camera = workspace.CurrentCamera
    if not camera then return end

    -- Calculate a framing offset: back and up from the build center
    local offset = Vector3.new(0, 15, 25)
    local targetCFrame = CFrame.lookAt(position + offset, position)

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
end

--[[
    Return camera control to the player after construction completes.
    Client-side only.
]]
function BuildAnimator._returnCamera()
    if not RunService:IsClient() then return end

    local player = Players.LocalPlayer
    if not player then return end

    -- Delay slightly so the completion burst is visible
    task.delay(CONFIG.CAMERA_RETURN_DELAY, function()
        local camera = workspace.CurrentCamera
        if not camera then return end

        -- Smoothly return to the player's default camera position
        camera.CameraType = Enum.CameraType.Custom

        -- Optional: tween back. Since we don't know the exact player CFrame,
        -- we just restore the camera type and let the player's camera scripts take over.
        -- A more sophisticated version could tween back to the HumanoidRootPart.
    end)
end

----------------------------------------------------------------
-- CONFIGURATION OVERRIDE
----------------------------------------------------------------

--[[
    Update CONFIG values at runtime.
    Allows external modules to tune animation parameters.

    @param overrides table -- key/value pairs to merge into CONFIG
]]
function BuildAnimator.configure(overrides: table)
    for key, value in pairs(overrides or {}) do
        CONFIG[key] = value
    end
end

--[[
    Get a copy of the current config (read-only inspection).
    @return table
]]
function BuildAnimator.getConfig(): table
    local copy = {}
    for key, value in pairs(CONFIG) do
        copy[key] = value
    end
    return copy
end

return BuildAnimator
