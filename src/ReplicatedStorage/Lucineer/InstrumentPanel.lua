--[[
    InstrumentPanel.lua
    Slackwater — Marine HUD Instruments

    "Lucineer built these gauges by hand. Brass-rimmed, slightly worn,
     the needles jitter with the engine's opinion. They tell you
     what the water won't."

    ───────────────────────────────────────────────
    A GUI panel showing real-time vessel data with analog marine gauges:

      • Speed        — studs/sec and knots
      • Heading      — compass degrees (0–359)
      • Depth        — under keel (from NavigationSystem — CRITICAL)
      • Throttle     — position (0–100%)
      • Rudder       — angle (-35° to +35°)
      • Engine RPM   — rotations per minute
      • Hull         — integrity (damaged indicator)
      • Cargo        — current/max weight
      • Clock        — in-game time, tied to day/night

    All gauges are analog dials — brass-rimmed, slightly worn.
    They look like real marine instruments because Lucineer made them.

    INTEGRATION:
      • Reads vessel data from workspace attributes on the vessel model:
          Speed, Heading, Depth, Throttle, RudderAngle, EngineRPM,
          HullIntegrity, CargoWeight, CargoMax
      • Reads in-game time from Lighting.ClockTime
      • Integrates with UIManager (parents to UIManager's ScreenGui if available)
      • Shows/hides based on whether the player is at the helm

    This module is designed to be required from the client.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local InstrumentPanel = {}

----------------------------------------------------------------
-- DESIGN CONSTANTS
----------------------------------------------------------------

-- Brass colors (worn, hand-made feel)
local BRASS_LIGHT  = Color3.fromRGB(196, 168, 102)
local BRASS_DARK   = Color3.fromRGB(138, 116, 68)
local BRASS_SHADOW = Color3.fromRGB(90, 75, 42)
local DIAL_FACE    = Color3.fromRGB(32, 38, 40)      -- dark gunmetal face
local DIAL_RIM     = Color3.fromRGB(160, 138, 82)     -- brass rim
local NEEDLE_COLOR = Color3.fromRGB(230, 195, 120)    -- brass-gold needle
local NEEDLE_DANGER = Color3.fromRGB(220, 80, 60)     -- red for danger zones
local TEXT_COLOR   = Color3.fromRGB(200, 190, 165)    -- aged off-white
local WARNING_COLOR = Color3.fromRGB(220, 100, 70)    -- warning orange-red
local GOOD_COLOR   = Color3.fromRGB(120, 180, 130)    -- muted green
local BG_PANEL     = Color3.fromRGB(22, 26, 28)       -- dark panel background
local BG_PANEL_ACCENT = Color3.fromRGB(35, 40, 42)

-- Sizes
local PANEL_WIDTH = 420
local PANEL_HEIGHT = 280
local GAUGE_SIZE = 90
local SMALL_GAUGE_SIZE = 70

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

InstrumentPanel._initialized = false
InstrumentPanel._screenGui = nil
InstrumentPanel._panel = nil
InstrumentPanel._visible = false
InstrumentPanel._heartbeatConn = nil
InstrumentPanel._gauges = {}  -- gauge name → { frame, needle, label, valueLabel, config }
InstrumentPanel._vesselRoot = nil
InstrumentPanel._clockLabel = nil
InstrumentPanel._hullBar = nil
InstrumentPanel._cargoBar = nil

----------------------------------------------------------------
-- INTERNAL: DIAL CREATION
----------------------------------------------------------------

--[[
    Create a single analog gauge dial.

    The gauge consists of:
      • A brass outer rim (circle with gradient)
      • A dark dial face
      • Tick marks around the edge
      • A label (what this gauge measures)
      • A needle (rotates to show the value)
      • A value readout (digital text below the dial)
      • A center cap (small circle where the needle pivots)

    @param name string — gauge identifier
    @param parent Instance — parent GUI element
    @param position UDim2 — position of the gauge
    @param size number — pixel size of the gauge (diameter)
    @param config table — gauge configuration:
        min, max, dangerZone (optional table { start, stop }),
        label, unit, tickCount, tickInterval
    @return table — { frame, needle, label, valueLabel }
]]
local function createGauge(name, parent, position, size, config)
    local container = Instance.new("Frame")
    container.Name = name .. "Gauge"
    container.Size = UDim2.new(0, size, 0, size + 20)
    container.Position = position
    container.BackgroundTransparency = 1
    container.Parent = parent

    -- Brass outer rim (largest circle)
    local rim = Instance.new("Frame")
    rim.Name = "Rim"
    rim.Size = UDim2.new(0, size, 0, size)
    rim.Position = UDim2.new(0.5, -size / 2, 0, 0)
    rim.BackgroundColor3 = BRASS_LIGHT
    rim.BorderSizePixel = 0
    rim.Parent = container

    local rimCorner = Instance.new("UICorner")
    rimCorner.CornerRadius = UDim.new(1, 0)  -- perfect circle
    rimCorner.Parent = rim

    -- Brass gradient (simulates worn metal)
    local rimGradient = Instance.new("UIGradient")
    rimGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, BRASS_LIGHT),
        ColorSequenceKeypoint.new(0.5, BRASS_DARK),
        ColorSequenceKeypoint.new(1, BRASS_SHADOW),
    })
    rimGradient.Rotation = 45
    rimGradient.Parent = rim

    -- Inner shadow ring (dark band between rim and face)
    local shadowRing = Instance.new("Frame")
    shadowRing.Name = "ShadowRing"
    shadowRing.Size = UDim2.new(0, size - 6, 0, size - 6)
    shadowRing.Position = UDim2.new(0.5, -(size - 6) / 2, 0, 3)
    shadowRing.BackgroundColor3 = BRASS_SHADOW
    shadowRing.BorderSizePixel = 0
    shadowRing.Parent = container

    local shadowCorner = Instance.new("UICorner")
    shadowCorner.CornerRadius = UDim.new(1, 0)
    shadowCorner.Parent = shadowRing

    -- Dial face (dark gunmetal)
    local faceSize = size - 10
    local face = Instance.new("Frame")
    face.Name = "Face"
    face.Size = UDim2.new(0, faceSize, 0, faceSize)
    face.Position = UDim2.new(0.5, -faceSize / 2, 0, 5)
    face.BackgroundColor3 = DIAL_FACE
    face.BorderSizePixel = 0
    face.Parent = container

    local faceCorner = Instance.new("UICorner")
    faceCorner.CornerRadius = UDim.new(1, 0)
    faceCorner.Parent = face

    -- Subtle face gradient for depth
    local faceGradient = Instance.new("UIGradient")
    faceGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 46, 48)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 24, 26)),
    })
    faceGradient.Rotation = 90
    faceGradient.Parent = face

    -- Tick marks
    local tickCount = config.tickCount or 10
    local tickStartAngle = -225  -- gauges start at bottom-left (7 o'clock)
    local tickEndAngle = 45      -- and end at bottom-right (5 o'clock)
    local tickSpan = tickEndAngle - tickStartAngle

    for i = 0, tickCount do
        local angle = math.rad(tickStartAngle + (tickSpan * i / tickCount))
        local isMajor = (i % (config.tickInterval or 2) == 0) or i == tickCount

        local tickSize = isMajor and 8 or 4
        local tickWidth = isMajor and 2 or 1
        local tickColor = isMajor and TEXT_COLOR or Color3.fromRGB(100, 95, 80)

        -- Danger zone ticks
        if config.dangerZone then
            local tickValue = config.min + (config.max - config.min) * (i / tickCount)
            if tickValue >= config.dangerZone.start and tickValue <= config.dangerZone.stop then
                tickColor = NEEDLE_DANGER
            end
        end

        local tick = Instance.new("Frame")
        tick.Name = "Tick" .. i
        tick.AnchorPoint = Vector2.new(0.5, 0.5)
        tick.Size = UDim2.new(0, tickWidth, 0, tickSize)
        tick.BackgroundColor3 = tickColor
        tick.BorderSizePixel = 0

        -- Position tick around the dial
        local radius = (faceSize / 2) - 6
        local centerX = faceSize / 2
        local centerY = faceSize / 2
        tick.Position = UDim2.new(
            0, centerX + math.cos(angle - math.rad(90)) * radius,
            0, centerY + math.sin(angle - math.rad(90)) * radius
        )
        tick.Rotation = math.deg(angle) + 90
        tick.Parent = face
    end

    -- Danger zone arc (if configured)
    if config.dangerZone then
        local dangerStartRatio = (config.dangerZone.start - config.min) / (config.max - config.min)
        local dangerEndRatio = (config.dangerZone.stop - config.min) / (config.max - config.min)
        local dangerStartAngle = tickStartAngle + tickSpan * dangerStartRatio
        local dangerEndAngle = tickStartAngle + tickSpan * dangerEndRatio

        -- Simple visual: color the rim section differently via a frame
        -- (Full arc rendering is complex in Roblox GUI; this is a good approximation)
        local dangerArc = Instance.new("Frame")
        dangerArc.Name = "DangerArc"
        dangerArc.Size = UDim2.new(0, 4, 0, faceSize * 0.4)
        dangerArc.AnchorPoint = Vector2.new(0.5, 1)
        dangerArc.Position = UDim2.new(0.5, 0, 0.5, 0)
        dangerArc.BackgroundColor3 = NEEDLE_DANGER
        dangerArc.BackgroundTransparency = 0.3
        dangerArc.BorderSizePixel = 0
        dangerArc.Rotation = (dangerStartAngle + dangerEndAngle) / 2 + 90
        dangerArc.Parent = face
    end

    -- Needle (brass-gold)
    local needleLength = faceSize * 0.38
    local needle = Instance.new("Frame")
    needle.Name = "Needle"
    needle.AnchorPoint = Vector2.new(0.5, 1)  -- pivot at bottom center
    needle.Size = UDim2.new(0, 3, 0, needleLength)
    needle.Position = UDim2.new(0.5, 0, 0.5, 2)
    needle.BackgroundColor3 = NEEDLE_COLOR
    needle.BorderSizePixel = 0
    needle.Rotation = tickStartAngle + 90  -- start at min
    needle.ZIndex = 5
    needle.Parent = face

    -- Needle tip (triangle effect via small frame)
    local needleTip = Instance.new("Frame")
    needleTip.Name = "NeedleTip"
    needleTip.Size = UDim2.new(0, 1, 0, 4)
    needleTip.Position = UDim2.new(0.5, -0.5, 0, -4)
    needleTip.BackgroundColor3 = NEEDLE_COLOR
    needleTip.BorderSizePixel = 0
    needleTip.Parent = needle

    -- Center cap (brass dot where needle pivots)
    local capSize = 10
    local cap = Instance.new("Frame")
    cap.Name = "CenterCap"
    cap.Size = UDim2.new(0, capSize, 0, capSize)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.Position = UDim2.new(0.5, 0, 0.5, 0)
    cap.BackgroundColor3 = BRASS_LIGHT
    cap.BorderSizePixel = 0
    cap.ZIndex = 6
    cap.Parent = face

    local capCorner = Instance.new("UICorner")
    capCorner.CornerRadius = UDim.new(1, 0)
    capCorner.Parent = cap

    local capGradient = Instance.new("UIGradient")
    capGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, BRASS_LIGHT),
        ColorSequenceKeypoint.new(1, BRASS_SHADOW),
    })
    capGradient.Parent = cap

    -- Label (gauge name)
    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.Size = UDim2.new(1, 0, 0, 14)
    label.Position = UDim2.new(0, 0, 1, -16)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gibson
    label.TextSize = 11
    label.TextColor3 = TEXT_COLOR
    label.Text = string.upper(config.label or name)
    label.Parent = container

    -- Value readout (digital text)
    local valueLabel = Instance.new("TextLabel")
    valueLabel.Name = "ValueReadout"
    valueLabel.Size = UDim2.new(0, 50, 0, 14)
    valueLabel.Position = UDim2.new(0.5, -25, 0, size * 0.5)
    valueLabel.BackgroundTransparency = 1
    valueLabel.Font = Enum.Font.RobotoMono
    valueLabel.TextSize = 12
    valueLabel.TextColor3 = TEXT_COLOR
    valueLabel.Text = "--"
    valueLabel.ZIndex = 7
    valueLabel.Parent = face

    return {
        container = container,
        needle = needle,
        label = label,
        valueLabel = valueLabel,
        config = config,
        tickStartAngle = tickStartAngle,
        tickSpan = tickSpan,
    }
