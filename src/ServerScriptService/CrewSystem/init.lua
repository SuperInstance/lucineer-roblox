--!strict
--[[
    CrewSystem — Slackwater Crew & NPC Interaction System
    ═════════════════════════════════════════════════════════════════
    "A harbor is more than water and wood. It's the people who
     show up every morning knowing the fog might not lift."

    Bootstraps the five-module system that makes Slackwater alive:

      • NPCAI          — Daily routines, schedules, pathfinding
      • CrewSystem      — Hire/manage NPC crew aboard vessels
      • DialogueSystem  — Context-aware branching conversations
      • HarborLife      — Ambient harbor activity (boats, gulls, fog)
      • NPCManager      — (external, already exists — we integrate)

    Dependencies:
      - ServerScriptService.NPCManager (existing NPC models)
      - ServerScriptService.BondSystem (bond tiers gate dialogue)
      - ServerScriptService.WeatherSystem (storm/shelter behavior)
      - ServerScriptService.VesselSystem (crew berth checks)

    API:
      CrewSystem.init()                      — bootstrap all subsystems
      CrewSystem.getCrewSystem()             — returns CrewSystem module
      CrewSystem.getDialogueSystem()         — returns DialogueSystem module
      CrewSystem.getNPCAI()                  — returns NPCAI module
      CrewSystem.getHarborLife()             — returns HarborLife module
]]

local ServerScriptService = game:GetService("ServerScriptService")

local CrewSystem = {}

-- Submodule references (lazy-loaded)
local NPCAI
local CrewManager
local DialogueSystem
local HarborLife

local initialized = false

----------------------------------------------------------------
-- INTERNAL: REQUIRE SUBMODULES
----------------------------------------------------------------

-- Cache requires so we only do them once.
local function ensureRequires()
    if NPCAI then return end
    NPCAI = require(script:WaitForChild("NPCAI"))
    CrewManager = require(script:WaitForChild("CrewSystem"))
    DialogueSystem = require(script:WaitForChild("DialogueSystem"))
    HarborLife = require(script:WaitForChild("HarborLife"))
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the full Crew & NPC Interaction System.
    Call once during server init, after NPCManager and BondSystem are up.
]]
function CrewSystem.init()
    if initialized then
        warn("[CrewSystem] Already initialized.")
        return
    end

    ensureRequires()

    -- Boot order matters: NPCAI needs NPCManager models,
    -- DialogueSystem needs BondSystem tiers,
    -- CrewManager needs VesselSystem for berth checks,
    -- HarborLife is standalone ambient.
    NPCAI.init()
    DialogueSystem.init()
    CrewManager.init()
    HarborLife.init()

    initialized = true
    print("[CrewSystem] All subsystems online — Slackwater is alive.")
    print("  ↳ NPCAI: schedules & pathfinding")
    print("  ↳ DialogueSystem: branching conversations")
    print("  ↳ CrewManager: hire/manage vessel crew")
    print("  ↳ HarborLife: ambient harbor activity")
end

--[[
    Get the NPCAI module (for external access to schedule info).
    @return table
]]
function CrewSystem.getNPCAI()
    ensureRequires()
    return NPCAI
end

--[[
    Get the CrewManager module (for external hire/dismiss access).
    @return table
]]
function CrewSystem.getCrewManager()
    ensureRequires()
    return CrewManager
end

--[[
    Get the DialogueSystem module (for external dialogue triggers).
    @return table
]]
function CrewSystem.getDialogueSystem()
    ensureRequires()
    return DialogueSystem
end

--[[
    Get the HarborLife module (for external ambient control).
    @return table
]]
function CrewSystem.getHarborLife()
    ensureRequires()
    return HarborLife
end

--[[
    Shutdown all subsystems (for testing).
]]
function CrewSystem.shutdown()
    ensureRequires()
    HarborLife.shutdown()
    CrewManager.shutdown()
    DialogueSystem.shutdown()
    NPCAI.shutdown()
    initialized = false
    print("[CrewSystem] All subsystems shut down.")
end

return CrewSystem
