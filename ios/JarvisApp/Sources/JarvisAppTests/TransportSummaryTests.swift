import XCTest
import GRDB
@testable import Jarvis

/// TransportV2 must route `summary_ready` envelopes to `LocalNotifier` only —
/// no chat row inserted, but a `delivered` status is sent back to the host.
/// Uses the same `MockWebSocket` helper defined in `TransportV2Tests.swift`.
final class TransportSummaryTests: XCTestCase {
    var store: ConversationStoreV2!
    var transport: TransportV2!
    var socket: MockWebSocket!

    override func setUp() async throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStoreV2(writer: dbq)
        socket = MockWebSocket()
        transport = TransportV2(store: store, socket: socket, token: "tok",
                                ackTimeoutSeconds: 0.2, dispatcherIntervalMs: 50)
    }

    private func summaryReadyData(id: String = "summary-owner-2026-06-30", seq: Int = 12) -> Data {
        Data("""
        {"v":2,"kind":"data","type":"summary_ready","id":"\(id)","seq":\(seq),\
        "ts":"2026-06-30T00:52:00.000Z",\
        "payload":{"date":"2026-06-30","count":5,"text":"Сводка готова · 5 карточек","agent_id":"jarvis"}}
        """.utf8)
    }

    func testSummaryReadyDoesNotInsertChatRow() async throws {
        let before = try store.countAllMessages()
        try await transport.handleIncoming(summaryReadyData())
        XCTAssertEqual(try store.countAllMessages(), before, "summary_ready must not insert a chat row")
    }

    func testSummaryReadySendsDeliveredStatus() async throws {
        try await transport.handleIncoming(summaryReadyData(id: "summary-owner-2026-06-30"))

        let delivered = socket.sent
            .compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .first { $0.type == .delivered }
        let env = try XCTUnwrap(delivered, "summary_ready must send a delivered status")
        guard case let .statusBatch(s) = env.payload else {
            return XCTFail("expected statusBatch payload, got \(env.payload)")
        }
        XCTAssertEqual(s.ids, ["summary-owner-2026-06-30"])
    }

    func testSummaryReadyDedupSendsDeliveredWithoutExtraRow() async throws {
        // Feed the same envelope twice — dedup must prevent a second insert
        // (there is none for summary_ready) and still send delivered both times.
        try await transport.handleIncoming(summaryReadyData())
        try await transport.handleIncoming(summaryReadyData())

        let deliveredCount = socket.sent
            .compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .filter { $0.type == .delivered }
            .count
        XCTAssertEqual(deliveredCount, 2, "dedup path must still ack delivered on redelivery")
        XCTAssertEqual(try store.countAllMessages(), 0, "still no chat row after dedup redelivery")
    }
}
