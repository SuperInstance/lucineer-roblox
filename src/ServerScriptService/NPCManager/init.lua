--!strict
--[[
    NPC Manager — Slackwater Yard Ecosystem
    ═══════════════════════════════════════════════════════════════
    "Five locals and a raven. The yard doesn't feel empty because
     none of them are waiting for you. They were already working."

    Spawns and manages all NPCs in Slackwater Yard:

      • EARL        — quest giver, manifest keeper (cannery shack)
      • SPARK       — welder-bot, patrol + weld anim (forge area)
      • HERMES      — tender captain, Channel stories (the float)
      • BEA         — lighthouse keeper, fog hints (the Light)
      • FORTY-EIGHT — ambient raven, roofline patrol (no interaction)

    ═══════════════════════════════════════════════════════════════
    RESPONSIBILITY BOUNDARY (post-split-brain fix):
    ═══════════════════════════════════════════════════════════════
    NPCManager handles ONLY:
      • NPC spawning and model creation
      • Pathfinding and patrol behavior loops
      • ProximityPrompt events (fires callbacks, does NOT show dialogue)
      • Visual state (bubbles for AI-routed messages, animations, particles)
      • Facing player on interaction

    NPCManager does NOT handle:
      ✗ Static dialogue tables — ALL dialogue comes from the AI/Worker pipeline
      ✗ Quest data or quest cycling — handled by external quest systems
      ✗ Tutorial progression — handled by OnboardingSystem
      ✗ Onboarding hints — handled by OnboardingSystem via Worker API

    DIALOGUE ROUTING:
    When a player triggers a ProximityPrompt, NPCManager fires an
    InteractionRequested event. External systems (OnboardingSystem,
    AI Worker pipeline) listen and route dialogue back via
    NPCManager.showDialogue(npcName, text, player).

    API:
      NPCManager.init()                          — spawn all, start loops
      NPCManager.getNPC(name: string)            — return NPC Model
      NPCManager.forceInteract(name, player)     — testing hook
      NPCManager.showDialogue(npcName, text, player, duration?) — display AI dialogue
      NPCManager.InteractionRequested            — Signal-like event (array of callbacks)
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NPCManager = {}

----------------------------------------------------------------
-- INTERACTION REQUEST CALLBACK REGISTRY
-- External systems register here to receive proximity trigger events.
-- This replaces the old hardcoded dialogue handlers.
----------------------------------------------------------------

-- Array of callback functions: function(npcName: string, player: Player)
local interactionCallbacks = {}

--- Register a callback for NPC proximity interactions.
--- @param callback function(npcName: string, player: Player)
function NPCManager.onInteraction(callback)
    table.insert(interactionCallbacks, callback)
end

local function fireInteraction(npcName, player)
    for _, cb in ipairs(interactionCallbacks) do
        task.spawn(function()
            pcall(cb, npcName, player)
        end)
    end
end

----------------------------------------------------------------
-- NPC SPAWN POSITIONS
----------------------------------------------------------------

local SPAWN_POSITIONS = {
    Earl         = CFrame.new(-12, 1.5, -8),    -- cannery shack, manifest window
    Spark        = CFrame.new(0, 1.5, 4),       -- forge aisle center
    Hermes       = CFrame.new(35, 3.5, -20),    -- Capitaine wheelhouse deck
    Bea          = CFrame.new(-50, 25, -60),    -- lighthouse base
    FortyEight   = CFrame.new(8, 18, -2),       -- cannery roofline
}

----------------------------------------------------------------
-- COLORS / VISUAL CONSTANTS
----------------------------------------------------------------

local NPC_COLORS = {
    Earl        = Color3.fromRGB(180, 140, 60),   -- mustard hi-vis
    Spark       = Color3.fromRGB(200, 200, 210),  -- salvage metal
    Hermes      = Color3.fromRGB(40, 50, 65),     -- oil-skinned silhouette
    Bea         = Color3.fromRGB(130, 120, 110),  -- wool and weather
    FortyEight  = Color3.fromRGB(20, 20, 25),     -- raven black
}

local BUBBLE_BG = Color3.fromRGB(15, 25, 35)
local BUBBLE_TEXT = Color3.fromRGB(240, 240, 245)
local BUBBLE_ACCENT = Color3.fromRGB(0, 255, 170)

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

local npcs: {[string]: Model} = {}
local initialized = false

-- Track active bubble GUIs for cleanup
local activeBubbles: {[string]: BillboardGui} = {}

----------------------------------------------------------------
-- INTERNAL: MODEL CREATION
----------------------------------------------------------------

--[[
    Build a basic NPC model: a blocky humanoid figure.
    Each NPC gets custom colors and proportions per their design.
    @param name string — NPC name
    @param cframe CFrame — spawn position
    @return Model
]]
local function createNPCModel(name: string, cframe: CFrame): Model
    local model = Instance.new("Model")
    model.Name = name

    -- HumanoidRootPart
    local root = Instance.new("Part")
    root.Name = "HumanoidRootPart"
    root.Size = Vector3.new(2, 2, 1)
    root.Transparency = 1
    root.CanCollide = false
    root.CanQuery = false
    root.Anchored = true
    root.CFrame = cframe
    root.Parent = model

    -- Primary part
    model.PrimaryPart = root

    -- Body color
    local color = NPC_COLORS[name] or Color3.fromRGB(150, 150, 150)

    -- Build parts based on NPC type
    if name == "Earl" then
        -- Short, wide torso (hi-vis vest)
        local torso = Instance.new("Part")
        torso.Name = "Torso"
        torso.Size = Vector3.new(2.4, 2, 1.2)
        torso.Color = color
        torso.Material = Enum.Material.SmoothPlastic
        torso.CFrame = cframe
        torso.CanCollide = false
        torso.Parent = model
        torso.Anchored = true

        -- Head
        local head = Instance.new("Part")
        head.Name = "Head"
        head.Size = Vector3.new(1.2, 1.2, 1.2)
        head.Color = Color3.fromRGB(200, 170, 140)
        head.CFrame = cframe * CFrame.new(0, 2.2, 0)
        head.CanCollide = false
        head.Parent = model
        head.Anchored = true

        -- Welds to root
        local torsoWeld = Instance.new("Weld")
        torsoWeld.Part0 = root
        torsoWeld.Part1 = torso
        torsoWeld.C0 = CFrame.new(0, -0.5, 0)
        torsoWeld.Parent = torso

        local headWeld = Instance.new("Weld")
        headWeld.Part0 = torso
        headWeld.Part1 = head
        headWeld.C0 = CFrame.new(0, 1.6, 0)
        headWeld.Parent = head

        -- Clipboard (manifest) prop
        local clipboard = Instance.new("Part")
        clipboard.Name = "Manifest"
        clipboard.Size = Vector3.new(0.6, 0.8, 0.1)
        clipboard.Color = Color3.fromRGB(120, 100, 70)
        clipboard.Material = Enum.Material.Wood
        clipboard.CFrame = cframe * CFrame.new(0.8, 0.3, 0.8) * CFrame.Angles(0, 0.3, 0)
        clipboard.CanCollide = false
        clipboard.Parent = model
        clipboard.Anchored = true

    elseif name == "Spark" then
        -- Knee-high, three-legged welding rig
        local body = Instance.new("Part")
        body.Name = "Body"
        body.Size = Vector3.new(1.5, 1.5, 1.5)
        body.Color = color
        body.Material = Enum.Material.Metal
        body.CFrame = cframe * CFrame.new(0, -0.5, 0)
        body.CanCollide = false
        body.Parent = model
        body.Anchored = true

        local bodyWeld = Instance.new("Weld")
        bodyWeld.Part0 = root
        bodyWeld.Part1 = body
        bodyWeld.C0 = CFrame.new(0, -0.5, 0)
        bodyWeld.Parent = body

        -- Single lens-eye (welding mask face)
        local eye = Instance.new("Part")
        eye.Name = "Lens"
        eye.Size = Vector3.new(0.5, 0.5, 0.1)
        eye.Color = Color3.fromRGB(255, 200, 50)
        eye.Material = Enum.Material.Neon
        eye.CFrame = cframe * CFrame.new(0, 0.2, 0.8)
        eye.CanCollide = false
        eye.Parent = model
        eye.Anchored = true

        local eyeWeld = Instance.new("Weld")
        eyeWeld.Part0 = body
        eyeWeld.Part1 = eye
        eyeWeld.C0 = CFrame.new(0, 0.7, 0.75)
        eyeWeld.Parent = eye

        -- Three legs (mismatched salvage)
        for i = 1, 3 do
            local leg = Instance.new("Part")
            leg.Name = "Leg" .. tostring(i)
            leg.Size = Vector3.new(0.3, 1.5, 0.3)
            leg.Color = Color3.fromRGB(100, 95, 90)
            leg.Material = Enum.Material.Metal
            local angle = (i - 1) * (math.pi * 2 / 3)
            local offset = CFrame.new(math.cos(angle) * 0.6, -1.5, math.sin(angle) * 0.6)
            leg.CFrame = cframe * offset
            leg.CanCollide = false
            leg.Parent = model
            leg.Anchored = true

            local legWeld = Instance.new("Weld")
            legWeld.Part0 = body
            legWeld.Part1 = leg
            legWeld.C0 = offset
            legWeld.Parent = leg
        end

        -- Power cable "tail"
        local cable = Instance.new("Part")
        cable.Name = "PowerCable"
        cable.Size = Vector3.new(0.15, 0.15, 2)
        cable.Color = Color3.fromRGB(60, 50, 40)
        cable.Material = Enum.Material.SmoothPlastic
        cable.CFrame = cframe * CFrame.new(0, -1.2, -1)
        cable.CanCollide = false
        cable.Parent = model
        cable.Anchored = true

        local cableWeld = Instance.new("Weld")
        cableWeld.Part0 = body
        cableWeld.Part1 = cable
        cableWeld.C0 = CFrame.new(0, -0.7, -1)
        cableWeld.Parent = cable

    elseif name == "Hermes" then
        -- Tall, dark silhouette
        local torso = Instance.new("Part")
        torso.Name = "Torso"
        torso.Size = Vector3.new(2, 3, 1.2)
        torso.Color = color
        torso.Material = Enum.Material.SmoothPlastic
        torso.CFrame = cframe
        torso.CanCollide = false
        torso.Parent = model
        torso.Anchored = true

        local torsoWeld = Instance.new("Weld")
        torsoWeld.Part0 = root
        torsoWeld.Part1 = torso
        torsoWeld.Parent = torso

        -- Head (partially obscured — silhouette)
        local head = Instance.new("Part")
        head.Name = "Head"
        head.Size = Vector3.new(1.2, 1.4, 1.2)
        head.Color = Color3.fromRGB(30, 35, 45)
        head.Material = Enum.Material.SmoothPlastic
        head.CFrame = cframe * CFrame.new(0, 2.5, 0)
        head.CanCollide = false
        head.Parent = model
        head.Anchored = true

        local headWeld = Instance.new("Weld")
        headWeld.Part0 = torso
        headWeld.Part1 = head
        headWeld.C0 = CFrame.new(0, 2.5, 0)
        headWeld.Parent = head

    elseif name == "Bea" then
        -- Upright, weathered, watch cap silhouette
        local torso = Instance.new("Part")
        torso.Name = "Torso"
        torso.Size = Vector3.new(2, 2.8, 1.2)
        torso.Color = color
        torso.Material = Enum.Material.SmoothPlastic
        torso.CFrame = cframe
        torso.CanCollide = false
        torso.Parent = model
        torso.Anchored = true

        local torsoWeld = Instance.new("Weld")
        torsoWeld.Part0 = root
        torsoWeld.Part1 = torso
        torsoWeld.Parent = torso

        local head = Instance.new("Part")
        head.Name = "Head"
        head.Size = Vector3.new(1.2, 1.2, 1.2)
        head.Color = Color3.fromRGB(170, 145, 125)
        head.Material = Enum.Material.SmoothPlastic
        head.CFrame = cframe * CFrame.new(0, 2.3, 0)
        head.CanCollide = false
        head.Parent = model
        head.Anchored = true

        local headWeld = Instance.new("Weld")
        headWeld.Part0 = torso
        headWeld.Part1 = head
        headWeld.C0 = CFrame.new(0, 2.3, 0)
        headWeld.Parent = head

        -- Watch cap
        local cap = Instance.new("Part")
        cap.Name = "WatchCap"
        cap.Size = Vector3.new(1.3, 0.5, 1.3)
        cap.Color = Color3.fromRGB(50, 50, 55)
        cap.Material = Enum.Material.SmoothPlastic
        cap.CFrame = cframe * CFrame.new(0, 3.1, 0)
        cap.CanCollide = false
        cap.Parent = model
        cap.Anchored = true

        local capWeld = Instance.new("Weld")
        capWeld.Part0 = head
        capWeld.Part1 = cap
        capWeld.C0 = CFrame.new(0, 0.8, 0)
        capWeld.Parent = cap

        -- Key ring
        local keys = Instance.new("Part")
        keys.Name = "KeyRing"
        keys.Size = Vector3.new(0.4, 0.4, 0.1)
        keys.Color = Color3.fromRGB(180, 160, 80)
        keys.Material = Enum.Material.Metal
        keys.CFrame = cframe * CFrame.new(0.9, 0.5, 0.8)
        keys.CanCollide = false
        keys.Parent = model
        keys.Anchored = true

        local keysWeld = Instance.new("Weld")
        keysWeld.Part0 = torso
        keysWeld.Part1 = keys
        keysWeld.C0 = CFrame.new(0.9, 0.5, 0.8)
        keysWeld.Parent = keys

    elseif name == "FortyEight" then
        -- Raven: small body, beak, wings
        local body = Instance.new("Part")
        body.Name = "Body"
        body.Size = Vector3.new(0.8, 0.8, 1.5)
        body.Color = color
        body.Material = Enum.Material.SmoothPlastic
        body.CFrame = cframe
        body.CanCollide = false
        body.Parent = model
        body.Anchored = true

        local bodyWeld = Instance.new("Weld")
        bodyWeld.Part0 = root
        bodyWeld.Part1 = body
        bodyWeld.Parent = body

        -- Head
        local head = Instance.new("Part")
        head.Name = "Head"
        head.Size = Vector3.new(0.6, 0.6, 0.6)
        head.Color = color
        head.Material = Enum.Material.SmoothPlastic
        head.CFrame = cframe * CFrame.new(0, 0.5, 0.8)
        head.CanCollide = false
        head.Parent = model
        head.Anchored = true

        local headWeld = Instance.new("Weld")
        headWeld.Part0 = body
        headWeld.Part1 = head
        headWeld.C0 = CFrame.new(0, 0.5, 0.8)
        headWeld.Parent = head

        -- Beak
        local beak = Instance.new("Part")
        beak.Name = "Beak"
        beak.Size = Vector3.new(0.15, 0.15, 0.5)
        beak.Color = Color3.fromRGB(80, 70, 50)
        beak.Material = Enum.Material.SmoothPlastic
        beak.CFrame = cframe * CFrame.new(0, 0.5, 1.3)
        beak.CanCollide = false
        beak.Parent = model
        beak.Anchored = true

        local beakWeld = Instance.new("Weld")
        beakWeld.Part0 = head
        beakWeld.Part1 = beak
        beakWeld.C0 = CFrame.new(0, 0, 0.5)
        beakWeld.Parent = beak

        -- Hexagonal machine-washer on leg
        local washer = Instance.new("Part")
        washer.Name = "Washer"
        washer.Shape = Enum.PartType.Cylinder
        washer.Size = Vector3.new(0.1, 0.3, 0.3)
        washer.Color = Color3.fromRGB(160, 160, 170)
        washer.Material = Enum.Material.Metal
        washer.CFrame = cframe * CFrame.new(0.3, -0.4, 0) * CFrame.Angles(0, 0, math.pi / 2)
        washer.CanCollide = false
        washer.Parent = model
        washer.Anchored = true

        local washerWeld = Instance.new("Weld")
        washerWeld.Part0 = body
        washerWeld.Part1 = washer
        washerWeld.C0 = CFrame.new(0.3, -0.4, 0) * CFrame.Angles(0, 0, math.pi / 2)
        washerWeld.Parent = washer
    end

    -- Humanoid (for animation system compatibility and name display)
    local humanoid = Instance.new("Humanoid")
    humanoid.DisplayNameOffset = Vector3.new(0, 3, 0)
    humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
    humanoid.Name = "Humanoid"
    humanoid.Parent = model

    model.Parent = workspace
    return model
end

----------------------------------------------------------------
-- INTERNAL: PROXIMITY PROMPT
----------------------------------------------------------------

--[[
    Create and attach a ProximityPrompt to an NPC's primary part.
    @param model Model — the NPC
    @param name string — NPC display name for the prompt
    @param actionText string — prompt action text
    @param description string? — prompt description
    @return ProximityPrompt
]]
local function createProximityPrompt(model: Model, name: string, actionText: string, description: string?): ProximityPrompt
    local root = model.PrimaryPart
    if not root then return nil :: any end

    local prompt = Instance.new("ProximityPrompt")
    prompt.Name = "NPCPrompt"
    prompt.ActionText = actionText
    prompt.ObjectText = name
    prompt.HoldDuration = 0
    prompt.MaxActivationDistance = 12
    prompt.RequiresLineOfSight = false
    prompt.KeyboardKeyCode = Enum.KeyCode.E
    prompt.GamepadKeyCode = Enum.KeyCode.ButtonA
    if description then
        prompt.DescriptionText = description
    end
    prompt.Parent = root
    return prompt
end

----------------------------------------------------------------
-- INTERNAL: CHAT BUBBLE (AI-routed dialogue display)
----------------------------------------------------------------

--[[
    Show a chat bubble above an NPC with dialogue text.
    This is the SOLE entry point for displaying NPC dialogue.
    All dialogue content comes from external systems (AI Worker pipeline,
    OnboardingSystem). NPCManager never generates dialogue text itself.
    Auto-dismisses after a duration.
    @param npcName string — NPC identifier
    @param text string — dialogue text (from AI/Worker/onboarding)
    @param player Player? — optional: if provided, only show to this player
    @param duration number? — seconds to display (default 6)
]]
local function showBubble(npcName: string, text: string, player: Player?, duration: number?)
    duration = duration or 6

    -- Remove existing bubble
    local existing = activeBubbles[npcName]
    if existing then
        existing:Destroy()
    end

    local model = npcs[npcName]
    if not model then return end

    local root = model.PrimaryPart
    if not root then return end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "ChatBubble"
    billboard.Size = UDim2.new(0, 400, 0, 120)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
    billboard.MaxDistance = 60
    billboard.AlwaysOnTop = false

    -- If a specific player is provided, we need client-side filtering.
    -- BillboardGui doesn't support per-player visibility natively,
    -- so we use a RemoteEvent to tell the client to show the bubble locally.
    -- For server-wide bubbles (ambient NPC chatter), parent to root directly.
    if player then
        -- Try to use the Lucineer dialogue remote for per-player display
        local lucineerFolder = ReplicatedStorage:FindFirstChild("Lucineer")
        if lucineerFolder then
            local responseEvent = lucineerFolder:FindFirstChild("ResponseEvent")
            if responseEvent and responseEvent:IsA("RemoteEvent") then
                responseEvent:FireClient(player, {
                    type = "npc_dialogue",
                    speaker = npcName,
                    message = text,
                    duration = duration,
                })
                return
            end
        end
        -- Fallback: server-wide bubble (visible to all, less ideal)
    end

    billboard.Parent = root

    -- Background frame
    local frame = Instance.new("Frame")
    frame.Name = "BubbleFrame"
    frame.Size = UDim2.new(1, -10, 1, -10)
    frame.Position = UDim2.new(0, 5, 0, 5)
    frame.BackgroundColor3 = BUBBLE_BG
    frame.BackgroundTransparency = 0.1
    frame.BorderSizePixel = 0
    frame.Parent = billboard

    -- Rounded corners
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    -- Accent border (left edge)
    local accent = Instance.new("Frame")
    accent.Name = "AccentBar"
    accent.Size = UDim2.new(0, 3, 1, 0)
    accent.Position = UDim2.new(0, 0, 0, 0)
    accent.BackgroundColor3 = BUBBLE_ACCENT
    accent.BorderSizePixel = 0
    accent.Parent = frame

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(0, 2)
    accentCorner.Parent = accent

    -- Name label
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "NPCName"
    nameLabel.Size = UDim2.new(1, -20, 0, 22)
    nameLabel.Position = UDim2.new(0, 12, 0, 6)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 14
    nameLabel.TextColor3 = BUBBLE_ACCENT
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Text = npcName
    nameLabel.Parent = frame

    -- Dialogue text
    local textLabel = Instance.new("TextLabel")
    textLabel.Name = "Dialogue"
    textLabel.Size = UDim2.new(1, -20, 1, -34)
    textLabel.Position = UDim2.new(0, 12, 0, 30)
    textLabel.BackgroundTransparency = 1
    textLabel.Font = Enum.Font.Gotham
    textLabel.TextSize = 16
    textLabel.TextColor3 = BUBBLE_TEXT
    textLabel.TextWrapped = true
    textLabel.TextXAlignment = Enum.TextXAlignment.Left
    textLabel.TextYAlignment = Enum.TextYAlignment.Top
    textLabel.Text = text
    textLabel.Parent = frame

    activeBubbles[npcName] = billboard

    -- Fade in
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
    local tween = TweenService:Create(billboard, TweenInfo.new(0.3), {
        StudsOffsetWorldSpace = Vector3.new(0, 4, 0),
    })
    tween:Play()

    -- Auto-dismiss
    task.delay(duration, function()
        if activeBubbles[npcName] == billboard then
            local fadeTween = TweenService:Create(billboard, TweenInfo.new(0.3), {
                StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0),
            })
            fadeTween:Play()

            for _, child in ipairs(frame:GetChildren()) do
                if child:IsA("TextLabel") then
                    TweenService:Create(child, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
                end
            end
            TweenService:Create(frame, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()

            task.delay(0.35, function()
                if activeBubbles[npcName] == billboard then
                    billboard:Destroy()
                    activeBubbles[npcName] = nil
                end
            end)
        end
    end)
end

----------------------------------------------------------------
-- INTERNAL: NPC FACE PLAYER
----------------------------------------------------------------

--[[
    Smoothly rotate an NPC's root to face the player.
    @param npcName string
    @param player Player
    @param duration number? — seconds for the turn (default 0.5)
]]
local function facePlayer(npcName: string, player: Player, duration: number?)
    duration = duration or 0.5

    local model = npcs[npcName]
    if not model then return end

    local root = model.PrimaryPart
    if not root then return end

    local character = player.Character
    if not character then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local npcPos = root.Position
    local playerPos = hrp.Position
    local lookDir = (Vector3.new(playerPos.X, npcPos.Y, playerPos.Z) - npcPos).Unit
    local targetCFrame = CFrame.lookAt(npcPos, npcPos + lookDir)

    local tween = TweenService:Create(root, TweenInfo.new(duration), {
        CFrame = targetCFrame,
    })
    tween:Play()
end

----------------------------------------------------------------
-- INTERNAL: SPAWN PARTICLES (SPARK)
----------------------------------------------------------------

--[[
    Create a brief spark particle burst at a position.
    @param cframe CFrame — world position
]]
local function spawnSparkParticles(cframe: CFrame)
    local attachment = Instance.new("Part")
    attachment.Name = "SparkBurst"
    attachment.Size = Vector3.new(0.1, 0.1, 0.1)
    attachment.Transparency = 1
    attachment.CanCollide = false
    attachment.CanQuery = false
    attachment.Anchored = true
    attachment.CFrame = cframe
    attachment.Parent = workspace

    local emitter = Instance.new("ParticleEmitter")
    emitter.Texture = "rbxassetid://243660364"
    emitter.Color = ColorSequence.new(Color3.fromRGB(255, 200, 50))
    emitter.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.5),
        NumberSequenceKeypoint.new(1, 0),
    })
    emitter.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    emitter.Lifetime = NumberRange.new(0.3, 0.6)
    emitter.Rate = 0
    emitter.Speed = NumberRange.new(8, 15)
    emitter.SpreadAngle = Vector2.new(45, 45)
    emitter.Rotation = NumberRange.new(0, 360)
    emitter.Parent = attachment

    emitter:Emit(12)
    Debris:AddItem(attachment, 2)
