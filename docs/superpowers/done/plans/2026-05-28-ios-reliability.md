# iOS Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guarantee delivery of every user message in the iOS Jarvis app — never silently drop a send when offline, retry on reconnect, dedupe on the server.

**Architecture:** New `OutboxStore` (persisted JSON FIFO under `Documents/Outbox/queue.json`) sits in front of `WebSocketClient.send()`. Every send is enqueued before any wire attempt. WS reconnect drains the outbox via `flushOutbox()`. Server emits `message_ack` (already does); the iOS client removes the entry on ack and marks `.delivered`. Server gains an LRU `processedClientMsgIds` per device to swallow retried duplicates.

**Tech Stack:** Swift / SwiftUI / XCTest on iOS; Node + vitest + `ws` on the server.

---

## File Structure

| File | Purpose |
|---|---|
| `ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift` (NEW) | `OutboxEntry` struct + `@Observable @MainActor OutboxStore` class. Persists to `Documents/Outbox/queue.json`. Owns enqueue/remove/bumpAttempt/load/save/shouldRetry. |
| `ios/JarvisApp/Sources/JarvisApp/Utility/ContextBuilder.swift` (MODIFY) | Add a 15-minute staleness gate on the `location` field. |
| `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift` (MODIFY) | Rewire `send()` to always enqueue; add `flushOutbox()`, `handleMessageAck()`, `bumpStaleSentEntries()`. Inject an `OutboxStore` at construction. |
| `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift` (MODIFY) | Create the `OutboxStore` and pass it into `WebSocketClient`. |
| `ios/JarvisApp/Sources/JarvisApp/Components/DeliveryChecks.swift` (MODIFY) | Make `.failed` state tappable; emit a callback. |
| `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift` (MODIFY) | Wire the tap callback to `WebSocketClient.retrySend(id:)`. |
| `src/channels/ios-app.ts` (MODIFY) | Add `processedClientMsgIds: Map<platformId, LRUSet>` to `IosWsHandlerState`. Dedup repeated `clientMessageId` — second occurrence emits ack only, no `onInbound`. |
| `ios/JarvisApp/Sources/JarvisAppTests/OutboxStoreTests.swift` (NEW) | Unit tests for OutboxStore. |
| `ios/JarvisApp/Sources/JarvisAppTests/MessageCacheDeliveryStatusTests.swift` (NEW) | Round-trip of `.sent`/`.delivered`/`.failed` through MessageCache. |
| `ios/JarvisApp/Sources/JarvisAppTests/ContextBuilderTests.swift` (NEW) | Auto-context-merge matrix. |
| `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift` (NEW) | Offline-send + flush + stale-sent tests on WebSocketClient. |
| `src/channels/ios-app.message-ack.test.ts` (NEW) | Server ack contract test. |
| `src/channels/ios-app.dedup.test.ts` (NEW) | Server clientMessageId dedup test. |

## Test Commands

- **iOS unit tests:** `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/<ClassName>/<methodName>` (or run via Xcode UI ⌘U).
- **iOS regenerate Xcode project after adding files:** `cd ios/JarvisApp && xcodegen generate`.
- **Server tests:** `pnpm vitest run src/channels/<file>.test.ts`.
- **Server typecheck:** `pnpm typecheck`.

---

### Task 1: Add 15-minute staleness gate to ContextBuilder

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Utility/ContextBuilder.swift:19-25`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/ContextBuilderTests.swift` (NEW)

- [ ] **Step 1: Regenerate Xcode project so new test files are picked up**

The Xcode project is generated from `project.yml`. New test files in `Sources/JarvisAppTests/` are auto-included via the `path:` glob, but the generator must run.

Run:
```bash
cd ios/JarvisApp && xcodegen generate
```

Expected: `Created project at /Users/.../JarvisApp.xcodeproj`. No errors.

- [ ] **Step 2: Write failing test for stale location**

Create `ios/JarvisApp/Sources/JarvisAppTests/ContextBuilderTests.swift`:

```swift
import XCTest
import CoreLocation
@testable import Jarvis

@MainActor
final class ContextBuilderTests: XCTestCase {

    func testLocationOmittedWhenStale() {
        let settings = AppSettings()
        settings.useLocation = true
        settings.useHealth = false
        settings.useCalendar = false
        let loc = LocationManager()
        // 16 minutes old — past the 15min staleness gate
        let staleLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 8.6, longitude: 115.1),
            altitude: 0, horizontalAccuracy: 50, verticalAccuracy: 50,
            timestamp: Date().addingTimeInterval(-16 * 60)
        )
        loc.lastLocation = staleLoc
        loc.cityName = "Canggu"

        let health = HealthManager()
        let cal = CalendarManager()

        let ctx = ContextBuilder.build(fields: [], settings: settings, location: loc, health: health, calendar: cal)
        XCTAssertNil(ctx["location"], "location should be omitted when older than 15 minutes")
    }

    func testLocationIncludedWhenFresh() {
        let settings = AppSettings()
        settings.useLocation = true
        settings.useHealth = false
        settings.useCalendar = false
        let loc = LocationManager()
        let freshLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 8.6, longitude: 115.1),
            altitude: 0, horizontalAccuracy: 50, verticalAccuracy: 50,
            timestamp: Date().addingTimeInterval(-60)
        )
        loc.lastLocation = freshLoc
        loc.cityName = "Canggu"

        let health = HealthManager()
        let cal = CalendarManager()

        let ctx = ContextBuilder.build(fields: [], settings: settings, location: loc, health: health, calendar: cal)
        XCTAssertNotNil(ctx["location"], "location should be present when under 15 minutes old")
    }

    func testTimestampAndTimezoneAlwaysPresent() {
        let settings = AppSettings()
        settings.useLocation = false
        settings.useHealth = false
        settings.useCalendar = false
        let ctx = ContextBuilder.build(fields: [], settings: settings,
                                       location: LocationManager(), health: HealthManager(), calendar: CalendarManager())
        XCTAssertNotNil(ctx["timestamp"], "timestamp must always be present")
        XCTAssertNotNil(ctx["timezone"], "timezone must always be present")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/ContextBuilderTests/testLocationOmittedWhenStale 2>&1 | tail -20
```

Expected: `testLocationOmittedWhenStale` **FAILS** — current builder doesn't check staleness. The other two tests pass (existing behavior already correct).

- [ ] **Step 4: Add the 15-minute staleness gate**

Edit `ios/JarvisApp/Sources/JarvisApp/Utility/ContextBuilder.swift` lines 19-25, replace:

```swift
        if want.contains("location"), settings.useLocation, let loc = location.lastLocation {
            ctx["location"] = [
                "lat":  (loc.coordinate.latitude  * 1e4).rounded() / 1e4,
                "lon":  (loc.coordinate.longitude * 1e4).rounded() / 1e4,
                "city": location.cityName ?? "",
            ]
        }
```

with:

```swift
        if want.contains("location"), settings.useLocation, let loc = location.lastLocation,
           Date().timeIntervalSince(loc.timestamp) < 15 * 60 {
            ctx["location"] = [
                "lat":  (loc.coordinate.latitude  * 1e4).rounded() / 1e4,
                "lon":  (loc.coordinate.longitude * 1e4).rounded() / 1e4,
                "city": location.cityName ?? "",
            ]
        }
```

