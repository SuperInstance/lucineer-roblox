--!strict
--[[
    TutorialSystem — Slackwater's Diegetic Onboarding Controller
    =============================================================
    Tracks and orchestrates the 30-minute guided first session
    described in TUTORIAL_DESIGN.md.

    Seven steps, no popups, no quest trackers. Every trigger is
    a physical event in the world — a beam placed, a plank set,
    salvage returned, a gear crafted, a wheel engaged, a bracket
    left unfinished.

    Steps:
        1. beam_carry    — Player carries the beam to the rollers
        2. first_build   — Player places plank on the bench
        3. tideline_quest— Player returns 3 salvage to Earl
        4. first_craft   — Player crafts a wooden gear
        5. first_power   — Player places gear in the water wheel
        6. unfinished    — Lucineer's deliberate gap (60s scene)
        7. opening       — Player leaves the forge or talks freely

    Usage:
        local TutorialSystem = require(ServerScriptService.TutorialSystem)
        TutorialSystem.init()

        TutorialSystem.startTutorial(playerId)
        TutorialSystem.getStep(playerId)           -- → number (0-8)
        TutorialSystem.completeStep(playerId, stepId)
        TutorialSystem.skipTutorial(playerId)
        TutorialSystem.isOnTutorial(playerId)      -- → boolean

    Dependencies (all optional-safe — system degrades gracefully):
        - ReplicatedStorage.Lucineer.Http          (D1 persistence)
        - ReplicatedStorage.Lucineer.Config        (worker URL)
        - ServerScriptService.BondSystem           (XP on completion)
        - ServerScriptService.EraSystem            (era context)
        - ServerScriptService.EraSystem.CraftingSystem (step 4 gate)
        - ServerScriptService.PowerGrid            (step 5 registration)
        - ServerScriptService.NPCManager           (dialogue dispatch)

    D1 Schema:
        player_profiles.tutorial_step      INTEGER  DEFAULT 0
        player_profiles.tutorial_completed BOOLEAN  DEFAULT FALSE
        player_profiles.tutorial_skipped   BOOLEAN  DEFAULT FALSE
]]

