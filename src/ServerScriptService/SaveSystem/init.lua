--!strict
--[[
    SaveSystem — Slackwater Persistence Layer
    ===========================================
    Persists player builds, inventory, era progression, bond level,
    and terrain modifications across sessions.

    Architecture:
        - R2 bucket (via memory worker) for large data: build snapshots, terrain
        - D1 table (via memory worker) for small data: inventory, era, bond
        - In-memory cache for fast access during active sessions

    Usage:
        local SaveSystem = require(ServerScriptService.SaveSystem)
        SaveSystem.init()

        SaveSystem.savePlayer(playerName)
        SaveSystem.loadPlayer(playerName)
        SaveSystem.saveBuilds(playerName)
        SaveSystem.serializeBuilds()
        SaveSystem.deserializeBuilds(data)
        SaveSystem.createLegacyBuild(playerName)

    Dependencies:
        - ReplicatedStorage.Lucineer.Http (HTTP to memory worker)
        - ReplicatedStorage.Lucineer.CommandExecutor (for part recreation)
        - ReplicatedStorage.Lucineer.Config (for worker URL)

    Design doc: lucineer-system/SAVE_SYSTEM.md
]]

local Http = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("Http"))
local CommandExecutor = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("CommandExecutor"))

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

-- Memory worker URL for save endpoints
local MEMORY_URL = "https://lucineer-memory.casey-digennaro.workers.dev"

-- ═══════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════

local AUTOSAVE_INTERVAL = 60       -- seconds between auto-save cycles
local LEGACY_TRANSPARENCY = 0.7    -- ghost build transparency
local LEGACY_MAX_PARTS = 50        -- max parts in a legacy build
local LEGACY_MAX_PER_SERVER = 3    -- max concurrent legacy builds
local SAVE_VERSION = 1             -- snapshot format version

-- ═══════════════════════════════════════════════════════════════════════════
-- IN-MEMORY STATE
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → { loaded = true, lastBuildSave = os.time(), inventory = {}, eraData = {}, bondLevel = 0 }
local playerSaveState = {}

-- Auto-save accumulator
local autosaveAccumulator = 0

-- Track loaded legacy builds for cleanup rotation
local legacyBuilds = {}  -- array of { playerName = string, folder = Instance, timestamp = number }

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get or create the LucineerBuilds folder in workspace.
    @return Folder
]]
local function ensureBuildsFolder(): Folder
    local folder = Workspace:FindFirstChild("LucineerBuilds")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "LucineerBuilds"
        folder.Parent = Workspace
    end
    return folder
end

--[[
    Get or create the LegacyBuilds folder in workspace.
    @return Folder
]]
local function ensureLegacyFolder(): Folder
    local folder = Workspace:FindFirstChild("LegacyBuilds")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "LegacyBuilds"
        folder.Parent = Workspace
    end
    return folder
end

--[[
    Encode a Lua value as JSON via the Http module.
    @param value any
    @return string
]]
local function jsonEncode(value: any): string
    return Http.encode(value)
end

--[[
    Decode a JSON string into a Lua table via the Http module.
    @param s string
    @return table?
]]
local function jsonDecode(s: string): table?
    local ok, result = pcall(Http.decode, s)
    if ok then return result end
    return nil
end

--[[
    Convert a Color3 to a hex string "#RRGGBB".
    @param color Color3
    @return string
]]
local function colorToHex(color: Color3): string
    return string.format("#%02X%02X%02X",
        math.floor(color.R * 255 + 0.5),
        math.floor(color.G * 255 + 0.5),
        math.floor(color.B * 255 + 0.5))
end

--[[
    Parse a hex color string into Color3.
    @param hex string -- "#RRGGBB" or "RRGGBB"
    @return Color3
]]
local function hexToColor(hex: string): Color3
    hex = hex:gsub("#", "")
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return Color3.fromRGB(r, g, b)
end

--[[
    Parse a material name into Enum.Material.
    @param mat string?
    @return Enum.Material
]]
local function parseMaterial(mat: string?): Enum.Material
    if not mat then return Enum.Material.SmoothPlastic end
    local ok, result = pcall(function()
        return Enum.Material[mat]
    end)
    return ok and result or Enum.Material.SmoothPlastic
