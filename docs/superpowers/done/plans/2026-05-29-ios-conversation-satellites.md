# iOS Conversation-as-Satellite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the user's active and pinned conversations as orbiting satellites around the home center orb, replacing the current single "Диалог" satellite. Up to 3 conversation satellites total (1 active + 2 pinned), each tapping into the corresponding conversation.

**Architecture:** Extract a pure `ConversationSatelliteBuilder` helper struct so the satellite-selection logic (active-within-24h, pinned-by-recency, dedup, cap-at-3) is unit-testable in isolation. `OrbHomeView.defaultSatellites` consumes the builder's output and renders it alongside the existing suggestion satellites. Cluster radius bumps from 130 to 150 when total count > 6 to prevent overlap.

**Tech Stack:** Swift / SwiftUI / XCTest.

**Scope note:** This plan is Plan C of the larger `2026-05-28-ios-ui-unified-navigation-design.md` spec. Plans A (navigation cleanup) and B (Glass voice mode) have landed. Plan D (Apple Watch + JarvisCore SPM) is the last remaining sub-plan.

---

## File Structure

| File | Purpose |
|---|---|
| `ios/JarvisApp/Sources/JarvisApp/Utility/ConversationSatelliteBuilder.swift` (NEW) | Pure helper: takes `(activeConversationId, lastAssistantTimestamp, allConversations, now)` → ordered list of satellite descriptors `[(id, title, kind)]`. Kind is enum `.active / .pinned`. Cap at 3, dedup against active. |
| `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` (MODIFY) | Replace the single `if hasActiveChat` "Диалог" satellite with the builder's output (truncate titles to 14 chars, wire taps to `coordinator.handleAction(.open(conv))` then `onContinueChat()`). Update orbit radius from `130` to `150` when `defaultSatellites.count > 6`. |
| `ios/JarvisApp/Sources/JarvisAppTests/ConversationSatelliteBuilderTests.swift` (NEW) | Unit tests for the builder. |

## Test Commands

- **iOS unit tests:** `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/<ClassName>`.
- **Regen Xcode project after adding files:** `cd ios/JarvisApp && xcodegen generate`.

---

### Task 1: ConversationSatelliteBuilder — active + cap + dedup

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Utility/ConversationSatelliteBuilder.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/ConversationSatelliteBuilderTests.swift`

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 2: Write failing tests**

Create `ios/JarvisApp/Sources/JarvisAppTests/ConversationSatelliteBuilderTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class ConversationSatelliteBuilderTests: XCTestCase {

    private func conv(_ id: UUID = UUID(), title: String = "x",
                      lastMessageAt: Date = Date(),
                      pinned: Bool = false) -> Conversation {
        var c = Conversation(title: title)
        c.id = id
        c.lastMessageAt = lastMessageAt
        c.isPinned = pinned
        return c
    }

    func testEmptyInputsProduceEmptyResult() {
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: nil,
            lastAssistantTimestamp: nil,
            allConversations: [],
            now: Date()
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testActiveWithFreshAssistantWithin24hAppearsAsActive() {
        let id = UUID()
        let active = conv(id, title: "Test", lastMessageAt: Date())
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: Date().addingTimeInterval(-3600),
            allConversations: [active],
            now: Date()
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, id)
        XCTAssertEqual(result.first?.kind, .active)
        XCTAssertEqual(result.first?.title, "Test")
    }

    func testActiveOlderThan24hIsExcluded() {
        let id = UUID()
        let active = conv(id, title: "Old", lastMessageAt: Date())
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: Date().addingTimeInterval(-25 * 3600),
            allConversations: [active],
            now: Date()
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testActiveWithoutLastAssistantIsExcluded() {
        let id = UUID()
        let active = conv(id, title: "NoReply", lastMessageAt: Date())
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: nil,
            allConversations: [active],
            now: Date()
        )
        XCTAssertTrue(result.isEmpty)
    }
}
```

- [ ] **Step 3: Verify build error**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/ConversationSatelliteBuilderTests 2>&1 | tail -15
```

Expected: build error.

- [ ] **Step 4: Implement builder (active path only)**

Create `ios/JarvisApp/Sources/JarvisApp/Utility/ConversationSatelliteBuilder.swift`:

