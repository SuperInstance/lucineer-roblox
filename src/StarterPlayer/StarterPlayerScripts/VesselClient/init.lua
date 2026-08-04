--[[
    VesselClient/init.lua
    Slackwater — Client-Side Vessel Experience Bootstrap

    "You don't just see the boat. You feel it. The creak, the lean,
     the way the wheel answers back. This is where the player becomes
     the captain — or realizes they never were one."

    ───────────────────────────────────────────────
    This is a LocalScript entry point placed in StarterPlayerScripts.
    It bootstraps all vessel-related client UI:

      1. HelmUI       — throttle, rudder, compass, depth, speed
      2. FishingUI    — tension minigame, catch preview, results
      3. ChartUI      — nautical chart overlay (toggle with C)
      4. CargoUI      — cargo/inventory panel (toggle with I)
      5. VesselStateUI — hull integrity, sections, fuel, crew

    The bootstrap watches player attributes set by HelmController:
      AtHelm, VesselSpeed, VesselHeading, VesselThrottle, VesselRudder,
      AnchorSet, VesselWarning, HullIntegrity, SpeedZone

    And toggles UI panels accordingly. All UI is created programmatically
    — no pre-built ScreenGui required. Matches the UIManager aesthetic:
    brass-rimmed gauges, worn metal textures, hand-built fishing village.

    MODULE DEPENDENCIES:
      Lucineer/Config (ReplicatedStorage)
      Lucineer/UIManager (ReplicatedStorage) — for ScreenGui parent + aesthetic

    INPUT MAP (when at helm):
      W/S       — throttle up/down
      A/D       — rudder left/right
      Space     — anchor toggle
      Q         — horn
      E         — deploy/retrieve fishing gear
      C         — toggle chart
      I         — toggle cargo
      X         — emergency stop (HelmController handles server-side)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- Wait for Lucineer modules
local Lucineer = ReplicatedStorage:WaitForChild("Lucineer")
local Config = require(Lucineer:WaitForChild("Config"))

-- ─── AESTHETIC PALETTE ──────────────────────────────────
-- Maritime hand-built: brass, worn copper, salt-stained wood, canvas.
local PALETTE = {
    brass       = Color3.fromRGB(184, 148, 76),
    brassDark   = Color3.fromRGB(120, 96, 48),
    copper      = Color3.fromRGB(148, 84, 52),
    wood        = Color3.fromRGB(90, 66, 42),
    woodDark    = Color3.fromRGB(54, 38, 24),
    woodLight   = Color3.fromRGB(130, 98, 62),
    canvas      = Color3.fromRGB(200, 188, 156),
    iron        = Color3.fromRGB(72, 72, 78),
    ironRust    = Color3.fromRGB(128, 68, 42),
    glass       = Color3.fromRGB(180, 200, 215),
    redWarn     = Color3.fromRGB(220, 60, 40),
    greenOk     = Color3.fromRGB(80, 200, 100),
    amber       = Color3.fromRGB(240, 180, 60),
    ink         = Color3.fromRGB(28, 22, 16),
    parchment   = Color3.fromRGB(225, 215, 185),
    -- Depth alarm colors
    depthSafe   = Color3.fromRGB(60, 180, 100),
    depthWarn   = Color3.fromRGB(240, 180, 60),
    depthDanger = Color3.fromRGB(220, 60, 40),
}

-- Expose palette to child modules via a shared table
local VesselClient = {
    palette = PALETTE,
    player = player,
    screenGui = nil :: ScreenGui?,
    modules = {},
}

-- ─── SCREEN GUI ─────────────────────────────────────────
local function createVesselScreenGui(): ScreenGui
    local playerGui = player:WaitForChild("PlayerGui")

    local gui = Instance.new("ScreenGui")
    gui.Name = "VesselUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 10  -- above LucineerUI (default 0)
    gui.Parent = playerGui

    return gui
end

-- ─── MODULE LOADING ─────────────────────────────────────

local function loadModules(gui: ScreenGui)
    local scriptParent = script

    local HelmUI = require(scriptParent:WaitForChild("HelmUI"))
    local FishingUI = require(scriptParent:WaitForChild("FishingUI"))
    local ChartUI = require(scriptParent:WaitForChild("ChartUI"))
    local CargoUI = require(scriptParent:WaitForChild("CargoUI"))
    local VesselStateUI = require(scriptParent:WaitForChild("VesselStateUI"))

    VesselClient.modules.HelmUI = HelmUI
    VesselClient.modules.FishingUI = FishingUI
    VesselClient.modules.ChartUI = ChartUI
    VesselClient.modules.CargoUI = CargoUI
    VesselClient.modules.VesselStateUI = VesselStateUI

    -- Initialize each module with shared context
    local ctx = {
        player = player,
        gui = gui,
        palette = PALETTE,
        config = Config,
    }

    HelmUI.init(ctx)
    FishingUI.init(ctx)
    ChartUI.init(ctx)
    CargoUI.init(ctx)
    VesselStateUI.init(ctx)
end

-- ─── ATTRIBUTE WATCHER ──────────────────────────────────
-- Watches player attributes set by HelmController and toggles UI.

local wasAtHelm = false

local function watchAttributes()
    RunService.Heartbeat:Connect(function()
        local atHelm = player:GetAttribute("AtHelm") == true

        -- Boarding transition
        if atHelm and not wasAtHelm then
            wasAtHelm = true
            if VesselClient.modules.HelmUI then
                VesselClient.modules.HelmUI.show()
            end
            if VesselClient.modules.VesselStateUI then
                VesselClient.modules.VesselStateUI.show()
            end
        elseif not atHelm and wasAtHelm then
            wasAtHelm = false
            if VesselClient.modules.HelmUI then
                VesselClient.modules.HelmUI.hide()
            end
            if VesselClient.modules.FishingUI then
                VesselClient.modules.FishingUI.hide()
            end
            -- Chart and Cargo can stay toggleable even off-helm,
            -- but hide them on disembark for cleanliness
            if VesselClient.modules.ChartUI then
                VesselClient.modules.ChartUI.hide()
            end
            if VesselClient.modules.CargoUI then
                VesselClient.modules.CargoUI.hide()
            end
            if VesselClient.modules.VesselStateUI then
                VesselClient.modules.VesselStateUI.hide()
            end
        end
    end)
end

-- ─── INPUT HANDLING (client-only toggles) ───────────────

local function connectInput()
    local chartVisible = false
    local cargoVisible = false

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end

        -- C = toggle chart (only when at helm or on a vessel)
        if input.KeyCode == Enum.KeyCode.C and wasAtHelm then
            chartVisible = not chartVisible
            if VesselClient.modules.ChartUI then
                if chartVisible then
                    VesselClient.modules.ChartUI.show()
                else
                    VesselClient.modules.ChartUI.hide()
                end
            end

        -- I = toggle cargo
        elseif input.KeyCode == Enum.KeyCode.I and wasAtHelm then
            cargoVisible = not cargoVisible
            if VesselClient.modules.CargoUI then
                if cargoVisible then
                    VesselClient.modules.CargoUI.show()
                else
                    VesselClient.modules.CargoUI.hide()
                end
            end

        -- Space = anchor toggle (forward to HelmUI for visual feedback)
        elseif input.KeyCode == Enum.KeyCode.Space and wasAtHelm then
            if VesselClient.modules.HelmUI then
                VesselClient.modules.HelmUI.flashAnchor()
            end

        -- Q = horn
        elseif input.KeyCode == Enum.KeyCode.Q and wasAtHelm then
            if VesselClient.modules.HelmUI then
                VesselClient.modules.HelmUI.flashHorn()
            end

        -- E = fishing gear toggle
        elseif input.KeyCode == Enum.KeyCode.E and wasAtHelm then
            if VesselClient.modules.FishingUI then
                VesselClient.modules.FishingUI.toggle()
            end
        end
    end)
end

-- ─── INITIALIZATION ─────────────────────────────────────

print("[VesselClient] Booting vessel client UI...")

VesselClient.screenGui = createVesselScreenGui()
loadModules(VesselClient.screenGui)
watchAttributes()
connectInput()

print("[VesselClient] ✅ Vessel client ready — UI initialized, attribute watcher active")

-- Export for sibling modules that need cross-references
return VesselClient
