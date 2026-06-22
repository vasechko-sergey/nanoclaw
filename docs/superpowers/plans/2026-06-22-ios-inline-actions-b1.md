# iOS Inline Action Cards (B1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent's `ask_user_question` renders on iOS as a tappable multiple-choice card; the user's tap returns the choice to the blocking agent call — reusing the existing host `ask_question` primitive end-to-end.

**Architecture:** Carry `actions[]` on the v2 `message` payload. The ios-app-v2 adapter renders an `ask_question` outbound row as a `message` whose envelope `id == questionId` and whose `actions` are the options. iOS persists `actions_json`, builds `.action` content in `toChatMessage`, renders the existing `ActionRow`, and on tap sends the existing `action_response` (which the existing host `onAction` router maps back to the question). No new agent tooling.

**Tech Stack:** TypeScript (host adapter, Zod protocol, vitest), Swift/SwiftUI (iOS, XCTest), GRDB. Test module `Jarvis`. iOS sim `iPhone 17`.

---

## Conventions

- Host tests: `pnpm test -- <path>` (vitest). iOS tests: `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/<Class>`.
- iOS test files: `@testable import Jarvis`. After a new `.swift` file: `cd ios/JarvisApp && xcodegen generate`.
- Container typecheck (if touching container/agent-runner — not needed here): N/A for B1.

## File Structure

| File | Responsibility | New? |
|------|----------------|------|
| `shared/ios-app-protocol/v2.ts` | `actions?` on `message` payload + `Action` shape. | Modify |
| `shared/ios-app-protocol/fixtures/message_with_actions.json` | Round-trip fixture. | **New** |
| `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` | `V2.Action` + `actions` on `V2.Message`. | Modify |
| `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift` | Bump fixture count 22→23. | Modify |
| `src/channels/ios-app/v2/index.ts` | Outbound `ask_question` → message with `actions[]`, `id=questionId`. | Modify |
| `ios/JarvisApp/Sources/JarvisApp/Models/StoredAction.swift` | `[StoredAction]` persistence shape. | **New** |
| `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift` | Migration: `actions_json` column. | Modify |
| `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift` | Persist/read `actions_json`; `markActionAnswered`; `StoredMessage.actionsJSON`; `mapRow`. | Modify |
| `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift` | `toChatMessage` builds `.action`. | Modify |
| `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` | tap → also persist answered. | Modify |
| `ios/JarvisApp/project.yml` | Version bump. | Modify |

---

## Task 1: Protocol — `actions[]` on the message payload

**Files:** `shared/ios-app-protocol/v2.ts`, `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`, `shared/ios-app-protocol/fixtures/message_with_actions.json`, `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`

- [ ] **Step 1: Extend the Zod `message` payload** in `shared/ios-app-protocol/v2.ts`. After the `reply_to_id` line (currently line 93) inside the `message` payload `z.object({ … })`, add:

```ts
      actions: z.array(z.object({
        id: z.string().min(1),
        label: z.string().min(1),
        style: z.enum(['primary', 'danger', 'secondary']).optional(),
      })).optional(),
```

- [ ] **Step 2: Mirror in Swift** — `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`. Add an `Action` struct next to `Attachment`:

```swift
    struct Action: Codable, Equatable {
        let id: String
        let label: String
        var style: String?   // "primary" | "danger" | "secondary"
    }
```

In `struct Message`, add the stored property + init param + assignment. The property (after `reply_to_id`):
```swift
        let actions: [Action]?
```
The `init` signature gains `actions: [Action]? = nil` (place it after `reply_to_id`), and the body gets `self.actions = actions`.

- [ ] **Step 3: Add the fixture** `shared/ios-app-protocol/fixtures/message_with_actions.json`:

```json
{
  "v": 2,
  "kind": "data",
  "type": "message",
  "id": "q-123",
  "seq": 7,
  "ts": "2026-06-22T10:00:00Z",
  "payload": {
    "thread_id": "ios:default",
    "text": "Pick one",
    "actions": [
      { "id": "yes", "label": "Yes", "style": "primary" },
      { "id": "no", "label": "No", "style": "secondary" }
    ]
  }
}
```

