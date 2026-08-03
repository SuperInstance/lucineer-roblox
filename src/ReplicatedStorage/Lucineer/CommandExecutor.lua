--[[
    Lucineer Command Executor
    Receives structured build commands from the AI and executes them in the workspace.
    Supports: createPart, createWedge, createCylinder, createSphere, createModel,
              createSurface, createGroup, deletePart, movePart, addLight, addSound,
              addParticle, addScript (Studio-only), setTerrain, sendMessage,
              markUnfinished

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
local CollectionService = game:GetService("CollectionService")
local Terrain = game:GetService("Workspace").Terrain
local InsertService = game:GetService("InsertService")

local BuildAnimator = require(script.Parent.BuildAnimator)
local WorldScanner = require(script.Parent.WorldScanner)
local BeatClock = require(script.Parent.BeatClock)
local VoiceLines = require(script.Parent.VoiceLines)

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
    Helper: apply common BasePart properties and batch-animation tracking.
    Used by createPart, createWedge, createCylinder, createSphere.
    The caller is responsible for parenting the returned part.

    GAP #10d: Increments _partsCreated and updates WorldScanner build count cache.
]]
local function prepareBasePart(part: BasePart, params: { [string]: any }): BasePart
    part.Name = params.name or "LucineerPart"

    -- Store the TARGET values — BuildAnimator will tween to these
    local targetPosition = parseVector3(params.position or { x = 0, y = 5, z = 0 })
    local targetSize = parseVector3(params.size or { x = 4, y = 1, z = 4 })
    local targetTransparency = params.transparency or 0

    part.Size = targetSize
    part.Material = parseMaterial(params.material)
    part.Color = parseColor(params.color)
    part.Anchored = if params.anchored ~= nil then params.anchored else true
    part.Transparency = targetTransparency

    -- SPATIAL: apply rotation and optional physics flags from generator.
    -- Rotation is in degrees {x, y, z} and pivots around the part's position.
    local rotation = params.rotation
    if type(rotation) == "table" then
        part.CFrame = CFrame.new(targetPosition)
            * CFrame.Angles(
                math.rad(rotation.x or rotation[1] or 0),
                math.rad(rotation.y or rotation[2] or 0),
                math.rad(rotation.z or rotation[3] or 0)
            )
    else
        part.Position = targetPosition
    end

    if params.canCollide ~= nil then
        part.CanCollide = params.canCollide
    end
    if params.reflectance ~= nil then
        part.Reflectance = params.reflectance
    end

    -- Pre-animation state: if we're in batch mode, make the part invisible
    -- and tiny so it's ready for BuildAnimator.animateBatch() to reveal it.
    if inBatchMode then
        part.Transparency = 1
        part.Size = Vector3.new(0.1, 0.1, 0.1)
    end

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

    return part
end

--[[
    createPart: Create a new BasePart in the workspace.
    Expects: { name, position, size, material, color, anchored, transparency, shape }

    When called inside executeBatch(), the part is created in a pre-animation
    state (parented but invisible) and deferred to BuildAnimator.animateBatch().
    When called standalone via execute(), it animates immediately.
]]
function CommandExecutor.createPart(params: { [string]: any }): Instance
    local folder = ensureFolder()
    local part = Instance.new("Part")

    prepareBasePart(part, params)

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
    createWedge: Create a WedgePart for ramps, roofs, and door wedges.
    Expects: { name, position, size, material, color, anchored, transparency, rotation }
]]
function CommandExecutor.createWedge(params: { [string]: any }): Instance
    local folder = ensureFolder()
    local part = Instance.new("WedgePart")

    prepareBasePart(part, params)
    part.Parent = folder

    print(string.format("[Lucineer] CommandExecutor: created Wedge '%s' at %s", part.Name, tostring(part.Position)))
    return part
end

--[[
    createCylinder: Create a cylinder-shaped part for columns and pipes.
    Expects: { name, position, size, material, color, anchored, transparency, rotation }
]]
function CommandExecutor.createCylinder(params: { [string]: any }): Instance
    local folder = ensureFolder()
    local part = Instance.new("Part")

    local ok = pcall(function()
        part.Shape = Enum.PartType.Cylinder
    end)

    prepareBasePart(part, params)
    part.Parent = folder

    print(string.format("[Lucineer] CommandExecutor: created Cylinder '%s' at %s", part.Name, tostring(part.Position)))
    return part
end

