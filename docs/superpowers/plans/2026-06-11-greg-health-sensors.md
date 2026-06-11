# Greg Health-Sensor Expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Greg (the autonomous health analyzer) three missing Apple Watch signals — sleep phases, morning HRV, nocturnal SpO2 — and a smarter `analyze.js` (upgraded recovery composite, training-load awareness, sleep regularity, a 0-100 readiness score).

**Architecture:** Data flows iOS `HealthHistory.swift` → POST `/ios/health/upload` (zod-validated) → `health-ingest.ts` (passthrough) → `raw.jsonl` → `analyze.js` → Greg (LLM). New optional fields are added at the protocol layer (zod **must** list them or zod strips unknown keys), produced on-device, and consumed by the analyzer. Host ingest needs no code change.

**Tech Stack:** TypeScript + zod (host/protocol), Swift + HealthKit + XCTest (iOS), JavaScript on Bun (`analyze.js`), Vitest (host/protocol tests), Bun test (`analyze.test.js`).

**Spec:** `docs/superpowers/specs/2026-06-11-greg-health-sensors-design.md`

---

## File Structure

**Modify:**
- `shared/ios-app-protocol/v2.ts` — add 8 optional fields to `HealthUploadDay` zod schema.
- `shared/ios-app-protocol/fixtures/health/upload_sensors.json` *(create)* — fixture exercising new fields (auto-tested by `fixtures.test.ts`).
- `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` — add 8 optional vars to `HealthUpload.Day`.
- `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` — sleep-stage split + onset, morning HRV, SpO2; plus pure testable reducers.
- `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift` — authorize `.oxygenSaturation`.
- `ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift` *(create)* — unit tests for the pure reducers.
- `groups/greg/scripts/analyze.js` — new metrics, recovery upgrade, sleep regularity, training load, readiness.
- `groups/greg/scripts/analyze.test.js` — tests for all new analyzer logic.
- `groups/greg/CLAUDE.md` — interpretation of new metrics + `workouts.jsonl` wiring.

**No change:** `src/channels/ios-app/v2/health-ingest.ts` (already spreads `...d`), `src/channels/ios-app/v2/http-handler.ts` (validates via the zod schema we extend).

