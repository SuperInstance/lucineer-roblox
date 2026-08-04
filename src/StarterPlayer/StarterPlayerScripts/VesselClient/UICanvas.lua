-- UICanvas.lua
-- Master controller: manages which vessel UIs are visible based on game state.
-- Receives state changes from server via RemoteEvents, routes updates to child UIs.

local UICanvas = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local HelmUI = require(script.Parent:WaitForChild("HelmUI"))
local FishingUI = require(script.Parent:WaitForChild("FishingUI"))
local ChartUI = require(script.Parent:WaitForChild("ChartUI"))
local CargoUI = require(script.Parent:WaitForChild("CargoUI"))
local VesselStateUI = require(script.Parent:WaitForChild("VesselStateUI"))

-- State enum
UICanvas.States = {
	IN_YARD = "IN_YARD",
	AT_DOCK = "AT_DOCK",
	UNDERWAY = "UNDERWAY",
	FISHING = "FISHING",
}

local currentState = nil
local remoteFolder

local STATE_VISIBILITY = {
	[UICanvas.States.IN_YARD] = {},
	[UICanvas.States.AT_DOCK] = { cargo = true, vesselState = true },
	[UICanvas.States.UNDERWAY] = { helm = true, vesselState = true, chart = "available" },
	[UICanvas.States.FISHING] = { fishing = true, vesselState = true },
}

local function applyVisibility(state)
	local vis = STATE_VISIBILITY[state] or {}

	HelmUI.hide()
	FishingUI.hide()
	ChartUI.hide()
	CargoUI.hide()
	VesselStateUI.hide()

	if vis.helm then HelmUI.show() end
	if vis.fishing then FishingUI.show() end
	if vis.cargo then CargoUI.show() end
	if vis.vesselState then VesselStateUI.show() end
	-- Chart is "available" but player toggles it manually via [C]
	if vis.chart == "available" then
		-- ChartUI.show() is NOT called; player presses C to toggle
		-- but we make sure it's hidden when entering UNDERWAY
		ChartUI.hide()
	end
end

function UICanvas.init()
	-- Initialize all child UIs
	HelmUI.init()
	FishingUI.init()
	ChartUI.init()
	CargoUI.init()
	VesselStateUI.init()

	-- Connect to RemoteEvents from server
	remoteFolder = ReplicatedStorage:WaitForChild("VesselRemotes", 5)
	if remoteFolder then
		local stateEvent = remoteFolder:FindFirstChild("StateChange")
		if stateEvent then
			stateEvent.OnClientEvent:Connect(function(state)
				UICanvas.setState(state)
			end)
		end

		local updateEvent = remoteFolder:FindFirstChild("UIUpdate")
		if updateEvent then
			updateEvent.OnClientEvent:Connect(function(eventType, data)
				UICanvas.handleRemoteEvent(eventType, data)
			end)
		end
	end

	-- Default state
	UICanvas.setState(UICanvas.States.IN_YARD)
end

function UICanvas.setState(state)
	if currentState == state then return end
	currentState = state
	applyVisibility(state)
end

function UICanvas.getState()
	return currentState
end

function UICanvas.handleRemoteEvent(eventType, data)
	if eventType == "helm" then
		HelmUI.update(data)
	elseif eventType == "fishing" then
		if data.tension ~= nil then
			FishingUI.update(data.tension, data.fishData)
		end
	elseif eventType == "fishingResult" then
		FishingUI.showResult(data)
	elseif eventType == "chart" then
		local player = Players.LocalPlayer
		if player and player.Character then
			local hrp = player.Character:FindFirstChild("HumanoidRootPart")
			if hrp then
				ChartUI.update(hrp.Position, data.heading or 0)
			end
		end
	elseif eventType == "chartMarker" then
		ChartUI.addMarker(data.markerType, data.position, data.label)
	elseif eventType == "cargo" then
		CargoUI.update(data)
	elseif eventType == "vesselState" then
		VesselStateUI.update(data)
	end
end

return UICanvas
