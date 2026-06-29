# Proactive Notifications (local-notif, no-push) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface Jarvis's (and any agent's) messages as iOS lock-screen local notifications when the app is not foreground-active, with no APNs — live-push notif when backgrounded-but-alive, plus a self-wake HTTP pull on iOS background ticks.

**Architecture:** Server gains a read-only `GET /ios/pending` that returns queued user-facing message envelopes (does not consume the queue). iOS raises `UNNotificationRequest` local notifications from two paths — (A) inline in `TransportV2` when a live WS message is inserted while the app isn't foreground-active, and (B) a `PendingNotifications.drain()` HTTP pull invoked on every existing background wake (HealthKit observers, the morning `BGProcessingTask`) plus a new `BGAppRefreshTask`. A single configured `LocalNotifier` singleton does foreground-gating, a per-id dedup against `inbound_dedup.notified_at`, and the notification build. No APNs anywhere (free Personal Team has no push entitlement).

**Tech Stack:** Host — Node + TypeScript, vitest, better-sqlite3. iOS — Swift, SwiftUI, GRDB, UserNotifications, BackgroundTasks, XCTest (`@testable import Jarvis`).

**Design deviation from spec (intentional, surfaced during planning):** The spec said the foreground flag lives in `AppCoordinator`. `TransportV2.routeInboundMessage` holds no coordinator reference (only `store`), so the flag instead lives in a tiny standalone `AppForegroundState` readable from both `TransportV2` (actor) and the background pull. Behavior and scope are unchanged.

---

## File Structure

**Server (host):**
- `src/channels/ios-app/v2/types.ts` — add `NOTIFY_TYPES` const.
- `src/channels/ios-app/v2/outbound-queue.ts` — add `listPendingNotify(platform_id, sinceSeq)`.
- `src/channels/ios-app/v2/http-handler.ts` — add `GET /ios/pending` + `listPending` dep.
- `src/channels/ios-app/v2/index.ts` — wire `listPending` to the queue.
- `src/channels/ios-app/v2/outbound-queue.test.ts` — test the new query.
- `src/channels/ios-app/v2/http-routes.test.ts` — test the new route.

**iOS (new files):**
- `Sources/JarvisApp/Services/AppForegroundState.swift` — thread-safe foreground bool.
- `Sources/JarvisApp/Services/LocalNotifier.swift` — `NotificationScheduling` protocol + `LocalNotifier` (gate + dedup + build + raise).
- `Sources/JarvisApp/Services/PendingNotifications.swift` — HTTP pull `GET /ios/pending` → raise.
- `Sources/JarvisApp/Services/PendingRefreshTask.swift` — `BGAppRefreshTask` register/schedule/handle.
- `Sources/JarvisAppTests/LocalNotifierTests.swift`, `Sources/JarvisAppTests/PendingNotificationsTests.swift`, `Sources/JarvisAppTests/StoreNotifiedTests.swift`.

**iOS (modified):**
- `Sources/JarvisApp/Storage/Schema.swift` — migration `v11-dedup-notified-at`.
- `Sources/JarvisApp/Storage/ConversationStoreV2.swift` — `notifiedSeen` / `recordNotified`.
- `Sources/JarvisApp/Models/AppSettings.swift` — `notificationsEnabled` toggle.
- `Sources/JarvisApp/Services/TransportV2.swift` — live-path raise after insert.
- `Sources/JarvisApp/Services/AppCoordinator.swift` — configure `LocalNotifier.shared`.
- `Sources/JarvisApp/Services/HealthSync.swift`, `Services/HealthBackgroundTask.swift` — call the pull on background wakes.
- `Sources/JarvisApp/JarvisApp.swift` — set foreground state; register/schedule the refresh task.
- `Sources/JarvisApp/Views/Settings*.swift` — a "Уведомления" toggle row.
- `project.yml` — `BGTaskSchedulerPermittedIdentifiers` entry + version bump.

---

## Task 1: Server — `NOTIFY_TYPES` + `OutboundQueue.listPendingNotify`

**Files:**
- Modify: `src/channels/ios-app/v2/types.ts`
- Modify: `src/channels/ios-app/v2/outbound-queue.ts`
- Test: `src/channels/ios-app/v2/outbound-queue.test.ts`

- [ ] **Step 1: Add the `NOTIFY_TYPES` constant**

In `src/channels/ios-app/v2/types.ts`, after the existing `export const MAX_QUEUE_PER_DEVICE = 1000;` line, add:

```typescript
/**
 * Outbound envelope types the device should raise a local notification for.
 * The notification pull (`GET /ios/pending`) and the device-side notifier are
 * both restricted to these. `message` only for the MVP; extend (e.g.
 * `coach_message`) when those become notification-worthy.
 */
export const NOTIFY_TYPES = ['message'] as const;
```

- [ ] **Step 2: Write the failing test**

