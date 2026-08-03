--[[
    VoiceLinesData — Raw voice line data for Lucineer.
    Separated from logic so designers can tweak lines without touching code.

    Each entry: { category = string, trigger = string, line = string }
    50 lines across 8 categories.
]]

return {
    -- GREETING (5)
    { category = "GREETING",   trigger = "hello",         line = "Aye, who goes there?" },
    { category = "GREETING",   trigger = "greetings",      line = "Well met, traveler." },
    { category = "GREETING",   trigger = "hi",             line = "Speak your piece." },
    { category = "GREETING",   trigger = "hey",            line = "You need something built?" },
    { category = "GREETING",   trigger = "welcome",        line = "Welcome to my workshop." },

    -- FIRST_BUILD (5)
    { category = "FIRST_BUILD", trigger = "first build",     line = "Your first creation. Make it count." },
    { category = "FIRST_BUILD", trigger = "initial structure", line = "Every journey begins with one stone." },
    { category = "FIRST_BUILD", trigger = "beginning",       line = "The start of something grand." },
    { category = "FIRST_BUILD", trigger = "first construction", line = "Lay the foundation with care." },
    { category = "FIRST_BUILD", trigger = "new builder",     line = "A new builder is born." },

    -- TEMPLATES (17)
    { category = "TEMPLATES",   trigger = "tower",           line = "A tower, tall and true." },
    { category = "TEMPLATES",   trigger = "house",           line = "A house, a home, a hearth." },
    { category = "TEMPLATES",   trigger = "castle",          line = "A castle, fit for a king." },
    { category = "TEMPLATES",   trigger = "tree",            line = "A tree, reaching for the sun." },
    { category = "TEMPLATES",   trigger = "bridge",          line = "A bridge, spanning the divide." },
    { category = "TEMPLATES",   trigger = "wall",            line = "A wall, strong and steadfast." },
    { category = "TEMPLATES",   trigger = "road",            line = "A road, the path to adventure." },
    { category = "TEMPLATES",   trigger = "lamp",            line = "A lamp, to light the way." },
    { category = "TEMPLATES",   trigger = "pyramid",         line = "A pyramid, ancient and mysterious." },
    { category = "TEMPLATES",   trigger = "dome",            line = "A dome, a marvel of engineering." },
    { category = "TEMPLATES",   trigger = "arch",            line = "An arch, elegant and simple." },
    { category = "TEMPLATES",   trigger = "platform",        line = "A platform, a stage for stories untold." },
    { category = "TEMPLATES",   trigger = "staircase",       line = "A staircase, to ascend to new heights." },
    { category = "TEMPLATES",   trigger = "garden",          line = "A garden, where life blooms." },
    { category = "TEMPLATES",   trigger = "dock",            line = "A dock, where journeys begin and end." },
    { category = "TEMPLATES",   trigger = "lighthouse",      line = "A lighthouse, a beacon in the dark." },
    { category = "TEMPLATES",   trigger = "default",         line = "A structure, waiting to take shape." },

    -- ARGUMENTS (5)
    { category = "ARGUMENTS",  trigger = "wrong",           line = "You're wrong, and I'll prove it." },
    { category = "ARGUMENTS",  trigger = "disagree",        line = "We disagree, so be it." },
    { category = "ARGUMENTS",  trigger = "fight",           line = "Stand your ground, I'll stand mine." },
    { category = "ARGUMENTS",  trigger = "anger",           line = "Anger fuels the fire of creation." },
    { category = "ARGUMENTS",  trigger = "conflict",        line = "From conflict, comes progress." },

    -- IMPRESSED (5)
    { category = "IMPRESSED",  trigger = "amazing",         line = "Impressive. Very impressive." },
    { category = "IMPRESSED",  trigger = "great work",      line = "Your work is a sight to behold." },
    { category = "IMPRESSED",  trigger = "fantastic",       line = "Remarkable craftsmanship." },
    { category = "IMPRESSED",  trigger = "marvelous",       line = "A marvel, truly." },
    { category = "IMPRESSED",  trigger = "brilliant",       line = "Brilliant! A master's touch." },

    -- REFUSAL (5)
    { category = "REFUSAL",    trigger = "no",              line = "No, I won't do it." },
    { category = "REFUSAL",    trigger = "refuse",          line = "I refuse. Find another." },
    { category = "REFUSAL",    trigger = "reject",          line = "I reject your proposal." },
    { category = "REFUSAL",    trigger = "deny",            line = "I deny your request." },
    { category = "REFUSAL",    trigger = "decline",         line = "I decline. My answer is final." },

    -- FAREWELL (5)
    { category = "FAREWELL",   trigger = "goodbye",         line = "Until our next meeting." },
    { category = "FAREWELL",   trigger = "farewell",        line = "Farewell, traveler." },
    { category = "FAREWELL",   trigger = "see you",         line = "I'll see you when I see you." },
    { category = "FAREWELL",   trigger = "later",           line = "Later, builder." },
    { category = "FAREWELL",   trigger = "bye",             line = "Go in peace." },

    -- IDLE (3)
    { category = "IDLE",       trigger = "waiting",         line = "I'm waiting. Patiently." },
    { category = "IDLE",       trigger = "bored",           line = "Boredom is the enemy of creation." },
    { category = "IDLE",       trigger = "idle",            line = "In idleness, inspiration strikes." },

    -- BRAIN_REPLY (5) — in-voice completion lines after a build
    { category = "BRAIN_REPLY", trigger = "unfinished",     line = "There. One piece still waits for your hand." },
    { category = "BRAIN_REPLY", trigger = "left undone",    line = "I built it, but I left the last touch open." },
    { category = "BRAIN_REPLY", trigger = "gap",            line = "See the gap? That's where you finish the thought." },
    { category = "BRAIN_REPLY", trigger = "not done",       line = "A build is never finished — only paused." },
    { category = "BRAIN_REPLY", trigger = "one waiting",    line = "Mostly done. The last part is yours to place." },
}
