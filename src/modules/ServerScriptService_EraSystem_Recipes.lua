--!strict
--[[
    Recipes — Slackwater's Technology Recipe Database
    ==================================================
    145+ recipes across 7 technology eras.
    Each recipe defines the crafting inputs and outputs for a component.

    Format:
    {
        id          = unique string identifier
        era         = 0-6, which era this belongs to
        name        = display name
        category    = grouping tag (simple_machine, power, electrical, etc.)
        ingredients = { resource = amount, ... }
        output      = { type = "component", componentType = "..." }
        description = player-facing flavor text
        techNote    = real-world science fact
        agentTip    = in-character agent hint
    }

    Usage:
        local Recipes = require(ServerScriptService.EraSystem.Recipes)
        local all = Recipes.getAll()
        local byEra = Recipes.getByEra(2)
        local recipe = Recipes.get("generator")
        local results = Recipes.search("light")
]]

-- ═══════════════════════════════════════════════════════════════════════════
-- RECIPE DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════

local RECIPES = {}

-- Helper to register a recipe
local function r(def)
    table.insert(RECIPES, def)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 0: SIMPLE MACHINES (15 recipes)
-- ═══════════════════════════════════════════════════════════════════════════

r{ id = "lever", era = 0, name = "Lever", category = "simple_machine",
   ingredients = { wood = 2, stone = 1 },
   output = { type = "component", componentType = "lever" },
   description = "A rigid bar pivoting on a fulcrum. Multiplies force.",
   techNote = "Mechanical advantage = effort arm / load arm",
   agentTip = "The Mechanic says: everything else is just this with extra steps." }

r{ id = "pulley", era = 0, name = "Pulley", category = "simple_machine",
   ingredients = { wood = 3, rope = 2 },
   output = { type = "component", componentType = "pulley" },
   description = "A wheel with a grooved rim that changes the direction of a rope's pull.",
   techNote = "A block and tackle with N pulleys divides the force by N.",
   agentTip = "The Mechanic says: hang it high. The rope does the complaining for you." }

r{ id = "wheel", era = 0, name = "Wheel and Axle", category = "simple_machine",
   ingredients = { wood = 4, stone = 1 },
   output = { type = "component", componentType = "wheel" },
   description = "A circular frame that rotates around a central axle.",
   techNote = "The wheel reduces sliding friction to rolling friction.",
   agentTip = "The Mechanic says: you'd be surprised how long humans existed without this." }

r{ id = "wedge", era = 0, name = "Wedge", category = "simple_machine",
   ingredients = { wood = 1, stone = 2 },
   output = { type = "component", componentType = "wedge" },
   description = "A triangular tool that splits, lifts, or holds by converting force to lateral pressure.",
   techNote = "The wedge is two inclined planes joined back-to-back.",
   agentTip = "The Mechanic says: an axe is just a wedge with ambition." }

r{ id = "screw", era = 0, name = "Screw", category = "simple_machine",
   ingredients = { wood = 1, metal_fragment = 1 },
   output = { type = "component", componentType = "screw" },
   description = "An inclined plane wrapped around a cylinder. Converts rotation to linear force.",
   techNote = "Archimedes' screw moved water uphill 2,000 years ago.",
   agentTip = "The Mechanic says: it's a ramp in disguise. Everything is a ramp." }

r{ id = "inclined_plane", era = 0, name = "Inclined Plane", category = "simple_machine",
   ingredients = { wood = 3, stone = 2 },
   output = { type = "component", componentType = "inclined_plane" },
   description = "A flat surface tilted at an angle. Reduces the force needed to move loads upward.",
   techNote = "The longer the ramp, the less force required.",
   agentTip = "The Mechanic says: pyramids were built with this and stubbornness." }

r{ id = "waterwheel", era = 0, name = "Waterwheel", category = "compound_machine",
   ingredients = { wood = 8, stone = 4, rope = 3 },
   output = { type = "component", componentType = "waterwheel" },
   description = "A large wheel with buckets or blades, turned by flowing water.",
   techNote = "Undershot wheels use river current; overshot wheels use gravity-fed water.",
   agentTip = "The Mechanic says: find a stream with good flow. This is your first power source." }

r{ id = "windmill", era = 0, name = "Windmill", category = "compound_machine",
   ingredients = { wood = 6, cloth = 4, stone = 3 },
   output = { type = "component", componentType = "windmill" },
   description = "Sails or blades that capture wind energy and convert it to rotation.",
   techNote = "Post mills rotated the entire structure to face the wind.",
   agentTip = "The Mechanic says: higher ground, steadier wind. Don't cheap out on the sails." }

r{ id = "trip_hammer", era = 0, name = "Trip Hammer", category = "compound_machine",
   ingredients = { wood = 5, stone = 3, metal_fragment = 2 },
   output = { type = "component", componentType = "trip_hammer" },
   description = "A heavy hammer lifted by a cam and dropped by gravity. Automates pounding.",
   techNote = "Used in ancient China for forging and rice husking.",
   agentTip = "The Mechanic says: waterwheel + cam + heavy rock = automated smithing." }

r{ id = "bellows", era = 0, name = "Bellows", category = "simple_machine",
   ingredients = { wood = 2, leather = 3, rope = 1 },
   output = { type = "component", componentType = "bellows" },
   description = "A device that delivers pressurized air to a fire, increasing its heat.",
   techNote = "Higher airflow means higher combustion temperature — essential for smelting.",
   agentTip = "The Mechanic says: if your fire won't melt it, you need more air, not more wood." }

r{ id = "ladder", era = 0, name = "Ladder", category = "simple_machine",
   ingredients = { wood = 4, rope = 1 },
   output = { type = "component", componentType = "ladder" },
   description = "Two vertical rails connected by rungs. Essentially portable inclined steps.",
   techNote = "A ladder is two inclined planes you can climb.",
   agentTip = "The Mechanic says: not glamorous. You'll use it more than anything else here." }

r{ id = "ramp", era = 0, name = "Ramp", category = "simple_machine",
   ingredients = { wood = 3, stone = 3 },
   output = { type = "component", componentType = "ramp" },
   description = "A solid inclined plane built for moving heavy loads.",
   techNote = "Used in construction since prehistory — ramps scale better than lifting.",
   agentTip = "The Mechanic says: build it once, use it forever." }

r{ id = "wooden_gear", era = 0, name = "Wooden Gear", category = "simple_machine",
   ingredients = { wood = 3, stone = 1 },
   output = { type = "component", componentType = "wooden_gear" },
   description = "A toothed wheel that transfers rotation between shafts.",
   techNote = "Antikythera mechanism had precision bronze gears in 100 BCE.",
   agentTip = "The Mechanic says: rough wood, but it'll mesh. We'll make better later." }

r{ id = "cam", era = 0, name = "Cam", category = "simple_machine",
   ingredients = { wood = 2, metal_fragment = 1 },
   output = { type = "component", componentType = "cam" },
   description = "An eccentric wheel that converts rotational motion to reciprocating linear motion.",
   techNote = "Cams enabled automation centuries before electricity.",
   agentTip = "The Mechanic says: this is how you turn spinning into hammering." }

r{ id = "crank", era = 0, name = "Crank", category = "simple_machine",
   ingredients = { wood = 2, metal_fragment = 1 },
   output = { type = "component", componentType = "crank" },
   description = "An arm attached to a rotating shaft, converting reciprocal to rotary motion.",
   techNote = "The crank-handle appeared around 200 BCE in China and Rome.",
   agentTip = "The Mechanic says: it's the opposite of a cam. Spin to push, push to spin." }

r{ id = "fulcrum", era = 0, name = "Fulcrum", category = "simple_machine",
   ingredients = { stone = 3, wood = 1 },
   output = { type = "component", componentType = "fulcrum" },
   description = "A pivot point for a lever. The foundation of mechanical advantage.",
   techNote = "Moving the fulcrum closer to the load increases mechanical advantage.",
   agentTip = "The Mechanic says: the lever gets all the credit. The fulcrum does the work." }

r{ id = "axle", era = 0, name = "Axle", category = "simple_machine",
   ingredients = { wood = 3, metal_fragment = 1 },
   output = { type = "component", componentType = "axle" },
   description = "A central shaft for a rotating wheel. Reduces rotational friction.",
   techNote = "Greased bronze bearings reduce friction to near-zero rotational drag.",
   agentTip = "The Mechanic says: the wheel is useless without the axle. They're a package deal." }