end

----------------------------------------------------------------
-- INTERNAL: NEEDLE UPDATE
----------------------------------------------------------------

--[[
    Set a gauge's needle to a specific value with a slight mechanical jitter.

    @param gauge table — gauge data from createGauge
    @param value number — the value to display
    @param unit string? — optional unit suffix for the digital readout
]]
local function setGaugeValue(gauge, value, unit)
    if not gauge then return end

    local config = gauge.config
    value = math.clamp(value, config.min, config.max)

    -- Map value to angle
    local ratio = (value - config.min) / (config.max - config.min)
    local angle = gauge.tickStartAngle + gauge.tickSpan * ratio

    -- Add slight mechanical jitter (gauges are old, hand-built)
    local jitter = (math.random() - 0.5) * 0.8
    angle = angle + jitter

    gauge.needle.Rotation = angle + 90

    -- Update digital readout
    local displayValue = value
    if config.decimals then
        displayValue = string.format("%." .. config.decimals .. "f", value)
    else
        displayValue = string.format("%.0f", value)
    end
    gauge.valueLabel.Text = displayValue .. (unit or config.unit or "")

    -- Color the readout if in danger zone
    if config.dangerZone and value >= config.dangerZone.start and value <= config.dangerZone.stop then
        gauge.valueLabel.TextColor3 = WARNING_COLOR
    else
        gauge.valueLabel.TextColor3 = TEXT_COLOR
    end