In `src/channels/ios-app/v2/outbound-queue.test.ts`, add this test (place it inside the existing top-level `describe`, or append a new one — match the file's existing structure):

```typescript
import { NOTIFY_TYPES } from './types.js';

describe('listPendingNotify', () => {
  it('returns only NOTIFY_TYPES rows with seq greater than since, oldest first', () => {
    const db = openTransportDb(':memory:');
    const q = new OutboundQueue(db);
    const pid = 'ios-app-v2:p1';
    const s1 = q.enqueue(pid, { id: 'm1', kind: 'data', type: 'message', payload: { text: 'a' } });
    q.enqueue(pid, { id: 'w1', kind: 'data', type: 'workout_plan', payload: { x: 1 } });
    const s3 = q.enqueue(pid, { id: 'm2', kind: 'data', type: 'message', payload: { text: 'b' } });

    // since = 0 → both message rows, workout excluded, oldest first.
    const all = q.listPendingNotify(pid, 0);
    expect(all.map((r) => r.id)).toEqual(['m1', 'm2']);

    // since = s1 → only the later message row.
    const after = q.listPendingNotify(pid, s1);
    expect(after.map((r) => r.id)).toEqual(['m2']);

    // scoped per device.
    expect(q.listPendingNotify('ios-app-v2:other', 0)).toEqual([]);

    // read-only — the queue is unchanged.
    expect(q.list(pid)).toHaveLength(3);
    void s3;
    db.raw.close();
  });
});
```

Confirm the test file already imports `openTransportDb` and `OutboundQueue`; if not, add `import { openTransportDb } from './transport-db.js';` and `import { OutboundQueue } from './outbound-queue.js';` at the top.

- [ ] **Step 3: Run the test to verify it fails**

Run: `pnpm exec vitest run src/channels/ios-app/v2/outbound-queue.test.ts`
Expected: FAIL — `q.listPendingNotify is not a function`.

- [ ] **Step 4: Implement `listPendingNotify`**

In `src/channels/ios-app/v2/outbound-queue.ts`, add the import at the top (merge with the existing `./types.js` import line):

```typescript
import { MAX_QUEUE_PER_DEVICE, NOTIFY_TYPES, type OutboundQueueRow } from './types.js';
```

Then add this method to the `OutboundQueue` class, after `list(...)`:

```typescript
  /**
   * Read-only: queued envelopes the device should raise a notification for —
   * `NOTIFY_TYPES` only, with seq strictly greater than `sinceSeq`, oldest
   * first. Does NOT delete anything; the WS drain + ack path remains the sole
   * consumer. The device dedups per-id, so re-returning an un-acked row is a
   * no-op there.
   */
  listPendingNotify(platform_id: string, sinceSeq: number): OutboundQueueRow[] {
    const placeholders = NOTIFY_TYPES.map(() => '?').join(', ');
    return this.db.raw
      .prepare(
        `SELECT * FROM outbound_queue
         WHERE platform_id = ? AND seq > ? AND type IN (${placeholders})
         ORDER BY seq ASC`,
      )
      .all(platform_id, sinceSeq, ...NOTIFY_TYPES) as OutboundQueueRow[];
  }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pnpm exec vitest run src/channels/ios-app/v2/outbound-queue.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/channels/ios-app/v2/types.ts src/channels/ios-app/v2/outbound-queue.ts src/channels/ios-app/v2/outbound-queue.test.ts
git commit -m "feat(ios-notif): listPendingNotify + NOTIFY_TYPES for the pending pull"
```

---

## Task 2: Server — `GET /ios/pending` endpoint

**Files:**
- Modify: `src/channels/ios-app/v2/http-handler.ts`
- Modify: `src/channels/ios-app/v2/index.ts:459-469` (the `createIosHttpHandler({...})` call)
- Test: `src/channels/ios-app/v2/http-routes.test.ts`

- [ ] **Step 1: Add `listPending` to the handler deps**

In `src/channels/ios-app/v2/http-handler.ts`, add an import for the row type at the top (merge with existing imports from `./types.js` if present, else add a new line):

```typescript
import type { OutboundQueueRow } from './types.js';
```

Then add a field to the `HttpHandlerDeps` interface, after `healthRequestsStore: HealthRequestsStore;`:

```typescript
  /**
   * Read queued notification-worthy envelopes for a device (token-resolved
   * platform_id), seq > sinceSeq. Read-only — see OutboundQueue.listPendingNotify.
   */
  listPending: (platformId: string, sinceSeq: number) => OutboundQueueRow[];
```

And add `listPending` to the destructure at the top of `createIosHttpHandler`:

```typescript
  const { resolveToken, healthRequestsStore, healthAgentFolder, getChannelSetup, imageCache, listPending, log, logWarn } =
    deps;
```

- [ ] **Step 2: Write the failing test**

In `src/channels/ios-app/v2/http-routes.test.ts`:

First extend the harness. Add the import near the others:

```typescript
import { OutboundQueue } from './outbound-queue.js';
```

Add `queue: OutboundQueue;` to the `Harness` interface. In `bootHarness`, after `const store = new HealthRequestsStore(db);` add `const queue = new OutboundQueue(db);`. Add `listPending: (pid, since) => queue.listPendingNotify(pid, since),` to the `createIosHttpHandler({...})` call. Add `queue,` to the returned harness object.

Then append this describe block:

```typescript
describe('GET /ios/pending', () => {
  it('returns notification-worthy messages for the token device, parsed, oldest first', async () => {
    h.queue.enqueue(PLATFORM_ID, { id: 'm1', kind: 'data', type: 'message', payload: { text: 'hello', agent_id: 'jarvis' } });
    h.queue.enqueue(PLATFORM_ID, { id: 'w1', kind: 'data', type: 'workout_plan', payload: { x: 1 } });
    h.queue.enqueue(PLATFORM_ID, { id: 'm2', kind: 'data', type: 'message', payload: { text: 'second', agent_id: 'greg' } });
    h.queue.enqueue('ios-app-v2:someone-else', { id: 'mX', kind: 'data', type: 'message', payload: { text: 'leak' } });

    const r = await fetchJson(`${h.url}/ios/pending`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    const body = r.json() as { messages: Array<{ id: string; seq: number; agent_id: string | null; text: string }> };
    expect(body.messages.map((m) => m.id)).toEqual(['m1', 'm2']);
    expect(body.messages[0]).toMatchObject({ id: 'm1', agent_id: 'jarvis', text: 'hello' });
    expect(body.messages[1]).toMatchObject({ id: 'm2', agent_id: 'greg', text: 'second' });

    // The queue is NOT consumed by the pull.
    expect(h.queue.list(PLATFORM_ID)).toHaveLength(3);
  });

  it('honors ?since= and never leaks another device, and requires auth', async () => {
    const s1 = h.queue.enqueue(PLATFORM_ID, { id: 'm1', kind: 'data', type: 'message', payload: { text: 'a' } });
    h.queue.enqueue(PLATFORM_ID, { id: 'm2', kind: 'data', type: 'message', payload: { text: 'b' } });

    const r = await fetchJson(`${h.url}/ios/pending?since=${s1}`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    expect((r.json() as { messages: Array<{ id: string }> }).messages.map((m) => m.id)).toEqual(['m2']);

    const noAuth = await fetchJson(`${h.url}/ios/pending`, { method: 'GET' });
    expect(noAuth.status).toBe(401);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts`
Expected: FAIL — `/ios/pending` returns 404 (route not implemented).

- [ ] **Step 4: Implement the route**

In `src/channels/ios-app/v2/http-handler.ts`, add this block immediately before the final `res.writeHead(404, ...)` line at the end of the returned handler:

```typescript
    if (req.method === 'GET' && url.pathname === '/ios/pending') {
      const id = authIdentity(req);
      if (!id) {
        res.writeHead(401, { 'Content-Type': 'application/json' }).end('{"error":"unauthorized"}');
        return;
      }
      const sinceRaw = url.searchParams.get('since');
      const since = sinceRaw ? parseInt(sinceRaw, 10) : 0;
      const safeSince = Number.isFinite(since) && since > 0 ? since : 0;
      const messages = listPending(id.platform_id, safeSince).map((row) => {
        let agent_id: string | null = null;
        let text = '';
        try {
          const p = JSON.parse(row.payload_json) as { text?: unknown; agent_id?: unknown };
          if (typeof p.text === 'string') text = p.text;
          if (typeof p.agent_id === 'string') agent_id = p.agent_id;
        } catch {
          /* malformed payload — surface id/seq with empty text */
        }
        return { id: row.id, seq: row.seq, agent_id, text };
      });
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ messages }));
      return;
    }
```

- [ ] **Step 5: Wire `listPending` into the live adapter**

In `src/channels/ios-app/v2/index.ts`, inside the `createIosHttpHandler({...})` call (currently around line 459), add the `listPending` field after `healthRequestsStore,`:

```typescript
        listPending: (pid, since) => queue.listPendingNotify(pid, since),
```

(`queue` is already in scope — `const queue = new OutboundQueue(db);` at line 204.)

- [ ] **Step 6: Run the tests + typecheck**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts && pnpm run build`
Expected: PASS; build (tsc) exits 0.

- [ ] **Step 7: Commit**

```bash
git add src/channels/ios-app/v2/http-handler.ts src/channels/ios-app/v2/index.ts src/channels/ios-app/v2/http-routes.test.ts
git commit -m "feat(ios-notif): GET /ios/pending read-only pending-message endpoint"
```

---

## Task 3: iOS — `inbound_dedup.notified_at` migration + store methods

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift:157` (add migration before `try m.migrate(writer)`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift` (after `recordDedup`, ~line 196)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/StoreNotifiedTests.swift` (new)

- [ ] **Step 1: Add the migration**

In `Schema.swift`, immediately before `try m.migrate(writer)` (currently line 157), add:

```swift
        m.registerMigration("v11-dedup-notified-at") { db in
            // Tracks which inbound message ids have already raised a local
            // notification, so live-push and background-pull never double-notify.
            // NULL = not yet notified.
            try db.execute(sql: "ALTER TABLE inbound_dedup ADD COLUMN notified_at INTEGER;")
        }
```

- [ ] **Step 2: Write the failing test**

Create `ios/JarvisApp/Sources/JarvisAppTests/StoreNotifiedTests.swift`:

```swift
import XCTest
import GRDB
@testable import Jarvis

final class StoreNotifiedTests: XCTestCase {
    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    func testNotifiedRoundTrip() throws {
        let store = try makeStore()
        XCTAssertFalse(try store.notifiedSeen(id: "a"))
        try store.recordNotified(id: "a", seq: 5)
        XCTAssertTrue(try store.notifiedSeen(id: "a"))
        // Idempotent — second record doesn't throw and stays seen.
        try store.recordNotified(id: "a", seq: 5)
        XCTAssertTrue(try store.notifiedSeen(id: "a"))
    }

    func testRecordNotifiedUpsertsOntoAnExistingDedupRow() throws {
        let store = try makeStore()
        // Simulate the live path: dedup recorded first (no notified_at), then notified.
        try store.recordDedup(id: "b", seq: 9)
        XCTAssertFalse(try store.notifiedSeen(id: "b"))
        try store.recordNotified(id: "b", seq: 9)
        XCTAssertTrue(try store.notifiedSeen(id: "b"))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run from `ios/JarvisApp/`: `xcodebuild test -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:JarvisTests/StoreNotifiedTests 2>&1 | tail -20`
Expected: FAIL — `notifiedSeen` / `recordNotified` not found (build error).

(If `xcodebuild` scheme/destination differ in this environment, use the XcodeBuildMCP `test_sim` tool with the project's scheme `Jarvis` and any booted simulator. Run `xcodegen generate` from `ios/JarvisApp/` first if the new test file isn't in the project yet.)

- [ ] **Step 4: Implement the store methods**

In `ConversationStoreV2.swift`, after `recordDedup(id:seq:)` (~line 196), add:

```swift
    /// True if this inbound id has already raised a local notification.
    func notifiedSeen(id: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM inbound_dedup WHERE id=? AND notified_at IS NOT NULL)",
                arguments: [id]) ?? false
        }
    }

    /// Stamp an inbound id as notified. Upserts: the live path already wrote a
    /// dedup row (only notified_at flips); the pull path may insert fresh.
    func recordNotified(id: String, seq: Int) throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            try db.execute(
                sql: """
                INSERT INTO inbound_dedup (id, seq, received_at, notified_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET notified_at = excluded.notified_at
                """,
                arguments: [id, seq, now, now])
        }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run the same test command as Step 3.