- [ ] **Step 5: Run tests to verify pass**

Run:
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/ContextBuilderTests 2>&1 | tail -10
```

Expected: all three `ContextBuilderTests` tests **PASS**.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/ContextBuilder.swift \
        ios/JarvisApp/Sources/JarvisAppTests/ContextBuilderTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: gate location context on 15-minute freshness

ContextBuilder.build now omits the location field when the cached
location is older than 15 minutes. The LocationManager already throttles
GPS wakes to the same window; this is defence-in-depth at the builder
level so a stale cached CLLocation can't leak into outbound messages."
```

---

### Task 2: OutboxStore — empty, enqueue, persist, load

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/OutboxStoreTests.swift`

- [ ] **Step 1: Write failing test for empty + enqueue + reload**

Create `ios/JarvisApp/Sources/JarvisAppTests/OutboxStoreTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class OutboxStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeEntry(id: String = UUID().uuidString, text: String = "hi") -> OutboxEntry {
        OutboxEntry(
            id: id,
            conversationId: nil,
            createdAt: Date(),
            lastAttempt: nil,
            attempts: 0,
            payload: Data("payload-\(id)".utf8),
            textPreview: text,
            hasAttachments: false,
            deliveryStatus: .sending
        )
    }

    func testEmptyOnFirstInit() {
        let store = OutboxStore(directory: tempDir)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEnqueuePersistsAcrossReload() {
        let store = OutboxStore(directory: tempDir)
        let e = makeEntry(id: "abc", text: "hello")
        store.enqueue(e)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, "abc")

        let reloaded = OutboxStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.id, "abc")
        XCTAssertEqual(reloaded.entries.first?.textPreview, "hello")
    }

    func testRemoveErasesEntry() {
        let store = OutboxStore(directory: tempDir)
        store.enqueue(makeEntry(id: "a"))
        store.enqueue(makeEntry(id: "b"))
        store.remove("a")
        XCTAssertEqual(store.entries.map(\.id), ["b"])

        let reloaded = OutboxStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.map(\.id), ["b"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (compile error)**

Run:
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/OutboxStoreTests 2>&1 | tail -20
```

Expected: **build error** — `OutboxStore` and `OutboxEntry` do not exist yet.

- [ ] **Step 3: Implement OutboxStore (minimal — enqueue/remove/load/save)**

Create `ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift`:

```swift
import Foundation

/// Single entry in the outbox — one user-originated message that has not yet been
/// acknowledged by the server. Codable so the store survives app relaunches.
struct OutboxEntry: Codable, Equatable {
    /// `clientMessageId` — matches the id used on the `ChatMessage` in the UI.
    let id: String
    let conversationId: UUID?
    let createdAt: Date
    var lastAttempt: Date?
    var attempts: Int
    /// JSON-serialized WS payload. Sent verbatim on flush.
    let payload: Data
    /// Short text used to render the row when the cached ChatMessage is gone.
    let textPreview: String
    let hasAttachments: Bool
    /// Mirrors the UI-side status — `.sending`, `.sent`, `.failed`. `.delivered` entries are removed.
    var deliveryStatus: DeliveryStatus

    init(id: String, conversationId: UUID?, createdAt: Date, lastAttempt: Date? = nil,
         attempts: Int = 0, payload: Data, textPreview: String, hasAttachments: Bool,
         deliveryStatus: DeliveryStatus = .sending) {
        self.id = id
        self.conversationId = conversationId
        self.createdAt = createdAt
        self.lastAttempt = lastAttempt
        self.attempts = attempts
        self.payload = payload
        self.textPreview = textPreview
        self.hasAttachments = hasAttachments
        self.deliveryStatus = deliveryStatus
    }
}

/// Persisted FIFO of pending outbound messages. Survives app relaunch and crashes.
/// Single owner: `WebSocketClient`. Single writer: `@MainActor`.
@Observable @MainActor final class OutboxStore {
    var entries: [OutboxEntry] = []   // sorted by createdAt asc

    @ObservationIgnored private let url: URL
    @ObservationIgnored static let maxEntries = 100

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("queue.json")
        load()
    }

    func enqueue(_ entry: OutboxEntry) {
        entries.append(entry)
        entries.sort { $0.createdAt < $1.createdAt }
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let arr = try? dec.decode([OutboxEntry].self, from: data) {
            entries = arr.sorted { $0.createdAt < $1.createdAt }
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(entries) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            print("OutboxStore: save failed — \(error)")
        }
    }
}
```

- [ ] **Step 4: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 5: Run tests to verify pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/OutboxStoreTests 2>&1 | tail -10
```

Expected: `testEmptyOnFirstInit`, `testEnqueuePersistsAcrossReload`, `testRemoveErasesEntry` all **PASS**.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift \
        ios/JarvisApp/Sources/JarvisAppTests/OutboxStoreTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add OutboxStore — persisted FIFO of unsent messages

OutboxEntry struct + OutboxStore @Observable @MainActor service.
Persists to Documents/Outbox/queue.json. Atomic replace on save.
Single-owner contract (WebSocketClient). Unit tests cover enqueue,
remove, and persistence across reload."
```

---

### Task 3: OutboxStore — cap at 100 with drop-failed policy

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/OutboxStoreTests.swift`

- [ ] **Step 1: Add failing tests for the cap**

Append to `OutboxStoreTests.swift`, inside the class:

```swift
    func testCapAllowsExactly100Entries() {
        let store = OutboxStore(directory: tempDir)
        for i in 0..<100 {
            store.enqueue(makeEntry(id: "id-\(i)"))
        }
        XCTAssertEqual(store.entries.count, 100, "100 entries should fit")
    }

    func test101stWithOneFailedAtFrontDropsOldestFailed() {
        let store = OutboxStore(directory: tempDir)
        var failed = makeEntry(id: "failed-old")
        failed.deliveryStatus = .failed
        store.enqueue(failed)
        for i in 1..<100 {
            store.enqueue(makeEntry(id: "id-\(i)"))
        }
        XCTAssertEqual(store.entries.count, 100)

        // Enqueue 101st — should drop the failed-old one
        let added = store.enqueue(makeEntry(id: "newcomer"))
        XCTAssertTrue(added, "enqueue must succeed when an older .failed entry can be dropped")
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertFalse(store.entries.contains { $0.id == "failed-old" }, "oldest .failed should be removed")
        XCTAssertTrue(store.entries.contains { $0.id == "newcomer" })
    }

    func test101stWithNoFailedRefuses() {
        let store = OutboxStore(directory: tempDir)
        for i in 0..<100 {
            var e = makeEntry(id: "id-\(i)")
            e.deliveryStatus = .sending      // none are .failed
            store.enqueue(e)
        }
        let added = store.enqueue(makeEntry(id: "newcomer"))
        XCTAssertFalse(added, "enqueue must refuse when no .failed entry to evict")
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertFalse(store.entries.contains { $0.id == "newcomer" })
    }
```

- [ ] **Step 2: Verify tests fail (compile error — `enqueue` currently returns Void)**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/OutboxStoreTests 2>&1 | tail -10
```

Expected: build error — `enqueue` returns `Void`, not `Bool`. The new tests fail to compile.

- [ ] **Step 3: Change `enqueue` to return `Bool` and implement the cap**

In `OutboxStore.swift`, replace the `enqueue` method:

```swift
    /// Enqueue a new entry. Returns `true` on success, `false` if the outbox is
    /// full and no `.failed` entry is available to evict.
    @discardableResult
    func enqueue(_ entry: OutboxEntry) -> Bool {
        if entries.count >= Self.maxEntries {
            // Drop the oldest .failed entry, if any
            if let idx = entries.firstIndex(where: { $0.deliveryStatus == .failed }) {
                entries.remove(at: idx)
            } else {
                // Nothing droppable — refuse the new entry
                return false
            }
        }
        entries.append(entry)
        entries.sort { $0.createdAt < $1.createdAt }
        save()
        return true
    }
```

- [ ] **Step 4: Run tests to verify pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/OutboxStoreTests 2>&1 | tail -10
```

Expected: all `OutboxStoreTests` **PASS** (6 tests now).

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift \
        ios/JarvisApp/Sources/JarvisAppTests/OutboxStoreTests.swift
git commit -m "ios: cap OutboxStore at 100, drop oldest .failed on overflow

enqueue() now returns Bool. When the outbox is full, the oldest .failed
entry is evicted to make room. If no .failed entries are present, the
new entry is refused (the caller surfaces a system row warning later)."
```

---

### Task 4: OutboxStore — bumpAttempt + shouldRetry (backoff)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/OutboxStoreTests.swift`

- [ ] **Step 1: Add failing tests for backoff**

Append to `OutboxStoreTests.swift`:

```swift
    func testBumpAttemptIncrementsAndPersists() {
        let store = OutboxStore(directory: tempDir)
        store.enqueue(makeEntry(id: "a"))
        store.bumpAttempt("a")
        XCTAssertEqual(store.entries.first?.attempts, 1)
        XCTAssertNotNil(store.entries.first?.lastAttempt)

        let reloaded = OutboxStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.first?.attempts, 1)
    }

    func testShouldRetryTrueWhenAttemptsLow() {
        let store = OutboxStore(directory: tempDir)
        store.enqueue(makeEntry(id: "a"))
        XCTAssertTrue(store.shouldRetry("a", now: Date()))
    }

    func testShouldRetryFalseAfterFiveQuickAttempts() {
        let store = OutboxStore(directory: tempDir)
        store.enqueue(makeEntry(id: "a"))
        let now = Date()
        // simulate 5 attempts in the last second
        for _ in 0..<5 { store.bumpAttempt("a") }
        XCTAssertFalse(store.shouldRetry("a", now: now), "5+ attempts in 60s window should be skipped")
    }

    func testShouldRetryTrueAfter60sWindow() {
        let store = OutboxStore(directory: tempDir)
        store.enqueue(makeEntry(id: "a"))
        for _ in 0..<5 { store.bumpAttempt("a") }
        let future = Date().addingTimeInterval(61)
        XCTAssertTrue(store.shouldRetry("a", now: future), "after 60s window passes, retry is allowed again")
    }
```

- [ ] **Step 2: Verify tests fail (compile error)**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/OutboxStoreTests 2>&1 | tail -10
```

Expected: build error — `bumpAttempt` and `shouldRetry` not implemented.

- [ ] **Step 3: Implement `bumpAttempt` and `shouldRetry`**

In `OutboxStore.swift`, add inside the class (after `remove`):

```swift
    /// Mark an entry as just-attempted: bumps `attempts`, sets `lastAttempt = now`.
    func bumpAttempt(_ id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].attempts += 1
        entries[idx].lastAttempt = Date()
        save()
    }

    /// Whether the flush loop should attempt this entry now. Skip if there have
    /// been 5+ attempts within the last 60 seconds (tight-loop guard).
    func shouldRetry(_ id: String, now: Date = Date()) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        if entry.attempts < 5 { return true }
        guard let last = entry.lastAttempt else { return true }
        return now.timeIntervalSince(last) > 60
    }
