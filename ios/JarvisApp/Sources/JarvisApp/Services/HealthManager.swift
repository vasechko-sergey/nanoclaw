import HealthKit

final class HealthManager: ObservableObject {
    private let store = HKHealthStore()
    @Published var steps: Int?
    @Published var heartRate: Int?
    @Published var activeEnergy: Int?
    @Published var sleepHours: Double?
    @Published var restingHeartRate: Int?
    @Published var exerciseMinutes: Int?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAndFetch() {
        guard isAvailable else { return }
        let types: Set<HKObjectType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.heartRateVariabilitySDNN),
        ]
        store.requestAuthorization(toShare: nil, read: types) { [weak self] ok, _ in
            guard ok else { return }
            self?.fetchToday()
        }
    }

    private func fetchToday() {
        let start = Calendar.current.startOfDay(for: Date())
        let pred  = HKQuery.predicateForSamples(withStart: start, end: Date())
        stat(.stepCount,          pred, .cumulativeSum, .count())       { [weak self] v in
            DispatchQueue.main.async { self?.steps        = v.map(Int.init) }
        }
        stat(.activeEnergyBurned, pred, .cumulativeSum, .kilocalorie()) { [weak self] v in
            DispatchQueue.main.async { self?.activeEnergy = v.map(Int.init) }
        }
        stat(.appleExerciseTime, pred, .cumulativeSum, .minute()) { [weak self] v in
            DispatchQueue.main.async { self?.exerciseMinutes = v.map(Int.init) }
        }

        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let qHR = HKSampleQuery(
            sampleType: HKQuantityType(.heartRate),
            predicate: nil, limit: 1, sortDescriptors: [sort]
        ) { [weak self] _, s, _ in
            if let s = s?.first as? HKQuantitySample {
                let bpm = Int(s.quantity.doubleValue(for: HKUnit(from: "count/min")))
                DispatchQueue.main.async { self?.heartRate = bpm }
            }
        }
        store.execute(qHR)

        let qRHR = HKSampleQuery(
            sampleType: HKQuantityType(.restingHeartRate),
            predicate: nil, limit: 1, sortDescriptors: [sort]
        ) { [weak self] _, s, _ in
            if let s = s?.first as? HKQuantitySample {
                let bpm = Int(s.quantity.doubleValue(for: HKUnit(from: "count/min")))
                DispatchQueue.main.async { self?.restingHeartRate = bpm }
            }
        }
        store.execute(qRHR)

        fetchSleep()
    }

    private func fetchSleep() {
        let cal = Calendar.current
        let now = Date()
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let eveningYesterday = cal.date(byAdding: .hour, value: -18, to: noon)!
        let pred = HKQuery.predicateForSamples(withStart: eveningYesterday, end: noon)

        let q = HKSampleQuery(
            sampleType: HKCategoryType(.sleepAnalysis),
            predicate: pred, limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { [weak self] _, samples, _ in
            let asleep = (samples as? [HKCategorySample])?.filter {
                [.asleepUnspecified, .asleepCore, .asleepREM, .asleepDeep].contains(
                    HKCategoryValueSleepAnalysis(rawValue: $0.value)
                )
            }
            let total = asleep?.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } ?? 0
            let hours = (total / 3600 * 10).rounded() / 10
            DispatchQueue.main.async { self?.sleepHours = hours > 0 ? hours : nil }
        }
        store.execute(q)
    }

    private func stat(
        _ t: HKQuantityTypeIdentifier,
        _ pred: NSPredicate,
        _ opts: HKStatisticsOptions,
        _ unit: HKUnit,
        _ cb: @escaping (Double?) -> Void
    ) {
        let q = HKStatisticsQuery(
            quantityType: HKQuantityType(t),
            quantitySamplePredicate: pred,
            options: opts
        ) { _, s, _ in
            cb(opts.contains(.cumulativeSum)
               ? s?.sumQuantity()?.doubleValue(for: unit)
               : s?.averageQuantity()?.doubleValue(for: unit))
        }
        store.execute(q)
    }
}