- [ ] **Step 4: Bump the fixture count** in `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`: change `XCTAssertEqual(urls.count, 22, …)` to `23`.

- [ ] **Step 5: Run the fixture round-trip test (verify it FAILS first if you run before Steps 2/4, else PASS):**
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ProtocolFixtureTests 2>&1 | tail -20
```
Expected after Steps 1-4: PASS (23 fixtures round-trip, including the new actions one).

- [ ] **Step 6: Verify the TS schema accepts it** (host side):
```bash
cd /Users/serg/git/nanoclaw && pnpm exec tsc -p tsconfig.json --noEmit 2>&1 | tail -5
```
Expected: no new type errors (the Zod change compiles).

- [ ] **Step 7: Commit**
```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/fixtures/message_with_actions.json ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift
git commit -m "feat(proto): actions[] on the v2 message payload"
```

---

## Task 2: Host outbound — render `ask_question` as a message with `actions[]`

**Files:** `src/channels/ios-app/v2/index.ts`, test `src/channels/ios-app/v2/inline-actions.test.ts`

The outbound builder (around line 484+) reads `contentType = content.type`. There are branches for `context_request` and the workout bridge, then a default `message` build that calls `handler.sendEnvelopeToDevice(platformId, { id, kind:'data', type:'message', payload:{…} })`. An `ask_question` content row looks like `{ type:'ask_question', questionId, title, question, options:[{label, selectedLabel, value}] }`.

- [ ] **Step 1: Write the failing test** `src/channels/ios-app/v2/inline-actions.test.ts`. Follow the harness pattern in `src/channels/ios-app/v2/integration.test.ts` (read it for the exact setup of the adapter + a fake `sendEnvelopeToDevice` capture). The test:

```ts
import { describe, it, expect } from 'vitest';
// import { makeTestAdapter } from './testing/harness'  // use the same helper integration.test.ts uses

describe('ios-app-v2 inline actions outbound', () => {
  it('renders an ask_question row as a message with actions[] and id == questionId', async () => {
    // ARRANGE: build the adapter with a captured sendEnvelopeToDevice (per harness).
    // ACT: deliver an outbound content:
    //   { type:'ask_question', questionId:'q-1', title:'T', question:'Pick',
    //     options:[{label:'Yes',selectedLabel:'Yes',value:'yes'},
    //              {label:'No',selectedLabel:'No',value:'no'}] }
    // ASSERT on the captured envelope:
    expect(env.id).toBe('q-1');
    expect(env.type).toBe('message');
    expect(env.payload.text).toContain('Pick');
    expect(env.payload.actions).toEqual([
      { id: 'yes', label: 'Yes', style: 'primary' },
      { id: 'no', label: 'No', style: 'primary' },
    ]);
  });

  it('a normal message has no actions', async () => {
    // deliver { text: 'hi' } → captured env.payload.actions is undefined
  });
});
```
(Fill the ARRANGE/ACT using the exact harness API from `integration.test.ts`.)

- [ ] **Step 2: Run, verify FAIL**
```bash
cd /Users/serg/git/nanoclaw && pnpm test -- src/channels/ios-app/v2/inline-actions.test.ts 2>&1 | tail -20
```
Expected: FAIL — actions undefined / id mismatch (no ask_question branch yet).

- [ ] **Step 3: Add the `ask_question` branch** in `src/channels/ios-app/v2/index.ts`, BEFORE the default `message` build (e.g. right after the workout-bridge `if` around line 526):

```ts
      // ask_question outbound — render as a v2 message carrying actions[]. The
      // envelope id == questionId so the device's action_response.action_id maps
      // back to the pending question via the existing onAction router.
      if (contentType === 'ask_question') {
        const questionId = String(content.questionId ?? content.id ?? randomUUID());
        const title = typeof content.title === 'string' ? content.title : '';
        const question = typeof content.question === 'string' ? content.question : '';
        const text = title ? `${title}\n${question}` : question;
        const options = Array.isArray(content.options) ? content.options : [];
        const actions = options.map((o: { label: string; value?: string }) => ({
          id: String(o.value ?? o.label),
          label: String(o.label),
          style: 'primary' as const,
        }));
        handler.sendEnvelopeToDevice(platformId, {
          id: questionId,
          kind: 'data',
          type: 'message',
          payload: {
            thread_id: threadId ?? 'default',
            text,
            actions,
            ...(agentFolderForContent(content) ? {} : {}), // agent_id stamped below by default path is skipped here
          },
        });
        return questionId;
      }
