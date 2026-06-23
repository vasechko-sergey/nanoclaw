# iOS Message Edit (by id) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent can edit the text of a message it already sent on ios-app-v2; the iOS app updates that message in place (by id) and marks it edited.

**Architecture:** New explicit `update` wire envelope (`data` kind, `payload {id, text}`) carried server→device. The agent's existing `edit_message` MCP tool already emits `{operation:"edit", messageId, text}`; the host ios-app-v2 adapter (which today has no edit handler and silently drops it) detects that and emits an `update` envelope. The device does `UPDATE messages SET text=?, edited=1 WHERE id=payload.id`. The envelope's own `id` is a fresh UUID (NOT the target id) so device-side dedup doesn't drop the edit as a duplicate of the original message; the target id rides in `payload.id`.

**Tech Stack:** TypeScript (host Node + shared protocol, zod), Bun/TypeScript (agent-runner, bun:test), Swift (iOS app, GRDB, XCTest), Vitest (host + shared tests).

---

## Key facts established from the codebase (do not re-derive)

- **Id alignment:** `delivery.ts:389-392` stamps `content.id = content.id ?? msg.id` for ios-app-v2 before calling `deliver()`. The device stores the message under `envelope.id` (= that `msg-…` id). `delivery.ts:219` then `markDelivered(inDb, msg.id, platformMsgId)` where `platformMsgId` is `deliver()`'s return (= the same `msg-…` id). So `getMessageIdBySeq(seq)` (container) → the original `msg-…` id → equals the device row id. The chain is consistent; editing is `UPDATE … WHERE id = <msg-id>`.
- **`edit_message` IS registered** (`container/agent-runner/src/mcp-tools/core.ts:336` `registerTools([... editMessage ...])`). The 867B-UUID incident was the agent passing a non-numeric `messageId` (→ `Number(...)` = `NaN` → `!seq` → tool returned an error → nothing delivered → user saw stale text), **compounded by** the host having no edit handler even for a correct call. Both are fixed here. No registration change needed.
- **Why envelope.id must be a fresh UUID, not the target id:** the device dedups inbound by `envelope.id` (`ConversationStoreV2.dedupSeen`); the host `OutboundQueue.ackUpTo` only cursor-acks `type:'message'`. An `update` is cleared from the host queue solely by the device's per-id `delivered` status → `ackById` (`inbound-dispatch.ts:66`), exactly like the workout-family envelopes. So `update` mirrors the workout-family receive path: apply + send `delivered`, do NOT advance the inbound cursor, rely on idempotency for redelivery.
- **Swift `V2.Envelope` Codable `switch type` is exhaustive (no `default`)** — adding `update` to `TypeTag` forces matching decode + encode cases or it won't compile (good guard). The `TransportV2.handleIncoming` `switch env.payload` DOES have a `default: break`, so the `.update` case must be added explicitly there.
- **Fixture count is pinned in two tests:** `shared/ios-app-protocol/fixtures.test.ts` (`toHaveLength(23)` + per-file round-trip through `AnyEnvelope`) and `ios/.../ProtocolFixtureTests.swift` (`XCTAssertEqual(urls.count, 23 …)` + round-trip through `V2.Envelope`). Adding `update.json` ⇒ both become 24.
- **Build wiring:** root `pnpm run build` = `tsc -p shared/ios-app-protocol && tsc` (shared compiled first). `pnpm test` = vitest (host + shared). Container tests: `cd container/agent-runner && bun test`.

## File structure (what each change owns)

| File | Change |
|------|--------|
| `shared/ios-app-protocol/v2.ts` | Add `Envelopes.Update` + include in `AnyEnvelope` union |
| `shared/ios-app-protocol/fixtures/update.json` | New fixture |
| `shared/ios-app-protocol/fixtures.test.ts` | Count 23→24 |
| `shared/ios-app-protocol/v2.test.ts` | Add `update` round-trip assertion |
| `container/agent-runner/src/db/messages-out.ts` | Add `getLatestUserFacingOutboundSeq()` |
| `container/agent-runner/src/db/messages-out.test.ts` | Test the new query |
| `container/agent-runner/src/mcp-tools/core.ts` | `edit_message`: `messageId` optional + new description |
| `container/agent-runner/src/mcp-tools/core.test.ts` | Tests for omitted/invalid `messageId` |
| `container/agent-runner/src/mcp-tools/core.instructions.md` | Document edit capability |
| `src/channels/ios-app/v2/index.ts` | `deliver()`: dispatch `operation:"edit"` → `update` envelope |
| `src/channels/ios-app/v2/ios-edit-delivery.test.ts` | New host test |
| `ios/.../Protocol/V2.swift` | `TypeTag.update`, `Payload.update`, `struct Update`, decode/encode |
| `ios/.../JarvisAppTests/ProtocolFixtureTests.swift` | Count 23→24 |
| `ios/.../Storage/Schema.swift` | `v9-message-edited` migration (add `edited` column) |
| `ios/.../Storage/ConversationStoreV2.swift` | `updateMessageText`; `StoredMessage.edited`; populate in `mapRow` |
| `ios/.../Storage/MessageTimeline.swift` | Populate `edited` in the seed query |
| `ios/.../Models/Message.swift` | `ChatMessage.edited` |
| `ios/.../Services/WebSocketClientV2.swift` | `toChatMessage` threads `edited` |
| `ios/.../Services/TransportV2.swift` | `handleIncoming` `.update` case |
| `ios/.../JarvisAppTests/TransportV2Tests.swift` | Test update applies in place |
| `ios/.../Components/MessageRow.swift` | "(ред.)" marker in `metaRow` |
| `ios/JarvisApp/project.yml` | Version bump (per iOS rule) |
| `groups/INSTRUCTIONS.md` (scp, gitignored) | One-line agent guidance |

