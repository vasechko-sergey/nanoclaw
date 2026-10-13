import Foundation
import Combine
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Stopwatch for a timed set (plank, hold, the warmup walk). Counts up from the
/// wall clock, so it keeps time while the screen is off; `refresh()` on
/// returning to the foreground catches up. Reaching the target buzzes once in
/// the foreground; a local notification covers a locked phone — the user is
/// holding a plank, not looking at the screen.
@MainActor
final class HoldTimer: ObservableObject {
    @Published private(set) var elapsedSec: Int = 0
    @Published private(set) var running: Bool = false
    @Published private(set) var reachedTarget: Bool = false
    @Published private(set) var targetSec: Int = 0

    /// Injectable clock for tests.
    var now: () -> Date = { Date() }

    private var startDate: Date?
    private var cancellable: AnyCancellable?
    private let notificationId = "HoldTimer.target"
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func start(targetSec: Int) {
        reset()
        self.targetSec = targetSec
        startDate = now()
        running = true
        cancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        if targetSec > 0 { scheduleNotification(after: TimeInterval(targetSec)) }
    }

    /// Recompute elapsed from the wall clock. Safe to call any time.
    func refresh() {
        guard running, let start = startDate else { return }
        elapsedSec = max(0, Int(now().timeIntervalSince(start)))
        if !reachedTarget, targetSec > 0, elapsedSec >= targetSec {
            reachedTarget = true
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        }
    }

    /// Stop and return the exact elapsed seconds (the card snaps it for the wheels).
    @discardableResult
    func stop() -> TimeInterval {
        guard running, let start = startDate else { return TimeInterval(elapsedSec) }
        let elapsed = max(0, now().timeIntervalSince(start))
        elapsedSec = Int(elapsed)
        halt()
        return elapsed
    }

    /// Drop a watch left running (exercise changed, workout closed).
    func reset() {
        halt()
        elapsedSec = 0
        reachedTarget = false
        targetSec = 0
    }

    private func halt() {
        cancellable?.cancel()
        cancellable = nil
        running = false
        startDate = nil
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
    }

    private func scheduleNotification(after sec: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Время вышло"
        content.body = "Цель \(WorkoutSetFormat.duration(Int(sec))) — можно останавливать."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(sec, 1), repeats: false)
        center.add(UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger))
    }
}
