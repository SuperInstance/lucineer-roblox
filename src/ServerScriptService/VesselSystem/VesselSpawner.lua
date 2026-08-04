--[[
    VesselSystem/VesselSpawner.lua
    Slackwater — Vessel Spawn and Fleet Management

    "Every boat Casey ever owned is still in the harbor. The old skiff he
     learned on. The cutter that paid for itself twice over. The longliner
     that nearly sank him in '84. They're all tied up at the dock, a timeline
     you can walk past and touch. That's not neglect. That's history."

    ───────────────────────────────────────────────
    FEATURES:

    1. SPAWN ON DEMAND
       When a player reaches a new building era, VesselSpawner creates the
       appropriate vessel at the pier. The vessel is fully physical —
       buoyancy, helm, damage — ready to board.

    2. FLEET HISTORY
       When a player upgrades to a new vessel era, the OLD vessel stays in
       the world, tied up at its own slip. Over a full playthrough, the pier
       fills with the history of the fleet. Each old vessel is boarded up
       (no boarding prompt) but visually present.

    3. PIER MANAGEMENT
       Each player gets a row of slips. Slip 1 = Era 1, Slip 2 = Era 2, etc.
       Vessels are positioned along the pier with proper spacing.

    4. COLLECTIONSERVICE TAGGING
       Each vessel is tagged:
         • "Vessel" — all vessels
         • "Vessel_<playerId>" — owner-specific
         • "Vessel_Era<eraNumber>" — era-specific

    5. OWNERSHIP
       Each vessel has attributes for:
         • OwnerPlayerId — who owns it
         • OwnerName — display name
         • VesselEra — which era (1-5)
         • VesselKey — type key ("skiff", "cutter", etc.)
         • IsRetired — old vessels stay but aren't usable

    INTEGRATION:
        EraSystem     → triggers vessel spawn on era advancement
        VesselTypes   → configuration for each vessel
        VesselPhysics → physics initialization
        VesselDamage  → damage system initialization
        HelmController → boarding registration

    API:
        VesselSpawner.init()
        VesselSpawner.spawnVessel(player, eraNumber)
        VesselSpawner.retireVessel(player, eraNumber)
        VesselSpawner.getPlayerVessels(player) → table<era, vesselModel>
        VesselSpawner.getActiveVessel(player) → vesselModel|nil
        VesselSpawner.getDockOrigin() → Vector3
]]

----------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

----------------------------------------------------------------
-- MODULE
----------------------------------------------------------------

local VesselSpawner = {}

----------------------------------------------------------------
-- CONSTANTS
----------------------------------------------------------------

-- Pier layout: vessels line up along the pier, each at a slip
local PIER_ORIGIN = Vector3.new(0, 5, -40)  -- adjusted to actual pier location
local SLIP_SPACING = 60                       -- studs between vessel slips
local SLIP_HEADING = 0                         -- degrees (facing direction)

-- Vessel hull part naming convention (for VesselDamage section mapping)
local HULL_SECTIONS = {
    "bow", "port", "starboard", "stern", "keel",
}

-- Module references (lazy)
local VesselTypes
local VesselPhysics
local VesselDamage
local HelmController

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------

-- playerId → { [era] = vesselModel, activeEra = N }
local playerFleets = {}

-- Track the dock folder in workspace
local dockFolder

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function getVesselTypes()
    if not VesselTypes then
        VesselTypes = require(script.Parent:WaitForChild("VesselTypes"))
    end
    return VesselTypes
end

local function getVesselPhysics()
    if not VesselPhysics then
        VesselPhysics = require(script.Parent:WaitForChild("VesselPhysics"))
    end
    return VesselPhysics
end

local function getVesselDamage()
    if not VesselDamage then
        VesselDamage = require(script.Parent:WaitForChild("VesselDamage"))
    end
    return VesselDamage
end

local function getHelmController()
    if not HelmController then
        HelmController = require(script.Parent:WaitForChild("HelmController"))
    end
    return HelmController
end

--[[
    Get or create the dock folder in workspace.
    All vessels are parented here.
    @return Folder
]]
local function getDockFolder()
    if dockFolder and dockFolder.Parent then return dockFolder end

    dockFolder = Workspace:FindFirstChild("VesselDock")
    if not dockFolder then
        dockFolder = Instance.new("Folder")
        dockFolder.Name = "VesselDock"
        dockFolder.Parent = Workspace
    end

    return dockFolder
end

