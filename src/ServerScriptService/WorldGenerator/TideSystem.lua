--[[
    WorldGenerator/TideSystem.lua
    Slackwater — Tidal Cycle Simulator

    Manages the real-time tide cycle that affects the coastline biome.

    Features:
      - 4 phases: low, rising, high, falling
      - Adjustable cycle length (default 20 min real-time)
      - Low tide exposes beach resources (calls Resources.SpawnTideLoot on falling→low transition)
      - High tide brings new salvage from the Channel
      - Storm tide (5% chance per cycle) damages structures near shoreline
      - Visual: Terrain water level rises and falls smoothly
      - Audio hook: calls AudioManager to change wave intensity

    API:
        TideSystem.Init(config, worldSeed, terrainObject)
        TideSystem.Start()
        TideSystem.Stop()
        TideSystem.GetPhase()
        TideSystem.GetWaterLevel()
        TideSystem.SetOnPhaseChange(callback)
        TideSystem.SetOnStorm(callback)
]]

local TideSystem = {}

-- Dependencies
local Config

-- State
TideSystem._running = false
TideSystem._elapsed = 0          -- seconds since cycle start
TideSystem._cycleLength = 1200   -- 20 minutes default
TideSystem._waterLevel = 0       -- current water height (studs)
TideSystem._baseWaterLevel = 0   -- baseline water level from terrain
TideSystem._currentPhase = "low"
TideSystem._terrain = nil        -- Roblox Terrain instance
TideSystem._worldSeed = 1
TideSystem._stormActive = false
TideSystem._nextStormRoll = true -- whether to roll for storm next high tide
TideSystem._connection = nil     -- RunService connection

-- Callbacks
TideSystem._onPhaseChange = nil  -- function(phaseName, waterLevel)
TideSystem._onStorm = nil        -- function(stormData)
TideSystem._onTideLoot = nil     -- function(phaseName) — called for loot spawning

-- Phase definitions (relative durations summing to 1.0)
local PHASES = {
    { name = "low",    portion = 0.20 },
    { name = "rising", portion = 0.30 },
    { name = "high",   portion = 0.20 },
    { name = "falling", portion = 0.30 },
}

-- Water level offsets per phase (studs relative to base)
local PHASE_OFFSETS = {
    low = -6,
    rising = 0,    -- interpolated: low→high
    high = 6,
    falling = 0,   -- interpolated: high→low
}

--==========================================================================
-- LOCAL HELPERS
--==========================================================================

--- Smooth interpolation between two values.
local function smoothstep(a, b, t)
    t = math.clamp(t, 0, 1)
    local s = t * t * (3 - 2 * t)
    return a + (b - a) * s
end

--- Determine which phase we're in and the interpolation factor.
--- @param elapsed number  Seconds since cycle start
--- @param cycleLength number  Total cycle length in seconds
--- @return string phaseName, number waterLevel
local function computePhaseAndLevel(elapsed, cycleLength)
    local progress = (elapsed % cycleLength) / cycleLength

    local cumulative = 0
    for i = 1, #PHASES do
        local phaseEnd = cumulative + PHASES[i].portion
        if progress < phaseEnd then
            local phaseName = PHASES[i].name
            local localT = (progress - cumulative) / PHASES[i].portion

            if phaseName == "low" then
                return phaseName, PHASE_OFFSETS.low
            elseif phaseName == "high" then
                return phaseName, PHASE_OFFSETS.high
            elseif phaseName == "rising" then
                -- Interpolate from low offset to high offset
                return phaseName, smoothstep(PHASE_OFFSETS.low, PHASE_OFFSETS.high, localT)
            else -- falling
                return phaseName, smoothstep(PHASE_OFFSETS.high, PHASE_OFFSETS.low, localT)
            end
        end
        cumulative = phaseEnd
    end

    -- Fallback
    return "low", PHASE_OFFSETS.low
end

--- Roll for storm tide (5% chance).
local function rollStorm()
    local r = math.random()
    return r < (Config.tide.stormChance or 0.05)
end