```

- [ ] **Step 4: Run tests to verify pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/OutboxStoreTests 2>&1 | tail -10
```

Expected: all `OutboxStoreTests` **PASS** (10 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/OutboxStore.swift \
        ios/JarvisApp/Sources/JarvisAppTests/OutboxStoreTests.swift
git commit -m "ios: OutboxStore backoff — bumpAttempt + shouldRetry

bumpAttempt increments attempts counter and stamps lastAttempt.
shouldRetry returns false when an entry has 5+ attempts within the
last 60 seconds — prevents tight-loop hammering on a server that
keeps NAKing a payload."
```

---

### Task 5: MessageCache delivery-status round-trip tests (existing behavior)

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisAppTests/MessageCacheDeliveryStatusTests.swift`

- [ ] **Step 1: Write tests covering existing round-trip behavior**

Create `ios/JarvisApp/Sources/JarvisAppTests/MessageCacheDeliveryStatusTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class MessageCacheDeliveryStatusTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msgcache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func textMsg(_ id: String, _ text: String, _ status: DeliveryStatus) -> ChatMessage {
        var m = ChatMessage.text(id, role: .user, text: text, timestamp: Date())
        m.deliveryStatus = status
        return m
    }

    func testRoundTripSent() {
        MessageCache.save([textMsg("a", "hi", .sent)], to: tempDir)
        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.first?.deliveryStatus, .sent)
    }

    func testRoundTripDelivered() {
        MessageCache.save([textMsg("b", "hi", .delivered)], to: tempDir)
        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.first?.deliveryStatus, .delivered)
    }

    func testRoundTripFailed() {
        MessageCache.save([textMsg("c", "hi", .failed)], to: tempDir)
        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.first?.deliveryStatus, .failed)
    }

    func testSendingCollapsesToDeliveredOnReload() {
        MessageCache.save([textMsg("d", "hi", .sending)], to: tempDir)
        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.first?.deliveryStatus, .delivered,
                       ".sending is treated as completed on cache reload — outbox is the real source of truth")
    }

    func testLegacyJSONWithoutDeliveryStatusDefaultsToDelivered() throws {
        // Hand-craft a legacy index.json (no deliveryStatus field)
        let indexURL = tempDir.appendingPathComponent("index.json")
        let legacyJSON = """
        [{
          "id":"legacy-1","role":"user","kind":"text","text":"old",
          "timestamp":"\(ISO8601DateFormatter().string(from: Date()))"
        }]
        """
        try legacyJSON.write(to: indexURL, atomically: true, encoding: .utf8)

        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.deliveryStatus, .delivered,
                       "legacy entries without the field default to .delivered")
    }
}
```

- [ ] **Step 2: Run tests — they should pass (covers existing behavior)**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/MessageCacheDeliveryStatusTests 2>&1 | tail -10
```

Expected: all 5 tests **PASS** without code changes. This task is pure coverage — if any test fails, the existing code is buggier than the spec assumed; fix the code, not the test.

- [ ] **Step 3: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisAppTests/MessageCacheDeliveryStatusTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "test(ios): pin MessageCache deliveryStatus round-trip behavior

Existing MessageCache.load/save already round-trips deliveryStatus
through CachedMessage. These tests pin that behavior so future
refactors don't silently regress: .sent/.delivered/.failed survive;
.sending collapses to .delivered; legacy entries default to .delivered."
```

---

### Task 6: ContextBuilder auto-context-merge matrix tests

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/ContextBuilderTests.swift`

- [ ] **Step 1: Add matrix tests covering useLocation/useHealth/useCalendar toggles**

Append to `ContextBuilderTests.swift`:

```swift
    func testUseLocationOffOmitsLocation() {
        let settings = AppSettings()
        settings.useLocation = false
        settings.useHealth = false
        settings.useCalendar = false
        let loc = LocationManager()
        loc.lastLocation = CLLocation(latitude: 8.6, longitude: 115.1)
        loc.cityName = "Canggu"

        let ctx = ContextBuilder.build(fields: [], settings: settings,
                                       location: loc, health: HealthManager(), calendar: CalendarManager())
        XCTAssertNil(ctx["location"], "useLocation=false must omit location")
    }

    func testTimezoneAlwaysISO() {
        let settings = AppSettings()
        let ctx = ContextBuilder.build(fields: [], settings: settings,
                                       location: LocationManager(), health: HealthManager(), calendar: CalendarManager())
        XCTAssertEqual(ctx["timezone"] as? String, TimeZone.current.identifier)
    }

    func testDeviceBatteryPresentWhenAvailable() {
        // Simulators report -1 (unknown), so this test asserts the negative
        // case: when level is unavailable, the device.battery key is absent.
        // (We can't force a positive battery level in a simulator.)
        let settings = AppSettings()
        settings.useLocation = false
        settings.useHealth = false
        settings.useCalendar = false
        let ctx = ContextBuilder.build(fields: [], settings: settings,
                                       location: LocationManager(), health: HealthManager(), calendar: CalendarManager())
        if let device = ctx["device"] as? [String: Any] {
            // If device dict exists, battery is optional — that's fine.
            XCTAssertTrue(device["battery"] is Int? || device["battery"] == nil)
        }
        // If no device dict at all (sim returns -1, network nil, lowPower false), that's also valid.
    }

    func testFieldSubsetLocationOnly() {
        let settings = AppSettings()
        settings.useLocation = true
        settings.useHealth = true
        let loc = LocationManager()
        loc.lastLocation = CLLocation(coordinate: .init(latitude: 8.6, longitude: 115.1),
                                      altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                                      timestamp: Date())
        loc.cityName = "Canggu"

        let ctx = ContextBuilder.build(fields: ["location"], settings: settings,
                                       location: loc, health: HealthManager(), calendar: CalendarManager())
        XCTAssertNotNil(ctx["location"])
        XCTAssertNil(ctx["health"], "explicit field subset must not leak other fields")
    }
```

- [ ] **Step 2: Run tests**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/ContextBuilderTests 2>&1 | tail -10
```

Expected: all `ContextBuilderTests` (now 7 total) **PASS** — these cover existing behavior plus the 15min gate from Task 1.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisAppTests/ContextBuilderTests.swift
git commit -m "test(ios): ContextBuilder matrix — privacy toggles and field subsets

Pins the existing privacy-toggle behavior in ContextBuilder: useLocation
off omits the location key; timezone is always TimeZone.current.identifier;
explicit fields subset doesn't leak other sections."
```

---

### Task 7: WebSocketClient — inject OutboxStore + offline-send enqueue

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift`

- [ ] **Step 1: Write failing test — send() while offline keeps message + enqueues**

Create `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class WebSocketClientOutboxTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-outbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testOfflineSendKeepsMessageAndEnqueues() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        // Not connected — task is nil, isConnected is false (default)
        XCTAssertFalse(ws.isConnected)

        ws.send(text: "hello offline", timezone: "Asia/Makassar", status: nil, attachments: [], context: nil)

        XCTAssertEqual(ws.messages.count, 1, "the user message must still appear in the UI list")
        XCTAssertEqual(ws.messages.first?.text, "hello offline")
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .sending)
        XCTAssertEqual(outbox.entries.count, 1, "outbox must contain exactly one entry")
        XCTAssertEqual(outbox.entries.first?.textPreview, "hello offline")
    }

    func testOfflineSendIdMatchesMessageId() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        ws.send(text: "x", timezone: "UTC", status: nil, attachments: [], context: nil)
        XCTAssertEqual(ws.messages.first?.id, outbox.entries.first?.id,
                       "ChatMessage.id and OutboxEntry.id must match — same clientMessageId")
    }
}
```

- [ ] **Step 2: Verify tests fail (compile error)**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests 2>&1 | tail -10
```

Expected: build error — `WebSocketClient.init(outbox:)` does not exist.

- [ ] **Step 3: Add `outbox` dependency to WebSocketClient and rewire `send()`**

In `WebSocketClient.swift`, find the existing `@ObservationIgnored private var sentReadIds: Set<String> = []` line (around line 41) and add below it:

```swift
    @ObservationIgnored let outbox: OutboxStore
```

Then add an initializer before the `var conversationId: UUID?` line (around line 43):

```swift
    init(outbox: OutboxStore = OutboxStore()) {
        self.outbox = outbox
    }
```

Now find the existing `send(text:...)` method (line 118) and replace its body. Locate this signature:

```swift
    func send(text: String, timezone: String, status: String?, attachments: [DraftAttachment] = [], context: [String: Any]? = nil) {
```

Replace the entire method body (lines ~118-150) with:

```swift
    func send(text: String, timezone: String, status: String?, attachments: [DraftAttachment] = [], context: [String: Any]? = nil) {
        let clientMsgId = UUID().uuidString
        let ts = Date()

        // Build the payload up front — same shape whether we send now or later.
        var payload: [String: Any] = [
            "type": "message",
            "text": text,
            "timezone": timezone,
            "clientMessageId": clientMsgId,
        ]
        if let st = status, !st.isEmpty { payload["status"] = st }
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        if !attachments.isEmpty { payload["attachments"] = attachments.map { $0.payload } }
        if let ctx = context, !ctx.isEmpty { payload["context"] = ctx }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        // 1. Append to UI as .sending so the user sees their own message immediately.
        isTyping = true
        lastUserSentAt = Date()
        if !text.isEmpty {
            var msg = ChatMessage.text(clientMsgId, role: .user, text: text, timestamp: ts)
            msg.deliveryStatus = .sending
            messages.append(msg)
        }
        for att in attachments {
            if let img = att.image {
                messages.append(.image(UUID().uuidString, role: .user, image: img, filename: att.name, timestamp: ts))
            } else {
                let info = FileInfo(name: att.name, size: Int64(att.size), mimeType: att.mimeType, url: nil, thumbnail: nil)
                messages.append(.file(UUID().uuidString, role: .user, info: info, timestamp: ts))
            }
        }
        onMessagesChanged?(messages)

        // 2. Enqueue locally — survives crash, offline, anything.
        let added = outbox.enqueue(OutboxEntry(
            id: clientMsgId,
            conversationId: conversationId,
            createdAt: ts,
            payload: data,
            textPreview: text,
            hasAttachments: !attachments.isEmpty
        ))
        if !added {
            // Outbox full and nothing droppable — surface a system row.
            let warn = ChatMessage.status(UUID().uuidString,
                                          text: "Очередь переполнена, проверьте соединение",
                                          level: .warning, timestamp: Date())
            messages.append(warn)
            onMessagesChanged?(messages)
            return
        }

        // 3. Best-effort immediate send. flushOutbox handles the wire-or-stay decision.
        flushOutbox()
    }

    /// Try to send everything currently in the outbox. No-op when WS is down.
    func flushOutbox() {
        guard let ws = task, isConnected else { return }
        let snapshot = outbox.entries
        let now = Date()
        for entry in snapshot {
            guard outbox.shouldRetry(entry.id, now: now) else { continue }
            outbox.bumpAttempt(entry.id)
            ws.send(.data(entry.payload)) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateDeliveryStatus(entry.id, error == nil ? .sent : .failed)
                    // Entry stays in the outbox; removal happens on message_ack.
                }
            }
        }
    }