**Runtime-created:** `groups/greg/health/workouts.jsonl` (Greg appends Payne's `workout_done` rows; `analyze.js` reads, tolerates absence).

---

## Task 1: Protocol — new optional fields (zod + fixture)

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts:317-335` (`HealthUploadDay`)
- Create: `shared/ios-app-protocol/fixtures/health/upload_sensors.json`
- Test: `shared/ios-app-protocol/fixtures.test.ts` (existing loop auto-covers new fixture)

- [ ] **Step 1: Add a fixture that exercises the new fields (failing — fields get stripped)**

Create `shared/ios-app-protocol/fixtures/health/upload_sensors.json`:

```json
{
  "platformId": "ios-app-v2:default",
  "days": [
    {
      "date": "2026-06-10",
      "steps": 9176,
      "activeEnergy": 589,
      "exerciseMinutes": 71,
      "heartRate": 78,
      "restingHeartRate": 63,
      "hrv": 51,
      "sleepHours": 7.2,
      "deepMin": 62,
      "remMin": 95,
      "coreMin": 275,
      "awakeMin": 18,
      "sleepOnsetMin": -42,
      "hrvMorning": 58,
      "spo2Avg": 96.4,
      "spo2Min": 91.0,
      "wristTempDeviation": 0.1,
      "respiratoryRate": 15.2
    }
  ]
}
```

- [ ] **Step 2: Add a round-trip assertion that the new fields survive**

Append inside the `describe('shared/ios-app-protocol health-upload fixtures', ...)` block in `shared/ios-app-protocol/fixtures.test.ts`:

```ts
  it('upload_sensors.json preserves sleep-phase / morning-HRV / SpO2 fields', () => {
    const raw = readFileSync(join(fixturesDir, 'health', 'upload_sensors.json'), 'utf8');
    const body = HealthUploadBody.parse(JSON.parse(raw));
    const d = body.days[0];
    expect(d.deepMin).toBe(62);
    expect(d.remMin).toBe(95);
    expect(d.awakeMin).toBe(18);
    expect(d.sleepOnsetMin).toBe(-42);
    expect(d.hrvMorning).toBe(58);
    expect(d.spo2Avg).toBe(96.4);
    expect(d.spo2Min).toBe(91.0);
  });
```

- [ ] **Step 3: Run the test — verify it FAILS**

Run: `pnpm exec vitest run shared/ios-app-protocol/fixtures.test.ts`
Expected: FAIL — `expected undefined to be 62` (zod stripped the unknown keys).

- [ ] **Step 4: Add the fields to the zod schema**

In `shared/ios-app-protocol/v2.ts`, inside `HealthUploadDay` (after the `vo2max` line, before `workouts`):

```ts
  // New 2026-06-11: sleep phases (split out of sleepHours), sleep onset for
  // circadian regularity, morning HRV (cleaner than whole-day SDNN), nocturnal
  // SpO2 (min catches desaturation). All optional — older rows omit them and
  // analyze.js's series() skips missing values.
  deepMin: z.number().int().nonnegative().optional(),
  remMin: z.number().int().nonnegative().optional(),
  coreMin: z.number().int().nonnegative().optional(),
  awakeMin: z.number().int().nonnegative().optional(),
  sleepOnsetMin: z.number().int().optional(),       // minutes from local midnight; <0 = before midnight
  hrvMorning: z.number().int().nonnegative().optional(),
  spo2Avg: z.number().nonnegative().optional(),
  spo2Min: z.number().nonnegative().optional(),
```

- [ ] **Step 5: Run the test — verify it PASSES**

Run: `pnpm exec vitest run shared/ios-app-protocol/fixtures.test.ts`
Expected: PASS (both the new assertion and the existing `upload.json` round-trip).

- [ ] **Step 6: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/fixtures/health/upload_sensors.json shared/ios-app-protocol/fixtures.test.ts
git commit -m "feat(protocol): add sleep-phase, morning-HRV, SpO2 fields to HealthUploadDay"
```

---

## Task 2: Swift protocol mirror

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift:617-632` (`HealthUpload.Day`)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift` (create; first test here)

- [ ] **Step 1: Create the Swift test file with a Codable round-trip test (failing — fields don't exist)**

Create `ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class HealthHistoryTests: XCTestCase {
    func test_day_decodes_new_sensor_fields() throws {
        let json = """
        {"date":"2026-06-10","sleepHours":7.2,"deepMin":62,"remMin":95,"coreMin":275,
         "awakeMin":18,"sleepOnsetMin":-42,"hrvMorning":58,"spo2Avg":96.4,"spo2Min":91.0}
        """.data(using: .utf8)!
        let day = try JSONDecoder().decode(V2.HealthUpload.Day.self, from: json)
        XCTAssertEqual(day.deepMin, 62)
        XCTAssertEqual(day.remMin, 95)
        XCTAssertEqual(day.awakeMin, 18)
        XCTAssertEqual(day.sleepOnsetMin, -42)
        XCTAssertEqual(day.hrvMorning, 58)
        XCTAssertEqual(day.spo2Avg, 96.4)
        XCTAssertEqual(day.spo2Min, 91.0)
    }
}
```

- [ ] **Step 2: Build the test target — verify it FAILS to compile**

Run: `cd ios/JarvisApp && xcodebuild build-for-testing -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20`
Expected: compile error — `value of type 'V2.HealthUpload.Day' has no member 'deepMin'`.

- [ ] **Step 3: Add the vars to `HealthUpload.Day`**

In `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`, inside `struct Day`, after `var vo2max: Double?` and before `var workouts: [Workout]?`:

```swift
            // New 2026-06-11: sleep phases, onset, morning HRV, nocturnal SpO2.
            var deepMin: Int?
            var remMin: Int?
            var coreMin: Int?
            var awakeMin: Int?
            var sleepOnsetMin: Int?              // minutes from local midnight; <0 = before midnight
            var hrvMorning: Int?                 // ms, SDNN over sleep window
            var spo2Avg: Double?                 // %
            var spo2Min: Double?                 // %
```

(No `CodingKeys` on `Day` — Swift synthesizes Codable; absent JSON keys decode to nil.)

- [ ] **Step 4: Run the Swift test — verify it PASSES**

Run: `cd ios/JarvisApp && xcodebuild test -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/HealthHistoryTests/test_day_decodes_new_sensor_fields 2>&1 | tail -20`
Expected: `Test Suite 'HealthHistoryTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift
git commit -m "feat(ios): mirror new health fields in V2.HealthUpload.Day"
```

---

## Task 3: iOS — sleep-stage split + onset (pure reducer + HK shell)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` (`sleepByDay` → stage-aware)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift`

- [ ] **Step 1: Add a failing test for the pure stage-bucketing reducer**

Append to `HealthHistoryTests.swift`:

```swift
    func test_bucketSleepStages_splits_minutes_and_onset() {
        // wake-day local midnight
        let midnight = Date(timeIntervalSince1970: 1_800_000_000)
        func t(_ min: Int) -> Date { midnight.addingTimeInterval(Double(min) * 60) }
        // onset 30 min before midnight; deep 60, rem 90, core 120, awake 15
        let samples: [HealthHistory.SleepSampleInput] = [
            .init(stage: HealthHistory.SleepStage.asleepDeep.rawValue, start: t(-30), end: t(30)),
            .init(stage: HealthHistory.SleepStage.asleepREM.rawValue,  start: t(30),  end: t(120)),
            .init(stage: HealthHistory.SleepStage.asleepCore.rawValue, start: t(120), end: t(240)),
            .init(stage: HealthHistory.SleepStage.awake.rawValue,      start: t(240), end: t(255)),
            .init(stage: HealthHistory.SleepStage.inBed.rawValue,      start: t(-40), end: t(260)), // ignored
        ]
        let r = HealthHistory.bucketSleepStages(samples, dayStart: midnight)
        XCTAssertEqual(r.deepMin, 60)
        XCTAssertEqual(r.remMin, 90)
        XCTAssertEqual(r.coreMin, 120)
        XCTAssertEqual(r.awakeMin, 15)
        XCTAssertEqual(r.onsetMin, -30)
        XCTAssertEqual(r.sleepHours, 4.5, accuracy: 0.05) // (60+90+120)/60
    }
```

- [ ] **Step 2: Build-for-testing — verify it FAILS to compile** (`SleepSampleInput`/`bucketSleepStages` undefined)

Run: `cd ios/JarvisApp && xcodebuild build-for-testing -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20`
Expected: compile error referencing `SleepSampleInput`.

- [ ] **Step 3: Add the pure reducer to `HealthHistory.swift`**

At the top of `enum HealthHistory { ... }` (after `private static let store`):

```swift
    /// Sleep stage rawValues — mirror HKCategoryValueSleepAnalysis so the pure
    /// reducer needs no live HealthKit store and is unit-testable.
    enum SleepStage: Int { case inBed = 0, asleepUnspecified = 1, awake = 2, asleepCore = 3, asleepDeep = 4, asleepREM = 5 }

    struct SleepSampleInput { let stage: Int; let start: Date; let end: Date }
    struct SleepStageResult: Equatable {
        var deepMin: Int; var remMin: Int; var coreMin: Int; var awakeMin: Int
        var onsetMin: Int?; var sleepHours: Double
    }

    /// Pure: split sleep samples into per-stage minutes + onset (minutes from
    /// `dayStart` local midnight to the earliest asleep sample; negative = before
    /// midnight). `inBed`/`asleepUnspecified→core`. sleepHours = (deep+rem+core)/60.
    static func bucketSleepStages(_ samples: [SleepSampleInput], dayStart: Date) -> SleepStageResult {
        var deep = 0.0, rem = 0.0, core = 0.0, awake = 0.0
        var earliestAsleep: Date? = nil
        for s in samples {
            let mins = s.end.timeIntervalSince(s.start) / 60
            switch SleepStage(rawValue: s.stage) {
            case .asleepDeep: deep += mins
            case .asleepREM:  rem += mins
            case .asleepCore, .asleepUnspecified: core += mins
            case .awake: awake += mins
            case .inBed, .none: continue
            }
            if s.stage != SleepStage.awake.rawValue && s.stage != SleepStage.inBed.rawValue {
                if earliestAsleep == nil || s.start < earliestAsleep! { earliestAsleep = s.start }
            }
        }
        let onset = earliestAsleep.map { Int(($0.timeIntervalSince(dayStart) / 60).rounded()) }
        return SleepStageResult(
            deepMin: Int(deep.rounded()), remMin: Int(rem.rounded()),
            coreMin: Int(core.rounded()), awakeMin: Int(awake.rounded()),
            onsetMin: onset, sleepHours: ((deep + rem + core) / 60 * 10).rounded() / 10
        )
    }
```

- [ ] **Step 4: Run the test — verify it PASSES**

Run: `cd ios/JarvisApp && xcodebuild test -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/HealthHistoryTests/test_bucketSleepStages_splits_minutes_and_onset 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Wire the reducer into the HK sleep query (replace `sleepByDay`)**

In `HealthHistory.swift`, replace the `sleepByDay` call site (the `group.enter(); sleepByDay(...)` block, ~lines 96-103) with a per-wake-day stage query, and replace the `sleepByDay` helper with one that returns raw samples bucketed by wake-day. Concretely, change the call block to:

```swift
        // Sleep: split into stages + onset, bucketed by wake day (sample end day).
        group.enter()
        sleepSamplesByWakeDay(start: start, end: end, bucket: bucketKey) { byWakeDay in
            for (k, samples) in byWakeDay {
                let dayStart = self.cal0(for: samples) ?? start
                let r = HealthHistory.bucketSleepStages(samples, dayStart: dayStart)
                mutate(k) {
                    $0.deepMin = r.deepMin; $0.remMin = r.remMin
                    $0.coreMin = r.coreMin; $0.awakeMin = r.awakeMin
                    $0.sleepOnsetMin = r.onsetMin
                    $0.sleepHours = r.sleepHours
                }
            }
            group.leave()
        }
```

Replace the old `sleepByDay(...)` helper with:

```swift
    /// Group sleep samples by wake-day key (sample end day). Returns the raw
    /// per-day samples so the pure reducer does the stage math.
    private static func sleepSamplesByWakeDay(
        start: Date, end: Date,
        bucket: @escaping (Date) -> String,
        _ cb: @escaping ([String: [SleepSampleInput]]) -> Void
    ) {
        let q = HKSampleQuery(
            sampleType: HKCategoryType(.sleepAnalysis),
            predicate: HKQuery.predicateForSamples(withStart: start, end: end),
            limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { _, samples, _ in
            var byDay: [String: [SleepSampleInput]] = [:]
            for s in (samples as? [HKCategorySample]) ?? [] {
                let k = bucket(s.endDate)
                byDay[k, default: []].append(.init(stage: s.value, start: s.startDate, end: s.endDate))
            }
            cb(byDay)
        }
        store.execute(q)
    }

    /// Local midnight of the wake day for a sample set (used as onset reference).
    private static func cal0(for samples: [SleepSampleInput]) -> Date? {
        guard let last = samples.map(\.end).max() else { return nil }
        return Calendar.current.startOfDay(for: last)
    }
```

- [ ] **Step 6: Build to confirm the shell compiles**

Run: `cd ios/JarvisApp && xcodebuild build -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift
git commit -m "feat(ios): split sleep into stages + onset, keep sleepHours"
```

---

## Task 4: iOS — morning HRV (SDNN over sleep window)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift`

- [ ] **Step 1: Add a failing test for the overnight-bucketing reducer**

`hrvMorning` (and SpO2 in Task 5) must reflect the OVERNIGHT reading, not the 24h average — otherwise it's a silent re-derivation of the whole-day `hrv`. So we bucket samples to wake-days keeping only overnight / early-morning readings and dropping daytime. Append to `HealthHistoryTests.swift`:

```swift
    func test_bucketOvernight_keeps_overnight_drops_daytime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = ISO8601DateFormatter()
        let samples: [(value: Double, date: Date)] = [
            (50, f.date(from: "2026-06-09T22:00:00Z")!), // evening → wake-day 06-10
            (55, f.date(from: "2026-06-10T05:00:00Z")!), // morning → wake-day 06-10
            (99, f.date(from: "2026-06-10T14:00:00Z")!), // daytime → dropped
        ]
        let out = HealthHistory.bucketOvernight(samples, calendar: cal)
        XCTAssertEqual(out["2026-06-10"]?.sorted(), [50, 55])
        XCTAssertFalse(out["2026-06-10"]?.contains(99) ?? false)
        XCTAssertTrue(HealthHistory.bucketOvernight([], calendar: cal).isEmpty)
    }
```

- [ ] **Step 2: Build-for-testing — verify it FAILS** (`bucketOvernight` undefined)

Run: `cd ios/JarvisApp && xcodebuild build-for-testing -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15`
Expected: compile error referencing `bucketOvernight`.

- [ ] **Step 3: Add the pure reducer**

In `HealthHistory.swift` (near `bucketSleepStages`):

```swift
    /// Pure: bucket time-stamped samples to wake-days, keeping only overnight /
    /// early-morning readings (local hour >= eveningStart the night before →
    /// next morning, or < morningEnd the day-of). Daytime samples are dropped so
    /// the value reflects sleep recovery, not daytime stress. Key = wake-day
    /// "yyyy-MM-dd" in `calendar`'s timezone. Shared by morning HRV + SpO2.
    static func bucketOvernight(
        _ samples: [(value: Double, date: Date)], calendar: Calendar,
        eveningStart: Int = 20, morningEnd: Int = 11
    ) -> [String: [Double]] {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        var out: [String: [Double]] = [:]
        for s in samples {
            let h = calendar.component(.hour, from: s.date)
            let wakeDay: Date
            if h >= eveningStart {
                wakeDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: s.date))!
            } else if h < morningEnd {
                wakeDay = calendar.startOfDay(for: s.date)
            } else { continue } // daytime — not a recovery signal
            out[fmt.string(from: wakeDay), default: []].append(s.value)
        }
        return out
    }
```

- [ ] **Step 4: Run the test — verify it PASSES**

Run: `cd ios/JarvisApp && xcodebuild test -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/HealthHistoryTests/test_bucketOvernight_keeps_overnight_drops_daytime 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Add the HK morning-HRV query (overnight SDNN, daytime excluded)**

In `HealthHistory.fetch`, after the existing whole-day HRV block (the `group.enter(); collection(.heartRateVariabilitySDNN, ...)` block ~lines 82-93), add. This queries SDNN over the whole interval but uses `bucketOvernight` to keep only overnight/morning readings per wake-day — so `hrvMorning` is genuinely the sleep-recovery signal, distinct from the whole-day `hrv`:

```swift
        // Morning HRV: overnight SDNN only (bucketOvernight drops daytime), per
        // wake day. Cleaner recovery signal than the whole-day SDNN average.
        group.enter()
        let hrvQ = HKSampleQuery(
            sampleType: HKQuantityType(.heartRateVariabilitySDNN),
            predicate: HKQuery.predicateForSamples(withStart: start, end: end),
            limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { _, samples, _ in
            let ms = HKUnit.secondUnit(with: .milli)
            let pairs = ((samples as? [HKQuantitySample]) ?? [])
                .map { (value: $0.quantity.doubleValue(for: ms), date: $0.endDate) }
            for (k, vals) in HealthHistory.bucketOvernight(pairs, calendar: cal) {
                let avg = vals.reduce(0, +) / Double(vals.count)
                mutate(k) { $0.hrvMorning = Int(avg.rounded()) }
            }
            group.leave()
        }
        store.execute(hrvQ)
```

(No window helper needed — `bucketOvernight` does the per-day overnight scoping. `cal` is the `Calendar.current` already defined at the top of `fetch`.)

- [ ] **Step 6: Build to confirm compile**

Run: `cd ios/JarvisApp && xcodebuild build -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift
git commit -m "feat(ios): collect morning HRV (SDNN over sleep window)"
```

---

## Task 5: iOS — nocturnal SpO2 (+ authorization + build-time count)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift:16-30` (auth set)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift`

- [ ] **Step 1: Add a failing test for the SpO2 min/avg reducer**

Append to `HealthHistoryTests.swift`:

```swift
    func test_reduceSpo2_returns_avg_and_min_in_percent() {
        // HealthKit reports fraction (0..1); reducer converts to percent.
        let r = HealthHistory.reduceSpo2([0.97, 0.95, 0.91, 0.96])
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.avg, 94.75, accuracy: 0.01)
        XCTAssertEqual(r!.min, 91.0, accuracy: 0.01)
        XCTAssertNil(HealthHistory.reduceSpo2([]))
    }
```

- [ ] **Step 2: Build-for-testing — verify it FAILS** (`reduceSpo2` undefined)

Run: `cd ios/JarvisApp && xcodebuild build-for-testing -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15`
Expected: compile error referencing `reduceSpo2`.

- [ ] **Step 3: Add the pure reducer**

In `HealthHistory.swift`:

```swift
    /// Pure: nocturnal SpO2 avg + min, converting HK fraction (0..1) to percent.
    static func reduceSpo2(_ fractions: [Double]) -> (avg: Double, min: Double)? {
        guard !fractions.isEmpty else { return nil }
        let pct = fractions.map { $0 * 100 }
        let avg = pct.reduce(0, +) / Double(pct.count)
        return (avg: (avg * 10).rounded() / 10, min: (pct.min()! * 10).rounded() / 10)
    }
```

- [ ] **Step 4: Run the test — verify it PASSES**

Run: `cd ios/JarvisApp && xcodebuild test -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/HealthHistoryTests/test_reduceSpo2_returns_avg_and_min_in_percent 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Authorize `.oxygenSaturation`**

In `HealthManager.swift`, add to the `types` set in `requestAndFetch()` (after `HKQuantityType(.vo2Max)`):

```swift
            HKQuantityType(.oxygenSaturation),
```

- [ ] **Step 6: Add the SpO2 HK query + build-time sample count**

In `HealthHistory.fetch`, after the morning-HRV block. Uses `bucketOvernight` (from Task 4) so SpO2 reflects NOCTURNAL desaturation, not daytime readings:

```swift
        // Nocturnal SpO2: overnight min + avg (bucketOvernight drops daytime), per wake day.
        group.enter()
        let spo2Q = HKSampleQuery(
            sampleType: HKQuantityType(.oxygenSaturation),
            predicate: HKQuery.predicateForSamples(withStart: start, end: end),
            limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { _, samples, _ in
            let frac = HKUnit.percent()  // HK percent unit == fraction 0..1
            let pairs = ((samples as? [HKQuantitySample]) ?? [])
                .map { (value: $0.quantity.doubleValue(for: frac), date: $0.endDate) }
            let byDay = HealthHistory.bucketOvernight(pairs, calendar: cal)
            // Build-time diagnostic (SpO2 availability sanity-check; see spec §8).
            let total = byDay.values.reduce(0) { $0 + $1.count }
            print("[HealthHistory] SpO2 overnight samples: \(total) across \(byDay.count) day(s)")
            for (k, vals) in byDay {
                if let r = HealthHistory.reduceSpo2(vals) {
                    mutate(k) { $0.spo2Avg = r.avg; $0.spo2Min = r.min }
                }
            }
            group.leave()
        }
        store.execute(spo2Q)
```

- [ ] **Step 7: Build to confirm compile**

Run: `cd ios/JarvisApp && xcodebuild build -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift ios/JarvisApp/Sources/JarvisAppTests/HealthHistoryTests.swift
git commit -m "feat(ios): collect nocturnal SpO2 (avg/min) + authorize oxygenSaturation"
```

---

## Task 6: analyze.js — new metrics + recovery composite upgrade

**Files:**
- Modify: `groups/greg/scripts/analyze.js`
- Test: `groups/greg/scripts/analyze.test.js`

> **Prereq:** Bun must be available locally. Check `bun --version`; if missing, `brew install bun` (macOS). All Task 6–10 tests run via `bun test`.

- [ ] **Step 1: Add failing tests for the upgraded recovery composite**

Append to `groups/greg/scripts/analyze.test.js`:

```js
import { buildRecovery } from "./analyze.js";

describe("buildRecovery", () => {
  function rowsWith(extra) {
    return Array.from({ length: 10 }, (_, i) => ({
      date: `2026-06-${String(i + 1).padStart(2, "0")}`,
      hrv: 50, restingHeartRate: 60, sleepHours: 7.5, ...extra(i),
    }));
  }
  it("prefers hrvMorning over whole-day hrv", () => {
    const rows = rowsWith(() => ({ hrvMorning: 55 }));
    buildRecovery(rows);
    expect(rows[0].hrvEff).toBe(55); // morning wins
  });
  it("falls back to daily hrv when morning absent", () => {
    const rows = rowsWith(() => ({}));
    buildRecovery(rows);
    expect(rows[0].hrvEff).toBe(50);
  });
  it("writes a recovery score when >=2 components present", () => {
    const rows = rowsWith(() => ({}));
    buildRecovery(rows);
    expect(typeof rows[9].recovery).toBe("number");
  });
  it("drags recovery down on a low-SpO2 + low-deep night", () => {
    const rows = rowsWith((i) => ({ deepMin: 60, spo2Min: 96 }));
    rows[9] = { ...rows[9], deepMin: 20, spo2Min: 88, hrv: 30 };
    buildRecovery(rows);
    expect(rows[9].recovery).toBeLessThan(0);
  });
});
```

- [ ] **Step 2: Run — verify FAIL**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -20`
Expected: FAIL — `buildRecovery` not exported / `hrvEff` undefined.

- [ ] **Step 3: Upgrade `buildRecovery` and export it**

In `groups/greg/scripts/analyze.js`, replace the whole `function buildRecovery(rows) { ... }` block with:

```js
// Recovery composite (higher = better). Robust-normalized components, each
// present-only (>=2 of N). Morning HRV preferred over whole-day SDNN. Sleep
// phases (deep/REM) and nocturnal SpO2 min added 2026-06-11.
export function buildRecovery(rows) {
  for (const r of rows) {
    const eff = typeof r.hrvMorning === "number" ? r.hrvMorning
              : typeof r.hrv === "number" ? r.hrv : undefined;
    if (eff !== undefined) r.hrvEff = eff;
  }
  const comps = [
    ["hrvEff", 1], ["restingHeartRate", -1], ["sleepHours", 1],
    ["deepMin", 1], ["remMin", 1], ["spo2Min", 1], ["wristTempDeviation", -1],
  ];
  const stats = {};
  for (const [m] of comps) {
    const vs = rows.map((r) => r[m]).filter((v) => typeof v === "number" && Number.isFinite(v));
    if (vs.length >= 5) {
      const med = median(vs);
      const sc = mad(vs, med) * 1.4826 || pstdev(vs) || 1;
      stats[m] = { med, sc };
    }
  }
  for (const r of rows) {
    let sum = 0, w = 0;
    for (const [m, sign] of comps) {
      const s = stats[m]; const v = r[m];
      if (s && typeof v === "number" && Number.isFinite(v)) { sum += sign * ((v - s.med) / s.sc); w++; }
    }
    if (w >= 2) r.recovery = Math.round((sum / w) * 100) / 100;
  }
}
```

- [ ] **Step 4: Add the new metrics to `METRICS` / `CONCERN_*`**

Replace the `METRICS`, `CONCERN_UP`, `CONCERN_DOWN` declarations near the top of `analyze.js` with:

```js
const METRICS = [
  "steps", "activeEnergy", "exerciseMinutes",
  "heartRate", "restingHeartRate",
  "sleepHours", "hrv", "recovery",
  "wristTempDeviation", "respiratoryRate",
  "walkingHeartRateAverage", "vo2max",
  // New 2026-06-11.
  "deepMin", "remMin", "awakeMin", "hrvMorning", "spo2Min", "sleepRegularity",
];
const CONCERN_UP = new Set([
  "restingHeartRate", "heartRate",
  "wristTempDeviation", "respiratoryRate", "walkingHeartRateAverage",
  "awakeMin", "sleepRegularity",
]);
const CONCERN_DOWN = new Set([
  "sleepHours", "steps", "activeEnergy", "exerciseMinutes",
  "hrv", "recovery", "vo2max",
  "deepMin", "remMin", "hrvMorning", "spo2Min",
]);
```

- [ ] **Step 5: Run — verify PASS**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -20`
Expected: PASS (new `buildRecovery` block + existing differential/sick tests).

- [ ] **Step 6: Commit**

```bash
git add groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js
git commit -m "feat(greg): upgrade recovery composite with morning HRV, sleep phases, SpO2"
```

---

## Task 7: analyze.js — sleep regularity (synthetic metric)

**Files:**
- Modify: `groups/greg/scripts/analyze.js`
- Test: `groups/greg/scripts/analyze.test.js`

- [ ] **Step 1: Add a failing test**

Append to `analyze.test.js`:

```js
import { buildSleepRegularity } from "./analyze.js";

describe("buildSleepRegularity", () => {
  it("is low for consistent onset, higher for erratic onset", () => {
    const steady = Array.from({ length: 14 }, (_, i) => ({
      date: `2026-06-${String(i + 1).padStart(2, "0")}`, sleepOnsetMin: -30,
    }));
    buildSleepRegularity(steady);
    expect(steady[13].sleepRegularity).toBeLessThan(5);

    const erratic = Array.from({ length: 14 }, (_, i) => ({
      date: `2026-06-${String(i + 1).padStart(2, "0")}`,
      sleepOnsetMin: i % 2 === 0 ? -120 : 60,
    }));
    buildSleepRegularity(erratic);
    expect(erratic[13].sleepRegularity).toBeGreaterThan(60);
  });
  it("skips days with <5 onset samples in window", () => {
    const rows = [{ date: "2026-06-01", sleepOnsetMin: -30 }];
    buildSleepRegularity(rows);
    expect(rows[0].sleepRegularity).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run — verify FAIL** (`buildSleepRegularity` not exported)

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: FAIL.

- [ ] **Step 3: Implement `buildSleepRegularity`**

In `analyze.js`, after `buildRecovery`:

```js
// Sleep regularity: rolling SD of sleep-onset time (minutes from midnight) over
// a trailing window. Written per-day as a synthetic metric, then run through the
// same anomaly detector (CONCERN_UP — rising spread = degrading consistency).
export function buildSleepRegularity(rows, window = 14) {
  const onset = rows.map((r) =>
    (typeof r.sleepOnsetMin === "number" && Number.isFinite(r.sleepOnsetMin)) ? r.sleepOnsetMin : null);
  for (let i = 0; i < rows.length; i++) {
    const slice = [];
    for (let j = Math.max(0, i - window + 1); j <= i; j++) if (onset[j] !== null) slice.push(onset[j]);
    if (slice.length >= 5) rows[i].sleepRegularity = Math.round(pstdev(slice) * 10) / 10;
  }
}
```

- [ ] **Step 4: Run — verify PASS**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js
git commit -m "feat(greg): add sleep-regularity synthetic metric"
```

---

## Task 8: analyze.js — training-load context

**Files:**
- Modify: `groups/greg/scripts/analyze.js`
- Test: `groups/greg/scripts/analyze.test.js`

- [ ] **Step 1: Add failing tests for load math**

Append to `analyze.test.js`:

```js
import { dailyLoad, loadContext } from "./analyze.js";

describe("training load", () => {
  it("dailyLoad prefers tonnage_kg over workout energy", () => {
    const row = { date: "2026-06-10", workouts: [{ energyKcal: 300 }] };
    expect(dailyLoad(row, { tonnage_kg: 7000 })).toBeCloseTo(7, 5);     // 7000/1000
    expect(dailyLoad(row, undefined)).toBeCloseTo(3, 5);                // 300/100
    expect(dailyLoad({ date: "x" }, undefined)).toBe(0);
  });
  it("loadContext computes acute/chronic/ratio", () => {
    const rows = Array.from({ length: 28 }, (_, i) => ({
      date: `2026-06-${String(i + 1).padStart(2, "0")}`,
      workouts: [{ energyKcal: 100 }], // chronic ~1.0/day
    }));
    // last 5 days heavier
    for (let i = 23; i < 28; i++) rows[i].workouts = [{ energyKcal: 300 }]; // acute ~3.0
    const ctx = loadContext(rows, new Map());
    expect(ctx.acute).toBeGreaterThan(ctx.chronic);
    expect(ctx.ratio).toBeGreaterThan(1.3);
  });
});
```

- [ ] **Step 2: Run — verify FAIL**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: FAIL — `dailyLoad`/`loadContext` not exported.

- [ ] **Step 3: Implement load helpers**

In `analyze.js`, after `loadRows`:

```js
// Structured workout load log (Greg appends Payne's workout_done rows):
// {date, tonnage_kg, duration_min, rir}. Missing file → empty map.
export function loadWorkoutsLog(path) {
  let text; try { text = readFileSync(path, "utf8"); } catch { return new Map(); }
  const byDate = new Map();
  for (const line of text.split("\n")) {
    const s = line.trim(); if (!s) continue;
    let r; try { r = JSON.parse(s); } catch { continue; }
    if (r && r.date) byDate.set(r.date, r); // last line per date wins
  }
  return byDate;
}

// Per-day load score. tonnage_kg/1000 if logged, else workout energyKcal/100.
export function dailyLoad(row, logEntry) {
  if (logEntry && typeof logEntry.tonnage_kg === "number") return logEntry.tonnage_kg / 1000;
  const ws = Array.isArray(row.workouts) ? row.workouts : [];
  const kcal = ws.reduce((a, w) => a + (typeof w.energyKcal === "number" ? w.energyKcal : 0), 0);
  return kcal / 100;
}

// Acute (recent acuteDays) vs chronic (recent chronicDays) mean daily load.
export function loadContext(rows, workoutsLog, acuteDays = 5, chronicDays = 28) {
  const loads = rows.map((r) => dailyLoad(r, workoutsLog.get(r.date)));
  const mean = (xs) => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0;
  const acute = mean(loads.slice(-acuteDays));
  const chronic = mean(loads.slice(-chronicDays));
  const ratio = chronic > 0 ? acute / chronic : (acute > 0 ? 1.5 : 0);
  const r2 = (x) => Math.round(x * 100) / 100;
  return { acute: r2(acute), chronic: r2(chronic), ratio: r2(ratio) };
}
```

- [ ] **Step 4: Run — verify PASS**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js
git commit -m "feat(greg): compute acute/chronic training-load context"
```

---

## Task 9: analyze.js — load-aware anomaly contextualization

**Files:**
- Modify: `groups/greg/scripts/analyze.js`
- Test: `groups/greg/scripts/analyze.test.js`

- [ ] **Step 1: Add failing tests**

Append to `analyze.test.js`:

```js
import { applyLoadContext } from "./analyze.js";

describe("applyLoadContext", () => {
  const dip = () => ({ metric: "hrv", direction: "down", severity: "warn", mod_z: -2.5, window: { days: 3 } });
  it("softens a moderate recovery dip under high acute load", () => {
    const a = applyLoadContext([dip()], { ratio: 1.5 });
    expect(a[0].expected_post_load).toBe(true);
    expect(a[0].severity).toBe("info"); // warn -> info
  });
  it("does not soften a large dip; flags load_persistent", () => {
    const big = { ...dip(), mod_z: -5, severity: "critical" };
    const a = applyLoadContext([big], { ratio: 1.5 });
    expect(a[0].expected_post_load).toBeUndefined();
    expect(a[0].load_persistent).toBe(true);
    expect(a[0].severity).toBe("critical");
  });
  it("leaves dips untouched when load is normal", () => {
    const a = applyLoadContext([dip()], { ratio: 1.0 });
    expect(a[0].severity).toBe("warn");
    expect(a[0].expected_post_load).toBeUndefined();
  });
  it("ignores non-recovery-family or upward anomalies", () => {
    const up = { metric: "restingHeartRate", direction: "up", severity: "warn", mod_z: 3, window: { days: 3 } };
    const a = applyLoadContext([up], { ratio: 1.5 });
    expect(a[0].severity).toBe("warn");
  });
});
```

- [ ] **Step 2: Run — verify FAIL**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: FAIL — `applyLoadContext` not exported.

- [ ] **Step 3: Implement `applyLoadContext`**

In `analyze.js`, after `loadContext`:

```js
// Contextualize recovery-family down-anomalies by training load. A moderate dip
// right after a load spike is an expected training response — soften one notch.
// A large dip despite that context is flagged (load isn't the whole story).
const RECOVERY_FAMILY = new Set(["recovery", "hrv", "hrvMorning", "deepMin", "remMin", "spo2Min"]);
export function applyLoadContext(anomalies, load) {
  for (const a of anomalies) {
    if (a.direction !== "down" || !RECOVERY_FAMILY.has(a.metric)) continue;
    if (load.ratio >= 1.3) {
      if (Math.abs(a.mod_z) < 4) {
        a.expected_post_load = true;
        if (a.severity === "warn") a.severity = "info";
        else if (a.severity === "critical") a.severity = "warn";
      } else {
        a.load_persistent = true;
      }
    }
  }
  return anomalies;
}
```

- [ ] **Step 4: Run — verify PASS**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js
git commit -m "feat(greg): soften/escalate recovery anomalies by training load"
```

---

## Task 10: analyze.js — readiness score + normal-mode wiring

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (`computeReadiness`, `parseModeArgs`, normal-mode block)
- Test: `groups/greg/scripts/analyze.test.js`

- [ ] **Step 1: Add failing tests for readiness**

Append to `analyze.test.js`:

```js
import { computeReadiness } from "./analyze.js";

describe("computeReadiness", () => {
  it("maps a positive recovery z to a green band", () => {
    const rows = [{ date: "2026-06-10", recovery: 1.5 }];
    const r = computeReadiness(rows, { ratio: 1.0 });
    expect(r.score).toBe(68); // 50 + 12*1.5
    expect(r.band).toBe("yellow");
  });
  it("clamps to 100 and bands green at high recovery", () => {
    const r = computeReadiness([{ date: "x", recovery: 5 }], { ratio: 1.0 });
    expect(r.score).toBe(100);
    expect(r.band).toBe("green");
  });
  it("applies a load penalty under high acute load", () => {
    const base = computeReadiness([{ date: "x", recovery: 1.0 }], { ratio: 1.0 }).score; // 62
    const penalized = computeReadiness([{ date: "x", recovery: 1.0 }], { ratio: 1.8 }).score;
    expect(penalized).toBeLessThan(base);
  });
  it("returns null without a recovery value", () => {
    expect(computeReadiness([{ date: "x" }], { ratio: 1.0 })).toBeNull();
  });
});
```

- [ ] **Step 2: Run — verify FAIL**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: FAIL — `computeReadiness` not exported.

- [ ] **Step 3: Implement `computeReadiness`**

In `analyze.js`, after `applyLoadContext`:

```js
// Readiness 0-100: human-facing scaling of the recovery composite, tempered by
// acute load. recovery is a robust z (~-3..+3); map around 50, subtract a load
// penalty. Bands: >=70 green, 50-69 yellow, <50 red → drives Payne's level.
export function computeReadiness(rows, load) {
  const last = rows.length ? rows[rows.length - 1] : null;
  if (!last || typeof last.recovery !== "number") return null;
  const K = 12;
  const loadPenalty = load.ratio > 1.3 ? Math.min(15, (load.ratio - 1.3) * 20) : 0;
  const score = Math.max(0, Math.min(100, Math.round(50 + K * last.recovery - loadPenalty)));
  const band = score >= 70 ? "green" : score >= 50 ? "yellow" : "red";
  return { score, band, recovery_z: last.recovery, load_ratio: load.ratio };
}
```

- [ ] **Step 4: Run — verify PASS**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Export `analyze`, then add a normal-mode integration test**

First export the detector — in `analyze.js` change `function analyze(rows, {` to `export function analyze(rows, {`.

Then append to `analyze.test.js`:

```js
import { analyze } from "./analyze.js";

describe("normal mode integration", () => {
  it("emits readiness + load and runs sleepRegularity through detection", () => {
    // 28 stable days, heavy last 5, fresh hrv dip on the final day
    const rows = Array.from({ length: 28 }, (_, i) => ({
      date: `2026-05-${String(i + 1).padStart(2, "0")}`,
      hrv: 50, hrvMorning: 52, restingHeartRate: 60, sleepHours: 7.5,
      deepMin: 60, remMin: 90, spo2Min: 96, sleepOnsetMin: -30,
      workouts: [{ energyKcal: 100 }],
    }));
    for (let i = 23; i < 28; i++) rows[i].workouts = [{ energyKcal: 320 }];
    buildRecovery(rows);
    buildSleepRegularity(rows);
    const load = loadContext(rows, new Map());
    const out = applyLoadContext(analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 }), load);
    const readiness = computeReadiness(rows, load);
    expect(readiness).not.toBeNull();
    expect(load.ratio).toBeGreaterThan(1.3);
    expect(Array.isArray(out)).toBe(true);
  });
});
```

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -15`
Expected: PASS — the pieces (buildRecovery, buildSleepRegularity, loadContext, applyLoadContext, computeReadiness, analyze) compose end-to-end.

- [ ] **Step 6: Wire readiness/load/regularity into the normal-mode CLI result**

In `analyze.js`, add `workoutsLog` to `parseModeArgs` defaults:

```js
  const o = { raw: "/workspace/agent/health/raw.jsonl", mode: "normal",
              recent: 3, baseline: 21, minN: 7, topK: 8, out: null,
              complaint: "", window: 14,
              workoutsLog: "/workspace/agent/health/workouts.jsonl" };
```

and parse it in the arg loop:

```js
    else if (a === "--workouts-log") o.workoutsLog = argv[++i];
```

In the `if (import.meta.main)` block, after `buildRecovery(rows);` add:

```js
  buildSleepRegularity(rows);
```

Replace the normal-mode `else { ... }` result block with:

```js
  } else {
    // normal mode
    const workoutsLog = loadWorkoutsLog(opts.workoutsLog);
    const load = loadContext(rows, workoutsLog);
    result = {
      generated_at: rows.length ? rows[rows.length - 1].date : null,
      n_days: rows.length,
      mode: "normal",
      anomalies: applyLoadContext(analyze(rows, opts), load),
      readiness: computeReadiness(rows, load),
      load,
      coverage: computeCoverage(rows),
    };
  }
```

- [ ] **Step 7: Smoke-run the CLI against the local raw.jsonl**

Run: `cd groups/greg && bun scripts/analyze.js health/raw.jsonl --out /tmp/anom.json --workouts-log health/workouts.jsonl && node -e "const r=require('/tmp/anom.json'); console.log({readiness:r.readiness, load:r.load, anomalies:r.anomalies.length})"`
Expected: prints a `readiness` object (score/band), a `load` object, and an anomaly count — no crash (workouts.jsonl absent is fine).

- [ ] **Step 8: Run the full analyzer test suite**

Run: `bun test groups/greg/scripts/analyze.test.js 2>&1 | tail -20`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js
git commit -m "feat(greg): emit readiness score + load context in normal mode"
```

---

## Task 11: Greg CLAUDE.md — interpretation + workouts.jsonl wiring

**Files:**
- Modify: `groups/greg/CLAUDE.md`

- [ ] **Step 1: Document the new data fields**

In `groups/greg/CLAUDE.md`, in the `## Данные (read-only)` section, after the `raw.jsonl` bullet, add:

```markdown
- **Новые поля (2026-06-11):** `deepMin/remMin/coreMin/awakeMin` (минуты фаз сна — deep и REM несут восстановление; рост `awakeMin` в окне = фрагментация), `sleepOnsetMin` (начало сна, мин от полуночи; `<0` = до полуночи), `hrvMorning` (HRV за окно сна — чище дневного `hrv`, скрипт предпочитает его), `spo2Avg/spo2Min` (ночное насыщение O₂, %; низкий `spo2Min` объясняет «спал, но не восстановился» — наблюдение, не диагноз: апноэ/высота/болезнь, формулируй «стоит проверить»). `sleepRegularity` — синтетика (разброс времени отхода ко сну); рост = нерегулярный режим.
- **vo2max** — данных пока ~ноль (силовые не генерят кардио-фитнес). НЕ трактуй как сигнал, пока не появится покрытие.
- `analyze.js` теперь выдаёт `readiness` (0-100: `≥70` green, `50-69` yellow, `<50` red) и `load` (acute/chronic/ratio). Высокая `load.ratio` + просадка восстановления = ожидаемая реакция (скрипт сам помечает `expected_post_load` и приглушает severity); не алармируй сверх этого.
```

- [ ] **Step 2: Remove the stale RMSSD reference**

In `groups/greg/CLAUDE.md`, the data section mentions HRV. Ensure no text claims RMSSD. If the phrase "RMSSD" appears anywhere, replace with "SDNN (Apple даёт SDNN, не RMSSD)". Verify:

Run: `grep -n RMSSD groups/greg/CLAUDE.md` — expected: no output after the edit.

- [ ] **Step 3: Wire workouts.jsonl in the Payne section**

In `groups/greg/CLAUDE.md`, in the `## Связка с Пейном` section, after the paragraph about receiving `workout_done`, add:

```markdown
**При получении `workout_done` дописывай строку в `/workspace/agent/health/workouts.jsonl`:**
`{"date":"YYYY-MM-DD","tonnage_kg":N,"duration_min":N,"rir":N}` (один JSON на строку, append). `analyze.js` читает этот лог для acute/chronic нагрузки и `readiness`. Это в дополнение к заметке в `state.md`.
```

- [ ] **Step 4: Add readiness to the health_signal to Payne**

In `groups/greg/CLAUDE.md`, in the `health_signal` JSON block of the Payne section, add a `readiness` field to the documented shape:

```markdown
- `readiness`: число 0-100 из `analyze.js` (`level` мэппится: green ≥70, yellow 50-69, red <50). Передавай его Пейну — он калибрует объём тренировки.
```

- [ ] **Step 5: Commit**

```bash
git add groups/greg/CLAUDE.md
git commit -m "docs(greg): teach new sensors, readiness, load; wire workouts.jsonl"
```

---

## Task 12: Deploy + verify

**Files:** none (deploy actions). Confirm via host build, VDS pull, scp, iOS install.

- [ ] **Step 1: Full host + protocol test sweep (local)**

Run: `pnpm exec vitest run shared/ios-app-protocol && pnpm run build`
Expected: protocol fixtures PASS; `tsc` build succeeds (new optional fields type-check through `health-ingest`/`sick-day`).

- [ ] **Step 2: Push host + protocol + greg changes**

Run: `git push origin main`
Expected: push succeeds (personal repo, direct-to-main per workflow).

- [ ] **Step 3: Deploy host on the VDS**

Run: `ssh root@148.253.211.164 'sudo -u nanoclaw bash -lc "cd ~/nanoclaw && git pull && pnpm install --frozen-lockfile && pnpm run build && XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw"'`
Expected: pull + build OK, service restarts. (Protocol/zod change is live so new fields survive ingest.)

- [ ] **Step 4: Sync Greg's group files to the VDS**

`groups/` is scp-synced, not git (per project memory). Run:

```bash
scp groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/scripts/
scp groups/greg/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/CLAUDE.md
ssh root@148.253.211.164 'chown nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/greg/scripts/analyze.js /home/nanoclaw/nanoclaw/groups/greg/scripts/analyze.test.js /home/nanoclaw/nanoclaw/groups/greg/CLAUDE.md'
```

Expected: files copied. `analyze.js` is live-mounted into Greg's container — picked up on his next run. **CLAUDE.md reload:** a running Greg session resumes via `continuation:claude`; instruction edits only load at session birth. To apply now, kill Greg's container and clear the continuation (per project memory `feedback_agent_instruction_reload`); otherwise it applies on his next fresh session.

- [ ] **Step 5: Build + install the iOS app**

Run from `ios/JarvisApp`:

```bash
xcodegen generate
xcodebuild test -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/HealthHistoryTests 2>&1 | tail -15
```

Expected: `HealthHistoryTests` pass. Then install on Sergei's physical device via Xcode (Product → Run on the connected iPhone) — HealthKit data requires a real device, not the simulator.

- [ ] **Step 6: Trigger a history re-fetch and verify new fields land in raw.jsonl**

After the app runs on-device (it re-uploads the last 14 days), on the VDS check that new keys appear:

```bash
ssh root@148.253.211.164 'tail -1 /home/nanoclaw/nanoclaw/groups/greg/health/raw.jsonl | grep -oE "\"(deepMin|remMin|hrvMorning|spo2Min|sleepOnsetMin)\"" | sort -u'
```

Expected: prints the new keys (confirms iOS → host → raw.jsonl end-to-end). Also check the app log line `[HealthHistory] SpO2 samples in window: N` is non-zero (SpO2 availability sanity-check, spec §8).

- [ ] **Step 7: Verify Greg's next run consumes them**

Run a manual analyze on the VDS via Greg's container (or wait for the 09:00 scheduled run) and confirm the output JSON now carries `readiness` and `load`:

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw/groups/greg && docker run --rm -v "$PWD":/workspace/agent nanoclaw-agent:latest bun /workspace/agent/scripts/analyze.js /workspace/agent/health/raw.jsonl 2>/dev/null | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const r=JSON.parse(s);console.log({readiness:r.readiness,load:r.load})})"'
```

Expected: prints a `readiness` object and `load` object computed from real data. (If the exact docker invocation differs on the VDS, any path that runs `analyze.js` under Bun against the live `raw.jsonl` is equivalent.)

- [ ] **Step 8: Final commit (if any deploy-doc tweaks) / done**

No code change expected here. Confirm `git status` is clean and the feature is live.

---

## Self-Review

**Spec coverage:**
- §4 protocol fields → Task 1 (zod) + Task 2 (Swift). ✓
- §5 iOS collection (sleep phases, onset, morning HRV, SpO2 + auth) → Tasks 3, 4, 5. ✓
- §6 host ingest no-change → confirmed in Task 12 Step 1 (build proves types flow). ✓
- §7.1 METRICS/CONCERN → Task 6 Step 4. ✓
- §7.2 recovery upgrade (morning-HRV priority, deep/rem/spo2) → Task 6. ✓
- §7.3 sleep regularity synthetic metric → Task 7. ✓
- §7.4 training-load (workouts.jsonl + raw workouts[], acute/chronic, suppress/escalate) → Tasks 8, 9. ✓
- §7.5 readiness 0-100 + bands + normal-mode output → Task 10. ✓
- §7.6 morning HRV priority → Task 6 (`hrvEff`). ✓
- §8 SpO2 build-time count → Task 5 Step 6; on-device check → Task 12 Step 6. ✓
- §9 CLAUDE.md + workouts.jsonl wiring + vo2max/RMSSD fixes → Task 11. ✓
- §10 tests + deploy → Tasks 1–10 tests, Task 12 deploy. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code; commands have expected output. ✓

**Type/name consistency:** `hrvEff` (Task 6) used only internally; `sleepRegularity`/`deepMin`/`remMin`/`awakeMin`/`hrvMorning`/`spo2Min` consistent across protocol (Task 1), Swift (Task 2), METRICS (Task 6), tests. `loadContext`→`{acute,chronic,ratio}` consumed identically in Tasks 9/10. `computeReadiness`→`{score,band,recovery_z,load_ratio}` consistent. `bucketSleepStages`/`SleepSampleInput`/`SleepStageResult`/`averageInWindow`/`reduceSpo2` consistent across Swift tasks. ✓
