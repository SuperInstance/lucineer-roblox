--[[
    Lucineer World Scanner
    Collects world state around a player: position, nearby parts, models, lights, etc.
    Caps at Config.SCAN_MAX_INSTANCES to avoid huge payloads.

    GAP #10 Fixes:
      10a: Uses GetPartBoundsInRadius spatial query instead of GetDescendants().
      10b: Collects ALL candidates first, sorts by distance, THEN caps to N nearest.
      10c: isRelevant no longer calls IsDescendantOf(nil) when Camera is absent.
      10d: Build count is maintained by CommandExecutor._partsCreated — no tree recount.
]]

local Config = require(script.Parent.Config)

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local WorldScanner = {}

-- Build count cache — incremented by CommandExecutor, read by quickScan.
-- Set externally via WorldScanner.setBuildCount().
WorldScanner._cachedBuildCount = 0

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

--[[
    Collect character models for the spatial query exclusion filter.
    Returns an array of Instances to exclude (player characters + their descendants).
]]
local function getCharacterModels(): { Instance }
    local exclude = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then
            table.insert(exclude, player.Character)
        end
    end
    return exclude
end

--[[
    Check if an instance is inside a player's character model.
    Walks up the ancestor chain looking for a Model with a Player.
]]
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
    Determine if an instance is relevant for scanning.
    GAP #10c: No longer calls IsDescendantOf(nil) — the Camera check is removed
    entirely since the player-character check below already filters out
    camera attachments. The old check threw when Workspace had no Camera.
]]
local function isRelevant(instance: Instance): boolean
    local className = instance.ClassName

    -- Only collect physical objects we care about
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
local function serializeInstance(instance: Instance): { [string]: any }?
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
    GAP #10a/#10b: Spatial query instead of full-tree walk.
    Uses GetPartBoundsInRadius to find parts near the player, then
    collects ALL candidates, sorts by distance, THEN caps to N nearest.
]]
local function collectNearby(playerPosition: Vector3): { { [string]: any } }
    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = getCharacterModels()
    -- Overshoot so we have enough after filtering by relevance + distance sort
    params.MaxParts = Config.SCAN_MAX_INSTANCES * 4

    local parts = Workspace:GetPartBoundsInRadius(
        playerPosition, Config.SCAN_RADIUS, params)

    local candidates = {}
    for _, part in ipairs(parts) do
        if isRelevant(part) then
            local serialized = serializeInstance(part)
            if serialized then
                serialized.distance = (part.Position - playerPosition).Magnitude
                table.insert(candidates, serialized)
            end
        end
    end

    -- GAP #10b: Sort BEFORE capping — keep the nearest N, not the first N in traversal order.
    table.sort(candidates, function(a, b)
        return (a.distance or 0) < (b.distance or 0)
    end)

    -- Cap to max instances
    while #candidates > Config.SCAN_MAX_INSTANCES do
        table.remove(candidates)
    end

    return candidates
end

--[[
    Full world-state scan for a given player.
    Uses spatial query (GetPartBoundsInRadius) instead of full workspace traversal.
    @param player Player
    @return { [string]: any } -- structured world state
]]
function WorldScanner.scan(player: Player): { [string]: any }
    local character = player.Character
    if not character then
        return { error = "Player has no character" }
    end

    local hrp = character:FindFirstChild("HumanoidRootPart")
    local position = hrp and hrp.Position or (character:GetPivot().Position)

    local instances = collectNearby(position)

    local state = {
        player = {
            name = player.Name,
            userId = player.UserId,
            position = { x = position.X, y = position.Y, z = position.Z },
        },
        nearbyInstances = instances,
        instanceCount = #instances,
        buildCount = WorldScanner._cachedBuildCount,
        timestamp = os.time(),
        placeId = game.PlaceId,
    }

    print(string.format("[Lucineer] WorldScanner: scanned %d instances near %s (buildCount=%d from cache)",
        #instances, player.Name, WorldScanner._cachedBuildCount))

    return state
end

--[[
    Lightweight scan — just position + cached counts, no instance list.
    Uses cached build count from CommandExecutor to avoid workspace traversal.
    @param player Player
    @return { [string]: any }
]]
function WorldScanner.quickScan(player: Player): { [string]: any }
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
        buildCount = WorldScanner._cachedBuildCount,
        timestamp = os.time(),
    }
end

--[[
    GAP #10d: Allow CommandExecutor to update the cached build count
    without triggering a full workspace traversal.
    @param count number -- the new build count
]]
function WorldScanner.setBuildCount(count: number)
    WorldScanner._cachedBuildCount = count
end

--[[
    Increment the cached build count by 1.
    Called by CommandExecutor after each successful createPart.
]]
function WorldScanner.incrementBuildCount()
    WorldScanner._cachedBuildCount += 1
end

return WorldScanner
