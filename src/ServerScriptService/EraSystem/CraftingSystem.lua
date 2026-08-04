--!strict
--[[
    CraftingSystem — Slackwater's Crafting Table Interface
    =======================================================
    The player-facing system for crafting components from recipes.

    Two input modes:
        1. Menu mode — open crafting table, browse recipes, select, craft
        2. Voice mode — speak what you want (STT → recipe matching → craft)

    Physical assembly mode (optional):
        Player drags physical ingredients onto a workbench surface.
        System detects the combination and matches it to a recipe.

    Usage:
        local CraftingSystem = require(ServerScriptService.EraSystem.CraftingSystem)
        CraftingSystem.init()

        CraftingSystem.openTable(playerId)
        local success, result = CraftingSystem.craft(playerId, "generator")
        CraftingSystem.voiceCraft(playerId, "I want to make a lever")

    Dependencies:
        - ReplicatedStorage.Lucineer.Http
        - ServerScriptService.EraSystem (init.lua)
        - ServerScriptService.EraSystem.Recipes
]]

local Http = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("Http"))
local EraSystem = require(script.Parent)
local Recipes = require(script.Parent:WaitForChild("Recipes"))

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Bug 1 fix: MEMORY_URL removed. Http.post/get already prepends the configured
-- worker URL. Passing a full URL caused double-URL construction (404s).
-- Bug 2 fix: auth header (X-Lucineer-Key) is injected by Http.headers() on every call.

-- ═══════════════════════════════════════════════════════════════════════════
-- RUNTIME STATE
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → { [itemType] = amount }
local inventories = {}

-- playerName → bool (table open state)
local openTables = {}

-- RemoteEvents for client UI
local CraftRemote -- client → server: craft request
local CraftResponseRemote -- server → client: craft result
local CraftUIRemote -- server → client: open/close UI
local VoiceCraftRemote -- client → server: voice craft request

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

local initialized = false

local function setupRemotes()
    local Lucineer = ReplicatedStorage:WaitForChild("Lucineer")

    local function getOrCreate(name)
        local existing = Lucineer:FindFirstChild(name)
        if existing then return existing end
        local remote = Instance.new("RemoteEvent")
        remote.Name = name
        remote.Parent = Lucineer
        return remote
    end

    CraftRemote = getOrCreate("CraftRequestEvent")
    CraftResponseRemote = getOrCreate("CraftResponseEvent")
    CraftUIRemote = getOrCreate("CraftUIEvent")
    VoiceCraftRemote = getOrCreate("VoiceCraftEvent")
end

local function init()
    if initialized then return end
    initialized = true

    setupRemotes()

    -- Load inventory on join
    Players.PlayerAdded:Connect(function(player)
        CraftingSystem.loadInventory(player.Name)
    end)

    -- Save inventory on leave
    Players.PlayerRemoving:Connect(function(player)
        CraftingSystem.saveInventory(player.Name)
        openTables[player.Name] = nil
    end)

    -- Handle craft requests from client
    CraftRemote.OnServerEvent:Connect(function(player, data)
        if type(data) ~= "table" then return end
        if data.action == "craft" and data.recipeId then
            CraftingSystem.craft(player.Name, data.recipeId)
        elseif data.action == "open" then
            CraftingSystem.openTable(player.Name)
        elseif data.action == "close" then
            CraftingSystem.closeTable(player.Name)
        elseif data.action == "addIngredient" then
            CraftingSystem.addIngredient(player.Name, data.itemType, data.amount or 1)
        end
    end)

    -- Handle voice craft requests
    VoiceCraftRemote.OnServerEvent:Connect(function(player, data)
        if type(data) == "table" and data.text then
            CraftingSystem.voiceCraft(player.Name, data.text)
        end
    end)

    print("[CraftingSystem] Initialized — " .. Recipes.count() .. " recipes loaded")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INVENTORY MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

local function getInventory(playerName)
    if not inventories[playerName] then
        inventories[playerName] = {}
    end
    return inventories[playerName]
