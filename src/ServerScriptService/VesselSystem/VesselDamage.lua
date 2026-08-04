--[[
    VesselSystem/VesselDamage.lua
    Slackwater — Hull Damage and Sinking System

    "A boat is a conversation between wood and water. When the wood stops
     talking back, the water comes in. That's all sinking is — the water
     winning the argument."

    ───────────────────────────────────────────────
    DAMAGE MODEL:

    The hull is divided into 5 sections, each tracking its own HP:
      • BOW       — takes the brunt of wave pounding and head-on collisions
      • PORT      — left side, broadside collisions
      • STARBOARD — right side, broadside collisions
      • STERN     — rear, following-sea damage, engine area
      • KEEL      — underside, grounding damage, most critical for buoyancy

    DAMAGE SOURCES:

    1. COLLISION
       When the vessel hits something solid at speed, damage is applied to
       the section facing the impact. Rock strikes at speed are catastrophic.
       Damage = f(impact_speed, section_armor, mass_ratio)

    2. WAVE DAMAGE
       Storm waves stress hull joints. Every wave tick during storms applies
       small damage spread across all sections. Reinforced hulls take less.

    3. GROUNDING
       Keel strike on the bottom. Damage proportional to impact speed.
       Applied entirely to the KEEL section.

    4. SINKING
       When total hull HP reaches 0, the boat begins to flood.
       Over 30 seconds:
         a) Water effects (bubbles, spray)
         b) Boat sinks lower in the water (buoyancy decreases)
         c) At -15 studs, boat despawns and players are ejected
       Players can abandon ship at any point during sinking.

    5. REPAIR
       Lucineier can repair hull sections at the dock for materials.
       Each section repaired independently. Keel requires haul-out.

    INTEGRATION:
        VesselPhysics  → grounding damage events
        WeatherSystem  → wave stress damage during storms
        VesselTypes    → section HP values
        EraSystem      → repair costs scale by era

    API:
        VesselDamage.init(vesselModel, vesselConfig, vesselState)
        VesselDamage.applyCollisionDamage(vesselState, impactSpeed, impactPoint, normalVec)
        VesselDamage.applyWaveDamage(vesselState, waveIntensity, dt)
        VesselDamage.applyGroundingDamage(vesselState, impactSpeed)
        VesselDamage.getHullIntegrity(vesselState) → 0.0 to 1.0
        VesselDamage.getSectionHP(vesselState, sectionName) → number
        VesselDamage.repairSection(vesselState, sectionName, amount)
        VesselDamage.isSinking(vesselState) → boolean
        VesselDamage.update(dt)  — called per vessel every frame
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local VesselDamage = {}

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

-- Collision damage
local COLLISION_BASE_DAMAGE = 2.0      -- base damage per stud/sec of impact
local COLLISION_MASS_FACTOR = 0.5      -- how much the OTHER object's mass matters
local ROCK_COLLISION_MULT = 3.0        -- hitting rock is worse than hitting wood

-- Wave stress damage
local WAVE_DAMAGE_BASE = 0.5           -- per-second damage during light storm
local WAVE_DAMAGE_STORM = 2.0          -- per-second damage during heavy storm
local WAVE_DAMAGE_INTERVAL = 1.0       -- apply damage every N seconds (not every frame)

-- Grounding damage
local GROUNDING_BASE_DAMAGE = 8.0      -- per stud/sec over threshold
local KEEL_CRITICAL_FRAC = 0.0         -- keel at 0 = instant sinking

-- Sinking
local SINK_DURATION = 30.0             -- seconds from flood start to despawn
local SINK_DEPTH = 15.0               -- how far the boat sinks before despawning
local SINK_BUOYANCY_LOSS = 0.95        -- buoyancy multiplier at full flood

-- Repair
local REPAIR_RATE = 10.0               -- HP per second when repairing at dock
local REPAIR_COST_PER_HP = 0.5         -- material units per HP repaired

-- Section names
local SECTIONS = { "bow", "port", "starboard", "stern", "keel" }

----------------------------------------------------------------
-- STATE (per vessel)
----------------------------------------------------------------

-- vesselPrimaryPart → damage state
local damageStates = {}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

--[[
    Get the weather system safely.
]]
local function getWeatherSystem()
    local ok, ws = pcall(function()
        return require(game.ServerScriptService.WeatherSystem)
    end)
    if ok then return ws end
    return nil
end

