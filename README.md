# lucineer-roblox

**Roblox client for Slackwater — 16 Luau modules bridging player chat to AI-generated builds via Cloudflare Workers.**

When a player types in chat, the message flows through ChatHandler → Http → Cloudflare Worker → Python processor → 4-model AI pipeline and back. Something appears in the world — not instantly, but part by part, each piece fading in with material-aware sound and particle bursts, staggered on a musical grid derived from the BeatClock.

---

## Architecture

```
 ┌─────────────────────────── Roblox Client ──────────────────────────────┐
 │                                                                        │
 │  ChatHandler ──▶ Http ──▶ Worker (POST /api/message)                   │
 │       │                          │                                     │
 │       ▼                          ▼                                     │
 │  WorldScanner ────────────▶ Poller (GET /api/job/:id, 0.5s)           │
 │  (context gathering)              │                                    │
 │                                   ▼                                    │
 │                          CommandExecutor.executeBatch()                │
 │                                   │                                    │
 │                          ┌────────┼────────┐                           │
 │                          ▼        ▼        ▼                           │
 │                    createPart  addLight  setTerrain  ...               │
 │                          │                                             │
 │                          ▼                                             │
 │                    BuildAnimator.animateBatch()                        │
 │                    (staggered reveal: fade, scale, sound, particles)   │
 │                          │                                             │
 │                          ▼                                             │
 │                    FilterGate.filterFor()                              │
 │                    (TextService fail-closed)                           │
 │                          │                                             │
 │                          ▼                                             │
 │                    UIManager.displayChatResponse()                     │
 │                    (styled bubble, typewriter effect)                  │
 │                                                                        │
 │  BeatClock ──▶ client-side tick mirror (synced from DO)                │
 │  AudioManager ──▶ ambient soundscape (tide, wind, gulls, foghorn)     │
 │  CinematicController ──▶ camera framing on build completion           │
 │                                                                        │
 └────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Player types "build a castle"
  → ChatHandler captures message + WorldScanner gathers nearby parts
  → Http POST /api/message to Worker
  → Worker creates job, returns jobId
  → Poller polls GET /api/job/:jobId every 0.5s
  → Meanwhile: Processor claims job, runs brain pipeline, posts result
  → Poller receives status=complete with reply + commands[]
  → CommandExecutor.executeBatch() creates all parts in pre-animation state
  → BuildAnimator.animateBatch() reveals each part with staggered timing
  → FilterGate.filterFor() sanitizes reply text (fail-closed)
  → UIManager displays typewriter chat bubble with Lucineer's reply
  → CinematicController frames the completed build
```

---

## Module Catalog

### Build Execution

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `CommandExecutor` | ~400 | Dispatches structured build commands: createPart, createModel, deletePart, movePart, addLight, addSound, addScript, setTerrain, sendMessage. Batch mode collects parts for deferred animation. |
| `BuildAnimator` | ~300 | Staggered cinematic reveal: parts fade-in + scale-up with Back easing, material-aware sounds (stone thuds, wood knocks, metal clangs), particle bursts on landing, multi-colored completion burst. |
| `CinematicController` | ~150 | Camera framing on build completion. Hard cut, no fade — control arrives like a handoff. |

### Chat and Communication

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `ChatHandler` | ~100 | Captures player chat, attaches world context, POSTs to Worker, registers jobId with Poller. |
| `Http` | ~80 | HttpService wrapper with JSON serialization, auth headers, exponential backoff retry (max 3, base 0.5s, cap 4s). |
| `Poller` | ~120 | Tracks active jobs by ID, polls at `POLL_INTERVAL` (0.5s), fires callbacks on completion/error, times out at `POLL_TIMEOUT` (180s). |
| `UIManager` | ~200 | Custom styled chat bubbles (cyan-green on dark blue), typewriter effect, "Lucineer is thinking..." status bar. Never uses default Roblox chat. |
| `VoiceLines` + `VoiceLinesData` | ~350 | 50 voice lines in Lucineer's character across 6 categories (greetings, arguments, refusals, impressed, building, idle). Weighted random selection. |

### Safety and Compliance

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `FilterGate` | ~100 | Single chokepoint for text moderation. Every AI-generated string passes through `filterFor()` before display. Calls `TextService:FilterStringAsync()` → `GetNonChatStringForBroadcastAsync()`. **Fail-closed**: on any error, returns nil (display nothing). No second path. |

