-- HelmUI.lua
-- Helm control interface shown when player sits in HelmSeat.
-- Throttle slider, rudder wheel, compass strip, speed readout, depth alarm.

local HelmUI = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local BRASS = Color3.fromRGB(180, 140, 60)
local DARK_BG = Color3.fromRGB(28, 32, 38)
local DARK_FRAME = Color3.fromRGB(38, 42, 50)
local ALARM_RED = Color3.fromRGB(200, 40, 40)
local TEXT_LIGHT = Color3.fromRGB(210, 210, 200)
local ACCENT_GREEN = Color3.fromRGB(60, 160, 80)

local gui
local throttleFill
local rudderWheel
local compassStrip
local speedLabel
local depthAlarm
local connection

-- State
local throttle = 0      -- -1 (full reverse) to 1 (full ahead)
local rudder = 0         -- -1 (hard port) to 1 (hard starboard)
local gear = 1           -- 1=ahead, 0=neutral, -1=reverse
local anchorDown = false
local keysDown = {}

local function createLabel(parent, text, pos, size, color)
	local lbl = Instance.new("TextLabel")
	lbl.Name = text:match("%S+") or "Label"
	lbl.BackgroundTransparency = 1
	lbl.Position = pos
	lbl.Size = size
	lbl.Font = Enum.Font.Code
	lbl.Text = text
	lbl.TextColor3 = color or TEXT_LIGHT
	lbl.TextScaled = true
	lbl.Parent = parent
	return lbl
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "HelmUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false

	-- Anchor / horn quick bar (bottom center)
	local bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.Size = UDim2.new(0, 240, 0, 44)
	bottomBar.Position = UDim2.new(0.5, -120, 1, -60)
	bottomBar.BackgroundColor3 = DARK_FRAME
	bottomBar.BackgroundTransparency = 0.1
	bottomBar.BorderSizePixel = 2
	bottomBar.BorderColor3 = BRASS
	bottomBar.Parent = gui

	local anchorBtn = Instance.new("TextButton")
	anchorBtn.Name = "AnchorBtn"
	anchorBtn.Size = UDim2.new(0, 100, 0, 32)
	anchorBtn.Position = UDim2.new(0, 10, 0, 6)
	anchorBtn.BackgroundColor3 = DARK_BG
	anchorBtn.BorderColor3 = BRASS
	anchorBtn.Text = "⚓ Anchor"
	anchorBtn.TextColor3 = TEXT_LIGHT
	anchorBtn.Font = Enum.Font.Code
	anchorBtn.TextScaled = true
	anchorBtn.Parent = bottomBar
	anchorBtn.MouseButton1Click:Connect(function()
		anchorDown = not anchorDown
		anchorBtn.Text = anchorDown and "⚓ Anchored" or "⚓ Anchor"
		anchorBtn.TextColor3 = anchorDown and ACCENT_GREEN or TEXT_LIGHT
	end)

	local hornBtn = Instance.new("TextButton")
	hornBtn.Name = "HornBtn"
	hornBtn.Size = UDim2.new(0, 100, 0, 32)
	hornBtn.Position = UDim2.new(1, -110, 0, 6)
	hornBtn.BackgroundColor3 = DARK_BG
	hornBtn.BorderColor3 = BRASS
	hornBtn.Text = "📢 Horn"
	hornBtn.TextColor3 = TEXT_LIGHT
	hornBtn.Font = Enum.Font.Code
	hornBtn.TextScaled = true
	hornBtn.Parent = bottomBar

	-- Throttle slider (left side)
	local throttleFrame = Instance.new("Frame")
	throttleFrame.Name = "ThrottleFrame"
	throttleFrame.Size = UDim2.new(0, 50, 0, 240)
	throttleFrame.Position = UDim2.new(0, 20, 0.5, -120)
	throttleFrame.BackgroundColor3 = DARK_FRAME
	throttleFrame.BorderSizePixel = 2
	throttleFrame.BorderColor3 = BRASS
	throttleFrame.Parent = gui

	local throttleTrack = Instance.new("Frame")
	throttleTrack.Name = "Track"
	throttleTrack.Size = UDim2.new(0, 12, 0, 200)
	throttleTrack.Position = UDim2.new(0.5, -6, 0, 20)
	throttleTrack.BackgroundColor3 = DARK_BG
	throttleTrack.BorderSizePixel = 1
	throttleTrack.BorderColor3 = BRASS
	throttleTrack.Parent = throttleFrame

	throttleFill = Instance.new("Frame")
	throttleFill.Name = "Fill"
	throttleFill.Size = UDim2.new(1, 0, 0.5, 0)
	throttleFill.Position = UDim2.new(0, 0, 0.5, 0)
	throttleFill.BackgroundColor3 = ACCENT_GREEN
	throttleFill.BorderSizePixel = 0
	throttleFill.Parent = throttleTrack

	createLabel(throttleFrame, "0%", UDim2.new(0, 0, 1, -16), UDim2.new(1, 0, 0, 14), TEXT_LIGHT)
	createLabel(throttleFrame, "THR", UDim2.new(0, 0, 0, 2), UDim2.new(1, 0, 0, 14), BRASS)

	-- Rudder wheel (right side)
	local rudderFrame = Instance.new("Frame")
	rudderFrame.Name = "RudderFrame"
	rudderFrame.Size = UDim2.new(0, 120, 0, 120)
	rudderFrame.Position = UDim2.new(1, -140, 0.5, -60)
	rudderFrame.BackgroundColor3 = DARK_FRAME
	rudderFrame.BorderSizePixel = 2
	rudderFrame.BorderColor3 = BRASS
	rudderFrame.Parent = gui

	rudderWheel = Instance.new("Frame")
	rudderWheel.Name = "Wheel"
	rudderWheel.Size = UDim2.new(0, 80, 0, 80)
	rudderWheel.Position = UDim2.new(0.5, -40, 0.5, -40)
	rudderWheel.BackgroundColor3 = BRASS
	rudderWheel.BackgroundTransparency = 0.3
	rudderWheel.BorderSizePixel = 3
	rudderWheel.BorderColor3 = BRASS
	rudderWheel.Parent = rudderFrame

	-- Wheel spokes
	for i = 1, 4 do
		local spoke = Instance.new("Frame")
		spoke.Name = "Spoke" .. i
		spoke.Size = UDim2.new(0, 76, 0, 4)
		spoke.Position = UDim2.new(0.5, -38, 0.5, -2)
		spoke.BackgroundColor3 = BRASS
		spoke.BorderSizePixel = 0
		spoke.Rotation = (i - 1) * 45
		spoke.Parent = rudderWheel
	end

	createLabel(rudderFrame, "RUD", UDim2.new(0, 0, 1, -16), UDim2.new(1, 0, 0, 14), BRASS)

	-- Compass strip (top center)
	local compassFrame = Instance.new("Frame")
	compassFrame.Name = "CompassFrame"
	compassFrame.Size = UDim2.new(0, 400, 0, 36)
	compassFrame.Position = UDim2.new(0.5, -200, 0, 8)
	compassFrame.BackgroundColor3 = DARK_FRAME
	compassFrame.BorderSizePixel = 2
	compassFrame.BorderColor3 = BRASS
	compassFrame.ClipsDescendants = true
	compassFrame.Parent = gui

	compassStrip = Instance.new("Frame")
	compassStrip.Name = "Strip"
	compassStrip.Size = UDim2.new(0, 1440, 1, 0)
	compassStrip.BackgroundTransparency = 1
	compassStrip.Parent = compassFrame

	-- Generate degree marks every 15°
	for deg = 0, 359, 15 do
		local mark = Instance.new("Frame")
		mark.Size = UDim2.new(0, 1, 1, 0)
		mark.Position = UDim2.new(0, deg * 4, 0, 0)
		mark.BackgroundColor3 = (deg % 90 == 0) and BRASS or Color3.fromRGB(120, 120, 110)
		mark.BorderSizePixel = 0
		mark.Parent = compassStrip

		if deg % 45 == 0 then
			local dirText = ({ [0] = "N", [45] = "NE", [90] = "E", [135] = "SE", [180] = "S", [225] = "SW", [270] = "W", [315] = "NW" })[deg]
			local dlbl = Instance.new("TextLabel")
			dlbl.BackgroundTransparency = 1
			dlbl.Position = UDim2.new(0, deg * 4 - 10, 0, 4)
			dlbl.Size = UDim2.new(0, 20, 0, 12)
			dlbl.Font = Enum.Font.Code
			dlbl.Text = dirText or tostring(deg)
			dlbl.TextColor3 = TEXT_LIGHT
			dlbl.TextScaled = true
			dlbl.Parent = compassStrip
		end
	end

	-- Center indicator line
	local centerLine = Instance.new("Frame")
	centerLine.Name = "CenterLine"
	centerLine.Size = UDim2.new(0, 2, 1, 0)
	centerLine.Position = UDim2.new(0.5, -1, 0, 0)
	centerLine.BackgroundColor3 = ALARM_RED
	centerLine.BorderSizePixel = 0
	centerLine.ZIndex = 3
	centerLine.Parent = compassFrame

	-- Speed readout
	speedLabel = createLabel(gui, "0.0 kn", UDim2.new(1, -140, 0, 50), UDim2.new(0, 120, 0, 22), BRASS)
	speedLabel.TextXAlignment = Enum.TextXAlignment.Right

	-- Depth alarm overlay
	depthAlarm = Instance.new("TextLabel")
	depthAlarm.Name = "DepthAlarm"
	depthAlarm.Size = UDim2.new(0, 200, 0, 30)
	depthAlarm.Position = UDim2.new(0.5, -100, 0, 50)
	depthAlarm.BackgroundColor3 = ALARM_RED
	depthAlarm.BackgroundTransparency = 1
	depthAlarm.Text = "⚠ SHALLOW WATER"
	depthAlarm.TextColor3 = ALARM_RED
	depthAlarm.Font = Enum.Font.Code
	depthAlarm.TextScaled = true
	depthAlarm.Visible = false
	depthAlarm.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- Input handling
