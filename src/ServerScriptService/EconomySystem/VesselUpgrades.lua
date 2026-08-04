--!strict
--[[
    VesselUpgrades — Boat Progression System
    =========================================
    Each era-gated vessel has upgrade slots that cost Scrap + Materials.
    Upgrades are built by Lucineier — this tracks state and costs.

    Vessel progression mirrors the building eras:
        Era 1 (Driftwood): Skiff — base boat, 2 upgrade slots
        Era 2 (Salvage):   Dory — 3 upgrade slots
        Era 3 (Pioneer):   Cutter — 4 upgrade slots
        Era 4 (Mariner):   Trawler — 5 upgrade slots
        Era 5 (Captain):   Longliner — all 7 upgrade slots

    Upgrade Slots:
        hull           — Hull reinforcement     (more HP, storm resistance)
        engine         — Engine upgrade          (faster, better fuel economy)
        cargo          — Cargo expansion         (more fish per trip)
        sonar          — Fish finder             (better catch rates)
        lights         — Navigation lights       (night fishing unlocked)
        radio          — Ship-to-shore radio     (mission availability)
        freezer        — Deep freeze             (fish don't spoil, premium price)

    Each upgrade has era requirements and material costs that scale
    with vessel tier. Lucineier performs the installation.

    Dependencies:
        - ServerScriptService.EconomySystem.Currency
        - ServerScriptService.EconomySystem.BuildCosts
        - ServerScriptService.EraSystem (for era gating)
]]

local Players = game:GetService("Players")

-- ═══════════════════════════════════════════════════════════════════════════
-- VESSEL DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════

local VESSELS = {
    [1] = {
        name = "Skiff",
        era = 1,
        description = "A driftwood skiff. Poles in the shallows, catches what swims by.",
        baseCost = { scrap = 100, materials = { wood = 10 } },
        upgradeSlots = { "hull", "cargo" },
    },
    [2] = {
        name = "Dory",
        era = 2,
        description = "A salvaged dory. Wider beam, stable in chop, can row or sail.",
        baseCost = { scrap = 400, materials = { wood = 25, cloth = 10 } },
        upgradeSlots = { "hull", "engine", "cargo" },
    },
    [3] = {
        name = "Cutter",
        era = 3,
        description = "A framed cutter. Real keel, real deck. Takes the weather.",
        baseCost = { scrap = 1200, materials = { wood = 40, metal = 15, cloth = 15 } },
        upgradeSlots = { "hull", "engine", "cargo", "sonar" },
    },
    [4] = {
        name = "Trawler",
        era = 4,
        description = "An iron-framed trawler. Engine-driven, pot-hauling, works the Channel.",
        baseCost = { scrap = 4000, materials = { metal = 50, wood = 30, copper = 10, glass = 5 } },
        upgradeSlots = { "hull", "engine", "cargo", "sonar", "lights", "radio" },
    },
    [5] = {
        name = "Longliner",
        era = 5,
        description = "A steel-hulled longliner. Goes deep, stays long, brings back everything.",
        baseCost = { scrap = 12000, materials = { metal = 100, copper = 30, glass = 20, cloth = 20 } },
        upgradeSlots = { "hull", "engine", "cargo", "sonar", "lights", "radio", "freezer" },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- UPGRADE DEFINITIONS
-- Costs scale with vessel tier. These are BASE costs; multiply by
-- the vessel's tier multiplier (defined per-vessel below).
-- ═══════════════════════════════════════════════════════════════════════════

local UPGRADES = {
    hull = {
        name = "Hull Reinforcement",
        description = "Bronzed plating, sealed seams. Takes a storm and asks for more.",
        baseCost = { scrap = 150, materials = { metal = 5, wood = 5 } },
        effect = { stormResistance = 1, hpMultiplier = 1.5 },
        minEra = 1,
    },
    engine = {
        name = "Engine Upgrade",
        description = "A real engine. Salvaged, rebuilt, runs. Faster than arms.",
        baseCost = { scrap = 300, materials = { metal = 10, copper = 3 } },
        effect = { speedMultiplier = 1.4, fuelEconomy = 0.85 },
        minEra = 2,
    },
    cargo = {
        name = "Cargo Expansion",
        description = "Built-out hold. More fish per trip, fewer trips per day.",
        baseCost = { scrap = 200, materials = { wood = 8, cloth = 3 } },
        effect = { cargoCapacity = 1.5 },
        minEra = 1,
    },
    sonar = {
        name = "Sonar Array",
        description = "Depths and fish, shown on a dim green screen. Witchcraft.",
        baseCost = { scrap = 500, materials = { copper = 8, glass = 5, metal = 5 } },
        effect = { catchRateMultiplier = 1.3 },
        minEra = 3,
    },
    lights = {
        name = "Navigation Lights",
        description = "Port red, starboard green. You fish after dark now.",
        baseCost = { scrap = 350, materials = { copper = 5, glass = 8 } },
        effect = { nightFishing = true },
        minEra = 3,
    },
    radio = {
        name = "Ship-to-Shore Radio",
        description = "Calls come in mid-channel. Hermes relays, Bea warns.",
        baseCost = { scrap = 600, materials = { copper = 10, metal = 5 } },
        effect = { channelMissions = true },
        minEra = 4,
    },
    freezer = {
        name = "Deep Freeze Hold",
        description = "Fish stay fresh indefinitely. Premium price at market.",
        baseCost = { scrap = 1000, materials = { copper = 15, metal = 10, glass = 5 } },
        effect = { fishPreservation = true, priceMultiplier = 1.5 },
        minEra = 5,
    },
}

-- Cost multiplier per vessel tier (tier 1 = 1x, tier 5 = 3.5x)
local TIER_MULTIPLIERS = {
    [1] = 1.0,
    [2] = 1.3,
    [3] = 1.8,
    [4] = 2.5,
    [5] = 3.5,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- LUCINEIER INSTALLATION LINES
-- Things Lucineier says when installing an upgrade.
-- ═══════════════════════════════════════════════════════════════════════════

local INSTALL_LINES = {
    "There. She'll take weather now. Don't thank me — thank the plating.",
    "Engine's in. She vibrates at quarter-throttle. That's character.",
    "Hold's wider. You'll fill it. That's the idea.",
    "Green screen works. Fish show up as smudges. Trust the smudges.",
    "Lights are wired. Red port, green starboard. You know which is which.",
    "Radio's live. Channel six for Hermes, eleven for Bea. Don't mix them up.",
    "Freezer's running. Fish go in cold, come out worth more. That's the whole trick.",
}

local INSUFFICIENT_LINES = {
    scrap = "I need more scrap. The work's not cheap and neither is the metal.",
    wood = "I need more wood. Good wood — not the punky beach stuff.",
    metal = "I need more metal. Bring me stock, not salvage-bent.",
    cloth = "I need more cloth. Heavy weave. Sailcloth if you've got it.",
    glass = "I need more glass. Fog glass works. Pane glass is better.",
    copper = "I need more copper. Wire, sheet, pipe — I'm not picky.",
    stone = "I need more stone. Cut block, not field rubble.",
}

-- ═══════════════════════════════════════════════════════════════════════════
-- RUNTIME STATE
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → vessel state
-- {
--   currentTier = number (1-5),
--   ownedVessels = { [tier] = true },
--   upgrades = { [tier] = { hull=true, engine=true, ... } },
--   totalUpgradesPurchased = number,
-- }
local playerVessels: { [string]: { [string]: any } } = {}

local Currency
local BuildCosts
local initialized = false

-- ═══════════════════════════════════════════════════════════════════════════
-- INTERNAL HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function getVesselState(playerName: string): { [string]: any }
    if not playerVessels[playerName] then
        playerVessels[playerName] = {
            currentTier = 0,  -- no vessel owned yet
            ownedVessels = {},
            upgrades = {},
            totalUpgradesPurchased = 0,
        }
    end
    return playerVessels[playerName]
end

--[[
    Calculate the actual cost of an upgrade for a specific vessel tier.
    @param upgradeId string
    @param vesselTier number
    @return table — cost { scrap, materials }
]]
local function calculateCost(upgradeId: string, vesselTier: number): { [string]: any }
    local upgrade = UPGRADES[upgradeId]
    if not upgrade then return {} end

    local multiplier = TIER_MULTIPLIERS[vesselTier] or 1.0
    local cost = {
        scrap = math.floor((upgrade.baseCost.scrap or 0) * multiplier),
        materials = {},
    }

    for material, amount in pairs(upgrade.baseCost.materials or {}) do
        cost.materials[material] = math.floor(amount * multiplier)
    end

    return cost
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

local VesselUpgrades = {}

--[[
    Bind the Currency subsystem.
    @param currencyModule table
]]
function VesselUpgrades.bindCurrency(currencyModule)
    Currency = currencyModule
end

--[[
    Bind the BuildCosts subsystem.
    @param buildCostsModule table
]]
function VesselUpgrades.bindBuildCosts(buildCostsModule)
    BuildCosts = buildCostsModule
end

--[[
    Initialize the system.
]]
function VesselUpgrades.init()
    if initialized then return end
    initialized = true

    Players.PlayerAdded:Connect(function(player)
        getVesselState(player.Name)
    end)

    print("[VesselUpgrades] Initialized — 5 vessels, 7 upgrade types")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- VESSEL PURCHASING
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Check if a player can purchase a vessel of the given tier.
    Requires: previous vessel owned, era unlocked, sufficient currency.
    @param playerName string
    @param tier number — vessel tier (1-5)
    @return boolean, string? — canPurchase, reason if not
]]
function VesselUpgrades.canPurchaseVessel(playerName: string, tier: number): (boolean, string?)
    if not VESSELS[tier] then
        return false, "invalid_tier"
    end

    local state = getVesselState(playerName)

    -- Must own previous tier vessel (unless tier 1)
    if tier > 1 and not state.ownedVessels[tier - 1] then
        return false, "previous_vessel_required"
    end

    -- Check era requirement
    local EraSystem = require(game:GetService("ServerScriptService"):WaitForChild("EraSystem"))
    local buildingEra = EraSystem.getBuildingEra(playerName)
    if buildingEra < VESSELS[tier].era then
        return false, "era_locked"
    end

    -- Check currency
    if Currency then
        local canAfford, missing = Currency.validateCost(playerName, VESSELS[tier].baseCost)
        if not canAfford then
            return false, "insufficient_" .. (missing or "currency")
        end
    end

    return true
end

--[[
    Purchase a vessel. Charges currency and records ownership.
    @param playerName string
    @param tier number
    @return boolean, string? — success, reason if failed
]]
function VesselUpgrades.purchaseVessel(playerName: string, tier: number): (boolean, string?)
    local canPurchase, reason = VesselUpgrades.canPurchaseVessel(playerName, tier)
    if not canPurchase then
        return false, reason
    end

    local state = getVesselState(playerName)
    local vessel = VESSELS[tier]

    -- Charge the player
    if Currency then
        local charged, chargeFailReason = Currency.chargeCost(playerName, vessel.baseCost, "vessel_purchase_" .. vessel.name)
        if not charged then
            return false, chargeFailReason
        end
    end

    -- Record ownership
    state.ownedVessels[tier] = true
    state.currentTier = tier
    state.upgrades[tier] = state.upgrades[tier] or {}

    print(string.format("[VesselUpgrades] %s purchased %s (tier %d)", playerName, vessel.name, tier))

    return true
end

--[[
    Get the player's current vessel tier.
    @param playerName string
    @return number — 0 if no vessel owned
]]
function VesselUpgrades.getCurrentVesselTier(playerName: string): number
    local state = getVesselState(playerName)
    return state.currentTier
end

--[[
    Get the player's current vessel definition.
    @param playerName string
    @return table? — vessel data or nil
]]
function VesselUpgrades.getCurrentVessel(playerName: string): { [string]: any }?
    local state = getVesselState(playerName)
    return VESSELS[state.currentTier]
end

--[[
    Check if the player owns a vessel of a specific tier.
    @param playerName string
    @param tier number
    @return boolean
]]
function VesselUpgrades.ownsVessel(playerName: string, tier: number): boolean
    local state = getVesselState(playerName)
    return state.ownedVessels[tier] == true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UPGRADE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Check if an upgrade can be installed on the player's current vessel.
    @param playerName string
    @param upgradeId string — "hull", "engine", "cargo", "sonar", "lights", "radio", "freezer"
    @return boolean, string? — canInstall, reason if not
]]
function VesselUpgrades.canInstallUpgrade(playerName: string, upgradeId: string): (boolean, string?)
    local upgrade = UPGRADES[upgradeId]
    if not upgrade then
        return false, "invalid_upgrade"
    end

    local state = getVesselState(playerName)
    local tier = state.currentTier

    if tier == 0 then
        return false, "no_vessel"
    end

    local vessel = VESSELS[tier]
    if not vessel then
        return false, "invalid_vessel"
    end

    -- Check if this upgrade slot is available on this vessel
    local slotAvailable = false
    for _, slot in ipairs(vessel.upgradeSlots) do
        if slot == upgradeId then
            slotAvailable = true
            break
        end
    end
    if not slotAvailable then
        return false, "slot_not_available"
    end

    -- Check if already installed
    state.upgrades[tier] = state.upgrades[tier] or {}
    if state.upgrades[tier][upgradeId] then
        return false, "already_installed"
    end

    -- Check era requirement
    local EraSystem = require(game:GetService("ServerScriptService"):WaitForChild("EraSystem"))
    local buildingEra = EraSystem.getBuildingEra(playerName)
    if buildingEra < upgrade.minEra then
        return false, "era_locked"
    end

    -- Check currency
    if Currency then
        local cost = calculateCost(upgradeId, tier)
        local canAfford, missing = Currency.validateCost(playerName, cost)
        if not canAfford then
            return false, "insufficient_" .. (missing or "scrap")
        end
    end

    return true
