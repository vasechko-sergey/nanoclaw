# iOS App Protocol v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the v2 ios-app channel: three clean layers (iOS app / adapter / agent), versioned wire protocol in a shared module, durable cursor-based transport with deduplicated at-least-once delivery, and a full test matrix.

**Architecture:** A single canonical `shared/ios-app-protocol/v2.ts` (Zod schemas + types) is imported by both the host adapter (Node) and the agent-runner (Bun). The Swift mirror is hand-maintained but pinned via shared JSON fixtures. The adapter persists outbound queue and inbound dedup in `data/ios-app/transport.db` (better-sqlite3). The iOS app persists conversations/messages in SQLite via GRDB. Cursor seqs enable exact replay on reconnect.

**Tech Stack:** TypeScript (Node host, Bun container), Zod, better-sqlite3, `ws`, vitest, bun:test, Swift, SwiftUI, GRDB, XCTest, XcodeBuildMCP for E2E.

**Reference:** Full design in `docs/superpowers/specs/2026-05-31-ios-app-protocol-v2-design.md`. Read it before starting.

---

## File Structure

### New files

```
shared/ios-app-protocol/
  v2.ts                                   — Zod schemas + discriminated union + types
  index.ts                                — re-exports
  fixtures/
    auth.json                             — sample envelopes for contract tests
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
  v2.test.ts                              — TS schema unit tests
  fixtures.test.ts                        — round-trip parse of every fixture

src/channels/ios-app/v2/
  index.ts                                — registerChannelAdapter('ios-app', ...)
  transport-db.ts                         — SQLite schema + CRUD
  outbound-queue.ts                       — enqueue/drain/ack/retry/overflow
  ws-handler.ts                           — handshake + dispatch + ping
  context-bridge.ts                       — messages_out → envelope, TTL sweep
  inbound-dispatch.ts                     — routes parsed envelopes
  receipt-store.ts                        — local ReadReceiptStore
  types.ts                                — internal shared types
  transport-db.test.ts
  outbound-queue.test.ts
  ws-handler.test.ts
  ws-handler.ping.test.ts
  context-bridge.test.ts
  inbound-dispatch.test.ts
  integration.test.ts                     — Node-only end-to-end

container/agent-runner/src/channels/
  ios-app-format.ts                       — render InlineContext prefix
  ios-app-format.test.ts

container/agent-runner/src/mcp-tools/
  request_context.ts                      — async deferred MCP tool
  request_context.test.ts

ios/JarvisApp/Sources/JarvisApp/Protocol/
  V2.swift                                — Codable mirror of canonical schemas

ios/JarvisApp/Sources/JarvisApp/Storage/
  ConversationStore.swift                 — GRDB-backed local store
  Schema.swift                            — migrations

ios/JarvisApp/Sources/JarvisApp/Services/
  Transport.swift                         — replaces WSTransport+WebSocketClient
  InboundDispatcher.swift                 — replaces InboundRouter
  Status.swift                            — state machine helpers
  MigrationV2.swift                       — one-shot import from old JSON stores

ios/JarvisApp/Sources/JarvisAppTests/
  ProtocolFixtureTests.swift
  ConversationStoreTests.swift
  TransportTests.swift
  InboundDispatchTests.swift
  MigrationTests.swift
  E2E/E2EHarness.swift                    — local Node-driven harness for sim
  E2E/CheckmarksE2ETests.swift
  E2E/OfflineQueueE2ETests.swift
  E2E/ContextRequestE2ETests.swift
  E2E/ReconnectE2ETests.swift
  E2E/RestartE2ETests.swift

scripts/
  e2e-harness.ts                          — Node harness for iOS sim E2E
```

### Modified files

```
tsconfig.json                             — add path alias @shared/*
tsconfig.base.json                        — same in monorepo base (if present)
container/agent-runner/tsconfig.json      — add path alias
container/agent-runner/src/poll-loop.ts   — dispatch context_response, route ios-app meta.kind
container/build.sh                        — COPY shared/ into image
src/channels/index.ts                     — switch to ios-app/v2
ios/JarvisApp/Package.swift               — add GRDB dependency
```

### Deleted files

```
src/channels/ios-app.ts
src/channels/ios-app.context.test.ts
src/channels/ios-app.dedup.test.ts
src/channels/ios-app.message-ack.test.ts
src/channels/ios-app.proactive.test.ts
src/channels/ios-app.video-attachment.test.ts
src/channels/ios-app.ws.test.ts
src/channels/ios-read-receipts.ts
src/channels/ios-read-receipts.test.ts
ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift
ios/JarvisApp/Sources/JarvisApp/Services/WSTransport.swift
ios/JarvisApp/Sources/JarvisApp/Services/InboundRouter.swift
ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift
ios/JarvisApp/Sources/JarvisApp/Services/MessageCache.swift
ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift
ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientBusyTests.swift
ios/JarvisApp/Sources/JarvisAppTests/DeliveryChecksTests.swift
ios/JarvisApp/Sources/JarvisAppTests/DraftAttachmentVideoTests.swift
```

---

## Phases

The plan is split into seven phases that match the migration commit order in the spec. Each phase ends with a green test suite for its own scope and a commit.

- Phase 1 — Shared protocol module + fixtures + contract tests (TS side)
- Phase 2 — Adapter v2 implementation + unit tests
- Phase 3 — Agent-runner changes (format helper + request_context tool)
- Phase 4 — iOS Protocol mirror + ConversationStore + Transport
- Phase 5 — iOS cleanup (remove old services, video, APNs)
- Phase 6 — Integration tests (Node-only) + E2E (iOS Simulator)
- Phase 7 — Switch over (`src/channels/index.ts`) + deploy verification

---

## Phase 1 — Shared protocol module

### Task 1.1: Scaffold `shared/ios-app-protocol/` + add tsconfig path alias

**Files:**
- Create: `shared/ios-app-protocol/v2.ts` (stub)
- Create: `shared/ios-app-protocol/index.ts`
- Modify: `tsconfig.json` (add `paths`)
- Modify: `container/agent-runner/tsconfig.json` (add `paths`)

- [ ] **Step 1: Create empty stub for v2.ts**

`shared/ios-app-protocol/v2.ts`:
```ts
// Canonical iOS-app wire protocol v2.
// Both host adapter (Node) and agent-runner (Bun) import from here.
// Swift mirror lives in ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift
// and is pinned via shared/ios-app-protocol/fixtures/*.json contract tests.
export const PROTOCOL_VERSION = 2 as const;
```

`shared/ios-app-protocol/index.ts`:
```ts
export * from './v2.js';
```

- [ ] **Step 2: Add path alias `@shared/*` to root `tsconfig.json`**

Add under `compilerOptions`:
```json
"baseUrl": ".",
"paths": {
  "@shared/*": ["shared/*"]
}
```

- [ ] **Step 3: Mirror alias in `container/agent-runner/tsconfig.json`**

Add under `compilerOptions` (path is relative to that tsconfig dir):
```json
"baseUrl": ".",
"paths": {
  "@shared/*": ["../../shared/*"]
}
```

- [ ] **Step 4: Verify both projects compile**

Run from repo root:
```bash
pnpm exec tsc --noEmit
pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit
```
Expected: no errors (only adding alias, no usage yet).

- [ ] **Step 5: Commit**

```bash
git add tsconfig.json container/agent-runner/tsconfig.json shared/ios-app-protocol/
git commit -m "shared/ios-app-protocol: scaffold canonical wire protocol module"
```

---

### Task 1.2: Define core types (Envelope base, InlineContext, ContextField)

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`

- [ ] **Step 1: Add Zod to host package**

```bash
pnpm add zod@^3.23.0
```

- [ ] **Step 2: Add Zod to agent-runner**

```bash
cd container/agent-runner && bun add zod@3.23.0
```

- [ ] **Step 3: Write failing schema test for base envelope**

Create `shared/ios-app-protocol/v2.test.ts`:
```ts
import { describe, it, expect } from 'vitest';
import { EnvelopeBase, InlineContext, ContextFieldEnum } from './v2';

describe('EnvelopeBase', () => {
  const ok = {
    v: 2 as const, kind: 'data', type: 'message',
    id: '550e8400-e29b-41d4-a716-446655440000',
    seq: 1, ts: '2026-05-31T12:00:00.000Z',
  };

  it('accepts a minimal valid envelope', () => {
    expect(() => EnvelopeBase.parse(ok)).not.toThrow();
  });

  it('allows seq=null for stateless envelopes', () => {
    expect(() => EnvelopeBase.parse({ ...ok, seq: null })).not.toThrow();
  });

  it('rejects v != 2', () => {
    expect(() => EnvelopeBase.parse({ ...ok, v: 1 })).toThrow();
  });

  it('rejects negative seq', () => {
    expect(() => EnvelopeBase.parse({ ...ok, seq: -1 })).toThrow();
  });

  it('rejects non-uuid id', () => {
    expect(() => EnvelopeBase.parse({ ...ok, id: 'nope' })).toThrow();
  });
});

describe('InlineContext', () => {
  it('accepts a fully populated context', () => {
    expect(() => InlineContext.parse({
      location: { lat: 55.7, lon: 37.6, accuracy: 25 },
      timestamp: '2026-05-31T12:00:00.000Z',
      timezone: 'Europe/Moscow',
      locality: "Patriarch's Ponds",
    })).not.toThrow();
  });

  it('requires timestamp + timezone', () => {
    expect(() => InlineContext.parse({ timezone: 'UTC' })).toThrow();
    expect(() => InlineContext.parse({ timestamp: '2026-05-31T12:00:00.000Z' })).toThrow();
  });
});

describe('ContextFieldEnum', () => {
  it('lists exactly the v1 catalog', () => {
    const ALL = ['health','calendar','device','next_event','recent_locations','screen_state'];
    for (const f of ALL) expect(ContextFieldEnum.parse(f)).toBe(f);
    expect(() => ContextFieldEnum.parse('read_receipts')).toThrow();
    expect(() => ContextFieldEnum.parse('dialog_summary')).toThrow();
  });
});
```

Run:
```bash
pnpm exec vitest run shared/ios-app-protocol/v2.test.ts
```
Expected: FAIL — `EnvelopeBase` / `InlineContext` / `ContextFieldEnum` are not exported yet.

- [ ] **Step 4: Implement schemas**

In `shared/ios-app-protocol/v2.ts`:
```ts
import { z } from 'zod';

export const PROTOCOL_VERSION = 2 as const;

export const EnvelopeBase = z.object({
  v: z.literal(2),
  kind: z.enum(['data', 'control', 'ack', 'status']),
  type: z.string(),
  id: z.string().uuid(),
  // Nullable: ack, ping, pong, status:* envelopes carry seq=null and do not
  // advance the per-direction cursor. Ordered types (message, context_request,
  // context_response, new_conversation, action_response, feedback) require an
  // integer >= 0.
  seq: z.number().int().nonnegative().nullable(),
  ts: z.string().datetime(),
});
export type EnvelopeBase = z.infer<typeof EnvelopeBase>;

export const InlineContext = z.object({
  location: z.object({
    lat: z.number(),
    lon: z.number(),
    accuracy: z.number().optional(),
  }).optional(),
  timestamp: z.string().datetime(),
  timezone: z.string(),
  locality: z.string().optional(),
});
export type InlineContext = z.infer<typeof InlineContext>;

export const ContextFieldEnum = z.enum([
  'health', 'calendar', 'device', 'next_event', 'recent_locations', 'screen_state',
]);
export type ContextField = z.infer<typeof ContextFieldEnum>;
```

- [ ] **Step 5: Run test, expect PASS**

```bash
pnpm exec vitest run shared/ios-app-protocol/v2.test.ts
```

- [ ] **Step 6: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts package.json pnpm-lock.yaml container/agent-runner/package.json container/agent-runner/bun.lock
git commit -m "shared/ios-app-protocol: add EnvelopeBase, InlineContext, ContextFieldEnum"
```

---

### Task 1.3: Add data + control envelope types (Auth, Message, ContextRequest, ContextResponse, NewConversation, ActionResponse, Feedback)

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`
- Modify: `shared/ios-app-protocol/v2.test.ts`

- [ ] **Step 1: Append failing tests for each envelope type**

Append to `v2.test.ts`:
```ts
import { Envelopes, AnyEnvelope } from './v2';

const baseFor = (over: Record<string, unknown>) => ({
  v: 2 as const,
  kind: 'data',
  type: 'message',
  id: '550e8400-e29b-41d4-a716-446655440000',
  seq: 1,
  ts: '2026-05-31T12:00:00.000Z',
  ...over,
});

describe('Envelopes.Message', () => {
  it('accepts minimal message', () => {
    expect(() => Envelopes.Message.parse(baseFor({
      payload: { thread_id: 't1', text: 'hi' },
    }))).not.toThrow();
  });
  it('accepts message with inline context', () => {
    expect(() => Envelopes.Message.parse(baseFor({
      payload: {
        thread_id: 't1', text: 'hi',
        context: { timestamp: '2026-05-31T12:00:00.000Z', timezone: 'UTC' },
      },
    }))).not.toThrow();
  });
  it('rejects missing thread_id', () => {
    expect(() => Envelopes.Message.parse(baseFor({ payload: { text: 'hi' } }))).toThrow();
  });
});

describe('Envelopes.Auth', () => {
  it('accepts valid auth', () => {
    expect(() => Envelopes.Auth.parse(baseFor({
      kind: 'control', type: 'auth',
      payload: { token: 'abc', last_seen_inbound_seq: 0, capabilities: [] },
    }))).not.toThrow();
  });
});

describe('Envelopes.ContextRequest', () => {
  it('accepts request_id + non-empty fields', () => {
    expect(() => Envelopes.ContextRequest.parse(baseFor({
      kind: 'control', type: 'context_request',
      payload: {
        request_id: '550e8400-e29b-41d4-a716-446655440000',
        fields: ['device', 'next_event'],
      },
    }))).not.toThrow();
  });
  it('rejects empty fields', () => {
    expect(() => Envelopes.ContextRequest.parse(baseFor({
      kind: 'control', type: 'context_request',
      payload: {
        request_id: '550e8400-e29b-41d4-a716-446655440000',
        fields: [],
      },
    }))).toThrow();
  });
});

