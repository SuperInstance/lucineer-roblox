--!strict
-- UIAudio.lua
-- Interface feedback sounds: reel, tension, coin, fanfare, stamp, impact, alarm, klaxon
-- Part of Lucineer vessel experience

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local UIAudio = {}

----------------------------------------------------------------
-- Sound Registry
----------------------------------------------------------------

export type SoundName =
	"reelClick"
	| "tensionCreak"
	| "coin"
	| "eraFanfare"
	| "missionStamp"
	| "hullImpact"
	| "depthAlarm"
	| "stormKlaxon"

----------------------------------------------------------------
-- Asset IDs (placeholders — replace with real uploads)
----------------------------------------------------------------
local ASSET = {
	reelClick    = "rbxassetid://9112979230",
	tensionCreak = "rbxassetid://9112979231",
	coin         = "rbxassetid://9112979232",
	eraFanfare   = "rbxassetid://9112979233",
	missionStamp = "rbxassetid://9112979234",
	hullImpact   = "rbxassetid://9112979235",
	depthAlarm   = "rbxassetid://9112979236",
	stormKlaxon  = "rbxassetid://9112979237",
}

----------------------------------------------------------------
-- Per-sound config: volume, pitch, loop, duration
----------------------------------------------------------------
local SOUND_CONFIG: { [SoundName]: { volume: number, pitch: number, loop: boolean, duration: number } } = {
	reelClick    = { volume = 0.35, pitch = 1.1,  loop = false, duration = 0.3 },
	tensionCreak = { volume = 0.30, pitch = 0.95, loop = false, duration = 0.8 },
	coin         = { volume = 0.25, pitch = 1.0,  loop = false, duration = 0.5 },
	eraFanfare   = { volume = 0.50, pitch = 1.0,  loop = false, duration = 2.0 },
	missionStamp = { volume = 0.40, pitch = 1.0,  loop = false, duration = 0.4 },
	hullImpact   = { volume = 0.60, pitch = 0.7,  loop = false, duration = 0.6 },
	depthAlarm   = { volume = 0.35, pitch = 1.3,  loop = true,  duration = 0.5 },
	stormKlaxon  = { volume = 0.45, pitch = 0.85, loop = true,  duration = 1.0 },
}

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local soundFolder: Instance?
local activeLooping: { [string]: Sound } = {}

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function getOrCreateFolder(): Instance
	if not soundFolder or not soundFolder.Parent then
		soundFolder = Instance.new("Folder")
		soundFolder.Name = "UIAudio"
		soundFolder.Parent = SoundService
	end
	return soundFolder
end

local function makeSound(name: SoundName): Sound
	local cfg = SOUND_CONFIG[name]
	local snd = Instance.new("Sound")
	snd.Name = name
	snd.SoundId = ASSET[name]
	snd.Volume = cfg.volume
	snd.PlaybackSpeed = cfg.pitch
	snd.Looped = cfg.loop
	snd.Parent = getOrCreateFolder()
	return snd
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

function UIAudio.init()
	-- Pre-create the folder
	getOrCreateFolder()
	print("[UIAudio] Initialized")
end

function UIAudio.play(name: SoundName): Sound?
	local cfg = SOUND_CONFIG[name]
	if not cfg then
		warn("[UIAudio] Unknown sound:", tostring(name))
		return nil
	end

	-- For looping sounds, track and stop previous instance
	if cfg.loop then
		local existing = activeLooping[name]
		if existing then
			existing:Stop()
			existing:Destroy()
		end
	end

	local snd = makeSound(name)
	snd:Play()

	if cfg.loop then
		activeLooping[name] = snd
	else
		-- Auto-cleanup after duration + small buffer
		task.delay(cfg.duration + 0.5, function()
			if snd and snd.Parent then
				snd:Destroy()
			end
		end)
	end

	return snd
end

function UIAudio.stop(name: SoundName)
	local snd = activeLooping[name]
	if snd then
		-- Fade out quickly
		TweenService:Create(snd, TweenInfo.new(0.3), { Volume = 0 }):Play()
		task.delay(0.35, function()
			if snd and snd.Parent then
				snd:Stop()
				snd:Destroy()
			end
		end)
		activeLooping[name] = nil
	end
end

function UIAudio.stopAll()
	for name, snd in pairs(activeLooping) do
		TweenService:Create(snd, TweenInfo.new(0.3), { Volume = 0 }):Play()
		task.delay(0.35, function()
			if snd and snd.Parent then
				snd:Stop()
				snd:Destroy()
			end
		end)
	end
	activeLooping = {}
end

function UIAudio.playWithPitch(name: SoundName, pitch: number): Sound?
	local snd = UIAudio.play(name)
	if snd then
		snd.PlaybackSpeed = pitch
	end
	return snd
end

-- Convenience: play a sound with a one-off volume override
function UIAudio.playAtVolume(name: SoundName, volume: number): Sound?
	local snd = UIAudio.play(name)
	if snd then
		snd.Volume = volume
	end
	return snd
end

function UIAudio.cleanup()
	UIAudio.stopAll()
	if soundFolder then
		soundFolder:Destroy()
		soundFolder = nil
	end
end

return UIAudio
