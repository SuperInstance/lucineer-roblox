--!strict
--[[
    Currency — Multi-Currency Tracking & Persistence
    ================================================
    Slackwater's three-tier economy:

    SCRAP (soft currency)
        Earned: selling fish, completing missions, salvage
        Spent:  gear, fuel, repairs, vessel upgrades, build materials
        The lifeblood. Everything costs scrap. Everything earns scrap.

    MATERIALS (commodity currencies)
        Wood, Metal, Cloth, Glass, Copper, Stone
        Sources: bycatch while fishing, tide pool foraging,
                 trade with NPCs, mission rewards, salvage
        Spent:  construction (via BuildCosts), vessel upgrades
        Each material has different availability by era and region.

    INFLUENCE (meta-progression currency)
        Earned: NPC missions, bond advancement, era ceremonies
        Spent:  unlocks build templates, vessel plans, special missions
        Not grindable — earned through meaningful actions only.

    All balances are per-player, persisted via D1/SaveSystem.
    Every transaction is validated and logged.

    Dependencies:
        - ReplicatedStorage.Lucineer.Http (for D1 persistence)
]]

local Http = require(game:GetService("ReplicatedStorage"):WaitForChild("Lucineer"):WaitForChild("Http"))
local Players = game:GetService("Players")

-- Uses Http module (already configured with WORKER_URL and AUTH_KEY by LucineerServer/init.lua)
-- No hardcoded MEMORY_URL — that was Bug #1 pattern, already fixed for other modules

-- ═══════════════════════════════════════════════════════════════════════════
-- CURRENCY DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Material types (commodities)
local MATERIAL_TYPES = {
    "wood",
    "metal",
    "cloth",
    "glass",
    "copper",
    "stone",
}

-- Default starting balances
local STARTING_BALANCES = {
    scrap = 50,         -- enough for a small build or basic gear
    materials = {
        wood = 10,
        metal = 2,
        cloth = 3,
        glass = 0,
        copper = 0,
        stone = 5,
    },
    influence = 0,
}

-- Transaction log limit per player (keep recent history for debugging)
local MAX_LOG_ENTRIES = 50

-- ═══════════════════════════════════════════════════════════════════════════
-- RUNTIME STATE
-- ═══════════════════════════════════════════════════════════════════════════

-- playerName → wallet
-- {
--   scrap = number,
--   materials = { wood=N, metal=N, cloth=N, glass=N, copper=N, stone=N },
--   influence = number,
--   totalScrapEarned = number,     -- lifetime (for achievements/stats)
--   totalScrapSpent = number,
--   transactionLog = { {type, currency, amount, reason, timestamp}, ... },
-- }
local wallets: { [string]: { [string]: any } } = {}

local initialized = false

-- ═══════════════════════════════════════════════════════════════════════════
-- INTERNAL HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get or create a wallet for a player.
    @param playerName string
    @return table
]]
local function getWallet(playerName: string): { [string]: any }
    if not wallets[playerName] then
        wallets[playerName] = {
            scrap = STARTING_BALANCES.scrap,
            materials = {
                wood = STARTING_BALANCES.materials.wood,
                metal = STARTING_BALANCES.materials.metal,
                cloth = STARTING_BALANCES.materials.cloth,
                glass = STARTING_BALANCES.materials.glass,
                copper = STARTING_BALANCES.materials.copper,
                stone = STARTING_BALANCES.materials.stone,
            },
            influence = STARTING_BALANCES.influence,
            totalScrapEarned = 0,
            totalScrapSpent = 0,
            transactionLog = {},
        }
    end

    -- Ensure materials table exists (migration safety)
    if not wallets[playerName].materials then
        wallets[playerName].materials = {}
        for _, mat in ipairs(MATERIAL_TYPES) do
            wallets[playerName].materials[mat] = STARTING_BALANCES.materials[mat] or 0
        end
    end

    -- Ensure all material keys exist
    for _, mat in ipairs(MATERIAL_TYPES) do
        if wallets[playerName].materials[mat] == nil then
            wallets[playerName].materials[mat] = 0
        end
    end

    return wallets[playerName]
