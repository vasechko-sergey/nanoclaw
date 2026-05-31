import Foundation

/// Minimal abstraction over URLSessionWebSocketTask so tests can substitute a mock.
protocol WebSocketLike: AnyObject {
    func connect() async throws
    func send(_ data: Data) async throws
    var onMessage: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func close()
}

actor TransportV2 {
    enum State: Equatable {
        case idle
        case connecting
        case authed
        case reconnecting(delaySeconds: Double)
    }

    enum TransportError: Error {
        case notAuthed
        case sendFailed(String)
    }

    private let store: ConversationStoreV2
    private let socket: WebSocketLike
    private let token: String
    private let contextCoordinator: ContextCoordinatorV2?
    private(set) var state: State = .idle
    private var ackDeadlines: [String: Date] = [:]
    /// Scheduled retry tasks per envelope id; cancellation on ack.
    private var ackTasks: [String: Task<Void, Never>] = [:]
    /// In-flight auto-reconnect task; nil while connected or idle.
    private var reconnectTask: Task<Void, Never>?

    private let ackTimeoutSeconds: Double
    private let dispatcherIntervalMs: Int
    private let reconnectDelaySeconds: Double

    init(
        store: ConversationStoreV2,
        socket: WebSocketLike,
        token: String,
        contextCoordinator: ContextCoordinatorV2? = nil,
        ackTimeoutSeconds: Double = 5.0,
        dispatcherIntervalMs: Int = 200,
        reconnectDelaySeconds: Double = 2.0
    ) {
        self.store = store
        self.socket = socket
        self.token = token
        self.contextCoordinator = contextCoordinator
        self.ackTimeoutSeconds = ackTimeoutSeconds
        self.dispatcherIntervalMs = dispatcherIntervalMs
        self.reconnectDelaySeconds = reconnectDelaySeconds
    }

    func connect() async throws {
        state = .connecting
        // Wire socket callbacks BEFORE opening the socket so the first inbound
        // frame can't race the assignment. The closures bounce back into the
        // actor via a detached `Task` — `WebSocketLike` callbacks fire on the
        // URLSession completion queue (or a Timer block) and must not touch
        // actor-isolated state directly.
        socket.onMessage = { [weak self] data in
            Task { [weak self] in
                try? await self?.handleIncoming(data)
            }
        }
        socket.onClose = { [weak self] error in
            Task { [weak self] in
                await self?.handleSocketClose(error)
            }
        }
        try await socket.connect()
        let lastSeenInbound = try store.cursor(.lastSeenInbound)
        let authEnv = V2.Envelope(
            v: V2.protocolVersion,
            kind: .control,
            type: .auth,
            id: UUID().uuidString,
            seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .auth(V2.Auth(token: token, last_seen_inbound_seq: lastSeenInbound, capabilities: []))
        )
        try await sendEnvelope(authEnv)
    }

    /// Test-friendly: drive auth_ok handling directly.
    func handleAuthOk(lastSeenOutboundSeq: Int) async throws {
        try store.confirmAckedUpTo(maxSeq: lastSeenOutboundSeq)
        try store.resetSendingToQueued(maxSeq: lastSeenOutboundSeq)
        state = .authed
        try await tickDispatcher()
    }

    /// Drain queued outbound messages.
    func tickDispatcher() async throws {
        let rows = try store.queuedOutbound(limit: 10)
        for row in rows {
            let seq = try store.allocateNextSendSeq()
            try store.markSending(id: row.id, seq: seq)
            let env = makeMessageEnvelope(row: row, seq: seq)
            try await sendEnvelope(env)
            scheduleAckRetry(for: row.id)
        }
    }

    /// Test-friendly inbound entrypoint.
    func handleIncoming(_ data: Data) async throws {
        let env = try JSONDecoder().decode(V2.Envelope.self, from: data)
        switch env.payload {
        case .ack(let a):
            cancelAckRetry(id: a.id)
            try store.markSent(id: a.id, serverTS: parseTS(env.ts))
        case .authOk(let ok):
            try await handleAuthOk(lastSeenOutboundSeq: ok.last_seen_outbound_seq)
        case .message(let m):
            try await routeInboundMessage(envelope: env, message: m)
        case .statusBatch(let s):
            if env.type == .delivered { try store.markDelivered(ids: s.ids) }
            else if env.type == .read { try store.markRead(ids: s.ids) }
        case .pong:
            break
        case .ping(let p):
            try await sendEnvelope(V2.Envelope(
                v: V2.protocolVersion, kind: .control, type: .pong,
                id: UUID().uuidString, seq: nil,
                ts: ISO8601DateFormatter().string(from: Date()),
                payload: .pong(V2.Pong(nonce: p.nonce))
            ))
        case .contextRequest(let req):
            await handleContextRequest(req)
        default:
            break
        }
    }

    /// Test-only helper: force-advance the ack retry timer.
    func fastForwardAckTimer(by milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    // MARK: - Facade helpers (5.2b)
    //
    // These let `WebSocketClientV2` emit one-shot control envelopes (new
    // conversation, feedback, action response) and status batches (read /
    // delivered) without re-implementing envelope construction. They are
    // best-effort: send errors are logged by the caller's `nil` swallow.
    // Unlike `tickDispatcher`, these do not persist anything to the store —
    // ack/retry semantics for control envelopes are out of scope for the v2
    // protocol (they're idempotent by `id`).

    /// Send a control envelope built from a literal payload. Used by the
    /// facade for `new_conversation`, `feedback`, `action_response` etc.
    func sendControlEnvelope(type: V2.TypeTag, payload: V2.Payload) async {
        let env = V2.Envelope(
            v: V2.protocolVersion,
            kind: .control,
            type: type,
            id: UUID().uuidString,
            seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: payload
        )
        try? await sendEnvelope(env)
    }

    /// Send a `status:delivered` or `status:read` batch.
    func sendStatusEnvelope(type: V2.TypeTag, ids: [String]) async {
        let env = V2.Envelope(
            v: V2.protocolVersion,
            kind: .status,
            type: type,
            id: UUID().uuidString,
            seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .statusBatch(V2.StatusBatch(ids: ids))
        )
        try? await sendEnvelope(env)
    }

    // MARK: - Private

    private func routeInboundMessage(envelope: V2.Envelope, message: V2.Message) async throws {
        if try store.dedupSeen(id: envelope.id) {
            try await sendAck(id: envelope.id, seq: envelope.seq ?? 0)
            return
        }
        try store.recordDedup(id: envelope.id, seq: envelope.seq ?? 0)
        try store.insertInbound(envelope: envelope, message: message)
        try await sendAck(id: envelope.id, seq: envelope.seq ?? 0)
        try await sendStatus(.delivered, ids: [envelope.id])
        if let seq = envelope.seq {
            let current = try store.cursor(.lastSeenInbound)
            if seq > current { try store.setCursor(.lastSeenInbound, seq) }
        }
    }

    private func sendAck(id: String, seq: Int) async throws {
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .ack, type: .ack,
            id: UUID().uuidString, seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .ack(V2.Ack(id: id, seq: seq))
        )
        try await sendEnvelope(env)
    }

    private func sendStatus(_ type: V2.TypeTag, ids: [String]) async throws {
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .status, type: type,
            id: UUID().uuidString, seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .statusBatch(V2.StatusBatch(ids: ids))
        )
        try await sendEnvelope(env)
    }

    private func makeMessageEnvelope(row: StoredMessage, seq: Int) -> V2.Envelope {
        // Decode attachments_json / context_json if present.
        let decoder = JSONDecoder()
        let attachments: [V2.Attachment]? = row.attachmentsJSON
            .flatMap { try? decoder.decode([V2.Attachment].self, from: Data($0.utf8)) }
        let context: V2.InlineContext? = row.contextJSON
            .flatMap { try? decoder.decode(V2.InlineContext.self, from: Data($0.utf8)) }
        return V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: row.id, seq: seq,
            ts: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(row.ts) / 1000)),
            payload: .message(V2.Message(thread_id: row.conversationId, text: row.text,
                                          attachments: attachments, context: context))
        )
    }

    private func sendEnvelope(_ env: V2.Envelope) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(env)
        do { try await socket.send(data) }
        catch { throw TransportError.sendFailed("\(error)") }
    }

    private func scheduleAckRetry(for id: String) {
        ackTasks[id]?.cancel()
        let nanos = UInt64(ackTimeoutSeconds * 1_000_000_000)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            await self?.retryEnvelopeIfPending(id: id)
        }
        ackTasks[id] = task
    }

    private func cancelAckRetry(id: String) {
        ackTasks[id]?.cancel()
        ackTasks[id] = nil
    }

    private func retryEnvelopeIfPending(id: String) async {
        guard let row = try? store.fetchById(id), row.status == .sending else { return }
        guard let seq = row.seq else { return }
        let env = makeMessageEnvelope(row: row, seq: seq)
        try? await sendEnvelope(env)
        scheduleAckRetry(for: id)
    }

    // MARK: - Reconnect

    /// Called from the socket's `onClose` callback. Coalesces overlapping closes:
    /// if a reconnect is already pending, ignore. Otherwise transition to
    /// `.reconnecting` and schedule `connect()` after `reconnectDelaySeconds`.
    private func handleSocketClose(_ error: Error?) async {
        if case .reconnecting = state { return }
        state = .reconnecting(delaySeconds: reconnectDelaySeconds)
        reconnectTask?.cancel()
        let delay = reconnectDelaySeconds
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            try? await self.connect()
        }
    }

    // MARK: - Context requests

    /// Server asked us for device-side context fields. Fan out to the
    /// dispatcher (which fans out to the coordinator) and reply with a single
    /// `context_response` envelope. If no coordinator was injected we silently
    /// drop the request — that's the test/in-memory build configuration.
    private func handleContextRequest(_ req: V2.ContextRequest) async {
        guard let coord = contextCoordinator else { return }
        let dispatcher = InboundDispatcherV2(coordinator: coord)
        let response = await dispatcher.gather(
            requestID: req.request_id,
            fields: req.fields,
            params: req.params
        )
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .control, type: .contextResponse,
            id: UUID().uuidString, seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .contextResponse(response)
        )
        try? await sendEnvelope(env)
    }

    private func parseTS(_ ts: String) -> Int {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) ?? Date()
        return Int(date.timeIntervalSince1970 * 1000)
    }
}
