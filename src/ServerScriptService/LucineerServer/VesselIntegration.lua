--!strict
--[[
    VesselIntegration.lua — Slackwater Vessel Ecosystem Integration
    ================================================================
    Wires VesselSystem, FishingSystem, EconomySystem, CrewSystem
    into the existing LucineerServer game loop.

    Game State Machine:
      IN_YARD → AT_DOCK → BOARDING → UNDERWAY → FISHING → RETURNING → DOCKED → loop
]]

local VesselIntegration = {}

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

-- State
VesselIntegration._playerStates = {}  -- [userId] = stateString
VesselIntegration._vessels = {}       -- [userId] = vesselModel
VesselIntegration._modules = {}       -- cached module refs
VesselIntegration._remoteEvents = {}

-- Game states
local STATES = {
    IN_YARD = "IN_YARD",
    AT_DOCK = "AT_DOCK",
    BOARDING = "BOARDING",
    UNDERWAY = "UNDERWAY",
    FISHING = "FISHING",
    RETURNING = "RETURNING",
    DOCKED = "DOCKED",
}

-- Safe require — wraps in pcall, returns nil if module missing
local function safeRequire(path)
    local ok, mod = pcall(function()
        return require(path)
    end)
    if ok then return mod end
    warn("[VesselIntegration] Could not load: " .. path:GetFullName())
    return nil
end

-- Lazy-load all vessel sub-systems
local function loadModules()
    if VesselIntegration._modulesLoaded then return end
    VesselIntegration._modulesLoaded = true

    local ss = script.Parent
    local rs = ReplicatedStorage:FindFirstChild("Lucineer")

    VesselIntegration._modules.VesselSystem = safeRequire(ss.Parent:FindFirstChild("VesselSystem"))
    VesselIntegration._modules.FishingSystem = safeRequire(ss.Parent:FindFirstChild("FishingSystem"))
    VesselIntegration._modules.EconomySystem = safeRequire(ss.Parent:FindFirstChild("EconomySystem"))
    VesselIntegration._modules.CrewSystem = safeRequire(ss.Parent:FindFirstChild("CrewSystem"))
    VesselIntegration._modules.BondSystem = safeRequire(ss:FindFirstChild("BondSystem"))
    VesselIntegration._modules.EraSystem = safeRequire(ss:FindFirstChild("EraSystem"))
    VesselIntegration._modules.AchievementManager = safeRequire(ss:FindFirstChild("AchievementManager"))
    VesselIntegration._modules.SaveSystem = safeRequire(ss:FindFirstChild("SaveSystem"))
    VesselIntegration._modules.WeatherSystem = safeRequire(ss:FindFirstChild("WeatherSystem"))
    VesselIntegration._modules.NPCManager = safeRequire(ss:FindFirstChild("NPCManager"))
end

-- Create RemoteEvents for vessel communication
local function createRemoteEvents()
    if VesselIntegration._remoteEventsCreated then return end
    VesselIntegration._remoteEventsCreated = true

    local target = ReplicatedStorage:FindFirstChild("Lucineer")
    if not target then
        target = Instance.new("Folder")
        target.Name = "Lucineer"
        target.Parent = ReplicatedStorage
    end

    local eventNames = {"VesselEvent", "FishingEvent", "EconomyEvent", "CrewEvent"}
    for _, name in ipairs(eventNames) do
        if not target:FindFirstChild(name) then
            local ev = Instance.new("RemoteEvent")
            ev.Name = name
            ev.Parent = target
        end
        VesselIntegration._remoteEvents[name] = target:FindFirstChild(name)
    end
end

-- Get or initialize player state
function VesselIntegration.getPlayerState(player)
    local uid = player.UserId
    if not VesselIntegration._playerStates[uid] then
        VesselIntegration._playerStates[uid] = STATES.IN_YARD
    end
    return VesselIntegration._playerStates[uid]
end