r{ id = "rope", era = 0, name = "Rope", category = "simple_machine",
   ingredients = { fiber = 3 },
   output = { type = "component", componentType = "rope", amount = 3 },
   description = "Twisted fibers for tension loads. Essential for pulleys and bindings.",
   techNote = "Natural fiber ropes lose strength when wet; synthetics don't.",
   agentTip = "The Mechanic says: you'll tie more things together than you'll ever build." }

r{ id = "chisel", era = 0, name = "Chisel", category = "simple_machine",
   ingredients = { metal_fragment = 2, wood = 1 },
   output = { type = "component", componentType = "chisel" },
   description = "A wedge-edged cutting tool for carving stone and wood.",
   techNote = "A chisel is a controlled wedge — all force concentrated on one edge.",
   agentTip = "The Mechanic says: precision wedge work. Your stone projects need this." }

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 1: POWER TRANSMISSION (15 recipes)
-- ═══════════════════════════════════════════════════════════════════════════

r{ id = "driveshaft", era = 1, name = "Drive Shaft", category = "power",
   ingredients = { wood = 4, metal_fragment = 3 },
   output = { type = "component", componentType = "driveshaft" },
   description = "A long cylindrical shaft that transmits torque from a power source to machinery.",
   techNote = "Line shafts in 19th-century factories powered entire floors of machines.",
   agentTip = "The Millwright says: one waterwheel, twelve workstations. Run the math." }

r{ id = "belt_drive", era = 1, name = "Belt Drive", category = "power",
   ingredients = { leather = 3, wood = 2 },
   output = { type = "component", componentType = "belt_drive" },
   description = "A flexible belt looped over pulleys to transmit rotational power.",
   techNote = "Belt drives can step up or step down RPM by using different pulley diameters.",
   agentTip = "The Millwright says: tight enough to grip, loose enough to slip if something jams." }

r{ id = "chain_drive", era = 1, name = "Chain Drive", category = "power",
   ingredients = { metal_fragment = 5, wood = 1 },
   output = { type = "component", componentType = "chain_drive" },
   description = "A linked chain running over toothed sprockets. No slip, positive drive.",
   techNote = "Chain drives transmit more torque than belts and never slip.",
   agentTip = "The Millwright says: when belts aren't enough, chain up." }

r{ id = "gearbox", era = 1, name = "Gearbox", category = "power",
   ingredients = { metal_fragment = 6, wood = 2 },
   output = { type = "component", componentType = "gearbox" },
   description = "An assembly of gears that trades speed for torque (or vice versa).",
   techNote = "A 3:1 gear ratio triples torque but cuts output speed to one-third.",
   agentTip = "The Millwright says: decide what you need — speed or muscle. You can't have both." }

r{ id = "worm_gear", era = 1, name = "Worm Gear", category = "power",
   ingredients = { metal_fragment = 4, wood = 2 },
   output = { type = "component", componentType = "worm_gear" },
   description = "A screw-like gear that drives a wheel. High reduction, self-locking.",
   techNote = "Worm gears can achieve 100:1 reduction in a single stage.",
   agentTip = "The Millwright says: the screw turns, the wheel follows. It can't go backward." }

r{ id = "piston", era = 1, name = "Piston", category = "power",
   ingredients = { metal_fragment = 4, leather = 2, wood = 1 },
   output = { type = "component", componentType = "piston" },
   description = "A cylindrical component that moves linearly inside a cylinder, driven by pressure.",
   techNote = "Pistons convert pressure differential into linear force.",
   agentTip = "The Millwright says: seals matter. A leaky piston is a useless piston." }

r{ id = "flywheel", era = 1, name = "Flywheel", category = "power",
   ingredients = { metal_fragment = 5, stone = 3 },
   output = { type = "component", componentType = "flywheel" },
   description = "A heavy wheel that stores rotational energy, smoothing out power delivery.",
   techNote = "Flywheels resist changes in rotational speed via angular momentum.",
   agentTip = "The Millwright says: power comes in bursts. The flywheel spreads it out smooth." }

r{ id = "pipe", era = 1, name = "Pipe", category = "fluid",
   ingredients = { metal_fragment = 3 },
   output = { type = "component", componentType = "pipe" },
   description = "A hollow tube for transporting fluids under pressure.",
   techNote = "Roman aqueducts used gravity-fed pipes; modern pipes handle pressurized flow.",
   agentTip = "The Millwright says: water goes where you tell it — if the pipe doesn't leak." }

r{ id = "valve", era = 1, name = "Valve", category = "fluid",
   ingredients = { metal_fragment = 3, leather = 1 },
   output = { type = "component", componentType = "valve" },
   description = "A device that regulates, directs, or controls fluid flow.",
   techNote = "Check valves allow flow in one direction only.",
   agentTip = "The Millwright says: put valves everywhere. You'll thank yourself later." }

r{ id = "pressure_gauge", era = 1, name = "Pressure Gauge", category = "instrument",
   ingredients = { metal_fragment = 3, glass = 1 },
   output = { type = "component", componentType = "pressure_gauge" },
   description = "An instrument that measures fluid pressure in a system.",
   techNote = "Bourdon tube gauges use a curved tube that straightens under pressure.",
   agentTip = "The Millwright says: if you can't measure it, you can't trust it." }

r{ id = "coupling", era = 1, name = "Coupling", category = "power",
   ingredients = { metal_fragment = 2, leather = 1 },
   output = { type = "component", componentType = "coupling" },
   description = "A device that connects two shafts to transmit power while allowing misalignment.",
   techNote = "Flexible couplings absorb vibration and shaft misalignment.",
   agentTip = "The Millwright says: shafts never line up perfectly. Couplings forgive." }

r{ id = "clutch", era = 1, name = "Clutch", category = "power",
   ingredients = { metal_fragment = 4, leather = 2 },
   output = { type = "component", componentType = "clutch" },
   description = "A mechanism that engages and disengages power transmission between shafts.",
   techNote = "Friction clutches use surface contact to transfer torque.",
   agentTip = "The Millwright says: sometimes you need the machine to stop without stopping the power." }

r{ id = "differential", era = 1, name = "Differential", category = "power",
   ingredients = { metal_fragment = 6, wood = 2 },
   output = { type = "component", componentType = "differential" },
   description = "A gear system that allows two outputs to rotate at different speeds.",
   techNote = "Differentials allow wheels on the same axle to turn at different speeds in corners.",
   agentTip = "The Millwright says: the inside wheel travels less than the outside. This fixes that." }

r{ id = "escapement", era = 1, name = "Escapement", category = "instrument",
   ingredients = { metal_fragment = 4, wood = 1 },
   output = { type = "component", componentType = "escapement" },
   description = "A mechanism that releases energy in discrete steps, enabling clocks and timers.",
   techNote = "The verge escapement powered mechanical clocks for 400 years.",
   agentTip = "The Millwright says: tick... tick... tick. That's time, made mechanical." }

r{ id = "manometer", era = 1, name = "Manometer", category = "instrument",
   ingredients = { glass = 2, water = 1 },
   output = { type = "component", componentType = "manometer" },
   description = "A U-tube liquid column that measures pressure difference.",
   techNote = "A manometer measures pressure by the height difference of liquid columns.",
   agentTip = "The Millwright says: simple, accurate, no moving parts. The best instruments." }

r{ id = "turbine_water", era = 1, name = "Water Turbine", category = "power",
   ingredients = { metal_fragment = 6, wood = 3, axle = 1 },
   output = { type = "component", componentType = "turbine_water" },
   description = "An enclosed water-driven turbine. More efficient than an open waterwheel.",
   techNote = "Pelton wheels achieve 90% efficiency by using cup-shaped buckets.",
   agentTip = "The Millwright says: enclose the water, squeeze every drop of power." }

r{ id = "turbine_steam", era = 1, name = "Steam Turbine", category = "power",
   ingredients = { metal_fragment = 8, boiler = 1, valve = 2 },
   output = { type = "component", componentType = "turbine_steam" },
   description = "A turbine driven by high-pressure steam. The bridge to the electric age.",
   techNote = "Steam turbines convert thermal energy to rotational via expanding steam.",
   agentTip = "The Millwright says: boil water, spin blades, conquer the world." }

r{ id = "boiler", era = 1, name = "Boiler", category = "fluid",
   ingredients = { metal_fragment = 6, valve = 1, pipe = 2 },
   output = { type = "component", componentType = "boiler" },
   description = "A pressurized vessel that boils water to produce steam.",
   techNote = "Boilers must handle high pressure — safety valves are mandatory.",
   agentTip = "The Millwright says: respect the boiler. Or it will disrespect you." }

