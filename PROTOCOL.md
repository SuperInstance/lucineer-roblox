# Lucineer Roblox ↔ Worker API Protocol

**Version:** 1.0 — aligned with `lucineer-worker/src/index.ts` and `types.ts`
**Last verified:** 2026-08-03 against Worker commit (post-claiming, post-rate-limit)

This document defines the HTTP contract between the Roblox game client and the
Cloudflare Worker relay (`lucineer-relay`). It is the single source of truth for
payload shapes. If the Worker's `types.ts` and this document disagree, the Worker
is correct and this document must be updated.

---

## Base URL

```
https://lucineer-relay.casey-digennaro.workers.dev
```

## Authentication

| Endpoint group | Auth required |
|---|---|
| `POST /api/message` | **No** — public (rate-limited per session) |
| `GET /api/job/:jobId` | **No** — jobId serves as capability token |
| All other endpoints | **Yes** — `X-Lucineer-Key` header |

The Roblox client only calls the two public endpoints. The processor (Python)
uses the authenticated endpoints.

---

## Endpoints

### 1. POST `/api/message` — Player sends a chat message

Creates a job in the Worker's Durable Object. The processor polls
`/api/jobs/pending` to pick it up.

**Auth:** None (rate-limited: 10 messages/minute/session)

**Request:**
```json
{
  "sessionId": "1234567890-studio",
  "playerName": "BuilderBob",
  "message": "build me a castle",
  "playerState": {
    "position": { "x": 0, "y": 5, "z": 0 },
    "health": 100
  },
  "worldSnapshot": {
    "objects": [
      {
        "id": "Part-123",
        "type": "Part",
        "position": { "x": 10, "y": 5, "z": 10 },
        "properties": { "name": "TreeTrunk", "material": "Wood" }
      }
    ],
    "timestamp": 1722672000000
  }
}
```

| Field | Required | Type | Notes |
|---|---|---|---|
| `sessionId` | ✅ | `string` | `"{PlaceId}-{JobId}"` or `"{PlaceId}-studio"`. Must be stable per server instance. |
| `playerName` | ✅ | `string` | Roblox player username |
| `message` | ✅ | `string` | The player's chat message |
| `playerState` | ❌ | `object` | Player position, health, etc. |
| `worldSnapshot` | ❌ | `object` | Current world state — objects, timestamp, etc. If provided, stored in `world_state` table. |

**Response (200):**
```json
{
  "jobId": "a1b2c3d4e5f678901234567890123456",
  "status": "processing"
}
```

**Response (400):** Missing required fields
```json
{ "error": "Missing required fields: sessionId, playerName, message" }
```

**Response (429):** Rate limit exceeded
```json
{ "error": "Rate limit exceeded. Max 10 messages per minute per session." }
```

---

### 2. POST `/api/state` — Sync world state

Called periodically by the Roblox server (every 10s by default) to keep the
Worker's world_state table current for the processor.