### World Perception

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `WorldScanner` | ~100 | Collects world state: player position, nearby parts/models/lights within `SCAN_RADIUS` (200 studs). Caps at `SCAN_MAX_INSTANCES` (50). Single-pass traversal for build counting. |

### Timing and Audio

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `BeatClock` | ~120 | Client-side mirror of authoritative DO BeatClock. Computes ticks from elapsed wall-clock time. 8 ticks per beat (32nd-note resolution). BPM-synced on server WebSocket messages and channel-15 META tempo events. |
| `AudioManager` | ~150 | Ambient soundscape: tide layer, wind variation, gull calls, foghorn. The world is never silent. |

### Vibe-Coding Interface

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `VibeCoder` | ~200 | Diegetic "Slack-Pad" tablet: players describe what they want in natural language, a coder agent generates gamified code that "just works." Bridge between natural language and real code. |
| `VibeCoderDialogue` | ~150 | Deep-dive learning interface: players can ask to see the real Arduino C++ underneath the gamified abstraction. |

### Configuration

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `Config` | ~40 | Central settings: `WORKER_URL`, `SESSION_ID` (`{PlaceId}-{JobId}`), poll intervals, scan radius, UI colors, HTTP retry config. |

---

## Module Dependency Graph

```
                    ┌──────────┐
                    │  Config  │ ─────────────────── (all modules read Config)
                    └────┬─────┘
                         │
              ┌──────────┼──────────┐
              ▼          ▼          ▼
        ┌──────────┐ ┌────────┐ ┌───────────┐
        │   Http   │ │Poller  │ │BeatClock  │
        └─────┬────┘ └───┬────┘ └───────────┘
              │          │
              ▼          │
        ┌──────────┐    │
        │ChatHandler│   │
        └─────┬────┘    │
              │         │
    ┌─────────┼─────────┤
    │         │         │
    ▼         ▼         ▼
┌─────────┐ ┌──────────────┐ ┌─────────────┐
│WorldScan│ │CommandExecutor│ │ VoiceLines  │
└────┬────┘ └──────┬───────┘ └──────┬──────┘
     │             │                 │
     │             ▼                 │
     │      ┌─────────────┐          │
     │      │BuildAnimator│          │
     │      └──────┬──────┘          │
     │             │                 │
     │             ▼                 │
     │      ┌─────────────┐          │
     │      │ FilterGate  │          │
     │      └──────┬──────┘          │
     │             │                 │
     │             ▼                 │
     │      ┌─────────────┐          │
     └─────▶│  UIManager  │◀─────────┘
            └──────┬──────┘
                   │
                   ▼
            ┌──────────────────┐
            │CinematicController│
            └──────────────────┘

  Independent:
  ┌────────────┐  ┌───────────────┐  ┌─────────────────┐
  │ AudioManager│  │ VibeCoder     │  │VibeCoderDialogue│
  └────────────┘  └───────────────┘  └─────────────────┘
```

---

## BeatClock + FilterGate Architecture

### BeatClock: Musical Timing

The BeatClock is a client-side mirror of the authoritative clock in the BuildCoordinator Durable Object. It provides local tick/beat queries without server round-trips.

**Resolution:** 8 ticks per beat (32nd-note granularity).

| BPM | Tick Duration | 32nd-Note Duration |
|-----|--------------|-------------------|
| 72 (Adagio) | 0.104s | 0.104s |
| 90 (Andante) | 0.083s | 0.083s |
| 120 (Allegro) | 0.063s | 0.063s |

**Sync protocol:**
1. On WebSocket connect, server sends current BPM and tick → `syncFromServer()`
2. Channel-15 META tempo events update BPM via `setBPM()` (preserves current tick position)
3. Drift correction happens on every WebSocket message (≤1 tick/beat tolerance)
4. The mirror is approximate; the DO is authoritative

The `get32ndNoteDuration()` method replaces the old hardcoded 0.08s stagger interval. Build animation timing now scales with the musical tempo.

### FilterGate: The One Chokepoint

FilterGate is the **single boundary** between "model output" and "player-visible string." There is no second path. If a string hasn't passed `filterFor()`, it does not render.

**Contract:** Never return unfiltered text. If the filter breaks, the string doesn't show.

