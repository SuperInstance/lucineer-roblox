-- Lua 5.1 test file for Currency system economy logic
-- Tests the pure-logic portions of the Currency module
-- Run with: lua5.1 test/economy-logic-test.lua

-- ═══════════════════════════════════════════════════════════
-- MOCK ROBLOX ENVIRONMENT
-- ═══════════════════════════════════════════════════════════

-- Mock game service
local game = {
    GetService = function(self, serviceName)
        return {
            WaitForChild = function(self, name)
                return {
                    WaitForChild = function(self, name2)
                        return {} -- mock Http module
                    end
                }
            end
        }
    end
}
_G.game = game

-- Mock Players service
local mockPlayers = {
    PlayerAdded = { Connect = function(self, fn) end },
    PlayerRemoving = { Connect = function(self, fn) end },
}
game.GetService = function(self, serviceName)
    if serviceName == "Players" then return mockPlayers end
    if serviceName == "ReplicatedStorage" then
        return {
            WaitForChild = function(self, name)
                return {
                    WaitForChild = function(self, name2)
                        return {
                            post = function(url, data) return nil, nil end,
                            get = function(url) return nil, "mock_error" end,
                            decode = function(data) return {} end,
                        }
                    end
                }
            end
        }
    end
end

-- Mock task
task = { spawn = function(fn) end }
_G.task = task

-- Mock os.time
local mockTime = 1000000
local originalOsTime = os.time
os.time = function() return mockTime end

-- ═══════════════════════════════════════════════════════════
-- TEST FRAMEWORK
-- ═══════════════════════════════════════════════════════════

local tests = {}
local testCount = 0
local passCount = 0
local failCount = 0

local function test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

local function assertEqual(a, b, msg)
    if a ~= b then
        error(string.format("Assertion failed: %s (expected %s, got %s)",
            msg or "", tostring(b), tostring(a)))
    end
end

local function assertTrue(cond, msg)
    if not cond then
        error("Assertion failed: " .. (msg or "expected true"))
    end
end

local function assertFalse(cond, msg)
    if cond then
        error("Assertion failed: " .. (msg or "expected false"))
    end
end