---

## Task 1: Protocol — add the `update` envelope (canonical TS + fixture)

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`
- Modify: `shared/ios-app-protocol/fixtures.test.ts`
- Modify: `shared/ios-app-protocol/v2.test.ts`
- Create: `shared/ios-app-protocol/fixtures/update.json`

- [ ] **Step 1: Write the fixture (the failing input)**

Create `shared/ios-app-protocol/fixtures/update.json`:

```json
{
  "v": 2,
  "kind": "data",
  "type": "update",
  "id": "11111111-1111-4111-8111-111111111111",
  "seq": 7,
  "ts": "2026-06-23T12:00:00.000Z",
  "payload": {
    "id": "msg-1750670000000-abc123",
    "text": "Исправленный текст"
  }
}
```

- [ ] **Step 2: Bump both count assertions**

In `shared/ios-app-protocol/fixtures.test.ts:25` change `toHaveLength(23)` to `toHaveLength(24)`:

```ts
  it('covers all 24 expected envelope fixtures', () => {
    expect(envelopeFiles).toHaveLength(24);
  });
```

- [ ] **Step 3: Add an explicit round-trip assertion in v2.test.ts**

Append inside the `describe('AnyEnvelope discriminated union', …)` block in `shared/ios-app-protocol/v2.test.ts`:

```ts
  it('parses an update envelope (server→device edit)', () => {
    const env = AnyEnvelope.parse({
      v: 2,
      kind: 'data',
      type: 'update',
      id: '11111111-1111-4111-8111-111111111111',
      seq: 7,
      ts: '2026-06-23T12:00:00.000Z',
      payload: { id: 'msg-1750670000000-abc123', text: 'fixed' },
    });
    if (env.type !== 'update') throw new Error('expected update');
    expect(env.payload.id).toBe('msg-1750670000000-abc123');
    expect(env.payload.text).toBe('fixed');
  });
```

If `v2.test.ts` does not already `import { AnyEnvelope } from './v2';`, add it to the existing import line.

- [ ] **Step 4: Run the protocol tests to verify they FAIL**

Run: `pnpm exec vitest run shared/ios-app-protocol`
Expected: FAIL — `update.json` fails `AnyEnvelope.parse` (no `update` member in the union), the count test expects 24 but the parse throws, and the new v2 assertion throws.

- [ ] **Step 5: Add `Envelopes.Update` and include it in the union**

In `shared/ios-app-protocol/v2.ts`, add a new entry to the `Envelopes` object (place it right after `Envelopes.Message`, since it is the other `data`/text envelope):

```ts
  Update: EnvelopeBase.extend({
    kind: z.literal('data'),
    type: z.literal('update'),
    payload: z.object({
      // Target message id to edit in place. This is the original outbound
      // `msg-…` id the device stored the message under — NOT a uuid, so .min(1)
      // (the envelope's own `id` stays a uuid via EnvelopeBase).
      id: z.string().min(1),
      text: z.string(),
      agent_id: z.string().min(1).optional(),
    }),
  }),
```

Then add `Envelopes.Update` to the `AnyEnvelope` discriminated union list (after `Envelopes.Message`):

```ts
export const AnyEnvelope = z.discriminatedUnion('type', [
  Envelopes.Auth, Envelopes.AuthOk, Envelopes.AuthFail,
  Envelopes.Message, Envelopes.Update, Envelopes.ContextRequest, Envelopes.ContextResponse,
  Envelopes.NewConversation, Envelopes.ActionResponse, Envelopes.Feedback,
  Envelopes.Ack, Envelopes.Ping, Envelopes.Pong,
  Envelopes.StatusDelivered, Envelopes.StatusRead,
  // Workout-mode envelopes (P3.T1)
  Envelopes.WorkoutStartRequest, Envelopes.WorkoutPlan, Envelopes.SetLog,
  Envelopes.ExerciseDone, Envelopes.WorkoutComplete, Envelopes.WorkoutAbort,
  Envelopes.ImageRequest, Envelopes.ImageBlob,
  Envelopes.ExerciseSwapRequest, Envelopes.ExerciseSwapConfirm,
  Envelopes.ExerciseSwapOptions, Envelopes.ProgramUpdate,
  Envelopes.CoachMessage, Envelopes.IntroRequest,
]);
```

- [ ] **Step 6: Run the protocol tests to verify they PASS**

Run: `pnpm exec vitest run shared/ios-app-protocol`
Expected: PASS — all 24 fixtures round-trip, count is 24, the new v2 assertion passes.

- [ ] **Step 7: Compile shared so the emitted JS is current (host imports `index.js`)**

Run: `pnpm run build:protocol`
Expected: exits 0; `shared/ios-app-protocol/v2.js` now contains `Update`.

- [ ] **Step 8: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.js shared/ios-app-protocol/v2.d.ts shared/ios-app-protocol/v2.js.map shared/ios-app-protocol/v2.d.ts.map shared/ios-app-protocol/fixtures/update.json shared/ios-app-protocol/fixtures.test.ts shared/ios-app-protocol/v2.test.ts shared/ios-app-protocol/tsconfig.tsbuildinfo
git commit -m "feat(ios-protocol): add update envelope (server→device edit-in-place)"
```

