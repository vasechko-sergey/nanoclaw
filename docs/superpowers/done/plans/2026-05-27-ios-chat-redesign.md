# iOS Chat Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the iOS chat to use a bubbleless layout, custom delivery indicators, a reliable busy-state indicator, a left-drawer conversation list with one-gesture switching, and a heartbeat-backed stable WebSocket.

**Architecture:** SwiftUI, single-target app (`ios/JarvisApp/`), built via xcodegen. Views own state with `@Observable`. New `JarvisAppTests` unit-test target hosts business-logic tests for WebSocketClient state, DeliveryChecks rendering, and Heartbeat behaviour. UI tests live in the existing `JarvisUITests` target. No host-side (Node) changes — WS ping/pong is transport-level.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 18+, xcodegen, XCTest, XCUITest. Reference spec: `docs/superpowers/specs/2026-05-27-ios-chat-redesign-design.md`.

---

## File Structure

**New files:**
- `ios/JarvisApp/Sources/JarvisApp/Components/DeliveryChecks.swift` — custom `Shape` checkmarks for `sending/sent/delivered/failed`.
- `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift` — bubbleless message renderer (replaces `MessageBubble.swift`). Contains `MessageRow`, `ThinkingRow`, and inline card variants (`FileRow`, `ActionRow`, `StatusRow`).
- `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientBusyTests.swift` — unit tests for `isBusy` derived state.
- `ios/JarvisApp/Sources/JarvisAppTests/DeliveryChecksTests.swift` — unit tests for DeliveryChecks state rendering.
- `ios/JarvisApp/Sources/JarvisAppTests/HeartbeatTests.swift` — unit tests for heartbeat reconnect logic.
- `ios/JarvisApp/Sources/JarvisUITests/DrawerTests.swift` — UI tests for drawer open/close/switching.
- `ios/JarvisApp/Sources/JarvisUITests/ThinkingRowTests.swift` — UI tests for busy indicator lifecycle.

**Modified files:**
- `ios/JarvisApp/project.yml` — add `JarvisAppTests` target.
- `ios/JarvisApp/Sources/JarvisApp/Utility/Theme.swift` — new tokens; remove bubble tokens.
- `ios/JarvisApp/Sources/JarvisApp/Components/MiniOrbView.swift` — size-conditional particle overlay for `.processing`.
- `ios/JarvisApp/Sources/JarvisApp/Components/UnifiedInputBar.swift` — pill style refresh + identifiers.
- `ios/JarvisApp/Sources/JarvisApp/Components/EmptyStateView.swift` — visual refresh.
- `ios/JarvisApp/Sources/JarvisApp/Components/ConnectionBanner.swift` — hairline strip.
- `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift` — heartbeat, busy state, scene phase, thinkingDetail.
- `ios/JarvisApp/Sources/JarvisApp/Services/ConnectivityMonitor.swift` — `onSatisfied` callback.
- `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` — `scenePhase` wiring.
- `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` — header refresh, drawer overlay, ThinkingRow, gestures.
- `ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift` — extract `DrawerContent`, row tap → `.open(conv)`.
- `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift` — remove "История" section.
- `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` — add "Continue" pill.
- `ios/JarvisApp/Sources/JarvisUITests/JarvisUITests.swift` — predicate updates.

**Deleted files:**
- `ios/JarvisApp/Sources/JarvisApp/Views/ArchivedChatView.swift`
- `ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift`

---

## Task 1: Add JarvisAppTests target

**Files:**
- Modify: `ios/JarvisApp/project.yml`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/.gitkeep`

- [ ] **Step 1: Create the test source directory**

```bash
mkdir -p ios/JarvisApp/Sources/JarvisAppTests
touch ios/JarvisApp/Sources/JarvisAppTests/.gitkeep
```

- [ ] **Step 2: Add the test target to project.yml**

Append the following YAML under `targets:` (after `JarvisUITests:` block):

```yaml
  JarvisAppTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Sources/JarvisAppTests
    dependencies:
      - target: JarvisApp
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vasechko.jarvis.unittests
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Jarvis.app/Jarvis"
        BUNDLE_LOADER: "$(TEST_HOST)"
        SWIFT_VERSION: "5.9"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: 24Z6S27D7U
        GENERATE_INFOPLIST_FILE: YES
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

Expected: `Generated project successfully` (or similar) and `JarvisApp.xcodeproj` updated.

- [ ] **Step 4: Verify the target builds (empty)**

```bash
xcodebuild build-for-testing -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisAppTests
```

Expected: build succeeds; no tests run yet.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj ios/JarvisApp/Sources/JarvisAppTests
git commit -m "ios: add JarvisAppTests unit-test target"
```

---

## Task 2: Add new Theme tokens

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Utility/Theme.swift`

- [ ] **Step 1: Read the current Theme file to find the insertion point**

```bash
grep -n "messagePadH\|inputRadius\|bubbleRadius" ios/JarvisApp/Sources/JarvisApp/Utility/Theme.swift
```

- [ ] **Step 2: Add new tokens to Theme.swift**

Append after the existing layout/spacing tokens:

```swift
// MARK: - Bubbleless row tokens (2026 redesign)
static let rowPadV: CGFloat = 12
static let rowPadH: CGFloat = 18
static let metaFont = Font.system(size: 10, design: .monospaced)
static let avatarDotSize: CGFloat = 8
static let hairlineColor = Theme.accent.opacity(0.05)
static var drawerWidth: CGFloat { UIScreen.main.bounds.width * 0.78 }
static let inputBarRadius: CGFloat = 22
```

Leave existing bubble tokens (`userBubble`, `assistantBubble`, `userBubbleBorder`, `assistantBubbleBorder`, `bubbleRadius`, `messagePadH`, `messagePadV`) intact for now — they're removed in a later task once no call sites depend on them.

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/Theme.swift
git commit -m "ios: add bubbleless layout tokens to Theme"
```

---

## Task 3: DeliveryChecks — failing tests

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisAppTests/DeliveryChecksTests.swift`

- [ ] **Step 1: Write the failing test**

Write to `ios/JarvisApp/Sources/JarvisAppTests/DeliveryChecksTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Jarvis

final class DeliveryChecksTests: XCTestCase {
    func testCheckmarkShapePath() {
        let shape = CheckmarkShape()
        let rect = CGRect(x: 0, y: 0, width: 10, height: 6)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty, "CheckmarkShape should produce a non-empty path")
        XCTAssertEqual(path.boundingRect.width, 10, accuracy: 0.5)
    }

    func testDeliveryChecksAcceptsAllStates() {
        // Compile-time guarantee: all DeliveryStatus cases are renderable.
        for status in [DeliveryStatus.sending, .sent, .delivered, .failed] {
            let view = DeliveryChecks(status: status)
            XCTAssertNotNil(view.body)
        }
    }
}
```

- [ ] **Step 2: Run the test — expect failure (no DeliveryChecks symbol yet)**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisAppTests/DeliveryChecksTests
```

Expected: FAIL — `cannot find 'CheckmarkShape' in scope` and `cannot find 'DeliveryChecks' in scope`.

---

## Task 4: DeliveryChecks — implementation

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Components/DeliveryChecks.swift`

- [ ] **Step 1: Write the component**

Write to `ios/JarvisApp/Sources/JarvisApp/Components/DeliveryChecks.swift`:

```swift
import SwiftUI

/// Path-drawn checkmark shape. Drawn from left edge to mid-bottom to top-right.
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX * 0.85, y: rect.maxY - 1))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 1))
        }
    }
}

/// Delivery state indicator. Replaces overlapping SF Symbol checkmarks.
struct DeliveryChecks: View {
    let status: DeliveryStatus

    @State private var spinRotation: Double = 0
    @State private var secondCheckOpacity: Double = 1

    var body: some View {
        ZStack {
            switch status {
            case .sending:
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.accent.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(spinRotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            spinRotation = 360
                        }
                    }
            case .sent:
                CheckmarkShape()
                    .stroke(Theme.accent.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 6)
            case .delivered:
                HStack(spacing: -3) {
                    CheckmarkShape()
                        .stroke(Theme.accent.opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: 10, height: 6)
                    CheckmarkShape()
                        .stroke(Theme.accent.opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: 10, height: 6)
                        .opacity(secondCheckOpacity)
                        .onAppear {
                            secondCheckOpacity = 0
                            withAnimation(.easeOut(duration: 0.2)) {
                                secondCheckOpacity = 1
                            }
                        }
                }
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
        .frame(width: 14, height: 10)
        .animation(.easeOut(duration: 0.2), value: status)
    }
}
```

