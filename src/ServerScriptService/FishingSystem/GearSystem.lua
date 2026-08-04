--!strict
--[[
    GearSystem.lua — Fishing Gear Equipment
    Handles gear types, deployment, retrieval, and durability.
]]

local GearSystem = {}

local GEAR_TYPES = {
    handline = {
        name = "Handline",
        era = 0,
        cost = 0,
        deployTime = 2,
        retrieveTime = 4,
        catchRate = 0.3,
        speciesFilter = {"herring", "cod", "salmon"},
        maxWeight = 15,
        durability = 100,
        passive = false,
        description = "Simple line and hook. Everyone starts here.",
    },
    rod = {
        name = "Rod & Reel",
        era = 1,
        cost = 150,
        deployTime = 3,
        retrieveTime = 5,
        catchRate = 0.5,
        speciesFilter = {"salmon", "cod", "halibut", "herring"},
        maxWeight = 60,
        durability = 150,
        passive = false,
        description = "Proper rod. Better range, faster retrieve.",
    },
    gillnet = {
        name = "Gillnet",
        era = 2,
        cost = 400,
        deployTime = 8,
        retrieveTime = 15,
        catchRate = 0.7,
        speciesFilter = {"herring", "cod", "salmon"},
        maxWeight = 200,
        durability = 200,
        passive = true,
        soakTime = 120,
        description = "Set it, wait, collect. Catches schooling fish.",
    },
    longline = {
        name = "Longline",
        era = 3,
        cost = 800,
        deployTime = 12,
        retrieveTime = 20,
        catchRate = 0.8,
        speciesFilter = {"halibut", "cod", "tuna"},
        maxWeight = 500,
        durability = 300,
        passive = true,
        soakTime = 180,
        description = "Multi-hook line for large pelagics.",
    },
    pot = {
        name = "Crab Pot",
        era = 2,
        cost = 250,
        deployTime = 5,
        retrieveTime = 8,
        catchRate = 0.6,
        speciesFilter = {"crab"},
        maxWeight = 50,
        durability = 250,
        passive = true,
        soakTime = 300,
        description = "Drop, wait, retrieve. Steady crab harvest.",
    },
}

-- Per-player gear inventory
GearSystem._playerGear = {}  -- [userId] = { [gearType] = { count=n, durability=table } }

function GearSystem.init()
    print("[GearSystem] Initialized — " .. #GearSystem.getGearList() .. " gear types registered")
end

function GearSystem.getGearList()
    local list = {}
    for key, data in pairs(GEAR_TYPES) do
        table.insert(list, {
            key = key,
            name = data.name,
            era = data.era,
            cost = data.cost,
            description = data.description,
        })
    end
    return list
end

function GearSystem.getGearData(gearType)
    return GEAR_TYPES[gearType]
end

function GearSystem.canUse(player, gearType, currentEra)
    local gear = GEAR_TYPES[gearType]
    if not gear then return false, "Unknown gear" end
    if currentEra < gear.era then
        return false, "Requires era " .. gear.era
    end
    return true
end

function GearSystem.getPlayerGear(userId)
    if not GearSystem._playerGear[userId] then
        GearSystem._playerGear[userId] = {
            handline = { count = 1, durability = { 100 } },
        }
    end
    return GearSystem._playerGear[userId]
end

function GearSystem.addGear(userId, gearType)
    local data = GEAR_TYPES[gearType]
    if not data then return false end
    local gear = GearSystem.getPlayerGear(userId)
    if not gear[gearType] then
        gear[gearType] = { count = 0, durability = {} }
    end
    gear[gearType].count += 1
    table.insert(gear[gearType].durability, data.durability)
    return true
end

function GearSystem.damageGear(userId, gearType, amount)
    local gear = GearSystem.getPlayerGear(userId)
    if not gear[gearType] then return end
    for i, dur in ipairs(gear[gearType].durability) do
        if dur > 0 then
            gear[gearType].durability[i] = math.max(0, dur - amount)
            if gear[gearType].durability[i] == 0 then
                -- Gear broke
                gear[gearType].count = math.max(0, gear[gearType].count - 1)
            end
            break
        end
    end
end

function GearSystem.getDeployInfo(gearType)
    local data = GEAR_TYPES[gearType]
    if not data then return nil end
    return {
        deployTime = data.deployTime,
        retrieveTime = data.retrieveTime,
        passive = data.passive,
        soakTime = data.soakTime,
    }
end

return GearSystem
