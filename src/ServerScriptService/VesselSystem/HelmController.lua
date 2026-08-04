--[[
    VesselSystem/HelmController.lua
    Slackwater — Player Helm Control

    "You don't drive a boat. You negotiate with it. You suggest a direction
     and hope the current agrees. You feed it throttle and pray the engine
     remembers its manners. A good captain listens before they steer."

    ───────────────────────────────────────────────
    FEATURES:

    1. BOARDING
       Walk to the boat → ProximityPrompt appears on the helm seat.
       Press to board → camera locks to helm, player character sits.
       Player gets control of throttle/rudder via keyboard.

    2. THROTTLE (0-100%, forward/reverse)
       W/S keys control throttle up/down. There's an acceleration curve —
       you don't slam to full power instantly. The engine has to answer.
       Reverse is slower than forward (real boats).

    3. RUDDER (speed-dependent steering)
       A/D keys control rudder left/right. Turn rate is proportional to
       speed through water. No speed = no steering. This is the #1 rule
       of boat handling and this system enforces it.

    4. ANCHOR
       Press a key to drop anchor. Takes 3 seconds to set (rope plays out).
       While set, boat holds position. Takes 3 seconds to raise.
       Can't throttle while anchored.

    5. SPEED ZONES
       Harbor zone: speed limited to 8 studs/sec (no-wake zone).
       Open water: no limit. Zone is defined by distance from pier.

    6. ENGINE SEQUENCE
       Boarding starts the engine sequence:
         a) Choke (1s — engine cranking sound)
         b) Crank (1s — engine catches, sputters)
         c) Idle (2s — RPM stabilizes)
         d) Engage (ready for throttle)
       Engine can be stopped (kill switch) when leaving helm.

    INPUT MAP (keyboard):
       W          — throttle up
       S          — throttle down / reverse
       A          — rudder left (port)
       D          — rudder right (starboard)
       X          — full stop (emergency throttle to 0)
       F          — anchor toggle
       E          — disembark

    API:
        HelmController.init()              — connect to PlayerAdded
        HelmController.boardVessel(player, vesselState)
        HelmController.disembark(player)
        HelmController.getActiveVessel(player) — vesselState|nil
        HelmController.isPlayerAtHelm(player)   — boolean
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local HelmController = {}

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

-- Throttle response
local THROTTLE_RATE = 0.4       -- how fast throttle changes per second
local THROTTLE_DEADZONE = 0.05  -- below this, throttle = 0

-- Rudder response
local RUDDER_RATE = 1.5         -- how fast rudder moves per second
local RUDDER_RETURN = 2.0       -- auto-centering rate when no input

-- Speed zones
local HARBOR_RADIUS = 150       -- studs from pier origin
local HARBOR_SPEED_LIMIT = 8    -- studs/sec

-- Engine sequence timings (seconds)
local ENGINE_CHOKE_TIME = 1.0
local ENGINE_CRANK_TIME = 1.0
local ENGINE_IDLE_TIME = 2.0

-- Anchor timings
local ANCHOR_SET_TIME = 3.0
local ANCHOR_RAISE_TIME = 3.0

-- Input keys
local KEYS = {
    throttleUp   = Enum.KeyCode.W,
    throttleDown = Enum.KeyCode.S,
    rudderLeft   = Enum.KeyCode.A,
    rudderRight  = Enum.KeyCode.D,
    fullStop     = Enum.KeyCode.X,
    anchor       = Enum.KeyCode.F,
    disembark    = Enum.KeyCode.E,
}