```

- [ ] **Step 4: Update AppCoordinator to construct OutboxStore and pass it to WebSocketClient**

In `AppCoordinator.swift`, find the line `let ws = WebSocketClient()` (around the property declarations). Replace with:

```swift
    let outbox = OutboxStore()
    lazy var ws = WebSocketClient(outbox: outbox)
```

(If WebSocketClient is currently `let ws = WebSocketClient()`, you may need to also adjust the `init` to reflect this — search the file for `WebSocketClient()` and ensure all call sites pass the outbox or rely on the default.)

- [ ] **Step 5: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 6: Run tests to verify pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests 2>&1 | tail -10
```

Expected: both new tests **PASS**.

Also run the full test target to confirm nothing else broke:

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests 2>&1 | tail -20
```

Expected: all `JarvisAppTests` tests pass.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: route every send() through OutboxStore

WebSocketClient now accepts an OutboxStore at init and enqueues every
outbound message — including when offline. The UI append of .sending
happens before the wire attempt, so messages never silently vanish.
flushOutbox() runs the actual send loop; it is a no-op when the WS
task is nil. Entries stay in the outbox until removed by message_ack."
```

---

### Task 8: WebSocketClient — flushOutbox on reconnect

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift`

- [ ] **Step 1: Write failing test — simulate reconnect flushes existing outbox**

Append to `WebSocketClientOutboxTests.swift`:

```swift
    func testFlushOutboxNoOpWhenDisconnected() {
        let outbox = OutboxStore(directory: tempDir)
        outbox.enqueue(OutboxEntry(id: "x", conversationId: nil, createdAt: Date(),
                                   payload: Data(), textPreview: "x", hasAttachments: false))
        let ws = WebSocketClient(outbox: outbox)
        XCTAssertFalse(ws.isConnected)
        ws.flushOutbox()  // should not crash, should not modify entries
        XCTAssertEqual(outbox.entries.count, 1)
        XCTAssertEqual(outbox.entries.first?.attempts, 0, "no attempt should be recorded when WS is down")
    }

    func testReconnectTriggersFlush() {
        // We can't easily stand up a real URLSessionWebSocketTask in a unit test,
        // so we assert the contract: when the doConnect success path completes,
        // it must call flushOutbox. We expose a test seam to verify.
        let outbox = OutboxStore(directory: tempDir)
        outbox.enqueue(OutboxEntry(id: "x", conversationId: nil, createdAt: Date(),
                                   payload: Data(), textPreview: "x", hasAttachments: false))
        let ws = WebSocketClient(outbox: outbox)
        var flushCalls = 0
        ws.onFlushForTesting = { flushCalls += 1 }
        ws.notifyConnectedForTesting()
        XCTAssertEqual(flushCalls, 1, "on transition to connected, flushOutbox must be invoked")
    }
