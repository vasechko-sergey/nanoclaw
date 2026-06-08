# Payne — Plan 1: iOS Multi-Agent Routing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow one iOS device (over one WebSocket connection) to talk to multiple agent groups (`jarvis`, `greg`, and later `payne`) as separate chat threads, with a per-thread switcher in the app.

**Architecture:** Add an `agent_id` field to the iOS-app wire protocol (Message / ContextRequest / ContextResponse / NewConversation envelopes). The host's `ios-app` v2 channel adapter resolves an inbound envelope to a `(user, messaging_group, session)` tuple using both the `platform_id` and the `agent_id`. On outbound, the adapter stamps `agent_id` from the sending agent group's slug. iOS holds one `ChatThread` per agent in `ConversationStoreV2` with thread-aware UI.

**Tech Stack:** TypeScript (host, pnpm + vitest), Bun (agent-runner — not touched here), Swift / SwiftUI (iOS app), Zod schemas in `shared/ios-app-protocol/`.

**Prerequisites:** None — this is the first plan in the Payne series and is independently shippable.

**Spec:** [docs/superpowers/specs/2026-06-08-payne-fitness-coach-design.md §7.1](../specs/2026-06-08-payne-fitness-coach-design.md#71-multi-agent-routing).

---

## File map

### Modify
- `shared/ios-app-protocol/v2.ts` — add `agent_id?: string` to Message / ContextRequest / ContextResponse / NewConversation payloads
- `shared/ios-app-protocol/v2.test.ts` — assert the new optional field round-trips
- `shared/ios-app-protocol/fixtures/message_no_context.json` (+ peers) — pin contract: existing fixtures stay without `agent_id`; add one new fixture with it
- `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` — Swift mirror (optional decode, optional encode)
- `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift` — extend to load the new fixture
- `src/channels/ios-app/v2/index.ts` — channel config now carries a map of `agent_id → messaging_group_id`
- `src/channels/ios-app/v2/inbound-dispatch.ts` — change `resolveSessionForPlatform` to accept `agent_id` and look up the right messaging group
- `src/channels/ios-app/v2/inbound-dispatch.test.ts` — new tests for multi-agent dispatch
- `src/channels/ios-app/v2/ws-handler.ts` — outbound envelopes stamped with `agent_id`
- `src/channels/ios-app/v2/ws-handler.test.ts` — assertion for outbound stamping
- `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift` — add `agent_id` column to messages table (default `"jarvis"`) + index
- `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift` — per-agent queries + counters
- `ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcherV2.swift` — route inbound to the right thread
- `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` — outbound Message stamped with active `agent_id`
- `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` — agent switcher chip strip

### Create
- `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift` — `enum AgentIdentity { case jarvis, payne, greg }` with display name, accent color, slug
- `ios/JarvisApp/Sources/JarvisApp/Views/AgentSwitcherStrip.swift` — segment-style chip row used in `ChatView`
- `ios/JarvisApp/Sources/JarvisApp/Models/ActiveAgentState.swift` — `@Observable` (or `ObservableObject`) holding the currently-selected `AgentIdentity`
- `scripts/wire-greg-ios.ts` — one-shot script to create `ios-greg` messaging group + wiring on the VDS (used by the deploy task)
- `shared/ios-app-protocol/fixtures/message_with_agent_id.json` — new fixture

### Touch (config / docs)
- `src/channels/ios-app/v2/types.ts` — extend `DeviceRow` if a per-device default agent is stored
- `docs/api-details.md` — document the new optional field at the protocol surface

---

## Task 1: Add `agent_id` to the wire protocol (TS)

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`
- Modify: `shared/ios-app-protocol/v2.test.ts`

- [ ] **Step 1: Write failing tests**

Open `shared/ios-app-protocol/v2.test.ts` and add at the end:

```ts
import { describe, it, expect } from 'vitest';
import { Envelopes } from './v2.js';

describe('agent_id field', () => {
  it('accepts a Message envelope without agent_id (backward compat)', () => {
    const parsed = Envelopes.Message.parse({
      v: 2, kind: 'data', type: 'message',
      id: '00000000-0000-4000-8000-000000000001',
      seq: 0, ts: '2026-06-08T12:00:00.000Z',
      payload: { thread_id: 't1', text: 'hi' },
    });
    expect(parsed.payload.agent_id).toBeUndefined();
  });

  it('accepts a Message envelope with agent_id', () => {
    const parsed = Envelopes.Message.parse({
      v: 2, kind: 'data', type: 'message',
      id: '00000000-0000-4000-8000-000000000002',
      seq: 1, ts: '2026-06-08T12:00:00.000Z',
      payload: { thread_id: 't1', text: 'hi', agent_id: 'payne' },
    });
    expect(parsed.payload.agent_id).toBe('payne');
  });

  it('accepts NewConversation with agent_id', () => {
    const parsed = Envelopes.NewConversation.parse({
      v: 2, kind: 'control', type: 'new_conversation',
      id: '00000000-0000-4000-8000-000000000003',
      seq: 2, ts: '2026-06-08T12:00:00.000Z',
      payload: { thread_id: 't1', agent_id: 'greg' },
    });
    expect(parsed.payload.agent_id).toBe('greg');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pnpm exec vitest run shared/ios-app-protocol/v2.test.ts
```

Expected: failures on `agent_id` being rejected as unknown key (or stripped).

- [ ] **Step 3: Add the field to the schemas**

In `shared/ios-app-protocol/v2.ts`, change the relevant payload definitions:

```ts
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
    agent_id: z.string().min(1).optional(),
  }),
}),
ContextRequest: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('context_request'),
  payload: z.object({
    request_id: z.string().uuid(),
    fields: z.array(ContextFieldEnum).min(1),
    params: z.record(z.string(), z.unknown()).optional(),
    agent_id: z.string().min(1).optional(),
  }),
}),
ContextResponse: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('context_response'),
  payload: z.object({
    request_id: z.string().uuid(),
    data: z.record(z.string(), z.unknown()),
    errors: z.record(z.string(), z.string()).optional(),
    agent_id: z.string().min(1).optional(),
  }),
}),
NewConversation: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('new_conversation'),
  payload: z.object({
    thread_id: z.string().min(1),
    agent_id: z.string().min(1).optional(),
  }),
}),
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pnpm exec vitest run shared/ios-app-protocol/v2.test.ts
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts
git commit -m "feat(protocol): add optional agent_id to iOS envelopes"
```

---

## Task 2: Add a contract fixture with `agent_id`

**Files:**
- Create: `shared/ios-app-protocol/fixtures/message_with_agent_id.json`
- Modify: `shared/ios-app-protocol/fixtures.test.ts` (load + assert)

- [ ] **Step 1: Create the fixture**

```json
{
  "v": 2,
  "kind": "data",
  "type": "message",
  "id": "11111111-1111-4111-8111-111111111111",
  "seq": 5,
  "ts": "2026-06-08T12:00:00.000Z",
  "payload": {
    "thread_id": "ios-payne-default",
    "text": "Здорово, солдат.",
    "agent_id": "payne"
  }
}
```

- [ ] **Step 2: Add the fixture assertion**

In `shared/ios-app-protocol/fixtures.test.ts`, find the existing list of message fixtures and add an entry. If the file iterates a directory, ensure the new file is picked up automatically. Otherwise add:

```ts
it('loads message_with_agent_id.json', async () => {
  const raw = await import('./fixtures/message_with_agent_id.json', { with: { type: 'json' } });
  const parsed = Envelopes.Message.parse(raw.default);
  expect(parsed.payload.agent_id).toBe('payne');
});
```

- [ ] **Step 3: Run fixture tests**

```bash
pnpm exec vitest run shared/ios-app-protocol/fixtures.test.ts
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add shared/ios-app-protocol/fixtures/message_with_agent_id.json shared/ios-app-protocol/fixtures.test.ts
git commit -m "test(protocol): pin agent_id with new contract fixture"
```

---

## Task 3: Swift protocol mirror

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`

