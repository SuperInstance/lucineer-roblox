--!strict
--[[
    CrewSystem.lua — Hire and Manage NPC Crew
    Deckhand, Navigator, Engineer, Spotter — provide passive bonuses at sea.
]]

local CrewSystem = {}

local CREW_TYPES = {
    deckhand = {
        name = "Deckhand",
        dailyRate = 50,
        bonus = "auto_retrieve_gear",
        description = "Auto-retrieves pots/lines. Speeds up catch processing.",
    },
    navigator = {
        name = "Navigator",
        dailyRate = 100,
        bonus = "auto_pilot",
        description = "Auto-pilots to GPS coordinates. Warns of hazards.",
    },
    engineer = {
        name = "Engineer",
        dailyRate = 75,
        bonus = "hull_repair",
        description = "Slowly repairs hull at sea. Prevents breakdowns.",
    },
    spotter = {
        name = "Spotter",
        dailyRate = 60,
        bonus = "fish_detection",
        description = "Increases fish detection range. Marks fish on chart.",
    },
}

CrewSystem._hiredCrew = {}  -- [userId] = { [crewType] = { daysPaid, hireDate } }

function CrewSystem.init()
    print("[CrewSystem] Initialized — " .. #CrewSystem.getCrewList() .. " crew types available")
end

function CrewSystem.getCrewList()
    local list = {}
    for key, data in pairs(CREW_TYPES) do
        table.insert(list, { key = key, name = data.name, rate = data.dailyRate, desc = data.description })
    end
    return list
end

function CrewSystem.hire(userId, crewType)
    if not CREW_TYPES[crewType] then return false, "Unknown crew type" end
    if not CrewSystem._hiredCrew[userId] then
        CrewSystem._hiredCrew[userId] = {}
    end
    if CrewSystem._hiredCrew[userId][crewType] then
        return false, "Already hired"
    end
    CrewSystem._hiredCrew[userId][crewType] = {
        daysPaid = 1,
        hireDate = os.time(),
    }
    return true
end

function CrewSystem.fire(userId, crewType)
    if CrewSystem._hiredCrew[userId] then
        CrewSystem._hiredCrew[userId][crewType] = nil
        return true
    end
    return false
end

function CrewSystem.getActiveCrew(userId)
    return CrewSystem._hiredCrew[userId] or {}
end

function CrewSystem.payDaily(userId)
    -- Deduct daily rate, fire if can't pay
    local crew = CrewSystem._hiredCrew[userId]
    if not crew then return 0 end
    local totalCost = 0
    for crewType, data in pairs(crew) do
        totalCost += CREW_TYPES[crewType].dailyRate
        data.daysPaid = data.daysPaid - 1
        if data.daysPaid <= 0 then
            crew[crewType] = nil  -- Crew leaves if not paid
        end
    end
    return totalCost
end

function CrewSystem.hasBonus(userId, bonusName)
    local crew = CrewSystem._hiredCrew[userId]
    if not crew then return false end
    for crewType, _ in pairs(crew) do
        if CREW_TYPES[crewType] and CREW_TYPES[crewType].bonus == bonusName then
            return true
        end
    end
    return false
end

return CrewSystem
