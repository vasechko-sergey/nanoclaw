import EventKit
import Foundation
import UserNotifications

/// Ближайшее событие календаря как контекст для агента. Кэшируется, обновляется при подключении.
final class CalendarManager: ObservableObject {
    @Published var nextEvent: (title: String, start: Date)?

    private let store = EKEventStore()

    func requestAndFetch() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard granted else { return }
            self?.fetchNext()
        }
    }

    private func fetchNext() {
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: 18, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= now }
            .min { $0.startDate < $1.startDate }
        DispatchQueue.main.async {
            self.nextEvent = next.map { ($0.title ?? "Событие", $0.startDate) }
        }
    }

    /// Schedule a silent local notification 15 minutes before the event start.
    /// On fire, the UNUserNotificationCenterDelegate routes to the proactive
    /// dispatcher and suppresses the system banner.
    func scheduleCalendarWarn(for event: EKEvent) {
        let fireDate = event.startDate.addingTimeInterval(-15 * 60)
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.userInfo = [
            "proactive": true,
            "type": "calendar_warn",
            "title": event.title ?? "",
            "start": ISO8601DateFormatter().string(from: event.startDate),
        ]
        content.sound = nil
        content.title = event.title ?? "Event"

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: fireDate.timeIntervalSinceNow,
            repeats: false
        )
        let req = UNNotificationRequest(identifier: "calendar-\(event.eventIdentifier ?? UUID().uuidString)",
                                        content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
}
