import Foundation
import BackgroundTasks

/// Periodic background self-wake whose sole job is to pull pending agent
/// messages and raise local notifications (no APNs). Complements the HealthKit
/// observer wakes and the morning BGProcessing task. iOS decides actual cadence
/// (the interval is an `earliestBeginDate` floor, throttled by usage); nothing
/// runs after the app is force-quit.
enum PendingRefreshTask {
    static let taskId = "com.vasechko.jarvis.pending-pull"
    static let interval: TimeInterval = 15 * 60

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            handle(task)
        }
    }

    static func schedule(now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("PendingRefreshTask: submit failed: \(error)")
        }
    }

    private static func handle(_ task: BGTask) {
        schedule() // re-arm first so a crash/expiry can't break the chain
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        // BGAppRefreshTask carries no network guarantee (unlike BGProcessingTask),
        // so if the device is offline `drain` silently no-ops — that's fine; the
        // next refresh (or a live WS message) surfaces the message instead.
        PendingNotifications.drain {
            task.setTaskCompleted(success: true)
        }
    }
}
