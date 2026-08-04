-- ChartUI.lua
-- Nautical chart overlay — top-down map, player blip, depth contours,
-- fish zones, nav marks, GPS label, click-to-set waypoint.

local ChartUI = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BRASS = Color3.fromRGB(180, 140, 60)
local DARK_BG = Color3.fromRGB(28, 32, 38)
local DARK_FRAME = Color3.fromRGB(38, 42, 50)
local TEXT_LIGHT = Color3.fromRGB(210, 210, 200)
local OCEAN = Color3.fromRGB(20, 50, 80)
local SHALLOW = Color3.fromRGB(40, 120, 90)
local DEEP = Color3.fromRGB(15, 40, 70)
local DANGER = Color3.fromRGB(140, 40, 30)
local FISH_COLOR = Color3.fromRGB(80, 180, 200)
local NAV_YELLOW = Color3.fromRGB(200, 180, 50)

local gui
local mapCanvas
local playerBlip
local waypointMarker
local gpsLabel
local markers = {}  -- {type, pos, label, guiObj}
local connection
local visible = false

-- Map scale: how many studs per pixel on the chart
local SCALE = 0.5
local MAP_SIZE = 400
local CENTER = MAP_SIZE / 2

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

local function worldToMap(worldPos)
	-- Convert world position to map canvas position
	return CENTER + worldPos.X * SCALE, CENTER + worldPos.Z * SCALE
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "ChartUI"
	gui.ResetOnSpawn = false
	gui.Enabled = false

	-- Map frame
	local mapFrame = Instance.new("Frame")
	mapFrame.Name = "MapFrame"
	mapFrame.Size = UDim2.new(0, MAP_SIZE, 0, MAP_SIZE)
	mapFrame.Position = UDim2.new(0.5, -MAP_SIZE / 2, 0.5, -MAP_SIZE / 2)
	mapFrame.BackgroundColor3 = DARK_FRAME
	mapFrame.BorderSizePixel = 3
	mapFrame.BorderColor3 = BRASS
	mapFrame.ClipsDescendants = true
	mapFrame.Parent = gui

	-- Ocean canvas
	mapCanvas = Instance.new("Frame")
	mapCanvas.Name = "Canvas"
	mapCanvas.Size = UDim2.new(0, MAP_SIZE, 0, MAP_SIZE)
	mapCanvas.BackgroundColor3 = OCEAN
	mapCanvas.BorderSizePixel = 0
	mapCanvas.Parent = mapFrame

	-- Depth contour bands (concentric rectangles)
	for i = 1, 5 do
		local band = Instance.new("Frame")
		band.Name = "Contour" .. i
		local inset = i * 30
		band.Size = UDim2.new(0, MAP_SIZE - inset * 2, 0, MAP_SIZE - inset * 2)
		band.Position = UDim2.new(0, inset, 0, inset)
		band.BackgroundTransparency = 1
		band.BorderSizePixel = 1
		band.BorderColor3 = i <= 2 and SHALLOW or (i >= 4 and DEEP or Color3.fromRGB(30, 70, 100))
		band.Parent = mapCanvas
	end

	-- Grid lines
	for i = 0, 8 do
		local vline = Instance.new("Frame")
		vline.Size = UDim2.new(0, 1, 0, MAP_SIZE)
		vline.Position = UDim2.new(0, i * (MAP_SIZE / 8), 0, 0)
		vline.BackgroundColor3 = Color3.fromRGB(30, 60, 80)
		vline.BorderSizePixel = 0
		vline.ZIndex = 1
		vline.Parent = mapCanvas

		local hline = Instance.new("Frame")
		hline.Size = UDim2.new(0, MAP_SIZE, 0, 1)
		hline.Position = UDim2.new(0, 0, 0, i * (MAP_SIZE / 8))
		hline.BackgroundColor3 = Color3.fromRGB(30, 60, 80)
		hline.BorderSizePixel = 0
		hline.ZIndex = 1
		hline.Parent = mapCanvas
	end

	-- Player blip (triangle-ish — using a small rotated frame)
	playerBlip = Instance.new("Frame")
	playerBlip.Name = "PlayerBlip"
	playerBlip.Size = UDim2.new(0, 10, 0, 10)
	playerBlip.Position = UDim2.new(0.5, -5, 0.5, -5)
	playerBlip.BackgroundColor3 = BRASS
	playerBlip.BorderSizePixel = 1
	playerBlip.BorderColor3 = TEXT_LIGHT
	playerBlip.ZIndex = 5
	playerBlip.Parent = mapCanvas

	-- Player direction arrow
	local arrow = Instance.new("Frame")
	arrow.Name = "DirArrow"
	arrow.Size = UDim2.new(0, 2, 0, 12)
	arrow.Position = UDim2.new(0.5, -1, 0, -10)
	arrow.BackgroundColor3 = BRASS
	arrow.BorderSizePixel = 0
	arrow.ZIndex = 5
	arrow.Parent = playerBlip

	-- Waypoint marker
	waypointMarker = Instance.new("Frame")
	waypointMarker.Name = "Waypoint"
	waypointMarker.Size = UDim2.new(0, 8, 0, 8)
	waypointMarker.Position = UDim2.new(0.5, -4, 0.5, -4)
	waypointMarker.BackgroundColor3 = DANGER
	waypointMarker.BorderSizePixel = 0
	waypointMarker.Visible = false
	waypointMarker.ZIndex = 4
	waypointMarker.Parent = mapCanvas

	-- Click to set waypoint
	mapCanvas.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local mousePos = input.Position
			local relX = mousePos.X - mapCanvas.AbsolutePosition.X
			local relY = mousePos.Y - mapCanvas.AbsolutePosition.Y
			waypointMarker.Position = UDim2.new(0, relX - 4, 0, relY - 4)
			waypointMarker.Visible = true
		end
	end)

	-- Title bar
	createLabel(mapFrame, "NAUTICAL CHART", UDim2.new(0, 0, 0, -22), UDim2.new(1, 0, 0, 18), BRASS)

	-- GPS label (bottom of map)
	gpsLabel = Instance.new("TextLabel")
	gpsLabel.Name = "GPS"
	gpsLabel.BackgroundTransparency = 1
	gpsLabel.Position = UDim2.new(0, 4, 1, -18)
	gpsLabel.Size = UDim2.new(1, -8, 0, 14)
	gpsLabel.Font = Enum.Font.Code
	gpsLabel.Text = "X: 0  Z: 0  HDG 000°"
	gpsLabel.TextColor3 = BRASS
	gpsLabel.TextScaled = true
	gpsLabel.TextXAlignment = Enum.TextXAlignment.Left
	gpsLabel.Parent = mapFrame

	-- Legend (right side of map)
	local legend = Instance.new("Frame")
	legend.Name = "Legend"
	legend.Size = UDim2.new(0, 120, 0, 120)
	legend.Position = UDim2.new(1, 8, 0, 0)
	legend.BackgroundColor3 = DARK_BG
	legend.BorderSizePixel = 1
	legend.BorderColor3 = BRASS
	legend.Parent = mapFrame

	createLabel(legend, "Legend", UDim2.new(0, 4, 0, 2), UDim2.new(1, -8, 0, 14), BRASS)
	createLabel(legend, "● Player", UDim2.new(0, 4, 0, 18), UDim2.new(1, -8, 0, 12), BRASS)
	createLabel(legend, "◆ Fish Zone", UDim2.new(0, 4, 0, 34), UDim2.new(1, -8, 0, 12), FISH_COLOR)
	createLabel(legend, "▲ Hazard", UDim2.new(0, 4, 0, 50), UDim2.new(1, -8, 0, 12), DANGER)
	createLabel(legend, "◆ Buoy", UDim2.new(0, 4, 0, 66), UDim2.new(1, -8, 0, 12), NAV_YELLOW)
	createLabel(legend, "★ Lighthouse", UDim2.new(0, 4, 0, 82), UDim2.new(1, -8, 0, 12), Color3.fromRGB(255, 220, 100))
	createLabel(legend, "[C] Close", UDim2.new(0, 4, 1, -14), UDim2.new(1, -8, 0, 12), TEXT_LIGHT)

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

