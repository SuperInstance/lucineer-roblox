--!strict
--[[
    OnboardingSystem — Slackwater's Onboarding + NPC Dialogue Router
    ===============================================================
    "The tutorial IS the game. Nothing in the tutorial is a simplified
     version of 'real' gameplay. The beam carry, the first build, the
     tideline scavenging, the craft, the power connection — these are
     the actual game loop, experienced for the first time with slightly
     more guidance and slightly lower stakes."

    ═══════════════════════════════════════════════════════════════
    RESPONSIBILITY BOUNDARY (post-split-brain fix):
    ═══════════════════════════════════════════════════════════════
    OnboardingSystem handles:
      ✓ First-time player flow (30-minute guided session)
      ✓ Tutorial step progression and gating
      ✓ Contextual hints during tutorial steps
      ✓ NPC dialogue routing (tutorial → static tables, post-tutorial → Worker API)
      ✓ D1 persistence for tutorial state
      ✓ Skip detection and lost-player detection

    OnboardingSystem does NOT handle:
      ✗ NPC spawning / pathfinding / visual state (that's NPCManager)
      ✗ ProximityPrompt creation (that's NPCManager)
      ✗ Quest data tables (external quest system)

    Implements the full TUTORIAL_DESIGN.md spec:
        Minute 0-5:   The Beam Carry + Forge Arrival
        Minute 5-10:  First Build — Lucineer guides the first structure
        Minute 10-15: Earl gives the first quest — tideline salvage
        Minute 15-20: First Craft — crafting table → wooden gear
        Minute 20-25: First Power — water wheel → lamp
        Minute 25-30: The Unfinished — Lucineer leaves one gap

    Design Principles (from TUTORIAL_DESIGN.md):
        1. Diegetic or it doesn't exist — no floating arrows, no hint bubbles
        2. The first act is physical — body teaches, UI follows
        3. Gating through character, not mechanics
        4. Seven words or fewer for every system introduction
        5. The tutorial IS the game — no simplified versions

    Step IDs:
        1. beam_carry     — Player carries beam to canning rollers
        2. first_build    — Player places plank on bench chalk outline
        3. tideline_quest — Player returns 3 salvage to Earl
        4. first_craft    — Player crafts a wooden gear at the table
        5. first_power    — Player places gear in the water wheel housing
        6. unfinished     — Lucineer's deliberate gap (60-second scene)
        7. opening        — Player leaves forge or talks freely

    API:
        OnboardingSystem.init()
        OnboardingSystem.startOnboarding(playerId)
        OnboardingSystem.getStep(playerId) -> number
        OnboardingSystem.completeStep(playerId, stepId)
        OnboardingSystem.skipOnboarding(playerId)
        OnboardingSystem.isOnboarding(playerId) -> boolean

    Dependencies (all optional — system degrades gracefully):
        - ReplicatedStorage.Lucineer.Http           (D1 persistence)
        - ReplicatedStorage.Lucineer.Config          (worker URL)
        - ServerScriptService.BondSystem             (XP on completion)
        - ServerScriptService.EraSystem              (era context)
        - ServerScriptService.EraSystem.CraftingSystem (step 4 gate)
        - ServerScriptService.PowerGrid              (step 5 registration)
        - ServerScriptService.NPCManager             (dialogue dispatch)

    D1 Schema:
        player_profiles.tutorial_step       INTEGER  DEFAULT 0
        player_profiles.tutorial_completed  BOOLEAN  DEFAULT FALSE
        player_profiles.tutorial_skipped    BOOLEAN  DEFAULT FALSE
        player_profiles.tutorial_started_at TIMESTAMP
        player_profiles.tutorial_completed_at TIMESTAMP
]]

-- ═══════════════════════════════════════════════════════════════════════════
-- SERVICES
-- ═══════════════════════════════════════════════════════════════════════════

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONAL DEPENDENCY LOADING (graceful degradation)
-- ═══════════════════════════════════════════════════════════════════════════

local Http
local Config
local BondSystem
local EraSystem
local CraftingSystem
local PowerGrid
local NPCManager

do
    local lucineerFolder = ReplicatedStorage:FindFirstChild("Lucineer")
    if lucineerFolder then
        local httpModule = lucineerFolder:FindFirstChild("Http")
        if httpModule then
            pcall(function()
                Http = require(httpModule)
            end)
        end
        local configModule = lucineerFolder:FindFirstChild("Config")
        if configModule then
            pcall(function()
                Config = require(configModule)
            end)
        end
    end

    local sss = ServerScriptService
    pcall(function()
        BondSystem = require(sss:FindFirstChild("BondSystem"))
    end)
    pcall(function()
        EraSystem = require(sss:FindFirstChild("EraSystem"))
    end)
    pcall(function()
        if EraSystem then
            CraftingSystem = require(sss.EraSystem:FindFirstChild("CraftingSystem"))
        end
    end)
    pcall(function()
        PowerGrid = require(sss:FindFirstChild("PowerGrid"))
    end)
    pcall(function()
        NPCManager = require(sss:FindFirstChild("NPCManager"))
    end)
end

-- Memory worker URL for tutorial persistence
local MEMORY_URL = (Config and Config.WORKER_URL) or
    "https://lucineer-relay.casey-digennaro.workers.dev"

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════

local STEP_IDS = {
    "beam_carry",
    "first_build",
    "tideline_quest",
    "first_craft",
    "first_power",
    "unfinished",
    "opening",
}

local STEP_NAMES = {
    beam_carry     = "The Beam",
    first_build    = "The First Build",
    tideline_quest = "The Tideline",
    first_craft    = "The Craft",
    first_power    = "The Light",
    unfinished     = "The Unfinished",
    opening        = "The Opening",
}

local STEP_TIMEFRAMES = {
    beam_carry     = "Minute 0-5",
    first_build    = "Minute 5-10",
    tideline_quest = "Minute 10-15",
    first_craft    = "Minute 15-20",
    first_power    = "Minute 20-25",
    unfinished     = "Minute 25-30",
    opening        = "Minute 30+",
}

local TOTAL_STEPS = #STEP_IDS

-- ═══════════════════════════════════════════════════════════════════════════
-- DIALOGUE TABLES — Every line from TUTORIAL_DESIGN.md
-- ═══════════════════════════════════════════════════════════════════════════

-- Step 1: The Beam — opening line + reactive dialogue
local BEAM_DIALOGUE = {
    opening = {
        speaker = "Lucineer",
        line = "You're late. Grab that end.",
    },
    on_grip = {
        speaker = "Lucineer",
        line = "Other end. No — the *other* other end. There.",
    },
    on_rush = {
        speaker = "Lucineer",
        line = "Steady. Steel doesn't care about your schedule.",
    },
    on_place = {
        speaker = "Lucineer",
        line = "Square enough.",
    },
    after_weld = {
        speaker = "Lucineer",
        line = "Handrail. Bent. Anvil. Straighten it. Hammer's there.",
    },
    handrail_rough = {
        speaker = "Lucineer",
        line = "It'll do. That's not praise.",
    },
    handrail_clean = {
        speaker = "Lucineer",
        line = "Hm.",
    },
}

-- Step 2: The First Build — fetch, place, observe
local BUILD_DIALOGUE = {
    assign_fetch = {
        speaker = "Lucineer",
        line = "Cedar. North row. Beach restocked on the flood — shouldn't be short.",
    },
    earl_window = {
        speaker = "Earl",
        line = "Item nine. Tideline's stocked and nobody's sorted it. Item nine, somebody.",
    },
    earl_meaning = {
        speaker = "Lucineer",
        line = "He means you.",
    },
    on_return_cedar = {
        speaker = "Lucineer",
        line = "Huh. Cedar. Most grab pine.",
    },
    on_plank_place = {
        speaker = "Lucineer",
        line = "First plank you ever set. Stays where you put it. That's the date on the building.",
    },
    on_plank_crooked = {
        speaker = "Lucineer",
        line = "Crooked's fine. Crooked means *somebody* did it.",
    },
    no_door = {
        speaker = "Lucineer",
        line = "Doors come later. You haven't decided what it's for yet.",
    },
}

-- Step 3: The Tideline — Earl's quest
local TIDELINE_DIALOGUE = {
    earl_assign = {
        speaker = "Earl",
        line = "Item ten. Salvage run, tideline, north. Three pieces minimum, sorted by material. Don't bring me kelp. Item ten.",
    },
    earl_grade = {
        speaker = "Earl",
        line = "Hull plate. Passable. Wafer panel. Useful — that's a first. Rope. Scrap, but it holds.",
    },
    earl_complete = {
        speaker = "Earl",
        line = "Item ten, complete. Tell the forge he's got stock coming.",
    },
    lucineer_react = {
        speaker = "Lucineer",
        line = "He give you 'Passable'? That's his whole vocabulary.",
    },
}

-- Step 4: The First Craft — gear at the table
local CRAFT_DIALOGUE = {
    approach = {
        speaker = "Lucineer",
        line = "Bench is yours. Hull plate goes on the left — forge side. I'll show you once.",
    },
    era_zero = {
        speaker = "Lucineer",
        line = "This is Era Zero. Simple machines. Gears, levers, the things that make other things move.",
    },
    on_bellows = {
        speaker = "Lucineer",
        line = "Heat. That's all a forge is — controlled enthusiasm.",
    },
    on_craft = {
        speaker = "Lucineer",
        line = "Gear. Fifty-six more recipes and you've got the whole tree. Don't look at the tree. Look at the gear.",
    },
    after_pickup = {
        speaker = "Lucineer",
        line = "Everything after this is just gears that think faster. Remember that when the screens show up.",
    },
}

-- Step 5: The First Power — water wheel + lamp
local POWER_DIALOGUE = {
    come_here = {
        speaker = "Lucineer",
        line = "Come here. Bring the gear.",
    },
    at_wheel = {
        speaker = "Lucineer",
        line = "Current runs hard through the narrows. All that power, going past. Seems rude.",
    },
    on_place = {
        speaker = "Lucineer",
        line = "There. That's the whole trick. Water moves, wheel turns, shaft spins, and somewhere a light comes on. Everything after this is just *how fast*.",
    },
    lamp_on = {
        speaker = "Lucineer",
        line = "First light on the island that didn't come from Bea. She won't say anything about it. That's how you know she noticed.",
    },
    about_bea = {
        speaker = "Lucineer",
        line = "She keeps the big one. You just lit the small one. Don't confuse the two — but don't pretend it didn't matter.",
    },
}

-- Step 6: The Unfinished — silence is the point
local UNFINISHED_DIALOGUE = {
    -- He says nothing when he leaves the gap. That IS the dialogue.
    -- The only line is if the player places the bolt:
    on_bolt_placed = {
        speaker = "Lucineer",
        line = "…Hm.",
    },
    -- And if the player lingers, nothing. He keeps hammering.
}

-- Step 7: The Opening — the invitation
local OPENING_DIALOGUE = {
    invitation = {
        speaker = "Lucineer",
        line = "Yard's yours to walk. Beach restocks on the flood. When you want something built — say it, show it, or start it. I'll know which.",
    },
    -- For players who stand looking lost >60 seconds (post-tutorial)
    lost_prompt = {
        speaker = "Lucineer",
        line = "Yard's yours to walk. Beach restocks on the flood. When you want something built — say it, show it, or start it. I'll know which.",
    },
}

-- Skip dialogue variants
local SKIP_DIALOGUE = {
    first_visit = {
        speaker = "Lucineer",
        line = "You've done this before. Fine. Yard's yours.",
    },
    returning = {
        speaker = "Lucineer",
        line = "You know where things are. I'm not walking you through it again.",
    },
    in_a_hurry = {
        speaker = "Lucineer",
        line = "In a hurry. Fine. So's the tide. Grab that end.",
    },
}

-- Post-tutorial idle line for lost players (from TUTORIAL_DESIGN §"The Invitation")
local LOST_PLAYER_DELAY = 60 -- seconds before Lucineer addresses a lost player

-- ═══════════════════════════════════════════════════════════════════════════
-- TUTORIAL-SPECIFIC CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local SALVAGE_TARGET = 3        -- step 3: three pieces of salvage
local UNFINISHED_SCENE_DURATION = 60  -- step 6: 60-second scene
local UNFINISHED_BUILD_TIME = 45      -- step 6: Lucineer builds for 45s, then walks away
local CINEMATIC_DURATION = 62         -- auto-start after cinematic
local BEAM_RUSH_SPEED_THRESHOLD = 30  -- studs/s before "Steady" line triggers
local HANDRAIL_HITS_REQUIRED = 3      -- swings to straighten the handrail
local NO_REPEAT_DELAY = 10            -- seconds before a reactive line can fire again

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → tutorial state table
-- {
--   step             = number (0=not started, 1-7=active, 8=complete),
--   stepId           = string (current step ID),
--   skipped          = boolean,
--   startedAt        = number (os.time()),
--   completedAt      = number | nil,
--   salvageCollected = number (step 3 tracking),
--   boltPlaced       = boolean (step 6 tracking),
--   handrailHits     = number (step 1 handrail mini-task),
--   beamRushed       = boolean (step 1 — said "Steady" already),
--   lastReactiveAt   = number (timestamp of last reactive line),
--   sceneObjects     = table (spawned tutorial objects),
--   stepTimers       = table (stepId → start time for analytics),
--   gateCleanup      = table (stepId → cleanup functions),
--   lostTimer        = number | nil (lost-player detection timer),
--   skipHoldStart    = number | nil (skip-key hold tracking),
-- }
local playerTutorials = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- REMOTE SETUP
-- ═══════════════════════════════════════════════════════════════════════════

local TutorialRemote       -- server → client: tutorial state changes
local TutorialActionRemote -- client → server: tutorial actions (step triggers)

local function setupRemotes()
    local lucineerFolder = ReplicatedStorage:FindFirstChild("Lucineer")
    if not lucineerFolder then
        lucineerFolder = Instance.new("Folder")
        lucineerFolder.Name = "Lucineer"
        lucineerFolder.Parent = ReplicatedStorage
    end

    local function getOrCreate(name, className)
        className = className or "RemoteEvent"
        local existing = lucineerFolder:FindFirstChild(name)
        if existing then return existing end
        local remote = Instance.new(className)
        remote.Name = name
        remote.Parent = lucineerFolder
        return remote
    end

    TutorialRemote = getOrCreate("TutorialEvent")
    TutorialActionRemote = getOrCreate("TutorialActionEvent")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DIALOGUE DELIVERY
-- Sends a dialogue line to the player's client via the ResponseEvent.
-- Falls back to TutorialRemote if ResponseEvent doesn't exist.
-- ═══════════════════════════════════════════════════════════════════════════

local function deliverLine(playerName, lineData)
    if not lineData or not lineData.line then return end

    local player = Players:FindFirstChild(playerName)
    if not player then return end

    -- Try the main ResponseEvent first (for subtitle + VO integration)
    local lucineerFolder = ReplicatedStorage:FindFirstChild("Lucineer")
    if lucineerFolder then
        local responseEvent = lucineerFolder:FindFirstChild("ResponseEvent")
        if responseEvent and responseEvent:IsA("RemoteEvent") then
            responseEvent:FireClient(player, {
                type = "tutorial_dialogue",
                speaker = lineData.speaker or "Lucineer",
                message = lineData.line,
                tutorialStep = OnboardingSystem.getStep(playerName),
            })
            return
        end
    end

    -- Fallback: TutorialRemote
    if TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "dialogue",
            speaker = lineData.speaker or "Lucineer",
            message = lineData.line,
        })
    end