- [ ] **Step 2: Run the test — expect pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisAppTests/DeliveryChecksTests
```

Expected: PASS for both tests.

- [ ] **Step 3: Regenerate project (new file)**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/DeliveryChecks.swift ios/JarvisApp/Sources/JarvisAppTests/DeliveryChecksTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add DeliveryChecks component with shape-based checkmarks"
```

---

## Task 5: WebSocketClient isBusy state — failing tests

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientBusyTests.swift`

- [ ] **Step 1: Write the failing tests**

Write to `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientBusyTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class WebSocketClientBusyTests: XCTestCase {
    func testIsBusyTrueWhenTyping() {
        let ws = WebSocketClient()
        ws.isTyping = true
        XCTAssertTrue(ws.isBusy)
    }

    func testIsBusyTrueWhenUserSentNoReply() {
        let ws = WebSocketClient()
        ws.lastUserSentAt = Date()
        ws.lastAssistantAt = nil
        XCTAssertTrue(ws.isBusy)
    }

    func testIsBusyFalseAfterAssistantReply() {
        let ws = WebSocketClient()
        let now = Date()
        ws.lastUserSentAt = now
        ws.lastAssistantAt = now.addingTimeInterval(1)
        XCTAssertFalse(ws.isBusy)
    }

    func testIsBusyFalseAfterFiveMinuteTimeout() {
        let ws = WebSocketClient()
        ws.lastUserSentAt = Date().addingTimeInterval(-400)   // 400s ago
        ws.lastAssistantAt = nil
        XCTAssertFalse(ws.isBusy)
    }

    func testIsBusyFalseWhenNoUserMessage() {
        let ws = WebSocketClient()
        XCTAssertFalse(ws.isBusy)
    }
}
```

- [ ] **Step 2: Run — expect failure (fields don't exist yet)**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisAppTests/WebSocketClientBusyTests
```

Expected: FAIL — `value of type 'WebSocketClient' has no member 'lastUserSentAt'` etc.

---

## Task 6: WebSocketClient isBusy state — implementation

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`

- [ ] **Step 1: Add new observable fields**

Locate the existing `@Observable` field declarations near the top of `WebSocketClient` (around line 13 — `var isTyping = false`). Add immediately below:

```swift
var lastUserSentAt: Date? = nil
var lastAssistantAt: Date? = nil
var thinkingDetail: String? = nil

/// Persistent "agent is busy" — derived state.
/// True if: server typing OR user sent < 5min ago and no later assistant reply.
var isBusy: Bool {
    if isTyping { return true }
    guard let sent = lastUserSentAt else { return false }
    if let got = lastAssistantAt, got >= sent { return false }
    return Date().timeIntervalSince(sent) < 300
}
```

- [ ] **Step 2: Wire `lastUserSentAt` into `send(text:...)`**

In the `send(text: String, ...)` method, immediately after `isTyping = true` (around line 100), add:

```swift
lastUserSentAt = Date()
```

- [ ] **Step 3: Wire `lastAssistantAt` into incoming-message handling**

In `routeIncomingMessage` (around line 380, or wherever assistant messages are appended), after the message append, add:

```swift
if msg.role == .assistant {
    lastAssistantAt = Date()
}
```

If `routeIncomingMessage` isn't where assistant messages land, grep for `.assistant` in the file to find the right append point and add the line there.

- [ ] **Step 4: Wire `thinkingDetail` for status messages**

In the same `routeIncomingMessage` function, when a `status` message arrives with `kind == "system"`, set:

```swift
if case .status(let info) = msg.content, info.kind == "system" {
    thinkingDetail = info.text
    // Auto-clear after 30s
    Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(30))
        if self?.thinkingDetail == info.text { self?.thinkingDetail = nil }
    }
}
```

- [ ] **Step 5: Reset on disconnect / reconnect failure**

In `receive(ws:)` failure branch (around line 249, where `isTyping = false` is set), add:

```swift
lastUserSentAt = nil
lastAssistantAt = nil
thinkingDetail = nil
```

In `routeIncomingMessage` for an `assistant` message arrival, also clear:

```swift
thinkingDetail = nil
```

(Place this clear right after `lastAssistantAt = Date()` so any active status detail goes away when the real reply arrives.)

- [ ] **Step 6: Run tests — expect pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisAppTests/WebSocketClientBusyTests
```

Expected: PASS for all 5 tests.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientBusyTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add isBusy derived state and thinkingDetail to WebSocketClient"
```

---

## Task 7: Heartbeat — failing tests

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisAppTests/HeartbeatTests.swift`

- [ ] **Step 1: Write tests**

Write to `ios/JarvisApp/Sources/JarvisAppTests/HeartbeatTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class HeartbeatTests: XCTestCase {
    func testForceReconnectClearsTransientState() {
        let ws = WebSocketClient()
        ws.isTyping = true
        ws.isConnected = true
        ws.lastUserSentAt = Date()

        ws.forceReconnect(reason: "test")

        XCTAssertFalse(ws.isConnected)
        XCTAssertFalse(ws.isTyping)
    }

    func testStaleHeartbeatTriggersReconnect() {
        let ws = WebSocketClient()
        ws.isConnected = true
        ws.lastPongAt = Date().addingTimeInterval(-60)   // 60s ago, past 35s timeout
        ws.tickHeartbeatForTesting()
        XCTAssertFalse(ws.isConnected, "stale pong should force reconnect (mark disconnected)")
    }

    func testFreshHeartbeatNoReconnect() {
        let ws = WebSocketClient()
        ws.isConnected = true
        ws.lastPongAt = Date()   // just now
        // tickHeartbeatForTesting() calls into the real ping path which requires a live task —
        // assert it does NOT mark as disconnected when pong is fresh.
        ws.tickHeartbeatForTesting()
        XCTAssertTrue(ws.isConnected, "fresh pong, no real socket → should remain connected (no force reconnect)")
    }
}
```

- [ ] **Step 2: Run — expect failure**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisAppTests/HeartbeatTests
```

Expected: FAIL — `forceReconnect`, `lastPongAt`, `tickHeartbeatForTesting` don't exist.

---

## Task 8: Heartbeat — implementation

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`

- [ ] **Step 1: Add heartbeat fields**

Below the `@ObservationIgnored private var reconnectDelay: TimeInterval = 1` line (around line 18):

```swift
@ObservationIgnored private var heartbeatTimer: Timer?
@ObservationIgnored var lastPongAt: Date = .distantPast
@ObservationIgnored private let pingInterval: TimeInterval = 25
@ObservationIgnored private let pongTimeout: TimeInterval = 35
```

(Note: `lastPongAt` is exposed at package access for tests; mark it `internal` not `private`.)

- [ ] **Step 2: Add heartbeat methods**

After the existing private methods (around line 200), add:

```swift
private func startHeartbeat() {
    heartbeatTimer?.invalidate()
    lastPongAt = Date()
    heartbeatTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tickHeartbeat() }
    }
}

private func stopHeartbeat() {
    heartbeatTimer?.invalidate()
    heartbeatTimer = nil
}

@MainActor
internal func tickHeartbeat() {
    guard let ws = task, isConnected else { return }
    if Date().timeIntervalSince(lastPongAt) > pongTimeout {
        forceReconnect(reason: "pong timeout")
        return
    }
    ws.sendPing { [weak self] error in
        Task { @MainActor in
            if error == nil { self?.lastPongAt = Date() }
            else { self?.forceReconnect(reason: "ping failed") }
        }
    }
}

/// Test seam: lets tests trigger the heartbeat tick without a live URLSessionWebSocketTask.
/// The real `tickHeartbeat()` early-returns when `task == nil`, so this just inlines the
/// timeout check.
@MainActor
internal func tickHeartbeatForTesting() {
    if Date().timeIntervalSince(lastPongAt) > pongTimeout {
        forceReconnect(reason: "pong timeout (test)")
    }
}

@MainActor
internal func forceReconnect(reason: String) {
    print("WS reconnect: \(reason)")
    task?.cancel(with: .goingAway, reason: nil)
    isConnected = false
    isTyping = false
    lastUserSentAt = nil
    lastAssistantAt = nil
    thinkingDetail = nil
    reconnectDelay = 1
    stopHeartbeat()
    guard !stopped, let settings else { return }
    doConnect(settings: settings)
}
```

- [ ] **Step 3: Wire heartbeat start/stop into connection lifecycle**

In `handleIncoming` at the `auth_ok` branch (around line 280, after `isConnected = true`), add:

```swift
startHeartbeat()
```

In `disconnect()` (around line 57), before `stopped = true`, add:

```swift
stopHeartbeat()
```

In `forceReconnect` we already call `stopHeartbeat()` (above). At the start of `doConnect(settings:)` (around line 207), add:

```swift
stopHeartbeat()
```

- [ ] **Step 4: Run tests — expect pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisAppTests/HeartbeatTests
```

Expected: PASS for 3 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift ios/JarvisApp/Sources/JarvisAppTests/HeartbeatTests.swift
git commit -m "ios: add WebSocket heartbeat with stale-pong reconnect"
```

---

## Task 9: ConnectivityMonitor onSatisfied callback

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/ConnectivityMonitor.swift`

- [ ] **Step 1: Replace the file**

Overwrite `ios/JarvisApp/Sources/JarvisApp/Services/ConnectivityMonitor.swift` with:

```swift
import Network

/// Текущий тип сетевого соединения для контекста агента ("wifi" / "cellular" / "offline").
/// Также вызывает `onSatisfied` каждый раз когда сеть становится доступной — используется
/// `WebSocketClient` для немедленного реконнекта на переключении wifi/cellular.
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private(set) var status = ""

    /// Called when network path becomes `.satisfied`. Dispatched on the main queue.
    var onSatisfied: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status != .satisfied {
                self?.status = "offline"
            } else if path.usesInterfaceType(.wifi) {
                self?.status = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                self?.status = "cellular"
            } else {
                self?.status = "online"
            }

            if path.status == .satisfied {
                DispatchQueue.main.async { self?.onSatisfied?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "connectivity.monitor"))
    }
}
```

- [ ] **Step 2: Wire onSatisfied in WebSocketClient.start**

Locate `WebSocketClient.start(settings:)` method. After the existing setup but before the `doConnect` call, add:

```swift
ConnectivityMonitor.shared.onSatisfied = { [weak self] in
    Task { @MainActor in
        guard let self, !self.isConnected, !self.stopped, let s = self.settings else { return }
        self.doConnect(settings: s)
    }
}
```

- [ ] **Step 3: Build to verify compile**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/ConnectivityMonitor.swift ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift
git commit -m "ios: trigger WebSocket reconnect on NWPath satisfied"
```

---

## Task 10: ScenePhase wiring

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift`

- [ ] **Step 1: Add handleScenePhase to WebSocketClient**

In `WebSocketClient.swift`, after `tickHeartbeat()` method, add:

```swift
@MainActor
func handleScenePhase(_ phase: ScenePhase) {
    switch phase {
    case .active:
        if !isConnected, !stopped, let settings {
            doConnect(settings: settings)
        } else if isConnected {
            tickHeartbeat()
        }
    case .background, .inactive:
        break
    @unknown default:
        break
    }
}
```

Add at the top of the file: `import SwiftUI` (if not already present) — needed for `ScenePhase`.

- [ ] **Step 2: Wire into JarvisApp**

In `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift`, find the `WindowGroup { ContentView() ... }` block. Add:

```swift
@Environment(\.scenePhase) private var scenePhase
```

as a `@main` struct field, then add to the `WindowGroup`'s content (after existing modifiers):

```swift
.onChange(of: scenePhase) { _, new in
    Task { @MainActor in
        coordinator.ws.handleScenePhase(new)
    }
}
```

(`coordinator` is the existing `AppCoordinator` instance accessible via `@State` or `@Environment` — match the existing pattern in `JarvisApp.swift`.)

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift
git commit -m "ios: reconnect WebSocket on app foreground via scenePhase"
```

---

## Task 11: MessageRow — new bubbleless component

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift`

- [ ] **Step 1: Write the new component**

Write to `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift`:

```swift
import SwiftUI
import UIKit
import Photos

/// Bubbleless message renderer. Replaces MessageBubble.
struct MessageRow: View {
    let message: ChatMessage
    let isLast: Bool
    var onImageTap: ((UIImage) -> Void)? = nil
    var onFeedback: ((String, Bool) -> Void)? = nil
    var onActionTap: ((String, String, String) -> Void)? = nil
    var onSpeak: ((String) -> Void)? = nil

    @State private var feedback: FeedbackState = .none

    private enum FeedbackState { case none, positive, negative }
    private var isUser: Bool { message.role == .user }

    var body: some View {
        switch message.content {
        case .text(let text):
            textRow(text)
        case .image(let img, _):
            imageRow(img)
        case .file(let info):
            FileRow(info: info, isUser: isUser, isLast: isLast)
        case .action(let info):
            ActionRow(messageId: message.id, info: info, onTap: onActionTap, isLast: isLast)
        case .status(let info):
            StatusRow(info: info)
        }
    }

    // MARK: - Text row

    private func textRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                avatarDot
                VStack(alignment: .leading, spacing: 4) {
                    metaRow
                    Group {
                        if isUser {
                            Text(text).font(.system(size: 14))
                        } else {
                            MarkdownText(text, fontSize: 14)
                        }
                    }
                    .foregroundStyle(isUser ? .white : Color(red: 0.88, green: 0.94, blue: 0.95))
                    .lineSpacing(2)
                    .contextMenu {
                        contextMenuButtons(text)
                    }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(isUser ? "row-user-\(message.id)" : "row-assistant-\(message.id)")
    }

    // MARK: - Image row

    private func imageRow(_ img: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                avatarDot
                VStack(alignment: .leading, spacing: 4) {
                    metaRow
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { onImageTap?(img) }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.image = img
                                Theme.hapticSend()
                            } label: { Label("Копировать", systemImage: "doc.on.doc") }
                            Button {
                                Task {
                                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                                    guard status == .authorized || status == .limited else { return }
                                    try? await PHPhotoLibrary.shared().performChanges {
                                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                                    }
                                }
                            } label: { Label("Сохранить в фото", systemImage: "square.and.arrow.down") }
                        }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Building blocks

    private var avatarDot: some View {
        Circle()
            .fill(isUser
                  ? Color.white.opacity(0.25)
                  : Theme.accent)
            .frame(width: Theme.avatarDotSize, height: Theme.avatarDotSize)
            .shadow(color: isUser ? .clear : Theme.accent.opacity(0.5), radius: 3)
            .padding(.top, 7)
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(isUser ? "Я" : "JARVIS")
                .font(Theme.metaFont)
                .tracking(0.5)
                .foregroundStyle(Theme.accentMedium)
            Spacer()
            Text(message.timestamp, style: .time)
                .font(Theme.metaFont)
                .foregroundStyle(Theme.timestamp)
            if isUser {
                DeliveryChecks(status: message.deliveryStatus)
            }
            if !isUser && feedback != .none {
                Image(systemName: feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(feedback == .positive ? Theme.accentMedium : Theme.offline.opacity(0.5))
            }
        }
        .textCase(.uppercase)
    }