r{ id = "cogwheel", era = 1, name = "Cogwheel Assembly", category = "power",
   ingredients = { metal_fragment = 3, wooden_gear = 2 },
   output = { type = "component", componentType = "cogwheel" },
   description = "A precision metal gear assembly for high-torque applications.",
   techNote = "Involute gear teeth maintain constant contact ratio during meshing.",
   agentTip = "The Millwright says: wooden gears chatter. Metal gears sing." }

r{ id = "universal_joint", era = 1, name = "Universal Joint", category = "power",
   ingredients = { metal_fragment = 3, coupling = 1 },
   output = { type = "component", componentType = "universal_joint" },
   description = "A joint that allows a shaft to transmit torque at an angle.",
   techNote = "Cardan joints introduce speed fluctuations at operating angles.",
   agentTip = "The Millwright says: when the shafts won't line up, the U-joint saves the day." }

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 2: ELECTRICITY (20 recipes)
-- ═══════════════════════════════════════════════════════════════════════════

r{ id = "generator", era = 2, name = "Generator", category = "electrical",
   ingredients = { magnet = 4, copper_wire = 6, metal_fragment = 4 },
   output = { type = "component", componentType = "generator" },
   description = "Converts mechanical rotation into electrical energy via electromagnetic induction.",
   techNote = "Faraday's law: a changing magnetic field induces a voltage in a coil.",
   agentTip = "The Electrician says: spin copper through magnets, get lightning. Simple." }

r{ id = "wire", era = 2, name = "Copper Wire", category = "electrical",
   ingredients = { copper_ore = 2 },
   output = { type = "component", componentType = "wire", amount = 4 },
   description = "A conductive strand that carries electric current between components.",
   techNote = "Copper's low resistivity makes it the standard conductor worldwide.",
   agentTip = "The Electrician says: always use more wire than you think you need." }

r{ id = "switch", era = 2, name = "Switch", category = "electrical",
   ingredients = { metal_fragment = 2, wood = 1 },
   output = { type = "component", componentType = "switch" },
   description = "A device that opens or closes an electrical circuit.",
   techNote = "A switch is just a controlled break in a wire.",
   agentTip = "The Electrician says: wire it inline. Up is on, down is off. Usually." }

r{ id = "lamp", era = 2, name = "Lamp", category = "electrical",
   ingredients = { glass = 2, metal_fragment = 2, copper_wire = 2 },
   output = { type = "component", componentType = "lamp" },
   description = "A lightbulb that converts electrical energy into visible light.",
   techNote = "Incandescent bulbs heat a filament until it glows; LEDs use semiconductor junctions.",
   agentTip = "The Electrician says: no more torches. Welcome to the future." }

r{ id = "motor", era = 2, name = "Electric Motor", category = "electrical",
   ingredients = { magnet = 3, copper_wire = 4, metal_fragment = 4 },
   output = { type = "component", componentType = "motor" },
   description = "Converts electrical energy into mechanical rotation.",
   techNote = "A motor is a generator in reverse — current in, rotation out.",
   agentTip = "The Electrician says: the waterwheel's replacement. Cleaner, quieter, precise." }

r{ id = "heating_element", era = 2, name = "Heating Element", category = "electrical",
   ingredients = { metal_fragment = 3, ceramic = 1 },
   output = { type = "component", componentType = "heating_element" },
   description = "A resistive component that converts electricity into heat.",
   techNote = "Nichrome wire resists oxidation at high temperatures.",
   agentTip = "The Electrician says: push current through resistance, get heat. Forge without fire." }

r{ id = "electromagnet", era = 2, name = "Electromagnet", category = "electrical",
   ingredients = { iron_bar = 1, copper_wire = 3 },
   output = { type = "component", componentType = "electromagnet" },
   description = "A magnet controlled by electric current — on when powered, off when not.",
   techNote = "Electromagnets can be 100x stronger than permanent magnets.",
   agentTip = "The Electrician says: lift scrap, sort metal, build relays. Endlessly useful." }

r{ id = "transformer", era = 2, name = "Transformer", category = "electrical",
   ingredients = { iron_bar = 2, copper_wire = 5 },
   output = { type = "component", componentType = "transformer" },
   description = "Steps voltage up or down using two coils on a shared iron core.",
   techNote = "Power = V×I. Step up voltage, step down current — same power, less loss.",
   agentTip = "The Electrician says: the grid doesn't work without these." }

r{ id = "battery", era = 2, name = "Battery", category = "electrical",
   ingredients = { zinc = 2, copper_ore = 2, acid = 1 },
   output = { type = "component", componentType = "battery" },
   description = "Stores chemical energy and releases it as electricity.",
   techNote = "Volta's pile (1800) was the first battery — alternating zinc and copper discs.",
   agentTip = "The Electrician says: electricity you can carry. The generator doesn't run at night." }

r{ id = "fuse", era = 2, name = "Fuse", category = "electrical",
   ingredients = { metal_fragment = 1, glass = 1 },
   output = { type = "component", componentType = "fuse" },
   description = "A sacrificial device that melts to break a circuit during overcurrent.",
   techNote = "A fuse is intentional failure point — it dies so the rest survives.",
   agentTip = "The Electrician says: it's the cheapest insurance you'll ever buy." }

r{ id = "circuit_breaker", era = 2, name = "Circuit Breaker", category = "electrical",
   ingredients = { metal_fragment = 3, electromagnet = 1 },
   output = { type = "component", componentType = "circuit_breaker" },
   description = "A resettable switch that trips during overcurrent, unlike a fuse.",
   techNote = "Breakers use a bimetallic strip or solenoid to detect overcurrent.",
   agentTip = "The Electrician says: like a fuse, but you don't have to replace it." }

r{ id = "buzzer", era = 2, name = "Buzzer", category = "electrical",
   ingredients = { metal_fragment = 2, copper_wire = 2, ceramic = 1 },
   output = { type = "component", componentType = "buzzer" },
   description = "An electromechanical device that produces a loud buzzing tone.",
   techNote = "Piezoelectric buzzers use a vibrating crystal disk.",
   agentTip = "The Electrician says: annoying on purpose. That's the point." }

r{ id = "solenoid", era = 2, name = "Solenoid", category = "electrical",
   ingredients = { copper_wire = 4, iron_bar = 1, spring = 1 },
   output = { type = "component", componentType = "solenoid" },
   description = "A linear actuator: an electromagnetic coil that pulls a plunger.",
   techNote = "Solenoids convert electrical signals into mechanical push/pull.",
   agentTip = "The Electrician says: electric finger. Push, pull, lock, unlock." }

r{ id = "simple_relay", era = 2, name = "Relay (Simple)", category = "electrical",
   ingredients = { electromagnet = 1, metal_fragment = 2, spring = 1 },
   output = { type = "component", componentType = "simple_relay" },
   description = "An electrically operated switch. Low power controls high power.",
   techNote = "Relays are the foundation of all logic and control systems.",
   agentTip = "The Electrician says: this is the seed of every computer you'll ever build." }

r{ id = "capacitor", era = 2, name = "Capacitor", category = "electrical",
   ingredients = { metal_fragment = 2, wax = 1, paper = 1 },
   output = { type = "component", componentType = "capacitor" },
   description = "Stores electrical energy in an electric field between two plates.",
   techNote = "Capacitors smooth voltage ripple and provide burst current.",
   agentTip = "The Electrician says: a tiny bucket for electricity. Fills fast, empties fast." }

r{ id = "resistor", era = 2, name = "Resistor", category = "electrical",
   ingredients = { carbon = 1, metal_fragment = 1, ceramic = 1 },
   output = { type = "component", componentType = "resistor" },
   description = "Limits current flow. The most basic component in electronics.",
   techNote = "Ohm's law: V = I × R. Resistors convert excess current to heat.",
   agentTip = "The Electrician says: without these, every LED dies instantly." }

r{ id = "diode", era = 2, name = "Diode", category = "electrical",
   ingredients = { semiconductor = 1, metal_fragment = 1 },
   output = { type = "component", componentType = "diode" },
   description = "Allows current in one direction only. A one-way valve for electricity.",
   techNote = "PN junction diodes have a 0.7V forward voltage drop.",
   agentTip = "The Electrician says: relays are slow. Diodes are instant." }

