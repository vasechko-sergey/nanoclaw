import Foundation
import Combine
import UserNotifications

/// Adaptive inter-set rest timer. Live UI via @Published `remainingSec`;
/// off-screen alert via local notification scheduled at start so a locked
/// phone still wakes when rest expires.
@MainActor
final class RestTimer: ObservableObject {
    @Published private(set) var remainingSec: Int = 0
    /// Adapted total this countdown started from — denominator for the ring.
    @Published private(set) var totalSec: Int = 0
    @Published private(set) var running: Bool = false

    /// Ring fill 0→1 as rest elapses.
    var progress: Double { totalSec > 0 ? Double(totalSec - remainingSec) / Double(totalSec) : 0 }

    private var cancellable: AnyCancellable?
    private let notificationId = "RestTimer.done"
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Start a countdown adapted to the last set's effort. Cancels any
    /// in-flight timer + local notification first.
    func start(planned: Int, lastRepsInReserve: Int) {
        stop()
        let effective = Self.effectiveDuration(planned: planned, rir: lastRepsInReserve)
        remainingSec = effective
        totalSec = effective
        running = true
        cancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.remainingSec > 0 {
                    self.remainingSec -= 1
                } else {
                    self.stop()
                }
            }
        scheduleLocalNotification(after: TimeInterval(effective))
    }

    /// User tapped "пропустить" or started next set early.
    func skip() {
        stop()
        cancelLocalNotification()
    }

    private func stop() {
        cancellable?.cancel()
        cancellable = nil
        running = false
        totalSec = 0
    }

    // MARK: - Adaptation rule

    nonisolated static func effectiveDuration(planned: Int, rir: Int) -> Int {
        if rir == 0 { return planned + 30 }
        if rir >= 4 { return max(planned - 15, 30) }
        return planned
    }

    // MARK: - Local notification

    private func scheduleLocalNotification(after sec: TimeInterval) {
        cancelLocalNotification()
        let content = UNMutableNotificationContent()
        content.title = "Отдых закончился"
        content.body = "Готов к подходу?"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(sec, 1), repeats: false)
        let req = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
        center.add(req)
    }

    private func cancelLocalNotification() {
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
    }
}
