--!strict
--[[
    CatchMechanics.lua — Active Fishing Gameplay
    The cast → wait → bite → fight → catch loop.
]]

local CatchMechanics = {}

local GearSystem = nil  -- lazy loaded
local FishStocks = nil

-- Active fishing sessions per player
CatchMechanics._sessions = {}  -- [userId] = session

local PHASES = {
    IDLE = "IDLE",
    CASTING = "CASTING",
    WAITING = "WAITING",
    BITE = "BITE",
    FIGHTING = "FIGHTING",
    CAUGHT = "CAUGHT",
    LOST = "LOST",
}

local function getSession(userId)
    if not CatchMechanics._sessions[userId] then
        CatchMechanics._sessions[userId] = {
            phase = PHASES.IDLE,
            gearType = nil,
            castTime = 0,
            biteTime = 0,
            fightStart = 0,
            fishData = nil,
            tension = 0.5,
            lineIntegrity = 100,
        }
    end
    return CatchMechanics._sessions[userId]
end

function CatchMechanics.init()
    print("[CatchMechanics] Initialized")
end

-- Start a cast
function CatchMechanics.cast(userId, gearType, fishZoneData)
    local session = getSession(userId)
    if session.phase ~= PHASES.IDLE then
        return false, "Already fishing"
    end

    session.phase = PHASES.CASTING
    session.gearType = gearType
    session.castTime = os.clock()

    -- Calculate wait time based on fish density in zone
    local baseWait = 5  -- seconds
    local density = (fishZoneData and fishZoneData.density) or 0.3
    local waitTime = baseWait / math.max(0.1, density) + math.random() * 10

    -- Transition to waiting
    session.phase = PHASES.WAITING

    -- Schedule bite
    task.delay(waitTime, function()
        if session.phase == PHASES.WAITING then
            CatchMechanics._triggerBite(userId, fishZoneData)
        end
    end)

    return true, waitTime
end

-- Fish bites
function CatchMechanics._triggerBite(userId, fishZoneData)
    local session = getSession(userId)
    session.phase = PHASES.BITE
    session.biteTime = os.clock()

    -- Determine fish species from zone
    local species = "cod"
    if fishZoneData and fishZoneData.species and #fishZoneData.species > 0 then
        species = fishZoneData.species[math.random(#fishZoneData.species)]
    end

    -- Generate fish stats
    local fishStats = CatchMechanics._generateFish(species)
    session.fishData = fishStats

    -- Auto-transition to fighting after 1.5s if player doesn't react
    task.delay(1.5, function()
        if session.phase == PHASES.BITE then
            CatchMechanics.startFight(userId)
        end
    end)
end

function CatchMechanics.startFight(userId)
    local session = getSession(userId)
    if session.phase ~= PHASES.BITE then return end
    session.phase = PHASES.FIGHTING
    session.fightStart = os.clock()
    session.tension = 0.5
    session.lineIntegrity = 100
end

-- Generate a fish based on species
function CatchMechanics._generateFish(species)
    local stats = {
        species = species,
        weight = 5,
        fightDifficulty = 0.3,
        fightDuration = 8,
        quality = "A",
        scrapValue = 15,
    }

    local speciesData = {
        herring = { minW = 0.2, maxW = 2, difficulty = 0.15, duration = 5, value = 5 },
        cod = { minW = 5, maxW = 30, difficulty = 0.35, duration = 10, value = 20 },
        salmon = { minW = 3, maxW = 25, difficulty = 0.45, duration = 12, value = 25 },
        halibut = { minW = 10, maxW = 80, difficulty = 0.6, duration = 18, value = 80 },
        crab = { minW = 0.5, maxW = 4, difficulty = 0.1, duration = 4, value = 15 },
        tuna = { minW = 40, maxW = 200, difficulty = 0.85, duration = 25, value = 350 },
    }

    local data = speciesData[species] or speciesData.cod
    stats.weight = data.minW + math.random() * (data.maxW - data.minW)
    stats.fightDifficulty = data.difficulty
    stats.fightDuration = data.duration + (stats.weight / data.maxW) * data.duration * 0.5
    stats.scrapValue = math.floor(data.value * (stats.weight / data.maxW))

    return stats
end

-- Update tension during fight (called from Heartbeat or client input)
function CatchMechanics.updateTension(userId, newTension)
    local session = getSession(userId)
    if session.phase ~= PHASES.FIGHTING then return end

    session.tension = math.clamp(newTension, 0, 1)

    -- Line breaks if tension too high for too long
    if session.tension > 0.85 then
        session.lineIntegrity = math.max(0, session.lineIntegrity - 2)
    elseif session.tension < 0.15 then
        session.lineIntegrity = math.max(0, session.lineIntegrity - 1)
    end

    -- Fish escapes if tension too low
    if session.tension < 0.1 and math.random() < 0.1 then
        CatchMechanics.loseFish(userId, "line_slack")
        return
    end

    -- Line snaps
    if session.lineIntegrity <= 0 then
        CatchMechanics.loseFish(userId, "line_snap")
        return
    end

    -- Check fight duration — fish tires
    local elapsed = os.clock() - session.fightStart
    if elapsed >= session.fishData.fightDuration then
        CatchMechanics.catchFish(userId)
    end
end

-- Successfully catch the fish
function CatchMechanics.catchFish(userId)
    local session = getSession(userId)
    if session.phase ~= PHASES.FIGHTING then return end

    session.phase = PHASES.CAUGHT

    local fish = session.fishData

    -- Quality degrades with fight time
    local elapsed = os.clock() - session.fightStart
    local fightRatio = elapsed / fish.fightDuration
    if fightRatio < 0.5 then
        fish.quality = "A"
    elseif fightRatio < 0.8 then
        fish.quality = "B"
    else
        fish.quality = "C"
    end

    -- Adjust scrap value by quality
    local qMult = (fish.quality == "A") and 1.0 or (fish.quality == "B") and 0.7 or 0.4
    fish.scrapValue = math.floor(fish.scrapValue * qMult)

    -- Reset to idle after 3s
    task.delay(3, function()
        local s = getSession(userId)
        s.phase = PHASES.IDLE
        s.fishData = nil
    end)

    return fish
end

-- Lose the fish
function CatchMechanics.loseFish(userId, reason)
    local session = getSession(userId)
    session.phase = PHASES.LOST

    task.delay(2, function()
        local s = getSession(userId)
        s.phase = PHASES.IDDE
        s.fishData = nil
    end)

    return false, reason
end

-- Get current session state for client
function CatchMechanics.getState(userId)
    local session = getSession(userId)
    return {
        phase = session.phase,
        tension = session.tension,
        lineIntegrity = session.lineIntegrity,
        fishData = session.fishData,
        fightElapsed = (session.phase == PHASES.FIGHTING)
            and (os.clock() - session.fightStart) or 0,
    }
end

return CatchMechanics
