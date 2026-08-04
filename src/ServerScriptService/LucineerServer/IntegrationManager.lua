--!strict
--[[
    IntegrationManager.lua — Slackwater System Integration Glue
    ═══════════════════════════════════════════════════════════════════════
    "The boat is the game. Everything else is weather."
    But the boat doesn't float without glue. This is the glue.

    Wires together the six critical integration points identified in the
    Aug 3 audit. Each system is 70-90% complete individually, but the
    connections between them were 20-30%. This file closes that gap.

    Integration Points:
      1. Build completion  → BondSystem + EconomySystem.BuildCosts
      2. Fishing completion → EconomySystem.Currency + AchievementManager
      3. Vessel spawn       → CrewSystem + VesselSystem.VesselSpawner
      4. Era change         → EconomySystem.EraGates + WeatherSystem + WorldGenerator
      5. Player join        → TutorialSystem + SaveSystem + BondSystem
      6. Player leave       → SaveSystem + BondSystem

    Design Pattern:
        Direct function calls (matching VesselIntegration.lua style).
        BindableEvents are created only for cross-system broadcasts that
        multiple consumers may need. Each hook wraps in pcall for safety
        so one failing system doesn't cascade.

    Usage:
        local IntegrationManager = require(script.IntegrationManager)
        IntegrationManager.init()

    Dependencies (all optional-safe — degrades gracefully if missing):
        - ServerScriptService.VesselSystem
        - ServerScriptService.FishingSystem
        - ServerScriptService.EconomySystem
        - ServerScriptService.CrewSystem
        - ServerScriptService.BondSystem
        - ServerScriptService.EraSystem
        - ServerScriptService.AchievementManager
        - ServerScriptService.SaveSystem
        - ServerScriptService.TutorialSystem
        - ServerScriptService.WeatherSystem
        - ServerScriptService.WorldGenerator
        - ServerScriptService.NPCManager
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local IntegrationManager = {}

-- Cached module references (populated by loadModules)
IntegrationManager._modules = {}
IntegrationManager._initialized = false

-- BindableEvents for cross-system broadcasts
IntegrationManager._bindables = {}

----------------------------------------------------------------
-- SAFE REQUIRE HELPER
----------------------------------------------------------------

--[[
    Safe-require a module instance. Returns nil if missing or errored.
    Matches the pattern used in LucineerServer/init.lua.
    @param instance Instance? -- the module to require
    @return table? -- module or nil
]]
local function safeRequire(instance)
    if not instance then return nil end
    local ok, mod = pcall(require, instance)
    if ok then return mod end
    warn(string.format("[IntegrationManager] Could not load %s: %s",
        instance:GetFullName(), tostring(mod)))
    return nil
end

----------------------------------------------------------------
-- MODULE LOADING
----------------------------------------------------------------

--[[
    Load all system modules lazily. Called once during init().
    Uses the safeRequire pattern so missing systems don't crash.
]]
local function loadModules()
    if IntegrationManager._modulesLoaded then return end
    IntegrationManager._modulesLoaded = true

    local sss = ServerScriptService
    local lucineerServer = sss:FindFirstChild("LucineerServer")

    -- Vessel ecosystem systems (direct children of ServerScriptService)
    IntegrationManager._modules.VesselSystem   = safeRequire(sss:FindFirstChild("VesselSystem"))
    IntegrationManager._modules.FishingSystem  = safeRequire(sss:FindFirstChild("FishingSystem"))
    IntegrationManager._modules.EconomySystem  = safeRequire(sss:FindFirstChild("EconomySystem"))
    IntegrationManager._modules.CrewSystem     = safeRequire(sss:FindFirstChild("CrewSystem"))

    -- Core Lucineer server systems (children of LucineerServer)
    local function fromServer(name)
        return safeRequire(lucineerServer and lucineerServer:FindFirstChild(name) or nil)
    end
    IntegrationManager._modules.BondSystem         = fromServer("BondSystem")
    IntegrationManager._modules.EraSystem           = fromServer("EraSystem")
    IntegrationManager._modules.AchievementManager  = fromServer("AchievementManager")
    IntegrationManager._modules.SaveSystem          = fromServer("SaveSystem")
    IntegrationManager._modules.TutorialSystem      = fromServer("TutorialSystem")
    IntegrationManager._modules.WeatherSystem       = fromServer("WeatherSystem")
    IntegrationManager._modules.NPCManager          = fromServer("NPCManager")

    -- WorldGenerator is a direct child of ServerScriptService
    IntegrationManager._modules.WorldGenerator = safeRequire(sss:FindFirstChild("WorldGenerator"))

    -- EconomySystem submodules (lazy access via getters, but cache them)
    local econ = IntegrationManager._modules.EconomySystem
    if econ then
        -- These are populated after EconomySystem.init() — grab references now
        -- but they may be nil until EconomySystem is initialized. We re-fetch
        -- in each hook to be safe.
        IntegrationManager._modules._econInitialized = false
    end
end

--[[
    Get the Currency submodule from EconomySystem.
    Handles the case where EconomySystem hasn't initialized submodules yet.
    @return table?
]]
local function getCurrency()
    local econ = IntegrationManager._modules.EconomySystem
    if not econ then return nil end
    if econ.getCurrency then
        return econ:getCurrency()
    end
    return nil
end

--[[
    Get the BuildCosts submodule from EconomySystem.
    @return table?
]]
local function getBuildCosts()
    local econ = IntegrationManager._modules.EconomySystem
    if not econ then return nil end
    if econ.getBuildCosts then
        return econ:getBuildCosts()
    end
    return nil
end

--[[
    Get the EraGates submodule from EconomySystem.
    @return table?
]]
local function getEraGates()
    local econ = IntegrationManager._modules.EconomySystem
    if not econ then return nil end
    if econ.getEraGates then
        return econ:getEraGates()
    end
    return nil
end

----------------------------------------------------------------
-- BINDABLE EVENTS
----------------------------------------------------------------

--[[
    Create BindableEvents for cross-system broadcasts.
    These allow multiple systems to listen without direct coupling.
]]
local function createBindables()
    if IntegrationManager._bindablesCreated then return end
    IntegrationManager._bindablesCreated = true

    local eventNames = {
        "OnBuildCompleted",     -- fired after every successful build
        "OnFishCaught",         -- fired after every catch
        "OnVesselSpawned",      -- fired after vessel spawn
        "OnEraChanged",         -- fired on era advancement
        "OnPlayerReady",        -- fired after player join sequence completes
        "OnPlayerDeparting",    -- fired before player leave sequence runs
    }

    for _, name in ipairs(eventNames) do
        local ev = Instance.new("BindableEvent")
        ev.Name = name
        IntegrationManager._bindables[name] = ev
    end
end

----------------------------------------------------------------
-- SAFE CALL HELPER
----------------------------------------------------------------

--[[
    Wrap a function call in pcall and warn on failure.
    Keeps one broken system from cascading.
    @param label string -- for error messages
    @param fn function -- the function to call
    @param ... any -- arguments
    @return any -- result or nil
]]
local function safeCall(label, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        warn(string.format("[IntegrationManager] %s failed: %s", label, tostring(result)))
        return nil
    end
    return result
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- INTEGRATION POINT 1: BUILD COMPLETION
-- ═══════════════════════════════════════════════════════════════
-- When a build completes:
--   → BondSystem.addBuildXP (bond progression)
--   → EconomySystem.BuildCosts.charge (deduct materials)
--   → Fire OnBuildCompleted bindable for other listeners
-- ═══════════════════════════════════════════════════════════════

--[[
    Hook: Called after CommandExecutor finishes a build batch.
    Deducts build costs from EconomySystem and awards bond XP.
    Uses player.Name as the key for EconomySystem (which uses player names),
    and tostring(player.UserId) for BondSystem (which uses userId strings).

    @param player Player -- the player who built
    @param buildType string -- the build type key (e.g. "stone_tower")
    @param succeededCount number -- how many parts succeeded
]]
function IntegrationManager.onBuildCompleted(player, buildType, succeededCount)
    local playerName = player.Name
    local playerId = tostring(player.UserId)

    -- ── EconomySystem: deduct build costs ──
    local buildCosts = getBuildCosts()
    if buildCosts then
        safeCall("BuildCosts.chargeBuild", function()
            local success, missing = buildCosts.chargeBuild(playerName, buildType)
            if not success then
                -- Player couldn't afford — log and notify
                local line = buildCosts.getInsufficientLine and buildCosts.getInsufficientLine(missing)
                    or "Insufficient materials."
                warn(string.format("[IntegrationManager] %s can't afford %s: missing %s",
                    playerName, buildType, tostring(missing)))

                -- Fire Lucineier dialogue about insufficient materials
                IntegrationManager._fireDialogue(player, line)
                return false
            end
            return true
        end)
    end

    -- ── BondSystem: award build XP ──
    local bond = IntegrationManager._modules.BondSystem
    if bond and bond.addBuildXP then
        safeCall("BondSystem.addBuildXP", function()
            if succeededCount and succeededCount > 0 then
                bond.addBuildXP(playerId)
            end
        end)
    end

    -- ── SaveSystem: persist after build ──
    local save = IntegrationManager._modules.SaveSystem
    if save and save.saveBuilds then
        safeCall("SaveSystem.saveBuilds", function()
            save.saveBuilds(playerName)
        end)
    end

    -- ── Broadcast to other listeners ──
    local ev = IntegrationManager._bindables.OnBuildCompleted
    if ev then
        ev:Fire(player, buildType, succeededCount)
    end
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- INTEGRATION POINT 2: FISHING COMPLETION
-- ═══════════════════════════════════════════════════════════════
-- When a fish is caught and sold:
--   → EconomySystem.Currency.earnScrap (add funds)
--   → AchievementManager.unlock (check achievements)
--   → Fire OnFishCaught bindable
-- ═══════════════════════════════════════════════════════════════

--[[
    Hook: Called when a player catches a fish.
    Awards currency and checks achievements.

    @param player Player -- the player who caught the fish
    @param species string -- fish species key
    @param weight number -- weight in game units
    @param quality string -- quality grade ("A", "B", "C")
    @param sellValue number? -- pre-calculated sell value (if already determined)
]]
function IntegrationManager.onFishCaught(player, species, weight, quality, sellValue)
    local playerName = player.Name

    -- ── EconomySystem: award scrap for the catch ──
    local currency = getCurrency()
    if currency then
        safeCall("Currency.earnScrap (catch)", function()
            -- If no pre-calculated sell value, estimate from quality + weight
            local value = sellValue
            if not value then
                local qMult = (quality == "A") and 1.0 or (quality == "B") and 0.7 or 0.4
                value = math.floor((weight or 10) * qMult * 2)
            end
            if value > 0 then
                currency.earnScrap(playerName, value, "caught_" .. tostring(species))
            end
        end)
    end

    -- ── EconomySystem: track lifetime stats ──
    -- Currency tracks totalScrapEarned internally via earnScrap.
    -- Additional stat tracking if the system supports it:
    if currency and currency.award then
        safeCall("Currency.award (fish stats)", function()
            -- Some economy setups track catch stats as influence
            -- Only award influence for quality A catches (meaningful actions only)
            if quality == "A" then
                currency.earnInfluence(playerName, 1, "quality_catch_" .. tostring(species))
            end
        end)
    end

    -- ── AchievementManager: check for catch-based achievements ──
    local ach = IntegrationManager._modules.AchievementManager
    if ach then
        safeCall("AchievementManager (catch)", function()
            -- AchievementManager doesn't have a dedicated checkCatch method,
            -- so we use the generic unlock path for known catch achievements.
            -- First catch
            if ach.getProgress then
                local unlocked = ach.getUnlocked(player.Name)
                if not unlocked or not table.find(unlocked, "first_catch") then
                    ach.unlock(player.Name, "first_catch")
                end
            end

            -- Big catch (weight > 50)
            if weight and weight > 50 then
                if ach.getProgress then
                    local unlocked = ach.getUnlocked(player.Name)
                    if not unlocked or not table.find(unlocked, "big_catch") then
                        ach.unlock(player.Name, "big_catch")
                    end
                end
            end
        end)
    end

    -- ── BondSystem: fishing is a shared activity, award small bond ──
    local bond = IntegrationManager._modules.BondSystem
    if bond and bond.addXP then
        safeCall("BondSystem.addXP (fishing)", function()
            -- Small bond for shared activity (1 point per catch, reasonable)
            bond.addXP(tostring(player.UserId), 1)
        end)
    end

    -- ── Broadcast ──
    local ev = IntegrationManager._bindables.OnFishCaught
    if ev then
        ev:Fire(player, species, weight, quality)
    end
end

--[[
    Hook: Called when a player sells their catch at the dock.
    Converts cargo to scrap via the economy system.

    @param player Player
    @param cargo table? -- { {species, weight, quality}, ... } or nil to use system cargo
    @return number? -- total earned, or nil if economy system unavailable
]]
function IntegrationManager.onCatchSold(player, cargo)
    local playerName = player.Name
    local totalEarned = 0

    local currency = getCurrency()
    if not currency then return nil end

    -- If cargo list provided, sell each item
    if cargo then
        for _, item in ipairs(cargo) do
            local species, weight, quality = item.species, item.weight, item.quality
            local qMult = (quality == "A") and 1.0 or (quality == "B") and 0.7 or 0.4
            local value = math.floor((weight or 10) * qMult * 2)
            if value > 0 then
                safeCall("Currency.earnScrap (sell)", function()
                    currency.earnScrap(playerName, value, "sold_" .. tostring(species))
                end)
                totalEarned = totalEarned + value
            end
        end
    end

    -- Check era advancement after selling
    IntegrationManager._checkEraAdvancement(player)

    -- Broadcast
    local ev = IntegrationManager._bindables.OnFishCaught
    if ev and totalEarned > 0 then
        ev:Fire(player, "bulk_sell", totalEarned, "A")
    end

    return totalEarned
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- INTEGRATION POINT 3: VESSEL SPAWN
-- ═══════════════════════════════════════════════════════════════
-- When a vessel spawns for a player:
--   → VesselSystem.VesselSpawner.spawnVessel (create the vessel)
--   → CrewSystem.assignNPC (assign starting crew)
--   → Fire OnVesselSpawned bindable
-- ═══════════════════════════════════════════════════════════════

--[[
    Hook: Called when a player's vessel should be spawned.
    Spawns the vessel via VesselSystem and assigns default crew.

    @param player Player
    @param eraNumber number -- era tier for vessel type selection
    @return boolean -- true if vessel was spawned successfully
]]
function IntegrationManager.onVesselSpawn(player, eraNumber)
    local success = false

    -- ── VesselSystem: spawn the vessel ──
    local vessel = IntegrationManager._modules.VesselSystem
    if vessel and vessel.VesselSpawner then
        safeCall("VesselSpawner.spawnVessel", function()
            vessel.VesselSpawner.spawnVessel(player, eraNumber or 1)
            success = true
        end)
    elseif vessel and vessel.getModule then
        -- Try via getModule API
        local spawner = vessel.getModule("VesselSpawner")
        if spawner then
            safeCall("VesselSpawner.spawnVessel (getModule)", function()
                spawner.spawnVessel(player, eraNumber or 1)
                success = true
            end)
        end
    end

    if not success then
        warn(string.format("[IntegrationManager] Could not spawn vessel for %s (VesselSystem unavailable)",
            player.Name))
        return false
    end

    -- ── CrewSystem: assign a default deckhand for new vessels ──
    local crew = IntegrationManager._modules.CrewSystem
    if crew then
        safeCall("CrewSystem (assign crew)", function()
            -- CrewSystem.lua exposes hire(userId, crewType) at the top level
            -- Also check for nested CrewSystem module via get crew system
            local crewMgr = crew
            if crew.getCrewSystem then
                crewMgr = crew.getCrewSystem() or crew
            end
            if crewMgr and crewMgr.hire then
                -- Assign a deckhand as starting crew (era 1+ gets deckhand)
                local hireOk = crewMgr.hire(player.UserId, "deckhand")
                if hireOk then
                    print(string.format("[IntegrationManager] Assigned deckhand to %s's vessel",
                        player.Name))
                end
            end
        end)
    end

    -- ── EconomySystem: deduct vessel spawn cost (era-dependent) ──
    local buildCosts = getBuildCosts()
    if buildCosts then
        safeCall("BuildCosts (vessel cost)", function()
            -- Vessel spawns don't have explicit cost entries in BUILD_COSTS,
            -- but we note the event for economy tracking
            -- Future: add vessel_spawn_<era> entries to BUILD_COSTS catalog
        end)
    end

    -- ── Broadcast ──
    local ev = IntegrationManager._bindables.OnVesselSpawned
    if ev then
        ev:Fire(player, eraNumber)
    end

    return true
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- INTEGRATION POINT 4: ERA CHANGE
-- ═══════════════════════════════════════════════════════════════
-- When era advances:
--   → EconomySystem.EraGates.unlock (unlock era content)
--   → WeatherSystem.forceWeather (era-appropriate weather)
--   → WorldGenerator.advanceEra (world changes)
--   → Fire OnEraChanged bindable
-- ═══════════════════════════════════════════════════════════════

-- Era-specific weather mappings
local ERA_WEATHER = {
    [0] = "clear",   -- Pre-era: calm beginnings
    [1] = "clear",   -- Salvage: open skies, salvage washing up
    [2] = "fog",     -- Pioneer: fog rolls in, new waters to explore
    [3] = "rain",    -- Mariner: rain and storms test the new boat
    [4] = "storm",   -- Captain: full storms, the sea demands respect
    [5] = "aurora",  -- Endgame: aurora — the world restored
}

--[[
    Hook: Called when a player advances to a new era.
    Runs the era advancement ceremony: unlock content, change weather,
    advance world generation, spawn new vessel.

    @param player Player
    @param newEra number -- the era the player has advanced to
    @param oldEra number? -- previous era (for delta calculations)
]]
function IntegrationManager.onEraChanged(player, newEra, oldEra)
    oldEra = oldEra or 0
    local playerName = player.Name

    -- ── EconomySystem: unlock era gates ──
    local eraGates = getEraGates()
    if eraGates then
        safeCall("EraGates (unlock)", function()
            -- EraGates defines requirements; we just crossed them.
            -- Notify by firing the check with current stats to log progression.
            if eraGates.getGateForEra then
                local nextGate = eraGates.getGateForEra(newEra)
                if nextGate then
                    print(string.format("[IntegrationManager] Next era gate: %s (era %d → %d)",
                        nextGate.name or "?", newEra, newEra + 1))
                end
            end
        end)
    end

    -- ── EraSystem: unlock the era for the player ──
    local era = IntegrationManager._modules.EraSystem
    if era and era.unlockEra then
        safeCall("EraSystem.unlockEra", function()
            era.unlockEra(playerName, newEra)
        end)
    end

    -- ── WeatherSystem: set era-appropriate weather ──
    local weather = IntegrationManager._modules.WeatherSystem
    if weather and weather.forceWeather then
        safeCall("WeatherSystem.forceWeather", function()
            local weatherType = ERA_WEATHER[newEra] or "clear"
            weather.forceWeather(weatherType)
            print(string.format("[IntegrationManager] Weather set to '%s' for era %d",
                weatherType, newEra))
        end)
    end

    -- ── WorldGenerator: advance era world changes ──
    local worldGen = IntegrationManager._modules.WorldGenerator
    if worldGen then
        safeCall("WorldGenerator (era advance)", function()
            -- WorldGenerator doesn't have an explicit advanceEra method,
            -- but it exposes _ready and world state. We trigger terrain
            -- updates by calling Generate with the era context if supported.
            if worldGen.advanceEra then
                worldGen.advanceEra(newEra)
            elseif worldGen.onEraChanged then
                worldGen.onEraChanged(newEra)
            else
                -- Fallback: just log — WorldGenerator responds to era changes
                -- via EraSystem connections it made during its own init.
                print(string.format("[IntegrationManager] WorldGenerator era hook: %d (no explicit API)",
                    newEra))
            end
        end)
    end

    -- ── EconomySystem: era bonus (influence award) ──
    local currency = getCurrency()
    if currency and currency.earnInfluence then
        safeCall("Currency.earnInfluence (era bonus)", function()
            -- Era advancement is a meaningful milestone → influence
            local bonus = newEra * 5
            currency.earnInfluence(playerName, bonus, "era_" .. tostring(newEra))
        end)
    end

    -- ── BondSystem: significant bond boost on era advancement ──
    local bond = IntegrationManager._modules.BondSystem
    if bond and bond.addXP then
        safeCall("BondSystem.addXP (era)", function()
            bond.addXP(tostring(player.UserId), 500)
        end)
    end

    -- ── Spawn new vessel for the era ──
    IntegrationManager.onVesselSpawn(player, newEra)

    -- ── Save the era progression ──
    local save = IntegrationManager._modules.SaveSystem
    if save and save.saveEra then
        safeCall("SaveSystem.saveEra", function()
            save.saveEra(player, {
                currentEra = newEra,
                unlockedEras = { oldEra, newEra },
            })
        end)
    elseif save and save.syncToCloud then
        safeCall("SaveSystem.syncToCloud (era fallback)", function()
            save.syncToCloud(player)
        end)
    end

    -- ── Broadcast ──
    local ev = IntegrationManager._bindables.OnEraChanged
    if ev then
        ev:Fire(player, newEra, oldEra)
    end

    print(string.format("[IntegrationManager] Era advancement complete: %s → era %d",
        playerName, newEra))
end

--[[
    Check if a player meets era advancement criteria and trigger era change.
    Internal method — called after builds and catch sales.

    @param player Player
]]
function IntegrationManager._checkEraAdvancement(player)
    local era = IntegrationManager._modules.EraSystem
    local currency = getCurrency()
    local eraGates = getEraGates()
    if not (era and currency and eraGates) then return end

    safeCall("Era advancement check", function()
        local playerName = player.Name

        -- Get current era
        local currentEra = 0
        if era.getBuildingEra then
            currentEra = era.getBuildingEra(playerName) or 0
        elseif era.getCurrentEra then
            currentEra = era.getCurrentEra(playerName) or 0
        end

        -- Gather stats for gate check
        local wallet = currency.getWallet and currency.getWallet(playerName) or {}
        local stats = {
            builds = (era.getBuildCounts and era.getBuildCounts(playerName)) or 0,
            fishCaught = wallet.totalFishCaught or 0,
            scrapEarned = wallet.totalScrapEarned or 0,
        }

        -- Check gate
        local allMet, info = eraGates.checkAdvancement(stats, currentEra)
        if allMet and info and info.gate then
            IntegrationManager.onEraChanged(player, info.gate.toEra, currentEra)
        end
    end)
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- INTEGRATION POINT 5: PLAYER JOIN
-- ═══════════════════════════════════════════════════════════════
-- When a player joins:
--   → SaveSystem.loadFromCloud (restore builds + state)
--   → BondSystem.loadBond (restore bond tier — handled internally by BondSystem)
--   → TutorialSystem.startTutorial (if new player)
--   → Fire OnPlayerReady bindable
-- ═══════════════════════════════════════════════════════════════

--[[
    Hook: Called when a player joins the server.
    Orchestrates the full join sequence: load save, restore bond,
    start tutorial for new players, initialize economy wallet.

    @param player Player
]]
function IntegrationManager.onPlayerJoin(player)
    local playerName = player.Name
    local playerId = tostring(player.UserId)

    -- ── SaveSystem: load from cloud ──
    local save = IntegrationManager._modules.SaveSystem
    if save then
        safeCall("SaveSystem.loadFromCloud", function()
            save.loadFromCloud(player)
        end)

        -- Also load D1 profile data (era, inventory)
        safeCall("SaveSystem.loadPlayer", function()
            if save.loadPlayer then
                save.loadPlayer(playerName)
            end
        end)

        -- Load era progression
        safeCall("SaveSystem.loadEra", function()
            if save.loadEra then
                save.loadEra(player)
            end
        end)
    end

    -- ── BondSystem: load bond (handled internally by BondSystem's own
    --    PlayerAdded connection, but we trigger the return check) ──
    local bond = IntegrationManager._modules.BondSystem
    if bond then
        safeCall("BondSystem (join)", function()
            -- BondSystem.init() already hooks PlayerAdded for loadBond.
            -- We call onPlayerJoin for the return-after-absence check.
            if bond.onPlayerJoin then
                bond.onPlayerJoin(playerId)
            end
        end)
    end

    -- ── EconomySystem: ensure wallet exists (Currency.init hooks
    --    PlayerAdded, but for Studio playtest with existing players we
    --    trigger manually) ──
    local currency = getCurrency()
    if currency then
        safeCall("Currency (wallet init)", function()
            -- getWallet has side effect of creating the wallet if missing
            if currency.getWallet then
                currency.getWallet(playerName)
            end
        end)
    end

    -- ── TutorialSystem: start tutorial for new players ──
    local tutorial = IntegrationManager._modules.TutorialSystem
    if tutorial then
        safeCall("TutorialSystem (start)", function()
            -- Check if player has completed tutorial before
            if tutorial.hasCompleted and tutorial.isOnTutorial then
                local completed = tutorial.hasCompleted(playerId)
                local onTutorial = tutorial.isOnTutorial(playerId)
                if not completed and not onTutorial then
                    tutorial.startTutorial(playerId)
                    print(string.format("[IntegrationManager] Started tutorial for new player %s",
                        playerName))
                end
            else
                -- If we can't check, start it — TutorialSystem handles its own
                -- deduplication via D1 persistence
                if tutorial.startTutorial then
                    tutorial.startTutorial(playerId)
                end
            end
        end)
    end

    -- ── Initialize vessel state ──
    -- VesselIntegration.lua already handles player state init via its own
    -- PlayerAdded connection (sets state to IN_YARD). We just ensure the
    -- economy wallet is ready for vessel transactions.

    -- ── Broadcast: player ready ──
    local ev = IntegrationManager._bindables.OnPlayerReady
    if ev then
        ev:Fire(player)
    end

    print(string.format("[IntegrationManager] Player join sequence complete: %s", playerName))
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- INTEGRATION POINT 6: PLAYER LEAVE
-- ═══════════════════════════════════════════════════════════════
-- When a player leaves:
--   → SaveSystem.syncToCloud (persist builds + state)
--   → BondSystem.saveBond (persist bond tier)
--   → Fire OnPlayerDeparting bindable
-- ═══════════════════════════════════════════════════════════════

--[[
    Hook: Called when a player leaves the server.
    Orchestrates the full leave sequence: save builds, persist bond,
    sync economy wallet, save era progression.

    @param player Player
]]
function IntegrationManager.onPlayerLeave(player)
    local playerName = player.Name
    local playerId = tostring(player.UserId)

    -- ── Broadcast: player departing (before save, so listeners can react) ──
    local departingEv = IntegrationManager._bindables.OnPlayerDeparting
    if departingEv then
        departingEv:Fire(player)
    end

    -- ── SaveSystem: sync to cloud ──
    local save = IntegrationManager._modules.SaveSystem
    if save then
        -- Full save (builds → R2, profile → D1)
        safeCall("SaveSystem.syncToCloud", function()
            save.syncToCloud(player)
        end)

        -- Save era progression
        safeCall("SaveSystem.saveEra", function()
            if save.saveEra then
                save.saveEra(player)
            end
        end)

        -- Save player profile
        safeCall("SaveSystem.savePlayer", function()
            if save.savePlayer then
                save.savePlayer(playerName)
            end
        end)
    end

    -- ── BondSystem: save bond ──
    -- BondSystem.init() hooks PlayerRemoving for persistence, but we
    -- also trigger a manual save for safety.
    local bond = IntegrationManager._modules.BondSystem
    if bond then
        safeCall("BondSystem (leave)", function()
            -- BondSystem persists via persistBond() internally on PlayerRemoving.
            -- We ensure it fires by calling addXP with 0 (which triggers persist).
            -- Actually that's wasteful — BondSystem already saves on leave.
            -- Just log the bond level for debugging.
            if bond.getBondLevel then
                local level = bond.getBondLevel(playerId)
                print(string.format("[IntegrationManager] %s leaving at bond tier %d",
                    playerName, level))
            end
        end)
    end

    -- ── EconomySystem: persist wallet ──
    -- Currency.init() hooks PlayerRemoving for persistence.
    -- No additional action needed, but we log for debugging.
    local currency = getCurrency()
    if currency and currency.getScrap then
        safeCall("Currency (leave log)", function()
            local scrap = currency.getScrap(playerName)
            print(string.format("[IntegrationManager] %s leaving with %d scrap",
                playerName, scrap))
        end)
    end

    -- ── FishingSystem: clean up any active fishing session ──
    local fishing = IntegrationManager._modules.FishingSystem
    if fishing and fishing.stopFishing then
        safeCall("FishingSystem.stopFishing", function()
            fishing.stopFishing(player)
        end)
    end

    print(string.format("[IntegrationManager] Player leave sequence complete: %s", playerName))
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- UTILITY: LUCINEIER DIALOGUE HELPER
-- ═══════════════════════════════════════════════════════════════

--[[
    Fire a Lucineier dialogue line to a player via the ResponseEvent remote.
    Matches the pattern in VesselIntegration._fireLucineerResponse.

    @param player Player
    @param text string -- the dialogue line
]]
function IntegrationManager._fireDialogue(player, text)
    local Lucineer = ReplicatedStorage:FindFirstChild("Lucineer")
    if not Lucineer then return end

    local remote = Lucineer:FindFirstChild("ResponseEvent")
    if not remote then return end

    remote:FireClient(player, {
        type = "dialogue",
        text = text,
        speaker = "Lucineier",
    })
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- PUBLIC API: BINDABLE EVENT ACCESS
-- ═══════════════════════════════════════════════════════════════

--[[
    Get a BindableEvent by name for external systems to listen on.
    @param name string -- one of: OnBuildCompleted, OnFishCaught,
                         OnVesselSpawned, OnEraChanged, OnPlayerReady,
                         OnPlayerDeparting
    @return BindableEvent? -- the event, or nil if not found
]]
function IntegrationManager.getEvent(name)
    return IntegrationManager._bindables[name]
end

--[[
    Connect a callback to a named bindable event.
    Convenience wrapper.

    @param name string -- event name
    @param callback function -- callback(player, ...)
    @return RBXScriptConnection? -- connection, or nil if event not found
]]
function IntegrationManager.on(name, callback)
    local ev = IntegrationManager._bindables[name]
    if not ev then
        warn(string.format("[IntegrationManager] Unknown event: %s", name))
        return nil
    end
    return ev.Event:Connect(callback)
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════

--[[
    Initialize the IntegrationManager.
    Loads modules, creates bindables, and wires player events.

    Call once during server bootstrap, after all other systems are initialized.
]]
function IntegrationManager.init()
    if IntegrationManager._initialized then
        warn("[IntegrationManager] Already initialized.")
        return
    end

    loadModules()
    createBindables()

    -- ── Wire player events ──
    Players.PlayerAdded:Connect(function(player)
        -- Delay slightly to let other systems' PlayerAdded fire first
        -- (BondSystem, Currency, etc. need to initialize their state)
        task.defer(function()
            IntegrationManager.onPlayerJoin(player)
        end)
    end)

    Players.PlayerRemoving:Connect(function(player)
        IntegrationManager.onPlayerLeave(player)
    end)

    -- ── Handle existing players (Studio playtest support) ──
    for _, player in ipairs(Players:GetPlayers()) do
        task.defer(function()
            IntegrationManager.onPlayerJoin(player)
        end)
    end

    IntegrationManager._initialized = true
    print("[IntegrationManager] Initialized — 6 integration points wired:")
    print("  1. Build completion  → BondSystem + EconomySystem.BuildCosts")
    print("  2. Fishing catch     → EconomySystem.Currency + AchievementManager")
    print("  3. Vessel spawn      → CrewSystem + VesselSystem.VesselSpawner")
    print("  4. Era change        → EraGates + WeatherSystem + WorldGenerator")
    print("  5. Player join       → SaveSystem.loadFromCloud + BondSystem + TutorialSystem")
    print("  6. Player leave      → SaveSystem.syncToCloud + BondSystem")
end

----------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════
-- RETURN
-- ═══════════════════════════════════════════════════════════════

return IntegrationManager
