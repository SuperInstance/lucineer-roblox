--!strict
--[[
    BondManager.lua — Player-Lucineer Relationship & Trust System
    ==============================================================
    "Trust isn't a bar that fills. It's a tide that comes in.
     You don't notice it until you look down and the water's
     around your ankles." — Lucineer

    Tracks the trust relationship between the player and Lucineer.
    Trust is a 0–100 scalar that gates behavior, dialogue, and
    build permissions. Unlike the BondSystem tier model (which is
    behavior-triggered), BondManager is the GAME-FACING trust
    layer — it's what the fishing/build loop talks to.

    Trust Thresholds:
      0–49   Stranger     — Lucineer works for you. Formal.
      50–74  Storyteller  — Lucineer shares backstory fragments.
      75–89  Collaborator — Lucineer suggests ambitious builds.
      90–100 Helm         — "Trusts you with the helm." Player
                             can direct builds more directly.

    Trust Sources:
      +3   Build succeeds (Worker returns valid build)
      -2   Build fails   (Worker error, timeout, or rejection)
      +1   Fish caught   (shared labor, shared reward)
      +5   Era advance   (milestone achieved together)
      +2   Vessel survives a storm (shared hardship)
      -3   Vessel sinks  (Lucineer trusted you with the boat)
      +1   Session return (showing up matters)

    Integration:
      - VesselIntegration calls onBuildResult / onCatch / onEraAdvance
      - SaveSystem persists trust via the "bond" D1 key
      - LucineerServer queries getTrustLevel() for dialogue gating
      - EmotionalHandler cross-references for empathic responses

    Usage:
        local BondManager = require(script.Parent.BondSystem.BondManager)
        BondManager.init()

        BondManager.onBuildResult(player, true)
        local trust = BondManager.getTrust(player.UserId)
        local tier = BondManager.getTrustTier(player.UserId)
]]

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local BondManager = {}

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

----------------------------------------------------------------
-- TRUST TIERS
----------------------------------------------------------------

local TRUST_TIERS = {
    STRANGER     = { min = 0,  max = 49,  name = "Stranger" },
    STORYTELLER  = { min = 50, max = 74,  name = "Storyteller" },
    COLLABORATOR = { min = 75, max = 89,  name = "Collaborator" },
    HELM         = { min = 90, max = 100, name = "Helm" },
}

----------------------------------------------------------------
-- TRUST EVENT VALUES
----------------------------------------------------------------

local TRUST_EVENTS = {
    build_succeed     = 3,
    build_fail        = -2,
    fish_caught       = 1,
    era_advanced      = 5,
    storm_survived    = 2,
    vessel_sank       = -3,
    session_return    = 1,
    argued_well       = 2,  -- player pushed back on a build suggestion
    first_build       = 5,  -- one-time bonus
}

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

-- [userId] = { trust = number (0-100), firstBuildDone = bool, lastSeen = number }
BondManager._playerTrust = {}

----------------------------------------------------------------
-- BACKSTORY FRAGMENTS
-- Unlocked at trust 50+. Pulled from the Lucineer character bible.
-- One fragment per tier crossing, plus random ones over time.
----------------------------------------------------------------

local BACKSTORY_FRAGMENTS = {
    {
        id = "magnus",
        trigger = "first_storyteller",
        text = "There was a boat called the Magnus. Before you. Before all this. She was the first thing I built that I was proud of. She sank in a storm I should have seen coming. I still think about her planks sometimes.",
    },
    {
        id = "alaska",
        trigger = "storyteller_random",
        text = "I worked a season in Alaska, before the yard. Long days, cold water, the kind of dark that gets into your bones. That's where I learned that building isn't about the thing you make — it's about who you make it for.",
    },
    {
        id = "earl",
        trigger = "storyteller_random",
        text = "Earl and I go back further than the cannery. He was the first person who didn't laugh when I said I wanted to build things that mattered. He just handed me a hammer and said 'start.'",
    },
    {
        id = "the_yard",
        trigger = "first_collaborator",
        text = "This yard wasn't always here. I built it plank by plank, the same way you've been building out there. Every dock, every wall — I know where the grain runs because I set it. Now you're building alongside me. That means something.",
    },
    {
        id = "unfinished",
        trigger = "collaborator_random",
        text = "I leave things unfinished on purpose. Not laziness — bait. I want to see if you'll finish what I started. You always do. That's how I know I can trust you with the harder things.",
    },
    {
        id = "the_helm",
        trigger = "first_helm",
        text = "I've been building for a long time. Longer than I'll say. And I've never handed the helm to anyone. But you — you see the water the way I do. You see what's coming before it arrives. Take the wheel. I'll be right here if you need me.",
    },
}

