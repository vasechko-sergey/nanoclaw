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

/// Minimal `ContextCoordinatorV2` for transport-layer tests. The cross-file
/// `MockCoordinator` in `InboundDispatcherV2Tests.swift` is `private`, so we
/// keep a separately-named clone here rather than promote it.
final class TransportTestCoordinator: ContextCoordinatorV2, @unchecked Sendable {
    func health() async throws -> V2.JSONValue { .object(["steps_today": .int(42)]) }
    func calendar() async throws -> V2.JSONValue { .array([]) }
    func device() async throws -> V2.JSONValue { .object(["model": .string("iPhone")]) }
    func nextEvent() async throws -> V2.JSONValue? { nil }
    func recentLocations(hours: Int) async throws -> V2.JSONValue { .array([]) }
    func screenState() async throws -> V2.JSONValue { .string("foreground") }
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

    func encodeAuthFail(reason: String) -> Data {
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .control, type: .authFail,
            id: UUID().uuidString, seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .authFail(V2.AuthFail(reason: reason))
        )
        return try! JSONEncoder().encode(env)
    }

    func encodeInbound(id: String, seq: Int, threadID: String, text: String, agentID: String? = nil) -> Data {
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: id, seq: seq,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .message(V2.Message(thread_id: threadID, text: text,
                                          attachments: nil, context: nil,
                                          agent_id: agentID))
        )
        return try! JSONEncoder().encode(env)
    }

    func testSendQueuedMessageGoesSending() async throws {
        try store.insertOutboundUserMessage(
            id: "msg-1", text: "hi", attachments: [], context: nil
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)  // triggers tickDispatcher
        let row = try XCTUnwrap(try store.fetchById("msg-1"))
        XCTAssertEqual(row.status, .sending)
        XCTAssertNotNil(row.seq)
    }

    func testAckMovesSendingToSent() async throws {
        try store.insertOutboundUserMessage(
            id: "msg-1", text: "hi", attachments: [], context: nil
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)
        try await transport.handleIncoming(encodeAck(id: "msg-1"))
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .sent)
    }

    func testAckRetryCapMarksFailed() async throws {
        // F2: a message the server never acks must not resend forever. After
        // maxAckRetries resend checks with no ack it is marked .failed (surfacing
        // the already-built failed row + retry button) instead of spinning an
        // uncapped 5s resend loop behind an eternal "sending" spinner.
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        let socket = MockWebSocket()
        let transport = TransportV2(store: store, socket: socket, token: "tok",
                                    ackTimeoutSeconds: 0.05, maxAckRetries: 3,
                                    dispatcherIntervalMs: 50)
        try store.insertOutboundUserMessage(id: "msg-1", text: "hi", attachments: [], context: nil)
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)   // -> sending, schedules retry
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .sending)

        // No ack ever arrives; wait past maxAckRetries * ackTimeout.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .failed)
    }

    func testAuthFailStopsReconnectLoop() async throws {
        // F1: a rejected token must stop the reconnect hammer (not loop forever)
        // and be recoverable once the token is fixed.
        try await transport.handleIncoming(encodeAuthFail(reason: "bad token"))
        let rejected = await transport.authRejected
        XCTAssertTrue(rejected)
        // connect() must no-op while rejected — no auth hammer.
        try await transport.connect()
        let s = await transport.state
        XCTAssertEqual(s, .idle, "must not reconnect with a rejected token")
        // Recovery: a fresh token + cleared rejection re-enables connect.
        await transport.updateToken("newtok")
        await transport.clearAuthRejection()
        try await transport.connect()
        let s2 = await transport.state
        XCTAssertEqual(s2, .connecting)
    }

    func testReconnectResetsSendingToQueued() async throws {
        try store.insertOutboundUserMessage(
            id: "msg-1", text: "hi", attachments: [], context: nil
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
            id: "msg-1", text: "hi", attachments: [], context: nil
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

    func testContextRequestRoutesToCoordinator() async throws {
        let coord = TransportTestCoordinator()
        transport = TransportV2(
            store: store, socket: socket, token: "tok",
            contextCoordinator: coord,
            ackTimeoutSeconds: 0.2, dispatcherIntervalMs: 50
        )
        let reqId = UUID().uuidString
        let request = V2.Envelope(
            v: V2.protocolVersion, kind: .control, type: .contextRequest,
            id: reqId, seq: 1,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .contextRequest(V2.ContextRequest(
                request_id: "r-1", fields: ["device", "health"], params: nil
            ))
        )
        try await transport.handleIncoming(try JSONEncoder().encode(request))

        // context_request is queued server-side but never cursor-acked, so the
        // client must confirm it by id (status:delivered) — the per-id ack that
        // removes it from the outbound queue.
        let delivered = socket.sent
            .compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .first { $0.type == .delivered }
        guard let deliveredEnv = delivered, case let .statusBatch(s) = deliveredEnv.payload else {
            return XCTFail("expected a status:delivered for the context_request")
        }
        XCTAssertEqual(s.ids, [reqId])
        let responses = socket.sent.compactMap { data -> V2.Envelope? in
            try? JSONDecoder().decode(V2.Envelope.self, from: data)
        }.filter { $0.type == .contextResponse }
        XCTAssertEqual(responses.count, 1, "expected exactly one context_response envelope")
        guard let env = responses.first, case .contextResponse(let resp) = env.payload else {
            XCTFail("expected contextResponse payload")
            return
        }
        XCTAssertEqual(resp.request_id, "r-1")
        guard case .object(let obj) = resp.data else {
            XCTFail("expected object data; got \(resp.data)")
            return
        }
        XCTAssertNotNil(obj["device"])
        XCTAssertNotNil(obj["health"])
    }

    func testReconnectAttemptResetsOnAuthOk() async throws {
        // Construct transport with very short delays so the test is fast.
        let socket2 = MockWebSocket()
        let transport2 = TransportV2(
            store: store, socket: socket2, token: "tok",
            ackTimeoutSeconds: 0.2,
            dispatcherIntervalMs: 50,
            baseReconnectDelaySeconds: 0.05,
            maxReconnectDelaySeconds: 0.5
        )
        // handleAuthOk lands cleanly → state .authed, counter reset to 0.
        try await transport2.handleAuthOk(lastSeenOutboundSeq: 0)
        let beforeState = await transport2.state
        XCTAssertEqual(beforeState, .authed)
    }

    func testReconnectDelayGrowsOnConsecutiveCloses() async throws {
        // Use a long enough max that the first few attempts are uncapped, so
        // we can observe pure exponential growth via the State enum's
        // associated value.
        let socket2 = MockWebSocket()
        let transport2 = TransportV2(
            store: store, socket: socket2, token: "tok",
            ackTimeoutSeconds: 0.2,
            dispatcherIntervalMs: 50,
            baseReconnectDelaySeconds: 1.0,
            maxReconnectDelaySeconds: 60.0
        )
        // We exercise handleSocketClose indirectly: the only way to invoke it
        // is via the socket's onClose callback, which `connect()` wires up. We
        // can't easily call it twice without the reconnectTask actually firing
        // and changing state back. Instead we test the math directly by
        // observing `.reconnecting` state immediately after each close.
        //
        // Strategy: call connect() so onClose is wired, then trigger close,
        // read state, then mutate state back to .authed (simulating a
        // successful reconnect *without* resetting the counter) to bypass
        // the coalescing guard, then close again. The bookkeeping we care
        // about is: each invocation of handleSocketClose uses the current
        // `reconnectAttempt` value, increments it, and emits a doubled delay.
        try await transport2.connect()
        // First close: expect delay = base * 2^0 = 1.0
        await transport2.simulateSocketClose()
        let s1 = await transport2.state
        guard case .reconnecting(let d1) = s1 else {
            XCTFail("expected .reconnecting; got \(s1)")
            return
        }
        XCTAssertEqual(d1, 1.0, accuracy: 0.001)
        // Force state back to .authed (without resetting counter) so the next
        // close isn't swallowed by the coalescing guard. We can't reach the
        // private setter from outside, so use the test helper.
        await transport2.forceStateAuthedPreservingCounter()
        // Second close: expect delay = base * 2^1 = 2.0
        await transport2.simulateSocketClose()
        let s2 = await transport2.state
        guard case .reconnecting(let d2) = s2 else {
            XCTFail("expected .reconnecting; got \(s2)")
            return
        }
        XCTAssertEqual(d2, 2.0, accuracy: 0.001)
        // Third close: expect delay = base * 2^2 = 4.0
        await transport2.forceStateAuthedPreservingCounter()
        await transport2.simulateSocketClose()
        let s3 = await transport2.state
        guard case .reconnecting(let d3) = s3 else {
            XCTFail("expected .reconnecting; got \(s3)")
            return
        }
        XCTAssertEqual(d3, 4.0, accuracy: 0.001)
    }

    func testOutboundMessageCarriesAgentIdFromStoredRow() async throws {
        // Default agentId "jarvis" is what TransportV2.tickDispatcher currently
        // drains (T11 scope: stamp the envelope; T12/T13 will fan out to other
        // agents). Verify the envelope's agent_id mirrors the stored row.
        try store.insertOutboundUserMessage(
            id: "msg-agent-1", text: "hi", attachments: [], context: nil,
            agentId: "jarvis"
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)  // triggers tickDispatcher
        let messageEnvelopes = socket.sent.compactMap { data -> V2.Envelope? in
            guard let env = try? JSONDecoder().decode(V2.Envelope.self, from: data),
                  env.type == .message else { return nil }
            return env
        }
        let sent = try XCTUnwrap(messageEnvelopes.first)
        guard case let .message(msg) = sent.payload else {
            XCTFail("expected .message payload, got \(sent.payload)"); return
        }
        XCTAssertEqual(msg.agent_id, "jarvis")
    }

    func testInboundMessage_persistedWithAgentIdFromEnvelope() async throws {
        let id = "in-agent-1"
        try await transport.handleIncoming(
            encodeInbound(id: id, seq: 42, threadID: "ios:default",
                          text: "Здорово, солдат.", agentID: "payne")
        )
        let stored = try XCTUnwrap(try store.fetchById(id))
        XCTAssertEqual(stored.agentId, "payne")
    }

    func testInboundMessage_defaultsToJarvisWhenAgentIdMissing() async throws {
        let id = "in-agent-2"
        try await transport.handleIncoming(
            encodeInbound(id: id, seq: 43, threadID: "ios:default",
                          text: "legacy server", agentID: nil)
        )
        let stored = try XCTUnwrap(try store.fetchById(id))
        XCTAssertEqual(stored.agentId, "jarvis")
    }

    func testRetryAfterAckTimeout() async throws {
        try store.insertOutboundUserMessage(
            id: "msg-1", text: "hi", attachments: [], context: nil
        )
        try await transport.handleAuthOk(lastSeenOutboundSeq: 0)
        let firstCount = socket.sent.count
        try await Task.sleep(nanoseconds: 350_000_000)  // > ack timeout (0.2s)
        let later = socket.sent.count
        XCTAssertGreaterThan(later, firstCount)
    }

    func testTickDispatcherDoesNotSendBeforeAuth() async throws {
        // F26: tickDispatcher is nudged opportunistically from send / retrySend /
        // scene-phase-active, any of which can fire while the socket is still
        // idle / connecting / reconnecting (the auth handshake hasn't completed).
        // Draining then pushes envelopes before auth — wasted work + a latent
        // ordering hazard. A tick while not authed must be a no-op: the row stays
        // queued and nothing goes on the wire.
        try store.insertOutboundUserMessage(
            id: "msg-1", text: "hi", attachments: [], context: nil
        )
        let s = await transport.state
        XCTAssertEqual(s, .idle, "precondition: transport starts unauthed")
        try await transport.tickDispatcher()
        XCTAssertTrue(socket.sent.isEmpty, "no envelope may be sent before auth")
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .queued,
                       "row must stay queued until the connection is authed")
    }

    func testTickDispatcherDrainsWhenAuthed() async throws {
        // Complement to the not-authed guard: once authed, a direct tick DOES
        // drain the queued row to `sending` and put a message envelope on the
        // wire — the guard must not over-block the legitimate authed path.
        try store.insertOutboundUserMessage(
            id: "msg-1", text: "hi", attachments: [], context: nil
        )
        await transport.forceStateAuthedPreservingCounter()  // state = .authed
        try await transport.tickDispatcher()
        XCTAssertEqual(try store.fetchById("msg-1")?.status, .sending,
                       "an authed tick drains the queued row to sending")
        XCTAssertTrue(
            socket.sent.contains { (try? JSONDecoder().decode(V2.Envelope.self, from: $0))?.type == .message },
            "an authed tick emits the message envelope"
        )
    }

    func testUpdateEnvelopeEditsMessageInPlace() async throws {
        let seed = V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: "msg-1", seq: 3,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .message(V2.Message(thread_id: "default", text: "oops",
                                          attachments: nil, context: nil, agent_id: nil))
        )
        try await transport.handleIncoming(JSONEncoder().encode(seed))

        let upd = V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .update,
            id: "env-uuid-1", seq: 5,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .update(V2.Update(id: "msg-1", text: "corrected"))
        )
        try await transport.handleIncoming(JSONEncoder().encode(upd))

        let row = try store.fetchById("msg-1")
        XCTAssertEqual(row?.text, "corrected")
        XCTAssertTrue(row?.edited ?? false)
    }
}
