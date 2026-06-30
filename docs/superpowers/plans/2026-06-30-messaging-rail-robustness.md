# Messaging-Rail Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two no-APNs messaging-rail bugs — (A) the WS fails to reconnect promptly on foreground, and (B) a backgrounded message can be notified but never rendered into the chat.

**Architecture:** (A) `TransportV2` (Swift actor) state machine: stop stranding `.connecting`, stop the intentional-disconnect reconnect re-arm, add an auth watchdog, and publish auth state so `WebSocketClientV2.isConnected` tracks reality; foreground forces a clean reconnect. (B) The host `/ios/pending` response gains `ts` + `has_attachments`, and the iOS pull path (`PendingNotifications.drain`) persists a chat row idempotently (not just notifies) for attachment-free messages.

**Tech Stack:** iOS SwiftUI + GRDB (`@testable import Jarvis`, XCTest, sim **iPhone 17 Pro**); Node host TypeScript (vitest). Spec: `docs/superpowers/specs/2026-06-30-messaging-rail-robustness-design.md`.

**Build/version:** ship as build **77 / 1.19.0** (single bump in the last iOS task — earlier iOS tasks must NOT touch `project.yml`). iPhone 16 sim is unavailable on this machine; use **iPhone 17 Pro**. SourceKit may show false `XCTest`/symbol errors — the sim `xcodebuild` is authoritative.

---

## File structure

iOS (`ios/JarvisApp/Sources/JarvisApp/`):
- `Services/TransportV2.swift` — connect reset-on-failure + auth watchdog; `handleSocketClose` idle-guard; `resetReconnectBackoff()`; `isAuthed()`; `onStateChange` callback. (A)
- `Services/WebSocketClientV2.swift` — `handleScenePhase(.active)` clean reconnect; wire `onStateChange` → `isConnected`. (A)
- `Storage/ConversationStoreV2.swift` — `insertInboundFromPull(...)`. (B)
- `Services/PendingNotifications.swift` — `PendingMessage` gains `ts`/`has_attachments`; `drain()` inserts text rows. (B)
- `project.yml` — build 77/1.19.0 (final task only).

Host (`src/channels/ios-app/v2/`):
- `http-handler.ts` — `/ios/pending` map adds `ts` + `has_attachments`. (B)
- `http-routes.test.ts` — extend pending assertions. (B)

---

## Task 1: TransportV2 — `handleSocketClose` idle-guard

