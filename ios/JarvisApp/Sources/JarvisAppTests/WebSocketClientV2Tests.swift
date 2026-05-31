import XCTest
import GRDB
@testable import Jarvis

/// 5.2b coverage: the facade preserves the legacy `WebSocketClient` observable
/// surface while internally driving `TransportV2` + `ConversationStoreV2`.
/// Tests here pin the public API shape — call sites will be swapped in 5.2c
/// without re-running these.
@MainActor
final class WebSocketClientV2Tests: XCTestCase {
    var dbq: DatabaseQueue!
    var store: ConversationStoreV2!
    var socket: MockWebSocket!
    var transport: TransportV2!
    var stack: AppV2Stack!
    var client: WebSocketClientV2!

    override func setUp() async throws {
        dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStoreV2(writer: dbq)
        socket = MockWebSocket()
        transport = TransportV2(store: store, socket: socket, token: "tok",
                                 ackTimeoutSeconds: 0.2, dispatcherIntervalMs: 50)
        let coord = AppContextCoordinator()
        stack = AppV2Stack(store: store, transport: transport, coordinator: coord, dbq: dbq)
        client = WebSocketClientV2(stack: stack)
    }

    // MARK: - Outbound

    func testSendEnqueuesQueuedRowAndTicksDispatcher() async throws {
        client.conversationId = UUID()
        client.send(text: "hello world", timezone: "UTC", status: nil)

        // Authed → tickDispatcher drains the queued row to sending.
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)
        // Tiny yield so the Task that calls tickDispatcher from `send` has a
        // chance to run before we assert (it races with handleAuthOk's own
        // tick, but either order leaves the row at `sending`).
        try await Task.sleep(nanoseconds: 50_000_000)

