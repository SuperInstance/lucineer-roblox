-- VesselStateUI.lua
-- Persistent bottom-right panel: hull integrity, section damage dots,
-- fuel gauge, crew status, gear status.

local VesselStateUI = {}

local Players = game:GetService("Players")

local BRASS = Color3.fromRGB(180, 140, 60)
local DARK_BG = Color3.fromRGB(28, 32, 38)
local DARK_FRAME = Color3.fromRGB(38, 42, 50)
local TEXT_LIGHT = Color3.fromRGB(210, 210, 200)
local GREEN = Color3.fromRGB(60, 160, 80)
local YELLOW = Color3.fromRGB(200, 180, 50)
local RED = Color3.fromRGB(200, 50, 50)
local GRAY = Color3.fromRGB(100, 100, 100)

local gui
local hullBar, hullFill, hullLabel
local sectionDots = {}  -- {bow, port, starboard, stern, keel}
local fuelBar, fuelFill, fuelLabel
local crewContainer
local gearIcon, gearLabel

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

local function hpColor(pct)
	if pct > 0.6 then return GREEN
	elseif pct > 0.3 then return YELLOW
	else return RED end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "VesselStateUI"
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, 200, 0, 220)
	panel.Position = UDim2.new(1, -216, 1, -240)
	panel.BackgroundColor3 = DARK_FRAME
	panel.BorderSizePixel = 2
	panel.BorderColor3 = BRASS
	panel.Parent = gui

	-- Title
	createLabel(panel, "🚢 VESSEL", UDim2.new(0, 0, 0, 2), UDim2.new(1, 0, 0, 18), BRASS)

	-- Hull integrity
	createLabel(panel, "Hull", UDim2.new(0, 6, 0, 22), UDim2.new(0, 40, 0, 14), TEXT_LIGHT)
	hullBar = Instance.new("Frame")
	hullBar.Name = "HullBar"
	hullBar.Size = UDim2.new(1, -50, 0, 14)
	hullBar.Position = UDim2.new(0, 44, 0, 22)
	hullBar.BackgroundColor3 = DARK_BG
	hullBar.BorderSizePixel = 1
	hullBar.BorderColor3 = BRASS
	hullBar.Parent = panel

	hullFill = Instance.new("Frame")
	hullFill.Name = "Fill"
	hullFill.Size = UDim2.new(1, 0, 1, 0)
	hullFill.BackgroundColor3 = GREEN
	hullFill.BorderSizePixel = 0
	hullFill.Parent = hullBar

	hullLabel = Instance.new("TextLabel")
	hullLabel.BackgroundTransparency = 1
	hullLabel.Position = UDim2.new(0, 2, 0, 0)
	hullLabel.Size = UDim2.new(1, -4, 1, 0)
	hullLabel.Font = Enum.Font.Code
	hullLabel.Text = "100%"
	hullLabel.TextColor3 = TEXT_LIGHT
	hullLabel.TextScaled = true
	hullLabel.Parent = hullFill

	-- Section damage dots
	createLabel(panel, "Sections", UDim2.new(0, 6, 0, 44), UDim2.new(1, -12, 0, 12), TEXT_LIGHT)

	local sectionNames = { "bow", "port", "stbd", "stern", "keel" }
	local sectionLabels = { "Bow", "Port", "Stbd", "Stern", "Keel" }
	for i, name in ipairs(sectionNames) do
		local dot = Instance.new("Frame")
		dot.Name = "Dot_" .. name
		dot.Size = UDim2.new(0, 24, 0, 24)
		dot.Position = UDim2.new(0, 6 + (i - 1) * 38, 0, 58)
		dot.BackgroundColor3 = GREEN
		dot.BorderSizePixel = 1
		dot.BorderColor3 = DARK_BG
		dot.Parent = panel

		local dotLbl = Instance.new("TextLabel")
		dotLbl.BackgroundTransparency = 1
		dotLbl.Position = UDim2.new(0, 0, 1, 0)
		dotLbl.Size = UDim2.new(1, 0, 0, 10)
		dotLbl.Font = Enum.Font.Code
		dotLbl.Text = sectionLabels[i]
		dotLbl.TextColor3 = TEXT_LIGHT
		dotLbl.TextScaled = true
		dotLbl.Parent = dot

		sectionDots[name] = dot
	end

	-- Fuel gauge
	createLabel(panel, "Fuel", UDim2.new(0, 6, 0, 96), UDim2.new(0, 40, 0, 14), TEXT_LIGHT)
	fuelBar = Instance.new("Frame")
	fuelBar.Name = "FuelBar"
	fuelBar.Size = UDim2.new(1, -50, 0, 14)
	fuelBar.Position = UDim2.new(0, 44, 0, 96)
	fuelBar.BackgroundColor3 = DARK_BG
	fuelBar.BorderSizePixel = 1
	fuelBar.BorderColor3 = BRASS
	fuelBar.Parent = panel

	fuelFill = Instance.new("Frame")
	fuelFill.Name = "Fill"
	fuelFill.Size = UDim2.new(1, 0, 1, 0)
	fuelFill.BackgroundColor3 = Color3.fromRGB(100, 140, 180)
	fuelFill.BorderSizePixel = 0
	fuelFill.Parent = fuelBar

	fuelLabel = Instance.new("TextLabel")
	fuelLabel.BackgroundTransparency = 1
	fuelLabel.Position = UDim2.new(0, 2, 0, 0)
	fuelLabel.Size = UDim2.new(1, -4, 1, 0)
	fuelLabel.Font = Enum.Font.Code
	fuelLabel.Text = "100%"
	fuelLabel.TextColor3 = TEXT_LIGHT
	fuelLabel.TextScaled = true
	fuelLabel.Parent = fuelFill

	-- Crew status
	createLabel(panel, "Crew", UDim2.new(0, 6, 0, 118), UDim2.new(1, -12, 0, 14), TEXT_LIGHT)
	crewContainer = Instance.new("Frame")
	crewContainer.Name = "CrewContainer"
	crewContainer.Size = UDim2.new(1, -12, 0, 20)
	crewContainer.Position = UDim2.new(0, 6, 0, 134)
	crewContainer.BackgroundTransparency = 1
	crewContainer.Parent = panel

	-- Gear status
	createLabel(panel, "Gear", UDim2.new(0, 6, 0, 162), UDim2.new(0, 40, 0, 14), TEXT_LIGHT)
	gearIcon = Instance.new("TextLabel")
	gearIcon.Name = "GearIcon"
	gearIcon.BackgroundTransparency = 1
	gearIcon.Position = UDim2.new(0, 44, 0, 160)
	gearIcon.Size = UDim2.new(0, 100, 0, 14)
	gearIcon.Font = Enum.Font.Code
	gearIcon.Text = "Stowed"
	gearIcon.TextColor3 = GRAY
	gearIcon.TextScaled = true
	gearIcon.TextXAlignment = Enum.TextXAlignment.Left
	gearIcon.Parent = panel

	gearLabel = Instance.new("TextLabel")
	gearLabel.Name = "GearDurability"
	gearLabel.BackgroundTransparency = 1
	gearLabel.Position = UDim2.new(0, 150, 0, 160)
	gearLabel.Size = UDim2.new(0, 40, 0, 14)
	gearLabel.Font = Enum.Font.Code
	gearLabel.Text = ""
	gearLabel.TextColor3 = GREEN
	gearLabel.TextScaled = true
	gearLabel.Parent = panel

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