- [ ] **Step 1: Write the failing fixture test**

In `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`, add:

```swift
func test_message_with_agent_id_decodes() throws {
  let url = Bundle.module.url(forResource: "message_with_agent_id", withExtension: "json")!
  let data = try Data(contentsOf: url)
  let env = try V2.decode(data)
  guard case let .message(msg) = env.payload else {
    XCTFail("expected message payload"); return
  }
  XCTAssertEqual(msg.agentId, "payne")
}
```

- [ ] **Step 2: Run; expect failure**

```bash
cd ios/JarvisApp
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing JarvisAppTests/ProtocolFixtureTests/test_message_with_agent_id_decodes
```

Expected: compile error — `agentId` doesn't exist on `V2.Message`.

- [ ] **Step 3: Add the field**

In `V2.swift`, locate `struct Message: Codable, Equatable { ... }` and add:

```swift
struct Message: Codable, Equatable {
  let threadId: String
  let text: String
  let attachments: [Attachment]?
  let context: InlineContext?
  let agentId: String?

  enum CodingKeys: String, CodingKey {
    case threadId = "thread_id"
    case text
    case attachments
    case context
    case agentId = "agent_id"
  }
}
```

Apply the same shape to `ContextRequest`, `ContextResponse`, `NewConversation` (each gets an `agentId: String?` with `case agentId = "agent_id"`).