--[[
    Get the world position for a vessel slip.
    @param playerId number
    @param era number (1-5)
    @return Vector3 position, number heading
]]
local function getSlipPosition(playerId, era)
    -- Offset each player's fleet along the pier
    -- Player offset: each player gets a row, spaced perpendicular to pier
    local playerRow = playerId % 10  -- up to 10 players per row

    -- Each era gets a slip along the pier
    local along = PIER_ORIGIN.X + era * SLIP_SPACING
    local across = PIER_ORIGIN.Z + playerRow * 30  -- 30 studs between players
    local height = PIER_ORIGIN.Y

    return Vector3.new(along, height, across), SLIP_HEADING
end

----------------------------------------------------------------
-- VESSEL MODEL CONSTRUCTION
----------------------------------------------------------------

--[[
    Build a physical vessel model from primitives.
    This creates a realistic multi-part hull with:
      - Hull sections (bow, port, starboard, stern, keel)
      - Deck
      - Superstructure (cabin, wheelhouse)
      - Helm seat

    @param config table from VesselTypes
    @param position Vector3 spawn position
    @param heading number spawn heading in degrees
    @return Model vesselModel with PrimaryPart set
]]
local function buildVesselModel(config, position, heading)
    local model = Instance.new("Model")
    model.Name = config.displayName .. "_" .. tostring(math.random(1000, 9999))

    local props = config.proportions
    local length = props.length
    local beam = props.beam
    local height = props.height

    -- ──────────────────────────────────────────────────────────────
    -- HULL (PrimaryPart)
    -- The hull is the main body. We make it a single part for physics.
    -- ──────────────────────────────────────────────────────────────

    local hull = Instance.new("Part")
    hull.Name = "Hull"
    hull.Size = Vector3.new(beam, height, length)
    hull.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(heading), 0)
    hull.Color = props.color
    hull.Material = props.material
    hull.CanCollide = true
    hull.Anchored = false
    hull.TopSurface = Enum.SurfaceType.Smooth
    hull.BottomSurface = Enum.SurfaceType.Smooth
    hull.Parent = model

    model.PrimaryPart = hull

    -- ──────────────────────────────────────────────────────────────
    -- HULL SECTION PARTS (for damage visuals and collision detection)
    -- These are welded to the hull and sized to represent each section.
    -- They allow VesselDamage to darken/modify specific sections.
    -- ──────────────────────────────────────────────────────────────

    local halfLen = length / 2
    local halfBeam = beam / 2

    -- Bow section (front 1/3)
    local bowPart = Instance.new("Part")
    bowPart.Name = "Hull_bow"
    bowPart.Size = Vector3.new(beam, height * 0.7, length * 0.35)
    bowPart.CFrame = hull.CFrame * CFrame.new(0, 0, halfLen * 0.65)
    bowPart.Color = props.color
    bowPart.Material = props.material
    bowPart.CanCollide = true
    bowPart.Anchored = false
    bowPart.Transparency = 1  -- invisible; hull is the visual
    bowPart.Parent = model

    -- Port section (left side, middle)
    local portPart = Instance.new("Part")
    portPart.Name = "Hull_port"
    portPart.Size = Vector3.new(beam * 0.2, height * 0.7, length * 0.4)
    portPart.CFrame = hull.CFrame * CFrame.new(halfBeam * 0.8, 0, 0)
    portPart.Color = props.color
    portPart.Material = props.material
    portPart.CanCollide = true
    portPart.Anchored = false
    portPart.Transparency = 1
    portPart.Parent = model

    -- Starboard section (right side, middle)
    local starPart = Instance.new("Part")
    starPart.Name = "Hull_starboard"
    starPart.Size = Vector3.new(beam * 0.2, height * 0.7, length * 0.4)
    starPart.CFrame = hull.CFrame * CFrame.new(-halfBeam * 0.8, 0, 0)
    starPart.Color = props.color
    starPart.Material = props.material
    starPart.CanCollide = true
    starPart.Anchored = false
    starPart.Transparency = 1
    starPart.Parent = model

    -- Stern section (rear 1/3)
    local sternPart = Instance.new("Part")
    sternPart.Name = "Hull_stern"
    sternPart.Size = Vector3.new(beam, height * 0.7, length * 0.3)
    sternPart.CFrame = hull.CFrame * CFrame.new(0, 0, -halfLen * 0.7)
    sternPart.Color = props.color
    sternPart.Material = props.material
    sternPart.CanCollide = true
    sternPart.Anchored = false
    sternPart.Transparency = 1
    sternPart.Parent = model

    -- Keel section (underside)
    local keelPart = Instance.new("Part")
    keelPart.Name = "Hull_keel"
    keelPart.Size = Vector3.new(beam * 0.6, config.draft, length * 0.8)
    keelPart.CFrame = hull.CFrame * CFrame.new(0, -height * 0.4 - config.draft * 0.5, 0)
    keelPart.Color = Color3.fromRGB(60, 50, 40)
    keelPart.Material = Enum.Material.WoodPlanks
    keelPart.CanCollide = true
    keelPart.Anchored = false
    keelPart.Transparency = 1  -- below waterline, not very visible
    keelPart.Parent = model

    -- ──────────────────────────────────────────────────────────────
    -- WELD ALL HULL SECTIONS TO PRIMARY PART
    -- ──────────────────────────────────────────────────────────────

    for _, sectionPart in ipairs({bowPart, portPart, starPart, sternPart, keelPart}) do
        local weld = Instance.new("WeldConstraint")
        weld.Name = sectionPart.Name .. "_Weld"
        weld.Part0 = hull
        weld.Part1 = sectionPart
        weld.Parent = sectionPart
    end

    -- ──────────────────────────────────────────────────────────────
    -- DECK (visual top of hull)
    -- ──────────────────────────────────────────────────────────────

    local deck = Instance.new("Part")
    deck.Name = "Deck"
    deck.Size = Vector3.new(beam * 0.95, 0.5, length * 0.95)
    deck.CFrame = hull.CFrame * CFrame.new(0, height * 0.4, 0)
    deck.Color = Color3.fromRGB(100, 80, 55)
    deck.Material = Enum.Material.WoodPlanks
    deck.CanCollide = true
    deck.Anchored = false
    deck.TopSurface = Enum.SurfaceType.Wood
    deck.Parent = model

    local deckWeld = Instance.new("WeldConstraint")
    deckWeld.Part0 = hull
    deckWeld.Part1 = deck
    deckWeld.Parent = deck

    -- ──────────────────────────────────────────────────────────────
    -- SUPERSTRUCTURE (cabin/wheelhouse — scales with vessel size)
    -- ──────────────────────────────────────────────────────────────

    if config.era >= 2 then
        -- Cabin (mid-deck structure)
        local cabinSize = Vector3.new(beam * 0.7, height * 0.5, length * 0.3)
        local cabin = Instance.new("Part")
        cabin.Name = "Cabin"
        cabin.Size = cabinSize
        cabin.CFrame = hull.CFrame * CFrame.new(0, height * 0.65, -length * 0.15)
        cabin.Color = Color3.fromRGB(140, 120, 90)
        cabin.Material = Enum.Material.WoodPlanks
        cabin.CanCollide = true
        cabin.Anchored = false
        cabin.Parent = model

        local cabinWeld = Instance.new("WeldConstraint")
        cabinWeld.Part0 = hull
        cabinWeld.Part1 = cabin
        cabinWeld.Parent = cabin
    end

    if config.era >= 3 then
        -- Wheelhouse (on top of cabin)
        local wheelhouse = Instance.new("Part")
        wheelhouse.Name = "Wheelhouse"
        wheelhouse.Size = Vector3.new(beam * 0.5, height * 0.4, length * 0.2)
        wheelhouse.CFrame = hull.CFrame * CFrame.new(0, height * 1.0, -length * 0.15)
        wheelhouse.Color = Color3.fromRGB(160, 150, 130)
        wheelhouse.Material = Enum.Material.Glass
        wheelhouse.Transparency = 0.3
        wheelhouse.CanCollide = true
        wheelhouse.Anchored = false
        wheelhouse.Parent = model

        local wheelWeld = Instance.new("WeldConstraint")
        wheelWeld.Part0 = hull
        wheelWeld.Part1 = wheelhouse
        wheelWeld.Parent = wheelhouse
    end

    -- ──────────────────────────────────────────────────────────────
    -- HELM SEAT
    -- ──────────────────────────────────────────────────────────────

    local helmSeat = Instance.new("Seat")
    helmSeat.Name = "HelmSeat"
    helmSeat.Size = Vector3.new(2, 1, 2)
    helmSeat.CFrame = hull.CFrame * CFrame.new(config.helmOffset)
    helmSeat.Color = Color3.fromRGB(80, 60, 40)
    helmSeat.Material = Enum.Material.WoodPlanks
    helmSeat.CanCollide = true
    helmSeat.Anchored = false
    helmSeat.Parent = model

    local seatWeld = Instance.new("WeldConstraint")
    seatWeld.Part0 = hull
    seatWeld.Part1 = helmSeat
    seatWeld.Parent = helmSeat

    -- ──────────────────────────────────────────────────────────────
    -- MAST (for visual reference and storm vulnerability)
    -- ──────────────────────────────────────────────────────────────

    if config.era <= 3 then
        local mastHeight = height * 2.5
        local mast = Instance.new("Part")
        mast.Name = "Mast"
        mast.Size = Vector3.new(0.5, mastHeight, 0.5)
        mast.CFrame = hull.CFrame * CFrame.new(0, height * 0.5 + mastHeight * 0.5, 0)
        mast.Color = Color3.fromRGB(90, 70, 50)
        mast.Material = Enum.Material.Wood
        mast.CanCollide = false
        mast.Anchored = false
        mast.Parent = model

        local mastWeld = Instance.new("WeldConstraint")
        mastWeld.Part0 = hull
        mastWeld.Part1 = mast
        mastWeld.Parent = mast

        -- Tag for weather effects (wind on mast)
        CollectionService:AddTag(mast, "WeatherAffected")
    end

    -- ──────────────────────────────────────────────────────────────
    -- ERA-SPECIFIC ADDITIONS
    -- ──────────────────────────────────────────────────────────────

    if config.era >= 4 and config.craneConfig then
        -- Crane boom (Seine Boat and Factory Trawler)
        local craneBoom = Instance.new("Part")
        craneBoom.Name = "CraneBoom"
        craneBoom.Size = Vector3.new(1, 1, config.craneConfig.boomLength)
        craneBoom.CFrame = hull.CFrame * CFrame.new(0, height * 1.2, config.craneConfig.boomLength * 0.4)
        craneBoom.Color = Color3.fromRGB(180, 140, 40)
        craneBoom.Material = Enum.Material.Metal
        craneBoom.CanCollide = true
        craneBoom.Anchored = false
        craneBoom.Parent = model

        local craneWeld = Instance.new("WeldConstraint")
        craneWeld.Part0 = hull
        craneWeld.Part1 = craneBoom
        craneWeld.Parent = craneBoom
    end

    if config.era >= 5 and config.factoryConfig then
        -- Factory processing structure (large stern factory)
        local factory = Instance.new("Part")
        factory.Name = "FactoryDeck"
        factory.Size = Vector3.new(beam * 0.9, height * 0.8, length * 0.35)
        factory.CFrame = hull.CFrame * CFrame.new(0, height * 0.7, -length * 0.25)
        factory.Color = Color3.fromRGB(70, 75, 80)
        factory.Material = Enum.Material.CorrodedMetal
        factory.CanCollide = true
        factory.Anchored = false
        factory.Parent = model

        local factoryWeld = Instance.new("WeldConstraint")
        factoryWeld.Part0 = hull
        factoryWeld.Part1 = factory
        factoryWeld.Parent = factory
    end

    return model