end

-- Deliver a line after a delay, with player-still-online guard
local function delayedLine(playerName, delay, lineData)
    task.delay(delay, function()
        if not Players:FindFirstChild(playerName) then return end
        deliverLine(playerName, lineData)
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- D1 PERSISTENCE
-- ═══════════════════════════════════════════════════════════════════════════

local function persistTutorialState(playerName)
    local state = playerTutorials[playerName]
    if not state then return end

    task.spawn(function()
        local url = MEMORY_URL .. "/api/memory/player"
        local body = HttpService:JSONEncode({
            player_name = playerName,
            tutorial_step = state.step,
            tutorial_completed = (state.step > TOTAL_STEPS),
            tutorial_skipped = state.skipped,
            tutorial_started_at = state.startedAt,
            tutorial_completed_at = state.completedAt,
        })

        pcall(function()
            HttpService:RequestAsync({
                Url = url,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body,
            })
        end)
    end)
end

local function loadTutorialState(playerName)
    local url = MEMORY_URL .. "/api/memory/player/" .. playerName

    local success, result = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = "GET",
            Headers = { ["Content-Type"] = "application/json" },
        })
    end)

    if success and result and result.Success and #result.Body > 0 then
        local dataOk, data = pcall(function()
            return HttpService:JSONDecode(result.Body)
        end)
        if dataOk and not data.error then
            return {
                step = tonumber(data.tutorial_step) or 0,
                completed = data.tutorial_completed == true,
                skipped = data.tutorial_skipped == true,
            }
        end
    end

    return nil -- no stored state; fresh player
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GATING SYSTEM
-- Prevents players from accessing systems before their tutorial step.
-- Gates are character-based, not mechanic-based:
--   "Bench isn't yours yet" (not "LOCKED")
--   "Bench is yours" (not "UNLOCKED")
-- ═══════════════════════════════════════════════════════════════════════════