r{ id = "copper_ore_refined", era = 2, name = "Refined Copper", category = "electrical",
   ingredients = { copper_ore = 3, heating_element = 1 },
   output = { type = "component", componentType = "copper_wire", amount = 6 },
   description = "Smelt raw copper ore into pure copper wire stock.",
   techNote = "Electrolytic refining produces 99.99% pure copper.",
   agentTip = "The Electrician says: raw ore won't conduct. Purify it first." }

r{ id = "voltmeter", era = 2, name = "Voltmeter", category = "instrument",
   ingredients = { wire = 3, metal_fragment = 2, glass = 1 },
   output = { type = "component", componentType = "voltmeter" },
   description = "Measures electrical voltage. Essential for debugging circuits.",
   techNote = "Ideal voltmeters have infinite internal resistance.",
   agentTip = "The Electrician says: 'is there power?' The voltmeter answers." }

r{ id = "ammeter", era = 2, name = "Ammeter", category = "instrument",
   ingredients = { wire = 2, metal_fragment = 2, glass = 1 },
   output = { type = "component", componentType = "ammeter" },
   description = "Measures electrical current flowing through a circuit.",
   techNote = "Ideal ammeters have zero internal resistance.",
   agentTip = "The Electrician says: voltage is pressure. Current is flow. Measure both." }

r{ id = "led", era = 2, name = "LED", category = "electrical",
   ingredients = { semiconductor = 1, metal_fragment = 1, glass = 1 },
   output = { type = "component", componentType = "led" },
   description = "A light-emitting diode. Efficient, instant, directional light.",
   techNote = "LEDs emit photons when electrons cross the PN junction.",
   agentTip = "The Electrician says: the future of lighting. Uses 1/10th the power of a bulb." }

r{ id = "inductor", era = 2, name = "Inductor", category = "electrical",
   ingredients = { iron_bar = 1, copper_wire = 3 },
   output = { type = "component", componentType = "inductor" },
   description = "A coil that stores energy in a magnetic field. Resists current changes.",
   techNote = "V = L × (di/dt). Inductors oppose changes in current flow.",
   agentTip = "The Electrician says: the inductor is the capacitor's opposite. It fights change." }

r{ id = "rheostat", era = 2, name = "Rheostat", category = "electrical",
   ingredients = { resistor = 2, metal_fragment = 2, ceramic = 1 },
   output = { type = "component", componentType = "rheostat" },
   description = "A variable resistor. Dial in the exact resistance you need.",
   techNote = "Rheostats use a wiper on a resistive track to vary resistance continuously.",
   agentTip = "The Electrician says: dim the lights, throttle the motor. Adjustable resistance." }

r{ id = "ground_rod", era = 2, name = "Ground Rod", category = "electrical",
   ingredients = { metal_fragment = 3, copper_wire = 1 },
   output = { type = "component", componentType = "ground_rod" },
   description = "An earth connection that safely dissipates excess current. Safety first.",
   techNote = "Grounding provides a zero-voltage reference and fault current path.",
   agentTip = "The Electrician says: if you skip this, your house burns down. Period." }

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 3: CONTROL SYSTEMS (18 recipes)
-- ═══════════════════════════════════════════════════════════════════════════

r{ id = "logic_gate_and", era = 3, name = "AND Gate", category = "control",
   ingredients = { simple_relay = 2, copper_wire = 2 },
   output = { type = "component", componentType = "logic_gate_and" },
   description = "Output is ON only when both inputs are ON. Series relays.",
   techNote = "AND gates can be built from two relays in series.",
   agentTip = "The Logician says: both conditions must be true. Door AND key. Power AND enable." }

r{ id = "logic_gate_or", era = 3, name = "OR Gate", category = "control",
   ingredients = { simple_relay = 2, copper_wire = 2 },
   output = { type = "component", componentType = "logic_gate_or" },
   description = "Output is ON when either input is ON. Parallel relays.",
   techNote = "OR gates use relays in parallel — either one energizes the output.",
   agentTip = "The Logician says: either button works. Either sensor triggers it." }

r{ id = "logic_gate_not", era = 3, name = "NOT Gate (Inverter)", category = "control",
   ingredients = { simple_relay = 1, copper_wire = 1 },
   output = { type = "component", componentType = "logic_gate_not" },
   description = "Output is the opposite of input. A normally-closed relay.",
   techNote = "NOT gates use a normally-closed contact — power until activated.",
   agentTip = "The Logician says: the simplest gate. Input on, output off. Input off, output on." }

r{ id = "timer_circuit", era = 3, name = "Timer Circuit", category = "control",
   ingredients = { capacitor = 2, simple_relay = 1, resistor = 1 },
   output = { type = "component", componentType = "timer_circuit" },
   description = "Delays an action by a set interval. RC charging through a relay.",
   techNote = "RC time constant = resistance × capacitance. Controls the delay.",
   agentTip = "The Logician says: 'wait 5 seconds, then activate.' That's it. That's all it does." }

r{ id = "light_sensor", era = 3, name = "Light Sensor", category = "sensor",
   ingredients = { photoresistor = 1, copper_wire = 2 },
   output = { type = "component", componentType = "light_sensor" },
   description = "Detects ambient light levels. Resistance drops in bright light.",
   techNote = "Photoresistors (LDRs) use cadmium sulfide — conductance increases with light.",
   agentTip = "The Logician says: 'is it dark?' Now the machine knows the answer." }

r{ id = "proximity_sensor", era = 3, name = "Proximity Sensor", category = "sensor",
   ingredients = { electromagnet = 1, copper_wire = 2, metal_fragment = 1 },
   output = { type = "component", componentType = "proximity_sensor" },
   description = "Detects nearby objects without physical contact.",
   techNote = "Inductive proximity sensors detect metal; capacitive sensors detect any material.",
   agentTip = "The Logician says: the machine can feel something coming close. No eyes needed." }

r{ id = "temperature_sensor", era = 3, name = "Temperature Sensor", category = "sensor",
   ingredients = { metal_fragment = 2, copper_wire = 2 },
   output = { type = "component", componentType = "temperature_sensor" },
   description = "Measures temperature via a thermocouple (junction of dissimilar metals).",
   techNote = "Thermocouples generate a small voltage proportional to temperature.",
   agentTip = "The Logician says: 'is it too hot?' The furnace asks itself now." }

r{ id = "pressure_switch", era = 3, name = "Pressure Switch", category = "sensor",
   ingredients = { diaphragm = 1, metal_fragment = 2, spring = 1 },
   output = { type = "component", componentType = "pressure_switch" },
   description = "Closes or opens a contact when fluid pressure crosses a threshold.",
   techNote = "Pressure switches guard boilers, compressors, and hydraulic systems.",
   agentTip = "The Logician says: 'too much pressure — shut it down!' Automatically." }

r{ id = "remote_trigger", era = 3, name = "Remote Trigger", category = "control",
   ingredients = { simple_relay = 1, antenna = 1, copper_wire = 3 },
   output = { type = "component", componentType = "remote_trigger" },
   description = "Wirelessly activates a circuit from a distance.",
   techNote = "Early remote controls used radio pulses to toggle relays.",
   agentTip = "The Logician says: push a button here, something happens over there." }

r{ id = "counter", era = 3, name = "Counter", category = "control",
   ingredients = { flip_flop = 2, copper_wire = 2 },
   output = { type = "component", componentType = "counter" },
   description = "Counts input pulses and outputs a binary value.",
   techNote = "Ripple counters chain flip-flops: each overflow clocks the next stage.",
   agentTip = "The Logician says: 'how many came through?' The machine keeps tally." }

r{ id = "flip_flop", era = 3, name = "Flip-Flop", category = "control",
   ingredients = { logic_gate_not = 2, logic_gate_or = 1, copper_wire = 2 },
   output = { type = "component", componentType = "flip_flop" },
   description = "A bistable circuit that stores one bit. The foundation of memory.",
   techNote = "An SR latch holds state until explicitly set or reset.",
   agentTip = "The Logician says: it remembers ONE thing. On or off. That's memory." }

r{ id = "multiplexer", era = 3, name = "Multiplexer", category = "control",
   ingredients = { logic_gate_and = 4, logic_gate_or = 1, copper_wire = 4 },
   output = { type = "component", componentType = "multiplexer" },
   description = "Selects one of several inputs and routes it to a single output.",
   techNote = "A 4:1 MUX uses 2 select lines to choose among 4 data inputs.",
   agentTip = "The Logician says: a traffic cop for signals. One out of many." }

