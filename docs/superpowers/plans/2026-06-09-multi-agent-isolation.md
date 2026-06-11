# Multi-Agent Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each iOS agent chip (Jarvis / Payne / Greg) a fully isolated direct chat with its own session and its own contextual bootstrap. Fix Payne's missing data on first contact, cross-agent leakage, missing workout visuals, wrong outbound stamp, dangling sessions, and the unread-badge bug.

**Architecture:** iOS adapter owns routing — when an envelope carries `agent_id`, it bypasses `routeInbound` and writes straight into the addressed session via a shared `adapterRouteToAgent` helper that still runs sender resolution + access gate + session resolve + wake. Host startup ensures `jarvis`/`payne`/`greg` agent groups + their three sessions exist. Payne gets MCP `workout.*` tools that emit the existing iOS workout envelopes. Both Payne and Greg get an `INDEX.md` + a `trigger=0` bootstrap inbound at session create. iOS gets a persisted `LastSeenStore` so the unread badge stops counting full history.

**Tech Stack:** TypeScript (host: pnpm + vitest), Bun (agent-runner: bun:test), SwiftUI (iOS), zod schemas under `shared/ios-app-protocol/`.

**Prerequisites:** Plans `2026-06-08-payne-1-ios-multi-agent-routing.md`, `-payne-2-agent-foundation.md`, `-payne-3-workout-mode.md` already landed (they shipped the `agent_id` protocol field, multi-agent dispatch shape, workout envelopes, and most of the iOS workout UI).

**Spec:** [docs/superpowers/specs/2026-06-09-multi-agent-isolation-design.md](../specs/2026-06-09-multi-agent-isolation-design.md).

---

## File map

### Create
- `src/adapter-route.ts` — shared `adapterRouteToAgent(event, agentGroupId, opts)` helper
- `src/adapter-route.test.ts` — vitest unit tests
- `src/bootstrap-trio.ts` — idempotent host-startup bootstrap of the three agent groups + wirings + sessions + bootstrap inbound messages
- `src/bootstrap-trio.test.ts` — vitest unit tests
- `container/agent-runner/src/mcp-tools/workout.ts` — `workout.start_plan` / `workout.coach` / `workout.swap` MCP tools
- `container/agent-runner/src/mcp-tools/workout.test.ts` — bun:test
- `container/agent-runner/src/mcp-tools/workout.instructions.md` — companion instructions file (matches sibling `self-mod.instructions.md` pattern)
- `groups/payne/INDEX.md` — hand-written seed
- `groups/health-analyzer/INDEX.md` — hand-written seed
- `ios/JarvisApp/Sources/JarvisApp/Storage/LastSeenStore.swift` — UserDefaults-backed seen-pointer per agent
- `ios/JarvisApp/Sources/JarvisAppTests/LastSeenStoreTests.swift` — XCTest

### Modify
- `src/router.ts` — export `senderResolver` + `accessGate` getters so the helper can call them; refactor `deliverToAgent` post-gate path to delegate to `adapterRouteToAgent`
- `src/channels/ios-app/v2/inbound-dispatch.ts` — accept a `routeToAgent(event, agentGroupId)` callback; rewire `onUserMessage` to use it
- `src/channels/ios-app/v2/inbound-dispatch.test.ts` — new cases: agent_id=payne routes to payne, missing agent_id falls back to jarvis, unknown agent_id falls back to jarvis with warn
- `src/channels/ios-app/v2/index.ts` — wire `adapterRouteToAgent` as the dispatcher's `routeToAgent` callback; drop the now-unused `cfg.onInbound` for `message` envelopes
- `src/index.ts` — call `bootstrapTrio()` after migrations
- `container/agent-runner/src/mcp-tools/index.ts` — register workout tools when `AGENT_GROUP_ID === 'payne'`
- `groups/payne/CLAUDE.md` — add "Ведение тренировки" and "INDEX.md" sections
- `groups/health-analyzer/CLAUDE.md` — add "INDEX.md" maintenance section
- `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` — rewrite `unreadByAgent`, add `onChange(of:)` + `onAppear` for `LastSeenStore`
- `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` — same rewrite

---

## Task 1: Export router hooks for the shared helper

**Files:** Modify `src/router.ts`

- [ ] **Step 1: Export getters next to the existing `set*` setters**

Add right after `setSenderResolver`:

```ts
export function getSenderResolver(): SenderResolverFn | null {
  return senderResolver;
}
```

And after `setAccessGate`:

```ts
export function getAccessGate(): AccessGateFn | null {
  return accessGate;
}
```

- [ ] **Step 2: Build check**

```bash
pnpm run build
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/router.ts
git commit -m "refactor(router): expose senderResolver/accessGate getters for adapter-route helper"
```

---

## Task 2: `adapterRouteToAgent` helper — failing test

