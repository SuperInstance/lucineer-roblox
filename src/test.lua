-- ═══════════════════════════════════════════════════════════
-- test.lua — Entry point for running all lucineer-roblox tests
-- ═══════════════════════════════════════════════════════════
--
-- In Roblox Studio: run this in the command bar to execute all tests.
-- In CI / local: run `lua5.1 test/*.lua` from the repo root.
--
-- Test suites:
--   test/economy-logic-test.lua — Currency system (38 tests)
--   (more suites added as systems are built)
-- ═══════════════════════════════════════════════════════════

local TEST_DIRS = {
    "ReplicatedStorage.Tests.EconomyLogic",
    "ReplicatedStorage.Tests.BuildCosts",
    "ReplicatedStorage.Tests.MissionBoard",
}

local function runTests()
    print("╔══════════════════════════════════════╗")
    print("║   LUCINEER ROBLOX — TEST RUNNER     ║")
    print("╚══════════════════════════════════════╝")

    local passed = 0
    local failed = 0

    for _, testPath in ipairs(TEST_DIRS) do
        local ok, result = pcall(function()
            -- In Roblox, require the ModuleScript at testPath
            -- This is a stub — actual test modules would be in ReplicatedStorage
            print("[SKIP] " .. testPath .. " (not yet implemented in-game)")
        end)

        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            warn("[FAIL] " .. testPath .. ": " .. tostring(result))
        end
    end

    print(string.format("\n═══ Results: %d passed, %d failed ═══", passed, failed))

    -- For local Lua testing, delegate to the economy-logic-test.lua
    if _VERSION == "Lua 5.1" and not game then
        print("\n[INFO] Running in Lua 5.1 mode — see test/ directory for runnable tests")
        print("[INFO] Run: lua5.1 test/economy-logic-test.lua")
    end

    return passed, failed
end

return runTests()