end

----------------------------------------------------------------
-- BEHAVIOR LOOPS
-- These handle ONLY pathfinding, patrol, and visual idle animations.
-- No dialogue, no quest logic, no interaction content.
----------------------------------------------------------------

--[[
    EARL BEHAVIOR LOOP
    Stands at his manifest desk. Occasional clipboard flip animation.
]]
local function earlBehaviorLoop()
    task.spawn(function()
        while initialized do
            task.wait(10 + math.random() * 10)
            if not initialized then break end
            local model = npcs["Earl"]
            if not model then break end

            local manifest = model:FindFirstChild("Manifest")
            if manifest then
                local currentCF = manifest.CFrame
                local nudge = CFrame.Angles(0, math.rad((math.random() - 0.5) * 10), 0)
                TweenService:Create(manifest, TweenInfo.new(0.8), {
                    CFrame = currentCF * nudge,
                }):Play()
            end
        end
    end)
end

--[[
    SPARK BEHAVIOR LOOP
    Patrols the forge area on a set path. Plays welding animation
    (sparks) at each stop. Occasional random spark bursts.
]]
local function sparkBehaviorLoop()
    local waypoints = {
        CFrame.new(0, 1.5, 4),
        CFrame.new(6, 1.5, 2),
        CFrame.new(6, 1.5, -4),
        CFrame.new(0, 1.5, -6),
        CFrame.new(-6, 1.5, -4),
        CFrame.new(-6, 1.5, 2),
    }

    task.spawn(function()
        while initialized do
            for _, targetCF in ipairs(waypoints) do
                if not initialized then break end
                local model = npcs["Spark"]
                if not model then break end

                local root = model.PrimaryPart
                if not root then break end

                local moveTween = TweenService:Create(root, TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                    CFrame = targetCF,
                })
                moveTween:Play()
                moveTween.Completed:Wait()

                if not initialized then break end

                local weldDuration = 2 + math.random() * 1.5
                local weldStart = tick()
                while tick() - weldStart < weldDuration do
                    if not initialized then break end
                    local body = model:FindFirstChild("Body")
                    if body then
                        spawnSparkParticles(body.CFrame * CFrame.new(0, 0.5, 0.8))
                    end
                    task.wait(0.3 + math.random() * 0.2)
                end

                task.wait(0.5)
            end
        end
    end)

    task.spawn(function()
        while initialized do
            task.wait(15 + math.random() * 20)
            if not initialized then break end
            local model = npcs["Spark"]
            if not model then break end
            local body = model:FindFirstChild("Body")
            if body then
                spawnSparkParticles(body.CFrame * CFrame.new(0, 1, 0))
            end
        end
    end)
