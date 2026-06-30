import XCTest
import GRDB
import UserNotifications
@testable import Jarvis

final class SummaryNotifierTests: XCTestCase {
    // Reuse the same mock-center pattern from LocalNotifierTests.
    final class RecordingCenter: NotificationScheduling {
        var requests: [UNNotificationRequest] = []
        func schedule(_ request: UNNotificationRequest) { requests.append(request) }
    }

    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    /// Schedules when all gating passes: enabled, not foreground, not quiet hours.
    /// Per-agent mute is ON for "jarvis" but must be IGNORED for summary notifications.
    func testSchedulesWhenEnabled() throws {
        let center = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(
            center: center,
            isForeground: { false },
            isEnabled: { true },
            isMuted: { _ in true },       // per-agent mute ON — must be ignored for summary
            inQuietHours: { false },
            isSummaryEnabled: { true }
        )
        n.configure(store: store)
        n.raiseSummaryReady(id: "summary-owner-2026-06-30", date: "2026-06-30", count: 5, agentId: "jarvis")
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertTrue(center.requests[0].content.body.contains("5"))
        XCTAssertEqual(center.requests[0].content.categoryIdentifier, NotificationCategories.summaryReady)
    }

    /// Suppressed when the dedicated «Сводка» toggle is off.
    func testSuppressedWhenSummaryToggleOff() throws {
        let center = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(
            center: center,
            isForeground: { false },
            isEnabled: { true },
            isMuted: { _ in false },
            inQuietHours: { false },
            isSummaryEnabled: { false }
        )
        n.configure(store: store)
        n.raiseSummaryReady(id: "x", date: "2026-06-30", count: 5, agentId: "jarvis")
        XCTAssertEqual(center.requests.count, 0)
    }

    /// Suppressed when the global notifications setting is off.
    func testSuppressedWhenGlobalDisabled() throws {
        let center = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(
            center: center,
            isForeground: { false },
            isEnabled: { false },
            isMuted: { _ in false },
            inQuietHours: { false },
            isSummaryEnabled: { true }
        )
        n.configure(store: store)
        n.raiseSummaryReady(id: "y", date: "2026-06-30", count: 3, agentId: "jarvis")
        XCTAssertEqual(center.requests.count, 0)
    }

    /// Suppressed during quiet hours.
    func testSuppressedInQuietHours() throws {
        let center = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(
            center: center,
            isForeground: { false },
            isEnabled: { true },
            isMuted: { _ in false },
            inQuietHours: { true },
            isSummaryEnabled: { true }
        )
        n.configure(store: store)
        n.raiseSummaryReady(id: "z", date: "2026-06-30", count: 3, agentId: "jarvis")
        XCTAssertEqual(center.requests.count, 0)
    }

    /// Deduplicates by id: second call with the same id must not schedule again.
    func testDedupsById() throws {
        let center = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(
            center: center,
            isForeground: { false },
            isEnabled: { true },
            isMuted: { _ in false },
            inQuietHours: { false },
            isSummaryEnabled: { true }
        )
        n.configure(store: store)
        n.raiseSummaryReady(id: "summary-owner-2026-06-30", date: "2026-06-30", count: 5, agentId: "jarvis")
        n.raiseSummaryReady(id: "summary-owner-2026-06-30", date: "2026-06-30", count: 5, agentId: "jarvis")
        XCTAssertEqual(center.requests.count, 1, "same id must not notify twice")
    }
}
