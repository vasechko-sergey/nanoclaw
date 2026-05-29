# iOS Protocol Contract

This document is the **single source of truth** for messages that cross the boundary between the iOS Jarvis app (`ios/JarvisApp/`) and the NanoClaw host (`src/channels/ios-app.ts`).

**If you change a message shape on one side, update both code paths and this document in the same commit.** Drift between the two will silently break real users.

## Transport

- **WebSocket** at `ws(s)://<server>:<IOS_APP_PORT>` (3001 by default). All real-time messages flow here. Both sides exchange JSON-encoded objects as binary or text frames.
- **HTTP** at the same origin for endpoints the WS can't handle (health-history poll/upload, background proactive wake when WS is dead).
- **APNs** silent / alert pushes wake the iOS app when the WS is closed and the server has buffered an inbound message.

The WebSocket server is an `ws` `WebSocketServer` mounted on the same `http.Server` that serves the HTTP routes — they share a port. There is no upgrade-path negotiation; the client picks WS or HTTP per call site.

## Authentication

- iOS sends `{ type: "auth", token, platformId, apnsToken? }` immediately after connecting.
- Server responds with `{ type: "auth_ok", commands: [...] }` and starts forwarding inbound state, or closes the socket with code 4001.
- HTTP requests carry `Authorization: Bearer <IOS_APP_TOKEN>`.
- `IOS_APP_TOKEN` matches on both sides; transport TLS is provided by Tailscale in the user's setup.

The server keeps a per-`platformId` set of live sockets (`wsClients`) — multiple devices can share an id and all receive broadcasts.

---

## WebSocket Messages — iOS → server

All envelopes are JSON. Top-level required fields shown without `?`; optional fields with `?`. Source: `WebSocketClient.swift`. Server dispatch: `createIosWsHandler` switch in `src/channels/ios-app.ts`.

### `auth`
```ts
{
  type: "auth",
  token: string,           // must equal env IOS_APP_TOKEN
  platformId: string,      // "ios:<UUID>" — stable per-install identity
  apnsToken?: string       // optional: persist this device's APNs token at the same time
}
```
Must be the first frame. Any other frame from an unauthed socket triggers `ws.close(4001)`. On success the server appends this `ws` to `wsClients[platformId]`, persists the APNs token if supplied, replies with `auth_ok`, and drains any buffered offline messages for this device.

### `message`
```ts
{
  type: "message",
  text: string,                // may be ""; required to be present even when only sending attachments
  clientMessageId?: string,    // UUID — required for ack-based retry; without it no ack is sent
  timezone?: string,           // IANA tz like "Europe/Moscow" — last seen value cached server-side
  status?: string,             // user-visible emoji/status string, prepended as "[status: …]"
  conversationId?: string,     // UUID → thread_id; absent = default thread
  attachments?: Array<{
    name: string,
    mimeType: string,
    size: number,
    data: string,              // base64
    duration?: number          // seconds, for audio attachments
  }>,
  context?: {                  // inline iOS context dict — see "Inline context block" below
    timezone?: string,
    location?: { city?: string; lat?: number; lon?: number },
    health?: { steps?: number; heartRate?: number; activeEnergy?: number;
               sleepHours?: number; restingHeartRate?: number; exerciseMinutes?: number },
    device?: { battery?: number; lowPower?: boolean; network?: string },
    nextEvent?: { title?: string; start?: string /* ISO */ },
    timestamp?: string,        // ISO
    status?: string
  }
}
```
Server flow:
1. If `clientMessageId` is present and already in the per-device LRU, immediately reply `message_ack` and stop. (At-least-once delivery with dedupe.)
2. Build agent-visible text as `inlineCtx + "[status: …]\n"? + msg.text`. `inlineCtx` is the formatted `[iOS Context — …]` block (see "Inline context block").
3. Attachments are forwarded as-is into the agent message `content.attachments`.
4. Call `onInbound(platformId, conversationId, …)` — this becomes a normal agent message.
5. Send `{ type: "message_ack", clientMessageId }` back.

### `new_conversation`
```ts
{
  type: "new_conversation",
  conversationId: string       // UUID
}
```
iOS sends this when the user opens a fresh thread. **Server-side this is a no-op** — the next `message` carrying the new `conversationId` is what actually causes a new session/container to be allocated. Kept for forward compat / explicit signalling.