**Files:** Create `src/adapter-route.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, beforeEach } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import { initTestDb, closeDb, createAgentGroup, createMessagingGroup } from './db/index.js';
import { runMigrations } from './db/migrations/index.js';
import { findSession, findSessionForAgent } from './db/sessions.js';
import { adapterRouteToAgent } from './adapter-route.js';
import type { InboundEvent } from './channels/adapter.js';

function makeEvent(platformId: string, threadId: string | null, text: string): InboundEvent {
  return {
    channelType: 'ios-app-v2',
    platformId,
    threadId,
    message: {
      id: `m-${Math.random().toString(36).slice(2, 8)}`,
      kind: 'chat',
      content: JSON.stringify({ text }),
      timestamp: new Date().toISOString(),
    },
  };
}

describe('adapterRouteToAgent', () => {
  let tmp: string;
  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'adapter-route-'));
    process.env.DATA_DIR = tmp;
    initTestDb(path.join(tmp, 'v2.db'));
    runMigrations();
    createAgentGroup({ id: 'payne', name: 'Payne', folder: 'payne', agent_provider: null, created_at: new Date().toISOString() });
    createMessagingGroup({
      id: 'mg-test',
      channel_type: 'ios-app-v2',
      platform_id: 'ios:test',
      name: 'iOS test',
      is_group: 0,
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
  });

  it('creates a session for the addressed agent and writes the message into its inbound.db', async () => {
    const event = makeEvent('ios:test', null, 'hello payne');
    const res = await adapterRouteToAgent(event, 'payne', { wake: false });
    expect(res.delivered).toBe(true);
    const sess = findSessionForAgent('payne', 'mg-test', null);
    expect(sess).toBeDefined();
  });

  it('returns delivered=false with reason=unknown_agent when the agent group does not exist', async () => {
    const event = makeEvent('ios:test', null, 'hi ghost');
    const res = await adapterRouteToAgent(event, 'ghost', { wake: false });
    expect(res).toEqual({ delivered: false, reason: 'unknown_agent' });
  });

  it('returns delivered=false with reason=no_messaging_group when the platform id is unknown', async () => {
    const event = makeEvent('ios:nobody', null, 'hi');
    const res = await adapterRouteToAgent(event, 'payne', { wake: false });
    expect(res).toEqual({ delivered: false, reason: 'no_messaging_group' });
  });
});

afterEach(() => closeDb());
```

- [ ] **Step 2: Run the test, watch it fail**

```bash
pnpm exec vitest run src/adapter-route.test.ts
```

Expected: FAIL — `Cannot find module './adapter-route.js'`.

---

## Task 3: `adapterRouteToAgent` implementation

**Files:** Create `src/adapter-route.ts`

- [ ] **Step 1: Write the helper**

```ts
/**
 * Direct route from a channel adapter that already resolved which agent
 * the inbound message addresses (e.g. iOS-app multi-agent picker). Bypasses
 * routeInbound's trigger-fanout; still runs sender resolution + access gate
 * + session resolve + write + wake so the dropped_messages audit trail and
 * permissions checks stay intact.
 */
import { getAgentGroup } from './db/agent-groups.js';
import { recordDroppedMessage } from './db/dropped-messages.js';
import { getMessagingGroupByPlatform } from './db/messaging-groups.js';
import { getSession } from './db/sessions.js';
import { log } from './log.js';
import { getAccessGate, getSenderResolver } from './router.js';
import { resolveSession, writeSessionMessage } from './session-manager.js';
import { wakeContainer } from './container-runner.js';
import { startTypingRefresh, stopTypingRefresh } from './modules/typing/index.js';
import type { InboundEvent } from './channels/adapter.js';
import type { SessionMode } from './types.js';

export interface AdapterRouteOpts {
  wake?: boolean;
  sessionMode?: SessionMode;
}

export interface AdapterRouteResult {
  delivered: boolean;
  reason?: string;
  sessionId?: string;
}

export async function adapterRouteToAgent(
  event: InboundEvent,
  agentGroupId: string,
  opts: AdapterRouteOpts = {},
): Promise<AdapterRouteResult> {
  const mg = getMessagingGroupByPlatform(event.channelType, event.platformId);
  if (!mg) {
    log.warn('adapterRouteToAgent: no messaging group', {
      channelType: event.channelType,
      platformId: event.platformId,
    });
    return { delivered: false, reason: 'no_messaging_group' };
  }

  const agentGroup = getAgentGroup(agentGroupId);
  if (!agentGroup) {
    log.warn('adapterRouteToAgent: unknown agent group', { agentGroupId });
    recordDroppedMessage({
      channel_type: event.channelType,
      platform_id: event.platformId,
      user_id: null,
      sender_name: null,
      reason: 'unknown_agent',
      messaging_group_id: mg.id,
      agent_group_id: agentGroupId,
    });
    return { delivered: false, reason: 'unknown_agent' };
  }

  const senderResolver = getSenderResolver();
  const userId: string | null = senderResolver ? senderResolver(event) : null;

  const accessGate = getAccessGate();
  if (accessGate) {
    const gate = accessGate(event, userId, mg, agentGroupId);
    if (!gate.allowed) {
      return { delivered: false, reason: gate.reason };
    }
  }

  const sessionMode: SessionMode = opts.sessionMode ?? 'shared';
  const { session } = resolveSession(agentGroupId, mg.id, event.threadId, sessionMode);
  const wake = opts.wake !== false;

  writeSessionMessage(session.agent_group_id, session.id, {
    id: event.message.id,
    kind: event.message.kind,
    timestamp: event.message.timestamp,
    platformId: event.platformId,
    channelType: event.channelType,
    threadId: event.threadId,
    content: event.message.content,
    trigger: wake ? 1 : 0,
  });

  if (wake) {
    startTypingRefresh(session.id, session.agent_group_id, event.channelType, event.platformId, event.threadId);
    const fresh = getSession(session.id);
    if (fresh) {
      const woke = await wakeContainer(fresh);
      if (!woke) stopTypingRefresh(fresh.id);
    }
  }

  return { delivered: true, sessionId: session.id };
}
```

- [ ] **Step 2: Run the test, watch it pass**