describe('AnyEnvelope discriminated union', () => {
  it('dispatches by type', () => {
    const env = baseFor({
      kind: 'control', type: 'auth',
      payload: { token: 'x', last_seen_inbound_seq: 0, capabilities: [] },
    });
    const parsed = AnyEnvelope.parse(env);
    expect(parsed.type).toBe('auth');
  });
});
```

Run, expect FAIL — `Envelopes` / `AnyEnvelope` undefined.

- [ ] **Step 2: Implement the envelope catalog**

Append to `v2.ts`:
```ts
export const Envelopes = {
  Auth: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth'),
    payload: z.object({
      token: z.string(),
      last_seen_inbound_seq: z.number().int().nonnegative(),
      capabilities: z.array(z.string()),
    }),
  }),
  AuthOk: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth_ok'),
    payload: z.object({
      last_seen_outbound_seq: z.number().int().nonnegative(),
      server_time: z.string().datetime(),
    }),
  }),
  AuthFail: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('auth_fail'),
    payload: z.object({ reason: z.string() }),
  }),
  Message: EnvelopeBase.extend({
    kind: z.literal('data'),
    type: z.literal('message'),
    payload: z.object({
      thread_id: z.string().min(1),
      text: z.string(),
      attachments: z.array(z.object({
        id: z.string().uuid(),
        kind: z.enum(['image', 'file']),
        name: z.string(),
        mime_type: z.string(),
        byte_size: z.number().int().nonnegative(),
        bytes_base64: z.string().optional(),
        remote_id: z.string().optional(),
      })).optional(),
      context: InlineContext.optional(),
    }),
  }),
  ContextRequest: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('context_request'),
    payload: z.object({
      request_id: z.string().uuid(),
      fields: z.array(ContextFieldEnum).min(1),
      params: z.record(z.unknown()).optional(),
    }),
  }),
  ContextResponse: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('context_response'),
    payload: z.object({
      request_id: z.string().uuid(),
      data: z.record(z.unknown()),
      errors: z.record(z.string()).optional(),
    }),
  }),
  NewConversation: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('new_conversation'),
    payload: z.object({ thread_id: z.string().min(1) }),
  }),
  ActionResponse: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('action_response'),
    payload: z.object({ action_id: z.string(), choice: z.string() }),
  }),
  Feedback: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('feedback'),
    payload: z.object({
      message_id: z.string().uuid(),
      kind: z.enum(['up', 'down']),
    }),
  }),
} as const;
```

(`AnyEnvelope` discriminated union added in Task 1.5 after ack/ping/pong/status are defined.)

- [ ] **Step 3: Temporary partial AnyEnvelope so Task 1.3 tests can pass**

Append to `v2.ts`:
```ts
// Provisional union — extended in Task 1.5 with ack/ping/pong/status types.
export const AnyEnvelope = z.discriminatedUnion('type', [
  Envelopes.Auth, Envelopes.AuthOk, Envelopes.AuthFail,
  Envelopes.Message, Envelopes.ContextRequest, Envelopes.ContextResponse,
  Envelopes.NewConversation, Envelopes.ActionResponse, Envelopes.Feedback,
]);
export type AnyEnvelope = z.infer<typeof AnyEnvelope>;
```

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm exec vitest run shared/ios-app-protocol/v2.test.ts
```

- [ ] **Step 5: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts
git commit -m "shared/ios-app-protocol: data + control envelope catalog"
```

---

### Task 1.4: Add Ack, Ping, Pong, Status envelopes

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`
- Modify: `shared/ios-app-protocol/v2.test.ts`

- [ ] **Step 1: Append failing tests**

Append to `v2.test.ts`:
```ts
describe('Stateless envelopes (ack/ping/pong/status)', () => {
  it('Ack accepts seq=null', () => {
    expect(() => Envelopes.Ack.parse(baseFor({
      kind: 'ack', type: 'ack', seq: null,
      payload: { id: '550e8400-e29b-41d4-a716-446655440000', seq: 5 },
    }))).not.toThrow();
  });

  it('Ping accepts non-empty nonce', () => {
    expect(() => Envelopes.Ping.parse(baseFor({
      kind: 'control', type: 'ping', seq: null,
      payload: { nonce: 'abc' },
    }))).not.toThrow();
  });

  it('Pong mirrors ping', () => {
    expect(() => Envelopes.Pong.parse(baseFor({
      kind: 'control', type: 'pong', seq: null,
      payload: { nonce: 'abc' },
    }))).not.toThrow();
  });

  it('Status delivered/read accept batches of ids', () => {
    expect(() => Envelopes.StatusDelivered.parse(baseFor({
      kind: 'status', type: 'delivered', seq: null,
      payload: { ids: ['550e8400-e29b-41d4-a716-446655440000'] },
    }))).not.toThrow();
    expect(() => Envelopes.StatusRead.parse(baseFor({
      kind: 'status', type: 'read', seq: null,
      payload: { ids: ['550e8400-e29b-41d4-a716-446655440000'] },
    }))).not.toThrow();
  });
});
```

Run, expect FAIL.

- [ ] **Step 2: Implement the four stateless envelopes**

Append to `v2.ts` inside the `Envelopes` object literal:
```ts
  Ack: EnvelopeBase.extend({
    kind: z.literal('ack'),
    type: z.literal('ack'),
    seq: z.null(),
    payload: z.object({
      id: z.string().uuid(),
      seq: z.number().int().nonnegative(),
    }),
  }),
  Ping: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('ping'),
    seq: z.null(),
    payload: z.object({ nonce: z.string().min(1) }),
  }),
  Pong: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('pong'),
    seq: z.null(),
    payload: z.object({ nonce: z.string().min(1) }),
  }),
  StatusDelivered: EnvelopeBase.extend({
    kind: z.literal('status'),
    type: z.literal('delivered'),
    seq: z.null(),
    payload: z.object({ ids: z.array(z.string().uuid()).min(1) }),
  }),
  StatusRead: EnvelopeBase.extend({
    kind: z.literal('status'),
    type: z.literal('read'),
    seq: z.null(),
    payload: z.object({ ids: z.array(z.string().uuid()).min(1) }),
  }),
```

- [ ] **Step 3: Extend AnyEnvelope to the full union**

Replace the provisional `AnyEnvelope` with:
```ts
export const AnyEnvelope = z.discriminatedUnion('type', [
  Envelopes.Auth, Envelopes.AuthOk, Envelopes.AuthFail,
  Envelopes.Message, Envelopes.ContextRequest, Envelopes.ContextResponse,
  Envelopes.NewConversation, Envelopes.ActionResponse, Envelopes.Feedback,
  Envelopes.Ack, Envelopes.Ping, Envelopes.Pong,
  Envelopes.StatusDelivered, Envelopes.StatusRead,
]);
export type AnyEnvelope = z.infer<typeof AnyEnvelope>;
```