end

----------------------------------------------------------------
-- INTERNAL: BAR INDICATOR (for hull and cargo)
----------------------------------------------------------------

--[[
    Create a horizontal bar indicator (like a fuel gauge) with brass styling.
    @param name string
    @param parent Instance
    @param position UDim2
    @param width number
    @param config table — { label, min, max, unit }
    @return table — { frame, fill, label, valueLabel }
]]
local function createBar(name, parent, position, width, config)
    local container = Instance.new("Frame")
    container.Name = name .. "Bar"
    container.Size = UDim2.new(0, width, 0, 40)
    container.Position = position
    container.BackgroundColor3 = BG_PANEL_ACCENT
    container.BorderSizePixel = 0
    container.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 3)
    corner.Parent = container

    -- Label
    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.Size = UDim2.new(0, 60, 1, 0)
    label.Position = UDim2.new(0, 6, 0, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gibson
    label.TextSize = 10
    label.TextColor3 = TEXT_COLOR
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = string.upper(config.label or name)
    label.Parent = container

    -- Bar background (the track)
    local barBg = Instance.new("Frame")
    barBg.Name = "BarBg"
    barBg.Size = UDim2.new(1, -110, 0, 12)
    barBg.Position = UDim2.new(0, 68, 0.5, -6)
    barBg.BackgroundColor3 = Color3.fromRGB(15, 18, 20)
    barBg.BorderSizePixel = 0
    barBg.Parent = container

    local bgCorner = Instance.new("UICorner")
    bgCorner.CornerRadius = UDim.new(0, 2)
    bgCorner.Parent = barBg

    -- Fill
    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.Size = UDim2.new(0.5, 0, 1, 0)
    fill.BackgroundColor3 = GOOD_COLOR
    fill.BorderSizePixel = 0
    fill.Parent = barBg

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 2)
    fillCorner.Parent = fill

    -- Value label
    local valueLabel = Instance.new("TextLabel")
    valueLabel.Name = "ValueLabel"
    valueLabel.Size = UDim2.new(0, 40, 1, 0)
    valueLabel.Position = UDim2.new(1, -42, 0, 0)
    valueLabel.BackgroundTransparency = 1
    valueLabel.Font = Enum.Font.RobotoMono
    valueLabel.TextSize = 11
    valueLabel.TextColor3 = TEXT_COLOR
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.Text = "--"
    valueLabel.Parent = container

    return {
        frame = container,
        fill = fill,
        label = label,
        valueLabel = valueLabel,
        config = config,
    }