    @ViewBuilder
    private func contextMenuButtons(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            Theme.hapticSend()
        } label: { Label("Копировать", systemImage: "doc.on.doc") }
        ShareLink(item: text) {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
        if !isUser {
            Divider()
            Button {
                onSpeak?(text)
            } label: { Label("Проговорить", systemImage: "speaker.wave.2") }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    feedback = feedback == .positive ? .none : .positive
                }
                if feedback == .positive { onFeedback?(message.id, true) }
            } label: {
                Label(feedback == .positive ? "Убрать оценку" : "Полезно",
                      systemImage: feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    feedback = feedback == .negative ? .none : .negative
                }
                if feedback == .negative { onFeedback?(message.id, false) }
            } label: {
                Label(feedback == .negative ? "Убрать оценку" : "Не полезно",
                      systemImage: feedback == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
        }
    }

    private var accessibilityDescription: String {
        let role = isUser ? "Пользователь" : "Jarvis"
        let time = message.timestamp.formatted(date: .omitted, time: .shortened)
        switch message.content {
        case .text(let text):
            return "\(role): \(text). \(time)"
        case .image(_, let filename):
            return "\(role): изображение \(filename). \(time)"
        case .file(let info):
            return "\(role): файл \(info.name). \(time)"
        case .action(let info):
            return "Jarvis запрашивает: \(info.text). \(time)"
        case .status(let info):
            return "Система: \(info.text). \(time)"
        }
    }
}

// MARK: - File row

struct FileRow: View {
    let info: FileInfo
    let isUser: Bool
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(isUser ? Color.white.opacity(0.25) : Theme.accent)
                    .frame(width: Theme.avatarDotSize, height: Theme.avatarDotSize)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(isUser ? "Я" : "JARVIS")
                            .font(Theme.metaFont)
                            .tracking(0.5)
                            .foregroundStyle(Theme.accentMedium)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Image(systemName: iconForMime(info.mimeType))
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                                .lineLimit(1)
                            Text(formattedSize(info.size))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Theme.accent.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 280)
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

    private func iconForMime(_ mime: String) -> String {
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "play.rectangle" }
        if mime.contains("pdf")     { return "doc.richtext" }
        if mime.contains("zip") || mime.contains("tar") { return "doc.zipper" }
        if mime.contains("spreadsheet") || mime.contains("excel") { return "tablecells" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.on.rectangle" }
        if mime.contains("word") || mime.contains("document") { return "doc.text" }
        return "doc"
    }

    private func formattedSize(_ bytes: Int64) -> String {
        if bytes == 0 { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Action row

struct ActionRow: View {
    let messageId: String
    let info: ActionInfo
    var onTap: ((String, String, String) -> Void)?
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
                    HStack {
                        Text("JARVIS")
                            .font(Theme.metaFont)
                            .tracking(0.5)
                            .foregroundStyle(Theme.accentMedium)
                        Spacer()
                    }

                    Text(info.text)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.88, green: 0.94, blue: 0.95))

                    if info.answered, let sid = info.selectedId,
                       let btn = info.buttons.first(where: { $0.id == sid }) {
                        HStack(spacing: 6) {
                            CheckmarkShape()
                                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .frame(width: 10, height: 6)
                            Text(btn.label)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12))
                        .clipShape(Capsule())
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(info.buttons) { btn in
                                Button {
                                    Theme.hapticSend()
                                    onTap?(messageId, btn.id, btn.label)
                                } label: {
                                    Text(btn.label)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(foregroundFor(btn.style))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(backgroundFor(btn.style))
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(borderFor(btn.style), lineWidth: 0.5))
                                }
                            }
                        }
                    }
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

    private func foregroundFor(_ style: ActionButton.Style) -> Color {
        switch style {
        case .primary:   return Theme.accent
        case .danger:    return Theme.offline
        case .secondary: return Theme.textSecondary
        }
    }
    private func backgroundFor(_ style: ActionButton.Style) -> Color {
        switch style {
        case .primary:   return Theme.accent.opacity(0.12)
        case .danger:    return Theme.offline.opacity(0.12)
        case .secondary: return Theme.surface
        }
    }
    private func borderFor(_ style: ActionButton.Style) -> Color {
        switch style {
        case .primary:   return Theme.accent.opacity(0.3)
        case .danger:    return Theme.offline.opacity(0.3)
        case .secondary: return Theme.surfaceBorder
        }
    }
}

// MARK: - Status row

struct StatusRow: View {
    let info: StatusInfo

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(info.text)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 280, alignment: .leading)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.18), lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch info.kind {
        case "cost":   return "dollarsign.circle"
        case "health": return "heart.fill"
        case "alert":  return "exclamationmark.triangle.fill"
        case "system": return "gear"
        default:
            switch info.level {
            case .warning: return "exclamationmark.triangle"
            case .error:   return "xmark.circle"
            case .info:    return "info.circle"
            }
        }
    }
    private var color: Color {
        switch info.level {
        case .info:    return Theme.accent
        case .warning: return .orange
        case .error:   return Theme.offline
        }
    }
}

// MARK: - Thinking row (busy indicator)

struct ThinkingRow: View {
    let detail: String?
    @State private var dots: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            MiniOrbView(size: 14, mood: .processing)
                .padding(.leading, 1)
            Text(label + dots)
                .font(.system(size: 13, design: .default).italic())
                .foregroundStyle(Theme.accent.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, Theme.rowPadV)
        .accessibilityLabel("Jarvis обрабатывает запрос")
        .accessibilityIdentifier("thinking-row")
        .onAppear { startDots() }
    }

    private var label: String {
        detail ?? "обдумываю"
    }

    private func startDots() {
        Task { @MainActor in
            let cycle = ["", ".", "..", "..."]
            var i = 0
            while !Task.isCancelled {
                dots = cycle[i % cycle.count]
                i += 1
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
}

// MARK: - FlowLayout (kept from MessageBubble)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? .infinity, subviews: subviews)
        return result.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, pos) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                                  proposal: .unspecified)
        }
    }
    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
```

- [ ] **Step 2: Build to verify compile (do not delete MessageBubble.swift yet)**

```bash
cd ios/JarvisApp && xcodegen generate && cd ../..
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds. `MessageBubble` still wired in ChatView; `MessageRow` is parallel.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add bubbleless MessageRow component (parallel to MessageBubble)"
```

---

## Task 12: MiniOrbView particle overlay

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MiniOrbView.swift`

- [ ] **Step 1: Add size-conditional particle overlay**

Read `MiniOrbView.swift` first. Locate the `var body` block. Wrap the existing body in a `ZStack` and add a particles layer that only renders when `size >= 20 && mood == .processing`:

```swift
@State private var particleAngle: Double = 0

var body: some View {
    ZStack {
        // Existing orb rendering (keep as-is)
        existingOrbBody

        // Particles for thinking mood at non-tiny sizes
        if size >= 20 && mood == .processing {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(cyan.opacity(0.7))
                    .frame(width: 2.5, height: 2.5)
                    .offset(x: cos(particleAngle + Double(i) * (2 * .pi / 3)) * (size / 2 + 4),
                            y: sin(particleAngle + Double(i) * (2 * .pi / 3)) * (size / 2 + 4))
            }
            .onAppear {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    particleAngle = 2 * .pi
                }
            }
        }
    }
}
```

Where `existingOrbBody` is whatever the current `var body` returns — extract it into a `@ViewBuilder private var existingOrbBody: some View { ... }` computed property so the new `body` can compose.

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 3: Visual check in simulator (manual)**