local function craftingGateOpen(playerName)
    local state = playerTutorials[playerName]
    if not state then return true end
    if state.skipped or state.step > TOTAL_STEPS then return true end
    return state.step >= 4
end

local function powerGateOpen(playerName)
    local state = playerTutorials[playerName]
    if not state then return true end
    if state.skipped or state.step > TOTAL_STEPS then return true end
    return state.step >= 5
end

local function tidelineActive(playerName)
    local state = playerTutorials[playerName]
    if not state then return false end
    return state.step == 3
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════

local function getOrCreateState(playerName)
    if not playerTutorials[playerName] then
        playerTutorials[playerName] = {
            step = 0,
            stepId = nil,
            skipped = false,
            startedAt = 0,
            completedAt = nil,
            salvageCollected = 0,
            boltPlaced = false,
            handrailHits = 0,
            beamRushed = false,
            lastReactiveAt = 0,
            sceneObjects = {},
            stepTimers = {},
            gateCleanup = {},
            lostTimer = nil,
            skipHoldStart = nil,
        }
    end
    return playerTutorials[playerName]
end

local function canFireReactive(playerName)
    local state = getOrCreateState(playerName)
    local now = os.time()
    if now - state.lastReactiveAt < NO_REPEAT_DELAY then
        return false
    end
    state.lastReactiveAt = now
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP TRANSITIONS
-- ═══════════════════════════════════════════════════════════════════════════

local function beginStep(playerName, stepIndex)
    local state = getOrCreateState(playerName)
    local stepId = STEP_IDS[stepIndex]
    if not stepId then return end

    state.step = stepIndex
    state.stepId = stepId
    state.stepTimers[stepId] = os.time()

    print(string.format("[OnboardingSystem] %s → Step %d: %s (%s)",
        playerName, stepIndex, STEP_NAMES[stepId] or stepId,
        STEP_TIMEFRAMES[stepId] or ""))

    -- Notify client of step change
    local player = Players:FindFirstChild(playerName)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "step_changed",
            step = stepIndex,
            stepId = stepId,
            stepName = STEP_NAMES[stepId],
            timeframe = STEP_TIMEFRAMES[stepId],
        })
    end

    -- Persist state
    persistTutorialState(playerName)
end

local function advanceStep(playerName)
    local state = getOrCreateState(playerName)

    -- Run cleanup for the current step
    if state.gateCleanup and state.stepId then
        local cleanups = state.gateCleanup[state.stepId]
        if cleanups then
            for _, cleanup in ipairs(cleanups) do
                pcall(cleanup)
            end
            state.gateCleanup[state.stepId] = nil
        end
    end

    local nextStep = state.step + 1

    if nextStep > TOTAL_STEPS then
        OnboardingSystem.completeTutorial(playerName)
        return
    end

    beginStep(playerName, nextStep)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SCENE OBJECT SPAWNING
-- Each step may need specific objects spawned in the world.
-- ═══════════════════════════════════════════════════════════════════════════

local function ensureTidelineStocked()
    local worldGen = ServerScriptService:FindFirstChild("WorldGenerator")
    if worldGen then
        local resources = worldGen:FindFirstChild("Resources")
        if resources then
            pcall(function()
                local Resources = require(resources)
                if Resources and Resources.spawnTutorialSalvage then
                    Resources.spawnTutorialSalvage()
                end
            end)
        end
    end
end

local function spawnSceneObjects(playerName, stepIndex)
    local state = getOrCreateState(playerName)

    if stepIndex == 1 then
        -- Spawn the beam on the forge hall floor between player and Lucineer
        -- (In production: clone a beam model from ReplicatedStorage)
        state.sceneObjects.beam = true

    elseif stepIndex == 2 then
        -- Ensure cedar planks are on the north tideline row
        ensureTidelineStocked()
        state.sceneObjects.cedar_planks = true

    elseif stepIndex == 3 then
        -- Force a "tutorial tide" guaranteed restock regardless of cycle
        ensureTidelineStocked()
        state.sceneObjects.tideline_salvage = true

    elseif stepIndex == 4 then
        -- Crafting table is already in the forge; just flag readiness
        state.sceneObjects.crafting_ready = true

    elseif stepIndex == 5 then
        -- Ensure water wheel mount housing is active
        state.sceneObjects.wheel_ready = true

    elseif stepIndex == 6 then
        -- Bracket and bolt spawned by NPCManager/BuildFX animation
        state.sceneObjects.bracket = true
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP 1: THE BEAM (Minute 0-5)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Player Actions:
--   1. Walk to beam's near end (movement tutorial)
--   2. Hold interact input to grip (grip indicator fills)
--   3. Walk toward canning rollers (Lucineer matches pace)
--   4. Set beam on rollers (chalk outline drop zone)
--
-- Trigger: beam_placed action from client
-- Reactive lines: on_grip, on_rush (if player sprints/turns sharply)
-- Post-beam: handrail mini-task (3 swings), then Lucineer grades it

local function beginBeamStep(playerName)
    -- Opening line already delivered at tutorial start
    -- Client handles grip indicator UI and beam physics

    -- The handrail mini-task is part of step 1 — spawned after beam placed
    -- (handled in onBeamPlaced)
