import XCTest
import GRDB
import UserNotifications
@testable import Jarvis

final class LocalNotifierTests: XCTestCase {
    final class RecordingCenter: NotificationScheduling {
        var requests: [UNNotificationRequest] = []
        func schedule(_ request: UNNotificationRequest) { requests.append(request) }
    }

    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    func testRaisesWhenBackgroundedAndEnabled() throws {
        let rec = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true })
        n.configure(store: store)

        n.raise(id: "m1", agentId: "greg", text: "Готовность 68", seq: 3)
        XCTAssertEqual(rec.requests.count, 1)
        let content = rec.requests[0].content
        XCTAssertEqual(content.body, "Готовность 68")
        XCTAssertEqual(content.threadIdentifier, "greg")
        // Title comes from the agent's display name.
        XCTAssertEqual(content.title, AgentIdentity(rawValue: "greg")?.displayName ?? "Jarvis")
        XCTAssertEqual(content.categoryIdentifier, "agent-message")
        XCTAssertEqual(content.userInfo["agentId"] as? String, "greg")
        XCTAssertEqual(content.userInfo["msgId"] as? String, "m1")
        XCTAssertTrue(try store.notifiedSeen(id: "m1"))
    }

    func testDedupsById() throws {
        let rec = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true })
        n.configure(store: store)
        n.raise(id: "m1", agentId: "jarvis", text: "x", seq: 1)
        n.raise(id: "m1", agentId: "jarvis", text: "x", seq: 1)
        XCTAssertEqual(rec.requests.count, 1, "same id must not notify twice")
    }

    func testSuppressedWhenForegroundOrDisabled() throws {
        let store = try makeStore()

        let fg = RecordingCenter()
        let nFg = LocalNotifier(center: fg, isForeground: { true }, isEnabled: { true })
        nFg.configure(store: store)
        nFg.raise(id: "a", agentId: "jarvis", text: "x", seq: 1)
        XCTAssertEqual(fg.requests.count, 0, "foreground-active → no notification")

        let off = RecordingCenter()
        let nOff = LocalNotifier(center: off, isForeground: { false }, isEnabled: { false })
        nOff.configure(store: store)
        nOff.raise(id: "b", agentId: "jarvis", text: "x", seq: 1)
        XCTAssertEqual(off.requests.count, 0, "setting off → no notification")
    }

    func testNoOpBeforeConfigure() throws {
        let rec = RecordingCenter()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true })
        // intentionally NOT configured
        n.raise(id: "x", agentId: "jarvis", text: "hello", seq: 1)
        XCTAssertEqual(rec.requests.count, 0)
    }

    func testTruncatesLongBody() throws {
        let rec = RecordingCenter()
        let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true })
        n.configure(store: store)
        n.raise(id: "m1", agentId: "jarvis", text: String(repeating: "x", count: 400), seq: 1)
        XCTAssertLessThanOrEqual(rec.requests[0].content.body.count, 160)
    }

    func testSuppressedWhenAgentMuted() throws {
        let rec = RecordingCenter(); let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true },
                              isMuted: { $0 == "greg" }, inQuietHours: { false })
        n.configure(store: store)
        n.raise(id: "m1", agentId: "greg", text: "x", seq: 1)
        XCTAssertEqual(rec.requests.count, 0, "muted agent → no notification")
        n.raise(id: "m2", agentId: "jarvis", text: "y", seq: 1)
        XCTAssertEqual(rec.requests.count, 1, "non-muted agent still notifies")
    }

    func testSuppressedDuringQuietHours() throws {
        let rec = RecordingCenter(); let store = try makeStore()
        let n = LocalNotifier(center: rec, isForeground: { false }, isEnabled: { true },
                              isMuted: { _ in false }, inQuietHours: { true })
        n.configure(store: store)
        n.raise(id: "m1", agentId: "jarvis", text: "x", seq: 1)
        XCTAssertEqual(rec.requests.count, 0, "quiet hours → no notification")
    }
}