--[[
    Determine which hull section faces a given world direction.
    @param vesselCF CFrame
    @param worldDirection Vector3 (direction from vessel to impact point)
    @return string section name
]]
local function getSectionFromDirection(vesselCF, worldDirection)
    -- Transform world direction to local space
    local localDir = vesselCF:VectorToObjectSpace(worldDirection)

    -- In vessel-local space:
    -- +Z = bow, -Z = stern, +X = port, -X = starboard, -Y = keel
    local absX, absY, absZ = math.abs(localDir.X), math.abs(localDir.Y), math.abs(localDir.Z)

    if absY > absX and absY > absZ then
        -- Impact is primarily vertical → keel
        return "keel"
    elseif absZ > absX then
        -- Impact is fore/aft
        if localDir.Z > 0 then
            return "bow"
        else
            return "stern"
        end
    else
        -- Impact is port/starboard
        if localDir.X > 0 then
            return "port"
        else
            return "starboard"
        end
    end
end

--[[
    Create visual damage effects on a section.
    @param vesselModel Model
    @param sectionName string
    @param integrity number (0-1, current HP fraction of this section)
]]
local function updateSectionVisuals(vesselModel, sectionName, integrity)
    local part = vesselModel:FindFirstChild("Hull_" .. sectionName, true)
    if not part or not part:IsA("BasePart") then return end

    -- Darken and crack based on damage level
    if integrity < 0.5 then
        local darken = 0.5 + integrity  -- 0.5 at 0% HP, 1.0 at 50% HP
        -- Only darken once (don't reapply every frame)
        if not part:GetAttribute("DamageDarkened") then
            part.Color = Color3.new(part.Color.R * darken, part.Color.G * darken, part.Color.B * darken)
            part:SetAttribute("DamageDarkened", true)
        end
    end

    if integrity < 0.25 and not part:FindFirstChild("CrackEffect") then
        -- Add crack decal/effect
        local crackLight = Instance.new("SurfaceLight")
        crackLight.Name = "CrackEffect"
        crackLight.Face = Enum.NormalId.Top
        crackLight.Color = Color3.fromRGB(255, 200, 100)
        crackLight.Range = 3
        crackLight.Brightness = 0.3
        crackLight.Parent = part
    end
end

----------------------------------------------------------------
-- SINKING
----------------------------------------------------------------

--[[
    Begin the sinking sequence for a vessel.
    @param state table damage state
]]
local function beginSinking(state)
    if state.sinking then return end  -- already sinking

    state.sinking = true
    state.sinkTimer = 0
    state.vesselModel:SetAttribute("Sinking", true)

    local vesselModel = state.vesselModel
    local primaryPart = vesselModel.PrimaryPart

    -- Visual: water spray and bubbles
    local bubbleEmitter = Instance.new("ParticleEmitter")
    bubbleEmitter.Name = "SinkingBubbles"
    bubbleEmitter.Color = ColorSequence.new(Color3.fromRGB(200, 220, 255))
    bubbleEmitter.Size = NumberSequence.new(0.5, 2)
    bubbleEmitter.Rate = 30
    bubbleEmitter.Speed = NumberRange.new(2, 5)
    bubbleEmitter.SpreadAngle = Vector2.new(45, 45)
    bubbleEmitter.Lifetime = NumberRange.new(2, 4)
    bubbleEmitter.Parent = primaryPart

    -- Sound: groaning hull, rushing water
    local groanSound = Instance.new("Sound")
    groanSound.Name = "HullGroan"
    groanSound.SoundId = "rbxassetid://9118858002"
    groanSound.Volume = 0.6
    groanSound.PlaybackSpeed = 0.5
    groanSound.Parent = primaryPart
    groanSound:Play()
    Debris:AddItem(groanSound, SINK_DURATION)

    -- Eject all players from the vessel
    local HelmController
    local ok, hc = pcall(function()
        return require(script.Parent:WaitForChild("HelmController"))
    end)
    if ok then HelmController = hc end

    if HelmController then
        local Players = game:GetService("Players")
        for _, player in ipairs(Players:GetPlayers()) do
            if HelmController.isPlayerAtHelm(player) then
                local activeVessel = HelmController.getActiveVessel(player)
                if activeVessel and activeVessel.model == vesselModel then
                    HelmController.disembark(player)
                    -- Place player in the water
                    local char = player.Character
                    if char and char:FindFirstChild("HumanoidRootPart") then
                        char.HumanoidRootPart.CFrame = primaryPart.CFrame + Vector3.new(0, 5, 10)
                    end
                end
            end
        end
    end

    -- Warning to nearby players
    print(string.format("[VesselDamage] %s is SINKING!", state.config.displayName))

    -- Schedule despawn
    task.delay(SINK_DURATION, function()
        if vesselModel and vesselModel.Parent then
            -- Final despawn: fade out
            for _, part in ipairs(vesselModel:GetDescendants()) do
                if part:IsA("BasePart") then
                    local tween = TweenService:Create(part,
                        TweenInfo.new(2), {Transparency = 1})
                    tween:Play()
                end
            end
            Debris:AddItem(vesselModel, 3)
        end

        -- Clean up damage state
        if damageStates[primaryPart] then
            damageStates[primaryPart] = nil
        end
    end)
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the damage system for a vessel.
    @param vesselModel Model
    @param vesselConfig table (from VesselTypes)
    @param vesselState table (from VesselPhysics)
    @return table damageState
]]
function VesselDamage.init(vesselModel, vesselConfig, vesselState)
    local primaryPart = vesselModel.PrimaryPart

    -- Build per-section HP from config
    local sectionHP = {}
    local sectionMaxHP = {}
    for _, section in ipairs(SECTIONS) do
        local maxHP = vesselConfig.sectionHP[section] or 50
        sectionHP[section] = maxHP
        sectionMaxHP[section] = maxHP
    end

    local state = {
        vesselModel = vesselModel,
        primaryPart = primaryPart,
        config = vesselConfig,
        vesselState = vesselState,

        sectionHP = sectionHP,
        sectionMaxHP = sectionMaxHP,

        totalHP = 0,
        totalMaxHP = 0,

        waveDamageTimer = 0,
        sinking = false,
        sinkTimer = 0,

        -- Collision tracking (debounce rapid contacts)
        lastCollisionTime = 0,
    }

    -- Calculate totals
    for _, section in ipairs(SECTIONS) do
        state.totalHP = state.totalHP + sectionHP[section]
        state.totalMaxHP = state.totalMaxHP + sectionMaxHP[section]
    end

    -- Tag the vessel for damage system
    CollectionService:AddTag(vesselModel, "VesselDamageable")
    vesselModel:SetAttribute("HullIntegrity", 1.0)

    damageStates[primaryPart] = state

    print(string.format("[VesselDamage] Initialized for %s — total HP: %d",
        vesselConfig.displayName, state.totalMaxHP))

    return state