- [ ] **Step 4: Run tests**

```bash
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing JarvisAppTests/ProtocolFixtureTests
```

Expected: green. All existing fixture tests still pass because `agentId` is optional.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift
git commit -m "feat(ios-protocol): mirror agent_id in Swift V2"
```

---

## Task 4: Channel config carries an agent → messaging-group map

**Files:**
- Modify: `src/channels/ios-app/v2/index.ts`
- Modify: `src/channels/ios-app/v2/types.ts`

The current channel registration maps one platform_id to one messaging group. We extend the resolver to take an `agent_id` argument and consult a configured map.

- [ ] **Step 1: Find the registration and the resolver glue**

```bash
grep -nE 'IOS_APP_TARGET|resolveSessionForPlatform' src/channels/ios-app/v2/index.ts
```

Expected: hits showing where the device → messaging_group lookup is wired.

- [ ] **Step 2: Introduce an `IosAgentRouting` config type**

In `src/channels/ios-app/v2/types.ts` at the bottom:

```ts
export interface IosAgentRouting {
  /** Slug → messaging_group_id. The "default" key is the fallback when an inbound has no agent_id. */
  agents: Record<string, string>;
  /** Slug used when no agent_id is present on inbound envelopes. Must be a key in `agents`. */
  defaultAgentSlug: string;
}
```

- [ ] **Step 3: Wire the routing into the channel adapter**

In `src/channels/ios-app/v2/index.ts`, change the place that currently reads `IOS_APP_TARGET_MESSAGING_GROUP` into a JSON map. Read from a new env var `IOS_APP_AGENT_ROUTING` shaped:

```
IOS_APP_AGENT_ROUTING='{"defaultAgentSlug":"jarvis","agents":{"jarvis":"mg-...","greg":"mg-..."}}'
```

Replace the single-string resolver with:

```ts
function loadRouting(): IosAgentRouting {
  const raw = process.env.IOS_APP_AGENT_ROUTING;
  if (!raw) {
    // Backward compat: fall back to the legacy single-MG env var.
    const single = process.env.IOS_APP_TARGET_MESSAGING_GROUP;
    if (!single) throw new Error('ios-app channel: set IOS_APP_AGENT_ROUTING or IOS_APP_TARGET_MESSAGING_GROUP');
    return { defaultAgentSlug: 'jarvis', agents: { jarvis: single } };
  }
  const parsed = JSON.parse(raw) as IosAgentRouting;
  if (!parsed.agents[parsed.defaultAgentSlug]) {
    throw new Error(`ios-app channel: defaultAgentSlug "${parsed.defaultAgentSlug}" missing from agents map`);
  }
  return parsed;
}
```

Pass `routing` down into the `InboundDispatcher` via deps.

- [ ] **Step 4: Run host tests to verify nothing breaks yet**

```bash
pnpm exec vitest run src/channels/ios-app/v2/
```

Expected: green (no behaviour change yet — resolver still resolves the same way for callers that pass no agent_id).

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/index.ts src/channels/ios-app/v2/types.ts
git commit -m "feat(ios-app): config map for agent → messaging_group routing"
```