Run the app, navigate to ChatView, trigger `ws.isBusy = true` (e.g., send a message). Verify the header orb (size 22, mood `.processing`) shows 3 rotating particles around it.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/MiniOrbView.swift
git commit -m "ios: add particle overlay to MiniOrbView for .processing at size >= 20"
```

---

## Task 13: ChatView — swap MessageBubble for MessageRow, replace TypingIndicator

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Replace the message rendering**

In `ChatView.swift`, find the `ForEach(Array(visibleMessages.enumerated())) ...` block (around line 82). Replace:

```swift
MessageBubble(
    message: msg,
    onImageTap: { img in fullScreenImage = img },
    onFeedback: { messageId, isPositive in
        coordinator.sendFeedback(messageId: messageId, value: isPositive, messageText: msg.text)
    },
    onActionTap: { messageId, buttonId, buttonLabel in
        coordinator.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
    },
    onSpeak: { text in coordinator.speak(text) }
)
```

with:

```swift
MessageRow(
    message: msg,
    isLast: index == visibleMessages.count - 1,
    onImageTap: { img in fullScreenImage = img },
    onFeedback: { messageId, isPositive in
        coordinator.sendFeedback(messageId: messageId, value: isPositive, messageText: msg.text)
    },
    onActionTap: { messageId, buttonId, buttonLabel in
        coordinator.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
    },
    onSpeak: { text in coordinator.speak(text) }
)
```

- [ ] **Step 2: Replace TypingIndicator with ThinkingRow gated by isBusy**

Find the block (around line 113):

```swift
if ws.isTyping {
    TypingIndicator()
        .id("typing")
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
}
```

Replace with:

```swift
if ws.isBusy {
    ThinkingRow(detail: ws.thinkingDetail)
        .id("thinking")
        .transition(.opacity.combined(with: .offset(y: 4)))
}
```

- [ ] **Step 3: Update scroll-to-bottom triggers**

Find `.onChange(of: ws.isTyping)` (around line 177). Change to `.onChange(of: ws.isBusy)` and update the inner `proxy.scrollTo("typing", ...)` to `proxy.scrollTo("thinking", ...)`.

In the keyboard-show handler block (around line 184), change `if ws.isTyping` to `if ws.isBusy` and `"typing"` to `"thinking"`.

In `EmptyStateView` gating (line 58), change `!ws.isTyping` to `!ws.isBusy`.

In the input-bar visibility (line 233), change `ws.isTyping` to `ws.isBusy`.

- [ ] **Step 4: Adjust transitions on MessageRow insertion**

Find the `.transition(.asymmetric(...))` on the MessageBubble loop. Replace the body with:

```swift
.transition(
    .asymmetric(
        insertion: .opacity.combined(with: .offset(y: 8)),
        removal:   .opacity
    )
)
```

(Remove `.scale` per the spec — text shouldn't visually re-size on insertion.)

- [ ] **Step 5: Build and run manually**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds. Manually verify in simulator: messages render bubbleless, thinking shows orb + label.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "ios: wire MessageRow and ThinkingRow into ChatView"
```

---

## Task 14: Delete MessageBubble and ArchivedChatView

**Files:**
- Delete: `ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift`
- Delete: `ios/JarvisApp/Sources/JarvisApp/Views/ArchivedChatView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift`

- [ ] **Step 1: Remove ArchivedChatView's references in ConversationListView**

Open `ConversationListView.swift`. Find `@State private var archivedConversation: Conversation? = nil` (around line 8) and delete that line.

Find the `conversationRow` button body (around line 208):

```swift
return Button {
    if isActive {
        dismiss()
    } else {
        archivedConversation = conv
    }
} label: {
```

Replace with:

```swift
return Button {
    onAction(.open(conv))
    dismiss()
} label: {
```

Find the `.fullScreenCover(item: $archivedConversation)` modifier (around line 165) and delete the entire block:

```swift
.fullScreenCover(item: $archivedConversation) { conv in
    ArchivedChatView(
        conversation: conv,
        messages: store.loadMessages(for: conv.id)
    ) { ... }
}
```

In the `.contextMenu` for non-active conversations (around line 274), find:

```swift
Button {
    archivedConversation = conv
} label: {
    Label("Открыть", systemImage: "eye")
}
```

Replace with:

```swift
Button {
    onAction(.open(conv))
    dismiss()
} label: {
    Label("Открыть", systemImage: "eye")
}
```

- [ ] **Step 2: Delete the two files**

```bash
git rm ios/JarvisApp/Sources/JarvisApp/Components/MessageBubble.swift
git rm ios/JarvisApp/Sources/JarvisApp/Views/ArchivedChatView.swift
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate && cd ../..
```

- [ ] **Step 4: Build to verify nothing references the deleted symbols**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

If the build fails with `cannot find 'MessageBubble' in scope` or `cannot find 'TypingIndicator' in scope`, search and replace those references — `TypingIndicator` was inside MessageBubble.swift; ChatView already uses `ThinkingRow` now. Any other reference is a stale callsite.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: remove ArchivedChatView and MessageBubble; conv tap now opens conv"
```

---

## Task 15: Remove Settings "История" section

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift`

- [ ] **Step 1: Delete the "История" settings section**

In `SettingsView.swift`, find the block (around line 105):

```swift
// Conversation history section
if !isInitialSetup, let store {
    settingsSection(title: "История") {
        NavigationLink {
            ConversationListView(store: store) { action in
                dismiss()
                onConversationAction?(action)
            }
        } label: {
            settingsField(icon: "bubble.left.and.bubble.right", label: "Диалоги") { ... }
        }
    }
}
```

Delete the entire `if !isInitialSetup, let store { ... }` block (around 25 lines).

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift
git commit -m "ios: remove conversation history section from settings (moved to drawer)"
```

---

## Task 16: Extract DrawerContent from ConversationListView

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift`

- [ ] **Step 1: Add a DrawerContent view next to ConversationListView**

At the bottom of `ConversationListView.swift`, add a new struct:

```swift
/// Drawer-friendly version of the conversation list — same logic, no full-screen chrome.
/// Hosted as a sliding overlay from ChatView, not as a sheet.
struct DrawerContent: View {
    var store: ConversationStore
    var onAction: (ConversationAction) -> Void
    var onSettings: () -> Void = {}

    @State private var searchText = ""
    @State private var conversationToDelete: Conversation? = nil

    private var filtered: [Conversation] {
        guard !searchText.isEmpty else { return store.conversations }
        let q = searchText.lowercased()
        return store.conversations.filter {
            $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    private var grouped: [(String, [Conversation])] {
        // Reuse logic from ConversationListView.grouped (copy verbatim — keep both
        // implementations consistent until the list view is also removed).
        let calendar = Calendar.current
        let now = Date()
        var pinned: [Conversation] = []
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var thisWeek: [Conversation] = []
        var older: [Conversation] = []
        for conv in filtered {
            if conv.isPinned { pinned.append(conv) }
            else if calendar.isDateInToday(conv.lastMessageAt) { today.append(conv) }
            else if calendar.isDateInYesterday(conv.lastMessageAt) { yesterday.append(conv) }
            else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                    conv.lastMessageAt > weekAgo { thisWeek.append(conv) }
            else { older.append(conv) }
        }
        var result: [(String, [Conversation])] = []
        if !pinned.isEmpty    { result.append(("Закреплённые", pinned)) }
        if !today.isEmpty     { result.append(("Сегодня", today)) }
        if !yesterday.isEmpty { result.append(("Вчера", yesterday)) }
        if !thisWeek.isEmpty  { result.append(("Эта неделя", thisWeek)) }
        if !older.isEmpty     { result.append(("Ранее", older)) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Диалоги")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                Spacer()
                Button { onAction(.newChat) } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentMedium)
                TextField("Поиск в архиве...", text: $searchText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.accent.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.15), lineWidth: 0.5))
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, 12)

            // Empty state
            if store.conversations.isEmpty {
                Spacer()
                Text("Нет диалогов")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(grouped, id: \.0) { group, conversations in
                        Section {
                            ForEach(conversations) { conv in
                                drawerRow(conv)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            }
                        } header: {
                            Text(group.uppercased())
                                .font(Theme.metaFont)
                                .tracking(1)
                                .foregroundStyle(Theme.accentMedium)
                                .padding(.horizontal, Theme.hPadding)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            // Settings footer
            Divider().background(Theme.hairlineColor)
            Button(action: onSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Настройки")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.accentMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.hPadding)
                .padding(.vertical, 14)
            }
        }
        .background(Color(red: 0.04, green: 0.08, blue: 0.11))   // slightly darker than chat bg
        .accessibilityIdentifier("conv-drawer")
        .alert("Удалить диалог?", isPresented: Binding(
            get: { conversationToDelete != nil },
            set: { if !$0 { conversationToDelete = nil } }
        )) {
            Button("Отмена", role: .cancel) { conversationToDelete = nil }
            Button("Удалить", role: .destructive) {
                if let conv = conversationToDelete {
                    withAnimation(.spring(duration: 0.3)) { store.deleteConversation(conv.id) }
                    conversationToDelete = nil
                }
            }
        } message: {
            Text("Диалог «\(conversationToDelete?.title ?? "")» будет удалён безвозвратно.")
        }
    }

    private func drawerRow(_ conv: Conversation) -> some View {
        let isActive = conv.id == store.activeConversationId
        return Button {
            onAction(.open(conv))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(isActive ? Theme.accent : Theme.accent.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .shadow(color: isActive ? Theme.accent.opacity(0.6) : .clear, radius: 3)
                    .padding(.top, 7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if conv.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.accentMedium)
                        }
                        Text(conv.title)
                            .font(.system(size: 14, weight: isActive ? .medium : .regular))
                            .foregroundStyle(Theme.textPrimary.opacity(isActive ? 0.9 : 0.7))
                            .lineLimit(1)
                    }
                    if !conv.preview.isEmpty {
                        Text(conv.preview)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Text(formattedDate(conv.lastMessageAt) + " · \(conv.messageCount) сообщ.")
                        .font(Theme.metaFont)
                        .foregroundStyle(Theme.accentMedium)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, 12)
            .background(isActive ? Theme.accent.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("conv-row-\(conv.id.uuidString)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                conversationToDelete = conv
            } label: { Label("Удалить", systemImage: "trash") }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation(.spring(duration: 0.25)) { store.togglePin(conv.id) }
            } label: {
                Label(conv.isPinned ? "Открепить" : "Закрепить",
                      systemImage: conv.isPinned ? "pin.slash" : "pin")
            }
            .tint(Theme.accent)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(date) {
            return "вчера, " + date.formatted(date: .omitted, time: .shortened)
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift
git commit -m "ios: add DrawerContent — drawer-friendly conversation list"
```