end

--[[
    Log a transaction in the player's history.
    @param playerName string
    @param txType string — "earn" or "spend"
    @param currency string — "scrap", "wood", "influence", etc.
    @param amount number
    @param reason string? — what caused this transaction
]]
local function logTransaction(playerName: string, txType: string, currency: string, amount: number, reason: string?)
    local wallet = getWallet(playerName)
    local log = wallet.transactionLog

    table.insert(log, 1, {
        type = txType,
        currency = currency,
        amount = amount,
        reason = reason or "unspecified",
        timestamp = os.time(),
    })

    while #log > MAX_LOG_ENTRIES do
        table.remove(log, #log)
    end
end

--[[
    Persist wallet to D1 via the memory worker.
    Fire-and-forget.
    @param playerName string
]]
local function persistWallet(playerName: string)
    task.spawn(function()
        local wallet = wallets[playerName]
        if not wallet then return end

        local _, err = Http.post("/api/economy/wallet", {
            player_name = playerName,
            scrap = wallet.scrap,
            materials = wallet.materials,
            influence = wallet.influence,
            total_scrap_earned = wallet.totalScrapEarned,
            total_scrap_spent = wallet.totalScrapSpent,
        })

        if err then
            warn(string.format("[Currency] Failed to persist wallet for %s: %s",
                playerName, err))
        end
    end)
end

--[[
    Load wallet from D1 on player join.
    @param playerName string
]]
local function loadWallet(playerName: string)
    task.spawn(function()
        local response, err = Http.get("/api/economy/wallet/" .. playerName)

        if not err and response then
            local dataOk, data = pcall(Http.decode, response)
            if dataOk and data and not data.error then
                local wallet = getWallet(playerName)
                wallet.scrap = tonumber(data.scrap) or wallet.scrap
                wallet.influence = tonumber(data.influence) or wallet.influence
                wallet.totalScrapEarned = tonumber(data.total_scrap_earned) or 0
                wallet.totalScrapSpent = tonumber(data.total_scrap_spent) or 0

                -- Restore materials
                if data.materials then
                    for _, mat in ipairs(MATERIAL_TYPES) do
                        wallet.materials[mat] = tonumber(data.materials[mat]) or wallet.materials[mat]
                    end
                end

                print(string.format("[Currency] %s loaded: %d scrap, %d influence",
                    playerName, wallet.scrap, wallet.influence))
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

local Currency = {}

--[[
    Initialize the Currency system. Hooks into player join/leave.
]]
function Currency.init()
    if initialized then return end
    initialized = true

    Players.PlayerAdded:Connect(function(player)
        getWallet(player.Name)
        loadWallet(player.Name)
    end)

    Players.PlayerRemoving:Connect(function(player)
        persistWallet(player.Name)
        -- Keep in memory briefly for clean reconnect
    end)

    print("[Currency] Initialized — 3 currency types: Scrap, Materials (6 types), Influence")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SCRAP API
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Award scrap to a player.
    @param playerName string
    @param amount number — must be positive
    @param reason string? — e.g. "sold_fish", "mission_reward", "salvage"
]]
function Currency.earnScrap(playerName: string, amount: number, reason: string?)
    assert(amount > 0, "[Currency] earnScrap amount must be positive")
    local wallet = getWallet(playerName)
    wallet.scrap = wallet.scrap + amount
    wallet.totalScrapEarned = (wallet.totalScrapEarned or 0) + amount
    logTransaction(playerName, "earn", "scrap", amount, reason)
    persistWallet(playerName)
end

--[[
    Spend scrap from a player. Returns false if insufficient.
    @param playerName string
    @param amount number — must be positive
    @param reason string?
    @return boolean — true if transaction succeeded
]]
function Currency.spendScrap(playerName: string, amount: number, reason: string?): boolean
    assert(amount > 0, "[Currency] spendScrap amount must be positive")
    local wallet = getWallet(playerName)
    if wallet.scrap < amount then
        return false
    end
    wallet.scrap = wallet.scrap - amount
    wallet.totalScrapSpent = (wallet.totalScrapSpent or 0) + amount
    logTransaction(playerName, "spend", "scrap", amount, reason)
    persistWallet(playerName)
    return true
