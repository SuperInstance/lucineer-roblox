--[[
    VesselSystem/init.lua
    Slackwater — Vessel System Entry Point

    "The boat is the game. Everything else is weather."

    This module bootstraps the entire vessel system in the correct order:
      1. VesselTypes   — load configurations (no dependencies)
      2. VesselPhysics — physics engine (depends on VesselTypes)
      3. VesselDamage  — damage system (depends on VesselTypes, VesselPhysics)
      4. HelmController — player control (depends on VesselPhysics, VesselTypes)
      5. VesselSpawner — spawns vessels (depends on all above + EraSystem)

    Call VesselSystem.init() once on server start.

    API:
        VesselSystem.init()
        VesselSystem.getModule(name) → module reference
]]

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local VesselSystem = {}

----------------------------------------------------------------
-- SUB-MODULE REFERENCES
----------------------------------------------------------------

-- Load order matters for dependencies
VesselSystem.VesselTypes = require(script:WaitForChild("VesselTypes"))
VesselSystem.VesselPhysics = require(script:WaitForChild("VesselPhysics"))
VesselSystem.VesselDamage = require(script:WaitForChild("VesselDamage"))
VesselSystem.HelmController = require(script:WaitForChild("HelmController"))
VesselSystem.VesselSpawner = require(script:WaitForChild("VesselSpawner"))

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the entire vessel system.
    Call once on server start after WeatherSystem and EraSystem are initialized.
]]
function VesselSystem.init()
    print("[VesselSystem] Initializing vessel system...")

    -- HelmController connects input handling and player events
    VesselSystem.HelmController.init()

    -- VesselSpawner connects to EraSystem and PlayerAdded events
    VesselSystem.VesselSpawner.init()

    -- VesselDamage connects its own internal heartbeat for wave/sinking updates
    -- (already connected at module load)

    -- VesselPhysics updates are per-vessel (connected on init)
    -- (no global init needed)

    print("[VesselSystem] ✅ Vessel system initialized — 5 vessel types, physics, damage, helm, spawner")
end

--[[
    Get a sub-module by name.
    @param name string — "VesselTypes", "VesselPhysics", etc.
    @return module|nil
]]
function VesselSystem.getModule(name)
    return VesselSystem[name]
end

return VesselSystem
