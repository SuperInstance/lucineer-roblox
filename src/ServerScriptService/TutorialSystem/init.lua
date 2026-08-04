--!strict
--[[
    TutorialSystem — DEPRECATED (Thin Redirect to OnboardingSystem)
    ═══════════════════════════════════════════════════════════════
    This module has been merged into OnboardingSystem as of the
    NPC/Tutorial split-brain fix (Aug 2026).

    TutorialSystem was redundant with OnboardingSystem — both tracked
    the same 7 tutorial steps with the same D1 schema. Having two
    systems caused conflicting dialogue and split-brain behavior.

    This file remains as a backward-compatibility shim. Any code that
    does `require(ServerScriptService.TutorialSystem)` will get
    OnboardingSystem back, with legacy API names mapped.

    ═══════════════════════════════════════════════════════════════
    MIGRATION GUIDE:
    ═══════════════════════════════════════════════════════════════
    OLD (TutorialSystem):              NEW (OnboardingSystem):
      TutorialSystem.init()              OnboardingSystem.init()
      TutorialSystem.startTutorial()    OnboardingSystem.startOnboarding()
      TutorialSystem.getStep()           OnboardingSystem.getStep()
      TutorialSystem.completeStep()      OnboardingSystem.completeStep()
      TutorialSystem.skipTutorial()      OnboardingSystem.skipOnboarding()
      TutorialSystem.isOnTutorial()      OnboardingSystem.isOnboarding()
      TutorialSystem.hasCompleted()      OnboardingSystem.hasCompleted()
      TutorialSystem.setStep()           OnboardingSystem.setStep()
      TutorialSystem.isActionAllowed()   OnboardingSystem.isActionAllowed()
      TutorialSystem.getStepData()       OnboardingSystem.getStepData()
      TutorialSystem.getStepIds()        OnboardingSystem.getStepIds()
      TutorialSystem.getStepName()       OnboardingSystem.getStepName()
      TutorialSystem.isTidelineStep()    OnboardingSystem.isTidelineStep()
      TutorialSystem.addSalvageCollected() OnboardingSystem.addSalvageCollected()
      TutorialSystem.notifyBoltPlaced()  OnboardingSystem.notifyBoltPlaced()
      TutorialSystem.shouldPlayCinematic() OnboardingSystem.shouldPlayCinematic()
      TutorialSystem.getStepId()         OnboardingSystem.getStepId()

    To migrate: replace `require(ServerScriptService.TutorialSystem)`
    with `require(ServerScriptService.OnboardingSystem)` and update
    the method names above.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local OnboardingSystem

do
    local ok = pcall(function()
        OnboardingSystem = require(ServerScriptService:WaitForChild("OnboardingSystem"))
    end)
    if not ok or not OnboardingSystem then
        warn("[TutorialSystem] ⚠️ DEPRECATED: Could not load OnboardingSystem! " ..
            "TutorialSystem is now a redirect. Ensure OnboardingSystem is present.")
        -- Return an empty table to prevent hard crashes; all calls will no-op
        return {} :: any
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- LEGACY API REDIRECT TABLE
-- Maps old TutorialSystem method names to OnboardingSystem methods.
-- ═══════════════════════════════════════════════════════════════════════════

local TutorialSystem = {}

-- Methods that map 1:1 (same name, different module)
TutorialSystem.init = function()
    warn("[TutorialSystem] ⚠️ DEPRECATED: Use OnboardingSystem.init() instead.")
    return OnboardingSystem.init()
end

TutorialSystem.getStep = function(playerId)
    return OnboardingSystem.getStep(playerId)
end

TutorialSystem.getStepId = function(playerId)
    return OnboardingSystem.getStepId(playerId)
end

TutorialSystem.completeStep = function(playerId, stepId)
    return OnboardingSystem.completeStep(playerId, stepId)
end

TutorialSystem.hasCompleted = function(playerId)
    return OnboardingSystem.hasCompleted(playerId)
end

TutorialSystem.isActionAllowed = function(playerId, action)
    return OnboardingSystem.isActionAllowed(playerId, action)
end

TutorialSystem.getStepData = function(playerId)
    return OnboardingSystem.getStepData(playerId)
end

TutorialSystem.getStepIds = function()
    return OnboardingSystem.getStepIds()
end

TutorialSystem.getStepName = function(stepId)
    return OnboardingSystem.getStepName(stepId)
end

TutorialSystem.setStep = function(playerId, step)
    return OnboardingSystem.setStep(playerId, step)
end

TutorialSystem.isTidelineStep = function(playerId)
    return OnboardingSystem.isTidelineStep(playerId)
end

TutorialSystem.addSalvageCollected = function(playerId)
    return OnboardingSystem.addSalvageCollected(playerId)
end

TutorialSystem.notifyBoltPlaced = function(playerId)
    return OnboardingSystem.notifyBoltPlaced(playerId)
end

TutorialSystem.shouldPlayCinematic = function(playerId)
    return OnboardingSystem.shouldPlayCinematic(playerId)
end

-- Methods with renamed equivalents (old name → new name)
TutorialSystem.startTutorial = function(playerId)
    warn("[TutorialSystem] ⚠️ DEPRECATED: Use OnboardingSystem.startOnboarding() instead.")
    return OnboardingSystem.startOnboarding(playerId)
end

TutorialSystem.skipTutorial = function(playerId)
    warn("[TutorialSystem] ⚠️ DEPRECATED: Use OnboardingSystem.skipOnboarding() instead.")
    return OnboardingSystem.skipOnboarding(playerId)
end

TutorialSystem.isOnTutorial = function(playerId)
    return OnboardingSystem.isOnboarding(playerId)
end

-- completeTutorial maps directly
TutorialSystem.completeTutorial = function(playerId)
    return OnboardingSystem.completeTutorial(playerId)
end

-- getStepName and getCurrentQuestIndex were in old TutorialSystem
-- getCurrentQuestIndex was actually from NPCManager, not TutorialSystem
-- If called, redirect to OnboardingSystem.getStep()
TutorialSystem.getCurrentQuestIndex = function(playerId)
    return OnboardingSystem.getStep(playerId)
end

print("[TutorialSystem] ⚠️ DEPRECATED module loaded — redirecting to OnboardingSystem")

return TutorialSystem