```swift
import Foundation

/// Picks which conversations from `ConversationStore` should appear as
/// orbiting satellites on the home cluster. Pure — no SwiftUI dependency,
/// so the selection logic is unit-testable in isolation.
enum ConversationSatelliteBuilder {

    enum Kind: Equatable { case active, pinned }

    struct Satellite: Equatable {
        let id: UUID
        let title: String
        let kind: Kind
    }

    /// 24-hour freshness window for the active conversation's last assistant reply.
    private static let freshnessWindow: TimeInterval = 24 * 3600

    /// Maximum total conversation satellites surfaced at once.
    static let maxSatellites = 3

    /// Build the satellite list given the current store state.
    ///
    /// - Parameters:
    ///   - activeConversationId: the UUID of the conversation currently open in chat (if any).
    ///   - lastAssistantTimestamp: timestamp of the most recent assistant message in the active conversation; nil if none.
    ///   - allConversations: full conversation list from `ConversationStore.conversations`.
    ///   - now: current wall clock (injectable for tests).
    /// - Returns: ordered list of satellites, capped at `maxSatellites`.
    static func build(
        activeConversationId: UUID?,
        lastAssistantTimestamp: Date?,
        allConversations: [Conversation],
        now: Date
    ) -> [Satellite] {
        var result: [Satellite] = []

        // Active satellite: only when fresh assistant reply exists within 24h.
        if let activeId = activeConversationId,
           let lastAt = lastAssistantTimestamp,
           now.timeIntervalSince(lastAt) < freshnessWindow,
           let active = allConversations.first(where: { $0.id == activeId }) {
            result.append(Satellite(id: active.id, title: active.title, kind: .active))
        }

        return Array(result.prefix(maxSatellites))
    }
}
```

- [ ] **Step 5: Regenerate + run tests**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/ConversationSatelliteBuilderTests 2>&1 | tail -15
```

Expected: 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/ConversationSatelliteBuilder.swift \
        ios/JarvisApp/Sources/JarvisAppTests/ConversationSatelliteBuilderTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add ConversationSatelliteBuilder — active-conversation path

Pure helper enum with Satellite struct + Kind enum (.active / .pinned).
Active satellite appears only when the current conversation has had
an assistant reply within the last 24 hours. Returns at most
maxSatellites (3) entries."
```

---

### Task 2: ConversationSatelliteBuilder — pinned + dedup

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Utility/ConversationSatelliteBuilder.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/ConversationSatelliteBuilderTests.swift`

- [ ] **Step 1: Append failing tests**

Append inside `ConversationSatelliteBuilderTests`:

```swift
    func testPinnedConversationsAppearAsPinnedKind() {
        let p1 = conv(title: "P1", lastMessageAt: Date().addingTimeInterval(-100), pinned: true)
        let p2 = conv(title: "P2", lastMessageAt: Date().addingTimeInterval(-200), pinned: true)
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: nil,
            lastAssistantTimestamp: nil,
            allConversations: [p2, p1],
            now: Date()
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.kind), [.pinned, .pinned])
        XCTAssertEqual(result.map(\.title), ["P1", "P2"], "pinned satellites sorted by lastMessageAt desc")
    }

    func testPinnedCapAtTwo() {
        let p1 = conv(title: "P1", lastMessageAt: Date().addingTimeInterval(-100), pinned: true)
        let p2 = conv(title: "P2", lastMessageAt: Date().addingTimeInterval(-200), pinned: true)
        let p3 = conv(title: "P3", lastMessageAt: Date().addingTimeInterval(-300), pinned: true)
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: nil,
            lastAssistantTimestamp: nil,
            allConversations: [p1, p2, p3],
            now: Date()
        )
        XCTAssertEqual(result.count, 2, "only 2 pinned slots regardless of how many are pinned")
        XCTAssertEqual(result.map(\.title), ["P1", "P2"], "newest two pinned win")
    }

    func testActivePlusPinnedDedupesWhenActiveIsPinned() {
        let id = UUID()
        let active = conv(id, title: "Active", lastMessageAt: Date(), pinned: true)
        let p2 = conv(title: "P2", lastMessageAt: Date().addingTimeInterval(-200), pinned: true)
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: Date().addingTimeInterval(-3600),
            allConversations: [active, p2],
            now: Date()
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].kind, .active)
        XCTAssertEqual(result[0].id, id)
        XCTAssertEqual(result[1].kind, .pinned)
        XCTAssertEqual(result[1].title, "P2")
    }

    func testActivePlusTwoPinnedTotalsThree() {
        let id = UUID()
        let active = conv(id, title: "Active", lastMessageAt: Date())
        let p1 = conv(title: "P1", lastMessageAt: Date().addingTimeInterval(-100), pinned: true)
        let p2 = conv(title: "P2", lastMessageAt: Date().addingTimeInterval(-200), pinned: true)
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: Date().addingTimeInterval(-3600),
            allConversations: [active, p1, p2],
            now: Date()
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.kind), [.active, .pinned, .pinned])
    }
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/ConversationSatelliteBuilderTests 2>&1 | tail -15
```

Expected: 4 new tests fail (only active path implemented).

- [ ] **Step 3: Add pinned-satellite logic to builder**

In `ConversationSatelliteBuilder.swift`, extend the `build` method. Replace the existing implementation with:

```swift
    static func build(
        activeConversationId: UUID?,
        lastAssistantTimestamp: Date?,
        allConversations: [Conversation],
        now: Date
    ) -> [Satellite] {
        var result: [Satellite] = []

        // 1. Active satellite — only when fresh assistant reply exists within 24h.
        var activeId: UUID? = nil
        if let aid = activeConversationId,
           let lastAt = lastAssistantTimestamp,
           now.timeIntervalSince(lastAt) < freshnessWindow,
           let active = allConversations.first(where: { $0.id == aid }) {
            result.append(Satellite(id: active.id, title: active.title, kind: .active))
            activeId = active.id
        }

        // 2. Up to 2 pinned satellites, sorted by lastMessageAt descending,
        //    excluding the active one (so it doesn't appear twice).
        let pinned = allConversations
            .filter { $0.isPinned && $0.id != activeId }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
            .prefix(2)

        for conv in pinned {
            result.append(Satellite(id: conv.id, title: conv.title, kind: .pinned))
        }

        return Array(result.prefix(maxSatellites))
    }