-- ──────────────────────────────────────────────────────────────────────────
-- SERVICES
-- ──────────────────────────────────────────────────────────────────────────

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- ──────────────────────────────────────────────────────────────────────────
-- OPTIONAL DEPENDENCY LOADING (graceful degradation)
-- ──────────────────────────────────────────────────────────────────────────

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
            local ok = pcall(function()
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

-- ──────────────────────────────────────────────────────────────────────────
-- STEP DEFINITIONS
-- ──────────────────────────────────────────────────────────────────────────

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

-- Total step count (including 0 = not started and 8 = complete)
local TOTAL_STEPS = #STEP_IDS

-- ──────────────────────────────────────────────────────────────────────────
-- STEP OPENING DIALOGUE
-- Each step's first line, delivered when the step begins.
-- ──────────────────────────────────────────────────────────────────────────

local STEP_OPENING_LINES = {
    beam_carry = {
        speaker = "Lucineer",
        line = "You're late. Grab that end.",
    },
    first_build = {
        speaker = "Lucineer",
        line = "Cedar. North row. Beach restocked on the flood.",
    },
    tideline_quest = {
        speaker = "Earl",
        line = "Item ten. Salvage run, tideline, north. Three pieces minimum.",
    },
    first_craft = {
        speaker = "Lucineer",
        line = "Bench is yours. Hull plate goes on the left — forge side.",
    },
    first_power = {
        speaker = "Lucineer",
        line = "Come here. Bring the gear.",
    },
    unfinished = {
        speaker = "Lucineer",
        line = nil, -- Deliberate silence. He doesn't explain.
    },
    opening = {
        speaker = "Lucineer",
        line = "Yard's yours to walk. Beach restocks on the flood. When you want something built — say it, show it, or start it.",
    },
}

-- ──────────────────────────────────────────────────────────────────────────
-- TUTORIAL-SPECIFIC SALVAGE TRACKING
-- For step 3 (tideline quest), we track collected salvage locally.
-- ──────────────────────────────────────────────────────────────────────────

local SALVAGE_TARGET = 3

-- ──────────────────────────────────────────────────────────────────────────
-- STATE MANAGEMENT
-- ──────────────────────────────────────────────────────────────────────────

-- playerName → tutorial state table
-- {
--   step            = number (0 = not started, 1-7 = active step index, 8 = complete),
--   stepId          = string (current step ID, or nil),
--   skipped         = boolean,
--   startedAt       = number (os.time()),
--   completedAt     = number | nil,
--   salvageCollected= number (for step 3 tracking),
--   boltPlaced      = boolean (for step 6 / unfinished tracking),
--   sceneObjects    = table (references to spawned tutorial objects),
--   stepTimers      = table (stepId → startTime for analytics),
--   gateCleanup     = table (functions to call on step complete for cleanup),
-- }
local playerTutorials = {}

-- ──────────────────────────────────────────────────────────────────────────
-- REMOTE SETUP
-- ──────────────────────────────────────────────────────────────────────────

-- The tutorial uses the existing ResponseEvent for dialogue delivery
-- and a dedicated TutorialEvent for tutorial-specific client state.
local TutorialRemote -- server → client: tutorial state changes
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

-- ──────────────────────────────────────────────────────────────────────────
-- DIALOGUE DELIVERY
-- Sends a dialogue line to the player's client via the ResponseEvent.
-- Falls back to TutorialRemote if ResponseEvent doesn't exist.
-- ──────────────────────────────────────────────────────────────────────────

local function deliverLine(playerName, lineData)
    if not lineData or not lineData.line then return end

    local player = Players:FindFirstChild(playerName)
    if not player then return end

    -- Try the main ResponseEvent first (for subtitle + VO integration)
    local lucineerFolder = ReplicatedStorage:FindFirstChild("Lucineer")
    if lucineerFolder then
        local responseEvent = lucineerFolder:FindFirstChild("ResponseEvent")
        if responseEvent then
            responseEvent:FireClient(player, {
                type = "tutorial_dialogue",
                speaker = lineData.speaker or "Lucineer",
                message = lineData.line,
                tutorialStep = TutorialSystem.getStep(playerName),
            })
            return
        end
    end

    -- Fallback: TutorialRemote
    TutorialRemote:FireClient(player, {
        action = "dialogue",
        speaker = lineData.speaker or "Lucineer",
        message = lineData.line,
    })
end

-- ──────────────────────────────────────────────────────────────────────────
-- D1 PERSISTENCE
-- ──────────────────────────────────────────────────────────────────────────

local function persistTutorialState(playerName)
    local state = playerTutorials[playerName]
    if not state then return end

    task.spawn(function()
        local HttpService = game:GetService("HttpService")
        local url = MEMORY_URL .. "/api/memory/player"
        local body = HttpService:JSONEncode({
            player_name = playerName,
            tutorial_step = state.step,
            tutorial_completed = (state.step > TOTAL_STEPS),
            tutorial_skipped = state.skipped,
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
        local HttpService = game:GetService("HttpService")
        return HttpService:RequestAsync({
            Url = url,
            Method = "GET",
            Headers = { ["Content-Type"] = "application/json" },
        })
    end)

    if success and result and result.Success and #result.Body > 0 then
        local HttpService = game:GetService("HttpService")
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

-- ──────────────────────────────────────────────────────────────────────────
-- GATING SYSTEM
-- Prevents players from accessing systems before their tutorial step.
-- Gates are removed as the player progresses.
-- ──────────────────────────────────────────────────────────────────────────

-- Gate check: can the player use the crafting table?
local function craftingGateOpen(playerName)
    local state = playerTutorials[playerName]
    if not state then return true end -- not in tutorial = free
    if state.skipped or state.step > TOTAL_STEPS then return true end
    -- Can craft at step 4+
    return state.step >= 4
end

-- Gate check: can the player interact with the water wheel?
local function powerGateOpen(playerName)
    local state = playerTutorials[playerName]
    if not state then return true end
    if state.skipped or state.step > TOTAL_STEPS then return true end
    return state.step >= 5
end

-- Gate check: is the tideline quest active?
local function tidelineActive(playerName)
    local state = playerTutorials[playerName]
    if not state then return false end
    return state.step == 3
end

-- ──────────────────────────────────────────────────────────────────────────
-- STEP TRANSITIONS
-- ──────────────────────────────────────────────────────────────────────────

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
            sceneObjects = {},
            stepTimers = {},
            gateCleanup = {},
        }
    end
    return playerTutorials[playerName]
end

local function beginStep(playerName, stepIndex)
    local state = getOrCreateState(playerName)
    local stepId = STEP_IDS[stepIndex]

    if not stepId then return end

    state.step = stepIndex
    state.stepId = stepId
    state.stepTimers[stepId] = os.time()

    print(string.format("[TutorialSystem] %s → Step %d: %s",
        playerName, stepIndex, STEP_NAMES[stepId] or stepId))

    -- Deliver the opening line for this step (if any)
    local opening = STEP_OPENING_LINES[stepId]
    if opening then
        -- Small delay for dramatic pacing
        task.delay(opening.delay or 1.0, function()
            deliverLine(playerName, opening)
        end)
    end

    -- Notify client of step change
    local player = Players:FindFirstChild(playerName)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "step_changed",
            step = stepIndex,
            stepId = stepId,
            stepName = STEP_NAMES[stepId],
        })
    end

    -- Persist
    persistTutorialState(playerName)
