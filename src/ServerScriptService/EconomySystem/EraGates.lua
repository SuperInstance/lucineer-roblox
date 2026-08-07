--!strict
--[[
    EraGates.lua — Era Progression & Build Gating System
    =====================================================
    "You don't build a lighthouse with driftwood and good intentions.
     You earn the right to build it by learning what the sea does to
     things that aren't ready." — Lucineer

    Tracks player era based on builds completed, fish caught, and scrap
    earned. Gates certain builds behind era requirements — you can't
    build a lighthouse in the driftwood era.

    Era Progression:
      Era 0: Driftwood  (starter — shelters, basic docks, simple walls)
      Era 1: Salvage    (unlock: proper boats, cannery, wood structures)
      Era 2: Pioneer    (unlock: stone buildings, bridges, windmills)
      Era 3: Mariner    (unlock: metal works, forges, advanced vessels)
      Era 4: Light      (unlock: lighthouses, temples, grand monuments)

    Usage:
        local EraGates = require(script.Parent.EconomySystem.EraGates)
        EraGates.init()

        -- Check if a player can build something
        local canBuild, reason = EraGates.canBuild(player, "lighthouse")
        if not canBuild then
            -- Show reason to player
        end

        -- Record a completed build
        EraGates.recordBuild(player, "cottage")

        -- Get player's current era
        local era = EraGates.getEra(player)
]]

local EraGates = {}

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

----------------------------------------------------------------
-- ERA DEFINITIONS
----------------------------------------------------------------

ERA_NAMES = {
    [0] = "Driftwood",
    [1] = "Salvage",
    [2] = "Pioneer",
    [3] = "Mariner",
    [4] = "Light",
}

-- Build gating: which builds require which minimum era
-- Anything not listed here is buildable in any era
local BUILD_ERA_REQUIREMENTS: {[string]: number} = {
    -- Era 1+ (Salvage): proper boats, cannery, wood structures
    ["cannery"] = 1,
    ["warehouse"] = 1,
    ["boathouse"] = 1,
    ["shipyard"] = 1,
    ["cottage"] = 1,
    ["workshop"] = 1,

    -- Era 2+ (Pioneer): stone buildings, bridges, windmills
    ["bridge"] = 2,
    ["windmill"] = 2,
    ["mill"] = 2,
    ["stone tower"] = 2,
    ["stone house"] = 2,
    ["market"] = 2,
    ["stable"] = 2,
    ["barn"] = 2,

    -- Era 3+ (Mariner): metal works, forges, advanced vessels
    ["forge"] = 3,
    ["foundry"] = 3,
    ["metal tower"] = 3,
    ["clock tower"] = 3,
    ["steel ship"] = 3,

    -- Era 4 (Light): lighthouses, temples, grand monuments
    ["lighthouse"] = 4,
    ["beacon"] = 4,
    ["temple"] = 4,
    ["shrine"] = 4,
    ["obelisk"] = 4,
    ["monument"] = 4,
    ["cathedral"] = 4,
    ["grand tower"] = 4,
}

-- Era advancement requirements
local ERA_GATES = {
    {
        fromEra = 0, toEra = 1,
        name = "Salvage",
        requirements = { builds = 10, fishCaught = 20, scrapEarned = 200 },
        ceremony = "First real tools. Lucineier unlocks the salvage yard.",
    },
    {
        fromEra = 1, toEra = 2,
        name = "Pioneer",
        requirements = { builds = 25, fishCaught = 75, scrapEarned = 1000 },
        ceremony = "Pioneer status. New vessel, new waters, new possibilities.",
    },
    {
        fromEra = 2, toEra = 3,
        name = "Mariner",
        requirements = { builds = 50, fishCaught = 200, scrapEarned = 3000 },
        ceremony = "Mariner. You've earned the sea's respect. And a proper fishing boat.",
    },
    {
        fromEra = 3, toEra = 4,
        name = "Light",
        requirements = { builds = 100, fishCaught = 500, scrapEarned = 8000 },
        ceremony = "The Light era. This harbor answers to you now.",
    },
}

-- Era unlock descriptions (shown to player on advancement)
local ERA_UNLOCK_DESCRIPTIONS = {
    [1] = "You can now build: cottages, cannery, warehouse, boathouse, shipyard, workshop.",
    [2] = "You can now build: bridges, windmills, stone towers, markets, stables, barns.",
    [3] = "You can now build: forges, foundries, metal towers, clock towers, steel ships.",
    [4] = "You can now build: lighthouses, temples, shrines, obelisks, monuments, cathedrals.",
}

----------------------------------------------------------------
-- STATE (per-player, in-memory; persisted via SaveSystem)
----------------------------------------------------------------

EraGates._playerEras = {}       -- [userId] = eraNumber (0-4)
EraGates._playerStats = {}      -- [userId] = { builds, fishCaught, scrapEarned }
EraGates._notified = {}         -- [userId] = { eraNumber = true } (avoid duplicate notifications)