--- Apply storm damage to structures near shoreline.
--- @param waterLevel number  Current water level (studs)
local function applyStormDamage(waterLevel)
    local stormRadius = Config.tide.stormDamageRadius or 20
    local stormDamage = Config.tide.stormDamage or 35

    -- Find structures near the shoreline.
    -- We look for Models tagged "Structure" within stormRadius of current water level.
    -- This is game-specific; we use CollectionService for tagging.
    local CollectionService = game:GetService("CollectionService")
    local structures = CollectionService:GetTagged("Structure")

    local damaged = 0
    for _, structure in ipairs(structures) do
        if structure:IsA("Model") and structure.PrimaryPart then
            local pos = structure.PrimaryPart.Position
            -- Check if near shoreline (close to water level in Y, within radius in XZ of coastline)
            local heightDiff = math.abs(pos.Y - waterLevel)
            if heightDiff < stormRadius then
                -- Apply damage via an attribute or humanoid if available
                local currentHealth = structure:GetAttribute("Health")
                local maxHealth = structure:GetAttribute("MaxHealth")
                if currentHealth and maxHealth then
                    local newHealth = math.max(0, currentHealth - stormDamage)
                    structure:SetAttribute("Health", newHealth)
                    damaged = damaged + 1
                    if newHealth <= 0 then
                        -- Structure destroyed
                        structure:SetAttribute("Destroyed", true)
                        -- Fire a BindableEvent if one exists
                        local destroyEvent = structure:FindFirstChild("OnDestroyed")
                        if destroyEvent and destroyEvent:IsA("BindableEvent") then
                            destroyEvent:Fire()
                        end
                    end
                end
            end
        end
    end

    return damaged
end

--==========================================================================
-- UPDATE LOOP
--==========================================================================

local function update(dt)
    TideSystem._elapsed = TideSystem._elapsed + dt

    local cycleLength = TideSystem._cycleLength
    if cycleLength <= 0 then
        return -- tide disabled (creative mode)
    end

    -- Check for cycle wrap
    local prevElapsed = TideSystem._elapsed - dt
    local wrappedCycle = math.floor(prevElapsed / cycleLength) ~= math.floor(TideSystem._elapsed / cycleLength)

    local phaseName, offset = computePhaseAndLevel(TideSystem._elapsed, cycleLength)
    TideSystem._waterLevel = TideSystem._baseWaterLevel + offset

    -- Update visual water height
    if TideSystem._terrain then
        -- We adjust the Terrain water by moving a Region3 water volume.
        -- Roblox Terrain does not expose direct "set water height" but we can
        -- use FillBlock / with a water part at the correct height.
        -- For performance, we only update if the level changed by at least 0.5 studs.
        local lastApplied = TideSystem._lastAppliedLevel or TideSystem._waterLevel
        if math.abs(TideSystem._waterLevel - lastApplied) >= 0.5 then
            TideSystem._applyWaterLevel(TideSystem._waterLevel)
            TideSystem._lastAppliedLevel = TideSystem._waterLevel
        end
    end

    -- Phase change detection
    if phaseName ~= TideSystem._currentPhase then
        local oldPhase = TideSystem._currentPhase
        TideSystem._currentPhase = phaseName

        -- Phase transition events
        if phaseName == "low" then
            -- Low tide: expose beach resources
            if TideSystem._onTideLoot then
                TideSystem._onTideLoot("low")
            end
        elseif phaseName == "high" then
            -- High tide: bring new salvage from the Channel
            if TideSystem._onTideLoot then
                TideSystem._onTideLoot("high")
            end

            -- Roll for storm tide
            if TideSystem._nextStormRoll then
                local isStorm = rollStorm()
                if isStorm then
                    TideSystem._stormActive = true
                    print("[WorldGenerator.TideSystem] ⚡ STORM TIDE triggered!")
                    local damagedCount = applyStormDamage(TideSystem._waterLevel)
                    if TideSystem._onStorm then
                        TideSystem._onStorm({
                            waterLevel = TideSystem._waterLevel,
                            damageRadius = Config.tide.stormDamageRadius,
                            structuresDamaged = damagedCount,
                        })
                    end
                end
            end
            TideSystem._nextStormRoll = false
        end

        -- Reset storm roll at cycle wrap
        if wrappedCycle then
            TideSystem._nextStormRoll = true
            TideSystem._stormActive = false
        end

        -- Fire phase change callback
        if TideSystem._onPhaseChange then
            TideSystem._onPhaseChange(phaseName, TideSystem._waterLevel)
        end

        -- Audio intensity change
        TideSystem._updateAudio(phaseName)
    end
end

-- Apply water level to terrain (internal)
TideSystem._applyWaterLevel = function(level)
    if not TideSystem._terrain then return end

    -- Strategy: Use a large flat water block at the given height.
    -- We create or update a single Part with water material covering the ocean area.
    -- This is simpler than Terrain:FillBlock for dynamic changes.
    local oceanPart = workspace:FindFirstChild("__TideOcean")
    if not oceanPart then
        oceanPart = Instance.new("Part")
        oceanPart.Name = "__TideOcean"
        oceanPart.Anchored = true
        oceanPart.CanCollide = false
        oceanPart.Material = Enum.Material.Glass
        oceanPart.Transparency = 0.6
        oceanPart.Color = Color3.fromRGB(40, 80, 120)
        oceanPart.Size = Vector3.new(4096, 2, 4096)
        oceanPart.Position = Vector3.new(0, level, 0)
        oceanPart.Parent = workspace
    else
        oceanPart.Position = Vector3.new(oceanPart.Position.X, level, oceanPart.Position.Z)
    end