-- Set player state and notify client
function VesselIntegration.setPlayerState(player, newState)
    local uid = player.UserId
    local oldState = VesselIntegration._playerStates[uid] or STATES.IN_YARD
    VesselIntegration._playerStates[uid] = newState

    if oldState ~= newState then
        -- Fire state change event to client
        local ev = VesselIntegration._remoteEvents.VesselEvent
        if ev then
            ev:FireClient(player, {
                type = "stateChange",
                oldState = oldState,
                newState = newState,
            })
        end

        -- Context-aware Lucineier dialogue
        if newState == STATES.BOARDING then
            VesselIntegration._fireLucineerResponse(player,
                "Watch your step. She's a good boat. Treat her right.")
        elseif newState == STATES.UNDERWAY then
            VesselIntegration._fireLucineierResponse(player,
                " Seas aren't bad today. Should be a good run.")
        elseif newState == STATES.FISHING then
            VesselIntegration._fireLucineierResponse(player,
                "Gear's wet. Now we see what the ocean's willing to give up today.")
        elseif newState == STATES.DOCKED then
            VesselIntegration._fireLucineierResponse(player,
                "Tied off solid. Earl's waiting at the cannery.")
        end
    end
end

-- Chat command router for vessel mode
-- Returns true if handled (skip normal Lucineier chat), false to pass through
function VesselIntegration.handleChat(player, message)
    local state = VesselIntegration.getPlayerState(player)
    local msg = string.lower(message)

    -- Only intercept in vessel states
    if state == STATES.IN_YARD then
        return false
    end

    local handled = false

    -- Anchor controls
    if msg:match("drop anchor") or msg:match("anchor down") then
        VesselIntegration._fireVesselCommand(player, "anchor", true)
        VesselIntegration._fireLucineerResponse(player, "Anchor's going down. We'll hold here.")
        handled = true

    elseif msg:match("raise anchor") or msg:match("anchor up") or msg:match("weigh anchor") then
        VesselIntegration._fireVesselCommand(player, "anchor", false)
        VesselIntegration._fireLucineierResponse(player, "Anchor's up. We're moving.")
        handled = true

    -- Speed controls
    elseif msg:match("full speed") or msg:match("full throttle") then
        VesselIntegration._fireVesselCommand(player, "throttle", 1.0)
        VesselIntegration._fireLucineierResponse(player, "Full ahead. Holding on.")
        handled = true

    elseif msg:match("slow down") or msg:match("half speed") then
        VesselIntegration._fireVesselCommand(player, "throttle", 0.5)
        VesselIntegration._fireLucineierResponse(player, "Half speed. Easing back.")
        handled = true

    elseif msg:match("stop") or msg:match("all stop") or msg:match("hold position") then
        VesselIntegration._fireVesselCommand(player, "throttle", 0.0)
        VesselIntegration._fireLucineierResponse(player, "All stop. Drifting neutral.")
        handled = true

    -- Heading controls
    elseif msg:match("head north") or msg:match("turn north") then
        VesselIntegration._fireVesselCommand(player, "heading", 0)
        VesselIntegration._fireLucineierResponse(player, "Coming to north. Compass is steady.")
        handled = true

    elseif msg:match("head south") or msg:match("turn south") then
        VesselIntegration._fireVesselCommand(player, "heading", 180)
        VesselIntegration._fireLucineierResponse(player, "South it is. Open water ahead.")
        handled = true

    elseif msg:match("head east") or msg:match("turn east") then
        VesselIntegration._fireVesselCommand(player, "heading", 90)
        VesselIntegration._fireLucineierResponse(player, "Eastward. Sun's off the starboard bow.")
        handled = true

    elseif msg:match("head west") or msg:match("turn west") then
        VesselIntegration._fireVesselCommand(player, "heading", 270)
        VesselIntegration._fireLucineierResponse(player, "West. Into whatever's coming.")
        handled = true

    -- Navigation
    elseif msg:match("check depth") or msg:match("how deep") or msg:match("depth") then
        VesselIntegration._fireVesselCommand(player, "checkDepth", nil)
        handled = true

    elseif msg:match("head back") or msg:match("return to dock") or msg:match("head home") then
        VesselIntegration.setPlayerState(player, STATES.RETURNING)
        VesselIntegration._fireVesselCommand(player, "returnToDock", nil)
        VesselIntegration._fireLucineierResponse(player, "Coming about. Harbor's bearing southeast.")
        handled = true

    -- Fishing
    elseif msg:match("cast line") or msg:match("drop line") or msg:match("start fishing") then
        if state == STATES.UNDERWAY or state == STATES.AT_DOCK then
            VesselIntegration.setPlayerState(player, STATES.FISHING)
            VesselIntegration._fireFishingCommand(player, "deploy", "handline")
            handled = true
        end
    elseif msg:match("drop pot") or msg:match("set pot") then
        if state == STATES.UNDERWAY or state == STATES.AT_DOCK then
            VesselIntegration.setPlayerState(player, STATES.FISHING)
            VesselIntegration._fireFishingCommand(player, "deploy", "pot")
            handled = true
        end
    elseif msg:match("reel in") or msg:match("retrieve") or msg:match("pull up") then
        VesselIntegration._fireFishingCommand(player, "retrieve", nil)
        handled = true

    -- Docking
    elseif msg:match("dock") or msg:match("tie up") or msg:match("moor") then
        VesselIntegration.setPlayerState(player, STATES.DOCKED)
        handled = true

    -- Disembark
    elseif msg:match("go ashore") or msg:match("leave boat") or msg:match("disembark") then
        VesselIntegration.setPlayerState(player, STATES.IN_YARD)
        VesselIntegration._fireLucineierResponse(player, "Boat's tied off safe. I'll keep an eye on her.")
        handled = true
    end

    return handled