end

--[[
    Parse a position/size table {x, y, z} into Vector3.
    @param t table
    @return Vector3
]]
local function parseVector3(t: table): Vector3
    return Vector3.new(t.x or t[1] or 0, t.y or t[2] or 0, t.z or t[3] or 0)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- R2 PERSISTENCE (via memory worker)
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Save data to R2 bucket via the memory worker.
    @param key string -- R2 object key (e.g. "saves/Player1/builds.json")
    @param data table -- data to store (will be JSON-encoded)
    @return boolean success
]]
local function saveToR2(key: string, data: table): boolean
    local response, err = Http.post(MEMORY_URL .. "/api/save/r2/" .. key, {
        key = key,
        data = jsonEncode(data),
    })

    if err then
        warn(string.format("[SaveSystem] R2 save failed for key '%s': %s", key, err))
        return false
    end

    return true
end

--[[
    Load data from R2 bucket via the memory worker.
    @param key string -- R2 object key
    @return table? -- decoded data, or nil if not found / error
]]
local function loadFromR2(key: string): table?
    local response, err = Http.get(MEMORY_URL .. "/api/save/r2/" .. key)

    if err then
        -- Non-fatal: could be first-time player with no saves
        return nil
    end

    if not response or not response.data then
        return nil
    end

    -- The worker returns data as a JSON string; decode it
    local decoded = jsonDecode(response.data)
    if typeof(decoded) == "string" then
        -- Double-encoded fallback: try once more
        decoded = jsonDecode(decoded)
    end
    return decoded
end

-- ═══════════════════════════════════════════════════════════════════════════
-- D1 PERSISTENCE (via memory worker)
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Save a small key-value pair to D1 via the memory worker.
    @param playerName string
    @param key string -- save key (e.g. "inventory", "era", "bond")
    @param value any -- value to store (will be JSON-encoded)
    @return boolean success
]]
local function saveToD1(playerName: string, key: string, value: any): boolean
    local dataStr = jsonEncode(value)
    local _, err = Http.post(MEMORY_URL .. "/api/save/d1/" .. playerName .. "/" .. key, {
        player_name = playerName,
        save_key = key,
        save_data = dataStr,
    })

    if err then
        warn(string.format("[SaveSystem] D1 save failed for %s/%s: %s", playerName, key, err))
        return false
    end

    return true
end

--[[
    Load a small key-value pair from D1 via the memory worker.
    @param playerName string
    @param key string
    @return any? -- decoded value, or nil if not found / error
]]
local function loadFromD1(playerName: string, key: string): any?
    local response, err = Http.get(MEMORY_URL .. "/api/save/d1/" .. playerName .. "/" .. key)

    if err or not response then
        return nil
    end

    local dataStr = response.save_data or response.data
    if not dataStr then return nil end

    local decoded = jsonDecode(dataStr)
    return decoded
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BUILD SERIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Serialize a single BasePart into a compact table for JSON storage.
    @param part BasePart
    @return table
]]
local function serializePart(part: BasePart): table
    local data = {
        name = part.Name,
        className = part.ClassName,
        position = {
            x = math.floor(part.Position.X * 100 + 0.5) / 100,
            y = math.floor(part.Position.Y * 100 + 0.5) / 100,
            z = math.floor(part.Position.Z * 100 + 0.5) / 100,
        },
        size = {
            x = math.floor(part.Size.X * 100 + 0.5) / 100,
            y = math.floor(part.Size.Y * 100 + 0.5) / 100,
            z = math.floor(part.Size.Z * 100 + 0.5) / 100,
        },
        material = tostring(part.Material),
        color = colorToHex(part.Color),
        transparency = part.Transparency,
        anchored = part.Anchored,
    }

    -- Shape (only for Part instances, not MeshPart/UnionOperation)
    if part:IsA("Part") then
        local ok, shapeName = pcall(function()
            return tostring(part.Shape.Name)
        end)
        if ok then
            data.shape = shapeName
        end
    end

    -- Rotation (CFrame angles) — saved as Euler degrees for compactness
    local rx, ry, rz = part.CFrame:ToEulerAnglesXYZ()
    data.rotation = {
        x = math.floor(math.deg(rx) * 100 + 0.5) / 100,
        y = math.floor(math.deg(ry) * 100 + 0.5) / 100,
        z = math.floor(math.deg(rz) * 100 + 0.5) / 100,
    }

    return data