---

## Task 5: Inbound dispatcher routes by `agent_id`

**Files:**
- Modify: `src/channels/ios-app/v2/inbound-dispatch.ts`
- Modify: `src/channels/ios-app/v2/inbound-dispatch.test.ts`

- [ ] **Step 1: Write failing tests**

Add to `src/channels/ios-app/v2/inbound-dispatch.test.ts`:

```ts
it('routes Message with agent_id="payne" to the payne messaging group session', () => {
  const calls: Array<{ session_id: string; text: string }> = [];
  const dispatcher = makeDispatcher({
    resolveSessionForPlatform: (platform_id, agent_id) => {
      if (platform_id === 'ios-app:dev1' && agent_id === 'payne') return 'sess-payne';
      if (platform_id === 'ios-app:dev1' && agent_id === 'jarvis') return 'sess-jarvis';
      return null;
    },
    onUserMessage: ({ session_id, envelope }) =>
      calls.push({ session_id, text: envelope.payload.text }),
  });

  dispatcher.dispatch('ios-app:dev1', messageEnvelope({ agent_id: 'payne', text: 'go' }));
  dispatcher.dispatch('ios-app:dev1', messageEnvelope({ agent_id: 'jarvis', text: 'hi' }));

  expect(calls).toEqual([
    { session_id: 'sess-payne', text: 'go' },
    { session_id: 'sess-jarvis', text: 'hi' },
  ]);
});

it('falls back to the default agent when agent_id is absent', () => {
  const calls: string[] = [];
  const dispatcher = makeDispatcher({
    resolveSessionForPlatform: (_, agent_id) => `sess-${agent_id ?? 'unknown'}`,
    onUserMessage: ({ session_id }) => calls.push(session_id),
  });
  dispatcher.dispatch('ios-app:dev1', messageEnvelope({ text: 'no agent' }));
  // Adapter should resolve "no agent" via the configured default slug,
  // which the test harness threads through `resolveSessionForPlatform`.
  expect(calls).toEqual(['sess-default']);
});
```

The test harness factory `makeDispatcher` may need a small update (use the existing one in `testing/harness.ts` — add an `agent_id` second arg to its resolver injection).

- [ ] **Step 2: Run; expect failure**

```bash
pnpm exec vitest run src/channels/ios-app/v2/inbound-dispatch.test.ts
```

- [ ] **Step 3: Change the dispatcher signature**

In `inbound-dispatch.ts`, change `resolveSessionForPlatform` to accept an optional agent_id and have the dispatcher pull it out of the envelope where applicable:

```ts
export interface DispatcherDeps {
  // ... existing fields ...
  resolveSessionForPlatform: (platform_id: string, agent_id: string | undefined) => string | null;
  /** Slug used when an inbound envelope omits agent_id. */
  defaultAgentSlug: string;
}

// Inside dispatch(), where session_id is resolved:
const inferredAgent =
  (env.type === 'message' || env.type === 'context_response' ||
   env.type === 'new_conversation' || env.type === 'action_response' ||
   env.type === 'feedback')
    ? ((env.payload as { agent_id?: string }).agent_id ?? this.deps.defaultAgentSlug)
    : this.deps.defaultAgentSlug;
const session_id = this.deps.resolveSessionForPlatform(platform_id, inferredAgent);
```

