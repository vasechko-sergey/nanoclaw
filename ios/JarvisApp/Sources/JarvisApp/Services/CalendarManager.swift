import EventKit
import Foundation
import UserNotifications

/// Ближайшее событие календаря как контекст для агента. Кэшируется, обновляется при подключении.
final class CalendarManager: ObservableObject {
    @Published var nextEvent: (title: String, start: Date)?

    /// When true, fetchAndScheduleProactive() schedules 15-min warns for upcoming events.
    var proactiveEnabled: Bool = false

    private let store = EKEventStore()

    func requestAndFetch() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard granted else { return }
            self?.fetchNext()
            Task { [weak self] in
                await self?.fetchAndScheduleProactive()
            }
        }
    }

    /// Pull the next 24h of events and schedule a 15-min proactive warn for each
    /// when proactiveCalendarWarn opt-in is on. Re-adding a request with the same
    /// identifier replaces the pending one, so this is safe to call repeatedly.
    func fetchAndScheduleProactive(now: Date = Date()) async {
        guard proactiveEnabled else { return }
        let predicate = store.predicateForEvents(withStart: now,
                                                  end: now.addingTimeInterval(24 * 3600),
                                                  calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= now }
        for ev in events {
            scheduleCalendarWarn(for: ev)
        }
    }

    // MARK: - Window helpers

    /// Returns the end date for a named calendar window starting at `start`.
    /// - "next_7d"  → start + 7 days
    /// - "next_30d" → start + 30 days
    /// - anything else (incl. "today") → start + 24 hours
    static func windowEnd(window: String, from start: Date) -> Date {
        switch window {
        case "next_7d":  return start.addingTimeInterval(7 * 24 * 3600)
        case "next_30d": return start.addingTimeInterval(30 * 24 * 3600)
        default:         return start.addingTimeInterval(24 * 3600)   // "today"
        }
    }

    /// Returns all non-all-day events between now and the window end, sorted by start time.
    /// Must be called on the main thread (reads from `EKEventStore` directly).
    func events(window: String) -> [(title: String, start: Date, end: Date)] {
        let now = Date()
        let pred = store.predicateForEvents(
            withStart: now,
            end: Self.windowEnd(window: window, from: now),
            calendars: nil
        )
        return store.events(matching: pred)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map { ($0.title ?? "", $0.startDate, $0.endDate) }
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

    /// Incomplete reminders due on/before the window end. Empty if access denied.
    func reminders(window: String = "today") async -> [(title: String, due: Date?)] {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { return [] }
        let pred = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: Self.windowEnd(window: window, from: Date()),
            calendars: nil)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { rems in
                cont.resume(returning: (rems ?? []).map { ($0.title ?? "", $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) }) })
            }
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
