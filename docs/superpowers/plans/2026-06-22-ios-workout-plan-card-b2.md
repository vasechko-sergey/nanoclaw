# iOS Inline Workout-Plan Card (B2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Payne's workout plan renders as a compact inline chat card with a "Начать тренировку" button (replacing the persistent button); tapping opens the live WorkoutView with the already-held plan; finishing/aborting marks the card done — persisted across reload.

**Architecture:** The `workout_plan` envelope already arrives decoded on-device. Instead of auto-opening WorkoutView, persist the plan as a chat message (`workout_plan_json` column), render it via a new `.workoutPlan` content case + `WorkoutPlanRow`, open WorkoutView from the stored plan on tap, and reuse the B1 `action_choice` column + answered visual for the done-state. iOS-only — no protocol or host change.

**Tech Stack:** Swift/SwiftUI, GRDB, XCTest. Test module `Jarvis`. iOS sim `iPhone 17`. Test files use `@testable import Jarvis`. After adding a `.swift` file or editing `project.yml`: `cd ios/JarvisApp && xcodegen generate`.

---

## Conventions

- iOS tests: `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/<Class>[/<method>]`. First cold sim build is slow — be patient.
- `StoredMessage` field order (current): `id, dir, seq, text, attachmentsJSON, contextJSON, status, failureReason, ts, serverTS, createdAt, agentId, actionsJSON, actionChoice`. This plan appends `workoutPlanJSON` at the END.
- No host tests (no host change). No `pnpm` needed.

## File Structure

| File | Responsibility | New? |
|------|----------------|------|
| `Storage/Schema.swift` | Migration `v8-workout-plan`: `workout_plan_json TEXT`. | Modify |
| `Storage/ConversationStoreV2.swift` | `StoredMessage.workoutPlanJSON`; read-path population; `insertWorkoutPlan`. | Modify |
| `Models/Message.swift` | `.workoutPlan(WorkoutPlanCardInfo)` content case + `WorkoutPlanCardInfo`. | Modify |
| `Components/MessageRow.swift` | `WorkoutPlanRow` + route `.workoutPlan`. | Modify |
| `Services/WebSocketClientV2.swift` | `toChatMessage` builds `.workoutPlan` from `workoutPlanJSON`. | Modify |
| `Services/AppCoordinator.swift` | `insertWorkoutPlan` forwarder; `handleWorkoutEnvelope` persists instead of `.planReceived`. | Modify |
| `Views/ChatView.swift` | Remove persistent button; `WorkoutPresentation.messageId`; `onWorkoutStart` wiring; done-on-close; drop `.planReceived` open. | Modify |
| `Components/MessageListView.swift` | Thread `onWorkoutStart` to `MessageRow` (mirror `onActionTap`). | Modify |
| `ios/JarvisApp/project.yml` | Version/build bump. | Modify |
| Tests | store insert/read; `toChatMessage` mapping. | Modify |

---

## Task 1: Storage — `workout_plan_json` column + `insertWorkoutPlan`

**Files:** `Storage/Schema.swift`, `Storage/ConversationStoreV2.swift`, test `Sources/JarvisAppTests/ConversationStoreV2AgentTests.swift`

- [ ] **Step 1: Write the failing test** — append to `ConversationStoreV2AgentTests.swift`:

```swift
    func test_insertWorkoutPlan_persistsPlanJSON_idempotent_andMarkDone() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "День груди", week: 3, intensityLabel: "средняя",
            exercises: [
                ExercisePlan(exerciseSlug: "bench", targetSets: 4, targetReps: "8-10", targetRir: 2, restSec: 120, notes: nil),
                ExercisePlan(exerciseSlug: "fly", targetSets: 3, targetReps: "12-15", targetRir: 1, restSec: 90, notes: nil),
            ],
            imageManifest: [])

        try store.insertWorkoutPlan(id: plan.workoutId, agentId: "payne", plan: plan)
        let row = try store.fetchById("w1")!
        XCTAssertNotNil(row.workoutPlanJSON)
        XCTAssertEqual(row.agentId, "payne")
        XCTAssertNil(row.actionChoice)
        // The stored JSON decodes back to the same plan.
        let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: Data(row.workoutPlanJSON!.utf8))
        XCTAssertEqual(decoded, plan)

        // Idempotent: a second insert with the same id doesn't duplicate.
        try store.insertWorkoutPlan(id: plan.workoutId, agentId: "payne", plan: plan)
        let count = try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages WHERE id=?", arguments: ["w1"]) }
        XCTAssertEqual(count, 1)

        // Done-state reuses the B1 action_choice column.
        try store.markActionAnswered(rowId: "w1", choice: "completed")
        XCTAssertEqual(try store.fetchById("w1")!.actionChoice, "completed")
    }
```

