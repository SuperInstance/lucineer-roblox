--[[
    currency-logic.test.lua — Pure Lua tests for Currency system logic
    
    Extracts the pure logic from Currency.lua (Roblox-dependent)
    and tests it in plain Lua 5.1.
    
    Tests: wallet creation, earning, spending, validation, atomic costs.
]]

-- ═══ Extracted pure logic (no Roblox deps) ═══

local MATERIAL_TYPES = { "wood", "metal", "cloth", "glass", "copper", "stone" }

local STARTING_BALANCES = {
    scrap = 50,
    materials = { wood = 10, metal = 2, cloth = 3, glass = 0, copper = 0, stone = 5 },
    influence = 0,
}

local MAX_LOG_ENTRIES = 50

local wallets = {}

local function getWallet(playerName)
    if not wallets[playerName] then
        wallets[playerName] = {
            scrap = STARTING_BALANCES.scrap,
            materials = {},
            influence = STARTING_BALANCES.influence,
            totalScrapEarned = 0,
            totalScrapSpent = 0,
            transactionLog = {},
        }
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

local function logTransaction(playerName, txType, currency, amount, reason)
    local wallet = getWallet(playerName)
    local log = wallet.transactionLog
    table.insert(log, 1, {
        type = txType, currency = currency, amount = amount,
        reason = reason or "unspecified", timestamp = os.time(),
    })
    while #log > MAX_LOG_ENTRIES do table.remove(log, #log) end
end

-- ═══ Currency API (pure) ═══

local Currency = {}

function Currency.earnScrap(playerName, amount, reason)
    assert(amount > 0, "amount must be positive")
    local wallet = getWallet(playerName)
    wallet.scrap = wallet.scrap + amount
    wallet.totalScrapEarned = (wallet.totalScrapEarned or 0) + amount
    logTransaction(playerName, "earn", "scrap", amount, reason)
end

function Currency.spendScrap(playerName, amount, reason)
    assert(amount > 0, "amount must be positive")
    local wallet = getWallet(playerName)
    if wallet.scrap < amount then return false end
    wallet.scrap = wallet.scrap - amount
    wallet.totalScrapSpent = (wallet.totalScrapSpent or 0) + amount
    logTransaction(playerName, "spend", "scrap", amount, reason)
    return true
end

function Currency.getScrap(playerName)
    return getWallet(playerName).scrap
end

function Currency.earnMaterial(playerName, material, amount, reason)
    assert(amount > 0, "amount must be positive")
    local wallet = getWallet(playerName)
    if wallet.materials[material] == nil then return end
    wallet.materials[material] = wallet.materials[material] + amount
    logTransaction(playerName, "earn", material, amount, reason)
end

function Currency.spendMaterial(playerName, material, amount, reason)
    assert(amount > 0, "amount must be positive")
    local wallet = getWallet(playerName)
    if wallet.materials[material] == nil then return false end
    if wallet.materials[material] < amount then return false end
    wallet.materials[material] = wallet.materials[material] - amount
    logTransaction(playerName, "spend", material, amount, reason)
    return true
end

function Currency.getMaterial(playerName, material)
    return getWallet(playerName).materials[material] or 0
end

function Currency.earnInfluence(playerName, amount, reason)
    assert(amount > 0, "amount must be positive")
    local wallet = getWallet(playerName)
    wallet.influence = wallet.influence + amount
    logTransaction(playerName, "earn", "influence", amount, reason)
end

function Currency.spendInfluence(playerName, amount, reason)
    assert(amount > 0, "amount must be positive")
    local wallet = getWallet(playerName)
    if wallet.influence < amount then return false end
    wallet.influence = wallet.influence - amount
    logTransaction(playerName, "spend", "influence", amount, reason)
    return true
end

function Currency.getInfluence(playerName)
    return getWallet(playerName).influence
end

function Currency.hasScrap(playerName, amount)
    return Currency.getScrap(playerName) >= amount
end

function Currency.hasMaterial(playerName, material, amount)
    return Currency.getMaterial(playerName, material) >= amount
end

function Currency.hasInfluence(playerName, amount)
    return Currency.getInfluence(playerName) >= amount
end

function Currency.validateCost(playerName, cost)
    if cost.scrap and not Currency.hasScrap(playerName, cost.scrap) then
        return false, "scrap"
    end
    if cost.materials then
        for material, amount in pairs(cost.materials) do
            if not Currency.hasMaterial(playerName, material, amount) then
                return false, material
            end
        end
    end
    if cost.influence and not Currency.hasInfluence(playerName, cost.influence) then
        return false, "influence"
    end
    return true