---

## Task 2: Container — `edit_message` targets last message when seq omitted

**Files:**
- Modify: `container/agent-runner/src/db/messages-out.ts`
- Modify: `container/agent-runner/src/db/messages-out.test.ts`
- Modify: `container/agent-runner/src/mcp-tools/core.ts:249-288`
- Modify: `container/agent-runner/src/mcp-tools/core.test.ts`
- Modify: `container/agent-runner/src/mcp-tools/core.instructions.md`

- [ ] **Step 1: Write the failing test for the new query**

Append to `container/agent-runner/src/db/messages-out.test.ts`:

```ts
import { writeMessageOut, getUserFacingDispatchCount, resetUserFacingDispatch, getLatestUserFacingOutboundSeq } from './messages-out.js';

describe('getLatestUserFacingOutboundSeq', () => {
  const base = {
    id: '',
    kind: 'chat',
    platform_id: 'p',
    channel_type: 'c',
    thread_id: null as string | null,
    content: '',
  };

  beforeEach(() => {
    initTestSessionDb();
    resetUserFacingDispatch();
  });

  it('returns null when there is no outbound message', () => {
    expect(getLatestUserFacingOutboundSeq()).toBeNull();
  });

  it('returns the seq of the most recent user-facing chat message', () => {
    writeMessageOut({ ...base, id: 'm1', content: JSON.stringify({ text: 'first' }) });
    const seq2 = writeMessageOut({ ...base, id: 'm2', content: JSON.stringify({ text: 'second' }) });
    expect(getLatestUserFacingOutboundSeq()).toBe(seq2);
  });

  it('skips status pings, edits and reactions', () => {
    const real = writeMessageOut({ ...base, id: 'm1', content: JSON.stringify({ text: 'real' }) });
    writeMessageOut({ ...base, id: 'm2', content: JSON.stringify({ type: 'status', text: 'working' }) });
    writeMessageOut({ ...base, id: 'm3', content: JSON.stringify({ operation: 'edit', messageId: 'x', text: 'e' }) });
    writeMessageOut({ ...base, id: 'm4', content: JSON.stringify({ operation: 'reaction', messageId: 'x', emoji: 'heart' }) });
    expect(getLatestUserFacingOutboundSeq()).toBe(real);
  });
});
```