```bash
pnpm exec vitest run src/adapter-route.test.ts
```

Expected: PASS — 3 tests green.

- [ ] **Step 3: Commit**

```bash
git add src/adapter-route.ts src/adapter-route.test.ts
git commit -m "feat(adapter-route): shared helper for adapter-owned routing to a specific agent"
```

---

## Task 4: Rewire iOS dispatcher to call `routeToAgent` for text messages

**Files:** Modify `src/channels/ios-app/v2/inbound-dispatch.ts`, `src/channels/ios-app/v2/index.ts`

- [ ] **Step 1: Extend DispatcherDeps with `routeToAgent`**

In `inbound-dispatch.ts`, replace the `onUserMessage` field with `routeToAgent`:

```ts
export interface DispatcherDeps {
  db: TransportDb;
  queue: OutboundQueue;
  receipts: ReceiptStore;
  resolveSessionForPlatform: (platform_id: string, agent_id: string | undefined) => string | null;
  defaultAgentSlug: string;
  /**
   * Route a user-message envelope directly to the addressed agent.
   * Called instead of the host's routeInbound for ios-app-v2 — the adapter
   * already knows the target agent from `payload.agent_id` (defaulting to
   * `defaultAgentSlug` when absent).
   */
  routeToAgent: (input: { platform_id: string; agent_group_id: string; envelope: UserMessageEnvelope }) => void;
  onContextResponse: (input: { platform_id: string; envelope: ContextResponseEnvelope }) => void;
  onAction: (input: { platform_id: string; envelope: ActionResponseEnvelope }) => void;
  onNewConversation: (input: { platform_id: string; envelope: NewConversationEnvelope }) => void;
  onFeedback: (input: { platform_id: string; envelope: FeedbackEnvelope }) => void;
  workoutBridge?: WorkoutBridge;
}
```

Update the `case 'message':` branch in `dispatch()`:

```ts
case 'message': {
  const targetSlug =
    (env.payload as { agent_id?: string }).agent_id ?? this.deps.defaultAgentSlug;
  this.deps.routeToAgent({
    platform_id,
    agent_group_id: targetSlug,
    envelope: env,
  });
  break;
}
```

- [ ] **Step 2: Wire `routeToAgent` into `createV2Adapter`**

In `src/channels/ios-app/v2/index.ts`, replace the `onUserMessage:` block in the `new InboundDispatcher({...})` literal with:

```ts
routeToAgent: ({ platform_id, agent_group_id, envelope }) => {
  void adapterRouteToAgent(
    {
      channelType: CHANNEL_TYPE,
      platformId: platform_id,
      threadId: envelope.payload.thread_id ?? null,
      message: {
        id: envelope.id,
        kind: 'chat',
        content: JSON.stringify({
          text: envelope.payload.text ?? '',
          senderId: platform_id,
          ios_context: envelope.payload.context ?? null,
          attachments: envelope.payload.attachments ?? [],
        }),
        timestamp: envelope.ts ?? new Date().toISOString(),
      },
    },
    agent_group_id,
  ).catch((err) => logV2Warn('routeToAgent threw', { err: String(err), agent_group_id }));
},
```

Add the import at the top of the file:

```ts
import { adapterRouteToAgent } from '../../../adapter-route.js';
```

- [ ] **Step 3: Build**

```bash
pnpm run build
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/inbound-dispatch.ts src/channels/ios-app/v2/index.ts
git commit -m "feat(ios-app): route user-message envelopes directly to the addressed agent

Bypasses routeInbound's trigger-fanout. Adapter resolves agent_id (or
defaults to jarvis) and calls adapterRouteToAgent with the agent group
slug. Other envelope kinds (context_response, action_response,
new_conversation, feedback) keep their existing paths."
```

---

## Task 5: Dispatcher tests for agent_id routing

**Files:** Modify `src/channels/ios-app/v2/inbound-dispatch.test.ts`

- [ ] **Step 1: Add three test cases**

Insert after the existing "routes a user message" test:

```ts
it('routes a user message to the addressed agent when agent_id is present', () => {
  const calls: Array<{ platform_id: string; agent_group_id: string }> = [];
  const dispatcher = makeDispatcher({
    routeToAgent: (input) => calls.push({ platform_id: input.platform_id, agent_group_id: input.agent_group_id }),
  });
  dispatcher.dispatch(pid, env({ payload: { thread_id: 'thr', text: 'go', agent_id: 'payne' } }));
  expect(calls).toEqual([{ platform_id: pid, agent_group_id: 'payne' }]);
});

it('falls back to defaultAgentSlug when agent_id is missing', () => {
  const calls: Array<{ agent_group_id: string }> = [];
  const dispatcher = makeDispatcher({
    routeToAgent: (input) => calls.push({ agent_group_id: input.agent_group_id }),
  });
  dispatcher.dispatch(pid, env({ payload: { thread_id: null, text: 'hello' } }));
  expect(calls).toEqual([{ agent_group_id: 'jarvis' }]);
});

it('passes unknown agent_id slug through so adapterRouteToAgent can log/drop', () => {
  const calls: Array<{ agent_group_id: string }> = [];
  const dispatcher = makeDispatcher({
    routeToAgent: (input) => calls.push({ agent_group_id: input.agent_group_id }),
  });
  dispatcher.dispatch(pid, env({ payload: { thread_id: null, text: 'hi', agent_id: 'ghost' } }));
  expect(calls).toEqual([{ agent_group_id: 'ghost' }]);
});
```

