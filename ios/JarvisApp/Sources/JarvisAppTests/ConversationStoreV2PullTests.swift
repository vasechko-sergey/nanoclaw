import XCTest
import GRDB
@testable import Jarvis

/// Pull-path text-stub insert + WS upsert-upgrade (build 77, Task 6).
final class ConversationStoreV2PullTests: XCTestCase {
    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    /// Read one column of a row by id (test seam via the internal `writer`).
    private func col(_ store: ConversationStoreV2, _ id: String, _ name: String) throws -> String? {
        try store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT \(name) FROM messages WHERE id = ?", arguments: [id])
        }
    }

    private func wsMessage(id: String, text: String, attachments: [V2.Attachment]? = nil) -> (V2.Envelope, V2.Message) {
        let m = V2.Message(thread_id: "t", text: text, attachments: attachments, agent_id: "jarvis")
        let e = V2.Envelope(v: 2, kind: .data, type: .message, id: id, seq: 5,
                            ts: "2026-06-30T00:00:01.000Z", payload: .message(m))
        return (e, m)
    }

    func testInsertInboundFromPullIsIdempotent() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "m1", seq: 10, text: "hi", agentId: "jarvis", ts: 1000)
        try store.insertInboundFromPull(id: "m1", seq: 10, text: "hi", agentId: "jarvis", ts: 1000)
        XCTAssertEqual(try store.countAllMessages(), 1) // no duplicate
    }

    func testWSUpsertUpgradesPullStub() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "m1", seq: 5, text: "caption", agentId: "jarvis", ts: 1000)
        XCTAssertNil(try col(store, "m1", "attachments_json")) // stub: text only

        let att = V2.Attachment(id: "a1", kind: "image", name: "p.jpg", mime_type: "image/jpeg",
                                byte_size: 10, bytes_base64: "AAAA", remote_id: nil)
        let (e, m) = wsMessage(id: "m1", text: "caption", attachments: [att])
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")

        XCTAssertEqual(try store.countAllMessages(), 1)              // still one row
        XCTAssertNotNil(try col(store, "m1", "attachments_json"))    // upgraded with attachment
    }

    func testWSUpsertPreservesReadStatus() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "m2", seq: 6, text: "hi", agentId: "jarvis", ts: 1000)
        try store.markRead(ids: ["m2"])
        let (e, m) = wsMessage(id: "m2", text: "hi")
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")
        XCTAssertEqual(try col(store, "m2", "status"), "read")       // NOT reset to 'new'
    }

    func testWSUpsertSkipsEditedRow() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "m3", seq: 7, text: "orig", agentId: "jarvis", ts: 1000)
        _ = try store.updateMessageText(id: "m3", text: "corrected") // edited = 1
        let (e, m) = wsMessage(id: "m3", text: "orig")
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")
        XCTAssertEqual(try col(store, "m3", "text"), "corrected")    // edit NOT reverted
    }
}
