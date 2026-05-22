import Foundation
import HealthKit

/// Daily health aggregates over an interval, for the autonomous health analyzer (Greg).
/// Buckets on-device at LOCAL midnight (correct timezone — see plan P1).
/// Relies on app-level HealthKit authorization already requested by HealthManager.
enum HealthHistory {
    private static let store = HKHealthStore()

    /// `from`/`to` are "yyyy-MM-dd" (local). Returns one dict per day:
    /// { date, steps, activeEnergy, exerciseMinutes, heartRate, restingHeartRate, sleepHours }.
    static func fetch(from: String, to: String, completion: @escaping ([[String: Any]]) -> Void) {
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

        var byDay: [String: [String: Any]] = [:]
        let group = DispatchGroup()

        func bucketKey(_ d: Date) -> String { fmt.string(from: cal.startOfDay(for: d)) }

        // Cumulative sums: steps, active energy, exercise minutes.
        let sums: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
            (.stepCount, .count(), "steps"),
            (.activeEnergyBurned, .kilocalorie(), "activeEnergy"),
            (.appleExerciseTime, .minute(), "exerciseMinutes"),
        ]
        for (id, unit, key) in sums {
            group.enter()
            collection(id, start: start, end: end, options: .cumulativeSum) { stats in
                for s in stats {
                    if let q = s.sumQuantity() {
                        let k = bucketKey(s.startDate)
                        byDay[k, default: ["date": k]][key] = Int(q.doubleValue(for: unit).rounded())
                    }
                }
                group.leave()
            }
        }

        // Discrete averages: heart rate, resting heart rate.
        let bpm = HKUnit(from: "count/min")
        let avgs: [(HKQuantityTypeIdentifier, String)] = [
            (.heartRate, "heartRate"),
            (.restingHeartRate, "restingHeartRate"),
        ]
        for (id, key) in avgs {
            group.enter()
            collection(id, start: start, end: end, options: .discreteAverage) { stats in
                for s in stats {
                    if let q = s.averageQuantity() {
                        let k = bucketKey(s.startDate)
                        byDay[k, default: ["date": k]][key] = Int(q.doubleValue(for: bpm).rounded())
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
                    byDay[k, default: ["date": k]]["hrv"] = Int(q.doubleValue(for: ms).rounded())
                }
            }
            group.leave()
        }

        // Sleep: sum asleep durations, bucketed by wake day (the day the sleep block ends).
        group.enter()
        sleepByDay(start: start, end: end, bucket: bucketKey) { sleep in
            for (k, hours) in sleep {
                byDay[k, default: ["date": k]]["sleepHours"] = (hours * 10).rounded() / 10
            }
            group.leave()
        }

        group.notify(queue: .main) {
            let rows = byDay.values.sorted {
                ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "")
            }
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

    private static func sleepByDay(
        start: Date,
        end: Date,
        bucket: @escaping (Date) -> String,
        _ cb: @escaping ([String: Double]) -> Void
    ) {
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        ]
        let q = HKSampleQuery(
            sampleType: HKCategoryType(.sleepAnalysis),
            predicate: HKQuery.predicateForSamples(withStart: start, end: end),
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { _, samples, _ in
            var hoursByDay: [String: Double] = [:]
            for s in (samples as? [HKCategorySample]) ?? [] where asleepValues.contains(s.value) {
                let k = bucket(s.endDate)
                hoursByDay[k, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 3600
            }
            cb(hoursByDay)
        }
        store.execute(q)
    }
}