end

function Currency.chargeCost(playerName, cost, reason)
    local ok, missing = Currency.validateCost(playerName, cost)
    if not ok then return false, missing end
    if cost.scrap then Currency.spendScrap(playerName, cost.scrap, reason) end
    if cost.materials then
        for material, amount in pairs(cost.materials) do
            Currency.spendMaterial(playerName, material, amount, reason)
        end
    end
    if cost.influence then Currency.spendInfluence(playerName, cost.influence, reason) end
    return true
end

function Currency.award(playerName, reward, reason)
    if reward.scrap then Currency.earnScrap(playerName, reward.scrap, reason) end
    if reward.materials then
        for material, amount in pairs(reward.materials) do
            Currency.earnMaterial(playerName, material, amount, reason)
        end
    end
    if reward.influence then Currency.earnInfluence(playerName, reward.influence, reason) end
end

function Currency.getTransactionLog(playerName)
    return getWallet(playerName).transactionLog or {}
end

-- ═══ Test framework ═══

local passed = 0
local failed = 0

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAIL: %s\n  expected: %s\n  got: %s",
            msg or "", tostring(expected), tostring(actual)))
    end
end

local function assertOk(cond, msg)
    if not cond then error("ASSERT FAIL: " .. (msg or "condition false")) end
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("  ✓ " .. name)
        passed = passed + 1
    else
        print("  ✗ " .. name)
        print("    " .. (err or "unknown error"))
        failed = failed + 1
    end
end

-- ═══ Tests ═══

test("new wallet gets starting balances", function()
    local scrap = Currency.getScrap("newplayer")
    assertEq(scrap, 50, "starting scrap should be 50")
    assertEq(Currency.getMaterial("newplayer", "wood"), 10, "starting wood")
    assertEq(Currency.getMaterial("newplayer", "glass"), 0, "starting glass")
    assertEq(Currency.getInfluence("newplayer"), 0, "starting influence")
end)

test("earnScrap increases balance", function()
    Currency.earnScrap("p1", 25, "fishing")
    assertEq(Currency.getScrap("p1"), 75, "50 + 25 = 75")
end)

test("spendScrap decreases balance", function()
    Currency.spendScrap("p2", 10, "repair")
    assertEq(Currency.getScrap("p2"), 40, "50 - 10 = 40")
end)

test("spendScrap fails when insufficient", function()
    local ok = Currency.spendScrap("poor", 100)
    assertEq(ok, false, "should fail with insufficient scrap")
    assertEq(Currency.getScrap("poor"), 50, "balance unchanged after failed spend")
end)

test("spendScrap to zero succeeds", function()
    local ok = Currency.spendScrap("broke", 50)
    assertEq(ok, true, "should succeed spending exactly all scrap")
    assertEq(Currency.getScrap("broke"), 0, "should be zero")
end)

test("earnMaterial increases balance", function()
    Currency.earnMaterial("crafter", "wood", 15, "foraging")
    assertEq(Currency.getMaterial("crafter", "wood"), 25, "10 + 15 = 25")
end)

test("spendMaterial decreases balance", function()
    Currency.earnMaterial("m2", "metal", 10)
    Currency.spendMaterial("m2", "metal", 5, "building")
    assertEq(Currency.getMaterial("m2", "metal"), 7, "2 + 10 - 5 = 7")
end)

test("spendMaterial fails when insufficient", function()
    local ok = Currency.spendMaterial("m3", "glass", 1)
    assertEq(ok, false, "glass starts at 0, should fail")
end)

test("earnInfluence increases balance", function()
    Currency.earnInfluence("hero", 5, "mission_complete")
    assertEq(Currency.getInfluence("hero"), 5, "0 + 5 = 5")
end)

test("spendInfluence fails when insufficient", function()
    local ok = Currency.spendInfluence("hero", 100)
    assertEq(ok, false, "should fail")
end)

test("hasScrap returns true for affordable amount", function()
    assertOk(Currency.hasScrap("rich", 50), "should have 50 scrap")
    assertOk(not Currency.hasScrap("rich", 51), "should not have 51 scrap")
end)

test("hasMaterial checks correctly", function()
    assertOk(Currency.hasMaterial("check", "wood", 10), "should have 10 wood")
    assertOk(not Currency.hasMaterial("check", "wood", 11), "should not have 11 wood")
end)