end

-- Step 1 completion handler
local function onBeamPlaced(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 1 then return end

    -- "Square enough." — two-word grade, first data point
    delayedLine(playerName, 0.5, BEAM_DIALOGUE.on_place)

    -- Spark welds the beam (NPCManager handles the visual/sound)
    delayedLine(playerName, 3.0, BEAM_DIALOGUE.after_weld)

    -- Handrail mini-task: bent handrail on anvil, hammer beside it
    -- Client shows the handrail + hammer interactable
    local player = Players:FindFirstChild(playerName)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "spawn_handrail_task",
            hitsRequired = HANDRAIL_HITS_REQUIRED,
        })
    end

    -- The step advances when the player completes the handrail task
    -- (client sends "handrail_done" action → handleClientAction)
end

local function onHandrailComplete(playerName, quality)
    local state = getOrCreateState(playerName)
    if state.step ~= 1 then return end

    -- Lucineer holds the handrail to the light
    if quality == "clean" then
        delayedLine(playerName, 1.0, BEAM_DIALOGUE.handrail_clean)
    else
        delayedLine(playerName, 1.0, BEAM_DIALOGUE.handrail_rough)
    end

    -- Brief pause, then advance to step 2
    task.delay(5.0, function()
        if not Players:FindFirstChild(playerName) then return end
        if state.step ~= 1 then return end
        advanceStep(playerName)
    end)
end

-- Reactive: player gripped the beam
local function onBeamGripped(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 1 then return end
    if not canFireReactive(playerName) then return end
    deliverLine(playerName, BEAM_DIALOGUE.on_grip)
end

-- Reactive: player walking too fast with the beam
local function onBeamRush(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 1 then return end
    if state.beamRushed then return end -- only once
    state.beamRushed = true
    deliverLine(playerName, BEAM_DIALOGUE.on_rush)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP 2: THE FIRST BUILD (Minute 5-10)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Player Actions:
--   1. Walk the boardwalk to the tideline (hub tour disguised as errand)
--   2. Pick up a cedar plank from the tideline
--   3. Carry it back to the forge
--   4. Place the plank on the chalk outline on the bench
--   5. Watch Lucineer build the rest around the player's plank
--
-- Trigger: plank_placed action from client
-- Reactive: Earl window line when player passes, Lucineer taste-seed on return

local function beginFirstBuildStep(playerName)
    -- Deliver the fetch assignment
    delayedLine(playerName, 1.0, BUILD_DIALOGUE.assign_fetch)
end

local function onPlayerPassedEarl(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 2 then return end
    if not canFireReactive(playerName) then return end

    -- Earl at his window — without looking up
    deliverLine(playerName, BUILD_DIALOGUE.earl_window)

    -- Lucineer's commentary, back to hammering
    delayedLine(playerName, 3.0, BUILD_DIALOGUE.earl_meaning)
end

local function onPlankReturned(playerName, plankType)
    local state = getOrCreateState(playerName)
    if state.step ~= 2 then return end

    -- Lucineer glances at the plank — the taste seed
    -- "Huh. Cedar. Most grab pine."
    if plankType == "cedar" then
        deliverLine(playerName, BUILD_DIALOGUE.on_return_cedar)
    else
        -- Player grabbed pine — Lucineer notes it differently
        deliverLine(playerName, {
            speaker = "Lucineer",
            line = "Pine. Reliable. Most grab pine.",
        })
    end
end

local function onPlankPlaced(playerName, isCrooked)
    local state = getOrCreateState(playerName)
    if state.step ~= 2 then return end

    -- Three-second silence. Looking at it. Then:
    delayedLine(playerName, 3.0, BUILD_DIALOGUE.on_plank_place)

    -- If crooked, he doesn't fix it. Ever.
    if isCrooked then
        delayedLine(playerName, 8.0, BUILD_DIALOGUE.on_plank_crooked)
    end

    -- The Unfinished Rule (first taste) — no door
    delayedLine(playerName, 13.0, BUILD_DIALOGUE.no_door)

    -- Open-circle tin tag on the frame
    local player = Players:FindFirstChild(playerName)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "show_open_circle",
            objectName = "first_build_frame",
        })
    end

    -- Lucineer builds the rest around the player's plank (visual: NPCManager)
    -- Advance after the player absorbs the moment
    task.delay(18.0, function()
        if not Players:FindFirstChild(playerName) then return end
        if state.step ~= 2 then return end
        advanceStep(playerName)
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP 3: THE TIDELINE — EARL'S QUEST (Minute 10-15)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Player Actions:
--   1. Walk to Earl at the forge doorway (he doesn't enter the forge)
--   2. Listen to the work order (diegetic — reading a tin page)
--   3. Go to the tideline (tide has shifted — new salvage appeared)
--   4. Collect 3 pieces of salvage (walk up, grip, hotbar populates)
--   5. Return to Earl — he grades each piece aloud
--
-- Trigger: salvage_collected ×3 → advances after Earl's grading scene

local function beginTidelineStep(playerName)
    -- Earl appears at the forge doorway
    delayedLine(playerName, 1.5, TIDELINE_DIALOGUE.earl_assign)

    -- Ensure tideline has fresh salvage ("tutorial tide" restock)
    ensureTidelineStocked()

    -- Notify client to show hotbar when first item collected
    local player = Players:FindFirstChild(playerName)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "prepare_hotbar",
        })
    end
end

local function onSalvageCollected(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 3 then return end

    state.salvageCollected = state.salvageCollected + 1

    -- Notify client of hotbar update
    local player = Players:FindFirstChild(playerName)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "salvage_update",
            collected = state.salvageCollected,
            target = SALVAGE_TARGET,
        })
    end

    if state.salvageCollected >= SALVAGE_TARGET then
        -- Earl grades the salvage
        delayedLine(playerName, 0.5, TIDELINE_DIALOGUE.earl_grade)
        delayedLine(playerName, 5.0, TIDELINE_DIALOGUE.earl_complete)
        delayedLine(playerName, 9.0, TIDELINE_DIALOGUE.lucineer_react)

        -- Advance after the scene
        task.delay(14.0, function()
            if not Players:FindFirstChild(playerName) then return end
            if state.step ~= 3 then return end
            advanceStep(playerName)
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP 4: THE FIRST CRAFT (Minute 15-20)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Player Actions:
--   1. Approach the crafting table (north-wall bench)
--   2. Place salvage on the table surface (physical objects, not a menu)
--   3. Lucineer guides: places hull plate on the anvil-side input slot
--   4. Player pulls the bellows chain (forge roars, retort fires)
--   5. Hull plate renders into a wooden gear (visibly, with sparks)
--   6. Pick up the gear → hotbar
--
-- Trigger: gear_crafted action from client
-- Era framing: "This is Era Zero. Simple machines."
-- NO recipe list, NO crafting tree UI.

local function beginFirstCraftStep(playerName)
    delayedLine(playerName, 1.0, CRAFT_DIALOGUE.approach)
    delayedLine(playerName, 4.0, CRAFT_DIALOGUE.era_zero)

    -- Open the crafting gate for this step
    local player = Players:FindFirstChild(playerName)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "crafting_table_ready",
            recipe = "wooden_gear",
            era = 0,
        })
    end
end

