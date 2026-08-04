--!strict
--[[
    HarborLife.lua — Ambient Harbor Activity
    Makes the harbor feel alive: other boats, workers, gulls, sounds.
]]

local HarborLife = {}

HarborLife._ambientBoats = {}
HarborLife._effects = {}

function HarborLife.init()
    print("[HarborLife] Initialized")
end

-- Schedule NPC fishing boats that depart and return
function HarborLife.spawnAmbientBoats()
    local schedule = {
        { departHour = 5, returnHour = 15, name = "Marie B" },
        { departHour = 6, returnHour = 17, name = "Cora Lee" },
        { departHour = 4, returnHour = 12, name = "Old Salt" },
    }
    HarborLife._ambientBoats = schedule
end

function HarborLife.tick(gameHour, workspace)
    -- Check if any ambient boats should depart or return
    for _, boat in ipairs(HarborLife._ambientBoats) do
        if gameHour >= boat.departHour and gameHour < boat.returnHour then
            boat.state = "at_sea"
        elseif boat.state == "at_sea" then
            boat.state = "docked"
            -- Boat returns — could spawn catch unloading effect
            HarborLife._spawnUnloadEffect(workspace)
        end
    end
end

function HarborLife._spawnUnloadEffect(workspace)
    -- Fork this — smoke from cannery when processing
    task.spawn(function()
        task.wait(math.random(5, 30))
        -- Could add particle effects here
    end)
end

-- Get harbor atmosphere state
function HarborLife.getAtmosphere(gameHour, weatherState)
    local atmo = {
        smokeFromCannery = true,  -- always processing during day
        harborLightsOn = (gameHour < 6 or gameHour > 18),
        gullIntensity = (gameHour > 6 and gameHour < 18) and 1.0 or 0.2,
        foghornActive = (weatherState == "fog"),
        workersActive = (gameHour > 6 and gameHour < 18),
    }

    if gameHour < 6 or gameHour > 18 then
        atmo.smokeFromCannery = false
    end

    return atmo
end

return HarborLife
