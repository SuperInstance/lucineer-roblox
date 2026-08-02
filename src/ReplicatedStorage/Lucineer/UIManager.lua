--[[
    Lucineer UI Manager
    Handles all client-side UI: chat bubbles for Lucineer responses and the
    "Lucineer is thinking..." status bar.

    This module is designed to be required from the client.
    It creates GUI elements programmatically — no pre-built ScreenGui needed.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local Config = require(script.Parent.Config)

local UIManager = {}

-- Track created UI elements so we can clean them up
UIManager._screenGui = nil :: ScreenGui?
UIManager._thinkingBar = nil :: Frame?
UIManager._thinkingLabel = nil :: TextLabel?
UIManager._initialized = false

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
    @param text string? -- override text (defaults to Config.UI_THINKING_TEXT)
]]
function UIManager.showThinking(text: string?)
    if not UIManager._thinkingBar then return end
    UIManager._thinkingLabel.Text = text or Config.UI_THINKING_TEXT
    UIManager._thinkingBar.Visible = true

    -- Slide up animation
    UIManager._thinkingBar.Position = UDim2.new(0.5, -200, 1, 0)
    local tween = TweenService:Create(
        UIManager._thinkingBar,
        TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        { Position = UDim2.new(0.5, -200, 1, -60) }
    )
    tween:Play()

    -- Pulsing dot animation
    task.spawn(function()
        while UIManager._thinkingBar and UIManager._thinkingBar.Visible do
            local pulse = TweenService:Create(
                UIManager._thinkingBar:FindFirstChild("Dot"),
                TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                { BackgroundTransparency = 0.5 }
            )
            pulse:Play()
            pulse.Completed:Wait()
            local unpulse = TweenService:Create(
                UIManager._thinkingBar:FindFirstChild("Dot"),
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
    Display Lucineer's response as a system message in the chat.
    Uses ChatMakeSystemMessage for native chat integration.
    @param message string -- the message text
]]
function UIManager.displayChatResponse(message: string)
    local ok, err = pcall(function()
        StarterGui:SetCore("ChatMakeSystemMessage", {
            Text = "[" .. Config.BOT_NAME .. "]: " .. message,
            Color = Config.CHAT_COLOR,
            Font = Enum.Font.GothamMedium,
            TextSize = 16,
        })
    end)

    if not ok then
        warn(string.format("[Lucineer] UIManager: ChatMakeSystemMessage failed: %s", err))
        -- Fallback: print to output
        print(string.format("[Lucineer] %s: %s", Config.BOT_NAME, message))
    end
end

--[[
    Create a floating chat bubble above a target part/position.
    This is for spatial messages (e.g., when Lucineer builds something).
    @param text string -- the bubble text
    @param adornee Instance -- the part to attach the bubble to
    @param duration number? -- how long to show the bubble (default: 4s)
]]
function UIManager.showChatBubble(text: string, adornee: Instance, duration: number?)
    duration = duration or 4

    local ok, err = pcall(function()
        game:GetService("Chat"):Chat(adornee, "[" .. Config.BOT_NAME .. "] " .. text, Enum.ChatColor.Green)
    end)

    if not ok then
        warn(string.format("[Lucineer] UIManager: Chat bubble failed: %s", err))
    end
end

--[[
    Update the thinking bar text (e.g., "Building a castle...").
    @param text string
]]
function UIManager.updateThinkingText(text: string)
    if UIManager._thinkingLabel then
        UIManager._thinkingLabel.Text = text
    end
end

--[[
    Initialize the UI Manager. Creates all GUI elements.
    Call once from the client script.
]]
function UIManager.init()
    if UIManager._initialized then
        warn("[Lucineer] UIManager: already initialized")
        return
    end
    UIManager._initialized = true

    UIManager._screenGui = createScreenGui()
    UIManager._thinkingBar, UIManager._thinkingLabel = createThinkingBar(UIManager._screenGui)

    print("[Lucineer] UIManager: initialized")
end

return UIManager