end

--[[
    Install an upgrade on the player's current vessel.
    Lucineier performs the installation.
    @param playerName string
    @param upgradeId string
    @return boolean, string? — success, reason if failed
]]
function VesselUpgrades.installUpgrade(playerName: string, upgradeId: string): (boolean, string?)
    local canInstall, reason = VesselUpgrades.canInstallUpgrade(playerName, upgradeId)
    if not canInstall then
        return false, reason
    end

    local state = getVesselState(playerName)
    local tier = state.currentTier

    -- Charge the cost
    if Currency then
        local cost = calculateCost(upgradeId, tier)
        local charged = Currency.chargeCost(playerName, cost, "upgrade_" .. upgradeId)
        if not charged then
            return false, "charge_failed"
        end
    end

    -- Record the upgrade
    state.upgrades[tier] = state.upgrades[tier] or {}
    state.upgrades[tier][upgradeId] = true
    state.totalUpgradesPurchased = (state.totalUpgradesPurchased or 0) + 1

    local upgrade = UPGRADES[upgradeId]
    print(string.format("[VesselUpgrades] %s installed %s on %s (tier %d)",
        playerName, upgrade.name, VESSELS[tier].name, tier))

    return true
end

--[[
    Check if a specific upgrade is installed on the player's current vessel.
    @param playerName string
    @param upgradeId string
    @return boolean
]]
function VesselUpgrades.hasUpgrade(playerName: string, upgradeId: string): boolean
    local state = getVesselState(playerName)
    local tier = state.currentTier
    if tier == 0 then return false end
    state.upgrades[tier] = state.upgrades[tier] or {}
    return state.upgrades[tier][upgradeId] == true
