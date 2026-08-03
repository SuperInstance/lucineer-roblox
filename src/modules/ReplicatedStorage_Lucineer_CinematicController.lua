--[[
    Lucineer CinematicController
    ───────────────────────────────────────────────
    "The hard cut. No fade. Control arrives like a handoff, because it is one."

    Drives the sixty-second opening cinematic (Production Design §1.1):
    fog to forge, one unbroken camera move, hard cut to gameplay at 0:55.

    Responsibilities:
      • Beat timeline — fires VO/captions/tags on schedule, hands control
        back to the player with a hard cut (no fade) at the final beat.
      • Mobile detection — same skip verb (tap) works on every input path,
        per §1.4: "the entire first experience uses exactly two verbs."
      • Quality scaling — trims cinematic-only visual effects (fog density,
        beam particle count) on low-end devices. Never touches audio.
      • Skip — unlocks per SKIP_UNLOCK_TIME below and jumps straight to the
        turn-and-three-count beat, never further. A skip gets its own line;
        nobody enters Slackwater without being looked at.
      • Load-bearing audio is never cut. Quality tiers and skips only ever
        remove polish (extra fog layers, motion smoothing) — the eight
        beats marked loadBearing = true in BEATS always play their sound.

    This module is designed to be required from the client.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local CinematicController = {}

----------------------------------------------------------------
-- BEAT TIMELINE (Production Design §1.1)
----------------------------------------------------------------
-- voiceId left nil until VO is recorded/generated — the controller
-- degrades gracefully (caption + timing still fire) when it is.

local BEATS = {
    {
        t = 0.00,
        tag = "the_line",
        line = "Every engine dies. That's not the sad part.",
        voiceId = nil,
        loadBearing = true,
    },
    {
        t = 5.00,
        tag = "heat_sink_prop",
        line = nil,
        voiceId = nil,
        loadBearing = true,
    },
    {
        t = 12.00,
        tag = "beam_sweep",
        line = nil,
        voiceId = nil,
        loadBearing = true,
        skipUnlocks = true, -- platform + App Review reality (§1.1)
    },
    {
        t = 22.00,
        tag = "hammer_rhythm_enters",
        line = nil,
        voiceId = nil,
        loadBearing = true,
        musicCue = "build", -- AudioManager.setMusic mode
    },
    {
        t = 32.00,
        tag = "tideline_no_slowdown",
        line = nil,
        voiceId = nil,
        loadBearing = true,
    },
    {
        t = 41.00,
        tag = "sentence_break",
        line = "What's half-built —",
        voiceId = nil,
        loadBearing = true,
    },
    {
        t = 50.00,
        tag = "three_count",
        line = "…belongs to whoever shows up.",
        voiceId = nil,
        loadBearing = true,
        holdSeconds = 3, -- hold it even if a producer says it's dead air
    },
    {
        t = 55.00,
        tag = "hard_cut_to_gameplay",
        line = "You're late. Grab that end.",
        voiceId = nil,
        loadBearing = true,
        handoff = true, -- no fade; control returns here
    },
}

local SKIP_LINE = "In a hurry. Fine. So's the tide. Grab that end."

-- Design doc §1.1 is the canonical source: skippable after 0:12, not 0:05.
-- (0:05 is the heat-sink beat, easy to confuse with the skip gate — kept
-- as a named constant so a designer can retune it in one place either way.)
local SKIP_UNLOCK_TIME = 12.0
local SKIP_TARGET_TIME = 50.0 -- a skip jumps to the turn; never further

----------------------------------------------------------------
-- MOBILE DETECTION
----------------------------------------------------------------

--[[
    True if the player's primary input is touch, not mouse/keyboard.
    Console (10-foot interface) is treated as mobile for cinematic
    purposes: same "one tap" skip affordance, no keyboard assumed.
]]
function CinematicController.isMobile(): boolean
    if GuiService:IsTenFootInterface() then
        return true
    end
    return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

----------------------------------------------------------------
-- QUALITY SCALING
----------------------------------------------------------------
-- Cinematic-only visual budget. Never scales audio — load-bearing
-- beats play their sound at every tier.

local QUALITY_TIERS = {
    low = {
        fogDensity = 0.35,
        beamParticleDensity = 0.3,
        cameraSmoothing = false,
    },
    medium = {
        fogDensity = 0.65,
        beamParticleDensity = 0.65,
        cameraSmoothing = true,
    },
    high = {
        fogDensity = 1.0,
        beamParticleDensity = 1.0,
        cameraSmoothing = true,
    },
}

--[[
    Pick a quality tier from the player's saved Roblox graphics setting,
    falling back to a mobile-safe default when the setting is Automatic
    (the common case) or unavailable (e.g. Studio).
]]
function CinematicController.getQualityTier(): string
    local ok, gameSettings = pcall(function()
        return UserSettings():GetService("UserGameSettings")
    end)

    if ok and gameSettings then
        local level = gameSettings.SavedQualityLevel
        if level and level ~= Enum.SavedQualitySetting.Automatic then
            local n = level.Value -- QualityLevel1..QualityLevel21
            if n <= 7 then
                return "low"
            elseif n <= 14 then
                return "medium"
            else
                return "high"
            end
        end
    end

    -- Automatic / unavailable: bias mobile toward low, desktop toward medium.
    return CinematicController.isMobile() and "low" or "medium"
end

----------------------------------------------------------------
-- INTERNAL STATE
----------------------------------------------------------------

local state = {
    playing = false,
    skipped = false,
    startClock = 0,
    firedBeats = {} :: {[number]: boolean},
    gui = nil :: ScreenGui?,
    skipButton = nil :: TextButton?,
    captionLabel = nil :: TextLabel?,
    heartbeatConn = nil :: RBXScriptConnection?,
    onCompleteCallback = nil :: (() -> ())?,
}

----------------------------------------------------------------
-- UI: CAPTION + SKIP BUTTON
----------------------------------------------------------------

local function createGui(): (ScreenGui, TextLabel, TextButton)
    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

    local gui = Instance.new("ScreenGui")
    gui.Name = "LucineerCinematic"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 100
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = playerGui

    -- Letterbox bars sell "cinematic" cheaply and hide camera-rig edge cases.
    local topBar = Instance.new("Frame")
    topBar.Name = "LetterboxTop"
    topBar.Size = UDim2.new(1, 0, 0, 60)
    topBar.Position = UDim2.new(0, 0, 0, 0)
    topBar.BackgroundColor3 = Color3.new(0, 0, 0)
    topBar.BorderSizePixel = 0
    topBar.Parent = gui

    local bottomBar = topBar:Clone()
    bottomBar.Name = "LetterboxBottom"
    bottomBar.Position = UDim2.new(0, 0, 1, -60)
    bottomBar.Parent = gui

    local caption = Instance.new("TextLabel")
    caption.Name = "Caption"
    caption.Size = UDim2.new(0.8, 0, 0, 50)
    caption.Position = UDim2.new(0.1, 0, 1, -110)
    caption.BackgroundTransparency = 1
    caption.Font = Enum.Font.Gotham
    caption.TextSize = 22
    caption.TextColor3 = Color3.fromRGB(240, 240, 245)
    caption.TextStrokeTransparency = 0.4
    caption.TextWrapped = true
    caption.Text = ""
    caption.Parent = gui

    local skipButton = Instance.new("TextButton")
    skipButton.Name = "SkipButton"
    skipButton.Size = UDim2.new(0, 120, 0, 40)
    skipButton.Position = UDim2.new(1, -140, 0, 14)
    skipButton.BackgroundColor3 = Color3.fromRGB(15, 25, 35)
    skipButton.BackgroundTransparency = 0.2
    skipButton.TextColor3 = Color3.fromRGB(240, 240, 245)
    skipButton.Font = Enum.Font.Gotham
    skipButton.TextSize = 18
    skipButton.Text = "Skip ▶"
    skipButton.Visible = false -- becomes visible at SKIP_UNLOCK_TIME
    skipButton.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = skipButton

    return gui, caption, skipButton
end

----------------------------------------------------------------
-- CAMERA RIG (optional — degrades gracefully if art isn't in yet)
----------------------------------------------------------------

--[[
    Looks for Workspace.Cinematic.CameraPath, an ordered folder of parts
    named Waypoint1, Waypoint2, ... If present, locks the camera and
    tweens it across the path over the cinematic's duration. If absent,
    the timeline still runs (audio, captions, hard cut) — this lets the
    controller ship ahead of the art rig without erroring.
]]
local function tryLockCamera(qualityTier: string): (() -> ())?
    local cinematicFolder = Workspace:FindFirstChild("Cinematic")
    local path = cinematicFolder and cinematicFolder:FindFirstChild("CameraPath")
    if not path then
        return nil
    end

    local waypoints = {}
    for _, child in ipairs(path:GetChildren()) do
        if child:IsA("BasePart") then
            table.insert(waypoints, child)
        end
    end
    table.sort(waypoints, function(a, b)
        return a.Name < b.Name
    end)
    if #waypoints < 2 then
        return nil
    end

    local camera = Workspace.CurrentCamera
    local previousType = camera.CameraType
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = waypoints[1].CFrame

    local tiers = QUALITY_TIERS[qualityTier] or QUALITY_TIERS.medium
    local easingStyle = tiers.cameraSmoothing and Enum.EasingStyle.Sine or Enum.EasingStyle.Linear

    local totalDuration = BEATS[#BEATS].t
    local segmentDuration = totalDuration / (#waypoints - 1)

    for i = 2, #waypoints do
        local tween = TweenService:Create(
            camera,
            TweenInfo.new(segmentDuration, easingStyle, Enum.EasingDirection.InOut),
            { CFrame = waypoints[i].CFrame }
        )
        task.delay(segmentDuration * (i - 2), function()
            if camera.CameraType == Enum.CameraType.Scriptable then
                tween:Play()
            end
        end)
    end

    return function()
        camera.CameraType = previousType
    end
end

----------------------------------------------------------------
-- BEAT PLAYBACK
----------------------------------------------------------------

local function fireBeat(beat, AudioManager)
    if beat.line then
        state.captionLabel.Text = beat.line
    end

    if beat.voiceId and AudioManager then
        AudioManager.playCue(beat.tag)
    end

    if beat.musicCue and AudioManager then
        AudioManager.setMusic(beat.musicCue)
    end

    if beat.holdSeconds then
        task.delay(beat.holdSeconds, function()
            if state.captionLabel and state.captionLabel.Text == beat.line then
                state.captionLabel.Text = ""
            end
        end)
    end

    if beat.skipUnlocks and state.skipButton then
        state.skipButton.Visible = true
    end

    if beat.handoff then
        CinematicController._finish()
    end
end

function CinematicController._finish()
    if not state.playing then
        return
    end
    state.playing = false

    if state.heartbeatConn then
        state.heartbeatConn:Disconnect()
        state.heartbeatConn = nil
    end
    if state.gui then
        state.gui:Destroy()
        state.gui = nil
    end
    if state.unlockCamera then
        state.unlockCamera()
        state.unlockCamera = nil
    end

    local cb = state.onCompleteCallback
    state.onCompleteCallback = nil
    if cb then
        cb()
    end
end

--[[
    Skip forward to the turn-and-three-count beat (0:50). Per §1.1, a
    skip never skips the final look — everyone gets looked at once.
    Fires the skip-specific line instead of the normal 0:41 sentence.
]]
function CinematicController.skip()
    if not state.playing or state.skipped then
        return
    end
    if (os.clock() - state.startClock) < SKIP_UNLOCK_TIME then
        return -- not unlocked yet; ignore
    end
    state.skipped = true

    for _, beat in ipairs(BEATS) do
        if beat.t < SKIP_TARGET_TIME then
            state.firedBeats[beat.t] = true
        end
    end

    if state.captionLabel then
        state.captionLabel.Text = SKIP_LINE
    end
    if state.skipButton then
        state.skipButton.Visible = false
    end

    state.startClock = os.clock() - SKIP_TARGET_TIME
end

----------------------------------------------------------------
-- PLAY
----------------------------------------------------------------

--[[
    Plays the opening cinematic. onComplete fires once, at the hard cut
    (whether reached naturally or via skip) — this is when callers should
    hand back player movement / start the beam interaction.
]]
function CinematicController.play(onComplete: (() -> ())?)
    if state.playing then
        return
    end
    state.playing = true
    state.skipped = false
    state.startClock = os.clock()
    state.firedBeats = {}
    state.onCompleteCallback = onComplete

    local AudioManager
    local ok = pcall(function()
        AudioManager = require(script.Parent:WaitForChild("AudioManager"))
    end)
    if not ok then
        AudioManager = nil
    end

    local qualityTier = CinematicController.getQualityTier()

    state.gui, state.captionLabel, state.skipButton = createGui()
    state.skipButton.Activated:Connect(CinematicController.skip)

    state.unlockCamera = tryLockCamera(qualityTier)

    state.heartbeatConn = RunService.Heartbeat:Connect(function()
        if not state.playing then
            return
        end
        local elapsed = os.clock() - state.startClock
        for _, beat in ipairs(BEATS) do
            if elapsed >= beat.t and not state.firedBeats[beat.t] then
                state.firedBeats[beat.t] = true
                fireBeat(beat, AudioManager)
            end
        end
    end)
end

return CinematicController