end

--[[
    Apply collision damage to the vessel.
    @param state table damage state
    @param impactSpeed number (studs/sec)
    @param impactPoint Vector3 (world position of impact)
    @param normalVec Vector3 (surface normal at impact — direction force came FROM)
]]
function VesselDamage.applyCollisionDamage(state, impactSpeed, impactPoint, normalVec)
    if state.sinking then return end

    -- Debounce: ignore collisions within 0.2s of the last one
    local now = tick()
    if now - state.lastCollisionTime < 0.2 then return end
    state.lastCollisionTime = now

    -- Only damage on significant impacts
    if impactSpeed < 3 then return end

    -- Determine which section was hit
    local vesselCF = state.primaryPart.CFrame
    local toImpact = (impactPoint - state.primaryPart.Position).Unit
    local section = getSectionFromDirection(vesselCF, toImpact)

    -- Calculate damage
    local damage = impactSpeed * COLLISION_BASE_DAMAGE

    -- Check if the hit object is rock (more damage)
    -- This is determined by raycasting from impact point
    local rayParams = RaycastParams.new()
    rayParams.FilterDescendantsInstances = {state.vesselModel}
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    local hitResult = Workspace:Raycast(
        state.primaryPart.Position,
        (impactPoint - state.primaryPart.Position),
        rayParams
    )
    if hitResult and hitResult.Instance then
        local mat = hitResult.Instance.Material
        if mat == Enum.Material.Rock or mat == Enum.Material.Slate or mat == Enum.Material.Basalt then
            damage = damage * ROCK_COLLISION_MULT
        end
    end

    -- Apply damage to the section
    state.sectionHP[section] = math.max(0, state.sectionHP[section] - damage)

    -- Recalculate total
    VesselDamage._recalculateTotal(state)

    -- Visual feedback
    updateSectionVisuals(state.vesselModel, section, state.sectionHP[section] / state.sectionMaxHP[section])

    -- Push the vessel away from impact
    local pushForce = normalVec * impactSpeed * state.config.mass * 0.3
    state.primaryPart:ApplyImpulse(pushForce)

    print(string.format("[VesselDamage] %s collision: %s section took %.1f damage (%.0f%% hull remaining)",
        state.config.displayName, section, damage,
        (state.totalHP / state.totalMaxHP) * 100))

    -- Check for sinking
    if state.totalHP <= 0 then
        beginSinking(state)
    end
