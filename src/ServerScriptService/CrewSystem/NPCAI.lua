--!strict
--[[
    NPCAI.lua — Daily Routines for Harbor NPCs
    NPCs move between locations on a schedule, react to weather, and acknowledge player.
]]

local NPCAI = {}

local SCHEDULES = {
    Earl = {
        { start = 6, stop = 12, location = "cannery", activity = "working" },
        { start = 12, stop = 13, location = "harbor_cafe", activity = "lunch" },
        { start = 13, stop = 18, location = "cannery", activity = "working" },
        { start = 18, stop = 6, location = "home", activity = "off_duty" },
    },
    Spark = {
        { start = 5, stop = 20, location = "forge", activity = "working" },
        { start = 20, stop = 5, location = "home", activity = "sleeping" },
    },
    Hermes = {
        { start = 5, stop = 7, location = "dock", activity = "prepping_boat" },
        { start = 7, stop = 17, location = "on_water", activity = "fishing" },
        { start = 17, stop = 19, location = "dock", activity = "docking" },
        { start = 19, stop = 5, location = "home", activity = "off_duty" },
    },
    Bea = {
        { start = 6, stop = 18, location = "lighthouse", activity = "maintaining" },
        { start = 18, stop = 6, location = "lighthouse", activity = "watch" },
    },
}

local LOCATIONS = {
    cannery = Vector3.new(-12, 1.5, -8),
    harbor_cafe = Vector3.new(10, 1.5, 5),
    forge = Vector3.new(0, 1.5, 4),
    dock = Vector3.new(35, 3.5, -20),
    lighthouse = Vector3.new(-50, 25, -60),
    home = Vector3.new(-20, 1.5, 30),
    on_water = Vector3.new(100, 0, -200),
}

NPCAI._npcStates = {}  -- [npcName] = { currentLocation, model, walking }

function NPCAI.init()
    for name, _ in pairs(SCHEDULES) do
        NPCAI._npcStates[name] = {
            currentLocation = nil,
            model = nil,
            walking = false,
        }
    end
    print("[NPCAI] Initialized — " .. #NPCAI.getNPCList() .. " NPCs with schedules")
end

function NPCAI.getNPCList()
    local list = {}
    for name, _ in pairs(SCHEDULES) do
        table.insert(list, name)
    end
    return list
end

function NPCAI.getCurrentActivity(npcName, hour)
    hour = hour or (os.time() % 24)
    local schedule = SCHEDULES[npcName]
    if not schedule then return nil end
    for _, block in ipairs(schedule) do
        if hour >= block.start and hour < block.stop then
            return block
        end
    end
    return schedule[#schedule]
end

function NPCAI.getLocation(npcName, hour)
    local activity = NPCAI.getCurrentActivity(npcName, hour)
    if not activity then return nil end
    return LOCATIONS[activity.location]
end

function NPCAI.setNPCModel(npcName, model)
    if NPCAI._npcStates[npcName] then
        NPCAI._npcStates[npcName].model = model
    end
end

-- Update NPC position based on schedule (called periodically)
function NPCAI.tick(gameHour)
    for npcName, state in pairs(NPCAI._npcStates) do
        local target = NPCAI.getLocation(npcName, gameHour)
        if target and state.model then
            local currentPos = state.model:GetPivot().Position
            local distance = (target - currentPos).Magnitude
            if distance > 2 then
                -- NPC walks to target
                state.walking = true
                state.model:Pivot(CFrame.new(target))
            else
                state.walking = false
            end
        end
    end
end

return NPCAI
