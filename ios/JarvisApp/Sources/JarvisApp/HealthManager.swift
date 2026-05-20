import HealthKit

final class HealthManager: ObservableObject {
    private let store = HKHealthStore()
    @Published var steps: Int?
    @Published var heartRate: Int?
    @Published var activeEnergy: Int?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAndFetch() {
        guard isAvailable else { return }
        let types: Set<HKObjectType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
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

        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let q = HKSampleQuery(
            sampleType: HKQuantityType(.heartRate),
            predicate: nil,
            limit: 1,
            sortDescriptors: [sort]
        ) { [weak self] _, s, _ in
            if let s = s?.first as? HKQuantitySample {
                let bpm = Int(s.quantity.doubleValue(for: HKUnit(from: "count/min")))
                DispatchQueue.main.async { self?.heartRate = bpm }
            }
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
