--!strict
--[[
    DialogueSystem.lua — Context-Aware NPC Conversations
    Branching dialogue with bond-gating and rumor system.
]]

local DialogueSystem = {}

local DIALOGUE_TREES = {
    Earl = {
        work = {
            { bond = 0, text = "Cannery's open. Bring me fish, I'll pay fair." },
            { bond = 2, text = "You've been steady. I can trust you with special orders now." },
            { bond = 4, text = "You know, my father ran this place. Same rules. Fish don't lie." },
        },
        gossip = {
            { bond = 0, text = "I don't gossip. But if I did... Hermes owes me for dock fees." },
            { bond = 3, text = "Bea found something in the rocks last week. Won't tell me what." },
        },
        advice = {
            { bond = 0, text = "Halibut bring the best price. But they're deep. You'll need gear." },
            { bond = 2, text = "Storm's coming? Don't head out. Fish aren't worth your hull." },
        },
    },
    Spark = {
        work = {
            { bond = 0, text = "Engine troubles? Bring it here. I fix things." },
            { bond = 2, text = "Your boat's running well. I been watching. You take care of her." },
        },
        gossip = {
            { bond = 0, text = "Did you hear Hermes? He was singing last night. LOUDLY." },
        },
        advice = {
            { bond = 0, text = "Copper wire's worth more than gold out here. Fish the kelp beds." },
        },
    },
    Hermes = {
        work = {
            { bond = 0, text = "Need a tow? I charge by the nautical mile. Fair rates." },
            { bond = 2, text = "I'll run rescue if you're in trouble. Don't make a habit of it." },
        },
        gossip = {
            { bond = 0, text = "There's a wreck north of the shoals. Big one. Nobody's worked it yet." },
            { bond = 3, text = "Earl was a fisherman before the cannery. Don't bring it up." },
        },
        advice = {
            { bond = 0, text = "Red right return. Keep the red buoys on your right coming in." },
            { bond = 2, text = "The channel shifts after storms. Trust your depth sounder, not memory." },
        },
    },
    Bea = {
        work = {
            { bond = 0, text = "The light must never go out. That's the deal." },
            { bond = 3, text = "You've been reliable. I have something for you. A chart. Old routes." },
        },
        gossip = {
            { bond = 0, text = "..." },
            { bond = 2, text = "Forty-Eight brought a shell yesterday. From very deep water. Unusual." },
        },
        advice = {
            { bond = 0, text = "Watch the fog. It comes fast. Know where you are at all times." },
        },
    },
}

local RUMORS = {
    "Storm coming Thursday. Big one, they say.",
    "Herring run's early this year.",
    "Saw a whale breach off the north point. Three times.",
    "Earl's paying double for salmon today. Don't know why.",
    "Spark's got a new engine part. Won't tell me where she found it.",
    "Bea's light was flickering last night. First time in years.",
}

function DialogueSystem.init()
    print("[DialogueSystem] Initialized")
end

function DialogueSystem.getLine(npcName, branch, bondLevel)
    local tree = DIALOGUE_TREES[npcName]
    if not tree then return "..." end
    local branchTree = tree[branch]
    if not branchTree then return "..." end

    -- Find highest bond-level line that player qualifies for
    local bestLine = branchTree[1].text
    for _, entry in ipairs(branchTree) do
        if bondLevel >= entry.bond then
            bestLine = entry.text
        end
    end
    return bestLine
end

function DialogueSystem.getBranches(npcName, bondLevel)
    local tree = DIALOGUE_TREES[npcName]
    if not tree then return {} end
    local available = {}
    for branch, _ in pairs(tree) do
        table.insert(available, branch)
    end
    return available
end

function DialogueSystem.getRandomRumor()
    return RUMORS[math.random(#RUMORS)]
end

return DialogueSystem