        let queued = try store.queuedOutbound()
        XCTAssertEqual(queued.count, 0, "row should have been drained to sending")
        let sent = socket.sent
        XCTAssertTrue(
            sent.contains(where: { (try? JSONDecoder().decode(V2.Envelope.self, from: $0))?.type == .message }),
            "transport should have emitted a message envelope"
        )
    }

    func testSendUpdatesLastUserSentAt() {
        client.conversationId = UUID()
        XCTAssertNil(client.lastUserSentAt)
        client.send(text: "hi", timezone: "UTC", status: nil)
        XCTAssertNotNil(client.lastUserSentAt)
    }

    func testIsBusyTrueAfterSendFalseAfterAssistantReply() async throws {
        let cid = UUID()
        client.conversationId = cid
        client.send(text: "hi", timezone: "UTC", status: nil)
        XCTAssertTrue(client.isBusy, "should be busy right after sending")

        // Simulate inbound assistant message arriving via the transport.
        let inbound = V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: "asst-1", seq: 1,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .message(V2.Message(thread_id: cid.uuidString, text: "yo",
                                          attachments: nil, context: nil))
        )
        let data = try JSONEncoder().encode(inbound)
        try await transport.handleIncoming(data)
        // ValueObservation propagation is async; poll until propagated or
        // timeout. Simulator can be slow under suite load.
        let deadline = Date().addingTimeInterval(2.0)
        while client.lastAssistantAt == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(client.lastAssistantAt)
        XCTAssertFalse(client.isBusy, "assistant reply should clear busy")
    }

    // MARK: - Control envelopes

    func testSendNewConversationEmitsControlEnvelope() async throws {
        client.sendNewConversation(id: UUID())
        try await Task.sleep(nanoseconds: 100_000_000)
        let envelopes = socket.sent.compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
        XCTAssertTrue(envelopes.contains(where: { $0.type == .newConversation && $0.kind == .control }))
    }

    func testSendFeedbackEmitsControlEnvelope() async throws {
        client.sendFeedback(conversationId: nil, messageId: "m-1", value: true, messageText: "any")
        try await Task.sleep(nanoseconds: 100_000_000)
        let envelopes = socket.sent.compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
        guard let env = envelopes.first(where: { $0.type == .feedback }) else {
            XCTFail("expected a feedback envelope"); return
        }
        if case .feedback(let f) = env.payload {
            XCTAssertEqual(f.message_id, "m-1")
            XCTAssertEqual(f.kind, "up")
        } else {
            XCTFail("payload mismatch")
        }
    }

    func testSendActionResponseEmitsControlEnvelope() async throws {
        client.sendActionResponse(messageId: "m-2", buttonId: "yes", buttonLabel: "Yes")
        try await Task.sleep(nanoseconds: 100_000_000)
        let envelopes = socket.sent.compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
        guard let env = envelopes.first(where: { $0.type == .actionResponse }) else {
            XCTFail("expected an action_response envelope"); return
        }
        if case .actionResponse(let a) = env.payload {
            XCTAssertEqual(a.action_id, "m-2")
            XCTAssertEqual(a.choice, "yes")
        } else {
            XCTFail("payload mismatch")
        }
    }

    // MARK: - Status envelopes

    func testSendMessageReadEmitsStatusEnvelopeOnceWhenConnected() async throws {
        client.isConnected = true
        client.sendMessageRead("m-1", conversationId: nil)
        client.sendMessageRead("m-1", conversationId: nil) // dedup
        try await Task.sleep(nanoseconds: 100_000_000)
        let statusReads = socket.sent.compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .filter { $0.type == .read && $0.kind == .status }
        XCTAssertEqual(statusReads.count, 1, "read receipt should dedup by messageId")
    }

    func testSendMessageReadSkippedWhenOffline() async throws {
        client.isConnected = false
        client.sendMessageRead("m-1", conversationId: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(
            socket.sent.contains(where: { (try? JSONDecoder().decode(V2.Envelope.self, from: $0))?.type == .read }),
            "no read receipt when offline"
        )
    }

    func testSendMessageDeliveredEmitsStatusEnvelopeWhenConnected() async throws {
        client.isConnected = true
        client.sendMessageDelivered("m-9", conversationId: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        let statusDelivered = socket.sent.compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .filter { $0.type == .delivered && $0.kind == .status }
        XCTAssertEqual(statusDelivered.count, 1)
    }

    // MARK: - Observation

    func testMessagesPopulatedFromStoreAfterSend() async throws {
        let cid = UUID()
        client.conversationId = cid
        client.send(text: "first", timezone: "UTC", status: nil)
        try await waitUntil { self.client.messages.count == 1 }
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.role, .user)
        XCTAssertEqual(client.messages.first?.text, "first")
    }

    func testConversationIdChangeReplacesMessagesView() async throws {
        let a = UUID()
        let b = UUID()
        client.conversationId = a
        client.send(text: "in-a", timezone: "UTC", status: nil)
        try await waitUntil { self.client.messages.count == 1 }
        XCTAssertEqual(client.messages.count, 1)

        client.conversationId = b
        try await waitUntil { self.client.messages.isEmpty }
        XCTAssertEqual(client.messages.count, 0, "switching conversation should drop the view")
    }

    // MARK: - Helpers

    /// Poll `condition` every 50ms up to `timeout` seconds. Returns when true
    /// or the deadline hits — leaves the assertion to the caller. Used to
    /// remove sleep-based flakes around GRDB's `ValueObservation` propagation.
    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - retrySend

    func testRetrySendFlipsFailedRowBackToQueued() async throws {
        let cid = UUID()
        client.conversationId = cid
        let id = UUID().uuidString
        try store.insertOutboundUserMessage(conversationId: cid.uuidString, id: id,
                                            text: "hi", attachments: [], context: nil)
        try store.markSending(id: id, seq: 7)
        try store.markFailed(id: id, reason: "network")
        XCTAssertEqual(try store.fetchById(id)?.status, .failed)

        client.retrySend(id: id)
        // Synchronous store mutation happens before the Task fires, so the row
        // should be back to queued immediately.
        let row = try XCTUnwrap(try store.fetchById(id))
        XCTAssertEqual(row.status, .queued)
        XCTAssertNil(row.seq)
    }

    // MARK: - auth_ok commands

    func testCommandsPopulatedFromAuthOk() async throws {
        // Wire the callback (init already did, but if the Task hasn't run yet,
        // give it a moment).
        try await Task.sleep(nanoseconds: 100_000_000)

        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .control, type: .authOk,
            id: UUID().uuidString, seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .authOk(V2.AuthOk(
                last_seen_outbound_seq: 0,
                server_time: ISO8601DateFormatter().string(from: Date()),
                commands: [
                    V2.Command(command: "/new", description: "start new"),
                    V2.Command(command: "/help", description: "show help"),
                ]
            ))
        )
        try await transport.handleIncoming(JSONEncoder().encode(env))
        // Hop to MainActor publishes through a nested Task — wait for it.
        let deadline = Date().addingTimeInterval(2.0)
        while client.commands.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(client.commands.count, 2)
        XCTAssertEqual(client.commands.first?.command, "/new")
        XCTAssertEqual(client.commands.first?.description, "start new")
    }

    func testCommandsClearedWhenAuthOkOmitsThem() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        // Seed with a stale catalogue.
        client.commands = [BotCommand(command: "/stale", description: "old")]

        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .control, type: .authOk,
            id: UUID().uuidString, seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .authOk(V2.AuthOk(
                last_seen_outbound_seq: 0,
                server_time: ISO8601DateFormatter().string(from: Date()),
                commands: nil
            ))
        )
        try await transport.handleIncoming(JSONEncoder().encode(env))
        let deadline = Date().addingTimeInterval(2.0)
        while !client.commands.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(client.commands.isEmpty)
    }

    // MARK: - Connection callback

    func testIsConnectedTogglingFiresOnConnectionChanged() {
        var observed: [Bool] = []
        client.onConnectionChanged = { observed.append($0) }
        client.isConnected = true
        client.isConnected = true // no duplicate
        client.isConnected = false
        XCTAssertEqual(observed, [true, false])
    }
}
