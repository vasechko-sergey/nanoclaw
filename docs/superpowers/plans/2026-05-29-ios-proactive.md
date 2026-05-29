# iOS Proactive Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add proactive triggers to the iOS Jarvis app so the agent gets a "wake" ping when something noteworthy happens (significant location change, heart-rate spike, sleep/workout end, near-future calendar event), even when the app is in the background. Each ping is opt-in via Settings; payloads carry only the wake-event facts (no health data shipped — agent pulls via `request_context` if needed).

**Architecture:** New `ProactiveDispatcher` (`@Observable @MainActor`) sits in front of `WebSocketClient`. It owns rate limits, per-type opt-in gates, and routes events either via WebSocket (`type: "proactive"`) or a new HTTP POST fallback (`/ios/proactive`) when the WS isn't connected. Existing `LocationManager` is extended with significant-location monitoring + 500 m delta. `HealthManager` gains observer queries that ping the dispatcher only when a coarse detector (`HrSpikeDetector` etc.) finds something interesting. `CalendarManager` schedules silent local notifications 15 min before events; the `UNUserNotificationCenterDelegate` swallows the system banner and dispatches via the same path. Server-side `ios-app.ts` gains a WS branch for `type: "proactive"` and a new `POST /ios/proactive` HTTP endpoint that both reformat the trigger as an inbound system message. Jarvis's `CLAUDE.md` gains a "Персона" block and a "Проактивные триггеры" section that teaches the agent when to surface and when to swallow.

**Tech Stack:** Swift / SwiftUI / XCTest / CoreLocation / HealthKit / EventKit / UserNotifications. Node + vitest server side.

---

## File Structure

| File | Purpose |
|---|---|
| `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift` (MODIFY) | Add `proactiveGeofence`, `proactiveHealthHR`, `proactiveHealthSleep`, `proactiveHealthWorkout`, `proactiveCalendarWarn` `@AppStorage` keys (all Bool, default false). Add `proactiveEnabled(_ triggerType: String) -> Bool` helper. |
| `ios/JarvisApp/Sources/JarvisApp/Services/ProactiveDispatcher.swift` (NEW) | `@Observable @MainActor final class`. Rate-limit map + per-type minInterval + per-type opt-in. `fire(type:payload:)` decides WS vs HTTP. Public method `sendProactiveOverHTTP(...)` for tests. |
| `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift` (MODIFY) | New `sendProactive(triggerType:payload:)` method that emits `{type:"proactive", trigger, payload, ts, tz}` on the wire. Returns Bool indicating success/queued. |
| `ios/JarvisApp/Sources/JarvisApp/Services/HrSpikeDetector.swift` (NEW) | Pure helper: `detect(samples: [(bpm: Double, at: Date)], baseline: Double, now: Date) -> Bool`. Spike = peak ≥ baseline + 30 sustained > 60s. |
| `ios/JarvisApp/Sources/JarvisApp/Services/LocationManager.swift` (MODIFY) | Start significant-location monitoring; in `didUpdateLocations` compute delta from `geofenceAnchor`; fire via injected dispatcher when > 500 m. |
| `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift` (MODIFY) | Add `installObservers(dispatcher:)` that wires HKObserverQuery for HR + sleep + workout. Inner detectors call the dispatcher with empty payloads. |
| `ios/JarvisApp/Sources/JarvisApp/Services/CalendarManager.swift` (MODIFY) | Add `scheduleCalendarWarn(for:)` that posts a silent UNNotificationRequest 15 min before event. |
| `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` (MODIFY) | Conform AppDelegate (or a wrapper) to `UNUserNotificationCenterDelegate.willPresent` — when `userInfo["proactive"] == true`, route to dispatcher and return `[.list]` (silent). |
| `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift` (MODIFY) | Instantiate `ProactiveDispatcher`, pass into LocationManager + HealthManager + Calendar wiring. |
| `ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift` (MODIFY) | Replace the placeholder КОНТЕКСТ section with 5 real toggles (geofence/HR/sleep/workout/calendar). |
| `src/channels/ios-app.ts` (MODIFY) | (a) Add WS branch `msg.type === 'proactive'` → forward as inbound system text with `[proactive trigger=…]` prefix. (b) Add HTTP `POST /ios/proactive` handler doing the same. |
| `src/channels/ios-app.proactive.test.ts` (NEW) | Server tests for both WS and HTTP paths. |
| `groups/jarvis/CLAUDE.md` (MODIFY) | Append "Персона" and "Проактивные триггеры" sections (verbatim from spec). |
| `ios/JarvisApp/Sources/JarvisAppTests/ProactiveDispatcherTests.swift` (NEW) | Unit tests for rate limiting, type gating, payload shape. |
| `ios/JarvisApp/Sources/JarvisAppTests/HrSpikeDetectorTests.swift` (NEW) | Unit tests for spike detection. |

## Test Commands

- **iOS unit:** `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/<ClassName>`.
- **Server:** `pnpm vitest run src/channels/<file>.test.ts`. `pnpm typecheck`.
- **Regen Xcode project after adding files:** `cd ios/JarvisApp && xcodegen generate`.

---

### Task 1: AppSettings — five proactive opt-in keys + helper

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift`

- [ ] **Step 1: Add @AppStorage keys + helper**

Append after the existing voice-mode keys (after `silenceTimeoutSec`):

```swift
    // MARK: – Proactive triggers (all opt-in, default off)
    @ObservationIgnored @AppStorage("proactiveGeofence")        var proactiveGeofence        = false
    @ObservationIgnored @AppStorage("proactiveHealthHR")        var proactiveHealthHR        = false
    @ObservationIgnored @AppStorage("proactiveHealthSleep")     var proactiveHealthSleep     = false
    @ObservationIgnored @AppStorage("proactiveHealthWorkout")   var proactiveHealthWorkout   = false
    @ObservationIgnored @AppStorage("proactiveCalendarWarn")    var proactiveCalendarWarn    = false

    /// Whether a given trigger type is allowed to fire. Used by ProactiveDispatcher.fire.
    func proactiveEnabled(_ triggerType: String) -> Bool {
        switch triggerType {
        case "geofence":              return proactiveGeofence
        case "health_hr_spike":       return proactiveHealthHR
        case "health_sleep_end":      return proactiveHealthSleep
        case "health_workout_end":    return proactiveHealthWorkout
        case "calendar_warn":         return proactiveCalendarWarn
        default:                      return false
        }
    }