**Auth:** `X-Lucineer-Key` header *(currently the Roblox client doesn't send this —
this endpoint is typically called by the processor or server-side only. The Roblox
server's HttpService calls it without auth since the endpoint is behind the auth gate.
The client should avoid calling this directly, or the Worker needs a public state
endpoint. See GAP_ANALYSIS #2b/#3 for the full discussion.)*

**Request:**
```json
{
  "sessionId": "1234567890-studio",
  "worldSnapshot": {
    "objects": [
      {
        "id": "CastleTower0",
        "type": "Part",
        "position": { "x": -18, "y": 11, "z": -18 },
        "properties": { "material": "Slate", "color": [150, 145, 140] }
      }
    ],
    "playerCount": 1,
    "timeOfDay": "14:00:00"
  }
}
```

| Field | Required | Type |
|---|---|---|
| `sessionId` | ✅ | `string` |
| `worldSnapshot` | ✅ | `object` |

**Response (200):**
```json
{ "ok": true }
```

---

### 3. GET `/api/job/:jobId` — Poll for job results

The Roblox client polls this every 0.5s after sending a message. The `jobId`
returned from `POST /api/message` serves as both the identifier and the
capability token — no auth header needed.

**Auth:** None

**Response (200) — job pending:**
```json
{
  "id": "a1b2c3d4e5f678901234567890123456",
  "sessionId": "1234567890-studio",
  "playerName": "BuilderBob",
  "message": "build me a castle",
  "status": "pending",
  "createdAt": 1722672000000
}
```

**Response (200) — job complete:**
```json
{
  "id": "a1b2c3d4e5f678901234567890123456",
  "sessionId": "1234567890-studio",
  "playerName": "BuilderBob",
  "message": "build me a castle",
  "status": "complete",
  "reply": "Castle's up — four tower walls in mixed stone, banners flying...",
  "commands": [
    {
      "type": "createPart",
      "target": "workspace.LucineerBuilds",
      "params": {
        "name": "CastleFloor",
        "shape": "Block",
        "size": { "x": 40, "y": 1, "z": 40 },
        "position": { "x": 0, "y": 0, "z": 0 },
        "material": "Slate",
        "color": { "r": 160, "g": 155, "b": 150 },
        "anchored": true
      }
    },
    {
      "type": "addLight",
      "target": "workspace.LucineerBuilds",
      "params": {
        "parent": "CastleBeacon",
        "lightType": "PointLight",
        "brightness": 8,
        "range": 60,
        "color": { "r": 255, "g": 200, "b": 100 },
        "shadows": true
      }
    }
  ],
  "createdAt": 1722672000000,
  "completedAt": 1722672005000
}
```

**Response (404):** Job not found
```json
{ "error": "Job not found" }
```

---

### 4. GET `/api/jobs/pending` — Processor polls for unprocessed jobs

Returns up to 10 pending, unclaimed jobs. The processor should call
`POST /api/job/:jobId/claim` immediately before starting work.

**Auth:** `X-Lucineer-Key` header

**Response (200):**
```json
{
  "jobs": [
    {
      "id": "a1b2c3d4e5f678901234567890123456",
      "sessionId": "1234567890-studio",
      "playerName": "BuilderBob",
      "message": "build me a castle",
      "status": "pending",
      "createdAt": 1722672000000,
      "attempts": 0
    }
  ],
  "notice": "Call POST /api/job/:jobId/claim before processing to prevent duplicate work."
}
```

---

### 5. POST `/api/job/:jobId/result — Processor posts results

Called by the processor after generating the build commands and reply text.

**Auth:** `X-Lucineer-Key` header

**Request:**
```json
{
  "reply": "Castle's up — four tower walls, banners flying, torches lit...",
  "commands": [
    {
      "type": "createPart",
      "target": "workspace.LucineerBuilds",
      "params": {
        "name": "CastleFloor",
        "shape": "Block",
        "size": { "x": 40, "y": 1, "z": 40 },
        "position": { "x": 0, "y": 0, "z": 0 },
        "material": "Slate",
        "color": { "r": 160, "g": 155, "b": 150 },
        "anchored": true
      }
    }
  ],
  "files": []
}
```

| Field | Required | Type | Notes |
|---|---|---|---|
| `reply` | ✅ | `string` | Lucineer's in-character response text |
| `commands` | ❌ | `BuildCommand[]` | Array of build commands for `CommandExecutor` |
| `files` | ❌ | `RemoteFile[]` | Optional remote asset references |

**Response (200):**
```json
{
  "ok": true,
  "jobId": "a1b2c3d4e5f678901234567890123456",
  "filtered": false,
  "filterNotice": "TextService:FilterStringAsync() must be called on `reply` before display."
}
```

---

### 6. POST `/api/job/:jobId/claim` — Atomically claim a job

Prevents race conditions when multiple processors are running.

**Auth:** `X-Lucineer-Key` header

**Response (200):**
```json
{
  "ok": true,
  "job": {
    "id": "a1b2c3d4e5f678901234567890123456",
    "sessionId": "1234567890-studio",
    "playerName": "BuilderBob",
    "message": "build me a castle",
    "status": "pending",
    "createdAt": 1722672000000,
    "claimedAt": 1722672001000,
    "attempts": 1
  }
}
```

**Response (409):** Already claimed
```json
{ "ok": false, "error": "Job already claimed or not found" }
```

---

## Build Command Envelope

Every command in the `commands` array follows this shape:

```json
{
  "type": "createPart",
  "target": "workspace.LucineerBuilds",
  "params": { ... }
}
```

### Supported command types

| `type` | Parameters | Description |
|---|---|---|
| `createPart` | `name`, `shape`, `size`, `position`, `material`, `color`, `anchored`, `transparency`, `reflectance` | Creates a Part in the build folder |
| `addLight` | `parent`, `lightType`, `brightness`, `range`, `color`, `shadows` | Attaches a light to a named part |
| `addParticle` | `parent`, `texture`, `rate`, `lifetime`, `speed`, `color`, `size`, `transparency`, `velocity` | Attaches a ParticleEmitter |
| `sendMessage` | `message` | Fires a RemoteEvent to display Lucineer's dialogue |

### Color format

Colors are RGB objects with `r`, `g`, `b` keys (0–255):

```json
{ "r": 255, "g": 200, "b": 100 }
```

### Position/Size format

3D vectors use `x`, `y`, `z` keys:

```json
{ "x": 10, "y": 5, "z": -20 }
```

### Shapes

| Shape string | Roblox Enum |
|---|---|
| `Block` | `Enum.PartType.Block` |
| `Ball` | `Enum.PartType.Ball` |
| `Cylinder` | `Enum.PartType.Cylinder` |
| `Wedge` | `Enum.PartType.Wedge` |
| `Cone` | `Enum.PartType.Cone` |

---

## Session Identity

`sessionId` is constructed in `Config.lua`:

```lua
Config.SESSION_ID = string.format("%d-%s", game.PlaceId,
    (game.JobId ~= "" and game.JobId or "studio"))
```

- In Studio: `"{PlaceId}-studio"`
- In live game: `"{PlaceId}-{serverJobId}"`

This ID is sent with every `/api/message` and `/api/state` call so the Worker
can route jobs and state correctly.

---

## Other endpoints

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/api/health` | GET | None | Health check — `{ "status": "ok", "timestamp": ... }` |
| `/api/state/:sessionId` | GET | Key | Retrieve stored world state for a session |
| `/api/trajectory` | POST | Key | Write MOLT trajectory events to R2 |
| `/api/diag` | GET | Key | Diagnostic — schema info, job count |

---

## Error Handling Contract

| HTTP Status | Meaning | Client action |
|---|---|---|
| 200 | Success | Process response |
| 400 | Bad request (missing fields, bad JSON) | **Do not retry** — fix the payload |
| 401 | Unauthorized (missing/invalid key) | Check credentials |
| 404 | Not found | Job/session doesn't exist |
| 409 | Conflict (already claimed) | Try next job |
| 429 | Rate limited | Back off and retry |
| 500 | Server error | Retry with backoff |

**Critical:** The Roblox client's `Http.lua` must NOT retry on 4xx (except 429).
A 400 means the payload is wrong — retrying the same payload just wastes requests.