### `feedback`
```ts
{
  type: "feedback",
  messageId: string,           // server-side id of the rated assistant message
  value: boolean,              // true = 👍, false = 👎
  messageText: string,         // <=800 chars, the actual text being rated
  conversationId?: string
}
```
Server forwards as a synthetic agent-inbound message: `[user feedback: 👍 on your previous message]` followed by a quoted block of `messageText`. There is **no** `feedback_ack` emitted by the server today — the iOS handler for `feedback_ack` is defensive.

### `apns_token`
```ts
{
  type: "apns_token",
  token: string                // hex device token
}
```
Persists / refreshes the device's APNs token. Stored in `data/ios-apns-tokens.json`, used to wake the device when an outbound message arrives while the WS is closed.

### `message_delivered`
```ts
{
  type: "message_delivered",
  messageId: string,           // server-side message id from a prior server→iOS "message"
  conversationId?: string
}
```
The iOS app emits this when an assistant message lands in its UI. Server records into `ReadReceiptStore` (persisted to `data/ios-read-receipts.json`) and accumulates the receipt for injection on the next `context_response` as a `[read receipts]` block.

### `message_read`
```ts
{
  type: "message_read",
  messageId: string,
  conversationId?: string
}
```
Emitted once per message-id (client de-duplicates with `sentReadIds`) when the user actually sees the message. Same persistence + injection path as `message_delivered`.

### `action_response`
```ts
{
  type: "action_response",
  messageId: string,           // the questionId from the original server→iOS "action"
  buttonId: string,
  buttonLabel: string,
  conversationId?: string
}
```
Server tries `cfg.onAction(questionId, buttonId, platformId)` — the approvals subsystem owns the live registry of pending questions. If that returns nothing meaningful (no live question), the response is instead forwarded as a normal agent-inbound message: `[user selected: "<buttonLabel>" (id: <buttonId>)]`.

### `context_response`
```ts
{
  type: "context_response",
  requestId: string,           // echoes the requestId from the matching context_request
  context: { /* same shape as the inline `context` dict in `message` */ },
  conversationId?: string
}
```
Reply to an agent-initiated pull (sent via `context_request`). Server adds the last-known timezone if missing, injects any pending read receipts, runs the formatter (`buildCtx`) to produce a `[iOS Context — …]` block, and pushes it as an agent-inbound message. If formatting yields an empty block the agent sees `[iOS context — requested data unavailable]`.

### `proactive`
```ts
{
  type: "proactive",
  trigger: string,             // e.g. "geofence-enter", "health-alert", "calendar-soon"
  payload?: Record<string, unknown>,
  ts?: string,                 // ISO; server defaults to now
  tz?: string                  // IANA tz; cached server-side
}
```
Wakes the agent with no user-visible request. Server formats as:
```
[proactive trigger=<trigger> ts=<ts> tz=<tz>]
key1=value1 key2=value2
---
```
…and posts as an agent-inbound message. If the WS is unavailable when the trigger fires, the iOS side falls back to `POST /ios/proactive` (see HTTP section) with the same envelope shape.

---

## WebSocket Messages — server → iOS

All envelopes are JSON. Source: `createIOSAdapter.deliver` and `createIosWsHandler` in `src/channels/ios-app.ts`. Handler: `handleIncoming` in `WebSocketClient.swift`.

### `auth_ok`
```ts
{
  type: "auth_ok",
  commands: Array<{ command: string; description: string }>
}
```
Sent in response to `auth`. `commands` is the slash-command menu (`BOT_COMMANDS`, each prefixed with `/`). On receipt iOS marks the connection live, flushes its outbox, starts the heartbeat, and resends any pending APNs token.

### `message` (assistant text)
```ts
{
  type: "message",
  id: string,                  // server-side message id
  text: string,
  conversationId?: string,
  timestamp: string            // ISO
}
```
Rendered as an assistant text bubble in the active conversation, or routed to the background-conversation handler if `conversationId` doesn't match the active one. On arrival in the active conversation iOS auto-emits `message_delivered`.

### `image`
```ts
{
  type: "image",
  id: string,
  data: string,                // base64
  filename: string,
  conversationId?: string,
  timestamp: string
}
```
Legacy / image-specific path. The host classifies files with image MIME or image extensions and ships them as `image` for backward compat; everything else uses `file`.

### `file`
```ts
{
  type: "file",
  id: string,
  name: string,
  size: number,
  mimeType: string,            // defaults to "application/octet-stream"
  data: string,                // base64
  url?: string,                // optional remote URL (server may omit)
  conversationId?: string,
  timestamp: string
}
```
Generic attachment from the agent. `url` is reserved for future use — current host always sends inline base64.