```
Note: if `threadId`/`agentFolder` resolution lives further down in the default path, hoist the small bits you need (thread id, agent folder) above this branch, or inline the same `agent_id` stamping used by the default path so the card routes to the right agent thread. Keep it consistent with the default build — read the surrounding code and match it (don't introduce a second agent-resolution style).

- [ ] **Step 4: Run, verify PASS**
```bash
pnpm test -- src/channels/ios-app/v2/inline-actions.test.ts 2>&1 | tail -20
```

- [ ] **Step 5: Commit**
```bash
git add src/channels/ios-app/v2/index.ts src/channels/ios-app/v2/inline-actions.test.ts
git commit -m "feat(ios-app-v2): render ask_question outbound as message with actions[]"
```

---

## Task 3: iOS persistence — `StoredAction` + `actions_json`

**Files:** `Models/StoredAction.swift` (new), `Storage/Schema.swift`, `Storage/ConversationStoreV2.swift`, tests in `ConversationStoreV2AgentTests.swift`

- [ ] **Step 1: Write the failing test** — append to `ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2AgentTests.swift`:

```swift
    func test_insertInbound_persistsActions_andMarkAnswered() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        let actions = [V2.Action(id: "yes", label: "Yes", style: "primary"),
                       V2.Action(id: "no", label: "No", style: nil)]
        let env = V2.Envelope(v: 2, kind: .data, type: .message, id: "q1", seq: 5,
                              ts: "2026-06-22T00:00:00Z",
                              payload: .message(V2.Message(thread_id: "t", text: "Pick", actions: actions)))
        try store.insertInbound(envelope: env,
                                message: V2.Message(thread_id: "t", text: "Pick", actions: actions))
        let json = try store.fetchById("q1")!.actionsJSON
        XCTAssertNotNil(json)
        let stored = try JSONDecoder().decode([StoredAction].self, from: Data(json!.utf8))
        XCTAssertEqual(stored.map(\.id), ["yes", "no"])
        XCTAssertNil(try store.fetchById("q1")!.actionChoice)

        try store.markActionAnswered(rowId: "q1", choice: "yes")
        XCTAssertEqual(try store.fetchById("q1")!.actionChoice, "yes")
    }
```

- [ ] **Step 2: Run, verify FAIL** (`cannot find 'StoredAction'` / no `actionsJSON`):
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ConversationStoreV2AgentTests/test_insertInbound_persistsActions_andMarkAnswered 2>&1 | tail -20
```

- [ ] **Step 3a: Create** `ios/JarvisApp/Sources/JarvisApp/Models/StoredAction.swift`:

```swift
import Foundation

/// Persistence shape for an inbound action button, stored in `messages.actions_json`.
/// Distinct from the wire `V2.Action` (kept minimal). Synthesized Codable.
struct StoredAction: Codable, Equatable {
    let id: String
    let label: String
    var style: String?   // "primary" | "danger" | "secondary"

    static func from(_ a: V2.Action) -> StoredAction {
        StoredAction(id: a.id, label: a.label, style: a.style)
    }
}
```

- [ ] **Step 3b: Migration** — in `Storage/Schema.swift`, after the `v6-drop-attachments-table` migration and before `try m.migrate(writer)`, add:

```swift
        m.registerMigration("v7-message-actions") { db in
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN actions_json TEXT;")
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN action_choice TEXT;")
        }
```

- [ ] **Step 3c: Store layer** — in `Storage/ConversationStoreV2.swift`:

Add to `StoredMessage` (with `= nil` defaults so the many outbound `StoredMessage(...)` call sites that don't set them keep compiling — only the READ paths must populate them):
```swift
    var actionsJSON: String? = nil
    var actionChoice: String? = nil
```

In `mapRow`, add (before the closing `)`):
```swift
                actionsJSON: row["actions_json"],
                actionChoice: row["action_choice"],
```
…wait — `mapRow` builds `StoredMessage(...)` positionally; add the two args in the SAME order as the struct fields. Append `actionsJSON: row["actions_json"], actionChoice: row["action_choice"]` to the initializer call. **Also update every other `StoredMessage(...)` construction in the file** (`queuedOutbound`, `fetchById`, `observeMessages`, `windowedRows` if not already routed through `mapRow`) — prefer routing them all through `mapRow` if they aren't already; otherwise add the two fields to each. (Tip: `grep -n "StoredMessage(" ConversationStoreV2.swift` and fix each.)

In `insertInbound`, after computing `attachmentsJSON`, compute + store actions. The current INSERT lists columns `(id, dir, seq, text, attachments_json, status, ts, created_at, agent_id)`; add `actions_json`:
```swift
            let actionsJSON: String?
            if let acts = message.actions, !acts.isEmpty {
                let stored = acts.map(StoredAction.from)
                actionsJSON = String(data: try encoder.encode(stored), encoding: .utf8)
            } else {
                actionsJSON = nil
            }
```
and add `actions_json` to the INSERT column list + a `?` + `actionsJSON` to the arguments array.

Add the answered-persist method:
```swift
    func markActionAnswered(rowId: String, choice: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET action_choice=? WHERE id=?",
                           arguments: [choice, rowId])
        }
    }
```

- [ ] **Step 4: Run, verify PASS** (also run the full `ConversationStoreV2AgentTests` + `StoredAttachmentTests` to confirm the `StoredMessage` field additions didn't break other constructions):
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ConversationStoreV2AgentTests -only-testing:JarvisAppTests/StoredAttachmentTests -only-testing:JarvisAppTests/AttachmentMigrationTests 2>&1 | tail -20
```

- [ ] **Step 5: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/StoredAction.swift ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2AgentTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): persist inbound message actions + answered choice"
```

---

## Task 4: iOS render — `.action` content + persist-on-tap

**Files:** `Services/WebSocketClientV2.swift` (`toChatMessage`), `Views/ChatView.swift`, test in `ChatImageMappingTests.swift`

- [ ] **Step 1: Write the failing test** — append to `ios/JarvisApp/Sources/JarvisAppTests/ChatImageMappingTests.swift`:

```swift
    func test_toChatMessage_buildsActionContent_fromActionsJSON() throws {
        let actionsJSON = "[{\"id\":\"yes\",\"label\":\"Yes\",\"style\":\"primary\"},{\"id\":\"no\",\"label\":\"No\"}]"
        let row = StoredMessage(id: "q1", dir: .in_, seq: 1, text: "Pick", attachmentsJSON: nil,
                                contextJSON: nil, status: .delivered, failureReason: nil,
                                ts: 1_700_000_000_000, serverTS: nil, createdAt: 1_700_000_000_000,
                                agentId: "jarvis", actionsJSON: actionsJSON, actionChoice: "yes")
        let msgs = WebSocketClientV2.toChatMessage(row)
        XCTAssertEqual(msgs.count, 1)
        guard case .action(let info) = msgs[0].content else { return XCTFail("expected .action") }
        XCTAssertEqual(info.text, "Pick")
        XCTAssertEqual(info.buttons.map(\.id), ["yes", "no"])
        XCTAssertTrue(info.answered)
        XCTAssertEqual(info.selectedId, "yes")
    }
```
(Match the `StoredMessage(...)` initializer argument order/labels to what Task 3 produced — add `actionsJSON:`/`actionChoice:` in the correct positions.)

- [ ] **Step 2: Run, verify FAIL** (returns `.text`, not `.action`):
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ChatImageMappingTests/test_toChatMessage_buildsActionContent_fromActionsJSON 2>&1 | tail -20
```

- [ ] **Step 3: Build `.action` in `toChatMessage`** (`WebSocketClientV2.swift`). At the TOP of `toChatMessage`, before the attachment/text handling, add an actions branch:

```swift
        // Inbound action card (ask_user_question). Built before the text/
        // attachment paths so a question row renders as a tappable .action.
        if let aj = row.actionsJSON, let data = aj.data(using: .utf8),
           let stored = try? JSONDecoder().decode([StoredAction].self, from: data), !stored.isEmpty {
            let buttons = stored.map { s -> ActionButton in
                let style = ActionButton.Style(rawValue: s.style ?? "primary") ?? .primary
                return ActionButton(id: s.id, label: s.label, style: style)
            }
            var info = ActionInfo(text: row.text, buttons: buttons)
            if let choice = row.actionChoice {
                info.answered = true
                info.selectedId = choice
            }
            var m = ChatMessage(id: row.id, role: role, content: .action(info), timestamp: timestamp)
            m.deliveryStatus = mapDelivery(row.status)
            m.agentId = row.agentId
            return [m]
        }
```
(`ActionButton.Style` is `enum Style: String { case primary, danger, secondary }` — `rawValue:` works. `role`/`timestamp`/`mapDelivery` already exist earlier in the function.)

- [ ] **Step 4: Persist on tap** in `ChatView.swift`. The `MessageListView` `onActionTap` closure currently does `coordinator.sendActionResponse(...)`. Add the persist call so the card stays answered after reload:
```swift
                        onActionTap: { messageId, buttonId, buttonLabel in
                            coordinator.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
                            try? coordinator.ws.stack?.store.markActionAnswered(rowId: messageId, choice: buttonId)
                        },
```
(If `coordinator.ws.stack?.store` isn't the right accessor, use whatever exposes the `ConversationStoreV2` — check `AppCoordinator`/`WebSocketClientV2`; there is a store reference used by `insertOutboundUserMessage`. Match that path.)

- [ ] **Step 5: Run, verify PASS + build**
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ChatImageMappingTests 2>&1 | tail -20
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

- [ ] **Step 6: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift ios/JarvisApp/Sources/JarvisAppTests/ChatImageMappingTests.swift
git commit -m "feat(ios): render inbound action card (.action) + persist answered on tap"
```

---

## Task 5: Version bump, full suites, manual verification

**Files:** `ios/JarvisApp/project.yml`

- [ ] **Step 1: Bump** `MARKETING_VERSION` → `"1.7.0"`, `CURRENT_PROJECT_VERSION` → next int above current (currently 30 → `31`).

- [ ] **Step 2: Regenerate + full iOS unit suite + host tests**
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests 2>&1 | tail -6
pnpm test -- src/channels/ios-app/v2/ 2>&1 | tail -8
```
Expected: iOS `TEST SUCCEEDED`; host ios-app-v2 tests pass.

- [ ] **Step 3: Manual device verification (Sergei — build 31)**
- An agent calls `ask_user_question` (e.g. ask Jarvis a yes/no via a tool path) → a card with the question + buttons appears in the chat.
- Tap a choice → the agent's blocking call receives that choice (it continues); the card shows the answered checkmark.
- The answered card survives killing + relaunching the app (persisted).

- [ ] **Step 4: Commit**
```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "chore(ios): bump to 1.7.0 (build 31) — inline action cards (B1)"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** protocol `actions[]` → Task 1. Host outbound `ask_question`→message+actions, `id=questionId` → Task 2. `actions_json` persistence + `markActionAnswered` + `StoredAction` → Task 3. `toChatMessage` `.action` + tap-persist → Task 4. Existing inbound `onAction` routing + `action_response` + `ActionRow` reused (no task — already present). Bump/tests/manual → Task 5. Non-goals (B2, free-form, new tooling) untouched.
- **Type consistency:** `V2.Action {id,label,style?}` (Task 1) == `StoredAction.from(V2.Action)` (Task 3); `actions_json`/`action_choice` columns (Task 3 migration) == `StoredMessage.actionsJSON`/`actionChoice` (Task 3) == read in `toChatMessage` (Task 4); `ActionInfo(text,buttons)` + `.answered`/`.selectedId` and `ActionButton(id,label,style)` match the existing `Models/Message.swift` definitions; `markActionAnswered(rowId:choice:)` defined Task 3, called Task 4.
- **Placeholder note:** Task 2's test ARRANGE/ACT references the existing `integration.test.ts` harness (read it for the exact helper) — the assertions are concrete; the setup mirrors an existing test rather than inventing an API. Task 3/4 flag the need to update all `StoredMessage(...)` call sites + confirm the store accessor — the compiler enforces both.
