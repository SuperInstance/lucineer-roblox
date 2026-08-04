--!strict
--[[
    MarketSystem.lua — Catch Selling and Price Fluctuation
    Earl at the cannery buys fish. Prices fluctuate.
]]

local MarketSystem = {}

-- Base prices per species (scrap per kg)
local BASE_PRICES = {
    herring = 3,
    cod = 8,
    salmon = 12,
    halibut = 35,
    crab = 10,
    tuna = 60,
}

-- Quality multipliers
local QUALITY_MULT = { A = 1.0, B = 0.7, C = 0.4, D = 0.1 }

-- Track daily sales for price depression
MarketSystem._dailySales = {}  -- [dayKey] = { [species] = totalKg }
MarketSystem._currentDay = nil

-- Special orders (daily)
MarketSystem._activeOrders = {}

function MarketSystem.init()
    print("[MarketSystem] Initialized")
end

function MarketSystem.getPrice(species, quality)
    quality = quality or "A"
    local base = BASE_PRICES[species] or 5
    local mult = QUALITY_MULT[quality] or 0.5

    -- Price depression: if >50kg sold today, price drops
    local dayKey = os.date("%Y%m%d")
    local sales = MarketSystem._dailySales[dayKey] or {}
    local todaySold = sales[species] or 0
    local depression = 1.0
    if todaySold > 50 then
        depression = math.max(0.5, 1.0 - (todaySold - 50) * 0.005)
    end

    return math.floor(base * mult * depression)
end

function MarketSystem.sellCatch(userId, cargo)
    -- cargo = { [species] = { weight = n, quality = "A"/B/C, count = n } }
    local totalScrap = 0
    local dayKey = os.date("%Y%m%d")

    if not MarketSystem._dailySales[dayKey] then
        MarketSystem._dailySales[dayKey] = {}
    end

    for species, data in pairs(cargo) do
        local pricePerKg = MarketSystem.getPrice(species, data.quality or "B")
        local earned = math.floor(pricePerKg * (data.weight or 0))

        -- Bulk bonus: 10+ of same species = 10% bonus
        if (data.count or 0) >= 10 then
            earned = math.floor(earned * 1.1)
        end

        totalScrap += earned

        -- Track for price depression
        MarketSystem._dailySales[dayKey][species] =
            (MarketSystem._dailySales[dayKey][species] or 0) + (data.weight or 0)
    end

    -- Check active special orders
    for i, order in ipairs(MarketSystem._activeOrders) do
        if order.userId == userId and not order.completed then
            local species = order.species
            if cargo[species] and (cargo[species].count or 0) >= order.amount then
                totalScrap += order.reward
                order.completed = true
            end
        end
    end

    return totalScrap
end

function MarketSystem.generateDailyOrder()
    local species = {"salmon", "halibut", "cod", "crab"}
    local pick = species[math.random(#species)]
    local amounts = { salmon = 15, halibut = 8, cod = 20, crab = 12 }
    local rewards = { salmon = 400, halibut = 800, cod = 300, crab = 350 }

    return {
        species = pick,
        amount = amounts[pick],
        reward = rewards[pick],
        deadline = os.time() + 86400,  -- 24 hours
        completed = false,
    }
end

return MarketSystem
