import Foundation
import HealthKit

/// Passive background sync (plan "Заход 3" A): HealthKit background delivery wakes
/// the app when new samples land; we fetch the last few days and upload over HTTP.
/// Works while the app is backgrounded (not force-quit). Requires Health auth
/// (requested by HealthManager) — observers no-op until granted.
enum HealthSync {
    private static let store = HKHealthStore()
    private static var started = false

    private static let sampleTypes: [HKSampleType] = [
        HKQuantityType(.stepCount),
        HKQuantityType(.heartRate),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.appleExerciseTime),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKCategoryType(.sleepAnalysis),
    ]

    static func start() {
        guard HKHealthStore.isHealthDataAvailable(), !started else { return }
        started = true
        for t in sampleTypes {
            let q = HKObserverQuery(sampleType: t, predicate: nil) { _, completion, _ in
                // On a background wake: drain any pending server fetch requests AND
                // push recent days. Both over HTTP (no APNs).
                HealthRequests.drain {
                    pushRecent { completion() }
                }
            }
            store.execute(q)
            store.enableBackgroundDelivery(for: t, frequency: .hourly) { _, _ in }
        }
    }

    /// Fetch the last 3 days of daily aggregates and upload them.
    static func pushRecent(_ done: @escaping () -> Void) {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let to = fmt.string(from: Date())
        let from = fmt.string(from: cal.date(byAdding: .day, value: -3, to: Date()) ?? Date())
        HealthHistory.fetch(from: from, to: to) { days in
            HealthUpload.upload(requestId: nil, days: days) { done() }
        }
    }

    /// Public production entrypoint. Called from scenePhase == .active.
    /// If `lastHealthUploadAt` is missing or not in today's calendar day,
    /// kicks `pushRecent` and stamps the date afterward. Otherwise no-op.
    static func kickIfStale() {
        _ = kickIfStaleForTesting(
            now: Date(),
            calendar: Calendar.current,
            defaults: UserDefaults.standard,
            push: { done in pushRecent(done) }
        )
    }

    /// Pure decision + side-effect seam for tests. Returns the number of times
    /// `push` was invoked (0 or 1).
    @discardableResult
    static func kickIfStaleForTesting(
        now: Date,
        calendar: Calendar,
        defaults: UserDefaults,
        push: (@escaping () -> Void) -> Void
    ) -> Int {
        let last = defaults.object(forKey: "lastHealthUploadAt") as? Date
        let today = calendar.startOfDay(for: now)
        if let last, calendar.startOfDay(for: last) >= today {
            return 0
        }
        push {
            defaults.set(Date(), forKey: "lastHealthUploadAt")
        }
        return 1
    }
}