end

--[[
    HERMES BEHAVIOR LOOP
    Stands on the Capitaine's deck. Gentle idle sway.
]]
local function hermesBehaviorLoop()
    task.spawn(function()
        while initialized do
            task.wait(20 + math.random() * 15)
            if not initialized then break end
            local model = npcs["Hermes"]
            if not model then break end

            local root = model.PrimaryPart
            if root then
                local currentCF = root.CFrame
                local sway = CFrame.Angles(0, math.rad((math.random() - 0.5) * 6), 0)
                TweenService:Create(root, TweenInfo.new(1.5, Enum.EasingStyle.Sine), {
                    CFrame = currentCF * sway,
                }):Play()
            end
        end
    end)
end

--[[
    BEA BEHAVIOR LOOP
    Stands at the lighthouse base. Rare, deliberate movements.
    Once per session-length, walks the yard (small repositioning).
]]
local function beaBehaviorLoop()
    task.spawn(function()
        while initialized do
            task.wait(60 + math.random() * 60)
            if not initialized then break end
            local model = npcs["Bea"]
            if not model then break end

            local root = model.PrimaryPart
            if root then
                local baseCF = SPAWN_POSITIONS.Bea
                local offset = CFrame.new(
                    (math.random() - 0.5) * 4,
                    0,
                    (math.random() - 0.5) * 4
                )
                local targetCF = baseCF * offset

                local walkTween = TweenService:Create(root, TweenInfo.new(4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
                    CFrame = targetCF,
                })
                walkTween:Play()
                walkTween.Completed:Wait()

                task.wait(10)

                local returnTween = TweenService:Create(root, TweenInfo.new(4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
                    CFrame = baseCF,
                })
                returnTween:Play()
                returnTween.Completed:Wait()
            end
        end
    end)
