import XCTest
import GRDB
@testable import Jarvis

/// Shape tests for the typed workout envelope builders on `TransportV2`
/// added in P3.T16. Uses the same `MockWebSocket` from TransportV2Tests —
/// we just decode whatever bytes the transport pushed at the socket.
final class TransportV2WorkoutTests: XCTestCase {
    var store: ConversationStoreV2!
    var transport: TransportV2!
    var socket: MockWebSocket!
    var dbq: DatabaseQueue!

    override func setUp() async throws {
        dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStoreV2(writer: dbq)
        socket = MockWebSocket()
        transport = TransportV2(store: store, socket: socket, token: "tok",
                                 ackTimeoutSeconds: 0.2, dispatcherIntervalMs: 50)
    }

    private func lastSentEnvelope() throws -> V2.Envelope {
        let data = try XCTUnwrap(socket.sent.last)
        return try JSONDecoder().decode(V2.Envelope.self, from: data)
    }

    func test_sendWorkoutStartRequest_encodesEnvelope() async throws {
        try await transport.sendWorkoutStartRequest(date: "2026-06-08")
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .workoutStartRequest)
        guard case let .workoutStartRequest(p) = env.payload else {
            return XCTFail("expected workoutStartRequest payload")
        }
        XCTAssertEqual(p.date, "2026-06-08")
        XCTAssertEqual(p.agent_id, "payne")
    }

    func test_sendSetLog_encodesAsSetLogEnvelope() async throws {
        let event = SetLogEvent(
            workoutId: "w1", exerciseSlug: "incline-db-press",
            setIdx: 0, reps: 10, weight: 22.5, repsInReserve: 3,
            ts: Date()
        )
        try await transport.sendSetLog(event)
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .setLog)
        XCTAssertEqual(env.kind, .data)
        guard case let .setLog(p) = env.payload else {
            return XCTFail("expected setLog payload")
        }
        XCTAssertEqual(p.workout_id, "w1")
        XCTAssertEqual(p.exercise_slug, "incline-db-press")
        XCTAssertEqual(p.set_idx, 0)
        XCTAssertEqual(p.reps, 10)
        XCTAssertEqual(p.weight, 22.5)
        XCTAssertEqual(p.reps_in_reserve, 3)
        XCTAssertEqual(p.agent_id, "payne")
    }

    func test_sendExerciseDone_carriesComment() async throws {
        try await transport.sendExerciseDone(workoutId: "w1", slug: "squat", comment: "knee felt tight")
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .exerciseDone)
        guard case let .exerciseDone(p) = env.payload else {
            return XCTFail("expected exerciseDone payload")
        }
        XCTAssertEqual(p.comment, "knee felt tight")
        XCTAssertEqual(p.agent_id, "payne")
    }

    func test_sendWorkoutComplete_serializesSession() async throws {
        let session = WorkoutSession(
            workoutId: "w42",
            date: "2026-06-08",
            dayName: "Push",
            week: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_003_600),
            exercises: [
                LoggedExercise(exerciseSlug: "bench", sets: [
                    LoggedSet(reps: 8, weight: 60, repsInReserve: 2, ts: Date(timeIntervalSince1970: 1_700_000_300))
                ], comment: nil)
            ],
            perceivedOverallRir: 2,
            healthSignalAtStart: nil
        )
        try await transport.sendWorkoutComplete(session)
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .workoutComplete)
        XCTAssertEqual(env.kind, .data)
        guard case let .workoutComplete(p) = env.payload else {
            return XCTFail("expected workoutComplete payload")
        }
        XCTAssertEqual(p.workout_id, "w42")
        XCTAssertEqual(p.agent_id, "payne")
        // Spot-check JSONValue structure.
        guard case let .object(obj) = p.full_session_json else {
            return XCTFail("full_session_json should be an object")
        }
        XCTAssertEqual(obj["workout_id"], .string("w42"))
        XCTAssertEqual(obj["week"], .int(3))
    }

    func test_sendWorkoutAbort_carriesReason() async throws {
        try await transport.sendWorkoutAbort(workoutId: "w7", reason: "ran out of time")
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .workoutAbort)
        guard case let .workoutAbort(p) = env.payload else {
            return XCTFail("expected workoutAbort payload")
        }
        XCTAssertEqual(p.workout_id, "w7")
        XCTAssertEqual(p.reason, "ran out of time")
        XCTAssertEqual(p.agent_id, "payne")
    }

    func test_sendImageRequest_carriesSlug() async throws {
        try await transport.sendImageRequest(slug: "squat-low-bar")
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .imageRequest)
        guard case let .imageRequest(p) = env.payload else {
            return XCTFail("expected imageRequest payload")
        }
        XCTAssertEqual(p.slug, "squat-low-bar")
        XCTAssertEqual(p.agent_id, "payne")
    }

    func test_sendExerciseSwapRequest_optionalProposed() async throws {
        try await transport.sendExerciseSwapRequest(workoutId: "w1", slug: "bench", proposed: nil)
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .exerciseSwapRequest)
        guard case let .exerciseSwapRequest(p) = env.payload else {
            return XCTFail("expected exerciseSwapRequest payload")
        }
        XCTAssertEqual(p.exercise_slug, "bench")
        XCTAssertNil(p.proposed)
        XCTAssertEqual(p.agent_id, "payne")
    }

    func test_sendExerciseSwapConfirm_carriesPersist() async throws {
        try await transport.sendExerciseSwapConfirm(
            workoutId: "w1", original: "bench", new: "incline-db", persist: true
        )
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .exerciseSwapConfirm)
        guard case let .exerciseSwapConfirm(p) = env.payload else {
            return XCTFail("expected exerciseSwapConfirm payload")
        }
        XCTAssertEqual(p.original_slug, "bench")
        XCTAssertEqual(p.new_slug, "incline-db")
        XCTAssertEqual(p.persist, true)
        XCTAssertEqual(p.agent_id, "payne")
    }

    func test_sendIntroRequest_encodesAgentId() async throws {
        try await transport.sendIntroRequest()
        let env = try lastSentEnvelope()
        XCTAssertEqual(env.type, .introRequest)
        guard case let .introRequest(p) = env.payload else {
            return XCTFail("expected introRequest payload")
        }
        XCTAssertEqual(p.agent_id, "payne")
    }

    // MARK: - drainSetLogQueue

    func test_drainSetLogQueue_sendsAllPendingAndMarksDelivered() async throws {
        let queue = SetLogQueue(writer: dbq)
        let now = Date()
        try queue.enqueue(SetLogEvent(workoutId: "w1", exerciseSlug: "bench", setIdx: 0,
                                       reps: 8, weight: 60, repsInReserve: 2, ts: now))
        try queue.enqueue(SetLogEvent(workoutId: "w1", exerciseSlug: "bench", setIdx: 1,
                                       reps: 7, weight: 60, repsInReserve: 1, ts: now))

        await transport.drainSetLogQueue(queue)

        XCTAssertEqual(socket.sent.count, 2, "both queued events should have been pushed")
        let remaining = try queue.pending()
        XCTAssertTrue(remaining.isEmpty, "delivered events should be marked")

        // Each frame should be a set_log envelope.
        for data in socket.sent {
            let env = try JSONDecoder().decode(V2.Envelope.self, from: data)
            XCTAssertEqual(env.type, .setLog)
        }
    }

    // MARK: - buildSetLogPayload (deviation mapping)

    func test_transport_setLog_carriesDeviation() {
        let dev = WorkoutRunnerLogic.SetDeviation(
            kind: .failure, magnitude: 0,
            target: .init(repsMin: 8, repsMax: 10, weight: 100, rir: 2)
        )
        let event = SetLogEvent(
            workoutId: "w", exerciseSlug: "ex", setIdx: 0,
            reps: 10, weight: 20, repsInReserve: 0,
            ts: Date(timeIntervalSince1970: 0),
            deviation: dev
        )
        let payload = TransportV2.buildSetLogPayload(event: event, agentId: "payne")
        XCTAssertEqual(payload.deviation?.kind, .failure)
        XCTAssertEqual(payload.deviation?.target.reps_min, 8)
        XCTAssertEqual(payload.deviation?.target.weight, 100)
        XCTAssertEqual(payload.agent_id, "payne")
    }

    func test_transport_setLog_omitsDeviationWhenNil() {
        let event = SetLogEvent(
            workoutId: "w", exerciseSlug: "ex", setIdx: 0,
            reps: 10, weight: 20, repsInReserve: 2,
            ts: Date(timeIntervalSince1970: 0),
            deviation: nil
        )
        let payload = TransportV2.buildSetLogPayload(event: event, agentId: "payne")
        XCTAssertNil(payload.deviation)
    }
}
