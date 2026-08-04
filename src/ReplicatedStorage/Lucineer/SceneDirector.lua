--[[
    SceneDirector.lua
    Slackwater — Cinematic Moment Director

    "Some moments deserve a wider lens. The boat pulling away from
     the dock. The sky cracking open with aurora light. The first
     time you see your own vessel. These aren't gameplay — they're
     the scenes you remember."

    ───────────────────────────────────────────────
    RESPONSIBILITY:
      Drives short scripted camera sequences for key gameplay moments.
      Works in concert with VisionController (which yields camera
      control) and CinematicController (the opening cinematic framework).

    CINEMATIC TRIGGERS:
      • departure      — Leaving dock. Camera pulls wide, 3 seconds.
      • arrival        — Approaching dock. Camera shows the harbor.
      • big_catch      — Hauling a full net. Slight slow-mo, dramatic angle.
      • storm_hit      — First large wave strikes. Camera punch.
      • aurora         — Aurora appears. Sky-scanning slow pan.
      • first_vessel   — Player gets their first boat. Special intro.

    INTEGRATION:
      • VisionController.yieldToCinematic() / releaseFromCinematic()
      • WeatherSystem attributes for state
      • Vessel model for camera targets
      • AudioManager for cinematic audio cues
      • Lighting for slow-mo effects (via time scale manipulation)

    This module is designed to be required from the client.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local SceneDirector = {}

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

-- Cinematic types and their default durations
local CINEMATIC_DURATION = {
    departure    = 3.0,
    arrival      = 3.5,
    big_catch    = 2.5,
    storm_hit    = 1.5,
    aurora       = 8.0,
    first_vessel = 6.0,
}

-- Easing styles for camera moves
local EASE_OUT   = TweenInfo.new(1, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local EASE_INOUT = TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local EASE_BACK  = TweenInfo.new(1, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

SceneDirector._initialized = false
SceneDirector._active = false
SceneDirector._currentCinematic = nil
SceneDirector._heartbeatConn = nil
SceneDirector._vesselRoot = nil
SceneDirector._savedCameraType = nil
SceneDirector._savedFOV = nil
SceneDirector._completionCallback = nil
SceneDirector._cinematicStartTime = 0
SceneDirector._elapsed = 0

-- Cooldown tracking: prevent rapid re-triggering of the same cinematic
SceneDirector._cooldowns = {}  -- { [cinematicType]: lastTriggerTime }

-- Minimum time between same-type cinematics (seconds)
local COOLDOWN_TIME = {
    departure    = 10,
    arrival      = 10,
    big_catch    = 5,
    storm_hit    = 3,
    aurora       = 30,   -- aurora cinematics shouldn't spam
    first_vessel = 0,    -- one-time, no cooldown needed
}

----------------------------------------------------------------
-- INTERNAL: UTILITY
----------------------------------------------------------------

--[[
    Safely get the AudioManager module.
    @return table? AudioManager or nil if unavailable
]]
local function getAudioManager()
    local Lucineer = Workspace:FindFirstChild("ReplicatedStorage")
        and Workspace.ReplicatedStorage:FindFirstChild("Lucineer")
    if not Lucineer then
        local rs = game:GetService("ReplicatedStorage")
        Lucineer = rs:FindFirstChild("Lucineer")
    end
    if not Lucineer then return nil end

    local ok, am = pcall(require, Lucineer:FindFirstChild("AudioManager"))
    if ok then return am end
    return nil
end

--[[
    Safely get the VisionController.
    @return table? VisionController or nil
]]
local function getVisionController()
    -- VisionController is a LocalScript in StarterPlayerScripts
    -- We need to require it through its module path
    local starterPlayerScripts = player:WaitForChild("PlayerScripts")
    local vcModule = starterPlayerScripts:FindFirstChild("VisionController")
    if not vcModule then return nil end

    local clientScript = vcModule:FindFirstChild("client")
    if not clientScript then return nil end

    local ok, vc = pcall(require, clientScript)
    if ok then return vc end
    return nil
end

--[[
    Find the player's current vessel root part.
    Checks workspace attribute and CollectionService tags.
    @return BasePart? vessel root
]]
local function findVesselRoot()
    -- Try active vessel attribute
    local vesselName = Workspace:GetAttribute("ActiveVessel")
    if vesselName then
        local model = Workspace:FindFirstChild(vesselName)
        if model and model:IsA("Model") and model.PrimaryPart then
            return model.PrimaryPart
        end
    end

    -- Try tagged parts
    local tagged = CollectionService:GetTagged("ActiveVessel")
    if #tagged > 0 then
        return tagged[1]
    end

    return nil
end

--[[
    Check if a cinematic is on cooldown.
    @param cinematicType string
    @return boolean — true if cooldown is active
]]
local function isOnCooldown(cinematicType)
    local last = SceneDirector._cooldowns[cinematicType]
    if not last then return false end
    local cooldown = COOLDOWN_TIME[cinematicType] or 5
    return (os.clock() - last) < cooldown
end

--[[
    Record a cinematic trigger for cooldown tracking.
    @param cinematicType string
]]
local function recordTrigger(cinematicType)
    SceneDirector._cooldowns[cinematicType] = os.clock()
end

----------------------------------------------------------------
-- INTERNAL: CINEMATIC FRAMEWORK
----------------------------------------------------------------

--[[
    Begin a cinematic sequence. Yields VisionController, saves camera state.
    @param cinematicType string
    @param duration number seconds
    @param onComplete function? callback when finished
    @return boolean — true if successfully started
]]
local function beginCinematic(cinematicType, duration, onComplete)
    if SceneDirector._active then
        return false  -- another cinematic is playing
    end

    if isOnCooldown(cinematicType) then
        return false  -- on cooldown
    end

    SceneDirector._active = true
    SceneDirector._currentCinematic = cinematicType
    SceneDirector._completionCallback = onComplete
    SceneDirector._cinematicStartTime = os.clock()
    SceneDirector._elapsed = 0

    -- Yield VisionController
    local vc = getVisionController()
    if vc then
        vc.yieldToCinematic()
    end

    -- Save camera state
    SceneDirector._savedCameraType = camera.CameraType
    SceneDirector._savedFOV = camera.FieldOfView

    -- Take over camera
    camera.CameraType = Enum.CameraType.Scriptable

    recordTrigger(cinematicType)

    return true
end

--[[
    End the current cinematic sequence. Restores camera control.
]]
local function endCinematic()
    if not SceneDirector._active then return end

    local callback = SceneDirector._completionCallback
    local cinematicType = SceneDirector._currentCinematic

    SceneDirector._active = false
    SceneDirector._currentCinematic = nil
    SceneDirector._completionCallback = nil

    -- Restore camera FOV
    if SceneDirector._savedFOV then
        TweenService:Create(camera, TweenInfo.new(0.5), {
            FieldOfView = SceneDirector._savedFOV
        }):Play()
    end

    -- Release VisionController (handles camera type restoration)
    local vc = getVisionController()
    if vc then
        vc.releaseFromCinematic()
    else
        -- Restore manually if VisionController isn't available
        camera.CameraType = SceneDirector._savedCameraType or Enum.CameraType.Custom
    end

    -- Restore time scale (in case slow-mo was used)
    if RunService:GetAttribute("TimeScale") then
        RunService:SetAttribute("TimeScale", 1.0)
    end

    if callback then
        callback()
    end

    print(string.format("[SceneDirector] Cinematic '%s' complete.", tostring(cinematicType)))
end

----------------------------------------------------------------
-- CINEMATIC SEQUENCES
----------------------------------------------------------------

--[[
    DEPARTURE — When leaving the dock.
    Camera pulls wide to show the boat heading out, then cuts back.

    Sequence:
      1. Start position: high and to the side, showing dock + vessel
      2. Pull back and up slowly (3 seconds)
      3. Hand back control
]]
function SceneDirector.playDeparture(onComplete)
    local vessel = findVesselRoot()
    if not vessel then return false end

    if not beginCinematic("departure", CINEMATIC_DURATION.departure, onComplete) then
        return false
    end

    local duration = CINEMATIC_DURATION.departure
    local vesselPos = vessel.Position
    local vesselForward = vessel.CFrame.LookVector

    -- Start camera: to the side and slightly behind, elevated
    local startPos = vesselPos + (-vesselForward * 10) + Vector3.new(15, 12, 0)
    camera.CFrame = CFrame.lookAt(startPos, vesselPos)

    -- End camera: further back and higher, showing the vessel heading out
    local endPos = vesselPos + (-vesselForward * 20) + Vector3.new(25, 20, 0)

    -- Update camera target to track the vessel as it moves
    local startTime = os.clock()

    SceneDirector._heartbeatConn = RunService.Heartbeat:Connect(function()
        SceneDirector._elapsed = os.clock() - startTime
        local t = math.clamp(SceneDirector._elapsed / duration, 0, 1)

        if t >= 1 then
            if SceneDirector._heartbeatConn then
                SceneDirector._heartbeatConn:Disconnect()
                SceneDirector._heartbeatConn = nil
            end
            endCinematic()
            return
        end

        -- Track the vessel's current position (it's moving)
        local currentVesselPos = vessel.Position
        local currentForward = vessel.CFrame.LookVector

        -- Interpolate camera position relative to the vessel
        local offset1 = Vector3.new(15, 12, 0) - (-currentForward * 10)
        local offset2 = Vector3.new(25, 20, 0) - (-currentForward * 20)

        -- Smoothstep
        local s = t * t * (3 - 2 * t)
        local offset = offset1:Lerp(offset2, s)

        local camPos = currentVesselPos + (-currentForward * (10 + 10 * s)) + Vector3.new(15 + 10 * s, 12 + 8 * s, 0)
        local lookAt = currentVesselPos + currentForward * 5

        camera.CFrame = CFrame.lookAt(camPos, lookAt)
    end)

    -- Audio: departure horn
    local audioMgr = getAudioManager()
    if audioMgr then
        audioMgr.playUi("chat_receive")  -- reuse a soft tone as a departure cue
    end

    print("[SceneDirector] Playing: departure")
    return true
end

--[[
    ARRIVAL — When approaching the dock.
    Camera shows the harbor and the vessel coming in.

    Sequence:
      1. Start with a wide shot of the harbor
      2. Pan to show the vessel approaching
      3. Cut to player view
]]
function SceneDirector.playArrival(onComplete)
    local vessel = findVesselRoot()
    if not vessel then return false end

    if not beginCinematic("arrival", CINEMATIC_DURATION.arrival, onComplete) then
        return false
    end

    local duration = CINEMATIC_DURATION.arrival
    local startTime = os.clock()

    -- Find dock/harbor center (look for tagged parts or use world origin)
    local dock = Workspace:FindFirstChild("Dock", true)
    local dockPos = dock and dock:IsA("BasePart") and dock.Position or Vector3.new(0, 5, 0)

    SceneDirector._heartbeatConn = RunService.Heartbeat:Connect(function()
        SceneDirector._elapsed = os.clock() - startTime
        local t = math.clamp(SceneDirector._elapsed / duration, 0, 1)

        if t >= 1 then
            if SceneDirector._heartbeatConn then
                SceneDirector._heartbeatConn:Disconnect()
                SceneDirector._heartbeatConn = nil
            end
            endCinematic()
            return
        end

        -- Phase 1 (0-0.4): wide harbor shot
        -- Phase 2 (0.4-0.7): pan to vessel approaching
        -- Phase 3 (0.7-1.0): follow vessel into dock
        local vesselPos = vessel.Position

        if t < 0.4 then
            -- Wide shot of the harbor, slowly panning
            local pan = t / 0.4
            local camPos = dockPos + Vector3.new(40 - pan * 15, 25, 40 - pan * 10)
            local lookAt = dockPos
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        elseif t < 0.7 then
            -- Pan to show vessel approaching
            local pan = (t - 0.4) / 0.3
            local midpoint = dockPos:Lerp(vesselPos, 0.5)
            local camPos = midpoint + Vector3.new(30, 20, 30)
            local lookAt = vesselPos:Lerp(dockPos, pan)
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        else
            -- Follow vessel as it comes alongside
            local follow = (t - 0.7) / 0.3
            local offset = Vector3.new(15 - follow * 5, 8 - follow * 3, 15 - follow * 5)
            local camPos = vesselPos + offset
            local lookAt = vesselPos
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        end
    end)

    print("[SceneDirector] Playing: arrival")
    return true
end

--[[
    BIG CATCH — When hauling a full net.
    Slight slow-mo and dramatic angle.

    Sequence:
      1. Quick tilt down to the net
      2. Slow-mo for 1.5 seconds
      3. Dramatic angle from below waterline looking up at the catch
      4. Resume normal speed
]]
function SceneDirector.playBigCatch(onComplete)
    local vessel = findVesselRoot()
    if not vessel then return false end

    if not beginCinematic("big_catch", CINEMATIC_DURATION.big_catch, onComplete) then
        return false
    end

    local duration = CINEMATIC_DURATION.big_catch
    local startTime = os.clock()

    -- Slow-mo: scale time down
    -- Note: We can't actually change server RunService time scale from client,
    -- but we can slow the heartbeat-driven animations and add visual slow-mo
    -- via a subtle BlurEffect and FOV widen
    local slowMoBlur = Instance.new("BlurEffect")
    slowMoBlur.Name = "__CinematicSlowMo"
    slowMoBlur.Size = 0
    slowMoBlur.Parent = Lighting

    TweenService:Create(slowMoBlur, TweenInfo.new(0.3), { Size = 4 }):Play()

    -- Widen FOV slightly for dramatic effect
    TweenService:Create(camera, TweenInfo.new(0.3), { FieldOfView = 80 }):Play()

    SceneDirector._heartbeatConn = RunService.Heartbeat:Connect(function()
        SceneDirector._elapsed = os.clock() - startTime
        local t = math.clamp(SceneDirector._elapsed / duration, 0, 1)

        if t >= 1 then
            if SceneDirector._heartbeatConn then
                SceneDirector._heartbeatConn:Disconnect()
                SceneDirector._heartbeatConn = nil
            end
            -- Clean up slow-mo
            TweenService:Create(slowMoBlur, TweenInfo.new(0.4), { Size = 0 }):Play()
            game:GetService("Debris"):AddItem(slowMoBlur, 0.5)
            endCinematic()
            return
        end

        local vesselPos = vessel.Position
        local vesselForward = vessel.CFrame.LookVector
        local vesselRight = vessel.CFrame.RightVector

        -- Dramatic angle: from the side, slightly below waterline, looking up
        if t < 0.3 then
            -- Quick tilt from helm view down to the net
            local tilt = t / 0.3
            local startPos = vesselPos + (-vesselForward * 8) + Vector3.new(0, 8, 0)
            local endPos = vesselPos + (vesselRight * 6) + Vector3.new(0, -1, 0)
            local camPos = startPos:Lerp(endPos, tilt)
            local lookAt = vesselPos + vesselRight * 3 + Vector3.new(0, 2, 0)
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        else
            -- Hold the dramatic angle with slight drift
            local drift = (t - 0.3) / 0.7
            local basePos = vesselPos + (vesselRight * 6) + Vector3.new(0, -1, 0)
            local driftPos = basePos + vesselForward * (drift * 3)
            local lookAt = vesselPos + vesselRight * 3 + Vector3.new(0, 2 + drift * 2, 0)
            camera.CFrame = CFrame.lookAt(driftPos, lookAt)
        end
    end)

    -- Audio: dramatic cue
    local audioMgr = getAudioManager()
    if audioMgr then
        audioMgr.playCue("surprise")  -- ascending arpeggio for the catch moment
    end

    print("[SceneDirector] Playing: big_catch")
    return true
end

--[[
    STORM HIT — When the first large wave strikes the vessel.
    Camera punch: quick jolt outward + shake.

    Sequence:
      1. Sharp camera punch outward (0.1s)
      2. Violent shake (0.8s)
      3. Recover and hand back (0.6s)
]]
function SceneDirector.playStormHit(onComplete)
    local vessel = findVesselRoot()

    if not beginCinematic("storm_hit", CINEMATIC_DURATION.storm_hit, onComplete) then
        return false
    end

    local duration = CINEMATIC_DURATION.storm_hit
    local startTime = os.clock()
    local vesselPos = vessel and vessel.Position or Vector3.zero

    -- FOV punch: briefly widen then recover
    camera.FieldOfView = 80

    SceneDirector._heartbeatConn = RunService.Heartbeat:Connect(function()
        SceneDirector._elapsed = os.clock() - startTime
        local t = math.clamp(SceneDirector._elapsed / duration, 0, 1)

        if t >= 1 then
            if SceneDirector._heartbeatConn then
                SceneDirector._heartbeatConn:Disconnect()
                SceneDirector._heartbeatConn = nil
            end
            endCinematic()
            return
        end

        if vessel and vessel.Parent then
            vesselPos = vessel.Position
        end

        local vesselForward = vessel and vessel.CFrame.LookVector or Vector3.new(0, 0, -1)

        -- Phase 1 (0-0.07): sharp punch outward
        -- Phase 2 (0.07-0.6): violent shake around a point
        -- Phase 3 (0.6-1.0): recover toward normal helm view
        if t < 0.07 then
            -- Sharp punch
            local punch = t / 0.07
            local offset = Vector3.new(0, 6 + punch * 3, 12 + punch * 5)
            local shake = Vector3.new(
                (math.random() - 0.5) * 2,
                (math.random() - 0.5) * 2,
                (math.random() - 0.5) * 2
            )
            local camPos = vesselPos + (-vesselForward * offset.Z) + Vector3.new(offset.X, offset.Y, 0) + shake
            local lookAt = vesselPos + vesselForward * 5
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        elseif t < 0.6 then
            -- Violent shake
            local shakeT = (t - 0.07) / 0.53
            local shakeIntensity = 1 - shakeT  -- decays over time
            local baseOffset = Vector3.new(2.5, 8, 14)
            local shake = Vector3.new(
                (math.random() - 0.5) * 4 * shakeIntensity,
                (math.random() - 0.5) * 4 * shakeIntensity,
                (math.random() - 0.5) * 3 * shakeIntensity
            )
            local camPos = vesselPos + (-vesselForward * baseOffset.Z) + Vector3.new(baseOffset.X, baseOffset.Y, 0) + shake
            local lookAt = vesselPos + vesselForward * 5
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        else
            -- Recover
            local recover = (t - 0.6) / 0.4
            local s = recover * recover * (3 - 2 * recover)  -- smoothstep
            local offset = Vector3.new(2.5, 4.5 + s * 2, 8 + s * 4)
            local shake = Vector3.new(
                (math.random() - 0.5) * 0.3 * (1 - recover),
                (math.random() - 0.5) * 0.3 * (1 - recover),
                0
            )
            local camPos = vesselPos + (-vesselForward * offset.Z) + Vector3.new(offset.X, offset.Y, 0) + shake
            local lookAt = vesselPos + vesselForward * 10
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        end
    end)

    -- Audio: impact sound
    local audioMgr = getAudioManager()
    if audioMgr then
        audioMgr.playBuildSound("Stone", vesselPos)  -- heavy impact sound
    end

    print("[SceneDirector] Playing: storm_hit")
    return true
end

--[[
    AURORA — When the aurora appears.
    Sky-scanning slow pan. 8 seconds of reverent beauty.

    Sequence:
      1. Camera tilts up slowly
      2. Slow pan across the sky
      3. Settle on the aurora ribbons
      4. Slowly tilt back down
]]
function SceneDirector.playAurora(onComplete)
    if not beginCinematic("aurora", CINEMATIC_DURATION.aurora, onComplete) then
        return false
    end

    local duration = CINEMATIC_DURATION.aurora
    local startTime = os.clock()

    -- Find a good vantage point (on the vessel or dock)
    local vessel = findVesselRoot()
    local character = player.Character
    local startPos = Vector3.new(0, 10, 0)

    if vessel then
        startPos = vessel.Position + Vector3.new(0, 5, 0)
    elseif character and character.PrimaryPart then
        startPos = character.PrimaryPart.Position + Vector3.new(0, 3, 0)
    end

    -- Soft aurora-specific blur for dreamlike quality
    local auroraBlur = Instance.new("BlurEffect")
    auroraBlur.Name = "__AuroraCinematicBlur"
    auroraBlur.Size = 0
    auroraBlur.Parent = Lighting

    TweenService:Create(auroraBlur, TweenInfo.new(3), { Size = 2 }):Play()

    SceneDirector._heartbeatConn = RunService.Heartbeat:Connect(function()
        SceneDirector._elapsed = os.clock() - startTime
        local t = math.clamp(SceneDirector._elapsed / duration, 0, 1)

        if t >= 1 then
            if SceneDirector._heartbeatConn then
                SceneDirector._heartbeatConn:Disconnect()
                SceneDirector._heartbeatConn = nil
            end
            -- Fade blur out
            TweenService:Create(auroraBlur, TweenInfo.new(1.5), { Size = 0 }):Play()
            game:GetService("Debris"):AddItem(auroraBlur, 2)
            endCinematic()
            return
        end

        -- Smooth, slow camera movement
        -- Phase 1 (0-0.15): tilt up from horizon to sky
        -- Phase 2 (0.15-0.85): slow pan across the aurora-lit sky
        -- Phase 3 (0.85-1.0): settle and slowly tilt back toward horizon
        local smooth = t * t * (3 - 2 * t)

        local camPos, lookAt

        if t < 0.15 then
            -- Tilt up
            local tiltUp = t / 0.15
            local upAmount = tiltUp * 30
            camPos = startPos + Vector3.new(0, 5, 0)
            lookAt = startPos + Vector3.new(
                math.sin(smooth * 2) * 20,
                50 + upAmount * 40,
                math.cos(smooth * 2) * 20
            )
        elseif t < 0.85 then
            -- Pan across sky
            local pan = (t - 0.15) / 0.7
            local angle = pan * math.pi * 0.6  -- ~108 degree pan
            local radius = 15
            camPos = startPos + Vector3.new(
                math.sin(angle) * radius,
                5 + math.sin(pan * math.pi) * 3,
                math.cos(angle) * radius
            )
            lookAt = startPos + Vector3.new(
                math.sin(angle + 0.5) * 40,
                80,
                math.cos(angle + 0.5) * 40
            )
        else
            -- Settle back toward horizon
            local settle = (t - 0.85) / 0.15
            local settleAngle = 0.6 * math.pi  -- continue from pan end
            local radius = 15
            camPos = startPos + Vector3.new(
                math.sin(settleAngle) * radius,
                5 + (1 - settle) * 3,
                math.cos(settleAngle) * radius
            )
            -- Look at gradually lowers from sky to horizon
            local skyLook = Vector3.new(
                math.sin(settleAngle + 0.5) * 40,
                80 - settle * 60,
                math.cos(settleAngle + 0.5) * 40
            )
            local horizonLook = Vector3.new(0, 10, 0) + Vector3.new(
                math.sin(settleAngle) * 20,
                0,
                math.cos(settleAngle) * 20
            )
            lookAt = skyLook:Lerp(horizonLook, settle)
        end

        camera.CFrame = CFrame.lookAt(camPos, lookAt)
    end)

    print("[SceneDirector] Playing: aurora")
    return true
end

--[[
    FIRST VESSEL — Special intro cinematic when the player gets their first boat.
    The most important cinematic — this is a milestone moment.

    Sequence:
      1. Player stands on the dock. Camera is at their eye level.
      2. Camera slowly turns toward the vessel at its mooring.
      3. Camera dollies forward along the dock toward the boat.
      4. Camera pans along the hull, showing the whole vessel.
      5. Camera settles behind and above the helm — the "ready" position.
      6. Hard cut to gameplay.
]]
function SceneDirector.playFirstVessel(vesselModel, onComplete)
    if not vesselModel or not vesselModel.PrimaryPart then
        -- Try to find it
        vesselModel = findVesselRoot()
        if not vesselModel then return false end
        -- Wrap in a model reference if it's a part
        if vesselModel:IsA("BasePart") then
            vesselModel = vesselModel:FindFirstAncestorOfClass("Model") or vesselModel
        end
    end

    if not beginCinematic("first_vessel", CINEMATIC_DURATION.first_vessel, onComplete) then
        return false
    end

    local duration = CINEMATIC_DURATION.first_vessel
    local startTime = os.clock()

    local character = player.Character
    local playerPos = character and character.PrimaryPart and character.PrimaryPart.Position or Vector3.new(0, 3, 10)

    local vesselPart = vesselModel:IsA("Model") and vesselModel.PrimaryPart or vesselModel
    local vesselPos = vesselPart.Position
    local vesselForward = vesselPart.CFrame.LookVector
    local vesselRight = vesselPart.CFrame.RightVector

    SceneDirector._heartbeatConn = RunService.Heartbeat:Connect(function()
        SceneDirector._elapsed = os.clock() - startTime
        local t = math.clamp(SceneDirector._elapsed / duration, 0, 1)

        if t >= 1 then
            if SceneDirector._heartbeatConn then
                SceneDirector._heartbeatConn:Disconnect()
                SceneDirector._heartbeatConn = nil
            end
            endCinematic()
            return
        end

        local smooth = t * t * (3 - 2 * t)
        local camPos, lookAt

        if t < 0.15 then
            -- Phase 1: Player eye level, looking at dock
            -- Slowly turn toward the vessel
            local turn = t / 0.15
            camPos = playerPos + Vector3.new(0, 5, 2)
            local initialLook = playerPos + Vector3.new(0, 4, -5)  -- looking along dock
            local vesselLook = vesselPos + Vector3.new(0, 2, 0)
            lookAt = initialLook:Lerp(vesselLook, turn)
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        elseif t < 0.4 then
            -- Phase 2: Dolly forward along the dock toward the boat
            local dolly = (t - 0.15) / 0.25
            local startCam = playerPos + Vector3.new(0, 5, 2)
            local endCam = vesselPos + (-vesselForward * 15) + Vector3.new(0, 6, 0)
            camPos = startCam:Lerp(endCam, dolly)
            lookAt = vesselPos + Vector3.new(0, 2, 0)
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        elseif t < 0.65 then
            -- Phase 3: Pan along the hull
            local pan = (t - 0.4) / 0.25
            -- Start from the stern, pan to the bow
            local sternPos = vesselPos + (-vesselForward * 15) + (vesselRight * 8) + Vector3.new(0, 4, 0)
            local bowPos = vesselPos + (vesselForward * 10) + (vesselRight * 8) + Vector3.new(0, 5, 0)
            camPos = sternPos:Lerp(bowPos, pan)
            lookAt = vesselPos + Vector3.new(0, 2, 0)
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        elseif t < 0.85 then
            -- Phase 4: Rise up and move to helm position
            local rise = (t - 0.65) / 0.2
            local panEnd = vesselPos + (vesselForward * 10) + (vesselRight * 8) + Vector3.new(0, 5, 0)
            local helmView = vesselPos + (-vesselForward * 8) + Vector3.new(2.5, 4.5, 0)
            camPos = panEnd:Lerp(helmView, rise)
            lookAt = vesselPos + vesselForward * 10
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        else
            -- Phase 5: Settle at helm, hard cut incoming
            local settle = (t - 0.85) / 0.15
            local helmView = vesselPos + (-vesselForward * 8) + Vector3.new(2.5, 4.5, 0)
            -- Small breathing movement
            camPos = helmView + Vector3.new(0, math.sin(os.clock() * 1.5) * 0.2, 0)
            lookAt = vesselPos + vesselForward * 10
            camera.CFrame = CFrame.lookAt(camPos, lookAt)
        end
    end)

    -- Audio: special moment
    local audioMgr = getAudioManager()
    if audioMgr then
        audioMgr.playCue("complete")  -- warm chime — this is YOUR boat
        task.delay(1.5, function()
            if audioMgr then
                audioMgr.setMusic("hub")  -- settle into the main theme
            end
        end)
    end

    print("[SceneDirector] Playing: first_vessel — a milestone.")
    return true
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Trigger a cinematic by type.
    @param cinematicType string — "departure", "arrival", "big_catch",
                                  "storm_hit", "aurora", "first_vessel"
    @param ... additional arguments passed to the specific cinematic function
    @return boolean — true if the cinematic started
]]
function SceneDirector.trigger(cinematicType, ...)
    if SceneDirector._active then
        return false  -- already playing
    end

    if cinematicType == "departure" then
        return SceneDirector.playDeparture(...)
    elseif cinematicType == "arrival" then
        return SceneDirector.playArrival(...)
    elseif cinematicType == "big_catch" then
        return SceneDirector.playBigCatch(...)
    elseif cinematicType == "storm_hit" then
        return SceneDirector.playStormHit(...)
    elseif cinematicType == "aurora" then
        return SceneDirector.playAurora(...)
    elseif cinematicType == "first_vessel" then
        return SceneDirector.playFirstVessel(...)
    else
        warn("[SceneDirector] Unknown cinematic type:", cinematicType)
        return false
    end
end

--[[
    Force-cancel the current cinematic. Used when the player
    skips or when something urgent interrupts.
]]
function SceneDirector.cancel()
    if not SceneDirector._active then return end

    if SceneDirector._heartbeatConn then
        SceneDirector._heartbeatConn:Disconnect()
        SceneDirector._heartbeatConn = nil
    end

    endCinematic()
    print("[SceneDirector] Cinematic cancelled.")
end

--[[
    Is a cinematic currently playing?
    @return boolean
]]
function SceneDirector.isActive()
    return SceneDirector._active
end

--[[
    Get the current cinematic type (or nil if inactive).
    @return string?
]]
function SceneDirector.getCurrentType()
    return SceneDirector._currentCinematic
end

--[[
    Initialize the SceneDirector. Sets up event listeners for
    automatic cinematic triggers (weather changes, vessel events).
    Call once on game start.
]]
function SceneDirector.init()
    if SceneDirector._initialized then
        warn("[SceneDirector] Already initialized.")
        return
    end

    -- Listen for aurora start → auto-trigger aurora cinematic
    Workspace:GetAttributeChangedSignal("AuroraActive"):Connect(function()
        if Workspace:GetAttribute("AuroraActive") and not SceneDirector._active then
            -- Small delay to let the aurora visuals build
            task.delay(3, function()
                if Workspace:GetAttribute("AuroraActive") and not SceneDirector._active then
                    SceneDirector.playAurora()
                end
            end)
        end
    end)

    -- Listen for storm start → arm storm_hit (triggered by first wave impact)
    -- The actual trigger happens via SceneDirector.trigger("storm_hit") called
    -- from VisionController.addWaveImpact when the first large wave hits.

    SceneDirector._initialized = true
    print("[SceneDirector] Initialized — standing by for cinematic moments.")
end

--[[
    Clean up the SceneDirector.
]]
function SceneDirector.shutdown()
    SceneDirector.cancel()

    SceneDirector._cooldowns = {}
    SceneDirector._initialized = false
    print("[SceneDirector] Shut down.")
end

return SceneDirector