Expected: PASS (`StoreNotifiedTests` green).

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift ios/JarvisApp/Sources/JarvisApp/Storage/ConversationStoreV2.swift ios/JarvisApp/Sources/JarvisAppTests/StoreNotifiedTests.swift
git commit -m "feat(ios-notif): inbound_dedup.notified_at + notifiedSeen/recordNotified"
```

---

## Task 4: iOS — `AppForegroundState` + `notificationsEnabled` setting

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/AppForegroundState.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift`

- [ ] **Step 1: Create the foreground-state holder**

Create `ios/JarvisApp/Sources/JarvisApp/Services/AppForegroundState.swift`:

```swift
import Foundation

/// Whether the app is currently foreground-active. Set from the scenePhase
/// observer in `JarvisApp.swift`; read from `LocalNotifier` (any thread) and the
/// `TransportV2` actor to decide whether an inbound message should raise a
/// local notification (active → it's already on screen, no notification).
/// Lock-guarded because writes come from MainActor and reads from background.
enum AppForegroundState {
    private static let lock = NSLock()
    private static var _active = false

    static var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }
}
```

- [ ] **Step 2: Add the settings toggle**

In `AppSettings.swift`, after the `watchCompanionEnabled` line, add:

```swift
    // MARK: – Notifications
    /// Master switch for agent-message local notifications (default on).
    @ObservationIgnored @AppStorage("notificationsEnabled") var notificationsEnabled = true
```

