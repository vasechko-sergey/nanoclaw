import XCTest
@testable import Jarvis

final class PendingNotificationsTests: XCTestCase {
    func testParseValidBody() throws {
        let json = """
        {"messages":[
          {"id":"m1","seq":3,"type":"message","agent_id":"jarvis","text":"hi"},
          {"id":"m2","seq":5,"type":"message","agent_id":"greg","text":"готовность 68"}
        ]}
        """.data(using: .utf8)!
        let msgs = PendingNotifications.parse(json)
        XCTAssertEqual(msgs.map(\.id), ["m1", "m2"])
        XCTAssertEqual(msgs[1].agent_id, "greg")
        XCTAssertEqual(msgs[1].seq, 5)
        XCTAssertEqual(msgs[0].type, "message")
    }

    func testParseToleratesNullAgentAndEmpty() throws {
        XCTAssertEqual(PendingNotifications.parse(Data("{}".utf8)).count, 0)
        XCTAssertEqual(PendingNotifications.parse(Data("garbage".utf8)).count, 0)
        let nullAgent = Data(#"{"messages":[{"id":"m1","seq":1,"agent_id":null,"text":"x"}]}"#.utf8)
        let msgs = PendingNotifications.parse(nullAgent)
        XCTAssertEqual(msgs.first?.agent_id, nil)
    }

    /// `type` is optional: a pre-`type` host (omits the field) still decodes,
    /// and `drain()` falls through to the agent-message path for nil/unknown.
    func testParseToleratesMissingType() throws {
        let noType = Data(#"{"messages":[{"id":"m1","seq":1,"agent_id":"jarvis","text":"x"}]}"#.utf8)
        let msgs = PendingNotifications.parse(noType)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertNil(msgs.first?.type)
    }

    /// A `summary_ready` pending row decodes carrying `type == "summary_ready"`.
    /// This is the seam `drain()` branches on to route to the «Сводка» board
    /// notifier (vs the agent-message notifier) on the background pull path.
    ///
    /// NOTE: the routing in `drain()` itself fans out through the
    /// `LocalNotifier.shared` singleton, which is not injectable, so the
    /// branch-to-notifier dispatch is not unit-testable here without a refactor.
    /// We assert the decode carries `type` (the routing key); the dispatch each
    /// branch performs is covered by `SummaryNotifierTests` (raiseSummaryReady)
    /// and `LocalNotifierTests` (raise).
    func testParseCarriesSummaryReadyType() throws {
        let json = Data(#"""
        {"messages":[
          {"id":"summary-owner-2026-06-30","seq":12,"type":"summary_ready","agent_id":"jarvis","text":"Сводка готова · 5 карточек"},
          {"id":"m2","seq":13,"type":"message","agent_id":"greg","text":"готовность 68"}
        ]}
        """#.utf8)
        let msgs = PendingNotifications.parse(json)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].type, "summary_ready")
        XCTAssertEqual(msgs[0].text, "Сводка готова · 5 карточек")
        XCTAssertEqual(msgs[1].type, "message")
    }
}