r{ id = "decoder", era = 3, name = "Decoder", category = "control",
   ingredients = { logic_gate_and = 4, logic_gate_not = 2, copper_wire = 3 },
   output = { type = "component", componentType = "decoder" },
   description = "Converts a binary code into a specific output line.",
   techNote = "A 2-to-4 decoder activates exactly one of four outputs based on the input.",
   agentTip = "The Logician says: 'which one?' The decoder points." }

r{ id = "adc", era = 3, name = "Analog-to-Digital Converter", category = "control",
   ingredients = { comparator = 4, resistor = 4, copper_wire = 3 },
   output = { type = "component", componentType = "adc" },
   description = "Converts a continuous analog voltage into a discrete digital number.",
   techNote = "Flash ADCs use a ladder of comparators for instant conversion.",
   agentTip = "The Logician says: the analog world meets the digital one. Right here." }

r{ id = "dac", era = 3, name = "Digital-to-Analog Converter", category = "control",
   ingredients = { resistor = 4, copper_wire = 3 },
   output = { type = "component", componentType = "dac" },
   description = "Converts a digital number into an analog voltage.",
   techNote = "An R-2R ladder DAC uses only two resistor values.",
   agentTip = "The Logician says: numbers become voltages. Digital meets physical." }

r{ id = "comparator", era = 3, name = "Comparator", category = "control",
   ingredients = { diode = 2, resistor = 2, copper_wire = 2 },
   output = { type = "component", componentType = "comparator" },
   description = "Compares two voltages and outputs which is higher.",
   techNote = "Op-amp comparators switch state when inputs cross by millivolts.",
   agentTip = "The Logician says: 'is this more than that?' One bit of judgment." }

r{ id = "oscillator", era = 3, name = "Oscillator Circuit", category = "control",
   ingredients = { capacitor = 2, resistor = 2, simple_relay = 1 },
   output = { type = "component", componentType = "oscillator" },
   description = "Generates a repeating signal. Clock pulses for digital circuits.",
   techNote = "Relaxation oscillators charge/discharge a capacitor through a resistor.",
   agentTip = "The Logician says: tick-tock-tick-tock. The heartbeat of every machine." }

r{ id = "schmitt_trigger", era = 3, name = "Schmitt Trigger", category = "control",
   ingredients = { comparator = 1, resistor = 3 },
   output = { type = "component", componentType = "schmitt_trigger" },
   description = "A comparator with hysteresis — clean switching from noisy signals.",
   techNote = "Hysteresis: different thresholds for rising vs. falling signals.",
   agentTip = "The Logician says: no more flickering. The trigger cleans up messy inputs." }

r{ id = "pid_controller", era = 3, name = "PID Controller", category = "control",
   ingredients = { comparator = 2, capacitor = 3, resistor = 3 },
   output = { type = "component", componentType = "pid_controller" },
   description = "Proportional-Integral-Derivative controller. Keeps things exactly right.",
   techNote = "PID: P reacts to present error, I integrates past error, D anticipates future.",
   agentTip = "The Logician says: 'keep the temperature at exactly 200°.' The PID never sleeps." }

r{ id = "latch", era = 3, name = "Latch Circuit", category = "control",
   ingredients = { flip_flop = 1, logic_gate_and = 1, copper_wire = 2 },
   output = { type = "component", componentType = "latch" },
   description = "Stores a value until explicitly changed. A transparent memory element.",
   techNote = "A D-latch passes input to output while enabled, holds when disabled.",
   agentTip = "The Logician says: 'remember this number.' The latch holds it." }

r{ id = "shift_register", era = 3, name = "Shift Register", category = "control",
   ingredients = { flip_flop = 4, copper_wire = 3 },
   output = { type = "component", componentType = "shift_register" },
   description = "Stores and shifts multiple bits. Serial-to-parallel conversion.",
   techNote = "74HC595 shift registers expand outputs via serial communication.",
   agentTip = "The Logician says: push bits in one at a time, get 8 outputs. Magic." }

r{ id = "voltage_comparator", era = 3, name = "Voltage Comparator", category = "sensor",
   ingredients = { comparator = 1, resistor = 2, copper_wire = 2 },
   output = { type = "component", componentType = "voltage_comparator" },
   description = "Compares a sensor voltage to a threshold. Triggers on crossing.",
   techNote = "Window comparators use two thresholds for upper/lower bound detection.",
   agentTip = "The Logician says: 'is the voltage above X?' Yes/no. One bit." }

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 4: PROGRAMMABLE LOGIC (18 recipes)
-- ═══════════════════════════════════════════════════════════════════════════

r{ id = "arduino_board", era = 4, name = "Arduino Board", category = "programmable",
   ingredients = { simple_relay = 2, timer_circuit = 1, copper_wire = 4, circuit_board = 1 },
   output = { type = "component", componentType = "arduino_board" },
   description = "A programmable microcontroller board. Replaces entire walls of relays.",
   techNote = "The Arduino Uno runs an ATmega328P at 16 MHz with 32KB flash.",
   agentTip = "The Coder says: describe what you want. I'll write the code. It just works." }

r{ id = "breadboard", era = 4, name = "Breadboard", category = "programmable",
   ingredients = { plastic = 1, metal_fragment = 2 },
   output = { type = "component", componentType = "breadboard" },
   description = "A solderless prototyping board. Plug in components, wire them up, iterate.",
   techNote = "Breadboard rails are internally connected in rows and columns.",
   agentTip = "The Coder says: prototype here first. Solder later. Trust me." }

r{ id = "led_module", era = 4, name = "LED Module", category = "programmable",
   ingredients = { led = 2, resistor = 1, copper_wire = 1 },
   output = { type = "component", componentType = "led_module" },
   description = "A pre-wired LED with current-limiting resistor. Plug and glow.",
   techNote = "LEDs require ~2V forward voltage and 10-20mA current.",
   agentTip = "The Coder says: every project starts with blinking an LED. It's tradition." }

r{ id = "servo_module", era = 4, name = "Servo Module", category = "programmable",
   ingredients = { motor = 1, potentiometer = 1, circuit_board = 1 },
   output = { type = "component", componentType = "servo_module" },
   description = "A motor with position feedback. Set an angle, it goes there.",
   techNote = "Standard servos accept PWM signals (1-2ms pulses) for 0-180° rotation.",
   agentTip = "The Coder says: 'point at 45 degrees.' It points. No feedback loops to debug." }

r{ id = "ultrasonic_sensor", era = 4, name = "Ultrasonic Sensor", category = "sensor_module",
   ingredients = { piezo = 2, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "ultrasonic_sensor" },
   description = "Measures distance using ultrasonic echolocation. Like a bat.",
   techNote = "HC-SR04: send 40kHz pulse, measure echo time, d = v×t/2.",
   agentTip = "The Coder says: 'how far is the wall?' Ping. The answer comes back." }

r{ id = "pir_sensor", era = 4, name = "PIR Motion Sensor", category = "sensor_module",
   ingredients = { infrared_sensor = 1, lens = 1, circuit_board = 1 },
   output = { type = "component", componentType = "pir_sensor" },
   description = "Detects human/animal movement via body heat (infrared radiation).",
   techNote = "PIR sensors split the field into zones — differential IR triggers detection.",
   agentTip = "The Coder says: 'something moved.' Lights on. Lights off. Hands-free." }

r{ id = "lcd_display", era = 4, name = "LCD Display", category = "programmable",
   ingredients = { glass = 2, circuit_board = 1, copper_wire = 3 },
   output = { type = "component", componentType = "lcd_display" },
   description = "A character display (16×2) for showing text and numbers.",
   techNote = "HD44780 controller drives most character LCDs; I2C backpacks reduce wire count.",
   agentTip = "The Coder says: your machine can talk back now. Use its screen wisely." }

r{ id = "keypad", era = 4, name = "Keypad", category = "programmable",
   ingredients = { switch = 12, circuit_board = 1, copper_wire = 3 },
   output = { type = "component", componentType = "keypad" },
   description = "A 4×3 matrix keypad for numeric input. Pin codes, menus, commands.",
   techNote = "Matrix keypads scan rows and columns to identify pressed keys with fewer pins.",
   agentTip = "The Coder says: now the player can type to the machine. Password-protected doors!" }

r{ id = "stepper_driver", era = 4, name = "Stepper Driver", category = "programmable",
   ingredients = { circuit_board = 1, motor = 1, capacitor = 2 },
   output = { type = "component", componentType = "stepper_driver" },
   description = "Controls a stepper motor for precise position control. No feedback needed.",
   techNote = "A4988 drivers microstep at 1/16 resolution for smooth motion.",
   agentTip = "The Coder says: servos guess position. Steppers KNOW position. Step by step." }