end

----------------------------------------------------------------
-- INTERNAL: BUILD PANEL
----------------------------------------------------------------

--[[
    Build the full instrument panel GUI. Creates the panel container
    with all gauges and bars.
]]
local function buildPanel()
    local playerGui = player:WaitForChild("PlayerGui")

    -- Create or reuse ScreenGui
    local gui = playerGui:FindFirstChild("LucineerInstruments")
    if not gui then
        gui = Instance.new("ScreenGui")
        gui.Name = "LucineerInstruments"
        gui.ResetOnSpawn = false
        gui.IgnoreGuiInset = true
        gui.DisplayOrder = 50
        gui.Parent = playerGui
    end
    InstrumentPanel._screenGui = gui

    -- Main panel container (bottom-right of screen)
    local panel = Instance.new("Frame")
    panel.Name = "InstrumentPanel"
    panel.Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT)
    panel.Position = UDim2.new(1, -PANEL_WIDTH - 16, 1, -PANEL_HEIGHT - 16)
    panel.BackgroundColor3 = BG_PANEL
    panel.BackgroundTransparency = 0.1
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.Parent = gui

    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 8)
    panelCorner.Parent = panel

    -- Brass accent border (top)
    local accent = Instance.new("Frame")
    accent.Name = "AccentBorder"
    accent.Size = UDim2.new(1, 0, 0, 2)
    accent.Position = UDim2.new(0, 0, 0, 0)
    accent.BackgroundColor3 = BRASS_DARK
    accent.BorderSizePixel = 0
    accent.Parent = panel

    local accentGradient = Instance.new("UIGradient")
    accentGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, BRASS_SHADOW),
        ColorSequenceKeypoint.new(0.5, BRASS_LIGHT),
        ColorSequenceKeypoint.new(1, BRASS_SHADOW),
    })
    accentGradient.Parent = accent

    -- Title bar
    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, 0, 0, 20)
    title.Position = UDim2.new(0, 0, 0, 4)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.Gibson
    title.TextSize = 11
    title.TextColor3 = BRASS_LIGHT
    title.Text = "SLACKWATER — VESSEL INSTRUMENTS"
    title.Parent = panel

    -- Clock label (top-right of panel)
    local clockLabel = Instance.new("TextLabel")
    clockLabel.Name = "Clock"
    clockLabel.Size = UDim2.new(0, 60, 0, 18)
    clockLabel.Position = UDim2.new(1, -66, 0, 4)
    clockLabel.BackgroundTransparency = 1
    clockLabel.Font = Enum.Font.RobotoMono
    clockLabel.TextSize = 13
    clockLabel.TextColor3 = BRASS_LIGHT
    clockLabel.TextXAlignment = Enum.TextXAlignment.Right
    clockLabel.Text = "00:00"
    clockLabel.Parent = panel
    InstrumentPanel._clockLabel = clockLabel

    -- ─── GAUGES ROW 1 (top) ──────────────────────────────
    -- Speed gauge
    InstrumentPanel._gauges.speed = createGauge("Speed", panel,
        UDim2.new(0, 20, 0, 30), GAUGE_SIZE, {
            min = 0, max = 50, label = "Speed",
            unit = " kn", tickCount = 10, tickInterval = 2,
            decimals = 1,
        })

    -- Heading (compass) gauge
    InstrumentPanel._gauges.heading = createGauge("Heading", panel,
        UDim2.new(0, 120, 0, 30), GAUGE_SIZE, {
            min = 0, max = 360, label = "Heading",
            unit = "°", tickCount = 12, tickInterval = 3,
            decimals = 0,
        })

    -- Depth gauge (CRITICAL — danger zone below 3 fathoms)
    InstrumentPanel._gauges.depth = createGauge("Depth", panel,
        UDim2.new(0, 220, 0, 30), GAUGE_SIZE, {
            min = 0, max = 50, label = "Depth",
            unit = " fm", tickCount = 10, tickInterval = 2,
            dangerZone = { start = 0, stop = 3 },  -- shallow = danger
            decimals = 1,
        })

    -- RPM gauge
    InstrumentPanel._gauges.rpm = createGauge("RPM", panel,
        UDim2.new(0, 320, 0, 30), SMALL_GAUGE_SIZE, {
            min = 0, max = 3000, label = "RPM",
            unit = "", tickCount = 6, tickInterval = 2,
            dangerZone = { start = 2400, stop = 3000 },
            decimals = 0,
        })

    -- ─── GAUGES ROW 2 (middle) ──────────────────────────
    -- Throttle gauge
    InstrumentPanel._gauges.throttle = createGauge("Throttle", panel,
        UDim2.new(0, 20, 0, 140), SMALL_GAUGE_SIZE, {
            min = 0, max = 100, label = "Throttle",
            unit = "%", tickCount = 10, tickInterval = 2,
            decimals = 0,
        })

    -- Rudder angle gauge
    InstrumentPanel._gauges.rudder = createGauge("Rudder", panel,
        UDim2.new(0, 110, 0, 140), SMALL_GAUGE_SIZE, {
            min = -35, max = 35, label = "Rudder",
            unit = "°", tickCount = 14, tickInterval = 2,
            decimals = 0,
        })

    -- ─── BARS ROW (bottom) ──────────────────────────────
    -- Hull integrity bar
    InstrumentPanel._hullBar = createBar("Hull", panel,
        UDim2.new(0, 200, 0, 140), 200, {
            label = "Hull", min = 0, max = 100, unit = "%",
        })

    -- Cargo bar
    InstrumentPanel._cargoBar = createBar("Cargo", panel,
        UDim2.new(0, 200, 0, 180), 200, {
            label = "Cargo", min = 0, max = 100, unit = "%",
        })

    InstrumentPanel._panel = panel