end

--[[
    Apply wave stress damage over time (called during storms).
    @param state table damage state
    @param waveIntensity number (0-1)
    @param dt number
]]
function VesselDamage.applyWaveDamage(state, waveIntensity, dt)
    if state.sinking then return end

    state.waveDamageTimer = state.waveDamageTimer + dt
    if state.waveDamageTimer < WAVE_DAMAGE_INTERVAL then return end
    state.waveDamageTimer = 0

    -- Only damage in significant weather
    if waveIntensity < 0.3 then return end

    -- Damage scales with intensity
    local damagePerSec = WAVE_DAMAGE_BASE
    if waveIntensity > 0.7 then
        damagePerSec = WAVE_DAMAGE_STORM
    else
        damagePerSec = WAVE_DAMAGE_BASE + (waveIntensity - 0.3) * (WAVE_DAMAGE_STORM - WAVE_DAMAGE_BASE) / 0.4
    end

    local tickDamage = damagePerSec * WAVE_DAMAGE_INTERVAL

    -- Spread damage across all sections (hull stress is distributed)
    -- Bow takes slightly more (wave pounding)
    local distribution = { bow = 1.4, port = 0.8, starboard = 0.8, stern = 1.0, keel = 1.0 }
    local totalWeight = 5.0

    for _, section in ipairs(SECTIONS) do
        local sectionDamage = tickDamage * (distribution[section] / totalWeight)
        state.sectionHP[section] = math.max(0, state.sectionHP[section] - sectionDamage)
        updateSectionVisuals(state.vesselModel, section, state.sectionHP[section] / state.sectionMaxHP[section])
    end

    VesselDamage._recalculateTotal(state)

    -- Check for sinking
    if state.totalHP <= 0 then
        beginSinking(state)
    end
end

--[[
    Apply grounding damage (keel hit bottom).
    @param state table damage state
    @param impactSpeed number (studs/sec at moment of grounding)
]]
function VesselDamage.applyGroundingDamage(state, impactSpeed)
    if state.sinking then return end

    -- Damage to keel section
    local damage = impactSpeed * GROUNDING_BASE_DAMAGE

    state.sectionHP.keel = math.max(0, state.sectionHP.keel - damage)

    VesselDamage._recalculateTotal(state)

    updateSectionVisuals(state.vesselModel, "keel", state.sectionHP.keel / state.sectionMaxHP.keel)

    print(string.format("[VesselDamage] %s grounding: keel took %.1f damage",
        state.config.displayName, damage))

    -- If keel is completely gone, instant sinking
    if state.sectionHP.keel <= 0 then
        beginSinking(state)
    end
end

--[[
    Get overall hull integrity (0.0 to 1.0).
    @param state table damage state
    @return number
]]
function VesselDamage.getHullIntegrity(state)
    if state.totalMaxHP == 0 then return 0 end
    return state.totalHP / state.totalMaxHP
end

--[[
    Get current HP of a specific section.
    @param state table damage state
    @param sectionName string
    @return number
]]
function VesselDamage.getSectionHP(state, sectionName)
    return state.sectionHP[sectionName] or 0
end

--[[
    Get max HP of a specific section.
    @param state table damage state
    @param sectionName string
    @return number
]]
function VesselDamage.getSectionMaxHP(state, sectionName)
    return state.sectionMaxHP[sectionName] or 0
end

--[[
    Repair a specific section by a given amount.
    @param state table damage state
    @param sectionName string
    @param amount number HP to restore
    @return number actual HP restored
]]
function VesselDamage.repairSection(state, sectionName, amount)
    if state.sinking then return 0 end
    if not state.sectionHP[sectionName] then return 0 end

    local current = state.sectionHP[sectionName]
    local maxHP = state.sectionMaxHP[sectionName]
    local newHP = math.min(maxHP, current + amount)
    local actualRepair = newHP - current

    state.sectionHP[sectionName] = newHP
    VesselDamage._recalculateTotal(state)

    -- Clear damage visuals if section is mostly repaired
    if newHP / maxHP > 0.5 then
        local part = state.vesselModel:FindFirstChild("Hull_" .. sectionName, true)
        if part then
            part:SetAttribute("DamageDarkened", false)
            local crack = part:FindFirstChild("CrackEffect")
            if crack and newHP / maxHP > 0.75 then
                crack:Destroy()
            end
        end
    end

    return actualRepair