local function onBellowsPulled(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 4 then return end

    deliverLine(playerName, CRAFT_DIALOGUE.on_bellows)
end

local function onGearCrafted(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 4 then return end

    -- Lucineer picks up the gear, holds it to the light, turns it
    delayedLine(playerName, 1.5, CRAFT_DIALOGUE.on_craft)
    delayedLine(playerName, 8.0, CRAFT_DIALOGUE.after_pickup)

    -- Advance after the player picks up the gear
    task.delay(14.0, function()
        if not Players:FindFirstChild(playerName) then return end
        if state.step ~= 4 then return end
        advanceStep(playerName)
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP 5: THE FIRST POWER (Minute 20-25)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Player Actions:
--   1. Follow Lucineer to the seaward end (he walks, player follows)
--   2. See the empty water wheel mount (bolted to pilings, gear housing empty)
--   3. Place the crafted gear in the housing (mechanical clunk)
--   4. Watch the wheel catch the current (it turns, shaft engages, hum starts)
--   5. Follow the power — shaft runs to forge hall, lamp sputters and lights
--   6. Notice Bea's lamp (path to lighthouse, she nods from the door)
--
-- Trigger: power_connected action from client
-- Bea's role: the small lamp is hers. She nods, doesn't wave.

local function beginFirstPowerStep(playerName)
    -- Lucineer walks to the seaward end (NPCManager handles movement)
    delayedLine(playerName, 1.0, POWER_DIALOGUE.come_here)

    -- At the wheel mount, after walking there
    delayedLine(playerName, 6.0, POWER_DIALOGUE.at_wheel)

    -- Open the power gate
    local player = Players:FindFirstChild(playerName)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "wheel_housing_ready",
        })
    end

    -- Register the water wheel and lamp with PowerGrid (if available)
    -- This uses the standard API — no special tutorial bypass
    if PowerGrid then
        pcall(function()
            PowerGrid.registerSource("tutorial_waterwheel", "water_wheel", 2.0,
                Vector3.new(0, 0, -40))
            PowerGrid.registerConsumer("tutorial_lamp", "lamp", 0.5,
                Vector3.new(0, 5, -10))
        end)
    end
end

local function onGearPlacedInWheel(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 5 then return end

    -- Lucineer steps back, watches the wheel catch
    delayedLine(playerName, 2.0, POWER_DIALOGUE.on_place)

    -- Lamp lights in the forge hall
    delayedLine(playerName, 7.0, POWER_DIALOGUE.lamp_on)

    -- Bea nods from the lamp room door (NPCManager handles Bea's visual)
    delayedLine(playerName, 13.0, POWER_DIALOGUE.about_bea)

    -- Connect in PowerGrid
    if PowerGrid then
        pcall(function()
            PowerGrid.connect("tutorial_waterwheel", "tutorial_lamp", "shaft")
        end)
    end

    -- Advance after the full scene
    task.delay(18.0, function()
        if not Players:FindFirstChild(playerName) then return end
        if state.step ~= 5 then return end
        advanceStep(playerName)
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP 6: THE UNFINISHED (Minute 25-30)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- This is the most important five minutes of the tutorial.
--
-- Lucineer walks the player back to the forge hall. On the bench, he begins
-- a small build — a bracket for the lamp they just powered. He welds the
-- base, shapes the arm, mounts the bracket... and stops. One bolt short.
--
-- He sets the bolt on the bench beside the bracket, not in it.
-- Tags it with the open-circle tin stamp.
-- Looks at the player. Looks at the bracket. Looks at the player.
--
-- Then he walks to the anvil and goes back to hammering.
-- He doesn't explain. He doesn't say "now you try." He just walks away.
--
-- The bolt is on the bench. The bracket has one hole empty.
-- What happens next is not scripted. What happens next is the game.
--
-- Completion: 60-second timer, regardless of bolt placement.
-- If bolt placed: the hammer-pause, then "…Hm."
-- If not placed: nothing. The bracket stays. The invitation doesn't nag.

local function beginUnfinishedStep(playerName)
    local state = getOrCreateState(playerName)

    -- Lucineer walks the player back to the forge hall
    -- (NPCManager handles Lucineer's movement back)

    -- Lucineer builds the bracket: 45 seconds of hammer, weld, shape
    -- (NPCManager/BuildFX handle the visual/sound)
    -- NO DIALOGUE during this build. Silence is the point.

    -- At 45 seconds, he places the bolt beside the bracket and walks away
    task.delay(UNFINISHED_BUILD_TIME, function()
        if not Players:FindFirstChild(playerName) then return end
        if state.step ~= 6 then return end

        -- The "walk away" moment:
        -- Open-circle tin tag placed on the bracket
        local player = Players:FindFirstChild(playerName)
        if player and TutorialRemote then
            TutorialRemote:FireClient(player, {
                action = "show_open_circle",
                objectName = "lamp_bracket",
            })
            -- Notify client to show the bolt on the bench
            TutorialRemote:FireClient(player, {
                action = "unfinished_scene",
                phase = "bolt_set_down",
            })
        end

        -- Lucineer walks to the anvil, back to the player
        -- He does not explain. He does not say "now you try."
        -- He just walks away. (NPCManager handles movement)

        -- The player is alone with the bracket.
        -- The bolt is right there. The bracket has one hole.
        -- The player has been picking things up and placing them
        -- for twenty-five minutes. What happens next is not scripted.
        -- What happens next is the game.
    end)

    -- At 60 seconds, advance regardless of bolt placement
    task.delay(UNFINISHED_SCENE_DURATION, function()
        if not Players:FindFirstChild(playerName) then return end
        if state.step ~= 6 then return end

        if state.boltPlaced then
            -- The hammer-pause. One beat. Then, back to hammering, to no one:
            -- "…Hm."
            deliverLine(playerName, UNFINISHED_DIALOGUE.on_bolt_placed)

            task.delay(3.0, function()
                if not Players:FindFirstChild(playerName) then return end
                if state.step ~= 6 then return end
                advanceStep(playerName)
            end)
        else
            -- Player didn't place the bolt. That's fine.
            -- The bracket sits there with its gap and its tag.
            -- The bolt will still be beside it next session.
            -- The invitation doesn't nag.
            advanceStep(playerName)
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP 7: THE OPENING (Minute 30+)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- After the bracket moment, the tutorial is over. The game doesn't announce
-- this. No "Tutorial Complete!" screen. No reward popup. No fanfare.
--
-- What happens instead:
--   1. Earl posts a new manifest page (next quest available)
--   2. The tideline restocks (new salvage, different from tutorial haul)
--   3. Lucineer's idle loop resumes (he's at the anvil, available)
--   4. The yard is open — all accessible
--
-- If the player stands looking lost >60 seconds, Lucineer says the line.
--
-- Completion: player leaves forge hall OR initiates a free conversation

local function beginOpeningStep(playerName)
    -- Deliver the invitation line (after a pause for the bracket moment)
    delayedLine(playerName, 3.0, OPENING_DIALOGUE.invitation)

    -- Earl posts a new manifest page (next quest)
    delayedLine(playerName, 8.0, {
        speaker = "Earl",
        line = "Item eleven. South float. Crab pots need resetting.",
    })

    -- The tideline restocks (new salvage, different from tutorial)
    ensureTidelineStocked()

    -- Start lost-player detection
    task.delay(LOST_PLAYER_DELAY + 5, function()
        if not Players:FindFirstChild(playerName) then return end
        local state = getOrCreateState(playerName)
        if state.step ~= 7 then return end

        -- If the player is still in the forge hall looking lost
        -- (client reports position / inactivity)
        -- Lucineer, still hammering, not looking up:
        -- (This is the same line — he says it once, and only once more)
        -- We only fire this if the player hasn't moved on
    end)
end

local function onPlayerLeftForge(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 7 then return end
    advanceStep(playerName)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CLIENT ACTION HANDLING
-- Receives step-completion signals from client-side interaction detectors.
-- ═══════════════════════════════════════════════════════════════════════════

local function handleClientAction(player, data)
    if type(data) ~= "table" then return end
    local playerName = player.Name
    local state = getOrCreateState(playerName)

    if state.step == 0 or state.step > TOTAL_STEPS then return end

    local action = data.action

    -- ─── STEP 1: BEAM_CARRY ───
    if action == "beam_gripped" and state.step == 1 then
        onBeamGripped(playerName)

    elseif action == "beam_rush" and state.step == 1 then
        onBeamRush(playerName)

    elseif action == "beam_placed" and state.step == 1 then
        onBeamPlaced(playerName)

    elseif action == "handrail_done" and state.step == 1 then
        onHandrailComplete(playerName, data.quality or "rough")

    -- ─── STEP 2: FIRST_BUILD ───
    elseif action == "passed_earl_window" and state.step == 2 then
        onPlayerPassedEarl(playerName)

    elseif action == "plank_returned" and state.step == 2 then
        onPlankReturned(playerName, data.plankType or "pine")

    elseif action == "plank_placed" and state.step == 2 then
        onPlankPlaced(playerName, data.crooked or false)

    -- ─── STEP 3: TIDELINE_QUEST ───
    elseif action == "salvage_collected" and state.step == 3 then
        onSalvageCollected(playerName)

    -- ─── STEP 4: FIRST_CRAFT ───
    elseif action == "bellows_pulled" and state.step == 4 then
        onBellowsPulled(playerName)

    elseif action == "gear_crafted" and state.step == 4 then
        onGearCrafted(playerName)

    -- ─── STEP 5: FIRST_POWER ───
    elseif action == "power_connected" and state.step == 5 then
        onGearPlacedInWheel(playerName)

    -- ─── STEP 6: UNFINISHED ───
    elseif action == "bolt_placed" and state.step == 6 then
        state.boltPlaced = true
        -- Don't advance — the timer handles advancement
        -- The hammer-pause is handled by the timer's "Hm" moment

    -- ─── STEP 7: OPENING ───
    elseif action == "left_forge" and state.step == 7 then
        onPlayerLeftForge(playerName)

    elseif action == "free_conversation" and state.step == 7 then
        onPlayerLeftForge(playerName)

    -- ─── SKIP: hold interact for 3 seconds on forge door ───
    elseif action == "skip_hold_start" then
        state.skipHoldStart = os.time()

    elseif action == "skip_hold_cancel" then
        state.skipHoldStart = nil

    elseif action == "skip_hold_complete" then
        if state.step >= 1 and state.step <= TOTAL_STEPS then
            OnboardingSystem.skipOnboarding(playerName)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STEP BEGIN DISPATCHER
-- Called when a step begins to deliver opening dialogue and set up the scene.
-- ═══════════════════════════════════════════════════════════════════════════

local function dispatchStepBegin(playerName, stepIndex)
    local state = getOrCreateState(playerName)

    -- Spawn scene objects for this step
    spawnSceneObjects(playerName, stepIndex)

    if stepIndex == 1 then
        beginBeamStep(playerName)

    elseif stepIndex == 2 then
        beginFirstBuildStep(playerName)

    elseif stepIndex == 3 then
        beginTidelineStep(playerName)

    elseif stepIndex == 4 then
        beginFirstCraftStep(playerName)

    elseif stepIndex == 5 then
        beginFirstPowerStep(playerName)

    elseif stepIndex == 6 then
        beginUnfinishedStep(playerName)

    elseif stepIndex == 7 then
        beginOpeningStep(playerName)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- LOST PLAYER DETECTION
-- If the player stands in the forge hall looking lost for more than
-- 60 seconds after the tutorial, Lucineer says the line.
-- ═══════════════════════════════════════════════════════════════════════════

local function startLostPlayerWatch(playerName)
    local state = getOrCreateState(playerName)
    if state.lostTimer then return end -- already watching

    state.lostTimer = task.delay(LOST_PLAYER_DELAY, function()
        if not Players:FindFirstChild(playerName) then return end
        local s = playerTutorials[playerName]
        if not s or s.step ~= 7 then return end

        -- Player has been idle/near forge for 60+ seconds
        deliverLine(playerName, OPENING_DIALOGUE.lost_prompt)
        s.lostTimer = nil
    end)
end

local function cancelLostPlayerWatch(playerName)
    local state = getOrCreateState(playerName)
    if state.lostTimer then
        task.cancel(state.lostTimer)
        state.lostTimer = nil
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

OnboardingSystem = {}

--- Initialize the system. Call once on server start.
--- Hooks into PlayerAdded/PlayerRemoving and sets up remotes.
function OnboardingSystem.init()
    setupRemotes()
    OnboardingSystem._initialized = true

    -- ══════════════════════════════════════════════════════════════════════
    -- NPC INTERACTION REGISTRATION
    -- Register as a listener on NPCManager's interaction system.
    -- When a player triggers a ProximityPrompt on an NPC, NPCManager
    -- fires the interaction callbacks. OnboardingSystem routes the
    -- dialogue through the tutorial step logic and/or Worker API.
    -- ══════════════════════════════════════════════════════════════════════
    if NPCManager and NPCManager.onInteraction then
        NPCManager.onInteraction(function(npcName, player)
            OnboardingSystem.handleNPCInteraction(npcName, player)
        end)
        print("[OnboardingSystem] Registered as NPCManager interaction listener")
    else
        warn("[OnboardingSystem] NPCManager not available — NPC interactions will not route through onboarding")
    end

    Players.PlayerAdded:Connect(function(player)
        -- Load tutorial state from D1
        task.spawn(function()
            local savedState = loadTutorialState(player.Name)

            if savedState then
                local state = getOrCreateState(player.Name)
                state.step = savedState.step or 0
                state.skipped = savedState.skipped or false

                if savedState.completed or savedState.step > TOTAL_STEPS then
                    -- Tutorial already complete
                    state.step = TOTAL_STEPS + 1
                    state.completedAt = os.time()
                elseif savedState.step > 0 and savedState.step <= TOTAL_STEPS then
                    -- Resume mid-tutorial — re-begin current step
                    print(string.format("[OnboardingSystem] %s resuming at step %d (%s)",
                        player.Name, savedState.step,
                        STEP_NAMES[STEP_IDS[savedState.step]] or "?"))
                    task.wait(3) -- let the client load
                    beginStep(player.Name, savedState.step)
                    dispatchStepBegin(player.Name, savedState.step)
                else
                    -- Fresh player — auto-start after cinematic
                    local state = getOrCreateState(player.Name)
                    state.step = 0
                    task.delay(CINEMATIC_DURATION, function()
                        if player and player.Parent and state.step == 0 then
                            OnboardingSystem.startOnboarding(player.Name)
                        end
                    end)
                end
            else
                -- No saved state — fresh player
                local state = getOrCreateState(player.Name)
                state.step = 0

                -- Auto-start after cinematic (62 seconds for the full opening)
                task.delay(CINEMATIC_DURATION, function()
                    if player and player.Parent and state.step == 0 then
                        OnboardingSystem.startOnboarding(player.Name)
                    end
                end)
            end
        end)
    end)

    Players.PlayerRemoving:Connect(function(player)
        cancelLostPlayerWatch(player.Name)
        local state = playerTutorials[player.Name]
        if state then
            persistTutorialState(player.Name)
            playerTutorials[player.Name] = nil
        end
    end)

    -- Handle client actions (step completion triggers)
    if TutorialActionRemote then
        TutorialActionRemote.OnServerEvent:Connect(function(player, data)
            handleClientAction(player, data)
        end)
    end

    -- Validate step IDs are contiguous
    for i = 1, TOTAL_STEPS do
        assert(STEP_IDS[i] ~= nil,
            string.format("[OnboardingSystem] Missing step ID at index %d", i))
    end

    print(string.format("[OnboardingSystem] Initialized — %d steps, 30-minute guided session",
        TOTAL_STEPS))
end

--- Start the tutorial for a player.
--- @param playerId string — player username
function OnboardingSystem.startOnboarding(playerId)
    local state = getOrCreateState(playerId)
    state.step = 0
    state.startedAt = os.time()
    state.skipped = false
    state.salvageCollected = 0
    state.boltPlaced = false
    state.handrailHits = 0
    state.beamRushed = false

    -- Begin step 1: The Beam
    beginStep(playerId, 1)

    -- Deliver the opening line (the hard cut from cinematic to gameplay)
    deliverLine(playerId, BEAM_DIALOGUE.opening)

    -- Set up the scene
    dispatchStepBegin(playerId, 1)

    print(string.format("[OnboardingSystem] %s onboarding started at %s",
        playerId, tostring(state.startedAt)))
end

--- Get the player's current tutorial step.
--- @param playerId string
--- @return number — 0 = not started, 1-7 = active step, 8 = complete
function OnboardingSystem.getStep(playerId)
    local state = playerTutorials[playerId]
    if not state then return 0 end
    return state.step
end

--- Get the current step ID string.
--- @param playerId string
--- @return string | nil
function OnboardingSystem.getStepId(playerId)
    local state = playerTutorials[playerId]
    if not state then return nil end
    return state.stepId
end

--- Check if player is currently in the tutorial.
--- @param playerId string
--- @return boolean
function OnboardingSystem.isOnboarding(playerId)
    local state = playerTutorials[playerId]
    if not state then return false end
    if state.skipped then return false end
    return state.step >= 1 and state.step <= TOTAL_STEPS
end

--- Check if player has completed the tutorial.
--- @param playerId string
--- @return boolean
function OnboardingSystem.hasCompleted(playerId)
    local state = playerTutorials[playerId]
    if not state then return false end
    return state.step > TOTAL_STEPS
end

--- Mark a step as complete and advance.
--- This is the primary API for external systems to trigger advancement.
--- @param playerId string
--- @param stepId string — the step ID that was completed
--- @return boolean success
function OnboardingSystem.completeStep(playerId, stepId)
    local state = getOrCreateState(playerId)
    local currentStepId = state.stepId

    -- Verify the completed step matches the current step
    if currentStepId ~= stepId then
        local stepIndex = table.find(STEP_IDS, stepId)
        if not stepIndex or stepIndex > state.step then
            warn(string.format("[OnboardingSystem] %s: cannot complete '%s' (current: '%s')",
                playerId, stepId, tostring(currentStepId)))
            return false
        end
    end

    advanceStep(playerId)
    return true
end

--- Complete the tutorial entirely.
--- @param playerId string
function OnboardingSystem.completeTutorial(playerId)
    local state = getOrCreateState(playerId)
    state.step = TOTAL_STEPS + 1
    state.completedAt = os.time()
    state.stepId = nil

    cancelLostPlayerWatch(playerId)

    local duration = state.completedAt - state.startedAt
    print(string.format("[OnboardingSystem] %s tutorial COMPLETE (%d seconds)",
        playerId, duration))

    -- Notify client
    local player = Players:FindFirstChild(playerId)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "tutorial_complete",
            durationSeconds = duration,
        })
    end

    -- Bond: tutorial completion grants +5 XP (quest equivalent)
    if BondSystem and BondSystem.addQuestXP then
        pcall(function()
            BondSystem.addQuestXP(playerId)
        end)
    end

    -- Era: ensure player is in Era 0
    if EraSystem then
        pcall(function()
            local currentEra = EraSystem.getCurrentEra(playerId)
            if currentEra < 0 then
                EraSystem.unlockEra(playerId, 0)
            end
        end)
    end

    -- Persist final state
    persistTutorialState(playerId)
end

--- Skip the tutorial for a player.
--- Marks all steps as complete and delivers the skip dialogue.
--- Even skipped, the bracket bolt is still on the bench.
--- @param playerId string
function OnboardingSystem.skipOnboarding(playerId)
    local state = getOrCreateState(playerId)
    state.skipped = true
    state.step = TOTAL_STEPS + 1
    state.completedAt = os.time()

    cancelLostPlayerWatch(playerId)

    print(string.format("[OnboardingSystem] %s tutorial SKIPPED", playerId))

    -- Deliver skip dialogue (diegetic — no "Skip Tutorial" button)
    deliverLine(playerId, SKIP_DIALOGUE.first_visit)

    -- Notify client
    local player = Players:FindFirstChild(playerId)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "tutorial_skipped",
        })
    end

    -- Still grant bond XP (they went through it, just faster)
    if BondSystem and BondSystem.addQuestXP then
        pcall(function()
            BondSystem.addQuestXP(playerId)
        end)
    end

    -- Persist
    persistTutorialState(playerId)
end

--- Check if a specific action is allowed during the tutorial.
--- Used by CraftingSystem, PowerGrid, and other systems to gate behavior.
--- @param playerId string
--- @param action string — "craft", "power", "interact", "build", "tideline"
--- @return boolean
function OnboardingSystem.isActionAllowed(playerId, action)
    local state = playerTutorials[playerId]
    if not state then return true end
    if state.skipped or state.step > TOTAL_STEPS then return true end

    if action == "craft" then
        return craftingGateOpen(playerId)
    elseif action == "power" then
        return powerGateOpen(playerId)
    elseif action == "interact" then
        return true -- interaction is always allowed
    elseif action == "build" then
        return state.step >= 2 or state.step == 0
    elseif action == "tideline" then
        return true -- tideline is always accessible
    end

    return true -- default: allow
end

--- Get the full tutorial state for a player (for debugging or external queries).
--- @param playerId string
--- @return table
function OnboardingSystem.getStepData(playerId)
    local state = playerTutorials[playerId]
    if not state then
        return {
            step = 0,
            stepId = nil,
            stepName = nil,
            onTutorial = false,
            completed = false,
            skipped = false,
        }
    end

    return {
        step = state.step,
        stepId = state.stepId,
        stepName = state.stepId and STEP_NAMES[state.stepId] or nil,
        timeframe = state.stepId and STEP_TIMEFRAMES[state.stepId] or nil,
        onTutorial = OnboardingSystem.isOnTutorial(playerId),
        completed = OnboardingSystem.hasCompleted(playerId),
        skipped = state.skipped,
        startedAt = state.startedAt,
        completedAt = state.completedAt,
        salvageCollected = state.salvageCollected,
        boltPlaced = state.boltPlaced,
    }
end

--- Get all step IDs in order (for external systems).
--- @return table
function OnboardingSystem.getStepIds()
    local copy = {}
    for i, id in ipairs(STEP_IDS) do
        copy[i] = id
    end
    return copy
end

--- Get step name by ID.
--- @param stepId string
--- @return string | nil
function OnboardingSystem.getStepName(stepId)
    return STEP_NAMES[stepId]
end

--- Force-set a player's step (admin/debug tool).
--- @param playerId string
--- @param step number
function OnboardingSystem.setStep(playerId, step)
    local state = getOrCreateState(playerId)
    state.step = step
    state.stepId = STEP_IDS[step]

    if step >= 1 and step <= TOTAL_STEPS then
        spawnSceneObjects(playerId, step)
        beginStep(playerId, step)
        dispatchStepBegin(playerId, step)
    elseif step > TOTAL_STEPS then
        OnboardingSystem.completeTutorial(playerId)
    end

    persistTutorialState(playerId)
end

--- Check if the tideline quest is the current step.
--- Used by interaction systems to route salvage pickups correctly.
--- @param playerId string
--- @return boolean
function OnboardingSystem.isTidelineStep(playerId)
    return tidelineActive(playerId)
end

--- Increment salvage collected (can be called by interaction handlers).
--- @param playerId string
function OnboardingSystem.addSalvageCollected(playerId)
    local state = getOrCreateState(playerId)
    if state.step ~= 3 then return end
    onSalvageCollected(playerId)
end

--- Note that the player placed the bolt (step 6).
--- Called by the interaction handler when the player places the bolt
--- in the lamp bracket.
--- @param playerId string
function OnboardingSystem.notifyBoltPlaced(playerId)
    local state = getOrCreateState(playerId)
    if state.step ~= 6 then return end
    state.boltPlaced = true
    -- The timer handles advancement and the "Hm" moment
end

--- Check if a player should see the cinematic.
--- Only first-ever spawn, not on rejoin mid-tutorial.
--- @param playerId string
--- @return boolean
function OnboardingSystem.shouldPlayCinematic(playerId)
    local state = playerTutorials[playerId]
    if not state then return true end
    return state.step == 0 and not state.skipped
end

--- Check if the player is on a specific step.
--- @param playerId string
--- @param stepId string
--- @return boolean
function OnboardingSystem.isOnStep(playerId, stepId)
    local state = playerTutorials[playerId]
    if not state then return false end
    return state.stepId == stepId
end

--- Get the salvage count for step 3.
--- @param playerId string
--- @return number
function OnboardingSystem.getSalvageCount(playerId)
    local state = playerTutorials[playerId]
    if not state then return 0 end
    return state.salvageCollected
end

--- Get the salvage target for step 3.
--- @return number
function OnboardingSystem.getSalvageTarget()
    return SALVAGE_TARGET
end

-- ═══════════════════════════════════════════════════════════════════════════
-- NPC INTERACTION ROUTING
-- Called when a player triggers a ProximityPrompt on an NPC.
-- Routes to either tutorial-specific dialogue (during onboarding) or
-- the Worker API for AI-generated responses (post-tutorial).
-- This replaces the old split-brain where NPCManager had static lines
-- AND TutorialSystem had dialogue AND they fought each other.
-- ═══════════════════════════════════════════════════════════════════════════

--- Handle an NPC proximity interaction from NPCManager.
--- During onboarding: routes to step-specific dialogue tables.
--- Post-onboarding: fires the Worker API for AI-generated responses.
--- @param npcName string — NPC name ("Earl", "Spark", "Hermes", "Bea")
--- @param player Player
function OnboardingSystem.handleNPCInteraction(npcName, player)
    local playerId = player.Name
    local state = getOrCreateState(playerId)

    -- During active tutorial: route to step-specific handlers
    if OnboardingSystem.isOnboarding(playerId) then
        -- During tutorial, NPC interactions are contextual to the step
        local step = state.step

        if step == 3 and npcName == "Earl" then
            -- Tideline quest step: Earl gives the assignment
            deliverLine(playerId, TIDELINE_DIALOGUE.earl_assign)
            return
        end

        if step == 4 and npcName == "Spark" then
            -- Crafting step: Spark emotes encouragement
            if NPCManager and NPCManager.emitSparks then
                NPCManager.emitSparks("Spark")
            end
            return
        end

        if step == 5 and npcName == "Bea" then
            -- Power step: Bea acknowledges the lamp
            deliverLine(playerId, {
                speaker = "Bea",
                line = "Mm.",
            })
            return
        end

        -- For other NPC interactions during tutorial, deliver a brief
        -- contextual hint without breaking the tutorial flow
        if npcName == "Spark" then
            -- Spark emotes but doesn't speak
            if NPCManager and NPCManager.emitSparks then
                NPCManager.emitSparks("Spark")
            end
            if NPCManager and NPCManager.showDialogue then
                NPCManager.showDialogue("Spark", "*tilts head, single lens-blink*", player, 4)
            end
            return
        end

        -- Default: deliver a brief contextual line during tutorial
        -- without breaking step progression
        return
    end

    -- ════════════════════════════════════════════════════════════════════════
    -- POST-TUTORIAL: Route to Worker API for AI-generated dialogue
    -- This is where Lucineier's AI personality comes through. The Worker
    -- pipeline generates contextual responses based on player history,
    -- era, and game state. NPCManager displays them via showDialogue.
    -- ════════════════════════════════════════════════════════════════════════
    OnboardingSystem.requestAIDialogue(npcName, player)
end

--- Request AI-generated dialogue from the Worker API pipeline.
--- Falls back to a brief generic acknowledgment if the Worker is unavailable.
--- @param npcName string
--- @param player Player
function OnboardingSystem.requestAIDialogue(npcName, player)
    local playerId = player.Name

    -- Fire request to the Worker API via HttpService
    -- The Worker generates a contextual response based on:
    --   - NPC personality/lore (system prompt)
    --   - Player conversation history (D1)
    --   - Current game state (era, bonds, quest progress)
    --   - Time of day, weather, recent events
    task.spawn(function()
        local success, result = pcall(function()
            return HttpService:RequestAsync({
                Url = MEMORY_URL .. "/api/dialogue/npc",
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode({
                    player_name = playerId,
                    npc_name = npcName,
                    context = {
                        step = OnboardingSystem.getStep(playerId),
                        completed = OnboardingSystem.hasCompleted(playerId),
                    },
                }),
            })
        end)

        if success and result and result.Success then
            local dataOk, data = pcall(function()
                return HttpService:JSONDecode(result.Body)
            end)
            if dataOk and data and data.message then
                -- Display the AI-generated dialogue via NPCManager
                if NPCManager and NPCManager.showDialogue then
                    NPCManager.showDialogue(npcName, data.message, player, data.duration or 8)
                else
                    -- Fallback: direct bubble (NPCManager not loaded)
                    warn(string.format("[OnboardingSystem] NPCManager not available to show dialogue for %s", npcName))
                end
                return
            end
        end

        -- ═══════════════════════════════════════════════════════════════════════
        -- FALLBACK: Worker API unavailable
        -- Show a brief, non-static acknowledgment that doesn't fight
        -- with AI responses. These are intentionally minimal — just
        -- enough so the NPC doesn't silently ignore the player.
        -- ═══════════════════════════════════════════════════════════════════════
        local fallbackLine
        if npcName == "Earl" then
            fallbackLine = "Manifest's current. Come back if you need work."
        elseif npcName == "Spark" then
            fallbackLine = "*servos whirr, single blink*"
        elseif npcName == "Hermes" then
            fallbackLine = "Channel's running. I'll be here."
        elseif npcName == "Bea" then
            fallbackLine = "The Light holds."
        else
            fallbackLine = "..."
        end

        if NPCManager and NPCManager.showDialogue then
            NPCManager.showDialogue(npcName, fallbackLine, player, 5)
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MODULE EXPORT
-- ═══════════════════════════════════════════════════════════════════════════

print("[OnboardingSystem] Module loaded — 7 steps, diegetic onboarding, 30-minute guided session")

return OnboardingSystem