- [ ] **Step 3: Build to verify it compiles**

Run from `ios/JarvisApp/`: `xcodegen generate` then build the `Jarvis` scheme (XcodeBuildMCP `build_sim`, scheme `Jarvis`).
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/AppForegroundState.swift ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios-notif): AppForegroundState + notificationsEnabled setting"
```

---

## Task 5: iOS — `LocalNotifier` (gate + dedup + build + raise)

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/LocalNotifier.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/LocalNotifierTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `ios/JarvisApp/Sources/JarvisAppTests/LocalNotifierTests.swift`:

```swift
import XCTest
import GRDB
import UserNotifications
@testable import Jarvis

final class LocalNotifierTests: XCTestCase {
    final class RecordingCenter: NotificationScheduling {
        var requests: [UNNotificationRequest] = []
        func schedule(_ request: UNNotificationRequest) { requests.append(request) }
    }

    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    func testRaisesWhenBackgroundedAndEnabled() throws {
        let rec = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true })
        n.configure(store: store)

        n.raise(id: "m1", agentId: "greg", text: "Готовность 68", seq: 3)
        XCTAssertEqual(rec.requests.count, 1)
        let content = rec.requests[0].content
        XCTAssertEqual(content.body, "Готовность 68")
        XCTAssertEqual(content.threadIdentifier, "greg")
        // Title comes from the agent's display name.
        XCTAssertEqual(content.title, AgentIdentity(rawValue: "greg")?.displayName ?? "Jarvis")
        XCTAssertTrue(try store.notifiedSeen(id: "m1"))
    }

    func testDedupsById() throws {
        let rec = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true })
        n.configure(store: store)
        n.raise(id: "m1", agentId: "jarvis", text: "x", seq: 1)
        n.raise(id: "m1", agentId: "jarvis", text: "x", seq: 1)
        XCTAssertEqual(rec.requests.count, 1, "same id must not notify twice")
    }

    func testSuppressedWhenForegroundOrDisabled() throws {
        let store = try makeStore()

        let fg = RecordingCenter()
        let nFg = LocalNotifier(center: fg, isForeground: { true }, isEnabled: { true })
        nFg.configure(store: store)
        nFg.raise(id: "a", agentId: "jarvis", text: "x", seq: 1)
        XCTAssertEqual(fg.requests.count, 0, "foreground-active → no notification")

        let off = RecordingCenter()
        let nOff = LocalNotifier(center: off, isForeground: { false }, isEnabled: { false })
        nOff.configure(store: store)
        nOff.raise(id: "b", agentId: "jarvis", text: "x", seq: 1)
        XCTAssertEqual(off.requests.count, 0, "setting off → no notification")
    }

    func testTruncatesLongBody() throws {
        let rec = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true })
        n.configure(store: store)
        n.raise(id: "m1", agentId: "jarvis", text: String(repeating: "x", count: 400), seq: 1)
        XCTAssertLessThanOrEqual(rec.requests[0].content.body.count, 160)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `ios/JarvisApp/`: `xcodegen generate` then the `LocalNotifierTests` via XcodeBuildMCP `test_sim` (scheme `Jarvis`, `-only-testing:JarvisTests/LocalNotifierTests`).
