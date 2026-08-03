--[[
    Smoke Test — Lucineer Module Load Verification
    ──────────────────────────────────────────────
    Place this Script in ServerScriptService and run in Studio.

    Every module in the build tree is loaded via require().
    Verifies critical API surfaces exist.
    Reports pass/fail per module and a final summary.

    This is the gate from the Grand Plan:
    "every merge must survive the smoke test in a live Studio session."
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

----------------------------------------------------------------
-- RESULTS TRACKING
----------------------------------------------------------------

local results = {}  -- { { module, status, detail } }
local passCount = 0
local failCount = 0

local function report(moduleName: string, passed: boolean, detail: string?)
    table.insert(results, {
        module = moduleName,
        status = passed and "✅ PASS" or "❌ FAIL",
        detail = detail or "",
    })
    if passed then
        passCount += 1
    else
        failCount += 1
    end
end

----------------------------------------------------------------
-- SAFE REQUIRE
----------------------------------------------------------------

local function safeRequire(moduleInstance: Instance): (any?, string?)
    if not moduleInstance then
        return nil, "module instance is nil"
    end

    local ok, result = pcall(function()
        return require(moduleInstance)
    end)

    if ok then
        return result, nil
    else
        return nil, tostring(result)
    end
end

----------------------------------------------------------------
-- TEST: ReplicatedStorage/Lucineer modules
----------------------------------------------------------------

print("══════════════════════════════════════════════════════")
print("  LUCINEER SMOKE TEST — Loading all modules")
print("══════════════════════════════════════════════════════")
print("")

local lucineerFolder = ReplicatedStorage:WaitForChild("Lucineer", 10)
if not lucineerFolder then
    error("[SmokeTest] ReplicatedStorage.Lucineer folder not found!")
end

-- Expected ReplicatedStorage modules (from default.project.json)
local replicatedModules = {
    "Config",
    "Http",
    "Poller",
    "ChatHandler",
    "CommandExecutor",
    "WorldScanner",
    "UIManager",
    "AudioManager",
    "BuildAnimator",
    "VibeCoder",
    "VibeCoderDialogue",
    "VoiceLines",
    "VoiceLinesData",
    "CinematicController",
    "FilterGate",
    "BeatClock",
}

-- Loaded module cache for API verification
local loaded = {}

-- Load all ReplicatedStorage/Lucineer modules
for _, moduleName in ipairs(replicatedModules) do
    local moduleInst = lucineerFolder:FindFirstChild(moduleName)
    if not moduleInst then
        report(moduleName, false, "Module instance not found in ReplicatedStorage.Lucineer")
    else
        local result, err = safeRequire(moduleInst)
        if err then
            report(moduleName, false, err)
        else
            loaded[moduleName] = result
            report(moduleName, true, "loaded successfully")
        end
    end
end

----------------------------------------------------------------
-- TEST: ServerScriptService modules
----------------------------------------------------------------

local serverSystems = {
    "LucineerServer",
    "NPCManager",
    "AchievementManager",
    "BondSystem",
    "EraSystem",
    "SaveSystem",
    "TutorialSystem",
    "WeatherSystem",
    "PowerGrid",
    "WorldGenerator",
    "VibeCodeExecutor",
    "OnboardingSystem",
}

for _, systemName in ipairs(serverSystems) do
    local systemFolder = ServerScriptService:FindFirstChild(systemName)
    if not systemFolder then
        report(systemName, false, "Folder not found in ServerScriptService")
    else
        -- Try to find the init module
        local initScript = systemFolder:FindFirstChild("init")
        if not initScript then
            -- Some systems might be Scripts, not Folders with init
            if systemFolder:IsA("Script") then
                -- It's a Script, not a Folder — can't require it
                report(systemName, true, "Script (not requireable — OK)")
            else
                report(systemName, false, "No init module found")
            end
        else
            local result, err = safeRequire(initScript)
            if err then
                report(systemName, false, err)
            else
                loaded[systemName] = result
                report(systemName, true, "loaded successfully")
            end
        end
    end
end

-- EraSystem submodules
local eraSystemFolder = ServerScriptService:FindFirstChild("EraSystem")
if eraSystemFolder then
    for _, subModuleName in ipairs({ "CraftingSystem", "Recipes" }) do
        local subModule = eraSystemFolder:FindFirstChild(subModuleName)
        if subModule then
            local result, err = safeRequire(subModule)
            if err then
                report("EraSystem." .. subModuleName, false, err)
            else
                loaded["EraSystem." .. subModuleName] = result
                report("EraSystem." .. subModuleName, true, "loaded successfully")
            end
        else
            report("EraSystem." .. subModuleName, false, "Submodule not found")
        end
    end
end

-- PowerGrid submodules
local powerGridFolder = ServerScriptService:FindFirstChild("PowerGrid")
if powerGridFolder then
    for _, subModuleName in ipairs({ "Mechanical", "Visualization" }) do
        local subModule = powerGridFolder:FindFirstChild(subModuleName)
        if subModule then
            local result, err = safeRequire(subModule)
            if err then
                report("PowerGrid." .. subModuleName, false, err)
            else
                loaded["PowerGrid." .. subModuleName] = result
                report("PowerGrid." .. subModuleName, true, "loaded successfully")
            end
        else
            report("PowerGrid." .. subModuleName, false, "Submodule not found")
        end
    end
end

-- WorldGenerator submodules
local worldGenFolder = ServerScriptService:FindFirstChild("WorldGenerator")
if worldGenFolder then
    for _, subModuleName in ipairs({ "Config", "Resources", "TideSystem" }) do
        local subModule = worldGenFolder:FindFirstChild(subModuleName)
        if subModule then
            local result, err = safeRequire(subModule)
            if err then
                report("WorldGenerator." .. subModuleName, false, err)
            else
                loaded["WorldGenerator." .. subModuleName] = result
                report("WorldGenerator." .. subModuleName, true, "loaded successfully")
            end
        else
            report("WorldGenerator." .. subModuleName, false, "Submodule not found")
        end
    end
end

-- WeatherSystem submodule
local weatherFolder = ServerScriptService:FindFirstChild("WeatherSystem")
if weatherFolder then
    local effectsModule = weatherFolder:FindFirstChild("Effects")
    if effectsModule then
        local result, err = safeRequire(effectsModule)
        if err then
            report("WeatherSystem.Effects", false, err)
        else
            loaded["WeatherSystem.Effects"] = result
            report("WeatherSystem.Effects", true, "loaded successfully")
        end
    else
        report("WeatherSystem.Effects", false, "Effects submodule not found")
    end
end

----------------------------------------------------------------
-- API SURFACE VERIFICATION
----------------------------------------------------------------

print("")
print("──────────────────────────────────────────────────────")
print("  API SURFACE VERIFICATION")
print("──────────────────────────────────────────────────────")
print("")

-- CommandExecutor must have an Execute function
local cmdExec = loaded["CommandExecutor"]
if cmdExec then
    if type(cmdExec.execute) == "function" then
        report("API: CommandExecutor.execute", true, "function exists")
    else
        report("API: CommandExecutor.execute", false, "execute is not a function (type: " .. typeof(cmdExec.execute) .. ")")
    end
else
    report("API: CommandExecutor.execute", false, "CommandExecutor not loaded")
end

-- BuildAnimator must have StreamBuild or PlayBuild function
-- (We use animatePart / animateBatch / getStagger)
local buildAnim = loaded["BuildAnimator"]
if buildAnim then
    local hasStream = type(buildAnim.animateBatch) == "function"
        or type(buildAnim.animateBatchInTime) == "function"
        or type(buildAnim.animatePart) == "function"
    if hasStream then
        report("API: BuildAnimator.streamBuild/animateBatch", true, "animation function exists")
    else
        report("API: BuildAnimator.streamBuild/animateBatch", false, "no build animation function found")
    end

    -- Also verify the new getStagger function
    if type(buildAnim.getStagger) == "function" then
        local stagger120 = buildAnim.getStagger(120)
        local stagger90 = buildAnim.getStagger(90)
        local stagger72 = buildAnim.getStagger(72)
        local staggerOK = stagger120 == 0.0625
            and math.abs(stagger90 - 0.0833) < 0.001
            and math.abs(stagger72 - 0.1042) < 0.001
        report("API: BuildAnimator.getStagger (32nd-note grid)", staggerOK,
            string.format("120=%.4fs 90=%.4fs 72=%.4fs", stagger120, stagger90, stagger72))
    else
        report("API: BuildAnimator.getStagger", false, "getStagger function not found")
    end
else
    report("API: BuildAnimator", false, "BuildAnimator not loaded")
end

-- Config must have expected keys
local config = loaded["Config"]
if config then
    local hasWorkerUrl = type(config.WORKER_URL) == "string"
    local hasPollInterval = type(config.POLL_INTERVAL) == "number"
    local hasBotName = type(config.BOT_NAME) == "string"
    local configOK = hasWorkerUrl and hasPollInterval and hasBotName
    report("API: Config keys", configOK,
        string.format("WORKER_URL=%s POLL_INTERVAL=%s BOT_NAME=%s",
            hasWorkerUrl and "✓" or "✗",
            hasPollInterval and "✓" or "✗",
            hasBotName and "✓" or "✗"))
else
    report("API: Config keys", false, "Config not loaded")
end

-- Http must have Post and Get functions
local http = loaded["Http"]
if http then
    local hasPost = type(http.post) == "function"
    local hasGet = type(http.get) == "function"
    report("API: Http.post / Http.get", hasPost and hasGet,
        string.format("post=%s get=%s",
            hasPost and "✓" or "✗",
            hasGet and "✓" or "✗"))
else
    report("API: Http.post / Http.get", false, "Http not loaded")
end

-- FilterGate must have filterFor
local filterGate = loaded["FilterGate"]
if filterGate then
    if type(filterGate.filterFor) == "function" then
        report("API: FilterGate.filterFor", true, "fail-closed filter chokepoint exists")
    else
        report("API: FilterGate.filterFor", false, "filterFor is not a function")
    end
else
    report("API: FilterGate.filterFor", false, "FilterGate not loaded")
end

-- BeatClock must have getCurrentTick, getCurrentBeat, getBPM
local beatClock = loaded["BeatClock"]
if beatClock then
    local hasTick = type(beatClock.getCurrentTick) == "function"
    local hasBeat = type(beatClock.getCurrentBeat) == "function"
    local hasBPM = type(beatClock.getBPM) == "function"
    local hasSetBPM = type(beatClock.setBPM) == "function"
    local hasStagger = type(beatClock.get32ndNoteDuration) == "function"
    local beatClockOK = hasTick and hasBeat and hasBPM and hasSetBPM and hasStagger
    report("API: BeatClock mirror", beatClockOK,
        string.format("getCurrentTick=%s getCurrentBeat=%s getBPM=%s setBPM=%s get32nd=%s",
            hasTick and "✓" or "✗",
            hasBeat and "✓" or "✗",
            hasBPM and "✓" or "✗",
            hasSetBPM and "✓" or "✗",
            hasStagger and "✓" or "✗"))
else
    report("API: BeatClock mirror", false, "BeatClock not loaded")
end

-- VoiceLines must have get/getByTrigger/forTemplate/getWeighted
local voiceLines = loaded["VoiceLines"]
if voiceLines then
    local hasGet = type(voiceLines.get) == "function"
    local hasWeighted = type(voiceLines.getWeighted) == "function"
    local hasTrigger = type(voiceLines.getByTrigger) == "function"
    report("API: VoiceLines", hasGet and hasWeighted and hasTrigger,
        string.format("get=%s getWeighted=%s getByTrigger=%s",
            hasGet and "✓" or "✗",
            hasWeighted and "✓" or "✗",
            hasTrigger and "✓" or "✗"))
else
    report("API: VoiceLines", false, "VoiceLines not loaded")
end

----------------------------------------------------------------
-- FINAL SUMMARY
----------------------------------------------------------------

print("")
print("══════════════════════════════════════════════════════")
print("  SMOKE TEST SUMMARY")
print("══════════════════════════════════════════════════════")
print("")

for _, result in ipairs(results) do
    local line = string.format("  %s  %s", result.status, result.module)
    if result.detail ~= "" then
        line = line .. " — " .. result.detail
    end
    print(line)
end

print("")
local total = passCount + failCount
print(string.format("  Total: %d  |  Pass: %d  |  Fail: %d", total, passCount, failCount))

if failCount > 0 then
    print("")
    print("  ❌ SMOKE TEST FAILED — fix failures before merging.")
    warn("[SmokeTest] FAILED — " .. failCount .. " of " .. total .. " checks failed")
else
    print("")
    print("  ✅ SMOKE TEST PASSED — all " .. total .. " modules and API checks green.")
    print("[SmokeTest] PASSED — all " .. total .. " checks green")
end

print("")
print("══════════════════════════════════════════════════════")