end

----------------------------------------------------------------
-- COLLISION DETECTION (for damage)
----------------------------------------------------------------

--[[
    Set up Touched event monitoring for the vessel hull.
    Uses velocity comparison to determine impact speed.
    @param vesselModel Model
    @param vesselState table (from VesselPhysics)
    @param damageState table (from VesselDamage)
]]
local function setupCollisionMonitoring(vesselModel, vesselState, damageState)
    local primaryPart = vesselModel.PrimaryPart
    local lastVelocity = primaryPart.AssemblyLinearVelocity

    primaryPart.Touched:Connect(function(hitPart)
        if hitPart == primaryPart then return end
        if hitPart:IsDescendantOf(vesselModel) then return end

        -- Calculate impact speed (relative velocity at moment of contact)
        local currentVel = primaryPart.AssemblyLinearVelocity
        local hitVel = hitPart.AssemblyLinearVelocity or Vector3.zero
        local relVel = currentVel - hitVel
        local impactSpeed = relVel.Magnitude

        -- Only register significant impacts
        if impactSpeed < 5 then return end

        -- Calculate impact point and normal
        local impactPoint = primaryPart.Position
        local normalVec = (primaryPart.Position - hitPart.Position).Unit
        if normalVec.Magnitude ~= normalVec.Magnitude then  -- NaN check
            normalVec = Vector3.new(0, 0, 1)
        end

        -- Apply damage
        local VDamage = getVesselDamage()
        VDamage.applyCollisionDamage(damageState, impactSpeed, impactPoint, normalVec)

        -- Apply physical impulse to VesselPhysics
        local physics = getVesselPhysics()
        physics.applyImpact(vesselState, -relVel * primaryPart.AssemblyMass * 0.3, impactPoint)
    end)
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