end

--[[
    Get scrap balance.
    @param playerName string
    @return number
]]
function Currency.getScrap(playerName: string): number
    local wallet = getWallet(playerName)
    return wallet.scrap
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MATERIALS API
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Award a material to a player.
    @param playerName string
    @param material string — one of MATERIAL_TYPES
    @param amount number — must be positive
    @param reason string?
]]
function Currency.earnMaterial(playerName: string, material: string, amount: number, reason: string?)
    assert(amount > 0, "[Currency] earnMaterial amount must be positive")
    local wallet = getWallet(playerName)
    if wallet.materials[material] == nil then
        warn(string.format("[Currency] Unknown material type: %s", material))
        return
    end
    wallet.materials[material] = wallet.materials[material] + amount
    logTransaction(playerName, "earn", material, amount, reason)
    persistWallet(playerName)
end

--[[
    Spend a material from a player. Returns false if insufficient.
    @param playerName string
    @param material string
    @param amount number
    @param reason string?
    @return boolean
]]
function Currency.spendMaterial(playerName: string, material: string, amount: number, reason: string?): boolean
    assert(amount > 0, "[Currency] spendMaterial amount must be positive")
    local wallet = getWallet(playerName)
    if wallet.materials[material] == nil then
        warn(string.format("[Currency] Unknown material type: %s", material))
        return false
    end
    if wallet.materials[material] < amount then
        return false
    end
    wallet.materials[material] = wallet.materials[material] - amount
    logTransaction(playerName, "spend", material, amount, reason)
    persistWallet(playerName)
    return true
end

--[[
    Get a specific material balance.
    @param playerName string
    @param material string
    @return number
]]
function Currency.getMaterial(playerName: string, material: string): number
    local wallet = getWallet(playerName)
    return wallet.materials[material] or 0
end

--[[
    Get all material balances.
    @param playerName string
    @return table — { wood=N, metal=N, cloth=N, glass=N, copper=N, stone=N }
]]
function Currency.getAllMaterials(playerName: string): { [string]: number }
    local wallet = getWallet(playerName)
    local result = {}
    for _, mat in ipairs(MATERIAL_TYPES) do
        result[mat] = wallet.materials[mat] or 0
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INFLUENCE API
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Award influence to a player (from missions, bond advancement).
    @param playerName string
    @param amount number
    @param reason string?
]]
function Currency.earnInfluence(playerName: string, amount: number, reason: string?)
    assert(amount > 0, "[Currency] earnInfluence amount must be positive")
    local wallet = getWallet(playerName)
    wallet.influence = wallet.influence + amount
    logTransaction(playerName, "earn", "influence", amount, reason)
    persistWallet(playerName)
end

--[[
    Spend influence. Returns false if insufficient.
    @param playerName string
    @param amount number
    @param reason string?
    @return boolean
]]
function Currency.spendInfluence(playerName: string, amount: number, reason: string?): boolean
    assert(amount > 0, "[Currency] spendInfluence amount must be positive")
    local wallet = getWallet(playerName)
    if wallet.influence < amount then
        return false
    end
    wallet.influence = wallet.influence - amount
    logTransaction(playerName, "spend", "influence", amount, reason)
    persistWallet(playerName)
    return true
end

--[[
    Get influence balance.
    @param playerName string
    @return number
]]
function Currency.getInfluence(playerName: string): number
    local wallet = getWallet(playerName)
    return wallet.influence
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COMBINED QUERIES & VALIDATION
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Get the full wallet for a player.
    @param playerName string
    @return table — { scrap, materials, influence, totalScrapEarned, totalScrapSpent }
]]
function Currency.getWallet(playerName: string): { [string]: any }
    local wallet = getWallet(playerName)
    return {
        scrap = wallet.scrap,
        materials = Currency.getAllMaterials(playerName),
        influence = wallet.influence,
        totalScrapEarned = wallet.totalScrapEarned or 0,
        totalScrapSpent = wallet.totalScrapSpent or 0,
    }