end

-- Update audio intensity (internal)
TideSystem._updateAudio = function(phaseName)
    -- Hook into AudioManager if available
    local audioManager = workspace:FindFirstChild("AudioManager")
    if audioManager and audioManager:IsA("Configuration") then
        local intensity = "calm"
        if phaseName == "high" or phaseName == "rising" then
            intensity = "moderate"
        end
        if TideSystem._stormActive then
            intensity = "storm"
        end
        audioManager:SetAttribute("WaveIntensity", intensity)
    end
end

--==========================================================================
-- PUBLIC API
--==========================================================================

--- Initialize the tide system.
--- @param worldConfig table     The active game-mode config (uses tideSpeed).
--- @param worldSeed number      World seed.
--- @param terrain table|Instance  Roblox Terrain instance (optional).
function TideSystem.Init(worldConfig, worldSeed, terrain)
    Config = Config or require(script.Parent.Config)

    TideSystem._cycleLength = Config.tide.cycleLength / (worldConfig.tideSpeed or 1.0)
    TideSystem._baseWaterLevel = Config.noise.waterLevel
    TideSystem._waterLevel = TideSystem._baseWaterLevel
    TideSystem._worldSeed = worldSeed or 1
    TideSystem._terrain = terrain
    TideSystem._elapsed = 0
    TideSystem._currentPhase = "low"
    TideSystem._stormActive = false
    TideSystem._nextStormRoll = true

    -- If tideSpeed is 0, tide is disabled
    if worldConfig.tideSpeed == 0 then
        TideSystem._cycleLength = 0
        print("[WorldGenerator.TideSystem] Tide disabled (tideSpeed = 0)")
    else
        print(string.format("[WorldGenerator.TideSystem] Initialized. Cycle=%.1f min",
            TideSystem._cycleLength / 60))
    end
end

--- Start the tide simulation.
--- Connects to RunService.Heartbeat.
function TideSystem.Start()
    if TideSystem._running then return end
    if TideSystem._cycleLength == 0 then return end -- disabled

    local RunService = game:GetService("RunService")
    TideSystem._connection = RunService.Heartbeat:Connect(function(dt)
        update(dt)
    end)
    TideSystem._running = true
    print("[WorldGenerator.TideSystem] Started")
end

--- Stop the tide simulation.
function TideSystem.Stop()
    if TideSystem._connection then
        TideSystem._connection:Disconnect()
        TideSystem._connection = nil
    end
    TideSystem._running = false
    print("[WorldGenerator.TideSystem] Stopped")
end

--- Get current phase name.
--- @return string
function TideSystem.GetPhase()
    return TideSystem._currentPhase
end

--- Get current water level (studs).
--- @return number
function TideSystem.GetWaterLevel()
    return TideSystem._waterLevel
end

--- Get whether a storm tide is currently active.
--- @return boolean
function TideSystem.IsStormActive()
    return TideSystem._stormActive
end

--- Get progress through the current cycle (0..1).
--- @return number
function TideSystem.GetCycleProgress()
    if TideSystem._cycleLength == 0 then return 0 end
    return (TideSystem._elapsed % TideSystem._cycleLength) / TideSystem._cycleLength
end

--- Set callback for phase changes.
--- @param callback function(phaseName, waterLevel)
function TideSystem.SetOnPhaseChange(callback)
    TideSystem._onPhaseChange = callback
end

--- Set callback for storm tide events.
--- @param callback function(stormData)
function TideSystem.SetOnStorm(callback)
    TideSystem._onStorm = callback
end

--- Set callback for tide loot events (low tide exposes, high tide washes in).
--- @param callback function(phaseName)
function TideSystem.SetOnTideLoot(callback)
    TideSystem._onTideLoot = callback
end

--- Serialize tide state for persistence.
--- @return table
function TideSystem.Serialize()
    return {
        elapsed = TideSystem._elapsed,
        waterLevel = TideSystem._waterLevel,
        currentPhase = TideSystem._currentPhase,
        stormActive = TideSystem._stormActive,
        cycleLength = TideSystem._cycleLength,
    }
end

--- Restore tide state from data.
--- @param data table
function TideSystem.Deserialize(data)
    if not data then return end
    TideSystem._elapsed = data.elapsed or 0
    TideSystem._waterLevel = data.waterLevel or TideSystem._baseWaterLevel
    TideSystem._currentPhase = data.currentPhase or "low"
    TideSystem._stormActive = data.stormActive or false
    TideSystem._cycleLength = data.cycleLength or TideSystem._cycleLength
end

return TideSystem
