--!strict
--[[
    EmotionalHandler.lua — Emotional Context Detection for Build Requests
    ======================================================================
    "Lucineer doesn't just build what you ask for. She builds what you need.
     Half the job is reading the weather in your voice."

    Detects emotional keywords in player messages and:
      1. Tags the build request with emotional context for brain.py
      2. Modifies Lucineer's response to acknowledge the feeling
      3. Guides the build type toward something thematically appropriate

    Emotion → Build Mapping:
      scared  → shelter, warm light, enclosed space (comfort)
      lonely  → companion structure, signal tower, dock (connection)
      sad     → quiet garden, memorial, soft materials (gentleness)
      happy   → flag, decoration, bright colors (celebration)
      excited → tower, monument, grand structure (ambition)
      angry   → target range, heavy materials, loud objects (catharsis)
      worried → watchtower, warning system, sturdy walls (protection)

    Usage:
        local EmotionalHandler = require(script.Parent.EmotionalHandler)

        -- Analyze a player message
        local ctx = EmotionalHandler.analyze(message)
        if ctx.emotion then
            -- Attach to request payload
            requestPayload.emotionalContext = ctx

            -- Get Lucineer's empathic pre-response
            local preLine = EmotionalHandler.getPreResponse(ctx.emotion)
        end
]]

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local EmotionalHandler = {}

----------------------------------------------------------------
-- EMOTION DEFINITIONS
----------------------------------------------------------------

--[[
    Emotion definitions.
    Each entry has:
      keywords   : {string} — lowercase patterns to match
      buildHints : {string} — suggested build types for brain.py
      preResponse: string — Lucineer's line before building
      postResponse: string — Lucineer's line after build completes
      modifier   : string — build instruction modifier for the AI
]]

local EMOTIONS = {
    scared = {
        keywords = { "scared", "afraid", "frightened", "terrified", "hide", "help me", "monster", "dark" },
        buildHints = { "shelter", "warm light", "enclosed space", "safe room", "lantern", "fireplace" },
        preResponse = "I hear you. Let's get you somewhere safe first.",
        postResponse = "There. Walls around you, light inside. Nothing's getting through that.",
        modifier = "Build something comforting and protective — warm lighting, enclosed walls, a place that feels safe from whatever scared them.",
    },
    lonely = {
        keywords = { "lonely", "alone", "nobody", "no one", "by myself", "miss", "empty" },
        buildHints = { "signal tower", "dock", "lantern post", "bench", "meeting hall" },
        preResponse = "The quiet gets heavy, doesn't it. Let me build toward someone.",
        postResponse = "Now there's a place for someone to find you. The light means 'come here.'",
        modifier = "Build something that reaches outward — a signal, a dock, a place that invites company. The structure should feel like it's waiting for someone to arrive.",
    },
    sad = {
        keywords = { "sad", "hurt", "cry", "tears", "broken", "lost", "grief", "miss" },
        buildHints = { "garden", "memorial", "soft material", "quiet space", "bench", "flowers" },
        preResponse = "I know. I know. Let me make something gentle.",
        postResponse = "It's quiet here. You can sit with it. That's allowed.",
        modifier = "Build something gentle and quiet — soft materials, muted tones, a space that holds sorrow without trying to fix it.",
    },
    happy = {
        keywords = { "happy", "great", "awesome", "love it", "amazing", "wonderful", "perfect", "yay" },
        buildHints = { "flag", "decoration", "bright color", "banner", "fountain", "celebration" },
        preResponse = "Now that's the spirit! Let's mark the occasion.",
        postResponse = "Look at that. Even the light hits it different when you're happy.",
        modifier = "Build something celebratory — bright colors, flags, decorations, a structure that feels like a festival.",
    },
    excited = {
        keywords = { "excited", "can't wait", "let's go", "finally", "incredible", "mind blown", "woah" },
        buildHints = { "tower", "monument", "grand structure", "spire", "lookout" },
        preResponse = "I love that energy. Let's build something worth being excited about.",
        postResponse = "That's a statement. When people see this, they'll know something happened here.",
        modifier = "Build something ambitious and towering — a monument, a spire, something that reaches higher than it should. The structure should feel like ambition made physical.",
    },
    angry = {
        keywords = { "angry", "mad", "furious", "hate", "rage", "frustrated", "annoyed", "pissed" },
        buildHints = { "target", "heavy material", "loud object", "training dummy", "anvil", "forge" },
        preResponse = "Alright. Let's put that somewhere useful.",
        postResponse = "Hit it if you need to. It can take it. That's what it's for.",
        modifier = "Build something cathartic — heavy materials, something that can be struck or challenged. The structure should feel like an outlet for force, not a target for anger.",
    },
    worried = {
        keywords = { "worried", "anxious", "nervous", "concerned", "what if", "hope", "dread" },
        buildHints = { "watchtower", "warning bell", "sturdy wall", "lookout", "signal post" },
        preResponse = "Let's build toward being ready, then. That helps.",
        postResponse = "Now you'll see them coming. And you'll be ready.",
        modifier = "Build something protective and vigilant — a watchtower, walls, a warning system. The structure should feel like preparedness, not fear.",
    },
}