- [ ] **Step 4: Run tests until green**

```bash
pnpm exec vitest run src/channels/ios-app/v2/
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/inbound-dispatch.ts src/channels/ios-app/v2/inbound-dispatch.test.ts src/channels/ios-app/v2/testing/harness.ts
git commit -m "feat(ios-app): route inbound by agent_id with default fallback"
```

---

## Task 6: Stamp outbound envelopes with `agent_id`

**Files:**
- Modify: `src/channels/ios-app/v2/ws-handler.ts` (or wherever outbound envelopes are built — find via grep)
- Modify: `src/channels/ios-app/v2/ws-handler.test.ts`

- [ ] **Step 1: Locate outbound construction**

```bash
grep -nE 'type: .message|kind: .data' src/channels/ios-app/v2/*.ts
```

The outbound queue projects messages from a sending agent group; find the projection step that copies `text` into the payload.

- [ ] **Step 2: Write a failing assertion**

In `ws-handler.test.ts` (or add a new test file `outbound-queue.test.ts` test):

```ts
it('stamps outbound Message envelopes with the sending agent_id', () => {
  const sent: AnyEnvelope[] = [];
  const harness = makeHarness({
    onSend: (env) => sent.push(env),
    agentRouting: {
      defaultAgentSlug: 'jarvis',
      agents: { jarvis: 'mg-jarvis', payne: 'mg-payne' },
    },
  });
  harness.sendOutboundFromAgentGroup('payne', { text: 'отдых 60 секунд' });
  const msg = sent.find((e) => e.type === 'message');
  expect(msg).toBeDefined();
  expect((msg as any).payload.agent_id).toBe('payne');
});
```

- [ ] **Step 3: Add the stamping**

Where the outbound Message envelope is built, look up the sending messaging_group → agent_id from the routing map (reverse lookup) and set `payload.agent_id` accordingly:

```ts
function reverseLookupAgent(routing: IosAgentRouting, mgId: string): string {
  for (const [slug, mg] of Object.entries(routing.agents)) {
    if (mg === mgId) return slug;
  }
  return routing.defaultAgentSlug;
}

// inside the outbound builder where you have messaging_group_id and payload:
const agent_id = reverseLookupAgent(routing, messaging_group_id);
const payload = { ...basePayload, agent_id };
```

- [ ] **Step 4: Run all ios-app channel tests**

```bash
pnpm exec vitest run src/channels/ios-app/v2/
```

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/ws-handler.ts src/channels/ios-app/v2/ws-handler.test.ts
git commit -m "feat(ios-app): stamp outbound envelopes with agent_id"
```

---

## Task 7: iOS storage — per-agent threading

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift`

- [ ] **Step 1: Schema migration**

In `Schema.swift`, add an `agent_id TEXT NOT NULL DEFAULT 'jarvis'` column to the messages table and an index. If the schema migrates by version number, bump it:

```swift
// Migration N: add agent_id to messages
db.execute(
  """
  ALTER TABLE messages ADD COLUMN agent_id TEXT NOT NULL DEFAULT 'jarvis';
  CREATE INDEX IF NOT EXISTS messages_agent_id_idx ON messages(agent_id, ts DESC);
  """
)
```

- [ ] **Step 2: Make queries agent-aware**

Open `ConversationStoreV2.swift`. Add an `agentId: String` parameter to the read APIs (e.g. `loadTimeline`, `unreadCount`). For each method, narrow with `WHERE agent_id = ?`. For inserts, take the agent_id as a parameter.

```swift
func loadTimeline(forAgent agentId: String, limit: Int) throws -> [Message] {
  try db.query("SELECT ... FROM messages WHERE agent_id = ? ORDER BY ts DESC LIMIT ?",
               bindings: [agentId, limit])
}

func insert(message: Message, agentId: String) throws {
  try db.execute("INSERT INTO messages (... , agent_id) VALUES (..., ?)",
                 bindings: [..., agentId])
}
```