(Update the existing top-of-file import on line 4 to include `getLatestUserFacingOutboundSeq`, OR keep the second import as written above — bun allows the duplicate symbol only if you don't double-declare; simplest is to add `getLatestUserFacingOutboundSeq` to the line-4 import and drop the extra import line.)

- [ ] **Step 2: Run the test to verify it FAILS**

Run: `cd container/agent-runner && bun test src/db/messages-out.test.ts`
Expected: FAIL — `getLatestUserFacingOutboundSeq is not a function` / not exported.

- [ ] **Step 3: Implement the query**

Add to `container/agent-runner/src/db/messages-out.ts` (after `getRoutingBySeq`, before `getUndeliveredMessages`):

```ts
/**
 * Latest user-facing outbound message's seq (or null). Powers `edit_message`
 * with no explicit id: "fix the message I just said". Mirrors isUserFacing —
 * chat kind, not a status ping — and additionally skips edit/reaction control
 * rows so we target a real message, never a prior correction.
 */
export function getLatestUserFacingOutboundSeq(): number | null {
  const row = getOutboundDb()
    .prepare(
      `SELECT seq FROM messages_out
       WHERE kind = 'chat'
         AND seq IS NOT NULL
         AND content NOT LIKE '%"type":"status"%'
         AND content NOT LIKE '%"operation":"edit"%'
         AND content NOT LIKE '%"operation":"reaction"%'
       ORDER BY seq DESC
       LIMIT 1`,
    )
    .get() as { seq: number } | undefined;
  return row?.seq ?? null;
}
```

- [ ] **Step 4: Run the test to verify it PASSES**

Run: `cd container/agent-runner && bun test src/db/messages-out.test.ts`
Expected: PASS.

- [ ] **Step 5: Write failing tests for the edit_message handler changes**

Inspect how `core.test.ts` exercises tools (it imports the tool defs and calls `.handler(args)`; it sets up the session DB the same way as `messages-out.test.ts`). Append tests mirroring that setup:

```ts
import { editMessage } from './core.js';
import { writeMessageOut } from '../db/messages-out.js';

describe('edit_message targeting', () => {
  beforeEach(() => {
    initTestSessionDb();      // use whatever init the file already calls in beforeEach
  });

  it('errors when text is missing', async () => {
    const res = await editMessage.handler({ messageId: 1 });
    expect(res.isError).toBe(true);
  });

  it('errors with a clear message when messageId is non-numeric', async () => {
    const res = await editMessage.handler({ messageId: '867B-not-a-seq', text: 'x' });
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain('numeric');
  });

  it('edits the last user-facing message when messageId is omitted', async () => {
    const seq = writeMessageOut({
      id: 'm1', kind: 'chat', platform_id: 'p', channel_type: 'ios-app-v2',
      thread_id: null, content: JSON.stringify({ text: 'oops' }),
    });
    const res = await editMessage.handler({ text: 'corrected' });
    expect(res.isError).toBeUndefined();
    expect(res.content[0].text).toContain(String(seq));
  });

  it('errors when omitted and there is no prior message', async () => {
    const res = await editMessage.handler({ text: 'corrected' });
    expect(res.isError).toBe(true);
  });
});
```

> Note: `getRoutingBySeq`/`getMessageIdBySeq` read the same outbound row written above, so the omitted-id happy path resolves routing from `m1`. If `core.test.ts` uses a different DB-init helper name in its `beforeEach`, reuse that one verbatim instead of `initTestSessionDb()`.

- [ ] **Step 6: Run to verify the new tests FAIL**

Run: `cd container/agent-runner && bun test src/mcp-tools/core.test.ts`
Expected: FAIL — omitted `messageId` currently hits `if (!seq …)` and errors; the non-numeric case errors but without the word "numeric".

- [ ] **Step 7: Make `messageId` optional + clearer errors in `edit_message`**

In `container/agent-runner/src/mcp-tools/core.ts`, update the import on line 14 to include the new helper:

```ts
import { getLatestUserFacingOutboundSeq, getMessageIdBySeq, getRoutingBySeq, writeMessageOut } from '../db/messages-out.js';
```

Replace the `editMessage` definition (lines 249-288) with:

```ts
export const editMessage: McpToolDefinition = {
  tool: {
    name: 'edit_message',
    description:
      'Edit a message you already sent — replaces its full text in place (the user sees the bubble change, marked edited). ' +
      'Omit `messageId` to edit the LAST message you sent (the common "fix what I just said" case). ' +
      'Pass `messageId` (the numeric id shown in messages) only to target an OLDER message. ' +
      'Never invent a messageId — omit it instead.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        messageId: {
          type: 'integer',
          description: 'Numeric id of an older message to edit. Omit to edit your most recent message.',
        },
        text: { type: 'string', description: 'New full message content (replaces the old text)' },
      },
      required: ['text'],
    },
  },
  async handler(args) {
    const text = args.text as string;
    if (!text) return err('text is required');

    let seq: number;
    if (args.messageId === undefined || args.messageId === null || args.messageId === '') {
      const last = getLatestUserFacingOutboundSeq();
      if (last === null) return err('No recent message to edit.');
      seq = last;
    } else {
      seq = Number(args.messageId);
      if (!Number.isFinite(seq) || seq <= 0) {
        return err('messageId must be the numeric id shown in messages — or omit it to edit your last message.');
      }
    }

    const platformId = getMessageIdBySeq(seq);
    if (!platformId) return err(`Message #${seq} not found`);

    const routing = getRoutingBySeq(seq);
    if (!routing || !routing.channel_type || !routing.platform_id) {
      return err(`Cannot determine destination for message #${seq}`);
    }

    const id = generateId();
    writeMessageOut({
      id,
      kind: 'chat',
      platform_id: routing.platform_id,
      channel_type: routing.channel_type,
      thread_id: routing.thread_id,
      content: JSON.stringify({ operation: 'edit', messageId: platformId, text }),
    });

    log(`edit_message: #${seq} → ${platformId}`);
    return ok(`Message edit queued for #${seq}`);
  },
};
```

- [ ] **Step 8: Run to verify the handler tests PASS**

Run: `cd container/agent-runner && bun test src/mcp-tools/core.test.ts`
Expected: PASS.

- [ ] **Step 9: Document the capability in core.instructions.md**

Open `container/agent-runner/src/mcp-tools/core.instructions.md`, find the `edit_message` / `send_message` section (grep for `edit_message`), and ensure it reads:

```markdown
- **edit_message** — Correct a message you already sent. It replaces the whole text in place (the user sees the same bubble update, marked edited). To fix the message you JUST sent, call `edit_message` with only the new `text` — do NOT pass a messageId. Pass the numeric `messageId` (shown next to messages) only to edit an OLDER message. Never invent a messageId; if you don't have the number, omit it.
```

- [ ] **Step 10: Container typecheck + full container tests**

Run: `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit && cd container/agent-runner && bun test`
Expected: typecheck clean; tests pass (3 pre-existing `userFacingDispatchCount` cross-file flakies may show — confirm they also fail on `git stash` if in doubt; they are not caused by this task).

- [ ] **Step 11: Commit**

```bash
git add container/agent-runner/src/db/messages-out.ts container/agent-runner/src/db/messages-out.test.ts container/agent-runner/src/mcp-tools/core.ts container/agent-runner/src/mcp-tools/core.test.ts container/agent-runner/src/mcp-tools/core.instructions.md
git commit -m "feat(agent): edit_message edits last message when id omitted; clearer errors + docs"
```

---

## Task 3: Host — ios-app-v2 `deliver()` dispatches `edit` → `update`

**Files:**
- Modify: `src/channels/ios-app/v2/index.ts` (`deliver()`, ~line 499-654)
- Create: `src/channels/ios-app/v2/ios-edit-delivery.test.ts`

- [ ] **Step 1: Write the failing host test**

Create `src/channels/ios-app/v2/ios-edit-delivery.test.ts` (mirrors `workout-outbound.test.ts`'s harness, but the edit path needs no resolvable session — it pushes straight to the device queue):

```ts
// The ios-app-v2 adapter turns an agent edit ({operation:'edit', messageId, text})
// into an `update` envelope (id in payload, fresh envelope id), enqueued for the
// device. Mirrors workout-outbound.test.ts: build the real adapter via
// createV2Adapter(), register a device row so seq allocation works, call
// deliver(), read the enqueued envelope back via OutboundQueue.list().
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'fs';
import path from 'path';
import os from 'os';