end

--[[
    Check if a player has at least the given scrap amount.
    @param playerName string
    @param amount number
    @return boolean
]]
function Currency.hasScrap(playerName: string, amount: number): boolean
    return Currency.getScrap(playerName) >= amount
end

--[[
    Check if a player has at least the given material amount.
    @param playerName string
    @param material string
    @param amount number
    @return boolean
]]
function Currency.hasMaterial(playerName: string, material: string, amount: number): boolean
    return Currency.getMaterial(playerName, material) >= amount
end

--[[
    Check if a player has at least the given influence amount.
    @param playerName string
    @param amount number
    @return boolean
]]
function Currency.hasInfluence(playerName: string, amount: number): boolean
    return Currency.getInfluence(playerName) >= amount
end

--[[
    Validate a multi-currency cost. Returns true if player can afford everything.
    @param playerName string
    @param cost table — { scrap=N, materials={wood=N,...}, influence=N }
    @return boolean, string? — affordable, first missing currency name
]]
function Currency.validateCost(playerName: string, cost: { [string]: any }): (boolean, string?)
    if cost.scrap then
        if not Currency.hasScrap(playerName, cost.scrap) then
            return false, "scrap"
        end
    end

    if cost.materials then
        for material, amount in pairs(cost.materials) do
            if not Currency.hasMaterial(playerName, material, amount) then
                return false, material
            end
        end
    end

    if cost.influence then
        if not Currency.hasInfluence(playerName, cost.influence) then
            return false, "influence"
        end
    end

    return true
end

--[[
    Charge a multi-currency cost. Validates first, then deducts atomically.
    If validation fails, nothing is charged.
    @param playerName string
    @param cost table — { scrap=N, materials={...}, influence=N }
    @param reason string?
    @return boolean, string? — success, missing currency if failed
]]
function Currency.chargeCost(playerName: string, cost: { [string]: any }, reason: string?): (boolean, string?)
    local canAfford, missing = Currency.validateCost(playerName, cost)
    if not canAfford then
        return false, missing
    end

    -- Deduct all (validated, so all will succeed)
    if cost.scrap then
        Currency.spendScrap(playerName, cost.scrap, reason)
    end
    if cost.materials then
        for material, amount in pairs(cost.materials) do
            Currency.spendMaterial(playerName, material, amount, reason)
        end
    end
    if cost.influence then
        Currency.spendInfluence(playerName, cost.influence, reason)
    end

    return true
end

--[[
    Award a multi-currency reward atomically.
    @param playerName string
    @param reward table — { scrap=N, materials={...}, influence=N }
    @param reason string?
]]
function Currency.award(playerName: string, reward: { [string]: any }, reason: string?)
    if reward.scrap then
        Currency.earnScrap(playerName, reward.scrap, reason)
    end
    if reward.materials then
        for material, amount in pairs(reward.materials) do
            Currency.earnMaterial(playerName, material, amount, reason)
        end
    end
    if reward.influence then
        Currency.earnInfluence(playerName, reward.influence, reason)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ADMIN / DEBUG
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    Set a player's scrap directly (admin/debug).
    @param playerName string
    @param amount number
]]
function Currency.setScrap(playerName: string, amount: number)
    local wallet = getWallet(playerName)
    wallet.scrap = math.max(0, math.floor(amount))
    logTransaction(playerName, "admin_set", "scrap", wallet.scrap, "admin override")
    persistWallet(playerName)
end

--[[
    Get the transaction log for a player.
    @param playerName string
    @return table
]]
function Currency.getTransactionLog(playerName: string): { [string]: any }
    local wallet = getWallet(playerName)
    return wallet.transactionLog or {}
end

--[[
    Get the list of valid material types.
    @return table
]]
function Currency.getMaterialTypes(): { [string]: any }
    local result = {}
    for _, mat in ipairs(MATERIAL_TYPES) do
        table.insert(result, mat)
    end
    return result
end

print("[Currency] Module loaded — Scrap, Materials (6), Influence")

return Currency
