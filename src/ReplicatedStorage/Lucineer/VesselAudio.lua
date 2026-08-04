--!strict
-- VesselAudio.lua
-- Boat sound system: engine, water hull, anchor, foghorn, creaking, bilge
-- Part of Lucineer vessel experience

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local VesselAudio = {}

----------------------------------------------------------------
-- Types
----------------------------------------------------------------

export type VesselState = {
	throttle: number,      -- 0..1
	rpm: number,           -- 0..1 normalized
	speed: number,          -- studs/sec
	anchorDown: boolean,
	damage: number,         -- 0..1
	stormIntensity: number, -- 0..1 set externally
}

----------------------------------------------------------------
-- Constants
----------------------------------------------------------------
local ENGINE_IDLE_PITCH = 0.85
local ENGINE_MAX_PITCH = 1.8
local ENGINE_VOLUME_BASE = 0.35
local ENGINE_VOLUME_MAX = 0.7

local WATER_HULL_VOL_MAX = 0.45
local WATER_HULL_PITCH_BASE = 0.9

local CREAK_BASE_CHANCE = 0.002
local CREAK_STORM_SCALE = 0.01
local CREAK_VOL_BASE = 0.25

local BILGE_THRESHOLD = 0.3
local BILGE_VOLUME = 0.2

local FOGHORN_VOLUME = 0.6
local FOGHORN_PITCH = 0.8

local ANCHOR_CHAIN_VOL = 0.5

-- Placeholder asset IDs (replace with real uploads)
local ASSET = {
	EngineLoop   = "rbxassetid://9112979203",
	WaterHull    = "rbxassetid://9112979204",
	AnchorChain  = "rbxassetid://9112979205",
	Foghorn      = "rbxassetid://9112979206",
	Creak        = "rbxassetid://9112979207",
	BilgePump    = "rbxassetid://9112979208",
}

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local vesselModel: Model? = nil
local sounds: { [string]: Sound } = {}
local stormLevel: number = 0
local lastCreakCheck: number = 0
local bilgeActive: boolean = false

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function createSound(name: string, parentId: Instance, assetId: string, looping: boolean, volume: number): Sound
	local snd = Instance.new("Sound")
	snd.Name = name
	snd.SoundId = assetId
	snd.Looped = looping
	snd.Volume = volume
	snd.Parent = parentId
	return snd
end

local function attachToPart(part: BasePart, name: string, assetId: string, looping: boolean, volume: number): Sound
	local snd = createSound(name, part, assetId, looping, volume)
	snd.RollOffMaxDistance = 80
	snd.RollOffMinDistance = 6
	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	return snd
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

function VesselAudio.init(model: Model)
	vesselModel = model

	-- Find a primary part or hull part for 3D attachment
	local hullPart = model.PrimaryPart
	if not hullPart then
		-- Search for a hull-like part
		for _, child in ipairs(model:GetDescendants()) do
			if child:IsA("BasePart") and child.Name:lower():match("hull") then
				hullPart = child :: BasePart
				break
			end
		end
	end
	if not hullPart then
		warn("[VesselAudio] No hull part found; attaching sounds to model")
		-- Create a folder in the model as fallback
		local folder = Instance.new("Folder")
		folder.Name = "VesselAudio"
		folder.Parent = model
		-- Non-3D sounds
		sounds.EngineLoop = createSound("EngineLoop", folder, ASSET.EngineLoop, true, ENGINE_VOLUME_BASE)
		sounds.WaterHull = createSound("WaterHull", folder, ASSET.WaterHull, true, 0)
		sounds.AnchorChain = createSound("AnchorChain", folder, ASSET.AnchorChain, false, ANCHOR_CHAIN_VOL)
		sounds.Foghorn = createSound("Foghorn", folder, ASSET.Foghorn, false, FOGHORN_VOLUME)
		sounds.Creak = createSound("Creak", folder, ASSET.Creak, false, CREAK_VOL_BASE)
		sounds.BilgePump = createSound("BilgePump", folder, ASSET.BilgePump, true, 0)
		return
	end

	hullPart = hullPart :: BasePart

	-- 3D positioned sounds on the hull
	sounds.EngineLoop = attachToPart(hullPart, "EngineLoop", ASSET.EngineLoop, true, ENGINE_VOLUME_BASE)
	sounds.WaterHull = attachToPart(hullPart, "WaterHull", ASSET.WaterHull, true, 0)
	sounds.AnchorChain = attachToPart(hullPart, "AnchorChain", ASSET.AnchorChain, false, ANCHOR_CHAIN_VOL)
	sounds.Foghorn = attachToPart(hullPart, "Foghorn", ASSET.Foghorn, false, FOGHORN_VOLUME)
	sounds.Creak = attachToPart(hullPart, "Creak", ASSET.Creak, false, CREAK_VOL_BASE)
	sounds.BilgePump = attachToPart(hullPart, "BilgePump", ASSET.BilgePump, true, 0)

	-- Start engine and water loops immediately; they modulate via update
	sounds.EngineLoop:Play()
	sounds.WaterHull:Play()
	sounds.BilgePump:Play()

	print("[VesselAudio] Initialized on", model.Name)
