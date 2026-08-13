import Foundation
import HealthKit

/// Daily health aggregates over an interval, for the autonomous health analyzer (Greg).
/// Buckets on-device at LOCAL midnight (correct timezone — see plan P1).
/// Relies on app-level HealthKit authorization already requested by HealthManager.
enum HealthHistory {
    private static let store = HKHealthStore()

    /// Sleep stage rawValues — mirror HKCategoryValueSleepAnalysis so the pure
    /// reducer needs no live HealthKit store and is unit-testable.
    enum SleepStage: Int { case inBed = 0, asleepUnspecified = 1, awake = 2, asleepCore = 3, asleepDeep = 4, asleepREM = 5 }

    struct SleepSampleInput { let stage: Int; let start: Date; let end: Date }
    struct SleepStageResult: Equatable {
        var deepMin: Int; var remMin: Int; var coreMin: Int; var awakeMin: Int
        var onsetMin: Int?; var sleepHours: Double
        /// The onset as an absolute instant (epoch ms), alongside the local
        /// minute. `onsetMin` is computed from `Calendar.current` AT UPLOAD TIME,
        /// so a backfill from a different timezone rewrites history's frame —
        /// measured on the 2026-07-04/05 Bali → Sri Lanka flight, which reframed
        /// four nights already slept in Bali. The instant does not move, so local
        /// time can always be re-derived, including under a corrected offset.
        var onsetUtcMs: Int?
    }

    struct SleepDayResult: Equatable {
        var stages: SleepStageResult
        var napMin: Int
        var napCount: Int
    }

    /// Stages that count as asleep at all.
    private static let asleepStages: Set<Int> = [
        SleepStage.asleepUnspecified.rawValue, SleepStage.asleepCore.rawValue,
        SleepStage.asleepDeep.rawValue, SleepStage.asleepREM.rawValue,
    ]

    /// Stages the watch only assigns inside a tracked sleep session. Sleep it
    /// picks up outside one arrives as `asleepUnspecified` — which is why stage
    /// presence, not clock time or gap width, is the primary night/nap marker.
    /// Measured over 1,734 real intervals: 1,726 staged, and all 8 unstaged ones
    /// are sleep outside the night.
    private static let stagedStages: Set<Int> = [
        SleepStage.asleepCore.rawValue, SleepStage.asleepDeep.rawValue, SleepStage.asleepREM.rawValue,
    ]

    /// Split a wake day's intervals into contiguous blocks, breaking on any gap of
    /// `gapMin` or more. A nap and the night that follows it are different events;
    /// merged, they produced a `sleepOnsetMin` of −560 and a critical circadian
    /// finding out of a 72-minute afternoon sleep.
    ///
    /// 120 minutes is not a guess: across 61 nights the gap distribution is empty
    /// between 120 and 240 minutes, and every threshold from 90 to 240 gives the
    /// identical partition. At 60 it starts cutting real nights in half — including
    /// 2026-08-10 and 08-11, where a long awakening *is* the symptom.
    static func splitSleepBlocks(
        _ samples: [SleepSampleInput], gapMin: Int = 120
    ) -> [[SleepSampleInput]] {
        let sorted = samples.sorted { $0.start < $1.start }
        guard var last = sorted.first?.end else { return [] }
        var blocks: [[SleepSampleInput]] = []
        var cur: [SleepSampleInput] = []
        for s in sorted {
            if !cur.isEmpty, s.start.timeIntervalSince(last) >= Double(gapMin) * 60 {
                blocks.append(cur); cur = []
            }
            cur.append(s)
            last = Swift.max(last, s.end)
        }
        if !cur.isEmpty { blocks.append(cur) }
        return blocks
    }

    /// Minutes actually asleep in a block — awake intervals inside it do not count.
    static func blockMinutes(_ block: [SleepSampleInput]) -> Double {
        block.filter { asleepStages.contains($0.stage) }
             .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
    }

