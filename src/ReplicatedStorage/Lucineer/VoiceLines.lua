--[[
    VoiceLines — Lucineer's voice line system.
    Provides category-based retrieval, trigger matching, template lookups,
    and weighted random selection.

    Usage:
        local VoiceLines = require(ReplicatedStorage.Lucineer.VoiceLines)
        VoiceLines.init()

        local greeting = VoiceLines.get("GREETING")
        local match    = VoiceLines.getByTrigger("hello")
        local tower    = VoiceLines.forTemplate("tower")
        local weighted = VoiceLines.getWeighted()
]]

local data = require(script.Parent.VoiceLinesData)

local VoiceLines = {}

-- Internal state
VoiceLines._byCategory = {}      -- [category] = { entries }
VoiceLines._byTrigger  = {}      -- [lowercase_trigger] = entry
VoiceLines._templates   = {}      -- [lowercase_template_name] = entry
VoiceLines._initialized = false

-- Category weights for weighted random selection.
-- Common categories appear more frequently; rare ones less so.
local CATEGORY_WEIGHTS = {
    GREETING    = 20,
    TEMPLATES   = 20,
    FIRST_BUILD = 12,
    FAREWELL    = 10,
    IDLE        = 10,
    ARGUMENTS   = 8,
    IMPRESSED   = 4,   -- rare
    REFUSAL     = 3,   -- rarest
}

--[[
    Build lookup tables from the raw data.
]]
function VoiceLines.init()
    if VoiceLines._initialized then return end
    VoiceLines._initialized = true

    for _, entry in ipairs(data) do
        local cat = entry.category
        local trig = entry.trigger:lower()

        -- Index by category
        if not VoiceLines._byCategory[cat] then
            VoiceLines._byCategory[cat] = {}
        end
        table.insert(VoiceLines._byCategory[cat], entry)

        -- Index by trigger (lowercased)
        VoiceLines._byTrigger[trig] = entry

        -- TEMPLATES entries are also templates
        if cat == "TEMPLATES" then
            VoiceLines._templates[trig] = entry
        end
    end

    print(string.format("[Lucineer] VoiceLines: loaded %d lines across %d categories",
        #data, (function()
            local count = 0
            for _ in pairs(VoiceLines._byCategory) do count = count + 1 end
            return count
        end)()))
end

--[[
    Ensure init has been called (lazy guard).
]]
local function ensureInit()
    if not VoiceLines._initialized then
        VoiceLines.init()
    end
end

--[[
    Get a random line from a specific category.
    @param category string -- e.g. "GREETING", "TEMPLATES"
    @return string -- the line text, or nil if category not found
]]
function VoiceLines.get(category: string): string?
    ensureInit()
    local entries = VoiceLines._byCategory[category]
    if not entries or #entries == 0 then
        warn(string.format("[Lucineer] VoiceLines: no entries for category '%s'", tostring(category)))
        return nil
    end
    local idx = math.random(1, #entries)
    return entries[idx].line
end

--[[
    Get a specific line by its trigger keyword.
    Does a case-insensitive lookup; falls back to partial substring match.
    @param trigger string -- e.g. "hello", "tower"
    @return string? -- the matching line, or nil if no match
]]
function VoiceLines.getByTrigger(trigger: string): string?
    ensureInit()
    local key = trigger:lower()

    -- Exact match first
    local entry = VoiceLines._byTrigger[key]
    if entry then
        return entry.line
    end

    -- Partial substring match: find a trigger that contains the input
    for trig, ent in pairs(VoiceLines._byTrigger) do
        if trig:find(key, 1, true) then
            return ent.line
        end
    end

    return nil
end

--[[
    Get the template-specific line for a structure name.
    Falls back to the "default" template if the name isn't found.
    @param templateName string -- e.g. "tower", "castle"
    @return string -- the template line (always returns something)
]]
function VoiceLines.forTemplate(templateName: string): string
    ensureInit()
    local key = templateName:lower()

    local entry = VoiceLines._templates[key]
    if entry then
        return entry.line
    end

    -- Fallback to default template
    local default = VoiceLines._templates["default"]
    if default then
        return default.line
    end

    -- Ultimate fallback
    return "A structure, waiting to take shape."
end

--[[
    Weighted random selection across all categories.
    Rare categories (IMPRESSED, REFUSAL) appear less frequently.
    @return string -- a weighted-random line
]]
function VoiceLines.getWeighted(): string
    ensureInit()

    -- Build a weighted list of categories that have entries
    local weightedCats = {}
    local totalWeight = 0

    for cat, weight in pairs(CATEGORY_WEIGHTS) do
        local entries = VoiceLines._byCategory[cat]
        if entries and #entries > 0 then
            table.insert(weightedCats, { category = cat, weight = weight })
            totalWeight = totalWeight + weight
        end
    end

    if totalWeight == 0 then
        -- Nothing loaded; return a safe default
        return "..."
    end

    -- Pick a category based on weight
    local roll = math.random() * totalWeight
    local accumulated = 0
    local chosenCat = weightedCats[1].category

    for _, wc in ipairs(weightedCats) do
        accumulated = accumulated + wc.weight
        if roll <= accumulated then
            chosenCat = wc.category
            break
        end
    end

    -- Now pick a random line within that category
    return VoiceLines.get(chosenCat) or "..."
end

--[[
    Get all categories that have entries.
    @return table -- array of category names
]]
function VoiceLines.getCategories(): {string}
    ensureInit()
    local cats = {}
    for cat in pairs(VoiceLines._byCategory) do
        table.insert(cats, cat)
    end
    return cats
end

--[[
    Get the number of lines in a category.
    @param category string
    @return number
]]
function VoiceLines.getCount(category: string): number
    ensureInit()
    local entries = VoiceLines._byCategory[category]
    return entries and #entries or 0
end

return VoiceLines