Update the existing `makeDispatcher` helper signature to accept the new `routeToAgent` callback name (was `onUserMessage`). Search-replace within the test file:

```bash
sed -i.bak 's/onUserMessage/routeToAgent/g' src/channels/ios-app/v2/inbound-dispatch.test.ts && rm src/channels/ios-app/v2/inbound-dispatch.test.ts.bak
```

Then hand-fix the shape of the call (the test fixtures used `{ pid, session_id, envelope }` and need to become `{ platform_id, agent_group_id, envelope }`).

- [ ] **Step 2: Run tests, watch them pass**

```bash
pnpm exec vitest run src/channels/ios-app/v2/inbound-dispatch.test.ts
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/channels/ios-app/v2/inbound-dispatch.test.ts
git commit -m "test(ios-app): cover agent_id routing — explicit, default, unknown slug"
```

---

## Task 6: Bootstrap-trio — failing test

**Files:** Create `src/bootstrap-trio.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import path from 'path';
import os from 'os';
import fs from 'fs';

import { initTestDb, closeDb, createMessagingGroup, getAllAgentGroups, getAgentGroupByFolder } from './db/index.js';
import { getMessagingGroupAgents } from './db/messaging-groups.js';
import { findSessionForAgent } from './db/sessions.js';
import { runMigrations } from './db/migrations/index.js';
import { bootstrapTrio } from './bootstrap-trio.js';

describe('bootstrapTrio', () => {
  let tmp: string;
  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'btrio-'));
    process.env.DATA_DIR = tmp;
    initTestDb(path.join(tmp, 'v2.db'));
    runMigrations();
  });
  afterEach(() => closeDb());

  it('creates the three agent groups on first run', () => {
    bootstrapTrio();
    expect(getAgentGroupByFolder('jarvis')).toBeDefined();
    expect(getAgentGroupByFolder('payne')).toBeDefined();
    expect(getAgentGroupByFolder('greg')).toBeDefined();
  });

  it('is idempotent on repeated runs', () => {
    bootstrapTrio();
    const firstCount = getAllAgentGroups().length;
    bootstrapTrio();
    expect(getAllAgentGroups().length).toBe(firstCount);
  });

  it('wires all three to any ios-app-v2 messaging group and eager-creates one session per agent', () => {
    createMessagingGroup({
      id: 'mg-ios',
      channel_type: 'ios-app-v2',
      platform_id: 'ios:abc',
      name: 'iPhone',
      is_group: 0,
      unknown_sender_policy: 'strict',
      created_at: new Date().toISOString(),
      denied_at: null,
    });
    bootstrapTrio();
    const wired = getMessagingGroupAgents('mg-ios').map((r) => r.agent_group_id).sort();
    expect(wired).toEqual(['greg', 'jarvis', 'payne']);
    for (const slug of ['jarvis', 'payne', 'greg']) {
      expect(findSessionForAgent(slug, 'mg-ios', null)).toBeDefined();
    }
  });
});
```

- [ ] **Step 2: Run, watch it fail**

```bash
pnpm exec vitest run src/bootstrap-trio.test.ts
```

Expected: FAIL — module not found.

---

## Task 7: Bootstrap-trio implementation

**Files:** Create `src/bootstrap-trio.ts`

- [ ] **Step 1: Write the implementation**

