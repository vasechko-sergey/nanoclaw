import XCTest
import GRDB
@testable import Jarvis

/// Inbound-handler tests for the workout_plan path.
///
/// Every prior workout test decoded `V2.Envelope` directly (`JSONDecoder().decode`)
/// and never exercised `TransportV2.handleIncoming` — the actual routing step that
/// forwards a decoded plan to `onWorkoutEnvelope`. On-device the card never rendered
/// and the sim DB showed zero workout_plan rows, so `insertWorkoutPlan` was never
/// reached. These tests close that gap by driving the EXACT bytes Payne emitted
/// (seq 405, pulled from `data/v2-sessions/payne/.../outbound.db` on 2026-06-23)
/// through the real handler + the real `WebSocketClientV2` wiring.
final class TransportV2WorkoutInboundTests: XCTestCase {
    /// Exact `content` row Payne wrote for seq 405. The host workout-bridge
    /// (`src/channels/ios-app/v2/workout-bridge.ts`) wraps `content.payload`
    /// into a v2 envelope; `realEnvelopeData()` reproduces that wrap so the
    /// bytes match the wire frame the device receives.
    private static let realContent = #"""
    {"type":"workout_plan","payload":{"workout_id":"2026-06-23","plan_json":{"day_name":"Верх А","week":2,"week_label":"Средняя","exercises":[{"slug":"hodba-na-begovoy-dorozhke","name_ru":"Ходьба на беговой дорожке","target_sets":null,"target_reps":"","reps_in_reserve":null,"rest_seconds":0,"duration_seconds":300,"notes":"разминка"},{"slug":"zhim-shtangi-lezha-shirokim-hvatom","name_ru":"Жим штанги лежа широким хватом","target_sets":4,"target_reps":"5-6","reps_in_reserve":2,"rest_seconds":180,"weight_kg_target":66.25},{"slug":"tyaga-bloka-k-poyasu","name_ru":"Тяга блока к поясу","target_sets":4,"target_reps":"5-6","reps_in_reserve":2,"rest_seconds":180,"weight_kg_target":66.25},{"slug":"zhim-ganteley-na-naklonnoy-skame","name_ru":"Жим гантелей на наклонной скамье","target_sets":3,"target_reps":"8-10","reps_in_reserve":2,"rest_seconds":120,"weight_kg_target":25},{"slug":"sgibanie-ruk-v-bloke","name_ru":"Сгибание рук в блоке","target_sets":3,"target_reps":"10-12","reps_in_reserve":2,"rest_seconds":90,"weight_kg_target":36.25},{"slug":"razgibanie-v-bloke","name_ru":"Разгибание в блоке","target_sets":3,"target_reps":"10-12","reps_in_reserve":2,"rest_seconds":90,"weight_kg_target":32.5},{"slug":"obratnaya-babochka","name_ru":"Обратная бабочка","target_sets":3,"target_reps":"12-15","reps_in_reserve":2,"rest_seconds":90,"weight_kg_target":41.25},{"slug":"zhim-lezha-v-trenazhere-hammer","name_ru":"Жим лежа в тренажере Хаммер","target_sets":2,"target_reps":"10-12","reps_in_reserve":2,"rest_seconds":90,"weight_kg_target":46.25,"notes":"финиш на грудь"}]},"image_manifest":[{"slug":"hodba-na-begovoy-dorozhke","sha256":"ae672aad02d165e94103e1dccba746b786ff33a72e0e2ca92e8b7964e3144e87","url":""},{"slug":"zhim-shtangi-lezha-shirokim-hvatom","sha256":"f61e6adbe6501eca6b82d02734430260ed348d6e55030eab1371f4e7958b22c5","url":""},{"slug":"tyaga-bloka-k-poyasu","sha256":"1f2580f9a1633a9a50a629e9e003db2d42c5e2ceb230091b3cbc58813f42c6a6","url":""},{"slug":"zhim-ganteley-na-naklonnoy-skame","sha256":"bdf7530ffca03b41d3bd1eef966f03f577aacd1af2c427f409cf1f0da63ebb99","url":""},{"slug":"sgibanie-ruk-v-bloke","sha256":"403f7079fbc79216c16128af3d75e57f5ab2141b538ce2ff6c1f532047b9c5ca","url":""},{"slug":"razgibanie-v-bloke","sha256":"c5e711cdc44dddf68c36457e4f16f5f941421767bd0f073e5415ec50d89c328b","url":""},{"slug":"obratnaya-babochka","sha256":"1fcb52067c89fd407234d92019355090ebe3f1d0ce67bf588a5d583c38e2410f","url":""},{"slug":"zhim-lezha-v-trenazhere-hammer","sha256":"0398ff0035421fde020cb016d978a3fc0a8e9db34c4ff488f1bd0b8cc9e75c07","url":""}]}}
    """#

    /// Wrap the real payload in the v2 envelope exactly as the host bridge does.
    private func realEnvelopeData() throws -> Data {
        let content = try JSONSerialization.jsonObject(with: Data(Self.realContent.utf8)) as! [String: Any]
        let payload = content["payload"] as! [String: Any]
        let envelope: [String: Any] = [
            "v": 2,
            "kind": "control",
            "type": "workout_plan",
            "id": "00000000-0000-4000-8000-000000000405",
            "seq": 405,
            "ts": "2026-06-23T06:13:33.000Z",
            "payload": payload,
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    // MARK: - Direct handler tests (deterministic, no stack)

    var store: ConversationStoreV2!
    var transport: TransportV2!
    var socket: MockWebSocket!
    var dbq: DatabaseQueue!

    override func setUp() async throws {
        dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStoreV2(writer: dbq)
        socket = MockWebSocket()
        transport = TransportV2(store: store, socket: socket, token: "tok")
    }

    /// The core gap: `handleIncoming` must forward the real workout_plan frame
    /// to `onWorkoutEnvelope`. If the switch falls through to `default: break`,
    /// the plan is silently dropped (no throw) — exactly the on-device symptom.
    func test_handleIncoming_realPayneSeq405_firesWorkoutEnvelopeCallback() async throws {
        let capture = WorkoutCapture()
        await transport.setOnWorkoutEnvelope { env in capture.store(env) }

        try await transport.handleIncoming(try realEnvelopeData())

        let env = try XCTUnwrap(capture.value,
            "handleIncoming must forward the real workout_plan to onWorkoutEnvelope")
        XCTAssertEqual(env.type, .workoutPlan)
        guard case .workoutPlan = env.payload else {
            return XCTFail("expected .workoutPlan payload, got \(env.payload)")
        }
    }

    /// Full offline chain through the real handler entrypoint: real bytes →
    /// `handleIncoming` → callback → `decodeWorkoutPlan` → `insertWorkoutPlan` →
    /// windowed read → `.workoutPlan` card content. Proves the card-render path
    /// is correct on production bytes; any remaining failure is delivery, not this.
    @MainActor
    func test_handleIncoming_realPayne_endToEndProducesCard() async throws {
        let capture = WorkoutCapture()
        await transport.setOnWorkoutEnvelope { env in capture.store(env) }
        try await transport.handleIncoming(try realEnvelopeData())

        let env = try XCTUnwrap(capture.value)
        guard case let .workoutPlan(p) = env.payload else {
            return XCTFail("expected .workoutPlan payload")
        }
        let plan = try AppCoordinator.decodeWorkoutPlan(payload: p)
        XCTAssertEqual(plan.exercises.count, 8)
        XCTAssertEqual(plan.intensityLabel, "Средняя")
        XCTAssertEqual(plan.exercises[0].targetSets, 0)   // null warmup → 0

        try store.insertWorkoutPlan(id: env.id, agentId: "payne", plan: plan)
        let rows = try await dbq.read { try ConversationStoreV2.windowedRows($0, perAgent: 500) }
        let payneRow = try XCTUnwrap(rows.first { $0.agentId == "payne" })
        let msgs = WebSocketClientV2.toChatMessage(payneRow)
        guard case .workoutPlan = msgs[0].content else {
            return XCTFail("expected .workoutPlan card content, got \(msgs[0].content)")
        }
    }

    /// The transport must confirm a workout_plan by id (status:delivered) so the
    /// host can drop it from the outbound queue — workout-family envelopes are
    /// exempt from the host's chat-cursor ackUpTo, making this the only signal
    /// that clears them (and what stops the "текст был, карточки нет" loss).
    func test_handleIncoming_workoutPlan_sendsDeliveredAckById() async throws {
        await transport.setOnWorkoutEnvelope { _ in }
        try await transport.handleIncoming(try realEnvelopeData())

        let delivered = socket.sent
            .compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .first { $0.type == .delivered }
        let env = try XCTUnwrap(delivered, "handleIncoming must send status:delivered for a workout")
        guard case let .statusBatch(s) = env.payload else {
            return XCTFail("expected statusBatch payload, got \(env.payload)")
        }
        XCTAssertEqual(s.ids, ["00000000-0000-4000-8000-000000000405"])
    }

    /// The image is optional: a plan that carries NO `image_manifest` field must
    /// still decode and produce a card (each exercise falls back to a placeholder
    /// in the UI). Without the tolerant wire decode this throws on the missing key
    /// and the whole plan is dropped.
    @MainActor
    func test_handleIncoming_workoutPlan_withoutImageManifest_stillProducesCard() async throws {
        let json = """
        {"v":2,"kind":"control","type":"workout_plan","id":"id-no-img","seq":7,"ts":"2026-06-23T00:00:00.000Z","payload":{"workout_id":"w-noimg","plan_json":{"day_name":"День","week":1,"week_label":"Лёгкая","exercises":[{"slug":"prised","name_ru":"Присед","target_sets":3,"target_reps":"5","reps_in_reserve":2,"rest_seconds":120}]}}}
        """
        let capture = WorkoutCapture()
        await transport.setOnWorkoutEnvelope { env in capture.store(env) }
        try await transport.handleIncoming(Data(json.utf8))

        let env = try XCTUnwrap(capture.value, "manifest-less workout_plan must still reach onWorkoutEnvelope")
        guard case let .workoutPlan(p) = env.payload else {
            return XCTFail("expected .workoutPlan payload, got \(env.payload)")
        }
        XCTAssertEqual(p.image_manifest, [], "absent image_manifest decodes to empty, not a throw")
        let plan = try AppCoordinator.decodeWorkoutPlan(payload: p)
        XCTAssertEqual(plan.exercises.count, 1)
        XCTAssertEqual(plan.imageManifest, [])
    }

    /// Documents the failure mode we hunted on-device: with no callback wired,
    /// `handleIncoming` must NOT throw and must NOT persist — the plan vanishes.
    func test_handleIncoming_workoutPlan_nilCallback_dropsSilently() async throws {
        try await transport.handleIncoming(try realEnvelopeData())
        let rows = try await dbq.read { try ConversationStoreV2.windowedRows($0, perAgent: 500) }
        XCTAssertTrue(rows.isEmpty,
            "nil onWorkoutEnvelope => plan silently dropped (no throw, no persistence)")
    }

    // MARK: - End-to-end wiring test (real WebSocketClientV2 + AppV2Stack)

    /// Strong ref so the transport's `[weak self]` callbacks survive the awaits.
    @MainActor var wsHolder: WebSocketClientV2?

    /// Exercises the PRODUCTION wiring chain: `WebSocketClientV2(stack:)` runs
    /// the real `wireAuthOkCallback()` which sets `transport.onWorkoutEnvelope`,
    /// `connect()` wires `socket.onMessage`, and a frame must propagate all the
    /// way to `ws.onWorkoutEnvelope` (the seam AppCoordinator hooks). If the
    /// callback is nil at frame time (a wiring race), this catches it.
    @MainActor
    func test_fullWiring_realFrameReachesOnWorkoutEnvelope() async throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        let socket = MockWebSocket()
        let transport = TransportV2(store: store, socket: socket, token: "tok")
        let stack = AppV2Stack(
            store: store,
            transport: transport,
            coordinator: AppContextCoordinator(),
            dbq: dbq,
            setLogQueue: SetLogQueue(writer: dbq),
            activeWorkoutStore: ActiveWorkoutStore(writer: dbq)
        )
        let ws = WebSocketClientV2(stack: stack)   // runs wireAuthOkCallback()
        wsHolder = ws

        let exp = expectation(description: "onWorkoutEnvelope fires")
        let capture = WorkoutCapture()
        ws.onWorkoutEnvelope = { env in
            capture.store(env)
            exp.fulfill()
        }

        // Let wireAuthOkCallback's detached Task install transport.onWorkoutEnvelope.
        try await Task.sleep(nanoseconds: 150_000_000)
        // connect() wires socket.onMessage (and sends auth to the mock).
        try await transport.connect()
        // Deliver the real frame exactly as the URLSession callback would.
        socket.onMessage?(try realEnvelopeData())

        await fulfillment(of: [exp], timeout: 3)
        let env = try XCTUnwrap(capture.value)
        guard case .workoutPlan = env.payload else {
            return XCTFail("expected .workoutPlan payload, got \(env.payload)")
        }
    }

    /// THE fake-WS-server end-to-end test. A MockWebSocket plays the server:
    /// the app sends a workout request, the "server" replies with the EXACT
    /// frame Payne emits (seq 405), and we assert the card surfaces in the live
    /// `ws.messages` array — the very list `ChatView` filters and renders. This
    /// closes the last gap: prior tests checked decode/callback/windowedRows but
    /// never that the inserted row reaches the observed UI list for the active
    /// agent. The `onWorkoutEnvelope` closure mirrors AppCoordinator's two real
    /// ops (decodeWorkoutPlan + chatStore.insertWorkoutPlan).
    @MainActor
    func test_payneWorkoutFrame_surfacesAsCardInObservedMessages() async throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        let socket = MockWebSocket()
        let transport = TransportV2(store: store, socket: socket, token: "tok")
        let stack = AppV2Stack(
            store: store,
            transport: transport,
            coordinator: AppContextCoordinator(),
            dbq: dbq,
            setLogQueue: SetLogQueue(writer: dbq),
            activeWorkoutStore: ActiveWorkoutStore(writer: dbq)
        )
        let ws = WebSocketClientV2(stack: stack)   // restartObservation + wireAuthOkCallback
        wsHolder = ws

        // Mirror AppCoordinator.handleWorkoutEnvelope: decode + persist.
        ws.onWorkoutEnvelope = { env in
            guard case let .workoutPlan(p) = env.payload else { return }
            guard let plan = try? AppCoordinator.decodeWorkoutPlan(payload: p) else {
                return XCTFail("decodeWorkoutPlan failed on the real frame")
            }
            try? store.insertWorkoutPlan(id: env.id, agentId: "payne", plan: plan)
        }

        // Let wireAuthOkCallback's detached Task install transport.onWorkoutEnvelope.
        try await Task.sleep(nanoseconds: 150_000_000)
        try await transport.connect()

        // Request leg: the user asks Payne for a workout.
        ws.send(text: "Дай план тренировки", timezone: "UTC", status: nil, agentId: "payne")

        // Fake server replies with Payne's real workout_plan frame.
        socket.onMessage?(try realEnvelopeData())

        // The card must reach the observed `messages` list (async observation tick).
        try await waitUntil(timeout: 3, "workout card surfaces in ws.messages") {
            ws.messages.contains {
                if case .workoutPlan = $0.content { return $0.agentId == "payne" }
                return false
            }
        }

        let card = try XCTUnwrap(
            ws.messages.first { if case .workoutPlan = $0.content { return true }; return false },
            "workout card must surface in ws.messages"
        )
        XCTAssertEqual(card.agentId, "payne")
        XCTAssertTrue(card.isVisible, "card must pass ChatView's isVisible gate")
        // And it must survive ChatView's active-agent filter when Payne is active.
        XCTAssertEqual(AgentIdentity(rawValue: card.agentId ?? ""), .payne)
    }

    /// Poll `cond` on the main actor until true or `timeout` elapses.
    @MainActor
    private func waitUntil(timeout: TimeInterval, _ label: String, _ cond: () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                return XCTFail("timeout waiting for: \(label)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Sendable capture box for the `@Sendable` envelope callback.
final class WorkoutCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: V2.Envelope?
    var value: V2.Envelope? {
        lock.lock(); defer { lock.unlock() }; return _value
    }
    func store(_ env: V2.Envelope) {
        lock.lock(); _value = env; lock.unlock()
    }
}
