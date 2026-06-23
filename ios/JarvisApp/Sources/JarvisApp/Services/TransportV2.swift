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
    /// Scheduled retry tasks per envelope id; cancellation on ack.
    private var ackTasks: [String: Task<Void, Never>] = [:]
    /// In-flight auto-reconnect task; nil while connected or idle.
    private var reconnectTask: Task<Void, Never>?

    private let ackTimeoutSeconds: Double
    private let dispatcherIntervalMs: Int
    private let baseReconnectDelaySeconds: Double
    private let maxReconnectDelaySeconds: Double
    /// Count of consecutive `handleSocketClose` invocations since the last
    /// successful auth. Drives exponential backoff in `handleSocketClose`.
    /// Resets to 0 in `handleAuthOk` once the server has accepted us.
    private var reconnectAttempt: Int = 0

    /// Fired with the decoded `auth_ok` payload every time the server accepts
    /// the handshake. Wired by `WebSocketClientV2` to publish the optional
    /// slash-command catalogue. Closure must be `@Sendable` since it's
    /// invoked from the transport actor.
    private(set) var onAuthOkPayload: (@Sendable (V2.AuthOk) -> Void)?

    /// Async setter — the property is actor-isolated; callers from outside
    /// must hop through this. `nil` clears the callback.
    func setOnAuthOkPayload(_ cb: (@Sendable (V2.AuthOk) -> Void)?) {
        onAuthOkPayload = cb
    }

    /// Fired with the raw inbound envelope for any workout-family type
    /// (`workout_plan`, `image_blob`, `coach_message`, `exercise_swap_options`,
    /// `program_update`). Decode + UI routing happens in `WebSocketClientV2`,
    /// keeping the transport actor free of protocol-specific decode logic.
    private(set) var onWorkoutEnvelope: (@Sendable (V2.Envelope) -> Void)?

    func setOnWorkoutEnvelope(_ cb: (@Sendable (V2.Envelope) -> Void)?) {
        onWorkoutEnvelope = cb
    }

    init(
        store: ConversationStoreV2,
        socket: WebSocketLike,
        token: String,
        contextCoordinator: ContextCoordinatorV2? = nil,
        ackTimeoutSeconds: Double = 5.0,
        dispatcherIntervalMs: Int = 200,
        baseReconnectDelaySeconds: Double = 1.0,
        maxReconnectDelaySeconds: Double = 60.0
    ) {
        self.store = store
        self.socket = socket
        self.token = token
        self.contextCoordinator = contextCoordinator
        self.ackTimeoutSeconds = ackTimeoutSeconds
        self.dispatcherIntervalMs = dispatcherIntervalMs
        self.baseReconnectDelaySeconds = baseReconnectDelaySeconds
        self.maxReconnectDelaySeconds = maxReconnectDelaySeconds
    }

    func connect() async throws {
        // Reentrancy guard. connect() is called from ~6 view-appear sites + the
        // reconnect loop + retry taps; without this each call stacks another
        // socket open + auth handshake on the same instance, multiplying the
        // reconnect churn. Already connecting/authed → no-op.
        if state == .connecting || state == .authed { return }
        state = .connecting
        // Wire socket callbacks BEFORE opening the socket so the first inbound
        // frame can't race the assignment. The closures bounce back into the
        // actor via a detached `Task` — `WebSocketLike` callbacks fire on the
        // URLSession completion queue (or a Timer block) and must not touch
        // actor-isolated state directly.
        socket.onMessage = { [weak self] data in
            Task { [weak self] in
                do { try await self?.handleIncoming(data) }
                catch { Log.warn(.ws, "WORKOUTDBG: handleIncoming failed: \(error)") }
            }
        }
        socket.onClose = { [weak self] error in
            Task { [weak self] in
                await self?.handleSocketClose(error)
            }
        }
        try await socket.connect()
        let lastSeenInbound = try store.cursor(.lastSeenInbound)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let authEnv = V2.Envelope(
            v: V2.protocolVersion,
            kind: .control,
            type: .auth,
            id: UUID().uuidString,
            seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .auth(V2.Auth(
                token: token,
                last_seen_inbound_seq: lastSeenInbound,
                capabilities: [],
                app_version: appVersion,
                build: appBuild
            ))
        )
        try await sendEnvelope(authEnv)
    }

    /// Test-friendly: drive auth_ok handling directly.
    func handleAuthOk(lastSeenOutboundSeq: Int) async throws {
        try store.confirmAckedUpTo(maxSeq: lastSeenOutboundSeq)
        try store.resetSendingToQueued(maxSeq: lastSeenOutboundSeq)
        state = .authed
        // Server accepted us — clear the backoff counter so the next clean
        // disconnect retries at the base delay rather than the prior peak.
        reconnectAttempt = 0
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
            onAuthOkPayload?(ok)
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
        case .workoutPlan, .imageBlob, .coachMessage, .exerciseSwapOptions, .programUpdate:
            // Forward to the facade for typed decode + UI bus publication.
            // We deliberately do NOT ack here — workout envelopes are control
            // kind (or data for plan) and their delivery semantics live above
            // the dispatcher.
            onWorkoutEnvelope?(env)
        default:
            break
        }
    }

    /// Test-only helper: force-advance the ack retry timer.
    func fastForwardAckTimer(by milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    /// Test-only: drive a close synchronously without going through the
    /// socket callback indirection. Cancels any scheduled reconnect Task
    /// afterward so the test doesn't race a real `connect()`.
    func simulateSocketClose() async {
        await handleSocketClose(nil)
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Test-only: pretend the reconnect succeeded *without* clearing the
    /// `reconnectAttempt` counter. Used by the backoff-growth test to bypass
    /// the `case .reconnecting` early-return in `handleSocketClose` between
    /// consecutive simulated closes.
    func forceStateAuthedPreservingCounter() async {
        state = .authed
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

        // Voice-note merge: a message that carries a voice-note attachment and
        // names the text message it replies to is attached onto that bubble
        // (one combined audio+text bubble) rather than inserted as its own row.
        // The id correlation is robust when several messages are in flight while
        // a slow render completes. Falls back to a normal insert if the target
        // row isn't stored yet (text is delivered before the audio, so rare).
        if let replyTo = message.reply_to_id,
           let audio = message.attachments?.first(where: {
               $0.kind == "audio" || $0.mime_type.hasPrefix("audio/")
           }),
           try store.appendAttachment(toRowId: replyTo, attachment: audio) {
            try await sendAck(id: envelope.id, seq: envelope.seq ?? 0)
            try await sendStatus(.delivered, ids: [envelope.id])
            if let seq = envelope.seq {
                let current = try store.cursor(.lastSeenInbound)
                if seq > current { try store.setCursor(.lastSeenInbound, seq) }
            }
            return
        }

        let agentId = message.agent_id ?? "jarvis"
        try store.insertInbound(envelope: envelope, message: message, agentId: agentId)
        try? store.prune() // global retention; cheap no-op while under cap
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

    /// Rebuild wire attachments from stored refs, loading image/file bytes back
    /// out of `ChatImageStore`. Inline bytes (audio voice notes, legacy rows)
    /// pass through untouched.
    static func hydrateForWire(_ stored: [StoredAttachment]) -> [V2.Attachment] {
        stored.map { s in
            let b64 = s.bytes_base64
                ?? s.sha256.flatMap { ChatImageStore.shared.bytes(sha: $0)?.base64EncodedString() }
            return V2.Attachment(id: UUID().uuidString, kind: s.kind, name: s.name,
                                 mime_type: s.mime_type, byte_size: s.byte_size,
                                 bytes_base64: b64, remote_id: s.remote_id)
        }
    }

    private func makeMessageEnvelope(row: StoredMessage, seq: Int) -> V2.Envelope {
        // Decode attachments_json / context_json if present.
        let decoder = JSONDecoder()
        let stored: [StoredAttachment]? = row.attachmentsJSON
            .flatMap { try? decoder.decode([StoredAttachment].self, from: Data($0.utf8)) }
        let attachments: [V2.Attachment]? = stored.map(Self.hydrateForWire)
        let context: V2.InlineContext? = row.contextJSON
            .flatMap { try? decoder.decode(V2.InlineContext.self, from: Data($0.utf8)) }
        return V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: row.id, seq: seq,
            ts: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(row.ts) / 1000)),
            payload: .message(V2.Message(thread_id: "ios:default", text: row.text,
                                          attachments: attachments, context: context,
                                          agent_id: row.agentId))
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
        // Only retry while authed. Otherwise this self-rescheduling loop keeps
        // re-sending on a dead socket every few seconds through a disconnect.
        guard state == .authed else {
            cancelAckRetry(id: id)
            return
        }
        guard let row = try? store.fetchById(id), row.status == .sending else { return }
        guard let seq = row.seq else { return }
        let env = makeMessageEnvelope(row: row, seq: seq)
        try? await sendEnvelope(env)
        scheduleAckRetry(for: id)
    }

    /// Tear down the connection + all background work. Idempotent. Cancels the
    /// reconnect loop + every in-flight ack-retry task (which self-reschedule)
    /// and closes the socket. Without this there is no way to stop the reconnect
    /// churn once it starts.
    func disconnect() {
        state = .idle
        reconnectTask?.cancel()
        reconnectTask = nil
        for (_, t) in ackTasks { t.cancel() }
        ackTasks.removeAll()
        socket.close()
    }

    // MARK: - Reconnect

    /// Called from the socket's `onClose` callback. Coalesces overlapping closes:
    /// if a reconnect is already pending, ignore. Otherwise compute the next
    /// exponential-backoff delay (`base * 2^attempt`, capped at `max`), bump
    /// the attempt counter, and schedule `connect()` after that delay. The
    /// counter is reset to 0 in `handleAuthOk` on successful auth.
    private func handleSocketClose(_ error: Error?) async {
        if case .reconnecting = state { return }
        // Stop in-flight ack-retry tasks before reconnecting — they
        // self-reschedule and would keep re-sending on the dead socket.
        for (_, t) in ackTasks { t.cancel() }
        ackTasks.removeAll()
        let delay = min(
            maxReconnectDelaySeconds,
            baseReconnectDelaySeconds * pow(2.0, Double(reconnectAttempt))
        )
        reconnectAttempt += 1
        state = .reconnecting(delaySeconds: delay)
        reconnectTask?.cancel()
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

    // MARK: - Workout outbound builders (P3.T16)
    //
    // Typed convenience methods for the workout-specific envelope family. All
    // stamp `agent_id: "payne"` since these messages are always targeted at
    // the workout agent. They go through the same `sendEnvelope(_:)` writer
    // as everything else — no store side-effect, no ack tracking (workout
    // envelopes are at-least-once via their own queues, not the dispatcher).

    /// Send a workout_start_request envelope to Payne.
    func sendWorkoutStartRequest(date: String) async throws {
        let env = workoutEnvelope(
            .workoutStartRequest,
            payload: .workoutStartRequest(
                V2.WorkoutStartRequest(date: date, agent_id: "payne")
            )
        )
        try await sendEnvelope(env)
    }

    /// Send a set_log envelope built from a queued `SetLogEvent`.
    func sendSetLog(_ event: SetLogEvent) async throws {
        let env = workoutEnvelope(
            .setLog,
            kind: .data,
            payload: .setLog(
                V2.SetLog(
                    workout_id: event.workoutId,
                    exercise_slug: event.exerciseSlug,
                    set_idx: event.setIdx,
                    reps: event.reps,
                    weight: event.weight,
                    reps_in_reserve: event.repsInReserve,
                    ts: Self.workoutISOFormatter.string(from: event.ts),
                    agent_id: "payne"
                )
            )
        )
        try await sendEnvelope(env)
    }

    func sendExerciseDone(workoutId: String, slug: String, comment: String?) async throws {
        let env = workoutEnvelope(
            .exerciseDone,
            payload: .exerciseDone(
                V2.ExerciseDone(workout_id: workoutId, exercise_slug: slug, comment: comment, agent_id: "payne")
            )
        )
        try await sendEnvelope(env)
    }

    /// Serialize the `WorkoutSession` model into a `JSONValue` and ship it.
    func sendWorkoutComplete(_ session: WorkoutSession) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let any = try JSONSerialization.jsonObject(with: data)
        let json = try V2.JSONValue.from(any)

        let env = workoutEnvelope(
            .workoutComplete,
            kind: .data,
            payload: .workoutComplete(
                V2.WorkoutComplete(
                    workout_id: session.workoutId,
                    full_session_json: json,
                    agent_id: "payne"
                )
            )
        )
        try await sendEnvelope(env)
    }

    func sendWorkoutAbort(workoutId: String, reason: String?) async throws {
        let env = workoutEnvelope(
            .workoutAbort,
            payload: .workoutAbort(
                V2.WorkoutAbort(workout_id: workoutId, reason: reason, agent_id: "payne")
            )
        )
        try await sendEnvelope(env)
    }

    func sendImageRequest(slug: String) async throws {
        let env = workoutEnvelope(
            .imageRequest,
            payload: .imageRequest(
                V2.ImageRequest(slug: slug, agent_id: "payne")
            )
        )
        try await sendEnvelope(env)
    }

    func sendExerciseSwapRequest(workoutId: String, slug: String, proposed: String?) async throws {
        let env = workoutEnvelope(
            .exerciseSwapRequest,
            payload: .exerciseSwapRequest(
                V2.ExerciseSwapRequest(
                    workout_id: workoutId,
                    exercise_slug: slug,
                    proposed: proposed,
                    agent_id: "payne"
                )
            )
        )
        try await sendEnvelope(env)
    }

    func sendExerciseSwapConfirm(workoutId: String, original: String, new: String, persist: Bool) async throws {
        let env = workoutEnvelope(
            .exerciseSwapConfirm,
            payload: .exerciseSwapConfirm(
                V2.ExerciseSwapConfirm(
                    workout_id: workoutId,
                    original_slug: original,
                    new_slug: new,
                    persist: persist,
                    agent_id: "payne"
                )
            )
        )
        try await sendEnvelope(env)
    }

    func sendIntroRequest() async throws {
        let env = workoutEnvelope(
            .introRequest,
            payload: .introRequest(
                V2.IntroRequest(agent_id: "payne")
            )
        )
        try await sendEnvelope(env)
    }

    /// Drain the persistent `SetLogQueue` of any pending events and re-send
    /// each as a `set_log` envelope. Called on successful auth/reconnect by
    /// `WebSocketClientV2`. Stops on the first send failure so the next
    /// connect cycle can retry; runs a housekeeping prune on success.
    func drainSetLogQueue(_ queue: SetLogQueue) async {
        do {
            let pending = try queue.pending()
            for row in pending {
                do {
                    try await sendSetLog(row.event)
                    try queue.markDelivered(localId: row.localId)
                } catch {
                    Log.warn(.ws, "set_log drain failed at row \(row.localId): \(error)")
                    return
                }
            }
            try? queue.pruneDelivered(olderThan: Date().addingTimeInterval(-86_400))
        } catch {
            Log.warn(.ws, "set_log drain enumerate failed: \(error)")
        }
    }

    private func workoutEnvelope(_ type: V2.TypeTag, kind: V2.Kind = .control, payload: V2.Payload) -> V2.Envelope {
        V2.Envelope(
            v: V2.protocolVersion,
            kind: kind,
            type: type,
            id: UUID().uuidString,
            seq: nil,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: payload
        )
    }

    private static let workoutISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