end

--[[
    Serialize all builds in the LucineerBuilds folder.
    Scans for all BaseParts and collects their properties.
    @return table -- { version, timestamp, parts, lights, metadata }
]]
local function serializeBuilds(): table
    local folder = ensureBuildsFolder()
    local parts = {}
    local lights = {}

    for _, descendant in ipairs(folder:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local partData = serializePart(descendant)
            table.insert(parts, partData)

            -- Check for attached lights
            for _, child in ipairs(descendant:GetChildren()) do
                if child:IsA("Light") then
                    local lightData = {
                        name = child.Name,
                        lightType = child.ClassName,
                        parent = descendant.Name,
                        range = child.Range,
                        brightness = child.Brightness,
                        color = colorToHex(child.Color),
                    }
                    if child:IsA("SpotLight") then
                        lightData.angle = child.Angle
                    end
                    table.insert(lights, lightData)
                end
            end
        end
    end

    return {
        version = SAVE_VERSION,
        timestamp = os.time(),
        parts = parts,
        lights = lights,
        metadata = {
            partCount = #parts,
            lightCount = #lights,
        },
    }
end

--[[
    Deserialize a build snapshot and reconstruct all parts.
    Parts are created directly (not via CommandExecutor.executeBatch) for
    instant restore — no animation, no sound, just placement.

    @param data table -- the snapshot from serializeBuilds() / R2
    @return number -- count of parts restored
]]
local function deserializeBuilds(data: table): number
    if not data or not data.parts then
        return 0
    end

    local folder = ensureBuildsFolder()
    local restored = 0

    for _, partData in ipairs(data.parts) do
        local ok, err = pcall(function()
            local part = Instance.new("Part")
            part.Name = partData.name or "LucineerPart"
            part.Position = parseVector3(partData.position or { x = 0, y = 5, z = 0 })
            part.Size = parseVector3(partData.size or { x = 4, y = 1, z = 4 })
            part.Material = parseMaterial(partData.material)
            part.Color = hexToColor(partData.color or "#B4B4B4")
            part.Transparency = partData.transparency or 0
            part.Anchored = partData.anchored ~= false  -- default true

            -- Shape
            if partData.shape then
                local shapeOk = pcall(function()
                    part.Shape = Enum.PartType[partData.shape]
                end)
            end

            -- Rotation
            if partData.rotation then
                local rx = math.rad(partData.rotation.x or 0)
                local ry = math.rad(partData.rotation.y or 0)
                local rz = math.rad(partData.rotation.z or 0)
                part.CFrame = CFrame.new(part.Position)
                    * CFrame.fromEulerAnglesXYZ(rx, ry, rz)
            end

            part.Parent = folder
            restored = restored + 1
        end)

        if not ok then
            warn(string.format("[SaveSystem] Failed to restore part '%s': %s",
                partData.name or "?", tostring(err)))
        end
    end

    -- Restore lights
    if data.lights then
        for _, lightData in ipairs(data.lights) do
            pcall(function()
                -- Find the parent part by name
                local parentPart = folder:FindFirstChild(lightData.parent, true)
                if not parentPart then return end

                local lightType = lightData.lightType or "PointLight"
                lightType = lightType:gsub("Light$", "")
                local light
                if lightType == "Spot" then
                    light = Instance.new("SpotLight")
                elseif lightType == "Surface" then
                    light = Instance.new("SurfaceLight")
                else
                    light = Instance.new("PointLight")
                end

                light.Name = lightData.name or "LucineerLight"
                light.Range = lightData.range or 16
                light.Brightness = lightData.brightness or 2
                light.Color = hexToColor(lightData.color or "#FFFFFF")
                if lightType == "Spot" and lightData.angle then
                    light.Angle = lightData.angle
                end
                light.Parent = parentPart
            end)
        end
    end

    print(string.format("[SaveSystem] Restored %d parts from snapshot", restored))
    return restored
end

-- ═══════════════════════════════════════════════════════════════════════════
-- LEGACY BUILDS
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Score a part group for "impressiveness" to select the legacy build.
    Factors: part count, material diversity, bounding box size.
    @param parts {BasePart} -- array of parts
    @return number -- score (higher = more impressive)
]]
local function scoreBuild(parts: { BasePart }): number
    if #parts == 0 then return 0 end

    local materialSet = {}
    local minPos = Vector3.new(math.huge, math.huge, math.huge)
    local maxPos = Vector3.new(-math.huge, -math.huge, -math.huge)

    for _, part in ipairs(parts) do
        materialSet[tostring(part.Material)] = true
        minPos = Vector3.new(
            math.min(minPos.X, part.Position.X),
            math.min(minPos.Y, part.Position.Y),
            math.min(minPos.Z, part.Position.Z)
        )
        maxPos = Vector3.new(
            math.max(maxPos.X, part.Position.X),
            math.max(maxPos.Y, part.Position.Y),
            math.max(maxPos.Z, part.Position.Z)
        )
    end

    local materialCount = 0
    for _ in pairs(materialSet) do
        materialCount = materialCount + 1
    end

    local footprint = (maxPos - minPos).Magnitude

    -- Weighted score: parts (10pts each) + materials (5pts each) + footprint (0.1/1000 studs)
    return (#parts * 10) + (materialCount * 5) + (footprint * 0.1)
end

--[[
    Create a legacy (ghost) build when a player leaves.
    Selects the most impressive contiguous build group and clones it
    as a semi-transparent, non-collidable ghost in the LegacyBuilds folder.

    @param playerName string
]]
local function createLegacyBuild(playerName: string)
    local folder = ensureBuildsFolder()

    -- Collect all parts in LucineerBuilds
    local allParts = {}
    for _, descendant in ipairs(folder:GetDescendants()) do
        if descendant:IsA("BasePart") then
            table.insert(allParts, descendant)
        end
    end

    if #allParts == 0 then
        return  -- nothing to ghost
    end

    -- Score the build as a whole (single group for now)
    local score = scoreBuild(allParts)
    if score < 20 then
        -- Not impressive enough to leave a ghost
        return
    end

    -- Enforce concurrent legacy build limit
    while #legacyBuilds >= LEGACY_MAX_PER_SERVER do
        local oldest = table.remove(legacyBuilds, 1)
        if oldest.folder then
            oldest.folder:Destroy()
        end
    end

    -- Create the ghost
    local legacyFolder = ensureLegacyFolder()
    local ghostFolder = Instance.new("Folder")
    ghostFolder.Name = playerName .. "_Legacy"
    ghostFolder:SetAttribute("LegacyOwner", playerName)
    ghostFolder:SetAttribute("LegacyTime", os.time())
    ghostFolder.Parent = legacyFolder

    local cloned = 0
    for _, part in ipairs(allParts) do
        if cloned >= LEGACY_MAX_PARTS then
            break
        end

        local ok = pcall(function()
            local clone = part:Clone()
            clone.Transparency = math.max(part.Transparency, LEGACY_TRANSPARENCY)
            clone.CanCollide = false
            clone.CanTouch = false
            clone.Anchored = true
            clone:SetAttribute("IsLegacy", true)
            clone:SetAttribute("LegacyOwner", playerName)

            -- Remove any scripts from the clone (no behavior, just visual)
            for _, script in ipairs(clone:GetDescendants()) do
                if script:IsA("Script") or script:IsA("LocalScript") then
                    script:Destroy()
                end
            end

            clone.Parent = ghostFolder
            cloned = cloned + 1
        end)

        if not ok then
            warn(string.format("[SaveSystem] Failed to clone legacy part for %s", playerName))
        end
    end

    -- Persist legacy build metadata to R2
    pcall(function()
        saveToR2("saves/" .. playerName .. "/legacy.json", {
            version = SAVE_VERSION,
            playerName = playerName,
            timestamp = os.time(),
            partCount = cloned,
            score = score,
        })
    end)

    -- Track for cleanup
    table.insert(legacyBuilds, {
        playerName = playerName,
        folder = ghostFolder,
        timestamp = os.time(),
    })

    print(string.format("[SaveSystem] Created legacy build for %s (%d parts, score %.1f)",
        playerName, cloned, score))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FULL SAVE / LOAD
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Save a player's complete state.
    - Builds → R2 snapshot
    - Inventory, era, bond → D1 rows
    - Last save metadata → D1 row

    @param playerName string
    @return boolean success
]]
local function savePlayer(playerName: string): boolean
    local state = playerSaveState[playerName]
    if not state then
        -- Player not loaded; nothing to save
        return false
    end

    local success = true

    -- Save build snapshot to R2
    local buildSnapshot = serializeBuilds()
    if buildSnapshot.metadata.partCount > 0 then
        local r2Ok = saveToR2("saves/" .. playerName .. "/builds.json", buildSnapshot)
        if not r2Ok then success = false end
    end

    -- Save inventory to D1
    if state.inventory then
        local invOk = saveToD1(playerName, "inventory", state.inventory)
        if not invOk then success = false end
    end

    -- Save era data to D1
    if state.eraData then
        local eraOk = saveToD1(playerName, "era", state.eraData)
        if not eraOk then success = false end
    end

    -- Save bond level to D1
    if state.bondLevel then
        local bondOk = saveToD1(playerName, "bond", { level = state.bondLevel })
        if not bondOk then success = false end
    end

    -- Save metadata
    saveToD1(playerName, "lastSave", {
        timestamp = os.time(),
        buildSnapshotR2 = "saves/" .. playerName .. "/builds.json",
    })

    state.lastBuildSave = os.time()

    if success then
        print(string.format("[SaveSystem] Full save complete for %s (%d parts)",
            playerName, buildSnapshot.metadata.partCount))
    end

    return success