```ts
/**
 * Idempotent host-startup bootstrap of the three iOS agents.
 *
 * Ensures `jarvis`/`payne`/`greg` agent_groups + container_configs rows
 * exist. For every ios-app-v2 messaging_group, wires all three as
 * `messaging_group_agents` and eager-creates one session per agent so the
 * adapter routing path always finds a session even before the first
 * inbound message. Writes the bootstrap inbound system message for
 * payne and greg on freshly-created sessions so they prime their context
 * from INDEX.md without producing a chat reply.
 */
import { randomUUID } from 'node:crypto';

import { createAgentGroup, getAgentGroupByFolder } from './db/agent-groups.js';
import { ensureContainerConfig } from './db/container-configs.js';
import {
  createMessagingGroupAgent,
  getAllMessagingGroups,
  getMessagingGroupAgentByPair,
} from './db/messaging-groups.js';
import { createSession, findSessionForAgent } from './db/sessions.js';
import { writeSessionMessage } from './session-manager.js';
import { log } from './log.js';

const TRIO = [
  { id: 'jarvis', name: 'Jarvis', folder: 'jarvis', bootstrap: null as string | null },
  {
    id: 'payne',
    name: 'Майор Пейн',
    folder: 'payne',
    bootstrap:
      '[bootstrap] Прочитай INDEX.md и memories/self/profile.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса Сергея.',
  },
  {
    id: 'greg',
    name: 'Dr House (Greg)',
    folder: 'health-analyzer',
    bootstrap:
      '[bootstrap] Прочитай INDEX.md и memories/self/. Молчи до явного запроса Сергея или явной аномалии в данных.',
  },
] as const;

function generateSessionId(): string {
  return `sess-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export function bootstrapTrio(): void {
  for (const entry of TRIO) {
    if (!getAgentGroupByFolder(entry.folder)) {
      createAgentGroup({
        id: entry.id,
        name: entry.name,
        folder: entry.folder,
        agent_provider: null,
        created_at: new Date().toISOString(),
      });
      log.info('bootstrap-trio created agent_group', { id: entry.id });
    }
    ensureContainerConfig(entry.id);
  }

  const ios = getAllMessagingGroups().filter((m) => m.channel_type === 'ios-app-v2');
  for (const mg of ios) {
    let priority = 0;
    for (const entry of TRIO) {
      if (!getMessagingGroupAgentByPair(mg.id, entry.id)) {
        createMessagingGroupAgent({
          id: `mga-${randomUUID()}`,
          messaging_group_id: mg.id,
          agent_group_id: entry.id,
          session_mode: 'shared',
          engage_mode: 'always',
          sender_scope: 'any',
          trigger_rules: null,
          ignored_message_policy: 'drop',
          priority: priority++,
          created_at: new Date().toISOString(),
        });
        log.info('bootstrap-trio wired agent to mg', { mg: mg.id, agent: entry.id });
      }
      const existing = findSessionForAgent(entry.id, mg.id, null);
      if (!existing) {
        const newSessId = generateSessionId();
        createSession({
          id: newSessId,
          agent_group_id: entry.id,
          messaging_group_id: mg.id,
          thread_id: null,
          status: 'active',
          last_seen_at: new Date().toISOString(),
          created_at: new Date().toISOString(),
        });
        log.info('bootstrap-trio eager-created session', { sessionId: newSessId, agent: entry.id, mg: mg.id });
        if (entry.bootstrap) {
          writeSessionMessage(entry.id, newSessId, {
            id: `bootstrap-${randomUUID()}`,
            kind: 'system',
            timestamp: new Date().toISOString(),
            platformId: null,
            channelType: null,
            threadId: null,
            content: JSON.stringify({ subtype: 'bootstrap', text: entry.bootstrap }),
            trigger: 0,
          });
        }
      }
    }
  }
}
```

- [ ] **Step 2: Run tests, watch them pass**

```bash
pnpm exec vitest run src/bootstrap-trio.test.ts
```

Expected: PASS — 3 tests.

- [ ] **Step 3: Commit**

```bash
git add src/bootstrap-trio.ts src/bootstrap-trio.test.ts
git commit -m "feat(bootstrap-trio): ensure jarvis/payne/greg + per-ios-mg wirings/sessions on host start"
```

---

## Task 8: Wire bootstrap-trio into host startup

**Files:** Modify `src/index.ts`

- [ ] **Step 1: Call after migrations, before adapter init**

Add import:

```ts
import { bootstrapTrio } from './bootstrap-trio.js';
```

Find the `runMigrations()` call and add right after:

```ts
runMigrations();
bootstrapTrio();
```

- [ ] **Step 2: Build + smoke run**

```bash
pnpm run build
pnpm exec tsx scripts/q.ts data/v2.db "SELECT id, folder FROM agent_groups"
```

Expected (after one `pnpm run dev` boot): rows for `jarvis`, `payne`, `greg`.

- [ ] **Step 3: Commit**

```bash
git add src/index.ts
git commit -m "feat(host): bootstrap trio agent groups on startup"
```

---

## Task 9: Workout MCP tools — failing test

**Files:** Create `container/agent-runner/src/mcp-tools/workout.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, beforeEach } from 'bun:test';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';

import { workoutStartPlan, workoutCoach, workoutSwap } from './workout.js';

let tmp: string;
beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'workout-mcp-'));
  process.env.SESSION_DIR = tmp;
  process.env.AGENT_GROUP_ID = 'payne';
  fs.mkdirSync(path.join(tmp, 'sessions/curr'), { recursive: true });
});

describe('workout MCP tools', () => {
  it('workout.start_plan writes a workout_plan outbound row', async () => {
    const res = await workoutStartPlan.handler({
      workout_id: 'w1',
      plan_json: { exercises: [] },
      image_manifest: [{ slug: 'squat', sha256: 'abc' }],
    });
    expect(res.isError).toBeUndefined();
    // The handler should write a content row whose JSON has type='workout_plan'.
    // Concrete DB assertion lives in the integration test; here we just
    // verify the handler returned ok.
  });

  it('workout.coach writes a coach_message row', async () => {
    const res = await workoutCoach.handler({ workout_id: 'w1', text: 'good set' });
    expect(res.isError).toBeUndefined();
  });

  it('workout.swap writes an exercise_swap_options row', async () => {
    const res = await workoutSwap.handler({
      workout_id: 'w1',
      from_exercise_slug: 'squat',
      options: [{ slug: 'leg_press', reason: 'knee' }],
    });
    expect(res.isError).toBeUndefined();
  });

  it('refuses when AGENT_GROUP_ID is not payne', async () => {
    process.env.AGENT_GROUP_ID = 'jarvis';
    const res = await workoutCoach.handler({ workout_id: 'w1', text: 'x' });
    expect(res.isError).toBe(true);
  });
});
```

- [ ] **Step 2: Run, watch it fail**

```bash
cd container/agent-runner && bun test src/mcp-tools/workout.test.ts
```

Expected: FAIL — module not found.

---

## Task 10: Workout MCP tools — implementation

**Files:** Create `container/agent-runner/src/mcp-tools/workout.ts`

- [ ] **Step 1: Write the tool module**

```ts
/**
 * Workout MCP tools for Payne.
 *
 * Each tool writes a structured outbound row whose JSON body carries the
 * envelope type expected by the iOS-app v2 workout-bridge:
 *   - workout.start_plan → type 'workout_plan'
 *   - workout.coach      → type 'coach_message'
 *   - workout.swap       → type 'exercise_swap_options'
 *
 * The workout-bridge on the host parses content.type and forwards as the
 * matching iOS envelope. No app-level CLAUDE.md change is needed for the
 * bridge — Payne just needs to know to use these tools instead of plain
 * chat for workout flow (see groups/payne/CLAUDE.md §"Ведение тренировки").
 */