end

--[[
    FORTY-EIGHT BEHAVIOR LOOP
    Hops along the roofline on exact, repeatable segments.
    Forty-Eight is ambient only — no ProximityPrompt, no interaction.
    Crowing sounds are handled as visual-only; ambient audio system
    or external AI can route crow sounds through showDialogue.
]]
local function fortyEightBehaviorLoop()
    local roofPoints = {
        CFrame.new(8, 18, -2),
        CFrame.new(4, 19, 0),
        CFrame.new(0, 19.5, 2),
        CFrame.new(-4, 19, 0),
        CFrame.new(0, 19.5, -4),
        CFrame.new(4, 19, -2),
    }

    -- Roofline patrol only — no dialogue, no crow sounds from NPCManager
    task.spawn(function()
        while initialized do
            for _, targetCF in ipairs(roofPoints) do
                if not initialized then break end
                local model = npcs["FortyEight"]
                if not model then break end

                local root = model.PrimaryPart
                if not root then break end

                local hopTween = TweenService:Create(root, TweenInfo.new(1.0, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
                    CFrame = targetCF,
                })
                hopTween:Play()
                hopTween.Completed:Wait()

                task.wait(3.0)
            end
        end
    end)
end

----------------------------------------------------------------
-- SPAWN ALL NPCs
----------------------------------------------------------------