---

## Task 17: Drawer integration in ChatView (overlay + gestures + hamburger)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Add drawer state**

In `ChatView`, add the following `@State` properties (near other `@State` declarations around line 22):

```swift
@State private var drawerOpen = false
@State private var drawerDragOffset: CGFloat = 0
```

- [ ] **Step 2: Wrap the body in a ZStack with drawer overlay**

The current `body` returns a `VStack(spacing: 0) { ... }`. Wrap that whole `VStack` in a `ZStack(alignment: .leading)`. After the `VStack`, add:

```swift
// Shroud
if drawerOpen {
    Color.black.opacity(0.5)
        .ignoresSafeArea()
        .onTapGesture { withAnimation { drawerOpen = false } }
        .transition(.opacity)
}

// Drawer
DrawerContent(
    store: store,
    onAction: { action in
        coordinator.handleAction(action)
        withAnimation { drawerOpen = false; drawerDragOffset = 0 }
    },
    onSettings: {
        withAnimation { drawerOpen = false }
        showSettings = true
    }
)
.frame(width: Theme.drawerWidth)
.offset(x: drawerOpen
        ? max(-Theme.drawerWidth, drawerDragOffset)
        : -Theme.drawerWidth)
.gesture(
    DragGesture()
        .onChanged { value in
            if drawerOpen && value.translation.width < 0 {
                drawerDragOffset = value.translation.width
            }
        }
        .onEnded { value in
            if drawerOpen && value.translation.width < -60 {
                withAnimation(.spring(duration: 0.3)) {
                    drawerOpen = false
                    drawerDragOffset = 0
                }
            } else {
                withAnimation { drawerDragOffset = 0 }
            }
        }
)
.shadow(color: .black.opacity(drawerOpen ? 0.4 : 0), radius: 12, x: 4)
.animation(.spring(duration: 0.35, bounce: 0.05), value: drawerOpen)
```

- [ ] **Step 3: Add edge-swipe gesture to the main content**

On the `VStack` that contains the chat body, add a `.gesture(...)` modifier:

```swift
.gesture(
    DragGesture(minimumDistance: 10)
        .onChanged { value in
            if value.startLocation.x < 24 && value.translation.width > 0 && !drawerOpen {
                drawerDragOffset = min(value.translation.width - Theme.drawerWidth, 0)
            }
        }
        .onEnded { value in
            if !drawerOpen && value.startLocation.x < 24 && value.translation.width > 80 {
                withAnimation(.spring(duration: 0.3)) {
                    drawerOpen = true
                    drawerDragOffset = 0
                }
            } else if !drawerOpen {
                withAnimation { drawerDragOffset = 0 }
            }
        }
)
```

- [ ] **Step 4: Add hamburger button to header**

In the existing `private var header: some View` block, find the leading `Button { showProfile = true } label: { ZStack { ... } }` (the connection-status profile dot, around line 309). Insert a hamburger button **before** it:

```swift
Button {
    withAnimation(.spring(duration: 0.35, bounce: 0.05)) { drawerOpen = true }
} label: {
    VStack(spacing: 4) {
        Rectangle().frame(width: 18, height: 1.5)
        Rectangle().frame(width: 14, height: 1.5)
        Rectangle().frame(width: 18, height: 1.5)
    }
    .foregroundStyle(Theme.accentMedium)
    .frame(width: Theme.minTapSize, height: Theme.minTapSize)
}
.accessibilityIdentifier("hamburger-btn")
.accessibilityLabel("Открыть список диалогов")
```

- [ ] **Step 5: Build and verify**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 6: Manual verification**

Run in simulator. Test: hamburger tap → drawer slides in. Tap shroud → drawer closes. Edge-swipe → drawer slides in. Drag drawer leftward → drawer closes.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "ios: add left drawer for conversation switching (hamburger + edge-swipe)"
```

---

## Task 18: Header — add orb-mini with connection status overlay

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Replace the existing profile-status button with orb-mini + status dot**

In the header view, find the existing `Button { showProfile = true } label: { ZStack { Circle() ... } }` block (around line 309). Replace its body (the inner `label:`) with:

```swift
ZStack(alignment: .bottomTrailing) {
    MiniOrbView(size: 22, mood: orbMood)
    Circle()
        .fill(ws.isConnected ? Theme.online : Theme.offline)
        .frame(width: 6, height: 6)
        .overlay(Circle().stroke(Theme.background, lineWidth: 1))
}
.frame(width: Theme.minTapSize, height: Theme.minTapSize)
```

- [ ] **Step 2: Compute orbMood**

In `ChatView`, add a computed property near the other private properties:

```swift
private var orbMood: OrbMood {
    if !ws.isConnected               { return .error }
    if ws.isBusy                     { return .processing }
    if coordinator.speech.isSpeaking { return .speaking }
    return .calm
}
```

(Note: we don't have a SpeechManager `isRecording` flag accessible at this level — leave that case out. The orb falls back to `.calm` when nothing's happening.)

- [ ] **Step 3: Build and verify**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 4: Manual verification**

Run in simulator. Verify the header now shows the orb in place of the connection-status dot. Send a message — orb should shift to `.processing` and show particles.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "ios: replace header connection dot with mood-driven MiniOrbView"
```

---

## Task 19: ConnectionBanner — hairline strip

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/ConnectionBanner.swift`

- [ ] **Step 1: Replace the existing banner**

Read the file first to understand current shape. Then overwrite with:

```swift
import SwiftUI

/// Hairline strip under the chat header. 28pt tall when disconnected, 0pt when connected.
struct ConnectionBanner: View {
    let isConnected: Bool
    var onTap: () -> Void

    @State private var pulseScale: CGFloat = 1

    var body: some View {
        Group {
            if !isConnected {
                Button(action: onTap) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulseScale)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                    pulseScale = 1.4
                                }
                            }
                        Text("Восстанавливаю связь...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.hPadding)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .offset(y: -10)))
            }
        }
        .animation(.easeOut(duration: 0.4), value: isConnected)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/ConnectionBanner.swift
