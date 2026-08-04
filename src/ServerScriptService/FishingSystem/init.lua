--!strict
--[[
    FishingSystem — Slackwater's Core Economy
    ═══════════════════════════════════════════════════════════════
    "Cast. Wait. Bite. Fight. Catch. That's the rhythm.
     Everything else in this place is built on that rhythm."

    The fishing system is the primary economic activity in Slackwater.
    Players fish to earn scrap, scrap funds building, building earns
     Lucineer's respect, and respect unlocks the next era.

    This module bootstraps the fishing system in the correct order:
      1. FishCatalog   — species definitions (no dependencies)
      2. FishStocks    — living ocean populations (existing, depends on Config)
      3. GearSystem    — fishing equipment definitions (depends on EraSystem)
      4. FishSpawner   — runtime zone management (depends on FishStocks, Config)
      5. CatchMechanics — active fishing loop (depends on all above)
      6. MarketSystem  — selling catch to Earl (depends on FishCatalog, NPCManager)

    Call FishingSystem.init() once on server start.

    API:
        FishingSystem.init()
        FishingSystem.getModule(name) → module reference
        FishingSystem.startFishing(player) — begin a fishing session
        FishingSystem.stopFishing(player) — force-end a fishing session
        FishingSystem.isFishing(player) → boolean
]]

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------
local FishingSystem = {}

----------------------------------------------------------------
-- SUB-MODULE REFERENCES
----------------------------------------------------------------

-- Load order matters for dependencies
-- FishStocks serves as the fish catalog (species definitions + populations)
FishingSystem.FishCatalog = require(script:WaitForChild("FishStocks"))
FishingSystem.FishStocks = FishingSystem.FishCatalog  -- alias
FishingSystem.FishStocks = require(script:WaitForChild("FishStocks"))
FishingSystem.GearSystem = require(script:WaitForChild("GearSystem"))
FishingSystem.FishSpawner = require(script:WaitForChild("FishSpawner"))
FishingSystem.CatchMechanics = require(script:WaitForChild("CatchMechanics"))
FishingSystem.MarketSystem = require(script:WaitForChild("MarketSystem"))

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local initialized = false

-- Track which players are currently in a fishing session
-- key: Player, value: { gearId, zone, depth, startTime, vesselId? }
local activeSessions: {[Player]: table} = {}

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the fishing system.
    Call once on server start, after EraSystem and WorldGenerator.
]]
function FishingSystem.init()
    if initialized then
        warn("[FishingSystem] Already initialized.")
        return
    end

    -- Initialize sub-modules in order
    FishingSystem.FishCatalog.init()
    FishingSystem.FishStocks.init()
    FishingSystem.GearSystem.init()
    FishingSystem.FishSpawner.init()
    FishingSystem.CatchMechanics.init()
    FishingSystem.MarketSystem.init()

    -- Connect to player removal to clean up sessions
    local Players = game:GetService("Players")
    Players.PlayerRemoving:Connect(function(player)
        if activeSessions[player] then
            FishingSystem.stopFishing(player)
        end
    end)

    initialized = true
    print("[FishingSystem] Initialized — 6 species, 5 gear types, 4 zones. The ocean is open.")
end

--[[
    Get a sub-module by name.
    @param name string — "FishCatalog", "FishStocks", "GearSystem",
                         "FishSpawner", "CatchMechanics", "MarketSystem"
    @return table?
]]
function FishingSystem.getModule(name: string)
    return FishingSystem[name]
end

--[[
    Start a fishing session for a player.
    Validates that the player is near water or on a vessel, has valid gear,
    and is not already fishing.
    @param player Player
    @param gearId string — gear type identifier
    @return boolean success, string? errorMessage
]]
function FishingSystem.startFishing(player: Player, gearId: string): (boolean, string?)
    if not initialized then
        return false, "FishingSystem not initialized"
    end

    if activeSessions[player] then
        return false, "Already fishing"
    end

    -- Validate gear
    local gear = FishingSystem.GearSystem.getGear(gearId)
    if not gear then
        return false, "Unknown gear type: " .. tostring(gearId)
    end

    -- Determine zone from player position
    local character = player.Character
    if not character then
        return false, "No character"
    end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then
        return false, "No HumanoidRootPart"
    end

    local position = hrp.Position
    local zone = FishingSystem.FishStocks.getZoneAtPosition(position)
    local depth = FishingSystem.FishStocks.getDepthAtPosition(position, zone)

    -- Check if player is on a vessel (optional)
    local vesselId = nil
    local vesselAttr = character:GetAttribute("CurrentVesselId")
    if vesselAttr then
        vesselId = vesselAttr
    end

    -- Check if player is near water or on a vessel
    -- Players on foot need to be in a coastline/ocean zone
    if not vesselId then
        local nearWater = false
        -- Check if any water part is within range
        for _, descendant in ipairs(workspace:GetChildren()) do
            if descendant.Name == "__TideOcean" and descendant:IsA("Part") then
                local dist = (descendant.Position - position).Magnitude
                if dist < 200 then
                    nearWater = true
                    break
                end
            end
        end
        if not nearWater then
            return false, "Not near water. Find the dock or use a vessel."
        end
    end

    activeSessions[player] = {
        gearId = gearId,
        zone = zone,
        depth = depth,
        startTime = os.clock(),
        vesselId = vesselId,
    }

    return true
end

--[[
    Stop a fishing session for a player.
    @param player Player
]]
function FishingSystem.stopFishing(player: Player)
    activeSessions[player] = nil
    FishingSystem.CatchMechanics.cancelSession(player)
end

--[[
    Check if a player is currently fishing.
    @param player Player
    @return boolean
]]
function FishingSystem.isFishing(player: Player): boolean
    return activeSessions[player] ~= nil
end

--[[
    Get the active fishing session data for a player.
    @param player Player
    @return table?
]]
function FishingSystem.getSession(player: Player)
    return activeSessions[player]
end

--[[
    Get all active fishing sessions (for admin/debug).
    @return table
]]
function FishingSystem.getActiveSessions()
    return activeSessions
end

--[[
    Shutdown: stop all sessions and clean up.
    Primarily for testing.
]]
function FishingSystem.shutdown()
    local Players = game:GetService("Players")
    for player in pairs(activeSessions) do
        FishingSystem.stopFishing(player)
    end
    activeSessions = {}

    FishingSystem.CatchMechanics.shutdown()
    FishingSystem.FishSpawner.shutdown()

    initialized = false
    print("[FishingSystem] Shut down. The ocean is closed.")
end

return FishingSystem