function ChartUI.init()
	build()

	-- C key toggles handled externally, but support it here too
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.C then
			ChartUI.toggle()
		end
	end)
end

function ChartUI.show()
	if gui then
		gui.Enabled = true
		visible = true
	end
end

function ChartUI.hide()
	if gui then
		gui.Enabled = false
		visible = false
	end
end

function ChartUI.toggle()
	if visible then
		ChartUI.hide()
	else
		ChartUI.show()
	end
end

function ChartUI.update(playerPos, heading)
	if not gui then return end

	-- Position blip at center; shift the canvas underneath instead
	-- (Simpler: just show player at center and offset markers)

	-- Update GPS label
	local x = math.floor(playerPos.X)
	local z = math.floor(playerPos.Z)
	local hdg = math.floor((heading or 0) + 0.5) % 360
	gpsLabel.Text = string.format("X: %d  Z: %d  HDG %03d°", x, z, hdg)

	-- Rotate blip arrow
	playerBlip.DirArrow.Rotation = (heading or 0) - 90

	-- Update marker positions relative to player
	for _, m in ipairs(markers) do
		local relX = (m.pos.X - playerPos.X) * SCALE
		local relZ = (m.pos.Z - playerPos.Z) * SCALE
		local mapX = CENTER + relX
		local mapY = CENTER + relZ
		m.guiObj.Position = UDim2.new(0, mapX - m.guiObj.Size.X.Offset / 2, 0, mapY - m.guiObj.Size.Y.Offset / 2)

		-- Hide markers outside canvas
		m.guiObj.Visible = (mapX >= 0 and mapX <= MAP_SIZE and mapY >= 0 and mapY <= MAP_SIZE)
	end
