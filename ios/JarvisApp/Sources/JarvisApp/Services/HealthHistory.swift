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
    }

    /// Pure: split sleep samples into per-stage minutes + onset (minutes from
    /// `dayStart` local midnight to the earliest asleep sample; negative = before
    /// midnight). `inBed` ignored; `asleepUnspecified`→core. sleepHours = (deep+rem+core)/60.
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

        // Sleep: split into stages + onset, bucketed by wake day (sample end day).
        group.enter()
        sleepSamplesByWakeDay(start: start, end: end, bucket: bucketKey) { byWakeDay in
            for (k, samples) in byWakeDay {
                let dayStart = cal.startOfDay(for: fmt.date(from: k) ?? start)
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

        // New in 2026-06-05 spec: scalar metrics for sick-day detection + differential.

        // Wrist temperature deviation — °C, signed. Daily average of HK's per-night
        // deviation reading. Apple Watch S8+ only; older devices simply return no data.
        group.enter()
        collection(.appleSleepingWristTemperature, start: start, end: end, options: .discreteAverage) { stats in
            let degC = HKUnit.degreeCelsius()
            for s in stats {
                if let q = s.averageQuantity() {
                    let k = bucketKey(s.startDate)
                    let v = (q.doubleValue(for: degC) * 100).rounded() / 100   // 2-decimal precision
                    mutate(k) { $0.wristTempDeviation = v }
                }
            }
            group.leave()
        }

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
            let rows = byDay.values.sorted { $0.date < $1.date }
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

}