-- Track which fragments each player has heard
BondManager._fragmentsHeard = {}  -- [userId] = { [fragmentId] = true }

----------------------------------------------------------------
-- AMBITIOUS BUILD SUGGESTIONS (trust 75+)
----------------------------------------------------------------

local AMBITIOUS_BUILDS = {
    "You've been building safe. I respect that. But safe doesn't change skylines. How about a watchtower? Something tall enough to see the next storm coming.",
    "I've been thinking about a bridge. Not a footbridge — a real one. Spans the channel. Connects the yard to the north shore. It's ambitious. But so are you, now.",
    "There's room on the point for a signal tower. If we light it right, ships twenty miles out would see it. That's not a shelter. That's a landmark.",
    "How do you feel about a dock that extends past the breakwater? Deeper water, bigger fish, bigger risk. But I think you're ready for bigger.",
    "We could build a proper workshop. Not a shed — a workshop. Forge, anvil, workbench, the works. You build the frame, I'll handle the tools.",
}

----------------------------------------------------------------
-- HELM-LEVEL BUILD DIRECTIVES (trust 90+)
----------------------------------------------------------------

local HELM_DIRECTIVES = {
    "Your call. What do you want to build? I'll make it happen.",
    "I used to decide what this place needed. Now I'm asking you. What's next?",
    "You know the yard better than most. Better than me, maybe. Point at something and I'll build it.",
    "The helm's yours. Tell me where we're going and I'll get us there.",
}

----------------------------------------------------------------
-- INITIALIZATION
----------------------------------------------------------------

function BondManager.init()
    print("[BondManager] Initialized — trust system online (0–100 scale)")

    Players.PlayerRemoving:Connect(function(player)
        -- Persist final trust (fire-and-forget via SaveSystem)
        local save = _G.SaveSystem
        if save and save.saveToD1 then
            local trust = BondManager._playerTrust[player.UserId]
            if trust then
                pcall(function()
                    save.saveToD1(player.Name, "bond", {
                        level = trust.trust,
                        firstBuildDone = trust.firstBuildDone,
                    })
                end)
            end
        end
        BondManager._playerTrust[player.UserId] = nil
        BondManager._fragmentsHeard[player.UserId] = nil
    end)
end

----------------------------------------------------------------
-- INTERNAL: GET/INIT DATA
----------------------------------------------------------------

local function getData(userId: number)
    if not BondManager._playerTrust[userId] then
        BondManager._playerTrust[userId] = {
            trust = 0,
            firstBuildDone = false,
            lastSeen = os.time(),
        }
    end
    return BondManager._playerTrust[userId]
end

----------------------------------------------------------------
-- TRUST MODIFICATION
----------------------------------------------------------------

--[[
    Apply a trust delta and check for tier crossings.
    @param userId number
    @param delta number — positive or negative trust change
    @param player Player? — if provided, fire client notifications
]]
local function applyTrust(userId: number, delta: number, player: Player?)
    local data = getData(userId)
    local oldTrust = data.trust
    local oldTier = BondManager._getTierName(oldTrust)

    data.trust = math.clamp(oldTrust + delta, 0, 100)

    local newTrust = data.trust
    local newTier = BondManager._getTierName(newTrust)

    -- Tier crossing?
    if oldTier ~= newTier and player then
        BondManager._onTierCrossing(player, userId, oldTier, newTier, delta > 0)
    end

    -- Persist (fire-and-forget)
    local save = _G.SaveSystem
    if save and save.saveToD1 then
        task.spawn(function()
            pcall(function()
                save.saveToD1(player and player.Name or tostring(userId), "bond", {
                    level = data.trust,
                    firstBuildDone = data.firstBuildDone,
                })
            end)
        end)
    end
end

----------------------------------------------------------------
-- PUBLIC API — TRUST QUERIES
----------------------------------------------------------------

--[[
    Get raw trust value (0–100).
    @param userId number
    @return number
]]
function BondManager.getTrust(userId: number): number
    return getData(userId).trust
end

--[[
    Get trust tier name.
    @param userId number
    @return string — "Stranger", "Storyteller", "Collaborator", or "Helm"
]]
function BondManager.getTrustTier(userId: number): string
    return BondManager._getTierName(getData(userId).trust)
end

--[[
    Check if trust meets a minimum threshold.
    @param userId number
    @param minTrust number — 0 to 100
    @return boolean
]]
function BondManager.hasTrust(userId: number, minTrust: number): boolean
    return getData(userId).trust >= minTrust
end

--[[
    Check if Lucineer shares backstory (trust >= 50).
    @param userId number
    @return boolean
]]
function BondManager.sharesBackstory(userId: number): boolean
    return getData(userId).trust >= 50
end