```

- [ ] **Step 4: Run tests**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/ConversationSatelliteBuilderTests 2>&1 | tail -15
```

Expected: 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/ConversationSatelliteBuilder.swift \
        ios/JarvisApp/Sources/JarvisAppTests/ConversationSatelliteBuilderTests.swift
git commit -m "ios: ConversationSatelliteBuilder — pinned satellites + dedup

Up to 2 pinned conversation satellites sorted by lastMessageAt
descending, excluding the active conversation (it already has its own
slot). Order: active first, then pinned. Capped at maxSatellites (3)."
```

---

### Task 3: Wire builder into OrbHomeView satellites

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`

- [ ] **Step 1: Add `conversationSatellites` helper**

In `OrbHomeView`, add a new computed property just above `defaultSatellites`:

```swift
    private var conversationSatellites: [(icon: String, label: String, isChat: Bool, action: () -> Void)] {
        let lastAssistantAt = coordinator.ws.messages.last(where: { $0.role == .assistant })?.timestamp
        let satellites = ConversationSatelliteBuilder.build(
            activeConversationId: coordinator.store.activeConversationId,
            lastAssistantTimestamp: lastAssistantAt,
            allConversations: coordinator.store.conversations,
            now: Date()
        )

        return satellites.map { sat in
            let truncated = truncateTitle(sat.title, max: 14)
            let icon = sat.kind == .active ? "bubble.left.fill" : "pin.fill"
            let isActiveKind = sat.kind == .active
            return (icon, truncated, isActiveKind, {
                if !isActiveKind, let conv = coordinator.store.conversations.first(where: { $0.id == sat.id }) {
                    coordinator.handleAction(.open(conv))
                }
                onContinueChat()
            })
        }
    }

    private func truncateTitle(_ title: String, max: Int) -> String {
        guard title.count > max else { return title }
        return String(title.prefix(max)) + "…"
    }
```

- [ ] **Step 2: Replace `defaultSatellites` body**

Replace the existing `defaultSatellites` (around lines 65-80 of `OrbHomeView.swift`) with:

```swift
    private var defaultSatellites: [(icon: String, label: String, isChat: Bool, action: () -> Void)] {
        var items: [(String, String, Bool, () -> Void)] = contextualSuggestions.map { text in
            (SuggestionEngine.icon(for: text), text, false, {
                Theme.hapticSend()
                SuggestionEngine.recordUsage(text)
                onStartChat(text)
            })
        }
        items.append(contentsOf: conversationSatellites)
        return items
    }
```

