# iOS App Protocol v2 — Layer Separation and Delivery Guarantees

**Status:** design approved, ready for implementation plan
**Date:** 2026-05-31
**Scope:** the `ios-app` channel only (iOS app ↔ NanoClaw adapter ↔ agent-runner). Other channels are not touched.

## Problem

The iOS-app channel currently mixes responsibilities across three layers:

- The iOS app sends a rich context dictionary (health, calendar, device, status, next event) on every user message.
- The adapter formats a human-readable context block from that dict, injects read receipts into it, holds an in-memory pending queue (cap 200, silently drops on overflow), and performs APNs push.
- The agent reads pre-formatted text and uses an MCP `request_context` tool with no timeout, no TTL on orphaned requests, and no per-session scope check.

Observed problems:

- `oneShotQueue` (feedback, button taps, `new_conversation`) lives in memory only and is lost on app crash.
- `pendingMessages` is capped at 200 per device; overflow drops messages silently with no signal to the app.
- `request_context` orphans accumulate forever — no TTL, no timeout, no cleanup.
- Read receipts are truncated at 20 with no signal.
- Reconnect races can briefly hold two sockets per `platformId`, allowing duplicate dispatch.
- Any agent in any group can issue `request_context` for any device.
- Oversized image base64 payloads can OOM the server during transcoding.

## Goal

Restructure the three layers so each one owns a single, well-bounded concern:

| Layer        | Owns                                                                                                                              |
|--------------|-----------------------------------------------------------------------------------------------------------------------------------|
| iOS app      | Local storage of dialogs/messages, send/receive with acks, minimal inline context (location + time + timezone + optional locality).|
| Adapter      | Transport: WS lifecycle, durable persistence, delivery guarantees, status pass-through, keepalive, per-session scope enforcement. |
| Agent        | Semantic processing; pulls anything beyond minimal context via technical messages (`request_context`).                            |

Hard rules:
- Adapter never formats context blocks. It writes raw `InlineContext` into the session DB; the agent renders prefix text.
- Agent never sees duplicates. The transport layer in the adapter deduplicates by envelope id.
- Read receipts are an internal app↔adapter signal for UI checkmarks; they never reach the agent.
- The `ios-app` wire protocol is defined in a single canonical TypeScript module, imported by both the adapter and the agent. The Swift mirror is hand-maintained but locked to the canonical source by contract tests with shared JSON fixtures.

## Non-Goals

- Other channels (Telegram, Slack, GitHub, etc.) are not touched.
- `messages_in`/`messages_out` table shapes in session DBs are not changed; only the `meta`/`payload` content is enriched.
- Central DB schema is not changed.
- APNs is removed. Push wakeups are out of scope for v2.
- Video attachments are dropped from the iOS app. Image and file attachments remain.
- Property-based testing is deferred to a follow-up PR.

## Architecture

### Layer 1 — iOS app

- Source of truth for the chat UI: conversations, messages, attachments, statuses.
- Local store backed by SQLite (via GRDB). Replaces `OutboxStore` (JSON queue) and `MessageCache` (JSON index).
- Inline context attached to outbound user messages: `location {lat, lon, accuracy?}`, `timestamp` (ISO-8601), `timezone` (IANA), optional `locality` (only if already cached from a previous CLPlacemark resolve — no on-demand geocoding).
- Replies to `context_request` envelopes from the adapter by gathering fields via on-device managers (`HealthManager`, `CalendarManager`, `LocationManager`, `DeviceManager`, `ScreenStateManager`) and sending `context_response`.
- Status state machine per outbound message: `composing → queued → sending → sent → delivered → read | failed`.
- The app does not know an agent exists. From its perspective, the adapter is "the server".

### Layer 2 — Adapter (`src/channels/ios-app/v2/`)

- Transport: WebSocket lifecycle (accept, auth handshake, native ping/pong every 25 s with 10 s pong timeout, application-level `control:ping/pong` every 60 s as proxy fallback, server-initiated close on misbehavior, reconnect handled by the client).
- Durable per-device outbound queue persisted to `data/ios-app/transport.db` (host-side SQLite, separate from session DBs). Entries are removed only on explicit `ack` from the app.
- Durable per-session inbound persisted via the existing session-manager into `inbound.db`. The `ack` to the app is only sent after the `inbound.db` write commits.
- Deduplicates inbound by envelope `id` (LRU-backed table, pruned by `received_at < now - 24h` via a daily sweep). Agents never see duplicates.
- Cursor-based replay on reconnect. On `auth`, the app provides `last_seen_inbound_seq` (the highest seq it has received from the adapter). The adapter sends all outbound queue entries with `seq > last_seen_inbound_seq` in seq order. Symmetrically, the adapter persists `last_seen_outbound_seq` (the highest seq it has received from the app) for inbound dedup.
- Status channel: `status:delivered` and `status:read` from the app land in a local `ReadReceiptStore` for UI use only. They are not propagated into `inbound.db`.
- Per-session scope for `context_request`: the agent does not specify a target `platform_id`. The adapter resolves the target from `session_id → messaging_group → platform_id`. Requests issued from sessions not wired to the `ios-app` channel are rejected immediately by writing a synthetic error response back to `inbound.db` with the same `request_id`.