end

--[[
    Save only the build state (called after build completion).
    @param playerName string
    @return boolean success
]]
local function saveBuilds(playerName: string): boolean
    local state = playerSaveState[playerName]
    if not state then return false end

    -- Debounce: skip if saved within last 5 seconds
    local now = os.time()
    if state.lastBuildSave and (now - state.lastBuildSave) < 5 then
        return true
    end

    local snapshot = serializeBuilds()
    if snapshot.metadata.partCount > 0 then
        local ok = saveToR2("saves/" .. playerName .. "/builds.json", snapshot)
        if ok then
            state.lastBuildSave = now
            print(string.format("[SaveSystem] Build snapshot saved for %s (%d parts)",
                playerName, snapshot.metadata.partCount))
        end
        return ok
    end

    return true  -- empty builds = success (nothing to save)
end

--[[
    Load a player's saved state.
    - Fetch D1 profile (inventory, era, bond)
    - Fetch R2 build snapshot
    - Deserialize builds into the workspace

    This is async — call in a task.spawn.

    @param playerName string
    @return table? -- loaded state, or nil on total failure
]]
local function loadPlayer(playerName: string): table?
    -- Initialize state with defaults
    local state = {
        loaded = true,
        lastBuildSave = 0,
        inventory = {},
        eraData = { currentEra = 0, unlockedEras = { 0 }, eraXP = {} },
        bondLevel = 0,
    }

    -- Load from D1 (small data)
    local inventory = loadFromD1(playerName, "inventory")
    if inventory then
        state.inventory = inventory
    end

    local eraData = loadFromD1(playerName, "era")
    if eraData then
        state.eraData = eraData
    end

    local bondData = loadFromD1(playerName, "bond")
    if bondData and type(bondData) == "table" and bondData.level then
        state.bondLevel = bondData.level
    elseif bondData and type(bondData) == "number" then
        state.bondLevel = bondData
    end

    -- Cache in memory
    playerSaveState[playerName] = state

    -- Load build snapshot from R2 (async, non-blocking)
    task.spawn(function()
        local buildSnapshot = loadFromR2("saves/" .. playerName .. "/builds.json")
        if buildSnapshot and buildSnapshot.parts then
            local restored = deserializeBuilds(buildSnapshot)
            print(string.format("[SaveSystem] Loaded %d parts for %s from R2", restored, playerName))
        else
            print(string.format("[SaveSystem] No build snapshot for %s (new player or first session)", playerName))
        end
    end)

    print(string.format("[SaveSystem] Profile loaded for %s (era %d, bond %d)",
        playerName, state.eraData.currentEra or 0, state.bondLevel))

    return state
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AUTO-SAVE LOOP
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Save all connected players. Called by the auto-save heartbeat.
]]
local function saveAll()
    local players = Players:GetPlayers()
    if #players == 0 then return end

    for _, player in ipairs(players) do
        task.spawn(function()
            savePlayer(player.Name)
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

SaveSystem = {}

--[[
    Initialize the SaveSystem.
    Wires PlayerAdded/PlayerRemoving events and starts the auto-save loop.
    Must be called once during server bootstrap.
]]
function SaveSystem.init()
    -- Load saves for players when they join
    Players.PlayerAdded:Connect(function(player)
        task.spawn(function()
            loadPlayer(player.Name)
        end)
    end)

    -- Save + create legacy build when players leave
    Players.PlayerRemoving:Connect(function(player)
        -- Full save (sync — player is still in workspace)
        savePlayer(player.Name)

        -- Create ghost build
        createLegacyBuild(player.Name)

        -- Clear in-memory state
        playerSaveState[player.Name] = nil

        print(string.format("[SaveSystem] Player %s removed, state cleared", player.Name))
    end)

    -- Auto-save heartbeat: save all players every AUTOSAVE_INTERVAL seconds
    RunService.Heartbeat:Connect(function(dt: number)
        autosaveAccumulator += dt
        if autosaveAccumulator >= AUTOSAVE_INTERVAL then
            autosaveAccumulator = 0
            saveAll()
        end
    end)

    print(string.format("[SaveSystem] Initialized — auto-save every %ds", AUTOSAVE_INTERVAL))
end

--[[
    Full save for a player. Saves builds to R2 and small data to D1.
    @param playerName string
    @return boolean success
]]
SaveSystem.savePlayer = savePlayer

--[[
    Save just the build state (fast path for after build completion).
    Debounced to max one save per 5 seconds per player.
    @param playerName string
    @return boolean success
]]
SaveSystem.saveBuilds = saveBuilds

--[[
    Load a player's saved state. Async-safe.
    @param playerName string
    @return table? -- { loaded, inventory, eraData, bondLevel, ... }
]]
SaveSystem.loadPlayer = loadPlayer

--[[
    Save large data to R2 bucket via memory worker.
    @param key string -- R2 object key
    @param data table -- data to save
    @return boolean success
]]
SaveSystem.saveToR2 = saveToR2

--[[
    Load large data from R2 bucket via memory worker.
    @param key string -- R2 object key
    @return table? -- decoded data
]]
SaveSystem.loadFromR2 = loadFromR2

--[[
    Save small data to D1 via memory worker.
    @param playerName string
    @param key string -- save key (e.g. "inventory")
    @param value any -- value to save
    @return boolean success
]]
SaveSystem.saveToD1 = saveToD1

--[[
    Load small data from D1 via memory worker.
    @param playerName string
    @param key string -- save key
    @return any? -- decoded value
]]
SaveSystem.loadFromD1 = loadFromD1

--[[
    Serialize all builds in LucineerBuilds folder into a JSON-ready table.
    Captures: name, position, size, material, color, transparency, shape, anchored, rotation.
    @return table -- { version, timestamp, parts, lights, metadata }
]]
SaveSystem.serializeBuilds = serializeBuilds

--[[
    Deserialize a build snapshot and reconstruct all parts in the workspace.
    Creates parts directly (no animation) for instant restore.
    @param data table -- snapshot from serializeBuilds() or R2
    @return number -- count of parts restored
]]
SaveSystem.deserializeBuilds = deserializeBuilds

--[[
    Create a legacy (ghost) build when a player leaves.
    Selects the most impressive build, clones it as semi-transparent
    and non-collidable into LegacyBuilds folder.
    @param playerName string
]]
SaveSystem.createLegacyBuild = createLegacyBuild

print("[SaveSystem] Module loaded — version " .. tostring(SAVE_VERSION))
return SaveSystem