git commit -m "ios: redesign ConnectionBanner as hairline strip"
```

---

## Task 20: DateSeparator — text-on-hairline

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Replace the DateSeparator implementation**

At the bottom of `ChatView.swift`, find the `private struct DateSeparator: View` block. Replace the `body` with:

```swift
var body: some View {
    HStack(spacing: 8) {
        Rectangle().fill(Theme.accent.opacity(0.1)).frame(height: 0.5)
        Text(formatted)
            .font(Theme.metaFont)
            .tracking(1)
            .foregroundStyle(Theme.accent.opacity(0.4))
        Rectangle().fill(Theme.accent.opacity(0.1)).frame(height: 0.5)
    }
    .padding(.horizontal, Theme.rowPadH)
    .padding(.vertical, 8)
}
```

Update `formatted`:

```swift
private var formatted: String {
    if Calendar.current.isDateInToday(date) { return "СЕГОДНЯ" }
    if Calendar.current.isDateInYesterday(date) { return "ВЧЕРА" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMMM"
    return f.string(from: date).uppercased()
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "ios: redesign DateSeparator as text-on-hairline"
```

---

## Task 21: UnifiedInputBar polish + identifiers

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/UnifiedInputBar.swift`

- [ ] **Step 1: Update pill styling**

Find the `HStack(spacing: 0)` containing the `+` button and `TextField` (around line 54). The block ending with:

```swift
.background(Theme.surface)
.clipShape(RoundedRectangle(cornerRadius: Theme.inputRadius))
```

Replace those two lines with:

```swift
.background(Color.white.opacity(0.04))
.overlay(
    RoundedRectangle(cornerRadius: Theme.inputBarRadius)
        .stroke(Theme.accent.opacity(0.15), lineWidth: 0.5)
)
.clipShape(RoundedRectangle(cornerRadius: Theme.inputBarRadius))
```

- [ ] **Step 2: Add identifiers to TextField and send button**

On the `TextField` (around line 59), add after `.submitLabel(...)`:

```swift
.accessibilityIdentifier("message-input")
```

Locate the send-button (mic / send icon at the right edge of the row). Add `.accessibilityIdentifier("send-btn")` on its outer view.

- [ ] **Step 3: Polish send button shape**

Find the send-button rendering. Verify it's a 36×36 `Circle` filled with `Theme.accent`. If not, update the frame and clipShape. The icon `arrow.up` should be 16pt, `.bold`, `Theme.background` foreground.

- [ ] **Step 4: Refine command suggestions and attachment chips**

In the `CommandList` rendering, change the row separator style from full dividers to 0.5pt hairlines:

```swift
Divider()
    .background(Theme.accent.opacity(0.05))
    .frame(height: 0.5)
```

In `AttachmentChips`, adjust chip corner radius to 10, padding to 8/6, and the `×` button to 11pt.

- [ ] **Step 5: Build and manual check**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds. Run in simulator, type a message — pill should look thinner-bordered with translucent fill.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/UnifiedInputBar.swift
git commit -m "ios: polish UnifiedInputBar pill + send button + add a11y identifiers"
```

---

## Task 22: EmptyStateView refresh

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/EmptyStateView.swift`

- [ ] **Step 1: Overwrite with the refreshed view**

Read the existing file first to preserve callback signatures (`onSuggestion`, `onStartVoice`, `onStartText`). Then overwrite with:

```swift
import SwiftUI

struct EmptyStateView: View {
    var onSuggestion: (String) -> Void
    var onStartVoice: () -> Void
    var onStartText: () -> Void

    private let suggestions = [
        "Что в календаре на сегодня?",
        "Покажи последние задачи",
        "Сделай резюме рабочего дня"
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            MiniOrbView(size: 96, mood: .calm)

            Text("О чём поговорим?")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { onSuggestion(s) } label: {
                            Text(s)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .overlay(
                                    Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 0.5)
                                )
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, Theme.hPadding)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: onStartVoice) {
                    HStack {
                        Image(systemName: "mic.fill")
                        Text("Голосом")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 0.5))
                    .clipShape(Capsule())
                }

                Button(action: onStartText) {
                    HStack {
                        Image(systemName: "keyboard")
                        Text("Текстом")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 0.5))
                    .clipShape(Capsule())
                }
                .accessibilityIdentifier("empty-start-text")
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/EmptyStateView.swift
git commit -m "ios: refresh EmptyStateView with large orb and hairline pills"
```

---

## Task 23: OrbHomeView "Continue" pill

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`

- [ ] **Step 1: Add Continue pill below the central orb**

Find the central orb rendering in `OrbHomeView` (look for `MiniOrbView(size: ...)` or `OrbView`). Below it (above the input bar / suggestion area), inject:

```swift
if let lastConv = store.conversations.first {
    Button {
        coordinator.handleAction(.open(lastConv))
        onOpenChat?()    // existing navigation callback
    } label: {
        HStack(spacing: 6) {
            Text("Продолжить: \(lastConv.title)")
                .font(.system(size: 13))
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 0.5))
        .clipShape(Capsule())
    }
    .padding(.top, 12)
}
```

The exact `coordinator`, `store`, and `onOpenChat` symbol names follow OrbHomeView's existing wiring — check the surrounding code and match. If `onOpenChat` doesn't exist, use whatever the existing "tap orb to enter chat" callback is.

- [ ] **Step 2: Build**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "ios: add Continue pill under home orb to resume last conversation"
```

---

## Task 24: Remove obsolete Theme tokens

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Utility/Theme.swift`

- [ ] **Step 1: Search for remaining bubble-token usages**

```bash
grep -rn "Theme\.userBubble\|Theme\.assistantBubble\|Theme\.userBubbleBorder\|Theme\.assistantBubbleBorder\|Theme\.bubbleRadius" ios/JarvisApp/Sources/
```

- [ ] **Step 2: Decide based on result**

If the search returns 0 matches, proceed to delete the tokens. If it returns matches (e.g., in file/action cards), audit each — most should already be replaced by Task 11; any remaining call sites must be fixed first.

- [ ] **Step 3: Delete the obsolete tokens from Theme.swift**

Remove the declarations:

```swift
static let userBubble: Color
static let assistantBubble: Color
static let userBubbleBorder
static let assistantBubbleBorder
static let bubbleRadius: CGFloat
```

Keep `messagePadH`, `messagePadV` (still used by inline cards in older sites).

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/Theme.swift
git commit -m "ios: remove unused bubble Theme tokens"
```

---

## Task 25: Update existing XCUITest identifiers

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisUITests/JarvisUITests.swift`

- [ ] **Step 1: Update predicates**

In `JarvisUITests.swift`, find:

```swift
NSPredicate(format: "identifier BEGINSWITH 'bubble-user-'")
```

Change to:

```swift
NSPredicate(format: "identifier BEGINSWITH 'row-user-'")
```

And:

```swift
NSPredicate(format: "identifier BEGINSWITH 'bubble-assistant-'")
```

Change to:

```swift
NSPredicate(format: "identifier BEGINSWITH 'row-assistant-'")
```

Update all three references (lines 85, 106, 130 in the original).

- [ ] **Step 2: Run existing UI tests**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisUITests
```

Expected: existing tests pass with new identifiers.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisUITests/JarvisUITests.swift
git commit -m "ios: update XCUI predicates from bubble- to row- identifiers"
```

---

## Task 26: New UI test — Drawer

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisUITests/DrawerTests.swift`

- [ ] **Step 1: Write the test**

Write to `ios/JarvisApp/Sources/JarvisUITests/DrawerTests.swift`:

```swift
import XCTest

final class DrawerTests: XCTestCase {
    func testHamburgerOpensDrawer() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "1"]
        app.launch()

        // Get into chat view (uses existing helper assumptions from JarvisUITests).
        let textStart = app.descendants(matching: .any)
            .matching(identifier: "empty-start-text").firstMatch
        if textStart.waitForExistence(timeout: 5) { textStart.tap() }

        let chatView = app.descendants(matching: .any)
            .matching(identifier: "chat-view").firstMatch
        XCTAssertTrue(chatView.waitForExistence(timeout: 5))

        let hamburger = app.buttons["hamburger-btn"]
        XCTAssertTrue(hamburger.waitForExistence(timeout: 3), "hamburger-btn not found")
        hamburger.tap()

        let drawer = app.descendants(matching: .any)
            .matching(identifier: "conv-drawer").firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 2), "conv-drawer didn't appear after hamburger tap")
    }

    func testEdgeSwipeOpensDrawer() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "1"]
        app.launch()

        let textStart = app.descendants(matching: .any)
            .matching(identifier: "empty-start-text").firstMatch
        if textStart.waitForExistence(timeout: 5) { textStart.tap() }

        let chatView = app.descendants(matching: .any)
            .matching(identifier: "chat-view").firstMatch
        XCTAssertTrue(chatView.waitForExistence(timeout: 5))

        let start = chatView.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = chatView.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        let drawer = app.descendants(matching: .any)
            .matching(identifier: "conv-drawer").firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 2), "conv-drawer didn't appear after edge-swipe")
    }
}
```

- [ ] **Step 2: Regenerate project**

```bash
cd ios/JarvisApp && xcodegen generate && cd ../..
```

- [ ] **Step 3: Run the tests**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisUITests/DrawerTests
```

Expected: both tests pass.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisUITests/DrawerTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add DrawerTests UI test coverage"
```

---

## Task 27: New UI test — ThinkingRow lifecycle

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisUITests/ThinkingRowTests.swift`

- [ ] **Step 1: Write the test**

Write to `ios/JarvisApp/Sources/JarvisUITests/ThinkingRowTests.swift`:

```swift
import XCTest

final class ThinkingRowTests: XCTestCase {
    func testThinkingRowVisibleAfterSend() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "1"]
        app.launch()

        let textStart = app.descendants(matching: .any)
            .matching(identifier: "empty-start-text").firstMatch
        if textStart.waitForExistence(timeout: 5) { textStart.tap() }

        let input = app.textFields["message-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Привет\n")

        let thinking = app.descendants(matching: .any)
            .matching(identifier: "thinking-row").firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 5), "thinking-row didn't appear after send")
    }

    func testThinkingRowDisappearsAfterReply() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "1"]
        app.launch()

        let textStart = app.descendants(matching: .any)
            .matching(identifier: "empty-start-text").firstMatch
        if textStart.waitForExistence(timeout: 5) { textStart.tap() }

        let input = app.textFields["message-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Привет\n")

        // The UI-test WebSocket mock sends a canned reply within 1-2s.
        let assistantRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row-assistant-'"))
            .firstMatch
        XCTAssertTrue(assistantRow.waitForExistence(timeout: 10),
                      "assistant reply didn't arrive — check WS test harness")

        let thinking = app.descendants(matching: .any)
            .matching(identifier: "thinking-row").firstMatch
        // After reply arrives, thinking-row should vanish within 1s.
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: thinking)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 2), .completed,
                       "thinking-row didn't disappear after assistant reply")
    }
}
```

- [ ] **Step 2: Regenerate project and run**

```bash
cd ios/JarvisApp && xcodegen generate && cd ../..
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisUITests/ThinkingRowTests
```

Expected: both tests pass.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisUITests/ThinkingRowTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add ThinkingRow UI test coverage"
```