local function spawnAllNPCs()
    -- EARL
    npcs["Earl"] = createNPCModel("Earl", SPAWN_POSITIONS.Earl)
    createProximityPrompt(npcs["Earl"], "Earl", "Talk to Earl", "Check the manifest for work")
    local earlPrompt = npcs["Earl"].PrimaryPart:FindFirstChild("NPCPrompt")
    if earlPrompt then
        earlPrompt.Triggered:Connect(function(player)
            facePlayer("Earl", player)
            fireInteraction("Earl", player)
        end)
    end

    -- SPARK
    npcs["Spark"] = createNPCModel("Spark", SPAWN_POSITIONS.Spark)
    createProximityPrompt(npcs["Spark"], "Spark", "Interact with Spark", "What's the little bot up to?")
    local sparkPrompt = npcs["Spark"].PrimaryPart:FindFirstChild("NPCPrompt")
    if sparkPrompt then
        sparkPrompt.Triggered:Connect(function(player)
            facePlayer("Spark", player)
            fireInteraction("Spark", player)
        end)
    end

    -- HERMES
    npcs["Hermes"] = createNPCModel("Hermes", SPAWN_POSITIONS.Hermes)
    createProximityPrompt(npcs["Hermes"], "Hermes", "Talk to Captain Hermes", "Hear a Channel story")
    local hermesPrompt = npcs["Hermes"].PrimaryPart:FindFirstChild("NPCPrompt")
    if hermesPrompt then
        hermesPrompt.Triggered:Connect(function(player)
            facePlayer("Hermes", player)
            fireInteraction("Hermes", player)
        end)
    end

    -- BEA
    npcs["Bea"] = createNPCModel("Bea", SPAWN_POSITIONS.Bea)
    createProximityPrompt(npcs["Bea"], "Bea", "Talk to Bea", "Ask about the Light")
    local beaPrompt = npcs["Bea"].PrimaryPart:FindFirstChild("NPCPrompt")
    if beaPrompt then
        beaPrompt.Triggered:Connect(function(player)
            facePlayer("Bea", player)
            fireInteraction("Bea", player)
        end)
    end

    -- FORTY-EIGHT (no ProximityPrompt — ambient only)
    npcs["FortyEight"] = createNPCModel("FortyEight", SPAWN_POSITIONS.FortyEight)

    print("[NPCManager] Spawned 5 NPCs: Earl, Spark, Hermes, Bea, Forty-Eight")