-- ═══════════════════════════════════════════════════════════
-- REPRODUCE THE LOGIC (since we can't require Roblox modules)
-- ═══════════════════════════════════════════════════════════

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
    if not wallets[playerName].materials then
        wallets[playerName].materials = {}
        for _, mat in ipairs(MATERIAL_TYPES) do
            wallets[playerName].materials[mat] = STARTING_BALANCES.materials[mat] or 0
        end
    end
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

-- Currency API (pure logic, no persistence)
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
    assert(amount > 0)
    local wallet = getWallet(playerName)
    if wallet.materials[material] == nil then return end
    wallet.materials[material] = wallet.materials[material] + amount
    logTransaction(playerName, "earn", material, amount, reason)
end
function Currency.spendMaterial(playerName, material, amount, reason)
    assert(amount > 0)
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
function Currency.getAllMaterials(playerName)
    local wallet = getWallet(playerName)
    local result = {}
    for _, mat in ipairs(MATERIAL_TYPES) do result[mat] = wallet.materials[mat] or 0 end
    return result
end
function Currency.earnInfluence(playerName, amount, reason)
    assert(amount > 0)
    local wallet = getWallet(playerName)
    wallet.influence = wallet.influence + amount
    logTransaction(playerName, "earn", "influence", amount, reason)
end
function Currency.spendInfluence(playerName, amount, reason)
    assert(amount > 0)
    local wallet = getWallet(playerName)
    if wallet.influence < amount then return false end
    wallet.influence = wallet.influence - amount
    logTransaction(playerName, "spend", "influence", amount, reason)
    return true
end
function Currency.getInfluence(playerName)
    return getWallet(playerName).influence
end
function Currency.hasScrap(playerName, amount) return Currency.getScrap(playerName) >= amount end
function Currency.hasMaterial(playerName, material, amount) return Currency.getMaterial(playerName, material) >= amount end
function Currency.hasInfluence(playerName, amount) return Currency.getInfluence(playerName) >= amount end

function Currency.validateCost(playerName, cost)
    if cost.scrap and not Currency.hasScrap(playerName, cost.scrap) then return false, "scrap" end
    if cost.materials then
        for material, amount in pairs(cost.materials) do
            if not Currency.hasMaterial(playerName, material, amount) then return false, material end
        end
    end
    if cost.influence and not Currency.hasInfluence(playerName, cost.influence) then return false, "influence" end
    return true
end

function Currency.chargeCost(playerName, cost, reason)
    local canAfford, missing = Currency.validateCost(playerName, cost)
    if not canAfford then return false, missing end
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

-- ═══════════════════════════════════════════════════════════
-- TESTS
-- ═══════════════════════════════════════════════════════════

test("Starting balances are correct", function()
    assertEqual(Currency.getScrap("newplayer1"), 50, "starting scrap")
    assertEqual(Currency.getInfluence("newplayer2"), 0, "starting influence")
    assertEqual(Currency.getMaterial("newplayer3", "wood"), 10, "starting wood")
    assertEqual(Currency.getMaterial("newplayer4", "glass"), 0, "starting glass")
end)

test("earnScrap increases balance", function()
    Currency.earnScrap("test1", 25, "sold_fish")
    assertEqual(Currency.getScrap("test1"), 75, "50 + 25 = 75")
end)

test("earnScrap tracks totalScrapEarned", function()
    Currency.earnScrap("test2", 30, "mission")
    Currency.earnScrap("test2", 20, "salvage")
    local wallet = getWallet("test2")
    assertEqual(wallet.totalScrapEarned, 50, "30 + 20 = 50 total earned")
end)

test("spendScrap decreases balance", function()
    Currency.earnScrap("test3", 100)
    Currency.spendScrap("test3", 30, "bought_gear")
    assertEqual(Currency.getScrap("test3"), 120, "50 + 100 - 30 = 120")
end)

test("spendScrap returns false when insufficient", function()
    assertFalse(Currency.spendScrap("test4", 1000), "can't spend 1000 with 50 scrap")
end)

test("spendScrap returns true on success", function()
    assertTrue(Currency.spendScrap("test5", 10, "repair"), "can spend 10 with 50 scrap")
end)

test("spendScrap does not deduct on failure", function()
    Currency.spendScrap("test6", 1000)
    assertEqual(Currency.getScrap("test6"), 50, "failed spend doesn't change balance")
end)

test("spendScrap tracks totalScrapSpent", function()
    Currency.spendScrap("test7", 20, "gear")
    Currency.spendScrap("test7", 10, "fuel")
    local wallet = getWallet("test7")
    assertEqual(wallet.totalScrapSpent, 30, "20 + 10 = 30 total spent")
end)

test("earnScrap errors on zero amount", function()
    local ok, err = pcall(Currency.earnScrap, "test8", 0)
    assertFalse(ok, "zero amount should error")
end)

test("earnScrap errors on negative amount", function()
    local ok, err = pcall(Currency.earnScrap, "test9", -5)
    assertFalse(ok, "negative amount should error")
end)

test("spendScrap errors on zero amount", function()
    local ok, err = pcall(Currency.spendScrap, "test10", 0)
    assertFalse(ok, "zero spend should error")
end)

-- Material tests
test("earnMaterial increases balance", function()
    Currency.earnMaterial("mtest1", "wood", 5, "foraging")
    assertEqual(Currency.getMaterial("mtest1", "wood"), 15, "10 + 5 = 15")
end)

test("earnMaterial handles unknown type gracefully", function()
    Currency.earnMaterial("mtest2", "unobtainium", 999)
    assertEqual(Currency.getMaterial("mtest2", "unobtainium"), 0, "unknown material stays 0")
end)

test("spendMaterial decreases balance", function()
    Currency.earnMaterial("mtest3", "metal", 10)
    Currency.spendMaterial("mtest3", "metal", 5, "build")
    assertEqual(Currency.getMaterial("mtest3", "metal"), 7, "2 + 10 - 5 = 7")
end)

test("spendMaterial returns false when insufficient", function()
    assertFalse(Currency.spendMaterial("mtest4", "copper", 1), "can't spend copper with 0")
end)

test("spendMaterial does not deduct on failure", function()
    Currency.spendMaterial("mtest5", "copper", 1)
    assertEqual(Currency.getMaterial("mtest5", "copper"), 0, "failed spend doesn't change")
end)

test("getAllMaterials returns all 6 types", function()
    local mats = Currency.getAllMaterials("mtest6")
    local count = 0
    for k, v in pairs(mats) do count = count + 1 end
    assertEqual(count, 6, "should have 6 material types")
end)

test("getAllMaterials returns correct values", function()
    local mats = Currency.getAllMaterials("mtest7")
    assertEqual(mats.wood, 10, "wood=10")
    assertEqual(mats.metal, 2, "metal=2")
    assertEqual(mats.cloth, 3, "cloth=3")
    assertEqual(mats.glass, 0, "glass=0")
    assertEqual(mats.copper, 0, "copper=0")
    assertEqual(mats.stone, 5, "stone=5")
end)

-- Influence tests
test("earnInfluence increases balance", function()
    Currency.earnInfluence("itest1", 10, "bond_advance")
    assertEqual(Currency.getInfluence("itest1"), 10, "0 + 10 = 10")
end)

test("spendInfluence decreases balance", function()
    Currency.earnInfluence("itest2", 20)
    Currency.spendInfluence("itest2", 5, "unlock")
    assertEqual(Currency.getInfluence("itest2"), 15, "0 + 20 - 5 = 15")
end)

test("spendInfluence returns false when insufficient", function()
    assertFalse(Currency.spendInfluence("itest3", 1), "can't spend influence with 0")
end)

test("hasScrap returns correct boolean", function()
    assertTrue(Currency.hasScrap("htest1", 50), "has exactly 50")
    assertTrue(Currency.hasScrap("htest2", 49), "has more than 49")
    assertFalse(Currency.hasScrap("htest3", 51), "doesn't have 51")
end)

test("hasMaterial returns correct boolean", function()
    assertTrue(Currency.hasMaterial("htest4", "wood", 10), "has exactly 10 wood")
    assertFalse(Currency.hasMaterial("htest5", "wood", 11), "doesn't have 11 wood")
end)

test("hasInfluence returns correct boolean", function()
    Currency.earnInfluence("htest6", 15)
    assertTrue(Currency.hasInfluence("htest6", 15), "has exactly 15")
    assertFalse(Currency.hasInfluence("htest6", 16), "doesn't have 16")
end)

-- Transaction log tests
test("Transaction log records earns", function()
    Currency.earnScrap("logtest1", 10, "test_reason")
    local log = Currency.getTransactionLog("logtest1")
    assertEqual(log[1].type, "earn", "first entry is earn")
    assertEqual(log[1].currency, "scrap", "currency is scrap")
    assertEqual(log[1].amount, 10, "amount is 10")
    assertEqual(log[1].reason, "test_reason", "reason recorded")
end)

test("Transaction log records spends", function()
    Currency.spendScrap("logtest2", 5, "bought_thing")
    local log = Currency.getTransactionLog("logtest2")
    assertEqual(log[1].type, "spend", "entry is spend")
    assertEqual(log[1].reason, "bought_thing", "reason recorded")
end)

test("Transaction log is capped at MAX_LOG_ENTRIES", function()
    for i = 1, 60 do
        Currency.earnScrap("logtest3", 1, "spam_" .. i)
    end
    local log = Currency.getTransactionLog("logtest3")
    local count = 0
    for _ in pairs(log) do count = count + 1 end
    assertTrue(count <= 50, "log should be capped at 50 entries, got " .. count)
end)

test("Transaction log has default reason when none provided", function()
    Currency.earnScrap("logtest4", 5)
    local log = Currency.getTransactionLog("logtest4")
    assertEqual(log[1].reason, "unspecified", "default reason")
end)

-- validateCost tests
test("validateCost returns true when affordable", function()
    local ok, missing = Currency.validateCost("vctest1", {
        scrap = 50, materials = { wood = 10 }, influence = 0
    })
    assertTrue(ok, "should be affordable")
    assertEqual(missing, nil, "no missing currency")
end)

test("validateCost returns false with first missing currency", function()
    local ok, missing = Currency.validateCost("vctest2", {
        scrap = 1000, materials = { wood = 10 }
    })
    assertFalse(ok, "can't afford 1000 scrap")
    assertEqual(missing, "scrap", "first missing is scrap")
end)

test("validateCost checks materials in order", function()
    local ok, missing = Currency.validateCost("vctest3", {
        scrap = 50, materials = { wood = 100, metal = 100 }
    })
    assertFalse(ok, "can't afford materials")
    -- one of wood or metal should be reported (depends on table iteration order)
    assertTrue(missing == "wood" or missing == "metal", "missing should be wood or metal")
end)

-- chargeCost tests
test("chargeCost succeeds when affordable", function()
    local ok, missing = Currency.chargeCost("cctest1", {
        scrap = 20, materials = { wood = 5 }
    }, "build_something")
    assertTrue(ok, "should succeed")
    assertEqual(Currency.getScrap("cctest1"), 30, "50 - 20 = 30")
    assertEqual(Currency.getMaterial("cctest1", "wood"), 5, "10 - 5 = 5")
end)

test("chargeCost fails atomically when not affordable", function()
    local ok, missing = Currency.chargeCost("cctest2", {
        scrap = 1000, materials = { wood = 5 }
    }, "too_expensive")
    assertFalse(ok, "should fail")
    -- Nothing should be charged (atomic)
    assertEqual(Currency.getScrap("cctest2"), 50, "scrap unchanged after failed charge")
    assertEqual(Currency.getMaterial("cctest2", "wood"), 10, "wood unchanged after failed charge")
end)

-- award tests
test("award gives multiple currencies at once", function()
    Currency.award("atest1", {
        scrap = 100,
        materials = { wood = 5, metal = 3 },
        influence = 10
    }, "big_mission_reward")
    assertEqual(Currency.getScrap("atest1"), 150, "50 + 100 = 150")
    assertEqual(Currency.getMaterial("atest1", "wood"), 15, "10 + 5 = 15")
    assertEqual(Currency.getMaterial("atest1", "metal"), 5, "2 + 3 = 5")
    assertEqual(Currency.getInfluence("atest1"), 10, "0 + 10 = 10")
end)

test("award with partial reward works", function()
    Currency.award("atest2", { scrap = 50 }, "scrap_only")
    assertEqual(Currency.getScrap("atest2"), 100, "50 + 50 = 100")
end)

-- Edge cases
test("Player name isolation — different players have separate wallets", function()
    Currency.earnScrap("playerA", 1000)
    Currency.earnScrap("playerB", 2000)
    assertEqual(Currency.getScrap("playerA"), 1050, "playerA has 1050")
    assertEqual(Currency.getScrap("playerB"), 2050, "playerB has 2050")
end)

test("Wallet is created lazily on first access", function()
    -- Accessing a new player should give starting balances
    assertEqual(Currency.getScrap("lazy_player"), 50, "lazy wallet starts at 50")
end)

test("Multiple earns and spends maintain running totals", function()
    Currency.earnScrap("running1", 100)
    Currency.earnScrap("running1", 50)
    Currency.spendScrap("running1", 30)
    Currency.earnScrap("running1", 20)
    Currency.spendScrap("running1", 10)
    -- 50 + 100 + 50 - 30 + 20 - 10 = 180
    assertEqual(Currency.getScrap("running1"), 180, "running balance should be 180")
    local wallet = getWallet("running1")
    assertEqual(wallet.totalScrapEarned, 170, "100+50+20=170 earned")
    assertEqual(wallet.totalScrapSpent, 40, "30+10=40 spent")
end)

-- ═══════════════════════════════════════════════════════════
-- RUN TESTS
-- ═══════════════════════════════════════════════════════════

for _, t in ipairs(tests) do
    testCount = testCount + 1
    local ok, err = pcall(t.fn)
    if ok then
        passCount = passCount + 1
        -- io.write(".")
    else
        failCount = failCount + 1
        print(string.format("\nFAIL: %s — %s", t.name, err))
    end
end

print(string.format("\n\n%d tests: %d passed, %d failed", testCount, passCount, failCount))
if failCount > 0 then
    os.exit(1)
end
