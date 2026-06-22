import XCTest
import GRDB
@testable import Jarvis

/// Single-chat coverage: the facade preserves the observable surface needed
/// by views while internally driving `TransportV2` + `ConversationStoreV2`.
/// Conversation-aware tests (per-thread filtering, `sendNewConversation`,
/// conversation switching) were retired in v3-single-chat alongside the
/// `conversation_id` column.
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
        stack = AppV2Stack(store: store, transport: transport, coordinator: coord, dbq: dbq,
                            setLogQueue: SetLogQueue(writer: dbq))
        client = WebSocketClientV2(stack: stack)
    }

    // MARK: - Outbound

    func testSendEnqueuesQueuedRowAndTicksDispatcher() async throws {
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
        XCTAssertNil(client.lastUserSentAt["jarvis"])
        client.send(text: "hi", timezone: "UTC", status: nil)   // default agentId "jarvis"
        XCTAssertNotNil(client.lastUserSentAt["jarvis"])
    }

    /// The fix: busy is per-agent. Sending to one agent must NOT mark others busy
    /// (previously a global flag lit "thinking" in every agent's chat).
    func testBusyIsPerAgent() {
        client.send(text: "hi payne", timezone: "UTC", status: nil, agentId: "payne")
        XCTAssertTrue(client.isBusy(agentId: "payne"), "the messaged agent is busy")
        XCTAssertFalse(client.isBusy(agentId: "jarvis"), "other agents are NOT busy")
        XCTAssertFalse(client.isBusy(agentId: "greg"), "other agents are NOT busy")
    }

    func testIsBusyTrueAfterSendFalseAfterAssistantReply() async throws {
        client.send(text: "hi", timezone: "UTC", status: nil)
        XCTAssertTrue(client.isBusy(agentId: "jarvis"), "should be busy right after sending")

        // Simulate inbound assistant message arriving via the transport.
        let inbound = V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: "asst-1", seq: 1,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .message(V2.Message(thread_id: "ios:default", text: "yo",
                                          attachments: nil, context: nil))
        )
        let data = try JSONEncoder().encode(inbound)
        try await transport.handleIncoming(data)
        // ValueObservation propagation is async; poll until propagated or
        // timeout. Simulator can be slow under suite load.
        let deadline = Date().addingTimeInterval(2.0)
        while client.lastAssistantAt["jarvis"] == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(client.lastAssistantAt["jarvis"])
        XCTAssertFalse(client.isBusy(agentId: "jarvis"), "assistant reply should clear busy")
    }

    // MARK: - Control envelopes

    func testSendFeedbackEmitsControlEnvelope() async throws {
        client.sendFeedback(messageId: "m-1", value: true, messageText: "any")
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
        client.sendMessageRead("m-1")
        client.sendMessageRead("m-1") // dedup
        try await Task.sleep(nanoseconds: 100_000_000)
        let statusReads = socket.sent.compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .filter { $0.type == .read && $0.kind == .status }
        XCTAssertEqual(statusReads.count, 1, "read receipt should dedup by messageId")
    }

    func testSendMessageReadSkippedWhenOffline() async throws {
        client.isConnected = false
        client.sendMessageRead("m-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(
            socket.sent.contains(where: { (try? JSONDecoder().decode(V2.Envelope.self, from: $0))?.type == .read }),
            "no read receipt when offline"
        )
    }

    func testSendMessageDeliveredEmitsStatusEnvelopeWhenConnected() async throws {
        client.isConnected = true
        client.sendMessageDelivered("m-9")
        try await Task.sleep(nanoseconds: 100_000_000)
        let statusDelivered = socket.sent.compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .filter { $0.type == .delivered && $0.kind == .status }
        XCTAssertEqual(statusDelivered.count, 1)
    }

    // MARK: - Observation

    func testMessagesPopulatedFromStoreAfterSend() async throws {
        client.send(text: "first", timezone: "UTC", status: nil)
        try await waitUntil { self.client.messages.count == 1 }
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.role, .user)
        XCTAssertEqual(client.messages.first?.text, "first")
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
        let id = UUID().uuidString
        try store.insertOutboundUserMessage(id: id,
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