Intentional `disconnect()` sets `state=.idle` then `socket.close()`, which (via task cancellation) fires `onClose` → `handleSocketClose` → currently re-arms a reconnect. Guard it.

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` (`handleSocketClose`, ~line 484)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/TransportV2ReconnectTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Read the existing `TransportV2Tests.swift` first for the real `MockWebSocket` (it exposes `onClose`/`onMessage` and a way to drive frames). Create `TransportV2ReconnectTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class TransportV2ReconnectTests: XCTestCase {
    // Build a transport on an in-memory store + a MockWebSocket (reuse the
    // helper/mocks from TransportV2Tests.swift — match their real names).
    func testIntentionalDisconnectDoesNotReconnect() async throws {
        let h = try makeTransport() // existing helper: { transport, socket, store }
        await h.transport.disconnect()
        // Simulate the close that socket.close() triggers via task cancellation.
        h.socket.onClose?(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let state = await h.transport.stateForTesting   // expose if not present
        XCTAssertEqual(state, .idle, "intentional disconnect must stay idle, not re-arm reconnect")
    }
}
```

If `TransportV2` has no test accessor for `state`, add `var stateForTesting: State { state }` (or reuse an existing one — check the file). Match the real mock/helper names from `TransportV2Tests.swift`.

- [ ] **Step 2: Run — verify FAIL**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/TransportV2ReconnectTests/testIntentionalDisconnectDoesNotReconnect 2>&1 | tail -20`
Expected: FAIL — state becomes `.reconnecting(...)` after the close.

- [ ] **Step 3: Add the idle-guard**

In `handleSocketClose(_ error:)`, add as the FIRST line of the body (before the existing `if case .reconnecting = state { return }`):

```swift
        // An intentional disconnect parks at `.idle`; the close it triggers
        // must NOT auto-reconnect (that re-armed the loop + inflated backoff).
        if state == .idle { return }
```

- [ ] **Step 4: Run — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/TransportV2ReconnectTests/testIntentionalDisconnectDoesNotReconnect 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift ios/JarvisApp/Sources/JarvisAppTests/TransportV2ReconnectTests.swift
git commit -m "fix(ios): intentional disconnect must not re-arm WS reconnect"
```

---

## Task 2: TransportV2 — connect reset-on-failure + auth watchdog

`connect()` sets `state=.connecting` before `await socket.connect()`/`sendEnvelope`. If the open/auth hangs (backgrounded socket, no `onClose`) or throws, `state` strands `.connecting` and the reentrancy guard no-ops every later `connect()`. Reset on throw + add a watchdog that recovers a stuck `.connecting`.

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` (`connect()` ~86-131; add fields + helpers)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/TransportV2ReconnectTests.swift` (append)

- [ ] **Step 1: Write failing tests**

Append:

```swift
    func testConnectResetsStateOnFailure() async throws {
        // MockWebSocket variant whose connect() throws. Reuse/extend the mock.
        let h = try makeTransport(failingConnect: true)
        try? await h.transport.connect()
        let state = await h.transport.stateForTesting
        XCTAssertEqual(state, .idle, "a failed connect must not strand .connecting")
    }

    func testAuthWatchdogRecoversStuckConnecting() async throws {
        // Mock connects OK but never delivers auth_ok. Short watchdog for the test.
        let h = try makeTransport(watchdogSeconds: 0.3)
        try? await h.transport.connect()              // → .connecting, no auth_ok
        let mid = await h.transport.stateForTesting
        XCTAssertEqual(mid, .connecting)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let after = await h.transport.stateForTesting
        XCTAssertNotEqual(after, .connecting, "watchdog must clear a stuck .connecting")
    }
```

Extend `makeTransport` (in the test file or shared helper) to accept `failingConnect` (mock throws on connect) and `watchdogSeconds` (passed to the transport init). Match the real mock — read `TransportV2Tests.swift`.

- [ ] **Step 2: Run — verify FAIL**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/TransportV2ReconnectTests 2>&1 | tail -20`
Expected: FAIL (stranded `.connecting`).

- [ ] **Step 3: Implement reset + watchdog**

In `TransportV2`, add fields near `reconnectTask` (~line 33):

```swift
    /// Bumped on each connect() entry; lets a watchdog tell "the connection I
    /// was scheduled for" from a later healthy one.
    private var connectGeneration: Int = 0
    private var watchdogTask: Task<Void, Never>?
    /// Seconds before a still-`.connecting` (auth never arrived) connection is
    /// reset + reconnected. Injectable for tests.
    private let connectWatchdogSeconds: Double
```

Add `connectWatchdogSeconds` to `init` (default `8.0`), stored. (Append the parameter at the end of the existing `init` signature with `= 8.0`.)

Rewrite `connect()` so state is reset on failure and a watchdog is armed:

```swift
    func connect() async throws {
        if state == .connecting || state == .authed { return }
        state = .connecting
        connectGeneration += 1
        let gen = connectGeneration
        armConnectWatchdog(gen)
        socket.onMessage = { [weak self] data in
            Task { [weak self] in
                do { try await self?.handleIncoming(data) }
                catch { Log.warn(.ws, "handleIncoming failed: \(error)") }
            }
        }
        socket.onClose = { [weak self] error in
            Task { [weak self] in await self?.handleSocketClose(error) }
        }
        do {
            try await socket.connect()
            let lastSeenInbound = try store.cursor(.lastSeenInbound)
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            let authEnv = V2.Envelope(
                v: V2.protocolVersion, kind: .control, type: .auth,
                id: UUID().uuidString, seq: nil,
                ts: ISO8601DateFormatter().string(from: Date()),
                payload: .auth(V2.Auth(
                    token: token, last_seen_inbound_seq: lastSeenInbound,
                    capabilities: ["image_ref"], app_version: appVersion, build: appBuild))
            )
            try await sendEnvelope(authEnv)
        } catch {
            // Never strand `.connecting`: reset so a later connect() can proceed.
            if state == .connecting { state = .idle }
            throw error
        }
    }

    private func armConnectWatchdog(_ gen: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.connectWatchdogSecondsValue ?? 8.0) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.connectWatchdogFired(gen)
        }
    }

    // nonisolated read of the injected interval for the sleep above.
    private nonisolated var connectWatchdogSecondsValue: Double { 8.0 }

    private func connectWatchdogFired(_ gen: Int) {
        guard connectGeneration == gen, state == .connecting else { return }
        Log.warn(.ws, "connect watchdog: auth never arrived, resetting + reconnecting")
        state = .idle
        scheduleReconnect()
    }
```

NOTE on `connectWatchdogSecondsValue`: a `nonisolated` computed property can't read the actor-isolated stored `connectWatchdogSeconds`. Simpler: capture the interval before the Task. Replace `armConnectWatchdog` body with:

```swift
    private func armConnectWatchdog(_ gen: Int) {
        watchdogTask?.cancel()
        let seconds = connectWatchdogSeconds
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.connectWatchdogFired(gen)
        }
    }
```

and DELETE the `connectWatchdogSecondsValue` property.

Extract the reconnect scheduler so both `handleSocketClose` and the watchdog use it. In `handleSocketClose`, after the guards, the existing body (compute delay, bump attempt, set `.reconnecting`, schedule `reconnectTask`) becomes a private `scheduleReconnect()`; `handleSocketClose` calls it:

```swift
    private func handleSocketClose(_ error: Error?) async {
        if state == .idle { return }
        if case .reconnecting = state { return }
        for (_, t) in ackTasks { t.cancel() }
        ackTasks.removeAll()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = min(maxReconnectDelaySeconds,
                        baseReconnectDelaySeconds * pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        state = .reconnecting(delaySeconds: delay)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            try? await self.connect()
        }
    }
```

Also cancel the watchdog on auth + on disconnect: in `handleAuthOk` (after `state = .authed`) add `watchdogTask?.cancel(); watchdogTask = nil`; in `disconnect()` add the same two lines.

- [ ] **Step 4: Run — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/TransportV2ReconnectTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` (all reconnect tests).

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift ios/JarvisApp/Sources/JarvisAppTests/TransportV2ReconnectTests.swift
git commit -m "fix(ios): connect resets state on failure + auth watchdog clears stuck .connecting"
```

---

## Task 3: TransportV2 — `resetReconnectBackoff()`, `isAuthed()`, `onStateChange`

The facade needs to (a) restart backoff on a foreground clean reconnect, (b) read authed-ness, and (c) be notified when auth state changes so `isConnected` tracks the whole session.

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/TransportV2ReconnectTests.swift` (append)

- [ ] **Step 1: Write failing test**

```swift
    func testAuthStateCallbackFires() async throws {
        let h = try makeTransport()
        var states: [Bool] = []
        await h.transport.setOnStateChange { authed in states.append(authed) }
        try await h.transport.handleAuthOk(lastSeenOutboundSeq: 0)  // → authed
        await h.transport.disconnect()                               // → not authed
        XCTAssertEqual(states, [true, false])
    }

    func testResetReconnectBackoff() async throws {
        let h = try makeTransport()
        await h.transport.bumpReconnectAttemptForTesting(5) // add a tiny test setter
        await h.transport.resetReconnectBackoff()
        XCTAssertEqual(await h.transport.reconnectAttemptForTesting, 0)
    }
```

(Add minimal test accessors if absent: `func bumpReconnectAttemptForTesting(_ n: Int) { reconnectAttempt = n }`, `var reconnectAttemptForTesting: Int { reconnectAttempt }`.)

- [ ] **Step 2: Run — verify FAIL**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/TransportV2ReconnectTests 2>&1 | tail -20`
Expected: FAIL — members missing.

- [ ] **Step 3: Implement**

Add to `TransportV2`:

```swift
    private(set) var onStateChange: (@Sendable (Bool) -> Void)?
    func setOnStateChange(_ cb: (@Sendable (Bool) -> Void)?) { onStateChange = cb }

    func isAuthed() -> Bool { state == .authed }
    func resetReconnectBackoff() { reconnectAttempt = 0 }
```

Fire `onStateChange` on transitions:
- in `handleAuthOk`, after `state = .authed`: `onStateChange?(true)`
- in `disconnect()`, after `state = .idle`: `onStateChange?(false)`
- in `scheduleReconnect()`, after `state = .reconnecting(...)`: `onStateChange?(false)`

- [ ] **Step 4: Run — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/TransportV2ReconnectTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift ios/JarvisApp/Sources/JarvisAppTests/TransportV2ReconnectTests.swift
git commit -m "feat(ios): TransportV2 onStateChange + isAuthed + resetReconnectBackoff"
```

---

## Task 4: WebSocketClientV2 — clean foreground reconnect + isConnected wiring

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift` (`handleScenePhase` ~371; `wireAuthOkCallback` ~699)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/` — add a focused test if a `WebSocketClientV2` test harness exists; otherwise verify via full build + the transport tests above.

- [ ] **Step 1: Wire `onStateChange` → `isConnected`**

In `wireAuthOkCallback()` (inside the `Task` that sets the transport callbacks), add:

```swift
            await transport.setOnStateChange { [weak self] authed in
                Task { @MainActor [weak self] in self?.isConnected = authed }
            }
```

- [ ] **Step 2: Force a clean reconnect on `.active`**

Replace the `.active` case body in `handleScenePhase`:

```swift
        case .active:
            // Force a clean reconnect: a prior connect may be stranded
            // (.connecting) or parked in a long backoff after a background cycle.
            // disconnect() resets to .idle + cancels pending work; resetting the
            // backoff restarts at the base delay; connect() then proceeds (the
            // reentrancy guard only blocks .connecting/.authed). isConnected is
            // updated by the onStateChange callback when auth_ok lands.
            Task { [weak self] in
                guard let self, let stack = self.stack else { return }
                await stack.transport.disconnect()
                await stack.transport.resetReconnectBackoff()
                try? await stack.transport.connect()
                try? await stack.transport.tickDispatcher()
            }
```

(Leave `.background` = `disconnect()` and `.inactive` = break unchanged.)

- [ ] **Step 3: Build + full transport test run**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/TransportV2ReconnectTests -only-testing:JarvisAppTests/TransportV2Tests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`; then a full `xcodebuild build` clean (UI wiring compiles).

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClientV2.swift
git commit -m "fix(ios): clean WS reconnect on foreground + isConnected tracks auth state"
```

---

## Task 5: Host — `/ios/pending` carries `ts` + `has_attachments`

**Files:**
- Modify: `src/channels/ios-app/v2/http-handler.ts` (the `/ios/pending` map, ~line 392-403)
- Test: `src/channels/ios-app/v2/http-routes.test.ts` (extend the pending test)

- [ ] **Step 1: Write the failing test**

Read the existing `/ios/pending` test in `http-routes.test.ts` for its harness (how it seeds an `outbound_queue` row + calls the route). Add/extend a case that enqueues a `message` row whose `payload_json` has `text`, `agent_id`, a `ts`, and an `attachments` array, then asserts the response message includes `ts` (number) and `has_attachments === true`; and a no-attachment row → `has_attachments === false`.

- [ ] **Step 2: Run — verify FAIL**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts`
Expected: FAIL — `ts`/`has_attachments` absent.

- [ ] **Step 3: Implement**

In the `/ios/pending` `.map((row) => {...})`, extend the payload parse + returned object:

```typescript
        let agent_id: string | null = null;
        let text = '';
        let ts: number | null = null;
        let has_attachments = false;
        try {
          const p = JSON.parse(row.payload_json) as {
            text?: unknown; agent_id?: unknown; ts?: unknown; attachments?: unknown;
          };
          if (typeof p.text === 'string') text = p.text;
          if (typeof p.agent_id === 'string') agent_id = p.agent_id;
          if (typeof p.ts === 'number') ts = p.ts;
          has_attachments = Array.isArray(p.attachments) && p.attachments.length > 0;
        } catch {
          /* malformed payload — surface id/seq with empty text */
        }
        return { id: row.id, seq: row.seq, type: row.type, agent_id, text, ts, has_attachments };
```

NOTE: confirm the `message` envelope payload actually carries `ts`. Read how `deliver()` builds the `message` envelope payload in `src/channels/ios-app/v2/index.ts`; if the payload has no `ts`, fall back to the row's `created_at` (the `OutboundQueueRow` has `created_at`) — i.e. `ts = row.created_at` when `p.ts` is absent. Use whichever the row reliably has; the iOS side only needs a monotonic authored-ish timestamp for ordering.

- [ ] **Step 4: Run — verify PASS**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts` then `pnpm run build`
Expected: PASS; build clean.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/http-handler.ts src/channels/ios-app/v2/http-routes.test.ts
git commit -m "feat(ios-app): /ios/pending carries ts + has_attachments for pull-render"
```

---

## Task 6: iOS — `ConversationStoreV2.insertInboundFromPull`

A lightweight idempotent text-row insert for the pull path. Mirrors `insertInbound`'s row shape (line ~250) minus attachments/actions, so a later WS `insertInbound` with the same `id` is a no-op (`INSERT OR IGNORE`).

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2PullTests.swift` (create)

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import GRDB
@testable import Jarvis

final class ConversationStoreV2PullTests: XCTestCase {
    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    func testInsertInboundFromPullIsIdempotent() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "msg-1", seq: 10, text: "hi", agentId: "jarvis", ts: 1000)
        try store.insertInboundFromPull(id: "msg-1", seq: 10, text: "hi", agentId: "jarvis", ts: 1000)
        XCTAssertEqual(try store.countAllMessages(), 1) // no duplicate
    }
}
```

(Use the real store init + `Schema.migrate` + `countAllMessages` — confirm names in `ConversationStoreV2.swift`/`Schema.swift`; `countAllMessages` exists per Task-11 of the summary feature.)

- [ ] **Step 2: Run — verify FAIL**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/ConversationStoreV2PullTests 2>&1 | tail -20`
Expected: FAIL — method missing.

- [ ] **Step 3: Implement**

Add to `ConversationStoreV2` (near `insertInbound`):

```swift
    /// Idempotent text-row insert for the background PULL path
    /// (`PendingNotifications`). Mirrors `insertInbound`'s row shape (no
    /// attachments/actions). `INSERT OR IGNORE` on the `id` PK so a later WS
    /// `insertInbound` for the same message is a safe no-op, and a re-pull
    /// doesn't duplicate. Does NOT advance the inbound cursor or record dedup —
    /// only the WS path owns those.
    func insertInboundFromPull(id: String, seq: Int?, text: String, agentId: String, ts: Int) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages
                  (id, dir, seq, text, status, ts, created_at, agent_id)
                VALUES (?, 'in', ?, ?, 'new', ?, ?, ?)
            """, arguments: [id, seq, text, ts, ts, agentId])
        }
    }
```

- [ ] **Step 4: Run — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/ConversationStoreV2PullTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift ios/JarvisApp/Sources/JarvisAppTests/ConversationStoreV2PullTests.swift
git commit -m "feat(ios): insertInboundFromPull — idempotent pull-path chat row"
```

---

## Task 7: iOS — `PendingNotifications.drain` renders text messages

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/PendingNotifications.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/PendingNotificationsTests.swift` (extend)

- [ ] **Step 1: Write failing test**

Extend the existing `PendingNotificationsTests` (the pure `parse` seam). Add a decode case asserting `PendingMessage` now carries `ts` and `has_attachments`:

```swift
    func testParseCarriesTsAndHasAttachments() {
        let json = """
        {"messages":[{"id":"msg-1","seq":10,"type":"message","agent_id":"jarvis",
          "text":"hi","ts":1000,"has_attachments":false}]}
        """.data(using: .utf8)!
        let msgs = PendingNotifications.parse(json)
        XCTAssertEqual(msgs.first?.ts, 1000)
        XCTAssertEqual(msgs.first?.has_attachments, false)
    }
```

(The `drain()` store-insert branch itself isn't unit-testable through the `LocalNotifier.shared`/store singletons — same documented limitation as the summary pull test. Cover the decode seam here; the insert is covered by Task 6.)

- [ ] **Step 2: Run — verify FAIL**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/PendingNotificationsTests 2>&1 | tail -20`
Expected: FAIL — fields missing.

- [ ] **Step 3: Implement**

In `PendingMessage`, add:

```swift
        let ts: Int?
        let has_attachments: Bool?
```

In `drain()`, change the non-summary branch to also persist a text row (read the store from the shared app stack — use the same accessor `LocalNotifier.shared` uses to reach the store, or `AppV2Bootstrap`'s shared store; confirm how `drain` can reach a `ConversationStoreV2`). The branch becomes:

```swift
                if m.type == "summary_ready" {
                    LocalNotifier.shared.raiseSummaryReady(id: m.id, body: m.text, agentId: m.agent_id ?? "jarvis")
                } else {
                    LocalNotifier.shared.raise(id: m.id, agentId: m.agent_id ?? "jarvis", text: m.text, seq: m.seq)
                    // Render attachment-free messages into the chat so a
                    // backgrounded message can't be stranded (notified-but-not-
                    // rendered). Attachment messages stay notify-only — WS renders
                    // the rich version (a text-only pull insert would strand it).
                    if m.has_attachments != true, let store = PendingNotifications.chatStore {
                        try? store.insertInboundFromPull(
                            id: m.id, seq: m.seq, text: m.text,
                            agentId: m.agent_id ?? "jarvis", ts: m.ts ?? m.seq)
                    }
                }
```

Provide `PendingNotifications.chatStore`: a static weak/optional set at app bootstrap (in `AppV2Bootstrap` or `AppCoordinator` init, the same place `LocalNotifier.shared.configure(store:)` is wired). Add `static weak var chatStore: ConversationStoreV2?` to `PendingNotifications`, and set it wherever `LocalNotifier.shared.configure(store:)` is called (grep for `configure(store:`). If `ConversationStoreV2` is a struct (not a class), use a non-weak optional `static var chatStore: ConversationStoreV2?` instead. Confirm its type in `ConversationStoreV2.swift`.

- [ ] **Step 4: Run — verify PASS + full build**

Run:
```bash
cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/PendingNotificationsTests 2>&1 | tail -20
xcodebuild build -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/PendingNotifications.swift ios/JarvisApp/Sources/JarvisAppTests/PendingNotificationsTests.swift <bootstrap file>
git commit -m "fix(ios): pull path renders attachment-free messages into the chat"
```

---

## Task 8: iOS version bump + full suite

**Files:** `ios/JarvisApp/project.yml`

- [ ] **Step 1: Bump** `MARKETING_VERSION` "1.18.0" → "1.19.0", `CURRENT_PROJECT_VERSION` "76" → "77". (Confirm current values first — increment from the real baseline.)
- [ ] **Step 2:** `cd ios/JarvisApp && xcodegen generate && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|Failing tests" | tail -8` — expect 0 failures across the whole suite.
- [ ] **Step 3:** verify `git diff --stat` on `project.pbxproj` is only the version bump (×2 each).
- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "chore(ios): bump build 77 / 1.19.0 — messaging-rail robustness"
```

---

## Task 9: Deploy host + verify

**Files:** none (deploy only). **PAUSE for the operator's go-ahead before the production deploy.**

- [ ] **Step 1:** Merge the branch → `main`, push origin/main.
- [ ] **Step 2:** VDS deploy: `cd ~/nanoclaw && git pull --ff-only && pnpm install --frozen-lockfile && pnpm run build` then restart the service (XDG/DBUS env). Host change is `/ios/pending` only (no migration, no new deps).
- [ ] **Step 3:** Smoke: `curl`-equiv via the device, or confirm `/ios/pending` returns `ts`/`has_attachments` (host log / a one-off authed GET).
- [ ] **Step 4:** Operator installs **iOS build 77 / 1.19.0**. Verify on-device: background→foreground reconnects promptly without Settings→connect; a message delivered while backgrounded appears in the chat after the next pull/foreground.

---

## Self-review notes

- **Spec coverage:** A defect 1 (stranded .connecting) → T2; A defect 2 (disconnect re-arm) → T1; A defect 3 (isConnected) → T3+T4; foreground clean reconnect → T4; auth watchdog → T2. B host fields → T5; pull-insert → T6; drain render → T7; version → T8; deploy → T9. All spec sections mapped.
- **Deviation from spec (noted):** `insertInboundFromPull` takes NO `thread_id` — `insertInbound` writes no `conversation_id` (rows keyed by `id`, filtered by `agent_id`), so the pull insert mirrors it without a conversation. The spec's `thread_id` field on `/ios/pending` is therefore dropped; only `ts` + `has_attachments` are added.
- **Type consistency:** `onStateChange`/`setOnStateChange`/`isAuthed`/`resetReconnectBackoff`/`scheduleReconnect`/`armConnectWatchdog`/`connectWatchdogFired` (T2/T3) consistent. `insertInboundFromPull(id:seq:text:agentId:ts:)` identical in T6 (def) and T7 (call). `PendingMessage.ts/has_attachments` (T7) match the host fields (T5). `State` cases `.idle/.connecting/.authed/.reconnecting(delaySeconds:)` per the real enum.
- **Placeholders:** harness-specific names (`makeTransport`, `MockWebSocket`, `chatStore` bootstrap site, `countAllMessages`, `Schema.migrate`) are flagged for the implementer to confirm against the real test files/bootstrap — they are pre-existing utilities, not inventions.