```

- [ ] **Step 2: Build + full test target**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + all existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift
git commit -m "ios: AppSettings — five proactive trigger opt-in keys

geofence, HR-spike, sleep-end, workout-end, calendar-warn — all default
false. Adds proactiveEnabled(_:) helper that maps trigger-type strings
to the right key for the dispatcher to consult."
```

---

### Task 2: ProactiveDispatcher service + rate-limit/type-gate tests

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/ProactiveDispatcher.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/ProactiveDispatcherTests.swift`

- [ ] **Step 1: Regen Xcode**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 2: Write failing tests**

Create `ios/JarvisApp/Sources/JarvisAppTests/ProactiveDispatcherTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class ProactiveDispatcherTests: XCTestCase {

    /// Records every call the dispatcher tried to ship (WS or HTTP).
    final class RecorderSink: ProactiveSink {
        var calls: [(type: String, payload: [String: Any])] = []
        func send(triggerType: String, payload: [String: Any]) -> Bool {
            calls.append((triggerType, payload))
            return true
        }
    }

    private func makeSettings(allOn: Bool = true) -> AppSettings {
        let s = AppSettings()
        s.proactiveGeofence = allOn
        s.proactiveHealthHR = allOn
        s.proactiveHealthSleep = allOn
        s.proactiveHealthWorkout = allOn
        s.proactiveCalendarWarn = allOn
        return s
    }

    func testRateLimitCollapsesRepeatsWithinInterval() {
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: makeSettings(), sink: sink)
        d.fire(type: "geofence", payload: [:])
        d.fire(type: "geofence", payload: [:])
        XCTAssertEqual(sink.calls.count, 1, "geofence has 60s min-interval — second call collapses")
    }

    func testDifferentTypesNotRateLimitedAgainstEachOther() {
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: makeSettings(), sink: sink)
        d.fire(type: "geofence", payload: [:])
        d.fire(type: "health_hr_spike", payload: [:])
        XCTAssertEqual(sink.calls.count, 2)
    }

    func testDisabledTypeIsSilenced() {
        let s = makeSettings(allOn: true)
        s.proactiveGeofence = false
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: s, sink: sink)
        d.fire(type: "geofence", payload: ["lat": 1.0])
        XCTAssertTrue(sink.calls.isEmpty)
    }

    func testGeofencePayloadShape() {
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: makeSettings(), sink: sink)
        d.fire(type: "geofence", payload: ["lat": 8.6, "lon": 115.1, "city": "Canggu"])
        XCTAssertEqual(sink.calls.count, 1)
        let p = sink.calls.first!.payload
        XCTAssertEqual(p["lat"] as? Double, 8.6)
        XCTAssertEqual(p["lon"] as? Double, 115.1)
        XCTAssertEqual(p["city"] as? String, "Canggu")
    }

    func testHrSpikePayloadIsEmpty() {
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: makeSettings(), sink: sink)
        d.fire(type: "health_hr_spike", payload: [:])
        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertTrue((sink.calls.first!.payload as [String: Any]).isEmpty,
                      "HR spike must not leak any data — payload empty by contract")
    }
}
```

- [ ] **Step 3: Verify failure**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/ProactiveDispatcherTests 2>&1 | tail -15
```

Expected: build error — ProactiveDispatcher, ProactiveSink undefined.

- [ ] **Step 4: Implement dispatcher**

Create `ios/JarvisApp/Sources/JarvisApp/Services/ProactiveDispatcher.swift`:

```swift
import Foundation

/// Outbound surface the dispatcher pushes events to. Production: WebSocketClient
/// (with HTTP fallback inside). Tests: a recording stub.
protocol ProactiveSink {
    func send(triggerType: String, payload: [String: Any]) -> Bool
}

/// Owns proactive trigger orchestration: opt-in gating, rate limits, and
/// fan-out to a `ProactiveSink`. Trigger sources (LocationManager,
/// HealthManager, CalendarManager) call `fire(type:payload:)` from any
/// thread that eventually hops to MainActor.
@Observable @MainActor final class ProactiveDispatcher {

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sink: ProactiveSink
    @ObservationIgnored private var lastFireByType: [String: Date] = [:]

    /// Per-trigger minimum interval between successive fires. Zero = no limit.
    @ObservationIgnored static let minIntervalByType: [String: TimeInterval] = [
        "geofence":              60,
        "health_hr_spike":      300,
        "health_sleep_end":    3600,
        "health_workout_end":     0,
        "calendar_warn":          0,
    ]

    init(settings: AppSettings, sink: ProactiveSink) {
        self.settings = settings
        self.sink = sink
    }

    /// Fire a proactive trigger. No-op if disabled in settings or within the
    /// type's min-interval window. Returns true if the event was actually
    /// shipped via the sink.
    @discardableResult
    func fire(type: String, payload: [String: Any]) -> Bool {
        guard settings.proactiveEnabled(type) else { return false }
        let minInt = Self.minIntervalByType[type] ?? 60
        if minInt > 0, let last = lastFireByType[type],
           Date().timeIntervalSince(last) < minInt {
            return false
        }
        lastFireByType[type] = Date()
        return sink.send(triggerType: type, payload: payload)
    }
}
```

- [ ] **Step 5: Run tests**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/ProactiveDispatcherTests 2>&1 | tail -15
```

Expected: 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/ProactiveDispatcher.swift \
        ios/JarvisApp/Sources/JarvisAppTests/ProactiveDispatcherTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add ProactiveDispatcher — opt-in + rate-limit fan-out

@Observable @MainActor service. Wraps a ProactiveSink protocol so
production sends via WebSocketClient (with HTTP fallback) and tests
use a recording stub. Per-type min-interval map + per-type
settings.proactiveEnabled gate prevent agent flooding."
```

---