### `action`
```ts
{
  type: "action",
  id: string,                  // questionId (used as messageId in action_response)
  text: string,                // the question / title
  buttons: Array<{
    id: string,
    label: string,
    style?: "primary" | "secondary" | "destructive" /* default "primary" */
  }>,
  conversationId?: string,
  timestamp: string
}
```
Emitted when the agent calls an `ask_question` flow. iOS renders a card with tappable buttons; tap fires `action_response`.

When the agent provides a text fallback (`content.text`), the host *also* emits a regular `message` envelope alongside `action` so offline / APNs paths still get something readable.

### `status`
```ts
{
  type: "status",
  id: string,
  text: string,
  level?: "info" | "warning" | "error" /* default "info" */,
  kind?: string,               // e.g. "system"; "system" status drives the thinking-detail strip
  conversationId?: string,
  timestamp: string
}
```
Banner row — renders as a divider with icon + text on iOS. `kind === "system"` is also stashed in `thinkingDetail` for the busy-state indicator, auto-cleared after ~30 s.

### `message_ack`
```ts
{
  type: "message_ack",
  clientMessageId: string
}
```
Confirms server received and committed the matching iOS `message`. iOS removes the entry from its outbox and marks the bubble `.delivered`. Idempotent: an ack for an unknown id is a no-op.

### `context_request`
```ts
{
  type: "context_request",
  requestId: string,
  fields: string[]             // hint to the client which subsystems to query
}
```
Emitted by the host when the agent runs the `request_context` MCP tool. iOS gathers the requested fields and replies with `context_response`. If the device is offline at the moment of the call, the host short-circuits the agent with `[iOS context unavailable — device offline]` instead of waiting.

### `typing_start` / `typing_stop`
```ts
{ type: "typing_start" }
{ type: "typing_stop"  }
```
iOS handles these in `handleIncoming` to drive the typing indicator. They are **not currently emitted by `src/channels/ios-app.ts`** — typing is inferred from `lastUserSentAt` and the busy timeout in iOS. Treat as reserved; safe to start emitting from the server in the future.

### `feedback_ack`
```ts
{ type: "feedback_ack" }
```
Handled by iOS as a no-op. **Not currently emitted by the server.** Reserved.

---

## HTTP Endpoints

All endpoints are served by the same `http.Server` that hosts the WS. JSON bodies. `Authorization: Bearer <IOS_APP_TOKEN>` required on the authed routes.

### `GET /ios/health`
```http
GET /ios/health
→ 200 {"ok":true}
```
Unauthenticated liveness check. Used by the iOS app's settings view and by external monitoring.

### `POST /ios/health/upload`
```ts
// request body
{
  requestId?: string,                       // matches a request from /ios/health/requests
  days: Array<Record<string, unknown>>      // each row must include a "date" key (string)
}
// → 200 {"ok":true} | 400 on parse failure | 401 if bearer mismatch
```
Background path for HealthKit daily-aggregate ingestion. iOS may call this when the app is woken by HealthKit background delivery, separate from any WS state. Server upserts by `date` into `<healthHistoryDir>/raw.jsonl` and removes the serviced request file. Request body capped at 2 MB.

### `GET /ios/health/requests`
```ts
// response body
{
  requests: Array<{
    requestId: string,
    from: string,                            // ISO date "YYYY-MM-DD"
    to: string                               // ISO date
  }>
}
// → 401 if bearer mismatch
```
Pulled by the iOS app on foreground and after HealthKit background-delivery wake. Each entry corresponds to a JSON file under `<healthHistoryDir>/requests/<requestId>.json` written by the analyzer agent. The app fetches the data and POSTs to `/ios/health/upload` with the matching `requestId`.

### `POST /ios/proactive`
```ts
// request body — same shape as the WS `proactive` envelope minus `type`
{
  platformId: string,
  trigger: string,
  payload?: Record<string, unknown>,
  ts?: string,
  tz?: string
}
// → 204 on accept | 400 on missing platformId/trigger or parse failure | 401 if bearer mismatch
```
HTTP fallback for `proactive` when the WS is closed. Equivalent server-side outcome: the agent receives the same `[proactive trigger=… ts=… tz=…]\n…\n---` text. There is no body in the success response.

---

## APNs Silent Push