end

-- Load inventory from D1
function CraftingSystem.loadInventory(playerName)
    local success, result = pcall(function()
        -- Bug 1 fix: path only — Http.post prepends worker URL automatically.
        return Http.post("/api/inventory/load", {
            playerName = playerName,
        })
    end)

    if success and result and result.items then
        inventories[playerName] = result.items
    else
        -- Default starting inventory
        inventories[playerName] = {
            wood = 10,
            stone = 5,
            rope = 3,
        }
    end
end

-- Save inventory to D1
function CraftingSystem.saveInventory(playerName)
    local inv = inventories[playerName]
    if not inv then return end

    pcall(function()
        -- Bug 1 fix: path only — no MEMORY_URL prefix.
        Http.post("/api/inventory/save", {
            playerName = playerName,
            items = inv,
        })
    end)
end

-- Add an ingredient/item to inventory
function CraftingSystem.addIngredient(playerName, itemType, amount)
    amount = amount or 1
    local inv = getInventory(playerName)
    inv[itemType] = (inv[itemType] or 0) + amount
end

-- Remove items from inventory (returns true if successful)
local function removeIngredients(playerName, ingredients)
    local inv = getInventory(playerName)

    -- First pass: verify all ingredients are available
    for itemType, amount in pairs(ingredients) do
        if (inv[itemType] or 0) < amount then
            return false
        end
    end

    -- Second pass: deduct
    for itemType, amount in pairs(ingredients) do
        inv[itemType] = inv[itemType] - amount
        if inv[itemType] <= 0 then
            inv[itemType] = nil
        end
    end

    return true
end

-- Get current inventory for a player
function CraftingSystem.getInventory(playerName)
    return getInventory(playerName)
end

-- Check if player has enough of a specific item
function CraftingSystem.hasItem(playerName, itemType, amount)
    amount = amount or 1
    local inv = getInventory(playerName)
    return (inv[itemType] or 0) >= amount
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CRAFTING TABLE INTERFACE
-- ═══════════════════════════════════════════════════════════════════════════