end

--[[
    Check if the vessel is sinking.
    @param state table damage state
    @return boolean
]]
function VesselDamage.isSinking(state)
    return state.sinking
end

--[[
    Get repair cost for a section (in material units).
    @param state table damage state
    @param sectionName string
    @return number material units needed
]]
function VesselDamage.getRepairCost(state, sectionName)
    if not state.sectionHP[sectionName] then return 0 end
    local missing = state.sectionMaxHP[sectionName] - state.sectionHP[sectionName]
    return math.ceil(missing * REPAIR_COST_PER_HP)
end

--[[
    Get all damage state for UI display.
    @param state table damage state
    @return table
]]
function VesselDamage.getDamageReport(state)
    local report = {}
    for _, section in ipairs(SECTIONS) do
        report[section] = {
            current = state.sectionHP[section],
            max = state.sectionMaxHP[section],
            integrity = state.sectionHP[section] / state.sectionMaxHP[section],
        }
    end
    report.total = {
        current = state.totalHP,
        max = state.totalMaxHP,
        integrity = VesselDamage.getHullIntegrity(state),
    }
    report.sinking = state.sinking
    report.sinkProgress = state.sinking and (state.sinkTimer / SINK_DURATION) or 0
    return report
end

----------------------------------------------------------------
-- INTERNAL
----------------------------------------------------------------

--[[
    Recalculate total HP from section HP values.
    @param state table
]]
function VesselDamage._recalculateTotal(state)
    state.totalHP = 0
    for _, section in ipairs(SECTIONS) do
        state.totalHP = state.totalHP + state.sectionHP[section]
    end
    state.vesselModel:SetAttribute("HullIntegrity", VesselDamage.getHullIntegrity(state))
end

--[[
    Update sinking progression.
    @param state table
    @param dt number
]]
function VesselDamage._updateSinking(state, dt)
    if not state.sinking then return end

    state.sinkTimer = state.sinkTimer + dt

    -- Gradually reduce buoyancy by adjusting probe forces
    local progress = state.sinkTimer / SINK_DURATION
    local sinkOffset = -progress * SINK_DEPTH

    -- Push the boat down by reducing buoyancy
    -- We do this by nudging the primary part downward gradually
    if state.vesselState and state.vesselState.probes then
        for _, probe in ipairs(state.vesselState.probes) do
            -- Reduce buoyancy force progressively
            local currentForce = probe.vectorForce.Force.Y
            local targetForce = currentForce * (1 - dt * 0.5)
            probe.vectorForce.Force = Vector3.new(0, targetForce, 0)
        end
    end

    -- Add downward force
    state.primaryPart:ApplyImpulse(Vector3.new(0, -50 * dt * state.config.mass * progress, 0))
end

----------------------------------------------------------------
-- STATIC UPDATE (called from a central heartbeat)
----------------------------------------------------------------

-- Connect a single heartbeat to update all damage states
RunService.Heartbeat:Connect(function(dt)
    local weather = getWeatherSystem()
    local waveIntensity = weather and weather.getWeatherIntensity() or 0
    local isStorm = weather and weather.isStormActive and weather.isStormActive() or false

    for primaryPart, state in pairs(damageStates) do
        if not primaryPart or not primaryPart.Parent then
            damageStates[primaryPart] = nil
            goto continue
        end

        -- Wave damage during storms
        if isStorm and waveIntensity > 0.3 then
            VesselDamage.applyWaveDamage(state, waveIntensity, dt)
        end

        -- Sinking progression
        VesselDamage._updateSinking(state, dt)

        -- Check for grounding events from physics
        local groundingImpact = state.vesselModel:GetAttribute("GroundingImpact")
        if groundingImpact and groundingImpact > 0 then
            VesselDamage.applyGroundingDamage(state, groundingImpact)
            state.vesselModel:SetAttribute("GroundingImpact", 0)
        end

        ::continue::
    end
end)

return VesselDamage