end

-- Fire Lucineier dialogue response through existing ResponseRemote
function VesselIntegration._fireLucineierResponse(player, text)
    local responseRemote = ReplicatedStorage:FindFirstChild("ResponseRemote")
        or (ReplicatedStorage:FindFirstChild("Lucineer") and ReplicatedStorage.Lucineer:FindFirstChild("ResponseRemote"))
    if responseRemote then
        responseRemote:FireClient(player, {
            type = "dialogue",
            text = text,
            speaker = "Lucineier",
        })
    end
end

-- Fire vessel command to client
function VesselIntegration._fireVesselCommand(player, command, value)
    local ev = VesselIntegration._remoteEvents.VesselEvent
    if ev then
        ev:FireClient(player, {
            type = "command",
            command = command,
            value = value,
        })
    end
end

-- Fire fishing command
function VesselIntegration._fireFishingCommand(player, command, gearType)
    local ev = VesselIntegration._remoteEvents.FishingEvent
    if ev then
        ev:FireClient(player, {
            type = "fishingCommand",
            command = command,
            gearType = gearType,
        })
    end
end

-- Post-build hook: vessel-related builds
function VesselIntegration.onBuild(player, buildType)
    local economy = VesselIntegration._modules.EconomySystem
    local buildCosts = economy and economy.BuildCosts

    -- Vessel-related builds unlock capabilities
    local buildType_lower = string.lower(buildType or "")

    if buildType_lower:match("dock") or buildType_lower:match("pier") then
        -- Dock extension → increase harbor capacity
        VesselIntegration._fireLucineierResponse(player,
            "Dock's longer. Can berth a bigger boat now, when you're ready.")

    elseif buildType_lower:match("lighthouse") then
        -- Lighthouse → reveal chart area, enable night navigation
        local ev = VesselIntegration._remoteEvents.VesselEvent
        if ev then
            ev:FireClient(player, { type = "chartReveal", area = "north" })
        end
        VesselIntegration._fireLucineierResponse(player,
            "Light's sweeping clean. You can find harbor in any fog now.")

    elseif buildType_lower:match("cannery") or buildType_lower:match("warehouse") then
        -- Cannery upgrade → increase daily catch processing limit
        VesselIntegration._fireLucineierResponse(player,
            "More floor space. Earl can process bigger hauls. Good.")

    elseif buildType_lower:match("boathouse") or buildType_lower:match("shipyard") then
        -- Boat house → unlock vessel upgrade path
        VesselIntegration._fireLucineierResponse(player,
            "Now we can work on the hull proper. Bring me materials when you've got them.")
    end

    -- Check era gates after every build
    VesselIntegration._checkEraAdvancement(player)