-- Reverse index: keyword → emotion key (built at init)
local _keywordIndex: {[string]: string} = {}

----------------------------------------------------------------
-- INITIALIZATION
----------------------------------------------------------------

function EmotionalHandler.init()
    -- Build keyword reverse index
    for emotionKey, def in pairs(EMOTIONS) do
        for _, keyword in ipairs(def.keywords) do
            _keywordIndex[keyword] = emotionKey
        end
    end
    print("[EmotionalHandler] Initialized — " .. #table.clone({}) .. " emotion patterns loaded")
    -- Count emotions
    local count = 0
    for _ in pairs(EMOTIONS) do count += 1 end
    print(string.format("[EmotionalHandler] %d emotion types tracked", count))
end

----------------------------------------------------------------
-- ANALYSIS
----------------------------------------------------------------

--[[
    Analyze a player message for emotional content.
    Returns an emotion context table, or nil if no emotion detected.

    @param message string -- the raw player message
    @return table? -- { emotion, confidence, hints, modifier, preResponse, postResponse }
]]
function EmotionalHandler.analyze(message: string): table?
    if not message or message == "" then return nil end

    local lower = string.lower(message)
    local bestEmotion: string? = nil
    local bestMatches = 0

    -- Score each emotion by keyword hit count
    local scores: {[string]: number} = {}
    for emotionKey, def in pairs(EMOTIONS) do
        local hits = 0
        for _, keyword in ipairs(def.keywords) do
            if string.find(lower, keyword, 1, true) then
                hits += 1
            end
        end
        if hits > 0 then
            scores[emotionKey] = hits
            if hits > bestMatches then
                bestMatches = hits
                bestEmotion = emotionKey
            end
        end
    end

    if not bestEmotion then return nil end

    local def = EMOTIONS[bestEmotion]
    if not def then return nil end

    -- Confidence: 0.4 base for one hit, +0.2 per additional hit, cap 1.0
    local confidence = math.min(0.4 + (bestMatches - 1) * 0.2, 1.0)

    return {
        emotion = bestEmotion :: string,
        confidence = confidence,
        keywordHits = bestMatches,
        buildHints = def.buildHints,
        modifier = def.modifier,
        preResponse = def.preResponse,
        postResponse = def.postResponse,
    }
end

----------------------------------------------------------------
-- RESPONSE GENERATION
----------------------------------------------------------------

--[[
    Get Lucineer's empathic pre-response line for an emotion.
    Called BEFORE the build request is sent to brain.py.

    @param emotion string -- the detected emotion key
    @return string -- Lucineier's dialogue line, or "" if unknown emotion
]]
function EmotionalHandler.getPreResponse(emotion: string): string
    local def = EMOTIONS[emotion]
    if not def then return "" end
    return def.preResponse
end

--[[
    Get Lucineer's post-build response line for an emotion.
    Called AFTER the build completes.

    @param emotion string -- the detected emotion key
    @return string -- Lucineier's dialogue line, or "" if unknown emotion
]]
function EmotionalHandler.getPostResponse(emotion: string): string
    local def = EMOTIONS[emotion]
    if not def then return "" end
    return def.postResponse
end

----------------------------------------------------------------
-- REQUEST ENRICHMENT
----------------------------------------------------------------

--[[
    Enrich a build request payload with emotional context.
    Adds emotional metadata that brain.py can use to influence the build.

    @param payload table -- the existing request payload
    @param ctx table -- the emotion context from analyze()
    @return table -- the enriched payload
]]
function EmotionalHandler.enrichRequest(payload: table, ctx: table): table
    if not ctx or not ctx.emotion then return payload end

    payload.emotionalContext = {
        emotion = ctx.emotion,
        confidence = ctx.confidence,
        buildHints = ctx.buildHints,
        modifier = ctx.modifier,
    }

    -- Also append the modifier to the message itself so the AI
    -- sees the emotional framing alongside the build request
    if payload.message and ctx.modifier then
        payload.message = payload.message .. " [Emotional context: " .. ctx.modifier .. "]"
    end

    return payload
end

----------------------------------------------------------------
-- RETURN
----------------------------------------------------------------

return EmotionalHandler