- [ ] **Step 4: Run, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts
git commit -m "shared/ios-app-protocol: ack/ping/pong/status envelopes + full union"
```

---

### Task 1.5: Add JSON fixtures + round-trip contract test

**Files:**
- Create: `shared/ios-app-protocol/fixtures/*.json` (16 files)
- Create: `shared/ios-app-protocol/fixtures.test.ts`

- [ ] **Step 1: Write each fixture**

Each file is one valid envelope. Examples:

`fixtures/auth.json`:
```json
{
  "v": 2,
  "kind": "control",
  "type": "auth",
  "id": "11111111-1111-4111-8111-111111111111",
  "seq": 0,
  "ts": "2026-05-31T12:00:00.000Z",
  "payload": {
    "token": "test-token",
    "last_seen_inbound_seq": 0,
    "capabilities": ["location", "health", "calendar"]
  }
}
```

`fixtures/auth_ok.json`:
```json
{
  "v": 2,
  "kind": "control",
  "type": "auth_ok",
  "id": "22222222-2222-4222-8222-222222222222",
  "seq": 0,
  "ts": "2026-05-31T12:00:00.100Z",
  "payload": {
    "last_seen_outbound_seq": 0,
    "server_time": "2026-05-31T12:00:00.100Z"
  }
}
```

`fixtures/message_with_context.json`:
```json
{
  "v": 2,
  "kind": "data",
  "type": "message",
  "id": "33333333-3333-4333-8333-333333333333",
  "seq": 1,
  "ts": "2026-05-31T12:00:01.000Z",
  "payload": {
    "thread_id": "thr-1",
    "text": "remind me later",
    "context": {
      "location": { "lat": 55.7619, "lon": 37.5957, "accuracy": 25 },
      "timestamp": "2026-05-31T12:00:01.000Z",
      "timezone": "Europe/Moscow",
      "locality": "Patriarch's Ponds"
    }
  }
}
```

`fixtures/message_no_context.json`:
```json
{
  "v": 2, "kind": "data", "type": "message",
  "id": "33333333-3333-4333-8333-333333333334",
  "seq": 2, "ts": "2026-05-31T12:00:02.000Z",
  "payload": { "thread_id": "thr-1", "text": "ping" }
}
```

`fixtures/message_with_attachments.json`:
```json
{
  "v": 2, "kind": "data", "type": "message",
  "id": "44444444-4444-4444-8444-444444444444",
  "seq": 3, "ts": "2026-05-31T12:00:03.000Z",
  "payload": {
    "thread_id": "thr-1",
    "text": "see image",
    "attachments": [
      { "id": "44444444-4444-4444-8444-444444444445", "kind": "image",
        "name": "photo.jpg", "mime_type": "image/jpeg", "byte_size": 12345 }
    ]
  }
}
```

`fixtures/context_request_health_calendar.json`:
```json
{
  "v": 2, "kind": "control", "type": "context_request",
  "id": "55555555-5555-4555-8555-555555555555",
  "seq": 5, "ts": "2026-05-31T12:00:05.000Z",
  "payload": {
    "request_id": "55555555-5555-4555-8555-555555555556",
    "fields": ["health", "calendar"],
    "params": { "health_days": 7, "calendar_window": "next_7d" }
  }
}
```

`fixtures/context_response_full.json`:
```json
{
  "v": 2, "kind": "control", "type": "context_response",
  "id": "66666666-6666-4666-8666-666666666666",
  "seq": 6, "ts": "2026-05-31T12:00:06.000Z",
  "payload": {
    "request_id": "55555555-5555-4555-8555-555555555556",
    "data": {
      "health": { "steps_today": 4123, "hr_resting": 58 },
      "calendar": [
        { "title": "Standup", "start": "2026-06-01T09:00:00.000Z" }
      ]
    }
  }
}
```

`fixtures/context_response_partial_errors.json`:
```json
{
  "v": 2, "kind": "control", "type": "context_response",
  "id": "77777777-7777-4777-8777-777777777777",
  "seq": 7, "ts": "2026-05-31T12:00:07.000Z",
  "payload": {
    "request_id": "55555555-5555-4555-8555-555555555556",
    "data": { "calendar": [] },
    "errors": { "health": "denied" }
  }
}
```

`fixtures/ack.json`:
```json
{
  "v": 2, "kind": "ack", "type": "ack",
  "id": "88888888-8888-4888-8888-888888888888",
  "seq": null, "ts": "2026-05-31T12:00:08.000Z",
  "payload": {
    "id": "33333333-3333-4333-8333-333333333333", "seq": 1
  }
}
```

`fixtures/status_delivered_batch.json`:
```json
{
  "v": 2, "kind": "status", "type": "delivered",
  "id": "99999999-9999-4999-8999-999999999999",
  "seq": null, "ts": "2026-05-31T12:00:09.000Z",
  "payload": { "ids": [
    "33333333-3333-4333-8333-333333333333",
    "33333333-3333-4333-8333-333333333334"
  ] }
}
```

`fixtures/status_read_batch.json`:
```json
{
  "v": 2, "kind": "status", "type": "read",
  "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "seq": null, "ts": "2026-05-31T12:00:10.000Z",
  "payload": { "ids": ["33333333-3333-4333-8333-333333333333"] }
}
```

`fixtures/new_conversation.json`:
```json
{
  "v": 2, "kind": "control", "type": "new_conversation",
  "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "seq": 4, "ts": "2026-05-31T12:00:11.000Z",
  "payload": { "thread_id": "thr-2" }
}
```

`fixtures/action_response.json`:
```json
{
  "v": 2, "kind": "control", "type": "action_response",
  "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  "seq": 8, "ts": "2026-05-31T12:00:12.000Z",
  "payload": { "action_id": "approval-1", "choice": "approve" }
}
```

`fixtures/feedback.json`:
```json
{
  "v": 2, "kind": "control", "type": "feedback",
  "id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
  "seq": 9, "ts": "2026-05-31T12:00:13.000Z",
  "payload": {
    "message_id": "33333333-3333-4333-8333-333333333333",
    "kind": "up"
  }
}
```

`fixtures/ping.json`:
```json
{
  "v": 2, "kind": "control", "type": "ping",
  "id": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
  "seq": null, "ts": "2026-05-31T12:00:14.000Z",
  "payload": { "nonce": "n-1" }
}
```

`fixtures/pong.json`:
```json
{
  "v": 2, "kind": "control", "type": "pong",
  "id": "ffffffff-ffff-4fff-8fff-ffffffffffff",
  "seq": null, "ts": "2026-05-31T12:00:14.050Z",
  "payload": { "nonce": "n-1" }
}
```

- [ ] **Step 2: Write contract test**

`shared/ios-app-protocol/fixtures.test.ts`:
```ts
import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AnyEnvelope } from './v2';

const here = dirname(fileURLToPath(import.meta.url));
const fixturesDir = join(here, 'fixtures');

const files = readdirSync(fixturesDir).filter(f => f.endsWith('.json'));

describe('shared/ios-app-protocol fixtures', () => {
  for (const f of files) {
    it(`${f} round-trips through AnyEnvelope`, () => {
      const raw = readFileSync(join(fixturesDir, f), 'utf8');
      const parsedJson = JSON.parse(raw);
      const env = AnyEnvelope.parse(parsedJson);
      // Re-serialize and re-parse — semantic equality preserved.
      const reParsed = AnyEnvelope.parse(JSON.parse(JSON.stringify(env)));
      expect(reParsed).toEqual(env);
    });
  }

  it('covers all 16 expected fixtures', () => {
    expect(files).toHaveLength(16);
  });
});
```

- [ ] **Step 3: Run**

```bash
pnpm exec vitest run shared/ios-app-protocol/fixtures.test.ts
```
Expected: PASS for all 16.

- [ ] **Step 4: Commit**

```bash
git add shared/ios-app-protocol/fixtures shared/ios-app-protocol/fixtures.test.ts
git commit -m "shared/ios-app-protocol: 16 JSON fixtures + round-trip contract test"
```

---

### Task 1.6: Wire `shared/` into container build

**Files:**
- Modify: `container/build.sh`
- Modify: `container/Dockerfile` (if path needs explicit COPY)

- [ ] **Step 1: Inspect current build**

```bash
cat container/build.sh
cat container/Dockerfile
```

- [ ] **Step 2: Add COPY for shared into the image**

In `container/Dockerfile`, before the agent-runner `bun install` step, add:
```dockerfile
# Canonical wire protocol — imported by mcp-tools/request_context.ts and
# channels/ios-app-format.ts via @shared alias.
COPY shared /app/shared
```

In `container/build.sh`, ensure the build context includes the repo root (it already does — verify).

- [ ] **Step 3: Rebuild the container**

```bash
./container/build.sh
```
Expected: image rebuilds without error.

- [ ] **Step 4: Smoke check that `/app/shared` exists inside the image**

```bash
docker run --rm --entrypoint /bin/sh nanoclaw-agent:latest -c 'ls /app/shared/ios-app-protocol/'
```
Expected: list shows `v2.ts`, `fixtures/`, `index.ts`.

- [ ] **Step 5: Commit**

```bash
git add container/Dockerfile container/build.sh
git commit -m "container: copy shared/ into image for protocol module import"
```

---


## Phase 2 — Adapter v2 implementation

The new adapter lives in `src/channels/ios-app/v2/` alongside the legacy `src/channels/ios-app.ts`. We keep both compilable in this phase; the switch in `src/channels/index.ts` happens in Phase 7.

### Task 2.1: Scaffold the v2 directory + internal types

**Files:**
- Create: `src/channels/ios-app/v2/types.ts`
- Create: `src/channels/ios-app/v2/index.ts` (empty placeholder, exports added later)

- [ ] **Step 1: Create `src/channels/ios-app/v2/types.ts`**

```ts
import type { AnyEnvelope, InlineContext, ContextField } from '@shared/ios-app-protocol';

export type PlatformId = string;          // `ios-app:<deviceId>`

export interface DeviceRow {
  platform_id: PlatformId;
  last_seen_outbound_seq: number;         // highest app→adapter seq we persisted
  last_emitted_inbound_seq: number;       // highest adapter→app seq we allocated
  capabilities_json: string | null;
  updated_at: number;
}

export interface OutboundQueueRow {
  platform_id: PlatformId;
  seq: number;
  id: string;
  kind: string;
  type: string;
  payload_json: string;
  created_at: number;
}

export interface InboundDedupRow {
  platform_id: PlatformId;
  id: string;
  seq: number;
  received_at: number;
}

export interface PendingContextRequestRow {
  request_id: string;
  platform_id: PlatformId;
  session_id: string;
  fields_json: string;
  created_at: number;
  expires_at: number;
}

export const MAX_QUEUE_PER_DEVICE = 1000;
export const DEDUP_TTL_MS = 24 * 60 * 60 * 1000;
export const ACK_RETRY_MS = 5_000;
export const APP_PING_INTERVAL_MS = 60_000;
export const WS_PING_INTERVAL_MS = 25_000;
export const WS_PONG_TIMEOUT_MS = 10_000;
```

- [ ] **Step 2: Create `src/channels/ios-app/v2/index.ts`**

```ts
// Public surface: will export registerIosAppV2 in Task 2.x.
export {};
```

- [ ] **Step 3: Verify build**

```bash
pnpm exec tsc --noEmit
```

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/
git commit -m "channels/ios-app/v2: scaffold types + module shell"
```

---

### Task 2.2: `transport-db.ts` — SQLite schema + CRUD

**Files:**
- Create: `src/channels/ios-app/v2/transport-db.ts`
- Create: `src/channels/ios-app/v2/transport-db.test.ts`

- [ ] **Step 1: Write failing tests**

`src/channels/ios-app/v2/transport-db.test.ts`:
```ts
import { describe, it, expect, beforeEach } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db';

let db: TransportDb;
beforeEach(() => { db = openTransportDb(':memory:'); });

describe('transport-db', () => {
  it('creates tables on open', () => {
    const names = db.raw.prepare(`SELECT name FROM sqlite_master WHERE type='table'`).all()
      .map((r: any) => r.name).sort();
    expect(names).toEqual(expect.arrayContaining([
      'devices', 'outbound_queue', 'inbound_dedup', 'pending_context_requests',
    ]));
  });

  it('upserts a device row', () => {
    db.upsertDevice('ios-app:dev-1', { capabilities: ['location'] });
    const row = db.getDevice('ios-app:dev-1');
    expect(row?.last_seen_outbound_seq).toBe(0);
    expect(row?.last_emitted_inbound_seq).toBe(0);
    expect(JSON.parse(row!.capabilities_json!)).toEqual(['location']);
  });

  it('advances last_seen_outbound_seq monotonically', () => {
    db.upsertDevice('ios-app:dev-1', {});
    db.advanceLastSeenOutbound('ios-app:dev-1', 5);
    db.advanceLastSeenOutbound('ios-app:dev-1', 3);     // ignored — lower
    db.advanceLastSeenOutbound('ios-app:dev-1', 10);
    expect(db.getDevice('ios-app:dev-1')!.last_seen_outbound_seq).toBe(10);
  });

  it('allocates monotonic emitted seqs', () => {
    db.upsertDevice('ios-app:dev-1', {});
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(1);
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(2);
    expect(db.allocateInboundSeq('ios-app:dev-1')).toBe(3);
  });
});
```

Run, expect FAIL — module not yet present.

- [ ] **Step 2: Implement `transport-db.ts`**

```ts
import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import type { DeviceRow } from './types';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS devices (
  platform_id TEXT PRIMARY KEY,
  last_seen_outbound_seq INTEGER NOT NULL DEFAULT 0,
  last_emitted_inbound_seq INTEGER NOT NULL DEFAULT 0,
  capabilities_json TEXT,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS outbound_queue (
  platform_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  id TEXT NOT NULL,
  kind TEXT NOT NULL,
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (platform_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_outbound_id ON outbound_queue (platform_id, id);
CREATE INDEX IF NOT EXISTS idx_outbound_created ON outbound_queue (platform_id, created_at);

CREATE TABLE IF NOT EXISTS inbound_dedup (
  platform_id TEXT NOT NULL,
  id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (platform_id, id)
);
CREATE INDEX IF NOT EXISTS idx_inbound_dedup_received ON inbound_dedup (received_at);

CREATE TABLE IF NOT EXISTS pending_context_requests (
  request_id TEXT PRIMARY KEY,
  platform_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  fields_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pending_expires ON pending_context_requests (expires_at);
`;

export interface TransportDb {
  raw: Database.Database;
  upsertDevice(platform_id: string, opts: { capabilities?: string[] }): void;
  getDevice(platform_id: string): DeviceRow | undefined;
  advanceLastSeenOutbound(platform_id: string, seq: number): void;
  allocateInboundSeq(platform_id: string): number;
}

export function openTransportDb(path: string): TransportDb {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.exec(SCHEMA);

  return {
    raw: db,
    upsertDevice(platform_id, opts) {
      db.prepare(`
        INSERT INTO devices (platform_id, capabilities_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(platform_id) DO UPDATE SET
          capabilities_json = excluded.capabilities_json,
          updated_at = excluded.updated_at
      `).run(platform_id, JSON.stringify(opts.capabilities ?? null), Date.now());
    },
    getDevice(platform_id) {
      return db.prepare(`SELECT * FROM devices WHERE platform_id = ?`).get(platform_id) as DeviceRow | undefined;
    },
    advanceLastSeenOutbound(platform_id, seq) {
      db.prepare(`
        UPDATE devices
        SET last_seen_outbound_seq = MAX(last_seen_outbound_seq, ?), updated_at = ?
        WHERE platform_id = ?
      `).run(seq, Date.now(), platform_id);
    },
    allocateInboundSeq(platform_id) {
      const row = db.prepare(`
        UPDATE devices
        SET last_emitted_inbound_seq = last_emitted_inbound_seq + 1, updated_at = ?
        WHERE platform_id = ?
        RETURNING last_emitted_inbound_seq AS seq
      `).get(Date.now(), platform_id) as { seq: number } | undefined;
      if (!row) throw new Error(`unknown platform_id: ${platform_id}`);
      return row.seq;
    },
  };
}
```

- [ ] **Step 3: Run tests, expect PASS**

```bash
pnpm exec vitest run src/channels/ios-app/v2/transport-db.test.ts
```

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/transport-db.ts src/channels/ios-app/v2/transport-db.test.ts
git commit -m "channels/ios-app/v2: transport-db schema + device CRUD"
```

---

### Task 2.3: `outbound-queue.ts` — enqueue, drain, ack, retry, overflow

**Files:**
- Create: `src/channels/ios-app/v2/outbound-queue.ts`
- Create: `src/channels/ios-app/v2/outbound-queue.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
import { describe, it, expect, beforeEach } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db';
import { OutboundQueue } from './outbound-queue';
import { MAX_QUEUE_PER_DEVICE } from './types';

let db: TransportDb;
let q: OutboundQueue;
beforeEach(() => {
  db = openTransportDb(':memory:');
  db.upsertDevice('ios-app:dev-1', {});
  q = new OutboundQueue(db);
});

const env = (over: Partial<{id: string; kind: string; type: string; payload: unknown}> = {}) => ({
  id: over.id ?? '11111111-1111-4111-8111-111111111111',
  kind: over.kind ?? 'data',
  type: over.type ?? 'message',
  payload: over.payload ?? { thread_id: 't', text: 'hi' },
});

describe('OutboundQueue', () => {
  it('enqueue allocates seq and stores row', () => {
    const seq = q.enqueue('ios-app:dev-1', env());
    expect(seq).toBe(1);
    expect(q.list('ios-app:dev-1')).toHaveLength(1);
  });

  it('ack by id removes the row', () => {
    q.enqueue('ios-app:dev-1', env({ id: '11111111-1111-4111-8111-111111111111' }));
    q.enqueue('ios-app:dev-1', env({ id: '22222222-2222-4222-8222-222222222222' }));
    q.ackById('ios-app:dev-1', '11111111-1111-4111-8111-111111111111');
    const ids = q.list('ios-app:dev-1').map(r => r.id);
    expect(ids).toEqual(['22222222-2222-4222-8222-222222222222']);
  });

  it('ackUpTo seq removes all rows <= seq', () => {
    for (let i = 0; i < 5; i++) {
      q.enqueue('ios-app:dev-1', env({ id: `1111111${i}-1111-4111-8111-111111111111` }));
    }
    q.ackUpTo('ios-app:dev-1', 3);
    expect(q.list('ios-app:dev-1').map(r => r.seq)).toEqual([4, 5]);
  });

  it('overflow drops oldest when > MAX_QUEUE_PER_DEVICE', () => {
    for (let i = 0; i < MAX_QUEUE_PER_DEVICE + 5; i++) {
      q.enqueue('ios-app:dev-1', env({ id: `${i.toString(16).padStart(8, '0')}-1111-4111-8111-111111111111` }));
    }
    const rows = q.list('ios-app:dev-1');
    expect(rows).toHaveLength(MAX_QUEUE_PER_DEVICE);
    expect(rows[0].seq).toBe(6);   // first 5 dropped
  });

  it('listOlderThan returns retry candidates', () => {
    q.enqueue('ios-app:dev-1', env());
    const now = Date.now();
    // freshly inserted — none older than now+1
    expect(q.listOlderThan('ios-app:dev-1', now + 1)).toEqual([]);
    // all older than now+10s
    expect(q.listOlderThan('ios-app:dev-1', now - 10_000)).toHaveLength(1);
  });
});
```

Run, expect FAIL.

- [ ] **Step 2: Implement `outbound-queue.ts`**

```ts
import type { TransportDb } from './transport-db';
import { MAX_QUEUE_PER_DEVICE, type OutboundQueueRow } from './types';

export interface EnqueueInput {
  id: string;
  kind: string;
  type: string;
  payload: unknown;
}

export class OutboundQueue {
  constructor(private db: TransportDb) {}

  enqueue(platform_id: string, input: EnqueueInput): number {
    return this.db.raw.transaction(() => {
      const seq = this.db.allocateInboundSeq(platform_id);
      const count = this.db.raw.prepare(
        `SELECT COUNT(*) AS n FROM outbound_queue WHERE platform_id = ?`
      ).get(platform_id) as { n: number };
      if (count.n >= MAX_QUEUE_PER_DEVICE) {
        // drop oldest by seq
        const toDrop = count.n - MAX_QUEUE_PER_DEVICE + 1;
        this.db.raw.prepare(`
          DELETE FROM outbound_queue
          WHERE platform_id = ? AND seq IN (
            SELECT seq FROM outbound_queue WHERE platform_id = ? ORDER BY seq ASC LIMIT ?
          )
        `).run(platform_id, platform_id, toDrop);
      }
      this.db.raw.prepare(`
        INSERT INTO outbound_queue (platform_id, seq, id, kind, type, payload_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `).run(platform_id, seq, input.id, input.kind, input.type, JSON.stringify(input.payload), Date.now());
      return seq;
    })();
  }

  ackById(platform_id: string, id: string): void {
    this.db.raw.prepare(
      `DELETE FROM outbound_queue WHERE platform_id = ? AND id = ?`
    ).run(platform_id, id);
  }

  ackUpTo(platform_id: string, seq: number): void {
    this.db.raw.prepare(
      `DELETE FROM outbound_queue WHERE platform_id = ? AND seq <= ?`
    ).run(platform_id, seq);
  }

  list(platform_id: string): OutboundQueueRow[] {
    return this.db.raw.prepare(
      `SELECT * FROM outbound_queue WHERE platform_id = ? ORDER BY seq ASC`
    ).all(platform_id) as OutboundQueueRow[];
  }

  listOlderThan(platform_id: string, beforeMs: number): OutboundQueueRow[] {
    return this.db.raw.prepare(
      `SELECT * FROM outbound_queue WHERE platform_id = ? AND created_at < ? ORDER BY seq ASC`
    ).all(platform_id, beforeMs) as OutboundQueueRow[];
  }
}
```

- [ ] **Step 3: Run, expect PASS**

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/outbound-queue.ts src/channels/ios-app/v2/outbound-queue.test.ts
git commit -m "channels/ios-app/v2: durable outbound queue with overflow + retry list"
```

---

### Task 2.4: `receipt-store.ts` — local read receipt store

**Files:**
- Create: `src/channels/ios-app/v2/receipt-store.ts`

- [ ] **Step 1: Implement (no test — trivial)**

```ts
// UI-only bookkeeping for delivered/read on agent→user messages.
// Adapter never propagates these to the agent.
import type { TransportDb } from './transport-db';

export class ReceiptStore {
  constructor(private db: TransportDb) {
    this.db.raw.exec(`
      CREATE TABLE IF NOT EXISTS receipts (
        platform_id TEXT NOT NULL,
        message_id TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('delivered','read')),
        ts INTEGER NOT NULL,
        PRIMARY KEY (platform_id, message_id, state)
      );
    `);
  }
  record(platform_id: string, ids: string[], state: 'delivered' | 'read'): void {
    const stmt = this.db.raw.prepare(`
      INSERT OR IGNORE INTO receipts (platform_id, message_id, state, ts) VALUES (?, ?, ?, ?)
    `);
    const now = Date.now();
    this.db.raw.transaction(() => { for (const id of ids) stmt.run(platform_id, id, state, now); })();
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add src/channels/ios-app/v2/receipt-store.ts
git commit -m "channels/ios-app/v2: local read receipt store (UI-only)"
```

---

### Task 2.5: `inbound-dispatch.ts` — route parsed envelopes to side-effects

**Files:**
- Create: `src/channels/ios-app/v2/inbound-dispatch.ts`
- Create: `src/channels/ios-app/v2/inbound-dispatch.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db';
import { OutboundQueue } from './outbound-queue';
import { ReceiptStore } from './receipt-store';
import { InboundDispatcher } from './inbound-dispatch';

const pid = 'ios-app:dev-1';
let db: TransportDb, q: OutboundQueue, receipts: ReceiptStore, d: InboundDispatcher;
let onInbound = vi.fn();
let onContextResponse = vi.fn();
let onAction = vi.fn();
let onNewConversation = vi.fn();

beforeEach(() => {
  db = openTransportDb(':memory:');
  db.upsertDevice(pid, {});
  q = new OutboundQueue(db);
  receipts = new ReceiptStore(db);
  onInbound = vi.fn(); onContextResponse = vi.fn(); onAction = vi.fn(); onNewConversation = vi.fn();
  d = new InboundDispatcher({
    db, queue: q, receipts,
    resolveSessionForPlatform: () => 'sess-1',
    onUserMessage: onInbound,
    onContextResponse,
    onAction,
    onNewConversation,
    onFeedback: vi.fn(),
  });
});

const env = (over: any) => ({
  v: 2 as const, id: '11111111-1111-4111-8111-111111111111',
  ts: '2026-05-31T12:00:00.000Z', seq: 1, kind: 'data', type: 'message',
  payload: { thread_id: 'thr', text: 'hi' }, ...over,
});

describe('InboundDispatcher', () => {
  it('routes message → onUserMessage and writes inbound_dedup', () => {
    const action = d.dispatch(pid, env({}));
    expect(action.kind).toBe('ack');
    expect(onInbound).toHaveBeenCalledTimes(1);
    expect(db.raw.prepare(`SELECT COUNT(*) AS n FROM inbound_dedup`).get()).toEqual({ n: 1 });
  });

  it('dedups by id and re-acks without re-dispatch', () => {
    const e = env({});
    d.dispatch(pid, e);
    const second = d.dispatch(pid, e);
    expect(second.kind).toBe('ack');
    expect(onInbound).toHaveBeenCalledTimes(1);
  });

  it('advances last_seen_outbound_seq monotonically', () => {
    d.dispatch(pid, env({ seq: 5, id: '11111111-1111-4111-8111-111111111111' }));
    d.dispatch(pid, env({ seq: 3, id: '22222222-2222-4222-8222-222222222222' }));
    expect(db.getDevice(pid)!.last_seen_outbound_seq).toBe(5);
  });

  it('status:delivered records in ReceiptStore, never propagates', () => {
    d.dispatch(pid, env({
      kind: 'status', type: 'delivered', seq: null,
      payload: { ids: ['11111111-1111-4111-8111-111111111119'] },
    }));
    const rec = db.raw.prepare(`SELECT state FROM receipts`).all();
    expect(rec).toEqual([{ state: 'delivered' }]);
    expect(onInbound).not.toHaveBeenCalled();
  });

  it('control:ping returns a pong action and does not persist', () => {
    const action = d.dispatch(pid, env({
      kind: 'control', type: 'ping', seq: null, payload: { nonce: 'n1' },
    }));
    expect(action.kind).toBe('pong');
    if (action.kind === 'pong') expect(action.nonce).toBe('n1');
    expect(db.raw.prepare(`SELECT COUNT(*) AS n FROM inbound_dedup`).get()).toEqual({ n: 0 });
    expect(db.getDevice(pid)!.last_seen_outbound_seq).toBe(0);
  });

  it('context_response calls onContextResponse', () => {
    d.dispatch(pid, env({
      kind: 'control', type: 'context_response', seq: 7,
      payload: {
        request_id: '55555555-5555-4555-8555-555555555556',
        data: { device: { battery: 0.5 } },
      },
    }));
    expect(onContextResponse).toHaveBeenCalledWith(expect.objectContaining({
      request_id: '55555555-5555-4555-8555-555555555556',
    }));
  });
});
```

Run, expect FAIL.

- [ ] **Step 2: Implement `inbound-dispatch.ts`**

```ts
import type { TransportDb } from './transport-db';
import type { OutboundQueue } from './outbound-queue';
import type { ReceiptStore } from './receipt-store';
import type { AnyEnvelope } from '@shared/ios-app-protocol';

export type DispatchAction =
  | { kind: 'ack' }                               // sender should be acked
  | { kind: 'pong'; nonce: string }                // adapter must send pong synchronously
  | { kind: 'noop' };                              // status — sender does not get ack

export interface DispatcherDeps {
  db: TransportDb;
  queue: OutboundQueue;
  receipts: ReceiptStore;
  resolveSessionForPlatform: (platform_id: string) => string | null;
  onUserMessage: (input: {
    platform_id: string; session_id: string; envelope: Extract<AnyEnvelope, { type: 'message' }>;
  }) => void;
  onContextResponse: (input: {
    platform_id: string; envelope: Extract<AnyEnvelope, { type: 'context_response' }>;
  }) => void;
  onAction: (input: {
    platform_id: string; envelope: Extract<AnyEnvelope, { type: 'action_response' }>;
  }) => void;
  onNewConversation: (input: {
    platform_id: string; envelope: Extract<AnyEnvelope, { type: 'new_conversation' }>;
  }) => void;
  onFeedback: (input: {
    platform_id: string; envelope: Extract<AnyEnvelope, { type: 'feedback' }>;
  }) => void;
}

export class InboundDispatcher {
  constructor(private deps: DispatcherDeps) {}

  dispatch(platform_id: string, env: AnyEnvelope): DispatchAction {
    // Stateless types short-circuit.
    if (env.type === 'ping')
      return { kind: 'pong', nonce: env.payload.nonce };
    if (env.type === 'delivered' || env.type === 'read') {
      this.deps.receipts.record(platform_id, env.payload.ids, env.type);
      return { kind: 'noop' };
    }
    if (env.type === 'ack')
      return { kind: 'noop' };  // acks for our outbound are handled by ws-handler

    // Ordered types: dedup + persist + dispatch in a transaction.
    return this.deps.db.raw.transaction(() => {
      const existing = this.deps.db.raw.prepare(
        `SELECT 1 FROM inbound_dedup WHERE platform_id = ? AND id = ?`
      ).get(platform_id, env.id);
      if (existing) return { kind: 'ack' as const };  // re-ack duplicate, no re-dispatch

      this.deps.db.raw.prepare(`
        INSERT INTO inbound_dedup (platform_id, id, seq, received_at) VALUES (?, ?, ?, ?)
      `).run(platform_id, env.id, env.seq ?? 0, Date.now());
      if (env.seq != null) this.deps.db.advanceLastSeenOutbound(platform_id, env.seq);

      const session_id = this.deps.resolveSessionForPlatform(platform_id);

      switch (env.type) {
        case 'message':
          if (session_id) this.deps.onUserMessage({ platform_id, session_id, envelope: env });
          break;
        case 'context_response':
          this.deps.onContextResponse({ platform_id, envelope: env });
          break;
        case 'action_response':
          this.deps.onAction({ platform_id, envelope: env });
          break;
        case 'new_conversation':
          this.deps.onNewConversation({ platform_id, envelope: env });
          break;
        case 'feedback':
          this.deps.onFeedback({ platform_id, envelope: env });
          break;
      }
      return { kind: 'ack' as const };
    })();
  }
}
```

- [ ] **Step 3: Run, expect PASS**

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/inbound-dispatch.ts src/channels/ios-app/v2/inbound-dispatch.test.ts
git commit -m "channels/ios-app/v2: inbound dispatcher with dedup + ping pong + receipts"
```

---

### Task 2.6: `context-bridge.ts` — agent's context_request → WS envelope, TTL sweep

**Files:**
- Create: `src/channels/ios-app/v2/context-bridge.ts`
- Create: `src/channels/ios-app/v2/context-bridge.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db';
import { ContextBridge } from './context-bridge';

let db: TransportDb;
let bridge: ContextBridge;
const pid = 'ios-app:dev-1';
const session = 'sess-1';

const sendEnvelope = vi.fn();
const writeInbound = vi.fn();
const resolvePid = vi.fn(() => pid);

beforeEach(() => {
  db = openTransportDb(':memory:');
  db.upsertDevice(pid, {});
  sendEnvelope.mockReset();
  writeInbound.mockReset();
  bridge = new ContextBridge({
    db, resolvePlatformForSession: resolvePid,
    sendEnvelopeToDevice: sendEnvelope,
    writeInboundContextResponse: writeInbound,
  });
});

describe('ContextBridge', () => {
  it('registers pending row + sends envelope', () => {
    bridge.handleAgentRequest({
      session_id: session,
      request_id: 'r-1',
      fields: ['device'],
      params: {},
      expires_at_ms: Date.now() + 10_000,
    });
    const row = db.raw.prepare(`SELECT * FROM pending_context_requests`).get();
    expect(row).toBeTruthy();
    expect(sendEnvelope).toHaveBeenCalledTimes(1);
  });

  it('rejects when session has no ios-app device', () => {
    resolvePid.mockReturnValueOnce(null);
    bridge.handleAgentRequest({
      session_id: 'sess-X', request_id: 'r-2', fields: ['device'], params: {},
      expires_at_ms: Date.now() + 10_000,
    });
    expect(sendEnvelope).not.toHaveBeenCalled();
    expect(writeInbound).toHaveBeenCalledWith(expect.objectContaining({
      session_id: 'sess-X', request_id: 'r-2',
      errors: { scope: 'no ios-app device wired' },
    }));
  });

  it('sweep expires stale requests', () => {
    bridge.handleAgentRequest({
      session_id: session, request_id: 'r-3', fields: ['device'], params: {},
      expires_at_ms: Date.now() - 100,
    });
    bridge.sweepExpired();
    expect(writeInbound).toHaveBeenCalledWith(expect.objectContaining({
      request_id: 'r-3', errors: { timeout: 'device offline / timeout' },
    }));
    expect(db.raw.prepare(`SELECT COUNT(*) AS n FROM pending_context_requests`).get()).toEqual({ n: 0 });
  });

  it('removes pending row on incoming context_response', () => {
    bridge.handleAgentRequest({
      session_id: session, request_id: 'r-4', fields: ['device'], params: {},
      expires_at_ms: Date.now() + 10_000,
    });
    bridge.resolveDeviceResponse('r-4');
    expect(db.raw.prepare(`SELECT COUNT(*) AS n FROM pending_context_requests`).get()).toEqual({ n: 0 });
  });
});
```

Run, expect FAIL.

- [ ] **Step 2: Implement `context-bridge.ts`**

```ts
import { randomUUID } from 'node:crypto';
import type { TransportDb } from './transport-db';
import type { ContextField } from '@shared/ios-app-protocol';

export interface ContextBridgeDeps {
  db: TransportDb;
  resolvePlatformForSession: (session_id: string) => string | null;
  sendEnvelopeToDevice: (platform_id: string, envelope: unknown) => void;
  writeInboundContextResponse: (input: {
    session_id: string;
    request_id: string;
    data: Record<string, unknown>;
    errors?: Record<string, string>;
  }) => void;
}

export interface AgentRequest {
  session_id: string;
  request_id: string;
  fields: ContextField[];
  params: Record<string, unknown>;
  expires_at_ms: number;
}

export class ContextBridge {
  constructor(private deps: ContextBridgeDeps) {}

  handleAgentRequest(req: AgentRequest) {
    const platform_id = this.deps.resolvePlatformForSession(req.session_id);
    if (!platform_id) {
      this.deps.writeInboundContextResponse({
        session_id: req.session_id,
        request_id: req.request_id,
        data: {},
        errors: { scope: 'no ios-app device wired' },
      });
      return;
    }
    this.deps.db.raw.prepare(`
      INSERT OR REPLACE INTO pending_context_requests
        (request_id, platform_id, session_id, fields_json, created_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(req.request_id, platform_id, req.session_id, JSON.stringify(req.fields),
            Date.now(), req.expires_at_ms);

    this.deps.sendEnvelopeToDevice(platform_id, {
      v: 2, kind: 'control', type: 'context_request',
      id: randomUUID(), seq: 0,                    // seq is replaced by ws-handler at send
      ts: new Date().toISOString(),
      payload: { request_id: req.request_id, fields: req.fields, params: req.params },
    });
  }

  resolveDeviceResponse(request_id: string): { session_id: string } | null {
    const row = this.deps.db.raw.prepare(
      `SELECT session_id FROM pending_context_requests WHERE request_id = ?`
    ).get(request_id) as { session_id: string } | undefined;
    if (!row) return null;
    this.deps.db.raw.prepare(
      `DELETE FROM pending_context_requests WHERE request_id = ?`
    ).run(request_id);
    return { session_id: row.session_id };
  }

  sweepExpired() {
    const now = Date.now();
    const rows = this.deps.db.raw.prepare(
      `SELECT request_id, session_id FROM pending_context_requests WHERE expires_at < ?`
    ).all(now) as { request_id: string; session_id: string }[];
    for (const r of rows) {
      this.deps.writeInboundContextResponse({
        session_id: r.session_id,
        request_id: r.request_id,
        data: {},
        errors: { timeout: 'device offline / timeout' },
      });
    }
    this.deps.db.raw.prepare(
      `DELETE FROM pending_context_requests WHERE expires_at < ?`
    ).run(now);
  }
}
```

- [ ] **Step 3: Run, expect PASS**

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/context-bridge.ts src/channels/ios-app/v2/context-bridge.test.ts
git commit -m "channels/ios-app/v2: context bridge with per-session scope + TTL sweep"
```

---

### Task 2.7: `ws-handler.ts` — handshake, dispatch loop, retry timer, replay

**Files:**
- Create: `src/channels/ios-app/v2/ws-handler.ts`
- Create: `src/channels/ios-app/v2/ws-handler.test.ts`
- Create: `src/channels/ios-app/v2/ws-handler.ping.test.ts`

This task is substantial. Test code shown for behavior; implementation references the dispatcher + queue.

- [ ] **Step 1: Write failing test for the handshake**

`ws-handler.test.ts` (excerpt — repeat per scenario):
```ts
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { WebSocket } from 'ws';
import { startTestServer, type Harness } from './testing/harness';
// harness is a tiny helper that boots a WSServer with the handler wired against in-memory DB.

let h: Harness;
beforeEach(async () => { h = await startTestServer(); });
afterEach(async () => { await h.close(); });

describe('ws-handler handshake', () => {
  it('replies auth_ok with current last_seen_outbound_seq', async () => {
    const ws = new WebSocket(h.url);
    await new Promise(r => ws.on('open', r));
    ws.send(JSON.stringify({
      v: 2, kind: 'control', type: 'auth',
      id: '11111111-1111-4111-8111-111111111111', seq: 0,
      ts: new Date().toISOString(),
      payload: { token: h.validToken, last_seen_inbound_seq: 0, capabilities: [] },
    }));
    const msg = await h.expectIncoming(ws);
    expect(msg.type).toBe('auth_ok');
    expect(msg.payload.last_seen_outbound_seq).toBe(0);
    ws.close();
  });

  it('closes with protocol_violation on v != 2', async () => {
    const ws = new WebSocket(h.url);
    await new Promise(r => ws.on('open', r));
    const closed = new Promise<number>(r => ws.on('close', code => r(code)));
    ws.send(JSON.stringify({ v: 1 }));
    expect(await closed).toBe(4002);   // adapter-defined code for protocol_violation
  });
});
```

Add scenarios per spec Section "Tests → Layer 1 → ws-handler.test.ts": cursor replay, superseded socket, dedup duplicate id.

Run, expect FAIL.

- [ ] **Step 2: Implement `ws-handler.ts`**

The handler stitches `transport-db`, `outbound-queue`, `inbound-dispatch`, and `context-bridge` together over a `ws.WebSocketServer`. Full reference shape:

```ts
import { WebSocketServer, type WebSocket } from 'ws';
import { AnyEnvelope } from '@shared/ios-app-protocol';
import { ACK_RETRY_MS, APP_PING_INTERVAL_MS, WS_PING_INTERVAL_MS, WS_PONG_TIMEOUT_MS, type PlatformId } from './types';
import type { TransportDb } from './transport-db';
import type { OutboundQueue } from './outbound-queue';
import type { InboundDispatcher } from './inbound-dispatch';
import type { ContextBridge } from './context-bridge';

const CODES = {
  protocol_violation: 4002,
  auth_failed: 4003,
  superseded: 4004,
};

export interface WsHandlerDeps {
  db: TransportDb;
  queue: OutboundQueue;
  dispatcher: InboundDispatcher;
  contextBridge: ContextBridge;
  validateToken: (token: string) => Promise<PlatformId | null>;
}

export class WsHandler {
  private sockets = new Map<PlatformId, WebSocket>();
  private retryTimers = new Map<PlatformId, NodeJS.Timeout>();
  private appPingTimers = new Map<PlatformId, NodeJS.Timeout>();

  constructor(private deps: WsHandlerDeps) {}

  attach(server: WebSocketServer) {
    server.on('connection', ws => this.onConnection(ws));
  }

  private onConnection(ws: WebSocket) {
    let platform_id: PlatformId | null = null;
    const authTimeout = setTimeout(() => {
      if (!platform_id) ws.close(CODES.auth_failed, 'auth_timeout');
    }, 10_000);

    ws.on('message', async raw => {
      let env: AnyEnvelope;
      try { env = AnyEnvelope.parse(JSON.parse(raw.toString())); }
      catch { ws.close(CODES.protocol_violation, 'protocol_violation'); return; }

      if (!platform_id) {
        if (env.type !== 'auth') { ws.close(CODES.auth_failed, 'expected_auth'); return; }
        const pid = await this.deps.validateToken(env.payload.token);
        if (!pid) { ws.close(CODES.auth_failed, 'invalid_token'); return; }
        clearTimeout(authTimeout);
        this.attachAuthed(ws, pid, env);
        platform_id = pid;
        return;
      }

      const action = this.deps.dispatcher.dispatch(platform_id, env);
      if (action.kind === 'ack') this.sendAck(ws, env);
      else if (action.kind === 'pong') this.sendPong(ws, action.nonce);
      // noop: nothing
    });

    ws.on('close', () => {
      if (platform_id && this.sockets.get(platform_id) === ws) {
        this.sockets.delete(platform_id);
        clearInterval(this.retryTimers.get(platform_id));
        clearInterval(this.appPingTimers.get(platform_id));
      }
    });
  }

  private attachAuthed(ws: WebSocket, pid: PlatformId, auth: Extract<AnyEnvelope, { type: 'auth' }>) {
    this.deps.db.upsertDevice(pid, { capabilities: auth.payload.capabilities });
    // app's last_seen_inbound_seq == highest adapter→app seq client has acknowledged
    this.deps.queue.ackUpTo(pid, auth.payload.last_seen_inbound_seq);

    // supersede any existing socket
    const prev = this.sockets.get(pid);
    if (prev && prev !== ws) prev.close(CODES.superseded, 'superseded');
    this.sockets.set(pid, ws);

    // reply auth_ok
    const dev = this.deps.db.getDevice(pid)!;
    this.send(ws, {
      v: 2, kind: 'control', type: 'auth_ok',
      id: crypto.randomUUID(), seq: null, ts: new Date().toISOString(),
      payload: {
        last_seen_outbound_seq: dev.last_seen_outbound_seq,
        server_time: new Date().toISOString(),
      },
    });

    // drain queue
    for (const row of this.deps.queue.list(pid)) this.sendQueueRow(ws, row);

    // retry timer + app-level ping
    this.retryTimers.set(pid, setInterval(() => this.tickRetry(pid), 1000));
    this.appPingTimers.set(pid, setInterval(() => this.sendAppPing(ws), APP_PING_INTERVAL_MS));
  }

  // ... sendAck, sendPong, sendQueueRow, send (raw), tickRetry, sendAppPing, sendEnvelopeToDevice for ContextBridge.
  // Full bodies in spec §"Adapter Internals → Connection Lifecycle".
}
```

- [ ] **Step 3: Run all `ws-handler.test.ts` scenarios, expect PASS**

- [ ] **Step 4: Write `ws-handler.ping.test.ts`**

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { WebSocket } from 'ws';
import { startTestServer, type Harness } from './testing/harness';

let h: Harness;
beforeEach(async () => { h = await startTestServer(); });
afterEach(async () => { await h.close(); });

describe('ping isolation', () => {
  it('ping → pong with same nonce; no inbound write; no seq advance', async () => {
    const ws = await h.connectAuthed();
    await h.send(ws, {
      v: 2, kind: 'control', type: 'ping', id: crypto.randomUUID(),
      seq: null, ts: new Date().toISOString(), payload: { nonce: 'n1' },
    });
    const pong = await h.expectIncoming(ws);
    expect(pong.type).toBe('pong');
    expect(pong.payload.nonce).toBe('n1');

    // Side-effect checks
    expect(h.db.raw.prepare(`SELECT COUNT(*) AS n FROM inbound_dedup`).get()).toEqual({ n: 0 });
    expect(h.db.raw.prepare(`SELECT COUNT(*) AS n FROM outbound_queue`).get()).toEqual({ n: 0 });
    expect(h.db.getDevice(h.platformId)!.last_seen_outbound_seq).toBe(0);
  });
});
```

Run, expect PASS (already supported by handler from Step 2).

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/ws-handler.ts src/channels/ios-app/v2/ws-handler.test.ts src/channels/ios-app/v2/ws-handler.ping.test.ts src/channels/ios-app/v2/testing/
git commit -m "channels/ios-app/v2: ws-handler with handshake, dispatch, retry, ping isolation"
```

---

### Task 2.8: `index.ts` — register the adapter, wire host glue

**Files:**
- Modify: `src/channels/ios-app/v2/index.ts`

- [ ] **Step 1: Write the registration entry**

```ts
import http from 'node:http';
import { WebSocketServer } from 'ws';
import path from 'node:path';
import { registerChannelAdapter } from '../../channel-registry.js';
import { openTransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { ReceiptStore } from './receipt-store.js';
import { InboundDispatcher } from './inbound-dispatch.js';
import { ContextBridge } from './context-bridge.js';
import { WsHandler } from './ws-handler.js';

export function registerIosAppV2(ctx: ChannelRegistrationContext) {
  const db = openTransportDb(path.join(ctx.dataDir, 'ios-app', 'transport.db'));
  const queue = new OutboundQueue(db);
  const receipts = new ReceiptStore(db);
  const dispatcher = new InboundDispatcher({
    db, queue, receipts,
    resolveSessionForPlatform: ctx.resolveSessionForPlatform,
    onUserMessage: ctx.writeInboundUserMessage,
    onContextResponse: ctx.writeInboundContextResponse,
    onAction: ctx.onAction,
    onNewConversation: ctx.onNewConversation,
    onFeedback: ctx.writeInboundFeedback,
  });
  const contextBridge = new ContextBridge({
    db,
    resolvePlatformForSession: ctx.resolvePlatformForSession,
    sendEnvelopeToDevice: (pid, env) => handler.sendEnvelopeToDevice(pid, env),
    writeInboundContextResponse: ctx.writeInboundContextResponse,
  });
  const handler = new WsHandler({ db, queue, dispatcher, contextBridge, validateToken: ctx.validateToken });

  const server = http.createServer();
  const wss = new WebSocketServer({ server });
  handler.attach(wss);
  setInterval(() => contextBridge.sweepExpired(), 1000).unref();

  // outbound from agent: poll outbound.db rows, route `context_request` and other types
  ctx.subscribeOutbound(msg => {
    if (msg.type === 'context_request') {
      contextBridge.handleAgentRequest({
        session_id: msg.session_id,
        request_id: msg.payload.request_id,
        fields: msg.payload.fields,
        params: msg.payload.params ?? {},
        expires_at_ms: msg.payload.expires_at_ms ?? Date.now() + 10_000,
      });
    } else {
      const pid = ctx.resolvePlatformForSession(msg.session_id);
      if (!pid) return;
      const seq = queue.enqueue(pid, { id: crypto.randomUUID(), kind: msg.kind, type: msg.type, payload: msg.payload });
      handler.flushToLiveSocket(pid, seq);
    }
  });

  server.listen(ctx.iosAppPort);

  registerChannelAdapter('ios-app', { /* lifecycle hooks, etc. */ });
}