const { mockEnv } = vi.hoisted(() => ({ mockEnv: {} as Record<string, string> }));
vi.mock('../../../env.js', () => ({
  readEnvFile: vi.fn((keys: string[]) => {
    const out: Record<string, string> = {};
    for (const k of keys) if (mockEnv[k]) out[k] = mockEnv[k];
    return out;
  }),
}));

import { initTestDb, closeDb } from '../../../db/index.js';
import { runMigrations } from '../../../db/migrations/index.js';
import { openTransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { createV2Adapter } from './index.js';

let tmpDir: string;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-edit-'));
  mockEnv.IOS_APP_TOKEN = 'tok';
  mockEnv.IOS_APP_V2_PORT = '0';
  mockEnv.IOS_APP_V2_DB_PATH = path.join(tmpDir, 'transport.db');
  initTestDb();
  runMigrations();
});

afterEach(() => {
  closeDb();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

function registerDevice(platformId: string): void {
  const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
  tdb.upsertDevice(platformId, { capabilities: [] });
  tdb.raw.close();
}

describe('ios-app-v2 deliver() edit dispatch', () => {
  it('emits an update envelope with the target id in the payload', async () => {
    const platformId = 'ios-app-v2:default';
    registerDevice(platformId);
    const adapter = createV2Adapter()!;
    expect(adapter).not.toBeNull();

    await adapter.deliver(platformId, 'default', {
      content: { operation: 'edit', messageId: 'msg-123-abc', text: 'corrected text' },
    } as any);

    const queue = new OutboundQueue(openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!));
    const rows = queue.list(platformId);
    const update = rows.find((r) => r.type === 'update');
    expect(update).toBeTruthy();
    const payload = JSON.parse(update!.payload_json);
    expect(payload.id).toBe('msg-123-abc');
    expect(payload.text).toBe('corrected text');
    // The envelope's own id must NOT be the target id (else the device dedups
    // the edit as the original message and drops it).
    expect(update!.id).not.toBe('msg-123-abc');
  });

  it('drops an edit with no messageId (no update enqueued)', async () => {
    const platformId = 'ios-app-v2:default';
    registerDevice(platformId);
    const adapter = createV2Adapter()!;
    await adapter.deliver(platformId, 'default', {
      content: { operation: 'edit', text: 'no target' },
    } as any);
    const queue = new OutboundQueue(openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!));
    expect(queue.list(platformId).some((r) => r.type === 'update')).toBe(false);
  });
});
```

> If `createV2Adapter` returns null for `IOS_APP_V2_PORT='0'` (the factory guards `parseInt(...) <= 0`), use `'4599'` instead — the test never calls `setup()`, so the port is never bound. Adjust both the env value and keep `deliver()`/`OutboundQueue` reads unchanged.

- [ ] **Step 2: Run to verify it FAILS**

Run: `pnpm exec vitest run src/channels/ios-app/v2/ios-edit-delivery.test.ts`
Expected: FAIL — today's `deliver()` has no edit branch, so the edit content falls through to the default `message` envelope (`type:'message'`, fresh-uuid id, no `payload.id`). No `update` row exists.

- [ ] **Step 3: Add the edit branch in `deliver()`**

In `src/channels/ios-app/v2/index.ts`, inside `deliver()`, immediately after the `contentType` is computed (right before the `if (contentType === 'context_request')` block, ~line 502), insert:

```ts
      // Edit-in-place: the agent's edit_message tool emits
      //   { operation:'edit', messageId, text }
      // messageId is the original outbound msg-id (= the id the device stored
      // the message under, see delivery.ts:389). Emit an explicit `update`
      // envelope; the device does UPDATE … WHERE id = payload.id. Do NOT reuse
      // messageId as the envelope id — sendEnvelopeToDevice defaults it to a
      // fresh uuid, and the device dedups inbound by envelope id (reusing the
      // original id would make it drop the edit as a duplicate).
      if (content.operation === 'edit') {
        const targetId = typeof content.messageId === 'string' ? content.messageId : undefined;
        if (!targetId) {
          logV2Warn('edit with no messageId — dropping', { platformId });
          return undefined;
        }
        const newText = typeof content.text === 'string' ? content.text : '';
        const agentFolder = resolveAgentFolder(message.agentGroupId);
        handler.sendEnvelopeToDevice(platformId, {
          kind: 'data',
          type: 'update',
          payload: {
            id: targetId,
            text: newText,
            ...(agentFolder ? { agent_id: agentFolder } : {}),
          },
        });
        logV2('edit dispatched', { platformId, targetId });
        return targetId;
      }
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `pnpm exec vitest run src/channels/ios-app/v2/ios-edit-delivery.test.ts`
Expected: PASS — one `update` row with `payload.id === 'msg-123-abc'`, `payload.text === 'corrected text'`, and a different envelope id; the no-messageId case enqueues nothing.