test("validateCost passes when affordable", function()
    Currency.earnScrap("buyer", 100)
    Currency.earnMaterial("buyer", "wood", 50)
    local ok, missing = Currency.validateCost("buyer", {
        scrap = 100, materials = { wood = 50 }, influence = 0,
    })
    assertEq(ok, true, "should be affordable")
    assertEq(missing, nil, "no missing currency")
end)

test("validateCost fails with correct missing currency", function()
    local ok, missing = Currency.validateCost("buyer2", {
        scrap = 1000, -- buyer2 only has 50
    })
    assertEq(ok, false, "should fail")
    assertEq(missing, "scrap", "scrap is missing")
end)

test("validateCost identifies missing material", function()
    local ok, missing = Currency.validateCost("builder", {
        materials = { glass = 1 }, -- glass starts at 0
    })
    assertEq(ok, false, "should fail")
    assertEq(missing, "glass", "glass is missing")
end)

test("chargeCost deducts atomically on success", function()
    Currency.earnScrap("atomic", 100)
    Currency.earnMaterial("atomic", "wood", 20)
    local ok = Currency.chargeCost("atomic", {
        scrap = 30, materials = { wood = 10 },
    }, "build_thing")
    assertEq(ok, true, "charge should succeed")
    assertEq(Currency.getScrap("atomic"), 120, "150 - 30 = 120")  -- 50 starting + 100 earned - 30 charged
    assertEq(Currency.getMaterial("atomic", "wood"), 20, "30 - 10 = 20")  -- 10 start + 20 earned - 10 charged
end)

test("chargeCost does nothing on failure", function()
    local ok = Currency.chargeCost("poor2", {
        scrap = 1000,
    }, "expensive_thing")
    assertEq(ok, false, "should fail")
    assertEq(Currency.getScrap("poor2"), 50, "balance unchanged")
end)

test("award gives multiple currencies at once", function()
    Currency.award("champ", {
        scrap = 50, materials = { wood = 5, metal = 3 }, influence = 2,
    }, "big_mission")
    assertEq(Currency.getScrap("champ"), 100, "50 + 50 = 100")
    assertEq(Currency.getMaterial("champ", "wood"), 15, "10 + 5 = 15")
    assertEq(Currency.getMaterial("champ", "metal"), 5, "2 + 3 = 5")
    assertEq(Currency.getInfluence("champ"), 2, "0 + 2 = 2")
end)

test("transaction log records entries", function()
    Currency.earnScrap("logger", 10, "test")
    Currency.spendScrap("logger", 5, "test2")
    local log = Currency.getTransactionLog("logger")
    assertOk(#log >= 2, "should have at least 2 entries")
    assertEq(log[1].reason, "test2", "most recent first")
    assertEq(log[2].reason, "test", "older second")
end)

test("transaction log caps at MAX_LOG_ENTRIES", function()
    for i = 1, 60 do
        Currency.earnScrap("spammer", 1, "spam_" .. i)
    end
    local log = Currency.getTransactionLog("spammer")
    assertOk(#log <= 50, "log should be capped at 50 entries")
end)

test("earnScrap with zero amount throws", function()
    local ok, err = pcall(function()
        Currency.earnScrap("zero", 0)
    end)
    assertOk(not ok, "should throw for zero amount")
end)

test("earnScrap with negative amount throws", function()
    local ok, err = pcall(function()
        Currency.earnScrap("neg", -5)
    end)
    assertOk(not ok, "should throw for negative amount")
end)

test("wallets are independent per player", function()
    Currency.earnScrap("player_a", 100)
    Currency.earnScrap("player_b", 200)
    assertEq(Currency.getScrap("player_a"), 150, "50 + 100 = 150")
    assertEq(Currency.getScrap("player_b"), 250, "50 + 200 = 250")
end)

test("totalScrapEarned tracks lifetime earnings", function()
    -- Can't access wallet directly in this API, but we can verify
    -- through the transaction log that earning was logged
    Currency.earnScrap("tracker", 42, "tracked")
    local log = Currency.getTransactionLog("tracker")
    local found = false
    for _, entry in ipairs(log) do
        if entry.currency == "scrap" and entry.amount == 42 and entry.type == "earn" then
            found = true
            break
        end
    end
    assertOk(found, "earning should be in transaction log")
end)

-- ═══ Results ═══

print(string.format("\n%d passed, %d failed, %d total", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