-- Engine states
local ENGINE_STATE = {
    OFF = "off",
    CHOKING = "choking",
    CRANKING = "cranking",
    IDLING = "idling",
    READY = "ready",
    STOPPING = "stopping",
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

-- playerId → helm session
local helmSessions = {}

-- Cache of currently pressed keys (for smooth input)
local pressedKeys = {}

-- Module references (lazily loaded)
local VesselPhysics
local VesselTypes

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

--[[
    Lazy-load VesselPhysics to avoid circular requires.
]]
local function getVesselPhysics()
    if not VesselPhysics then
        VesselPhysics = require(script.Parent:WaitForChild("VesselPhysics"))
    end
    return VesselPhysics
end

--[[
    Lazy-load VesselTypes.
]]
local function getVesselTypes()
    if not VesselTypes then
        VesselTypes = require(script.Parent:WaitForChild("VesselTypes"))
    end
    return VesselTypes
end

--[[
    Check if the player is within harbor speed zone.
    @param position Vector3
    @return boolean
]]
local function isInHarborZone(position)
    -- Harbor zone is a circle around the pier origin (world 0,0 by default)
    local pierOrigin = Vector3.new(0, 0, 0)

    -- Check for a pier part in workspace
    local pier = Workspace:FindFirstChild("Pier")
    if pier and pier:IsA("Model") and pier.PrimaryPart then
        pierOrigin = pier.PrimaryPart.Position
    elseif pier and pier:IsA("BasePart") then
        pierOrigin = pier.Position
    end

    local flatPos = Vector3.new(position.X, 0, position.Z)
    local flatPier = Vector3.new(pierOrigin.X, 0, pierOrigin.Z)
    return (flatPos - flatPier).Magnitude < HARBOR_RADIUS
end

--[[
    Create a ProximityPrompt on the vessel's helm seat.
    @param vesselModel Model
    @param helmSeat Part
]]
local function createBoardingPrompt(vesselModel, helmSeat)
    -- Remove existing prompt
    local existing = helmSeat:FindFirstChild("BoardPrompt")
    if existing then existing:Destroy() end

    local prompt = Instance.new("ProximityPrompt")
    prompt.Name = "BoardPrompt"
    prompt.ActionText = "Take the Helm"
    prompt.ObjectText = vesselModel.Name or "Vessel"
    prompt.KeyboardKeyCode = Enum.KeyCode.E
    prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
    prompt.MaxActivationDistance = 8
    prompt.RequiresLineOfSight = false
    prompt.HoldDuration = 0.5  -- brief hold to board
    prompt.Parent = helmSeat
end

--[[
    Play an engine sound at the vessel.
    @param vesselModel Model
    @param soundId string
    @param duration number
    @param volume number
]]
local function playEngineSound(vesselModel, soundId, duration, volume)
    local sound = Instance.new("Sound")
    sound.SoundId = soundId
    sound.Volume = volume or 0.5
    sound.Parent = vesselModel.PrimaryPart
    sound:Play()
    game:GetService("Debris"):AddItem(sound, duration + 0.5)
end

----------------------------------------------------------------
-- ENGINE SEQUENCE
----------------------------------------------------------------

--[[
    Run the engine startup sequence.
    @param session table helm session
]]
local function startEngineSequence(session)
    session.engineState = ENGINE_STATE.CHOKING

    -- Choke sound
    playEngineSound(session.vesselModel, "rbxassetid://9118858002", ENGINE_CHOKE_TIME, 0.3)

    task.delay(ENGINE_CHOKE_TIME, function()
        if not session.active then return end
        session.engineState = ENGINE_STATE.CRANKING

        -- Crank sound (engine turning over)
        playEngineSound(session.vesselModel, "rbxassetid://9120299190", ENGINE_CRANK_TIME, 0.4)

        task.delay(ENGINE_CRANK_TIME, function()
            if not session.active then return end
            session.engineState = ENGINE_STATE.IDLING

            -- Idle sound (engine caught, settling)
            playEngineSound(session.vesselModel, "rbxassetid://9120546960", ENGINE_IDLE_TIME, 0.35)

            task.delay(ENGINE_IDLE_TIME, function()
                if not session.active then return end
                session.engineState = ENGINE_STATE.READY
                session.vesselModel:SetAttribute("EngineRunning", true)

                -- Start continuous engine sound
                local idleLoop = Instance.new("Sound")
                idleLoop.Name = "EngineIdle"
                idleLoop.SoundId = "rbxassetid://9120546960"
                idleLoop.Looped = true
                idleLoop.Volume = 0.3
                idleLoop.Parent = session.vesselModel.PrimaryPart
                idleLoop:Play()
            end)
        end)
    end)
end

--[[
    Stop the engine.
    @param session table helm session
]]
local function stopEngine(session)
    session.engineState = ENGINE_STATE.STOPPING

    -- Remove idle sound
    local idleLoop = session.vesselModel.PrimaryPart:FindFirstChild("EngineIdle")
    if idleLoop then
        -- Fade out
        local tween = game:GetService("TweenService"):Create(idleLoop,
            TweenInfo.new(0.5), {Volume = 0})
        tween:Play()
        game:GetService("Debris"):AddItem(idleLoop, 1)
    end

    -- Kill throttle
    session.throttle = 0
    getVesselPhysics().setThrottle(session.vesselState, 0)

    task.delay(0.5, function()
        if session then
            session.engineState = ENGINE_STATE.OFF
            if session.vesselModel then
                session.vesselModel:SetAttribute("EngineRunning", false)
            end
        end
    end)
end

----------------------------------------------------------------
-- BOARDING / DISEMBARKING
----------------------------------------------------------------

--[[
    Board a vessel and take the helm.
    @param player Player
    @param vesselState table (from VesselPhysics.init)
]]
function HelmController.boardVessel(player, vesselState)
    if helmSessions[player.UserId] then
        warn(string.format("[HelmController] %s is already at a helm", player.Name))
        return false
    end

    local vesselModel = vesselState.model
    local config = vesselState.config
    local physics = getVesselPhysics()

    -- Create helm seat if it doesn't exist
    local helmSeat = vesselModel:FindFirstChild("HelmSeat", true)
    if not helmSeat then
        helmSeat = Instance.new("Seat")
        helmSeat.Name = "HelmSeat"
        helmSeat.Size = Vector3.new(2, 1, 2)
        helmSeat.Position = vesselModel.PrimaryPart.Position + config.helmOffset
        helmSeat.Color = Color3.fromRGB(80, 60, 40)
        helmSeat.Material = Enum.Material.WoodPlanks
        helmSeat.CanCollide = true
        helmSeat.Parent = vesselModel
    end

    -- Sit the player
    player.Character.Humanoid.SeatPart = helmSeat
    local humanoidRootPart = player.Character:FindFirstChild("HumanoidRootPart")
    if humanoidRootPart then
        humanoidRootPart.CFrame = helmSeat.CFrame + Vector3.new(0, 1, 0)
    end

    -- Create session
    local session = {
        active = true,
        player = player,
        vesselModel = vesselModel,
        vesselState = vesselState,
        config = config,
        helmSeat = helmSeat,

        -- Control state
        throttle = 0,        -- -1.0 to 1.0
        rudder = 0,          -- -1.0 to 1.0
        targetThrottle = 0,
        targetRudder = 0,

        -- Engine
        engineState = ENGINE_STATE.OFF,

        -- Anchor
        anchorState = "raised",  -- "raised", "setting", "set", "raising"
        anchorTimer = 0,

        -- HUD attributes
        speedDisplay = 0,
        headingDisplay = 0,

        -- Heartbeat connection
        connection = nil,
    }

    helmSessions[player.UserId] = session

    -- Hide the boarding prompt
    local prompt = helmSeat:FindFirstChild("BoardPrompt")
    if prompt then prompt.Enabled = false end

    -- Start engine sequence
    startEngineSequence(session)

    -- Tag the player as at-helm
    player:SetAttribute("AtHelm", true)
    player:SetAttribute("VesselType", config.key)

    -- Connect per-player update
    session.connection = RunService.Heartbeat:Connect(function(dt)
        HelmController._updateSession(session, dt)
    end)

    print(string.format("[HelmController] %s boarded %s", player.Name, config.displayName))
    return true
end

--[[
    Disembark from the current vessel.
    @param player Player
]]
function HelmController.disembark(player)
    local session = helmSessions[player.UserId]
    if not session then return false end

    -- Stop engine
    stopEngine(session)

    -- Release controls
    session.throttle = 0
    session.targetThrottle = 0
    getVesselPhysics().setThrottle(session.vesselState, 0)
    getVesselPhysics().setRudder(session.vesselState, 0)

    -- Stand the player up
    local char = player.Character
    if char then
        local humanoid = char:FindFirstChild("Humanoid")
        if humanoid then
            humanoid.Sit = false
        end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp and session.helmSeat then
            -- Place player next to the helm
            local offset = session.helmSeat.CFrame.RightVector * 3
            hrp.CFrame = session.helmSeat.CFrame + offset + Vector3.new(0, 2, 0)
        end
    end

    -- Disconnect
    if session.connection then
        session.connection:Disconnect()
        session.connection = nil
    end

    -- Show boarding prompt again
    if session.helmSeat then
        local prompt = session.helmSeat:FindFirstChild("BoardPrompt")
        if prompt then prompt.Enabled = true end
    end

    -- Clear attributes
    player:SetAttribute("AtHelm", false)
    player:SetAttribute("VesselType", nil)

    session.active = false
    helmSessions[player.UserId] = nil

    print(string.format("[HelmController] %s disembarked", player.Name))
    return true
end

----------------------------------------------------------------
-- INPUT HANDLING
----------------------------------------------------------------

--[[
    Handle keyboard input from players at the helm.
]]
local function onInputBegan(input, gameProcessed)
    if gameProcessed then return end

    -- Track pressed keys
    pressedKeys[input.KeyCode] = true

    -- One-shot actions
    for userId, session in pairs(helmSessions) do
        if not session.active then goto continue end
        local player = session.player
        if not player or not player.Parent then goto continue end

        if input.KeyCode == KEYS.disembark then
            HelmController.disembark(player)
        elseif input.KeyCode == KEYS.fullStop then
            session.targetThrottle = 0
            session.throttle = 0
        elseif input.KeyCode == KEYS.anchor then
            HelmController._toggleAnchor(session)
        end

        ::continue::
    end
end

local function onInputEnded(input, gameProcessed)
    pressedKeys[input.KeyCode] = nil
end

----------------------------------------------------------------
-- PER-SESSION UPDATE
----------------------------------------------------------------

--[[
    Update a single helm session every frame.
    Handles throttle/rudder smoothing, speed zones, and anchor timing.
    @param session table
    @param dt number
]]
function HelmController._updateSession(session, dt)
    if not session.active then return end
    if not session.player or not session.player.Parent then
        HelmController.disembark(session.player)
        return
    end

    local physics = getVesselPhysics()

    -- ──────────────────────────────────────────────────────────────
    -- READ INPUT (held keys)
    -- ──────────────────────────────────────────────────────────────

    if session.engineState == ENGINE_STATE.READY then
        -- Throttle
        if pressedKeys[KEYS.throttleUp] and not pressedKeys[KEYS.throttleDown] then
            session.targetThrottle = math.min(1.0, session.targetThrottle + THROTTLE_RATE * dt)
        elseif pressedKeys[KEYS.throttleDown] and not pressedKeys[KEYS.throttleUp] then
            session.targetThrottle = math.max(-1.0, session.targetThrottle - THROTTLE_RATE * dt)
        end

        -- Rudder
        if pressedKeys[KEYS.rudderLeft] and not pressedKeys[KEYS.rudderRight] then
            session.targetRudder = math.max(-1.0, session.targetRudder - RUDDER_RATE * dt)
        elseif pressedKeys[KEYS.rudderRight] and not pressedKeys[KEYS.rudderLeft] then
            session.targetRudder = math.min(1.0, session.targetRudder + RUDDER_RATE * dt)
        else
            -- Auto-center rudder when no input
            if session.targetRudder > 0 then
                session.targetRudder = math.max(0, session.targetRudder - RUDDER_RETURN * dt)
            elseif session.targetRudder < 0 then
                session.targetRudder = math.min(0, session.targetRudder + RUDDER_RETURN * dt)
            end
        end
    end

    -- ──────────────────────────────────────────────────────────────
    -- SMOOTH CONTROLS
    -- ──────────────────────────────────────────────────────────────

    -- Smooth throttle toward target
    session.throttle = session.throttle + (session.targetThrottle - session.throttle) * dt * 2.0
    if math.abs(session.throttle) < THROTTLE_DEADZONE then
        session.throttle = 0
    end

    -- Smooth rudder toward target
    session.rudder = session.rudder + (session.targetRudder - session.rudder) * dt * 3.0

    -- ──────────────────────────────────────────────────────────────
    -- SPEED ZONE ENFORCEMENT
    -- ──────────────────────────────────────────────────────────────

    local vesselPos = session.vesselModel.PrimaryPart.Position
    local effectiveThrottle = session.throttle

    if isInHarborZone(vesselPos) then
        -- Limit speed in harbor
        local maxHarborThrottle = HARBOR_SPEED_LIMIT / session.config.topSpeed
        if session.throttle > maxHarborThrottle then
            effectiveThrottle = maxHarborThrottle
            session.player:SetAttribute("SpeedZone", "harbor")
        end
    else
        session.player:SetAttribute("SpeedZone", "open")
    end

    -- ──────────────────────────────────────────────────────────────
    -- ANCHOR STATE MACHINE
    -- ──────────────────────────────────────────────────────────────

    if session.anchorState == "setting" then
        session.anchorTimer = session.anchorTimer + dt
        if session.anchorTimer >= ANCHOR_SET_TIME then
            session.anchorState = "set"
            physics.setAnchor(session.vesselState, true)
            session.player:SetAttribute("AnchorSet", true)
        end
        -- No throttle while anchor is setting
        effectiveThrottle = 0
    elseif session.anchorState == "raising" then
        session.anchorTimer = session.anchorTimer + dt
        if session.anchorTimer >= ANCHOR_RAISE_TIME then
            session.anchorState = "raised"
            physics.setAnchor(session.vesselState, false)
            session.player:SetAttribute("AnchorSet", false)
        end
        -- No throttle while raising anchor
        effectiveThrottle = 0
    elseif session.anchorState == "set" then
        effectiveThrottle = 0
    end

    -- ──────────────────────────────────────────────────────────────
    -- APPLY TO PHYSICS
    -- ──────────────────────────────────────────────────────────────

    physics.setThrottle(session.vesselState, effectiveThrottle)
    physics.setRudder(session.vesselState, session.rudder)

    -- ──────────────────────────────────────────────────────────────
    -- UPDATE HUD ATTRIBUTES
    -- ──────────────────────────────────────────────────────────────

    local speed = physics.getSpeed(session.vesselState)
    local heading = physics.getHeading(session.vesselState)

    session.speedDisplay = speed
    session.headingDisplay = heading

    session.player:SetAttribute("VesselSpeed", math.floor(math.abs(speed)))
    session.player:SetAttribute("VesselHeading", math.floor(heading))
    session.player:SetAttribute("VesselThrottle", math.floor(session.throttle * 100))
    session.player:SetAttribute("VesselRudder", math.floor(session.rudder * 100))

    -- Check for capsize or grounding warnings
    if physics.isCapsized(session.vesselState) then
        session.player:SetAttribute("VesselWarning", "capsized")
    elseif physics.isGrounded(session.vesselState) then
        session.player:SetAttribute("VesselWarning", "grounded")
    else
        session.player:SetAttribute("VesselWarning", "")
    end
end

--[[
    Toggle anchor state for a session.
    @param session table
]]
function HelmController._toggleAnchor(session)
    if session.anchorState == "raised" then
        -- Start setting anchor
        session.anchorState = "setting"
        session.anchorTimer = 0
        session.targetThrottle = 0
        session.throttle = 0
        session.player:SetAttribute("AnchorState", "setting")
    elseif session.anchorState == "set" then
        -- Start raising anchor
        session.anchorState = "raising"
        session.anchorTimer = 0
        session.player:SetAttribute("AnchorState", "raising")
    end
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Get the vessel a player is currently helming.
    @param player Player
    @return table|nil vesselState
]]
function HelmController.getActiveVessel(player)
    local session = helmSessions[player.UserId]
    return session and session.vesselState or nil
