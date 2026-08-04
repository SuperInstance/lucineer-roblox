--!strict
--[[
    EraGates.lua — Era Advancement Requirements
    Defines what the player must achieve to unlock each era.
]]

local EraGates = {}

local GATES = {
    {
        fromEra = 0, toEra = 1,
        name = "Salvage",
        requirements = { builds = 10, fishCaught = 20, scrapEarned = 200 },
        ceremony = "First real tools. Lucineier unlocks the salvage yard.",
    },
    {
        fromEra = 1, toEra = 2,
        name = "Pioneer",
        requirements = { builds = 25, fishCaught = 75, scrapEarned = 1000, vesselUpgrades = 1 },
        ceremony = "Pioneer status. New vessel, new waters, new possibilities.",
    },
    {
        fromEra = 2, toEra = 3,
        name = "Mariner",
        requirements = { builds = 50, fishCaught = 200, scrapEarned = 3000, stormsSurvived = 1 },
        ceremony = "Mariner. You've earned the sea's respect. And a proper fishing boat.",
    },
    {
        fromEra = 3, toEra = 4,
        name = "Captain",
        requirements = { builds = 100, fishCaught = 500, scrapEarned = 8000, missionsCompleted = 10 },
        ceremony = "Captain. This harbor answers to you now.",
    },
}

function EraGates.init()
    print("[EraGates] Initialized — " .. #GATES .. " era gates defined")
end

function EraGates.getGateForEra(currentEra)
    for _, gate in ipairs(GATES) do
        if gate.fromEra == currentEra then
            return gate
        end
    end
    return nil  -- Max era reached
end

function EraGates.checkAdvancement(stats, currentEra)
    -- stats = { builds, fishCaught, scrapEarned, vesselUpgrades, stormsSurvived, missionsCompleted }
    local gate = EraGates.getGateForEra(currentEra)
    if not gate then return false, nil end

    local req = gate.requirements
    local progress = {}

    local allMet = true
    for key, requiredValue in pairs(req) do
        local current = stats[key] or 0
        progress[key] = {
            current = current,
            required = requiredValue,
            met = current >= requiredValue,
        }
        if current < requiredValue then
            allMet = false
        end
    end

    return allMet, { gate = gate, progress = progress }
end

function EraGates.getProgressStats(stats, currentEra)
    local gate = EraGates.getGateForEra(currentEra)
    if not gate then return nil end
    return EraGates.checkAdvancement(stats, currentEra)
end

return EraGates
