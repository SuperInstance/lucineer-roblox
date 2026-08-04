--!strict
-- EnvironmentAudio.lua
-- Ocean atmosphere: layered waves, wind, rain, thunder, foghorn, bell buoy
-- Part of Lucineer vessel experience

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local EnvironmentAudio = {}

----------------------------------------------------------------
-- Types
----------------------------------------------------------------

export type WeatherState = {
	windSpeed: number,       -- studs/sec
	precipitation: number,   -- 0..1
	fogLevel: number,        -- 0..1
	stormIntensity: number,  -- 0..1
	isDaytime: boolean,
}

----------------------------------------------------------------
-- Constants
----------------------------------------------------------------
local WAVE_CALM_VOL = 0.3
local WAVE_STORM_VOL = 0.55
local WIND_BASE_VOL = 0.15
local WIND_MAX_VOL = 0.45
local WIND_BASE_PITCH = 0.85
local WIND_MAX_PITCH = 1.4
local RAIN_MAX_VOL = 0.35
local FOGHORN_INTERVAL = 30 -- seconds
local FOG_FOGHORN_VOL = 0.25
local BUOY_MIN_DELAY = 8
local BUOY_MAX_DELAY = 25
local BUOY_VOL = 0.15
local THUNDER_BASE_VOL = 0.6

-- Placeholder asset IDs
local ASSET = {
	WaveCalm    = "rbxassetid://9112979210",
	WaveStorm   = "rbxassetid://9112979211",
	Wind        = "rbxassetid://9112979212",
	Rain        = "rbxassetid://9112979213",
	Thunder     = "rbxassetid://9112979214",
	LighthouseHorn = "rbxassetid://9112979215",
	BellBuoy    = "rbxassetid://9112979216",
}

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local sounds: { [string]: Sound } = {}
local initialized = false
local lastFoghorn = 0
local nextBuoyRing = 0
local thunderQueue: { { time: number, distance: number } } = {}

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

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function tweenVolume(snd: Sound, target: number, fadeTime: number)
	TweenService:Create(snd, TweenInfo.new(fadeTime), { Volume = target }):Play()
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

function EnvironmentAudio.init()
	local container = Instance.new("Folder")
	container.Name = "EnvironmentAudio"
	container.Parent = Workspace

	-- Wave layers: calm + storm crossfade
	sounds.WaveCalm = createSound("WaveCalm", container, ASSET.WaveCalm, true, WAVE_CALM_VOL)
	sounds.WaveStorm = createSound("WaveStorm", container, ASSET.WaveStorm, true, 0)
	sounds.Wind = createSound("Wind", container, ASSET.Wind, true, WIND_BASE_VOL)
	sounds.Rain = createSound("Rain", container, ASSET.Rain, true, 0)
	sounds.Thunder = createSound("Thunder", container, ASSET.Thunder, false, THUNDER_BASE_VOL)
	sounds.LighthouseHorn = createSound("LighthouseHorn", container, ASSET.LighthouseHorn, false, FOG_FOGHORN_VOL)
	sounds.BellBuoy = createSound("BellBuoy", container, ASSET.BellBuoy, false, BUOY_VOL)

	-- Start ambient loops
	sounds.WaveCalm:Play()
	sounds.WaveStorm:Play()
	sounds.Wind:Play()
	sounds.Rain:Play()

	-- Schedule first buoy ring
	nextBuoyRing = os.clock() + math.random(BUOY_MIN_DELAY, BUOY_MAX_DELAY)

	initialized = true
	print("[EnvironmentAudio] Initialized")
end

function EnvironmentAudio.update(state: WeatherState)
	if not initialized then return end
	local storm = state.stormIntensity

	-- Wave crossfade: calm fades down, storm fades up
	tweenVolume(sounds.WaveCalm, lerp(WAVE_CALM_VOL, 0, storm), 2)
	tweenVolume(sounds.WaveStorm, lerp(0, WAVE_STORM_VOL, storm), 2)

	-- Wind: pitch and volume by wind speed
	local windNorm = math.clamp(state.windSpeed / 80, 0, 1)
	sounds.Wind.PlaybackSpeed = lerp(WIND_BASE_PITCH, WIND_MAX_PITCH, windNorm)
	tweenVolume(sounds.Wind, lerp(WIND_BASE_VOL, WIND_MAX_VOL, windNorm), 1)

	-- Rain: volume by precipitation
	tweenVolume(sounds.Rain, state.precipitation * RAIN_MAX_VOL, 1)

	-- Foghorn from lighthouse in fog
	local now = os.clock()
	if state.fogLevel > 0.3 and now - lastFoghorn > FOGHORN_INTERVAL then
		lastFoghorn = now
		sounds.LighthouseHorn.Volume = FOG_FOGHORN_VOL * state.fogLevel
		sounds.LighthouseHorn:Play()
	end

	-- Bell buoy random rings
	if now > nextBuoyRing then
		nextBuoyRing = now + math.random(BUOY_MIN_DELAY, BUOY_MAX_DELAY)
		sounds.BellBuoy.PlaybackSpeed = 0.9 + math.random() * 0.2
		sounds.BellBuoy:Play()
	end

	-- Process queued thunder
	local i = 1
	while i <= #thunderQueue do
		local entry = thunderQueue[i]
		if now >= entry.time then
			-- Volume drops with distance; 3 seconds per 1km roughly
			local distFactor = math.clamp(1.0 / (1.0 + entry.distance * 0.3), 0.05, 1)
			sounds.Thunder.Volume = THUNDER_BASE_VOL * distFactor
			sounds.Thunder.PlaybackSpeed = lerp(1.2, 0.7, distFactor) -- distant thunder is deeper
			sounds.Thunder:Play()
			table.remove(thunderQueue, i)
		else
			i += 1
		end
	end
end

function EnvironmentAudio.playThunder(distance: number)
	if not initialized then return end
	-- Speed of sound: ~343 m/s; use 1 stud ≈ 0.28 m → ~0.0035s per stud
	local delay = distance * 0.0035
	table.insert(thunderQueue, {
		time = os.clock() + delay,
		distance = distance,
	})
end

function EnvironmentAudio.cleanup()
	for _, snd in pairs(sounds) do
		snd:Stop()
		snd:Destroy()
	end
	sounds = {}
	thunderQueue = {}
	initialized = false
end

return EnvironmentAudio
