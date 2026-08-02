--!strict
--[[
    VibeCoderDialogue — Deep-Dive Learning Interface
    =================================================
    When a player wants to learn the REAL code behind their gamified
    vibe-code, this module opens a chat interface with Glitch (the Coder
    agent) who explains the actual Arduino C++, MicroPython, or circuit
    design in detail.

    Features:
        - Toggle between SlackScript view and real code view
        - Interactive "Explain This" — click any line to get an explanation
        - 10 pre-built deep-dive dialogues covering different era concepts
        - Glitch's personality: enthusiastic, uses analogies, a bit snarky

    Usage:
        local VibeCoderDialogue = require(ReplicatedStorage.Lucineer.VibeCoderDialogue)
        VibeCoderDialogue.open(vibeCodeObject)

    Dependencies:
        - ReplicatedStorage.Lucineer.Http (for live deep-dive queries)
        - ReplicatedStorage.Lucineer.Config
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Http = require(script.Parent.Http)
local Config = require(script.Parent.Config)

-- ═══════════════════════════════════════════════════════════════════════════
-- THEME (matches VibeCoder)
-- ═══════════════════════════════════════════════════════════════════════════

local THEME = {
    bg          = Color3.fromRGB(12, 18, 28),
    bgPanel     = Color3.fromRGB(18, 26, 40),
    bgInput     = Color3.fromRGB(8, 14, 22),
    accent      = Color3.fromRGB(0, 255, 170),
    accentDim   = Color3.fromRGB(0, 140, 95),
    accentWarn  = Color3.fromRGB(255, 180, 0),
    accentError = Color3.fromRGB(255, 70, 70),
    text        = Color3.fromRGB(220, 230, 240),
    textDim     = Color3.fromRGB(130, 145, 160),
    textCode    = Color3.fromRGB(120, 220, 180),
    textKey     = Color3.fromRGB(100, 180, 255),
    textComment = Color3.fromRGB(100, 110, 120),
    textStr     = Color3.fromRGB(255, 200, 100),
    textNum     = Color3.fromRGB(200, 130, 255),
    textCPP     = Color3.fromRGB(140, 200, 255),
    border      = Color3.fromRGB(30, 45, 65),
}

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

local VibeCoderDialogue = {}

local dialogueGui = nil
local isOpen = false
local currentVibeCode = nil
local currentMode = "vibe" -- "vibe" | "cpp" | "python"
local chatScroll = nil
local codeScroll = nil
local inputBox = nil

-- ═══════════════════════════════════════════════════════════════════════════
-- DEEP-DIVE DATABASE — 10 EXAMPLE DIALOGUES
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Each dialogue covers a different era concept:
--   1. Digital Output (blink LED) — Era 4
--   2. Analog Input (light sensor) — Era 3-4
--   3. PWM / Motor Control — Era 4
--   4. If/Then Logic (conditional) — Era 3-4
--   5. Timers & Delays — Era 3-4
--   6. Serial Communication — Era 4-5
--   7. EEPROM / Data Persistence — Era 4
--   8. Interrupts — Era 4
--   9. I2C / LCD Display — Era 4
--  10. Networking (Wi-Fi / MQTT) — Era 5
--
-- Each entry contains:
--   topic       — short name
--   era         — which era this teaches
--   trigger     — keywords from player's vibe-code request that match
--   glitchIntro — Glitch's conversational opening
--   slackScript — the gamified version shown in VIBE MODE
--   realCode    — actual compilable Arduino C++ code
--   realPython  — actual MicroPython code
--   explanations — table of { linePattern, explanation } for "Explain This"
-- ─────────────────────────────────────────────────────────────────────────────

local DEEP_DIVES = {

    -- ═══ 1. DIGITAL OUTPUT (BLINK LED) ═══
    {
        topic = "blink",
        era = 4,
        trigger = { "blink", "light", "led", "turn on", "turn off", "flash" },
        glitchIntro = "Alright, let's pull back the curtain! You asked for light, and here's how the magic actually works in Arduino-land. It all starts with one beautiful little function called digitalWrite().",
        slackScript = [[-- Vibe-Code: Blink the LED
device = "LED_1"
trigger = "timer 0.5s"
action = "toggle(Light)"
loop = true
eraRequired = 4]],
        realCode = [[/*
 * Slackwater → Real World Firmware Export
 * Project: LED Blink
 * Board: Arduino Uno
 * Wiring: LED + 220Ω resistor on Pin 13
 */

#define LED_PIN 13

void setup() {
  // Configure pin 13 as an OUTPUT pin
  // "pinMode tells the guard at Gate 13 to throw things OUT"
  pinMode(LED_PIN, OUTPUT);
}

void loop() {
  // digitalWrite sends 5V (HIGH) to the pin — LED ON
  digitalWrite(LED_PIN, HIGH);

  // delay() pauses execution in milliseconds
  // 1000ms = 1 second
  delay(500);

  // digitalWrite sends 0V (LOW) to the pin — LED OFF
  digitalWrite(LED_PIN, LOW);

  delay(500);

  // loop() runs forever — this creates the blink pattern
}]],
        realPython = [[# Slackwater → MicroPython Export
# Project: LED Blink
# Board: Raspberry Pi Pico
from machine import Pin
import time

# GP15 → LED + 220Ω resistor
led = Pin(15, Pin.OUT)

while True:
    led.value(1)   # ON — 3.3V
    time.sleep(0.5)
    led.value(0)   # OFF — 0V
    time.sleep(0.5)]],
        explanations = {
            { pattern = "pinMode", text = "pinMode is like assigning a job to a pin. OUTPUT means 'send power out,' INPUT means 'listen for signals in.' Think of it as hiring someone for outbound sales vs. customer support." },
            { pattern = "digitalWrite", text = "digitalWrite is a binary switch: HIGH = 5 volts flowing, LOW = 0 volts stopped. That's it. Two states. On or off. The entire digital world is built on this." },
            { pattern = "delay", text = "delay() freezes the Arduino for a set number of milliseconds. It's the simplest timer — but the downside is the Arduino can't do ANYTHING else during the delay. We'll learn better ways later!" },
            { pattern = "void setup", text = "setup() runs exactly ONCE when you power on. It's like packing your backpack before school — set everything up, then get going." },
            { pattern = "void loop", text = "loop() runs FOREVER after setup(). Top to bottom, then back to top. It's the heartbeat of every Arduino program." },
            { pattern = "HIGH", text = "HIGH means 'set this pin to 5 volts.' For an LED, that pushes current through, and light happens. Physics!" },
        },
    },

    -- ═══ 2. ANALOG INPUT (LIGHT SENSOR) ═══
    {
        topic = "light_sensor",
        era = 4,
        trigger = { "light sensor", "dark", "bright", "photoresistor", "ldr", "light level" },
        glitchIntro = "Ooh, sensing the environment! This is where machines start to 'see.' A photoresistor changes its resistance based on light — more light, less resistance. The Arduino reads this as a number. Let me show you!",
        slackScript = [[-- Vibe-Code: Smart Streetlight
device = "Streetlight_1"
trigger = "light_sensor < 30%"
action = "setBrightness(100%)"
loop = true
eraRequired = 4]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: Smart Streetlight (LDR + LED)
 * Board: Arduino Uno
 * Wiring: LDR voltage divider on A0, LED on Pin 9 (PWM)
 */

#define SENSOR_PIN A0    // Analog input from LDR divider
#define LED_PIN 9        // PWM-capable output for dimming
#define THRESHOLD 300    // Below this = dark (0-1023 scale)

void setup() {
  pinMode(LED_PIN, OUTPUT);
  Serial.begin(9600);   // For debugging — watch values in Serial Monitor
}

void loop() {
  // analogRead returns 0 (0V) to 1023 (5V)
  int lightLevel = analogRead(SENSOR_PIN);

  Serial.print("Light: ");
  Serial.println(lightLevel);  // Watch the values change!

  if (lightLevel < THRESHOLD) {
    // It's dark — turn the light on full
    analogWrite(LED_PIN, 255);  // PWM: 0-255 duty cycle
  } else {
    // It's bright — turn the light off
    analogWrite(LED_PIN, 0);
  }

  delay(100);  // Small delay — don't read too fast
}]],
        realPython = [[# Slackwater → MicroPython
# Project: Smart Streetlight
from machine import ADC, Pin, PWM
import time

sensor = ADC(26)   # GP26 = ADC0
led = PWM(Pin(15))
led.freq(1000)

THRESHOLD = 300

while True:
    light_level = sensor.read_u16() >> 6  # Convert 16-bit to 10-bit
    print(f"Light: {light_level}")

    if light_level < THRESHOLD:
        led.duty_u16(65535)  # Full brightness
    else:
        led.duty_u16(0)      # Off

    time.sleep(0.1)]],
        explanations = {
            { pattern = "analogRead", text = "analogRead measures the VOLTAGE on an analog pin and converts it to a number 0-1023. 0 = 0V, 1023 = 5V. It uses an ADC (Analog-to-Digital Converter) — the bridge between the continuous physical world and digital numbers." },
            { pattern = "THRESHOLD", text = "THRESHOLD is a constant we chose — if the sensor reads below 300, we call it 'dark.' You'd calibrate this by watching the Serial Monitor and seeing what value your room light gives." },
            { pattern = "analogWrite", text = "analogWrite doesn't actually output analog voltage! It uses PWM (Pulse Width Modulation) — rapidly switching the pin on and off so fast that our eyes perceive it as dimmer or brighter. 255 = always on, 128 = half on, 0 = always off." },
            { pattern = "Serial.begin", text = "Serial.begin(9600) opens a communication channel between the Arduino and your computer. 9600 is the baud rate (bits per second). You can watch the output in the Arduino IDE's Serial Monitor." },
            { pattern = "Serial.print", text = "Serial.print sends text to your computer. It's the Arduino's version of print() — essential for debugging! If your sensor isn't working, Serial.print the values to see what's happening." },
        },
    },

    -- ═══ 3. MOTOR CONTROL (PWM/SERVO) ═══
    {
        topic = "motor",
        era = 4,
        trigger = { "motor", "servo", "spin", "rotate", "conveyor", "speed" },
        glitchIntro = "Motors! Now we're talking real machinery. A servo motor doesn't just spin — it goes to a specific angle and holds there. Perfect for robot arms, rudders, and... well, anything that needs to POINT somewhere.",
        slackScript = [[-- Vibe-Code: Solar Tracker
device = "SolarPanel_1"
trigger = "sun angle changed"
action = "setMotorAngle(90)"
loop = true
eraRequired = 4]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: Servo Motor Control
 * Board: Arduino Uno
 * Wiring: Servo signal wire on Pin 9, VCC to 5V, GND to GND
 */

#include <Servo.h>  // Arduino's built-in servo library

Servo myServo;       // Create a servo object
#define SERVO_PIN 9

void setup() {
  myServo.attach(SERVO_PIN);  // Connect servo to pin 9
  Serial.begin(9600);
}

void loop() {
  // Sweep from 0° to 180°
  for (int angle = 0; angle <= 180; angle += 5) {
    myServo.write(angle);     // Command servo to this angle
    Serial.print("Angle: ");
    Serial.println(angle);
    delay(50);                // Give servo time to reach position
  }

  // Sweep back from 180° to 0°
  for (int angle = 180; angle >= 0; angle -= 5) {
    myServo.write(angle);
    delay(50);
  }
}]],
        realPython = [[# Slackwater → MicroPython
# Project: Servo Motor Control
from machine import Pin, PWM
import time

# Servo on GP15
servo = PWM(Pin(15))
servo.freq(50)  # Servos expect 50Hz PWM

def set_angle(angle):
    # Convert angle (0-180) to duty cycle (1000-9000 μs)
    # Standard servo: 1ms = 0°, 2ms = 180°
    duty = int(1000 + (angle / 180) * 8000)
    servo.duty_u16(duty * 6)  # Scale to 16-bit

while True:
    for angle in range(0, 181, 5):
        set_angle(angle)
        time.sleep(0.05)
    for angle in range(180, -1, -5):
        set_angle(angle)
        time.sleep(0.05)]],
        explanations = {
            { pattern = "Servo.h", text = "The <Servo.h> library handles all the tricky PWM timing for you. A servo expects a pulse every 20ms — the pulse width (1-2ms) determines the angle. The library abstracts this into simple write(angle) calls." },
            { pattern = "attach", text = "attach() tells the servo object which pin to use. You can have multiple servos — each needs its own Servo object and pin. Arduino supports up to 12 servos on most boards." },
            { pattern = "write", text = "myServo.write(90) tells the servo to go to 90°. The servo has a tiny potentiometer inside that reports its current position. It adjusts the motor until actual position matches the command. That's a closed-loop feedback system!" },
            { pattern = "for", text = "The for loop creates the sweeping motion. Instead of jumping instantly to 180°, we step 5° at a time with a delay. This gives the servo physical time to move. Without delays, you'll strip gears!" },
        },
    },

    -- ═══ 4. CONDITIONAL LOGIC (IF/THEN) ═══
    {
        topic = "conditional",
        era = 3,
        trigger = { "if", "when", "condition", "sensor", "threshold", "temperature" },
        glitchIntro = "IF this THEN that — the foundation of ALL programming. Not just Arduino, not just C++. Every app, every website, every AI model — at their core, they're all just elaborate if-statements. Let me show you the real thing!",
        slackScript = [[-- Vibe-Code: Temperature Alarm
device = "Alarm_1"
trigger = "temperature > 30"
action = "playAlert(siren)"
loop = true
eraRequired = 3]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: Temperature Alarm with Hysteresis
 * Board: Arduino Uno
 * Wiring: TMP36 temp sensor on A0, Buzzer on Pin 8
 */

#define TEMP_PIN A0
#define BUZZER_PIN 8
#define ALARM_TEMP 30    // °C — sound alarm above this
#define CLEAR_TEMP 28    // °C — stop alarm below this (hysteresis)

bool alarmActive = false;

void setup() {
  pinMode(BUZZER_PIN, OUTPUT);
  Serial.begin(9600);
}

void loop() {
  // Read temperature from TMP36
  int rawValue = analogRead(TEMP_PIN);
  float voltage = rawValue * (5.0 / 1023.0);
  float tempC = (voltage - 0.5) * 100;  // TMP36: 10mV/°C, 500mV offset

  Serial.print("Temp: ");
  Serial.print(tempC);
  Serial.print("°C — Alarm: ");
  Serial.println(alarmActive ? "ACTIVE" : "OFF");

  // Hysteresis: different on/off thresholds prevent rapid toggling
  if (!alarmActive && tempC > ALARM_TEMP) {
    alarmActive = true;
    tone(BUZZER_PIN, 1000);  // 1kHz siren
  }

  if (alarmActive && tempC < CLEAR_TEMP) {
    alarmActive = false;
    noTone(BUZZER_PIN);       // Stop sound
  }

  delay(500);  // Read twice per second
}]],
        realPython = [[# Slackwater → MicroPython
# Project: Temperature Alarm
from machine import ADC, Pin
import time

temp_sensor = ADC(26)
buzzer = Pin(15, Pin.OUT)

ALARM_TEMP = 30
CLEAR_TEMP = 28
alarm_active = False

while True:
    raw = temp_sensor.read_u16()
    voltage = raw * (3.3 / 65535)
    temp_c = (voltage - 0.5) * 100

    print(f"Temp: {temp_c:.1f}°C — Alarm: {'ACTIVE' if alarm_active else 'OFF'}")

    if not alarm_active and temp_c > ALARM_TEMP:
        alarm_active = True
        buzzer.value(1)

    if alarm_active and temp_c < CLEAR_TEMP:
        alarm_active = False
        buzzer.value(0)

    time.sleep(0.5)]],
        explanations = {
            { pattern = "if", text = "if is the most important word in programming. It evaluates a condition (true/false) and only runs the code inside the braces if the condition is TRUE. Everything else in programming is just organizing if-statements." },
            { pattern = "hysteresis", text = "Hysteresis is why your home thermostat doesn't rapidly click on and off. The alarm triggers at 30° but only clears at 28°. This gap prevents the buzzer from stuttering when temperature hovers right at the threshold. Real engineering is full of these little tricks!" },
            { pattern = "tone", text = "tone(pin, frequency) generates a square wave at the given frequency. 1000Hz = a piercing beep. 440Hz = musical A note. The piezo buzzer vibrates at this frequency, creating sound waves in the air." },
            { pattern = "float", text = "float means 'floating point' — a number with decimals. We use it because analogRead gives us integers (0-1023) but the actual temperature calculation produces fractional values like 27.3°C." },
            { pattern = "bool", text = "bool means 'boolean' — it can only be true or false. alarmActive is our memory: 'are we currently in alarm mode?' Without this, we'd have to re-check every time, and the logic gets tangled." },
        },
    },

    -- ═══ 5. TIMERS & DELAYS ═══
    {
        topic = "timer",
        era = 3,
        trigger = { "timer", "wait", "delay", "schedule", "every", "interval" },
        glitchIntro = "Time is the one resource you can never get back. In Arduino-land, there are two ways to wait: the lazy way (delay) and the smart way (millis). Let me show you why the smart way matters!",
        slackScript = [[-- Vibe-Code: Sprinkler Timer
device = "Sprinkler_1"
trigger = "Time.Sunrise"
action = "start_motor(300s)"
loop = true
eraRequired = 3]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: Non-Blocking Timer (Sprinkler System)
 * Board: Arduino Uno
 *
 * Uses millis() instead of delay() so the Arduino
 * can do OTHER things while waiting.
 */

#define PUMP_PIN 7
#define INTERVAL 86400000UL  // 24 hours in ms (for daily schedule)
#define DURATION  300000UL   // 5 minutes in ms

unsigned long previousMillis = 0;
unsigned long pumpStartMillis = 0;
bool pumpRunning = false;

void setup() {
  pinMode(PUMP_PIN, OUTPUT);
  digitalWrite(PUMP_PIN, LOW);
  Serial.begin(9600);
}

void loop() {
  unsigned long currentMillis = millis();

  // Check if it's time to start the pump
  if (!pumpRunning && currentMillis - previousMillis >= INTERVAL) {
    previousMillis = currentMillis;
    pumpStartMillis = currentMillis;
    pumpRunning = true;

    digitalWrite(PUMP_PIN, HIGH);
    Serial.println("Pump ON — watering for 5 minutes");
  }

  // Check if the pump has run long enough
  if (pumpRunning && currentMillis - pumpStartMillis >= DURATION) {
    pumpRunning = false;
    digitalWrite(PUMP_PIN, LOW);
    Serial.println("Pump OFF — watering complete");
  }

  // The Arduino is FREE to do other things here!
  // With delay(), this wouldn't be possible.
  // Read sensors, update displays, listen for input...
}]],
        realPython = [[# Slackwater → MicroPython
# Project: Non-Blocking Timer
from machine import Pin
import time

pump = Pin(7, Pin.OUT)
INTERVAL = 86400  # 24 hours in seconds
DURATION = 300    # 5 minutes

last_run = time.time()
pump_start = 0
pump_running = False

while True:
    now = time.time()

    if not pump_running and (now - last_run) >= INTERVAL:
        last_run = now
        pump_start = now
        pump_running = True
        pump.value(1)
        print("Pump ON")

    if pump_running and (now - pump_start) >= DURATION:
        pump_running = False
        pump.value(0)
        print("Pump OFF")

    # Arduino is free to do other things here
    time.sleep(1)  # Just a small yield]],
        explanations = {
            { pattern = "millis", text = "millis() returns the number of milliseconds since the Arduino was powered on. It's like a stopwatch that never stops. By checking 'current time - previous time >= interval,' we can schedule events without freezing the whole program." },
            { pattern = "unsigned long", text = "unsigned long is a 32-bit whole number (0 to 4,294,967,295). We use it because millis() counts up rapidly — after 49 days, it wraps around! unsigned means 'never negative,' which is perfect for time." },
            { pattern = "delay", text = "delay() is the LAZY approach. It completely freezes the Arduino — no sensor reading, no button listening, nothing. For simple projects it's fine. For anything with multiple tasks, use millis() instead. This is a rite of passage for Arduino programmers!" },
            { pattern = "UL", text = "The UL suffix means 'Unsigned Long.' 86400000UL tells the compiler 'treat this as an unsigned long.' Without it, the Arduino might treat it as a regular int (max 32,767) and silently overflow. This is a classic Arduino bug!" },
        },
    },

    -- ═══ 6. SERIAL COMMUNICATION ═══
    {
        topic = "serial",
        era = 5,
        trigger = { "serial", "communicate", "send data", "uart", "message", "broadcast" },
        glitchIntro = "Serial communication is how devices TALK to each other. TX goes out, RX comes in. It's like a phone call between two Arduinos — or between an Arduino and your computer. Every USB cable is basically a serial connection!",
        slackScript = [[-- Vibe-Code: Device-to-Device Chat
device = "SensorNode_1"
trigger = "new data received"
action = "broadcastSignal(data)"
loop = true
eraRequired = 5]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: Serial Communication Between Two Arduinos
 * Board: Arduino Uno (x2)
 *
 * Wiring: Arduino A TX → Arduino B RX
 *         Arduino A RX → Arduino B TX
 *         COMMON GROUND (critical!)
 */

// ═══ SENDER (Arduino A) ═══
#define SENSOR_PIN A0

void setup() {
  Serial.begin(9600);    // USB to computer
  Serial1.begin(9600);   // Hardware serial to other Arduino
  // Note: Uno only has one hardware serial (Serial).
  // For two serial channels, use SoftwareSerial on other pins.
}

void loop() {
  int value = analogRead(SENSOR_PIN);

  // Send as formatted message with delimiter
  Serial1.print("DATA:");
  Serial1.println(value);

  Serial.print("Sent: ");
  Serial.println(value);

  delay(1000);
}

// ═══ RECEIVER (Arduino B) ═══
/*
#include <SoftwareSerial.h>
SoftwareSerial link(10, 11); // RX, TX

void setup() {
  Serial.begin(9600);
  link.begin(9600);
}

void loop() {
  if (link.available()) {
    String message = link.readStringUntil('\n');
    Serial.print("Received: ");
    Serial.println(message);

    // Parse the message
    if (message.startsWith("DATA:")) {
      String valueStr = message.substring(5);
      int value = valueStr.toInt();
      Serial.print("Parsed value: ");
      Serial.println(value);
    }
  }
}
*/]],
        explanations = {
            { pattern = "Serial.begin", text = "Serial.begin(9600) opens a serial channel. Think of it as picking up the phone and dialing. Both devices MUST use the same baud rate (9600), or they'll hear garbage." },
            { pattern = "TX", text = "TX (Transmit) sends data out. RX (Receive) listens for data coming in. The golden rule: connect TX→RX and RX→TX (cross over). TX to TX is like two people talking at the same time — nobody hears anything." },
            { pattern = "SoftwareSerial", text = "SoftwareSerial lets you create serial ports on any digital pin using software timing. It's slower than hardware serial but lets you have multiple connections. Perfect for reading GPS modules, Bluetooth boards, or talking to other Arduinos." },
            { pattern = "available", text = "Serial.available() returns how many bytes are waiting in the receive buffer. It's like checking your mailbox — if it's empty, there's nothing to read yet. This is the core of non-blocking serial receive." },
            { pattern = "COMMON GROUND", text = "Both devices MUST share a ground connection. Without it, the voltage signals have no reference point and you'll get random garbage. This is the #1 debugging step for serial communication — check your grounds!" },
        },
    },

    -- ═══ 7. DATA PERSISTENCE (EEPROM) ═══
    {
        topic = "eeprom",
        era = 4,
        trigger = { "save", "store", "remember", "persist", "eeprom", "memory" },
        glitchIntro = "What happens when the power goes out? RAM forgets everything. But EEPROM remembers — for up to 100 years! It's the Arduino's long-term memory. Let me show you how to save data that survives a reboot.",
        slackScript = [[-- Vibe-Code: Save Settings to Memory
device = "Controller_1"
trigger = "settings changed"
action = "saveToEEPROM(settings)"
eraRequired = 4]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: EEPROM Data Persistence
 * Board: Arduino Uno
 *
 * EEPROM: 1KB of non-volatile storage
 * Survives power cycles. Rated for 100,000 writes.
 */

#include <EEPROM.h>

// Store a settings struct in EEPROM
struct Settings {
  int threshold;
  float calibration;
  bool autoMode;
  unsigned long runCount;
};

#define EEPROM_ADDR 0  // Start writing at address 0

Settings currentSettings = {
  .threshold = 300,
  .calibration = 1.05,
  .autoMode = true,
  .runCount = 0,
};

void saveSettings() {
  // Write the struct byte-by-byte to EEPROM
  EEPROM.put(EEPROM_ADDR, currentSettings);
  Serial.println("Settings saved to EEPROM!");
}

void loadSettings() {
  Settings loaded;
  EEPROM.get(EEPROM_ADDR, loaded);

  // Validate: check if EEPROM has valid data
  // (first boot has all 0xFF = 255 for bytes)
  if (loaded.threshold > 0 && loaded.threshold < 1024) {
    currentSettings = loaded;
    Serial.println("Settings loaded from EEPROM");
    Serial.print("  Threshold: ");
    Serial.println(currentSettings.threshold);
    Serial.print("  Calibration: ");
    Serial.println(currentSettings.calibration);
    Serial.print("  Run count: ");
    Serial.println(currentSettings.runCount);
  } else {
    Serial.println("EEPROM empty — using defaults");
  }
}

void setup() {
  Serial.begin(9600);

  // Load saved settings on boot
  loadSettings();
}

void loop() {
  // Increment run counter each loop
  currentSettings.runCount++;

  // Save every 1000 loops (reduce EEPROM wear)
  if (currentSettings.runCount % 1000 == 0) {
    saveSettings();
  }

  delay(10);
}]],
        explanations = {
            { pattern = "EEPROM", text = "EEPROM (Electrically Erasable Programmable Read-Only Memory) is like a tiny hard drive on the Arduino. It holds 1KB of data that survives power loss. The catch? It's rated for only ~100,000 writes. Write too often and you'll wear it out!" },
            { pattern = "put", text = "EEPROM.put() writes any data type to EEPROM. It automatically handles the byte-by-byte conversion of structs, floats, etc. Under the hood, it uses EEPROM.write() for each byte." },
            { pattern = "get", text = "EEPROM.get() reads data back. It mirrors put() — give it the same address and data type, and it reconstructs your struct perfectly. Just make sure the struct layout hasn't changed between saves!" },
            { pattern = "100.000 writes", text = "EEPROM has a limited write lifetime — about 100,000 per cell. That sounds like a lot, but in a tight loop writing every millisecond, you'd kill it in 100 seconds! That's why we only save every 1000 loops, not every loop." },
            { pattern = "struct", text = "A struct groups related variables together. Instead of managing individual ints and floats, we pack them into one tidy package. EEPROM.put/get can save/load the entire struct in one call." },
        },
    },

    -- ═══ 8. INTERRUPTS ═══
    {
        topic = "interrupt",
        era = 4,
        trigger = { "interrupt", "instant", "immediately", "trigger", "button", "emergency" },
        glitchIntro = "Interrupts are the Arduino's version of reflexes — an INSTANT response to an event, no matter what the code is doing. It's like your hand jerking away from a hot stove before your brain even processes the pain. Let me show you how!",
        slackScript = [[-- Vibe-Code: Emergency Stop Button
device = "Motor_1"
trigger = "emergency_button pressed"
action = "stop(immediately)"
eraRequired = 4]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: Hardware Interrupt — Emergency Stop
 * Board: Arduino Uno
 *
 * Wiring: Push button on Pin 2 (Interrupt 0)
 *         Motor controller on Pin 9
 *
 * Hardware interrupts fire INSTANTLY,
 * regardless of what loop() is doing.
 */

#define MOTOR_PIN 9
#define BUTTON_PIN 2  // Pin 2 = Interrupt 0 on Uno

volatile bool emergencyStop = false;  // volatile = modified by ISR

void setup() {
  pinMode(MOTOR_PIN, OUTPUT);
  pinMode(BUTTON_PIN, INPUT_PULLUP);  // Internal pull-up resistor

  // Attach interrupt: trigger on FALLING edge
  // (button pressed = pin goes from HIGH to LOW)
  attachInterrupt(digitalPinToInterrupt(BUTTON_PIN),
                  emergencyISR, FALLING);

  Serial.begin(9600);
  Serial.println("System armed. Press button for E-STOP.");
}

// ═══ Interrupt Service Routine (ISR) ═══
// RULES FOR ISRs:
// 1. Keep it SHORT — no delay(), no Serial.print in real code
// 2. Only modify 'volatile' variables
// 3. Don't call functions that depend on interrupts
void emergencyISR() {
  emergencyStop = true;
  digitalWrite(MOTOR_PIN, LOW);  // Kill motor IMMEDIATELY
}

void loop() {
  if (emergencyStop) {
    Serial.println("!! EMERGENCY STOP ACTIVATED !!");
    Serial.println("Reset to continue.");
    while (true) {
      // Halt forever — requires physical reset
    }
  }

  // Normal operation: run the motor
  // Simulated PWM speed ramping
  for (int speed = 0; speed <= 255; speed += 5) {
    analogWrite(MOTOR_PIN, speed);

    // If button pressed during this loop,
    // interrupt fires and motor stops INSTANTLY
    // — even mid-iteration!
    if (emergencyStop) return;

    delay(50);
  }

  for (int speed = 255; speed >= 0; speed -= 5) {
    analogWrite(MOTOR_PIN, speed);
    if (emergencyStop) return;
    delay(50);
  }
}]],
        explanations = {
            { pattern = "attachInterrupt", text = "attachInterrupt connects a hardware pin to a function (ISR). When the pin changes state, the Arduino INSTANTLY stops whatever it's doing and runs the ISR. This is the closest thing to 'instant' in embedded programming." },
            { pattern = "volatile", text = "volatile tells the compiler: 'This variable can change at ANY time, outside the normal flow of code.' Without it, the compiler might optimize away the check in loop() because it doesn't see any code modifying emergencyStop there. The ISR modifies it asynchronously!" },
            { pattern = "ISR", text = "The Interrupt Service Routine must be FAST. No delay(), no Serial.print (in production), no complex calculations. Set a flag, do the critical action, get out. Everything else happens in loop() where interrupts are safe." },
            { pattern = "FALLING", text = "FALLING means 'trigger when the pin goes from HIGH to LOW.' With INPUT_PULLUP, the pin is normally HIGH (pulled up to 5V internally). When the button connects to ground, the pin FALLS to 0V — that's the trigger." },
            { pattern = "INPUT_PULLUP", text = "INPUT_PULLUP enables the Arduino's internal pull-up resistor (~20kΩ). The pin reads HIGH by default, and goes LOW when the button connects it to ground. This saves you from needing an external resistor!" },
        },
    },

    -- ═══ 9. I2C / LCD DISPLAY ═══
    {
        topic = "lcd",
        era = 4,
        trigger = { "lcd", "display", "screen", "show text", "i2c" },
        glitchIntro = "I2C (Inter-Integrated Circuit, pronounced 'eye-squared-see') is a brilliant protocol — just two wires for communication between dozens of devices! It's how your Arduino talks to displays, sensors, and real-time clocks. Let's light up a screen!",
        slackScript = [[-- Vibe-Code: Display Sensor Data
device = "LCD_1"
trigger = "new sensor reading"
action = "displayText(temperature)"
loop = true
eraRequired = 4]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: I2C LCD Display (16x2)
 * Board: Arduino Uno
 *
 * Wiring: LCD SDA → A4, LCD SCL → A5
 *         LCD VCC → 5V, LCD GND → GND
 *         I2C Address: 0x27 (common) or 0x3F
 *
 * Install: LiquidCrystal_I2C library
 */

#include <Wire.h>
#include <LiquidCrystal_I2C.h>

// Set LCD address (run I2C scanner to find yours)
LiquidCrystal_I2C lcd(0x27, 16, 2);

#define TEMP_PIN A0

void setup() {
  // Initialize LCD
  lcd.init();
  lcd.backlight();

  // Welcome message
  lcd.setCursor(0, 0);
  lcd.print("Slackwater OS");
  lcd.setCursor(0, 1);
  lcd.print("Booting...");

  delay(2000);
  lcd.clear();

  Serial.begin(9600);
}

void loop() {
  // Read temperature from TMP36
  int raw = analogRead(TEMP_PIN);
  float voltage = raw * (5.0 / 1023.0);
  float tempC = (voltage - 0.5) * 100;

  // Display on LCD
  lcd.setCursor(0, 0);
  lcd.print("Temp: ");
  lcd.print(tempC, 1);    // 1 decimal place
  lcd.print((char)223);   // Degree symbol
  lcd.print("C   ");      // Padding to clear old chars

  // Second line: status
  lcd.setCursor(0, 1);
  if (tempC > 30) {
    lcd.print("STATUS: HOT!  ");
  } else if (tempC < 10) {
    lcd.print("STATUS: COLD  ");
  } else {
    lcd.print("STATUS: OK    ");
  }

  // Also print to Serial for debugging
  Serial.print("Temp: ");
  Serial.print(tempC);
  Serial.println(" C");

  delay(1000);
}]],
        explanations = {
            { pattern = "Wire.h", text = "Wire.h is Arduino's I2C communication library. I2C uses just 2 signal wires: SDA (data) and SCL (clock). You can connect up to 127 devices on the same 2 wires — each has a unique address like 0x27." },
            { pattern = "SDA.*SCL", text = "SDA (Serial Data) carries the actual information. SCL (Serial Clock) is the timing heartbeat — every data bit is sent on a clock pulse. Think of SCL as a metronome and SDA as the singer following the beat." },
            { pattern = "0x27", text = "0x27 is the I2C address — a 7-bit hexadecimal number that identifies this specific device on the bus. The Arduino says 'Hey, 0x27, talk to me!' and only that LCD responds. Run an I2C scanner sketch to find your device's address." },
            { pattern = "setCursor", text = "setCursor(column, row) moves the text cursor. On a 16×2 display, columns are 0-15 and rows are 0-1. Characters after setCursor appear at that position." },
            { pattern = "223", text = "(char)223 is the degree symbol (°) in the LCD's character ROM. LCDs have a built-in font table, and 223 maps to °. Every display has special characters at specific codes — check the HD44780 datasheet!" },
        },
    },

    -- ═══ 10. NETWORKING (WIFI / MQTT) ═══
    {
        topic = "network",
        era = 5,
        trigger = { "wifi", "network", "internet", "mqtt", "cloud", "wireless", "connect" },
        glitchIntro = "Welcome to Era 5! This is where your devices leave the island and join the WORLD. Using Wi-Fi and MQTT, your Arduino can send data anywhere — to a phone, a server, even another Slackwater player's machine. The future is connected!",
        slackScript = [[-- Vibe-Code: IoT Weather Station
device = "WeatherStation_1"
trigger = "every 60 seconds"
action = "sendToCloud(weather_data)"
loop = true
eraRequired = 5]],
        realCode = [[/*
 * Slackwater → Real World Firmware
 * Project: Wi-Fi Weather Station with MQTT
 * Board: ESP32 (Wi-Fi enabled)
 *
 * Publishes temperature + humidity to an MQTT broker
 * every 60 seconds. Subscribe from anywhere!
 *
 * Libraries: WiFi.h, PubSubClient.h
 */

#include <WiFi.h>
#include <PubSubClient.h>
#include <DHT.h>

// ═══ Configuration ═══
const char* WIFI_SSID     = "YourNetwork";
const char* WIFI_PASSWORD = "YourPassword";
const char* MQTT_BROKER   = "broker.hivemq.com";
const int   MQTT_PORT     = 1883;

#define DHT_PIN 4
#define DHT_TYPE DHT22

// ═══ Objects ═══
WiFiClient espClient;
PubSubClient client(espClient);
DHT dht(DHT_PIN, DHT_TYPE);

unsigned long lastReport = 0;
const long REPORT_INTERVAL = 60000;  // 60 seconds

void connectWiFi() {
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Connecting to WiFi");

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }

  Serial.println();
  Serial.print("Connected! IP: ");
  Serial.println(WiFi.localIP());
}

void connectMQTT() {
  while (!client.connected()) {
    Serial.print("Connecting to MQTT...");
    String clientId = "Slackwater-" + String(random(0xffff), HEX);

    if (client.connect(clientId.c_str())) {
      Serial.println("Connected!");
      client.subscribe("slackwater/commands/#");
    } else {
      Serial.print("Failed, rc=");
      Serial.print(client.state());
      Serial.println(" — retrying in 5s");
      delay(5000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  dht.begin();

  connectWiFi();
  client.setServer(MQTT_BROKER, MQTT_PORT);
  client.setCallback([](char* topic, byte* payload, unsigned int length) {
    Serial.print("Command received: ");
    Serial.println(topic);
    // Handle incoming commands here
  });
}

void loop() {
  // Maintain connections
  if (WiFi.status() != WL_CONNECTED) connectWiFi();
  if (!client.connected()) connectMQTT();
  client.loop();

  // Report weather data on schedule
  unsigned long now = millis();
  if (now - lastReport >= REPORT_INTERVAL) {
    lastReport = now;

    float temp = dht.readTemperature();
    float humidity = dht.readHumidity();

    if (!isnan(temp) && !isnan(humidity)) {
      // Format as JSON
      char payload[100];
      snprintf(payload, sizeof(payload),
               "{\"temp\":%.1f,\"humidity\":%.1f}", temp, humidity);

      // Publish to MQTT topic
      client.publish("slackwater/weather", payload);
      Serial.print("Published: ");
      Serial.println(payload);
    }
  }
}]],
        realPython = [[# Slackwater → MicroPython (ESP32)
# Project: Wi-Fi Weather Station
import network, time, json
from machine import Pin
import dht

# Connect to Wi-Fi
wlan = network.WLAN(network.STA_IF)
wlan.active(True)
wlan.connect("YourNetwork", "YourPassword")

print("Connecting to WiFi...", end="")
while not wlan.isconnected():
    time.sleep(0.5)
    print(".", end="")
print(f"\nConnected! IP: {wlan.ifconfig()[0]}")

# MQTT via umqtt.simple
from umqtt.simple import MQTTClient
import dht
sensor = dht.DHT22(Pin(4))

CLIENT_ID = "Slackwater-" + str(int(time.time()) % 0xffff)

def connect_mqtt():
    while True:
        try:
            client = MQTTClient(CLIENT_ID, "broker.hivemq.com", 1883)
            client.connect()
            print("MQTT connected!")
            return client
        except Exception as e:
            print(f"MQTT failed: {e}, retrying...")
            time.sleep(5)

client = connect_mqtt()
last_report = 0

while True:
    if not wlan.isconnected():
        wlan.connect()
        time.sleep(5)
        continue

    now = time.time()
    if now - last_report >= 60:
        last_report = now
        try:
            sensor.measure()
            temp = sensor.temperature()
            humidity = sensor.humidity()
            payload = json.dumps({"temp": temp, "humidity": humidity})
            client.publish(b"slackwater/weather", payload.encode())
            print(f"Published: {payload}")
        except Exception as e:
            print(f"Sensor error: {e}")]],
        explanations = {
            { pattern = "WiFi.h", text = "WiFi.h is the ESP32's Wi-Fi library. The ESP32 has Wi-Fi built into the chip itself — no shield needed! It can be a client (connect to your router) or an access point (be its own hotspot)." },
            { pattern = "PubSubClient", text = "PubSubClient is the standard MQTT library for Arduino. MQTT uses a publish/subscribe model: devices PUBLISH data to topics (like 'slackwater/weather') and other devices SUBSCRIBE to those topics to receive the data. It's a message board for IoT devices." },
            { pattern = "MQTT", text = "MQTT (Message Queuing Telemetry Transport) is the #1 protocol for IoT. It's lightweight, works on bad connections, and uses a broker as a middleman. Devices don't talk directly — they publish to the broker, and the broker routes messages to subscribers." },
            { pattern = "WL_CONNECTED", text = "WL_CONNECTED is a status code meaning 'successfully connected to Wi-Fi.' Wi-Fi is notoriously flaky — you should ALWAYS check the status and reconnect if it drops. In production, wrap this in a robust reconnect function." },
            { pattern = "snprintf", text = "snprintf formats a string safely (unlike sprintf, it won't overflow the buffer). We use it to create JSON: {\"temp\":23.5,\"humidity\":65.0}. JSON is the universal language of APIs — even tiny IoT devices speak it." },
            { pattern = "callback", text = "The callback function handles INCOMING messages. When another device publishes to a topic you subscribed to, this function fires automatically. It's the subscriber side of MQTT — you listen for commands, not just send data." },
        },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- DEEP-DIVE MATCHING
-- ═══════════════════════════════════════════════════════════════════════════

-- Find the best matching deep-dive for a vibe-code object or query
function VibeCoderDialogue.findDeepDive(queryOrCode)
    local query = ""
    if type(queryOrCode) == "string" then
        query = queryOrCode:lower()
    elseif type(queryOrCode) == "table" then
        -- Combine relevant fields from the code object
        query = string.lower(
            (queryOrCode.action or "") .. " " ..
            (queryOrCode.trigger or "") .. " " ..
            (queryOrCode.request or "") .. " " ..
            (queryOrCode.device or "")
        )
    end

    local bestMatch = nil
    local bestScore = 0

    for _, dive in ipairs(DEEP_DIVES) do
        local score = 0
        for _, trigger in ipairs(dive.trigger) do
            if query:find(trigger, 1, true) then
                score = score + 1
            end
        end
        if score > bestScore then
            bestScore = score
            bestMatch = dive
        end
    end

    return bestMatch, bestScore
end

-- Get all deep-dives for a specific era
function VibeCoderDialogue.getByEra(eraNumber)
    local results = {}
    for _, dive in ipairs(DEEP_DIVES) do
        if dive.era == eraNumber then
            table.insert(results, dive)
        end
    end
    return results
end

-- Get all deep-dives
function VibeCoderDialogue.getAll()
    return DEEP_DIVES
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UI CONSTRUCTION
-- ═══════════════════════════════════════════════════════════════════════════

local function addBorder(parent, color, thickness)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color or THEME.border
    stroke.Thickness = thickness or 1
    stroke.Parent = parent
    return stroke
end

local function addCorner(parent, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 6)
    corner.Parent = parent
    return corner
end

local function buildDialogueGui()
    local player = Players.LocalPlayer
    local playerGui = player:WaitForChild("PlayerGui")

    local existing = playerGui:FindFirstChild("VibeCoderDialogue")
    if existing then existing:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "VibeCoderDialogue"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 101

    local container = Instance.new("Frame")
    container.Name = "Container"
    container.Size = UDim2.new(0, 800, 0, 560)
    container.Position = UDim2.new(0.5, -400, 0.5, -280)
    container.BackgroundColor3 = THEME.bg
    container.BorderSizePixel = 0
    container.Visible = false
    container.Parent = gui
    addCorner(container, 8)
    addBorder(container, THEME.textKey, 2)

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundColor3 = THEME.bgPanel
    titleBar.BorderSizePixel = 0
    titleBar.Parent = container
    addCorner(titleBar, 6)

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(0, 400, 0, 20)
    title.Position = UDim2.new(0, 12, 0, 4)
    title.Font = Enum.Font.Code
    title.Text = "Ġ DEEP DIVE — Glitch's Code Explainer"
    title.TextColor3 = THEME.textKey
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = titleBar

    local subtitle = Instance.new("TextLabel")
    subtitle.BackgroundTransparency = 1
    subtitle.Size = UDim2.new(0, 400, 0, 14)
    subtitle.Position = UDim2.new(0, 12, 0, 20)
    subtitle.Font = Enum.Font.Code
    subtitle.Text = "Click any line of code to learn what it does"
    subtitle.TextColor3 = THEME.textDim
    subtitle.TextSize = 11
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Parent = titleBar

    -- Close button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 24, 0, 24)
    closeBtn.Position = UDim2.new(1, -28, 0, 6)
    closeBtn.BackgroundColor3 = THEME.bgInput
    closeBtn.Text = "✕"
    closeBtn.Font = Enum.Font.Code
    closeBtn.TextSize = 14
    closeBtn.TextColor3 = THEME.accentError
    closeBtn.BorderSizePixel = 0
    closeBtn.Parent = titleBar
    addCorner(closeBtn, 4)

    -- Left pane: Chat with Glitch
    local leftPane = Instance.new("Frame")
    leftPane.Size = UDim2.new(0.4, -4, 1, -44)
    leftPane.Position = UDim2.new(0, 4, 0, 40)
    leftPane.BackgroundColor3 = THEME.bgPanel
    leftPane.BorderSizePixel = 0
    leftPane.Parent = container
    addCorner(leftPane, 6)
    addBorder(leftPane, THEME.border, 1)

    chatScroll = Instance.new("ScrollingFrame")
    chatScroll.Size = UDim2.new(1, -12, 1, -58)
    chatScroll.Position = UDim2.new(0, 6, 0, 6)
    chatScroll.BackgroundTransparency = 1
    chatScroll.ScrollBarThickness = 4
    chatScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    chatScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    chatScroll.Parent = leftPane

    local chatLayout = Instance.new("UIListLayout")
    chatLayout.Padding = UDim.new(0, 6)
    chatLayout.Parent = chatScroll

    inputBox = Instance.new("TextBox")
    inputBox.Size = UDim2.new(1, -12, 0, 40)
    inputBox.Position = UDim2.new(0, 6, 1, -46)
    inputBox.BackgroundColor3 = THEME.bgInput
    inputBox.Text = ""
    inputBox.PlaceholderText = "Ask Glitch about the code..."
    inputBox.Font = Enum.Font.Code
    inputBox.TextSize = 13
    inputBox.TextColor3 = THEME.text
    inputBox.PlaceholderColor3 = THEME.textDim
    inputBox.TextXAlignment = Enum.TextXAlignment.Left
    inputBox.TextYAlignment = Enum.TextYAlignment.Top
    inputBox.ClearTextOnFocus = false
    inputBox.Parent = leftPane
    addCorner(inputBox, 4)
    addBorder(inputBox, THEME.textKey, 1)

    -- Right pane: Code display
    local rightPane = Instance.new("Frame")
    rightPane.Size = UDim2.new(0.6, -4, 1, -44)
    rightPane.Position = UDim2.new(0.4, 0, 0, 40)
    rightPane.BackgroundColor3 = THEME.bgPanel
    rightPane.BorderSizePixel = 0
    rightPane.Parent = container
    addCorner(rightPane, 6)
    addBorder(rightPane, THEME.border, 1)

    -- Toggle bar
    local toggleBar = Instance.new("Frame")
    toggleBar.Size = UDim2.new(1, -12, 0, 28)
    toggleBar.Position = UDim2.new(0, 6, 0, 6)
    toggleBar.BackgroundTransparency = 1
    toggleBar.Parent = rightPane

    local toggleLayout = Instance.new("UIListLayout")
    toggleLayout.FillDirection = Enum.FillDirection.Horizontal
    toggleLayout.Padding = UDim.new(0, 4)
    toggleLayout.Parent = toggleBar

    local toggleButtons = {}
    local function makeToggle(text)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 130, 0, 24)
        btn.BackgroundColor3 = THEME.bgInput
        btn.Text = text
        btn.Font = Enum.Font.Code
        btn.TextSize = 11
        btn.TextColor3 = THEME.textDim
        btn.BorderSizePixel = 0
        btn.Parent = toggleBar
        addCorner(btn, 4)
        table.insert(toggleButtons, btn)
        return btn
    end

    local vibeBtn = makeToggle("VIBE MODE")
    local cppBtn = makeToggle("REAL CODE (C++)")
    local pyBtn = makeToggle("REAL CODE (PY)")

    codeScroll = Instance.new("ScrollingFrame")
    codeScroll.Size = UDim2.new(1, -12, 1, -40)
    codeScroll.Position = UDim2.new(0, 6, 0, 38)
    codeScroll.BackgroundTransparency = 1
    codeScroll.ScrollBarThickness = 4
    codeScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    codeScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    codeScroll.Parent = rightPane

    local codeLayout = Instance.new("UIListLayout")
    codeLayout.Padding = UDim.new(0, 1)
    codeLayout.Parent = codeScroll

    -- Set initial active toggle
    local function setActiveToggle(activeBtn)
        for _, btn in ipairs(toggleButtons) do
            btn.BackgroundColor3 = THEME.bgInput
            btn.TextColor3 = THEME.textDim
        end
        activeBtn.BackgroundColor3 = THEME.accentDim
        activeBtn.TextColor3 = THEME.text
    end
    setActiveToggle(vibeBtn)

    gui.Parent = playerGui

    return gui, container, closeBtn, vibeBtn, cppBtn, pyBtn, setActiveToggle
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CHAT RENDERING
-- ═══════════════════════════════════════════════════════════════════════════

local function addChatMessage(role, text)
    if not chatScroll then return end

    local msg = Instance.new("TextLabel")
    msg.BackgroundTransparency = 1
    msg.Size = UDim2.new(1, -4, 0, 0)
    msg.AutomaticSize = Enum.AutomaticSize.Y
    msg.TextWrapped = true
    msg.Font = Enum.Font.Code
    msg.TextSize = 12
    msg.TextXAlignment = Enum.TextXAlignment.Left
    msg.TextYAlignment = Enum.TextYAlignment.Top

    if role == "glitch" then
        msg.Text = "Ġ " .. text
        msg.TextColor3 = THEME.textKey
    elseif role == "player" then
        msg.Text = "» " .. text
        msg.TextColor3 = THEME.text
    else
        msg.Text = text
        msg.TextColor3 = THEME.textDim
    end

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 6)
    padding.PaddingRight = UDim.new(0, 6)
    padding.PaddingTop = UDim.new(0, 3)
    padding.PaddingBottom = UDim.new(0, 3)
    padding.Parent = msg

    msg.Parent = chatScroll

    task.defer(function()
        chatScroll.CanvasPosition = Vector2.new(0, math.huge)
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CODE RENDERING
-- ═══════════════════════════════════════════════════════════════════════════

local currentDeepDive = nil
local currentExplanations = nil

local function renderCodeLines(codeText, explanations)
    -- Clear existing
    for _, child in ipairs(codeScroll:GetChildren()) do
        if child:IsA("TextLabel") or child:IsA("TextButton") then
            child:Destroy()
        end
    end

    currentExplanations = explanations

    local lines = string.split(codeText, "\n")
    for lineNum, line in ipairs(lines) do
        local btn = Instance.new("TextButton")
        btn.BackgroundTransparency = 1
        btn.Size = UDim2.new(1, -4, 0, 16)
        btn.Text = line
        btn.Font = Enum.Font.Code
        btn.TextSize = 12
        btn.TextColor3 = THEME.textCode
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.TextYAlignment = Enum.TextYAlignment.Top
        btn.RichText = true
        btn.LayoutOrder = lineNum

        -- Color comments differently
        if line:match("^%s*//") or line:match("^%s*%-%-") or line:match("^%s*#") then
            btn.TextColor3 = THEME.textComment
        elseif line:match("^%s*$") then
            btn.Text = " "
        end

        -- Click to explain
        btn.MouseButton1Click:Connect(function()
            if explanations then
                for _, expl in ipairs(explanations) do
                    if line:find(expl.pattern) then
                        addChatMessage("glitch", expl.text)
                        return
                    end
                end
                -- No specific explanation for this line
                addChatMessage("glitch",
                    "Hmm, that line is pretty standard — nothing too tricky. " ..
                    "It's just part of the program structure. Anything specific about it you want to know?")
            end
        end)

        -- Hover effect
        btn.MouseEnter:Connect(function()
            btn.BackgroundTransparency = 0.8
            btn.BackgroundColor3 = THEME.textKey
        end)
        btn.MouseLeave:Connect(function()
            btn.BackgroundTransparency = 1
        end)

        btn.Parent = codeScroll
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SHOW DEEP DIVE
-- ═══════════════════════════════════════════════════════════════════════════

local function showDeepDive(dive)
    currentDeepDive = dive

    -- Glitch intro
    addChatMessage("glitch", dive.glitchIntro)
    addChatMessage("system", "Topic: " .. dive.topic .. " (Era " .. tostring(dive.era) ..
        ") — Click code lines to learn more.")

    -- Show SlackScript by default
    renderCodeLines(dive.slackScript, dive.explanations)
    currentMode = "vibe"
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPEN / CLOSE
-- ═══════════════════════════════════════════════════════════════════════════

function VibeCoderDialogue.open(vibeCodeObj)
    currentVibeCode = vibeCodeObj

    -- Build GUI if needed
    if not dialogueGui then
        local closeBtn, vibeBtn, cppBtn, pyBtn, setActiveToggle
        dialogueGui, _, closeBtn, vibeBtn, cppBtn, pyBtn, setActiveToggle = buildDialogueGui()

        -- Close button
        closeBtn.MouseButton1Click:Connect(function()
            VibeCoderDialogue.close()
        end)

        -- Toggle handlers
        vibeBtn.MouseButton1Click:Connect(function()
            if currentDeepDive then
                setActiveToggle(vibeBtn)
                currentMode = "vibe"
                renderCodeLines(currentDeepDive.slackScript, currentDeepDive.explanations)
            end
        end)

        cppBtn.MouseButton1Click:Connect(function()
            if currentDeepDive then
                setActiveToggle(cppBtn)
                currentMode = "cpp"
                renderCodeLines(currentDeepDive.realCode, currentDeepDive.explanations)
                addChatMessage("glitch",
                    "Here's the REAL Arduino C++ code! This would actually compile and run " ..
                    "on a physical Arduino board. Click any line to learn more.")
            end
        end)

        pyBtn.MouseButton1Click:Connect(function()
            if currentDeepDive then
                setActiveToggle(pyBtn)
                currentMode = "python"
                renderCodeLines(currentDeepDive.realPython, currentDeepDive.explanations)
                addChatMessage("glitch",
                    "And here's the MicroPython version! This runs on Raspberry Pi Pico " ..
                    "and ESP32. Different syntax, same logic. Python is friendlier to read!")
            end
        end)

        -- Input box: ask Glitch questions
        if inputBox then
            inputBox.FocusLost:Connect(function(enterPressed)
                if enterPressed then
                    local text = inputBox.Text
                    if #text > 0 then
                        inputBox.Text = ""
                        addChatMessage("player", text)
                        VibeCoderDialogue.askQuestion(text)
                    end
                end
            end)
        end
    end

    -- Show the GUI
    local container = dialogueGui:FindFirstChild("Container")
    if container then
        container.Visible = true
        isOpen = true

        -- Animate in
        container.Size = UDim2.new(0, 1, 0, 1)
        local tween = TweenService:Create(container,
            TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
            { Size = UDim2.new(0, 800, 0, 560) }
        )
        tween:Play()
    end

    -- Clear chat
    if chatScroll then
        for _, child in ipairs(chatScroll:GetChildren()) do
            if child:IsA("TextLabel") then
                child:Destroy()
            end
        end
    end

    -- Find matching deep-dive or show a generic one
    local dive, score = VibeCoderDialogue.findDeepDive(vibeCodeObj)
    if dive and score > 0 then
        showDeepDive(dive)
    else
        -- Default: show the first deep-dive as an introduction
        addChatMessage("glitch",
            "Hey boss! I'm not sure exactly what concept you're looking at, " ..
            "but let's start with the basics. Here's how digital output works — " ..
            "the foundation of everything we build!")
        showDeepDive(DEEP_DIVES[1])
    end
end

function VibeCoderDialogue.close()
    if not dialogueGui then return end
    local container = dialogueGui:FindFirstChild("Container")
    if container then
        local tween = TweenService:Create(container,
            TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.In),
            { Size = UDim2.new(0, 1, 0, 1) }
        )
        tween:Play()
        task.delay(0.25, function()
            container.Visible = false
        end)
    end
    isOpen = false
