import XCTest
import GRDB
@testable import Jarvis

final class MockWebSocket: WebSocketLike, @unchecked Sendable {
    var sent: [Data] = []
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    var connectCalled = false

    func connect() async throws { connectCalled = true }
    func send(_ data: Data) async throws { sent.append(data) }
    func close() {}
}

final class TransportV2Tests: XCTestCase {
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

    func encodeAck(id: String) -> Data {
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .ack, type: .ack,
            id: UUID().uuidString, seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .ack(V2.Ack(id: id, seq: 1))
        )
        return try! JSONEncoder().encode(env)
    }

    func encodeInbound(id: String, seq: Int, threadID: String, text: String) -> Data {
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: id, seq: seq,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .message(V2.Message(thread_id: threadID, text: text,
                                          attachments: nil, context: nil))
        )
        return try! JSONEncoder().encode(env)
    }

    func testSendQueuedMessageGoesSending() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi", attachments: [], context: nil
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)  // triggers tickDispatcher
        let row = try XCTUnwrap(try store.fetchById("msg-1"))
        XCTAssertEqual(row.status, .sending)
        XCTAssertNotNil(row.seq)
    }

    func testAckMovesSendingToSent() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi", attachments: [], context: nil
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)
        try await transport.handleIncoming(encodeAck(id: "msg-1"))
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .sent)
    }

    func testReconnectResetsSendingToQueued() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi", attachments: [], context: nil
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)  // seq=1 allocated
        let firstSeq = try store.fetchById("msg-1")?.seq
        XCTAssertEqual(firstSeq, 1)
        // Server says it only acknowledged up through 0 — our seq=1 should reset to
        // queued and then be re-dispatched with a new seq.
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)
        let row = try XCTUnwrap(try store.fetchById("msg-1"))
        // Reset happened (briefly queued) then redispatch allocated a fresh seq.
        XCTAssertEqual(row.status, .sending)
        XCTAssertNotEqual(row.seq, firstSeq, "seq should have been re-allocated after reset")
    }

    func testReconnectConfirmsAckedSeqAsSent() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi", attachments: [], context: nil
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)  // seq=1, sending
        // Server confirms it received seq<=1 — our message should be marked sent.
        try await transport.handleAuthOk(lastSeenOutboundSeq: 1)
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .sent)
    }

    func testInboundDedupByID() async throws {
        let id = "in-1"
        try await transport.handleIncoming(encodeInbound(id: id, seq: 1, threadID: "c-1", text: "hello"))
        try await transport.handleIncoming(encodeInbound(id: id, seq: 1, threadID: "c-1", text: "hello"))
        // Only one row inserted
        let count = try store.queuedOutbound().count + (try store.fetchById(id) != nil ? 1 : 0)
        XCTAssertEqual(count, 1)
        // Both acks sent (one per incoming)
        let acks = socket.sent.filter { data in
            (try? JSONDecoder().decode(V2.Envelope.self, from: data))?.type == .ack
        }
        XCTAssertEqual(acks.count, 2)
    }

    func testRetryAfterAckTimeout() async throws {
        try store.insertOutboundUserMessage(
            conversationId: "c-1", id: "msg-1", text: "hi", attachments: [], context: nil
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)
        let firstCount = socket.sent.count
        try await Task.sleep(nanoseconds: 350_000_000)  // > ack timeout (0.2s)
        let later = socket.sent.count
        XCTAssertGreaterThan(later, firstCount)
    }
}
