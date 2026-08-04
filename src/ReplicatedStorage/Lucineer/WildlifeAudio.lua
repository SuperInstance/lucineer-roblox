--!strict
-- WildlifeAudio.lua
-- Living ocean sounds: gulls, whales, porpoises, fish splashes
-- Part of Lucineer vessel experience

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local WildlifeAudio = {}

----------------------------------------------------------------
-- Types
----------------------------------------------------------------

export type WildlifeType = "gull" | "whale" | "porpoise" | "fishSplash"

----------------------------------------------------------------
-- Constants
----------------------------------------------------------------
local GULL_VOL = 0.3
local GULL_AGGRESSIVE_VOL = 0.45
local GULL_DAY_CHANCE = 0.015
local GULL_NIGHT_CHANCE = 0.0
local GULL_SHORE_BONUS = 0.02

local WHALE_VOL = 0.4
local WHALE_CHANCE = 0.0005 -- rare
local WHALE_DEEP_OCEAN_DIST = 500

local PORPOISE_VOL = 0.25
local PORPOISE_CHANCE = 0.003

local FISH_SPLASH_VOL = 0.2
local FISH_SPLASH_CHANCE = 0.01

local MAX_3D_DIST = 200

-- Placeholder asset IDs — multiple variations per type
local ASSET = {
	Gull1     = "rbxassetid://9112979220",
	Gull2     = "rbxassetid://9112979221",
	Gull3     = "rbxassetid://9112979222",
	WhaleBlow = "rbxassetid://9112979223",
	Porpoise1 = "rbxassetid://9112979224",
	Porpoise2 = "rbxassetid://9112979225",
	FishSplash = "rbxassetid://9112979226",
}