Expected: FAIL — `NotificationScheduling` / `LocalNotifier` not found.

- [ ] **Step 3: Implement `LocalNotifier`**

Create `ios/JarvisApp/Sources/JarvisApp/Services/LocalNotifier.swift`:

```swift
import Foundation
import UserNotifications

/// Seam over `UNUserNotificationCenter` so tests can record scheduled requests.
protocol NotificationScheduling: AnyObject {
    func schedule(_ request: UNNotificationRequest)
}

extension UNUserNotificationCenter: NotificationScheduling {
    func schedule(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }
}

/// Raises agent-message local notifications. No APNs — these are on-device
/// notifications fired while the app is alive (live WS insert) or on a
/// background self-wake pull. Gated on: app not foreground-active, the user
/// setting, and a per-id dedup against `inbound_dedup.notified_at`.
final class LocalNotifier {
    static let shared = LocalNotifier()

    private let center: NotificationScheduling
    private let isForeground: () -> Bool
    private let isEnabled: () -> Bool
    private var store: ConversationStoreV2?

    init(
        center: NotificationScheduling = UNUserNotificationCenter.current(),
        isForeground: @escaping () -> Bool = { AppForegroundState.isActive },
        isEnabled: @escaping () -> Bool = {
            // Mirrors @AppStorage("notificationsEnabled") default = true.
            UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        }
    ) {
        self.center = center
        self.isForeground = isForeground
        self.isEnabled = isEnabled
    }

    /// Wire the dedup store. Called once at app init (foreground or background
    /// launch) from `AppCoordinator`. Until configured, `raise` is a safe no-op.
    func configure(store: ConversationStoreV2) {
        self.store = store
    }

    func raise(id: String, agentId: String, text: String, seq: Int = 0) {
        guard !isForeground() else { return }   // already on screen
        guard isEnabled() else { return }
        guard let store else { return }
        if (try? store.notifiedSeen(id: id)) == true { return }

        let content = UNMutableNotificationContent()
        content.title = AgentIdentity(rawValue: agentId)?.displayName ?? "Jarvis"
        content.body = String(text.prefix(160))
        content.sound = .default
        content.threadIdentifier = agentId

        // nil trigger → delivered immediately. Identifier keyed by message id so
        // a repeat (belt-and-suspenders vs the dedup) replaces rather than dups.
        let req = UNNotificationRequest(identifier: "msg-\(id)", content: content, trigger: nil)
        center.schedule(req)
        try? store.recordNotified(id: id, seq: seq)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same `-only-testing:JarvisTests/LocalNotifierTests` command.
Expected: PASS.

> If `AgentIdentity(rawValue:)?.displayName` doesn't compile, open `Sources/JarvisApp/Models/AgentIdentity.swift` and use the exact display-name accessor it exposes (it is the enum keyed by folder slug — jarvis/payne/greg/scrooge — per the iOS CLAUDE.md). Adjust both the implementation and the test's expectation to match.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/LocalNotifier.swift ios/JarvisApp/Sources/JarvisAppTests/LocalNotifierTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios-notif): LocalNotifier — foreground/setting/dedup-gated local notification"
```

---

## Task 6: iOS — live-path hook in `TransportV2` + configure `LocalNotifier.shared`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift:326-328` (after `store.insertInbound`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift` (init, after storage is bound)

- [ ] **Step 1: Configure the shared notifier at app init**

In `AppCoordinator.swift`, find the init block that binds storage:

```swift
        if let storage {
            self.timeline = storage.timeline
            self.chatStore = storage.store   // prewarmed in startBackgroundPrep (post-splash)
        }
```