interface ChannelRegistrationContext { /* shape matches existing channel adapter API */ }
```

(The exact `ChannelRegistrationContext` and `registerChannelAdapter` shapes mirror today's `src/channels/ios-app.ts` registration. Adapt to whatever the current channel registry expects.)

- [ ] **Step 2: Run `pnpm exec tsc --noEmit`, fix typing**

- [ ] **Step 3: Do NOT yet wire this in `src/channels/index.ts`** — Phase 7 does the switch.

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/index.ts
git commit -m "channels/ios-app/v2: wire registration (not yet enabled in src/channels/index.ts)"
```

---


## Phase 3 — Agent-runner changes

### Task 3.1: `ios-app-format.ts` — render InlineContext as prefix

**Files:**
- Create: `container/agent-runner/src/channels/ios-app-format.ts`
- Create: `container/agent-runner/src/channels/ios-app-format.test.ts`

- [ ] **Step 1: Write failing test (bun:test)**

```ts
import { describe, it, expect } from 'bun:test';
import { formatIosInbound } from './ios-app-format';

describe('formatIosInbound', () => {
  const text = 'remind me later';

  it('full context renders all parts', () => {
    const out = formatIosInbound(text, {
      location: { lat: 55.7619, lon: 37.5957, accuracy: 25 },
      timestamp: '2026-05-31T12:00:00.000Z',
      timezone: 'Europe/Moscow',
      locality: "Patriarch's Ponds",
    });
    expect(out).toContain('[iOS context — 2026-05-31T12:00:00Z Europe/Moscow, near "Patriarch\'s Ponds"');
    expect(out).toContain('loc=55.7619,37.5957 ±25m');
    expect(out.endsWith(text)).toBe(true);
  });

  it('no locality drops the near segment', () => {
    const out = formatIosInbound(text, {
      location: { lat: 1, lon: 2 },
      timestamp: '2026-05-31T12:00:00.000Z',
      timezone: 'UTC',
    });
    expect(out).not.toContain('near');
    expect(out).toContain('loc=1,2]');             // no accuracy → no ±
  });

  it('no context returns text unchanged', () => {
    expect(formatIosInbound(text, undefined)).toBe(text);
  });
});
```