### Layer 3 — Agent (`container/agent-runner/src/`)

- Receives clean user text plus minimal inline context through `messages_in`.
- Renders the inline context as a strict prefix block via `container/agent-runner/src/channels/ios-app-format.ts`. Format template lives in code; missing fields shrink the prefix.
- Sends outbound text, files, `ask_question`, and `status` messages through `messages_out`, unchanged from today.
- Pulls extra context via the new `request_context` MCP tool. The tool is async with a deferred await: it writes a `messages_out` row of type `context_request`, registers a pending promise, and either resolves on `context_response` arrival or rejects on a configurable timeout (default 10 s, 1–30 s range).
- Catalog of pullable fields in v1: `health`, `calendar`, `device`, `next_event`, `recent_locations`, `screen_state`.

### Contract Between Layers

- **iOS ↔ Adapter:** WS protocol v2, defined in `shared/ios-app-protocol/v2.ts`.
- **Adapter ↔ Agent:** existing session DBs `inbound.db` and `outbound.db`. The `meta` field on `messages_in` carries a discriminator (`kind: 'user_message' | 'context_response' | 'system'`); the `payload` on `messages_out` carries `type: 'context_request'` rows in addition to today's text/files/ask_question/status types.

## Wire Protocol v2

### Envelope

```json
{
  "v": 2,
  "kind": "data" | "control" | "ack" | "status",
  "type": "<envelope type>",
  "id": "<uuid>",
  "seq": 42,
  "ts": "2026-05-31T12:00:00.000Z",
  "payload": { ... }
}
```

- `v`: protocol version. The adapter rejects the handshake if `v != 2`.
- `kind`: a coarse category. The transport layer routes by `kind`; the dispatcher routes by `type`.
- `id`: UUID. Used for idempotent dedup on the receiver and for ack tracking.
- `seq`: monotonic per-direction. `app→adapter` has its own counter; `adapter→app` has its own. Used for cursor replay. Required for `kind=data` and for `kind=control` types that are part of the ordered stream (`message`, `context_request`, `context_response`, `new_conversation`, `action_response`, `feedback`). Set to `null` (and omitted from the cursor) for envelopes that are stateless transport-internal: `ack`, `ping`, `pong`, and `status:delivered` / `status:read`.
- `ts`: client-side clock at envelope creation. Not trusted for security; used only as a UX/ordering hint when seqs match.
- `payload`: type-specific shape.

### Type Catalog

| kind    | type                | direction        | payload                                                                                       |
|---------|---------------------|------------------|-----------------------------------------------------------------------------------------------|
| control | `auth`              | app→adapter      | `{ token, last_seen_inbound_seq, capabilities: string[] }`                                    |
| control | `auth_ok`           | adapter→app      | `{ last_seen_outbound_seq, server_time }`                                                     |
| control | `auth_fail`         | adapter→app      | `{ reason }`                                                                                  |
| data    | `message`           | both             | `{ thread_id, text, attachments?, context? }` (`context` only on `app→adapter`)               |
| control | `context_request`   | adapter→app      | `{ request_id, fields: ContextField[], params?: { ... } }`                                    |
| control | `context_response`  | app→adapter      | `{ request_id, data: Record<string, unknown>, errors?: Record<string, string> }`              |
| control | `new_conversation`  | app→adapter      | `{ thread_id }`                                                                               |
| control | `action_response`   | app→adapter      | `{ action_id, choice }`                                                                       |
| control | `feedback`          | app→adapter      | `{ message_id, kind: 'up' | 'down' }`                                                         |
| control | `ping`              | app→adapter      | `{ nonce: string }`                                                                           |
| control | `pong`              | adapter→app      | `{ nonce: string }`                                                                           |
| ack     | `ack`               | both             | `{ id, seq }` — the id and seq of the envelope being acknowledged                             |
| status  | `delivered`         | both             | `{ ids: string[] }`                                                                           |
| status  | `read`              | app→adapter      | `{ ids: string[] }`                                                                           |

Inline context shape (only on `data:message` from app to adapter):

```ts
type InlineContext = {
  location?: { lat: number; lon: number; accuracy?: number };
  timestamp: string;     // ISO-8601
  timezone: string;      // IANA
  locality?: string;
};
```

Context catalog enum:

```ts
type ContextField = 'health' | 'calendar' | 'device' | 'next_event' | 'recent_locations' | 'screen_state';
```

Types removed compared to v1:
- `proactive` — folded into `data:message` with a `meta` marker if still needed.
- `apns_token` — APNs is removed.
- `message_delivered` / `message_read` — replaced by `status:delivered` / `status:read`.
- Separate `image` type — all media goes through `attachments[]`.

### Auth Handshake

1. App opens the WS connection and sends `control:auth { token, last_seen_inbound_seq }`.
2. The adapter validates the token. On failure it sends `auth_fail` and closes.
3. The adapter updates `devices.last_seen_outbound_seq = max(current, auth.last_seen_inbound_seq)` and deletes all `outbound_queue` rows with `seq <= auth.last_seen_inbound_seq` (the app has acknowledged everything up to and including that seq).
4. The adapter replies with `auth_ok { last_seen_outbound_seq, server_time }`. The app inspects `last_seen_outbound_seq` — if its own `last_sent_outbound_seq > last_seen_outbound_seq`, there are un-acked sends; the local dispatcher resets them from `sending` back to `queued` for retransmission.
5. The adapter drains the `outbound_queue` to the live socket in seq order.

### Ack Flow

- Every `data` envelope and every `control` envelope of an ordered type (`message`, `context_request`, `context_response`, `new_conversation`, `action_response`, `feedback`) requires a matching `ack:ack` from the receiver, sent only after persistence (commit of the local TX).
- `ack`, `ping`, `pong`, and `status:*` envelopes are stateless: no ack, no retry timer, no seq, no dedup.
- The sender holds a 5-second retry timer per envelope. On timeout it resends with the same `id` and `seq`. After three retries without an ack, the sender forces a reconnect; retransmission continues after `auth_ok`.
- The receiver dedups by `id`. On a duplicate it re-sends the ack and does not process the payload again.
- `status:delivered` and `status:read` are batched and best-effort. If a batch is lost, the next user action that touches the affected message re-emits its current status.

### Ping/Pong

- `control:ping` and `control:pong` are stateless. They do not write to `inbound.db`, do not update `last_seen_outbound_seq`, do not consume a seq, and are not retried with timers.
- Native WS ping/pong frames (URLSessionWebSocketTask on iOS, `ws` library on the server) handle most keepalive. The application-level ping is a fallback for proxies that strip binary pings.

### Canonical Module

The protocol lives in `shared/ios-app-protocol/v2.ts` as Zod schemas with derived TypeScript types and a `z.discriminatedUnion` for the full envelope set. Both the adapter (`src/channels/ios-app/v2/`) and the agent (`container/agent-runner/src/`) import it.

- Adapter usage: parse every incoming frame via `AnyEnvelope.parse(JSON.parse(raw))`. On failure, close the socket with reason `protocol_violation`. No silent ignore.
- Agent usage: import `ContextFieldEnum` for the `request_context` tool schema and `InlineContext` for the inbound-format helper.
- Build wiring: `container/build.sh` copies `shared/` into the image at `/app/shared/`. Bun imports `.ts` directly. Host uses a tsconfig path alias `@shared/ios-app-protocol`.
- Swift mirror: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` is hand-written Codable structs. Contract tests pin the mirror to the TypeScript source via shared JSON fixtures (see "Tests" below).

## Adapter Internals

### Storage

A new SQLite file `data/ios-app/transport.db`, opened with `better-sqlite3`. One writer (the adapter process).

```sql
CREATE TABLE devices (
  platform_id TEXT PRIMARY KEY,
  last_seen_outbound_seq INTEGER NOT NULL DEFAULT 0,   -- highest app→adapter seq we've persisted
  last_emitted_inbound_seq INTEGER NOT NULL DEFAULT 0, -- highest adapter→app seq we've allocated
  capabilities_json TEXT,
  updated_at INTEGER NOT NULL
);

CREATE TABLE outbound_queue (
  platform_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  id TEXT NOT NULL,
  kind TEXT NOT NULL,
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (platform_id, seq)
);
CREATE INDEX idx_outbound_id ON outbound_queue (platform_id, id);

CREATE TABLE inbound_dedup (
  platform_id TEXT NOT NULL,
  id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (platform_id, id)
);
-- pruned daily where received_at < now - 24h