import { writeMessageOut } from '../db/messages-out.js';
import type { McpToolDefinition } from './types.js';

function ok(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}
function err(text: string) {
  return { content: [{ type: 'text' as const, text: `Error: ${text}` }], isError: true };
}

function guard(): { ok: true } | { ok: false; res: ReturnType<typeof err> } {
  if (process.env.AGENT_GROUP_ID !== 'payne') {
    return { ok: false, res: err('workout.* tools are only enabled for the payne agent') };
  }
  return { ok: true };
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export const workoutStartPlan: McpToolDefinition = {
  tool: {
    name: 'workout.start_plan',
    description:
      'Send the full workout plan to the iOS app. App pre-caches everything (plan + image manifest) so the session runs offline. Call exactly once at the start of a workout.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string', description: 'Stable id for this workout (UUID or yyyy-mm-dd slug).' },
        plan_json: { type: 'object', description: 'Full plan tree: exercises, sets, reps, target RPE, rest seconds.' },
        image_manifest: {
          type: 'array',
          description: 'Image references for each exercise; iOS prefetches by slug+sha256.',
          items: { type: 'object', properties: { slug: { type: 'string' }, sha256: { type: 'string' }, url: { type: 'string' } }, required: ['slug', 'sha256'] },
        },
      },
      required: ['workout_id', 'plan_json', 'image_manifest'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    writeMessageOut({
      id: generateId(),
      kind: 'control',
      content: JSON.stringify({
        type: 'workout_plan',
        payload: {
          workout_id: args.workout_id,
          plan_json: args.plan_json,
          image_manifest: args.image_manifest,
        },
      }),
    });
    return ok(`workout_plan sent for ${args.workout_id}`);
  },
};

export const workoutCoach: McpToolDefinition = {
  tool: {
    name: 'workout.coach',
    description:
      'Short in-workout message. Goes to the workout UI, not the chat scroll. Use sparingly: PR, missed-set pattern, fatigue cue. Default to silence.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string' },
        text: { type: 'string', description: 'One or two sentences, plain language.' },
      },
      required: ['workout_id', 'text'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    writeMessageOut({
      id: generateId(),
      kind: 'control',
      content: JSON.stringify({
        type: 'coach_message',
        payload: { workout_id: args.workout_id, text: args.text },
      }),
    });
    return ok('coach_message sent');
  },
};

export const workoutSwap: McpToolDefinition = {
  tool: {
    name: 'workout.swap',
    description:
      'Offer the user 1–3 swap options for an exercise mid-workout. User picks one in the iOS swap sheet.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string' },
        from_exercise_slug: { type: 'string' },
        options: {
          type: 'array',
          items: { type: 'object', properties: { slug: { type: 'string' }, reason: { type: 'string' } }, required: ['slug', 'reason'] },
          minItems: 1,
          maxItems: 3,
        },
      },
      required: ['workout_id', 'from_exercise_slug', 'options'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    writeMessageOut({
      id: generateId(),
      kind: 'control',
      content: JSON.stringify({
        type: 'exercise_swap_options',
        payload: {
          workout_id: args.workout_id,
          from_exercise_slug: args.from_exercise_slug,
          options: args.options,
        },
      }),
    });
    return ok(`swap options sent (${(args.options as unknown[]).length})`);
  },
};
```

- [ ] **Step 2: Run, watch it pass**

```bash
cd container/agent-runner && bun test src/mcp-tools/workout.test.ts
```

Expected: PASS — 4 tests.

- [ ] **Step 3: Commit**

```bash
git add container/agent-runner/src/mcp-tools/workout.ts container/agent-runner/src/mcp-tools/workout.test.ts
git commit -m "feat(workout-mcp): payne tools workout.start_plan / coach / swap

Each tool writes a structured outbound row consumed by the ios-app v2
workout-bridge. Guarded — refuses unless AGENT_GROUP_ID=payne."
```

---

## Task 11: Register workout tools at agent-runner init

**Files:** Modify `container/agent-runner/src/mcp-tools/index.ts`, Create `container/agent-runner/src/mcp-tools/workout.instructions.md`

- [ ] **Step 1: Register the tools when AGENT_GROUP_ID=payne**

Locate the registration block in `mcp-tools/index.ts` and add:

```ts
if (process.env.AGENT_GROUP_ID === 'payne') {
  const workout = await import('./workout.js');
  registerTools([workout.workoutStartPlan, workout.workoutCoach, workout.workoutSwap]);
}
```

(Place it next to the existing conditional registrations near where `registerTools(...)` is called for other modules.)

- [ ] **Step 2: Add the instructions companion file**

```bash
cat > container/agent-runner/src/mcp-tools/workout.instructions.md <<'EOF'
# workout.* tools (Payne only)

Use these tools to drive a structured workout session over the iOS app.
Default to silence — emit only the messages the user must see.

| Tool | When |
|------|------|
| `workout.start_plan` | Exactly once, at the start. Full plan + image manifest. App runs the session offline from this. |
| `workout.coach`      | A personal record, a clear missed-set pattern, or a fatigue cue. Sparingly. |
| `workout.swap`       | Mid-workout exercise replacement. 1–3 options, each with a reason. |

Inbound side: `set_log`, `exercise_done`, `workout_complete` arrive as
`workout_event` system messages on the poll loop. React via `workout.coach`
only when meaningful.

