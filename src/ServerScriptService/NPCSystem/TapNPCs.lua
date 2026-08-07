--!strict
--[[
    TapNPCs.lua — The Crew at The Tap
    ================================================================
    "The Tap doesn't close. Neither do the stories. You just have
     to sit down long enough for someone to start telling one."
     — Hermes, tender captain

    Spawns and manages NPC characters at The Tap — the social hub
    of Slackwater. These NPCs connect the game world to the creative
    corpus (ai-writings), pulling curated stories into in-game dialogue.

    NPCs:
      EARL        — cannery boss, work assignments, fish counts
      HERMES      — tender captain, Channel stories, weather lore
      BEA         — lighthouse keeper, fog hints, the old ways
      MIRA        — fisher poet, sea shanties, catches of the day
      SALT        — old dockhand, harbor gossip, repair tips

    Each NPC:
      • Has a distinct personality (based on the Tap character bible)
      • Tells curated stories (adapted from ai-writings)
      • Reacts to player builds (comments on what you built today)
      • Has ambient chatter (cycles when idle)

    Integration:
      - NPCManager handles spawning, proximity prompts, and visual bubbles
      - TapNPCs provides the CONTENT — dialogue lines, story sets, reactions
      - VesselIntegration fires onBuild/onCatch hooks for NPC reactions
      - BondManager trust level gates richer dialogue

    Usage:
        local TapNPCs = require(script.Parent.NPCSystem.TapNPCs)
        TapNPCs.init()

        -- NPCManager routes interaction here
        TapNPCs.onInteraction("Earl", player)

        -- React to a build
        TapNPCs.onPlayerBuild(player, "lighthouse")
]]

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local TapNPCs = {}

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

----------------------------------------------------------------
-- DEPENDENCIES (lazy-loaded)
----------------------------------------------------------------

local function getNPCManager()
    local ok, mod = pcall(function()
        return require(script.Parent.Parent:FindFirstChild("NPCManager"))
    end)
    return ok and mod or nil
end

local function getBondManager()
    local ok, mod = pcall(function()
        return require(script.Parent.Parent:FindFirstChild("BondSystem"):FindFirstChild("BondManager"))
    end)
    return ok and mod or nil
end

----------------------------------------------------------------
-- STORY CORPUS
-- Curated dialogue sets adapted from ai-writings.
-- Each NPC has themed story sets that cycle through.
----------------------------------------------------------------