- [ ] **Step 3: Write a Swift unit test**

In `ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2Tests.swift`:

```swift
func test_unreadCount_isolatedPerAgent() throws {
  let store = ConversationStoreV2.inMemory()
  try store.insert(message: sampleMessage(text: "j1"), agentId: "jarvis")
  try store.insert(message: sampleMessage(text: "p1"), agentId: "payne")
  try store.insert(message: sampleMessage(text: "p2"), agentId: "payne")
  XCTAssertEqual(try store.unreadCount(forAgent: "jarvis"), 1)
  XCTAssertEqual(try store.unreadCount(forAgent: "payne"), 2)
}
```

- [ ] **Step 4: Run iOS tests**

```bash
cd ios/JarvisApp
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing JarvisAppTests/ConversationStoreV2Tests
```

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2Tests.swift
git commit -m "feat(ios): per-agent message storage in ConversationStoreV2"
```

---

## Task 8: `AgentIdentity` model + `ActiveAgentState` observable

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Models/ActiveAgentState.swift`

- [ ] **Step 1: Create `AgentIdentity.swift`**

```swift
import SwiftUI

enum AgentIdentity: String, CaseIterable, Identifiable, Codable {
  case jarvis
  case payne
  case greg

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .jarvis: return "Джарвис"
    case .payne:  return "Майор Пейн"
    case .greg:   return "Грег"
    }
  }

  var accentColor: Color {
    switch self {
    case .jarvis: return .blue
    case .payne:  return .orange
    case .greg:   return .green
    }
  }
}
```

- [ ] **Step 2: Create `ActiveAgentState.swift`**

```swift
import Foundation
import Combine

final class ActiveAgentState: ObservableObject {
  @Published var active: AgentIdentity {
    didSet { UserDefaults.standard.set(active.rawValue, forKey: Self.key) }
  }
  private static let key = "ActiveAgentState.active"

  init() {
    let raw = UserDefaults.standard.string(forKey: Self.key) ?? AgentIdentity.jarvis.rawValue
    self.active = AgentIdentity(rawValue: raw) ?? .jarvis
  }
}
```

- [ ] **Step 3: Wire it in `JarvisApp.swift`**

Inject as an `@StateObject` at the app root and provide via `.environmentObject` to `ChatView`.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AgentIdentity.swift ios/JarvisApp/Sources/JarvisApp/Models/ActiveAgentState.swift ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift
git commit -m "feat(ios): AgentIdentity + ActiveAgentState models"
```

---

## Task 9: `AgentSwitcherStrip` SwiftUI view

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/AgentSwitcherStrip.swift`

- [ ] **Step 1: Implement the strip**

```swift
import SwiftUI

struct AgentSwitcherStrip: View {
  @EnvironmentObject var active: ActiveAgentState
  let unreadCounts: [AgentIdentity: Int]

  var body: some View {
    HStack(spacing: 8) {
      ForEach(AgentIdentity.allCases) { agent in
        Button {
          active.active = agent
        } label: {
          HStack(spacing: 6) {
            Text(agent.displayName)
              .font(.subheadline.weight(active.active == agent ? .semibold : .regular))
            if let count = unreadCounts[agent], count > 0 {
              Text("\(count)")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.red))
                .foregroundStyle(.white)
            }
          }
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(
            Capsule().fill(active.active == agent ? agent.accentColor.opacity(0.18) : Color.clear)
          )
          .overlay(
            Capsule().stroke(agent.accentColor.opacity(active.active == agent ? 0.6 : 0.2), lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal)
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/AgentSwitcherStrip.swift
git commit -m "feat(ios): AgentSwitcherStrip chip-row UI"
```

---

## Task 10: `ChatView` filters by active agent

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Add the strip and bind the message list to active agent**

At the top of `ChatView`:

```swift
@EnvironmentObject var active: ActiveAgentState
@State private var unreadCounts: [AgentIdentity: Int] = [:]
```