--[[
    createSphere: Create a sphere-shaped part for decorative elements.
    Expects: { name, position, size, material, color, anchored, transparency, rotation }
]]
function CommandExecutor.createSphere(params: { [string]: any }): Instance
    local folder = ensureFolder()
    local part = Instance.new("Part")

    local ok = pcall(function()
        part.Shape = Enum.PartType.Ball
    end)

    prepareBasePart(part, params)
    part.Parent = folder

    print(string.format("[Lucineer] CommandExecutor: created Sphere '%s' at %s", part.Name, tostring(part.Position)))
    return part
end

--[[
    createSurface: Apply a material/color/texture change to an existing part.
    Expects: { name, material, color, transparency, texture, face }
      - texture: optional rbxassetid://... string; adds a Decal on the given face
      - face:    optional face name (Front, Back, Top, Bottom, Left, Right)
]]
function CommandExecutor.createSurface(params: { [string]: any }): Instance?
    local part = findPartByName(params.name)
    if not part or not part:IsA("BasePart") then
        warn(string.format("[Lucineer] CommandExecutor: createSurface — '%s' not found or not a Part", tostring(params.name)))
        return nil
    end

    if params.material then
        part.Material = parseMaterial(params.material)
    end
    if params.color then
        part.Color = parseColor(params.color)
    end
    if params.transparency ~= nil then
        part.Transparency = params.transparency
    end

    if params.texture then
        local face = params.face or "Front"
        local normalId = Enum.NormalId[face] or Enum.NormalId.Front
        local decal = Instance.new("Decal")
        decal.Name = params.decalName or "LucineerSurfaceDecal"
        decal.Texture = params.texture
        decal.Face = normalId
        decal.Color3 = if params.decalColor then parseColor(params.decalColor) else Color3.new(1, 1, 1)
        decal.Transparency = params.decalTransparency or 0
        decal.Parent = part
    end

    print(string.format("[Lucineer] CommandExecutor: applied surface to '%s'", part.Name))
    return part
end