local STORIES = {
    Earl = {
        -- Work and the cannery
        "Cannery runs dawn to dusk. You bring the fish, I'll process them. Just don't bring me trash fish and call it a haul.",
        "Used to be three canneries on this dock. Now it's just me. The others couldn't keep up. I kept up.",
        "Your catch today was respectable. Not impressive — respectable. There's a difference. Impressive comes tomorrow.",
        "I've seen a lot of fish. Seen a lot of fisherfolk. The ones who last? They listen to the water. The ones who don't? They listen to themselves.",
        "Manifest says you've been pulling steady. Good. Steady keeps the lights on. Steady feeds the harbor.",
        "You know what a cannery smells like after thirty years? Same thing. Every day. I don't notice it anymore. That's either peace or brain damage.",
    },
    Hermes = {
        -- Channel stories and the sea
        "I've run the Channel in every kind of weather. The sea doesn't care about your schedule. She cares about your respect.",
        "There's a spot past the breakwater where the current turns. Fish stack up there like they're waiting in line. I'll mark it on your chart if you ask nice.",
        "Ran a tender up the Inside Passage once. Eight days, no radio, no engine. Just tide and sail. You learn to read water when there's nothing else to read.",
        "The old fisherfolk used to say: 'red sky at morning, sailor's warning.' They were right about most things. The sea teaches you to be right, or it teaches you nothing at all.",
        "I've seen fog so thick you could cut it. Bea's light cuts through all of it. Every time. That woman doesn't miss a night.",
        "You want to know the secret to the Channel? There isn't one. It's just patience and a good chart. And maybe a little luck, but don't tell the fish I said that.",
    },
    Bea = {
        -- Lighthouse, fog, the old ways
        "The light has been on every night for forty-seven years. I've been here for thirty-two of them. She doesn't go dark on my watch.",
        "People think the lighthouse is about seeing out. It's not. It's about being seen. That light says 'here I am' to every boat in the dark.",
        "Fog's coming in. I can feel it before I see it — pressure drops, the gulls go quiet. When the fog arrives, you'll want to be tied up tight.",
        "I keep the light because someone has to. Not because I'm brave. Brave implies I had a choice. I didn't. The sea needed a light, so I became one.",
        "There are nights when the beam hits the water just right and the whole channel lights up like a road. Those are the nights I remember why I'm here.",
        "My father kept the light before me. His father before him. I don't have children. When I go, the light stays. That's the deal.",
    },
    Mira = {
        -- Fisher poet, sea shanties, beauty
        "I caught a salmon once that fought like it had somewhere to be. I understood. I let it go. Some fish aren't yours to keep.",
        "The sea doesn't write poems. She doesn't have to. She IS the poem. We just copy it down badly.",
        "There's a sound the water makes at dusk. Not waves, not wind. Something else. Like the ocean exhaling. I've been trying to describe it for years.",
        "Best catch I ever had? It wasn't the biggest. It was the one that came out of the water like it was flying. Silver in the sunset. I'll never forget that fish.",
        "You want a shanty? I've got twenty. But the good ones aren't about fish — they're about the people waiting on the dock.",
        "They call me the poet because I talk funny. I call them fishermen because they think 'funny' is an insult. We're both right.",
    },
    Salt = {
        -- Old dockhand, harbor gossip, repair
        "This dock's been here longer than any boat tied to it. I should know — I've patched every plank. Twice.",
        "You hear about the wreck past the point? Nobody talks about it. Nobody goes there either. The hull's still visible at low tide. Don't ask me how I know.",
        "Your boat's listing to port. Either your cargo's shifted or your ballast tank is acting up. Fix it before you go out again. I'm not hauling you back.",
        "I've seen storms take boats and leave the dock. I've seen storms take the dock and leave the boats. The sea plays favorites, and she doesn't explain herself.",
        "Salt water fixes most things. Rots the rest. The trick is knowing which is which before it's too late.",
        "That rope you're using? It's got maybe three more trips in it. Don't push it to four. I've seen what happens at four.",
    },
}

----------------------------------------------------------------
-- BUILD REACTIONS
-- NPCs comment on what the player built.
-- Keyed by build type keywords → NPC reactions.
----------------------------------------------------------------

local BUILD_REACTIONS = {
    Earl = {
        lighthouse = "A lighthouse. Good — means Bea'll have company on the night shift. And it means you're planning to stay.",
        dock = "Longer dock. More berths. Good. I've been turning away tenders because there's nowhere to tie up.",
        cannery = "You expanded the cannery. I noticed. Earl notices everything. Thank you.",
        bridge = "A bridge. Now people can walk to the north shore without a boat. That changes things. That changes everything.",
        cottage = "A cottage. You're settling in. I respect that. This harbor needs people who plant roots.",
        default = "Saw what you built out there. Solid work. The harbor's looking better.",
    },
    Hermes = {
        lighthouse = "That new light — I can see it from the Channel. It's a good light. Steady. I trust it.",
        dock = "New dock means I can bring the tender in closer. Less rowing for my crew. Thank you.",
        bridge = "A bridge to the north shore. I've been running boats across that stretch for years. Feels different, seeing it bridged.",
        vessel = "You built a new boat? Let me look at her lines. ...Good. She'll handle well in a following sea.",
        default = "I saw your build from the water. It looks good from out there. That's the test — if it looks right from the Channel, it IS right.",
    },
    Bea = {
        lighthouse = "Another light on the point. Every light matters. Every dark spot we eliminate is a boat that comes home.",
        default = "I can see what you've been building from the top of the tower. The yard's growing. Good.",
    },
    Mira = {
        default = "You've been building. I can tell — the harbor looks different every time I walk the dock. Different is good. Different is alive.",
    },
    Salt = {
        default = "New construction. I can smell the fresh-cut wood from here. Just make sure you treat it. Salt water eats untreated wood like a dog eats fish.",
        dock = "Good dock work. Tight planks, even spacing. Whoever taught you knew what they were doing.",
        default_repair = "I'll check the pilings on that new build tomorrow. Salt water's patient. So am I.",
    },
}