Above the message list, embed:

```swift
AgentSwitcherStrip(unreadCounts: unreadCounts)
  .padding(.vertical, 6)
```

Change the message-list view-model query to filter on `active.active.rawValue`. When `active.active` changes (e.g. via `.onChange(of: active.active)`), reload the list and recompute unread counts.

- [ ] **Step 2: Recompute unread counts on every inbound**

Wherever the inbound dispatcher notifies the chat view of a new message, refresh `unreadCounts` per agent via `ConversationStoreV2.unreadCount(forAgent:)`.

- [ ] **Step 3: Run a UI smoke test (manual)**

Boot the simulator, send a fake inbound for each agent via the existing fixture replay path (or `WebSocketClientV2` test stub), confirm chips update and switching filters the list.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "feat(ios): agent strip in ChatView with per-agent filtering"
```

---

## Task 11: Outbound `agent_id` from iOS

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift`

- [ ] **Step 1: Stamp outgoing Message envelopes**

In `TransportV2.swift`, locate where a `Message` envelope is built before being enqueued for send. Add a parameter `agentId: String` and write it into the payload:

```swift
func enqueueMessage(text: String, attachments: [V2.Attachment]?, agentId: String) {
  let env = V2.Envelope.message(
    .init(threadId: defaultThreadId(forAgent: agentId),
          text: text,
          attachments: attachments,
          context: nil,
          agentId: agentId)
  )
  outboundQueue.enqueue(env)
}
```

Callers in `ChatView` send-button handler: pass `active.active.rawValue`.

- [ ] **Step 2: Same stamping for `new_conversation`** when the user resets a thread per agent.

- [ ] **Step 3: Run iOS tests**

```bash
cd ios/JarvisApp
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "feat(ios): stamp outbound envelopes with active agent_id"
```

---

## Task 12: Inbound dispatcher writes to the right agent thread

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcherV2.swift`

- [ ] **Step 1: Read `agent_id` from inbound payloads, default to `jarvis`**

```swift
let incomingAgentId = (env.payload.message?.agentId
  ?? env.payload.contextRequest?.agentId
  ?? env.payload.newConversation?.agentId
  ?? "jarvis")
try store.insert(message: ..., agentId: incomingAgentId)
```

- [ ] **Step 2: Test with a fake inbound for `payne`**

Use the existing inbound test harness (search for `XCTestCase` files that exercise `InboundDispatcherV2`) and add:

```swift
func test_inboundMessage_routesToAgentThread() throws {
  let store = ConversationStoreV2.inMemory()
  let dispatcher = InboundDispatcherV2(store: store, /* ... */)
  let env = sampleMessageEnvelope(text: "вперёд", agentId: "payne")
  try dispatcher.dispatch(env)
  XCTAssertEqual(try store.unreadCount(forAgent: "payne"), 1)
  XCTAssertEqual(try store.unreadCount(forAgent: "jarvis"), 0)
}
```

- [ ] **Step 3: Run tests**

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcherV2.swift ios/JarvisApp/Sources/JarvisAppTests/InboundDispatcherV2Tests.swift
git commit -m "feat(ios): inbound dispatcher writes to per-agent threads"
```

---

## Task 13: One-shot wiring script for `ios-greg`

**Files:**
- Create: `scripts/wire-greg-ios.ts`

- [ ] **Step 1: Implement the script**

```ts
import { initDb, getDb } from '../src/db/connection.js';
import { createMessagingGroup } from '../src/db/messaging-groups.js';
import { createWiring } from '../src/db/wirings.js'; // confirm exact export name

const DB_PATH = process.env.NANOCLAW_DB ?? '/home/nanoclaw/nanoclaw/data/v2.db';

initDb(DB_PATH);
const mgId = `ios-greg`;
createMessagingGroup({
  id: mgId,
  channel_type: 'ios-app',
  thread_id: 'ios-greg-default',
  unknown_sender_policy: 'reject',
  created_at: new Date().toISOString(),
});
createWiring({
  messaging_group_id: mgId,
  agent_group_id: 'greg',
  session_mode: 'shared',
});
console.log(`wired ${mgId} -> greg`);
```