end

--[[
    Get all installed upgrades for the player's current vessel.
    @param playerName string
    @return table — map of upgradeId -> true
]]
function VesselUpgrades.getInstalledUpgrades(playerName: string): { [string]: boolean }
    local state = getVesselState(playerName)
    local tier = state.currentTier
    if tier == 0 then return {} end
    state.upgrades[tier] = state.upgrades[tier] or {}
    return state.upgrades[tier]
end

--[[
    Get the cost for an upgrade on the player's current vessel.
    @param playerName string
    @param upgradeId string
    @return table? — cost or nil if not installable
]]
function VesselUpgrades.getUpgradeCost(playerName: string, upgradeId: string): { [string]: any }?
    local state = getVesselState(playerName)
    local tier = state.currentTier
    if tier == 0 then return nil end
    return calculateCost(upgradeId, tier)
end

--[[
    Get the Lucineier voice line for a successful installation.
    @return string
]]
function VesselUpgrades.getRandomInstallLine(): string
    return INSTALL_LINES[math.random(1, #INSTALL_LINES)]
end

--[[
    Get the Lucineier voice line for insufficient materials.
    @param material string — the missing material type
    @return string
]]
function VesselUpgrades.getInsufficientLine(material: string): string
    return INSUFFICIENT_LINES[material] or "I need more materials. Bring me stock and we'll talk."
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EFFECT QUERIES
-- Other systems (fishing, sailing, storm) query these to modify gameplay.
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get the aggregated effect bonuses from all installed upgrades.
    @param playerName string
    @return table — e.g. { speedMultiplier = 1.4, cargoCapacity = 1.5, ... }
]]
function VesselUpgrades.getEffectBonuses(playerName: string): { [string]: any }
    local state = getVesselState(playerName)
    local tier = state.currentTier
    if tier == 0 then return {} end

    state.upgrades[tier] = state.upgrades[tier] or {}
    local bonuses = {}

    for upgradeId, installed in pairs(state.upgrades[tier]) do
        if installed and UPGRADES[upgradeId] and UPGRADES[upgradeId].effect then
            for stat, value in pairs(UPGRADES[upgradeId].effect) do
                if type(value) == "number" then
                    -- Multiplier stats: multiply together
                    if bonuses[stat] then
                        bonuses[stat] = bonuses[stat] * value
                    else
                        bonuses[stat] = value
                    end
                else
                    -- Boolean stats: OR together
                    bonuses[stat] = value
                end
            end
        end
    end

    return bonuses
end

--[[
    Get all vessel definitions (for UI/mission reference).
    @return table
]]
function VesselUpgrades.getAllVessels(): { [string]: any }
    return VESSELS
end

--[[
    Get all upgrade definitions (for UI/mission reference).
    @return table
]]
function VesselUpgrades.getAllUpgrades(): { [string]: any }
    return UPGRADES
end

--[[
    Get full vessel state for a player (admin/debug).
    @param playerName string
    @return table
]]
function VesselUpgrades.getPlayerVesselState(playerName: string): { [string]: any }
    local state = getVesselState(playerName)
    return {
        currentTier = state.currentTier,
        currentVesselName = VESSELS[state.currentTier] and VESSELS[state.currentTier].name or "None",
        ownedVessels = state.ownedVessels,
        upgrades = state.upgrades,
        totalUpgradesPurchased = state.totalUpgradesPurchased or 0,
    }
end

print("[VesselUpgrades] Module loaded — 5 vessels, 7 upgrade types")

return VesselUpgrades