r{ id = "relay_module", era = 4, name = "Relay Module", category = "programmable",
   ingredients = { simple_relay = 4, circuit_board = 1, optocoupler = 1 },
   output = { type = "component", componentType = "relay_module" },
   description = "A 4-channel relay board with optoisolation. Arduino-safe switching.",
   techNote = "Optocouplers isolate the Arduino from high-voltage loads.",
   agentTip = "The Coder says: Arduino brain, relay muscles. The perfect partnership." }

r{ id = "esp8266", era = 4, name = "ESP8266", category = "programmable",
   ingredients = { circuit_board = 1, antenna = 1, copper_wire = 3 },
   output = { type = "component", componentType = "esp8266" },
   description = "A Wi-Fi-enabled microcontroller. Cheaper than an Arduino, with networking built in.",
   techNote = "ESP8266 runs at 80MHz, has 4MB flash, and costs ~$3.",
   agentTip = "The Coder says: Arduino's cousin who grew up near a router." }

r{ id = "esp32", era = 4, name = "ESP32", category = "programmable",
   ingredients = { circuit_board = 1, antenna = 2, copper_wire = 3 },
   output = { type = "component", componentType = "esp32" },
   description = "Dual-core, Wi-Fi + Bluetooth. The powerhouse microcontroller.",
   techNote = "ESP32: 240MHz dual-core, 520KB SRAM, hardware crypto, 18 ADC channels.",
   agentTip = "The Coder says: when the Arduino isn't enough. Dual-core. Wi-Fi. Bluetooth. Monster." }

r{ id = "rtc_module", era = 4, name = "RTC Module", category = "programmable",
   ingredients = { crystal = 1, battery = 1, circuit_board = 1 },
   output = { type = "component", componentType = "rtc_module" },
   description = "Real-Time Clock. Keeps time even when the main board is off.",
   techNote = "DS3231 RTCs are accurate to ±2ppm with temperature compensation.",
   agentTip = "The Coder says: 'what time is it?' The machine always knows." }

r{ id = "sd_card_module", era = 4, name = "SD Card Module", category = "programmable",
   ingredients = { circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "sd_card_module" },
   description = "Reads/writes SD cards for data logging. SPI interface.",
   techNote = "SPI: 4 pins (MOSI, MISO, SCK, CS). Up to 32GB cards supported.",
   agentTip = "The Coder says: the machine can remember things. Lots of things." }

r{ id = "xbee_radio", era = 4, name = "XBee Radio", category = "programmable",
   ingredients = { antenna = 1, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "xbee_radio" },
   description = "A long-range (up to 1 mile) serial radio module. Mesh-capable.",
   techNote = "XBee ZB modules form self-healing mesh networks automatically.",
   agentTip = "The Coder says: Wi-Fi is close-range. XBee goes the distance." }

r{ id = "microphone_module", era = 4, name = "Microphone Module", category = "sensor_module",
   ingredients = { electret = 1, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "microphone_module" },
   description = "Electret microphone breakout for sound detection and voice input.",
   techNote = "Electret mics need bias voltage; MAX4466 modules include preamp.",
   agentTip = "The Coder says: the machine can hear you. STT integration starts here." }

r{ id = "speaker_module", era = 4, name = "Speaker Module", category = "sensor_module",
   ingredients = { speaker = 1, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "speaker_module" },
   description = "Amplified speaker for TTS output and audio feedback.",
   techNote = "I2S DACs (e.g., MAX98357A) provide crystal-clear digital audio to speakers.",
   agentTip = "The Coder says: the machine speaks back. Wire this up before anything else." }

r{ id = "gas_sensor", era = 4, name = "Gas Sensor", category = "sensor_module",
   ingredients = { semiconductor = 2, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "gas_sensor" },
   description = "Detects combustible and toxic gases. Safety first.",
   techNote = "MQ-2 sensors detect methane, propane, CO, and smoke via resistance change.",
   agentTip = "The Coder says: if the machine smells gas, it shuts everything down." }

r{ id = "gps_module", era = 4, name = "GPS Module", category = "sensor_module",
   ingredients = { antenna = 1, circuit_board = 1, crystal = 1 },
   output = { type = "component", componentType = "gps_module" },
   description = "Satellite positioning. Knows exactly where it is on the map.",
   techNote = "GPS needs 4 satellites for 3D position fix. Accuracy: ~3m civilian.",
   agentTip = "The Coder says: 'where am I?' The machine always knows now." }

r{ id = "rfid_reader", era = 4, name = "RFID Reader", category = "sensor_module",
   ingredients = { antenna = 1, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "rfid_reader" },
   description = "Reads RFID tags for identification and tracking. Touch to identify.",
   techNote = "125kHz RFID is passive (no battery). UHF RFID reads at 10m+.",
   agentTip = "The Coder says: tag your tools, tag your builds. Scan to identify." }

r{ id = "joystick_module", era = 4, name = "Joystick Module", category = "programmable",
   ingredients = { potentiometer = 2, switch = 1, circuit_board = 1 },
   output = { type = "component", componentType = "joystick_module" },
   description = "Dual-axis analog joystick with click. Precise manual control.",
   techNote = "Two potentiometers (X/Y) plus a push button. Analog values 0-1023.",
   agentTip = "The Coder says: when you need analog input from a human. Cranes, arms, rovers." }

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 5: NETWORKED SYSTEMS (18 recipes)
-- ═══════════════════════════════════════════════════════════════════════════

r{ id = "wireless_module", era = 5, name = "Wireless Module", category = "network",
   ingredients = { esp32 = 1, antenna = 2, circuit_board = 1 },
   output = { type = "component", componentType = "wireless_module" },
   description = "A self-contained Wi-Fi transceiver for connecting devices to a network.",
   techNote = "802.11n operates at 2.4GHz with typical range of 70m indoor.",
   agentTip = "The Architect says: the wire stops here. Everything after this is air." }

r{ id = "mesh_node", era = 5, name = "Mesh Node", category = "network",
   ingredients = { esp32 = 1, xbee_radio = 1, circuit_board = 1 },
   output = { type = "component", componentType = "mesh_node" },
   description = "A self-routing node in a mesh network. Passes messages, extends range.",
   techNote = "Mesh networks self-heal: if one node drops, traffic reroutes.",
   agentTip = "The Architect says: place them like lighthouses. Each one extends the web." }

r{ id = "protocol_bridge", era = 5, name = "Protocol Bridge", category = "network",
   ingredients = { esp32 = 1, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "protocol_bridge" },
   description = "Translates between different communication protocols. Universal translator.",
   techNote = "Bridges operate at Layer 2 (data link) of the OSI model.",
   agentTip = "The Architect says: your XBee network and your Wi-Fi network need to talk. This helps." }

r{ id = "data_logger", era = 5, name = "Data Logger", category = "network",
   ingredients = { sd_card_module = 1, rtc_module = 1, esp32 = 1 },
   output = { type = "component", componentType = "data_logger" },
   description = "Records sensor data with timestamps for later analysis.",
   techNote = "Time-series logging with NTP sync enables trend analysis.",
   agentTip = "The Architect says: 'what happened while I was gone?' The logger knows." }

r{ id = "cloud_gateway", era = 5, name = "Cloud Gateway", category = "network",
   ingredients = { esp32 = 1, antenna = 3, circuit_board = 2 },
   output = { type = "component", componentType = "cloud_gateway" },
   description = "Connects the local network to a remote server. Edge-to-cloud bridge.",
   techNote = "MQTT over TLS is the standard for IoT cloud communication.",
   agentTip = "The Architect says: your world has an outside now. Data flows both ways." }

r{ id = "mqtt_broker", era = 5, name = "MQTT Broker", category = "network",
   ingredients = { esp32 = 2, circuit_board = 2, copper_wire = 4 },
   output = { type = "component", componentType = "mqtt_broker" },
   description = "A message broker that routes data between publishers and subscribers.",
   techNote = "MQTT uses a publish/subscribe model with topics and QoS levels.",
   agentTip = "The Architect says: nobody talks directly. Everyone publishes. Everyone subscribes." }

r{ id = "packet_sniffer", era = 5, name = "Packet Sniffer", category = "network",
   ingredients = { esp32 = 1, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "packet_sniffer" },
   description = "Monitors network traffic. Debugs protocols. Finds problems.",
   techNote = "Promiscuous mode captures all packets, not just addressed ones.",
   agentTip = "The Architect says: when the network breaks, this tells you where." }