end

-- Post-catch hook
function VesselIntegration.onCatch(player, species, weight, quality)
    local uid = player.UserId

    -- Update cargo via economy system
    local economy = VesselIntegration._modules.EconomySystem
    if economy and economy.Currency then
        -- Quality multiplier: A=1.0, B=0.7, C=0.4
        local qMult = (quality == "A") and 1.0 or (quality == "B") and 0.7 or 0.4
        -- Track lifetime stats
        economy.Currency.addStat(uid, "fishCaught", 1)
        economy.Currency.addStat(uid, "weightCaught", weight or 0)
    end

    -- Check achievements
    local ach = VesselIntegration._modules.AchievementManager
    if ach and ach.checkCatch then
        ach.checkCatch(player, species, weight)
    end

    -- Check era gates
    VesselIntegration._checkEraAdvancement(player)

    -- Rare catch dialogue
    if weight and weight > 50 then
        VesselIntegration._fireLucineierResponse(player,
            "That's a proper fish. Earl'll notice that one.")
    end
end

-- Check and trigger era advancement
function VesselIntegration._checkEraAdvancement(player)
    local era = VesselIntegration._modules.EraSystem
    local economy = VesselIntegration._modules.EconomySystem
    if not era or not economy then return end

    local uid = player.UserId
    local stats = economy.Currency.getStats(uid)
    if not stats then return end

    -- Era gate thresholds
    local gates = {
        { from = 0, to = 1, builds = 10, fish = 20, scrap = 200 },
        { from = 1, to = 2, builds = 25, fish = 75, scrap = 1000 },
        { from = 2, to = 3, builds = 50, fish = 200, scrap = 3000 },
        { from = 3, to = 4, builds = 100, fish = 500, scrap = 8000 },
    }

    local currentEra = era.GetEra and era.GetEra(player) or 0

    for _, gate in ipairs(gates) do
        if currentEra == gate.from then
            if (stats.builds or 0) >= gate.builds
               and (stats.fishCaught or 0) >= gate.fish
               and (stats.scrapEarned or 0) >= gate.scrap then
                VesselIntegration._advanceEra(player, gate.to)
                break
            end
        end
    end
end

-- Era advancement ceremony
function VesselIntegration._advanceEra(player, newEra)
    local era = VesselIntegration._modules.EraSystem
    local bond = VesselIntegration._modules.BondSystem
    local save = VesselIntegration._modules.SaveSystem

    -- Advance era
    if era and era.SetEra then
        era.SetEra(player, newEra)
    end

    -- Deepen bond
    if bond and bond.addBondXP then
        bond.addBondXP(player.UserId, 500)  -- significant bond boost
    end

    -- Announce
    local eraNames = {
        [1] = "Salvage",
        [2] = "Pioneer",
        [3] = "Mariner",
        [4] = "Captain",
    }
    local name = eraNames[newEra] or "new"

    VesselIntegration._fireLucineierResponse(player,
        string.format(
            "We made it. %s tier. I've been waiting to build you something proper. " ..
            "Head to the dock — your new boat's waiting.",
            name
        ))

    -- Fire era advancement event
    local ev = VesselIntegration._remoteEvents.EconomyEvent
    if ev then
        ev:FireAllClients({
            type = "eraAdvancement",
            player = player.Name,
            newEra = newEra,
            eraName = name,
        })
    end

    -- Spawn new vessel at dock
    local vessel = VesselIntegration._modules.VesselSystem
    if vessel and vessel.Spawner and vessel.Spawner.spawnForPlayer then
        vessel.Spawner.spawnForPlayer(player, newEra)
    end

    -- Save state
    if save and save.syncToCloud then
        save.syncToCloud(player.UserId)
    end
end