--[[
    Spawn a vessel for a player at their era-appropriate slip.
    @param player Player
    @param eraNumber number (1-5)
    @return Model|nil spawned vessel model
]]
function VesselSpawner.spawnVessel(player, eraNumber)
    local types = getVesselTypes()
    local config = types.get(eraNumber)
    if not config then
        warn("[VesselSpawner] No vessel config for era " .. tostring(eraNumber))
        return nil
    end

    -- Check if this player already has this vessel
    local fleet = playerFleets[player.UserId]
    if not fleet then
        fleet = {}
        playerFleets[player.UserId] = fleet
    end

    if fleet[eraNumber] and fleet[eraNumber].Parent then
        warn(string.format("[VesselSpawner] %s already has a vessel for era %d", player.Name, eraNumber))
        return fleet[eraNumber]
    end

    -- Get spawn position
    local slipPos, heading = getSlipPosition(player.UserId, eraNumber)

    -- Build the vessel model
    local vesselModel = buildVesselModel(config, slipPos, heading)
    vesselModel.Name = string.format("%s_%s_Era%d", config.displayName, player.Name, eraNumber)
    vesselModel.Parent = getDockFolder()

    -- Set ownership attributes
    vesselModel:SetAttribute("OwnerPlayerId", player.UserId)
    vesselModel:SetAttribute("OwnerName", player.Name)
    vesselModel:SetAttribute("VesselEra", eraNumber)
    vesselModel:SetAttribute("VesselKey", config.key)
    vesselModel:SetAttribute("VesselDisplayName", config.displayName)
    vesselModel:SetAttribute("IsRetired", false)
    vesselModel:SetAttribute("SpawnedAt", os.time())

    -- Tag with CollectionService
    CollectionService:AddTag(vesselModel, "Vessel")
    CollectionService:AddTag(vesselModel, "Vessel_" .. tostring(player.UserId))
    CollectionService:AddTag(vesselModel, "Vessel_Era" .. tostring(eraNumber))

    -- Initialize physics
    local physics = getVesselPhysics()
    local vesselState = physics.init(vesselModel, config, tostring(player.UserId))

    -- Initialize damage system
    local damage = getVesselDamage()
    local damageState = damage.init(vesselModel, config, vesselState)

    -- Set up collision monitoring
    setupCollisionMonitoring(vesselModel, vesselState, damageState)

    -- Register for boarding (only active vessel, not retired ones)
    local helm = getHelmController()
    helm.registerBoardable(vesselModel, vesselState, player.UserId)

    -- Store in fleet
    fleet[eraNumber] = vesselModel
    fleet.activeEra = eraNumber

    print(string.format("[VesselSpawner] Spawned %s (Era %d) for %s at slip %d",
        config.displayName, eraNumber, player.Name, eraNumber))

    return vesselModel