r{ id = "antenna_array", era = 5, name = "Antenna Array", category = "network",
   ingredients = { metal_fragment = 4, antenna = 2, circuit_board = 1 },
   output = { type = "component", componentType = "antenna_array" },
   description = "Directional antenna system for long-range communication.",
   techNote = "Phased arrays steer beams electronically without moving parts.",
   agentTip = "The Architect says: point it at the far node. Signal goes the distance." }

r{ id = "signal_repeater", era = 5, name = "Signal Repeater", category = "network",
   ingredients = { wireless_module = 1, antenna = 1, battery = 1 },
   output = { type = "component", componentType = "signal_repeater" },
   description = "Receives and retransmits signals to extend network range.",
   techNote = "Repeaters add latency but solve distance limitations.",
   agentTip = "The Architect says: too far? Put one in the middle. Problem solved." }

r{ id = "network_hub", era = 5, name = "Network Hub", category = "network",
   ingredients = { esp32 = 1, circuit_board = 2, copper_wire = 4 },
   output = { type = "component", componentType = "network_hub" },
   description = "Central connection point for multiple network devices.",
   techNote = "Hubs broadcast to all ports; switches are smarter. Use switches.",
   agentTip = "The Architect says: everything plugs in here. The hub is the heart." }

r{ id = "routing_table", era = 5, name = "Routing Table", category = "network",
   ingredients = { esp32 = 1, circuit_board = 1, sd_card_module = 1 },
   output = { type = "component", componentType = "routing_table" },
   description = "Stores network topology and determines optimal paths for data.",
   techNote = "Dijkstra's algorithm finds shortest paths; A* adds heuristics.",
   agentTip = "The Architect says: the map of your network. Every road, every turn." }

r{ id = "encryption_module", era = 5, name = "Encryption Module", category = "network",
   ingredients = { esp32 = 1, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "encryption_module" },
   description = "Hardware-accelerated AES encryption for secure communication.",
   techNote = "ESP32 has hardware AES acceleration: 128/192/256-bit.",
   agentTip = "The Architect says: if you don't want them reading it, encrypt it." }

r{ id = "ota_updater", era = 5, name = "OTA Updater", category = "network",
   ingredients = { esp32 = 1, cloud_gateway = 1, circuit_board = 1 },
   output = { type = "component", componentType = "ota_updater" },
   description = "Over-the-air firmware updates. Fix bugs without touching the device.",
   techNote = "OTA partitions flash memory: write new while running old, then swap.",
   agentTip = "The Architect says: push code to every device at once. No more walking." }

r{ id = "dashboard_screen", era = 5, name = "Dashboard Screen", category = "network",
   ingredients = { lcd_display = 2, esp32 = 1, circuit_board = 2 },
   output = { type = "component", componentType = "dashboard_screen" },
   description = "A real-time monitoring display showing all networked devices.",
   techNote = "Web dashboards use WebSocket for real-time push updates.",
   agentTip = "The Architect says: every device, every sensor, one screen. God's-eye view." }

r{ id = "data_pipeline", era = 5, name = "Data Pipeline", category = "network",
   ingredients = { mqtt_broker = 1, data_logger = 1, cloud_gateway = 1 },
   output = { type = "component", componentType = "data_pipeline" },
   description = "End-to-end data flow: collect, process, store, visualize.",
   techNote = "ETL pipelines: Extract (sensors) → Transform (process) → Load (database).",
   agentTip = "The Architect says: data goes in raw, comes out as decisions." }

r{ id = "edge_compute", era = 5, name = "Edge Compute Node", category = "network",
   ingredients = { esp32 = 2, circuit_board = 2, sd_card_module = 1 },
   output = { type = "component", componentType = "edge_compute" },
   description = "Processes data locally at the network edge. Faster decisions.",
   techNote = "Edge computing reduces latency by processing near the data source.",
   agentTip = "The Architect says: not everything needs the cloud. Process at the edge." }

r{ id = "time_sync", era = 5, name = "Time Sync Server", category = "network",
   ingredients = { esp32 = 1, rtc_module = 1, antenna = 1 },
   output = { type = "component", componentType = "time_sync" },
   description = "NTP-like time synchronization across the network. Everyone agrees.",
   techNote = "NTP achieves sub-50ms sync across the public internet.",
   agentTip = "The Architect says: every node on the same clock. Coordination starts here." }

r{ id = "firewall", era = 5, name = "Network Firewall", category = "network",
   ingredients = { esp32 = 1, circuit_board = 1, encryption_module = 1 },
   output = { type = "component", componentType = "firewall" },
   description = "Filters network traffic. Blocks unauthorized access to devices.",
   techNote = "Stateful firewalls track connection state, not just packet headers.",
   agentTip = "The Architect says: the network is open. The firewall decides who enters." }

r{ id = "load_balancer", era = 5, name = "Load Balancer", category = "network",
   ingredients = { esp32 = 2, circuit_board = 2, network_hub = 1 },
   output = { type = "component", componentType = "load_balancer" },
   description = "Distributes work across multiple devices. No single point of overload.",
   techNote = "Round-robin DNS is the simplest load balancing strategy.",
   agentTip = "The Architect says: when one node can't keep up, split the work." }

r{ id = "message_queue", era = 5, name = "Message Queue", category = "network",
   ingredients = { mqtt_broker = 1, sd_card_module = 1, esp32 = 1 },
   output = { type = "component", componentType = "message_queue" },
   description = "Buffers messages between devices. Reliable asynchronous delivery.",
   techNote = "Persistent queues survive restarts by writing to disk.",
   agentTip = "The Architect says: send now, process later. The queue waits patiently." }

-- ═══════════════════════════════════════════════════════════════════════════
-- ERA 6: AUTONOMOUS AGENTS (18 recipes)
-- ═══════════════════════════════════════════════════════════════════════════

r{ id = "agent_core", era = 6, name = "Agent Core", category = "autonomous",
   ingredients = { esp32 = 2, circuit_board = 3, battery = 2, antenna = 1 },
   output = { type = "component", componentType = "agent_core" },
   description = "The brain of an autonomous agent. Thinks, acts, communicates.",
   techNote = "Agent loop: PERCEIVE → THINK → ACT → COMMUNICATE → LEARN.",
   agentTip = "The Orchestrator says: this is what we are. A core, a purpose, a loop." }

r{ id = "fleet_beacon", era = 6, name = "Fleet Beacon", category = "autonomous",
   ingredients = { antenna_array = 1, esp32 = 2, circuit_board = 2 },
   output = { type = "component", componentType = "fleet_beacon" },
   description = "Command center for coordinating multiple autonomous agents simultaneously.",
   techNote = "Fleet management uses priority queues and task partitioning.",
   agentTip = "The Orchestrator says: one agent is interesting. A fleet is unstoppable." }

r{ id = "task_scheduler", era = 6, name = "Task Scheduler", category = "autonomous",
   ingredients = { esp32 = 1, rtc_module = 1, circuit_board = 1 },
   output = { type = "component", componentType = "task_scheduler" },
   description = "Assigns and prioritizes tasks across agents. Who does what, when.",
   techNote = "Priority schedulers use heuristics: urgency, capability, proximity.",
   agentTip = "The Orchestrator says: nobody stands idle. Nobody does the wrong job." }

r{ id = "autonomous_miner", era = 6, name = "Autonomous Miner", category = "autonomous",
   ingredients = { agent_core = 1, ultrasonic_sensor = 2, motor = 2, battery = 2 },
   output = { type = "component", componentType = "autonomous_miner" },
   description = "An agent that locates and extracts resources autonomously.",
   techNote = "Resource detection: ultrasonic for range, IR for material identification.",
   agentTip = "The Orchestrator says: point it at a vein. It mines. You build." }

r{ id = "autonomous_builder", era = 6, name = "Autonomous Builder", category = "autonomous",
   ingredients = { agent_core = 1, servo_module = 3, motor = 2, battery = 2 },
   output = { type = "component", componentType = "autonomous_builder" },
   description = "An agent that assembles structures from blueprints.",
   techNote = "Build agents use spatial decomposition: decompose → subdivide → assign → assemble.",
   agentTip = "The Orchestrator says: give it a plan. It builds while you dream." }

r{ id = "autonomous_scout", era = 6, name = "Autonomous Scout", category = "autonomous",
   ingredients = { agent_core = 1, pir_sensor = 1, antenna = 2, battery = 1 },
   output = { type = "component", componentType = "autonomous_scout" },
   description = "An agent that explores terrain and reports interesting locations.",
   techNote = "Frontier-based exploration: always move toward the boundary of known space.",
   agentTip = "The Orchestrator says: send it out. It comes back with a map." }

