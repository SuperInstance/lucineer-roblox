--[[
    Lucineer World Scanner
    Collects world state around a player: position, nearby parts, models, lights, etc.
    Caps at Config.SCAN_MAX_INSTANCES to avoid huge payloads.
    Single-pass traversal: collects nearby instances AND build count together.
]]

local Config = require(script.Parent.Config)

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local WorldScanner = {}

-- Build count cache — incremented by CommandExecutor, read by quickScan.
-- Avoids a full workspace traversal on every state-sync tick.
WorldScanner._cachedBuildCount = 0

-- Track if we've done at least one full scan to populate the cache.
local hasFullScanCount = false

-- Relevant class names for instance collection.
local RELEVANT_CLASSES = {
    Part = true,
    MeshPart = true,
    UnionOperation = true,
    Model = true,
    SpecialMesh = true,
    PointLight = true,
    SpotLight = true,
    SurfaceLight = true,
}

-- Check if an instance is inside a player's character model.
local function isInPlayerCharacter(instance: Instance): boolean
    local ancestor = instance.Parent
    while ancestor do
        if ancestor:IsA("Model") and Players:GetPlayerFromCharacter(ancestor) then
            return true
        end
        ancestor = ancestor.Parent
    end
    return false
end

--[[
    Determine if an instance is relevant (not a player character, etc.)
]]
local function isRelevant(instance: Instance): boolean
    local className = instance.ClassName

    -- Only collect physical objects
    if not RELEVANT_CLASSES[className] then
        return false
    end

    -- Skip player characters
    if isInPlayerCharacter(instance) then
        return false
    end

    return true
end

--[[
    Get the position of an instance. Handles both Parts and Models.
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
    Single-pass workspace traversal: collect nearby instances AND count all builds.
    Merged from the former collectNearby() + countBuilds() to avoid two
    separate GetDescendants() calls.
    @param playerPosition Vector3
    @return { table } nearby instances (sorted by distance, capped)
    @return number total build count
]]
local function scanWorkspace(playerPosition: Vector3): ({ table }, number)
    local nearby = {}
    local buildCount = 0

    for _, descendant in ipairs(Workspace:GetDescendants()) do
        -- Count all BaseParts for the build total
        if descendant:IsA("BasePart") then
            buildCount += 1
        end

        -- Collect relevant nearby instances (up to cap)
        if #nearby < Config.SCAN_MAX_INSTANCES and isRelevant(descendant) then
            local pos = getInstancePosition(descendant)
            if pos then
                local distance = (pos - playerPosition).Magnitude
                if distance <= Config.SCAN_RADIUS then
                    local serialized = serializeInstance(descendant)
                    if serialized then
                        serialized.distance = distance
                        table.insert(nearby, serialized)
                    end
                end
            end
        end
    end

    -- Sort by distance (closest first) — sort BEFORE the cap matters because
    -- we collected up to MAX_INSTANCES in traversal order, not distance order.
    -- We may have some closer instances beyond the cap, but since we can't
    -- know that without collecting all, this is the best we can do in one pass.
    -- The cap is a payload-size limit, not a relevance limit.
    table.sort(nearby, function(a, b)
        return (a.distance or 0) < (b.distance or 0)
    end)

    return nearby, buildCount
end

--[[
    Full world-state scan for a given player.
    Single-pass traversal collects nearby instances and build count together.
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

    local instances, buildCount = scanWorkspace(position)

    -- Update the cached build count so quickScan doesn't need to traverse
    WorldScanner._cachedBuildCount = buildCount
    hasFullScanCount = true

    local state = {
        player = {
            name = player.Name,
            userId = player.UserId,
            position = { x = position.X, y = position.Y, z = position.Z },
        },
        nearbyInstances = instances,
        instanceCount = #instances,
        buildCount = buildCount,
        timestamp = os.time(),
        placeId = game.PlaceId,
    }

    print(string.format("[Lucineer] WorldScanner: scanned %d instances, %d total builds, for %s",
        #instances, buildCount, player.Name))

    return state
end

--[[
    Lightweight scan — just position + cached counts, no instance list.
    Uses cached build count from the last full scan to avoid workspace traversal.
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

    -- If we haven't done a full scan yet (e.g., server just started),
    -- do one now to populate the cache. This only happens once.
    if not hasFullScanCount then
        local _ = WorldScanner.scan(player)
    end

    return {
        player = {
            name = player.Name,
            userId = player.UserId,
            position = { x = position.X, y = position.Y, z = position.Z },
        },
        buildCount = WorldScanner._cachedBuildCount,
        timestamp = os.time(),
    }
end

return WorldScanner