end

function ChartUI.addMarker(markerType, worldPos, label)
	if not mapCanvas then return end

	local color, symbol
	if markerType == "fish" then
		color = FISH_COLOR
		symbol = "◆"
	elseif markerType == "hazard" then
		color = DANGER
		symbol = "▲"
	elseif markerType == "buoy" then
		color = NAV_YELLOW
		symbol = "◆"
	elseif markerType == "lighthouse" then
		color = Color3.fromRGB(255, 220, 100)
		symbol = "★"
	elseif markerType == "island" then
		color = Color3.fromRGB(100, 140, 70)
		symbol = "■"
	else
		color = TEXT_LIGHT
		symbol = "•"
	end

	local marker = Instance.new("TextLabel")
	marker.Name = "Marker_" .. (label or markerType)
	marker.Size = UDim2.new(0, 14, 0, 14)
	marker.BackgroundColor3 = color
	marker.BackgroundTransparency = 0.2
	marker.BorderSizePixel = 0
	marker.Font = Enum.Font.Code
	marker.Text = ""
	marker.TextColor3 = color
	marker.TextScaled = true
	marker.ZIndex = 3
	marker.Parent = mapCanvas

	-- Small label below marker
	if label then
		local mlbl = Instance.new("TextLabel")
		mlbl.BackgroundTransparency = 1
		mlbl.Position = UDim2.new(0, -10, 1, 0)
		mlbl.Size = UDim2.new(0, 40, 0, 10)
		mlbl.Font = Enum.Font.Code
		mlbl.Text = label
		mlbl.TextColor3 = TEXT_LIGHT
		mlbl.TextScaled = true
		mlbl.Parent = marker
	end

	table.insert(markers, { type = markerType, pos = worldPos, label = label, guiObj = marker })
end

return ChartUI
