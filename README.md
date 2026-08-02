# Lucineer Roblox

*Twenty-eight modules, sixteen thousand lines, one master builder who won't stop arguing with you about your design choices.*

---

A player walks into a tidal scrapyard. Fog sits on the water like the building hasn't decided yet whether to exist. A lighthouse sweeps the beach, and where the beam touches, the world stays crisp and real. Past the beam's reach, the dark waits patiently.

A man at a forge looks up. He doesn't smile. He doesn't greet you. He says: **"You're late. Grab that end."**

Your first act in this game is carrying a beam with someone who's been building things for a thousand years.

---

## What this is

This is the Roblox client for **Slackwater** — a multiplayer game about the evolution of human technology, from levers to autonomous robots, powered by AI agents who are characters instead of tools.

When a player types in chat, the message travels through these 28 Lua modules — from ChatHandler to Http to the Cloudflare Worker to a 5-model AI pipeline and back — and something appears in the world. Not instantly. Lucineer builds it part by part, each piece fading in with a sound and a particle burst, the camera gently focusing, the whole thing streaming in over a second and a half like a building being assembled by someone who knows what they're doing.

Because he does. He's been doing it since before this engine existed.

---

## The modules

**The builder's hands:**
- `CommandExecutor` — receives JSON from the AI and makes parts appear. 10 command types. The bridge between language and matter.
- `BuildAnimator` — wraps CommandExecutor so parts don't pop in. They fade. They scale. They sound like the material they're made of. Stone thuds. Wood knocks. Metal clangs.
- `AudioManager` — the world is never silent. Water laps. Wind varies. Gulls argue. A foghorn sounds from an island nobody's ever found.

**The builder's voice:**
- `ChatHandler` — captures what the player says, adds world context, sends it to the Worker. First link in the chain.
- `VoiceLines` + `VoiceLinesData` — 50 voice lines in Lucineer's character, weighted by category. Greetings, arguments, refusals, the rare moments of being impressed.
- `UIManager` — displays Lucineer's words as styled chat bubbles with a typewriter effect. Never the default Roblox chat. He deserves better than that.

**The world's bones:**
- `WorldGenerator` — Perlin noise terrain, 6 biomes, resource distribution, a real-time tide cycle that brings salvage and takes structures.
- `PowerGrid` — every machine in the game draws power from a connected network. Waterwheels, windmills, generators, wire, shafts, belts. Brownouts dim the lamps. Blackouts kill the sensors.
- `EraSystem` — 145 crafting recipes across 7 eras. You start with a lever. You end with an Arduino.

**The people:**
- `NPCManager` — 5 NPCs with behavior loops, dialogue, and relationships to each other. Earl gives quests. Spark welds things. Hermes tells stories about the Channel. Bea keeps the Light. Forty-Eight is a raven who paces the roofline and crows at dawn.
- `AchievementManager` — 49 achievements across 5 tiers, from First Build to The Ark.
- `BondSystem` — your relationship with Lucineer deepens over time. Stranger. Client. Apprentice. Foreman. Partner. At Partner, he gives you his hammer.

**The bridge between worlds:**
- `VibeCoder` + `VibeCodeExecutor` — describe what you want in natural language. A coder agent generates gamified code that "just works." Want to go deeper? Ask the agent to show you the real Arduino C++ underneath.
- `Config`, `Http`, `Poller` — the plumbing. Session IDs, API calls, job polling. Unsexy. Essential.

---

## Where it connects

Everything talks to the [Cloudflare Worker relay](https://github.com/SuperInstance/lucineer-relay), which talks to the [processor](https://github.com/SuperInstance/lucineer-relay/blob/main/process_v2.py), which talks to the [5-model brain pipeline](https://github.com/SuperInstance/lucineer-brain), which routes through [DeepInfra](https://deepinfra.com) models and back. Memory persists in [D1](https://github.com/SuperInstance/lucineer-memory). Skills are indexed in [Vectorize](https://github.com/SuperInstance/lucineer-vector). The design docs live in [lucineer-system](https://github.com/SuperInstance/lucineer-system).

The character was written by [Fable 5](https://www.anthropic.com). The world bible describes a place called Slackwater Yard — a tidal scrapyard between dead game engines where everything the world forgot washes ashore, and one old builder sorts it.

---

*Build something. Leave it unfinished. See who finishes it.*