end

----------------------------------------------------------------
-- INTERNAL: READ VESSEL DATA
----------------------------------------------------------------

--[[
    Read vessel telemetry from workspace attributes.
    The vessel model is expected to have these attributes set on its
    PrimaryPart (or on a child named "Telemetry").

    Falls back to 0/default values when no vessel is present.
    @return table telemetry
]]
local function readVesselTelemetry()
    -- Try to find the active vessel from workspace attribute
    local vesselRef = Workspace:GetAttribute("ActiveVessel")
    local vesselModel = nil
    if vesselRef then
        -- Find the model by name
        vesselModel = Workspace:FindFirstChild(vesselRef)
    end

    -- Also try the VisionController's vessel root if available
    local telemetrySource = nil
    if vesselModel and vesselModel:IsA("Model") then
        telemetrySource = vesselModel.PrimaryPart or vesselModel:FindFirstChild("Hull")
    end

    if not telemetrySource then
        -- Try any tagged "ActiveVessel" part
        local CollectionService = game:GetService("CollectionService")
        local tagged = CollectionService:GetTagged("ActiveVessel")
        if #tagged > 0 then
            telemetrySource = tagged[1]
        end
    end

    local t = {
        speed = 0,
        heading = 0,
        depth = 0,
        throttle = 0,
        rudder = 0,
        rpm = 0,
        hullIntegrity = 100,
        cargoWeight = 0,
        cargoMax = 100,
    }

    if telemetrySource then
        t.speed = telemetrySource:GetAttribute("Speed") or 0
        t.heading = telemetrySource:GetAttribute("Heading") or 0
        t.depth = telemetrySource:GetAttribute("Depth") or 0
        t.throttle = telemetrySource:GetAttribute("Throttle") or 0
        t.rudder = telemetrySource:GetAttribute("RudderAngle") or 0
        t.rpm = telemetrySource:GetAttribute("EngineRPM") or 0
        t.hullIntegrity = telemetrySource:GetAttribute("HullIntegrity") or 100
        t.cargoWeight = telemetrySource:GetAttribute("CargoWeight") or 0
        t.cargoMax = telemetrySource:GetAttribute("CargoMax") or 100
    end

    return t
