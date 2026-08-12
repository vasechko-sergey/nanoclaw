import Foundation
import HealthKit

/// Raw HealthKit sample export, for offline analysis on a laptop.
///
/// Why this exists: the pipeline uploads one aggregated row per day
/// (`HealthHistory` collapses everything through `discreteAverage` /
/// `cumulativeSum` before it leaves the phone), so nothing sub-daily has ever
/// reached the server. The Health app's own "Export All Health Data" does carry
/// raw samples, but it emits the entire history as one multi-gigabyte XML and
/// reliably fails partway through the transfer.
///
/// This dumps only the sparse metrics, only over a chosen window, as JSONL —
/// a few hundred KB instead of gigabytes. Deliberately excludes `heartRate` and
/// `stepCount`: at ~120 samples a night and thousands a day they are what makes
/// the full export unwieldy, and they are already available elsewhere.
///
/// Reads only types `HealthManager.requestAndFetch` already asks authorization
/// for, so this never triggers a new permission prompt.
enum HealthSampleDump {

    /// Quantity types to dump, with the unit each is read in. The unit string is
    /// written into every row so the reader never has to guess.
    private static let quantities: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
        (.heartRateVariabilitySDNN,       .secondUnit(with: .milli), "ms"),
        (.appleSleepingWristTemperature,  .degreeCelsius(),          "degC"),
        (.restingHeartRate,               HKUnit(from: "count/min"), "bpm"),
        (.respiratoryRate,                HKUnit(from: "count/min"), "breaths/min"),
        (.oxygenSaturation,               .percent(),                "fraction"),
    ]

    private static let stageNames: [Int: String] = [
        HKCategoryValueSleepAnalysis.inBed.rawValue: "inBed",
        HKCategoryValueSleepAnalysis.awake.rawValue: "awake",
        HKCategoryValueSleepAnalysis.asleepCore.rawValue: "core",
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue: "deep",
        HKCategoryValueSleepAnalysis.asleepREM.rawValue: "rem",
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: "asleep",
    ]

    struct Result {
        let url: URL
        let counts: [String: Int]
        var total: Int { counts.values.reduce(0, +) }
    }

    /// Dump `daysBack` days ending now. Completion runs on the main queue.
    static func run(daysBack: Int = 60, completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async { completion(.failure(DumpError.unavailable)) }
            return
        }
        let store = HKHealthStore()
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        // ISO-8601 with the offset kept, matching what the Health app's own export
        // writes. Day attribution downstream is local-time based, so a bare UTC
        // instant would be the wrong thing to hand the analysis.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        let group = DispatchGroup()
        let lock = NSLock()
        var lines: [String] = []
        var counts: [String: Int] = [:]
        var failure: Error?

        func record(_ metric: String, _ rows: [String]) {
            lock.lock()
            lines.append(contentsOf: rows)
            counts[metric, default: 0] += rows.count
            lock.unlock()
        }

        for (id, unit, unitName) in quantities {
            group.enter()
            let metric = id.rawValue.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            let q = HKSampleQuery(
                sampleType: HKQuantityType(id), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, error in
                defer { group.leave() }
                if let error { lock.lock(); failure = failure ?? error; lock.unlock(); return }
                let rows = ((samples as? [HKQuantitySample]) ?? []).map { s in
                    #"{"metric":"\#(metric)","start":"\#(fmt.string(from: s.startDate))","end":"\#(fmt.string(from: s.endDate))","value":\#(s.quantity.doubleValue(for: unit)),"unit":"\#(unitName)"}"#
                }
                record(metric, rows)
            }
            store.execute(q)
        }

        group.enter()
        let sleepQ = HKSampleQuery(
            sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
            limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { _, samples, error in
            defer { group.leave() }
            if let error { lock.lock(); failure = failure ?? error; lock.unlock(); return }
            let rows = ((samples as? [HKCategorySample]) ?? []).map { s in
                let stage = stageNames[s.value] ?? "unknown(\(s.value))"
                let source = s.sourceRevision.source.name
                    .replacingOccurrences(of: "\"", with: "'")
                // Source matters here: an iPhone-inferred sleep block and a watch
                // one are different evidence, and 2026-08-10's 14:40 "night" needs
                // that distinction to be diagnosable at all.
                return #"{"metric":"SleepAnalysis","start":"\#(fmt.string(from: s.startDate))","end":"\#(fmt.string(from: s.endDate))","stage":"\#(stage)","source":"\#(source)"}"#
            }
            record("SleepAnalysis", rows)
        }
        store.execute(sleepQ)

        group.notify(queue: .global(qos: .userInitiated)) {
            if let failure {
                DispatchQueue.main.async { completion(.failure(failure)) }
                return
            }
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("health-samples-\(stamp.string(from: Date())).jsonl")
            do {
                try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                let snapshot = counts
                DispatchQueue.main.async { completion(.success(Result(url: url, counts: snapshot))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    enum DumpError: LocalizedError {
        case unavailable
        var errorDescription: String? { "HealthKit недоступен на этом устройстве" }
    }
}
