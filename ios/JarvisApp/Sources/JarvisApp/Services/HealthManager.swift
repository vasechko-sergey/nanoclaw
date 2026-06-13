import HealthKit

@Observable final class HealthManager {
    @ObservationIgnored private let store = HKHealthStore()
    var steps: Int?
    var heartRate: Int?
    var activeEnergy: Int?
    var sleepHours: Double?
    var restingHeartRate: Int?
    var exerciseMinutes: Int?
    var bodyMass: Double?   // kg, latest
    var height: Double?     // m, latest

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
            // New in 2026-06-05 spec.
            HKQuantityType(.appleSleepingWristTemperature),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.walkingHeartRateAverage),
            HKQuantityType(.vo2Max),
            HKQuantityType(.oxygenSaturation),
            HKWorkoutType.workoutType(),
            HKQuantityType(.bodyMass),
            HKQuantityType(.height),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.leanBodyMass),
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

        latestSample(.heartRate,        unit: HKUnit(from: "count/min"))  { [weak self] v in
            self?.heartRate = Int(v)
        }
        latestSample(.restingHeartRate, unit: HKUnit(from: "count/min"))  { [weak self] v in
            self?.restingHeartRate = Int(v)
        }
        latestSample(.bodyMass,         unit: HKUnit.gramUnit(with: .kilo)) { [weak self] v in
            self?.bodyMass = (v * 10).rounded() / 10
        }
        latestSample(.height,           unit: HKUnit.meter())             { [weak self] v in
            self?.height = (v * 100).rounded() / 100
        }

        fetchSleep()
    }

    /// Fetch the single most-recent sample for `id`, read it in `unit`, and hand
    /// the raw `Double` to `assign` on the main queue. Callers do their own
    /// Int-cast / rounding inside `assign`.
    private func latestSample(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        assign: @escaping (Double) -> Void
    ) {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let q = HKSampleQuery(
            sampleType: HKQuantityType(id),
            predicate: nil, limit: 1, sortDescriptors: [sort]
        ) { _, s, _ in
            if let s = s?.first as? HKQuantitySample {
                let v = s.quantity.doubleValue(for: unit)
                DispatchQueue.main.async { assign(v) }
            }
        }
        store.execute(q)
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
}