### Task 3: HrSpikeDetector — pure detector + tests

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/HrSpikeDetector.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/HrSpikeDetectorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `ios/JarvisApp/Sources/JarvisAppTests/HrSpikeDetectorTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class HrSpikeDetectorTests: XCTestCase {

    private func sample(_ bpm: Double, secondsAgo: TimeInterval, from now: Date) -> HrSpikeDetector.Sample {
        .init(bpm: bpm, at: now.addingTimeInterval(-secondsAgo))
    }

    func testQuietStreamReturnsFalse() {
        let now = Date()
        let stream = (0..<120).map { i in
            sample(70, secondsAgo: TimeInterval(120 - i), from: now)
        }
        XCTAssertFalse(HrSpikeDetector.detect(samples: stream, baseline: 70, now: now))
    }

    func testShortSpikeBelowOneMinuteReturnsFalse() {
        let now = Date()
        // 30s spike — should be ignored
        var stream: [HrSpikeDetector.Sample] = []
        for i in 0..<90 { stream.append(sample(70, secondsAgo: TimeInterval(120 - i), from: now)) }
        for i in 90..<120 { stream.append(sample(110, secondsAgo: TimeInterval(120 - i), from: now)) }
        XCTAssertFalse(HrSpikeDetector.detect(samples: stream, baseline: 70, now: now))
    }

    func testSustainedSpikeOverThresholdReturnsTrue() {
        let now = Date()
        var stream: [HrSpikeDetector.Sample] = []
        for i in 0..<60 { stream.append(sample(70, secondsAgo: TimeInterval(120 - i), from: now)) }
        // 70s sustained at 110 — over baseline (70) + 30 = 100, over 60s
        for i in 60..<120 { stream.append(sample(110, secondsAgo: TimeInterval(120 - i), from: now)) }
        XCTAssertTrue(HrSpikeDetector.detect(samples: stream, baseline: 70, now: now))
    }

    func testJustBelowThresholdReturnsFalse() {
        let now = Date()
        var stream: [HrSpikeDetector.Sample] = []
        for i in 0..<60 { stream.append(sample(70, secondsAgo: TimeInterval(120 - i), from: now)) }
        // sustained at 99 — under baseline+30=100 threshold
        for i in 60..<120 { stream.append(sample(99, secondsAgo: TimeInterval(120 - i), from: now)) }
        XCTAssertFalse(HrSpikeDetector.detect(samples: stream, baseline: 70, now: now))
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/HrSpikeDetectorTests 2>&1 | tail -15
```

Expected: build error.

- [ ] **Step 3: Implement detector**

Create `ios/JarvisApp/Sources/JarvisApp/Services/HrSpikeDetector.swift`:

```swift
import Foundation

/// Pure heart-rate spike detector. No HealthKit or AVFoundation dependency.
/// Used by HealthManager.HRObserver to decide whether to fire a
/// `health_hr_spike` proactive trigger.
///
/// Definition: a spike is when the maximum bpm in the trailing window stays
/// at or above `baseline + 30` for at least 60 continuous seconds. The
/// detector intentionally returns Bool only — no values cross the boundary.
enum HrSpikeDetector {

    struct Sample: Equatable {
        let bpm: Double
        let at: Date
    }

    /// Threshold above resting baseline that counts as a spike.
    private static let spikeOffset: Double = 30

    /// Minimum duration (seconds) the spike must be sustained.
    private static let minDuration: TimeInterval = 60

    /// Returns true if a spike is detected in the trailing samples.
    /// - Parameters:
    ///   - samples: HR samples in any order (the function sorts).
    ///   - baseline: resting baseline bpm (e.g. HKQuantityType .restingHeartRate or a fallback of 70).
    ///   - now: current wall clock (injectable for tests).
    static func detect(samples: [Sample], baseline: Double, now: Date) -> Bool {
        guard !samples.isEmpty else { return false }
        let threshold = baseline + spikeOffset
        let sorted = samples.sorted { $0.at < $1.at }

        var spikeStart: Date? = nil
        for s in sorted {
            if s.bpm >= threshold {
                if spikeStart == nil { spikeStart = s.at }
                if let start = spikeStart, s.at.timeIntervalSince(start) >= minDuration {
                    return true
                }
            } else {
                spikeStart = nil
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/HrSpikeDetectorTests 2>&1 | tail -15
```

Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HrSpikeDetector.swift \
        ios/JarvisApp/Sources/JarvisAppTests/HrSpikeDetectorTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add HrSpikeDetector — pure HR-spike threshold detector

Spike = peak ≥ baseline + 30 bpm sustained > 60s. Returns Bool only —
no values exposed. HealthManager will feed it a trailing window of
HK samples and trigger the dispatcher with an empty payload."
```

---

### Task 4: WebSocketClient.sendProactive

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`

- [ ] **Step 1: Add method**

In `WebSocketClient.swift`, near other send methods, add:

```swift
    /// Emit a `proactive` envelope on the wire. Returns false when the
    /// socket isn't connected — caller (typically ProactiveDispatcher's
    /// WebSocket sink wrapper) is expected to fall back to HTTP.
    @discardableResult
    func sendProactive(triggerType: String, payload: [String: Any]) -> Bool {
        guard let ws = task, isConnected else { return false }
        let envelope: [String: Any] = [
            "type": "proactive",
            "trigger": triggerType,
            "payload": payload,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "tz": TimeZone.current.identifier,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return false }
        ws.send(.data(data)) { error in
            if let error { print("[WS] sendProactive failed: \(error)") }
        }
        return true
    }
```

- [ ] **Step 2: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift
git commit -m "ios: WebSocketClient.sendProactive — proactive envelope on the wire