```
AI Reply ──▶ FilterGate.filterFor(text, playerId) ──▶ filtered string OR nil
                                                          │
                                                    if nil: display nothing
                                                    if string: UIManager renders
```

Two methods:
- `filterFor(text, playerId)` — for non-chat UI text (labels, notifications). Uses `GetNonChatStringForBroadcastAsync()`.
- `filterForChat(text, fromUserId, toUserId)` — for chat messages with sender context. Uses `GetChatForUserAsync()`.

---

## Command Types

CommandExecutor supports 9 command types dispatched from AI-generated JSON:

| Command | Parameters | Behavior |
|---------|-----------|----------|
| `createPart` | name, position, size, material, color, shape, anchored, transparency | Creates a BasePart in `workspace.LucineerBuilds`. Pre-animation state in batch mode (invisible, 0.1 size). |
| `createModel` | name, parts[] | Creates a Model containing multiple parts. |
| `deletePart` | name | Removes a part by name from LucineerBuilds or workspace. |
| `movePart` | name, position | Relocates an existing part. |
| `addLight` | name, type (Point/Spot/Surface), position, range, brightness, color, parent | Attaches a light to an existing part or creates a carrier. |
| `addSound` | name, soundId, position, volume, looped, pitch, autoplay | Creates a Sound on a carrier part. |
| `addScript` | name, source, type (Script/LocalScript), parent | Creates a script instance. (Note: `runLua` is disabled — BUG #9, loadstring is unsafe.) |
| `setTerrain` | position, size, material, action (fill/clear) | Modifies terrain cells via `Terrain:FillRegion()`. Resolution: 4 studs. |
| `sendMessage` | message, targetPlayer | Routes a message to UIManager for display. |

**Batch mode:** `executeBatch()` collects all created parts during execution, then passes them to `BuildAnimator.animateBatch()` for a single staggered cinematic reveal. Individual `execute()` calls animate immediately.

---

## Configuration

```lua
Config.WORKER_URL         = "https://lucineer-relay.casey-digennaro.workers.dev"
Config.SESSION_ID         = "{PlaceId}-{JobId}"
Config.POLL_INTERVAL      = 0.5     -- seconds
Config.POLL_TIMEOUT       = 180     -- must exceed brain's DEEP_TIMEOUT (120s)
Config.STATE_SYNC_INTERVAL = 10     -- seconds
Config.SCAN_RADIUS        = 200     -- studs
Config.SCAN_MAX_INSTANCES = 50
Config.HTTP_MAX_RETRIES   = 3
Config.HTTP_BASE_DELAY    = 0.5     -- exponential backoff base
Config.HTTP_MAX_DELAY     = 4.0     -- backoff cap
```

---

## File Layout

```
src/
└── ReplicatedStorage/
    └── Lucineer/
        ├── AudioManager.lua         # Ambient soundscape
        ├── BeatClock.lua            # Client-side tick mirror
        ├── BuildAnimator.lua        # Staggered cinematic build reveal
        ├── ChatHandler.lua          # Player chat capture and dispatch
        ├── CinematicController.lua  # Camera framing on completion
        ├── CommandExecutor.lua      # Build command dispatcher (9 types)
        ├── Config.lua               # Central configuration
        ├── FilterGate.lua           # TextService moderation chokepoint
        ├── Http.lua                 # HTTP wrapper with retry
        ├── Poller.lua               # Job status polling
        ├── UIManager.lua            # Styled chat bubbles + typewriter
        ├── VibeCoder.lua            # Diegetic vibe-coding tablet
        ├── VibeCoderDialogue.lua    # Deep-dive code learning interface
        ├── VoiceLines.lua           # Voice line retrieval system
        ├── VoiceLinesData.lua       # 50 voice lines (designer-editable)
        └── WorldScanner.lua         # World state collection
```

---

## Related Repositories

| Repository | Role |
|-----------|------|
| [lucineer-worker](../lucineer-worker) | Cloudflare Worker relay + Durable Object job queue |
| [lucineer-brain](../lucineer-brain) | 4-stage AI pipeline (Seed → Planner → Coder → Hermes) |
| [lucineer-memory](../lucineer-memory) | D1 player profiles, build history, conversations |
| [lucineer-vector](../lucineer-vector) | Vectorize semantic skill library |
| [lucineer-system](../lucineer-system) | Design docs and architecture specs |
| [casting-call](../casting-call) | Model routing atlas (Layer 8) |

---

## License

MIT