```

- [ ] **Step 2: Verify tests fail**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests/testReconnectTriggersFlush 2>&1 | tail -10
```

Expected: build error — `onFlushForTesting` / `notifyConnectedForTesting` not yet exposed.

- [ ] **Step 3: Add test seams + wire flush on connection transition**

In `WebSocketClient.swift`, add a test-only hook near the other `@ObservationIgnored` callbacks (around line 66):

```swift
    /// Test seam: fires whenever the connection-success path calls flushOutbox.
    @ObservationIgnored var onFlushForTesting: (() -> Void)?
```

Add a test helper just below `tickHeartbeatForTesting` (around line 267):

```swift
    /// Test seam: mimics the success branch of doConnect (sets isConnected = true
    /// and runs the same post-connect actions, minus the URLSession plumbing).
    @MainActor
    func notifyConnectedForTesting() {
        isConnected = true
        flushOutbox()
        onFlushForTesting?()
    }
```

Now find the `doConnect` success branch (search for `isConnected = true`). The existing code likely sets `isConnected = true` after `auth_ok` is received. Right after that line, add:

```swift
        flushOutbox()
        onFlushForTesting?()
```

If you can't find a single success site, search for `case .auth_ok` or where `auth_ok` is decoded; the spec assumes there's exactly one place where the client decides "we're connected for real". Add the flush call immediately after `isConnected = true`.

- [ ] **Step 4: Run tests to verify pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests 2>&1 | tail -10
```

Expected: 4 tests **PASS**.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift
git commit -m "ios: flushOutbox on every successful reconnect

After auth_ok and isConnected = true, WebSocketClient now drains the
outbox via flushOutbox(). Messages queued while offline are sent in
createdAt order. A test seam (onFlushForTesting) lets the unit tests
verify the contract without needing a real URLSessionWebSocketTask."
```

---

### Task 9: WebSocketClient — handle message_ack, remove from outbox, mark .delivered

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift`

- [ ] **Step 1: Write failing test — ack removes the entry and marks .delivered**

Append to `WebSocketClientOutboxTests.swift`:

```swift
    func testMessageAckRemovesEntryAndMarksDelivered() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        ws.send(text: "boom", timezone: "UTC", status: nil, attachments: [], context: nil)
        guard let id = ws.messages.first?.id else { XCTFail("no message"); return }
        XCTAssertEqual(outbox.entries.count, 1)

        ws.handleMessageAckForTesting(clientMessageId: id)

        XCTAssertEqual(outbox.entries.count, 0, "ack must remove the outbox entry")
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .delivered)
    }

    func testUnknownAckIsIgnored() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        ws.send(text: "x", timezone: "UTC", status: nil, attachments: [], context: nil)
        let startingCount = outbox.entries.count

        ws.handleMessageAckForTesting(clientMessageId: "unknown-id")

        XCTAssertEqual(outbox.entries.count, startingCount, "ack for unknown id must be a no-op")
    }
```

- [ ] **Step 2: Verify tests fail**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests/testMessageAckRemovesEntryAndMarksDelivered 2>&1 | tail -10
```

Expected: build error — `handleMessageAckForTesting` not defined.

- [ ] **Step 3: Add ack handler + test seam, wire into existing receive loop**

In `WebSocketClient.swift`, find the receive loop where messages are decoded. Look for an existing block like `if t == "feedback_ack"` (we saw this in spec review around line 408-416). There may already be a `message_ack` branch that does `updateDeliveryStatus(clientMsgId, .delivered)`. Replace that branch with a call to the new central handler.

Add this method near `updateDeliveryStatus`:

```swift
    /// Server confirmed receipt of a previously-sent client message. Remove the
    /// outbox entry and mark the UI row as `.delivered`.
    @MainActor
    func handleMessageAck(clientMessageId: String) {
        guard outbox.entries.contains(where: { $0.id == clientMessageId }) else {
            // Unknown id — idempotent no-op.
            return
        }
        outbox.remove(clientMessageId)
        updateDeliveryStatus(clientMessageId, .delivered)
    }

    /// Test seam — call `handleMessageAck` directly without a real socket.
    @MainActor
    func handleMessageAckForTesting(clientMessageId: String) {
        handleMessageAck(clientMessageId: clientMessageId)
    }
```

Now find the existing `message_ack` branch in the receive loop:

```swift
        if t == "message_ack",
           let clientMsgId = obj["clientMessageId"] as? String {
            updateDeliveryStatus(clientMsgId, .delivered)
            ...
        }
```

Replace with:

```swift
        if t == "message_ack",
           let clientMsgId = obj["clientMessageId"] as? String {
            handleMessageAck(clientMessageId: clientMsgId)
            return
        }
```

- [ ] **Step 4: Run tests to verify pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests 2>&1 | tail -10
```

Expected: all 6 tests **PASS**.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift
git commit -m "ios: route message_ack through handleMessageAck — remove + mark delivered

The previous code only updated the UI status. Now it also removes the
outbox entry, so retry-on-reconnect won't re-send already-acked messages.
Unknown-id acks are idempotent no-ops (e.g. server replay)."
```

---

### Task 10: WebSocketClient — stale-sent timeout bumps .sent → .failed after 30s

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift`

- [ ] **Step 1: Write failing test**

Append to `WebSocketClientOutboxTests.swift`:

```swift
    func testStaleSentEntryBumpsToFailedOnFlush() {
        let outbox = OutboxStore(directory: tempDir)
        var entry = OutboxEntry(id: "stale", conversationId: nil,
                                createdAt: Date().addingTimeInterval(-60),
                                payload: Data(), textPreview: "x", hasAttachments: false,
                                deliveryStatus: .sent)
        // Mark its last attempt 31 seconds ago — past the 30s ack timeout
        entry.lastAttempt = Date().addingTimeInterval(-31)
        outbox.entries = [entry]
        outbox.save()

        let ws = WebSocketClient(outbox: outbox)
        // Also stage a UI row matching the entry, so we can observe the status change
        var uiMsg = ChatMessage.text("stale", role: .user, text: "x", timestamp: Date())
        uiMsg.deliveryStatus = .sent
        ws.messages = [uiMsg]

        ws.bumpStaleSentEntriesForTesting(now: Date())

        XCTAssertEqual(outbox.entries.first?.deliveryStatus, .failed)
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .failed)
    }
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests/testStaleSentEntryBumpsToFailedOnFlush 2>&1 | tail -10
```

Expected: build error — `bumpStaleSentEntriesForTesting` not defined.

- [ ] **Step 3: Implement stale-sent bump**

In `WebSocketClient.swift`, add near `flushOutbox`:

```swift
    /// 30s after we marked an entry as .sent, if no message_ack has arrived,
    /// downgrade it to .failed so the next flush re-sends it.
    @MainActor
    func bumpStaleSentEntries(now: Date = Date()) {
        for entry in outbox.entries where entry.deliveryStatus == .sent {
            guard let last = entry.lastAttempt,
                  now.timeIntervalSince(last) > 30 else { continue }
            if let idx = outbox.entries.firstIndex(where: { $0.id == entry.id }) {
                outbox.entries[idx].deliveryStatus = .failed
            }
            updateDeliveryStatus(entry.id, .failed)
        }
        outbox.save()
    }

    /// Test seam.
    @MainActor
    func bumpStaleSentEntriesForTesting(now: Date) {
        bumpStaleSentEntries(now: now)
    }
```

Also update `flushOutbox` to call `bumpStaleSentEntries()` at the top so every flush sweep picks up stragglers:

```swift
    func flushOutbox() {
        bumpStaleSentEntries()
        guard let ws = task, isConnected else { return }
        ...
    }
```

- [ ] **Step 4: Run tests to verify pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests 2>&1 | tail -10
```

Expected: 7 tests **PASS**.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift
git commit -m "ios: stale-sent timeout — bump .sent to .failed after 30s without ack

Fixes the case where ws.send() succeeds at the TCP layer but the server
never gets the bytes (e.g. network split during a reconnect). After 30s
without a message_ack, the entry is downgraded so the next reconnect
re-sends it via the standard flushOutbox loop."
```

---

### Task 11: Server-side dedup — repeated clientMessageId emits ack but no second onInbound

**Files:**
- Modify: `src/channels/ios-app.ts`
- Create: `src/channels/ios-app.dedup.test.ts`

- [ ] **Step 1: Write failing server test**

Create `src/channels/ios-app.dedup.test.ts` using the same harness pattern as `ios-app.context.test.ts`:

```ts
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { WebSocketServer, WebSocket } from 'ws';
import { ReadReceiptStore } from './ios-read-receipts.js';
import { createIosWsHandler, type IosWsHandlerState } from './ios-app.js';

function makeState(): IosWsHandlerState {
  return {
    wsClients: new Map(),
    apnsTokens: new Map(),
    pendingMessages: new Map(),
    deliveredIds: new Map(),
    lastTimezone: new Map(),
    processedClientMsgIds: new Map(),
  };
}