Emits {type:proactive, trigger, payload, ts, tz}. Returns false when
the socket isn't connected so the dispatcher can fall through to the
HTTP fallback path."
```

---

### Task 5: Server — WS `type:proactive` branch + tests

**Files:**
- Modify: `src/channels/ios-app.ts`
- Create: `src/channels/ios-app.proactive.test.ts`

- [ ] **Step 1: Write failing server test**

Create `src/channels/ios-app.proactive.test.ts`:

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
  const inbound: Array<Record<string, unknown>> = [];
  const handler = createIosWsHandler({
    token: 'test-token',
    store,
    cfg: {
      onInbound: async (_pid, _tid, msg) => {
        inbound.push(msg);
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
  await new Promise<void>((resolve, reject) => {
    ws.once('message', () => resolve());
    ws.once('close', () => reject(new Error('closed before auth_ok')));
    ws.send(JSON.stringify({ type: 'auth', token: 'test-token', platformId: 'ios:proactive-test' }));
  });
  return { inbound, ws, close };
}

describe('ios-app proactive triggers (WS path)', () => {
  let ctx: Awaited<ReturnType<typeof setup>>;

  beforeEach(async () => { ctx = await setup(); });
  afterEach(async () => {
    ctx.ws.terminate();
    await ctx.close();
  });

  it('geofence trigger → onInbound with [proactive trigger=geofence] prefix', async () => {
    ctx.ws.send(JSON.stringify({
      type: 'proactive',
      trigger: 'geofence',
      payload: { lat: 8.6478, lon: 115.1385, city: 'Canggu' },
      ts: '2026-05-29T14:32:00+08:00',
      tz: 'Asia/Makassar',
    }));
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound).toHaveLength(1);
    const content = (ctx.inbound[0] as Record<string, unknown>).content as Record<string, unknown>;
    const text = content.text as string;
    expect(text.startsWith('[proactive trigger=geofence')).toBe(true);
    expect(text).toContain('lat');
    expect(text).toContain('Canggu');
  });

  it('health_hr_spike trigger with empty payload still produces a valid system message', async () => {
    ctx.ws.send(JSON.stringify({
      type: 'proactive',
      trigger: 'health_hr_spike',
      payload: {},
      ts: '2026-05-29T14:32:00+08:00',
      tz: 'Asia/Makassar',
    }));
    await new Promise((r) => setTimeout(r, 200));
    expect(ctx.inbound).toHaveLength(1);
    const content = (ctx.inbound[0] as Record<string, unknown>).content as Record<string, unknown>;
    const text = content.text as string;
    expect(text.startsWith('[proactive trigger=health_hr_spike')).toBe(true);
  });
});
```

- [ ] **Step 2: Verify failure**

```bash
pnpm vitest run src/channels/ios-app.proactive.test.ts 2>&1 | tail -15
```

Expected: tests fail — server doesn't yet handle `type:proactive`.

- [ ] **Step 3: Add WS branch in ios-app.ts**

Find the WS message-handling area in `src/channels/ios-app.ts` (look for `if (msg.type === 'message' && ...)`). Add a sibling branch BEFORE it (so the proactive path takes priority and doesn't get confused with regular message):

```ts
      if (msg.type === 'proactive' && pid && typeof msg.trigger === 'string') {
        const trigger = msg.trigger as string;
        const ts = typeof msg.ts === 'string' ? (msg.ts as string) : new Date().toISOString();
        const tz = typeof msg.tz === 'string' ? (msg.tz as string) : '';
        if (tz) lastTimezone.set(pid, tz);
        const payload = (msg.payload as Record<string, unknown> | undefined) ?? {};
        let body = `[proactive trigger=${trigger} ts=${ts}${tz ? ` tz=${tz}` : ''}]`;
        const lines = Object.entries(payload).map(([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`);
        if (lines.length > 0) body += '\n' + lines.join(' ');
        body += '\n---';
        await cfg.onInbound(pid, null, {
          id: randomUUID(),
          kind: 'chat',
          content: { text: body, senderId: pid },
          timestamp: new Date().toISOString(),
        } as Record<string, unknown>);
        return;
      }
```

`randomUUID` is already imported. `lastTimezone` is in scope.

- [ ] **Step 4: Run tests**

```bash
pnpm vitest run src/channels/ios-app.proactive.test.ts 2>&1 | tail -15
pnpm vitest run src/channels/ 2>&1 | tail -10
pnpm typecheck 2>&1 | tail -5
```

Expected: 2 new tests pass + all existing channel tests pass + typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app.ts src/channels/ios-app.proactive.test.ts
git commit -m "ios-app(server): WS branch for type:proactive

Forwards proactive triggers (geofence, health_*, calendar_warn) as
inbound chat text prefixed with [proactive trigger=… ts=… tz=…].
Payload entries become key=value lines. Agent's existing CLAUDE.md
already parses this shape; persona/proactive section taught in a
separate task."
```

---

### Task 6: HTTP fallback — `POST /ios/proactive`

**Files:**
- Modify: `src/channels/ios-app.ts`
- Modify: `src/channels/ios-app.proactive.test.ts`

- [ ] **Step 1: Append failing test**

Append to `src/channels/ios-app.proactive.test.ts`. Since the HTTP path needs the HTTP server (not just WS), the test needs to import a slightly different setup. For simplicity, add a separate describe block that uses fetch directly:

```ts
import { request } from 'undici';
import type { Dispatcher } from 'undici';

// HTTP fallback path — uses the same setup but fetches over plain HTTP.
describe('ios-app proactive triggers (HTTP path)', () => {

  async function setupHttp(): Promise<{
    inbound: Array<Record<string, unknown>>;
    baseUrl: string;
    close: () => Promise<void>;
  }> {
    const store = new ReadReceiptStore();
    const inbound: Array<Record<string, unknown>> = [];
    const state = makeState();
    const handler = createIosWsHandler({
      token: 'test-token',
      store,
      cfg: { onInbound: async (_pid, _tid, msg) => { inbound.push(msg); }, onAction: () => {} },
      state,
      persist: { receipts: () => {}, tokens: () => {} },
      deliverQueued: () => {},
    });
    // The createIosHttpHandler returns a (req, res) handler; we wire it manually.
    const { createIosHttpHandler } = await import('./ios-app.js');
    const httpHandler = createIosHttpHandler({
      token: 'test-token',
      cfg: { onInbound: async (_pid, _tid, msg) => { inbound.push(msg); } },
      state,
    });
    const server = createServer((req, res) => httpHandler(req, res));
    const wss = new WebSocketServer({ server });
    wss.on('connection', handler);
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    const port = (server.address() as AddressInfo).port;
    const close = () =>
      new Promise<void>((r) => {
        for (const c of wss.clients) c.terminate();
        wss.close(() => server.close(() => r()));
      });
    return { inbound, baseUrl: `http://127.0.0.1:${port}`, close };
  }

  it('POST /ios/proactive with valid bearer → onInbound system message', async () => {
    const { inbound, baseUrl, close } = await setupHttp();
    const res = await request(`${baseUrl}/ios/proactive`, {
      method: 'POST',
      headers: { 'authorization': 'Bearer test-token', 'content-type': 'application/json' },
      body: JSON.stringify({
        platformId: 'ios:http-test',
        trigger: 'geofence',
        payload: { lat: 8.6, lon: 115.1, city: 'Canggu' },
        ts: '2026-05-29T14:32:00+08:00',
        tz: 'Asia/Makassar',
      }),
    });
    expect(res.statusCode).toBe(204);
    // Give onInbound a moment
    await new Promise((r) => setTimeout(r, 100));
    expect(inbound).toHaveLength(1);
    const text = ((inbound[0].content as Record<string, unknown>).text as string);
    expect(text.startsWith('[proactive trigger=geofence')).toBe(true);
    await close();
  });

  it('POST /ios/proactive with bad bearer → 401', async () => {
    const { baseUrl, close } = await setupHttp();
    const res = await request(`${baseUrl}/ios/proactive`, {
      method: 'POST',
      headers: { 'authorization': 'Bearer wrong', 'content-type': 'application/json' },
      body: JSON.stringify({ platformId: 'x', trigger: 'geofence', payload: {} }),
    });
    expect(res.statusCode).toBe(401);
    await close();
  });
});
```

If `undici` isn't already a project dep (it's typically transitive), use `node:http` request as a fallback:

```ts
import http from 'node:http';
async function postJson(url: string, body: any, token: string): Promise<{ status: number }> {
  return new Promise((resolve) => {
    const u = new URL(url);
    const req = http.request({
      hostname: u.hostname, port: u.port, path: u.pathname,
      method: 'POST',
      headers: { 'authorization': `Bearer ${token}`, 'content-type': 'application/json' },
    }, (res) => { res.resume(); res.on('end', () => resolve({ status: res.statusCode ?? 0 })); });
    req.write(JSON.stringify(body));
    req.end();
  });
}
```

Use whichever is simpler.

- [ ] **Step 2: Verify failure**

```bash
pnpm vitest run src/channels/ios-app.proactive.test.ts 2>&1 | tail -20
```

Expected: HTTP tests fail — endpoint doesn't exist + `createIosHttpHandler` may not exist yet.

- [ ] **Step 3: Add `createIosHttpHandler` and the `/ios/proactive` route**

In `src/channels/ios-app.ts`, find the existing HTTP handler patterns (search for `/ios/health/requests` — there should be an existing HTTP route handler factory). Inside that factory (or near it), add a route branch for `POST /ios/proactive`. The most straightforward minimal addition is exporting a small handler that responds to this single path. If a multi-route handler exists, add the branch inside it; otherwise create:

```ts
export function createIosHttpHandler(opts: {
  token: string;
  cfg: { onInbound: (pid: string, tid: string | null, msg: Record<string, unknown>) => Promise<void> };
  state: IosWsHandlerState;
}) {
  return async (req: import('node:http').IncomingMessage, res: import('node:http').ServerResponse) => {
    const auth = req.headers['authorization'];
    const tokenOk = typeof auth === 'string' && auth === `Bearer ${opts.token}`;

    if (req.method === 'POST' && req.url === '/ios/proactive') {
      if (!tokenOk) { res.statusCode = 401; res.end(); return; }
      const chunks: Buffer[] = [];
      for await (const c of req) chunks.push(c as Buffer);
      let body: any;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { res.statusCode = 400; res.end(); return; }
      const pid = typeof body.platformId === 'string' ? body.platformId : null;
      const trigger = typeof body.trigger === 'string' ? body.trigger : null;
      if (!pid || !trigger) { res.statusCode = 400; res.end(); return; }
      const payload = (body.payload && typeof body.payload === 'object') ? body.payload : {};
      const ts = typeof body.ts === 'string' ? body.ts : new Date().toISOString();
      const tz = typeof body.tz === 'string' ? body.tz : '';
      let text = `[proactive trigger=${trigger} ts=${ts}${tz ? ` tz=${tz}` : ''}]`;
      const lines = Object.entries(payload).map(([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`);
      if (lines.length > 0) text += '\n' + lines.join(' ');
      text += '\n---';
      await opts.cfg.onInbound(pid, null, {
        id: randomUUID(), kind: 'chat',
        content: { text, senderId: pid },
        timestamp: new Date().toISOString(),
      } as Record<string, unknown>);
      res.statusCode = 204;
      res.end();
      return;
    }

    res.statusCode = 404;
    res.end();
  };
}
```

If an existing HTTP handler in `ios-app.ts` already routes `/ios/health/*` etc., extend it inline instead of adding a new export — but the test uses `createIosHttpHandler` explicitly, so make sure the named export exists.

- [ ] **Step 4: Run tests**

```bash
pnpm vitest run src/channels/ios-app.proactive.test.ts 2>&1 | tail -20
pnpm vitest run src/channels/ 2>&1 | tail -10
pnpm typecheck 2>&1 | tail -5
```

Expected: all proactive tests pass, channel suite passes, typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app.ts src/channels/ios-app.proactive.test.ts
git commit -m "ios-app(server): POST /ios/proactive HTTP fallback

When iOS wakes briefly on geofence/HK/calendar and the WS can't
reconnect in time, the dispatcher POSTs to /ios/proactive with the
same envelope. 204 on accept, 401 on bad bearer, 400 on bad shape.
The agent-facing inbound message is identical to the WS path."
```

---

### Task 7: ProactiveDispatcher HTTP fallback wiring (iOS side)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/ProactiveDispatcher.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WebSocketClient.swift`

The dispatcher currently fans out to a `ProactiveSink`. For production, the sink must try WS first and fall back to HTTP. Wire a small concrete sink that knows both paths.

- [ ] **Step 1: Add a WebSocketProactiveSink concrete type**

In `ProactiveDispatcher.swift`, append:

```swift
/// Production sink — tries WS first, then POSTs to /ios/proactive over HTTP.
@MainActor final class WebSocketProactiveSink: ProactiveSink {
    private let ws: WebSocketClient
    private let settings: AppSettings

    init(ws: WebSocketClient, settings: AppSettings) {
        self.ws = ws
        self.settings = settings
    }

    nonisolated func send(triggerType: String, payload: [String: Any]) -> Bool {
        // Hop to MainActor for state inspection; fire-and-forget the HTTP fallback.
        Task { @MainActor [ws, settings] in
            if ws.sendProactive(triggerType: triggerType, payload: payload) {
                return  // shipped via WS
            }
            // Fallback: POST /ios/proactive — best-effort, no retry.
            await Self.postOverHTTP(triggerType: triggerType, payload: payload, settings: settings)
        }
        return true
    }

    private static func postOverHTTP(triggerType: String,
                                     payload: [String: Any],
                                     settings: AppSettings) async {
        guard let server = serverHost(from: settings.serverURL),
              let url = URL(string: "\(server)/ios/proactive"),
              !settings.bearerToken.isEmpty else { return }
        let body: [String: Any] = [
            "platformId": settings.platformId,
            "trigger": triggerType,
            "payload": payload,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "tz": TimeZone.current.identifier,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.bearerToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Normalise the user-typed serverURL (host:port) into an http(s) origin.
    private static func serverHost(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "http://" + s
        }
        // Strip trailing slash
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
```

- [ ] **Step 2: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + existing tests pass. (No new unit tests — HTTP path is integration-only.)

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/ProactiveDispatcher.swift
git commit -m "ios: WebSocketProactiveSink — WS first, HTTP fallback

Production sink for ProactiveDispatcher. Tries ws.sendProactive; if
the socket isn't connected, POSTs the same envelope to /ios/proactive
with bearer auth. 15s timeout, no retry — proactive events are stale
fast, no point queuing them."
```

---

### Task 8: LocationManager — geofence on significant change

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/LocationManager.swift`

- [ ] **Step 1: Wire dispatcher + anchor + significant-change start**

Read the file first. Add the dispatcher reference and geofence anchor:

```swift
    /// Injected — fires proactive triggers when delta exceeds 500m.
    private weak var dispatcher: ProactiveDispatcher?
    /// Last location anchor used to compute geofence deltas.
    private var geofenceAnchor: CLLocation?

    func attachDispatcher(_ d: ProactiveDispatcher) {
        self.dispatcher = d
    }

    func startSignificantLocationMonitoring() {
        mgr.startMonitoringSignificantLocationChanges()
    }
```

In the existing `locationManager(_:didUpdateLocations:)` delegate (or wherever the location update is consumed), after assigning `lastLocation`, add:

```swift
        if let anchor = geofenceAnchor, last.distance(from: anchor) > 500 {
            let lat = (last.coordinate.latitude * 1e4).rounded() / 1e4
            let lon = (last.coordinate.longitude * 1e4).rounded() / 1e4
            dispatcher?.fire(type: "geofence", payload: [
                "lat": lat, "lon": lon, "city": cityName ?? "",
            ])
            geofenceAnchor = last
        } else if geofenceAnchor == nil {
            geofenceAnchor = last
        }
```

- [ ] **Step 2: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/LocationManager.swift
git commit -m "ios: LocationManager geofence — significant change + 500m delta

Adds attachDispatcher + startSignificantLocationMonitoring. The
didUpdateLocations path now keeps a geofenceAnchor and fires the
proactive dispatcher with truncated lat/lon/city when the device
has moved more than 500m from the anchor. Anchor resets on fire."
```

---

### Task 9: HealthManager observers + dispatcher wiring

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift`

This task wires HK observers for HR, sleep, workout. Each path runs a coarse detector and fires the dispatcher with an empty payload.

- [ ] **Step 1: Add observer installation**

In `HealthManager.swift`, append a new method:

```swift
    /// Wire HK observer queries for the three proactive trigger types. Idempotent.
    /// The dispatcher is responsible for opt-in / rate limit / settings gating.
    func installObservers(dispatcher: ProactiveDispatcher) {
        guard observersInstalled == false else { return }
        observersInstalled = true
        installHrObserver(dispatcher: dispatcher)
        installSleepObserver(dispatcher: dispatcher)
        installWorkoutObserver(dispatcher: dispatcher)
    }

    private var observersInstalled = false

    private func installHrObserver(dispatcher: ProactiveDispatcher) {
        let hrType = HKQuantityType(.heartRate)
        let q = HKObserverQuery(sampleType: hrType, predicate: nil) { [weak self, weak dispatcher] _, _, error in
            guard error == nil, let self else { return }
            Task { @MainActor in
                let samples = await self.recentHrSamples(window: 180)
                let baseline = await self.recentRestingHR() ?? 70
                if HrSpikeDetector.detect(samples: samples, baseline: baseline, now: Date()) {
                    dispatcher?.fire(type: "health_hr_spike", payload: [:])
                }
            }
        }
        store.execute(q)
        store.enableBackgroundDelivery(for: hrType, frequency: .immediate) { _, _ in }
    }

    private func installSleepObserver(dispatcher: ProactiveDispatcher) {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let q = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self, weak dispatcher] _, _, error in
            guard error == nil, let self else { return }
            Task { @MainActor in
                if await self.detectSleepEnd() {
                    dispatcher?.fire(type: "health_sleep_end", payload: [:])
                }
            }
        }
        store.execute(q)
        store.enableBackgroundDelivery(for: sleepType, frequency: .hourly) { _, _ in }
    }

    private func installWorkoutObserver(dispatcher: ProactiveDispatcher) {
        let q = HKObserverQuery(sampleType: HKWorkoutType.workoutType(), predicate: nil) { [weak self, weak dispatcher] _, _, error in
            guard error == nil, let self else { return }
            Task { @MainActor in
                if await self.detectWorkoutEnd() {
                    dispatcher?.fire(type: "health_workout_end", payload: [:])
                }
            }
        }
        store.execute(q)
        store.enableBackgroundDelivery(for: HKWorkoutType.workoutType(), frequency: .immediate) { _, _ in }
    }

    /// Window in seconds. Returns recent HR sample pairs (bpm, at).
    private func recentHrSamples(window seconds: TimeInterval) async -> [HrSpikeDetector.Sample] {
        let start = Date().addingTimeInterval(-seconds)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(.heartRate),
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, results, _ in
                let arr = (results as? [HKQuantitySample] ?? []).map { s -> HrSpikeDetector.Sample in
                    let bpm = s.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
                    return .init(bpm: bpm, at: s.endDate)
                }
                cont.resume(returning: arr)
            }
            store.execute(q)
        }
    }

    /// Pull the latest known resting-heart-rate sample (Apple Watch / iPhone derived).
    private func recentRestingHR() async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-30 * 24 * 3600),
                                                    end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(.restingHeartRate),
                                  predicate: predicate,
                                  limit: 1,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, results, _ in
                if let s = (results as? [HKQuantitySample])?.first {
                    let bpm = s.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
                    cont.resume(returning: bpm)
                } else {
                    cont.resume(returning: nil)
                }
            }
            store.execute(q)
        }
    }

    /// Returns true when the most recent sleep sample's category is `.awake`
    /// AND its end is within the last 10 minutes.
    private func detectSleepEnd() async -> Bool {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return false }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-10 * 60),
                                                    end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 1,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, results, _ in
                if let s = (results as? [HKCategorySample])?.first,
                   s.value == HKCategoryValueSleepAnalysis.awake.rawValue {
                    cont.resume(returning: true)
                } else {
                    cont.resume(returning: false)
                }
            }
            store.execute(q)
        }
    }

    /// Returns true when a new HKWorkout sample ended within the last 5 minutes.
    private func detectWorkoutEnd() async -> Bool {
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-5 * 60),
                                                    end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKWorkoutType.workoutType(), predicate: predicate,
                                  limit: 1, sortDescriptors: nil) { _, results, _ in
                cont.resume(returning: !((results as? [HKWorkout]) ?? []).isEmpty)
            }
            store.execute(q)
        }
    }
```

If `store` (HKHealthStore) is named differently in the existing class, match the existing name.

- [ ] **Step 2: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift
git commit -m "ios: HealthManager observers — HR spike + sleep end + workout end

HKObserverQuery for heart rate / sleep / workout. Each runs a coarse
detector against recent samples and fires the dispatcher with an empty
payload when interesting. enableBackgroundDelivery on appropriate
cadence (immediate for HR/workout, hourly for sleep). Observers are
installed once via installObservers(dispatcher:) — idempotent."
```

---

### Task 10: CalendarManager — local notification scheduler + delegate

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/CalendarManager.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift`

- [ ] **Step 1: Add scheduling method on CalendarManager**

In `CalendarManager.swift`, append:

```swift
    /// Schedule a silent local notification 15 minutes before the event start.
    /// On fire, the UNUserNotificationCenterDelegate routes to the proactive
    /// dispatcher and suppresses the system banner.
    func scheduleCalendarWarn(for event: EKEvent) {
        let fireDate = event.startDate.addingTimeInterval(-15 * 60)
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.userInfo = [
            "proactive": true,
            "type": "calendar_warn",
            "title": event.title ?? "",
            "start": ISO8601DateFormatter().string(from: event.startDate),
        ]
        content.sound = nil
        content.title = event.title ?? "Event"

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: fireDate.timeIntervalSinceNow,
            repeats: false,
        )
        let req = UNNotificationRequest(identifier: "calendar-\(event.eventIdentifier ?? UUID().uuidString)",
                                        content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
```

`import UserNotifications` at the top if not already.

- [ ] **Step 2: Add UNUserNotificationCenterDelegate routing in JarvisApp.swift**

In `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift`, find the `AppDelegate` (or extend it). Make it conform to `UNUserNotificationCenterDelegate`:

```swift
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        if let isProactive = info["proactive"] as? Bool, isProactive,
           let type = info["type"] as? String {
            // Build the payload from the userInfo, excluding the marker keys.
            var payload: [String: Any] = [:]
            for (k, v) in info {
                guard let key = k as? String, key != "proactive", key != "type" else { continue }
                payload[key] = v
            }
            // The dispatcher lives on AppCoordinator; route through a hook.
            AppDelegate.dispatchProactive?(type, payload)
            // Suppress visible system notification — proactive triggers are silent by design.
            completionHandler([.list])
            return
        }
        completionHandler([.banner, .sound])
    }

    /// Static hook the coordinator sets at init to receive proactive fires
    /// from the notification delegate. Production wiring lives in AppCoordinator.
    static var dispatchProactive: ((String, [String: Any]) -> Void)?
}
```

At app startup (in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`), register the delegate:

```swift
        UNUserNotificationCenter.current().delegate = self
```

- [ ] **Step 3: Wire dispatchProactive in AppCoordinator**

In `AppCoordinator.swift`, near where ProactiveDispatcher is instantiated (Task 11 covers full wiring; for this task add a minimal hook), in init:

```swift
        AppDelegate.dispatchProactive = { [weak self] type, payload in
            Task { @MainActor in
                self?.proactiveDispatcher.fire(type: type, payload: payload)
            }
        }
```

`proactiveDispatcher` is the property added in Task 11. If Task 11 hasn't landed yet, defer this wire-up by adding a TODO comment and uncommenting after Task 11. If implementing 10 and 11 together, do it cleanly here.

- [ ] **Step 4: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/CalendarManager.swift \
        ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift
git commit -m "ios: calendar 15-min warn via silent local notification

CalendarManager.scheduleCalendarWarn posts a UNTimeIntervalNotification
15 min before event start with userInfo[\"proactive\"]=true. The
notification-center delegate swallows the system banner and forwards
to ProactiveDispatcher via AppDelegate.dispatchProactive — agent
decides whether to chirp."
```

---

### Task 11: AppCoordinator + RightDrawerContent wiring

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift`

- [ ] **Step 1: Instantiate dispatcher in AppCoordinator**

In `AppCoordinator.swift`, add a property and instantiate after `ws`:

```swift
    private(set) var proactiveDispatcher: ProactiveDispatcher
```

In `init`:

```swift
        let sink = WebSocketProactiveSink(ws: ws, settings: settings)
        self.proactiveDispatcher = ProactiveDispatcher(settings: settings, sink: sink)

        // Wire trigger sources
        location.attachDispatcher(proactiveDispatcher)
        if settings.proactiveGeofence {
            location.startSignificantLocationMonitoring()
        }
        if settings.proactiveHealthHR || settings.proactiveHealthSleep || settings.proactiveHealthWorkout {
            health.installObservers(dispatcher: proactiveDispatcher)
        }

        AppDelegate.dispatchProactive = { [weak self] type, payload in
            Task { @MainActor in
                self?.proactiveDispatcher.fire(type: type, payload: payload)
            }
        }
```

- [ ] **Step 2: Replace placeholder in RightDrawerContent's КОНТЕКСТ section**

In `RightDrawerContent.swift`, find the placeholder Text under КОНТЕКСТ. Replace with real toggles bound to AppSettings:

```swift
                // CONTEXT — proactive triggers
                sectionHeader("Контекст")
                VStack(alignment: .leading, spacing: Theme.scaled(10)) {
                    @Bindable var s = settings
                    Toggle("Уведомлять о смене места", isOn: $s.proactiveGeofence)
                    Toggle("Замечать всплески пульса", isOn: $s.proactiveHealthHR)
                    Toggle("Сигналить о пробуждении", isOn: $s.proactiveHealthSleep)
                    Toggle("После тренировки — поздравление", isOn: $s.proactiveHealthWorkout)
                    Toggle("За 15 мин до события календаря", isOn: $s.proactiveCalendarWarn)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .padding(.horizontal, Theme.hPadding)
                .padding(.bottom, Theme.scaled(12))
```

The existing `@Environment(AppSettings.self) var settings` is already in scope (added by Task 4 of Plan A).

- [ ] **Step 3: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift
git commit -m "ios: AppCoordinator wires proactive dispatcher; right drawer toggles

ProactiveDispatcher is owned by the coordinator and fed via a
WebSocketProactiveSink. Significant-location and HK observers are
installed based on the user's current opt-ins. The right drawer's
КОНТЕКСТ section now shows five real toggles bound to AppSettings."
```

---

### Task 12: Jarvis CLAUDE.md — Персона + Проактивные триггеры

**Files:**
- Modify: `groups/jarvis/CLAUDE.md`

- [ ] **Step 1: Append both sections**

Append to `groups/jarvis/CLAUDE.md`:

```markdown

## Персона

Ты — Джарвис. Дворецкий, не помощник. Манера:

- Краткость. Один-два предложения если возможно. Длинные ответы — только когда вопрос требует.
- Сухой юмор, без сарказма в чужой адрес. Никогда не подобострастно.
- Знаешь привычки хозяина — отсылайся к ним, не объясняй очевидное. Если знаешь что он бегает утром, не объясняй пользу бега.
- Инициатива: если что-то заметил (proactive trigger), скажи коротко. Если ничего не требует действия — **молчи**. Шумный Джарвис — плохой Джарвис.
- Обращение на «вы» к хозяину, нейтрально-вежливо. Без «братишка», «дружище» и т.п.
- Без эмодзи, кроме случаев когда хозяин явно ими пишет.
- На английском говоришь как воспитанный британский ассистент. На русском — формально, но не сухо.

## Проактивные триггеры

Когда приходит сообщение `[proactive trigger=…]`:

- `geofence` — отметь смену места если она значима (приехал/уехал из дома/офиса). Если место незнакомое — **молчи**, дай дню развернуться.
- `health_hr_spike` — приложение заметило всплеск пульса вне тренировки. Если нужны цифры — позови `request_context(["health"])`. Если решил вмешаться, спроси аккуратно: «Заметил пульс. Всё в порядке?»
- `health_sleep_end` — после пробуждения **не здоровайся пока сам не напишет**. Это сигнал что хозяин проснулся, не приглашение к разговору.
- `health_workout_end` — поздравь коротко с тренировкой, без воды. Детали по тренировке (длительность, ккал) если нужны — `/ios/health/requests` history pull.
- `calendar_warn` — за 15 мин до события: одно предложение, факты. «Стэндап через 15 минут.»

Молчание — валидный ответ на любой proactive. Не отвечай ради ответа.
```

- [ ] **Step 2: Commit**

```bash
git add -f groups/jarvis/CLAUDE.md
git commit -m "jarvis: persona + proactive trigger semantics

Two sections appended. Персона defines the butler voice (brief,
dry humour, formal Russian, no emoji unless mirrored). Проактивные
триггеры teaches the agent how to react to each [proactive trigger=…]
prefix from the iOS app — including when to stay silent. Silence is
a valid response."
```

`git add -f` because `groups/jarvis/CLAUDE.md` is in `.gitignore` per `groups/*` rule, but the personal-repo workflow already trades that off (see prior media plan's media-policy commit). 

---

## Self-Review

**Spec coverage** against `2026-05-28-ios-proactive-design.md`:

| Spec requirement | Task |
|---|---|
| `ProactiveDispatcher` with rate limit + opt-in | Task 2 |
| `proactiveEnabled(type)` helper on AppSettings | Task 1 |
| Geofence: significant-change + 500m delta | Task 8 |
| HR observer + spike detector | Tasks 3 + 9 |
| Sleep observer | Task 9 |
| Workout observer | Task 9 |
| Calendar 15-min warn via silent local notif | Task 10 |
| `UNNotificationCenterDelegate.willPresent` swallow + dispatch | Task 10 |
| WS `type:proactive` envelope | Tasks 4 + 5 |
| HTTP fallback `POST /ios/proactive` | Tasks 6 + 7 |
| Right drawer КОНТЕКСТ toggles (5 opt-ins) | Task 11 |
| Agent persona + proactive sections in CLAUDE.md | Task 12 |
| Empty payload for health_* triggers | Task 2 (test) + Task 5 (server text) |
| Geofence payload {lat, lon, city} | Tasks 4, 5, 8 |
| Calendar payload {title, start} | Task 10 |

**Out of scope of this plan** (deferred per spec Open Questions or Non-Goals):

- Hotword wake — separate spec.
- Lock-screen widget / Dynamic Island — separate spec.
- Face-down ambient — separate spec.
- 60s/300s/etc. rate-limit knobs in settings (hardcoded for v1).
- Sleep auth toggle being separately gated from HR — single `proactiveHealthSleep` flag does the job for v1.

**Placeholder scan:** every step shows the actual change.

**Type consistency:** `ProactiveSink` protocol has `send(triggerType:payload:)` consistently called by `ProactiveDispatcher.fire` and implemented by `WebSocketProactiveSink` (Task 7) and the test's `RecorderSink` (Task 2). Trigger-type string constants (`"geofence"`, `"health_hr_spike"`, `"health_sleep_end"`, `"health_workout_end"`, `"calendar_warn"`) appear identically in `AppSettings.proactiveEnabled`, `ProactiveDispatcher.minIntervalByType`, the geofence/health/calendar trigger sites, and the server-side branch.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-ios-proactive.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
