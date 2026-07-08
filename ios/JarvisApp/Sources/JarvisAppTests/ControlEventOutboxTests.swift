import XCTest
import GRDB
@testable import Jarvis

/// F4: workout lifecycle events (workout_complete / workout_abort /
/// exercise_swap_confirm) must be durable — persisted to a GRDB outbox and
/// drained on auth, exactly like the set-log path (F23). These tests pin the
/// durable outbox: enqueue-without-send, drain-once, dedup, and app-kill
/// durability across a fresh on-disk open. Drives the transport with the same
/// `MockWebSocket` fake socket used by TransportV2WorkoutTests.
final class ControlEventOutboxTests: XCTestCase {
    var dbq: DatabaseQueue!
    var store: ConversationStoreV2!
    var transport: TransportV2!
    var socket: MockWebSocket!

    override func setUp() async throws {
        dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStoreV2(writer: dbq)
        socket = MockWebSocket()
        transport = TransportV2(store: store, socket: socket, token: "tok",
                                ackTimeoutSeconds: 0.2, dispatcherIntervalMs: 50)
    }

    private func sampleSession(id: String = "w42") -> WorkoutSession {
        WorkoutSession(
            workoutId: id, date: "2026-07-08", dayName: "Push", week: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_003_600),
            exercises: [
                LoggedExercise(exerciseSlug: "bench", sets: [
                    LoggedSet(reps: 8, weight: 60, repsInReserve: 2,
                              ts: Date(timeIntervalSince1970: 1_700_000_300))
                ], comment: nil)
            ],
            perceivedOverallRir: nil, healthSignalAtStart: nil,
            sessionFeeling: 4, sessionFeelingLabel: "норм"
        )
    }

    // 1. Enqueue while the transport is NOT authed → the event is persisted and
    //    NOT sent (no loss, no premature push).
    func test_enqueueWorkoutComplete_persistsWithoutSending() throws {
        let queue = ControlEventQueue(writer: dbq)
        let payload = try TransportV2.buildWorkoutCompletePayload(sampleSession())
        try queue.enqueueWorkoutComplete(payload)

        // Enqueue is pure persistence — nothing hits the socket.
        XCTAssertTrue(socket.sent.isEmpty, "enqueue must not touch the socket")
        let pending = try queue.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, "workout_complete")
    }

    // 2. Drain sends each queued event exactly once with the correct envelope
    //    type + kind + payload (byte-identical wire to the direct send methods).
    func test_drain_sendsEachQueuedEventOnce() async throws {
        let queue = ControlEventQueue(writer: dbq)
        try queue.enqueueWorkoutComplete(
            try TransportV2.buildWorkoutCompletePayload(sampleSession(id: "wc1")))
        try queue.enqueueWorkoutAbort(
            V2.WorkoutAbort(workout_id: "wa1", reason: "user cancelled", agent_id: "payne"))
        try queue.enqueueExerciseSwapConfirm(
            V2.ExerciseSwapConfirm(workout_id: "ws1", original_slug: "bench",
                                   new_slug: "incline-db", persist: true, agent_id: "payne"))

        await transport.drainControlEventQueue(queue)

        XCTAssertEqual(socket.sent.count, 3, "all three queued events should be pushed")
        let envs = try socket.sent.map { try JSONDecoder().decode(V2.Envelope.self, from: $0) }
        // Order preserved (insertion / rowid ASC), same wire types + kinds the
        // direct send methods use (complete=data, abort/swap=control).
        XCTAssertEqual(envs.map(\.type), [.workoutComplete, .workoutAbort, .exerciseSwapConfirm])
        XCTAssertEqual(envs.map(\.kind), [.data, .control, .control])

        guard case let .workoutComplete(wc) = envs[0].payload else { return XCTFail("wc payload") }
        XCTAssertEqual(wc.workout_id, "wc1")
        XCTAssertEqual(wc.agent_id, "payne")
        guard case let .workoutAbort(wa) = envs[1].payload else { return XCTFail("wa payload") }
        XCTAssertEqual(wa.workout_id, "wa1")
        XCTAssertEqual(wa.reason, "user cancelled")
        XCTAssertEqual(wa.agent_id, "payne")
        guard case let .exerciseSwapConfirm(sc) = envs[2].payload else { return XCTFail("sc payload") }
        XCTAssertEqual(sc.original_slug, "bench")
        XCTAssertEqual(sc.new_slug, "incline-db")
        XCTAssertEqual(sc.persist, true)
        XCTAssertEqual(sc.agent_id, "payne")

        XCTAssertTrue(try queue.pending().isEmpty, "drained events are marked delivered")
    }

    // 3. A delivered event is marked so a second drain does NOT re-send it.
    func test_drain_isIdempotent_noDoubleSend() async throws {
        let queue = ControlEventQueue(writer: dbq)
        try queue.enqueueWorkoutAbort(
            V2.WorkoutAbort(workout_id: "wa1", reason: nil, agent_id: "payne"))

        await transport.drainControlEventQueue(queue)
        XCTAssertEqual(socket.sent.count, 1)

        await transport.drainControlEventQueue(queue)
        XCTAssertEqual(socket.sent.count, 1, "a delivered event must not re-fire on the next drain")
    }

    // 4. App-kill durability: a queued event survives a fresh store/queue open on
    //    the same on-disk DB (relaunch after the app was killed mid-workout).
    func test_enqueue_survivesFreshOpen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("jarvis-v2.sqlite").path

        do {
            let db1 = try DatabaseQueue(path: path)
            try Schema.migrate(db1)
            let q1 = ControlEventQueue(writer: db1)
            try q1.enqueueWorkoutAbort(
                V2.WorkoutAbort(workout_id: "persist-me", reason: "kill", agent_id: "payne"))
        } // db1 + q1 deallocate → connection closes (process-death proxy)

        // Fresh open on the same file — the row must still be pending.
        let db2 = try DatabaseQueue(path: path)
        try Schema.migrate(db2)
        let q2 = ControlEventQueue(writer: db2)
        let pending = try q2.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, "workout_abort")
    }

    // Byte-identity guard: the payload the durable drain emits is wire-identical
    // to what the direct `sendWorkoutComplete` builds — the host cannot tell the
    // difference (only delivery timing changed).
    func test_drainedWorkoutComplete_matchesDirectSend() async throws {
        let session = sampleSession(id: "wc-eq")

        try await transport.sendWorkoutComplete(session)
        let directEnv = try JSONDecoder().decode(V2.Envelope.self, from: XCTUnwrap(socket.sent.last))
        guard case let .workoutComplete(direct) = directEnv.payload else { return XCTFail("direct payload") }

        let before = socket.sent.count
        let queue = ControlEventQueue(writer: dbq)
        try queue.enqueueWorkoutComplete(try TransportV2.buildWorkoutCompletePayload(session))
        await transport.drainControlEventQueue(queue)
        XCTAssertEqual(socket.sent.count, before + 1, "drain should emit exactly one workout_complete")

        let drainedEnv = try JSONDecoder().decode(V2.Envelope.self, from: XCTUnwrap(socket.sent.last))
        guard case let .workoutComplete(drained) = drainedEnv.payload else { return XCTFail("drained payload") }

        XCTAssertEqual(direct, drained, "durable-outbox payload must be wire-identical to the direct send")
        XCTAssertEqual(directEnv.type, drainedEnv.type)
        XCTAssertEqual(directEnv.kind, drainedEnv.kind)
    }

    // A corrupt / unknown-kind row must not wedge the queue behind a poison
    // pill — it is dropped (marked delivered) so later rows still drain.
    func test_drain_dropsUnbuildableRow() async throws {
        let queue = ControlEventQueue(writer: dbq)
        try queue.enqueue(kind: "bogus_kind", payloadJson: "{}")
        try queue.enqueueWorkoutAbort(
            V2.WorkoutAbort(workout_id: "after-poison", reason: nil, agent_id: "payne"))

        await transport.drainControlEventQueue(queue)

        // The bogus row is dropped; the valid one still sends.
        XCTAssertEqual(socket.sent.count, 1)
        let env = try JSONDecoder().decode(V2.Envelope.self, from: XCTUnwrap(socket.sent.last))
        XCTAssertEqual(env.type, .workoutAbort)
        XCTAssertTrue(try queue.pending().isEmpty, "both rows cleared (one sent, one dropped)")
    }
}