end

----------------------------------------------------------------
-- START BEHAVIOR LOOPS
----------------------------------------------------------------

local function startBehaviorLoops()
    earlBehaviorLoop()
    sparkBehaviorLoop()
    hermesBehaviorLoop()
    beaBehaviorLoop()
    fortyEightBehaviorLoop()
    print("[NPCManager] All behavior loops started")
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Initialize the NPC system. Spawns all NPCs and starts behavior loops.
    Call once during server init.
]]
function NPCManager.init()
    if initialized then
        warn("[NPCManager] Already initialized.")
        return
    end

    spawnAllNPCs()
    startBehaviorLoops()

    initialized = true
    print("[NPCManager] Initialized — Slackwater Yard is alive ✓")
end

--[[
    Get an NPC model by name.
    @param name string — "Earl", "Spark", "Hermes", "Bea", "FortyEight"
    @return Model?
]]
function NPCManager.getNPC(name: string): Model?
    return npcs[name]
end

--[[
    Display AI-sourced dialogue above an NPC.
    This is the canonical way to show NPC dialogue. All dialogue content
    must come from the AI/Worker pipeline or OnboardingSystem —
    NPCManager never generates text itself.

    Usage:
        NPCManager.showDialogue("Earl", "Item one: you're standing on my manifest line.", player, 6)

    @param npcName string — NPC identifier
    @param text string — dialogue text from AI/Worker/onboarding
    @param player Player? — optional: show only to this player (per-client)
    @param duration number? — seconds to display (default 6)
]]
function NPCManager.showDialogue(npcName: string, text: string, player: Player?, duration: number?)
    showBubble(npcName, text, player, duration)