end

--[[
    Retire a vessel (when player upgrades to a new era).
    The old vessel stays in the world but loses its boarding prompt.
    @param player Player
    @param eraNumber number
]]
function VesselSpawner.retireVessel(player, eraNumber)
    local fleet = playerFleets[player.UserId]
    if not fleet or not fleet[eraNumber] then return end

    local vesselModel = fleet[eraNumber]
    vesselModel:SetAttribute("IsRetired", true)

    -- Remove boarding prompt
    local helmSeat = vesselModel:FindFirstChild("HelmSeat", true)
    if helmSeat then
        local prompt = helmSeat:FindFirstChild("BoardPrompt")
        if prompt then prompt:Destroy() end
    end

    -- Remove "active" tags but keep ownership tags for history
    CollectionService:RemoveTag(vesselModel, "Vessel_Active")

    -- Anchor the retired vessel at its slip (it's parked permanently)
    local primaryPart = vesselModel.PrimaryPart
    if primaryPart then
        primaryPart.Anchored = true
    end

    print(string.format("[VesselSpawner] Retired %s for %s (still visible at dock)",
        vesselModel:GetAttribute("VesselDisplayName"), player.Name))
end

--[[
    Get all vessels a player owns.
    @param player Player
    @return table<int, Model>
]]
function VesselSpawner.getPlayerVessels(player)
    return playerFleets[player.UserId] or {}
end

--[[
    Get the player's currently active (non-retired) vessel.
    @param player Player
    @return Model|nil
]]
function VesselSpawner.getActiveVessel(player)
    local fleet = playerFleets[player.UserId]
    if not fleet then return nil end

    local era = fleet.activeEra
    if not era then return nil end

    local vessel = fleet[era]
    if vessel and vessel.Parent and not vessel:GetAttribute("IsRetired") then
        return vessel
    end

    return nil
end

--[[
    Get the dock origin position.
    @return Vector3
]]
function VesselSpawner.getDockOrigin()
    return PIER_ORIGIN
end

--[[
    Get a player's fleet info for UI/display.
    @param player Player
    @return table
]]
function VesselSpawner.getFleetInfo(player)
    local fleet = playerFleets[player.UserId]
    if not fleet then return {} end

    local info = {}
    for era = 1, 5 do
        local vessel = fleet[era]
        if vessel and vessel.Parent then
            table.insert(info, {
                era = era,
                displayName = vessel:GetAttribute("VesselDisplayName") or "Unknown",
                vesselKey = vessel:GetAttribute("VesselKey") or "unknown",
                isRetired = vessel:GetAttribute("IsRetired") or false,
                hullIntegrity = vessel:GetAttribute("HullIntegrity") or 1.0,
            })
        end
    end

    return info
end

----------------------------------------------------------------
-- INITIALIZATION
----------------------------------------------------------------

--[[
    Initialize the VesselSpawner system.
    Connects to EraSystem advancement events to auto-spawn new vessels.
    Call once on server start.
]]
function VesselSpawner.init()
    -- Watch for EraSystem building era advancements
    -- EraSystem fires via _G.EraSystem_BuildingEraAdvanced
    task.spawn(function()
        while true do
            if _G.EraSystem_BuildingEraAdvanced and #_G.EraSystem_BuildingEraAdvanced > 0 then
                local event = table.remove(_G.EraSystem_BuildingEraAdvanced, 1)
                local playerName = event.playerName
                local newEra = event.newEra

                local player = Players:FindFirstChild(playerName)
                if player and newEra <= 5 then
                    -- Retire old vessel if exists
                    local fleet = playerFleets[player.UserId]
                    if fleet and fleet.activeEra and fleet[fleet.activeEra] then
                        VesselSpawner.retireVessel(player, fleet.activeEra)
                    end

                    -- Spawn new vessel
                    task.wait(1)  -- brief delay for dramatic effect
                    VesselSpawner.spawnVessel(player, newEra)
                end
            end
            task.wait(0.5)
        end
    end)

    -- Listen for player joining to spawn their initial vessel (era 1)
    Players.PlayerAdded:Connect(function(player)
        task.wait(3)  -- wait for EraSystem to load player state

        local ok, EraSystem = pcall(function()
            return require(game.ServerScriptService.EraSystem)
        end)

        if ok and EraSystem then
            local buildingEra = EraSystem.getBuildingEra(player.Name)

            -- Spawn all vessels up to current era (so old ones are visible)
            for era = 1, buildingEra do
                if era < buildingEra then
                    -- Old vessel: spawn then immediately retire
                    VesselSpawner.spawnVessel(player, era)
                    VesselSpawner.retireVessel(player, era)
                else
                    -- Current vessel: spawn and keep active
                    VesselSpawner.spawnVessel(player, era)
                end
            end

            -- If this is their first time (era 1), always spawn the skiff
            if buildingEra == 1 and not playerFleets[player.UserId] then
                VesselSpawner.spawnVessel(player, 1)
            end
        else
            -- EraSystem not available: spawn era 1 by default
            VesselSpawner.spawnVessel(player, 1)
        end
    end)

    -- Clean up when player leaves (vessels stay in world but become dormant)
    Players.PlayerRemoving:Connect(function(player)
        local fleet = playerFleets[player.UserId]
        if not fleet then return end

        -- Vessels remain in the world for fleet history
        -- but we disembark if they were at the helm
        local ok, hc = pcall(function()
            return require(script.Parent:WaitForChild("HelmController"))
        end)
        if ok and hc.isPlayerAtHelm(player) then
            hc.disembark(player)
        end

        -- Don't destroy vessels — they persist in the world
    end)

    print("[VesselSpawner] Initialized — vessel spawn system ready")
end

return VesselSpawner