--[[
    createGroup: Parent multiple existing parts under a Model for organization.
    Expects: { name, partNames = { "PartA", "PartB", ... } }
]]
function CommandExecutor.createGroup(params: { [string]: any }): Model
    local folder = ensureFolder()
    local model = Instance.new("Model")
    model.Name = params.name or "LucineerGroup"
    model.Parent = folder

    for _, partName in ipairs(params.partNames or {}) do
        local part = findPartByName(partName)
        if part then
            part.Parent = model
        else
            warn(string.format("[Lucineer] CommandExecutor: createGroup — part '%s' not found", tostring(partName)))
        end
    end

    -- Set a PrimaryPart for the group if any part exists inside it.
    local primary = model:FindFirstChildWhichIsA("BasePart")
    if primary then
        model.PrimaryPart = primary
    end

    print(string.format("[Lucineer] CommandExecutor: created Group '%s' with %d children", model.Name, #model:GetChildren()))
    return model
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
    addParticle: Attach a particle system to a named part.
    Expects: { parent, texture, rate, lifetime {min, max}, speed {min, max},
               color, size {min, max}, transparency, velocity {x, y, z} }

    The templates use this for smoke, embers, fog, water spray, butterflies,
    and magical sparkles. Without this handler those effects silently vanish.
]]
function CommandExecutor.addParticle(params: { [string]: any }): Instance?
    local parentName = params.parent
    if not parentName then
        warn("[Lucineer] CommandExecutor: addParticle missing 'parent'")
        return nil
    end

    local parent = findPartByName(parentName)
    if not parent then
        warn(string.format("[Lucineer] CommandExecutor: addParticle — parent '%s' not found", parentName))
        return nil
    end

    -- Resolve to a BasePart we can attach to
    local attachParent: BasePart
    if parent:IsA("BasePart") then
        attachParent = parent
    elseif parent:IsA("Light") and parent.Parent and parent.Parent:IsA("BasePart") then
        attachParent = parent.Parent
    elseif parent:IsA("Model") then
        attachParent = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart") :: BasePart
    end

    if not attachParent then
        warn(string.format("[Lucineer] CommandExecutor: addParticle — cannot attach to '%s'", parentName))
        return nil
    end

    local lifetime = params.lifetime or { min = 1, max = 2 }
    local speed = params.speed or { min = 1, max = 2 }
    local size = params.size or { min = 0.5, max = 1 }
    local transparency = params.transparency or 0.3

    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = params.name or "LucineerParticles"
    emitter.Texture = params.texture or "rbxasset://textures/particles/sparkles_main.dds"
    emitter.Rate = params.rate or 10
    emitter.Lifetime = NumberRange.new(lifetime.min or 1, lifetime.max or 2)
    emitter.Speed = NumberRange.new(speed.min or 1, speed.max or 2)
    emitter.Size = NumberSequence.new(size.min or 0.5, size.max or 1)
    emitter.Color = ColorSequence.new(parseColor(params.color or "#FFFFFF"))
    emitter.Transparency = NumberSequence.new(transparency, transparency)
    emitter.SpreadAngle = Vector2.new(10, 10)

    -- Optional velocity direction: use magnitude to bias speed upward-ish
    local velocity = params.velocity
    if type(velocity) == "table" then
        local v = Vector3.new(velocity.x or 0, velocity.y or 0, velocity.z or 0)
        local mag = v.Magnitude
        if mag > 0 then
            emitter.Speed = NumberRange.new(mag * 0.8, mag * 1.2)
            -- Point the attachment so the emission favors the velocity direction
            local attachment = Instance.new("Attachment")
            attachment.Name = "ParticleAttachment"
            attachment.CFrame = CFrame.lookAt(Vector3.zero, v)
            attachment.Parent = attachParent
            emitter.Parent = attachment
            print(string.format("[Lucineer] CommandExecutor: added ParticleEmitter '%s' to '%s' (velocity-driven)", emitter.Name, parentName))
            return emitter
        end
    end

    local attachment = Instance.new("Attachment")
    attachment.Name = "ParticleAttachment"
    attachment.Parent = attachParent
    emitter.Parent = attachment

    print(string.format("[Lucineer] CommandExecutor: added ParticleEmitter '%s' to '%s'", emitter.Name, parentName))
    return emitter
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
    markUnfinished: pick one part from a build and mark it as a deliberate gap.
    Expects: { partName?, partsList? }
      - partName:   optional specific part to mark
      - partsList:  optional array of BaseParts to choose from (defaults to all
                    BaseParts under LucineerBuilds)

    Sets Transparency = 0.5, tags the part with CollectionService tag
    "LucineerUnfinished", and sets attribute Lucineer_Unfinished = true.
    Returns a sendMessage-style result so Lucineer can say what's left undone.

    CHARACTER_BIBLE §6: every build should leave one deliberate gap.
]]
function CommandExecutor.markUnfinished(params: { [string]: any }): { [string]: any }?
    VoiceLines.init()

    local candidates: { BasePart } = {}
    if params.partName then
        local part = findPartByName(params.partName)
        if part and part:IsA("BasePart") then
            table.insert(candidates, part)
        end
    elseif type(params.partsList) == "table" and #params.partsList > 0 then
        for _, p in ipairs(params.partsList) do
            if typeof(p) == "Instance" and p:IsA("BasePart") then
                table.insert(candidates, p)
            end
        end
    else
        local folder = ensureFolder()
        for _, child in ipairs(folder:GetDescendants()) do
            if child:IsA("BasePart") then
                table.insert(candidates, child)
            end
        end
    end

    if #candidates == 0 then
        warn("[Lucineer] CommandExecutor: markUnfinished — no build parts found")
        return nil
    end

    -- Pick a deliberate gap. Prefer a part that isn't already marked.
    local part: BasePart
    local unmarked: { BasePart } = {}
    for _, p in ipairs(candidates) do
        if not p:GetAttribute("Lucineer_Unfinished") then
            table.insert(unmarked, p)
        end
    end
    if #unmarked > 0 then
        part = unmarked[math.random(1, #unmarked)]
    else
        part = candidates[math.random(1, #candidates)]
    end

    -- Mark the part with both an attribute and a CollectionService tag so other
    -- systems can query the deliberate gap.
    part:SetAttribute("Lucineer_Unfinished", true)
    part:SetAttribute("Lucineer_OriginalTransparency", part.Transparency)
    CollectionService:AddTag(part, "LucineerUnfinished")

    -- Make the unfinished part semi-transparent and add a SelectionBox highlight
    -- so the player can clearly see which piece is left for them.
    part.Transparency = 0.5

    local highlight = Instance.new("SelectionBox")
    highlight.Name = "LucineerUnfinishedHighlight"
    highlight.Color3 = Color3.fromRGB(255, 180, 60)
    highlight.LineThickness = 0.05
    highlight.Adornee = part
    highlight.Parent = part

    -- Optional particle shimmer to draw the eye
    local attachment = Instance.new("Attachment")
    attachment.Name = "UnfinishedAttachment"
    attachment.Position = Vector3.new(0, 0, 0)
    attachment.Parent = part

    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = "LucineerUnfinishedParticles"
    emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    emitter.Rate = 8
    emitter.Lifetime = NumberRange.new(1, 2)
    emitter.Speed = NumberRange.new(0.2, 0.6)
    emitter.Size = NumberSequence.new(0.3, 0.8)
    emitter.Color = ColorSequence.new(Color3.fromRGB(255, 180, 60))
    emitter.Transparency = NumberSequence.new(0.3, 0.7)
    emitter.Parent = attachment

    local line = VoiceLines.get("BRAIN_REPLY") or "One piece still waits."
    local message = string.format("%s — %s is left undone.", line, part.Name)

    print(string.format("[Lucineer] CommandExecutor: markUnfinished — '%s' left as deliberate gap", part.Name))
    return CommandExecutor.sendMessage({ message = message })
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
    createWedge = CommandExecutor.createWedge,
    createCylinder = CommandExecutor.createCylinder,
    createSphere = CommandExecutor.createSphere,
    createModel = CommandExecutor.createModel,
    createSurface = CommandExecutor.createSurface,
    createGroup = CommandExecutor.createGroup,
    deletePart = CommandExecutor.deletePart,
    movePart = CommandExecutor.movePart,
    addLight = CommandExecutor.addLight,
    addSound = CommandExecutor.addSound,
    addParticle = CommandExecutor.addParticle,
    addScript = CommandExecutor.addScript,
    setTerrain = CommandExecutor.setTerrain,
    sendMessage = CommandExecutor.sendMessage,
    markUnfinished = CommandExecutor.markUnfinished,
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

    GAP #8b: Staggered placement — creation is throttled to one musical
    32nd-note every 3 parts so builds stream in rather than popping.
    BuildAnimator handles the actual reveal curve (drop + bounce, spatial
    ordering, and BeatClock-derived stagger).

    @param commands { { [string]: any } } -- array of command tables
    @param onProgress ((current: number, total: number, result: any) -> ())? -- optional progress callback
    @return { { [string]: any } } -- array of { success, result, error } per command
]]
function CommandExecutor.executeBatch(commands: { { [string]: any } }, onProgress: ((number, number, any) -> ())?, style: string?): { { [string]: any } }
    local results: { { [string]: any } } = {}

    -- Enter batch mode — created parts will be collected for deferred animation
    inBatchMode = true
    batchCreatedParts = {}

    local createStagger = math.max(0.03, BeatClock.get32ndNoteDuration())

    for i, command in ipairs(commands) do
        local result, err = CommandExecutor.execute(command)
        table.insert(results, {
            index = i,
            type = command.type,
            success = err == nil,
            result = result,
            error = err,
        })
        -- Notify progress callback if provided
        if onProgress then
            task.spawn(onProgress, i, #commands, result)
        end
        -- Throttle creation slightly every 3 parts to keep the main thread
        -- responsive and preserve the feeling of sequential construction.
        if i % 3 == 0 and i < #commands then
            task.wait(createStagger)
        end
    end

    -- Exit batch mode
    inBatchMode = false

    -- If we collected parts during the batch, animate them with staggered timing
    local unfinishedResult = nil
    if #batchCreatedParts > 0 then
        local partCount = #batchCreatedParts

        -- BuildAnimator reads the target Size/Transparency from attributes,
        -- sorts parts spatially, and runs the reveal curve.
        BuildAnimator.animateBatch(batchCreatedParts, nil, nil, nil, style)

        -- CHARACTER_BIBLE §6: every build leaves one deliberate gap.
        -- Pick a part from the freshly created batch so the player always has
        -- one piece left to finish.
        unfinishedResult = CommandExecutor.markUnfinished({ partsList = batchCreatedParts })

        -- Clear the tracking list
        table.clear(batchCreatedParts)

        print(string.format("[Lucineer] CommandExecutor: animated batch of %d parts via BuildAnimator", partCount))
    end

    -- Append the unfinished marker as a command result so the server can
    -- route Lucineer's "what's left undone" line to the player.
    if unfinishedResult then
        table.insert(results, {
            index = #results + 1,
            type = "markUnfinished",
            success = true,
            result = unfinishedResult,
        })
    end

    return results
end

return CommandExecutor