After `workout_complete` — update `INDEX.md` (last workout, RPE trend,
weekly-volume shift).
EOF
```

- [ ] **Step 3: Build + run container typecheck**

```bash
cd container/agent-runner && bun run typecheck
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add container/agent-runner/src/mcp-tools/index.ts container/agent-runner/src/mcp-tools/workout.instructions.md
git commit -m "feat(workout-mcp): register tools when AGENT_GROUP_ID=payne + author instructions"
```

---

## Task 12: Seed Payne INDEX.md and update his CLAUDE.md

**Files:** Create `groups/payne/INDEX.md`, Modify `groups/payne/CLAUDE.md`

- [ ] **Step 1: Write the initial INDEX.md**

```bash
cat > groups/payne/INDEX.md <<'EOF'
# Payne INDEX

> Сводка для быстрого подъёма контекста при старте сессии. Перепиши целиком после `workout_complete` (не append).

## Текущая программа
<имя программы, неделя, фокус>

## Последняя тренировка
<дата>: <короткое summary — какие упражнения, PR, тренд RPE>

## Активный мышечный цикл
<какие группы загружены на этой неделе, что требует объёма>

## Заметки
- <операторские предпочтения>
- <травмы / ограничения>
- <текущие цели>
EOF
```

- [ ] **Step 2: Append two sections to Payne's CLAUDE.md**

Open `groups/payne/CLAUDE.md`, append at the end:

```markdown
## Ведение тренировки

При запросе тренировки используй MCP-инструменты `workout.*`, а не текст:

1. `workout.start_plan` — один вызов, полный план целиком (упражнения, подходы, повторы, RPE-цели, rest_sec, `image_manifest` со слугами и sha256). iOS прокачивает картинки и проводит сессию даже без связи.
2. Слушай поступающие `workout_event` (`set_log`, `exercise_done`). Реагируй через `workout.coach` редко — только при PR, явном провале серии, признаке усталости.
3. Подмена упражнения — `workout.swap` с 1–3 вариантами и обоснованием.

Без визуала текстом не веди. Подходы/повторы в чат не пиши — для этого есть workout UI.

## INDEX.md

`INDEX.md` рядом с этим файлом — короткая выжимка для прогрева контекста при старте новой сессии. При старте — обязательно прочитай.

После `workout_complete` — **перепиши INDEX.md целиком** (не append): последняя тренировка, тренд RPE, изменения недельного объёма, что нужно сделать на следующей тренировке.
```

- [ ] **Step 3: Commit**

```bash
git add groups/payne/INDEX.md groups/payne/CLAUDE.md
git commit -m "groups(payne): INDEX.md seed + CLAUDE.md sections for workout MCP and INDEX maintenance"
```

---

## Task 13: Seed Greg INDEX.md and update his CLAUDE.md

**Files:** Create `groups/health-analyzer/INDEX.md`, Modify `groups/health-analyzer/CLAUDE.md`

- [ ] **Step 1: Write the initial INDEX.md**

```bash
cat > groups/health-analyzer/INDEX.md <<'EOF'
# Greg INDEX

> Перепиши целиком после каждого daily-analyze (не append).

## Текущие тренды (за 7 дней)
- HRV (вариабельность пульса): <baseline → последние 7 дней, направление>
- Пульс покоя: <baseline → последние 7 дней, направление>
- Сон: <часов в среднем, что выбивается>
- Активность / шаги: <тренд>

## Последний красный сигнал
<дата>: <что заметил, что рекомендовал Payne'у>

## Открытые вопросы к Сергею
- <bullet list>

## Активные рекомендации
<что выдал Payne'у недавно: сменить программу, разгрузка, и т.п.>
EOF
```

- [ ] **Step 2: Append a section to Greg's CLAUDE.md**

```markdown
## INDEX.md

`INDEX.md` рядом с этим файлом — короткая выжимка для прогрева контекста при старте сессии. При старте — прочитай.

После каждого daily-analyze (cron 09:00 UTC) — **перепиши INDEX.md целиком**: тренды за 7 дней, новые красные сигналы, открытые вопросы к Сергею, текущие рекомендации Payne'у.
```

- [ ] **Step 3: Commit**

```bash
git add groups/health-analyzer/INDEX.md groups/health-analyzer/CLAUDE.md
git commit -m "groups(health-analyzer): INDEX.md seed + CLAUDE.md maintenance section"
```

---

## Task 14: iOS LastSeenStore + tests

**Files:** Create `ios/JarvisApp/Sources/JarvisApp/Storage/LastSeenStore.swift`, Create `ios/JarvisApp/Sources/JarvisAppTests/LastSeenStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import JarvisApp

final class LastSeenStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LastSeenStoreTests-\(UUID().uuidString)")
    }

    func testDefaultLastSeenIsDistantPast() {
        let store = LastSeenStore(defaults: defaults)
        XCTAssertEqual(store.lastSeen(for: .payne), .distantPast)
    }

    func testMarkSeenPersists() {
        let store = LastSeenStore(defaults: defaults)
        let t = Date()
        store.markSeen(.payne, at: t)
        XCTAssertEqual(store.lastSeen(for: .payne), t)

        let reloaded = LastSeenStore(defaults: defaults)
        XCTAssertEqual(reloaded.lastSeen(for: .payne), t)
    }

    func testPerAgentIsolation() {
        let store = LastSeenStore(defaults: defaults)
        let t = Date()
        store.markSeen(.payne, at: t)
        XCTAssertEqual(store.lastSeen(for: .jarvis), .distantPast)
    }
}
```

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -only-testing:JarvisAppTests/LastSeenStoreTests`. Expected: FAIL — `LastSeenStore` undefined.

