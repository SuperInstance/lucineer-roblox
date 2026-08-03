--!strict
--[[
    VibeCodeExecutor — Server-Side Gamified Code Execution
    =======================================================
    Receives vibe-code objects from the VibeCoder client and executes
    them against in-game devices with full validation.

    Validation pipeline:
        1. Check era requirement (player must be in the right era)
        2. Check power requirement (device must be on a powered grid)
        3. Check device exists and is compatible with the code type
        4. Apply the effect (brightness, motor, sound, sensor trigger, etc.)
        5. Store the "program" on the device for persistence

    Supported device actions:
        - setBrightness (lamps, LEDs, streetlights)
        - setMotorSpeed / setMotorAngle (motors, servos, conveyors)
        - playSound / playAlert (buzzers, sirens, speakers)
        - setDoorState (doors, gates, vaults)
        - setValve / setPump (fluid systems)
        - broadcastSignal (networked devices — Era 5+)
        - logData (data loggers — Era 5+)
        - triggerAgent (autonomous agents — Era 6+)

    Usage:
        local VibeCodeExecutor = require(ServerScriptService.VibeCodeExecutor)
        VibeCodeExecutor.init()

        -- RemoteEvent from client fires automatically
        -- Or call directly:
        VibeCodeExecutor.execute(player, codeObject, targetDeviceName)

    Dependencies:
        - ReplicatedStorage.Lucineer.Http
        - ServerScriptService.EraSystem
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Http = require(ReplicatedStorage:WaitForChild("Lucineer"):WaitForChild("Http"))

-- Safely require EraSystem (optional dependency)
local EraSystem = nil
local eraSystemOk = pcall(function()
    EraSystem = require(ServerScriptService:WaitForChild("EraSystem"))
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local MEMORY_URL = "https://lucineer-memory.casey-digennaro.workers.dev"

-- Device type → supported actions mapping
local DEVICE_ACTIONS = {
    -- Era 2: Electrical
    lamp            = { "setBrightness", "setColor", "blink" },
    led             = { "setBrightness", "setColor", "blink" },
    led_module      = { "setBrightness", "setColor", "blink" },
    buzzer          = { "playSound", "playAlert", "playPattern" },
    speaker_module  = { "playSound", "playAlert", "speak" },
    motor           = { "setMotorSpeed", "setDirection", "stop" },
    solenoid        = { "setState", "pulse" },
    heating_element = { "setTemperature", "stop" },
    electromagnet   = { "setState", "pulse" },
    relay_module    = { "setState", "pulse" },

    -- Era 4: Programmable
    servo_module    = { "setMotorAngle", "setMotorSpeed", "stop" },
    stepper_driver  = { "setMotorAngle", "setMotorSpeed", "stop" },
    lcd_display     = { "displayText", "clearDisplay" },

    -- Era 3: Control (sensors are read-only targets)
    -- Era 5: Networked
    wireless_module = { "broadcastSignal", "sendMessage" },
    mesh_node       = { "broadcastSignal", "sendMessage", "relayMessage" },
    cloud_gateway   = { "sendToCloud", "receiveFromCloud" },

    -- Era 6: Autonomous
    agent_core      = { "triggerAgent", "assignTask", "pauseAgent" },
}

-- Action execution functions (mapped by name)
local ACTION_HANDLERS = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

local VibeCodeExecutor = {}

local isInitialized = false
local remoteEvent = nil

-- In-memory device program store: deviceName → program table
-- Persisted to D1 via saveDeviceProgram
local devicePrograms = {}

-- Active loops: deviceName → RBXScriptConnection (for RunService bindings)
local activeLoops = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- DEVICE DISCOVERY
-- ═══════════════════════════════════════════════════════════════════════════

-- Find a device part in the workspace by name
local function findDevice(deviceName)
    if not deviceName then return nil end

    -- Check workspace for the part
    local part = workspace:FindFirstChild(deviceName, true)
    if part then return part end

    -- Check for tagged devices (CollectionService)
    local CollectionService = game:GetService("CollectionService")
    for _, tagged in ipairs(CollectionService:GetTagged("VibeDevice")) do
        if tagged.Name == deviceName then
            return tagged
        end
    end

    return nil
end

-- Get the device type from attributes or name
local function getDeviceType(device)
    if not device then return nil end

    -- Check attribute first
    local devType = device:GetAttribute("deviceType")
    if devType then return devType end

    -- Try to infer from name patterns
    local name = device.Name:lower()
    for knownType, _ in pairs(DEVICE_ACTIONS) do
        -- Convert knownType underscores to match patterns
        local pattern = knownType:gsub("_", "[_%s]")
        if name:match(pattern) then
            return knownType
        end
    end

    return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- VALIDATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Check era requirement
local function validateEra(playerName, eraRequired)
    if not eraRequired then return true, "" end
    if not EraSystem then return true, "" end -- EraSystem not loaded; allow

    local currentEra = EraSystem.getCurrentEra(playerName)
    if currentEra < eraRequired then
        local eraNames = {
            [0] = "Simple Machines", [1] = "Power Transmission",
            [2] = "Electricity", [3] = "Control Systems",
            [4] = "Programmable Logic", [5] = "Networked Systems",
            [6] = "Autonomous Agents",
        }
        return false, "Requires Era " .. tostring(eraRequired) ..
            " (" .. (eraNames[eraRequired] or "Unknown") .. "). " ..
            "You are in Era " .. tostring(currentEra) .. "."
    end

    return true, ""
end

-- Check power requirement
local function validatePower(device, powerRequired)
    if not powerRequired or powerRequired <= 0 then return true, "" end

    -- Check if device is connected to a powered grid
    local hasPower = device:GetAttribute("hasPower")
    if hasPower == nil then
        -- Default: assume powered if in workspace (simplified)
        hasPower = true
    end

    if not hasPower then
        return false, "Device is not connected to a powered grid."
    end

    -- Check available power (simplified grid model)
    local availablePower = device:GetAttribute("availablePower") or 999
    if availablePower < powerRequired then
        return false, "Insufficient power. Need " .. tostring(powerRequired) ..
            " kW, but only " .. tostring(availablePower) .. " kW available."
    end

    return true, ""
end

-- Check that the device supports the requested action
local function validateAction(deviceType, action)
    if not deviceType then
        return false, "Unknown device type. Tag the device with a 'deviceType' attribute."
    end

    local actions = DEVICE_ACTIONS[deviceType]
    if not actions then
        return false, "Device type '" .. deviceType .. "' is not vibe-codeable."
    end

    -- Check if the action (or its root verb) is supported
    for _, supportedAction in ipairs(actions) do
        if action == supportedAction then
            return true, ""
        end
        -- Also check if the action string starts with a supported verb
        -- e.g., "setBrightness(100%)" matches "setBrightness"
        if action:match("^" .. supportedAction) then
            return true, ""
        end
    end

    return false, "Action '" .. action .. "' not supported by " .. deviceType
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ACTION EXECUTION HANDLERS
-- ═══════════════════════════════════════════════════════════════════════════

-- Set brightness on a lamp/LED
function ACTION_HANDLERS.setBrightness(device, params, codeObj)
    local brightness = params.brightness or params.value or 1.0
    -- Scale 0-100% to 0-1
    if brightness > 1 then brightness = brightness / 100 end

    -- Roblox: set PointLight intensity or Material brightness
    local light = device:FindFirstChildWhichIsA("PointLight")
               or device:FindFirstChildWhichIsA("SpotLight")
               or device:FindFirstChildWhichIsA("SurfaceLight")

    if light then
        light.Brightness = brightness * 5 -- scale up for visibility
        light.Enabled = brightness > 0
    end

    -- Visual material change
    if brightness > 0 then
        device.Material = Enum.Material.Neon
    else
        device.Material = Enum.Material.Plastic
    end

    -- Set attribute for state tracking
    device:SetAttribute("brightness", brightness)

    return true, "Brightness set to " .. tostring(math.floor(brightness * 100)) .. "%"
end

-- Set color on a light
function ACTION_HANDLERS.setColor(device, params, codeObj)
    local color = params.color or params.value
    local colorValue = Color3.fromRGB(255, 255, 255)

    if type(color) == "string" then
        local colorMap = {
            red = Color3.fromRGB(255, 50, 50),
            green = Color3.fromRGB(50, 255, 100),
            blue = Color3.fromRGB(50, 150, 255),
            yellow = Color3.fromRGB(255, 230, 50),
            white = Color3.fromRGB(255, 255, 255),
            orange = Color3.fromRGB(255, 150, 50),
            purple = Color3.fromRGB(180, 50, 255),
        }
        colorValue = colorMap[color:lower()] or Color3.fromRGB(255, 255, 255)
    elseif type(color) == "table" then
        colorValue = Color3.fromRGB(
            color.r or 255, color.g or 255, color.b or 255
        )
    end

    device.Color = colorValue
    local light = device:FindFirstChildWhichIsA("PointLight")
              or device:FindFirstChildWhichIsA("SpotLight")
              or device:FindFirstChildWhichIsA("SurfaceLight")
    if light then
        light.Color = colorValue
    end

    device:SetAttribute("lightColor", color)

    return true, "Color set to " .. tostring(color)
end

-- Blink a light
function ACTION_HANDLERS.blink(device, params, codeObj)
    local interval = params.interval or 0.5
    local color = params.color or "red"

    -- Stop existing blink loop
    if activeLoops[device.Name] then
        activeLoops[device.Name]:Disconnect()
        activeLoops[device.Name] = nil
    end

    local state = false
    local connection
    connection = RunService.Heartbeat:Connect(function()
        -- Throttle to interval
    end)

    -- Use a simpler timer-based approach
    task.spawn(function()
        while activeLoops[device.Name] do
            state = not state
            ACTION_HANDLERS.setBrightness(device, {
                brightness = state and 1.0 or 0
            }, codeObj)
            if state then
                ACTION_HANDLERS.setColor(device, { color = color }, codeObj)
            end
            task.wait(interval)
        end
    end)

    activeLoops[device.Name] = {
        Disconnect = function()
            activeLoops[device.Name] = nil
        end
    }

    return true, "Blinking " .. color .. " at " .. tostring(interval) .. "s intervals"
end

-- Set motor speed
function ACTION_HANDLERS.setMotorSpeed(device, params, codeObj)
    local speed = params.speed or params.value or 1.0
    if math.abs(speed) > 1 then speed = speed / 100 end

    -- Roblox: set HingeConstraint or Motor angular velocity
    local hinge = device:FindFirstChildWhichIsA("HingeConstraint")
    local motor = device:FindFirstChildWhichIsA("Motor")
    local motor6d = device:FindFirstChildWhichIsA("Motor6D")

    if hinge then
        hinge.AngularVelocity = speed * 10
        hinge.Enabled = true
    elseif motor then
        motor.MaxVelocity = speed
    elseif motor6d then
        -- Motor6D for animated parts
        motor6d.MaxVelocity = speed
    end

    -- Rotate the part directly as fallback
    if not hinge and not motor and not motor6d then
        -- Use BodyAngularVelocity
        local bav = device:FindFirstChild("VibeAngularVelocity")
        if not bav then
            bav = Instance.new("BodyAngularVelocity")
            bav.Name = "VibeAngularVelocity"
            bav.Parent = device
        end
        bav.AngularVelocity = Vector3.new(0, speed * 10, 0)
        bav.MaxTorque = Vector3.new(0, math.huge, 0)
    end

    device:SetAttribute("motorSpeed", speed)

    return true, "Motor speed set to " .. tostring(math.floor(speed * 100)) .. "%"
end

-- Set motor angle (servo)
function ACTION_HANDLERS.setMotorAngle(device, params, codeObj)
    local angle = params.angle or params.value or 0

    -- Roblox: use HingeConstraint.TargetAngle
    local hinge = device:FindFirstChildWhichIsA("HingeConstraint")
    if hinge then
        hinge.ActuatorType = Enum.ActuatorType.Motor
        hinge.TargetAngle = angle
    end

    -- Alternative: rotate via CFrame
    if not hinge then
        local currentOrientation = device.Orientation
        device.Orientation = Vector3.new(currentOrientation.X, angle, currentOrientation.Z)
    end

    device:SetAttribute("motorAngle", angle)

    return true, "Servo angle set to " .. tostring(angle) .. "°"
end

-- Stop a motor
function ACTION_HANDLERS.stop(device, params, codeObj)
    local hinge = device:FindFirstChildWhichIsA("HingeConstraint")
    if hinge then
        hinge.Enabled = false
    end

    local bav = device:FindFirstChild("VibeAngularVelocity")
    if bav then
        bav:Destroy()
    end

    device:SetAttribute("motorSpeed", 0)

    -- Stop blink loops
    if activeLoops[device.Name] then
        activeLoops[device.Name] = nil
    end

    return true, "Motor stopped"
end

-- Set direction
function ACTION_HANDLERS.setDirection(device, params, codeObj)
    local direction = params.direction or "forward"
    local speed = device:GetAttribute("motorSpeed") or 0.5

    if direction == "reverse" or direction == "backward" then
        speed = -math.abs(speed)
    else
        speed = math.abs(speed)
    end

    return ACTION_HANDLERS.setMotorSpeed(device, { speed = speed }, codeObj)
end

-- Play sound
function ACTION_HANDLERS.playSound(device, params, codeObj)
    local soundId = params.soundId or params.value

    local sound = device:FindFirstChildWhichIsA("Sound")
    if sound then
        if soundId then
            sound.SoundId = "rbxassetid://" .. tostring(soundId)
        end
        sound:Play()
    else
        -- Create a default beep
        sound = Instance.new("Sound")
        sound.SoundId = "rbxasset://sounds/button.wav"
        sound.Volume = params.volume or 1.0
        sound.Parent = device
        sound:Play()
    end

    device:SetAttribute("isPlayingSound", true)

    return true, "Sound playing"
end

-- Play alert pattern (siren/alarm)
function ACTION_HANDLERS.playAlert(device, params, codeObj)
    local pattern = params.pattern or "siren"

    -- Blink light + play sound
    ACTION_HANDLERS.blink(device, { interval = 0.3, color = "red" }, codeObj)

    -- Loop sound
    task.spawn(function()
        while activeLoops[device.Name] do
            ACTION_HANDLERS.playSound(device, { volume = 1.0 }, codeObj)
            task.wait(1.0)
        end
    end)

    return true, "Alert activated: " .. pattern
end

-- Play pattern (Morse code, sequences)
function ACTION_HANDLERS.playPattern(device, params, codeObj)
    local pattern = params.pattern or "... --- ..."

    task.spawn(function()
        for char in pattern:gmatch(".") do
            if char == "." then
                ACTION_HANDLERS.setBrightness(device, { brightness = 1.0 }, codeObj)
                task.wait(0.15)
                ACTION_HANDLERS.setBrightness(device, { brightness = 0 }, codeObj)
                task.wait(0.15)
            elseif char == "-" then
                ACTION_HANDLERS.setBrightness(device, { brightness = 1.0 }, codeObj)
                task.wait(0.45)
                ACTION_HANDLERS.setBrightness(device, { brightness = 0 }, codeObj)
                task.wait(0.15)
            elseif char == " " then
                task.wait(0.3)
            end
        end
    end)

    return true, "Pattern playing: " .. pattern
end

-- Speak via speaker module
function ACTION_HANDLERS.speak(device, params, codeObj)
    local text = params.text or params.value or "Hello"

    -- In a full implementation, this would call TTS via the Worker
    -- For now, display text as a billboard
    local billboard = device:FindFirstChild("VibeBillboard")
    if not billboard then
        billboard = Instance.new("BillboardGui")
        billboard.Name = "VibeBillboard"
        billboard.Size = UDim2.new(0, 200, 0, 50)
        billboard.StudsOffset = Vector3.new(0, 3, 0)
        billboard.Parent = device
    end

    local label = billboard:FindFirstChild("TextLabel")
    if not label then
        label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, 0, 1, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Gotham
        label.TextColor3 = Color3.fromRGB(0, 255, 170)
        label.TextScaled = true
        label.Parent = billboard
    end

    label.Text = text

    return true, "Speaking: " .. text
end

-- Set state (generic on/off for solenoids, relays, electromagnets)
function ACTION_HANDLERS.setState(device, params, codeObj)
    local state = params.state
    if state == nil then state = params.value end
    if type(state) == "string" then
        state = (state:lower() == "on" or state:lower() == "true" or state:lower() == "1")
    end

    -- Visual feedback
    if state then
        device.Material = Enum.Material.Neon
        device.Color = Color3.fromRGB(0, 255, 170)
    else
        device.Material = Enum.Material.Plastic
        device.Color = Color3.fromRGB(100, 100, 100)
    end

    device:SetAttribute("state", state)

    -- For relay modules, also toggle connected devices
    local connectedDevice = device:GetAttribute("connectedDevice")
    if connectedDevice and state ~= nil then
        local target = findDevice(connectedDevice)
        if target then
            target:SetAttribute("hasPower", state)
        end
    end

    return true, "State set to " .. (state and "ON" or "OFF")
end

-- Pulse (momentary activation)
function ACTION_HANDLERS.pulse(device, params, codeObj)
    local duration = params.duration or 0.2

    ACTION_HANDLERS.setState(device, { state = true }, codeObj)
    task.delay(duration, function()
        ACTION_HANDLERS.setState(device, { state = false }, codeObj)
    end)

    return true, "Pulsed for " .. tostring(duration) .. "s"
end

-- Set temperature
function ACTION_HANDLERS.setTemperature(device, params, codeObj)
    local temp = params.temperature or params.value or 100

    -- Visual: heat glow
    if temp > 0 then
        device.Material = Enum.Material.Neon
        -- Color shifts from orange to white-hot
        local heat = math.clamp(temp / 1200, 0, 1)
        device.Color = Color3.fromRGB(
            255,
            math.floor(100 + heat * 155),
            math.floor(heat * 200)
        )
    else
        device.Material = Enum.Material.Plastic
        device.Color = Color3.fromRGB(80, 80, 80)
    end

    device:SetAttribute("temperature", temp)

    return true, "Temperature set to " .. tostring(temp) .. "°"
end

-- Display text on LCD
function ACTION_HANDLERS.displayText(device, params, codeObj)
    local text = params.text or params.value or ""

    local billboard = device:FindFirstChild("VibeDisplay")
    if not billboard then
        billboard = Instance.new("SurfaceGui")
        billboard.Name = "VibeDisplay"
        billboard.Face = Enum.NormalId.Front
        billboard.Parent = device
    end

    local label = billboard:FindFirstChild("TextLabel")
    if not label then
        label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, 0, 1, 0)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Code
        label.TextColor3 = Color3.fromRGB(0, 255, 170)
        label.TextScaled = true
        label.Parent = billboard
    end

    label.Text = text

    return true, "Display: " .. text
end

-- Clear display
function ACTION_HANDLERS.clearDisplay(device, params, codeObj)
    local display = device:FindFirstChild("VibeDisplay")
    if display then
        display:Destroy()
    end
    return true, "Display cleared"
end

-- Broadcast signal (Era 5+)
function ACTION_HANDLERS.broadcastSignal(device, params, codeObj)
    local signal = params.signal or params.message or "ping"

    -- Fire a global event that other devices can listen for
    local broadcastEvent = ReplicatedStorage:FindFirstChild("VibeBroadcast")
    if not broadcastEvent then
        broadcastEvent = Instance.new("BindableEvent")
        broadcastEvent.Name = "VibeBroadcast"
        broadcastEvent.Parent = ReplicatedStorage
    end
    broadcastEvent:Fire(signal, device.Name)

    device:SetAttribute("lastBroadcast", signal)

    return true, "Broadcast sent: " .. signal
end

-- Send message to specific device (Era 5+)
function ACTION_HANDLERS.sendMessage(device, params, codeObj)
    local targetName = params.target or params.recipient
    local message = params.message or params.value or ""

    local target = findDevice(targetName)
    if target then
        target:SetAttribute("receivedMessage", message)
        target:SetAttribute("messageFrom", device.Name)
    end

    return true, "Message sent to " .. tostring(targetName) .. ": " .. message
end

-- Relay message (mesh node)
function ACTION_HANDLERS.relayMessage(device, params, codeObj)
    -- Same as sendMessage but through mesh
    return ACTION_HANDLERS.sendMessage(device, params, codeObj)
end

-- Send to cloud (Era 5+)
function ACTION_HANDLERS.sendToCloud(device, params, codeObj)
    local data = params.data or params.value or {}

    -- POST to Worker relay for cloud logging
    pcall(function()
        Http.post("/api/vibe-cloud", {
            deviceName = device.Name,
            data = data,
            playerName = device:GetAttribute("ownerPlayer") or "unknown",
        })
    end)

    return true, "Data sent to cloud"
end

-- Receive from cloud (Era 5+)
function ACTION_HANDLERS.receiveFromCloud(device, params, codeObj)
    -- Poll Worker for cloud commands
    local response
    pcall(function()
        response = Http.get("/api/vibe-cloud/" .. device.Name)
    end)

    if response and response.command then
        return true, "Cloud command received: " .. response.command
    end

    return true, "No pending cloud commands"
end

-- Trigger agent (Era 6+)
function ACTION_HANDLERS.triggerAgent(device, params, codeObj)
    local task = params.task or params.value or "idle"

    device:SetAttribute("agentTask", task)
    device:SetAttribute("agentActive", true)

    return true, "Agent task assigned: " .. task
end

-- Assign task to agent
function ACTION_HANDLERS.assignTask(device, params, codeObj)
    return ACTION_HANDLERS.triggerAgent(device, params, codeObj)
end

-- Pause agent
function ACTION_HANDLERS.pauseAgent(device, params, codeObj)
    device:SetAttribute("agentActive", false)
    return true, "Agent paused"
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CODE OBJECT PARSING & EXECUTION
-- ═══════════════════════════════════════════════════════════════════════════

-- Parse a gamified code object into actionable parameters
local function parseCodeObject(codeObj)
    local parsed = {
        deviceName = codeObj.device,
        trigger = codeObj.trigger,
        action = codeObj.action,
        conditions = codeObj.conditions or {},
        loop = codeObj.loop or false,
        powerRequired = codeObj.powerRequired or 0,
        eraRequired = codeObj.eraRequired or 4,
        params = codeObj.params or {},
    }

    -- Extract action name and params from the action string
    -- e.g., "setBrightness(100%)" → action="setBrightness", params={brightness=1.0}
    if type(parsed.action) == "string" then
        local actionName, argStr = parsed.action:match("^(%w+)%((.*)%)$")
        if actionName then
            parsed.action = actionName
            -- Parse simple arguments
            if argStr then
                local arg = argStr:gsub("%%", ""):gsub('"', ''):gsub("'", "")
                -- Try number first
                local num = tonumber(arg)
                if num then
                    parsed.params.value = num
                else
                    parsed.params.value = arg
                end

                -- Map common arg names
                if actionName == "setBrightness" then
                    local pct = tonumber(arg)
                    parsed.params.brightness = pct and (pct / 100) or 1.0
                elseif actionName == "setMotorSpeed" then
                    local pct = tonumber(arg)
                    parsed.params.speed = pct and (pct / 100) or 0.5
                elseif actionName == "setMotorAngle" then
                    parsed.params.angle = tonumber(arg) or 0
                elseif actionName == "setColor" then
                    parsed.params.color = arg
                elseif actionName == "setState" then
                    parsed.params.state = (arg:lower() == "on" or arg:lower() == "true")
                elseif actionName == "playSound" then
                    parsed.params.soundId = arg
                elseif actionName == "displayText" then
                    parsed.params.text = arg
                end
            end
        end
    end

    return parsed
end

-- Evaluate a trigger condition against device state
local function evaluateTrigger(device, trigger)
    if not trigger then return true end -- No trigger = always active

    -- Parse trigger patterns:
    -- "light_sensor < 30%" → device attribute check
    -- "MotionSensor.detects(Player)" → proximity check
    -- "temperature > 30" → temp check

    -- Simple attribute comparison
    local attr, op, value = trigger:match("^(%w+)%s*([<>=!]+)%s*(%d+)")
    if attr and op and value then
        local attrValue = device:GetAttribute(attr) or 0
        value = tonumber(value)
        if op == "<" then return attrValue < value
        elseif op == ">" then return attrValue > value
        elseif op == "<=" then return attrValue <= value
        elseif op == ">=" then return attrValue >= value
        elseif op == "==" then return attrValue == value
        elseif op == "!=" then return attrValue ~= value
        end
    end

    -- Proximity detection pattern
    if trigger:match("detects") or trigger:match("proximity") then
        -- Check for nearby players
        local range = tonumber(trigger:match("(%d+)")) or 5
        local pos = device.Position
        for _, player in ipairs(Players:GetPlayers()) do
            local char = player.Character
            if char and char:FindFirstChild("HumanoidRootPart") then
                local dist = (char.HumanoidRootPart.Position - pos).Magnitude
                if dist <= range then
                    return true
                end
            end
        end
        return false
    end

    -- Default: assume condition is met
    return true
end

-- Execute a single vibe-code object
function VibeCodeExecutor.execute(player, codeObj, targetDeviceName)
    if not codeObj then
        return { success = false, reason = "No code object provided" }
    end

    local playerName = (typeof(player) == "Instance" and player.Name) or tostring(player)
    local parsed = parseCodeObject(codeObj)

    -- ═══ 1. VALIDATE ERA ═══
    local eraOk, eraErr = validateEra(playerName, parsed.eraRequired)
    if not eraOk then
        return {
            success = false,
            errorType = "era_locked",
            reason = eraErr,
        }
    end

    -- ═══ 2. FIND DEVICE ═══
    local device = findDevice(targetDeviceName or parsed.deviceName)
    if not device then
        return {
            success = false,
            errorType = "missing_hardware",
            reason = "Device '" .. tostring(targetDeviceName or parsed.deviceName) ..
                "' not found. Make sure it's built and wired up.",
        }
    end

    -- ═══ 3. VALIDATE POWER ═══
    local powerOk, powerErr = validatePower(device, parsed.powerRequired)
    if not powerOk then
        return {
            success = false,
            errorType = "no_power",
            reason = powerErr,
        }
    end

    -- ═══ 4. VALIDATE ACTION ═══
    local deviceType = getDeviceType(device)
    local actionOk, actionErr = validateAction(deviceType, parsed.action)
    if not actionOk then
        return {
            success = false,
            errorType = "unsupported_action",
            reason = actionErr,
        }
    end

    -- ═══ 5. EXECUTE ═══
    local handler = ACTION_HANDLERS[parsed.action]
    if not handler then
        -- Try matching by prefix
        for name, fn in pairs(ACTION_HANDLERS) do
            if parsed.action:match("^" .. name) then
                handler = fn
                break
            end
        end
    end

    if not handler then
        return {
            success = false,
            errorType = "no_handler",
            reason = "No executor found for action: " .. tostring(parsed.action),
        }
    end

    local ok, message = handler(device, parsed.params, codeObj)
    if not ok then
        return {
            success = false,
            errorType = "execution_failed",
            reason = message or "Execution failed",
        }
    end

    -- ═══ 6. HANDLE TRIGGER / LOOP ═══
    if parsed.loop and parsed.trigger then
        -- Stop existing loop for this device
        if activeLoops[device.Name] then
            activeLoops[device.Name] = nil
        end

        -- Start monitoring loop
        task.spawn(function()
            local lastTriggered = false
            while activeLoops[device.Name] ~= nil do
                local triggered = evaluateTrigger(device, parsed.trigger)
                if triggered and not lastTriggered then
                    handler(device, parsed.params, codeObj)
                elseif not triggered and lastTriggered then
                    -- Turn off when trigger deactivates
                    if deviceType and DEVICE_ACTIONS[deviceType] then
                        local hasOff = false
                        for _, a in ipairs(DEVICE_ACTIONS[deviceType]) do
                            if a == "stop" or a == "setState" then
                                if a == "stop" then
                                    ACTION_HANDLERS.stop(device, {}, codeObj)
                                else
                                    ACTION_HANDLERS.setState(device, { state = false }, codeObj)
                                end
                                hasOff = true
                                break
                            end
                        end
                        if not hasOff then
                            ACTION_HANDLERS.setBrightness(device, { brightness = 0 }, codeObj)
                        end
                    end
                end
                lastTriggered = triggered
                task.wait(0.5) -- Poll every 500ms
            end
        end)

        activeLoops[device.Name] = true -- Marker that loop is active
    elseif parsed.trigger and not parsed.loop then
        -- One-shot trigger: execute when condition is met
        task.spawn(function()
            while true do
                if evaluateTrigger(device, parsed.trigger) then
                    handler(device, parsed.params, codeObj)
                    break
                end
                task.wait(0.5)
            end
        end)
    end

    -- ═══ 7. STORE PROGRAM FOR PERSISTENCE ═══
    local program = {
        codeObj = codeObj,
        targetDevice = device.Name,
        playerName = playerName,
        timestamp = os.time(),
        active = true,
    }
    devicePrograms[device.Name] = program

    -- Set attribute on device
    device:SetAttribute("vibeProgram", HttpService:JSONEncode(codeObj))
    device:SetAttribute("vibeProgramActive", true)

    -- Persist to D1
    pcall(function()
        Http.post(MEMORY_URL .. "/api/vibe-program/save", {
            deviceName = device.Name,
            playerName = playerName,
            code = HttpService:JSONEncode(codeObj),
            active = true,
        })
    end)

    return {
        success = true,
        message = message or "Code deployed successfully",
        deviceName = device.Name,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PROGRAM MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

-- Get the stored program for a device
function VibeCodeExecutor.getProgram(deviceName)
    return devicePrograms[deviceName]
end

-- Stop a running program on a device
function VibeCodeExecutor.stopProgram(deviceName)
    -- Stop any active loops
    if activeLoops[deviceName] then
        activeLoops[deviceName] = nil
    end

    local program = devicePrograms[deviceName]
    if program then
        program.active = false
        local device = findDevice(deviceName)
        if device then
            device:SetAttribute("vibeProgramActive", false)
        end
    end

    return true
end

-- Load persisted programs from D1 on startup
function VibeCodeExecutor.loadPrograms()
    pcall(function()
        local response = Http.get(MEMORY_URL .. "/api/vibe-programs/all")
        if response and response.programs then
            for _, prog in ipairs(response.programs) do
                if prog.active then
                    devicePrograms[prog.deviceName] = {
                        codeObj = HttpService:JSONDecode(prog.code),
                        targetDevice = prog.deviceName,
                        playerName = prog.playerName,
                        timestamp = prog.timestamp,
                        active = true,
                    }

                    -- Re-activate the program
                    local device = findDevice(prog.deviceName)
                    if device then
                        device:SetAttribute("vibeProgramActive", true)
                        -- Re-execute to restore state
                        local parsed = parseCodeObject(devicePrograms[prog.deviceName].codeObj)
                        local handler = ACTION_HANDLERS[parsed.action]
                        if handler then
                            handler(device, parsed.params, devicePrograms[prog.deviceName].codeObj)
                        end
                    end
                end
            end
            print("[VibeCodeExecutor] Loaded " .. #response.programs .. " device programs")
        end
    end)
end

-- Get all active programs (for UI/dashboard)
function VibeCodeExecutor.getAllPrograms()
    local result = {}
    for name, prog in pairs(devicePrograms) do
        if prog.active then
            table.insert(result, {
                deviceName = name,
                playerName = prog.playerName,
                action = prog.codeObj.action or "unknown",
                trigger = prog.codeObj.trigger or "none",
                timestamp = prog.timestamp,
            })
        end
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REMOTE EVENT HANDLING
-- ═══════════════════════════════════════════════════════════════════════════

local function ensureRemoteEvent()
    local replicated = ReplicatedStorage:WaitForChild("Lucineer")
    local remote = replicated:FindFirstChild("VibeCodeRemote")

    if not remote then
        remote = Instance.new("RemoteEvent")
        remote.Name = "VibeCodeRemote"
        remote.Parent = replicated
    end

    return remote
end

local function setupRemoteHandlers()
    if not remoteEvent then return end

    remoteEvent.OnServerEvent:Connect(function(player, action, data)
        if action == "vibe_code_request" then
            -- Forward to Worker for AI processing
            local playerName = player.Name

            -- Validate era first
            local eraOk, eraErr = validateEra(playerName, data.era or 4)
            if not eraOk then
                remoteEvent:FireClient(player, "vibe_code_response", {
                    error = eraErr,
                    errorType = "era_locked",
                })
                return
            end

            -- Send to Worker for vibe-code generation
            local response, err = Http.post("/api/vibe-code", {
                playerName = playerName,
                message = data.message,
                sessionId = data.sessionId or "",
                commandType = "vibe_code",
                era = data.era or 4,
                availableComponents = data.availableComponents or {},
                targetDevice = data.targetDevice,
            })

            if response then
                remoteEvent:FireClient(player, "vibe_code_response", response)
            else
                remoteEvent:FireClient(player, "vibe_code_response", {
                    error = "Couldn't reach the relay. Try again.",
                    errorType = "network",
                })
            end

        elseif action == "vibe_code_deploy" then
            -- Execute the code on the target device
            local result = VibeCodeExecutor.execute(player, data.code, data.targetDevice)
            remoteEvent:FireClient(player, "deploy_result", result)

        elseif action == "vibe_code_export" then
            -- Generate real-world firmware
            local response, err = Http.post("/api/vibe-export", {
                code = data.code,
                playerName = data.playerName or player.Name,
                boardType = data.boardType or "arduino_uno",
            })

            if response and response.success then
                remoteEvent:FireClient(player, "export_result", {
                    success = true,
                    url = response.url,
                    id = response.id,
                })
            else
                remoteEvent:FireClient(player, "export_result", {
                    success = false,
                    error = (err or "Export failed"),
                })
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

function VibeCodeExecutor.init()
    if isInitialized then return end
    isInitialized = true

    -- Setup remote event
    remoteEvent = ensureRemoteEvent()

    -- Wire up handlers
    setupRemoteHandlers()

    -- Load persisted programs
    task.delay(5, function()
        VibeCodeExecutor.loadPrograms()
    end)

    -- Cleanup on player leave
    Players.PlayerRemoving:Connect(function(player)
        -- Programs persist; just clean up any per-player references
    end)

    print("[VibeCodeExecutor] Initialized — ready to execute vibe-code programs")
end

return VibeCodeExecutor