CREATE TABLE pending_context_requests (
  request_id TEXT PRIMARY KEY,
  platform_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  fields_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
```

### Inbound Path (App → Agent)

1. Receive raw frame from WS. Parse via `AnyEnvelope.parse`. On failure, close with `protocol_violation`.
2. If `seq <= devices.last_seen_outbound_seq` or `id` exists in `inbound_dedup`, resend the ack and drop.
3. In a single transaction: insert into `inbound_dedup`, update `devices.last_seen_outbound_seq = max(current, seq)`, then dispatch by `type`:
   - `data:message` — write to `inbound.db.messages_in` via the session manager. `meta = { kind: 'user_message', ios_context, attachments }`. The agent formats the prefix, not the adapter.
   - `control:context_response` — look up `pending_context_requests[request_id]`, resolve the agent-side deferred promise, delete the row. Does not append to `messages_in` as a user-visible turn — it is a tool response.
   - `control:new_conversation` — create the thread in the session manager.
   - `control:action_response` — invoke the `onAction` callback (approvals path).
   - `control:feedback` — append a system row to `inbound.db.messages_in` with `meta = { kind: 'system', subtype: 'feedback' }`, text `[feedback: 👍/👎 on msg <id>]`.
   - `status:delivered` / `status:read` — update the local `ReadReceiptStore` for UI bookkeeping only. Not written to `inbound.db`. Not visible to the agent.
   - `control:ping` — reply with `control:pong { nonce }` synchronously. Not persisted, not seq-tracked.
4. Commit the transaction. Send `ack:ack { id, seq }` to the app.

### Outbound Path (Agent → App)

1. Poll `outbound.db.messages_out`, same loop as today.
2. For each row:
   - Allocate `seq = devices.last_emitted_inbound_seq + 1`.
   - In a single transaction: insert into `outbound_queue` with the allocated seq, update `devices.last_emitted_inbound_seq`. Commit.
   - If a live WS exists for this `platform_id`, send the envelope. Otherwise it sits in the queue.
3. On `ack:ack { id }` from the app, delete from `outbound_queue` where `id = ?`.
4. Retry timer per device (5 s). Any envelope in `outbound_queue` older than 5 s with no ack is resent with the same `id` and `seq`.
5. Overflow: before inserting into `outbound_queue`, count rows for the device. If the count is at 1000, delete the oldest row (lowest `seq`) before inserting. No notification to the agent. No notification to the app.

### Connection Lifecycle

- Native WS ping every 25 s; pong timeout 10 s. On timeout, close the socket. The client reconnects.
- Application-level `control:ping` cadence: 60 s. Same effect on ack failure as native ping — close and reconnect.
- Single live socket per `platform_id`. If a new connection completes auth while an older one is still open, the older one receives close `superseded`. Map `Map<platform_id, ws>` is strictly singleton.

### Per-Session Scope for `context_request`

- Agent writes a `messages_out` row with `type: 'context_request'` and `payload: { request_id, fields, params }`. No `platform_id`.
- Adapter resolves `platform_id` from `session_id → messaging_group → platform_id`. If the session is not wired to an `ios-app` channel, the adapter writes a synthetic `inbound.db` row of `meta = { kind: 'context_response', request_id, errors: { 'scope': 'no ios-app device wired' } }`. The agent's tool handler resolves the promise as a rejection.
- The agent writes `expires_at_ms` into the `messages_out` payload alongside `request_id`, computed as `now + timeout_ms`. The adapter reads it and stores `expires_at = expires_at_ms` in `pending_context_requests`. If the field is missing, the adapter defaults to `now + 10s`.
- The adapter sends the `context_request` envelope to the live socket (or queues if offline) and waits.
- A 1-second sweep removes expired `pending_context_requests` rows. Expired rows trigger a synthetic `inbound.db` row with `meta = { kind: 'context_response', request_id, errors: { 'timeout': 'device offline / timeout' }, data: {} }`. The agent-side tool resolves it as a rejection. The agent-side timer also fires at `timeout_ms`; if the agent rejects first, a late `context_response` is discarded silently when `pending.get(request_id)` returns undefined.

### Code Removed from the Adapter

- `buildCtx()` (context-block formatting) — moved to the agent.
- `pendingMessages` (in-memory map) — replaced by `outbound_queue`.
- `processedClientMsgIds` (in-memory LRU) — replaced by `inbound_dedup`.
- `deliveredIds` (in-memory LRU) — no longer needed; cursor replay is exact.
- APNs (`sendApnsPush`, JWT rotation, http2 client) — fully removed.
- `apns_token` envelope handler — removed.
- `ios-read-receipts.ts` (server-side store) — the receipts live in the iOS local store now.

## iOS App Internals

### Local Store

A new `ConversationStore` over SQLite via GRDB. Replaces `MessageCache` and `OutboxStore`.

```sql
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  title TEXT,
  created_at INTEGER NOT NULL,
  last_message_at INTEGER NOT NULL,
  archived INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  dir TEXT NOT NULL CHECK (dir IN ('out','in')),
  seq INTEGER,
  text TEXT NOT NULL,
  attachments_json TEXT,
  context_json TEXT,                       -- only for dir='out'
  status TEXT NOT NULL CHECK (status IN ('composing','queued','sending','sent','delivered','read','failed')),
  failure_reason TEXT,
  ts INTEGER NOT NULL,
  server_ts INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_msg_conv_ts ON messages (conversation_id, ts);
CREATE INDEX idx_msg_status ON messages (status) WHERE status IN ('queued','sending');

CREATE TABLE attachments (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES messages(id),
  kind TEXT NOT NULL CHECK (kind IN ('image','file')),
  name TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  local_path TEXT,
  remote_id TEXT
);

CREATE TABLE cursors (
  k TEXT PRIMARY KEY,
  v INTEGER NOT NULL
);

CREATE TABLE inbound_dedup (
  id TEXT PRIMARY KEY,
  seq INTEGER NOT NULL,
  received_at INTEGER NOT NULL
);
```

### Status State Machine

Outbound (user-sent) messages — terminal at `sent`. There is no UI surface on the agent side, so there are no `delivered` / `read` checkmark levels for user→agent messages:

```
composing       (UI-only, not persisted)
   ↓ user taps send
queued          (insert: status=queued, seq=NULL)
   ↓ dispatcher picks up
sending         (allocate seq, update status, send envelope)
   ↓ ack received from adapter
sent            (update status=sent, server_ts=envelope.ts) — single checkmark, terminal

failed:         terminal. Reason in failure_reason. UI exposes a retry that resets to queued.
```

Inbound (agent-sent) messages — `delivered` and `read` exist here, since the iOS app is the rendering surface:

```
received        (insert into messages after dedup)
   ↓ persistence commits
delivered       (app emits status:delivered to adapter, marks two checkmarks)
   ↓ rendered in open chat view
read            (app emits status:read to adapter, marks bold two checkmarks)
```

Status envelopes from the app are recorded in the adapter's `ReadReceiptStore` for bookkeeping. They are not propagated to the agent.

### Transport (`Transport.swift`)

Replaces the current `WSTransport`, `WebSocketClient`, `InboundRouter`, `OutboxStore`, `MessageCache` stack.

```
Transport
├── socket: URLSessionWebSocketTask
├── store: ConversationStore
├── outboundDispatcher: 200 ms timer scanning queued messages
├── ackTimers: [UUID: Timer]  — 5 s retry per sent-but-not-acked envelope
├── seqAllocator: monotonic, persisted in cursors
├── inboundRouter: parse, dedup, dispatch
└── connection: ConnectionState (.idle, .connecting, .authed, .reconnecting(delay))
```

Send flow:
1. UI calls `send(text, attachments, context)`.
2. `store.insert(message dir=out status=queued seq=NULL ts=now)`.
3. The dispatcher picks up queued messages (LIMIT 10). For each:
   - Allocate `seq = cursors[last_sent_outbound_seq] + 1`. Update cursor.
   - Update the message: `status = sending, seq = ...`.
   - Build the envelope and `socket.send(JSON)`.
   - Start a 5 s ack timer.
4. On `ack:ack { id }`: cancel the timer, update the message to `status = sent, server_ts = envelope.ts`.
5. On timer fire without ack: re-send with the same `id` and `seq`. After three retries, force reconnect.

Auth/reconnect flow:
1. On socket open, read `seq = cursors[last_sent_outbound_seq]` and `lsi = cursors[last_seen_inbound_seq]`.
2. Send `control:auth { token, last_seen_inbound_seq: lsi, capabilities: [...] }`.
3. On `auth_ok { last_seen_outbound_seq: serverAcked }`:
   - Messages with `dir='out' AND status='sending' AND seq <= serverAcked` are marked `sent`.
   - Messages with `dir='out' AND status='sending' AND seq > serverAcked` are reset to `queued` for re-send.
4. Inbound envelopes arrive ordered by seq. The app dedups via `inbound_dedup` and updates `cursors[last_seen_inbound_seq] = envelope.seq` after persistence.

### Handling `context_request`

- `InboundRouter` sees `control:context_request { request_id, fields, params }`.
- Field handlers run in parallel: `LocationManager`, `HealthManager`, `CalendarManager`, `DeviceManager`, `ScreenStateManager`.
- The app assembles `{ data: {...}, errors?: {...} }` and sends `control:context_response { request_id, data, errors }` through the standard ack-tracked envelope path.

### iOS Code Removed

- `OutboxStore.swift`, `MessageCache.swift`, `WebSocketClient.swift` (old), `InboundRouter.swift` (old), `WSTransport.swift` — replaced by the new `Transport` + `ConversationStore`.
- `oneShotQueue` — all control envelopes now go through the same ack-tracked path.
- `gatherContext` rich-context aggregation — kept, but only emits the `InlineContext` shape.
- Video attachment support: `DraftAttachmentVideoTests.swift`, `video` case of `DraftAttachment.Kind`, `VideoError`, `maxVideoBytes`, `checkVideoSize`, both `video(...)` factories, `public.movie` in `CameraPicker`, `videoMaximumDuration`, `videoQuality`, `.videos` PhotosPicker matcher, `VideoTransferable`, `surfaceVideoError`, the `play.rectangle` icon branch in `MessageRow.swift`.
- APNs: `registerApnsToken`, AppDelegate push handlers.

## Agent Internals

### Inbound Formatting

`container/agent-runner/src/channels/ios-app-format.ts` renders the prefix on read from `messages_in`:

```
[iOS context — 2026-05-31T12:00:00Z Europe/Moscow, near "Patriarch's Ponds"
 loc=55.7619,37.5957 ±25m]
<user text>
```

Rules:
- Drop the `near "<locality>"` segment when `locality` is missing.
- Drop the `±<accuracy>m` segment when `accuracy` is missing.
- Drop the `loc=...` line entirely when `location` is missing.
- When `meta.ios_context` is missing entirely, emit no prefix.

### `request_context` MCP Tool

File: `container/agent-runner/src/mcp-tools/request_context.ts`. Replaces the current handler in `core.ts:289`.

```ts
import { ContextFieldEnum, type ContextField } from '@shared/ios-app-protocol/v2';
import { z } from 'zod';

const InputSchema = z.object({
  fields: z.array(ContextFieldEnum).min(1),
  params: z.object({
    health_days: z.number().int().min(1).max(30).optional(),
    calendar_window: z.enum(['today','next_7d','next_30d']).optional(),
    locations_hours: z.number().int().min(1).max(168).optional(),
  }).optional(),
  timeout_ms: z.number().int().min(1000).max(30000).optional(),  // default 10000
});

const pending = new Map<string, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();

export const requestContextTool = {
  name: 'request_context',
  description: 'Pull device context (location, health, calendar, etc.) from the user iOS device. Async — blocks until device replies or timeout.',
  inputSchema: InputSchema,
  handler: async (input, ctx) => {
    const request_id = crypto.randomUUID();
    const timeout_ms = input.timeout_ms ?? 10000;
    const expires_at_ms = Date.now() + timeout_ms;
    await writeMessageOut(ctx.session_id, {
      type: 'context_request',
      payload: { request_id, fields: input.fields, params: input.params ?? {}, expires_at_ms },
    });
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(request_id);
        reject(new Error('[device offline / timeout]'));
      }, timeout_ms);
      pending.set(request_id, { resolve, reject, timer });
    });
  },
};

