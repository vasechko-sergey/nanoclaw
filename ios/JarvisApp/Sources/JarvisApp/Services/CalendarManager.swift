import EventKit
import Foundation

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
}