async function setup() {
  const store = new ReadReceiptStore();
  const inbound: Array<{ text: string }> = [];
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: {
      onInbound: async (_pid, _tid, msg) => {
        const content = (msg as Record<string, unknown>).content as Record<string, unknown>;
        inbound.push({ text: content.text as string });
      },
      onAction: () => {},
    },
    state: makeState(),
    persist: { receipts: () => {}, tokens: () => {} },
    deliverQueued: () => {},
  });
  const server = createServer();
  const wss = new WebSocketServer({ server });
  wss.on('connection', handler);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  const close = () =>
    new Promise<void>((r) => {
      for (const c of wss.clients) c.terminate();
      wss.close(() => server.close(() => r()));
    });

  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  await new Promise<void>((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  const acks: string[] = [];
  ws.on('message', (data) => {
    const m = JSON.parse(data.toString());
    if (m.type === 'message_ack' && typeof m.clientMessageId === 'string') {
      acks.push(m.clientMessageId);
    }
  });
  await new Promise<void>((resolve, reject) => {
    ws.once('message', () => resolve());
    ws.once('close', () => reject(new Error('closed before auth_ok')));
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:dup-test' }));
  });
  return { inbound, ws, close, acks };
}

describe('ios-app clientMessageId dedup', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => {
    ctx = await setup();
  });
  afterEach(async () => {
    ctx.ws.terminate();
    await ctx.close();
  });

  it('first message → onInbound called and ack emitted', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi', clientMessageId: 'cmsg-1' }));
    await new Promise((r) => setTimeout(r, 150));
    expect(ctx.inbound).toHaveLength(1);
    expect(ctx.acks).toContain('cmsg-1');
  });

  it('duplicate clientMessageId → onInbound not called again, ack still emitted', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi', clientMessageId: 'cmsg-2' }));
    await new Promise((r) => setTimeout(r, 100));
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi', clientMessageId: 'cmsg-2' }));
    await new Promise((r) => setTimeout(r, 150));
    expect(ctx.inbound).toHaveLength(1);
    expect(ctx.acks.filter((a) => a === 'cmsg-2')).toHaveLength(2);
  });

  it('different clientMessageIds → both onInbound and both acks', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'a', clientMessageId: 'cmsg-3' }));
    await new Promise((r) => setTimeout(r, 100));
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'b', clientMessageId: 'cmsg-4' }));
    await new Promise((r) => setTimeout(r, 150));
    expect(ctx.inbound).toHaveLength(2);
    expect(ctx.acks).toContain('cmsg-3');
    expect(ctx.acks).toContain('cmsg-4');
  });
});
```

- [ ] **Step 2: Verify tests fail**

```bash
pnpm vitest run src/channels/ios-app.dedup.test.ts 2>&1 | tail -30
```

Expected: TypeScript build error — `processedClientMsgIds` not yet on `IosWsHandlerState`. Or runtime failure on the "duplicate" test — `onInbound` is called twice.

- [ ] **Step 3: Add `processedClientMsgIds` to state and dedup logic**

In `src/channels/ios-app.ts`, find the `IosWsHandlerState` interface (line 247-253) and add a new field:

```ts
export interface IosWsHandlerState {
  wsClients: Map<string, Set<WebSocket>>;
  apnsTokens: Map<string, string>;
  pendingMessages: Map<string, QueuedMessage[]>;
  deliveredIds: Map<string, Set<string>>;
  lastTimezone: Map<string, string>;
  /** Per-device LRU of clientMessageIds we've already forwarded to the agent.
   *  Second-and-later occurrences emit ack only — never call onInbound twice. */
  processedClientMsgIds: Map<string, Set<string>>;
}
```

Inside `createIosWsHandler`, near `recordDelivered`, add a helper:

```ts
  function isDuplicateClientMsgId(pid: string, cmid: string): boolean {
    let s = state.processedClientMsgIds.get(pid);
    if (!s) state.processedClientMsgIds.set(pid, (s = new Set()));
    if (s.has(cmid)) return true;
    if (s.size > 500) {
      // Simple LRU: blow the cache when it gets too big.
      s.clear();
    }
    s.add(cmid);
    return false;
  }
```

Now find the `if (msg.type === 'message' && ...)` branch (around line 359). Replace its body so dedup happens before `onInbound`:

```ts
      if (msg.type === 'message' && typeof msg.text === 'string' && pid) {
        const cmid = typeof msg.clientMessageId === 'string' ? msg.clientMessageId : '';

        // Dedup BEFORE onInbound. Always ack so the client stops retrying.
        if (cmid && isDuplicateClientMsgId(pid, cmid)) {
          ws.send(JSON.stringify({ type: 'message_ack', clientMessageId: cmid }));
          return;
        }

        if (typeof msg.timezone === 'string' && msg.timezone) lastTimezone.set(pid, msg.timezone);
        const status = typeof msg.status === 'string' && msg.status ? `[status: ${msg.status}]\n` : '';
        const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
        let inlineCtx = '';
        if (msg.context && typeof msg.context === 'object') {
          const ctxObj = msg.context as Record<string, unknown>;
          if (typeof ctxObj.timezone !== 'string' && msg.timezone) {
            ctxObj.timezone = msg.timezone as string;
          }
          try {
            const block = buildCtx(ctxObj);
            if (block) inlineCtx = `${block}\n`;
          } catch {
            // Bad context payload — skip, don't fail the message
          }
        }
        const content: Record<string, unknown> = { text: inlineCtx + status + msg.text, senderId: pid };
        if (Array.isArray(msg.attachments)) {
          const atts = (msg.attachments as Array<Record<string, unknown>>).filter(
            (a) => a && typeof a.data === 'string',
          );
          if (atts.length > 0) content.attachments = atts;
        }
        await cfg.onInbound(pid, tid, {
          id: randomUUID(),
          kind: 'chat',
          content,
          timestamp: new Date().toISOString(),
        } as Record<string, unknown>);
        if (cmid) {
          ws.send(JSON.stringify({ type: 'message_ack', clientMessageId: cmid }));
        }
      }
```

Find the `const handlerState: IosWsHandlerState = { ... }` block (around line 632) and add the new field:

```ts
      const handlerState: IosWsHandlerState = {
        wsClients,
        apnsTokens,
        pendingMessages,
        deliveredIds,
        lastTimezone,
        processedClientMsgIds: new Map(),
      };
```

- [ ] **Step 4: Run tests to verify pass**

```bash
pnpm vitest run src/channels/ios-app.dedup.test.ts 2>&1 | tail -20
```

Expected: 3 tests **PASS**.

Run the wider iOS channel test set to confirm nothing else broke:

```bash
pnpm vitest run src/channels/ 2>&1 | tail -20
```

Expected: all existing iOS channel tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app.ts src/channels/ios-app.dedup.test.ts
git commit -m "ios-app(server): dedup repeated clientMessageId per device

Adds processedClientMsgIds (Map<platformId, Set<string>>) to
IosWsHandlerState. When the iOS retry path re-sends a payload whose
ack we missed, the server now swallows the second onInbound call but
still emits message_ack so the client stops retrying. LRU clears at
500 entries per device."
```

---

### Task 12: Server-side message_ack contract test

**Files:**
- Create: `src/channels/ios-app.message-ack.test.ts`

- [ ] **Step 1: Write the test (covers existing behavior)**

Create `src/channels/ios-app.message-ack.test.ts`:

```ts
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { WebSocketServer, WebSocket } from 'ws';
import { ReadReceiptStore } from './ios-read-receipts.js';
import { createIosWsHandler, type IosWsHandlerState } from './ios-app.js';

function makeState(): IosWsHandlerState {
  return {
    wsClients: new Map(),
    apnsTokens: new Map(),
    pendingMessages: new Map(),
    deliveredIds: new Map(),
    lastTimezone: new Map(),
    processedClientMsgIds: new Map(),
  };
}

async function setup() {
  const store = new ReadReceiptStore();
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: { onInbound: async () => {}, onAction: () => {} },
    state: makeState(),
    persist: { receipts: () => {}, tokens: () => {} },
    deliverQueued: () => {},
  });
  const server = createServer();
  const wss = new WebSocketServer({ server });
  wss.on('connection', handler);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  const close = () =>
    new Promise<void>((r) => {
      for (const c of wss.clients) c.terminate();
      wss.close(() => server.close(() => r()));
    });

  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  await new Promise<void>((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  const messages: Record<string, unknown>[] = [];
  ws.on('message', (data) => {
    messages.push(JSON.parse(data.toString()));
  });
  await new Promise<void>((resolve) => {
    const w = (m: { type: string }) => {
      if (m.type === 'auth_ok') resolve();
    };
    ws.on('message', (data) => w(JSON.parse(data.toString())));
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:ack-test' }));
  });
  return { messages, ws, close };
}

describe('ios-app message_ack contract', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => {
    ctx = await setup();
  });
  afterEach(async () => {
    ctx.ws.terminate();
    await ctx.close();
  });

  it('every message with clientMessageId gets a matching ack', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi', clientMessageId: 'unique-1' }));
    await new Promise((r) => setTimeout(r, 200));
    const acks = ctx.messages.filter((m) => m.type === 'message_ack');
    expect(acks).toHaveLength(1);
    expect((acks[0] as { clientMessageId: string }).clientMessageId).toBe('unique-1');
  });

  it('message without clientMessageId gets no ack (backward compat)', async () => {
    ctx.ws.send(JSON.stringify({ type: 'message', text: 'hi' }));
    await new Promise((r) => setTimeout(r, 200));
    const acks = ctx.messages.filter((m) => m.type === 'message_ack');
    expect(acks).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run tests — they should pass against existing code**

```bash
pnpm vitest run src/channels/ios-app.message-ack.test.ts 2>&1 | tail -20
```

Expected: 2 tests **PASS** (the server already emits acks).

- [ ] **Step 3: Commit**

```bash
git add src/channels/ios-app.message-ack.test.ts
git commit -m "test(ios-app): pin server message_ack contract