Run, expect FAIL.

- [ ] **Step 2: Implement**

```ts
import type { InlineContext } from '@shared/ios-app-protocol';

export function formatIosInbound(text: string, ctx: InlineContext | undefined): string {
  if (!ctx) return text;
  const headerParts: string[] = [
    `[iOS context — ${ctx.timestamp.replace(/\.\d{3}Z$/, 'Z')} ${ctx.timezone}`,
  ];
  if (ctx.locality) headerParts[0] += `, near "${ctx.locality}"`;
  let header = headerParts[0];
  if (ctx.location) {
    const acc = ctx.location.accuracy != null ? ` ±${ctx.location.accuracy}m` : '';
    header += `\n loc=${ctx.location.lat},${ctx.location.lon}${acc}`;
  }
  header += ']';
  return `${header}\n${text}`;
}
```

- [ ] **Step 3: Run, expect PASS**

```bash
cd container/agent-runner && bun test src/channels/ios-app-format.test.ts
```

- [ ] **Step 4: Commit**

```bash
git add container/agent-runner/src/channels/ios-app-format.ts container/agent-runner/src/channels/ios-app-format.test.ts
git commit -m "agent-runner: ios-app-format helper for InlineContext prefix"
```

---

### Task 3.2: `request_context` MCP tool

**Files:**
- Create: `container/agent-runner/src/mcp-tools/request_context.ts`
- Create: `container/agent-runner/src/mcp-tools/request_context.test.ts`
- Modify: `container/agent-runner/src/mcp-tools/core.ts` (remove old handler)

- [ ] **Step 1: Write failing test**

```ts
import { describe, it, expect, beforeEach, mock } from 'bun:test';
import { requestContextTool, onContextResponse } from './request_context';

const writeMessageOut = mock(async () => {});
const ctx = { session_id: 'sess-1', writeMessageOut };

beforeEach(() => writeMessageOut.mockClear());

describe('request_context tool', () => {
  it('writes messages_out with expires_at_ms = now + timeout_ms', async () => {
    const before = Date.now();
    const promise = requestContextTool.handler({ fields: ['device'] }, ctx as any);
    expect(writeMessageOut).toHaveBeenCalledTimes(1);
    const call = writeMessageOut.mock.calls[0];
    expect(call[1].type).toBe('context_request');
    expect(call[1].payload.expires_at_ms).toBeGreaterThanOrEqual(before + 9_500);
    expect(call[1].payload.expires_at_ms).toBeLessThanOrEqual(Date.now() + 10_500);

    // Trigger response
    const req_id = call[1].payload.request_id;
    onContextResponse({ request_id: req_id, data: { device: { battery: 0.5 } } });
    expect(await promise).toEqual({ data: { device: { battery: 0.5 } }, errors: {} });
  });

  it('rejects on timeout', async () => {
    const promise = requestContextTool.handler(
      { fields: ['device'], timeout_ms: 1000 }, ctx as any,
    );
    await new Promise(r => setTimeout(r, 1100));
    await expect(promise).rejects.toThrow('[device offline / timeout]');
  });

  it('late context_response after timeout is silently dropped', async () => {
    const promise = requestContextTool.handler(
      { fields: ['device'], timeout_ms: 200 }, ctx as any,
    );
    await new Promise(r => setTimeout(r, 250));
    await expect(promise).rejects.toThrow();
    const call = writeMessageOut.mock.calls[0];
    expect(() => onContextResponse({
      request_id: call[1].payload.request_id, data: { device: {} },
    })).not.toThrow();
  });
});
```

Run, expect FAIL.

- [ ] **Step 2: Implement (full code in spec Section "request_context MCP Tool")**

```ts
import { ContextFieldEnum, type ContextField } from '@shared/ios-app-protocol';
import { z } from 'zod';

const InputSchema = z.object({
  fields: z.array(ContextFieldEnum).min(1),
  params: z.object({
    health_days: z.number().int().min(1).max(30).optional(),
    calendar_window: z.enum(['today','next_7d','next_30d']).optional(),
    locations_hours: z.number().int().min(1).max(168).optional(),
  }).optional(),
  timeout_ms: z.number().int().min(1000).max(30000).optional(),
});

interface Entry { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout>; }
const pending = new Map<string, Entry>();

export interface ToolContext {
  session_id: string;
  writeMessageOut: (session_id: string, msg: { type: string; payload: Record<string, unknown> }) => Promise<void>;
}

export const requestContextTool = {
  name: 'request_context',
  description: 'Pull device context (location, health, calendar, etc.) from the user iOS device. Async — blocks until device replies or timeout.',
  inputSchema: InputSchema,
  handler: async (input: z.infer<typeof InputSchema>, ctx: ToolContext) => {
    const request_id = crypto.randomUUID();
    const timeout_ms = input.timeout_ms ?? 10000;
    const expires_at_ms = Date.now() + timeout_ms;
    await ctx.writeMessageOut(ctx.session_id, {
      type: 'context_request',
      payload: {
        request_id,
        fields: input.fields,
        params: input.params ?? {},
        expires_at_ms,
      },
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

export function onContextResponse(envelope: {
  request_id: string; data: Record<string, unknown>; errors?: Record<string, string>;
}): void {
  const entry = pending.get(envelope.request_id);
  if (!entry) return;
  clearTimeout(entry.timer);
  pending.delete(envelope.request_id);
  const errors = envelope.errors ?? {};
  const data = envelope.data ?? {};
  if (Object.keys(errors).length > 0 && Object.keys(data).length === 0) {
    entry.reject(new Error(`[context error: ${JSON.stringify(errors)}]`));
  } else {
    entry.resolve({ data, errors });
  }
}
```

- [ ] **Step 3: Run, expect PASS**

- [ ] **Step 4: Remove the old request_context handler from `core.ts`**

In `container/agent-runner/src/mcp-tools/core.ts`, find and delete the existing `request_context` tool definition (around `core.ts:289`). Replace any export reference with an import of `requestContextTool` from the new file.

- [ ] **Step 5: Verify agent-runner build**

```bash
cd container/agent-runner && pnpm exec tsc -p tsconfig.json --noEmit
```

- [ ] **Step 6: Commit**

```bash
git add container/agent-runner/src/mcp-tools/request_context.ts container/agent-runner/src/mcp-tools/request_context.test.ts container/agent-runner/src/mcp-tools/core.ts
git commit -m "agent-runner: async deferred request_context MCP tool"
```

---

### Task 3.3: Wire `onContextResponse` into the agent poll-loop

**Files:**
- Modify: `container/agent-runner/src/poll-loop.ts` (or equivalent file that reads `messages_in`)

- [ ] **Step 1: Locate the inbound dispatch in the poll-loop**

```bash
grep -n "messages_in" container/agent-runner/src/poll-loop.ts container/agent-runner/src/db/messages-in.ts
```

- [ ] **Step 2: Add discriminator handling**

Inside the loop that consumes `messages_in` rows, branch on `meta.kind`:

```ts
import { onContextResponse } from './mcp-tools/request_context';
import { formatIosInbound } from './channels/ios-app-format';

for (const row of pendingMessages) {
  const meta = row.meta ? JSON.parse(row.meta) : {};
  switch (meta.kind) {
    case 'context_response':
      onContextResponse({
        request_id: meta.request_id,
        data: meta.data ?? {},
        errors: meta.errors,
      });
      ackMessageIn(row.seq);
      continue;                        // do NOT add to conversation history
    case 'user_message': {
      const text = formatIosInbound(row.text, meta.ios_context);
      appendUserTurn(text, meta.attachments);
      ackMessageIn(row.seq);
      break;
    }
    case 'system':
      appendSystemNote(row.text);
      ackMessageIn(row.seq);
      break;
    default:
      // legacy / non-ios channels: existing behavior unchanged
      appendUserTurn(row.text, undefined);
      ackMessageIn(row.seq);
  }
}
```

- [ ] **Step 3: Add an integration-style test in `container/agent-runner/`**

A small test that inserts a row with `meta.kind=context_response` and asserts `onContextResponse` runs without adding a turn. Run `bun test`.

- [ ] **Step 4: Commit**

```bash
git add container/agent-runner/src/poll-loop.ts container/agent-runner/src/poll-loop.test.ts
git commit -m "agent-runner: dispatch ios meta.kind in poll-loop (context_response, user_message, system)"
```

---


## Phase 4 — iOS app: protocol mirror, ConversationStore, Transport

### Task 4.1: Add GRDB dependency

**Files:**
- Modify: `ios/JarvisApp/Package.swift`

- [ ] **Step 1: Add the package dependency**

In `Package.swift`, under `dependencies`:
```swift
.package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
```

In target dependencies for `JarvisApp`:
```swift
.product(name: "GRDB", package: "GRDB.swift"),
```

- [ ] **Step 2: Resolve packages**

```bash
cd ios/JarvisApp && swift package resolve
```

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Package.swift ios/JarvisApp/Package.resolved
git commit -m "ios: add GRDB dependency for local SQLite store"
```

---

### Task 4.2: `V2.swift` — Codable mirror of canonical schemas

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`

- [ ] **Step 1: Write the Codable mirror**

```swift
import Foundation

enum V2 {
    static let protocolVersion = 2

    struct Envelope: Codable, Equatable {
        let v: Int
        let kind: Kind
        let type: String
        let id: String
        let seq: Int?
        let ts: String
        let payload: Payload

        enum Kind: String, Codable { case data, control, ack, status }
    }

    enum Payload: Codable, Equatable {
        case auth(Auth)
        case authOk(AuthOk)
        case authFail(AuthFail)
        case message(Message)
        case contextRequest(ContextRequest)
        case contextResponse(ContextResponse)
        case newConversation(NewConversation)
        case actionResponse(ActionResponse)
        case feedback(Feedback)
        case ack(Ack)
        case ping(Ping)
        case pong(Pong)
        case statusBatch(StatusBatch)

        // Custom encode/decode that ignores discriminator at this layer —
        // the discriminator lives in the parent Envelope.type field. Decoding
        // is driven by a helper that takes (envelope.type, payload-data).
    }

    struct Auth: Codable, Equatable {
        let token: String
        let last_seen_inbound_seq: Int
        let capabilities: [String]
    }
    struct AuthOk: Codable, Equatable {
        let last_seen_outbound_seq: Int
        let server_time: String
    }
    struct AuthFail: Codable, Equatable { let reason: String }
    struct Message: Codable, Equatable {
        let thread_id: String
        let text: String
        let attachments: [Attachment]?
        let context: InlineContext?
    }
    struct Attachment: Codable, Equatable {
        let id: String
        let kind: String          // "image" | "file"
        let name: String
        let mime_type: String
        let byte_size: Int
        let bytes_base64: String?
        let remote_id: String?
    }
    struct InlineContext: Codable, Equatable {
        struct Location: Codable, Equatable { let lat: Double; let lon: Double; let accuracy: Double? }
        let location: Location?
        let timestamp: String
        let timezone: String
        let locality: String?
    }
    struct ContextRequest: Codable, Equatable {
        let request_id: String
        let fields: [String]
        let params: [String: AnyCodable]?
    }
    struct ContextResponse: Codable, Equatable {
        let request_id: String
        let data: [String: AnyCodable]
        let errors: [String: String]?
    }
    struct NewConversation: Codable, Equatable { let thread_id: String }
    struct ActionResponse: Codable, Equatable { let action_id: String; let choice: String }
    struct Feedback: Codable, Equatable {
        let message_id: String
        let kind: String           // "up" | "down"
    }
    struct Ack: Codable, Equatable { let id: String; let seq: Int }
    struct Ping: Codable, Equatable { let nonce: String }
    typealias Pong = Ping
    struct StatusBatch: Codable, Equatable { let ids: [String] }

    // Type-erased Codable wrapper for context data/params.
    struct AnyCodable: Codable, Equatable {
        let raw: Data
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            // Try to extract the encoded JSON as raw bytes by re-encoding via a
            // JSONSerialization round-trip — preserves any JSON shape.
            let value = try c.decode(JSONValue.self)
            raw = try JSONEncoder().encode(value)
        }
        func encode(to encoder: Encoder) throws {
            let value = try JSONDecoder().decode(JSONValue.self, from: raw)
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }

    indirect enum JSONValue: Codable, Equatable {
        case string(String); case int(Int); case double(Double); case bool(Bool); case null
        case array([JSONValue]); case object([String: JSONValue])
        // Implementation: standard "anyCodable"-style decoder. Use a known library if preferred.
    }
}

// Helper: decode a full envelope from raw bytes by reading `type` first.
extension V2.Envelope {
    static func decode(from data: Data) throws -> V2.Envelope {
        struct Header: Codable { let type: String }
        let header = try JSONDecoder().decode(Header.self, from: data)
        // Implement a single-shot decoder that branches on `header.type`
        // and parses `payload` into the matching V2.Payload case.
        // (Pattern: decode the whole envelope into a wrapper that includes a
        // typed `payload` per case.)
        fatalError("implement in step 2")
    }
}
```

(The `JSONValue` and `AnyCodable` helpers are 60-80 lines of straightforward Codable plumbing — implement using the standard pattern. The envelope decoder branches on `type`.)

- [ ] **Step 2: Implement the envelope decoder + JSONValue helpers**

Full file: standard Codable plumbing. Pattern: write `V2.Envelope.decode(from:)` that does `JSONDecoder().decode(EnvelopeWithUntypedPayload.self, from: data)` then maps `type` → the correct typed payload via the relevant subdecoder.

- [ ] **Step 3: Write `ProtocolFixtureTests.swift`**

```swift
import XCTest
@testable import JarvisApp

final class ProtocolFixtureTests: XCTestCase {
    func testAllFixturesRoundTrip() throws {
        let fixturesURL = URL(fileURLWithPath: "../../shared/ios-app-protocol/fixtures",
                              relativeTo: URL(fileURLWithPath: #filePath))
        let urls = try FileManager.default.contentsOfDirectory(at: fixturesURL,
                                                               includingPropertiesForKeys: nil)
        let jsons = urls.filter { $0.pathExtension == "json" }
        XCTAssertEqual(jsons.count, 16, "fixture count mismatch with TS side")
        for url in jsons {
            let data = try Data(contentsOf: url)
            let env = try V2.Envelope.decode(from: data)
            let re = try JSONEncoder().encode(env)
            let reDecoded = try V2.Envelope.decode(from: re)
            XCTAssertEqual(env, reDecoded, "\(url.lastPathComponent) round-trip mismatch")
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd ios/JarvisApp && swift test --filter ProtocolFixtureTests
```

Or via XcodeBuildMCP `test_sim` if simulator-only.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift
git commit -m "ios: V2 Codable mirror + contract test against shared fixtures"
```

---

### Task 4.3: `Schema.swift` + `ConversationStore.swift` — GRDB-backed local store

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStore.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import GRDB
@testable import JarvisApp

final class ConversationStoreTests: XCTestCase {
    var store: ConversationStore!

    override func setUp() async throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStore(writer: dbq)
    }

    func testInsertAndQueryByStatus() throws {
        try store.insertOutboundUserMessage(
            conversationId: "thr-1", id: UUID().uuidString,
            text: "hi", attachments: [], context: nil,
        )
        let pending = try store.queuedOutbound()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].status, .queued)
        XCTAssertNil(pending[0].seq)
    }

    func testAllocateSeqIsMonotonic() throws {
        XCTAssertEqual(try store.allocateNextSendSeq(), 1)
        XCTAssertEqual(try store.allocateNextSendSeq(), 2)
        XCTAssertEqual(try store.allocateNextSendSeq(), 3)
    }

    func testCursorReadWriteAtomic() throws {
        try store.setCursor(.lastSeenInbound, 42)
        XCTAssertEqual(try store.cursor(.lastSeenInbound), 42)
        try store.setCursor(.lastSeenInbound, 50)
        XCTAssertEqual(try store.cursor(.lastSeenInbound), 50)
    }
}
```

Run, expect FAIL.

- [ ] **Step 2: Implement `Schema.swift`**

```swift
import GRDB
import Foundation

enum Schema {
    static func migrate(_ writer: DatabaseWriter) throws {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
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
                  context_json TEXT,
                  status TEXT NOT NULL,
                  failure_reason TEXT,
                  ts INTEGER NOT NULL,
                  server_ts INTEGER,
                  created_at INTEGER NOT NULL
                );
                CREATE INDEX idx_msg_conv_ts ON messages (conversation_id, ts);
                CREATE INDEX idx_msg_status ON messages (status);
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
            """)
        }
        try m.migrate(writer)
    }
}
```

- [ ] **Step 3: Implement `ConversationStore.swift`**

Cover at minimum these methods (signatures shown — bodies are straightforward GRDB calls):

```swift
import GRDB
import Foundation

enum MessageDir: String { case out, in_ = "in" }
enum MessageStatus: String { case queued, sending, sent, delivered, read, failed, new }
enum CursorKey: String { case lastSeenInbound = "last_seen_inbound_seq", lastSentOutbound = "last_sent_outbound_seq" }

struct StoredMessage: FetchableRecord, PersistableRecord, Equatable {
    var id: String
    var conversationId: String
    var dir: MessageDir
    var seq: Int?
    var text: String
    var attachmentsJSON: String?
    var contextJSON: String?
    var status: MessageStatus
    var failureReason: String?
    var ts: Int
    var serverTS: Int?
    var createdAt: Int
}

final class ConversationStore {
    private let writer: DatabaseWriter
    init(writer: DatabaseWriter) { self.writer = writer }

    func insertOutboundUserMessage(conversationId: String, id: String, text: String,
                                   attachments: [V2.Attachment], context: V2.InlineContext?) throws { /* ... */ }
    func queuedOutbound(limit: Int = 10) throws -> [StoredMessage] { /* ... */ }
    func markSending(id: String, seq: Int) throws { /* ... */ }
    func markSent(id: String, serverTS: Int) throws { /* ... */ }
    func markFailed(id: String, reason: String) throws { /* ... */ }
    func markDelivered(ids: [String]) throws { /* ... */ }
    func markRead(ids: [String]) throws { /* ... */ }
    func resetSendingToQueued(maxSeq: Int) throws { /* updates dir=out AND status=sending AND seq>maxSeq */ }
    func confirmAckedUpTo(maxSeq: Int) throws { /* dir=out AND status=sending AND seq<=maxSeq → sent */ }

    func insertInbound(envelope: V2.Envelope, message: V2.Message) throws { /* ... */ }
    func dedupSeen(id: String) throws -> Bool { /* ... */ }
    func recordDedup(id: String, seq: Int) throws { /* ... */ }

    func cursor(_ k: CursorKey) throws -> Int { /* ... */ }
    func setCursor(_ k: CursorKey, _ v: Int) throws { /* ... */ }
    func allocateNextSendSeq() throws -> Int { /* atomic: cursor+1 */ }
}
```

- [ ] **Step 4: Run tests, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/ ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreTests.swift
git commit -m "ios: ConversationStore + Schema migration (GRDB)"
```

---

### Task 4.4: `Status.swift` + `Transport.swift` — the new transport

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/Status.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/Transport.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/TransportTests.swift`

- [ ] **Step 1: Write failing test for the state machine**

```swift
import XCTest
@testable import JarvisApp

final class TransportTests: XCTestCase {
    var store: ConversationStore!
    var transport: Transport!
    var socket: MockWebSocket!

    override func setUp() async throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStore(writer: dbq)
        socket = MockWebSocket()
        transport = Transport(store: store, socket: socket, token: "tok")
    }

    func testSendQueuedMessageGoesSending() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi",
            attachments: [], context: nil,
        )
        try await transport.connect()
        try await transport.tickDispatcher()
        let row = try XCTUnwrap(try store.fetchById("msg-1"))
        XCTAssertEqual(row.status, .sending)
        XCTAssertNotNil(row.seq)
    }

    func testAckMovesSendingToSent() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi",
            attachments: [], context: nil,
        )
        try await transport.connect()
        try await transport.tickDispatcher()
        try await transport.handleIncoming(makeAckEnvelope(for: "msg-1"))
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .sent)
    }

    func testRetryAfterAckTimeout() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi",
            attachments: [], context: nil,
        )
        try await transport.connect()
        try await transport.tickDispatcher()
        let firstSend = socket.sent.count
        await transport.fastForwardAckTimer(by: 5_500)
        XCTAssertGreaterThan(socket.sent.count, firstSend)        // retransmitted
    }

    func testReconnectResetsSendingToQueued() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi",
            attachments: [], context: nil,
        )
        try await transport.connect()
        try await transport.tickDispatcher()                       // → sending
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .queued)
    }

    func testInboundDedupByID() async throws {
        let env = makeInboundMessage(id: "in-1", seq: 1, text: "hello")
        try await transport.handleIncoming(env)
        try await transport.handleIncoming(env)                    // duplicate
        XCTAssertEqual(try store.countInboundMessages(conversationId: env.threadID), 1)
    }
}
```

(`MockWebSocket` is a small `protocol WebSocketLike { func send(...); var onMessage: ((Data) -> Void)? { get set } ... }` substitute.)

Run, expect FAIL.

- [ ] **Step 2: Implement `Status.swift` + `Transport.swift`**

Refer to the spec Section "iOS App Internals → Transport" for full behavior. Sketch:

```swift
import Foundation

actor Transport {
    // dependencies + state...
    private let store: ConversationStore
    private let socket: WebSocketLike
    private var ackTimers: [String: Task<Void, Never>] = [:]
    private let token: String

    init(store: ConversationStore, socket: WebSocketLike, token: String) { ... }

    func connect() async throws {
        try await socket.connect()
        let lsi = try store.cursor(.lastSeenInbound)
        try await send(envelope: makeAuth(token: token, lastSeenInbound: lsi))
        // expect auth_ok then drain queue continues
    }

    func tickDispatcher() async throws {
        for row in try store.queuedOutbound(limit: 10) {
            let seq = try store.allocateNextSendSeq()
            try store.markSending(id: row.id, seq: seq)
            let env = makeMessageEnvelope(row: row, seq: seq)
            try await socket.send(JSONEncoder().encode(env))
            scheduleAckTimer(id: row.id)
        }
    }

    func handleIncoming(_ data: Data) async throws {
        let env = try V2.Envelope.decode(from: data)
        switch env.payloadCase {
        case .ack(let a):
            cancelAckTimer(id: a.id)
            try store.markSent(id: a.id, serverTS: Int(parseTS(env.ts)))
        case .authOk(let ok):
            try store.confirmAckedUpTo(maxSeq: ok.last_seen_outbound_seq)
            try store.resetSendingToQueued(maxSeq: ok.last_seen_outbound_seq)
            // continue draining
            try await tickDispatcher()
        case .message(let m):
            try await routeInboundMessage(envelope: env, message: m)
        case .contextRequest(let r):
            await gatherAndReply(requestID: r.request_id, fields: r.fields, params: r.params)
        case .statusBatch(let s) where env.type == "delivered":
            try store.markDelivered(ids: s.ids)
        case .statusBatch(let s) where env.type == "read":
            try store.markRead(ids: s.ids)
        case .ping(let p):
            // not expected from server; ignore
            _ = p
        case .pong:
            break
        // remaining cases per spec
        }
    }

    private func routeInboundMessage(envelope: V2.Envelope, message: V2.Message) async throws {
        if try store.dedupSeen(id: envelope.id) { try await sendAck(id: envelope.id, seq: envelope.seq ?? 0); return }
        try store.recordDedup(id: envelope.id, seq: envelope.seq ?? 0)
        try store.insertInbound(envelope: envelope, message: message)
        try await sendAck(id: envelope.id, seq: envelope.seq ?? 0)
        try await sendStatus(.delivered, ids: [envelope.id])
        if let seq = envelope.seq { try store.setCursor(.lastSeenInbound, max(seq, try store.cursor(.lastSeenInbound))) }
    }

    private func scheduleAckTimer(id: String) {
        ackTimers[id]?.cancel()
        ackTimers[id] = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            try? await self.retransmit(id: id)
        }
    }
    // ... rest of behavior per spec
}
```

- [ ] **Step 3: Run tests, expect PASS**

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/Status.swift ios/JarvisApp/Sources/JarvisApp/Services/Transport.swift ios/JarvisApp/Sources/JarvisAppTests/TransportTests.swift
git commit -m "ios: Transport actor with state machine, ack timer, reconnect replay"
```

---

### Task 4.5: `InboundDispatcher.swift` — handle `context_request` field gathering

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcher.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/InboundDispatchTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import JarvisApp

final class InboundDispatchTests: XCTestCase {
    func testContextRequestProducesResponseWithRequestedFields() async throws {
        let coord = MockCoordinator(
            health: { ["steps": 4123] }, calendar: { [["title": "Standup"]] },
            device: { ["battery": 0.5] }, location: { ["lat": 1, "lon": 2] }
        )
        let dispatcher = InboundDispatcher(coordinator: coord)
        let response = try await dispatcher.gather(
            requestID: "r-1", fields: ["health", "device"], params: nil,
        )
        XCTAssertEqual(response.request_id, "r-1")
        XCTAssertNotNil(response.data["health"])
        XCTAssertNotNil(response.data["device"])
        XCTAssertNil(response.data["calendar"])
        XCTAssertNil(response.errors)
    }

    func testFieldErrorsReportedSeparately() async throws {
        let coord = MockCoordinator(
            health: { throw FieldError.denied },
            calendar: { [] }, device: { ["battery": 0.5] }, location: { nil },
        )
        let dispatcher = InboundDispatcher(coordinator: coord)
        let response = try await dispatcher.gather(
            requestID: "r-2", fields: ["health", "device"], params: nil,
        )
        XCTAssertNil(response.data["health"])
        XCTAssertEqual(response.errors?["health"], "denied")
        XCTAssertNotNil(response.data["device"])
    }
}
```

Run, expect FAIL.

- [ ] **Step 2: Implement `InboundDispatcher.swift`**

```swift
import Foundation

protocol ContextCoordinator {
    func health() async throws -> [String: Any]
    func calendar() async throws -> [[String: Any]]
    func device() async throws -> [String: Any]
    func location() async throws -> [String: Any]?
    func nextEvent() async throws -> [String: Any]?
    func recentLocations(hours: Int) async throws -> [[String: Any]]
    func screenState() async throws -> String
}

enum FieldError: Error, CustomStringConvertible {
    case denied, unsupported, failed(String)
    var description: String {
        switch self {
        case .denied: return "denied"
        case .unsupported: return "unsupported"
        case .failed(let s): return s
        }
    }
}

actor InboundDispatcher {
    private let coordinator: ContextCoordinator
    init(coordinator: ContextCoordinator) { self.coordinator = coordinator }

    func gather(requestID: String, fields: [String], params: [String: V2.AnyCodable]?) async throws -> V2.ContextResponse {
        var data: [String: Any] = [:]
        var errors: [String: String] = [:]
        await withTaskGroup(of: (String, Result<Any?, Error>).self) { group in
            for f in fields {
                group.addTask { (f, await Self.collect(f, coordinator: self.coordinator, params: params)) }
            }
            for await (f, r) in group {
                switch r {
                case .success(let v?): data[f] = v
                case .success(nil): continue
                case .failure(let e): errors[f] = "\(e)"
                }
            }
        }
        let dataAny: [String: V2.AnyCodable] = try data.mapValues { try V2.AnyCodable(any: $0) }
        return V2.ContextResponse(request_id: requestID, data: dataAny,
                                  errors: errors.isEmpty ? nil : errors)
    }

    private static func collect(_ field: String, coordinator: ContextCoordinator,
                                params: [String: V2.AnyCodable]?) async -> Result<Any?, Error> {
        do {
            switch field {
            case "health": return .success(try await coordinator.health())
            case "calendar": return .success(try await coordinator.calendar())
            case "device": return .success(try await coordinator.device())
            case "next_event": return .success(try await coordinator.nextEvent())
            case "recent_locations":
                let hours = params?["locations_hours"]?.intValue ?? 12
                return .success(try await coordinator.recentLocations(hours: hours))
            case "screen_state": return .success(try await coordinator.screenState())
            default: return .failure(FieldError.unsupported)
            }
        } catch { return .failure(error) }
    }
}
```

- [ ] **Step 3: Run, expect PASS**

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcher.swift ios/JarvisApp/Sources/JarvisAppTests/InboundDispatchTests.swift
git commit -m "ios: InboundDispatcher gathers context fields with per-field errors"
```

---

### Task 4.6: `MigrationV2.swift` — one-shot import from legacy JSON stores

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/MigrationV2.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/MigrationTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import JarvisApp

final class MigrationTests: XCTestCase {
    func testImportsOutboxAndCache() throws {
        let tmp = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: URL(fileURLWithPath: "/tmp"), create: true)
        // Write legacy outbox + cache files
        let outboxDir = tmp.appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        try """
        [{"id":"m1","conversationId":"thr-1","text":"hi","status":"sent","ts":1717000000}]
        """.write(to: outboxDir.appendingPathComponent("queue.json"), atomically: true, encoding: .utf8)
        let cacheDir = tmp.appendingPathComponent("MessageCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try """
        [{"id":"in-1","conversationId":"thr-1","text":"reply","dir":"in","ts":1717000010}]
        """.write(to: cacheDir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)

        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStore(writer: dbq)
        try MigrationV2.runIfNeeded(documentsURL: tmp, store: store)

        XCTAssertEqual(try store.countAllMessages(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboxDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path))
    }

    func testNoLegacyFilesIsANoop() throws {
        let tmp = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: URL(fileURLWithPath: "/tmp"), create: true)
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStore(writer: dbq)
        try MigrationV2.runIfNeeded(documentsURL: tmp, store: store)
        XCTAssertEqual(try store.countAllMessages(), 0)
    }
}
```

Run, expect FAIL.

- [ ] **Step 2: Implement**

```swift
import Foundation

enum MigrationV2 {
    static func runIfNeeded(documentsURL: URL, store: ConversationStore) throws {
        let outbox = documentsURL.appendingPathComponent("Outbox/queue.json")
        let cache = documentsURL.appendingPathComponent("MessageCache/index.json")

        if FileManager.default.fileExists(atPath: outbox.path) {
            try importOutbox(url: outbox, store: store)
            try? FileManager.default.removeItem(at: outbox.deletingLastPathComponent())
        }
        if FileManager.default.fileExists(atPath: cache.path) {
            try importCache(url: cache, store: store)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        }
    }

    private struct LegacyEntry: Codable {
        let id: String
        let conversationId: String
        let text: String
        let status: String?
        let dir: String?
        let ts: Int
    }

    private static func importOutbox(url: URL, store: ConversationStore) throws {
        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([LegacyEntry].self, from: data)
        for e in entries {
            try store.insertOutboundUserMessage(
                conversationId: e.conversationId, id: e.id, text: e.text,
                attachments: [], context: nil,
            )
            try store.markSentRaw(id: e.id, ts: e.ts)        // helper for migration
        }
    }

    private static func importCache(url: URL, store: ConversationStore) throws {
        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([LegacyEntry].self, from: data)
        for e in entries {
            try store.insertInboundMessage(
                id: e.id, conversationId: e.conversationId, text: e.text,
                ts: e.ts, status: .new,
            )
        }
    }
}
```

- [ ] **Step 3: Run, expect PASS**

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/MigrationV2.swift ios/JarvisApp/Sources/JarvisAppTests/MigrationTests.swift
git commit -m "ios: one-shot migration from legacy OutboxStore + MessageCache → SQLite"
```

---


## Phase 5 — iOS + adapter cleanup

### Task 5.1: Remove iOS video attachment stack

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/DraftAttachment.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/CameraPicker.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/AttachmentBar.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift`
- Delete: `ios/JarvisApp/Sources/JarvisAppTests/DraftAttachmentVideoTests.swift`

- [ ] **Step 1: `DraftAttachment.swift` — drop video parts**

In `DraftAttachment.swift`:
- Remove `case video` from `enum Kind`.
- Remove `enum VideoError`.
- Remove `static let maxVideoBytes`.
- Remove `static func checkVideoSize`.
- Remove both `static func video(...)` factories.
- Remove `thumbnail` and `duration` fields if they are exclusively for video.

- [ ] **Step 2: `CameraPicker.swift` — drop movie capture**

- Remove `case video(URL)` from the callback enum.
- Change `picker.mediaTypes` to `["public.image"]`.
- Remove `videoMaximumDuration`, `videoQuality`.
- In `imagePickerController(...didFinishPickingMediaWithInfo:)`, drop the `public.movie` branch.

- [ ] **Step 3: `AttachmentBar.swift` — drop PhotosPicker videos + VideoTransferable**

- In `PhotosPicker(... matching: .any(of: [.images, .videos]))`, change to `.images` only.
- Drop the `.video(url)` branch in the camera callback.
- Drop `VideoTransferable` (the trailing struct in the file).
- Drop `surfaceVideoError`.
- Drop the `VideoTransferable`-based loadTransferable branch in the picker handler.

- [ ] **Step 4: `MessageRow.swift` — drop video icon branch**

At `MessageRow.swift:269`, remove the `if mime.hasPrefix("video/") { return "play.rectangle" }` branch.

- [ ] **Step 5: Delete the video test**

```bash
git rm ios/JarvisApp/Sources/JarvisAppTests/DraftAttachmentVideoTests.swift
```

- [ ] **Step 6: Build + run all iOS tests, expect green**

```bash
cd ios/JarvisApp && swift test
```

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/DraftAttachment.swift ios/JarvisApp/Sources/JarvisApp/Components/CameraPicker.swift ios/JarvisApp/Sources/JarvisApp/Components/AttachmentBar.swift ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift
git commit -m "ios: drop video attachment support (images + files only)"
```

---

### Task 5.2: Remove legacy iOS services

**Files:**
- Delete: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`
- Delete: `ios/JarvisApp/Sources/JarvisApp/Services/WSTransport.swift`
- Delete: `ios/JarvisApp/Sources/JarvisApp/Services/InboundRouter.swift`
- Delete: `ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift`
- Delete: `ios/JarvisApp/Sources/JarvisApp/Services/MessageCache.swift`
- Delete: `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift`
- Delete: `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientBusyTests.swift`
- Delete: `ios/JarvisApp/Sources/JarvisAppTests/DeliveryChecksTests.swift`
- Modify: any UI/coordinator code that referenced the removed types

- [ ] **Step 1: Identify call sites of removed services**

```bash
grep -rn "WebSocketClient\|WSTransport\|InboundRouter\|OutboxStore\|MessageCache" ios/JarvisApp/Sources/JarvisApp/
```

- [ ] **Step 2: Rewire callers to `Transport` + `ConversationStore`**

For each call site, replace:
- `WebSocketClient.send(...)` → `Transport.enqueueUserMessage(...)`
- `WebSocketClient.connect(...)` → `Transport.connect()`
- `MessageCache.load(...)` → `ConversationStore.fetchConversation(...)`
- `OutboxStore.entries` → `ConversationStore.queuedOutbound(...)`
- `InboundRouter.dispatch(...)` → handled internally by `Transport.handleIncoming(...)`

- [ ] **Step 3: Delete the files**

```bash
git rm ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift
git rm ios/JarvisApp/Sources/JarvisApp/Services/WSTransport.swift
git rm ios/JarvisApp/Sources/JarvisApp/Services/InboundRouter.swift
git rm ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift
git rm ios/JarvisApp/Sources/JarvisApp/Services/MessageCache.swift
git rm ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift
git rm ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientBusyTests.swift
git rm ios/JarvisApp/Sources/JarvisAppTests/DeliveryChecksTests.swift
```

- [ ] **Step 4: Build + test, expect green**

```bash
cd ios/JarvisApp && swift test
```

- [ ] **Step 5: Commit**

```bash
git commit -m "ios: remove legacy WebSocketClient + Outbox + MessageCache (replaced by Transport + ConversationStore)"
```

---

### Task 5.3: Remove APNs registration from iOS

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` (AppDelegate)
- Audit: any other APNs-touching code

- [ ] **Step 1: Find APNs surface**

```bash
grep -rn "registerForRemoteNotifications\|UNUserNotificationCenter\|apnsToken\|registerApnsToken" ios/JarvisApp/Sources/
```

- [ ] **Step 2: Remove**

- Drop `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
- Drop `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
- Drop the `UIApplication.shared.registerForRemoteNotifications()` call.
- Drop the `apnsToken` envelope send.
- Remove the `UNUserNotificationCenter.current().requestAuthorization` call (unless used for local notifications elsewhere — if so, leave that part).
- Remove `aps-environment` from the `JarvisApp.entitlements` file if present.

- [ ] **Step 3: Build, run iOS tests, expect green**

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/
git commit -m "ios: remove APNs registration (server-side queue replaces push wakeups)"
```

---

### Task 5.4: Remove legacy adapter (`src/channels/ios-app.ts`) + tests

**Files:**
- Delete: `src/channels/ios-app.ts`
- Delete: `src/channels/ios-app.context.test.ts`
- Delete: `src/channels/ios-app.dedup.test.ts`
- Delete: `src/channels/ios-app.message-ack.test.ts`
- Delete: `src/channels/ios-app.proactive.test.ts`
- Delete: `src/channels/ios-app.video-attachment.test.ts`
- Delete: `src/channels/ios-app.ws.test.ts`
- Delete: `src/channels/ios-read-receipts.ts`
- Delete: `src/channels/ios-read-receipts.test.ts`

- [ ] **Step 1: Remove the registration import from `src/channels/index.ts`** (or leave temporarily — Phase 7 wires v2 in)

If `src/channels/index.ts` has a `import './ios-app.js'` or similar, remove the line. The v2 import is added in Phase 7.

- [ ] **Step 2: Delete the files**

```bash
git rm src/channels/ios-app.ts \
       src/channels/ios-app.context.test.ts \
       src/channels/ios-app.dedup.test.ts \
       src/channels/ios-app.message-ack.test.ts \
       src/channels/ios-app.proactive.test.ts \
       src/channels/ios-app.video-attachment.test.ts \
       src/channels/ios-app.ws.test.ts \
       src/channels/ios-read-receipts.ts \
       src/channels/ios-read-receipts.test.ts
```

- [ ] **Step 3: Verify build + tests still green**

```bash
pnpm exec tsc --noEmit && pnpm test
```

- [ ] **Step 4: Commit**

```bash
git add src/channels/index.ts
git commit -m "channels: delete legacy ios-app adapter + read-receipts (v2 lands in Phase 7)"
```

---


## Phase 6 — Integration + E2E tests

### Task 6.1: Test harness in `src/channels/ios-app/v2/testing/`

**Files:**
- Create: `src/channels/ios-app/v2/testing/harness.ts`

- [ ] **Step 1: Implement the harness**

```ts
import http from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import { openTransportDb } from '../transport-db.js';
import { OutboundQueue } from '../outbound-queue.js';
import { ReceiptStore } from '../receipt-store.js';
import { InboundDispatcher } from '../inbound-dispatch.js';
import { ContextBridge } from '../context-bridge.js';
import { WsHandler } from '../ws-handler.js';

export interface Harness {
  url: string;
  validToken: string;
  platformId: string;
  db: ReturnType<typeof openTransportDb>;
  queue: OutboundQueue;
  agent: {
    submit: (payload: unknown) => void;     // act as agent writing to outbound.db
    received: unknown[];                     // what agent saw on inbound.db
  };
  close(): Promise<void>;
  expectIncoming(ws: WebSocket): Promise<any>;
  send(ws: WebSocket, env: unknown): Promise<void>;
  connectAuthed(): Promise<WebSocket>;
}

export async function startTestServer(): Promise<Harness> { /* ... wires components ... */ }
```

- [ ] **Step 2: Smoke-test the harness from `transport-db.test.ts` style**

Add a 1-test sanity check in `harness.test.ts`:
```ts
it('boots and accepts auth', async () => {
  const h = await startTestServer();
  const ws = await h.connectAuthed();
  ws.close();
  await h.close();
});
```

- [ ] **Step 3: Commit**

```bash
git add src/channels/ios-app/v2/testing/harness.ts src/channels/ios-app/v2/testing/harness.test.ts
git commit -m "channels/ios-app/v2: integration test harness"
```

---

### Task 6.2: Integration scenarios

**Files:**
- Create: `src/channels/ios-app/v2/integration.test.ts`

For each scenario in spec Section "Tests → Layer 3 — Integration Test", write a discrete `it()` block. Pattern (shown for scenario 2):

- [ ] **Step 1: Write all 11 scenarios**

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { WebSocket } from 'ws';
import { startTestServer, type Harness } from './testing/harness';

let h: Harness;
beforeEach(async () => { h = await startTestServer(); });
afterEach(async () => { await h.close(); });

describe('Scenario 1: happy path', () => {
  it('round-trip user message and agent reply', async () => { /* ... */ });
});

describe('Scenario 2: reconnect mid-send', () => {
  it('client re-sends seq=5 with same id after reconnect', async () => {
    const ws1 = await h.connectAuthed();
    const id = '11111111-1111-4111-8111-111111111111';
    await h.send(ws1, makeMessage({ id, seq: 5 }));
    // ack intentionally not awaited — drop socket before consumption
    ws1.terminate();
    const ws2 = await h.reconnectAuthed({ lastSeenInbound: 4 });
    await h.send(ws2, makeMessage({ id, seq: 5 }));
    const ack = await h.expectIncoming(ws2);
    expect(ack.type).toBe('ack');
    expect(h.agent.received.filter((m: any) => m.id === id)).toHaveLength(1);
  });
});

describe('Scenario 3: reconnect mid-receive', () => { /* ... */ });
describe('Scenario 4: dedup by id', () => { /* ... */ });
describe('Scenario 5: queue overflow drops oldest', () => { /* ... */ });
describe('Scenario 6: context_request happy path', () => { /* ... */ });
describe('Scenario 7: context_request timeout', () => { /* ... */ });
describe('Scenario 8: per-session scope reject', () => { /* ... */ });
describe('Scenario 9: protocol violation closes socket', () => { /* ... */ });
describe('Scenario 10: superseded socket', () => { /* ... */ });
describe('Scenario 11: ping isolation under load', () => { /* ... */ });
```

(Each `/* ... */` body uses harness helpers to simulate the steps from the spec. Implementations are mechanical given the harness.)

- [ ] **Step 2: Run all scenarios**

```bash
pnpm exec vitest run src/channels/ios-app/v2/integration.test.ts
```

- [ ] **Step 3: Commit**

```bash
git add src/channels/ios-app/v2/integration.test.ts
git commit -m "channels/ios-app/v2: 11 integration scenarios covering all transport invariants"
```

---

### Task 6.3: E2E harness binary for iOS Simulator

**Files:**
- Create: `scripts/e2e-harness.ts`

- [ ] **Step 1: Implement a thin Node WS server that takes scripted scenarios**

```ts
// scripts/e2e-harness.ts
import { WebSocketServer, WebSocket } from 'ws';
import { AnyEnvelope } from '@shared/ios-app-protocol';

const port = Number(process.env.E2E_PORT ?? 8801);
const scenario = process.env.E2E_SCENARIO ?? 'happy';

const wss = new WebSocketServer({ port });
wss.on('connection', ws => {
  ws.on('message', raw => handle(ws, raw.toString()));
});

function handle(ws: WebSocket, raw: string) {
  const env = AnyEnvelope.parse(JSON.parse(raw));
  switch (scenario) {
    case 'happy': return runHappy(ws, env);
    case 'offline_queue': return runOfflineQueue(ws, env);
    case 'context': return runContext(ws, env);
    case 'reconnect': return runReconnect(ws, env);
    case 'restart': return runRestart(ws, env);
  }
}
// ... per-scenario functions

console.error(`E2E harness listening on ws://localhost:${port} scenario=${scenario}`);
```

- [ ] **Step 2: Add npm script**

In root `package.json` scripts:
```json
"e2e:harness": "tsx scripts/e2e-harness.ts"
```

- [ ] **Step 3: Commit**

```bash
git add scripts/e2e-harness.ts package.json
git commit -m "scripts: e2e harness for iOS simulator scenarios"
```

---

### Task 6.4: E2E XCTest tests on simulator

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisAppTests/E2E/E2EHarness.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/E2E/CheckmarksE2ETests.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/E2E/OfflineQueueE2ETests.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/E2E/ContextRequestE2ETests.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/E2E/ReconnectE2ETests.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/E2E/RestartE2ETests.swift`

- [ ] **Step 1: Implement `E2EHarness.swift`**

```swift
import XCTest

final class E2EHarness {
    private var task: Process?
    static let port = 8801

    func start(scenario: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["pnpm", "run", "e2e:harness"]
        var env = ProcessInfo.processInfo.environment
        env["E2E_PORT"] = String(Self.port)
        env["E2E_SCENARIO"] = scenario
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: "/Users/serg/git/nanoclaw")
        try p.run()
        self.task = p
        Thread.sleep(forTimeInterval: 1)              // small warm-up
    }

    func stop() {
        task?.terminate()
        task = nil
    }
}
```

- [ ] **Step 2: One test file per scenario**

`CheckmarksE2ETests.swift`:
```swift
import XCTest

final class CheckmarksE2ETests: XCTestCase {
    let harness = E2EHarness()
    override func setUp() async throws { try harness.start(scenario: "happy") }
    override func tearDown() async throws { harness.stop() }

    func testColdStartSendAndReceive() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["JARVIS_WS_URL"] = "ws://localhost:8801"
        app.launch()

        let input = app.textFields["chat-input"]
        input.tap(); input.typeText("hi")
        app.buttons["send"].tap()

        // outbound: see single checkmark
        XCTAssertTrue(app.images["status-sent-msg-1"].waitForExistence(timeout: 5))

        // harness echoed back; see inbound message in list, eventually marked read after view tap
        let inbound = app.cells["incoming-from-agent"].firstMatch
        XCTAssertTrue(inbound.waitForExistence(timeout: 5))
        inbound.tap()
        XCTAssertTrue(app.images["status-read-inbound"].waitForExistence(timeout: 5))
    }
}
```

`OfflineQueueE2ETests.swift`, `ContextRequestE2ETests.swift`, `ReconnectE2ETests.swift`, `RestartE2ETests.swift` follow the same pattern. Bodies mirror the corresponding bullet in spec Section "Tests → Layer 4 — E2E iOS Simulator".

- [ ] **Step 3: Run with XcodeBuildMCP**

```bash
# Via Bash tool — xcodebuild driver
xcrun simctl boot "iPhone 15" || true
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisAppTests/CheckmarksE2ETests
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisAppTests/E2E/
git commit -m "ios: E2E suite (cold start, offline queue, context, reconnect, restart)"
```

---


## Phase 7 — Switch over + deploy

### Task 7.1: Wire `registerIosAppV2` into `src/channels/index.ts`

**Files:**
- Modify: `src/channels/index.ts`

- [ ] **Step 1: Import the v2 registration**

```ts
import { registerIosAppV2 } from './ios-app/v2/index.js';
// ... other channel imports ...

export function registerAllChannels(ctx: ChannelContext) {
  // ... other channels ...
  registerIosAppV2(ctx);
}
```

- [ ] **Step 2: Verify the full host build**

```bash
pnpm run build
```
Expected: no errors.

- [ ] **Step 3: Run the full host test suite**

```bash
pnpm test
```
Expected: green.

- [ ] **Step 4: Commit**

```bash
git add src/channels/index.ts
git commit -m "channels: switch ios-app over to v2 adapter"
```

---

### Task 7.2: Rebuild container image with shared/ baked in

- [ ] **Step 1: Rebuild**

```bash
./container/build.sh
```

- [ ] **Step 2: Confirm shared/ is in the image**

```bash
docker run --rm --entrypoint /bin/sh nanoclaw-agent:latest -c 'ls /app/shared/ios-app-protocol/v2.ts'
```
Expected: file path printed.

- [ ] **Step 3: Run the container test suite**

```bash
cd container/agent-runner && bun test
```
Expected: green.

- [ ] **Step 4: No commit needed (image is build artifact)**

---

### Task 7.3: Local end-to-end smoke run

- [ ] **Step 1: Restart the host service locally**

```bash
launchctl kickstart -k gui/$(id -u)/com.nanoclaw
```

- [ ] **Step 2: Tail logs while sending a real message from the simulator (or device with the new build)**

```bash
tail -F logs/nanoclaw.log logs/nanoclaw.error.log
```

Send a message from the iOS app (new build with `Transport`). Verify in logs:
- `auth_ok` with `last_seen_outbound_seq=0`
- inbound user message hits `inbound.db` with `meta.kind=user_message`
- Agent reply pulled from `outbound.db` lands in `outbound_queue`, delivered, `ack` arrives.

- [ ] **Step 3: Verify storage state**

```bash
pnpm exec tsx scripts/q.ts data/ios-app/transport.db "SELECT * FROM devices"
pnpm exec tsx scripts/q.ts data/ios-app/transport.db "SELECT platform_id, COUNT(*) FROM outbound_queue GROUP BY platform_id"
```

Expected: device row present, outbound_queue empty after acks.

- [ ] **Step 4: Trigger a `request_context(['device'])` from the agent (have the agent ask itself in a session)**

Confirm in logs:
- `messages_out` row with `type=context_request, expires_at_ms=<now+10s>`
- `pending_context_requests` row appears
- `context_response` envelope from device → row deleted → tool resolves on agent side

```bash
pnpm exec tsx scripts/q.ts data/ios-app/transport.db "SELECT * FROM pending_context_requests"
```

- [ ] **Step 5: No commit (validation only)**

---

### Task 7.4: VDS deploy

- [ ] **Step 1: Push the branch to the personal remote**

```bash
git push origin main
```

- [ ] **Step 2: Ship the v2 iOS build via TestFlight BEFORE restarting the server**

Use Xcode's Archive → Distribute → TestFlight Internal Testing. Install on the device, confirm it launches.

- [ ] **Step 3: On the VDS, pull and rebuild**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && sudo -u nanoclaw git pull && sudo -u nanoclaw pnpm install && sudo -u nanoclaw pnpm run build'
```

- [ ] **Step 4: Restart the service on the VDS**

```bash
ssh root@148.253.211.164 'systemctl --user --machine=nanoclaw@.host restart nanoclaw'
```

Or, if the systemd unit is configured differently:
```bash
ssh root@148.253.211.164 'sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw'
```

- [ ] **Step 5: Watch VDS logs while sending a real message from the new iOS build**

```bash
ssh root@148.253.211.164 'tail -F /home/nanoclaw/nanoclaw/logs/nanoclaw.log'
```

Verify the full inbound + outbound + context_request flow.

- [ ] **Step 6: Rollback procedure (only if needed)**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && sudo -u nanoclaw git reset --hard <previous-sha> && sudo -u nanoclaw pnpm install && sudo -u nanoclaw pnpm run build && systemctl --user restart nanoclaw'
```

Downgrade the iOS build via TestFlight to the previous internal version.

---

## Spec coverage check

| Spec section                            | Implemented in                                    |
|-----------------------------------------|---------------------------------------------------|
| Layer 1 — iOS app                       | Phase 4 (Tasks 4.1–4.6), Phase 5 (Tasks 5.1–5.3)  |
| Layer 2 — Adapter                       | Phase 2 (Tasks 2.1–2.8), Phase 5 (Task 5.4)       |
| Layer 3 — Agent                         | Phase 3 (Tasks 3.1–3.3)                           |
| Wire protocol v2 (envelope + types)     | Phase 1 (Tasks 1.1–1.5)                           |
| Canonical module + Swift mirror         | Phase 1 + Task 4.2 + Task 6.2 fixtures            |
| Adapter storage (transport.db)          | Task 2.2                                          |
| Inbound path (dedup, persist, dispatch) | Task 2.5, Task 2.7                                |
| Outbound path (queue, retry, overflow)  | Task 2.3, Task 2.7                                |
| Auth handshake + cursor replay          | Task 2.7                                          |
| Ack flow + retries                      | Task 2.7 + iOS Task 4.4                           |
| Ping/pong isolation                     | Task 2.5 (test) + Task 2.7 (handler)              |
| Per-session scope (context_request)     | Task 2.6 (test) + Task 2.8 (wire)                 |
| iOS local store + state machines        | Tasks 4.3, 4.4                                    |
| iOS context_request gathering           | Task 4.5                                          |
| iOS one-shot migration                  | Task 4.6                                          |
| Removed: video, APNs, legacy services   | Tasks 5.1, 5.2, 5.3, 5.4                          |
| Unit tests (Layer 1)                    | Tasks 1.2, 1.3, 1.4, 2.2, 2.3, 2.5–2.7, 3.1, 3.2, 4.2, 4.3, 4.4, 4.5, 4.6 |
| Contract tests (Layer 2)                | Tasks 1.5, 4.2                                    |
| Integration scenarios (Layer 3)         | Tasks 6.1, 6.2                                    |
| E2E iOS Simulator (Layer 4)             | Tasks 6.3, 6.4                                    |
| Migration big-bang                      | Phases 1–6 in order, switch in Task 7.1, deploy in Task 7.4 |
| VDS deploy + rollback                   | Task 7.4                                          |

All seven invariants from the spec are exercised:

1. No dedup path lets a duplicate `id` through → Task 2.5 test "dedups by id".
2. No acked outbound entry lingers in `outbound_queue` → Task 2.3 test "ack by id removes the row".
3. No un-acked outbound entry is lost across reconnect → Task 6.2 Scenario 2.
4. Cursors are monotonic per direction → Task 2.2 + 4.3 monotonic tests.
5. `context_request` with TTL is never orphaned beyond `expires_at` → Task 2.6 sweep test + Task 6.2 Scenario 7.
6. Per-session scope rejects cross-session requests → Task 2.6 + Task 6.2 Scenario 8.
7. Ping/pong does not surface to the agent → Task 2.5 + 2.7 + Task 6.2 Scenario 11.