local GULL_SOUNDS = { ASSET.Gull1, ASSET.Gull2, ASSET.Gull3 }
local PORPOISE_SOUNDS = { ASSET.Porpoise1, ASSET.Porpoise2 }

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local sounds: { [string]: Sound } = {}
local initialized = false
local activeGulls: { Sound } = {}
local fishZones: { Vector3 } = {} -- active fish zones for splash origin

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function pickRandom(list: { string }): string
	return list[math.random(1, #list)]
end

local function playOneShot(assetId: string, volume: number, pitch: number?, parent: Instance?)
	local snd = Instance.new("Sound")
	snd.SoundId = assetId
	snd.Volume = volume
	snd.PlaybackSpeed = pitch or (0.9 + math.random() * 0.2)
	snd.Looped = false

	if parent then
		snd.Parent = parent
		snd.RollOffMaxDistance = MAX_3D_DIST
		snd.RollOffMinDistance = 10
		snd.RollOffMode = Enum.RollOffMode.InverseTapered
	else
		snd.Parent = Workspace
	end

	snd:Play()

	-- Auto-cleanup after playback
	snd.Ended:Connect(function()
		snd:Destroy()
	end)

	-- Safety cleanup
	task.delay(15, function()
		if snd and snd.Parent then
			snd:Destroy()
		end
	end)

	return snd
end

local function randomOffsetFromPlayer(playerPos: Vector3, minDist: number, maxDist: number): Vector3
	local angle = math.random() * math.pi * 2
	local dist = minDist + math.random() * (maxDist - minDist)
	return playerPos + Vector3.new(
		math.cos(angle) * dist,
		0,
		math.sin(angle) * dist
	)
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

function WildlifeAudio.init()
	local container = Instance.new("Folder")
	container.Name = "WildlifeAudio"
	container.Parent = Workspace

	-- Pre-create persistent gull sounds for ambient flock effect
	for i = 1, 3 do
		local gull = Instance.new("Sound")
		gull.Name = "AmbientGull" .. tostring(i)
		gull.SoundId = GULL_SOUNDS[i]
		gull.Volume = 0
		gull.Looped = false
		gull.Parent = container
		gull.RollOffMaxDistance = MAX_3D_DIST
		gull.RollOffMinDistance = 10
		gull.RollOffMode = Enum.RollOffMode.InverseTapered
		table.insert(activeGulls, gull)
	end

	initialized = true
	print("[WildlifeAudio] Initialized")
end

function WildlifeAudio.update(playerPos: Vector3, timeOfDay: number, hasFishOnDeck: boolean)
	if not initialized then return end

	local isDaytime = timeOfDay > 0.25 and timeOfDay < 0.75
	local distFromShore = playerPos.Magnitude -- simplified: origin = shore

	-- Gulls: more near shore, silent at night, aggressive when fish on deck
	local gullChance = GULL_DAY_CHANCE
	if not isDaytime then
		gullChance = GULL_NIGHT_CHANCE
	end
	if distFromShore < WHALE_DEEP_OCEAN_DIST then
		gullChance += GULL_SHORE_BONUS
	end

	if math.random() < gullChance then
		local vol = hasFishOnDeck and GULL_AGGRESSIVE_VOL or GULL_VOL
		local pitch = hasFishOnDeck and (1.1 + math.random() * 0.3) or (0.9 + math.random() * 0.3)
		local pos = randomOffsetFromPlayer(playerPos, 20, 80)

		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.Transparency = 1
		part.Position = pos
		part.Parent = Workspace

		local snd = playOneShot(pickRandom(GULL_SOUNDS), vol, pitch, part)

		-- Cleanup part after sound finishes
		snd.Ended:Connect(function()
			if part and part.Parent then
				part:Destroy()
			end
		end)
	end

	-- Whale blows: rare, deep ocean only
	if distFromShore > WHALE_DEEP_OCEAN_DIST and math.random() < WHALE_CHANCE then
		local pos = randomOffsetFromPlayer(playerPos, 60, 150)
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.Transparency = 1
		part.Position = pos
		part.Parent = Workspace

		local snd = playOneShot(ASSET.WhaleBlow, WHALE_VOL, 0.8 + math.random() * 0.2, part)
		snd.Ended:Connect(function()
			if part and part.Parent then part:Destroy() end
		end)
	end

	-- Porpoise clicks
	if math.random() < PORPOISE_CHANCE then
		local pos = randomOffsetFromPlayer(playerPos, 30, 100)
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.Transparency = 1
		part.Position = pos
		part.Parent = Workspace

		local snd = playOneShot(pickRandom(PORPOISE_SOUNDS), PORPOISE_VOL, 1.0 + math.random() * 0.3, part)
		snd.Ended:Connect(function()
			if part and part.Parent then part:Destroy() end
		end)
	end

	-- Fish surface splashes in active zones
	if #fishZones > 0 and math.random() < FISH_SPLASH_CHANCE then
		local zone = fishZones[math.random(1, #fishZones)]
		local pos = zone + Vector3.new(
			(math.random() - 0.5) * 20,
			0,
			(math.random() - 0.5) * 20
		)
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.Transparency = 1
		part.Position = pos
		part.Parent = Workspace

		local snd = playOneShot(ASSET.FishSplash, FISH_SPLASH_VOL, 0.9 + math.random() * 0.3, part)
		snd.Ended:Connect(function()
			if part and part.Parent then part:Destroy() end
		end)
	end
end

function WildlifeAudio.spawnWildlifeEvent(wildlifeType: WildlifeType)
	if not initialized then return end

	if wildlifeType == "gull" then
		playOneShot(pickRandom(GULL_SOUNDS), GULL_VOL)
	elseif wildlifeType == "whale" then
		playOneShot(ASSET.WhaleBlow, WHALE_VOL, 0.8)
	elseif wildlifeType == "porpoise" then
		playOneShot(pickRandom(PORPOISE_SOUNDS), PORPOISE_VOL)
	elseif wildlifeType == "fishSplash" then
		playOneShot(ASSET.FishSplash, FISH_SPLASH_VOL)
	end
end

-- Register active fish zones for ambient splashes
function WildlifeAudio.setFishZones(zones: { Vector3 })
	fishZones = zones
end

function WildlifeAudio.cleanup()
	for _, snd in ipairs(activeGulls) do
		snd:Destroy()
	end
	activeGulls = {}
	fishZones = {}
	initialized = false
end

return WildlifeAudio