----------------------------------------------------------------
-- INITIALIZATION
----------------------------------------------------------------

function EraGates.init()
    print("[EraGates] Initialized — 5 eras, " .. #BUILD_ERA_REQUIREMENTS .. " gated build types")

    Players.PlayerRemoving:Connect(function(player)
        local uid = player.UserId
        EraGates._playerEras[uid] = nil
        EraGates._playerStats[uid] = nil
        EraGates._notified[uid] = nil
    end)
end

----------------------------------------------------------------
-- ERA ACCESS
----------------------------------------------------------------

--[[
    Get the player's current era (0-4).
    @param player Player
    @return number — era 0 through 4
]]
function EraGates.getEra(player): number
    local uid = player.UserId
    if EraGates._playerEras[uid] == nil then
        EraGates._playerEras[uid] = 0
    end
    return EraGates._playerEras[uid]
end

--[[
    Set the player's era directly (used by save system on load).
    @param player Player
    @param era number — era to set (0-4)
]]
function EraGates.setEra(player, era: number)
    EraGates._playerEras[player.UserId] = math.clamp(era, 0, 4)
end

--[[
    Get the player's current stats.
    @param player Player
    @return table — { builds, fishCaught, scrapEarned }
]]
function EraGates.getStats(player)
    local uid = player.UserId
    if EraGates._playerStats[uid] == nil then
        EraGates._playerStats[uid] = { builds = 0, fishCaught = 0, scrapEarned = 0 }
    end
    return EraGates._playerStats[uid]
end

--[[
    Update player stats from external systems (EconomySystem.Currency).
    Called before era checks to ensure stats are current.
    @param player Player
    @param stats table — { builds=N, fishCaught=N, scrapEarned=N }
]]
function EraGates.updateStats(player, stats)
    local uid = player.UserId
    EraGates._playerStats[uid] = EraGates._playerStats[uid] or { builds = 0, fishCaught = 0, scrapEarned = 0 }
    if stats.builds then EraGates._playerStats[uid].builds = stats.builds end
    if stats.fishCaught then EraGates._playerStats[uid].fishCaught = stats.fishCaught end
    if stats.scrapEarned then EraGates._playerStats[uid].scrapEarned = stats.scrapEarned end
end

----------------------------------------------------------------
-- BUILD GATING
----------------------------------------------------------------

--[[
    Check if a player can build a specific structure.
    Returns (allowed, reason).
    @param player Player
    @param buildType string — the type of structure (e.g. "lighthouse", "cottage")
    @return boolean — true if allowed
    @return string? — reason if denied
]]
function EraGates.canBuild(player, buildType: string): (boolean, string?)
    if not buildType or buildType == "" then
        return true  -- No restriction on unknown build types
    end

    local required = BUILD_ERA_REQUIREMENTS[string.lower(buildType)]
    if not required then
        return true  -- Not gated — buildable in any era
    end

    local currentEra = EraGates.getEra(player)
    if currentEra >= required then
        return true
    end

    local eraName = ERA_NAMES[required] or "higher"
    local currentName = ERA_NAMES[currentEra] or "Driftwood"
    local reason = string.format(
        "Can't build a %s yet. That's %s-era work. You're in %s era — keep building.",
        buildType, eraName, currentName
    )
    return false, reason
end

----------------------------------------------------------------
-- BUILD RECORDING & ERA ADVANCEMENT
----------------------------------------------------------------

--[[
    Record a completed build and check for era advancement.
    @param player Player
    @param buildType string — what was built
    @return boolean — true if era advanced
    @return number? — new era if advanced
]]
function EraGates.recordBuild(player, buildType: string): (boolean, number?)
    local uid = player.UserId
    local stats = EraGates.getStats(player)
    stats.builds = (stats.builds or 0) + 1

    return EraGates._checkAdvancement(player)
end

--[[
    Record fish caught and check for era advancement.
    @param player Player
    @param count number — number of fish caught
    @return boolean — true if era advanced
]]
function EraGates.recordFish(player, count: number): (boolean, number?)
    local stats = EraGates.getStats(player)
    stats.fishCaught = (stats.fishCaught or 0) + (count or 1)
    return EraGates._checkAdvancement(player)
end

--[[
    Record scrap earned and check for era advancement.
    @param player Player
    @param amount number — scrap amount
    @return boolean — true if era advanced
]]
function EraGates.recordScrap(player, amount: number): (boolean, number?)
    local stats = EraGates.getStats(player)
    stats.scrapEarned = (stats.scrapEarned or 0) + (amount or 0)
    return EraGates._checkAdvancement(player)
end

----------------------------------------------------------------
-- INTERNAL: ADVANCEMENT CHECK
----------------------------------------------------------------

function EraGates._checkAdvancement(player): (boolean, number?)
    local uid = player.UserId
    local currentEra = EraGates.getEra(player)
    local stats = EraGates.getStats(player)

    -- Max era reached
    if currentEra >= 4 then
        return false, nil
    end

    -- Find the gate for current era
    local gate = nil
    for _, g in ipairs(ERA_GATES) do
        if g.fromEra == currentEra then
            gate = g
            break
        end
    end

    if not gate then
        return false, nil
    end

    -- Check all requirements
    local req = gate.requirements
    local allMet = true
    for key, requiredValue in pairs(req) do
        local current = stats[key] or 0
        if current < requiredValue then
            allMet = false
            break
        end
    end

    if not allMet then
        return false, nil
    end

    -- Advance!
    local newEra = gate.toEra
    EraGates._playerEras[uid] = newEra

    -- Fire notification
    EraGates._notifyAdvancement(player, newEra, gate)

    return true, newEra
end

----------------------------------------------------------------
-- NOTIFICATIONS
----------------------------------------------------------------

function EraGates._notifyAdvancement(player, newEra: number, gate)
    local uid = player.UserId

    -- Avoid duplicate notifications
    if EraGates._notified[uid] and EraGates._notified[uid][newEra] then
        return
    end
    EraGates._notified[uid] = EraGates._notified[uid] or {}
    EraGates._notified[uid][newEra] = true

    local eraName = ERA_NAMES[newEra] or "new"
    local ceremony = gate.ceremony or ""
    local unlocks = ERA_UNLOCK_DESCRIPTIONS[newEra] or ""

    -- Fire RemoteEvent to client
    local target = ReplicatedStorage:FindFirstChild("Lucineer")
    local ev = target and target:FindFirstChild("EconomyEvent")
    if ev then
        ev:FireClient(player, {
            type = "eraAdvancement",
            newEra = newEra,
            eraName = eraName,
            ceremony = ceremony,
            unlocks = unlocks,
        })
    end

    -- Also fire to all clients for server-wide awareness
    if ev then
        ev:FireAllClients({
            type = "eraAnnouncement",
            playerName = player.Name,
            newEra = newEra,
            eraName = eraName,
        })
    end

    -- Lucineer dialogue
    local responseRemote = ReplicatedStorage:FindFirstChild("ResponseRemote")
        or (target and target:FindFirstChild("ResponseRemote"))
    if responseRemote then
        local lines = {
            [1] = "We made it. Salvage tier. I've been waiting to build you something proper. Head to the dock — your new boat's waiting.",
            [2] = "Pioneer. You've earned stone and steel. Let's see what you build when the materials stop fighting back.",
            [3] = "Mariner. The sea knows your name now. So do I, for what it's worth. Let's build something worthy of the water.",
            [4] = "Light. The last era. Lighthouses, temples — things people build when they plan to stay. This harbor is yours now.",
        }
        responseRemote:FireClient(player, {
            type = "dialogue",
            text = lines[newEra] or ceremony,
            speaker = "Lucineier",
        })
    end

    print(string.format("[EraGates] %s advanced to Era %d (%s)",
        player.Name, newEra, eraName))
end

----------------------------------------------------------------
-- PROGRESS REPORTING
----------------------------------------------------------------

--[[
    Get progress toward the next era.
    @param player Player
    @return table? — { currentEra, nextEra, eraName, progress = { key = { current, required, met } } }
]]
function EraGates.getProgress(player)
    local currentEra = EraGates.getEra(player)
    local stats = EraGates.getStats(player)

    if currentEra >= 4 then
        return {
            currentEra = 4,
            nextEra = nil,
            eraName = "Light",
            progress = nil,
            maxEra = true,
        }
    end

    local gate = nil
    for _, g in ipairs(ERA_GATES) do
        if g.fromEra == currentEra then
            gate = g
            break
        end
    end

    if not gate then
        return { currentEra = currentEra, nextEra = nil, progress = nil }
    end

    local progress = {}
    for key, requiredValue in pairs(gate.requirements) do
        local current = stats[key] or 0
        progress[key] = {
            current = current,
            required = requiredValue,
            met = current >= requiredValue,
        }
    end

    return {
        currentEra = currentEra,
        nextEra = gate.toEra,
        eraName = ERA_NAMES[currentEra],
        nextEraName = gate.name,
        progress = progress,
    }
end

----------------------------------------------------------------
-- SERIALIZATION (for SaveSystem)
----------------------------------------------------------------

--[[
    Get serializable player data for saving.
    @param player Player
    @return table — { era = N, stats = {...} }
]]
function EraGates.serialize(player)
    return {
        era = EraGates.getEra(player),
        stats = EraGates.getStats(player),
    }
end

--[[
    Load player data from save.
    @param player Player
    @param data table — { era = N, stats = {...} }
]]
function EraGates.deserialize(player, data)
    if not data then return end
    if data.era then
        EraGates.setEra(player, data.era)
    end
    if data.stats then
        EraGates._playerStats[player.UserId] = data.stats
    end
end

return EraGates
