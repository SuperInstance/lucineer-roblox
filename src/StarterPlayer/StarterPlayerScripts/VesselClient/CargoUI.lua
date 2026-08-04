-- CargoUI.lua
-- Cargo inventory panel: fish list, quality breakdown, capacity bar,
-- perishable timers, materials, scrap balance, quick-sell at dock.

local CargoUI = {}

local Players = game:GetService("Players")

local BRASS = Color3.fromRGB(180, 140, 60)
local DARK_BG = Color3.fromRGB(28, 32, 38)
local DARK_FRAME = Color3.fromRGB(38, 42, 50)
local TEXT_LIGHT = Color3.fromRGB(210, 210, 200)
local GREEN = Color3.fromRGB(60, 160, 80)
local YELLOW = Color3.fromRGB(200, 180, 50)
local RED = Color3.fromRGB(200, 50, 50)

local gui
local fishList
local capacityBar, capacityFill, capacityLabel
local materialsList
local scrapLabel
local perishLabel
local sellBtn
local visible = false

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
	gui.Name = "CargoUI"
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local panel = Instance.new("ScrollingFrame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, 320, 0, 440)
	panel.Position = UDim2.new(0, 16, 0.5, -220)
	panel.BackgroundColor3 = DARK_FRAME
	panel.BorderSizePixel = 2
	panel.BorderColor3 = BRASS
	panel.ScrollBarThickness = 4
	panel.ScrollBarImageColor3 = BRASS
	panel.CanvasSize = UDim2.new(0, 0, 0, 600)
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.Parent = gui

	createLabel(panel, "⚓ CARGO HOLD", UDim2.new(0, 0, 0, 4), UDim2.new(1, 0, 0, 22), BRASS)

	-- Scrap balance
	scrapLabel = createLabel(panel, "Scrap: 0", UDim2.new(0, 8, 0, 28), UDim2.new(1, -16, 0, 18), GREEN)

	-- Capacity bar
	createLabel(panel, "Capacity", UDim2.new(0, 8, 0, 50), UDim2.new(0, 80, 0, 14), TEXT_LIGHT)
	capacityBar = Instance.new("Frame")
	capacityBar.Name = "CapacityBar"
	capacityBar.Size = UDim2.new(1, -16, 0, 16)
	capacityBar.Position = UDim2.new(0, 8, 0, 66)
	capacityBar.BackgroundColor3 = DARK_BG
	capacityBar.BorderSizePixel = 1
	capacityBar.BorderColor3 = BRASS
	capacityBar.Parent = panel

	capacityFill = Instance.new("Frame")
	capacityFill.Name = "Fill"
	capacityFill.Size = UDim2.new(0, 0, 1, 0)
	capacityFill.BackgroundColor3 = GREEN
	capacityFill.BorderSizePixel = 0
	capacityFill.Parent = capacityBar

	capacityLabel = createLabel(capacityBar, "0 / 0 kg", UDim2.new(0, 4, 0, 0), UDim2.new(1, -8, 1, 0), TEXT_LIGHT)

	-- Perishable warning
	perishLabel = createLabel(panel, "", UDim2.new(0, 8, 0, 88), UDim2.new(1, -16, 0, 14), YELLOW)

	-- Fish list header
	createLabel(panel, "━ CATCH ━", UDim2.new(0, 8, 0, 108), UDim2.new(1, -16, 0, 14), BRASS)

	fishList = Instance.new("Frame")
	fishList.Name = "FishList"
	fishList.Size = UDim2.new(1, -16, 0, 0)
	fishList.Position = UDim2.new(0, 8, 0, 126)
	fishList.BackgroundTransparency = 1
	fishList.AutomaticSize = Enum.AutomaticSize.Y
	fishList.LayoutOrder = 1
	fishList.Parent = panel

	local fishLayout = Instance.new("UIListLayout")
	fishLayout.SortOrder = Enum.SortOrder.LayoutOrder
	fishLayout.Padding = UDim.new(0, 2)
	fishLayout.Parent = fishList

	-- Materials header
	local matHeader = createLabel(panel, "━ MATERIALS ━", UDim2.new(0, 8, 0, 250), UDim2.new(1, -16, 0, 14), BRASS)

	materialsList = Instance.new("Frame")
	materialsList.Name = "MaterialsList"
	materialsList.Size = UDim2.new(1, -16, 0, 0)
	materialsList.Position = UDim2.new(0, 8, 0, 268)
	materialsList.BackgroundTransparency = 1
	materialsList.AutomaticSize = Enum.AutomaticSize.Y
	materialsList.Parent = panel

	local matLayout = Instance.new("UIListLayout")
	matLayout.SortOrder = Enum.SortOrder.LayoutOrder
	matLayout.Padding = UDim.new(0, 2)
	matLayout.Parent = materialsList

	-- Quick sell button (hidden unless docked)
	sellBtn = Instance.new("TextButton")
	sellBtn.Name = "QuickSell"
	sellBtn.Size = UDim2.new(1, -16, 0, 32)
	sellBtn.Position = UDim2.new(0, 8, 0, 360)
	sellBtn.BackgroundColor3 = DARK_BG
	sellBtn.BorderColor3 = GREEN
	sellBtn.Text = "💰 SELL ALL FISH"
	sellBtn.TextColor3 = GREEN
	sellBtn.Font = Enum.Font.Code
	sellBtn.TextScaled = true
	sellBtn.Visible = false
	sellBtn.Parent = panel

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function clearList(listFrame)
	for _, child in ipairs(listFrame:GetChildren()) do
		if child:IsA("TextLabel") or child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function addFishRow(parent, species, count, totalWeight, gradeA, gradeB, gradeC)
	local row = Instance.new("TextLabel")
	row.Size = UDim2.new(1, 0, 0, 28)
	row.BackgroundColor3 = DARK_BG
	row.BackgroundTransparency = 0.3
	row.BorderSizePixel = 0
	row.Font = Enum.Font.Code
	row.Text = string.format("  %s ×%d  %.1fkg", species, count, totalWeight)
	row.TextColor3 = TEXT_LIGHT
	row.TextScaled = true
	row.TextXAlignment = Enum.TextXAlignment.Left
	row.Parent = parent

	local gradeText = string.format("A:%d B:%d C:%d", gradeA, gradeB, gradeC)
	local gradeLbl = Instance.new("TextLabel")
	gradeLbl.BackgroundTransparency = 1
	gradeLbl.Position = UDim2.new(1, -60, 0, 0)
	gradeLbl.Size = UDim2.new(0, 56, 1, 0)
	gradeLbl.Font = Enum.Font.Code
	gradeLbl.Text = gradeText
	gradeLbl.TextColor3 = YELLOW
	gradeLbl.TextScaled = true
	gradeLbl.Parent = row
end

local function addMaterialRow(parent, name, count)
	local row = Instance.new("TextLabel")
	row.Size = UDim2.new(1, 0, 0, 20)
	row.BackgroundColor3 = DARK_BG
	row.BackgroundTransparency = 0.3
	row.BorderSizePixel = 0
	row.Font = Enum.Font.Code
	row.Text = string.format("  %s: %d", name, count)
	row.TextColor3 = TEXT_LIGHT
	row.TextScaled = true
	row.TextXAlignment = Enum.TextXAlignment.Left
	row.Parent = parent
end

function CargoUI.init()
	build()
end

function CargoUI.show()
	if gui then gui.Enabled = true; visible = true end
end

function CargoUI.hide()
	if gui then gui.Enabled = false; visible = false end
end

function CargoUI.toggle()
	if visible then CargoUI.hide() else CargoUI.show() end
end

function CargoUI.update(cargoData)
	if not gui then return end

	-- Scrap
	if cargoData.scrap then
		scrapLabel.Text = string.format("Scrap: ⚖ %d", cargoData.scrap)
	end

	-- Capacity
	local curW = cargoData.currentWeight or 0
	local maxW = cargoData.maxWeight or 1
	local pct = math.clamp(curW / maxW, 0, 1)
	capacityFill.Size = UDim2.new(pct, 0, 1, 0)
	capacityFill.BackgroundColor3 = (pct > 0.85 and RED) or (pct > 0.6 and YELLOW) or GREEN
	capacityLabel.Text = string.format("%.0f / %.0f kg", curW, maxW)

	-- Perishable
	if cargoData.oldestCatchAge then
		local remaining = 7200 - cargoData.oldestCatchAge  -- 2h in seconds
		if remaining <= 0 then
			perishLabel.Text = "⚠ FISH SPOILED — quality lost"
			perishLabel.TextColor3 = RED
		elseif remaining < 1800 then
			perishLabel.Text = string.format("⚠ Spoiling in %dm", math.ceil(remaining / 60))
			perishLabel.TextColor3 = RED
		elseif remaining < 3600 then
			perishLabel.Text = string.format("⏱ Fresh for %dm", math.ceil(remaining / 60))
			perishLabel.TextColor3 = YELLOW
		else
			perishLabel.Text = "✓ Catch is fresh"
			perishLabel.TextColor3 = GREEN
		end
	end

	-- Fish list
	clearList(fishList)
	if cargoData.fish then
		for _, fish in ipairs(cargoData.fish) do
			addFishRow(fishList, fish.species, fish.count, fish.totalWeight,
				fish.gradeA or 0, fish.gradeB or 0, fish.gradeC or 0)
		end
	end

	-- Materials
	clearList(materialsList)
	if cargoData.materials then
		local matNames = { "wood", "metal", "cloth", "glass", "copper", "stone" }
		for _, matName in ipairs(matNames) do
			local count = cargoData.materials[matName] or 0
			if count > 0 then
				addMaterialRow(materialsList, matName:upper(), count)
			end
		end
	end

	-- Sell button
	if cargoData.docked ~= nil then
		sellBtn.Visible = cargoData.docked
	end
end

function CargoUI.setDocked(isDocked)
	if sellBtn then sellBtn.Visible = isDocked end
end

return CargoUI