    /// True when at least half a block's asleep minutes carry a real stage. Half
    /// rather than all: a staged night can contain a stray unspecified fragment,
    /// and one such fragment must not disqualify the night.
    static func isStagedBlock(_ block: [SleepSampleInput]) -> Bool {
        let asleep = block.filter { asleepStages.contains($0.stage) }
        let total = asleep.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard total > 0 else { return false }
        let staged = asleep.filter { stagedStages.contains($0.stage) }
            .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return staged / total >= 0.5
    }

    /// Within one gap-joined block, separate the staged run (the night) from any
    /// unstaged sleep riding along with it. Catches the 2026-07-01 morning doze,
    /// which sits only 47 minutes after the night and so survives the gap split.
    /// Awake intervals stay with the night — they belong to whatever surrounds them.
    static func splitStagedRuns(
        _ block: [SleepSampleInput]
    ) -> (night: [SleepSampleInput], outside: [SleepSampleInput]) {
        var night: [SleepSampleInput] = [], outside: [SleepSampleInput] = []
        for s in block.sorted(by: { $0.start < $1.start }) {
            if asleepStages.contains(s.stage) && !stagedStages.contains(s.stage) { outside.append(s) }
            else { night.append(s) }
        }
        return (night, outside)
    }

    /// Pure: reduce a wake day's sleep to the NIGHT's stages plus whatever slept
    /// outside it. The night is the longest staged block; everything else — an
    /// unstaged block, or unstaged sleep riding inside the night's block — is a nap.
    static func reduceSleepDay(_ samples: [SleepSampleInput], dayStart: Date) -> SleepDayResult {
        let blocks = splitSleepBlocks(samples)
        guard !blocks.isEmpty else {
            return SleepDayResult(stages: bucketSleepStages([], dayStart: dayStart), napMin: 0, napCount: 0)
        }
        let staged = blocks.filter { isStagedBlock($0) }
        // No staged block at all (watch off, or a day of pure naps): fall back to
        // the longest block so the day is not silently emptied.
        let candidates = staged.isEmpty ? blocks : staged
        let nightBlock = candidates.max(by: { blockMinutes($0) < blockMinutes($1) })!

        let runs = splitStagedRuns(nightBlock)
        var napMin = 0.0, napCount = 0
        for b in blocks where !(b.first?.start == nightBlock.first?.start) {
            let m = blockMinutes(b)
            if m > 0 { napMin += m; napCount += 1 }
        }
        if !runs.outside.isEmpty {
            napMin += blockMinutes(runs.outside)
            napCount += 1
        }
        return SleepDayResult(
            stages: bucketSleepStages(runs.night, dayStart: dayStart),
            napMin: Int(napMin.rounded()), napCount: napCount
        )
    }