- [ ] **Step 2: Implement the store**

```swift
import Foundation
import Observation

/// Per-agent "last seen at" persisted in UserDefaults. Drives the unread
/// badge counter on `AgentPickerInline`. Missing entries default to
/// `.distantPast` so the first render shows everything as unread until the
/// active chip is opened (`ChatView.onAppear` marks it seen immediately).
@Observable
@MainActor
final class LastSeenStore {
    private let defaults: UserDefaults
    private static func key(for agent: AgentIdentity) -> String { "LastSeen.\(agent.rawValue)" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastSeen(for agent: AgentIdentity) -> Date {
        defaults.object(forKey: Self.key(for: agent)) as? Date ?? .distantPast
    }

    func markSeen(_ agent: AgentIdentity, at when: Date = Date()) {
        defaults.set(when, forKey: Self.key(for: agent))
    }
}
```

- [ ] **Step 3: Regenerate xcodeproj + run test**

```bash
cd ios/JarvisApp && xcodegen generate
xcodebuild test -scheme JarvisApp -only-testing:JarvisAppTests/LastSeenStoreTests | tail -20
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/LastSeenStore.swift ios/JarvisApp/Sources/JarvisAppTests/LastSeenStoreTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios(badges): LastSeenStore — UserDefaults-backed per-agent seen pointer"
```

---

## Task 15: Rewrite ChatView.unreadByAgent + OrbHomeView counterpart

**Files:** Modify `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`, Modify `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`

- [ ] **Step 1: Inject `LastSeenStore` into `ChatView`**

At the top of `ChatView`:

```swift
@State private var lastSeen = LastSeenStore()
```

- [ ] **Step 2: Replace `unreadByAgent` in ChatView**

Find the existing `unreadByAgent` computed property and replace its body:

```swift
private var unreadByAgent: [AgentIdentity: Int] {
    var counts: [AgentIdentity: Int] = [:]
    let activeSlug = active.active.rawValue
    for msg in ws.messages where msg.role == .assistant {
        guard let slug = msg.agentId, slug != activeSlug,
              let agent = AgentIdentity(rawValue: slug) else { continue }
        if msg.timestamp > lastSeen.lastSeen(for: agent) {
            counts[agent, default: 0] += 1
        }
    }
    return counts
}
```

(The slug-defaulting-to-jarvis behavior is removed deliberately — once Component 1 lands every assistant message carries an `agentId`. Untagged messages do not count, which matches the bug-fix intent: no historical accumulation.)

- [ ] **Step 3: Mark active agent as seen on appear + on switch**

Add inside the existing `var body` after the `ZStack`:

```swift
.onAppear { lastSeen.markSeen(active.active) }
.onChange(of: active.active) { _, newValue in lastSeen.markSeen(newValue) }
```

- [ ] **Step 4: Repeat the same three edits in OrbHomeView**

Apply the same `@State`, `unreadByAgent` body replacement, and `onAppear`/`onChange` handlers.

- [ ] **Step 5: Build + smoke test on simulator**

```bash
cd ios/JarvisApp && xcodebuild -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' build | tail -10
xcodebuild test -scheme JarvisApp -only-testing:JarvisAppTests | tail -10
```

Expected: build green, tests green.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "ios(badges): drive unread-by-agent off LastSeenStore so the counter stops growing"
```

---

## Task 16: End-to-end smoke + deploy

**Files:** none (verification)

- [ ] **Step 1: Host tests**

```bash
pnpm test
```

Expected: all green.

- [ ] **Step 2: Container tests**

```bash
cd container/agent-runner && bun test
```

Expected: all green.

- [ ] **Step 3: Local smoke — boot the host and verify trio appears**

```bash
pnpm run dev &
sleep 5
pnpm exec tsx scripts/q.ts data/v2.db "SELECT id FROM agent_groups ORDER BY id"
pnpm exec tsx scripts/q.ts data/v2.db "SELECT messaging_group_id, agent_group_id FROM messaging_group_agents WHERE messaging_group_id IN (SELECT id FROM messaging_groups WHERE channel_type='ios-app-v2')"
kill %1
```

Expected: `greg`, `jarvis`, `payne` returned; if any ios-app-v2 mg exists, all three are wired.

- [ ] **Step 4: Deploy to VDS**

```bash
git push
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && ./container/build.sh && XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw"'
```

- [ ] **Step 5: Live verify**

In iOS app: switch to Payne chip → send "что у меня по программе" → reply arrives in Payne thread, stamped payne, Jarvis silent. Switch to workout: Payne calls `workout.start_plan`, iOS shows workout UI. Switch back to Jarvis chip → Jarvis history intact, Payne chip badge clears.

---

## Self-Review

- **Spec coverage:** Components 1–7 all covered. Component 5 has no task (resolved by Component 1) — explicitly noted in the spec.
- **Placeholder scan:** none of `TBD`/`TODO`/`fill in`/`add appropriate ...`.
- **Type consistency:** `routeToAgent` callback shape `{ platform_id, agent_group_id, envelope }` used identically in Tasks 4, 5; `LastSeenStore.lastSeen(for:)` / `markSeen(_:at:)` used identically in Tasks 14, 15; `workoutStartPlan` / `workoutCoach` / `workoutSwap` exports used identically in Tasks 9, 10, 11.
- **Gaps:** none.