Replace it with:

```swift
        if let storage {
            self.timeline = storage.timeline
            self.chatStore = storage.store   // prewarmed in startBackgroundPrep (post-splash)
            // Wire the dedup store into the shared notifier. Runs on every
            // launch (foreground or BGTask-driven background), so the pull path
            // has a configured notifier during background wakes too.
            LocalNotifier.shared.configure(store: storage.store)
        }
```

- [ ] **Step 2: Add the live-path raise in TransportV2**

In `TransportV2.swift`, inside `routeInboundMessage`, find the normal-insert tail:

```swift
        let agentId = message.agent_id ?? "jarvis"
        try store.insertInbound(envelope: envelope, message: message, agentId: agentId)
        try? store.prune() // global retention; cheap no-op while under cap
        try await sendAck(id: envelope.id, seq: envelope.seq ?? 0)
```

Insert the raise immediately after `try? store.prune()`:

```swift
        let agentId = message.agent_id ?? "jarvis"
        try store.insertInbound(envelope: envelope, message: message, agentId: agentId)
        try? store.prune() // global retention; cheap no-op while under cap
        // Backgrounded-but-alive: surface a local notification. No-op when the
        // app is foreground-active (already on screen) or the notifier is
        // unconfigured (e.g. tests). Dedups against notified_at.
        LocalNotifier.shared.raise(id: envelope.id, agentId: agentId, text: message.text, seq: envelope.seq ?? 0)
        try await sendAck(id: envelope.id, seq: envelope.seq ?? 0)
```

- [ ] **Step 3: Verify the build + existing transport tests are unaffected**

Run from `ios/JarvisApp/`: `xcodegen generate`, then build the `Jarvis` scheme and run the existing TransportV2 test target (XcodeBuildMCP `test_sim`, scheme `Jarvis`, `-only-testing:JarvisTests` or the transport-specific test class if present).
Expected: build succeeds; existing tests still PASS (`LocalNotifier.shared` is unconfigured in tests → `raise` no-ops because `store` is nil).

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift
git commit -m "feat(ios-notif): raise local notification on backgrounded live message insert"
```

---

## Task 7: iOS — `PendingNotifications` HTTP pull

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/PendingNotifications.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/PendingNotificationsTests.swift` (new)

- [ ] **Step 1: Write the failing test (pure parse seam)**

Create `ios/JarvisApp/Sources/JarvisAppTests/PendingNotificationsTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class PendingNotificationsTests: XCTestCase {
    func testParseValidBody() throws {
        let json = """
        {"messages":[
          {"id":"m1","seq":3,"agent_id":"jarvis","text":"hi"},
          {"id":"m2","seq":5,"agent_id":"greg","text":"готовность 68"}
        ]}
        """.data(using: .utf8)!
        let msgs = PendingNotifications.parse(json)
        XCTAssertEqual(msgs.map(\.id), ["m1", "m2"])
        XCTAssertEqual(msgs[1].agent_id, "greg")
        XCTAssertEqual(msgs[1].seq, 5)
    }

    func testParseToleratesNullAgentAndEmpty() throws {
        XCTAssertEqual(PendingNotifications.parse(Data("{}".utf8)).count, 0)
        XCTAssertEqual(PendingNotifications.parse(Data("garbage".utf8)).count, 0)
        let nullAgent = Data(#"{"messages":[{"id":"m1","seq":1,"agent_id":null,"text":"x"}]}"#.utf8)
        let msgs = PendingNotifications.parse(nullAgent)
        XCTAssertEqual(msgs.first?.agent_id, nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `ios/JarvisApp/`: `xcodegen generate`, then `-only-testing:JarvisTests/PendingNotificationsTests` via XcodeBuildMCP `test_sim`.
Expected: FAIL — `PendingNotifications` not found.

- [ ] **Step 3: Implement `PendingNotifications`**

Create `ios/JarvisApp/Sources/JarvisApp/Services/PendingNotifications.swift`. This mirrors `HealthRequests.drain` (same URL-normalize + bearer + URLSession glue), with a pure `parse` seam for tests:

```swift
import Foundation

/// Pulls notification-worthy queued messages over HTTP (`GET /ios/pending`) and
/// raises a local notification for each via `LocalNotifier`. Invoked on every
/// background self-wake (HealthKit observers, the morning BGProcessing task, and
/// the dedicated BGAppRefresh task). No APNs. Dedup is per-id in LocalNotifier,
/// so re-pulling an un-acked message is a harmless no-op.
enum PendingNotifications {
    struct PendingMessage: Decodable {
        let id: String
        let seq: Int
        let agent_id: String?
        let text: String
    }
    private struct Envelope: Decodable { let messages: [PendingMessage] }

    /// Pure decode seam (unit-tested). Tolerant: any decode failure → empty.
    static func parse(_ data: Data) -> [PendingMessage] {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.messages ?? []
    }