- [ ] **Step 2: Run, verify FAIL** (`no member 'insertWorkoutPlan'` / `no member 'workoutPlanJSON'`):
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ConversationStoreV2AgentTests/test_insertWorkoutPlan_persistsPlanJSON_idempotent_andMarkDone 2>&1 | tail -20
```

- [ ] **Step 3a: Migration** — in `Storage/Schema.swift`, after the `v7-message-actions` migration and before `try m.migrate(writer)`, add:
```swift
        m.registerMigration("v8-workout-plan") { db in
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN workout_plan_json TEXT;")
        }
```

- [ ] **Step 3b: `StoredMessage` field** — in `Storage/ConversationStoreV2.swift`, add to `struct StoredMessage` after `actionChoice`:
```swift
    var workoutPlanJSON: String? = nil
```

- [ ] **Step 3c: Populate all read-from-row sites** — grep the file: `grep -n "StoredMessage(" Storage/ConversationStoreV2.swift` (5 sites: ~80, ~285, ~309, ~344, and the static `mapRow` ~396). To EACH, append the field after `actionChoice: row["action_choice"]`:
```swift
                workoutPlanJSON: row["workout_plan_json"],
```
(In `mapRow` the closing looks like `actionChoice: row["action_choice"]\n        )` → make it `actionChoice: row["action_choice"],\n            workoutPlanJSON: row["workout_plan_json"]\n        )`. Match each call site's indentation. Every read-from-DB-row site MUST populate it — a missed site silently never loads the plan.)

- [ ] **Step 3d: `insertWorkoutPlan`** — in `ConversationStoreV2`, add (place it near `insertInbound`):
```swift
    /// Persist an inbound workout plan as a chat message. The plan JSON is
    /// stored so the card (and the WorkoutView opened from it) survive reload.
    /// Idempotent on `id` (= workoutId) so a duplicate `workout_plan` envelope
    /// doesn't double the card. `text` holds a compact summary for the row's
    /// fallback/voiceover; the card view renders its own layout from the plan.
    func insertWorkoutPlan(id: String, agentId: String, plan: WorkoutPlan) throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let json = String(data: try JSONEncoder().encode(plan), encoding: .utf8)
            let summary = "🏋️ \(plan.dayName) · \(plan.intensityLabel) · \(plan.exercises.count) упр."
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages
                  (id, dir, seq, text, status, ts, created_at, agent_id, workout_plan_json)
                VALUES (?, 'in', NULL, ?, 'new', ?, ?, ?, ?)
            """, arguments: [id, summary, now, now, agentId, json])
        }
    }
```

- [ ] **Step 4: Run, verify PASS** (the new test + the existing agent suite, to confirm the `StoredMessage` field addition didn't break other constructions):
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ConversationStoreV2AgentTests 2>&1 | tail -20
```

- [ ] **Step 5: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2AgentTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): persist inbound workout plan as a chat message row"
```

---

## Task 2: Model + card view — `.workoutPlan` content + `WorkoutPlanRow`

**Files:** `Models/Message.swift`, `Components/MessageRow.swift`

This task adds the content case and its view so the project compiles with the new case handled everywhere. No row yet produces `.workoutPlan` (that's Task 3), so there's no behavior to unit-test here — verify by build.

- [ ] **Step 1: Add the content case + info struct** in `Models/Message.swift`.

Add `WorkoutPlanCardInfo` next to `ActionInfo` (after the `ActionInfo` struct, ~line 31):
```swift
/// Inbound workout-plan card (Payne). Carries the full decoded plan so tapping
/// "Начать тренировку" can open WorkoutView from the held plan (no round-trip).
/// `done`/`outcome` mirror the B1 answered visual, set when the workout ends.
struct WorkoutPlanCardInfo: Equatable {
    let plan: WorkoutPlan
    var done: Bool = false
    var outcome: String? = nil   // "completed" | "aborted"

    var dayName: String { plan.dayName }
    var intensityLabel: String { plan.intensityLabel }
    var exerciseCount: Int { plan.exercises.count }
}
```

In the `Content` enum (~line 78), add after `case action(ActionInfo)`:
```swift
        case workoutPlan(WorkoutPlanCardInfo)
```

In the `text` convenience accessor (~line 88), add a case before `default`:
```swift
        case .workoutPlan(let w): return "🏋️ \(w.dayName) · \(w.intensityLabel) · \(w.exerciseCount) упр."
```

- [ ] **Step 2: Add `WorkoutPlanRow` + route it** in `Components/MessageRow.swift`.

In the `body` switch (~line 38), add a case after `.action`:
```swift
            case .workoutPlan(let info):
                WorkoutPlanRow(messageId: message.id, info: info, onStart: onWorkoutStart, isLast: isLast)
```

Add a new callback property on `MessageRow` (next to `onActionTap`, ~line 11):
```swift
    var onWorkoutStart: ((WorkoutPlan, String) -> Void)? = nil
```

Add the `WorkoutPlanRow` view at the end of the file (after `ActionRow`, before the `// MARK: - Status row`). It mirrors `ActionRow`'s structure and reuses the B1 answered button styling (selected/done = accent fill + checkmark + thicker outline + disabled):
```swift
struct WorkoutPlanRow: View {
    let messageId: String
    let info: WorkoutPlanCardInfo
    var onStart: ((WorkoutPlan, String) -> Void)?
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: Theme.avatarDotSize, height: Theme.avatarDotSize)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 3)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 8) {
                    Text("PAYNE")
                        .font(Theme.metaFont)
                        .tracking(0.5)
                        .foregroundStyle(Theme.accentMedium)

                    // Compact plan summary.
                    HStack(spacing: 6) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(size: 13))
                        Text("\(info.dayName) · \(info.intensityLabel) · \(info.exerciseCount) упр.")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(Theme.assistantText)

                    // Start button. When the workout has been done, it greys +
                    // shows a checkmark + a thicker outline and is disabled.
                    Button {
                        Theme.hapticSend()
                        onStart?(info.plan, messageId)
                    } label: {
                        HStack(spacing: 5) {
                            if info.done {
                                CheckmarkShape()
                                    .stroke(Theme.textSecondary.opacity(0.6), style: StrokeStyle(lineWidth: Theme.lineAccent, lineCap: .round, lineJoin: .round))
                                    .frame(width: 9, height: 6)
                            }
                            Text("Начать тренировку")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(info.done ? Theme.textSecondary.opacity(0.6) : Theme.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(info.done ? Color.clear : Theme.accent.opacity(0.16))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                info.done ? Theme.surfaceBorder.opacity(0.5) : Theme.accent.opacity(0.35),
                                lineWidth: info.done ? Theme.lineHairline : Theme.lineAccent
                            )
                        )
                        .opacity(info.done ? 0.6 : 1)
                    }
                    .disabled(info.done)
                    .animation(.easeOut(duration: 0.2), value: info.done)
                }
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, Theme.rowPadV)

            if !isLast {
                Rectangle()
                    .fill(Theme.hairlineColor)
                    .frame(height: 0.5)
                    .padding(.horizontal, Theme.rowPadH)
            }
        }
    }
}
```

- [ ] **Step 3: Fix any other exhaustive `Content` switch the compiler flags.** Adding the enum case may break other exhaustive switches. Run a build; the compiler lists every non-exhaustive switch. The known one is `MessageRow.body` (handled above). For any other (e.g. in `MessageListView` if it switches on `content`), add a sensible `.workoutPlan` case. Build:
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`. (`onWorkoutStart` is nil at all call sites for now — wired in Task 4.)

- [ ] **Step 4: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Message.swift ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift
git commit -m "feat(ios): workoutPlan content case + WorkoutPlanRow card"
```

---

## Task 3: Mapping — `toChatMessage` builds `.workoutPlan`

**Files:** `Services/WebSocketClientV2.swift`, test `Sources/JarvisAppTests/ChatImageMappingTests.swift`

- [ ] **Step 1: Write the failing test** — append to `ChatImageMappingTests.swift`:
```swift
    func test_toChatMessage_buildsWorkoutPlan_fromWorkoutPlanJSON() throws {
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "День ног", week: 2, intensityLabel: "высокая",
            exercises: [ExercisePlan(exerciseSlug: "squat", targetSets: 5, targetReps: "5", targetRir: 2, restSec: 180, notes: nil)],
            imageManifest: [])
        let json = String(data: try JSONEncoder().encode(plan), encoding: .utf8)!

        // Not yet done.
        let row = StoredMessage(id: "w1", dir: .in_, seq: nil, text: "🏋️ День ног · высокая · 1 упр.",
                                attachmentsJSON: nil, contextJSON: nil, status: .delivered, failureReason: nil,
                                ts: 1_700_000_000_000, serverTS: nil, createdAt: 1_700_000_000_000,
                                agentId: "payne", actionsJSON: nil, actionChoice: nil, workoutPlanJSON: json)
        let msgs = WebSocketClientV2.toChatMessage(row)
        XCTAssertEqual(msgs.count, 1)
        guard case .workoutPlan(let info) = msgs[0].content else { return XCTFail("expected .workoutPlan") }
        XCTAssertEqual(info.plan, plan)
        XCTAssertFalse(info.done)
        XCTAssertNil(info.outcome)

        // Done (action_choice set).
        var doneRow = row
        doneRow.actionChoice = "completed"
        guard case .workoutPlan(let doneInfo) = WebSocketClientV2.toChatMessage(doneRow)[0].content
        else { return XCTFail("expected .workoutPlan") }
        XCTAssertTrue(doneInfo.done)
        XCTAssertEqual(doneInfo.outcome, "completed")

        // Garbage JSON falls through to a text bubble (no crash).
        var badRow = row
        badRow.workoutPlanJSON = "{not json"
        guard case .text = WebSocketClientV2.toChatMessage(badRow)[0].content
        else { return XCTFail("garbage workoutPlanJSON should fall through to text") }
    }
```
(Match the `StoredMessage(...)` argument order to the struct: `id, dir, seq, text, attachmentsJSON, contextJSON, status, failureReason, ts, serverTS, createdAt, agentId, actionsJSON, actionChoice, workoutPlanJSON`.)

- [ ] **Step 2: Run, verify FAIL** (returns `.text`, not `.workoutPlan`):
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ChatImageMappingTests/test_toChatMessage_buildsWorkoutPlan_fromWorkoutPlanJSON 2>&1 | tail -20
```

- [ ] **Step 3: Add the `.workoutPlan` branch** in `toChatMessage` (`WebSocketClientV2.swift`), immediately AFTER the existing `.action` branch (so it's before the attachment/text paths). A decode failure falls through to text (matches the `.action` house style):
```swift
        // Inbound workout-plan card (Payne). Built before text/attachment so a
        // plan row renders as a tappable card. The persisted `action_choice`
        // restores the done-state after reload. Decode failure falls through.
        if let wj = row.workoutPlanJSON, let data = wj.data(using: .utf8),
           let plan = try? JSONDecoder().decode(WorkoutPlan.self, from: data) {
            let info = WorkoutPlanCardInfo(plan: plan, done: row.actionChoice != nil, outcome: row.actionChoice)
            var m = ChatMessage(id: row.id, role: role, content: .workoutPlan(info), timestamp: timestamp)
            m.deliveryStatus = mapDelivery(row.status)
            m.agentId = row.agentId
            return [m]
        }
```

- [ ] **Step 4: Run, verify PASS** (the new test + the full `ChatImageMappingTests` class):
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ChatImageMappingTests 2>&1 | tail -20
```

- [ ] **Step 5: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift ios/JarvisApp/Sources/JarvisAppTests/ChatImageMappingTests.swift
git commit -m "feat(ios): toChatMessage renders workout_plan_json as a .workoutPlan card"
```

---

## Task 4: Wire — persist on receipt, open on tap, mark done on close, remove the button

**Files:** `Services/AppCoordinator.swift`, `Views/ChatView.swift`, `Components/MessageListView.swift`

- [ ] **Step 1: `insertWorkoutPlan` forwarder + persist on receipt** in `Services/AppCoordinator.swift`.

Add a forwarder next to `markActionAnswered` (~line 234):
```swift
    /// Persist an inbound workout plan as a chat card. No-op if the store isn't
    /// built yet. (Plan also pre-fetched into the image cache by the caller.)
    func insertWorkoutPlan(_ plan: WorkoutPlan) {
        try? chatStore?.insertWorkoutPlan(id: plan.workoutId, agentId: "payne", plan: plan)
    }
```

In `handleWorkoutEnvelope`, in the `case .workoutPlan(let p):` block, replace the line `workoutBus.events.send(.planReceived(plan))` with:
```swift
                insertWorkoutPlan(plan)
```
(Keep the `imageCache.prefetch(manifest:)` call above it and the `do { let plan = try Self.decodeWorkoutPlan(payload: p); … } catch { … }` structure — only the send-line changes. The plan now becomes a persisted chat card instead of auto-opening.)

- [ ] **Step 2: `WorkoutPresentation.messageId` + Start handler + done-on-close + remove button** in `Views/ChatView.swift`.

(a) Add `messageId` to the wrapper (~line 12):
```swift
private struct WorkoutPresentation: Identifiable {
    let plan: WorkoutPlan
    let coord: WorkoutCoordinator
    let messageId: String?
    var id: String { plan.workoutId }
}
```

(b) Add a Start handler method on `ChatView` (near the other private helpers):
```swift
    private func startWorkout(_ plan: WorkoutPlan, messageId: String) {
        guard let queue = coordinator.ws.stack?.setLogQueue else {
            Log.warn(.ws, "start workout but stack not built — dropping")
            return
        }
        let wc = WorkoutCoordinator(plan: plan, queue: queue)
        activeWorkout = WorkoutPresentation(plan: plan, coord: wc, messageId: messageId)
    }
```

(c) Thread `onWorkoutStart` into the message list. Find where `ChatView` passes `onActionTap:` to `MessageListView` (the list rendering) and add alongside it:
```swift
                        onWorkoutStart: { plan, messageId in startWorkout(plan, messageId: messageId) },
```

(d) In the `.fullScreenCover(item: $activeWorkout)` `onClose` closure, after the existing `activeWorkout = nil`, mark the card done:
```swift
                onClose: { session in
                    let workoutId = presentation.plan.workoutId
                    if let session {
                        Task { try? await coordinator.ws.stack?.transport.sendWorkoutComplete(session) }
                    } else {
                        Task { try? await coordinator.ws.stack?.transport.sendWorkoutAbort(workoutId: workoutId, reason: "user cancelled") }
                    }
                    if let mid = presentation.messageId {
                        coordinator.markActionAnswered(rowId: mid, choice: session != nil ? "completed" : "aborted")
                    }
                    activeWorkout = nil
                },
```

(e) In the `.onReceive(coordinator.workoutBus.events)` switch, the `.planReceived` case no longer opens a workout (plans now arrive as persisted cards). Change it to a no-op so the bus enum stays exhaustive without auto-opening:
```swift
            case .planReceived:
                // Plans now render as inline cards (persisted via insertWorkoutPlan);
                // the live WorkoutView opens from the card's Start button. No auto-open.
                break
```

(f) DELETE the persistent button block entirely — the `if active.active == .payne { Button { … } label: { Label("Начать тренировку", …) } … }` (currently ~`ChatView.swift:198-217`, including its `// MARK: – Payne workout starter` comment).

- [ ] **Step 3: Thread `onWorkoutStart` through `MessageListView`** (`Components/MessageListView.swift`). Find where `MessageListView` declares `onActionTap` and where it constructs `MessageRow(...)` passing `onActionTap:`. Add a parallel property and pass-through:
  - Declare: `var onWorkoutStart: ((WorkoutPlan, String) -> Void)? = nil`
  - In the `MessageRow(...)` construction, add: `onWorkoutStart: onWorkoutStart`
  (Mirror exactly how `onActionTap` is declared and forwarded. The compiler enforces both ends once Step 2c passes `onWorkoutStart:` to `MessageListView`.)

- [ ] **Step 4: Build + full unit suite** (no new unit test — this is wiring; behavior is verified on device in Task 5):
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`; unit suite green.

- [ ] **Step 5: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift ios/JarvisApp/Sources/JarvisApp/Components/MessageListView.swift
git commit -m "feat(ios): plan card opens WorkoutView on tap, marks done on close; remove persistent button"
```

---

## Task 5: Version bump, full suite, manual verification

**Files:** `ios/JarvisApp/project.yml`

- [ ] **Step 1: Bump** in `ios/JarvisApp/project.yml` (`JarvisApp` target `settings.base`): `MARKETING_VERSION` → `"1.8.0"`, `CURRENT_PROJECT_VERSION` → `"33"`.

- [ ] **Step 2: Regenerate + full iOS unit suite**
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`, 0 failures. If anything fails, BLOCKED — do not commit.

- [ ] **Step 3: Manual device verification (Sergei — build 33)**
- Open Payne's chat: the persistent "Начать тренировку" button is GONE.
- Ask Payne for a workout (conversational) → a compact plan card appears in the chat (day · intensity · N упр. + "Начать тренировку"). *(Requires the Payne-instruction companion change — see below.)*
- Tap "Начать тренировку" → WorkoutView opens with that plan.
- Finish (or abort) → the card's button shows done (greyed + checkmark, disabled).
- Kill + relaunch → the card is still there and still marked done.

- [ ] **Step 4: Commit**
```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "chore(ios): bump to 1.8.0 (build 33) — inline workout-plan card (B2)"
```

---

## Companion change (deploy-side, NOT part of these tasks)

Removing the persistent button removes the only sender of `workout_start_request`. **Payne must emit a `workout_plan` outbound when the user asks for a workout in conversation** (not only on the button's structured event). Without this, no card appears. This is a Payne-instruction edit (the Payne workout skill / `groups/payne` on the VDS) handled at deploy — verify Payne's current trigger and update it then. The agent-runner + group files are host-mounted (no image rebuild; restart the session).

---

## Self-Review (completed during planning)

- **Spec coverage:** persist-instead-of-auto-open → Task 4 Step 1. `workout_plan_json` column + `insertWorkoutPlan` → Task 1. `.workoutPlan` content + `WorkoutPlanCardInfo` + `WorkoutPlanRow` → Task 2. `toChatMessage` `.workoutPlan` → Task 3. Start-tap opens held plan + `WorkoutPresentation.messageId` + done-on-close (reusing `markActionAnswered`) → Task 4. Remove persistent button → Task 4 Step 2f. Bump/suite/manual → Task 5. Payne-instruction dependency → documented as deploy-side companion. Non-goals (exercise preview, WorkoutView changes, keep button, in-progress persistence, new protocol) untouched.
- **Type consistency:** `WorkoutPlan` (workoutId/dayName/week/intensityLabel/exercises/imageManifest, Equatable, Codable snake_case) used identically in Task 1 (encode), Task 3 (decode + test), Task 4 (start). `WorkoutPlanCardInfo {plan, done, outcome}` defined Task 2, built Task 3, read by `WorkoutPlanRow` Task 2. `insertWorkoutPlan(id:agentId:plan:)` defined Task 1, forwarded Task 4. `onWorkoutStart: (WorkoutPlan, String) -> Void` declared on `MessageRow` (Task 2) + `MessageListView` (Task 4) + passed by `ChatView` (Task 4). `markActionAnswered(rowId:choice:)` (existing) reused for done. `StoredMessage.workoutPlanJSON` appended last (Task 1), set in test inits (Task 3) in struct order.
- **Placeholder check:** all steps carry concrete code/commands. The only "find the existing pattern" instructions (Task 2 Step 3 other switches, Task 4 Step 3 MessageListView threading) reference an existing mirror (`onActionTap`) the compiler enforces — not vague placeholders.