---

## Task 28: Run host-side vitest to confirm no regression

**Files:**
- (none modified)

- [ ] **Step 1: Run host tests**

```bash
pnpm test
```

Expected: all tests pass, no protocol regression in `src/channels/ios-app.*.test.ts`.

- [ ] **Step 2: Run iOS test suite (unit + UI)**

```bash
xcodebuild test \
  -project ios/JarvisApp/JarvisApp.xcodeproj \
  -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

Expected: all unit tests (`JarvisAppTests`) and UI tests (`JarvisUITests`) pass.

---

## Task 29: Smoke test — manual run

**Files:**
- (none modified)

- [ ] **Step 1: Cold-launch sequence**

Run the app in the simulator. Verify in order:

1. Splash → OrbHomeView appears.
2. "Продолжить: <last conv>" pill visible under the orb when conversations exist.
3. Tap orb (or pill) → ChatView opens with the active conversation.
4. Header shows: hamburger ←  orb-mini (with connection dot)  ←→  JARVIS brand  ←→  gear.

- [ ] **Step 2: Messaging round-trip**

Send a message. Verify:

1. User row appears bubbleless with avatar-dot + meta + body.
2. Spinner (`sending`) → single check (`sent`) → double check (`delivered`) animates.
3. `thinking-row` appears with orb + "обдумываю...".
4. Assistant reply arrives, `thinking-row` disappears, assistant row inserts.
5. Long-press a row → context menu shows.

- [ ] **Step 3: Drawer round-trip**

1. Tap hamburger → drawer slides in from the left.
2. Tap a different conversation → drawer closes, ChatView updates.
3. Tap hamburger again → drawer slides in.
4. Edge-swipe right from screen edge → drawer slides in.
5. Drag drawer leftward → drawer closes.
6. Tap shroud → drawer closes.
7. Tap "⚙ Настройки" footer → drawer closes, settings sheet opens.

- [ ] **Step 4: Connection stability**

1. With WS connected, toggle airplane mode ON in simulator settings.
2. Within ~35s, ConnectionBanner hairline appears under the header.
3. Toggle airplane mode OFF — banner disappears within a few seconds (NWPath onSatisfied triggers reconnect).
4. Background the app for 60s, then foreground. Verify WS reconnects without a stuck spinner.

- [ ] **Step 5: Long-running task**

If you have a way to seed a slow agent task (e.g., `/sleep 90` if the agent supports it, or just spam a complex query), verify the `thinking-row` stays visible the entire time and clears only when the real reply arrives.

- [ ] **Step 6: Final commit (only if any tweaks were needed during smoke test)**

If the smoke test surfaced no issues, no commit. Otherwise: small fix commits.

---

## Self-Review

- [ ] Spec coverage:
  - Section 1/8 (Architecture): Task 1 (test target), Task 2 (theme), Tasks 11–14 (MessageRow + delete).
  - Section 2/8 (MessageRow): Task 11.
  - Section 3/8 (DeliveryChecks): Tasks 3, 4.
  - Section 4/8 (Thinking/Busy): Tasks 5, 6 (busy state), Task 11 (ThinkingRow inside MessageRow.swift), Task 13 (ChatView wire-in).
  - Section 5/8 (Connection): Tasks 7, 8 (heartbeat), Task 9 (NWPath), Task 10 (scenePhase), Task 19 (ConnectionBanner).
  - Section 6/8 (Drawer): Tasks 14 (remove archive), Task 16 (DrawerContent), Task 17 (drawer integration), Task 18 (header orb), Task 15 (settings cleanup).
  - Section 7/8 (Polish): Task 12 (orb particles), Task 20 (DateSeparator), Task 21 (input bar), Task 22 (empty state), Task 23 (orb home pill), Task 24 (theme cleanup).
  - Section 8/8 (Tests): Tasks 3 (DeliveryChecks tests), Task 5 (Busy tests), Task 7 (Heartbeat tests), Task 25 (XCUI updates), Tasks 26, 27 (new UI tests), Task 28 (regression run).

- [ ] Placeholder scan: searched the plan body for `TBD`, `TODO`, `fill in`, "appropriate", "similar to Task" — none present.

- [ ] Type consistency: `WebSocketClient` fields (`isBusy`, `lastUserSentAt`, `lastAssistantAt`, `thinkingDetail`, `lastPongAt`, `forceReconnect`, `tickHeartbeat`, `tickHeartbeatForTesting`, `handleScenePhase`) are defined in Task 6/8/10 and referenced in Tasks 5, 7, 11, 13. `OrbMood` cases used (`.calm`, `.processing`, `.speaking`, `.error`) match the existing enum in `MiniOrbView.swift`. `MessageRow` constructor signature matches the call site in Task 13. `DrawerContent` constructor (`store`, `onAction`, `onSettings`) matches the call in Task 17.

Plan complete.

---

## Plan complete and saved to `docs/superpowers/plans/2026-05-27-ios-chat-redesign.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
