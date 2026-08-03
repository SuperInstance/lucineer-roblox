--[[
    Lucineer UI Manager
    Handles all client-side UI: custom styled chat bubbles for Lucineer responses
    and the "Lucineer is thinking..." status bar.

    This module is designed to be required from the client.
    It creates GUI elements programmatically — no pre-built ScreenGui needed.

    Integrates VoiceLines for personality-driven message display.

    GAP #9d Fixes:
      - Replaced StarterGui:SetCore("ChatMakeSystemMessage") with
        TextChatService.TextChannels.RBXGeneral:DisplaySystemMessage (with pcall legacy fallback).
      - Replaced Chat:Chat() with TextChatService:DisplayBubble() (with pcall legacy fallback).

    GAP A6 Fixes:
      - showThinking animation loop guarded with a token so multiple rapid calls
        don't spawn competing while-loops fighting over the same Dot.
      - Nil check on _thinkingLabel before dereferencing.

    GAP #9e Fixes:
      - All `table` type annotations replaced with `{ [string]: any }`.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local TextChatService = game:GetService("TextChatService")

local Config = require(script.Parent.Config)
local VoiceLines = require(script.Parent.VoiceLines)

local UIManager = {}

-- Track created UI elements so we can clean them up
UIManager._screenGui = nil :: ScreenGui?
UIManager._thinkingBar = nil :: Frame?
UIManager._thinkingLabel = nil :: TextLabel?
UIManager._initialized = false

-- A6: Animation token for showThinking loop — prevents competing while-loops.
UIManager._thinkingAnimToken = 0 :: number

-- Active chat bubble tracking (for cleanup / overlap avoidance)
UIManager._activeBubbles = {} :: { Frame }
UIManager._maxBubbles = 3

-- Message type → display style mapping
local MESSAGE_STYLES: { [string]: { [string]: any } } = {
    message = {
        bgColor = Color3.fromRGB(20, 35, 50),
        accentColor = Color3.fromRGB(0, 255, 170),
        textColor = Color3.fromRGB(240, 240, 245),
        maxWidth = 450,
    },
    error = {
        bgColor = Color3.fromRGB(50, 20, 20),
        accentColor = Color3.fromRGB(255, 80, 80),
        textColor = Color3.fromRGB(255, 220, 220),
        maxWidth = 450,
    },
    commands = {
        bgColor = Color3.fromRGB(15, 30, 20),
        accentColor = Color3.fromRGB(100, 255, 130),
        textColor = Color3.fromRGB(220, 255, 230),
        maxWidth = 400,
    },
    greeting = {
        bgColor = Color3.fromRGB(20, 35, 50),
        accentColor = Color3.fromRGB(0, 255, 170),
        textColor = Color3.fromRGB(240, 240, 245),
        maxWidth = 450,
    },
    idle = {
        bgColor = Color3.fromRGB(30, 30, 35),
        accentColor = Color3.fromRGB(180, 180, 190),
        textColor = Color3.fromRGB(200, 200, 210),
        maxWidth = 400,
    },
}

--[[
    Create the ScreenGui container for all Lucineer UI.
]]
local function createScreenGui(): ScreenGui
    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

    local gui = Instance.new("ScreenGui")
    gui.Name = "LucineerUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = playerGui

    return gui
end

--[[
    Create the "Lucineer is thinking..." bar at the bottom of the screen.
]]
local function createThinkingBar(gui: ScreenGui): (Frame, TextLabel)
    local bar = Instance.new("Frame")
    bar.Name = "ThinkingBar"
    bar.Size = UDim2.new(0, 400, 0, 40)
    bar.Position = UDim2.new(0.5, -200, 1, -60)
    bar.AnchorPoint = Vector2.new(0, 0)
    bar.BackgroundColor3 = Config.UI_BG_COLOR
    bar.BackgroundTransparency = 0.2
    bar.BorderSizePixel = 0
    bar.Visible = false

    -- Rounded corners
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = bar

    -- Accent border on the left
    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.Size = UDim2.new(0, 4, 1, 0)
    accent.Position = UDim2.new(0, 0, 0, 0)
    accent.BackgroundColor3 = Config.UI_COLOR
    accent.BorderSizePixel = 0
    accent.Parent = bar

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(0, 2)
    accentCorner.Parent = accent

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.Size = UDim2.new(1, -20, 1, 0)
    label.Position = UDim2.new(0, 16, 0, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 14
    label.TextColor3 = Config.UI_TEXT_COLOR
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Text = Config.UI_THINKING_TEXT
    label.Parent = bar

    -- Pulsing dot indicator
    local dot = Instance.new("Frame")
    dot.Name = "Dot"
    dot.Size = UDim2.new(0, 8, 0, 8)
    dot.Position = UDim2.new(1, -20, 0.5, -4)
    dot.BackgroundColor3 = Config.UI_COLOR
    dot.BorderSizePixel = 0
    dot.Parent = bar

    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(1, 0)
    dotCorner.Parent = dot

    bar.Parent = gui

    return bar, label
end

--[[
    Show the thinking bar with optional custom text.
    GAP A6: Animation loop guarded with a token — each call increments
    _thinkingAnimToken and the loop checks it. If a new call comes in,
    the old loop exits instead of spawning a competing one.
    GAP A6: Nil check on _thinkingLabel before dereferencing.
    @param text string? -- override text (defaults to Config.UI_THINKING_TEXT)
]]
function UIManager.showThinking(text: string?)
    if not UIManager._thinkingBar then return end

    -- A6: Guard against nil _thinkingLabel
    if UIManager._thinkingLabel then
        UIManager._thinkingLabel.Text = text or Config.UI_THINKING_TEXT
    end

    UIManager._thinkingBar.Visible = true

    -- Slide up animation
    UIManager._thinkingBar.Position = UDim2.new(0.5, -200, 1, 0)
    local tween = TweenService:Create(
        UIManager._thinkingBar,
        TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        { Position = UDim2.new(0.5, -200, 1, -60) }
    )
    tween:Play()

    -- A6: Pulsing dot animation with token guard.
    -- Each call gets a unique token. The loop checks it every iteration;
    -- if a newer call came in, this loop exits.
    UIManager._thinkingAnimToken += 1
    local myToken = UIManager._thinkingAnimToken

    task.spawn(function()
        while UIManager._thinkingBar and UIManager._thinkingBar.Visible
            and myToken == UIManager._thinkingAnimToken do
            local dot = UIManager._thinkingBar:FindFirstChild("Dot")
            if not dot then break end

            local pulse = TweenService:Create(
                dot,
                TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { BackgroundTransparency = 0.5 }
            )
            pulse:Play()
            pulse.Completed:Wait()

            -- Check token again after wait
            if myToken ~= UIManager._thinkingAnimToken then break end

            local unpulse = TweenService:Create(
                dot,
                TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { BackgroundTransparency = 0 }
            )
            unpulse:Play()
            unpulse.Completed:Wait()
        end
    end)
end

--[[
    Hide the thinking bar.
]]
function UIManager.hideThinking()
    if not UIManager._thinkingBar then return end

    -- A6: Invalidate the animation token so the pulsing loop exits.
    UIManager._thinkingAnimToken += 1

    local tween = TweenService:Create(
        UIManager._thinkingBar,
        TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
        { Position = UDim2.new(0.5, -200, 1, 0) }
    )
    tween:Play()
    tween.Completed:Connect(function()
        if UIManager._thinkingBar then
            UIManager._thinkingBar.Visible = false
        end
    end)
end

--[[
    Resolve a message type from the raw server payload.
    Tries to infer a VoiceLines category for styling.
    @param msgType string -- the 'type' field from server payload
    @param message string -- the message text
    @return string -- a MESSAGE_STYLES key
]]
local function resolveStyleKey(msgType: string, message: string): string
    -- Direct style match
    if MESSAGE_STYLES[msgType] then
        return msgType
    end

    -- Infer from message content
    local lower = message:lower()
    if lower:find("hello") or lower:find("welcome") or lower:find("greet") then
        return "greeting"
    elseif lower:find("error") or lower:find("fail") or lower:find("unable") then
        return "error"
    elseif lower:find("build") or lower:find("creat") or lower:find("struct") then
        return "commands"
    elseif lower:find("wait") or lower:find("idle") or lower:find("bored") then
        return "idle"
    end

    return "message"
end

--[[
    Enrich a message with a voice line if the raw text is empty or generic.
    If the server sends a real message, use it directly.
    If the message is empty, pull from VoiceLines based on type.
    @param msgType string
    @param message string
    @return string -- the text to display
]]
local function enrichMessage(msgType: string, message: string): string
    if message and #message > 0 then
        return message
    end

    -- No message text: use VoiceLines
    if msgType == "greeting" then
        return VoiceLines.get("GREETING") or "..."
    elseif msgType == "error" then
        return VoiceLines.get("REFUSAL") or "Something went wrong."
    elseif msgType == "commands" then
        return VoiceLines.getWeighted()
    elseif msgType == "idle" then
        return VoiceLines.get("IDLE") or "..."
    end

    return VoiceLines.getWeighted()
end

--[[
    Create a custom styled chat bubble on screen.
    Shows the text with a typewriter effect.
    @param text string -- full text to display
    @param styleKey string -- key into MESSAGE_STYLES
    @param duration number? -- how long to show after typing finishes (default: 4s)
]]
local function createChatBubble(text: string, styleKey: string, duration: number?)
    duration = duration or 4
    local style = MESSAGE_STYLES[styleKey] or MESSAGE_STYLES.message

    -- Manage active bubbles: remove oldest if at max
    while #UIManager._activeBubbles >= UIManager._maxBubbles do
        local oldest = table.remove(UIManager._activeBubbles, 1)
        if oldest then
            oldest:Destroy()
        end
    end

    -- Calculate vertical position based on active bubble count
    local stackOffset = #UIManager._activeBubbles * 70

    -- Bubble container
    local bubble = Instance.new("Frame")
    bubble.Name = "ChatBubble"
    bubble.Size = UDim2.new(0, style.maxWidth, 0, 50)
    bubble.Position = UDim2.new(0.5, -style.maxWidth / 2, 1, -120 - stackOffset)
    bubble.AnchorPoint = Vector2.new(0, 0)
    bubble.BackgroundColor3 = style.bgColor
    bubble.BackgroundTransparency = 0.15
    bubble.BorderSizePixel = 0
    bubble.AutomaticSize = Enum.AutomaticSize.Y
    bubble.Parent = UIManager._screenGui

    -- Rounded corners
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = bubble

    -- Left accent bar
    local accent = Instance.new("Frame")
    accent.Name = "Accent"
    accent.Size = UDim2.new(0, 4, 1, 0)
    accent.Position = UDim2.new(0, 0, 0, 0)
    accent.BackgroundColor3 = style.accentColor
    accent.BorderSizePixel = 0
    accent.Parent = bubble

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(0, 2)
    accentCorner.Parent = accent

    -- Name label (Lucineer)
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "NameLabel"
    nameLabel.Size = UDim2.new(1, -24, 0, 16)
    nameLabel.Position = UDim2.new(0, 16, 0, 6)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 12
    nameLabel.TextColor3 = style.accentColor
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextYAlignment = Enum.TextYAlignment.Center
    nameLabel.Text = Config.BOT_NAME
    nameLabel.Parent = bubble

    -- Message text label (for typewriter)
    local textLabel = Instance.new("TextLabel")
    textLabel.Name = "MessageLabel"
    textLabel.Size = UDim2.new(1, -24, 0, 22)
    textLabel.Position = UDim2.new(0, 16, 0, 22)
    textLabel.BackgroundTransparency = 1
    textLabel.Font = Enum.Font.GothamMedium
    textLabel.TextSize = 15
    textLabel.TextColor3 = style.textColor
    textLabel.TextXAlignment = Enum.TextXAlignment.Left
    textLabel.TextYAlignment = Enum.TextYAlignment.Top
    textLabel.TextWrapped = true
    textLabel.Text = ""
    textLabel.AutomaticSize = Enum.AutomaticSize.Y
    textLabel.Parent = bubble

    -- Padding frame to give bottom breathing room
    local padding = Instance.new("UIListLayout")
    padding.Padding = UDim.new(0, 0)
    padding.Parent = bubble

    -- Track this bubble
    table.insert(UIManager._activeBubbles, bubble)

    -- Slide-in animation
    bubble.Position = UDim2.new(0.5, -style.maxWidth / 2, 1, -80 - stackOffset)
    bubble.BackgroundTransparency = 1
    local slideIn = TweenService:Create(
        bubble,
        TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        {
            Position = UDim2.new(0.5, -style.maxWidth / 2, 1, -120 - stackOffset),
            BackgroundTransparency = 0.15,
        }
    )
    slideIn:Play()

    -- Typewriter effect
    task.spawn(function()
        local totalChars = #text
        if totalChars == 0 then return end

        -- Aim for ~0.5s total regardless of length (clamped)
        local charDelay = math.clamp(0.5 / totalChars, 0.01, 0.05)

        for i = 1, totalChars do
            textLabel.Text = string.sub(text, 1, i)
            task.wait(charDelay)
        end

        -- Ensure full text is shown
        textLabel.Text = text

        -- Wait for the display duration, then fade out
        task.wait(duration)

        if bubble.Parent then
            local fadeOut = TweenService:Create(
                bubble,
                TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
                {
                    BackgroundTransparency = 1,
                    Position = UDim2.new(0.5, -style.maxWidth / 2, 1, -80 - stackOffset),
                }
            )

            -- Fade child elements too
            for _, child in ipairs(bubble:GetDescendants()) do
                if child:IsA("TextLabel") then
                    local textTween = TweenService:Create(
                        child,
                        TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
                        { TextTransparency = 1 }
                    )
                    textTween:Play()
                elseif child:IsA("Frame") then
                    local frameTween = TweenService:Create(
                        child,
                        TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
                        { BackgroundTransparency = 1 }
                    )
                    frameTween:Play()
                end
            end

            fadeOut:Play()
            fadeOut.Completed:Connect(function()
                -- Remove from active list
                for i, b in ipairs(UIManager._activeBubbles) do
                    if b == bubble then
                        table.remove(UIManager._activeBubbles, i)
                        break
                    end
                end
                bubble:Destroy()
            end)
        end
    end)
end

--[[
    GAP #9d: Display Lucineer's response using the custom chat bubble system.
    Picks display style based on message type and applies a typewriter effect.
    Falls back to TextChatService:DisplaySystemMessage, then legacy
    StarterGui:SetCore("ChatMakeSystemMessage") in a pcall.

    @param message string? -- the message text (may be empty, in which case VoiceLines fills in)
    @param msgType string? -- message type: "message", "error", "commands", "greeting", "idle"
]]
function UIManager.displayChatResponse(message: string?, msgType: string?)
    message = message or ""
    msgType = msgType or "message"

    -- Enrich empty messages with VoiceLines
    local displayText = enrichMessage(msgType, message)
    local styleKey = resolveStyleKey(msgType, displayText)

    -- Use custom bubble
    local ok, err = pcall(function()
        createChatBubble(displayText, styleKey)
    end)

    if not ok then
        warn(string.format("[Lucineer] UIManager: custom bubble failed: %s, falling back to chat", err))
        -- GAP #9d: Try TextChatService first (modern API)
        local chatOk = pcall(function()
            local channels = TextChatService:FindFirstChild("TextChannels")
            if channels then
                local channel = channels:FindFirstChild("RBXGeneral")
                if channel then
                    channel:DisplaySystemMessage(
                        string.format('<font color="#00FFAA">[%s]</font> %s', Config.BOT_NAME, displayText))
                    return
                end
            end
            -- If we get here, TextChatService path didn't work — force error to trigger legacy fallback
            error("TextChatService channels not available")
        end)
        -- GAP #9d: Legacy fallback for older experiences
        if not chatOk then
            pcall(function()
                StarterGui:SetCore("ChatMakeSystemMessage", {
                    Text = "[" .. Config.BOT_NAME .. "]: " .. displayText,
                    Color = Config.CHAT_COLOR,
                    Font = Enum.Font.GothamMedium,
                    TextSize = 16,
                })
            end)
        end
    end
end

--[[
    GAP #9d: Create a floating chat bubble above a target part/position.
    Uses TextChatService:DisplayBubble (modern API) with Chat:Chat legacy fallback.
    Uses VoiceLines for spatial messages when no text is provided.
    @param text string? -- the bubble text (optional; pulls from VoiceLines if nil)
    @param adornee Instance -- the part to attach the bubble to
    @param duration number? -- how long to show the bubble (default: 4s)
]]
function UIManager.showChatBubble(text: string?, adornee: Instance, duration: number?)
    duration = duration or 4

    -- Use VoiceLines weighted selection if no text provided
    if not text or #text == 0 then
        text = VoiceLines.getWeighted()
    end

    -- GAP #9d: Try TextChatService:DisplayBubble (modern API) first
    local ok = pcall(function()
        TextChatService:DisplayBubble(adornee, text)
    end)

    -- GAP #9d: Legacy fallback for older experiences
    if not ok then
        pcall(function()
            game:GetService("Chat"):Chat(adornee, "[" .. Config.BOT_NAME .. "] " .. text, Enum.ChatColor.Green)
        end)
    end
end

--[[
    Update the thinking bar text (e.g., "Building a castle...").
    @param text string
]]
function UIManager.updateThinkingText(text: string)
    -- A6: Nil check on _thinkingLabel
    if UIManager._thinkingLabel then
        UIManager._thinkingLabel.Text = text
    else
        warn("[Lucineer] UIManager: updateThinkingText called before init (_thinkingLabel is nil)")
    end
end

--[[
    Initialize the UI Manager. Creates all GUI elements and loads VoiceLines.
    Call once from the client script.
]]
function UIManager.init()
    if UIManager._initialized then
        warn("[Lucineer] UIManager: already initialized")
        return
    end
    UIManager._initialized = true

    -- Load voice lines
    VoiceLines.init()

    UIManager._screenGui = createScreenGui()
    UIManager._thinkingBar, UIManager._thinkingLabel = createThinkingBar(UIManager._screenGui)

    print("[Lucineer] UIManager: initialized (with VoiceLines)")
end

return UIManager
