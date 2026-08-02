--[[
    Lucineer World Scanner
    Collects world state around a player: position, nearby parts, models, lights, etc.
    Caps at Config.SCAN_MAX_INSTANCES to avoid huge payloads.
]]

local Config = require(script.Parent.Config)

local Workspace = game:GetService("Workspace")

local WorldScanner = {}

--[[
    Determine if an instance is relevant (not Lucineer's own generated content,
    not a character model, etc.)
    @param instance Instance
    @return boolean
]]
local function isRelevant(instance: Instance): boolean
    -- Skip nil-anchored floating server things
    local className = instance.ClassName

    -- Only collect physical objects
    if className ~= "Part" and className ~= "MeshPart" and className ~= "UnionOperation" and className ~= "Model" and className ~= "SpecialMesh" and className ~= "PointLight" and className ~= "SpotLight" and className ~= "SurfaceLight" then
        return false
    end

    -- Skip player characters
    if instance:IsDescendantOf(workspace:FindFirstChildOfClass("Camera")) then
        return false
    end

    -- Check if it's inside a Player's character
    local ancestor = instance.Parent
    while ancestor do
        if ancestor:IsA("Model") and game:GetService("Players"):GetPlayerFromCharacter(ancestor) then
            return false
        end
        ancestor = ancestor.Parent
    end

    return true
end

--[[
    Get the position of an instance. Handles both Parts and Models.
    @param instance Instance
    @return Vector3?
]]
local function getInstancePosition(instance: Instance): Vector3?
    if instance:IsA("BasePart") then
        return instance.Position
    elseif instance:IsA("Model") then
        return instance:GetPivot().Position
    elseif instance:IsA("PVInstance") then
        return instance:GetPivot().Position
    end
    return nil
end

--[[
    Serialize a single instance into a compact table for the AI.
    @param instance Instance
    @return table? -- nil if it can't be serialized
]]
local function serializeInstance(instance: Instance): table?
    local pos = getInstancePosition(instance)
    if not pos then return nil end

    local serialized: { [string]: any } = {
        name = instance.Name,
        class = instance.ClassName,
        position = { x = pos.X, y = pos.Y, z = pos.Z },
    }

    -- Add size/material for BaseParts
    if instance:IsA("BasePart") then
        serialized.size = { x = instance.Size.X, y = instance.Size.Y, z = instance.Size.Z }
        serialized.material = tostring(instance.Material)
        serialized.color = string.format("#%02X%02X%02X",
            instance.Color.R * 255,
            instance.Color.G * 255,
            instance.Color.B * 255
        )
        serialized.anchored = instance.Anchored
        serialized.transparency = instance.Transparency
    end

    -- Light properties
    if instance:IsA("Light") then
        serialized.brightness = instance.Brightness
        serialized.range = instance.Range
        serialized.color = string.format("#%02X%02X%02X",
            instance.Color.R * 255,
            instance.Color.G * 255,
            instance.Color.B * 255
        )
    end

    return serialized
end

--[[
    Collect instances within SCAN_RADIUS of the player.
    @param playerPosition Vector3 -- the player's character position
    @return { table } -- array of serialized instances
]]
local function collectNearby(playerPosition: Vector3): { table }
    local nearby = {}
    local count = 0

    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if count >= Config.SCAN_MAX_INSTANCES then
            print(string.format("[Lucineer] WorldScanner: hit cap of %d instances", Config.SCAN_MAX_INSTANCES))
            break
        end

        if isRelevant(descendant) then
            local pos = getInstancePosition(descendant)
            if pos then
                local distance = (pos - playerPosition).Magnitude
                if distance <= Config.SCAN_RADIUS then
                    local serialized = serializeInstance(descendant)
                    if serialized then
                        serialized.distance = distance
                        table.insert(nearby, serialized)
                        count += 1
                    end
                end
            end
        end
    end

    return nearby
end

--[[
    Count how many parts exist in the workspace (rough "build count").
    @return number
]]
local function countBuilds(): number
    local count = 0
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant:IsA("BasePart") then
            count += 1
        end
    end
    return count
end

--[[
    Full world-state scan for a given player.
    @param player Player
    @return table -- structured world state
]]
function WorldScanner.scan(player: Player): table
    local character = player.Character
    if not character then
        return { error = "Player has no character" }
    end

    local hrp = character:FindFirstChild("HumanoidRootPart")
    local position = hrp and hrp.Position or (character:GetPivot().Position)

    local instances = collectNearby(position)

    -- Sort by distance (closest first)
    table.sort(instances, function(a, b)
        return (a.distance or 0) < (b.distance or 0)
    end)

    local state = {
        player = {
            name = player.Name,
            userId = player.UserId,
            position = { x = position.X, y = position.Y, z = position.Z },
        },
        nearbyInstances = instances,
        instanceCount = #instances,
        buildCount = countBuilds(),
        timestamp = os.time(),
        placeId = game.PlaceId,
    }

    print(string.format("[Lucineer] WorldScanner: scanned %d instances, %d total builds, for %s",
        #instances, state.buildCount, player.Name))

    return state
end

--[[
    Lightweight scan — just position + counts, no instance list.
    Useful for periodic state sync.
    @param player Player
    @return table
]]
function WorldScanner.quickScan(player: Player): table
    local character = player.Character
    if not character then
        return { error = "Player has no character" }
    end

    local hrp = character:FindFirstChild("HumanoidRootPart")
    local position = hrp and hrp.Position or (character:GetPivot().Position)

    return {
        player = {
            name = player.Name,
            userId = player.UserId,
            position = { x = position.X, y = position.Y, z = position.Z },
        },
        buildCount = countBuilds(),
        timestamp = os.time(),
    }
end

return WorldScanner