end

--[[
    Display ambient (server-wide) dialogue above an NPC.
    Convenience wrapper for showDialogue without a player filter.
    @param npcName string
    @param text string
    @param duration number? — seconds (default 6)
]]
function NPCManager.showAmbient(npcName: string, text: string, duration: number?)
    showBubble(npcName, text, nil, duration)
end

--[[
    Trigger spark particle burst at an NPC's position.
    Useful for AI pipeline to add visual emphasis to Spark interactions.
    @param npcName string
]]
function NPCManager.emitSparks(npcName: string)
    local model = npcs[npcName]
    if not model then return end
    local body = model:FindFirstChild("Body")
    if body then
        spawnSparkParticles(body.CFrame * CFrame.new(0, 1, 0.5))
    else
        local root = model.PrimaryPart
        if root then
            spawnSparkParticles(root.CFrame * CFrame.new(0, 1, 0))
        end
    end
end

--[[
    Force an NPC interaction (for testing/debugging).
    Fires the interaction callbacks as if the player used the ProximityPrompt.
    For Forty-Eight (no prompt), shows a test line via showDialogue.

    @param name string — NPC name
    @param player Player — the player to simulate interaction for
]]
function NPCManager.forceInteract(name: string, player: Player)
    if npcs[name] then
        if name ~= "FortyEight" then
            facePlayer(name, player)
            fireInteraction(name, player)
        else
            -- Forty-Eight has no interaction; emit a test crow via showDialogue
            showBubble("FortyEight", "*caw*", nil, 3)
        end
    else
        warn("[NPCManager] Unknown NPC:", name)
    end
end

--[[
    Get all active NPC names.
    @return table — array of string names
]]
function NPCManager.getNPCNames(): { [string]: any }
    local names = {}
    for name in pairs(npcs) do
        table.insert(names, name)
    end
    return names
end

--[[
    Make an NPC face a specific player.
    @param npcName string
    @param player Player
    @param duration number? — seconds for turn animation (default 0.5)
]]
function NPCManager.facePlayer(npcName: string, player: Player, duration: number?)
    facePlayer(npcName, player, duration)
end

--[[
    Shutdown: clean up all NPCs and bubbles.
    Primarily for testing.
]]
function NPCManager.shutdown()
    initialized = false

    for name, bubble in pairs(activeBubbles) do
        bubble:Destroy()
    end
    activeBubbles = {}

    for name, model in pairs(npcs) do
        model:Destroy()
    end
    npcs = {}

    interactionCallbacks = {}
    print("[NPCManager] Shut down. Yard is empty.")
end

return NPCManager
