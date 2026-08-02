--[[
    Lucineer AudioManager
    ───────────────────────────────────────────────
    "The yard talks. Tide under the floor, gulls on the roofline,
     the foghorn out past the Light. Silence is information —
     everything else is ambience."

    Central audio system for Slackwater Yard. Manages:
      • Layered ambient bed (water, wind, creaks, gulls, foghorn)
      • Build SFX triggered by material type
      • Lucineer vocal cues (short motifs, not full voice)
      • UI sounds (chat, errors, achievements)
      • Music system with crossfade between modes

    All sounds parented to SoundService. SoundGroups for volume control.
    Ambient sounds are looped; SFX created on demand and cleaned up.
    Music crossfades over 0.5s when switching modes.
]]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local AudioManager = {}

----------------------------------------------------------------
-- SOUND GROUPS
----------------------------------------------------------------

-- We create four SoundGroups under SoundService for bus-level volume.
local soundGroups = {}

local function ensureSoundGroup(name: string): SoundGroup
    local existing = SoundService:FindFirstChild(name)
    if existing and existing:IsA("SoundGroup") then
        return existing
    end
    local group = Instance.new("SoundGroup")
    group.Name = name
    group.Volume = 1.0
    group.Parent = SoundService
    return group
end

----------------------------------------------------------------
-- SOUND ASSET IDs
----------------------------------------------------------------

-- All asset IDs use free Roblox audio assets.
-- Ambient bed
local AMBIENT_SOUNDS = {
    water = {
        soundId = "rbxassetid://4766793559",
        volume = 0.15,
        looped = true,
        playbackSpeed = 1.0,
    },
    wind = {
        soundId = "rbxassetid://6455667685",
        volume = 0.10,
        looped = true,
        playbackSpeed = 1.0,
    },
    creak = {
        soundId = "rbxassetid://9120832471",
        volume = 0.25,
        looped = false,
        playbackSpeed = 1.0,
    },
    gull = {
        soundId = "rbxassetid://9118858002",
        volume = 0.20,
        looped = false,
        playbackSpeed = 1.0,
    },
    foghorn = {
        soundId = "rbxassetid://229325720",
        volume = 0.30,
        looped = false,
        playbackSpeed = 0.9,
    },
}

-- Build SFX per material family
local BUILD_SFX = {
    Stone = {
        soundId = "rbxassetid://1565725028",
        volume = 0.6,
        pitch = 0.8,
    },
    Wood = {
        soundId = "rbxassetid://9120917974",
        volume = 0.5,
        pitch = 1.0,
    },
    Metal = {
        soundId = "rbxassetid://356659053",
        volume = 0.5,
        pitch = 1.3,
    },
    Glass = {
        soundId = "rbxassetid://9119634589",
        volume = 0.45,
        pitch = 1.2,
    },
    Neon = {
        soundId = "rbxassetid://9116245410",
        volume = 0.4,
        pitch = 1.5,
    },
    -- Build completion: warm low boom + reverb
    completion = {
        soundId = "rbxassetid://314428418",
        volume = 0.7,
        pitch = 0.7,
    },
}

-- Lucineer vocal cues — short motifs
local VOCAL_CUES = {
    acknowledge = {
        -- low hum, 0.3s
        soundId = "rbxassetid://314428418",
        volume = 0.35,
        pitch = 0.6,
    },
    thinking = {
        -- rhythmic tap, loops
        soundId = "rbxassetid://9120917974",
        volume = 0.20,
        pitch = 0.9,
        looped = true,
    },
    complete = {
        -- warm chime ascending
        soundId = "rbxassetid://9116245410",
        volume = 0.45,
        pitch = 1.1,
    },
    disagreement = {
        -- low buzz, descending
        soundId = "rbxassetid://314428418",
        volume = 0.40,
        pitch = 0.5,
    },
    surprise = {
        -- bright ascending arpeggio
        soundId = "rbxassetid://1836029595",
        volume = 0.50,
        pitch = 1.2,
    },
}