end

local function advanceStep(playerName)
    local state = getOrCreateState(playerName)

    -- Run any cleanup for the current step
    if state.gateCleanup then
        local currentId = state.stepId
        local cleanups = state.gateCleanup[currentId]
        if cleanups then
            for _, cleanup in ipairs(cleanups) do
                pcall(cleanup)
            end
            state.gateCleanup[currentId] = nil
        end
    end

    local nextStep = state.step + 1

    if nextStep > TOTAL_STEPS then
        -- Tutorial complete
        TutorialSystem.completeTutorial(playerName)
        return
    end

    beginStep(playerName, nextStep)
end

-- ──────────────────────────────────────────────────────────────────────────
-- STEP-SPECIFIC COMPLETION HANDLERS
-- ──────────────────────────────────────────────────────────────────────────

-- Step 1: beam_carry completion
-- Triggered when the beam part is placed on the canning rollers.
local function onBeamPlaced(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 1 then return end

    -- Deliver post-beam dialogue
    task.delay(0.5, function()
        deliverLine(playerName, { speaker = "Lucineer", line = "Square enough." })
    end)

    -- Spark welds the beam (Spark animation handled by NPCManager client-side)
    task.delay(2.0, function()
        deliverLine(playerName, { speaker = "Lucineer", line = "Handrail. Bent. Anvil. Straighten it. Hammer's there." })
    end)

    -- The handrail mini-task is part of the step; advance after a short beat
    task.delay(6.0, function()
        advanceStep(playerName)
    end)
end

-- Step 2: first_build completion
-- Triggered when the plank is placed on the bench chalk outline.
local function onPlankPlaced(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 2 then return end

    task.delay(1.0, function()
        deliverLine(playerName, {
            speaker = "Lucineer",
            line = "First plank you ever set. Stays where you put it. That's the date on the building.",
        })
    end)

    -- Give the player a moment to absorb
    task.delay(7.0, function()
        advanceStep(playerName)
    end)
end

-- Step 3: tideline_quest completion
-- Triggered when salvageCollected reaches SALVAGE_TARGET.
local function onSalvageComplete(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 3 then return end

    -- Earl grades the salvage
    task.delay(0.5, function()
        deliverLine(playerName, {
            speaker = "Earl",
            line = "Hull plate. Passable. Wafer panel. Useful — that's a first. Rope. Scrap, but it holds.",
        })
    end)

    task.delay(4.0, function()
        deliverLine(playerName, {
            speaker = "Earl",
            line = "Item ten, complete. Tell the forge he's got stock coming.",
        })
    end)

    task.delay(7.0, function()
        deliverLine(playerName, {
            speaker = "Lucineer",
            line = "He give you 'Passable'? That's his whole vocabulary.",
        })
    end)

    task.delay(11.0, function()
        advanceStep(playerName)
    end)
end

-- Step 4: first_craft completion
-- Triggered when the wooden gear recipe is crafted.
local function onGearCrafted(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 4 then return end

    task.delay(1.0, function()
        deliverLine(playerName, {
            speaker = "Lucineer",
            line = "Gear. Fifty-six more recipes and you've got the whole tree. Don't look at the tree. Look at the gear.",
        })
    end)

    task.delay(7.0, function()
        advanceStep(playerName)
    end)
end

-- Step 5: first_power completion
-- Triggered when the water wheel gear is placed and the lamp lights.
local function onPowerConnected(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 5 then return end

    task.delay(1.5, function()
        deliverLine(playerName, {
            speaker = "Lucineer",
            line = "There. That's the whole trick. Water moves, wheel turns, shaft spins, and somewhere a light comes on.",
        })
    end)

    task.delay(6.0, function()
        deliverLine(playerName, {
            speaker = "Lucineer",
            line = "First light on the island that didn't come from Bea. She won't say anything about it. That's how you know she noticed.",
        })
    end)

    task.delay(12.0, function()
        advanceStep(playerName)
    end)
end

-- Step 6: unfinished completion
-- This step completes on a timer — the scene plays out regardless of
-- whether the player places the bolt. 60 seconds total.
local UNFINISHED_STEP_DURATION = 60

local function onUnfinishedStep(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 6 then return end

    -- Lucineer builds the bracket (visual handled by NPCManager/BuildFX)
    -- At 45 seconds, he places the bolt beside the bracket and walks away
    task.delay(45, function()
        -- Check player is still online and in tutorial
        if not Players:FindFirstChild(playerName) then return end
        if state.step ~= 6 then return end

        -- The "walk away" moment — silence is the point
        -- No dialogue. The open-circle tag is placed on the bracket.
        -- Notify client to show the tin tag visual
        local player = Players:FindFirstChild(playerName)
        if player and TutorialRemote then
            TutorialRemote:FireClient(player, {
                action = "show_open_circle",
                objectName = "lamp_bracket",
            })
        end
    end)

    -- At 60 seconds, advance regardless of bolt placement
    task.delay(UNFINISHED_STEP_DURATION, function()
        if not Players:FindFirstChild(playerName) then return end
        if state.step ~= 6 then return end

        if state.boltPlaced then
            -- Player placed the bolt — the "Hm" moment
            deliverLine(playerName, { speaker = "Lucineer", line = "…Hm." })
            task.delay(3.0, function()
                advanceStep(playerName)
            end)
        else
            -- Player didn't place the bolt — that's fine
            advanceStep(playerName)
        end
    end)
end

-- Step 7: opening completion
-- Triggered when player leaves the forge hall or initiates a free conversation.
local function onPlayerLeftForge(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 7 then return end
    advanceStep(playerName)
end

-- ──────────────────────────────────────────────────────────────────────────
-- CLIENT ACTION HANDLING
-- Receives step-completion signals from client-side interaction detectors.
-- ──────────────────────────────────────────────────────────────────────────

local function handleClientAction(player, data)
    if type(data) ~= "table" then return end
    local playerName = player.Name
    local state = getOrCreateState(playerName)

    if state.step == 0 or state.step > TOTAL_STEPS then return end

    local action = data.action

    if action == "beam_placed" and state.step == 1 then
        onBeamPlaced(playerName)

    elseif action == "plank_placed" and state.step == 2 then
        onPlankPlaced(playerName)

    elseif action == "salvage_collected" and state.step == 3 then
        state.salvageCollected = state.salvageCollected + 1
        if state.salvageCollected >= SALVAGE_TARGET then
            onSalvageComplete(playerName)
        end

    elseif action == "gear_crafted" and state.step == 4 then
        onGearCrafted(playerName)

    elseif action == "power_connected" and state.step == 5 then
        onPowerConnected(playerName)

    elseif action == "bolt_placed" and state.step == 6 then
        state.boltPlaced = true
        -- Don't advance — the timer handles advancement
        -- But note the bolt was placed for the "Hm" moment

    elseif action == "left_forge" and state.step == 7 then
        onPlayerLeftForge(playerName)

    elseif action == "free_conversation" and state.step == 7 then
        onPlayerLeftForge(playerName)
    end
end

-- ──────────────────────────────────────────────────────────────────────────
-- CRAFTING GATE HOOK
-- Intercepts crafting attempts during tutorial.
-- ──────────────────────────────────────────────────────────────────────────

local function hookCraftingGate(playerName)
    -- The crafting gate works by checking tutorial state before the
    -- CraftingSystem processes a craft request. We hook into the
    -- CraftRequestEvent if it exists.
    local lucineerFolder = ReplicatedStorage:FindFirstChild("Lucineer")
    if not lucineerFolder then return end

    local craftEvent = lucineerFolder:FindFirstChild("CraftRequestEvent")
    if not craftEvent then return end

    -- We can't intercept server-side events that are already connected.
    -- Instead, the TutorialSystem provides an API that CraftingSystem
    -- (or any system) can query: TutorialSystem.isActionAllowed()
    -- The integration is handled at the system level, not by event interception.
end

-- ──────────────────────────────────────────────────────────────────────────
-- TIDELINE SALVAGE SPAWN
-- Ensures salvage is available on the tideline for step 3.
-- In production, this coordinates with TideSystem; in the tutorial,
-- we force a guaranteed restock.
-- ──────────────────────────────────────────────────────────────────────────

local function ensureTidelineStocked()
    -- Notify the WorldGenerator/TideSystem to spawn salvage
    -- This is a soft dependency — if the systems aren't present,
    -- the salvage should be pre-placed in the world.
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

-- ──────────────────────────────────────────────────────────────────────────
-- SCENE OBJECT SPAWNING
-- Each tutorial step may need specific objects in the world.
-- These are spawned server-side and cleaned up on completion.
-- ──────────────────────────────────────────────────────────────────────────

local function spawnSceneObjects(playerName, stepIndex)
    local player = Players:FindFirstChild(playerName)
    if not player then return end

    -- Objects are spawned relative to the forge hall and tideline.
    -- In production, these would be model references from ReplicatedStorage.
    -- The TutorialSystem tags them so they can be cleaned up if the player skips.

    local state = getOrCreateState(playerName)

    if stepIndex == 1 then
        -- Spawn the beam on the forge hall floor
        -- (In production: clone a beam model between Lucineer and spawn point)
        -- Tag for cleanup
        state.sceneObjects.beam = true

    elseif stepIndex == 2 then
        -- Ensure cedar planks are on the north tideline row
        ensureTidelineStocked()
        state.sceneObjects.cedar_planks = true

    elseif stepIndex == 3 then
        -- Ensure fresh salvage on tideline
        ensureTidelineStocked()
        state.sceneObjects.tideline_salvage = true

    elseif stepIndex == 4 then
        -- The crafting table is already in the forge; no new spawns needed
        -- But ensure the hull plate from step 3 is usable as crafting material
        state.sceneObjects.crafting_ready = true

    elseif stepIndex == 5 then
        -- Ensure the water wheel mount is visible and ready
        -- The mount should be pre-placed in the world; we just ensure
        -- the gear housing interactable is active
        state.sceneObjects.wheel_ready = true

    elseif stepIndex == 6 then
        -- The bracket and bolt are spawned as part of Lucineer's build animation
        -- (handled by NPCManager / BuildFX)
        state.sceneObjects.bracket = true
    end
end

-- ──────────────────────────────────────────────────────────────────────────
-- STEP 6 TIMER START
-- When step 6 begins, start the unfinished scene timer.
-- ──────────────────────────────────────────────────────────────────────────

local function onStepChanged_unfinished(playerName)
    local state = getOrCreateState(playerName)
    if state.step ~= 6 then return end

    -- Start the 60-second unfinished scene
    onUnfinishedStep(playerName)
end

-- ──────────────────────────────────────────────────────────────────────────
-- PUBLIC API
-- ──────────────────────────────────────────────────────────────────────────

TutorialSystem = {}

-- Initialize the system. Call once on server start.
function TutorialSystem.init()
    setupRemotes()

    -- Track if we've been initialized
    TutorialSystem._initialized = true

    Players.PlayerAdded:Connect(function(player)
        -- Load tutorial state from D1
        task.spawn(function()
            local savedState = loadTutorialState(player.Name)

            if savedState then
                local state = getOrCreateState(player.Name)
                state.step = savedState.step or 0
                state.skipped = savedState.skipped or false

                if savedState.completed or savedState.step > TOTAL_STEPS then
                    state.step = TOTAL_STEPS + 1
                    state.completedAt = os.time()
                elseif savedState.step > 0 and savedState.step <= TOTAL_STEPS then
                    -- Resume mid-tutorial
                    print(string.format("[TutorialSystem] %s resuming at step %d",
                        player.Name, savedState.step))
                    -- Re-begin current step (objects, dialogue)
                    task.wait(3) -- let the client load
                    beginStep(player.Name, savedState.step)
                end
            else
                -- Fresh player — will start tutorial on first interaction
                -- or automatically when they spawn in the forge hall
                local state = getOrCreateState(player.Name)
                state.step = 0

                -- Auto-start after a brief delay (let cinematic play)
                task.delay(62, function()
                    if player and player.Parent and state.step == 0 then
                        TutorialSystem.startTutorial(player.Name)
                    end
                end)
            end
        end)
    end)

    Players.PlayerRemoving:Connect(function(player)
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
            string.format("[TutorialSystem] Missing step ID at index %d", i))
    end

    print(string.format("[TutorialSystem] Initialized — %d tutorial steps", TOTAL_STEPS))
end

-- Start the tutorial for a player.
-- @param playerId string — player username
function TutorialSystem.startTutorial(playerId)
    local state = getOrCreateState(playerId)
    state.step = 0
    state.startedAt = os.time()
    state.skipped = false

    -- Begin step 1
    beginStep(playerId, 1)

    -- Spawn scene objects for step 1
    spawnSceneObjects(playerId, 1)

    print(string.format("[TutorialSystem] %s tutorial started", playerId))
end

-- Get the player's current tutorial step.
-- @param playerId string
-- @return number — 0 = not started, 1-7 = active step, 8 = complete
function TutorialSystem.getStep(playerId)
    local state = playerTutorials[playerId]
    if not state then return 0 end
    return state.step
end

-- Get the current step ID string.
-- @param playerId string
-- @return string | nil
function TutorialSystem.getStepId(playerId)
    local state = playerTutorials[playerId]
    if not state then return nil end
    return state.stepId
end

-- Check if player is currently in the tutorial.
-- @param playerId string
-- @return boolean
function TutorialSystem.isOnTutorial(playerId)
    local state = playerTutorials[playerId]
    if not state then return false end
    if state.skipped then return false end
    return state.step >= 1 and state.step <= TOTAL_STEPS
end

-- Check if player has completed the tutorial.
-- @param playerId string
-- @return boolean
function TutorialSystem.hasCompleted(playerId)
    local state = playerTutorials[playerId]
    if not state then return false end
    return state.step > TOTAL_STEPS
end

-- Mark a step as complete and advance.
-- This is the primary API for external systems to trigger advancement.
-- @param playerId string
-- @param stepId string — the step ID that was completed
function TutorialSystem.completeStep(playerId, stepId)
    local state = getOrCreateState(playerId)
    local currentStepId = state.stepId

    -- Verify the completed step matches the current step
    if currentStepId ~= stepId then
        -- Allow completing any step that's <= current (idempotent safety)
        local stepIndex = table.find(STEP_IDS, stepId)
        if not stepIndex or stepIndex > state.step then
            warn(string.format("[TutorialSystem] %s: cannot complete '%s' (current: '%s')",
                playerId, stepId, tostring(currentStepId)))
            return false
        end
    end

    advanceStep(playerId)
    return true
end

-- Complete the tutorial entirely.
-- @param playerId string
function TutorialSystem.completeTutorial(playerId)
    local state = getOrCreateState(playerId)
    state.step = TOTAL_STEPS + 1
    state.completedAt = os.time()
    state.stepId = nil

    print(string.format("[TutorialSystem] %s tutorial COMPLETE (%d seconds)",
        playerId, state.completedAt - state.startedAt))

    -- Notify client
    local player = Players:FindFirstChild(playerId)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "tutorial_complete",
        })
    end

    -- Grant bond XP for tutorial completion (quest-equivalent)
    if BondSystem and BondSystem.addQuestXP then
        BondSystem.addQuestXP(playerId)
    end

    -- Ensure the player is in Era 0
    if EraSystem then
        local currentEra = EraSystem.getCurrentEra(playerId)
        if currentEra < 0 then
            -- Player should be in Era 0 by default
            EraSystem.unlockEra(playerId, 0)
        end
    end

    -- Persist final state
    persistTutorialState(playerId)

    -- Deliver the opening line (the invitation)
    task.delay(2.0, function()
        deliverLine(playerId, {
            speaker = "Lucineer",
            line = "Yard's yours to walk. Beach restocks on the flood. When you want something built — say it, show it, or start it. I'll know which.",
        })
    end)
end

-- Skip the tutorial for a player.
-- Marks all steps as complete and delivers the skip dialogue.
-- @param playerId string
function TutorialSystem.skipTutorial(playerId)
    local state = getOrCreateState(playerId)
    state.skipped = true
    state.step = TOTAL_STEPS + 1
    state.completedAt = os.time()

    print(string.format("[TutorialSystem] %s tutorial SKIPPED", playerId))

    -- Deliver skip dialogue
    deliverLine(playerId, {
        speaker = "Lucineer",
        line = "You've done this before. Fine. Yard's yours.",
    })

    -- Notify client
    local player = Players:FindFirstChild(playerId)
    if player and TutorialRemote then
        TutorialRemote:FireClient(player, {
            action = "tutorial_skipped",
        })
    end

    -- Still grant bond XP (they went through it, just faster)
    if BondSystem and BondSystem.addQuestXP then
        BondSystem.addQuestXP(playerId)
    end

    -- Persist
    persistTutorialState(playerId)
end

-- Check if a specific action is allowed during the tutorial.
-- Used by CraftingSystem, PowerGrid, and other systems to gate behavior.
-- @param playerId string
-- @param action string — "craft", "power", "interact", "build"
-- @return boolean
function TutorialSystem.isActionAllowed(playerId, action)
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
        -- Free building allowed after step 2
        return state.step >= 2 or state.step == 0
    elseif action == "tideline" then
        return true -- tideline is always accessible
    end

    return true -- default: allow
end

-- Get the full tutorial state for a player (for debugging or external queries).
-- @param playerId string
-- @return table
function TutorialSystem.getStepData(playerId)
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
        onTutorial = TutorialSystem.isOnTutorial(playerId),
        completed = TutorialSystem.hasCompleted(playerId),
        skipped = state.skipped,
        startedAt = state.startedAt,
        completedAt = state.completedAt,
        salvageCollected = state.salvageCollected,
        boltPlaced = state.boltPlaced,
    }
end

-- Get all step IDs in order (for external systems).
-- @return table
function TutorialSystem.getStepIds()
    local copy = {}
    for i, id in ipairs(STEP_IDS) do
        copy[i] = id
    end
    return copy
end

-- Get step name by ID.
-- @param stepId string
-- @return string | nil
function TutorialSystem.getStepName(stepId)
    return STEP_NAMES[stepId]
end

-- Force-set a player's step (admin/debug tool).
-- @param playerId string
-- @param step number
function TutorialSystem.setStep(playerId, step)
    local state = getOrCreateState(playerId)
    state.step = step
    state.stepId = STEP_IDS[step]

    if step >= 1 and step <= TOTAL_STEPS then
        spawnSceneObjects(playerId, step)
        beginStep(playerId, step)

        -- Special handling for step 6 (unfinished timer)
        if step == 6 then
            onStepChanged_unfinished(playerId)
        end
    elseif step > TOTAL_STEPS then
        TutorialSystem.completeTutorial(playerId)
    end

    persistTutorialState(playerId)
end

-- Check if the tideline quest is the current step.
-- Used by interaction systems to route salvage pickups correctly.
-- @param playerId string
-- @return boolean
function TutorialSystem.isTidelineStep(playerId)
    return tidelineActive(playerId)
end

-- Increment salvage collected (can be called by interaction handlers).
-- @param playerId string
function TutorialSystem.addSalvageCollected(playerId)
    local state = getOrCreateState(playerId)
    if state.step ~= 3 then return end

    state.salvageCollected = state.salvageCollected + 1

    if state.salvageCollected >= SALVAGE_TARGET then
        onSalvageComplete(playerId)
    end
end

-- Note that the player placed the bolt (step 6).
-- Called by the interaction handler when the player places the bolt
-- in the lamp bracket.
-- @param playerId string
function TutorialSystem.notifyBoltPlaced(playerId)
    local state = getOrCreateState(playerId)
    if state.step ~= 6 then return end
    state.boltPlaced = true
    -- The timer will handle advancement and the "Hm" moment
end

-- Check if a player should see the cinematic.
-- Only first-ever spawn, not on rejoin mid-tutorial.
-- @param playerId string
-- @return boolean
function TutorialSystem.shouldPlayCinematic(playerId)
    local state = playerTutorials[playerId]
    if not state then return true end -- no state = fresh player
    return state.step == 0 and not state.skipped
end

-- ──────────────────────────────────────────────────────────────────────────
-- MODULE EXPORT
-- ──────────────────────────────────────────────────────────────────────────

print("[TutorialSystem] Module loaded — 7 tutorial steps, diegetic onboarding")

return TutorialSystem
