import CoreMotion

/// Reads the most-recent CoreMotion activity classification (walking, running,
/// automotive, cycling, stationary). Returns nil if motion data is unavailable
/// or access is denied.
final class MotionManager {
    private let activity = CMMotionActivityManager()

    func currentActivity() async -> String? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        let now = Date()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            activity.queryActivityStarting(from: now.addingTimeInterval(-120), to: now, to: .main) { acts, _ in
                guard let a = acts?.last else { cont.resume(returning: nil); return }
                let label = a.walking ? "walking"
                    : a.running ? "running"
                    : a.automotive ? "automotive"
                    : a.cycling ? "cycling"
                    : a.stationary ? "stationary" : "unknown"
                cont.resume(returning: label)
            }
        }
    }
}