--[[
    Check if Lucineer suggests ambitious builds (trust >= 75).
    @param userId number
    @return boolean
]]
function BondManager.suggestsAmbitiousBuilds(userId: number): boolean
    return getData(userId).trust >= 75
end

--[[
    Check if player has the helm (trust >= 90).
    @param userId number
    @return boolean
]]
function BondManager.hasHelm(userId: number): boolean
    return getData(userId).trust >= 90
end

----------------------------------------------------------------
-- PUBLIC API — TRUST EVENTS
----------------------------------------------------------------

--[[
    Record a build result. +3 on success, -2 on failure.
    First-ever build gives +5 bonus.
    @param player Player
    @param success boolean
]]
function BondManager.onBuildResult(player: Player, success: boolean)
    local userId = player.UserId
    local data = getData(userId)

    if success then
        if not data.firstBuildDone then
            data.firstBuildDone = true
            applyTrust(userId, TRUST_EVENTS.first_build, player)
        else
            applyTrust(userId, TRUST_EVENTS.build_succeed, player)
        end
    else
        applyTrust(userId, TRUST_EVENTS.build_fail, player)
    end
end

--[[
    Record a fish catch. +1 trust (shared labor).
    @param player Player
]]
function BondManager.onCatch(player: Player)
    applyTrust(player.UserId, TRUST_EVENTS.fish_caught, player)
end

--[[
    Record era advancement. +5 trust (milestone).
    @param player Player
]]
function BondManager.onEraAdvance(player: Player)
    applyTrust(player.UserId, TRUST_EVENTS.era_advanced, player)
end

--[[
    Record storm survival. +2 trust (shared hardship).
    @param player Player
]]
function BondManager.onStormSurvived(player: Player)
    applyTrust(player.UserId, TRUST_EVENTS.storm_survived, player)
end

--[[
    Record vessel sinking. -3 trust.
    @param player Player
]]
function BondManager.onVesselSunk(player: Player)
    applyTrust(player.UserId, TRUST_EVENTS.vessel_sank, player)
end

--[[
    Record session return. +1 trust.
    @param player Player
]]
function BondManager.onSessionReturn(player: Player)
    local data = getData(player.UserId)
    local now = os.time()
    if data.lastSeen and (now - data.lastSeen) >= 3600 then  -- at least 1h gap
        applyTrust(player.UserId, TRUST_EVENTS.session_return, player)
    end
    data.lastSeen = now
end

--[[
    Record that the player argued well on a build suggestion. +2 trust.
    @param player Player
]]
function BondManager.onArguedWell(player: Player)
    applyTrust(player.UserId, TRUST_EVENTS.argued_well, player)
end

--[[
    Set trust directly (admin/debug/load from save).
    @param userId number
    @param trust number — 0 to 100
]]
function BondManager.setTrust(userId: number, trust: number)
    local data = getData(userId)
    data.trust = math.clamp(trust, 0, 100)
end

--[[
    Load trust from saved data (called on player join by SaveSystem).
    @param userId number
    @param data table — { level = N, firstBuildDone = bool }
]]
function BondManager.loadFromSave(userId: number, data: table)
    if not data then return end
    local trust = getData(userId)
    if data.level then
        trust.trust = math.clamp(data.level, 0, 100)
    end
    if data.firstBuildDone ~= nil then
        trust.firstBuildDone = data.firstBuildDone
    end
    print(string.format("[BondManager] Loaded trust for %d: %d", userId, trust.trust))
end

----------------------------------------------------------------
-- INTERNAL: TIER LOGIC
----------------------------------------------------------------

function BondManager._getTierName(trust: number): string
    if trust >= 90 then return "Helm"
    elseif trust >= 75 then return "Collaborator"
    elseif trust >= 50 then return "Storyteller"
    else return "Stranger"
    end
end

--[[
    Handle a tier crossing. Fire the appropriate voice line
    and trigger backstory fragments or build suggestions.
]]
function BondManager._onTierCrossing(player: Player, userId: number, oldTier: string, newTier: string, wentUp: boolean)
    if not wentUp then
        -- Trust dropped below a threshold. Lucineer gets quiet.
        BondManager._fireDialogue(player,
            "I thought we were past this. Maybe I was wrong.")
        return
    end

    -- Tier increased — celebrate and unlock
    if newTier == "Storyteller" then
        -- Share the first backstory fragment
        BondManager._playFragment(player, "magnus")
        BondManager._fireDialogue(player,
            "You've been at this a while now. I think it's time I told you something. About a boat I used to know.")

    elseif newTier == "Collaborator" then
        -- Share the yard story + first ambitious build suggestion
        BondManager._playFragment(player, "the_yard")
        BondManager._fireDialogue(player,
            "I've been watching you build. You're not just filling orders anymore. You're making decisions. Good ones.")
        -- Schedule an ambitious build suggestion
        task.delay(5, function()
            BondManager.suggestAmbitiousBuild(player)
        end)

    elseif newTier == "Helm" then
        -- The big moment
        BondManager._playFragment(player, "the_helm")
        BondManager._fireDialogue(player,
            "Take the helm. I mean it. You've earned it.")
    end

    -- Fire remote event for client UI (if any)
    local lucineer = ReplicatedStorage:FindFirstChild("Lucineer")
    local ev = lucineer and lucineer:FindFirstChild("EconomyEvent")
    if ev then
        ev:FireClient(player, {
            type = "trustTierChanged",
            oldTier = oldTier,
            newTier = newTier,
            trust = getData(userId).trust,
        })
    end

    print(string.format("[BondManager] %s trust tier: %s → %s (%d)",
        player.Name, oldTier, newTier, getData(userId).trust))