end

----------------------------------------------------------------
-- INTERNAL: UPDATE GAUGES
----------------------------------------------------------------

--[[
    Update all gauges with current vessel telemetry and time.
]]
local function updateGauges()
    local t = readVesselTelemetry()

    -- Convert studs/sec to knots (1 knot ≈ 1.15 mph, 1 stud ≈ 0.28 meters)
    -- For gameplay: 1 knot ≈ 2 studs/sec at this scale
    local knots = t.speed / 2

    setGaugeValue(InstrumentPanel._gauges.speed, knots, " kn")
    setGaugeValue(InstrumentPanel._gauges.heading, t.heading, "°")
    setGaugeValue(InstrumentPanel._gauges.depth, t.depth, " fm")
    setGaugeValue(InstrumentPanel._gauges.rpm, t.rpm, "")
    setGaugeValue(InstrumentPanel._gauges.throttle, t.throttle, "%")
    setGaugeValue(InstrumentPanel._gauges.rudder, t.rudder, "°")

    -- Hull bar
    if InstrumentPanel._hullBar then
        local hullPct = t.hullIntegrity / 100
        InstrumentPanel._hullBar.fill.Size = UDim2.new(hullPct, 0, 1, 0)

        local hullText = string.format("%.0f%%", t.hullIntegrity)
        InstrumentPanel._hullBar.valueLabel.Text = hullText

        -- Color: green > 60%, yellow 30-60%, red < 30%
        if t.hullIntegrity > 60 then
            InstrumentPanel._hullBar.fill.BackgroundColor3 = GOOD_COLOR
        elseif t.hullIntegrity > 30 then
            InstrumentPanel._hullBar.fill.BackgroundColor3 = Color3.fromRGB(200, 170, 80)
        else
            InstrumentPanel._hullBar.fill.BackgroundColor3 = WARNING_COLOR
        end
    end

    -- Cargo bar
    if InstrumentPanel._cargoBar then
        local cargoPct = 0
        if t.cargoMax > 0 then
            cargoPct = t.cargoWeight / t.cargoMax
        end
        InstrumentPanel._cargoBar.fill.Size = UDim2.new(math.clamp(cargoPct, 0, 1), 0, 1, 0)
        InstrumentPanel._cargoBar.valueLabel.Text = string.format("%d/%d", t.cargoWeight, t.cargoMax)

        -- Color: brass-ish normally, brighter when full
        local cargoColor = BRASS_LIGHT
        if cargoPct >= 1.0 then
            cargoColor = Color3.fromRGB(220, 180, 100)
        end
        InstrumentPanel._cargoBar.fill.BackgroundColor3 = cargoColor
    end
