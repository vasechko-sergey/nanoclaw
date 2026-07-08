import XCTest
import GRDB
@testable import Jarvis

/// F30 — per-agent unread tracking in the message store. "Unread" reuses the
/// existing `status` machinery: an inbound row (`dir='in'`) is inserted with
/// `status='new'` and nothing flips it to `read` except `markAgentRead` (the
/// drawer mark-read). Outbound rows start `queued`, so the user's own sends
/// never count. No parallel marker table.
final class UnreadCountingTests: XCTestCase {

    private func makeStore() throws -> ConversationStoreV2 {
        let queue = try DatabaseQueue() // in-memory
        try Schema.migrate(queue)
        return ConversationStoreV2(writer: queue)
    }

    /// Insert an inbound (agent → user) message via the real WS path so the row
    /// lands with `status='new'` exactly as production does.
    private func insertInbound(_ store: ConversationStoreV2,
                               id: String, agent: String, seq: Int) throws {
        let msg = V2.Message(thread_id: "t", text: "reply \(id)")
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: id, seq: seq, ts: "2026-06-22T00:00:00.000Z",
            payload: .message(msg)
        )
        try store.insertInbound(envelope: env, message: msg, agentId: agent)
    }

    func test_countUnread_countsInboundNewRows_perAgent() throws {
        let store = try makeStore()
        try insertInbound(store, id: "p1", agent: "payne", seq: 1)
        try insertInbound(store, id: "p2", agent: "payne", seq: 3)
        try insertInbound(store, id: "g1", agent: "greg",  seq: 5)

        XCTAssertEqual(try store.countUnread(agentId: "payne"), 2)
        XCTAssertEqual(try store.countUnread(agentId: "greg"), 1)
        XCTAssertEqual(try store.countUnread(agentId: "jarvis"), 0, "no messages → zero")
    }

    func test_markAgentRead_zeroesTargetAgent_leavesOthersUntouched() throws {
        let store = try makeStore()
        try insertInbound(store, id: "p1", agent: "payne", seq: 1)
        try insertInbound(store, id: "p2", agent: "payne", seq: 3)
        try insertInbound(store, id: "g1", agent: "greg",  seq: 5)

        let marked = try store.markAgentRead(agentId: "payne")
        XCTAssertEqual(marked, 2, "both payne inbound rows flip new→read")
        XCTAssertEqual(try store.countUnread(agentId: "payne"), 0, "target agent cleared")
        XCTAssertEqual(try store.countUnread(agentId: "greg"), 1, "other agent untouched")

        // Idempotent: marking an already-read agent marks nothing.
        XCTAssertEqual(try store.markAgentRead(agentId: "payne"), 0)
    }

    func test_outboundUserSends_neverCountAsUnread() throws {
        let store = try makeStore()
        // The user's own sends to payne — status 'queued', never 'new'.
        try store.insertOutboundUserMessage(id: "u1", text: "hi", attachments: [], context: nil, agentId: "payne")
        try store.insertOutboundUserMessage(id: "u2", text: "yo", attachments: [], context: nil, agentId: "payne")
        XCTAssertEqual(try store.countUnread(agentId: "payne"), 0, "own outbound sends are not unread")

        // One inbound reply arrives → exactly one unread.
        try insertInbound(store, id: "p1", agent: "payne", seq: 1)
        XCTAssertEqual(try store.countUnread(agentId: "payne"), 1)
    }

    func test_unreadCountsByAgent_groupsInboundNewRows() throws {
        let store = try makeStore()
        try insertInbound(store, id: "p1", agent: "payne", seq: 1)
        try insertInbound(store, id: "p2", agent: "payne", seq: 3)
        try insertInbound(store, id: "g1", agent: "greg",  seq: 5)
        try store.insertOutboundUserMessage(id: "u1", text: "hi", attachments: [], context: nil, agentId: "jarvis")

        let counts = try store.unreadCountsByAgent()
        XCTAssertEqual(counts["payne"], 2)
        XCTAssertEqual(counts["greg"], 1)
        XCTAssertNil(counts["jarvis"], "outbound-only agent absent from the map")

        try store.markAgentRead(agentId: "payne")
        let after = try store.unreadCountsByAgent()
        XCTAssertNil(after["payne"], "cleared agent drops out of the map")
        XCTAssertEqual(after["greg"], 1)
    }
}
