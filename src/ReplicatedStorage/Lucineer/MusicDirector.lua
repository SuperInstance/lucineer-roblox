--!strict
-- MusicDirector.lua
-- Adaptive layered music system with mood states and stem crossfading
-- Part of Lucineer vessel experience

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local MusicDirector = {}

----------------------------------------------------------------
-- Types
----------------------------------------------------------------

export type Mood =
	"calm_sea"
	| "storm"
	| "night_fishing"
	| "harbor"
	| "era_ceremony"
	| "big_catch"
	| "silence"

export type Stem = {
	sound: Sound,
	role: string, -- "melody" | "harmony" | "rhythm"
	targetVolume: number,
}

----------------------------------------------------------------
-- Constants
----------------------------------------------------------------
local DEFAULT_FADE = 4.0
local STEM_FADE = 3.0

-- Placeholder asset IDs per mood/stem
local MOOD_ASSETS: { [Mood]: { { id: string, role: string, volume: number } } } = {
	calm_sea = {
		{ id = "rbxassetid://9112979240", role = "melody",  volume = 0.25 },
		{ id = "rbxassetid://9112979241", role = "harmony", volume = 0.18 },
		{ id = "rbxassetid://9112979242", role = "rhythm",  volume = 0.10 },
	},
	storm = {
		{ id = "rbxassetid://9112979243", role = "melody",  volume = 0.30 },
		{ id = "rbxassetid://9112979244", role = "harmony", volume = 0.25 },
		{ id = "rbxassetid://9112979245", role = "rhythm",  volume = 0.28 },
	},
	night_fishing = {
		{ id = "rbxassetid://9112979246", role = "melody",  volume = 0.20 },
		{ id = "rbxassetid://9112979247", role = "harmony", volume = 0.15 },
	},
	harbor = {
		{ id = "rbxassetid://9112979248", role = "melody",  volume = 0.28 },
		{ id = "rbxassetid://9112979249", role = "rhythm",  volume = 0.18 },
	},
	era_ceremony = {
		{ id = "rbxassetid://9112979250", role = "melody",  volume = 0.35 },
		{ id = "rbxassetid://9112979251", role = "harmony", volume = 0.28 },
		{ id = "rbxassetid://9112979252", role = "rhythm",  volume = 0.22 },
	},
	big_catch = {
		{ id = "rbxassetid://9112979253", role = "melody",  volume = 0.32 },
		{ id = "rbxassetid://9112979254", role = "rhythm",  volume = 0.25 },
	},
	silence = {},
}

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local musicFolder: Instance?
local currentMood: Mood = "silence"
local currentStems: { Stem } = {}
local initialized = false

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function getOrCreateFolder(): Instance
	if not musicFolder or not musicFolder.Parent then
		musicFolder = Instance.new("Folder")
		musicFolder.Name = "MusicDirector"
		musicFolder.Parent = SoundService
	end
	return musicFolder
end

local function fadeOutAndDestroy(snd: Sound, fadeTime: number)
	TweenService:Create(snd, TweenInfo.new(fadeTime), { Volume = 0 }):Play()
	task.delay(fadeTime + 0.2, function()
		snd:Stop()
		snd:Destroy()
	end)
end

local function fadeIn(snd: Sound, targetVolume: number, fadeTime: number)
	snd.Volume = 0
	snd:Play()
	TweenService:Create(snd, TweenInfo.new(fadeTime), { Volume = targetVolume }):Play()
end

local function randomizePlaybackSpeed(snd: Sound)
	-- Slight pitch variation to avoid obvious looping
	snd.PlaybackSpeed = 0.98 + math.random() * 0.04
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

function MusicDirector.init()
	getOrCreateFolder()
	initialized = true
	print("[MusicDirector] Initialized (mood: silence)")
end

function MusicDirector.setMood(mood: Mood)
	if not initialized then
		warn("[MusicDirector] Not initialized; call init() first")
		return
	end
	if mood == currentMood then return end
	MusicDirector.transitionTo(mood, STEM_FADE)
end

function MusicDirector.transitionTo(mood: Mood, fadeTime: number)
	if not initialized then return end
	if mood == currentMood then return end

	local folder = getOrCreateFolder()
	local newStemData = MOOD_ASSETS[mood]

	-- Fade out all current stems
	for _, stem in ipairs(currentStems) do
		fadeOutAndDestroy(stem.sound, fadeTime)
	end
	currentStems = {}

	-- Handle silence: just let everything fade out
	if mood == "silence" then
		currentMood = "silence"
		print("[MusicDirector] Mood → silence")
		return
	end

	-- Create and fade in new stems
	for _, data in ipairs(newStemData) do
		local snd = Instance.new("Sound")
		snd.Name = mood .. "_" .. data.role
		snd.SoundId = data.id
		snd.Looped = true
		snd.Parent = folder
		randomizePlaybackSpeed(snd)

		fadeIn(snd, data.volume, fadeTime)

		local stem: Stem = {
			sound = snd,
			role = data.role,
			targetVolume = data.volume,
		}
		table.insert(currentStems, stem)
	end

	currentMood = mood
	print("[MusicDirector] Mood →", mood, "(" .. #newStemData .. " stems)")
end

-- Adjust individual stem volumes dynamically (e.g., duck music during dialogue)
function MusicDirector.duckStems(amount: number)
	amount = math.clamp(amount, 0, 1)
	for _, stem in ipairs(currentStems) do
		TweenService:Create(stem.sound, TweenInfo.new(0.5), {
			Volume = stem.targetVolume * amount,
		}):Play()
	end
end

function MusicDirector.restoreStems()
	for _, stem in ipairs(currentStems) do
		TweenService:Create(stem.sound, TweenInfo.new(0.5), {
			Volume = stem.targetVolume,
		}):Play()
	end
end

function MusicDirector.getCurrentMood(): Mood
	return currentMood
end

function MusicDirector.cleanup()
	for _, stem in ipairs(currentStems) do
		stem.sound:Stop()
		stem.sound:Destroy()
	end
	currentStems = {}
	currentMood = "silence"
	if musicFolder then
		musicFolder:Destroy()
		musicFolder = nil
	end
	initialized = false
end

return MusicDirector