end

--[[
    Update the in-game clock display.
]]
local function updateClock()
    if not InstrumentPanel._clockLabel then return end
    local clockTime = Lighting.ClockTime
    local hours = math.floor(clockTime) % 24
    local minutes = math.floor((clockTime % 1) * 60)
    InstrumentPanel._clockLabel.Text = string.format("%02d:%02d", hours, minutes)
end

----------------------------------------------------------------
-- INTERNAL: VISIBILITY MANAGEMENT
----------------------------------------------------------------

--[[
    Show or hide the instrument panel based on whether the player
    is at the helm. Checks the player's seated state.
]]
local function updateVisibility()
    local character = player.Character
    if not character then
        InstrumentPanel._visible = false
        if InstrumentPanel._panel then
            InstrumentPanel._panel.Visible = false
        end
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    local CollectionService = game:GetService("CollectionService")
    local seatPart = humanoid.SeatPart

    if seatPart and CollectionService:HasTag(seatPart, "HelmSeat") then
        -- Player is at the helm — show instruments
        if not InstrumentPanel._visible then
            InstrumentPanel._visible = true
            if InstrumentPanel._panel then
                InstrumentPanel._panel.Visible = true
                -- Slide-in animation
                InstrumentPanel._panel.Position = UDim2.new(1, -PANEL_WIDTH + 50, 1, -PANEL_HEIGHT - 16)
                TweenService:Create(
                    InstrumentPanel._panel,
                    TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
                    { Position = UDim2.new(1, -PANEL_WIDTH - 16, 1, -PANEL_HEIGHT - 16) }
                ):Play()
            end
        end
    else
        -- Not at helm — hide instruments
        if InstrumentPanel._visible then
            InstrumentPanel._visible = false
            if InstrumentPanel._panel then
                -- Slide-out animation
                TweenService:Create(
                    InstrumentPanel._panel,
                    TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
                    { Position = UDim2.new(1, -PANEL_WIDTH + 50, 1, -PANEL_HEIGHT - 16) }
                ):Play()
                task.delay(0.35, function()
                    if InstrumentPanel._panel and not InstrumentPanel._visible then
                        InstrumentPanel._panel.Visible = false
                    end
                end)
            end
        end
    end
