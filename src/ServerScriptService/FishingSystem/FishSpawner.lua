--!strict
--[[
    FishSpawner.lua — Runtime Fish Population Management
    Maintains fish populations per zone with regen and overfishing penalty.
]]

local FishSpawner = {}

FishSpawner._zones = {}  -- [zoneId] = { species, population, maxPop, regenRate, position, radius }
FishSpawner._catchHistory = {}  -- [dayKey][zoneId][species] = count

function FishSpawner.init()
    print("[FishSpawner] Initialized")
end

function FishSpawner.registerZone(zoneId, data)
    FishSpawner._zones[zoneId] = {
        species = data.species or {"cod"},
        population = data.maxPopulation or 100,
        maxPopulation = data.maxPopulation or 100,
        regenRate = data.regenRate or 0.1,  -- per minute
        position = data.position,
        radius = data.radius or 50,
        depthRange = data.depthRange or {-5, -30},
    }
end

function FishSpawner.getZonePopulation(zoneId, species)
    local zone = FishSpawner._zones[zoneId]
    if not zone then return 0 end
    return math.floor(zone.population)
end

function FishSpawner.canCatch(zoneId, species)
    local zone = FishSpawner._zones[zoneId]
    if not zone then return false end
    -- Check species is in zone
    local found = false
    for _, s in ipairs(zone.species) do
        if s == species then found = true break end
    end
    if not found then return false end
    -- Check population
    if zone.population < 1 then return false end
    -- Catch probability based on population density
    local density = zone.population / zone.maxPopulation
    return math.random() < (0.3 + density * 0.5)
end

function FishSpawner.recordCatch(zoneId, species, count)
    local zone = FishSpawner._zones[zoneId]
    if not zone then return end
    count = count or 1

    -- Reduce population
    zone.population = math.max(0, zone.population - count)

    -- Track for overfishing
    local dayKey = os.date("%Y%m%d")
    if not FishSpawner._catchHistory[dayKey] then
        FishSpawner._catchHistory[dayKey] = {}
    end
    if not FishSpawner._catchHistory[dayKey][zoneId] then
        FishSpawner._catchHistory[dayKey][zoneId] = {}
    end
    FishSpawner._catchHistory[dayKey][zoneId][species] =
        (FishSpawner._catchHistory[dayKey][zoneId][species] or 0) + count
end

-- Called on Heartbeat or timer to regenerate populations
function FishSpawner.tick(deltaTime)
    local dayKey = os.date("%Y%m%d")

    for zoneId, zone in pairs(FishSpawner._zones) do
        -- Check overfishing penalty
        local penalty = 1.0
        local history = FishSpawner._catchHistory[dayKey]
        if history and history[zoneId] then
            local totalCaught = 0
            for _, count in pairs(history[zoneId]) do
                totalCaught += count
            end
            -- If >70% of max pop caught today, regen halved for 3 days
            if totalCaught > zone.maxPopulation * 0.7 then
                penalty = 0.5
            end
        end

        -- Regen
        local regenAmount = zone.regenRate * (deltaTime / 60) * penalty
        zone.population = math.min(zone.maxPopulation, zone.population + regenAmount)
    end
end

function FishSpawner.getZoneInfo(zoneId)
    local zone = FishSpawner._zones[zoneId]
    if not zone then return nil end
    return {
        species = zone.species,
        population = math.floor(zone.population),
        maxPopulation = zone.maxPopulation,
        position = zone.position,
        radius = zone.radius,
        density = zone.population / zone.maxPopulation,
    }
end

return FishSpawner