end

--[[
    Check if a player is currently at a helm.
    @param player Player
    @return boolean
]]
function HelmController.isPlayerAtHelm(player)
    return helmSessions[player.UserId] ~= nil
end

--[[
    Get the engine state string for display.
    @param player Player
    @return string
]]
function HelmController.getEngineState(player)
    local session = helmSessions[player.UserId]
    return session and session.engineState or ENGINE_STATE.OFF
end

--[[
    Get the anchor state string.
    @param player Player
    @return string
]]
function HelmController.getAnchorState(player)
    local session = helmSessions[player.UserId]
    return session and session.anchorState or "raised"
end

--[[
    Initialize the HelmController. Connects input and player events.
    Call once on server start.
]]
function HelmController.init()
    -- Connect input
    UserInputService.InputBegan:Connect(onInputBegan)
    UserInputService.InputEnded:Connect(onInputEnded)

    -- Clean up when players leave
    Players.PlayerRemoving:Connect(function(player)
        if helmSessions[player.UserId] then
            HelmController.disembark(player)
        end
    end)

    -- Watch for ProximityPrompt activations on vessel helm seats
    -- (set up by VesselSpawner when boats are spawned)
    -- The prompt handler connects in boardVessel via prompt.Triggered

    print("[HelmController] Initialized — helm input system ready")
end

--[[
    Register a vessel for boarding by creating a ProximityPrompt.
    Called by VesselSpawner after spawning a vessel.
    @param vesselModel Model
    @param vesselState table (from VesselPhysics)
    @param ownerId number (player.UserId)
]]
function HelmController.registerBoardable(vesselModel, vesselState, ownerId)
    local helmSeat = vesselModel:FindFirstChild("HelmSeat", true)
    if not helmSeat then
        -- Create helm seat
        local config = vesselState.config
        helmSeat = Instance.new("Seat")
        helmSeat.Name = "HelmSeat"
        helmSeat.Size = Vector3.new(2, 1, 2)
        helmSeat.Position = vesselModel.PrimaryPart.Position + config.helmOffset
        helmSeat.Color = Color3.fromRGB(80, 60, 40)
        helmSeat.Material = Enum.Material.WoodPlanks
        helmSeat.CanCollide = true
        helmSeat.Parent = vesselModel
    end

    createBoardingPrompt(vesselModel, helmSeat)

    -- Connect prompt
    local prompt = helmSeat:FindFirstChild("BoardPrompt")
    if prompt then
        prompt.Triggered:Connect(function(player)
            HelmController.boardVessel(player, vesselState)
        end)
    end
end

return HelmController