end

----------------------------------------------------------------
-- HEARTBEAT LOOP
----------------------------------------------------------------

local _gaugeTimer = 0
local _visibilityTimer = 0

local function onHeartbeat(dt)
    -- Update gauges every 0.1s (10 fps for instruments — feels mechanical)
    _gaugeTimer = _gaugeTimer + dt
    if _gaugeTimer > 0.1 then
        _gaugeTimer = 0
        updateGauges()
        updateClock()
    end

    -- Check visibility every 0.5s
    _visibilityTimer = _visibilityTimer + dt
    if _visibilityTimer > 0.5 then
        _visibilityTimer = 0
        updateVisibility()
    end
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the InstrumentPanel. Builds the GUI and connects heartbeat.
    Call once on game start.
]]
function InstrumentPanel.init()
    if InstrumentPanel._initialized then
        warn("[InstrumentPanel] Already initialized.")
        return
    end

    buildPanel()

    InstrumentPanel._heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

    InstrumentPanel._initialized = true
    print("[InstrumentPanel] Initialized — analog marine gauges ready.")
end

--[[
    Force-show the panel (for testing or cinematics).
]]
function InstrumentPanel.show()
    if InstrumentPanel._panel then
        InstrumentPanel._panel.Visible = true
        InstrumentPanel._visible = true
    end
end

--[[
    Force-hide the panel.
]]
function InstrumentPanel.hide()
    if InstrumentPanel._panel then
        InstrumentPanel._panel.Visible = false
        InstrumentPanel._visible = false
    end
end

--[[
    Manually set a gauge value (for testing or scripted events).
    @param gaugeName string — "speed", "heading", "depth", "rpm", "throttle", "rudder"
    @param value number
]]
function InstrumentPanel.setGaugeValue(gaugeName, value)
    local gauge = InstrumentPanel._gauges[gaugeName]
    if gauge then
        setGaugeValue(gauge, value)
    end
end

--[[
    Clean up the instrument panel.
]]
function InstrumentPanel.shutdown()
    if InstrumentPanel._heartbeatConn then
        InstrumentPanel._heartbeatConn:Disconnect()
        InstrumentPanel._heartbeatConn = nil
    end
    if InstrumentPanel._screenGui then
        InstrumentPanel._screenGui:Destroy()
        InstrumentPanel._screenGui = nil
    end
    InstrumentPanel._panel = nil
    InstrumentPanel._gauges = {}
    InstrumentPanel._initialized = false
    print("[InstrumentPanel] Shut down.")
end

return InstrumentPanel