end

function VesselAudio.update(state: VesselState)
	-- Engine: pitch by RPM, volume by throttle
	if sounds.EngineLoop then
		local targetPitch = lerp(ENGINE_IDLE_PITCH, ENGINE_MAX_PITCH, state.rpm)
		local targetVol = lerp(ENGINE_VOLUME_BASE, ENGINE_VOLUME_MAX, state.throttle)
		sounds.EngineLoop.PlaybackSpeed = targetPitch
		TweenService:Create(sounds.EngineLoop, TweenInfo.new(0.3), { Volume = targetVol }):Play()
	end

	-- Water against hull: volume by speed
	if sounds.WaterHull then
		local speedNorm = math.clamp(state.speed / 60, 0, 1)
		local targetVol = speedNorm * WATER_HULL_VOL_MAX
		local targetPitch = WATER_HULL_PITCH_BASE + speedNorm * 0.3
		sounds.WaterHull.PlaybackSpeed = targetPitch
		TweenService:Create(sounds.WaterHull, TweenInfo.new(0.5), { Volume = targetVol }):Play()
	end

	-- Creaking: random triggers, scales with storm + damage
	local creakChance = CREAK_BASE_CHANCE + (stormLevel * CREAK_STORM_SCALE) + (state.damage * 0.005)
	local now = os.clock()
	if now - lastCreakCheck > 0.5 then
		lastCreakCheck = now
		if math.random() < creakChance and sounds.Creak then
			sounds.Creak.PlaybackSpeed = 0.8 + math.random() * 0.4
			sounds.Creak.Volume = CREAK_VOL_BASE + stormLevel * 0.3 + state.damage * 0.2
			sounds.Creak:Play()
		end
	end

	-- Bilge pump: activates when taking water (damage or storm)
	local needBilge = state.damage > BILGE_THRESHOLD or stormLevel > 0.5
	if needBilge ~= bilgeActive and sounds.BilgePump then
		bilgeActive = needBilge
		local targetVol = needBilge and BILGE_VOLUME or 0
		TweenService:Create(sounds.BilgePump, TweenInfo.new(1.0), { Volume = targetVol }):Play()
	end
end

function VesselAudio.playHorn()
	if sounds.Foghorn then
		sounds.Foghorn.PlaybackSpeed = FOGHORN_PITCH
		sounds.Foghorn:Play()
	end
end

function VesselAudio.playAnchor()
	if sounds.AnchorChain then
		sounds.AnchorChain:Play()
	end
end

function VesselAudio.setStormIntensity(level: number)
	stormLevel = math.clamp(level, 0, 1)
end

function VesselAudio.cleanup()
	for _, snd in pairs(sounds) do
		snd:Stop()
		snd:Destroy()
	end
	sounds = {}
	vesselModel = nil
end

return VesselAudio