    /// Pure: split sleep samples into per-stage minutes + onset (minutes from
    /// `dayStart` local midnight to the earliest asleep sample; negative = before
    /// midnight). `inBed` ignored; `asleepUnspecified`→core. sleepHours = (deep+rem+core)/60.
    ///
    /// Callers should go through `reduceSleepDay`, which hands this the night only.
    /// Fed a whole wake day it will happily take a nap's start as the night's onset.
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
            onsetMin: onset, sleepHours: ((deep + rem + core) / 60 * 10).rounded() / 10,
            onsetUtcMs: earliestAsleep.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) }
        )
    }

    /// Pure: nocturnal SpO2 avg + min, converting HK fraction (0..1) to percent.
    static func reduceSpo2(_ fractions: [Double]) -> (avg: Double, min: Double)? {
        guard !fractions.isEmpty else { return nil }
        let pct = fractions.map { $0 * 100 }
        let avg = pct.reduce(0, +) / Double(pct.count)
        return (avg: (avg * 100).rounded() / 100, min: (pct.min()! * 10).rounded() / 10)
    }

    /// Overnight metrics (sleep stages, morning HRV, nocturnal SpO₂) can begin
    /// before midnight of the wake day. The fetch window must start one day
    /// before the requested `from` so the left-edge day's pre-midnight samples
    /// are included; wake-day bucketing keeps attribution correct.
    static func overnightWindowStart(from start: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -1, to: start)!
    }

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

    /// `from`/`to` are "yyyy-MM-dd" (local). Returns one `V2.HealthUpload.Day`
    /// per day — wire shape pinned by shared/ios-app-protocol fixtures.
    static func fetch(from: String, to: String, completion: @escaping ([V2.HealthUpload.Day]) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { completion([]); return }
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        guard let fromDay = fmt.date(from: from), let toDay = fmt.date(from: to) else {
            completion([]); return
        }
        let start = cal.startOfDay(for: fromDay)
        guard let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDay)) else {
            completion([]); return
        }

        // Overnight metrics need the previous evening; widen their left edge.
        let sleepStart = HealthHistory.overnightWindowStart(from: start, calendar: cal)

        var byDay: [String: V2.HealthUpload.Day] = [:]
        let group = DispatchGroup()
        let lock = NSLock()

        func bucketKey(_ d: Date) -> String { fmt.string(from: cal.startOfDay(for: d)) }
        func mutate(_ k: String, _ apply: (inout V2.HealthUpload.Day) -> Void) {
            lock.lock()
            var row = byDay[k] ?? V2.HealthUpload.Day(date: k)
            apply(&row)
            byDay[k] = row
            lock.unlock()
        }

        // Cumulative sums: steps, active energy, exercise minutes.
        let sums: [(HKQuantityTypeIdentifier, HKUnit, WritableKeyPath<V2.HealthUpload.Day, Int?>)] = [
            (.stepCount, .count(), \.steps),
            (.activeEnergyBurned, .kilocalorie(), \.activeEnergy),
            (.appleExerciseTime, .minute(), \.exerciseMinutes),
        ]
        for (id, unit, kp) in sums {
            group.enter()
            collection(id, start: start, end: end, options: .cumulativeSum) { stats in
                for s in stats {
                    if let q = s.sumQuantity() {
                        let k = bucketKey(s.startDate)
                        let v = Int(q.doubleValue(for: unit).rounded())
                        mutate(k) { $0[keyPath: kp] = v }
                    }
                }
                group.leave()
            }
        }

        // Discrete averages: heart rate, resting heart rate.
        let bpm = HKUnit(from: "count/min")
        let avgs: [(HKQuantityTypeIdentifier, WritableKeyPath<V2.HealthUpload.Day, Int?>)] = [
            (.heartRate, \.heartRate),
            (.restingHeartRate, \.restingHeartRate),
        ]
        for (id, kp) in avgs {
            group.enter()
            collection(id, start: start, end: end, options: .discreteAverage) { stats in
                for s in stats {
                    if let q = s.averageQuantity() {
                        let k = bucketKey(s.startDate)
                        let v = Int(q.doubleValue(for: bpm).rounded())
                        mutate(k) { $0[keyPath: kp] = v }
                    }
                }
                group.leave()
            }
        }

        // HRV (SDNN) daily average — ms. Key recovery signal.
        group.enter()
        collection(.heartRateVariabilitySDNN, start: start, end: end, options: .discreteAverage) { stats in
            let ms = HKUnit.secondUnit(with: .milli)
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = Int(q.doubleValue(for: ms).rounded())
                    mutate(k) { $0.hrv = v }
                }
            }
            group.leave()
        }

        // Morning HRV: overnight SDNN only (bucketOvernight drops daytime), per
        // wake day. Cleaner recovery signal than the whole-day SDNN average.
        group.enter()
        let hrvQ = HKSampleQuery(
            sampleType: HKQuantityType(.heartRateVariabilitySDNN),
            predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: end),
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

        // Nocturnal SpO2: overnight min + avg (bucketOvernight drops daytime), per wake day.
        group.enter()
        let spo2Q = HKSampleQuery(
            sampleType: HKQuantityType(.oxygenSaturation),
            predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: end),
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

        // Sleep: split into stages + onset, bucketed by wake day (sample end day).
        group.enter()
        sleepSamplesByWakeDay(start: sleepStart, end: end, bucket: bucketKey) { byWakeDay in
            for (k, samples) in byWakeDay {
                let dayStart = cal.startOfDay(for: fmt.date(from: k) ?? start)
                let d = HealthHistory.reduceSleepDay(samples, dayStart: dayStart)
                let r = d.stages
                mutate(k) {
                    $0.deepMin = r.deepMin; $0.remMin = r.remMin
                    $0.coreMin = r.coreMin; $0.awakeMin = r.awakeMin
                    $0.sleepOnsetMin = r.onsetMin
                    $0.sleepOnsetUtcMs = r.onsetUtcMs
                    $0.sleepHours = r.sleepHours
                    $0.napMin = d.napMin
                    $0.napCount = d.napCount
                }
            }
            group.leave()
        }

        // New in 2026-06-05 spec: scalar metrics for sick-day detection + differential.

        // Sleeping wrist temperature — °C absolute (NOT a deviation, despite the
        // field name; typical values here are 35.0–35.4). Apple Watch S8+ only.
        //
        // Raw sample query, NOT `collection`. A daily HKStatisticsCollectionQuery
        // buckets each sample by its own start time, so a 23:20 → 07:20 night is
        // filed under the evening date — and the statistics bucket only reports
        // its interval midnight, so the sample's real time is unrecoverable
        // downstream. Measured against a raw HealthKit dump: 52 of 58 samples
        // landed a day early that way. On the reference illness it put the fever
        // peak (36.19) under 08-10 instead of 08-11, and left 08-12 — the day the
        // sick-day rule actually ran — null, when the real value was 35.98,
        // +0.76 °C over baseline and well past the 0.4 threshold.
        //
        // Keyed on the wake day via `sleepWakeDay`, matching hrvMorning, spo2 and
        // the sleep phases. Query from `sleepStart` for the same reason they do:
        // the night belonging to the first requested day begins before it.
        group.enter()
        let wristTempQ = HKSampleQuery(
            sampleType: HKQuantityType(.appleSleepingWristTemperature),
            predicate: HKQuery.predicateForSamples(withStart: sleepStart, end: end),
            limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { _, samples, _ in
            let degC = HKUnit.degreeCelsius()
            var byDay: [String: [Double]] = [:]
            for s in (samples as? [HKQuantitySample]) ?? [] {
                let k = bucketKey(HealthHistory.sleepWakeDay(start: s.startDate, calendar: cal))
                byDay[k, default: []].append(s.quantity.doubleValue(for: degC))
            }
            for (k, vals) in byDay {
                // More than one sample on a night is rare; average as the daily
                // statistics query did, so the value is unchanged apart from its day.
                let avg = vals.reduce(0, +) / Double(vals.count)
                mutate(k) { $0.wristTempDeviation = (avg * 100).rounded() / 100 }
            }
            group.leave()
        }
        store.execute(wristTempQ)

        // Respiratory rate — breaths/min, sleep-window aggregate.
        group.enter()
        collection(.respiratoryRate, start: start, end: end, options: .discreteAverage) { stats in
            let rate = HKUnit(from: "count/min")
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = (q.doubleValue(for: rate) * 10).rounded() / 10
                    mutate(k) { $0.respiratoryRate = v }
                }
            }
            group.leave()
        }

        // Walking heart rate average — bpm. Early indicator of cardio drift.
        group.enter()
        collection(.walkingHeartRateAverage, start: start, end: end, options: .discreteAverage) { stats in
            let bpm2 = HKUnit(from: "count/min")
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = Int(q.doubleValue(for: bpm2).rounded())
                    mutate(k) { $0.walkingHeartRateAverage = v }
                }
            }
            group.leave()
        }

        // VO2max — mL/kg/min. Slow-moving fitness indicator; HK emits sporadically.
        group.enter()
        collection(.vo2Max, start: start, end: end, options: .discreteAverage) { stats in
            let vo2Unit = HKUnit(from: "ml/(kg*min)")
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = (q.doubleValue(for: vo2Unit) * 10).rounded() / 10
                    mutate(k) { $0.vo2max = v }
                }
            }
            group.leave()
        }

        // Body composition (smart scale): discrete measurements, per measured day.
        group.enter()
        collection(.bodyMass, start: start, end: end, options: .discreteAverage) { stats in
            let kg = HKUnit.gramUnit(with: .kilo)
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = (q.doubleValue(for: kg) * 10).rounded() / 10
                    mutate(k) { $0.bodyMass = v }
                }
            }
            group.leave()
        }
        group.enter()
        collection(.height, start: start, end: end, options: .discreteAverage) { stats in
            let m = HKUnit.meter()
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = (q.doubleValue(for: m) * 100).rounded() / 100
                    mutate(k) { $0.height = v }
                }
            }
            group.leave()
        }
        group.enter()
        collection(.bodyFatPercentage, start: start, end: end, options: .discreteAverage) { stats in
            let frac = HKUnit.percent()  // HK percent unit == fraction 0..1; ×100 → human percent number
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = (q.doubleValue(for: frac) * 1000).rounded() / 10
                    mutate(k) { $0.bodyFatPercentage = v }
                }
            }
            group.leave()
        }
        group.enter()
        collection(.leanBodyMass, start: start, end: end, options: .discreteAverage) { stats in
            let kg = HKUnit.gramUnit(with: .kilo)
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = (q.doubleValue(for: kg) * 10).rounded() / 10
                    mutate(k) { $0.leanBodyMass = v }
                }
            }
            group.leave()
        }

        // Manual thermometer readings. Max, not average: see the contract note
        // on Day.bodyTemperature — a fever peak averaged against a normal
        // morning reading is a number that describes neither.
        group.enter()
        collection(.bodyTemperature, start: start, end: end, options: .discreteMax) { stats in
            let degC = HKUnit.degreeCelsius()
            for s in stats {
                if let q = s.maximumQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = (q.doubleValue(for: degC) * 100).rounded() / 100
                    mutate(k) { $0.bodyTemperature = v }
                }
            }
            group.leave()
        }

        // Symptoms — presence per day, one query per type (HealthKit has no
        // aggregate symptom type). Bucketed by the sample's own calendar day,
        // not by wake-day: a symptom is a statement about the day it was
        // logged, unlike sleep which belongs to the night before its wake.
        for id in HealthManager.symptomTypes {
            group.enter()
            let key = HealthHistory.symptomKey(id)
            let q = HKSampleQuery(
                sampleType: HKCategoryType(id),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                for s in (samples as? [HKCategorySample]) ?? [] {
                    mutate(bucketKey(s.startDate)) { day in
                        var list = day.symptoms ?? []
                        if !list.contains(key) { list.append(key) }
                        day.symptoms = list
                    }
                }
                group.leave()
            }
            store.execute(q)
        }

        // Workouts — array per day. Differential mode uses accumulated load as evidence.
        group.enter()
        let workoutQuery = HKSampleQuery(
            sampleType: HKWorkoutType.workoutType(),
            predicate: HKQuery.predicateForSamples(withStart: start, end: end),
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { _, samples, _ in
            let workouts = (samples as? [HKWorkout]) ?? []
            let isoFormatter = ISO8601DateFormatter()
            for w in workouts {
                let k = bucketKey(w.startDate)
                let energy = w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                let bpm3 = HKUnit(from: "count/min")
                let hrStats = w.statistics(for: HKQuantityType(.heartRate))
                let avg = hrStats?.averageQuantity()?.doubleValue(for: bpm3)
                let max = hrStats?.maximumQuantity()?.doubleValue(for: bpm3)
                let entry = V2.HealthUpload.Workout(
                    type: String(describing: w.workoutActivityType),
                    startISO: isoFormatter.string(from: w.startDate),
                    durationMin: (w.duration / 60 * 10).rounded() / 10,
                    energyKcal: energy.map { ($0 * 10).rounded() / 10 },
                    avgHR: avg.map { Int($0.rounded()) },
                    maxHR: max.map { Int($0.rounded()) }
                )
                mutate(k) {
                    var list = $0.workouts ?? []
                    list.append(entry)
                    $0.workouts = list
                }
            }
            group.leave()
        }
        store.execute(workoutQuery)

        group.notify(queue: .main) {
            // Stamp each day with the UTC offset that applied ON THAT DAY, not the
            // one in force now — a backfill run after a move must not label last
            // month's nights with this month's timezone. sleepOnsetMin is measured
            // from LOCAL midnight and nothing recorded which local, so the
            // 2026-07-01 Bali → Sri Lanka move read as a collapsing routine and
            // held sleepRegularity in warn/critical for three weeks.
            lock.lock()
            for k in byDay.keys {
                guard let dayStart = fmt.date(from: k) else { continue }
                byDay[k]?.tzOffsetMin = TimeZone.current.secondsFromGMT(for: dayStart) / 60
                // A day the symptom queries covered and found nothing in gets []
                // rather than nil. nil has to keep meaning "this upload said
                // nothing about symptoms" — it is what lets the server's COALESCE
                // upsert defer instead of overwrite — so without this, deleting a
                // mis-logged fever in Health.app could never clear the stored one.
                //
                // The claim is slightly stronger than what HealthKit can prove:
                // read authorization is deliberately unknowable, so a denied
                // permission also looks like "found nothing". That is safe here
                // only because symptoms exclusively ADD to the sick-day score and
                // never subtract — a false [] can hide a signal that was never
                // available, but it can never invent a healthy verdict.
                if byDay[k]?.symptoms == nil { byDay[k]?.symptoms = [] }
            }
            lock.unlock()

            // The widened sleep window can surface a partial (from-1) wake-day row;
            // emit only days within the requested [from, to] range.
            let rows = byDay.values
                .filter { $0.date >= from && $0.date <= to }
                .sorted { $0.date < $1.date }
            completion(Array(rows))
        }
    }

    private static func collection(
        _ id: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        options: HKStatisticsOptions,
        _ cb: @escaping ([HKStatistics]) -> Void
    ) {
        let anchor = Calendar.current.startOfDay(for: start)
        let q = HKStatisticsCollectionQuery(
            quantityType: HKQuantityType(id),
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
            options: options,
            anchorDate: anchor,
            intervalComponents: DateComponents(day: 1)
        )
        q.initialResultsHandler = { _, results, _ in
            var out: [HKStatistics] = []
            results?.enumerateStatistics(from: start, to: end) { s, _ in out.append(s) }
            cb(out)
        }
        store.execute(q)
    }

    /// HealthKit identifier -> the short key the wire contract uses.
    /// `HKCategoryTypeIdentifierFever` -> `fever`. The suffix is the whole
    /// contract: the server stores these strings verbatim and Greg matches on
    /// them, so the mapping must stay a pure function of the identifier.
    static func symptomKey(_ id: HKCategoryTypeIdentifier) -> String {
        var s = id.rawValue
        if s.hasPrefix("HKCategoryTypeIdentifier") {
            s.removeFirst("HKCategoryTypeIdentifier".count)
        }
        return s.prefix(1).lowercased() + s.dropFirst()
    }

    /// Wake-day for a sleep sample, by a noon cutoff on its START time: from
    /// local noon onward the sample belongs to that night (→ wake the NEXT day);
    /// before noon it belongs to the previous night (→ wake that day). Groups a
    /// whole night — including pre-midnight chunks that END before midnight —
    /// under one wake day, instead of splitting them onto the prior calendar day.
    static func sleepWakeDay(start: Date, calendar: Calendar) -> Date {
        let day0 = calendar.startOfDay(for: start)
        return calendar.component(.hour, from: start) >= 12
            ? calendar.date(byAdding: .day, value: 1, to: day0)!
            : day0
    }

    /// Group sleep samples by wake-day key (noon cutoff on sample START — see
    /// `sleepWakeDay`). Returns the raw per-day samples so the pure reducer does
    /// the stage math.
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
                let k = bucket(HealthHistory.sleepWakeDay(start: s.startDate, calendar: Calendar.current))
                byDay[k, default: []].append(.init(stage: s.value, start: s.startDate, end: s.endDate))
            }
            cb(byDay)
        }
        store.execute(q)
    }

}