export function onContextResponse(envelope: { request_id: string; data: Record<string, unknown>; errors?: Record<string, string> }) {
  const entry = pending.get(envelope.request_id);
  if (!entry) return;
  clearTimeout(entry.timer);
  pending.delete(envelope.request_id);
  if (envelope.errors && Object.keys(envelope.errors).length > 0 && Object.keys(envelope.data ?? {}).length === 0) {
    entry.reject(new Error(`[context error: ${JSON.stringify(envelope.errors)}]`));
  } else {
    entry.resolve({ data: envelope.data, errors: envelope.errors ?? {} });
  }
}
```

### Agent Poll-Loop Dispatch

When a `messages_in` row arrives with `meta.kind === 'context_response'`, the agent calls `onContextResponse(meta)`. The row is not added to the conversation history — it is a tool response, not a user turn.

Regular `data:message` rows go through `ios-app-format.ts` and are added to history.

### Session DB Payload Additions

`messages_in.meta` discriminator:

```ts
type IosMessageMeta =
  | { kind: 'user_message'; ios_context?: InlineContext; attachments?: Attachment[] }
  | { kind: 'context_response'; request_id: string; data: Record<string, unknown>; errors?: Record<string, string> }
  | { kind: 'system'; subtype: 'feedback' | 'action_response'; /* ... */ };