If any of these helper imports don't match the actual codebase, follow the same shape as `scripts/init-first-agent.ts` (which already does messaging-group + wiring CRUD against the central DB).

- [ ] **Step 2: Dry-run locally against a copy of the DB**

```bash
cp /Users/serg/git/nanoclaw/data/v2.db /tmp/wire-test.db
NANOCLAW_DB=/tmp/wire-test.db pnpm exec tsx scripts/wire-greg-ios.ts
pnpm exec tsx scripts/q.ts /tmp/wire-test.db "SELECT * FROM messaging_groups WHERE id = 'ios-greg'"
```

Expected: row present.

- [ ] **Step 3: Commit**

```bash
git add scripts/wire-greg-ios.ts
git commit -m "feat(scripts): wire ios-greg messaging group"
```

---

## Task 14: Deploy to VDS

- [ ] **Step 1: Push to remote**

```bash
git push origin main
```

- [ ] **Step 2: Update VDS**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm install --frozen-lockfile && pnpm run build"'
```

- [ ] **Step 3: Set `IOS_APP_AGENT_ROUTING`**

Find the current `ios-jarvis` mg id:

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && pnpm exec tsx scripts/q.ts data/v2.db \"SELECT id, thread_id FROM messaging_groups WHERE channel_type=\\\"ios-app\\\"\""'
```

Set the env var in `/home/nanoclaw/nanoclaw/.env` (append, do not commit):

```
IOS_APP_AGENT_ROUTING={"defaultAgentSlug":"jarvis","agents":{"jarvis":"<jarvis-mg-id>","greg":"ios-greg"}}
```

- [ ] **Step 4: Run the wiring script on the VDS**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && pnpm exec tsx scripts/wire-greg-ios.ts"'
```

- [ ] **Step 5: Restart the service**

```bash
ssh root@148.253.211.164 'systemctl --machine=nanoclaw@.host --user restart nanoclaw'
ssh root@148.253.211.164 'journalctl --machine=nanoclaw@.host --user -u nanoclaw -n 50'
```

Expected: clean startup, no schema errors.

- [ ] **Step 6: Manual smoke test**

In the new iOS build (built locally for TestFlight or run on tethered device):
1. Open the app — chip strip shows Джарвис / Майор Пейн / Грег. (Payne won't have a wired mg yet — Plan 2 — so messages to Payne return a "no wiring" error, which is fine and expected.)
2. Send a message to Greg ("привет"). Expect Greg's reply in the Грег thread (not Jarvis's).
3. Send a message to Jarvis ("проверка"). Expect Jarvis's reply in his own thread, no cross-talk.

---

## Acceptance

- All ios-app channel vitest suites green: `pnpm exec vitest run src/channels/ios-app/v2/`
- All protocol contract tests green (TS + Swift)
- Manual smoke from Task 14 step 6 passes
- One device-WS connection serves three threads with independent unread counts

---

## Self-review notes

1. **Spec coverage:** All §7.1 items covered. §7.1 explicitly says "iOS multi-agent routing"; this plan delivers it. §6.1 (a2a destinations for Payne) is deferred to Plan 2 — correctly out of scope.
2. **Backwards compat:** `agent_id` is optional everywhere, defaulting to `jarvis` (matching the existing single-agent assumption). Legacy iOS builds continue to work against the new host.
3. **Greg side-effect:** Plan deliberately wires `ios-greg` so the multi-agent UI lands with two working agents (Jarvis + Greg) even if Payne is still in Plan 2.
4. **Watch out:** the env var name `IOS_APP_TARGET_MESSAGING_GROUP` may not exist in the actual codebase — Task 4 step 1 uses `grep` to locate the real glue. Do not assume the literal name.