    static func drain(completion: (() -> Void)? = nil) {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "bearerToken"), !token.isEmpty else {
            completion?(); return
        }
        var base = ServerConfig.url
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        else if !base.hasPrefix("http") { base = "http://" + base }
        guard let url = URL(string: base.hasSuffix("/") ? base + "ios/pending" : base + "/ios/pending") else {
            completion?(); return
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data else { completion?(); return }
            let messages = parse(data)
            for m in messages {
                LocalNotifier.shared.raise(id: m.id, agentId: m.agent_id ?? "jarvis", text: m.text, seq: m.seq)
            }
            completion?()
        }.resume()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same `-only-testing:JarvisTests/PendingNotificationsTests` command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/PendingNotifications.swift ios/JarvisApp/Sources/JarvisAppTests/PendingNotificationsTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios-notif): PendingNotifications — GET /ios/pending pull → local notifs"
```

---

## Task 8: iOS — wire the pull into all background wakes + `BGAppRefreshTask`

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/PendingRefreshTask.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift` (`handleObserverFire`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthBackgroundTask.swift` (`handle`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` (register/schedule + foreground state)
- Modify: `ios/JarvisApp/project.yml` (`BGTaskSchedulerPermittedIdentifiers`)

- [ ] **Step 1: Create the BGAppRefresh task**

Create `ios/JarvisApp/Sources/JarvisApp/Services/PendingRefreshTask.swift` (mirrors `HealthBackgroundTask`, but a `BGAppRefreshTaskRequest` on a short interval whose only job is the notification pull):

```swift
import Foundation
import BackgroundTasks

/// Periodic background self-wake whose sole job is to pull pending agent
/// messages and raise local notifications (no APNs). Complements the HealthKit
/// observer wakes and the morning BGProcessing task. iOS decides actual cadence
/// (the interval is an `earliestBeginDate` floor, throttled by usage); nothing
/// runs after the app is force-quit.
enum PendingRefreshTask {
    static let taskId = "com.vasechko.jarvis.pending-pull"
    static let interval: TimeInterval = 15 * 60

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            handle(task)
        }
    }

    static func schedule(now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("PendingRefreshTask: submit failed: \(error)")
        }
    }

    private static func handle(_ task: BGTask) {
        schedule() // re-arm first so a crash/expiry can't break the chain
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        PendingNotifications.drain {
            task.setTaskCompleted(success: true)
        }
    }
}
```

- [ ] **Step 2: Pull on HealthKit observer wakes**

In `HealthSync.swift`, in `handleObserverFire`, add the pull at the very top of the method (before the coalesce gate, so notifications still fire even when the health-upload is skipped as recently-pushed):

```swift
    private static func handleObserverFire(_ completion: @escaping () -> Void) {
        // Independent of the health-upload coalesce gate: a background wake is a
        // chance to surface queued agent messages even if we just pushed health.
        PendingNotifications.drain()

        pushLock.lock()
```

- [ ] **Step 3: Pull on the morning BGProcessing wake**

In `HealthBackgroundTask.swift`, in `handle(_:)`, add a pull alongside the existing drain chain. Change:

```swift
        HealthRequests.drain {
            HealthSync.pushRecent {
                task.setTaskCompleted(success: true)
            }
        }
```

to:

```swift
        PendingNotifications.drain()
        HealthRequests.drain {
            HealthSync.pushRecent {
                task.setTaskCompleted(success: true)
            }
        }
```

- [ ] **Step 4: Set foreground state + register/schedule the refresh task**

In `JarvisApp.swift`, in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, after the existing `HealthBackgroundTask.register()` / `.schedule()` lines, add:

```swift
        PendingRefreshTask.register()
        PendingRefreshTask.schedule()
```

Then in the `JarvisApp` `body` scenePhase observer, set the foreground flag. Change:

```swift
                .onChange(of: scenePhase) { _, new in
                    if new == .active {
                        Theme.refreshScale()
                        Theme.refreshDrawerWidth()
                        HealthSync.kickIfStale()
                    }
                    if new == .background {
                        // Re-arm the morning upload each time we background.
                        HealthBackgroundTask.schedule()
                    }
```

to:

```swift
                .onChange(of: scenePhase) { _, new in
                    AppForegroundState.isActive = (new == .active)
                    if new == .active {
                        Theme.refreshScale()
                        Theme.refreshDrawerWidth()
                        HealthSync.kickIfStale()
                    }
                    if new == .background {
                        // Re-arm the morning upload + pending pull each time we background.
                        HealthBackgroundTask.schedule()
                        PendingRefreshTask.schedule()
                    }
```

- [ ] **Step 5: Permit the new task identifier**

In `project.yml`, extend `BGTaskSchedulerPermittedIdentifiers`:

```yaml
        BGTaskSchedulerPermittedIdentifiers:
          - com.vasechko.jarvis.morning-health
          - com.vasechko.jarvis.pending-pull
```

(`fetch` is already in `UIBackgroundModes`, which BGAppRefreshTask requires — no change there.)

- [ ] **Step 6: Build to verify it compiles**

Run from `ios/JarvisApp/`: `xcodegen generate` then build the `Jarvis` scheme.
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/PendingRefreshTask.swift ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift ios/JarvisApp/Sources/JarvisApp/Services/HealthBackgroundTask.swift ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios-notif): self-wake pull on health observers + BGProcessing + new BGAppRefresh"
```

---

## Task 9: iOS — Settings toggle + version bump + clean build

**Files:**
- Modify: a Settings view under `ios/JarvisApp/Sources/JarvisApp/Views/` (the one that lists `@AppStorage` toggles like `useHealth`, `useLocation`)
- Modify: `ios/JarvisApp/project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`)

- [ ] **Step 1: Find the settings toggle list**

Run: `grep -rl "useHealth" ios/JarvisApp/Sources/JarvisApp/Views`
Open the file it reports (the settings screen). Locate the section where toggles bind to `settings.useHealth` / `settings.useLocation`.

- [ ] **Step 2: Add the notifications toggle**

Add a row in that section (match the surrounding `Toggle` style exactly — this is the canonical shape):

```swift
                Toggle("Уведомления", isOn: $settings.notificationsEnabled)
