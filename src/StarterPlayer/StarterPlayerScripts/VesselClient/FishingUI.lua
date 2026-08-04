-- FishingUI.lua
-- Fishing minigame interface: tension bar, line status, fish silhouette,
-- fight timer, result popup. Hold-to-reel / release-to-ease controls.

local FishingUI = {}

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local BRASS = Color3.fromRGB(180, 140, 60)
local DARK_BG = Color3.fromRGB(28, 32, 38)
local DARK_FRAME = Color3.fromRGB(38, 42, 50)
local TEXT_LIGHT = Color3.fromRGB(210, 210, 200)
local GREEN = Color3.fromRGB(60, 160, 80)
local YELLOW = Color3.fromRGB(200, 180, 50)
local RED = Color3.fromRGB(200, 50, 50)
local SNAP = Color3.fromRGB(200, 30, 30)

local gui
local tensionBar, tensionIndicator, greenZone
local lineIndicator
local fishSilhouette
local timerLabel
local resultFrame
local reelButton
local connection
local reeling = false
local startTime = 0

local function createLabel(parent, text, pos, size, color)
	local lbl = Instance.new("TextLabel")
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
	gui.Name = "FishingUI"
	gui.ResetOnSpawn = false
	gui.Enabled = false

	-- Tension bar (right side, vertical)
	local tensionFrame = Instance.new("Frame")
	tensionFrame.Name = "TensionFrame"
	tensionFrame.Size = UDim2.new(0, 50, 0, 300)
	tensionFrame.Position = UDim2.new(1, -70, 0.5, -150)
	tensionFrame.BackgroundColor3 = DARK_FRAME
	tensionFrame.BorderSizePixel = 2
	tensionFrame.BorderColor3 = BRASS
	tensionFrame.Parent = gui

	tensionBar = Instance.new("Frame")
	tensionBar.Name = "Bar"
	tensionBar.Size = UDim2.new(0, 16, 0, 260)
	tensionBar.Position = UDim2.new(0.5, -8, 0, 20)
	tensionBar.BackgroundColor3 = DARK_BG
	tensionBar.BorderSizePixel = 1
	tensionBar.Parent = tensionFrame

	-- Green safe zone (middle 40%)
	greenZone = Instance.new("Frame")
	greenZone.Name = "SafeZone"
	greenZone.Size = UDim2.new(1, 0, 0.4, 0)
	greenZone.Position = UDim2.new(0, 0, 0.3, 0)
	greenZone.BackgroundColor3 = GREEN
	greenZone.BackgroundTransparency = 0.5
	greenZone.BorderSizePixel = 0
	greenZone.Parent = tensionBar

	tensionIndicator = Instance.new("Frame")
	tensionIndicator.Name = "Indicator"
	tensionIndicator.Size = UDim2.new(1.4, 0, 0, 4)
	tensionIndicator.Position = UDim2.new(-0.2, 0, 0.5, -2)
	tensionIndicator.BackgroundColor3 = BRASS
	tensionIndicator.BorderSizePixel = 0
	tensionIndicator.ZIndex = 3
	tensionIndicator.Parent = tensionBar

	createLabel(tensionFrame, "TNS", UDim2.new(0, 0, 0, 2), UDim2.new(1, 0, 0, 14), BRASS)
	createLabel(tensionFrame, "HI", UDim2.new(0, 0, 0, 18), UDim2.new(1, 0, 0, 10), RED)
	createLabel(tensionFrame, "LO", UDim2.new(0, 0, 1, -28), UDim2.new(1, 0, 0, 10), RED)

	-- Line status indicator (left of tension bar)
	local lineFrame = Instance.new("Frame")
	lineFrame.Name = "LineStatus"
	lineFrame.Size = UDim2.new(0, 30, 0, 260)
	lineFrame.Position = UDim2.new(1, -100, 0.5, -130)
	lineFrame.BackgroundColor3 = DARK_FRAME
	lineFrame.BorderSizePixel = 2
	lineFrame.BorderColor3 = BRASS
	lineFrame.Parent = gui

	lineIndicator = Instance.new("Frame")
	lineIndicator.Name = "Indicator"
	lineIndicator.Size = UDim2.new(0, 16, 0, 16)
	lineIndicator.Position = UDim2.new(0.5, -8, 0.5, -8)
	lineIndicator.BackgroundColor3 = GREEN
	lineIndicator.BorderSizePixel = 1
	lineIndicator.Parent = lineFrame

	createLabel(lineFrame, "LINE", UDim2.new(0, 0, 1, -14), UDim2.new(1, 0, 0, 12), BRASS)

	-- Fish silhouette (center)
	fishSilhouette = Instance.new("TextLabel")
	fishSilhouette.Name = "FishSilhouette"
	fishSilhouette.Size = UDim2.new(0, 120, 0, 60)
	fishSilhouette.Position = UDim2.new(0.5, -60, 0.5, -30)
	fishSilhouette.BackgroundTransparency = 1
	fishSilhouette.Text = "🐟"
	fishSilhouette.TextColor3 = Color3.fromRGB(80, 90, 100)
	fishSilhouette.Font = Enum.Font.Code
	fishSilhouette.TextScaled = true
	fishSilhouette.Visible = false
	fishSilhouette.Parent = gui

	-- Timer
	timerLabel = createLabel(gui, "0.0s", UDim2.new(0.5, -50, 0, 60), UDim2.new(0, 100, 0, 24), BRASS)

	-- Reel button (bottom center — hold to reel)
	reelButton = Instance.new("TextButton")
	reelButton.Name = "ReelBtn"
	reelButton.Size = UDim2.new(0, 160, 0, 50)
	reelButton.Position = UDim2.new(0.5, -80, 1, -80)
	reelButton.BackgroundColor3 = DARK_FRAME
	reelButton.BorderColor3 = BRASS
	reelButton.Text = "HOLD: REEL IN"
	reelButton.TextColor3 = BRASS
	reelButton.Font = Enum.Font.Code
	reelButton.TextScaled = true
	reelButton.AutoButtonColor = false
	reelButton.Parent = gui

	reelButton.MouseButton1Down:Connect(function()
		reeling = true
		reelButton.BackgroundColor3 = GREEN
	end)
	reelButton.MouseButton1Up:Connect(function()
		reeling = false
		reelButton.BackgroundColor3 = DARK_FRAME
	end)

	-- Result popup (hidden until catch)
	resultFrame = Instance.new("Frame")
	resultFrame.Name = "ResultPopup"
	resultFrame.Size = UDim2.new(0, 280, 0, 160)
	resultFrame.Position = UDim2.new(0.5, -140, 0.5, -80)
	resultFrame.BackgroundColor3 = DARK_FRAME
	resultFrame.BorderSizePixel = 3
	resultFrame.BorderColor3 = BRASS
	resultFrame.Visible = false
	resultFrame.ZIndex = 5
	resultFrame.Parent = gui

	createLabel(resultFrame, "CATCH!", UDim2.new(0, 0, 0, 6), UDim2.new(1, 0, 0, 24), BRASS).ZIndex = 6

	-- Will be filled by showResult()
	resultFrame:FindFirstChild("CATCH").Name = "Title"

	local speciesLabel = Instance.new("TextLabel")
	speciesLabel.Name = "Species"
	speciesLabel.BackgroundTransparency = 1
	speciesLabel.Position = UDim2.new(0, 10, 0, 34)
	speciesLabel.Size = UDim2.new(1, -20, 0, 20)
	speciesLabel.Font = Enum.Font.Code
	speciesLabel.Text = ""
	speciesLabel.TextColor3 = TEXT_LIGHT
	speciesLabel.TextScaled = true
	speciesLabel.ZIndex = 6
	speciesLabel.Parent = resultFrame

	local weightLabel = Instance.new("TextLabel")
	weightLabel.Name = "Weight"
	weightLabel.BackgroundTransparency = 1
	weightLabel.Position = UDim2.new(0, 10, 0, 56)
	weightLabel.Size = UDim2.new(1, -20, 0, 20)
	weightLabel.Font = Enum.Font.Code
	weightLabel.Text = ""
	weightLabel.TextColor3 = TEXT_LIGHT
	weightLabel.TextScaled = true
	weightLabel.ZIndex = 6
	weightLabel.Parent = resultFrame

	local gradeLabel = Instance.new("TextLabel")
	gradeLabel.Name = "Grade"
	gradeLabel.BackgroundTransparency = 1
	gradeLabel.Position = UDim2.new(0, 10, 0, 78)
	gradeLabel.Size = UDim2.new(1, -20, 0, 20)
	gradeLabel.Font = Enum.Font.Code
	gradeLabel.Text = ""
	gradeLabel.TextColor3 = BRASS
	gradeLabel.TextScaled = true
	gradeLabel.ZIndex = 6
	gradeLabel.Parent = resultFrame

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.BackgroundTransparency = 1
	valueLabel.Position = UDim2.new(0, 10, 0, 100)
	valueLabel.Size = UDim2.new(1, -20, 0, 20)
	valueLabel.Font = Enum.Font.Code
	valueLabel.Text = ""
	valueLabel.TextColor3 = GREEN
	valueLabel.TextScaled = true
	valueLabel.ZIndex = 6
	valueLabel.Parent = resultFrame

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.Size = UDim2.new(0, 80, 0, 24)
	closeBtn.Position = UDim2.new(0.5, -40, 1, -30)
	closeBtn.BackgroundColor3 = DARK_BG
	closeBtn.BorderColor3 = BRASS
	closeBtn.Text = "Stow"
	closeBtn.TextColor3 = BRASS
	closeBtn.Font = Enum.Font.Code
	closeBtn.TextScaled = true
	closeBtn.ZIndex = 6
	closeBtn.Parent = resultFrame

	closeBtn.MouseButton1Click:Connect(function()
		resultFrame.Visible = false
	end)

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

