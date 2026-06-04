import XCTest
import GRDB
@testable import Jarvis

@MainActor
final class MessageTimelineTests: XCTestCase {
    private func makeStore() throws -> (DatabaseQueue, ConversationStoreV2) {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return (dbq, ConversationStoreV2(writer: dbq))
    }

    func test_outbound_insert_then_markSent_visible() async throws {
        let (dbq, store) = try makeStore()
        let tl = MessageTimeline(store: store, dbq: dbq)
        try await tl.start()

        let msg = try tl.insertOutbound(text: "hello", attachments: [], context: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tl.messages.count, 1)
        XCTAssertEqual(tl.messages.first?.text, "hello")

        try store.markSent(id: msg.id, serverTS: 12345)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tl.messages.first?.status, .sent)
    }

    func test_inbound_dedup_keeps_one() async throws {
        let (dbq, store) = try makeStore()
        let tl = MessageTimeline(store: store, dbq: dbq)
        try await tl.start()

        let m = V2.Message(thread_id: "ios:default", text: "hi", attachments: nil, context: nil)
        let env = V2.Envelope(
            v: 2,
            kind: .data,
            type: .message,
            id: "abc",
            seq: 1,
            ts: "2026-06-04T00:00:00Z",
            payload: .message(m)
        )

        try tl.insertInboundIfNew(envelope: env, message: m)
        try tl.insertInboundIfNew(envelope: env, message: m)   // dedup

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tl.messages.filter { $0.text == "hi" }.count, 1)
    }

    func test_prune_caps_to_limit() async throws {
        let (dbq, store) = try makeStore()
        let tl = MessageTimeline(store: store, dbq: dbq, retention: 3)
        try await tl.start()

        for i in 0..<5 {
            _ = try tl.insertOutbound(text: "m\(i)", attachments: [], context: nil)
            // Ensure ts ordering is deterministic even on fast machines.
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tl.messages.count, 3)
        XCTAssertEqual(tl.messages.map { $0.text }, ["m2", "m3", "m4"])
    }
}
