--[[
    Lucineer Command Executor
    Receives structured build commands from the AI and executes them in the workspace.
    Supports: createPart, createModel, deletePart, movePart, addLight, addSound,
              addScript (Studio-only), setTerrain, sendMessage

    GAP #9 Fixes:
      9a: runLua removed entirely — loadstring is unsafe and disabled by default.
      9b: addScript restricted to Studio-only with RunService:IsStudio() guard.
      9c: setTerrain uses FillBlock (CFrame-based) instead of deprecated FillRegion.
          Terrain materials validated against allowed set.
      9e: All `table` type annotations replaced with `{ [string]: any }`.

    GAP #10 Fix:
      10d: Maintains _partsCreated counter — increments on each createPart,
           updates WorldScanner cache. No more full-tree recount.

    INTEGRATION: BuildAnimator
    ───────────────────────────────────────────────
    Parts created by createPart are collected during executeBatch() and then
    passed to BuildAnimator.animateBatch() for staggered cinematic reveal:
    fade-in, scale-up with Back ease, particle bursts, and material-aware sounds.

    Individual execute() calls still animate via animatePart() for single commands.

    "Builds never pop — they arrive in work order."
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Terrain = game:GetService("Workspace").Terrain
local InsertService = game:GetService("InsertService")

local BuildAnimator = require(script.Parent.BuildAnimator)
local WorldScanner = require(script.Parent.WorldScanner)

local CommandExecutor = {}

-- GAP #10d: Build count counter — incremented on each createPart,
-- synced to WorldScanner cache so quickScan costs nothing.
CommandExecutor._partsCreated = 0

--[[
    Container folder for Lucineer-created instances, so we can track and manage them.
]]
local lucineerFolder: Folder? = nil

local function ensureFolder(): Folder
    if not lucineerFolder then
        lucineerFolder = workspace:FindFirstChild("LucineerBuilds")
        if not lucineerFolder then
            lucineerFolder = Instance.new("Folder")
            lucineerFolder.Name = "LucineerBuilds"
            lucineerFolder.Parent = workspace
        end
    end
    return lucineerFolder
end

--[[
    Helper: find a part by name in the workspace or LucineerBuilds folder.
    @param name string
    @return Instance?
]]
local function findPartByName(name: string): Instance?
    -- Check LucineerBuilds first
    local folder = ensureFolder()
    local part = folder:FindFirstChild(name)
    if part then return part end
    -- Fallback to whole workspace
    return workspace:FindFirstChild(name, true)
end

--[[
    Helper: parse a position table {x, y, z} into Vector3
    @param pos { [string]: any }
    @return Vector3
]]
local function parseVector3(pos: { [string]: any }): Vector3
    return Vector3.new(pos.x or pos[1] or 0, pos.y or pos[2] or 0, pos.z or pos[3] or 0)
end

--[[
    Helper: parse a color from hex string "#RRGGBB" or {r, g, b} (0-255)
    @param color any
    @return Color3
]]
local function parseColor(color: any): Color3
    if typeof(color) == "Color3" then return color end
    if type(color) == "string" then
        local hex = color:gsub("#", "")
        local r = tonumber(hex:sub(1, 2), 16) or 255
        local g = tonumber(hex:sub(3, 4), 16) or 255
        local b = tonumber(hex:sub(5, 6), 16) or 255
        return Color3.fromRGB(r, g, b)
    end
    if type(color) == "table" then
        return Color3.fromRGB(color[1] or color.r or 255, color[2] or color.g or 255, color[3] or color.b or 255)
    end
    return Color3.fromRGB(180, 180, 180)
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

-- GAP #9c: Allowed terrain materials for setTerrain validation.
local TERRAIN_MATERIALS = {
    Grass = true, Rock = true, Sand = true, Water = true, Snow = true,
    Mud = true, Slate = true, Ice = true, Ground = true, Asphalt = true,
    Basalt = true, CrackedLava = true, GlacialIce = true, LeafyGrass = true,
    Limestone = true, Marble = true, Pavement = true, Plaster = true,
    Salt = true, Sandstone = true, WoodPlanks = true,
}

----------------------------------------------------------------
-- BATCH TRACKING
----------------------------------------------------------------

-- During executeBatch(), created parts are accumulated here for deferred
-- animation. This allows BuildAnimator to stagger the reveal of all parts
-- as a cohesive cinematic sequence rather than each part animating independently.
local batchCreatedParts: { BasePart } = {}
local inBatchMode = false

----------------------------------------------------------------
-- COMMAND IMPLEMENTATIONS
----------------------------------------------------------------

--[[
    createPart: Create a new BasePart in the workspace.
    Expects: { name, position, size, material, color, anchored, transparency, shape }

    When called inside executeBatch(), the part is created in a pre-animation
    state (parented but invisible) and deferred to BuildAnimator.animateBatch().
    When called standalone via execute(), it animates immediately.

    GAP #10d: Increments _partsCreated and updates WorldScanner build count cache.
]]
function CommandExecutor.createPart(params: { [string]: any }): Instance
    local folder = ensureFolder()
    local part = Instance.new("Part")

    part.Name = params.name or "LucineerPart"

    -- Store the TARGET values — BuildAnimator will tween to these
    local targetPosition = parseVector3(params.position or { x = 0, y = 5, z = 0 })
    local targetSize = parseVector3(params.size or { x = 4, y = 1, z = 4 })
    local targetTransparency = params.transparency or 0

    part.Position = targetPosition
    part.Size = targetSize
    part.Material = parseMaterial(params.material)
    part.Color = parseColor(params.color)
    part.Anchored = if params.anchored ~= nil then params.anchored else true
    part.Transparency = targetTransparency

    if params.shape then
        local ok = pcall(function()
            part.Shape = Enum.PartType[params.shape]
        end)
    end

    -- Pre-animation state: if we're in batch mode, make the part invisible
    -- and tiny so it's ready for BuildAnimator.animateBatch() to reveal it.
    if inBatchMode then
        part.Transparency = 1
        part.Size = Vector3.new(0.1, 0.1, 0.1)
    end

    part.Parent = folder

    -- GAP #10d: Track build count
    CommandExecutor._partsCreated += 1
    WorldScanner.setBuildCount(CommandExecutor._partsCreated)

    -- Track for batch animation
    if inBatchMode then
        -- Store the target values on the part so BuildAnimator knows what to tween to.
        -- We use attributes since they persist with the instance and are type-safe.
        part:SetAttribute("BA_TargetSizeX", targetSize.X)
        part:SetAttribute("BA_TargetSizeY", targetSize.Y)
        part:SetAttribute("BA_TargetSizeZ", targetSize.Z)
        part:SetAttribute("BA_TargetTransparency", targetTransparency)
        table.insert(batchCreatedParts, part)
    end

    print(string.format("[Lucineer] CommandExecutor: created Part '%s' at %s", part.Name, tostring(targetPosition)))
    return part
end

--[[
    createModel: Create a simple grouped model from multiple parts.
    Expects: { name, parts = { {name, position, size, ...}, ... } }
]]
function CommandExecutor.createModel(params: { [string]: any }): Model
    local folder = ensureFolder()
    local model = Instance.new("Model")
    model.Name = params.name or "LucineerModel"
    model.Parent = folder

    for _, partData in ipairs(params.parts or {}) do
        partData.anchored = partData.anchored ~= false -- default anchored
        local part = CommandExecutor.createPart(partData)
        part.Parent = model
    end

    print(string.format("[Lucineer] CommandExecutor: created Model '%s' with %d parts", model.Name, #(params.parts or {})))
    return model
end

--[[
    deletePart: Remove a part by name.
    Expects: { name }
]]
function CommandExecutor.deletePart(params: { [string]: any }): boolean
    local part = findPartByName(params.name)
    if part then
        part:Destroy()
        -- GAP #10d: Decrement build count
        if CommandExecutor._partsCreated > 0 then
            CommandExecutor._partsCreated -= 1
            WorldScanner.setBuildCount(CommandExecutor._partsCreated)
        end
        print(string.format("[Lucineer] CommandExecutor: deleted '%s'", params.name))
        return true
    end
    warn(string.format("[Lucineer] CommandExecutor: deletePart — '%s' not found", params.name))
    return false
end

--[[
    movePart: Move a part to a new position.
    Expects: { name, position }
]]
function CommandExecutor.movePart(params: { [string]: any }): boolean
    local part = findPartByName(params.name)
    if part and part:IsA("BasePart") then
        part.Position = parseVector3(params.position)
        print(string.format("[Lucineer] CommandExecutor: moved '%s' to %s", params.name, tostring(part.Position)))
        return true
    end
    warn(string.format("[Lucineer] CommandExecutor: movePart — '%s' not found or not a Part", params.name))
    return false
end

--[[
    addLight: Add a light source to the workspace.
    Expects: { name, type ("Point"|"Spot"|"Surface"), position, range, brightness, color, parent }
]]
function CommandExecutor.addLight(params: { [string]: any }): Instance
    local folder = ensureFolder()

    -- Accept both "type" and "lightType" from generators
    local lightType = params.type or params.lightType or "Point"
    -- Strip "Light" suffix if present: "PointLight" -> "Point"
    lightType = lightType:gsub("Light$", "")

    local parent: Instance

    -- If a parent name is specified, find the existing part to attach the light to
    if params.parent then
        parent = findPartByName(params.parent) or folder
    elseif params.position then
        -- Create a carrier part if position is specified
        local carrier = Instance.new("Part")
        carrier.Name = (params.name or "Light") .. "Carrier"
        carrier.Size = Vector3.new(0.5, 0.5, 0.5)
        carrier.Position = parseVector3(params.position)
        carrier.Transparency = 1
        carrier.CanCollide = false
        carrier.Anchored = true
        carrier.Parent = folder
        parent = carrier
    else
        parent = folder
    end

    local light
    if lightType == "Spot" then
        light = Instance.new("SpotLight")
    elseif lightType == "Surface" then
        light = Instance.new("SurfaceLight")
    else
        light = Instance.new("PointLight")
    end

    light.Name = params.name or "LucineerLight"
    light.Range = params.range or 16
    light.Brightness = params.brightness or 2
    light.Color = parseColor(params.color or "#FFFFFF")
    light.Parent = parent

    print(string.format("[Lucineer] CommandExecutor: added %sLight '%s' (parent: %s)", lightType, light.Name, parent.Name))
    return light
end

--[[
    addSound: Add a Sound object to the workspace.
    Expects: { name, soundId, position, volume, looped, pitch }
]]
function CommandExecutor.addSound(params: { [string]: any }): Instance
    local folder = ensureFolder()
    local parent: Instance

    if params.position then
        local carrier = Instance.new("Part")
        carrier.Name = (params.name or "Sound") .. "Carrier"
        carrier.Size = Vector3.new(0.5, 0.5, 0.5)
        carrier.Position = parseVector3(params.position)
        carrier.Transparency = 1
        carrier.CanCollide = false
        carrier.Anchored = true
        carrier.Parent = folder
        parent = carrier
    else
        parent = folder
    end

    local sound = Instance.new("Sound")
    sound.Name = params.name or "LucineerSound"
    sound.SoundId = params.soundId or "rbxassetid://0"
    sound.Volume = params.volume or 0.5
    sound.PlaybackSpeed = params.pitch or 1
    sound.Looped = params.looped or false
    sound.Parent = parent

    if params.autoplay ~= false then
        sound:Play()
    end

    print(string.format("[Lucineer] CommandExecutor: added Sound '%s' (%s)", sound.Name, sound.SoundId))
    return sound
end

--[[
    GAP #9b: addScript — Studio-only.
    Script.Source is only assignable from plugins and the command bar (Studio).
    At runtime in a published game, this raises an error. Guard with RunService:IsStudio().
    Expects: { name, source, type ("Script"|"LocalScript"), parent }
]]
function CommandExecutor.addScript(params: { [string]: any }): Instance?
    -- GAP #9b: Script.Source is not assignable from runtime scripts.
    -- Only allow in Studio where plugins/command bar can write it.
    if not RunService:IsStudio() then
        warn("[Lucineer] CommandExecutor: addScript is Studio-only (Script.Source is not assignable at runtime)")
        return nil
    end

    local folder = ensureFolder()
    local scriptType = params.type or "Script"
    local scriptInstance

    if scriptType == "LocalScript" then
        scriptInstance = Instance.new("LocalScript")
    else
        scriptInstance = Instance.new("Script")
    end

    scriptInstance.Name = params.name or "LucineerScript"
    scriptInstance.Source = params.source or "print('[Lucineer] Script created')"
    scriptInstance.Parent = folder

    -- Try to find target parent by path
    if params.parent and params.parent ~= "workspace" and params.parent ~= "LucineerBuilds" then
        local target = workspace:FindFirstChild(params.parent, true)
        if target then
            scriptInstance.Parent = target
        end
    end

    print(string.format("[Lucineer] CommandExecutor: added %s '%s' (%d chars)", scriptType, scriptInstance.Name, #scriptInstance.Source))
    return scriptInstance
end

--[[
    GAP #9c: setTerrain — uses FillBlock instead of deprecated FillRegion.
    FillBlock takes a CFrame and Vector3 size, requiring no grid alignment.
    Terrain materials are validated against the allowed set.
    Expects: { position, size, material, action ("fill"|"clear") }
]]
function CommandExecutor.setTerrain(params: { [string]: any }): boolean
    local size = parseVector3(params.size or { x = 16, y = 1, z = 16 })
    local center = parseVector3(params.position or { x = 0, y = 0, z = 0 })

    local action = params.action or "fill"
    local matName = params.material or "Grass"

    local material: Enum.Material
    if action == "clear" then
        material = Enum.Material.Air
    else
        -- GAP #9c: Validate terrain materials against the allowed set
        if not TERRAIN_MATERIALS[matName] then
            warn(string.format("[Lucineer] setTerrain: '%s' is not a valid terrain material, defaulting to Grass", matName))
            matName = "Grass"
        end
        material = parseMaterial(matName)
    end

    -- GAP #9c: FillBlock (CFrame-based) replaces deprecated FillRegion.
    -- No grid alignment needed — CFrame handles positioning automatically.
    Terrain:FillBlock(CFrame.new(center), size, material)

    print(string.format("[Lucineer] CommandExecutor: %s terrain (%s) at %s, size %s",
        action, tostring(material), tostring(center), tostring(size)))
    return true
end

--[[
    sendMessage: Send a message to a player via UIManager.
    Expects: { message, targetPlayer? }
    Returns the message data so the caller (server) can route it to UIManager.
]]
function CommandExecutor.sendMessage(params: { [string]: any }): { [string]: any }
    local result: { [string]: any } = {
        type = "sendMessage",
        message = params.message or "",
        targetPlayer = params.targetPlayer,
    }
    print(string.format("[Lucineer] CommandExecutor: sendMessage — \"%s\"", result.message))
    return result
end

--[[
    GAP #9a: runLua REMOVED.
    loadstring requires ServerScriptService.LoadStringEnabled which is off by default
    and should stay off. Arbitrary server-side code execution from HTTP responses
    is unsafe. If dynamic behavior is needed, use a whitelist of parameterized
    behaviors instead of source strings.
]]

----------------------------------------------------------------
-- DISPATCHER
----------------------------------------------------------------

-- Command name → function mapping
-- GAP #9a: runLua removed from the command map.
local commandMap: { [string]: ({ [string]: any }) -> any } = {
    createPart = CommandExecutor.createPart,
    createModel = CommandExecutor.createModel,
    deletePart = CommandExecutor.deletePart,
    movePart = CommandExecutor.movePart,
    addLight = CommandExecutor.addLight,
    addSound = CommandExecutor.addSound,
    addScript = CommandExecutor.addScript,
    setTerrain = CommandExecutor.setTerrain,
    sendMessage = CommandExecutor.sendMessage,
}

--[[
    Execute a single command.
    @param command { [string]: any } -- { type, ...params }
    @return any -- result
    @return string? -- error
]]
function CommandExecutor.execute(command: { [string]: any }): (any, string?)
    if type(command) ~= "table" then
        return nil, "Command must be a table"
    end

    local cmdType = command.type
    if not cmdType then
        return nil, "Command missing 'type' field"
    end

    local handler = commandMap[cmdType]
    if not handler then
        return nil, string.format("Unknown command type: '%s'", cmdType)
    end

    -- Commands are envelopes: { type = "createPart", params = { ... } }.
    -- Accept a flat command as a fallback so hand-written test payloads still work.
    local params = command.params
    if type(params) ~= "table" then
        params = command
    end

    local ok, result = pcall(handler, params)
    if not ok then
        local err = tostring(result)
        warn(string.format("[Lucineer] CommandExecutor: '%s' failed: %s", cmdType, err))
        return nil, err
    end

    -- For standalone execute() calls that produce a single part,
    -- animate it immediately (not in batch mode).
    if not inBatchMode and result and typeof(result) == "Instance" and result:IsA("BasePart") then
        if not result:GetAttribute("BA_TargetSizeX") then
            -- Part was created outside batch mode — animate it directly.
            BuildAnimator.animatePart(result)
        end
    end

    return result, nil
end

--[[
    Execute a batch of commands sequentially.

    During batch execution, all created parts are collected and then passed
    to BuildAnimator.animateBatch() for staggered cinematic reveal:
    - Parts fade and scale in with Back/Quad easing
    - Staggered timing (0.08s between parts) simulates active construction
    - Each part emits a particle burst and material-aware sound on landing
    - The final part triggers a multi-colored completion burst

    @param commands { { [string]: any } } -- array of command tables
    @return { { [string]: any } } -- array of { success, result, error } per command
]]
function CommandExecutor.executeBatch(commands: { { [string]: any } }): { { [string]: any } }
    local results: { { [string]: any } } = {}

    -- Enter batch mode — created parts will be collected for deferred animation
    inBatchMode = true
    batchCreatedParts = {}

    for i, command in ipairs(commands) do
        local result, err = CommandExecutor.execute(command)
        table.insert(results, {
            index = i,
            type = command.type,
            success = err == nil,
            result = result,
            error = err,
        })
    end

    -- Exit batch mode
    inBatchMode = false

    -- If we collected parts during the batch, animate them with staggered timing
    if #batchCreatedParts > 0 then
        -- Compute the center position of all created parts for completion burst
        local sumVec = Vector3.new(0, 0, 0)
        for _, part in ipairs(batchCreatedParts) do
            sumVec = sumVec + part.Position
        end
        local centerPosition = sumVec / #batchCreatedParts

        -- Restore target sizes before animating (BuildAnimator.animateBatch reads part.Size as target)
        for _, part in ipairs(batchCreatedParts) do
            local tx = part:GetAttribute("BA_TargetSizeX")
            local ty = part:GetAttribute("BA_TargetSizeY")
            local tz = part:GetAttribute("BA_TargetSizeZ")
            local ttrans = part:GetAttribute("BA_TargetTransparency")

            if tx then
                local targetSize = Vector3.new(tx, ty, tz)
                part.Size = targetSize
                part.Transparency = ttrans or 0

                -- Clean up attributes
                part:RemoveAttribute("BA_TargetSizeX")
                part:RemoveAttribute("BA_TargetSizeY")
                part:RemoveAttribute("BA_TargetSizeZ")
                part:RemoveAttribute("BA_TargetTransparency")
            end
        end

        local partCount = #batchCreatedParts

        -- Now pass the full list to BuildAnimator for the staggered cinematic reveal
        BuildAnimator.animateBatch(batchCreatedParts, centerPosition)

        -- Clear the tracking list
        table.clear(batchCreatedParts)

        print(string.format("[Lucineer] CommandExecutor: animated batch of %d parts via BuildAnimator", partCount))
    end

    return results
end

return CommandExecutor