r{ id = "orchestrator_console", era = 6, name = "Orchestrator Console", category = "autonomous",
   ingredients = { dashboard_screen = 1, fleet_beacon = 1, circuit_board = 2 },
   output = { type = "component", componentType = "orchestrator_console" },
   description = "Master control interface for the entire agent fleet.",
   techNote = "The console aggregates state from all agents and provides override controls.",
   agentTip = "The Orchestrator says: this is your throne. Direct from here." }

r{ id = "skill_library", era = 6, name = "Skill Library", category = "autonomous",
   ingredients = { sd_card_module = 1, esp32 = 1, circuit_board = 1 },
   output = { type = "component", componentType = "skill_library" },
   description = "A searchable database of skills agents can learn and share.",
   techNote = "Skill embeddings enable semantic retrieval — agents find relevant skills.",
   agentTip = "The Orchestrator says: every lesson learned, saved forever. Teach the fleet." }

r{ id = "coordination_matrix", era = 6, name = "Coordination Matrix", category = "autonomous",
   ingredients = { mqtt_broker = 1, task_scheduler = 1, circuit_board = 2 },
   output = { type = "component", componentType = "coordination_matrix" },
   description = "Manages inter-agent communication and role negotiation.",
   techNote = "Contract Net Protocol: agents bid on tasks based on capability and availability.",
   agentTip = "The Orchestrator says: they talk to each other now. They figure out who does what." }

r{ id = "resource_allocator", era = 6, name = "Resource Allocator", category = "autonomous",
   ingredients = { data_pipeline = 1, task_scheduler = 1, circuit_board = 1 },
   output = { type = "component", componentType = "resource_allocator" },
   description = "Distributes materials and energy across the agent fleet optimally.",
   techNote = "Bin-packing algorithms optimize resource allocation under constraints.",
   agentTip = "The Orchestrator says: the right materials to the right agent at the right time." }

r{ id = "self_repair_module", era = 6, name = "Self-Repair Module", category = "autonomous",
   ingredients = { agent_core = 1, servo_module = 2, capacitor = 2 },
   output = { type = "component", componentType = "self_repair_module" },
   description = "Allows agents to diagnose and repair damage to themselves.",
   techNote = "Health monitoring: voltage, temperature, vibration signatures.",
   agentTip = "The Orchestrator says: agents that fix themselves. You sleep, they work." }

r{ id = "swarm_controller", era = 6, name = "Swarm Controller", category = "autonomous",
   ingredients = { coordination_matrix = 1, fleet_beacon = 1, antenna = 2 },
   output = { type = "component", componentType = "swarm_controller" },
   description = "Coordinates agents as a swarm using emergent behavior rules.",
   techNote = "Boids algorithm: separation, alignment, cohesion. Simple rules, complex behavior.",
   agentTip = "The Orchestrator says: no leader. No plan. Just rules. Watch them organize." }

r{ id = "priority_queue", era = 6, name = "Priority Queue", category = "autonomous",
   ingredients = { esp32 = 1, circuit_board = 1, copper_wire = 2 },
   output = { type = "component", componentType = "priority_queue" },
   description = "Orders tasks by urgency and importance. Critical jobs jump the line.",
   techNote = "Binary heaps provide O(log n) insertion and extraction for priority queues.",
   agentTip = "The Orchestrator says: not all tasks are equal. The queue knows the difference." }

r{ id = "agent_communicator", era = 6, name = "Agent Communicator", category = "autonomous",
   ingredients = { mesh_node = 1, coordination_matrix = 1, circuit_board = 1 },
   output = { type = "component", componentType = "agent_communicator" },
   description = "Structured messaging bus for agent-to-agent communication.",
   techNote = "FIPA ACL defines performatives for agent speech acts.",
   agentTip = "The Orchestrator says: agents that can't talk, can't coordinate." }

r{ id = "decision_engine", era = 6, name = "Decision Engine", category = "autonomous",
   ingredients = { agent_core = 1, data_pipeline = 1, circuit_board = 2 },
   output = { type = "component", componentType = "decision_engine" },
   description = "Evaluates options and selects actions using reasoning models.",
   techNote = "Decision engines use MDPs (Markov Decision Processes) for optimal policy selection.",
   agentTip = "The Orchestrator says: this is where thinking happens. Inputs in, decision out." }

r{ id = "learning_module", era = 6, name = "Learning Module", category = "autonomous",
   ingredients = { agent_core = 1, sd_card_module = 1, circuit_board = 2 },
   output = { type = "component", componentType = "learning_module" },
   description = "Allows agents to improve performance over time through experience.",
   techNote = "Reinforcement learning: agents maximize cumulative reward through exploration.",
   agentTip = "The Orchestrator says: agents that learn from mistakes. They get better every day." }

r{ id = "vision_system", era = 6, name = "Vision System", category = "autonomous",
   ingredients = { camera = 1, esp32 = 1, circuit_board = 2 },
   output = { type = "component", componentType = "vision_system" },
   description = "Gives agents the ability to see and interpret their surroundings.",
   techNote = "Edge vision: ESP32-CAM runs lightweight CNNs for object detection at 5fps.",
   agentTip = "The Orchestrator says: agents that see. They build better when they know what's there." }

r{ id = "pathfinder", era = 6, name = "Pathfinder Module", category = "autonomous",
   ingredients = { agent_core = 1, ultrasonic_sensor = 2, circuit_board = 1 },
   output = { type = "component", componentType = "pathfinder" },
   description = "Calculates optimal paths through terrain. Navigation for mobile agents.",
   techNote = "A* algorithm balances greedy search with path optimality.",
   agentTip = "The Orchestrator says: the scout needs to get from A to B. This finds the way." }

r{ id = "mission_planner", era = 6, name = "Mission Planner", category = "autonomous",
   ingredients = { decision_engine = 1, pathfinder = 1, circuit_board = 2 },
   output = { type = "component", componentType = "mission_planner" },
   description = "Generates complete mission plans for agent fleets. Goals in, steps out.",
   techNote = "HTN (Hierarchical Task Network) planners decompose goals into executable tasks.",
   agentTip = "The Orchestrator says: give it a goal. It makes the plan. The fleet executes." }

-- ═══════════════════════════════════════════════════════════════════════════
-- LOOKUP INDICES (built at load time for fast access)
-- ═══════════════════════════════════════════════════════════════════════════

local RECIPES_BY_ID = {}
local RECIPES_BY_ERA = { [0] = {}, [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {}, [6] = {} }

for _, recipe in ipairs(RECIPES) do
    RECIPES_BY_ID[recipe.id] = recipe
    local eraList = RECIPES_BY_ERA[recipe.era]
    if eraList then
        table.insert(eraList, recipe)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

local Recipes = {}

-- Get all recipes
function Recipes.getAll()
    return RECIPES
end

-- Get recipe by ID
function Recipes.get(id)
    return RECIPES_BY_ID[id]
end

-- Get all recipes for a specific era
function Recipes.getByEra(eraNumber)
    return RECIPES_BY_ERA[eraNumber] or {}
end

-- Search recipes by name or keyword (case-insensitive)
function Recipes.search(query)
    if not query or query == "" then return {} end
    query = string.lower(query)

    local results = {}
    for _, recipe in ipairs(RECIPES) do
        local name = string.lower(recipe.name)
        local desc = string.lower(recipe.description or "")
        local id = string.lower(recipe.id)
        local category = string.lower(recipe.category or "")

        if string.find(name, query, 1, true)
           or string.find(desc, query, 1, true)
           or string.find(id, query, 1, true)
           or string.find(category, query, 1, true) then
            table.insert(results, recipe)
        end
    end
    return results
end

-- Get total recipe count
function Recipes.count()
    return #RECIPES
end

-- Get count per era
function Recipes.countByEra()
    local counts = {}
    for era = 0, 6 do
        counts[era] = #(RECIPES_BY_ERA[era] or {})
    end
    return counts
end

-- Get recipes by category
function Recipes.getByCategory(category)
    local results = {}
    for _, recipe in ipairs(RECIPES) do
        if recipe.category == category then
            table.insert(results, recipe)
        end
    end
    return results
end

-- Get all categories
function Recipes.getCategories()
    local seen = {}
    local result = {}
    for _, recipe in ipairs(RECIPES) do
        if not seen[recipe.category] then
            seen[recipe.category] = true
            table.insert(result, recipe.category)
        end
    end
    return result
end

return Recipes