- [ ] **Step 5: Full host build + tests**

Run: `pnpm run build && pnpm test`
Expected: build clean; vitest green (including Task 1's shared tests).

- [ ] **Step 6: Commit**

```bash
git add src/channels/ios-app/v2/index.ts src/channels/ios-app/v2/ios-edit-delivery.test.ts
git commit -m "feat(ios-app-v2): dispatch agent edit -> update envelope (edit in place)"
```

---

## Task 4: iOS protocol mirror — `V2.Update`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`

- [ ] **Step 1: Bump the Swift fixture count (failing assertion + forces decode)**

In `ProtocolFixtureTests.swift:34` change `23` to `24`:

```swift
        XCTAssertEqual(urls.count, 24, "envelope fixture count mismatch — expected 24, got \(urls.count) at \(dir.path)")
```

- [ ] **Step 2: Run the Swift protocol test to verify it FAILS**

Run: `cd ios/JarvisApp && swift test --filter ProtocolFixtureTests` (or via XcodeBuildMCP `test_sim` filtering ProtocolFixtureTests).
Expected: FAIL — `update.json` now exists so count is 24 at the directory, but `V2.Envelope` can't decode `type:"update"` (the `TypeTag` enum has no `update` member → `decode(V2.TypeTag.self …)` throws) → `decode failed for update.json`.

- [ ] **Step 3: Add the `update` type tag**

In `V2.swift`, add to the `TypeTag` enum (after `case message`):

```swift
        case update
```

- [ ] **Step 4: Add the `Update` payload struct**

In `V2.swift`, add after the `Message` struct (after line ~133):

```swift
    struct Update: Codable, Equatable {
        let id: String      // target message id to edit in place
        let text: String
        var agent_id: String?
        init(id: String, text: String, agent_id: String? = nil) {
            self.id = id
            self.text = text
            self.agent_id = agent_id
        }
    }
```

- [ ] **Step 5: Add the `Payload` union case**

In the `Payload` enum, after `case message(Message)`:

```swift
        case update(Update)
```

- [ ] **Step 6: Add the decode + encode cases (exhaustive switch — required to compile)**

In `init(from:)` of `extension V2.Envelope: Codable`, after the `case .message:` block (~line 543):

```swift
        case .update:
            payload = .update(try V2.Update(from: payloadDecoder))
```

In `func encode(to:)`, after `case .message(let p): try p.encode(to: payloadEncoder)` (~line 609):

```swift
        case .update(let p): try p.encode(to: payloadEncoder)
```

- [ ] **Step 7: Run the Swift protocol test to verify it PASSES**

Run: `cd ios/JarvisApp && swift test --filter ProtocolFixtureTests`
Expected: PASS — `update.json` decodes, re-encodes, and re-decodes to an equal envelope; count is 24.

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift
git commit -m "feat(ios): V2.Update protocol mirror (edit-in-place envelope)"
```

---

## Task 5: iOS storage — `edited` column + `updateMessageText`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/MessageTimeline.swift`
- Modify (test): `ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2AgentTests.swift` (or a new store test file)

- [ ] **Step 1: Write the failing store test**

Append a test to `ConversationStoreV2AgentTests.swift` (reuse its in-memory `DatabaseQueue` + `Schema.migrate` setup; mirror an existing test's harness):

```swift
    func testUpdateMessageTextEditsInPlaceAndMarksEdited() throws {
        let dbq = try DatabaseQueue()        // or the file's existing makeStore() helper
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        let env = V2.Envelope(
            v: 2, kind: .data, type: .message,
            id: "msg-1", seq: 3, ts: "2026-06-23T12:00:00.000Z",
            payload: .message(V2.Message(thread_id: "default", text: "oops"))
        )
        try store.insertInbound(envelope: env, message: V2.Message(thread_id: "default", text: "oops"), agentId: "jarvis")

        let changed = try store.updateMessageText(id: "msg-1", text: "corrected")
        XCTAssertTrue(changed)

        let row = try store.fetchById("msg-1")
        XCTAssertEqual(row?.text, "corrected")
        XCTAssertTrue(row?.edited ?? false)

        // Unknown id is a silent no-op.
        let missing = try store.updateMessageText(id: "nope", text: "x")
        XCTAssertFalse(missing)
    }
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `cd ios/JarvisApp && swift test --filter ConversationStoreV2AgentTests`
Expected: FAIL — `updateMessageText` doesn't exist and `StoredMessage` has no `edited` member.

- [ ] **Step 3: Add the migration**

In `Schema.swift`, before `try m.migrate(writer)` (after the `v8-workout-plan` migration), add:

```swift
        m.registerMigration("v9-message-edited") { db in
            // Agent edit-in-place: mark a row as edited so the UI can show "(ред.)".
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN edited INTEGER NOT NULL DEFAULT 0;")
        }
```

- [ ] **Step 4: Add the field to `StoredMessage`**

In `ConversationStoreV2.swift`, add to `struct StoredMessage` (after `workoutPlanJSON`):

```swift
    var edited: Bool = false
```

- [ ] **Step 5: Populate `edited` in the live decoder + the seed query**

In `ConversationStoreV2.swift` `static func mapRow(_:)`, add to the `StoredMessage(...)` init (after `workoutPlanJSON: row["workout_plan_json"]`):

```swift
            ,
            edited: row["edited"] ?? false
```

(i.e. append `edited: row["edited"] ?? false` as the final argument.)

In `MessageTimeline.swift` `start()`, the synchronous seed builds `StoredMessage` inline (lines ~37-50). Append `edited: row["edited"] ?? false` as the final argument there too, so an edited message at launch shows the marker on the first frame (the live observation uses `mapRow`, already covered).

> The remaining inline decoders (`queuedOutbound`, `fetchById`, `allRows`, `observeMessages`) keep the `edited:false` default. `fetchById` is the exception — the store test above reads `edited` through it, so also append `edited: row["edited"] ?? false` to the `fetchById` `StoredMessage(...)` init (line ~305-321).

- [ ] **Step 6: Add `updateMessageText`**

In `ConversationStoreV2.swift`, add (next to `markActionAnswered`):

```swift
    /// Edit a message's text in place (agent correction) and mark it edited so
    /// the UI can show a "(ред.)" tag. Returns whether a row was updated —
    /// false means the id is unknown (e.g. pruned), which is a silent no-op.
    @discardableResult
    func updateMessageText(id: String, text: String) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET text = ?, edited = 1 WHERE id = ?",
                           arguments: [text, id])
            return db.changesCount > 0
        }
    }