Triggered server-side from `deliverTextAndFiles` when an outbound message must be delivered and no live WS exists for the target `platformId`.

- Endpoint: `api.push.apple.com` or `api.sandbox.push.apple.com` (selected by `IOS_APNS_ENV`).
- Topic: `IOS_APNS_BUNDLE_ID`. JWT auth via ES256 (`IOS_APNS_KEY_ID` / `IOS_APNS_TEAM_ID` / `IOS_APNS_KEY`). JWT cached and rotated every 55 minutes.
- `apns-push-type: alert`. Payload:
  ```json
  { "aps": { "alert": { "body": "<preview>" }, "sound": "default" },
    "conversationId": "<optional>" }
  ```
  `body` is the first 80 chars of the outbound text, or the first attachment's filename, or `"Новое сообщение"` as a last resort.
- 410 ("unregistered") and 400 responses cause the host to drop the dead device token from the persisted map.

The actual outbound message stays buffered server-side in `pendingMessages[platformId]` (LRU, cap `MAX_PENDING_PER_DEVICE = 200`); it's delivered on the next reconnect, deduped by id via `deliveredIds[platformId]`.

---

## Cross-Cutting Rules

- **`clientMessageId`**: end-to-end idempotency. iOS sends a UUID with every user `message`; server dedupes per-device (LRU of 500 ids); server emits `message_ack` with the same id. iOS removes the outbox entry on ack. iOS retries with the same id after 30 s without an ack, so dedup is load-bearing.
- **`conversationId` ↔ `thread_id`**: maps to a per-session container. New `conversationId` = new container = isolated agent context. iOS UUIDs are stringified directly; server treats the value as opaque. `new_conversation` is purely advisory — the first `message` carrying the new id is what materializes the session.
- **Inline context block**: every `message` payload carries an optional `context` dict (location, health, device, nextEvent, status, timestamp, timezone). The server formats this through `buildCtx` into a human-readable `[iOS Context — <localized ts>]` block and prepends it to the agent-visible text. The pull model (`context_request` → `context_response`) is layered on top for cases where the agent wants fresh data.
- **Read receipts** (`message_delivered`, `message_read`) accumulate server-side in `ReadReceiptStore` and are injected into the agent's next inbound message as a `[read receipts]` block on the next `context_response`. They never trigger a wake on their own.
- **Proactive triggers** are wake events; their `payload` is the entire ground truth that gets passed in-band. Agents pull additional details via `request_context` if they need them, rather than expecting the trigger to carry full state.
- **Offline buffering**: when a `platformId` has no live socket, outbound messages are queued in `pendingMessages` and replayed on reconnect. Replay is filtered through `deliveredIds` so reconnects can't double-deliver. iOS also dedupes by message id in `route`.
- **Bearer everywhere**: HTTP routes hard-fail on bearer mismatch (401). WS auth happens via the `auth` frame, not headers — there is no URL-bearer fallback.

---

## Versioning

This protocol has no version field. Both sides must update together. Treat any unfamiliar `msg.type` as a silent drop on the receiver — forward-compatibility is allowed (the server may add a type the iOS client doesn't know yet), but hard schema changes to existing types require a coordinated release.

---

## Where this is implemented

- **iOS**: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`
  - WS receive switch: `handleIncoming(_:)`
  - WS senders: `send(text:…)`, `sendNewConversation`, `sendFeedback`, `sendContextResponse`, `sendMessageDelivered`, `sendMessageRead`, `sendActionResponse`, `sendProactive`, `sendApnsToken`
  - Outbox / ack: `flushOutbox`, `handleMessageAck`, `bumpStaleSentEntries`
- **Server**: `src/channels/ios-app.ts`
  - WS dispatch: `createIosWsHandler`
  - Outbound: `createIOSAdapter.deliver`, `deliverViaSock`, `deliverTextAndFiles`
  - HTTP routes: inline in `setup()` (`/ios/health`, `/ios/health/requests`, `/ios/health/upload`) plus standalone `createIosHttpHandler` for `/ios/proactive`
  - APNs: `getApnsJwt`, `sendApnsPush`
- **Context formatter**: `buildCtx` in `src/channels/ios-app.ts` is the canonical formatter for both inline context (in `message`) and pulled context (in `context_response`).

When adding a new type:
1. Update this document first.
2. Implement on the emitting side (with a `msg.type` literal).
3. Add the receiver branch in the same commit.
4. Update unit tests on both sides.