```

If the view holds settings as `@Bindable var settings: AppSettings` or `@Environment(AppSettings.self)`, use the matching binding form already used by the neighboring toggles in that file.

- [ ] **Step 3: Bump the version**

In `project.yml`, change:

```yaml
        MARKETING_VERSION: "1.15.0"
        CURRENT_PROJECT_VERSION: "68"
```

to:

```yaml
        MARKETING_VERSION: "1.16.0"
        CURRENT_PROJECT_VERSION: "69"
```

- [ ] **Step 4: Regenerate + clean build + full test suite**

Run from `ios/JarvisApp/`:
```bash
xcodegen generate
```
Then a clean build of scheme `Jarvis` and the full `JarvisTests` suite (XcodeBuildMCP: `clean` then `build_sim` then `test_sim`, scheme `Jarvis`).
Expected: clean build succeeds; all tests PASS (including `StoreNotifiedTests`, `LocalNotifierTests`, `PendingNotificationsTests`).

- [ ] **Step 5: Commit (include the generated pbxproj)**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/Sources/JarvisApp/Views ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios-notif): Settings notifications toggle + bump build 69 / 1.16.0"
```

---

## Task 10: Deploy + doctrine

**Files:**
- `groups/INSTRUCTIONS.md` (NOT git — scp to VDS; the `groups/` tree is gitignored)

- [ ] **Step 1: Push host + run the full host suite**

```bash
pnpm test
git push origin main
```
Expected: host vitest suite green; push succeeds.

- [ ] **Step 2: Deploy host to the VDS**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && git pull --ff-only && pnpm run build && XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart nanoclaw && XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active nanoclaw"'
```
Expected: prints `active`.

- [ ] **Step 3: Smoke-test the endpoint on the VDS**

```bash
ssh root@148.253.211.164 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3001/ios/pending'
```
Expected: `401` (route exists, rejects unauthenticated — proves it's wired, not 404).

- [ ] **Step 4: Add the doctrine line (scp, not git)**

Append one line to the host's `groups/INSTRUCTIONS.md` under an appropriate proactive-discipline section, e.g.:

> Проактивные сообщения теперь поднимают локальное уведомление на телефоне владельца (без APNs, self-wake). Дисциплина 3–4 проактивных/день и тихие часы 23:00–08:00 — соблюдать строго: каждое лишнее сообщение теперь звенит.

Edit a local working copy, then:
```bash
scp /tmp/INSTRUCTIONS.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md
# fix ownership so the service account can read it
ssh root@148.253.211.164 'chown nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md'
```
(Do NOT `git add` `groups/` — it's gitignored and install-specific.)

- [ ] **Step 5: Install the iOS build on device**

Build the `Jarvis` scheme to the connected device (or archive + install per the usual flow), confirm build 69 / 1.16.0 installs, and verify on-device: background the app, send a message from another agent surface (or trigger a proactive), confirm a lock-screen notification appears within a background tick. Toggle "Уведомления" off in Settings → confirm no notification.

---

## Self-Review (completed during authoring)

- **Spec coverage:** §3 data flow → Tasks 2,6,7,8. §4.1 server → Tasks 1,2. §4.2 iOS → Tasks 3,4,5,6,7,8,9. §5 edge cases (double-notify dedup) → Tasks 3,5. §6 out-of-scope → respected (no APNs, no `since` cursor on device, `NOTIFY_TYPES=['message']`, no deep-link). §7 doctrine → Task 10. §8 testing → server Tasks 1,2; iOS Tasks 3,5,7; clean build Task 9. §9 deploy → Task 10. No gaps.
- **Placeholder scan:** every code step shows real code; commands have expected output. The two soft spots are explicitly bounded: AgentIdentity display-name accessor (Task 5 note) and the exact Settings view file (Task 9 grep step) — both give the engineer a concrete discovery step rather than a guess.
- **Type consistency:** `listPendingNotify(platform_id, sinceSeq)` / `listPending(platformId, sinceSeq)` / `GET /ios/pending` response `{messages:[{id,seq,agent_id,text}]}` consistent across Tasks 1,2,7. `notifiedSeen(id)` / `recordNotified(id,seq)` consistent across Tasks 3,5,6,7. `LocalNotifier.raise(id:agentId:text:seq:)` consistent across Tasks 5,6,7. `NotificationScheduling.schedule(_:)` consistent across Task 5. `AppForegroundState.isActive` consistent across Tasks 4,5,8.
