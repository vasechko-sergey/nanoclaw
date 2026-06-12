import Foundation
import BackgroundTasks

/// Time-based morning backstop to `HealthSync`'s event-driven observers.
///
/// `HealthSync` uploads when HealthKit delivers a new sample (watch sync on wake).
/// That covers most days, but only fires when a *new* sample lands. This task
/// guarantees a daily floor: a `BGProcessingTask` becomes eligible at ~08:00 local
/// and pushes recent health days, so Greg's 08:30 run and the 09:00 brief see
/// today's numbers even if no new-sample wake happened.
///
/// Caveats (iOS, not bugs): the OS decides *when* an eligible task actually runs
/// (08:00 is an `earliestBeginDate` floor, not a guarantee), and NOTHING runs in
/// the background after the app is force-quit (swiped out of the switcher).
enum HealthBackgroundTask {
    static let taskId = "com.vasechko.jarvis.morning-health"

    /// Next occurrence of `hour:00` in the calendar's timezone, strictly after `now`.
    /// Pure — unit tested.
    static func nextRun(after now: Date, calendar: Calendar, hour: Int = 8) -> Date {
        let todayRun = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if todayRun > now { return todayRun }
        return calendar.date(byAdding: .day, value: 1, to: todayRun) ?? todayRun.addingTimeInterval(86_400)
    }

    /// Register the launch handler. MUST be called before the app finishes launching
    /// (i.e. from `application(_:didFinishLaunchingWithOptions:)`).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            handle(task)
        }
    }

    /// Submit a request for the next morning run. Submitting again replaces the
    /// pending request for this identifier, so calling on launch + on background is safe.
    static func schedule(now: Date = Date(), calendar: Calendar = .current) {
        let request = BGProcessingTaskRequest(identifier: taskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextRun(after: now, calendar: calendar)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator / unentitled / scheduler unavailable → no-op. Real device only.
            print("HealthBackgroundTask: submit failed: \(error)")
        }
    }

    private static func handle(_ task: BGTask) {
        // Re-arm for tomorrow FIRST so a crash/expiry mid-run never breaks the chain.
        schedule()
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        // Drain any pending server fetch requests, then push recent days. Same path
        // the observers use; completion fires once after the HTTP upload returns.
        HealthRequests.drain {
            HealthSync.pushRecent {
                task.setTaskCompleted(success: true)
            }
        }
    }
}