function FishingUI.init()
	build()

	connection = RunService.Heartbeat:Connect(function()
		if not gui or not gui.Enabled then return end
		if startTime > 0 then
			local elapsed = tick() - startTime
			timerLabel.Text = string.format("%.1fs", elapsed)
			if elapsed > 30 then
				timerLabel.TextColor3 = RED
			elseif elapsed > 15 then
				timerLabel.TextColor3 = YELLOW
			else
				timerLabel.TextColor3 = BRASS
			end
		end
	end)
end

function FishingUI.show()
	if gui then
		gui.Enabled = true
		startTime = tick()
	end
end

function FishingUI.hide()
	if gui then
		gui.Enabled = false
		startTime = 0
		resultFrame.Visible = false
		fishSilhouette.Visible = false
		reeling = false
	end
end

function FishingUI.update(tension, fishData)
	if not gui then return end

	-- tension: 0=slack, 0.5=perfect, 1.0=snap
	local clamped = math.clamp(tension, 0, 1)
	tensionIndicator.Position = UDim2.new(-0.2, 0, 1 - clamped, -2)

	-- Color the indicator based on zone
	if clamped > 0.75 or clamped < 0.15 then
		tensionIndicator.BackgroundColor3 = RED
	elseif clamped > 0.3 and clamped < 0.7 then
		tensionIndicator.BackgroundColor3 = GREEN
	else
		tensionIndicator.BackgroundColor3 = YELLOW
	end

	-- Line status
	if clamped > 0.9 then
		lineIndicator.BackgroundColor3 = SNAP
	elseif clamped > 0.7 then
		lineIndicator.BackgroundColor3 = YELLOW
	elseif clamped < 0.1 then
		lineIndicator.BackgroundColor3 = Color3.fromRGB(80, 100, 140) -- slack blue
	else
		lineIndicator.BackgroundColor3 = GREEN
	end

	-- Fish silhouette reveal
	if fishData then
		if fishData.revealed then
			fishSilhouette.Text = fishData.emoji or "🐟"
			fishSilhouette.TextColor3 = TEXT_LIGHT
		else
			fishSilhouette.Text = "🐟"
			fishSilhouette.TextColor3 = Color3.fromRGB(60, 70, 80)
		end
		fishSilhouette.Visible = true
	end

	return reeling
end

function FishingUI.showResult(catchData)
	if not gui or not resultFrame then return end
	resultFrame.Visible = true
	resultFrame:WaitForChild("Species").Text = catchData.species or "Unknown Fish"
	resultFrame:WaitForChild("Weight").Text = string.format("%.1f kg", catchData.weight or 0)
	local grade = catchData.grade or "C"
	local gradeLbl = resultFrame:WaitForChild("Grade")
	gradeLbl.Text = "Grade: " .. grade
	gradeLbl.TextColor3 = (grade == "A" and GREEN) or (grade == "B" and YELLOW) or RED
	resultFrame:WaitForChild("Value").Text = string.format("⚖ %d scrap", catchData.value or 0)
end

function FishingUI.isReeling()
	return reeling
end

return FishingUI
