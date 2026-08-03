--!strict
--[[
    VibeCoder — Slackwater's Vibe-Coding Interface (Client-Side)
    =============================================================
    The "Slack-Pad" — a diegetic in-game tablet that lets players
    describe what they want in natural language and receive gamified
    code that "just works" when deployed to devices.

    Era requirement: Era 4 (Programmable Logic) or higher.

    Flow:
        1. Player presses hotkey (V) or interacts with Coder agent
        2. Slack-Pad GUI opens with split-pane layout
        3. Player types or speaks (STT hook) their request
        4. Request sent to Worker → processor → DeepInfra (Qwen3-Coder)
        5. Gamified code object returned and displayed on Code Canvas
        6. Player reviews, then deploys to a target device
        7. Server-side VibeCodeExecutor validates and executes

    Usage:
        local VibeCoder = require(ReplicatedStorage.Lucineer.VibeCoder)
        VibeCoder.init()
        -- Player presses V → GUI opens automatically
        -- Or: VibeCoder.open(player)

    Dependencies:
        - ReplicatedStorage.Lucineer.Http
        - ReplicatedStorage.Lucineer.Config
        - ReplicatedStorage.Lucineer.VibeCoderDialogue
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Http = require(script.Parent.Http)
local Config = require(script.Parent.Config)

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local HOTKEY = Enum.KeyCode.V
local SLACK_PAD_NAME = "SlackPad"
local ERA_REQUIRED = 4 -- Programmable Logic

-- Slack-Pad visual theme (retro-futuristic terminal)
local THEME = {
    bg          = Color3.fromRGB(12, 18, 28),
    bgPanel     = Color3.fromRGB(18, 26, 40),
    bgInput     = Color3.fromRGB(8, 14, 22),
    accent      = Color3.fromRGB(0, 255, 170),      -- cyan-green
    accentDim   = Color3.fromRGB(0, 140, 95),
    accentWarn  = Color3.fromRGB(255, 180, 0),       -- amber
    accentError = Color3.fromRGB(255, 70, 70),
    text        = Color3.fromRGB(220, 230, 240),
    textDim     = Color3.fromRGB(130, 145, 160),
    textCode    = Color3.fromRGB(120, 220, 180),     -- green-ish for code
    textKey     = Color3.fromRGB(100, 180, 255),     -- blue for keywords
    textComment = Color3.fromRGB(100, 110, 120),     -- grey for comments
    textStr     = Color3.fromRGB(255, 200, 100),     -- amber for strings
    textNum     = Color3.fromRGB(200, 130, 255),     -- purple for numbers
    border      = Color3.fromRGB(30, 45, 65),
    glitchColor = Color3.fromRGB(0, 255, 200),
}

-- Syntax highlighting keyword set (Lua-ish / SlackScript)
local KEYWORDS = {
    ["if"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["for"] = true, ["while"] = true, ["do"] = true,
    ["function"] = true, ["return"] = true, ["local"] = true,
    ["and"] = true, ["or"] = true, ["not"] = true,
    ["WHEN"] = true, ["LOOP"] = true, ["ON"] = true,
    ["START_TIMER"] = true, ["BROADCAST"] = true,
    ["true"] = true, ["false"] = true, ["nil"] = true,
    ["device"] = true, ["trigger"] = true, ["action"] = true,
    ["powerRequired"] = true, ["eraRequired"] = true,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

local VibeCoder = {}

local isInitialized = false
local guiOpen = false
local slackPadGui = nil          -- ScreenGui
local leftPane = nil             -- Vibe Stream (chat)
local rightPane = nil            -- Code Canvas
local inputBox = nil             -- TextBox for typing
local chatHistory = nil          -- ScrollingFrame for messages
local codeDisplay = nil          -- ScrollingFrame for code
local statusLabel = nil          -- Bottom status bar
local deployButton = nil         -- "Deploy to Hardware" button
local deepDiveButton = nil       -- "Real Code" toggle button
local exportButton = nil         -- "Export to Real World" button
local targetDevice = nil         -- Currently targeted device (Instance or name)
local lastVibeCode = nil         -- Last received code object
local isProcessing = false       -- Waiting for Worker response
local remoteEvent = nil          -- RemoteEvent for server communication

-- ═══════════════════════════════════════════════════════════════════════════
-- REMOTE EVENT SETUP
-- ═══════════════════════════════════════════════════════════════════════════

local function ensureRemoteEvent()
    local replicated = ReplicatedStorage:WaitForChild("Lucineer")
    local remote = replicated:FindFirstChild("VibeCodeRemote")

    if not remote then
        remote = Instance.new("RemoteEvent")
        remote.Name = "VibeCodeRemote"
        remote.Parent = replicated
    end

    return remote
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UI CONSTRUCTION
-- ═══════════════════════════════════════════════════════════════════════════

-- Helper: create a UIStroke (border)
local function addBorder(parent, color, thickness)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color or THEME.border
    stroke.Thickness = thickness or 1
    stroke.Parent = parent
    return stroke
end

-- Helper: create a UICorner
local function addCorner(parent, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 6)
    corner.Parent = parent
    return corner
end

-- Helper: create a text label
local function makeLabel(parent, text, size, color, font)
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = size or UDim2.new(1, 0, 0, 20)
    label.Position = UDim2.new(0, 0, 0, 0)
    label.Font = font or Enum.Font.Code
    label.Text = text
    label.TextColor3 = color or THEME.text
    label.TextSize = 14
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.Parent = parent
    return label
end

-- Build the top bar
local function buildTopBar(parent)
    local bar = Instance.new("Frame")
    bar.Name = "TopBar"
    bar.Size = UDim2.new(1, 0, 0, 36)
    bar.Position = UDim2.new(0, 0, 0, 0)
    bar.BackgroundColor3 = THEME.bgPanel
    bar.BorderSizePixel = 0
    bar.Parent = parent
    addCorner(bar, 6)

    -- Glitch avatar (pixel-art style placeholder)
    local glitch = Instance.new("TextLabel")
    glitch.Name = "GlitchAvatar"
    glitch.Size = UDim2.new(0, 28, 0, 28)
    glitch.Position = UDim2.new(0, 8, 0, 4)
    glitch.BackgroundColor3 = THEME.bg
    glitch.Text = "Ġ"
    glitch.Font = Enum.Font.Code
    glitch.TextSize = 18
    glitch.TextColor3 = THEME.glitchColor
    glitch.Parent = bar
    addCorner(glitch, 4)
    addBorder(glitch, THEME.accent, 1)

    -- Title
    makeLabel(bar, "SLACK-PAD v2.7", UDim2.new(0, 200, 0, 20), THEME.accent)
        .Position = UDim2.new(0, 42, 0, 4)
    makeLabel(bar, "Coder Agent: Glitch", UDim2.new(0, 200, 0, 14), THEME.textDim, Enum.Font.Code)
        .Position = UDim2.new(0, 42, 0, 18)

    -- Target reticle status
    local targetLabel = Instance.new("TextLabel")
    targetLabel.Name = "TargetStatus"
    targetLabel.BackgroundTransparency = 1
    targetLabel.Size = UDim2.new(0, 300, 0, 16)
    targetLabel.Position = UDim2.new(1, -308, 0, 10)
    targetLabel.Font = Enum.Font.Code
    targetLabel.Text = "Target: [None] | Pins: 0/0"
    targetLabel.TextColor3 = THEME.textDim
    targetLabel.TextSize = 12
    targetLabel.TextXAlignment = Enum.TextXAlignment.Right
    targetLabel.Parent = bar

    return bar, targetLabel
end

-- Build the left pane (Vibe Stream — chat interface)
local function buildLeftPane(parent)
    local pane = Instance.new("Frame")
    pane.Name = "LeftPane"
    pane.Size = UDim2.new(0.5, -4, 1, -44)
    pane.Position = UDim2.new(0, 4, 0, 40)
    pane.BackgroundColor3 = THEME.bgPanel
    pane.BorderSizePixel = 0
    pane.Parent = parent
    addCorner(pane, 6)
    addBorder(pane, THEME.border, 1)

    -- Chat scroll frame
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "ChatHistory"
    scroll.Size = UDim2.new(1, -12, 1, -58)
    scroll.Position = UDim2.new(0, 6, 0, 6)
    scroll.BackgroundTransparency = 1
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = THEME.accentDim
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.Parent = pane

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = scroll

    -- Input box
    local input = Instance.new("TextBox")
    input.Name = "InputBox"
    input.Size = UDim2.new(1, -12, 0, 40)
    input.Position = UDim2.new(0, 6, 1, -46)
    input.BackgroundColor3 = THEME.bgInput
    input.Text = ""
    input.PlaceholderText = "Type your vibe or hold [V] to speak..."
    input.Font = Enum.Font.Code
    input.TextSize = 14
    input.TextColor3 = THEME.text
    input.PlaceholderColor3 = THEME.textDim
    input.ClearTextOnFocus = false
    input.TextXAlignment = Enum.TextXAlignment.Left
    input.TextYAlignment = Enum.TextYAlignment.Top
    input.Parent = pane
    addCorner(input, 4)
    addBorder(input, THEME.accentDim, 1)

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingTop = UDim.new(0, 6)
    padding.Parent = input

    return pane, scroll, input
end

-- Build the right pane (Code Canvas)
local function buildRightPane(parent)
    local pane = Instance.new("Frame")
    pane.Name = "RightPane"
    pane.Size = UDim2.new(0.5, -4, 1, -44)
    pane.Position = UDim2.new(0.5, 0, 0, 40)
    pane.BackgroundColor3 = THEME.bgPanel
    pane.BorderSizePixel = 0
    pane.Parent = parent
    addCorner(pane, 6)
    addBorder(pane, THEME.border, 1)

    -- Toggle buttons at top
    local toggleBar = Instance.new("Frame")
    toggleBar.Name = "ToggleBar"
    toggleBar.Size = UDim2.new(1, -12, 0, 28)
    toggleBar.Position = UDim2.new(0, 6, 0, 6)
    toggleBar.BackgroundTransparency = 1
    toggleBar.Parent = pane

    local toggleLayout = Instance.new("UIListLayout")
    toggleLayout.FillDirection = Enum.FillDirection.Horizontal
    toggleLayout.Padding = UDim.new(0, 4)
    toggleLayout.Parent = toggleBar

    local function makeToggle(text, isActive)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 120, 0, 24)
        btn.BackgroundColor3 = isActive and THEME.accentDim or THEME.bgInput
        btn.Text = text
        btn.Font = Enum.Font.Code
        btn.TextSize = 11
        btn.TextColor3 = isActive and THEME.text or THEME.textDim
        btn.BorderSizePixel = 0
        btn.Parent = toggleBar
        addCorner(btn, 4)
        return btn
    end

    local vibeBtn = makeToggle("VIBE MODE", true)
    local realCodeBtn = makeToggle("REAL CODE (C++)")
    local pythonBtn = makeToggle("REAL CODE (PY)")

    -- Code scroll frame
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "CodeDisplay"
    scroll.Size = UDim2.new(1, -12, 1, -84)
    scroll.Position = UDim2.new(0, 6, 0, 38)
    scroll.BackgroundTransparency = 1
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = THEME.accentDim
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.Parent = pane

    local codeLayout = Instance.new("UIListLayout")
    codeLayout.Padding = UDim.new(0, 2)
    codeLayout.SortOrder = Enum.SortOrder.LayoutOrder
    codeLayout.Parent = scroll

    -- Action buttons at bottom
    local actionBar = Instance.new("Frame")
    actionBar.Name = "ActionBar"
    actionBar.Size = UDim2.new(1, -12, 0, 36)
    actionBar.Position = UDim2.new(0, 6, 1, -42)
    actionBar.BackgroundTransparency = 1
    actionBar.Parent = pane

    local actionLayout = Instance.new("UIListLayout")
    actionLayout.FillDirection = Enum.FillDirection.Horizontal
    actionLayout.Padding = UDim.new(0, 4)
    actionLayout.Parent = actionBar

    local function makeActionBtn(text, color)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 100, 0, 32)
        btn.BackgroundColor3 = THEME.bgInput
        btn.Text = text
        btn.Font = Enum.Font.Code
        btn.TextSize = 12
        btn.TextColor3 = color or THEME.text
        btn.BorderSizePixel = 0
        btn.Parent = actionBar
        addCorner(btn, 4)
        addBorder(btn, color or THEME.border, 1)
        return btn
    end

    local deploy = makeActionBtn("⚡ DEPLOY", THEME.accent)
    local deepDive = makeActionBtn("📖 DEEP DIVE", THEME.textKey)
    local exportBtn = makeActionBtn("📤 EXPORT", THEME.accentWarn)

    return pane, scroll, vibeBtn, realCodeBtn, pythonBtn, deploy, deepDive, exportBtn
end

-- Build the bottom status bar
local function buildStatusBar(parent)
    local bar = Instance.new("Frame")
    bar.Name = "StatusBar"
    bar.Size = UDim2.new(1, 0, 0, 24)
    bar.Position = UDim2.new(0, 0, 1, -24)
    bar.BackgroundColor3 = THEME.bgPanel
    bar.BorderSizePixel = 0
    bar.Parent = parent

    local status = makeLabel(bar, "● Ready", UDim2.new(0, 200, 0, 16), THEME.accent)
    status.Position = UDim2.new(0, 8, 0, 4)

    local eraInfo = makeLabel(bar, "Era 4: Programmable Logic", UDim2.new(0, 300, 0, 16), THEME.textDim)
    eraInfo.Position = UDim2.new(1, -308, 0, 4)
    eraInfo.TextXAlignment = Enum.TextXAlignment.Right

    return bar, status
end

-- Build the complete Slack-Pad GUI
local function buildSlackPad()
    local player = Players.LocalPlayer
    local playerGui = player:WaitForChild("PlayerGui")

    -- Remove existing if present
    local existing = playerGui:FindFirstChild(SLACK_PAD_NAME)
    if existing then
        existing:Destroy()
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = SLACK_PAD_NAME
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 100

    -- Main container (centered, 800x540)
    local container = Instance.new("Frame")
    container.Name = "Container"
    container.Size = UDim2.new(0, 800, 0, 540)
    container.Position = UDim2.new(0.5, -400, 0.5, -270)
    container.BackgroundColor3 = THEME.bg
    container.BorderSizePixel = 0
    container.Visible = false
    container.Parent = gui
    addCorner(container, 8)
    addBorder(container, THEME.accentDim, 2)

    -- Build sections
    local topBar, targetStatus = buildTopBar(container)
    leftPane, chatHistory, inputBox = buildLeftPane(container)
    rightPane, codeDisplay, deployButton, deepDiveButton, exportButton = buildRightPane(container)
    -- Fix: buildRightPane returns (pane, scroll, vibeBtn, realCodeBtn, pythonBtn, deploy, deepDive, exportBtn)
    -- Need to recapture properly
    rightPane, codeDisplay = nil, nil
    local _, codeScroll, vBtn, rcBtn, pyBtn, deploy, deepDive, exportBtn2 = buildRightPane(container)
    rightPane = nil
    codeDisplay = codeScroll
    deployButton = deploy
    deepDiveButton = deepDive
    exportButton = exportBtn2

    local statusBar
    statusBar, statusLabel = buildStatusBar(container)

    -- Close button (X in top-right of top bar)
    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseButton"
    closeBtn.Size = UDim2.new(0, 24, 0, 24)
    closeBtn.Position = UDim2.new(1, -28, 0, 6)
    closeBtn.BackgroundColor3 = THEME.bgInput
    closeBtn.Text = "✕"
    closeBtn.Font = Enum.Font.Code
    closeBtn.TextSize = 14
    closeBtn.TextColor3 = THEME.accentError
    closeBtn.BorderSizePixel = 0
    closeBtn.Parent = container:WaitForChild("TopBar")
    addCorner(closeBtn, 4)

    gui.Parent = playerGui

    return gui, container, closeBtn, targetStatus
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CHAT MESSAGE RENDERING
-- ═══════════════════════════════════════════════════════════════════════════

-- Add a message to the Vibe Stream chat panel
function VibeCoder.addMessage(role, text)
    if not chatHistory then return end

    local msg = Instance.new("TextLabel")
    msg.BackgroundTransparency = 1
    msg.Size = UDim2.new(1, -4, 0, 0)
    msg.AutomaticSize = Enum.AutomaticSize.Y
    msg.TextWrapped = true
    msg.Font = Enum.Font.Code
    msg.TextSize = 13
    msg.TextXAlignment = Enum.TextXAlignment.Left
    msg.TextYAlignment = Enum.TextYAlignment.Top

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.PaddingTop = UDim.new(0, 4)
    padding.PaddingBottom = UDim.new(0, 4)
    padding.Parent = msg

    if role == "player" then
        msg.Text = "» " .. text
        msg.TextColor3 = THEME.text
    elseif role == "glitch" then
        msg.Text = "Ġ " .. text
        msg.TextColor3 = THEME.accent
    elseif role == "system" then
        msg.Text = "[ " .. text .. " ]"
        msg.TextColor3 = THEME.textDim
    elseif role == "error" then
        msg.Text = "!! " .. text
        msg.TextColor3 = THEME.accentError
    end

    msg.Parent = chatHistory

    -- Auto-scroll to bottom
    task.defer(function()
        chatHistory.CanvasPosition = Vector2.new(0, math.huge)
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CODE CANVAS RENDERING (with syntax highlighting)
-- ═══════════════════════════════════════════════════════════════════════════

-- Tokenize a line of code for simple syntax highlighting
-- Returns a list of {text, color} segments
local function tokenizeLine(line)
    local segments = {}
    local i = 1
    local len = #line

    while i <= len do
        local ch = line:sub(i, i)

        -- Comment
        if line:sub(i, i + 1) == "--" then
            table.insert(segments, {text = line:sub(i), color = THEME.textComment})
            break
        end

        -- String (double or single quote)
        if ch == '"' or ch == "'" then
            local quote = ch
            local j = i + 1
            while j <= len and line:sub(j, j) ~= quote do
                j = j + 1
            end
            table.insert(segments, {text = line:sub(i, math.min(j, len)), color = THEME.textStr})
            i = j + 1
        else
            -- Word (identifier/keyword)
            if ch:match("[%a_]") then
                local j = i
                while j <= len and line:sub(j, j):match("[%w_]") do
                    j = j + 1
                end
                local word = line:sub(i, j - 1)
                if KEYWORDS[word] then
                    table.insert(segments, {text = word, color = THEME.textKey})
                elseif word:match("^%d") then
                    table.insert(segments, {text = word, color = THEME.textNum})
                else
                    table.insert(segments, {text = word, color = THEME.textCode})
                end
                i = j
            -- Number
            elseif ch:match("%d") then
                local j = i
                while j <= len and line:sub(j, j):match("[%d%.]") do
                    j = j + 1
                end
                table.insert(segments, {text = line:sub(i, j - 1), color = THEME.textNum})
                i = j
            -- Operator/punctuation
            else
                table.insert(segments, {text = ch, color = THEME.textDim})
                i = i + 1
            end
        end
    end

    return segments
end

-- Render code on the Code Canvas with syntax highlighting
function VibeCoder.renderCode(codeText)
    if not codeDisplay then return end

    -- Clear existing
    for _, child in ipairs(codeDisplay:GetChildren()) do
        if child:IsA("TextLabel") then
            child:Destroy()
        end
    end

    -- Split into lines
    local lines = string.split(codeText, "\n")

    for lineNum, line in ipairs(lines) do
        local segments = tokenizeLine(line)

        if #segments == 0 then
            -- Empty line
            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Size = UDim2.new(1, -4, 0, 16)
            label.Text = " "
            label.Font = Enum.Font.Code
            label.TextSize = 13
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.Parent = codeDisplay
        else
            -- Render using RichText
            local richText = ""
            for _, seg in ipairs(segments) do
                local hexColor = string.format("%02x%02x%02x",
                    math.floor(seg.Color.R * 255),
                    math.floor(seg.Color.G * 255),
                    math.floor(seg.Color.B * 255))
                -- Escape XML special characters in text
                local escaped = seg.text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
                richText = richText .. string.format('<font color="#%s">%s</font>', hexColor, escaped)
            end

            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Size = UDim2.new(1, -4, 0, 18)
            label.RichText = true
            label.Text = richText
            label.Font = Enum.Font.Code
            label.TextSize = 13
            label.TextColor3 = THEME.textCode
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.TextYAlignment = Enum.TextYAlignment.Top
            label.LayoutOrder = lineNum
            label.Parent = codeDisplay
        end
    end
end

-- Display a gamified code object as formatted Lua-like text
function VibeCoder.displayVibeCode(codeObj)
    lastVibeCode = codeObj

    -- Format the code object as readable SlackScript
    local lines = {}
    table.insert(lines, "-- Vibe-Code Generated by Glitch")
    table.insert(lines, "-- Request: " .. (codeObj.request or "unknown"))

    if codeObj.device then
        table.insert(lines, "")
        table.insert(lines, "device = \"" .. codeObj.device .. "\"")
    end

    if codeObj.trigger then
        table.insert(lines, "trigger = \"" .. codeObj.trigger .. "\"")
    end

    if codeObj.action then
        table.insert(lines, "action = \"" .. codeObj.action .. "\"")
    end

    if codeObj.conditions and #codeObj.conditions > 0 then
        table.insert(lines, "")
        table.insert(lines, "if " .. codeObj.conditions[1] .. " then")
        for i = 2, #codeObj.conditions do
            table.insert(lines, "  and " .. codeObj.conditions[i])
        end
        table.insert(lines, "  " .. (codeObj.action or "activate(device)"))
        table.insert(lines, "end")
    end

    if codeObj.loop then
        table.insert(lines, "")
        table.insert(lines, "while powered do")
        table.insert(lines, "  " .. (codeObj.trigger or "check_sensor()"))
        table.insert(lines, "  " .. (codeObj.action or "respond()"))
        table.insert(lines, "end")
    end

    if codeObj.powerRequired then
        table.insert(lines, "")
        table.insert(lines, "-- Power: " .. tostring(codeObj.powerRequired) .. " kW required")
    end

    if codeObj.eraRequired then
        local eraNames = {
            [0] = "Simple Machines", [1] = "Power Transmission",
            [2] = "Electricity", [3] = "Control Systems",
            [4] = "Programmable Logic", [5] = "Networked Systems",
            [6] = "Autonomous Agents",
        }
        local eraName = eraNames[codeObj.eraRequired] or "Unknown"
        table.insert(lines, "-- Era: " .. eraName .. " (Tier " .. tostring(codeObj.eraRequired) .. ")")
    end

    -- Build full code text
    local codeText = table.concat(lines, "\n")
    VibeCoder.renderCode(codeText)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WORKER COMMUNICATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Send a vibe-code request to the Worker for processing
function VibeCoder.sendRequest(message)
    if isProcessing then
        VibeCoder.addMessage("error", "Already processing a request. Wait for Glitch to finish.")
        return
    end

    isProcessing = true
    if statusLabel then
        statusLabel.Text = "◐ Glitch is thinking..."
        statusLabel.TextColor3 = THEME.accentWarn
    end

    VibeCoder.addMessage("player", message)

    -- Build request payload
    local payload = {
        playerName = Players.LocalPlayer.Name,
        message = message,
        sessionId = Config.SESSION_ID,
        commandType = "vibe_code",
        era = _G.Slackwater_CurrentEra or 4,
        availableComponents = _G.Slackwater_AvailableComponents or {},
        targetDevice = targetDevice and targetDevice.Name or nil,
    }

    -- Send via RemoteEvent to server (server validates era, then forwards to Worker)
    if remoteEvent then
        remoteEvent:FireServer("vibe_code_request", payload)
    else
        -- Fallback: direct HTTP (if server-side not available)
        local response, err = Http.post("/api/vibe-code", payload)

        if response and response.success then
            VibeCoder.handleResponse(response)
        else
            VibeCoder.addMessage("error", "Slack-Pad couldn't reach the relay. Check your connection.")
            if err then
                VibeCoder.addMessage("system", "Error: " .. err)
            end
        end
    end
end

-- Handle a response from the Worker (called by RemoteEvent or direct HTTP)
function VibeCoder.handleResponse(response)
    isProcessing = false

    if statusLabel then
        statusLabel.Text = "● Ready"
        statusLabel.TextColor3 = THEME.accent
    end

    if not response then
        VibeCoder.addMessage("error", "Empty response from Glitch. Something's off.")
        return
    end

    if response.error then
        -- In-character error handling
        local errorType = response.errorType or "generic"

        if errorType == "missing_hardware" then
            VibeCoder.addMessage("glitch",
                "I'd love to make that happen, boss, but my sensors say you're missing hardware: " ..
                response.error .. ". Craft one and wire it up first!")
        elseif errorType == "era_locked" then
            VibeCoder.addMessage("glitch",
                "Whoa, that's ahead of our tech level! You need to reach " ..
                response.error .. " before I can code that.")
        elseif errorType == "conflicting_logic" then
            VibeCoder.addMessage("glitch",
                "Hold on a cycle — " .. response.error ..
                " My circuits are tingling. Let's refine that logic.")
        else
            VibeCoder.addMessage("error", response.error)
        end
        return
    end

    -- Success — display the generated code
    local codeObj = response.code or response
    local glitchReply = response.reply or "Code compiled and ready to deploy!"

    VibeCoder.addMessage("glitch", glitchReply)
    VibeCoder.displayVibeCode(codeObj)

    -- Enable deploy button
    if deployButton then
        deployButton.BackgroundColor3 = THEME.accentDim
        deployButton.TextColor3 = THEME.text
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DEPLOYMENT
-- ═══════════════════════════════════════════════════════════════════════════

-- Deploy the current vibe-code to the target device (via server)
function VibeCoder.deploy()
    if not lastVibeCode then
        VibeCoder.addMessage("error", "No code to deploy. Vibe something first!")
        return
    end

    if not targetDevice then
        VibeCoder.addMessage("glitch",
            "I need a target device! Point the Slack-Pad at a machine and I'll flash its firmware.")
        return
    end

    VibeCoder.addMessage("system", "Deploying to " .. tostring(targetDevice.Name) .. "...")

    if statusLabel then
        statusLabel.Text = "⚡ Deploying..."
        statusLabel.TextColor3 = THEME.accentWarn
    end

    -- Send deploy command via RemoteEvent
    if remoteEvent then
        remoteEvent:FireServer("vibe_code_deploy", {
            code = lastVibeCode,
            targetDevice = targetDevice.Name,
            playerName = Players.LocalPlayer.Name,
        })
    end
end

-- Handle deploy result (called when server responds)
function VibeCoder.handleDeployResult(result)
    if statusLabel then
        statusLabel.Text = "● Ready"
        statusLabel.TextColor3 = THEME.accent
    end

    if result and result.success then
        VibeCoder.addMessage("glitch",
            "Deployed! " .. (result.message or "Your code is now running on the device."))
    else
        local reason = (result and result.reason) or "Unknown failure"
        if result and result.errorType == "era_locked" then
            VibeCoder.addMessage("glitch",
                "That device's firmware is beyond our current era. Progress further to unlock it!")
        elseif result and result.errorType == "no_power" then
            VibeCoder.addMessage("glitch",
                "No juice! The device isn't connected to a powered grid. Wire it up first.")
        else
            VibeCoder.addMessage("error", "Deploy failed: " .. reason)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPEECH-TO-TEXT HOOK
-- ═══════════════════════════════════════════════════════════════════════════

-- Hook for external STT system. Called with transcribed text.
function VibeCoder.receiveSTT(text)
    if text and #text > 0 then
        VibeCoder.sendRequest(text)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TARGET DEVICE SELECTION
-- ═══════════════════════════════════════════════════════════════════════════

-- Set the target device (called by raycast/mouseover system)
function VibeCoder.setTarget(deviceInstance)
    targetDevice = deviceInstance

    -- Update target status display
    local container = slackPadGui and slackPadGui:FindFirstChild("Container")
    if container then
        local topBar = container:FindFirstChild("TopBar")
        if topBar then
            local targetStatus = topBar:FindFirstChild("TargetStatus")
            if targetStatus then
                if deviceInstance then
                    targetStatus.Text = "Target: [" .. deviceInstance.Name .. "] | Pins: " ..
                        tostring(deviceInstance:GetAttribute("PinCount") or "?") .. "/10"
                    targetStatus.TextColor3 = THEME.accent
                else
                    targetStatus.Text = "Target: [None] | Pins: 0/0"
                    targetStatus.TextColor3 = THEME.textDim
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPEN / CLOSE
-- ═══════════════════════════════════════════════════════════════════════════

function VibeCoder.open()
    if not slackPadGui then return end

    local container = slackPadGui:FindFirstChild("Container")
    if not container then return end

    guiOpen = true
    container.Visible = true

    -- Animate in (scale + fade)
    container.Size = UDim2.new(0, 1, 0, 1)
    container.Position = UDim2.new(0.5, 0, 0.5, 0)
    container.BackgroundTransparency = 1

    local tween = TweenService:Create(container,
        TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        {
            Size = UDim2.new(0, 800, 0, 540),
            Position = UDim2.new(0.5, -400, 0.5, -270),
            BackgroundTransparency = 0,
        }
    )
    tween:Play()

    -- Greeting from Glitch
    if chatHistory and #chatHistory:GetChildren() == 0 then
        task.delay(0.3, function()
            VibeCoder.addMessage("glitch",
                "Hey boss! Glitch here. Tell me what you want to build and I'll code it up. " ..
                "Just type it out or hold [V] to speak.")
        end)
    end

    -- Focus input
    if inputBox then
        task.delay(0.3, function()
            inputBox:CaptureFocus()
        end)
    end
end

function VibeCoder.close()
    if not slackPadGui then return end

    local container = slackPadGui:FindFirstChild("Container")
    if not container then return end

    guiOpen = false

    local tween = TweenService:Create(container,
        TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.In),
        {
            Size = UDim2.new(0, 1, 0, 1),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            BackgroundTransparency = 1,
        }
    )
    tween:Play()

    task.delay(0.25, function()
        container.Visible = false
    end)
end

function VibeCoder.toggle()
    if guiOpen then
        VibeCoder.close()
    else
        VibeCoder.open()
    end
end

function VibeCoder.isOpen()
    return guiOpen
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INPUT HANDLING
-- ═══════════════════════════════════════════════════════════════════════════

local function setupInputHandlers()
    -- Hotkey toggle
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end

        if input.KeyCode == HOTKEY then
            -- Check if Slack-Pad is available (era check)
            local currentEra = _G.Slackwater_CurrentEra or 0
            if currentEra < ERA_REQUIRED then
                return -- Vibe-coding not yet unlocked
            end

            -- If typing in the input box, let the keystroke pass through
            if UserInputService:GetFocusedTextBox() == inputBox then
                return
            end

            VibeCoder.toggle()
        end

        -- Escape closes
        if input.KeyCode == Enum.KeyCode.Escape and guiOpen then
            VibeCoder.close()
        end
    end)

    -- Input box: submit on Enter
    if inputBox then
        inputBox.FocusLost:Connect(function(enterPressed)
            if enterPressed then
                local text = inputBox.Text
                if text and #text > 0 then
                    inputBox.Text = ""
                    VibeCoder.sendRequest(text)
                end
            end
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BUTTON HANDLERS
-- ═══════════════════════════════════════════════════════════════════════════

local function setupButtonHandlers(closeBtn)
    if closeBtn then
        closeBtn.MouseButton1Click:Connect(function()
            VibeCoder.close()
        end)
    end

    if deployButton then
        deployButton.MouseButton1Click:Connect(function()
            VibeCoder.deploy()
        end)
    end

    if deepDiveButton then
        deepDiveButton.MouseButton1Click:Connect(function()
            local VibeCoderDialogue = require(script.Parent:WaitForChild("VibeCoderDialogue"))
            VibeCoderDialogue.open(lastVibeCode)
        end)
    end

    if exportButton then
        exportButton.MouseButton1Click:Connect(function()
            if not lastVibeCode then
                VibeCoder.addMessage("error", "Nothing to export yet!")
                return
            end
            VibeCoder.addMessage("glitch",
                "Exporting to real-world firmware... Choose your board type in the export dialog.")
            -- Fire server to generate real .ino file
            if remoteEvent then
                remoteEvent:FireServer("vibe_code_export", {
                    code = lastVibeCode,
                    playerName = Players.LocalPlayer.Name,
                    boardType = "arduino_uno", -- default; UI could let player choose
                })
            end
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REMOTE EVENT HANDLERS (server → client)
-- ═══════════════════════════════════════════════════════════════════════════

local function setupRemoteHandlers()
    if not remoteEvent then return end

    remoteEvent.OnClientEvent:Connect(function(action, data)
        if action == "vibe_code_response" then
            VibeCoder.handleResponse(data)
        elseif action == "deploy_result" then
            VibeCoder.handleDeployResult(data)
        elseif action == "export_result" then
            if data and data.success then
                VibeCoder.addMessage("glitch",
                    "Firmware exported! Scan the QR code or visit: " ..
                    (data.url or "slackwater.game/export/" .. (data.id or "xxx")))
            else
                VibeCoder.addMessage("error", "Export failed: " .. (data and data.error or "unknown"))
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

function VibeCoder.init()
    if isInitialized then return end
    isInitialized = true

    -- Setup remote event
    remoteEvent = ensureRemoteEvent()

    -- Build GUI
    local closeBtn
    slackPadGui, _, closeBtn = buildSlackPad()

    -- Fix: buildSlackPad returns (gui, container, closeBtn, targetStatus)
    -- Re-assign closeBtn properly
    local gui, container, cBtn, tStatus = buildSlackPad()
    slackPadGui = gui
    closeBtn = cBtn

    -- Wire up input + buttons
    setupInputHandlers()
    setupButtonHandlers(closeBtn)
    setupRemoteHandlers()

    print("[VibeCoder] Slack-Pad initialized — press [V] to vibe-code (Era " ..
        tostring(ERA_REQUIRED) .. " required)")
end

-- Reset (for debugging/testing)
function VibeCoder.reset()
    isInitialized = false
    guiOpen = false
    slackPadGui = nil
    if inputBox then inputBox = nil end
    if chatHistory then chatHistory = nil end
    if codeDisplay then codeDisplay = nil end
    VibeCoder.init()
end

return VibeCoder