-- Open the crafting table for a player
function CraftingSystem.openTable(playerName)
    local player = Players:FindFirstChild(playerName)
    if not player then return end

    openTables[playerName] = true

    local available = CraftingSystem.getAvailableCrafts(playerName)
    local inv = getInventory(playerName)

    CraftUIRemote:FireClient(player, {
        action = "open",
        recipes = available,
        inventory = inv,
        currentEra = EraSystem.getCurrentEra(playerName),
    })

    print(string.format("[CraftingSystem] %s opened crafting table — %d recipes available",
        playerName, #available))
end

-- Close the crafting table
function CraftingSystem.closeTable(playerName)
    local player = Players:FindFirstChild(playerName)
    if not player then return end

    openTables[playerName] = nil
    CraftUIRemote:FireClient(player, {
        action = "close",
    })
end

-- Check if table is open
function CraftingSystem.isTableOpen(playerName)
    return openTables[playerName] == true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RECIPE FILTERING & CRAFTING
-- ═══════════════════════════════════════════════════════════════════════════

-- Get all crafts available to a player (era-gated + has ingredients)
function CraftingSystem.getAvailableCrafts(playerName)
    local eraRecipes = EraSystem.getAvailableRecipes(playerName)
    local inv = getInventory(playerName)

    local available = {}
    local locked = {}

    for _, recipe in ipairs(eraRecipes) do
        local canCraft = true
        local missing = {}

        for itemType, amount in pairs(recipe.ingredients) do
            if (inv[itemType] or 0) < amount then
                canCraft = false
                missing[itemType] = amount - (inv[itemType] or 0)
            end
        end

        local entry = {
            id = recipe.id,
            name = recipe.name,
            era = recipe.era,
            category = recipe.category,
            description = recipe.description,
            ingredients = recipe.ingredients,
            canCraft = canCraft,
            missing = canCraft and nil or missing,
            agentTip = recipe.agentTip,
        }

        if canCraft then
            table.insert(available, entry)
        else
            table.insert(locked, entry)
        end
    end

    -- Sort: available first (by era), then locked (by era)
    table.sort(available, function(a, b) return a.era < b.era end)
    table.sort(locked, function(a, b) return a.era < b.era end)

    -- Combine: available first, then locked
    local result = {}
    for _, e in ipairs(available) do table.insert(result, e) end
    for _, e in ipairs(locked) do table.insert(result, e) end

    return result
end

-- Attempt to craft an item
function CraftingSystem.craft(playerName, recipeId)
    local player = Players:FindFirstChild(playerName)

    local recipe = Recipes.get(recipeId)
    if not recipe then
        if player then
            CraftResponseRemote:FireClient(player, {
                success = false,
                error = "Unknown recipe: " .. tostring(recipeId),
            })
        end
        return false, { error = "unknown_recipe" }
    end

    -- Check era unlock
    if not EraSystem.canBuild(playerName, recipe.output.componentType) then
        local era = EraSystem.getCurrentEra(playerName)
        if player then
            CraftResponseRemote:FireClient(player, {
                success = false,
                error = string.format("This requires Era %d (%s). Current era: %d.",
                    recipe.era, EraSystem.getEraInfo(recipe.era).name, era),
            })
        end
        return false, { error = "era_locked", requiredEra = recipe.era }
    end

    -- Check ingredients
    local inv = getInventory(playerName)
    for itemType, amount in pairs(recipe.ingredients) do
        if (inv[itemType] or 0) < amount then
            if player then
                CraftResponseRemote:FireClient(player, {
                    success = false,
                    error = string.format("Not enough %s (need %d, have %d)",
                        itemType, amount, inv[itemType] or 0),
                })
            end
            return false, { error = "missing_ingredients", missing = itemType }
        end
    end

    -- Deduct ingredients
    removeIngredients(playerName, recipe.ingredients)

    -- Add output to inventory
    local outputType = recipe.output.componentType
    local outputAmount = recipe.output.amount or 1
    CraftingSystem.addIngredient(playerName, outputType, outputAmount)

    -- Record the craft
    pcall(function()
        -- Bug 1 fix: path only — no MEMORY_URL prefix.
        Http.post("/api/crafts/record", {
            playerName = playerName,
            recipeId = recipeId,
        })
    end)

    -- Notify era system (for unlock triggers)
    EraSystem.onBuild(playerName, outputType)

    -- Send success response to client
    if player then
        CraftResponseRemote:FireClient(player, {
            success = true,
            recipe = recipe,
            output = {
                type = outputType,
                amount = outputAmount,
            },
            inventory = getInventory(playerName),
            agentTip = recipe.agentTip,
        })
    end

    print(string.format("[CraftingSystem] %s crafted %s (%s)", playerName, recipe.name, recipeId))
    return true, { recipe = recipe, output = outputType }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- VOICE CRAFTING (STT Integration)
-- ═══════════════════════════════════════════════════════════════════════════

-- Keyword → recipe ID mapping for fast voice matching
local VOICE_KEYWORDS = {
    -- Era 0
    ["lever"] = "lever", ["pulley"] = "pulley", ["wheel"] = "wheel",
    ["wedge"] = "wedge", ["screw"] = "screw", ["ramp"] = "inclined_plane",
    ["inclined plane"] = "inclined_plane", ["water wheel"] = "waterwheel",
    ["waterwheel"] = "waterwheel", ["windmill"] = "windmill", ["wind mill"] = "windmill",
    ["trip hammer"] = "trip_hammer", ["hammer"] = "trip_hammer",
    ["bellows"] = "bellows", ["ladder"] = "ladder", ["gear"] = "wooden_gear",
    ["wooden gear"] = "wooden_gear", ["cam"] = "cam", ["crank"] = "crank",
    -- Era 1
    ["shaft"] = "driveshaft", ["drive shaft"] = "driveshaft", ["driveshaft"] = "driveshaft",
    ["belt"] = "belt_drive", ["belt drive"] = "belt_drive",
    ["chain"] = "chain_drive", ["chain drive"] = "chain_drive",
    ["gearbox"] = "gearbox", ["gear box"] = "gearbox", ["gear box"] = "gearbox",
    ["worm gear"] = "worm_gear", ["piston"] = "piston", ["flywheel"] = "flywheel",
    ["fly wheel"] = "flywheel", ["pipe"] = "pipe", ["valve"] = "valve",
    ["pressure gauge"] = "pressure_gauge", ["coupling"] = "coupling",
    ["clutch"] = "clutch", ["differential"] = "differential",
    ["escapement"] = "escapement", ["manometer"] = "manometer",
    -- Era 2
    ["generator"] = "generator", ["wire"] = "wire", ["copper wire"] = "wire",
    ["switch"] = "switch", ["lamp"] = "lamp", ["light"] = "lamp",
    ["lightbulb"] = "lamp", ["motor"] = "motor", ["electric motor"] = "motor",
    ["heater"] = "heating_element", ["heating element"] = "heating_element",
    ["electromagnet"] = "electromagnet", ["transformer"] = "transformer",
    ["battery"] = "battery", ["fuse"] = "fuse", ["breaker"] = "circuit_breaker",
    ["circuit breaker"] = "circuit_breaker", ["buzzer"] = "buzzer",
    ["solenoid"] = "solenoid", ["relay"] = "simple_relay",
    ["capacitor"] = "capacitor", ["cap"] = "capacitor",
    -- Era 3
    ["and gate"] = "logic_gate_and", ["or gate"] = "logic_gate_or",
    ["not gate"] = "logic_gate_not", ["inverter"] = "logic_gate_not",
    ["timer"] = "timer_circuit", ["timer circuit"] = "timer_circuit",
    ["light sensor"] = "light_sensor", ["proximity sensor"] = "proximity_sensor",
    ["temperature sensor"] = "temperature_sensor", ["temp sensor"] = "temperature_sensor",
    ["pressure switch"] = "pressure_switch", ["remote"] = "remote_trigger",
    ["remote trigger"] = "remote_trigger", ["counter"] = "counter",
    ["flip flop"] = "flip_flop", ["flip-flop"] = "flip_flop",
    ["multiplexer"] = "multiplexer", ["mux"] = "multiplexer",
    ["decoder"] = "decoder", ["adc"] = "adc", ["dac"] = "dac",
    -- Era 4
    ["arduino"] = "arduino_board", ["arduino board"] = "arduino_board",
    ["breadboard"] = "breadboard", ["bread board"] = "breadboard",
    ["led"] = "led_module", ["led module"] = "led_module",
    ["servo"] = "servo_module", ["servo module"] = "servo_module",
    ["ultrasonic"] = "ultrasonic_sensor", ["ultrasonic sensor"] = "ultrasonic_sensor",
    ["distance sensor"] = "ultrasonic_sensor", ["pir"] = "pir_sensor",
    ["motion sensor"] = "pir_sensor", ["pir sensor"] = "pir_sensor",
    ["lcd"] = "lcd_display", ["display"] = "lcd_display", ["screen"] = "lcd_display",
    ["keypad"] = "keypad", ["stepper"] = "stepper_driver",
    ["stepper driver"] = "stepper_driver", ["relay module"] = "relay_module",
    ["esp8266"] = "esp8266", ["esp32"] = "esp32", ["rtc"] = "rtc_module",
    ["real time clock"] = "rtc_module", ["sd card"] = "sd_card_module",
    ["xbee"] = "xbee_radio", ["radio"] = "xbee_radio",
    -- Era 5
    ["wireless"] = "wireless_module", ["wireless module"] = "wireless_module",
    ["mesh"] = "mesh_node", ["mesh node"] = "mesh_node",
    ["bridge"] = "protocol_bridge", ["protocol bridge"] = "protocol_bridge",
    ["logger"] = "data_logger", ["data logger"] = "data_logger",
    ["gateway"] = "cloud_gateway", ["cloud gateway"] = "cloud_gateway",
    ["broker"] = "mqtt_broker", ["mqtt"] = "mqtt_broker", ["mqtt broker"] = "mqtt_broker",
    ["sniffer"] = "packet_sniffer", ["packet sniffer"] = "packet_sniffer",
    ["antenna"] = "antenna_array", ["antenna array"] = "antenna_array",
    ["repeater"] = "signal_repeater", ["signal repeater"] = "signal_repeater",
    ["hub"] = "network_hub", ["network hub"] = "network_hub",
    ["routing table"] = "routing_table", ["encryption"] = "encryption_module",
    ["ota"] = "ota_updater", ["updater"] = "ota_updater",
    ["dashboard"] = "dashboard_screen", ["pipeline"] = "data_pipeline",
    -- Era 6
    ["agent core"] = "agent_core", ["core"] = "agent_core",
    ["fleet beacon"] = "fleet_beacon", ["beacon"] = "fleet_beacon",
    ["scheduler"] = "task_scheduler", ["task scheduler"] = "task_scheduler",
    ["miner"] = "autonomous_miner", ["autonomous miner"] = "autonomous_miner",
    ["builder"] = "autonomous_builder", ["autonomous builder"] = "autonomous_builder",
    ["scout"] = "autonomous_scout", ["autonomous scout"] = "autonomous_scout",
    ["console"] = "orchestrator_console", ["orchestrator console"] = "orchestrator_console",
    ["skill library"] = "skill_library", ["library"] = "skill_library",
    ["coordination"] = "coordination_matrix", ["coordination matrix"] = "coordination_matrix",
    ["allocator"] = "resource_allocator", ["resource allocator"] = "resource_allocator",
    ["repair"] = "self_repair_module", ["self repair"] = "self_repair_module",
    ["swarm"] = "swarm_controller", ["swarm controller"] = "swarm_controller",
    ["priority queue"] = "priority_queue",
    ["communicator"] = "agent_communicator",
    ["decision engine"] = "decision_engine",
}

-- Match spoken text to a recipe
local function matchRecipeFromText(text)
    if not text or text == "" then return nil end
    local lower = string.lower(text)

    -- Direct keyword match (longest first for specificity)
    local sortedKeys = {}
    for keyword in pairs(VOICE_KEYWORDS) do
        table.insert(sortedKeys, keyword)
    end
    table.sort(sortedKeys, function(a, b) return #a > #b end)

    for _, keyword in ipairs(sortedKeys) do
        if string.find(lower, keyword, 1, true) then
            local recipeId = VOICE_KEYWORDS[keyword]
            return recipeId, Recipes.get(recipeId)
        end
    end

    -- Fall back to recipe name search
    local results = Recipes.search(lower)
    if #results > 0 then
        return results[1].id, results[1]
    end

    return nil
end

-- Voice craft entry point (called from STT pipeline)
function CraftingSystem.voiceCraft(playerName, spokenText)
    local player = Players:FindFirstChild(playerName)
    if not player then return end

    print(string.format("[CraftingSystem] %s voice craft: \"%s\"", playerName, spokenText))

    local recipeId, recipe = matchRecipeFromText(spokenText)

    if not recipeId then
        -- No match found — send suggestions based on available recipes
        local suggestions = EraSystem.getAvailableRecipes(playerName)
        local names = {}
        for i = 1, math.min(5, #suggestions) do
            table.insert(names, suggestions[i].name)
        end

        CraftResponseRemote:FireClient(player, {
            success = false,
            error = "I couldn't find a recipe for that.",
            suggestions = names,
            voiceCraft = true,
        })
        return false, { error = "no_match" }
    end

    -- Check if player has the era unlocked
    if not EraSystem.canBuild(playerName, recipe.output.componentType) then
        local era = EraSystem.getCurrentEra(playerName)
        CraftResponseRemote:FireClient(player, {
            success = false,
            error = string.format("The %s requires Era %d (%s). You're in Era %d.",
                recipe.name, recipe.era, EraSystem.getEraInfo(recipe.era).name, era),
            voiceCraft = true,
        })
        return false, { error = "era_locked" }
    end

    -- Attempt the craft
    local success, result = CraftingSystem.craft(playerName, recipeId)

    -- Tag the response as voice-originated
    if player then
        -- The craft() function already sends a response, but we send an additional
        -- voice-specific acknowledgment with the agent tip
        if success then
            CraftResponseRemote:FireClient(player, {
                success = true,
                voiceCraft = true,
                message = string.format("Crafted: %s", recipe.name),
                agentTip = recipe.agentTip,
                techNote = recipe.techNote,
            })
        end
    end

    return success, result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PHYSICAL ASSEMBLY (Workbench mode)
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → { [itemType] = amount } items placed on workbench
local workbenchItems = {}

-- Add item to workbench surface (physical assembly mode)
function CraftingSystem.addToWorkbench(playerName, itemType, amount)
    amount = amount or 1
    if not workbenchItems[playerName] then
        workbenchItems[playerName] = {}
    end
    workbenchItems[playerName][itemType] = (workbenchItems[playerName][itemType] or 0) + amount
end

-- Clear workbench
function CraftingSystem.clearWorkbench(playerName)
    workbenchItems[playerName] = nil
end

-- Get workbench contents
function CraftingSystem.getWorkbench(playerName)
    return workbenchItems[playerName] or {}
end

-- Try to match workbench contents to a recipe
function CraftingSystem.tryAssemble(playerName)
    local bench = workbenchItems[playerName]
    if not bench then return false, { error = "empty_workbench" } end

    local availableRecipes = EraSystem.getAvailableRecipes(playerName)

    for _, recipe in ipairs(availableRecipes) do
        local matches = true
        for itemType, amount in pairs(recipe.ingredients) do
            if (bench[itemType] or 0) < amount then
                matches = false
                break
            end
        end

        if matches then
            -- Consume workbench items
            for itemType, amount in pairs(recipe.ingredients) do
                bench[itemType] = bench[itemType] - amount
                if bench[itemType] <= 0 then
                    bench[itemType] = nil
                end
            end

            -- Add output to inventory
            local outputType = recipe.output.componentType
            local outputAmount = recipe.output.amount or 1
            CraftingSystem.addIngredient(playerName, outputType, outputAmount)

            -- Notify era system
            EraSystem.onBuild(playerName, outputType)

            -- Clear empty workbench
            local hasLeftovers = false
            for _ in pairs(bench) do
                hasLeftovers = true
                break
            end
            if not hasLeftovers then
                workbenchItems[playerName] = nil
            end

            local player = Players:FindFirstChild(playerName)
            if player then
                CraftResponseRemote:FireClient(player, {
                    success = true,
                    recipe = recipe,
                    output = { type = outputType, amount = outputAmount },
                    inventory = getInventory(playerName),
                    workbench = workbenchItems[playerName] or {},
                    assembled = true,
                })
            end

            print(string.format("[CraftingSystem] %s assembled %s on workbench", playerName, recipe.name))
            return true, { recipe = recipe, output = outputType }
        end
    end

    return false, { error = "no_matching_recipe" }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STATS & REPORTING
-- ═══════════════════════════════════════════════════════════════════════════

-- Get crafting stats for a player
function CraftingSystem.getStats(playerName)
    local inv = getInventory(playerName)
    local itemCount = 0
    for _ in pairs(inv) do
        itemCount = itemCount + 1
    end

    return {
        inventorySlots = itemCount,
        currentEra = EraSystem.getCurrentEra(playerName),
        availableRecipes = #CraftingSystem.getAvailableCrafts(playerName),
        totalRecipes = Recipes.count(),
    }
end

-- Initialize module
CraftingSystem.init = init

print("[CraftingSystem] Module loaded — " .. Recipes.count() .. " recipes ready")

return CraftingSystem