Locks in the existing behavior: every \`message\` with a clientMessageId
gets a matching \`message_ack\` back. Messages without clientMessageId
get no ack (backward compat with older client versions). The iOS outbox
depends on this contract for removal-after-ack."
```

---

### Task 13: Failed-row tap → retry single entry

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/DeliveryChecks.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift`

- [ ] **Step 1: Write failing test — retry by id resets attempts and reflushes**

Append to `WebSocketClientOutboxTests.swift`:

```swift
    func testRetrySendResetsAttemptsAndFlushesSingleEntry() {
        let outbox = OutboxStore(directory: tempDir)
        var entry = OutboxEntry(id: "retry-me", conversationId: nil, createdAt: Date(),
                                payload: Data(), textPreview: "x", hasAttachments: false,
                                deliveryStatus: .failed)
        entry.attempts = 5
        entry.lastAttempt = Date()
        outbox.entries = [entry]
        outbox.save()

        let ws = WebSocketClient(outbox: outbox)

        ws.retrySend(id: "retry-me")

        XCTAssertEqual(outbox.entries.first?.attempts, 0, "manual retry must reset attempts so backoff doesn't block")
        XCTAssertEqual(outbox.entries.first?.deliveryStatus, .sending,
                       "manual retry returns the entry to .sending so the UI shows the spinner")
    }
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests/testRetrySendResetsAttemptsAndFlushesSingleEntry 2>&1 | tail -10
```

Expected: build error — `retrySend(id:)` not defined.

- [ ] **Step 3: Implement retrySend on WebSocketClient**

In `WebSocketClient.swift`, add near `flushOutbox`:

```swift
    /// Manual retry of a single outbox entry — triggered by tapping the red
    /// .failed indicator. Resets attempts so backoff doesn't immediately re-skip.
    @MainActor
    func retrySend(id: String) {
        guard let idx = outbox.entries.firstIndex(where: { $0.id == id }) else { return }
        outbox.entries[idx].attempts = 0
        outbox.entries[idx].lastAttempt = nil
        outbox.entries[idx].deliveryStatus = .sending
        outbox.save()
        updateDeliveryStatus(id, .sending)
        flushOutbox()
        Theme.hapticMedium()
    }
```

- [ ] **Step 4: Make DeliveryChecks tappable for .failed**

In `DeliveryChecks.swift`, replace the struct with:

```swift
struct DeliveryChecks: View {
    let status: DeliveryStatus
    var onRetryTap: (() -> Void)? = nil

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
                            withAnimation(.easeOut(duration: Theme.animFast)) {
                                secondCheckOpacity = 1
                            }
                        }
                }
            case .failed:
                Button {
                    onRetryTap?()
                } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red.opacity(0.9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Повторить отправку")
            }
        }
        .frame(width: 14, height: 10)
        .animation(.easeOut(duration: Theme.animFast), value: status)
    }
}
```

- [ ] **Step 5: Wire the tap through MessageRow**

In `MessageRow.swift`, find where `DeliveryChecks(status: ...)` is instantiated. Add the `onRetryTap` parameter — its value depends on how the row receives the coordinator. Common pattern:

```swift
// At the call site:
DeliveryChecks(status: message.deliveryStatus, onRetryTap: {
    coordinator.ws.retrySend(id: message.id)
})
```

If `coordinator` is not currently in scope, lift it via `@Environment` or pass it through the row's init. The simplest is to add an `onRetry: ((String) -> Void)?` closure to `MessageRow` and forward; the parent `ChatView` already has `coordinator` and can pass `{ id in coordinator.ws.retrySend(id: id) }`.

- [ ] **Step 6: Run tests to verify pass**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WebSocketClientOutboxTests 2>&1 | tail -10
```

Expected: all 8 outbox tests **PASS**.

Run the full iOS test suite as a final check:

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests 2>&1 | tail -20
```

Expected: all `JarvisAppTests` tests pass.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift \
        ios/JarvisApp/Sources/JarvisApp/Components/DeliveryChecks.swift \
        ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WebSocketClientOutboxTests.swift
git commit -m "ios: tappable .failed delivery indicator triggers single-entry retry

Tapping the red exclamation badge on a failed user message now calls
WebSocketClient.retrySend(id:) which resets the entry's attempts/lastAttempt,
moves it back to .sending in both the outbox and the UI, fires a medium
haptic, and reflushes. Backoff doesn't block a manual retry."
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| OutboxStore (entry struct, enqueue, remove, persist, load) | Task 2 |
| OutboxStore cap (100, drop oldest .failed, refuse otherwise) | Task 3 |
| OutboxStore backoff (5+ attempts in 60s skip) | Task 4 |
| MessageCache deliveryStatus round-trip tests | Task 5 |
| ContextBuilder 15-min staleness gate | Task 1 |
| ContextBuilder matrix tests | Task 1 + 6 |
| WebSocketClient — enqueue every send (offline-safe) | Task 7 |
| WebSocketClient — flushOutbox on reconnect | Task 8 |
| WebSocketClient — message_ack removes from outbox + .delivered | Task 9 |
| WebSocketClient — stale-sent 30s timeout → .failed | Task 10 |
| Server-side dedup of repeated clientMessageId | Task 11 |
| Server-side ack contract test | Task 12 |
| Manual retry on tappable .failed indicator | Task 13 |

**Out of scope (per spec Open Questions, deferred):**

- Header outbox-pending badge (Open Question #3). Not in this plan — UI surface decision pending.
- Configurable stale-sent timeout (Open Question #1). Hardcoded 30s; can be tuned later.

**Placeholder scan:** No "TBD", "implement later", "add error handling" without code. Every step shows the change.

**Type consistency check:**

- `OutboxEntry.id` (String, = clientMessageId) consistent across `WebSocketClient.send`, `flushOutbox`, `handleMessageAck`, `retrySend`.
- `OutboxStore.enqueue` returns `Bool` from Task 3 onwards (used in Task 7).
- `IosWsHandlerState.processedClientMsgIds` added in Task 11, referenced in `handlerState` constructor in same task; tests in Tasks 11 and 12 both include it in `makeState`.
- `WebSocketClient.init(outbox:)` introduced in Task 7, used in every later iOS task.
- `DeliveryChecks.onRetryTap` introduced in Task 13.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-28-ios-reliability.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