```

`messages_out.payload` adds:

```ts
{ type: 'context_request', payload: { request_id: string; fields: ContextField[]; params?: Record<string, unknown>; expires_at_ms: number } }
```

### Code Removed from the Agent

- The old `request_context` handler in `container/agent-runner/src/mcp-tools/core.ts` (the synchronous one that returned `"awaiting follow-up"`).
- The pattern of reading rich context out of inline `messages_in.text` — that context no longer arrives inline.

## Migration

Big-bang. Single PR. No feature flags.

Commit order:
1. `shared/ios-app-protocol/v2.ts`, fixtures, and the contract test for TypeScript. Adds the tsconfig path alias.
2. Adapter v2: new directory `src/channels/ios-app/v2/` with `transport-db.ts`, `ws-handler.ts`, `outbound-queue.ts`, `context-bridge.ts`, `index.ts`.
3. Adapter cleanup: delete the old `src/channels/ios-app.ts`, `src/channels/ios-read-receipts.ts`, and the APNs module. Re-register the channel via `src/channels/index.ts`.
4. Agent-runner: new `ios-app-format.ts` and `mcp-tools/request_context.ts`. Wire `onContextResponse` into the poll loop dispatch. Update `container/build.sh` to copy `shared/` into the image.
5. iOS new code: `Protocol/V2.swift`, `Storage/ConversationStore.swift`, `Services/Transport.swift`, `Services/Status.swift`. Add GRDB to `Package.swift`.
6. iOS cleanup: delete `OutboxStore.swift`, `MessageCache.swift`, the old `WebSocketClient.swift`, `InboundRouter.swift`, `WSTransport.swift`, the video stack, the APNs registration.
7. One-shot data migration on first v2 launch on the device. If `Documents/MessageCache/` or `Documents/Outbox/queue.json` exists, read it, convert to `messages` rows (status `sent` for outbound history; status `new` for inbound history), delete the JSON files on success.

Server-side first run: `data/ios-app/transport.db` is created empty. `inbound_dedup` starts empty, so one duplicate per device is possible if the app retries un-acked sends from the old outbox with new protocol envelopes. Acceptable.

Deploy procedure on the VDS:
- `git pull` on the VDS.
- `pnpm install && pnpm run build`.
- Ship the v2 iOS build through TestFlight before restarting the service. The old service still accepts the v1 protocol.
- `launchctl kickstart -k gui/$(id -u)/com.nanoclaw` locally, or `systemctl --user restart nanoclaw` on the VDS.
- New sessions immediately use v2.

Rollback: `git revert <merge sha>` on the server; downgrade iOS through TestFlight to the previous build.

Out of scope: other channels; session DB schema; central DB schema; agent groups; MCP tools other than `request_context`; OneCLI; container runtime.

## Tests

### Layer 1 — Unit Tests

| File                                                                         | What                                                                                                                                |
|------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| `shared/ios-app-protocol/v2.test.ts`                                         | Every envelope type: valid parse; reject on missing required field; reject on unknown extras (strict); discriminated union dispatch. |
| `src/channels/ios-app/v2/transport-db.test.ts`                               | Schema migration up/down; `outbound_queue` insert/delete is idempotent; overflow drops oldest; `inbound_dedup` prune.                |
| `src/channels/ios-app/v2/outbound-queue.test.ts`                             | Enqueue → drain → ack → row deleted. Retry timer fires on missing ack. Overflow >1000 drops oldest.                                  |
| `src/channels/ios-app/v2/ws-handler.test.ts`                                 | Auth → auth_ok with correct seq. Inbound dedup by id. Cursor replay on reconnect. Superseded socket close. Protocol violation close. |
| `src/channels/ios-app/v2/ws-handler.ping.test.ts`                            | `control:ping` returns `control:pong { nonce }`. No `messages_in` row. No `outbound_queue` row. No `last_seen_outbound_seq` change. |
| `src/channels/ios-app/v2/context-bridge.test.ts`                             | `messages_out:context_request` serializes correctly. TTL sweep removes expired. Per-session scope rejects cross-session.            |
| `container/agent-runner/src/channels/ios-app-format.test.ts`                 | Full `InlineContext` → expected prefix. Missing `locality` shortens prefix. Missing context → no prefix.                            |
| `container/agent-runner/src/mcp-tools/request_context.test.ts`               | Tool call writes `messages_out`. `onContextResponse` resolves the promise. Timeout rejects with `[device offline / timeout]`. Map cleanup. |
| `ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreTests.swift`          | Schema migration. Message insert/update/query by status. Cursor read/write atomically.                                              |
| `ios/JarvisApp/Sources/JarvisAppTests/TransportTests.swift`                  | State machine transitions. Failure terminal state. Retry on missing ack. Reconnect resets `sending` → `queued`.                     |
| `ios/JarvisApp/Sources/JarvisAppTests/InboundDispatchTests.swift`            | `context_request` → field gathering → `context_response`. Dedup by id. Cursor update.                                               |
| `ios/JarvisApp/Sources/JarvisAppTests/MigrationTests.swift`                  | One-shot migration from `OutboxStore.queue.json` and `MessageCache/index.json` into SQLite.                                         |

### Layer 2 — Contract Tests (shared fixtures)

`shared/ios-app-protocol/fixtures/`:

```
auth.json
auth_ok.json
message_with_context.json
message_no_context.json
message_with_attachments.json
context_request_health_calendar.json
context_response_full.json
context_response_partial_errors.json
ack.json
status_delivered_batch.json
status_read_batch.json
new_conversation.json
action_response.json
feedback.json
ping.json
pong.json
```

| Test                                                                  | Layer        | What                                                                                                  |
|-----------------------------------------------------------------------|--------------|-------------------------------------------------------------------------------------------------------|
| `shared/ios-app-protocol/fixtures.test.ts`                            | TS (vitest)  | Every fixture round-trips: `AnyEnvelope.parse(json)` succeeds and re-serializes to a byte-equal form. |
| `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`     | Swift        | Every fixture decodes through `JSONDecoder`, re-encodes, and semantically matches.                    |

A shape change forces both sides to update or both sides go red.

### Layer 3 — Integration Test (Node-only)

`src/channels/ios-app/v2/integration.test.ts` — spins up the real `WSServer` and the adapter with an in-memory SQLite (`:memory:`). The mock iOS client is a `ws`-package wrapper that imports the same Zod schemas. The mock agent writes to `outbound.db` and reads `inbound.db`.

Scenarios:
1. Happy path: connect → auth → send message → ack → delivered → agent reply → inbound at the client.
2. Reconnect mid-send: client sent seq=5 without ack → disconnect → reconnect with `last_seen_inbound_seq=4` → `auth_ok` with `last_seen_outbound=4` → client retransmits seq=5 → ack.
3. Reconnect mid-receive: server enqueued seqs 10, 11, 12 → client offline → reconnect with `last_seen_inbound_seq=9` → server flushes 10, 11, 12 in order.
4. Dedup: client sends `id=X` twice → server acks twice, agent sees once.
5. Queue overflow: agent sends 1500 messages while client offline → reconnect → client receives 1000 youngest, oldest 500 dropped silently.
6. Context request happy path: agent calls `request_context(['device'])` → envelope to client → response with data → tool resolves.
7. Context request timeout: client never responds → 10 s → tool rejects with `[device offline / timeout]` → `pending_context_requests` row deleted.
8. Per-session scope reject: agent in a non-`ios-app` session calls `request_context` → tool rejects with `[no ios-app device wired]`, no WS write.
9. Protocol violation: client sends `{ v: 1, ... }` → server closes with `protocol_violation`.
10. Superseded socket: client A connects, then client B with the same `platform_id` → A receives close `superseded`.
11. Ping isolation: 50 ping/pong rounds with a parallel agent poll → the agent observes zero raw envelopes from the ping traffic.

### Layer 4 — E2E iOS Simulator

`ios/JarvisApp/Sources/JarvisAppTests/E2E/` — UI tests via XcodeBuildMCP `test_sim`. Harness is a local Node script speaking the same protocol against the simulator over `ws://localhost:<port>`. Test target reads the harness address from an env var.