```

- [ ] **Step 7: Run to verify it PASSES**

Run: `cd ios/JarvisApp && swift test --filter ConversationStoreV2AgentTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift ios/JarvisApp/Sources/JarvisApp/Storage/MessageTimeline.swift ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2AgentTests.swift
git commit -m "feat(ios): edited column + updateMessageText (edit message in place)"
```

---

## Task 6: iOS transport + UI — apply `update`, render "(ред.)", version bump

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` (`handleIncoming`, ~line 160-203)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/Message.swift` (`ChatMessage`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift` (`toChatMessage`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift` (`metaRow`)
- Modify (test): `ios/JarvisApp/Sources/JarvisAppTests/TransportV2Tests.swift`
- Modify: `ios/JarvisApp/project.yml` (version bump)

- [ ] **Step 1: Write the failing transport test**

Append to `TransportV2Tests.swift` (mirror an existing `handleIncoming` test's setup — it builds a `TransportV2` over an in-memory store and feeds `Data`):

```swift
    func testUpdateEnvelopeEditsMessageInPlace() async throws {
        // (Reuse the file's existing helper to build a TransportV2 + store with a
        // seeded inbound message id "msg-1".)
        let (transport, store) = try makeTransport()      // existing helper
        let seed = V2.Envelope(
            v: 2, kind: .data, type: .message,
            id: "msg-1", seq: 3, ts: "2026-06-23T12:00:00.000Z",
            payload: .message(V2.Message(thread_id: "default", text: "oops"))
        )
        try await transport.handleIncoming(JSONEncoder().encode(seed))

        let upd = V2.Envelope(
            v: 2, kind: .data, type: .update,
            id: "env-uuid-1", seq: 5, ts: "2026-06-23T12:00:01.000Z",
            payload: .update(V2.Update(id: "msg-1", text: "corrected"))
        )
        try await transport.handleIncoming(JSONEncoder().encode(upd))

        let row = try store.fetchById("msg-1")
        XCTAssertEqual(row?.text, "corrected")
        XCTAssertTrue(row?.edited ?? false)
    }
```

> If `TransportV2Tests` has no `makeTransport()` helper, copy the construction from an existing `handleIncoming` test in that file verbatim.

- [ ] **Step 2: Run to verify it FAILS**

Run: `cd ios/JarvisApp && swift test --filter TransportV2Tests`
Expected: FAIL — `.update` falls into `handleIncoming`'s `default: break`, so the text is never updated.

- [ ] **Step 3: Handle `.update` in `handleIncoming`**

In `TransportV2.swift` `handleIncoming`, add a case before `default:` (~line 200):

```swift
        case .update(let u):
            // Edit-in-place. Not a chat `message`, so it's exempt from the host's
            // cursor ack (ackUpTo is message-only) — this per-id `delivered` is
            // the only thing that clears it from the host queue, same model as the
            // workout-family envelopes above. Idempotent: re-applying the same
            // edit is a no-op, so a redelivered update never harms.
            try store.updateMessageText(id: u.id, text: u.text)
            try await sendStatus(.delivered, ids: [env.id])
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `cd ios/JarvisApp && swift test --filter TransportV2Tests`
Expected: PASS.

- [ ] **Step 5: Thread `edited` into the UI model**

In `Message.swift`, add to `struct ChatMessage` (after `imageSHA`):

```swift
    /// True when an agent edited this message in place (shows a "(ред.)" tag).
    var edited: Bool = false
```

In `WebSocketClientV2.swift` `toChatMessage`, set `edited` on the plain-text bubble (the common edit target). Change the tail (lines 611-614) to:

```swift
        var msg = ChatMessage.text(row.id, role: role, text: row.text, timestamp: timestamp)
        msg.deliveryStatus = mapDelivery(row.status)
        msg.agentId = row.agentId
        msg.edited = row.edited
        return [msg]
```

- [ ] **Step 6: Render the marker in `MessageRow.metaRow`**

In `MessageRow.swift` `metaRow` (line ~164-186), add the "(ред.)" tag just before the timestamp `Text`:

```swift
            if message.edited {
                Text("ред.")
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.timestamp)
            }
            Text(message.timestamp, style: .time)
```

(The enclosing `HStack` already applies `.textCase(.uppercase)`, so it renders as "РЕД." in the meta style — consistent with the sender/time row.)

- [ ] **Step 7: Bump the app version (required by the iOS build rule)**

In `ios/JarvisApp/project.yml`, find `CURRENT_PROJECT_VERSION` and increment it by 1; bump `MARKETING_VERSION` minor (a user-facing feature). Then regenerate the project:

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 8: Full iOS unit-test run + clean simulator build**

Run: `cd ios/JarvisApp && swift test` (all unit tests) — then a clean build via XcodeBuildMCP `build_sim` (verify it compiles for the simulator; the exhaustive `V2.Envelope` switches and the new SwiftUI all build).
Expected: tests green; build succeeds. (Device install on the iPhone is the operator's step.)

- [ ] **Step 9: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift ios/JarvisApp/Sources/JarvisApp/Models/Message.swift ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift ios/JarvisApp/Sources/JarvisAppTests/TransportV2Tests.swift ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "feat(ios): apply update envelope in place + (ред.) marker + version bump"
```

---

## Task 7: Agent guidance (shared INSTRUCTIONS) + deploy

**Files:**
- Modify: `groups/INSTRUCTIONS.md` (gitignored — scp, not git)

- [ ] **Step 1: Add one line to the shared instructions**

In `groups/INSTRUCTIONS.md`, under the outbound/messaging discipline section, add:

```markdown
- To correct a message you already sent, use `edit_message` (it edits your LAST message when you pass only the new `text`; pass a numeric `messageId` only for an older one). Never invent a message id — omit it to edit the latest. The user sees the same bubble update in place.
```

- [ ] **Step 2: Deploy host + agent-runner to the VDS (host-mounted src → no image rebuild)**

```bash
pnpm run build && git push
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw"'
```

- [ ] **Step 3: Deploy the gitignored instructions via scp**

```bash
scp groups/INSTRUCTIONS.md root@148.253.211.164:/tmp/INSTRUCTIONS.md
ssh root@148.253.211.164 'install -o nanoclaw -g nanoclaw -m 644 /tmp/INSTRUCTIONS.md /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md && rm -f /tmp/INSTRUCTIONS.md'
```

- [ ] **Step 4: Reload running agent sessions so the instruction + new tool description take effect**

Instruction/CLAUDE-level changes are only read at session birth and the SDK resumes via `continuation:claude`. Kill the agent containers and wipe the continuation rows so the next message starts a fresh session that re-reads instructions. (The agent-runner code is host-mounted, so the new `edit_message` behavior is already live after the restart; only the *instructions/tool-description* reload needs the continuation wipe.) Use the project's established rebirth procedure (kill container + `DELETE` the `continuation:claude` row across the agent's sessions — `find`, not glob).

- [ ] **Step 5: Operator builds + installs the iOS app**

Tell Сергей: rebuild & install the Jarvis app on the iPhone (new build carries the `update` protocol type, the edited column migration, and the "(ред.)" marker). Until installed, edits no-op gracefully on the old build (unknown `update` type → the old decoder throws on the envelope and the socket treats it as a protocol violation — **verify** the old build simply drops/ignores the unknown type rather than dropping the socket; if it would drop the socket, gate sending `update` on a reported capability/build in `auth.payload.build`).

---

## Final verification (whole feature)

- [ ] **Host:** `pnpm run build && pnpm test` — green.
- [ ] **Container:** `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit && (cd container/agent-runner && bun test)` — green (modulo the 3 known cross-file `userFacingDispatchCount` flakies).
- [ ] **iOS:** `cd ios/JarvisApp && swift test` — green; `build_sim` clean.
- [ ] **Live (operator):** on the new iPhone build — an agent sends a message, then `edit_message` with new text → the SAME bubble updates in place, tagged "РЕД." (not a new message). Cross-check VDS logs for `[ios-app-v2] edit dispatched` and the device `[delivery] recv update`.

---

## Self-review notes (coverage vs spec)

- Spec component 1 (protocol `update`) → Task 1 (TS) + Task 4 (Swift). **Design refinement vs the spec sketch:** the target id rides in `payload.id` and the envelope `id` stays a fresh UUID (the spec sketched `id: messageId`); reusing the id would make the device dedup drop the edit — established from `ws-handler.ts`/`outbound-queue.ts`/`ConversationStoreV2.dedupSeen`.
- Spec component 2 (host dispatch) → Task 3. Confirmed `delivery.ts` passes `{operation:'edit',…}` content opaque to the adapter.
- Spec component 3 (iOS update in place + marker) → Tasks 5 + 6.
- Spec component 4 (agent tool + docs; verify registration) → Task 2. **Registration confirmed already present** (core.ts:336) — so the only fix is seq-optional + clearer errors + docs, not registration.
- Protocol-versioning / unknown-type-on-old-build concern → Task 7 Step 5 (verify graceful ignore; capability-gate if needed).
- Failure semantics (unknown id = silent no-op) → `updateMessageText` returns false on 0 rows (Task 5).
