--!strict
--[[
    EconomySystem — Slackwater's Resource Economy & Progression
    ===========================================================
    The synergy layer connecting building and fishing.

    "Spend scrap on a bigger boat (more fish) or building materials
     (more builds)? Both progress. Synergy is optimal."

    This module bootstraps the economy subsystems:
        • Currency        — multi-currency tracking (Scrap, Materials, Influence)
        • VesselUpgrades  — boat progression (era-gated, Lucineier-built)
        • BuildCosts      — material costs for construction & upgrades
        • MissionBoard    — quest distribution from Earl, Bea, Hermes, Spark
        • EraGates        — era advancement requirements & ceremonies

    All subsystems persist per-player via the existing SaveSystem/D1
    infrastructure. Currency integrates with EraSystem (era-gated unlocks),
    BondSystem (bond-gated missions), and NPCManager (quest sources).

    Dependencies:
        - ServerScriptService.EconomySystem.Currency
        - ServerScriptService.EconomySystem.VesselUpgrades
        - ServerScriptService.EconomySystem.BuildCosts
        - ServerScriptService.EconomySystem.MissionBoard
        - ServerScriptService.EconomySystem.EraGates
        - ServerScriptService.BondSystem (for bond-gated content)
        - ServerScriptService.EraSystem (for era-gated content)
]]

local EconomySystem = {}

-- Submodule cache
local Currency
local VesselUpgrades
local BuildCosts
local MissionBoard
local EraGates

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

local initialized = false

--[[
    Initialize the EconomySystem and all subsystems.
    Call once during server init, after EraSystem and BondSystem are ready.
]]
function EconomySystem.init()
    if initialized then
        warn("[EconomySystem] Already initialized.")
        return
    end

    -- Load submodules
    Currency = require(script:WaitForChild("Currency"))
    VesselUpgrades = require(script:WaitForChild("VesselUpgrades"))
    BuildCosts = require(script:WaitForChild("BuildCosts"))
    MissionBoard = require(script:WaitForChild("MissionBoard"))
    EraGates = require(script:WaitForChild("EraGates"))

    -- Initialize each subsystem in dependency order
    Currency.init()
    BuildCosts.init()
    VesselUpgrades.init()
    EraGates.init()
    MissionBoard.init()

    -- Cross-wire subsystems
    -- MissionBoard needs to query Currency for reward distribution
    MissionBoard.bindCurrency(Currency)
    MissionBoard.bindEraGates(EraGates)

    -- VesselUpgrades needs BuildCosts for pricing
    VesselUpgrades.bindBuildCosts(BuildCosts)

    -- EraGates needs Currency for threshold checks
    EraGates.bindCurrency(Currency)

    -- BuildCosts needs Currency for affordability checks
    BuildCosts.bindCurrency(Currency)

    initialized = true
    print("[EconomySystem] Initialized — Currency, VesselUpgrades, BuildCosts, MissionBoard, EraGates")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SUBMODULE ACCESSORS
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get the Currency subsystem.
    @return table
]]
function EconomySystem.getCurrency()
    return Currency
end

--[[
    Get the VesselUpgrades subsystem.
    @return table
]]
function EconomySystem.getVesselUpgrades()
    return VesselUpgrades
end

--[[
    Get the BuildCosts subsystem.
    @return table
]]
function EconomySystem.getBuildCosts()
    return BuildCosts
end

--[[
    Get the MissionBoard subsystem.
    @return table
]]
function EconomySystem.getMissionBoard()
    return MissionBoard
end

--[[
    Get the EraGates subsystem.
    @return table
]]
function EconomySystem.getEraGates()
    return EraGates
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONVENIENCE PROXIES
-- ═══════════════════════════════════════════════════════════════════════════
-- These exist so other systems can call EconomySystem.earnScrap() etc.
-- without grabbing the submodule first. Reduces boilerplate.

--[[
    Award scrap to a player (e.g., from selling fish).
    @param playerId string
    @param amount number
    @param reason string? — for transaction log
]]
function EconomySystem.earnScrap(playerId: string, amount: number, reason: string?)
    if not Currency then return end
    Currency.earnScrap(playerId, amount, reason)
end

--[[
    Spend scrap from a player (e.g., on gear/fuel).
    @param playerId string
    @param amount number
    @param reason string?
    @return boolean — true if successful
]]
function EconomySystem.spendScrap(playerId: string, amount: number, reason: string?): boolean
    if not Currency then return false end
    return Currency.spendScrap(playerId, amount, reason)
end

--[[
    Get a player's full wallet (all currencies).
    @param playerId string
    @return table
]]
function EconomySystem.getWallet(playerId: string): { [string]: any }
    if not Currency then return {} end
    return Currency.getWallet(playerId)
end

--[[
    Check if a player can afford a build cost.
    @param playerId string
    @param cost table — { scrap = N, materials = { wood = N, ... }, influence = N }
    @return boolean, string? — affordable, missing material name if not
]]
function EconomySystem.canAfford(playerId: string, cost: { [string]: any }): (boolean, string?)
    if not BuildCosts then return false, "not initialized" end
    return BuildCosts.canAfford(playerId, cost)
end

--[[
    Charge a player for a build. Returns true if successful.
    @param playerId string
    @param cost table
    @return boolean, string?
]]
function EconomySystem.chargeBuild(playerId: string, cost: { [string]: any }): (boolean, string?)
    if not BuildCosts then return false, "not initialized" end
    return BuildCosts.charge(playerId, cost)
end

print("[EconomySystem] Module loaded — synergy layer for building + fishing")

return EconomySystem