function VesselStateUI.init()
	build()
end

function VesselStateUI.show()
	if gui then gui.Enabled = true end
end

function VesselStateUI.hide()
	if gui then gui.Enabled = false end
end

function VesselStateUI.update(stateData)
	if not gui then return end

	-- Hull
	if stateData.hullPercent ~= nil then
		local pct = math.clamp(stateData.hullPercent, 0, 1)
		hullFill.Size = UDim2.new(pct, 0, 1, 0)
		hullFill.BackgroundColor3 = hpColor(pct)
		hullLabel.Text = string.format("%d%%", math.floor(pct * 100))
		hullLabel.TextColor3 = (pct > 0.3) and Color3.fromRGB(20, 20, 20) or TEXT_LIGHT
	end

	-- Sections
	if stateData.sections then
		for name, dot in pairs(sectionDots) do
			local hp = stateData.sections[name]
			if hp ~= nil then
				dot.BackgroundColor3 = hpColor(hp)
			end
		end
	end

	-- Fuel
	if stateData.fuelPercent ~= nil then
		local pct = math.clamp(stateData.fuelPercent, 0, 1)
		fuelFill.Size = UDim2.new(pct, 0, 1, 0)
		fuelLabel.Text = string.format("%d%%", math.floor(pct * 100))
		fuelFill.BackgroundColor3 = (pct < 0.2 and RED) or Color3.fromRGB(100, 140, 180)
	end

	-- Crew
	if stateData.crew then
		-- Clear old
		for _, child in ipairs(crewContainer:GetChildren()) do
			child:Destroy()
		end
		for i, member in ipairs(stateData.crew) do
			local icon = Instance.new("TextLabel")
			icon.Size = UDim2.new(0, 16, 0, 16)
			icon.Position = UDim2.new(0, (i - 1) * 20, 0, 2)
			icon.BackgroundColor3 = (member == "active" and GREEN)
				or (member == "injured" and YELLOW)
				or GRAY
			icon.BorderSizePixel = 1
			icon.Text = ""
			icon.Parent = crewContainer
		end
	end

	-- Gear
	if stateData.garDeployed ~= nil then
		if stateData.gearDeployed then
			gearIcon.Text = "🎣 Deployed"
			gearIcon.TextColor3 = GREEN
		else
			gearIcon.Text = "Stowed"
			gearIcon.TextColor3 = GRAY
		end
	end
	if stateData.gearDurability ~= nil then
		local pct = stateData.gearDurability
		gearLabel.Text = string.format("%d%%", math.floor(pct * 100))
		gearLabel.TextColor3 = hpColor(pct)
	end
end

return VesselStateUI