----------------------------------------------------------------
-- AMBIENT CHATTER
-- Cycling idle lines for when NPCs aren't being interacted with.
----------------------------------------------------------------

local AMBIENT = {
    Earl = {
        "*Earl flips a page on his manifest*",
        "*Earl checks the scales*",
        "Hmm. Inventory's off by two crates.",
        "*Earl squints at the horizon*",
    },
    Hermes = {
        "*Hermes adjusts his collar against the wind*",
        "*Hermes spits over the rail*",
        "Tide's changing. Can feel it in the deck.",
        "*Hermes hums a shanty, barely audible*",
    },
    Bea = {
        "*Bea polishes the lens housing*",
        "*Bea checks her watch against the sunset*",
        "Forty-seven years. Every night.",
        "*Bea pulls her watch cap tighter*",
    },
    Mira = {
        "*Mira watches the water, lips moving silently*",
        "*Mira ties a fly to an invisible line*",
        "Silver. Everything is silver at this hour.",
        "*Mira writes something on her forearm with a stub of pencil*",
    },
    Salt = {
        "*Salt runs his hand along a dock piling, frowning*",
        "*Salt coils a rope with practiced hands*",
        "Mm. This plank's getting soft.",
        "*Salt stares at the water like it owes him money*",
    },
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

TapNPCs._ambientTimers = {}  -- [npcName] = lastAmbientTime
TapNPCs._storyIndex = {}     -- [npcName] = current story index (for cycling)
TapNPCs._initialized = false

local AMBIENT_INTERVAL = 120  -- seconds between ambient lines (per NPC)
local AMBIENT_INTERVAL_JITTER = 60  -- random +/- seconds

----------------------------------------------------------------
-- INITIALIZATION
----------------------------------------------------------------

function TapNPCs.init()
    -- Register as an interaction listener with NPCManager
    local npcManager = getNPCManager()
    if npcManager and npcManager.onInteraction then
        npcManager.onInteraction(function(npcName, player)
            TapNPCs.onInteraction(npcName, player)
        end)
    else
        warn("[TapNPCs] NPCManager not found — interactions won't fire")
    end

    -- Start ambient chatter loop
    task.spawn(function()
        while true do
            task.wait(30)  -- check every 30s
            TapNPCs._tickAmbient()
        end
    end)

    TapNPCs._initialized = true
    print("[TapNPCs] Initialized — 5 NPCs wired with stories and reactions")
end

----------------------------------------------------------------
-- INTERACTION HANDLER
----------------------------------------------------------------

--[[
    Called when a player interacts with an NPC.
    Delivers a story or contextual dialogue line.
    @param npcName string
    @param player Player
]]
function TapNPCs.onInteraction(npcName: string, player: Player)
    -- Check trust level for richer dialogue
    local bond = getBondManager()
    local trustLevel = 0
    if bond and bond.getTrust then
        trustLevel = bond.getTrust(player.UserId)
    end

    -- Pick a story line
    local stories = STORIES[npcName]
    if not stories then return end

    -- Cycle through stories sequentially for consistency
    if not TapNPCs._storyIndex[npcName] then
        TapNPCs._storyIndex[npcName] = 0
    end
    TapNPCs._storyIndex[npcName] = TapNPCs._storyIndex[npcName] + 1
    if TapNPCs._storyIndex[npcName] > #stories then
        TapNPCs._storyIndex[npcName] = 1
    end

    local line = stories[TapNPCs._storyIndex[npcName]]

    -- High-trust players get occasional extra lines
    if trustLevel >= 75 and math.random() < 0.3 then
        local extra = STORIES[npcName][math.random(1, #stories)]
        if extra ~= line then
            line = line .. "\n\n" .. extra
        end
    end

    -- Deliver via NPCManager
    TapNPCs._showDialogue(npcName, line, player)
end

----------------------------------------------------------------
-- BUILD REACTIONS
----------------------------------------------------------------

--[[
    React to a player's build. Called by VesselIntegration.onBuild.
    A random nearby NPC comments on the build.
    @param player Player
    @param buildType string
]]
function TapNPCs.onPlayerBuild(player: Player, buildType: string)
    local npcNames = {"Earl", "Hermes", "Bea", "Mira", "Salt"}
    -- Pick 1-2 NPCs to react
    local reactor = npcNames[math.random(1, #npcNames)]

    local reactions = BUILD_REACTIONS[reactor]
    if not reactions then return end

    -- Find a matching reaction by keyword
    local buildLower = string.lower(buildType or "")
    local line = reactions.default or reactions.default_repair or "Saw your build. Good work."

    for keyword, reaction in pairs(reactions) do
        if keyword ~= "default" and keyword ~= "default_repair" then
            if string.find(buildLower, keyword, 1, true) then
                line = reaction
                break
            end
        end
    end

    -- Delay slightly so it doesn't overlap with Lucineer's post-build line
    task.delay(4, function()
        TapNPCs._showDialogue(reactor, line, player)
    end)
end

--[[
    React to a notable catch.
    @param player Player
    @param species string
    @param weight number
]]
function TapNPCs.onPlayerCatch(player: Player, species: string, weight: number)
    if not weight or weight < 20 then return end  -- only react to big catches

    local line
    if weight > 80 then
        line = string.format(
            "Heard you pulled a %.0f-lb %s out there. That's a boat fish, that is. Earl'll remember this one.",
            weight, species
        )
    else
        line = string.format(
            "Nice %s. %.0f lbs is nothing to sneeze at. Good fishing today.",
            species, weight
        )
    end

    -- Earl comments on catches
    task.delay(3, function()
        TapNPCs._showDialogue("Earl", line, player)
    end)
end

----------------------------------------------------------------
-- AMBIENT CHATTER
----------------------------------------------------------------

function TapNPCs._tickAmbient()
    local now = os.time()
    local npcNames = {"Earl", "Hermes", "Bea", "Mira", "Salt"}

    for _, npcName in ipairs(npcNames) do
        local lastTime = TapNPCs._ambientTimers[npcName] or 0
        local interval = AMBIENT_INTERVAL + math.random(-AMBIENT_INTERVAL_JITTER, AMBIENT_INTERVAL_JITTER)

        if (now - lastTime) >= interval then
            -- Count online players — only do ambient if someone's around
            local playerCount = #Players:GetPlayers()
            if playerCount > 0 then
                local lines = AMBIENT[npcName]
                if lines and #lines > 0 then
                    local line = lines[math.random(1, #lines)]
                    TapNPCs._showDialogue(npcName, line, nil)  -- nil = server-wide (ambient)
                end
            end
            TapNPCs._ambientTimers[npcName] = now
        end
    end
end

----------------------------------------------------------------
-- DIALOGUE DELIVERY
----------------------------------------------------------------

--[[
    Show dialogue via NPCManager. Falls back to direct RemoteEvent.
    @param npcName string
    @param text string
    @param player Player? — nil for ambient (all players)
]]
function TapNPCs._showDialogue(npcName: string, text: string, player: Player?)
    local npcManager = getNPCManager()
    if npcManager and npcManager.showDialogue then
        if player then
            npcManager.showDialogue(npcName, text, player, 7)
        else
            npcManager.showAmbient(npcName, text, 5)
        end
    else
        -- Fallback: fire directly via RemoteEvent
        local lucineer = ReplicatedStorage:FindFirstChild("Lucineer")
        local remote = lucineer and lucineer:FindFirstChild("ResponseEvent")
        if remote then
            if player then
                remote:FireClient(player, {
                    type = "npc_dialogue",
                    speaker = npcName,
                    message = text,
                })
            end
        end
    end
end

return TapNPCs