1. Cold start + send: launch, type "hi", tap send. See user-message status reach `sent` (single checkmark, terminal). Harness sends an inbound reply. See the inbound reply status reach `delivered` on persistence, then `read` after the test taps into the chat view to render it.
2. Offline send queues: enable airplane mode via CoreSimulator network toggle. Type three messages. See `queued`. Disable airplane mode. All three pass through `sending → sent`.
3. Inbound with `context_request`: harness sends `context_request[device]`. The app does not show this in the UI (technical). The reply goes back automatically. Harness receives.
4. Reconnect resilience: kill the WS connection mid-conversation. The app shows a "reconnecting" banner. After reconnect, pending messages arrive in order.
5. App restart preserves state: write a message into `queued`, kill the app, relaunch. The message is still `queued` and is sent.

### Layer 5 — Smoke

Removed. Manual build verification covers it.

### CI Wiring (`.github/workflows/`)

- `pnpm test` for host (vitest) and shared fixtures.
- `cd container/agent-runner && bun test` for the agent.
- iOS unit tests on a macOS runner: `xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'`.
- iOS E2E runs locally only (too slow for CI). Manual run before merge.

### Invariants Tests Must Cover Explicitly

1. No dedup path lets a duplicate `id` through.
2. No acked outbound entry lingers in `outbound_queue`.
3. No un-acked outbound entry is lost across reconnect.
4. Cursors are monotonic per direction.
5. `context_request` with TTL is never orphaned beyond `expires_at`.
6. Per-session scope rejects cross-session requests.
7. Ping/pong traffic does not surface to the agent layer.

## Open Questions / Followups

- Property-based testing on the adapter (fast-check) is a candidate for a follow-up PR.
- Future APNs reintroduction: when push wakeups come back, the path is `outbound_queue` insert → if no live socket → emit silent push. This design's `outbound_queue` is push-ready; the change is purely additive.
- GRDB depend on iOS adds a SwiftPM dependency. If the user prefers no third-party SQLite wrapper, the alternative is a thin hand-written wrapper over `sqlite3.framework`. Decision deferred to the implementation plan.