-- Handle vessel damage events
function VesselIntegration.onVesselDamage(player, section, damageAmount)
    local bond = VesselIntegration._modules.BondSystem

    -- Surviving damage together builds bond
    if bond and bond.addSharedHardship then
        bond.addSharedHardship(player.UserId, damageAmount)
    end

    -- Warning dialogue
    if damageAmount > 30 then
        VesselIntegration._fireLucineierResponse(player,
            "That was a hard hit. Check the hull. We might need Earl's yard.")
    end
end

-- Handle vessel sinking
function VesselIntegration.onVesselSink(player)
    VesselIntegration._fireLucineierResponse(player,
        "She's going down. Get clear. We'll build another — I promise.")

    -- Reset to dock state
    VesselIntegration.setPlayerState(player, STATES.IN_YARD)

    -- Penalty: lose current cargo, keep stats
    local economy = VesselIntegration._modules.EconomySystem
    if economy and economy.Currency then
        economy.Currency.clearCargo(player.UserId)
    end

    -- Save the loss
    local save = VesselIntegration._modules.SaveSystem
    if save and save.syncToCloud then
        save.syncToCloud(player.UserId)
    end
end

-- Player joining — initialize state
local function onPlayerAdded(player)
    VesselIntegration._playerStates[player.UserId] = STATES.IN_YARD
end

-- Player leaving — cleanup
local function onPlayerRemoving(player)
    VesselIntegration._playerStates[player.UserId] = nil
    VesselIntegration._vessels[player.UserId] = nil
end

-- Initialize the vessel integration
function VesselIntegration.init()
    loadModules()
    createRemoteEvents()

    -- Hook player events
    Players.PlayerAdded:Connect(onPlayerAdded)
    Players.PlayerRemoving:Connect(onPlayerRemoving)

    -- Initialize existing players (Studio playtest)
    for _, player in ipairs(Players:GetPlayers()) do
        onPlayerAdded(player)
    end

    -- RemoteEvent handlers (client → server)
    local vesselEv = VesselIntegration._remoteEvents.VesselEvent
    if vesselEv then
        vesselEv.OnServerEvent:Connect(function(player, data)
            if data.type == "requestBoard" then
                VesselIntegration.setPlayerState(player, STATES.BOARDING)
                -- After boarding animation, transition to UNDERWAY
                task.delay(3, function()
                    if VesselIntegration.getPlayerState(player) == STATES.BOARDING then
                        VesselIntegration.setPlayerState(player, STATES.UNDERWAY)
                    end
                end)
            elseif data.type == "vesselDamaged" then
                VesselIntegration.onVesselDamage(player, data.section or "hull", data.damage or 10)
            elseif data.type == "vesselSunk" then
                VesselIntegration.onVesselSink(player)
            end
        end)
    end

    local fishingEv = VesselIntegration._remoteEvents.FishingEvent
    if fishingEv then
        fishingEv.OnServerEvent:Connect(function(player, data)
            if data.type == "catch" then
                VesselIntegration.onCatch(player, data.species, data.weight, data.quality)
            elseif data.type == "requestDeploy" then
                VesselIntegration.setPlayerState(player, STATES.FISHING)
            elseif data.type == "doneFishing" then
                VesselIntegration.setPlayerState(player, STATES.UNDERWAY)
            end
        end)
    end

    local economyEv = VesselIntegration._remoteEvents.EconomyEvent
    if economyEv then
        economyEv.OnServerEvent:Connect(function(player, data)
            if data.type == "sellCatch" then
                local economy = VesselIntegration._modules.EconomySystem
                if economy and economy.Currency then
                    local earned = economy.Currency.sellCargo(player.UserId)
                    if earned and earned > 0 then
                        VesselIntegration._fireLucineierResponse(player,
                            string.format("Sold the lot. %d scrap in your pocket. Not bad for a day's work.", earned))
                        VesselIntegration._checkEraAdvancement(player)
                    end
                end
            end
        end)
    end

    print("[VesselIntegration] Initialized — vessel ecosystem online")
end

return VesselIntegration
