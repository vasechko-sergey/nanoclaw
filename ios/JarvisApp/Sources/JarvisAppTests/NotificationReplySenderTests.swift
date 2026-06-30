import XCTest
import GRDB
@testable import Jarvis

final class NotificationReplySenderTests: XCTestCase {
    func testBuildRequestTargetsReplyRoute() throws {
        let req = ReplyRequest.build(token: "tok", agentId: "greg", text: "привет")
        let r = try XCTUnwrap(req)
        XCTAssertEqual(r.url?.path, "/ios/reply")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try XCTUnwrap(r.httpBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(obj["text"], "привет")
        XCTAssertEqual(obj["agent_id"], "greg")
    }

    func testEchoIsNotQueuedForResend() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        // status 'sent' (terminal) — the WS drain (queuedOutbound filters status='queued') must NOT pick it up.
        try store.insertOutboundUserMessage(
            id: "echo-1", text: "hi", attachments: [], context: nil, agentId: "greg", status: "sent"
        )
        XCTAssertTrue(try store.queuedOutbound(agentId: "greg").isEmpty, "echo must not be re-sent")
        let total = try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages WHERE dir='out'") }
        XCTAssertEqual(total, 1, "echo row is present in the timeline")
    }
}