end

function VibeCoderDialogue.isOpen()
    return isOpen
end

-- ═══════════════════════════════════════════════════════════════════════════
-- QUESTION HANDLING
-- ═══════════════════════════════════════════════════════════════════════════

function VibeCoderDialogue.askQuestion(question)
    -- Try to find explanation in current deep-dive
    if currentDeepDive and currentDeepDive.explanations then
        local qLower = question:lower()
        for _, expl in ipairs(currentDeepDive.explanations) do
            if qLower:find(expl.pattern:lower(), 1, true) then
                addChatMessage("glitch", expl.text)
                return
            end
        end
    end

    -- Try matching to another deep-dive topic
    local dive = VibeCoderDialogue.findDeepDive(question)
    if dive then
        addChatMessage("glitch",
            "Ooh, that's a different topic! Let me pull up my notes on " ..
            dive.topic .. ".")
        showDeepDive(dive)
        return
    end

    -- Fallback: Glitch gives a generic helpful response
    local fallbackResponses = {
        "Great question! That's a bit beyond my pre-loaded notes, but here's the gist: in C++, everything boils down to setup() (run once) and loop() (run forever). If you understand those two functions, you understand Arduino.",
        "Hmm, let me think about that... The short answer is: it depends on the hardware. But the pattern is always the same — read an input, make a decision with if/then, control an output. That's 90% of Arduino programming!",
        "You know what, that's actually a really good question for the Historian agent. They know the full history of how these concepts evolved. But from a coding perspective: try it! Wire it up, write the code, and see what happens. Best way to learn.",
        "I love the curiosity, boss! For that level of detail, you might want to check out the Arduino Language Reference. But the key insight is: every complex system is just lots of simple if-statements and loops, stacked together like Lego bricks.",
    }
    local response = fallbackResponses[math.random(1, #fallbackResponses)]
    addChatMessage("glitch", response)

    -- In a full implementation, also send to Worker for LLM-powered answer
    task.spawn(function()
        local result, err = pcall(function()
            return Http.post("/api/vibe-deepdive", {
                question = question,
                topic = currentDeepDive and currentDeepDive.topic or "general",
                era = currentDeepDive and currentDeepDive.era or 4,
            })
        end)
        -- If we got a good response, add it as a follow-up
        if result and type(result) == "table" and result.answer then
            task.delay(1.0, function()
                addChatMessage("glitch", result.answer)
            end)
        end
    end)
end

return VibeCoderDialogue