local function handleInput(input, processed)
	if processed then return end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keysDown[input.KeyCode] = input.UserInputState == Enum.UserInputState.Begin
	end
end

local function updateInput(dt)
	local throttleSpeed = 1.5 * dt
	local rudderSpeed = 2.0 * dt

	if keysDown[Enum.KeyCode.W] then throttle = math.min(1, throttle + throttleSpeed) end
	if keysDown[Enum.KeyCode.S] then throttle = math.max(-1, throttle - throttleSpeed) end
	if keysDown[Enum.KeyCode.A] then rudder = math.max(-1, rudder - rudderSpeed) end
	if keysDown[Enum.KeyCode.D] then rudder = math.min(1, rudder + rudderSpeed) end

	-- Smooth rudder return when no steer input
	if not keysDown[Enum.KeyCode.A] and not keysDown[Enum.KeyCode.D] then
		rudder = rudder > 0 and math.max(0, rudder - rudderSpeed * 0.5) or math.min(0, rudder + rudderSpeed * 0.5)
	end
end

function HelmUI.init()
	build()

	UserInputService.InputBegan:Connect(function(input, processed)
		handleInput(input, processed)
		if input.UserInputType == Enum.UserInputType.Keyboard and input.UserInputState == Enum.UserInputState.Begin then
			local key = input.KeyCode
			if key == Enum.KeyCode.Space then
				anchorDown = not anchorDown
			elseif key == Enum.KeyCode.E then
				gear = gear == 1 and 0 or (gear == 0 and -1 or 1)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			keysDown[input.KeyCode] = false
		end
	end)

	connection = RunService.Heartbeat:Connect(function(dt)
		if not gui or not gui.Enabled then return end
		updateInput(dt)
		-- Visual updates
		throttleFill.Size = UDim2.new(1, 0, math.abs(throttle) / 2, 0)
		throttleFill.Position = UDim2.new(0, 0, throttle >= 0 and (0.5 - throttle / 4) or 0.5, 0)
		rudderWheel.Rotation = rudder * 135
	end)
end

function HelmUI.show()
	if gui then gui.Enabled = true end
end

function HelmUI.hide()
	if gui then gui.Enabled = false end
end

function HelmUI.update(data)
	if not gui then return end
	-- Speed
	if data.speed then
		local knots = math.floor(data.speed * 1.944 * 10) / 10
		speedLabel.Text = string.format("%.1f kn", knots)
	end
	-- Compass
	if data.heading then
		compassStrip.Position = UDim2.new(0, -data.heading * 4 + 200, 0, 0)
	end
	-- Depth alarm
	if data.depth ~= nil then
		local shallow = data.depth < 8
		depthAlarm.Visible = shallow
		depthAlarm.BackgroundTransparency = shallow and (math.sin(tick() * 8) * 0.4 + 0.4) or 1
	end
	-- Throttle/rudder from external source
	if data.throttle ~= nil then throttle = data.throttle end
	if data.rudder ~= nil then rudder = data.rudder end
end

return HelmUI