Note: the old `if hasActiveChat { items.append(("bubble.left.and.bubble.right", "Диалог", true, { onContinueChat() })) }` is removed — the builder now handles this path with richer information.

`hasActiveChat` may still be referenced elsewhere in `OrbHomeView` (e.g. in `actionSatellites` or layout) — leave that property in place.

- [ ] **Step 3: Bump radius when count > 6**

Find the radius constant in `orbCluster` (around line 264 of `OrbHomeView.swift`):

```swift
                let radius = Theme.scaled(130)
```

Replace with:

```swift
                let radius = Theme.scaled(defaultSatellites.count > 6 ? 150 : 130)
```

Do this for BOTH the default-satellites loop and the action-satellites loop (search for `Theme.scaled(130)` and update each occurrence in those loops).

- [ ] **Step 4: Build + full unit test target**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED + all unit tests pass (63 existing + 8 builder = 71).

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "ios(home): satellite cluster shows active + pinned conversations

The old single 'Диалог' satellite is replaced by up to 3 conversation
satellites from ConversationSatelliteBuilder. Active conversations
use bubble.left.fill, pinned use pin.fill. Tapping a pinned one
opens it in the store first, then continues to chat. Cluster radius
bumps from 130 to 150 when total satellites exceed 6."
```

---

### Task 4: UI test — satellite presence + tap

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisUITests/ConversationSatelliteTests.swift`

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 2: Write a single smoke UI test**

UI testing the cluster is hard because satellite positions are angular and identifiers don't reliably propagate through SwiftUI custom rendering (the recurring `chat-view` issue). A meaningful test is "the home screen renders and the orb-home view is reachable" — this catches build breakage but not visual regressions. For visual regressions, manual inspection is the v1 plan.

Create `ios/JarvisApp/Sources/JarvisUITests/ConversationSatelliteTests.swift`:

```swift
import XCTest

final class ConversationSatelliteTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    /// Smoke: the home view renders without crash after the satellite
    /// refactor. Catches build-time and runtime regressions in the new
    /// computed-property path even though we can't tap individual satellites
    /// reliably from XCUITest.
    func testHomeRendersWithConversationSatelliteRefactor() {
        let app = launchApp()
        let home = app.otherElements["orb-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5),
                      "Home view must still render after the satellite refactor")
    }
}
```

- [ ] **Step 3: Run UI test**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisUITests/ConversationSatelliteTests 2>&1 | tail -20
```

Expected: 1 test PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisUITests/ConversationSatelliteTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "test(ios-ui): home smoke test for the satellite refactor

Verifies the home view still renders after the conversation-satellite
refactor. Tapping individual satellites is not covered — XCUITest
can't reliably target the angular-positioned cluster items due to
the same SwiftUI identifier-propagation constraint that blocked
reliable child-element lookups in the other UI test suites."
```

---

## Self-Review

**Spec coverage** against the Conversation-as-Satellite section of `2026-05-28-ios-ui-unified-navigation-design.md`:

| Spec requirement | Task |
|---|---|
| Active satellite with bubble.left.fill icon | Tasks 1 + 3 |
| Active appears only with assistant reply < 24h | Task 1 |
| Up to 2 pinned satellites with pin.fill icon | Tasks 2 + 3 |
| Pinned sorted by lastMessageAt descending | Task 2 |
| Dedup pinned against active | Task 2 |
| Cap total conversation satellites at 3 | Tasks 1 + 2 (maxSatellites = 3) |
| Title truncate to 14 chars | Task 3 (`truncateTitle`) |
| Tap active → `onContinueChat()` | Task 3 |
| Tap pinned → open conv in store + `onContinueChat()` | Task 3 |
| Radius bump from 130 to 150 when count > 6 | Task 3 |

**Placeholder scan:** every step shows the actual change. No `TBD` markers.

**Type consistency:** `ConversationSatelliteBuilder.Satellite` shape (`id: UUID, title: String, kind: Kind`) is used identically in both task descriptions. `Kind` enum (`.active / .pinned`) is consistent. View-side mapping turns kind into `(icon, isActiveKind: Bool)` so the existing satellite-rendering tuple type doesn't change.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-ios-conversation-satellites.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