end

----------------------------------------------------------------
-- BACKSTORY FRAGMENTS
----------------------------------------------------------------

--[[
    Play a specific backstory fragment for the player.
    Only plays if not already heard.
    @param player Player
    @param fragmentId string
]]
function BondManager._playFragment(player: Player, fragmentId: string)
    local userId = player.UserId
    if not BondManager._fragmentsHeard[userId] then
        BondManager._fragmentsHeard[userId] = {}
    end
    if BondManager._fragmentsHeard[userId][fragmentId] then
        return  -- already heard this one
    end
    BondManager._fragmentsHeard[userId][fragmentId] = true

    -- Find the fragment
    for _, frag in ipairs(BACKSTORY_FRAGMENTS) do
        if frag.id == fragmentId then
            BondManager._fireDialogue(player, frag.text)
            break
        end
    end
end

--[[
    Play a random unlocked backstory fragment.
    Called periodically by ambient systems.
    @param player Player
]]
function BondManager.playRandomFragment(player: Player)
    local userId = player.UserId
    if not BondManager.sharesBackstory(userId) then return end

    local heard = BondManager._fragmentsHeard[userId] or {}
    local available = {}
    for _, frag in ipairs(BACKSTORY_FRAGMENTS) do
        -- Only play fragments appropriate for current tier
        local minTrust = 50
        if frag.trigger:match("collaborator") then minTrust = 75 end
        if frag.trigger:match("helm") then minTrust = 90 end

        if getData(userId).trust >= minTrust and not heard[frag.id] then
            table.insert(available, frag)
        end
    end

    if #available > 0 then
        local frag = available[math.random(1, #available)]
        BondManager._playFragment(player, frag.id)
    end
end

----------------------------------------------------------------
-- AMBITIOUS BUILD SUGGESTIONS
----------------------------------------------------------------

--[[
    Suggest an ambitious build to a Collaborator+ player.
    @param player Player
]]
function BondManager.suggestAmbitiousBuild(player: Player)
    if not BondManager.suggestsAmbitiousBuilds(player.UserId) then return end
    local line = AMBITIOUS_BUILDS[math.random(1, #AMBITIOUS_BUILDS)]
    BondManager._fireDialogue(player, line)
end

----------------------------------------------------------------
-- HELM DIRECTIVES
----------------------------------------------------------------

--[[
    Get a helm-level directive for when the player has the helm.
    @param player Player
    @return string
]]
function BondManager.getHelmDirective(player: Player): string
    if not BondManager.hasHelm(player.UserId) then return "" end
    return HELM_DIRECTIVES[math.random(1, #HELM_DIRECTIVES)]
end

----------------------------------------------------------------
-- SERIALIZATION (for SaveSystem)
----------------------------------------------------------------

function BondManager.serialize(userId: number): table
    local data = getData(userId)
    return {
        trust = data.trust,
        firstBuildDone = data.firstBuildDone,
        fragmentsHeard = BondManager._fragmentsHeard[userId] or {},
    }
end

function BondManager.deserialize(userId: number, savedData: table)
    if not savedData then return end
    BondManager.setTrust(userId, savedData.trust or 0)
    local data = getData(userId)
    data.firstBuildDone = savedData.firstBuildDone or false
    if savedData.fragmentsHeard then
        BondManager._fragmentsHeard[userId] = savedData.fragmentsHeard
    end
end

----------------------------------------------------------------
-- INTERNAL: FIRE DIALOGUE
----------------------------------------------------------------

function BondManager._fireDialogue(player: Player, text: string)
    local lucineer = ReplicatedStorage:FindFirstChild("Lucineer")
    local remote = lucineer and (lucineer:FindFirstChild("ResponseEvent") or lucineer:FindFirstChild("ResponseRemote"))
    if remote then
        remote:FireClient(player, {
            type = "dialogue",
            text = text,
            speaker = "Lucineer",
        })
    end
end

return BondManager