-- UI sounds
local UI_SOUNDS = {
    chat_send = {
        -- soft click
        soundId = "rbxassetid://7212399604",
        volume = 0.40,
        pitch = 1.0,
    },
    chat_receive = {
        -- gentle notification tone
        soundId = "rbxassetid://9116245410",
        volume = 0.35,
        pitch = 0.95,
    },
    error = {
        -- descending buzz
        soundId = "rbxassetid://314428418",
        volume = 0.45,
        pitch = 0.4,
    },
    achievement = {
        -- triumphant chord
        soundId = "rbxassetid://4342630136",
        volume = 0.55,
        pitch = 1.0,
    },
}

-- Music tracks per mode
local MUSIC_TRACKS = {
    hub = {
        -- slow, sparse, minor key — acoustic drone
        soundId = "rbxassetid://145485235",
        volume = 0.25,
        looped = true,
    },
    build = {
        -- slightly more active, soft rhythm added
        soundId = "rbxassetid://121873091542454",
        volume = 0.25,
        looped = true,
    },
    storm = {
        -- dramatic, minor key, building tension
        soundId = "rbxassetid://528689056",
        volume = 0.30,
        looped = true,
    },
    aurora = {
        -- ethereal, major key, shimmering
        soundId = "rbxassetid://1836029595",
        volume = 0.20,
        looped = true,
    },
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local initialized = false
local weatherIntensity = 0.0
local currentMusicMode: string? = nil
local activeMusicSound: Sound? = nil
local ambientInstances: {[string]: Sound} = {}
local thinkingSound: Sound? = nil
local ambientRandomTimer: number = 0
local preloadedIds: {[string]: boolean} = {}

----------------------------------------------------------------
-- INTERNAL: SOUND CREATION HELPERS
----------------------------------------------------------------

--[[
    Create a Sound instance configured from a sound definition table.
    @param def table with soundId, volume, pitch, [looped]
    @param parent Instance to parent the sound to
    @return Sound
]]
local function createSound(def: table, parent: Instance): Sound
    local sound = Instance.new("Sound")
    sound.SoundId = def.soundId
    sound.Volume = def.volume
    sound.PlaybackSpeed = def.pitch or def.playbackSpeed or 1.0
    sound.Looped = def.looped or false
    sound.Parent = parent
    return sound
end

--[[
    Play a one-shot sound at an optional position and clean it up after.
    Creates a temporary part with a Sound if position is provided,
    otherwise plays parented to the SFX SoundGroup.
    @param def table sound definition
    @param position Vector3? optional world position for 3D sound
    @param groupName string SoundGroup name ("sfx" by default)
]]
local function playOneShot(def: table, position: Vector3?, groupName: string?)
    groupName = groupName or "sfx"
    local group = soundGroups[groupName]

    if position then
        -- 3D positioned sound: parent to a temporary part
        local part = Instance.new("Part")
        part.Name = "SfxCarrier"
        part.Size = Vector3.new(0.2, 0.2, 0.2)
        part.Position = position
        part.Transparency = 1
        part.CanCollide = false
        part.CanQuery = false
        part.Anchored = true
        part.Parent = workspace

        local sound = Instance.new("Sound")
        sound.SoundId = def.soundId
        sound.Volume = def.volume
        sound.PlaybackSpeed = def.pitch or 1.0
        sound.Looped = false
        sound.RollOffMaxDistance = 80
        sound.RollOffMinDistance = 5
        sound.RollOffMode = Enum.RollOffMode.InverseTapered
        sound.Parent = part

        -- Parent the part to the sound group for volume control
        part.Parent = group or workspace

        sound:Play()
        Debris:AddItem(part, sound.TimeLength > 0 and (sound.TimeLength + 0.5) or 5)
    else
        -- Non-positional: parent directly to SoundGroup
        local sound = Instance.new("Sound")
        sound.SoundId = def.soundId
        sound.Volume = def.volume
        sound.PlaybackSpeed = def.pitch or 1.0
        sound.Looped = false
        sound.Parent = group or SoundService

        sound:Play()
        Debris:AddItem(sound, sound.TimeLength > 0 and (sound.TimeLength + 0.5) or 5)
    end
end

----------------------------------------------------------------
-- INTERNAL: AMBIENT RANDOM SCHEDULER
----------------------------------------------------------------

--[[
    Schedule the next random ambient one-shot (creak, gull, foghorn).
    Uses weighted random selection and interval ranges from the World Bible.
    Called on a heartbeat timer after init.
]]
local function scheduleAmbientRandoms()
    if not initialized then return end

    -- Decide which sound to play next and how long to wait
    -- We roll for the type first, then pick the delay range
    local roll = math.random()
    local soundDef, delayMin, delayMax

    if roll < 0.45 then
        -- Creaking: most frequent, 15-45s
        soundDef = AMBIENT_SOUNDS.creak
        delayMin, delayMax = 15, 45
    elseif roll < 0.80 then
        -- Gulls: medium frequency, 30-90s
        soundDef = AMBIENT_SOUNDS.gull
        delayMin, delayMax = 30, 90
    else
        -- Foghorn: rare, 120-300s (2-5 minutes)
        soundDef = AMBIENT_SOUNDS.foghorn
        delayMin, delayMax = 120, 300
    end

    local delay = delayMin + math.random() * (delayMax - delayMin)

    task.delay(delay, function()
        if not initialized then return end
        playOneShot(soundDef, nil, "ambient")

        -- Schedule the next one
        scheduleAmbientRandoms()
    end)
end

----------------------------------------------------------------
-- INTERNAL: WEATHER WIND RESPONSE
----------------------------------------------------------------

--[[
    Update wind volume based on weather intensity (0-1).
    Base wind volume is 0.10; at full storm it reaches ~0.40.
]]
local function updateWindVolume()
    local wind = ambientInstances.wind
    if not wind then return end

    local baseVol = AMBIENT_SOUNDS.wind.volume
    local stormVol = 0.40
    local targetVol = baseVol + (stormVol - baseVol) * weatherIntensity

    TweenService:Create(wind, TweenInfo.new(2.0), { Volume = targetVol }):Play()
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the audio system. Sets up SoundGroups, ambient bed,
    preloads all sound IDs, and starts the random ambient scheduler.
    Call once on game start (client or server).
]]
function AudioManager.init()
    if initialized then
        warn("[AudioManager] Already initialized.")
        return
    end

    -- Create SoundGroups
    soundGroups.ambient = ensureSoundGroup("AmbientGroup")
    soundGroups.sfx = ensureSoundGroup("SfxGroup")
    soundGroups.music = ensureSoundGroup("MusicGroup")
    soundGroups.ui = ensureSoundGroup("UiGroup")

    -- Create looping ambient sounds under the ambient SoundGroup
    for name, def in pairs(AMBIENT_SOUNDS) do
        if def.looped then
            local sound = createSound(def, soundGroups.ambient)
            sound.Looped = true
            ambientInstances[name] = sound
        end
    end

    -- Start ambient bed
    for _, sound in pairs(ambientInstances) do
        sound:Play()
    end

    -- Preload all sound IDs
    local allIds = {}
    for _, def in pairs(AMBIENT_SOUNDS) do
        table.insert(allIds, def.soundId)
    end
    for _, def in pairs(BUILD_SFX) do
        table.insert(allIds, def.soundId)
    end
    for _, def in pairs(VOCAL_CUES) do
        table.insert(allIds, def.soundId)
    end
    for _, def in pairs(UI_SOUNDS) do
        table.insert(allIds, def.soundId)
    end
    for _, def in pairs(MUSIC_TRACKS) do
        table.insert(allIds, def.soundId)
    end

    for _, id in ipairs(allIds) do
        if not preloadedIds[id] then
            preloadedIds[id] = true
        end
    end

    -- Kick off the random ambient scheduler
    task.spawn(function()
        -- Small initial delay so the bed settles
        task.wait(5)
        scheduleAmbientRandoms()
    end)

    initialized = true
    print("[AudioManager] Initialized — ambient bed live,", #allIds, "sound IDs preloaded.")
end

--[[
    Play a build sound for the given material.
    @param material string — "Stone", "Wood", "Metal", "Glass", "Neon"
    @param position Vector3? — world position for 3D sound
]]
function AudioManager.playBuildSound(material: string, position: Vector3?)
    local def = BUILD_SFX[material]
    if not def then
        -- Try to infer family from Enum.Material-like strings
        local lowerMat = (material or ""):lower()
        if lowerMat:match("slate") or lowerMat:match("concrete") or lowerMat:match("brick")
            or lowerMat:match("rock") or lowerMat:match("cobble") or lowerMat:match("sand")
            or lowerMat:match("marble") or lowerMat:match("granite") then
            def = BUILD_SFX.Stone
        elseif lowerMat:match("wood") or lowerMat:match("bamboo") or lowerMat:match("plank") then
            def = BUILD_SFX.Wood
        elseif lowerMat:match("metal") or lowerMat:match("diamond") or lowerMat:match("foil")
            or lowerMat:match("corrod") then
            def = BUILD_SFX.Metal
        elseif lowerMat:match("glass") or lowerMat:match("ice") or lowerMat:match("force") then
            def = BUILD_SFX.Glass
        elseif lowerMat:match("neon") then
            def = BUILD_SFX.Neon
        else
            -- Default: stone-like thunk
            def = BUILD_SFX.Stone
        end
    end

    playOneShot(def, position, "sfx")
end

--[[
    Play the build completion sound — a warm, resonant settle.
    @param position Vector3? — world position for 3D sound
]]
function AudioManager.playBuildCompletion(position: Vector3?)
    playOneShot(BUILD_SFX.completion, position, "sfx")
end

--[[
    Play a Lucineer vocal cue (short motif, not full voice).
    @param cueName string — "acknowledge", "thinking", "complete",
                             "disagreement", "surprise"
]]
function AudioManager.playCue(cueName: string)
    local def = VOCAL_CUES[cueName]
    if not def then
        warn("[AudioManager] Unknown vocal cue:", cueName)
        return
    end

    -- Special handling for "thinking" — it loops
    if cueName == "thinking" then
        if thinkingSound and thinkingSound.IsPlaying then
            return -- already playing
        end
        -- Stop any previous thinking sound
        if thinkingSound then
            thinkingSound:Stop()
            thinkingSound:Destroy()
        end
        thinkingSound = createSound(def, soundGroups.sfx)
        thinkingSound.Looped = true
        thinkingSound:Play()
        return
    end

    -- If we were thinking and a different cue plays, stop thinking
    if thinkingSound and thinkingSound.IsPlaying then
        thinkingSound:Stop()
        thinkingSound:Destroy()
        thinkingSound = nil
    end

    playOneShot(def, nil, "sfx")
end

--[[
    Stop the "thinking" loop if it's playing.
]]
function AudioManager.stopThinking()
    if thinkingSound then
        if thinkingSound.IsPlaying then
            -- Quick fade out
            TweenService:Create(thinkingSound, TweenInfo.new(0.3), { Volume = 0 }):Play()
            task.delay(0.35, function()
                if thinkingSound then
                    thinkingSound:Stop()
                    thinkingSound:Destroy()
                    thinkingSound = nil
                end
            end)
        else
            thinkingSound:Destroy()
            thinkingSound = nil
        end
    end
end

--[[
    Play a UI sound.
    @param soundName string — "chat_send", "chat_receive", "error", "achievement"
]]
function AudioManager.playUi(soundName: string)
    local def = UI_SOUNDS[soundName]
    if not def then
        warn("[AudioManager] Unknown UI sound:", soundName)
        return
    end

    playOneShot(def, nil, "ui")
end

--[[
    Switch the music mode with a 0.5s crossfade.
    @param mode string — "hub", "build", "storm", "aurora", "none"
]]
function AudioManager.setMusic(mode: string)
    if mode == currentMusicMode then return end

    local def = MUSIC_TRACKS[mode]
    if not def and mode ~= "none" then
        warn("[AudioManager] Unknown music mode:", mode)
        return
    end

    -- Fade out current music
    if activeMusicSound then
        local oldSound = activeMusicSound
        local tween = TweenService:Create(oldSound, TweenInfo.new(0.5), { Volume = 0 })
        tween:Play()
        tween.Completed:Connect(function()
            oldSound:Stop()
            oldSound:Destroy()
        end)
        activeMusicSound = nil
    end

    -- Fade in new music
    if def and mode ~= "none" then
        local newSound = createSound(def, soundGroups.music)
        newSound.Looped = def.looped or true
        newSound.Volume = 0 -- start at 0, fade up
        newSound:Play()

        TweenService:Create(newSound, TweenInfo.new(0.5), { Volume = def.volume }):Play()
        activeMusicSound = newSound
    end

    currentMusicMode = mode
end

--[[
    Set weather intensity (0 = clear, 1 = full storm).
    Affects wind volume and ambient character.
    @param intensity number 0-1
]]
function AudioManager.setWeatherIntensity(intensity: number)
    intensity = math.clamp(intensity, 0, 1)
    weatherIntensity = intensity
    updateWindVolume()
end

--[[
    Get the current weather intensity.
    @return number 0-1
]]
function AudioManager.getWeatherIntensity(): number
    return weatherIntensity
end

--[[
    Set the volume of a SoundGroup.
    @param groupName string — "ambient", "sfx", "music", "ui"
    @param volume number 0-1
]]
function AudioManager.setGroupVolume(groupName: string, volume: number)
    local group = soundGroups[groupName]
    if not group then
        warn("[AudioManager] Unknown sound group:", groupName)
        return
    end
    group.Volume = math.clamp(volume, 0, 1)
end

--[[
    Get the volume of a SoundGroup.
    @param groupName string
    @return number
]]
function AudioManager.getGroupVolume(groupName: string): number
    local group = soundGroups[groupName]
    if not group then return 1.0 end
    return group.Volume
end

--[[
    Tear down the audio system. Stops all sounds and cleans up.
    Primarily for testing or full resets.
]]
function AudioManager.shutdown()
    -- Stop ambient
    for name, sound in pairs(ambientInstances) do
        sound:Stop()
        sound:Destroy()
    end
    ambientInstances = {}

    -- Stop thinking
    if thinkingSound then
        thinkingSound:Stop()
        thinkingSound:Destroy()
        thinkingSound = nil
    end

    -- Stop music
    if activeMusicSound then
        activeMusicSound:Stop()
        activeMusicSound:Destroy()
        activeMusicSound = nil
    end

    currentMusicMode = nil
    initialized = false
    print("[AudioManager] Shut down.")
end

----------------------------------------------------------------
-- MATERIAL HELPER: map Enum.Material to string family
----------------------------------------------------------------

--[[
    Convenience: convert an Enum.Material to a string family name
    usable with playBuildSound.
    @param material Enum.Material
    @return string — "Stone", "Wood", "Metal", "Glass", "Neon"
]]
function AudioManager.materialToString(material: Enum.Material): string
    local name = material.Name:lower()
    if name:match("slate") or name:match("concrete") or name:match("brick")
        or name:match("cobble") or name:match("rock") or name:match("sand")
        or name:match("marble") or name:match("granite") then
        return "Stone"
    elseif name:match("wood") or name:match("bamboo") or name:match("plank") then
        return "Wood"
    elseif name:match("metal") or name:match("diamond") or name:match("foil")
        or name:match("corrod") then
        return "Metal"
    elseif name:match("glass") or name:match("ice") or name:match("force") then
        return "Glass"
    elseif name:match("neon") then
        return "Neon"
    end
    return "Stone" -- default
end

return AudioManager
