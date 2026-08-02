--[[
    Lucineer Command Executor
    Receives structured build commands from the AI and executes them in the workspace.
    Supports: createPart, createModel, deletePart, movePart, addLight, addSound,
              addScript, setTerrain, sendMessage, runLua
]]

local Players = game:GetService("Players")
local Terrain = game:GetService("Workspace").Terrain
local InsertService = game:GetService("InsertService")

local CommandExecutor = {}

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
    @return BasePart?
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
    @param pos table
    @return Vector3
]]
local function parseVector3(pos: table): Vector3
    return Vector3.new(pos.x or pos[1] or 0, pos.y or pos[2] or 0, pos.z or pos[3] or 0)
end

--[[
    Helper: parse a color from hex string "#RRGGBB" or {r, g, b} (0-255)
    @param color string | table
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
    @param mat string
    @return Enum.Material
]]
local function parseMaterial(mat: string?): Enum.Material
    if not mat then return Enum.Material.SmoothPlastic end
    local ok, result = pcall(function()
        return Enum.Material[mat]
    end)
    return ok and result or Enum.Material.SmoothPlastic
end

----------------------------------------------------------------
-- COMMAND IMPLEMENTATIONS
----------------------------------------------------------------

--[[
    createPart: Create a new BasePart in the workspace.
    Expects: { name, position, size, material, color, anchored, transparency, shape }
]]
function CommandExecutor.createPart(params: table): Instance
    local folder = ensureFolder()
    local part = Instance.new("Part")

    part.Name = params.name or "LucineerPart"
    part.Position = parseVector3(params.position or { x = 0, y = 5, z = 0 })
    part.Size = parseVector3(params.size or { x = 4, y = 1, z = 4 })
    part.Material = parseMaterial(params.material)
    part.Color = parseColor(params.color)
    part.Anchored = if params.anchored ~= nil then params.anchored else true
    part.Transparency = params.transparency or 0

    if params.shape then
        local ok = pcall(function()
            part.Shape = Enum.PartType[params.shape]
        end)
    end

    part.Parent = folder
    print(string.format("[Lucineer] CommandExecutor: created Part '%s' at %s", part.Name, tostring(part.Position)))
    return part
end

--[[
    createModel: Create a simple grouped model from multiple parts.
    Expects: { name, parts = { {name, position, size, ...}, ... } }
]]
function CommandExecutor.createModel(params: table): Model
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
function CommandExecutor.deletePart(params: table): boolean
    local part = findPartByName(params.name)
    if part then
        part:Destroy()
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
function CommandExecutor.movePart(params: table): boolean
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
    Expects: { name, type ("Point"|"Spot"|"Surface"), position, range, brightness, color }
]]
function CommandExecutor.addLight(params: table): Instance
    local folder = ensureFolder()
    local lightType = params.type or "Point"
    local parent: Instance

    -- Create a carrier part if position is specified
    if params.position then
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

    print(string.format("[Lucineer] CommandExecutor: added %sLight '%s'", lightType, light.Name))
    return light
end

--[[
    addSound: Add a Sound object to the workspace.
    Expects: { name, soundId, position, volume, looped, pitch }
]]
function CommandExecutor.addSound(params: table): Instance
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
    addScript: Add a Script or LocalScript to the workspace.
    Expects: { name, source, type ("Script"|"LocalScript"), parent (path string or "workspace") }
]]
function CommandExecutor.addScript(params: table): Instance
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
    setTerrain: Modify terrain cells.
    Expects: { position, size, material ("Water"|"Grass"|"Rock"|etc.), action ("fill"|"clear") }
]]
function CommandExecutor.setTerrain(params: table): boolean
    local regionSize = parseVector3(params.size or { x = 16, y = 1, z = 16 })
    local center = parseVector3(params.position or { x = 0, y = 0, z = 0 })

    local regionStart = center - regionSize / 2
    local regionEnd = center + regionSize / 2

    local region = Region3.new(regionStart, regionEnd)
    local resolution = 4 -- terrain cell size

    local action = params.action or "fill"
    local material = parseMaterial(params.material or "Grass")

    if action == "clear" then
        Terrain:FillRegion(region, resolution, Enum.Material.Air)
        print(string.format("[Lucineer] CommandExecutor: cleared terrain at %s", tostring(center)))
    else
        Terrain:FillRegion(region, resolution, material)
        print(string.format("[Lucineer] CommandExecutor: filled terrain (%s) at %s, size %s",
            tostring(material), tostring(center), tostring(regionSize)))
    end

    return true
end

--[[
    sendMessage: Send a message to a player via UIManager.
    Expects: { message, targetPlayer? }
    Returns the message data so the caller (server) can route it to UIManager.
]]
function CommandExecutor.sendMessage(params: table): table
    local result = {
        type = "sendMessage",
        message = params.message or "",
        targetPlayer = params.targetPlayer,
    }
    print(string.format("[Lucineer] CommandExecutor: sendMessage — \"%s\"", result.message))
    return result
end

--[[
    runLua: Execute arbitrary Lua source on the server.
    SECURITY: This should be gated behind auth. Only Lucineer AI commands trigger it.
    Expects: { source }
    @return any -- result of the executed code
]]
function CommandExecutor.runLua(params: table): any
    local source = params.source or ""
    if #source == 0 then
        warn("[Lucineer] CommandExecutor: runLua — empty source")
        return nil
    end

    print(string.format("[Lucineer] CommandExecutor: runLua (%d chars)", #source))

    local fn, err = loadstring(source)
    if not fn then
        warn(string.format("[Lucineer] CommandExecutor: runLua compile error: %s", err))
        return nil, err
    end

    local ok, result = pcall(fn)
    if not ok then
        warn(string.format("[Lucineer] CommandExecutor: runLua runtime error: %s", tostring(result)))
        return nil, tostring(result)
    end

    return result
end

----------------------------------------------------------------
-- DISPATCHER
----------------------------------------------------------------

-- Command name → function mapping
local commandMap: { [string]: (table) -> any } = {
    createPart = CommandExecutor.createPart,
    createModel = CommandExecutor.createModel,
    deletePart = CommandExecutor.deletePart,
    movePart = CommandExecutor.movePart,
    addLight = CommandExecutor.addLight,
    addSound = CommandExecutor.addSound,
    addScript = CommandExecutor.addScript,
    setTerrain = CommandExecutor.setTerrain,
    sendMessage = CommandExecutor.sendMessage,
    runLua = CommandExecutor.runLua,
}

--[[
    Execute a single command.
    @param command table -- { type, ...params }
    @return any -- result
    @return string? -- error
]]
function CommandExecutor.execute(command: table): (any, string?)
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

    local ok, result = pcall(handler, command)
    if not ok then
        local err = tostring(result)
        warn(string.format("[Lucineer] CommandExecutor: '%s' failed: %s", cmdType, err))
        return nil, err
    end

    return result, nil
end

--[[
    Execute a batch of commands sequentially.
    @param commands { table } -- array of command tables
    @return { table } -- array of { success, result, error } per command
]]
function CommandExecutor.executeBatch(commands: { table }): { table }
    local results = {}
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
    return results
end

return CommandExecutor
