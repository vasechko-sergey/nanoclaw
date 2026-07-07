import XCTest
import GRDB
@testable import Jarvis

@MainActor
final class WorkoutCoordinatorTests: XCTestCase {

    private func makePlan(exerciseCount: Int = 2, setsPerExercise: Int = 4) -> WorkoutPlan {
        let exercises = (0..<exerciseCount).map { i in
            ExercisePlan(
                exerciseSlug: "ex-\(i)",
                targetSets: setsPerExercise,
                targetReps: "8-10",
                targetRir: 2,
                restSec: 120,
                notes: nil
            )
        }
        return WorkoutPlan(
            workoutId: "w1",
            dayName: "Верх A",
            week: 2,
            intensityLabel: "тяжёлая",
            exercises: exercises,
            imageManifest: []
        )
    }

    private func makeQueue() throws -> SetLogQueue {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return SetLogQueue(writer: dbq)
    }

    func test_logSet_advancesSetIdxAndEnqueues() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(), queue: queue)
        XCTAssertEqual(coord.currentExerciseIdx, 0)
        XCTAssertEqual(coord.currentSetIdx, 0)
        coord.logSet(reps: 10, weight: 22.5, repsInReserve: 2)
        XCTAssertEqual(coord.currentSetIdx, 1)
        XCTAssertEqual(coord.loggedForCurrentExercise.count, 1)
        XCTAssertEqual(try queue.pending().count, 1)
    }

    func test_finishExercise_advancesToNext() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(), queue: queue)
        coord.logSet(reps: 10, weight: 22.5, repsInReserve: 2)
        coord.finishExercise(comment: "lock-out")
        XCTAssertEqual(coord.currentExerciseIdx, 1)
        XCTAssertEqual(coord.currentSetIdx, 0)
    }

    func test_finishExercise_onLastExercise_marksReadyToComplete() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 1, setsPerExercise: 2), queue: queue)
        coord.logSet(reps: 10, weight: 22.5, repsInReserve: 2)
        coord.logSet(reps: 9, weight: 22.5, repsInReserve: 1)
        coord.finishExercise(comment: nil)
        XCTAssertTrue(coord.readyToComplete)
    }

    func test_complete_returnsSessionWithAllLoggedSets() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(), queue: queue)
        coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
        coord.finishExercise(comment: nil)
        coord.logSet(reps: 8, weight: 20, repsInReserve: 0)
        let session = coord.complete(sessionFeeling: 4, sessionFeelingLabel: "Хорошо, с запасом")
        XCTAssertEqual(session.workoutId, "w1")
        XCTAssertEqual(session.exercises.flatMap(\.sets).count, 2)
        XCTAssertEqual(session.sessionFeeling, 4)
        XCTAssertEqual(session.sessionFeelingLabel, "Хорошо, с запасом")
        XCTAssertNil(session.perceivedOverallRir)
        XCTAssertTrue(coord.isFinished)
    }

    func test_logSet_afterFinished_isNoOp() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 1, setsPerExercise: 1), queue: queue)
        _ = coord.complete(sessionFeeling: 3, sessionFeelingLabel: "Нормально")
        coord.logSet(reps: 5, weight: 10, repsInReserve: 0)
        XCTAssertEqual(try queue.pending().count, 0)
    }

    func test_activate_switchesActiveAndResumesSetCount() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 3, setsPerExercise: 4), queue: queue)
        // Log one set on exercise 0, then jump to exercise 2.
        coord.logSet(reps: 8, weight: 40, repsInReserve: 2)
        coord.activate(idx: 2)
        XCTAssertEqual(coord.currentExerciseIdx, 2)
        XCTAssertEqual(coord.currentSetIdx, 0)            // exercise 2 has no sets yet
        coord.logSet(reps: 10, weight: 30, repsInReserve: 1)
        // Jump back to exercise 0 — set count resumes from what was logged there.
        coord.activate(idx: 0)
        XCTAssertEqual(coord.currentExerciseIdx, 0)
        XCTAssertEqual(coord.currentSetIdx, 1)
        XCTAssertEqual(coord.loggedForCurrentExercise.count, 1)
    }

    func test_activate_outOfRange_isNoOp() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 2), queue: queue)
        coord.activate(idx: 9)
        XCTAssertEqual(coord.currentExerciseIdx, 0)
    }

    func test_abort_marksFinishedWithoutSession() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(), queue: queue)
        coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
        coord.abort()
        XCTAssertTrue(coord.isFinished)
        // Queue still has the partial event — transport drains, server reconciles.
        XCTAssertEqual(try queue.pending().count, 1)
    }

    func test_logSet_taggsDeviationOnLoggedSet() throws {
        let queue = try makeQueue()
        // 100 kg target; log 80 → weightUnder
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "Верх A", week: 2, intensityLabel: "тяжёлая",
            exercises: [ExercisePlan(exerciseSlug: "ex-0", targetSets: 4, targetReps: "8-10",
                                     targetRir: 2, restSec: 120, notes: nil, nameRu: nil,
                                     durationSec: nil, weightKgTarget: 100)],
            imageManifest: [])
        let coord = WorkoutCoordinator(plan: plan, queue: queue)
        coord.logSet(reps: 10, weight: 80, repsInReserve: 2)
        XCTAssertEqual(coord.loggedForCurrentExercise.first?.deviation?.kind, .weightUnder)
    }

    func test_restoringInit_reproducesCursorAndLogged() throws {
        let queue = try makeQueue()
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let plan = makePlan(exerciseCount: 2, setsPerExercise: 3)
        let cursor = WorkoutCursor(
            currentExerciseIdx: 1, currentSetIdx: 2,
            logged: [
                LoggedExercise(exerciseSlug: "ex-0",
                               sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0))],
                               comment: nil),
                LoggedExercise(exerciseSlug: "ex-1",
                               sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0)),
                                      LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0))],
                               comment: nil),
            ]
        )
        try store.save(agentId: "payne", workoutId: plan.workoutId, plan: plan, cursor: cursor, messageId: "m")
        let record = try store.load(agentId: "payne")!

        let coord = WorkoutCoordinator(restoring: record, queue: queue, store: store)
        XCTAssertEqual(coord.currentExerciseIdx, 1)
        XCTAssertEqual(coord.currentSetIdx, 2)
        XCTAssertEqual(coord.loggedForCurrentExercise.count, 2)
    }

    func test_logSet_persistsToActiveWorkoutStore() throws {
        let queue = try makeQueue()
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let plan = makePlan()
        let coord = WorkoutCoordinator(plan: plan, queue: queue, store: store, agentId: "payne", messageId: "m")
        coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
        let rec = try store.load(agentId: "payne")
        XCTAssertEqual(rec?.cursor.currentSetIdx, 1)
        XCTAssertEqual(rec?.cursor.logged.first?.sets.count, 1)
    }

    func test_complete_clearsActiveWorkoutStore() throws {
        let queue = try makeQueue()
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let coord = WorkoutCoordinator(plan: makePlan(), queue: queue, store: store, agentId: "payne", messageId: "m")
        coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
        _ = coord.complete(sessionFeeling: 4, sessionFeelingLabel: "ok")
        XCTAssertNil(try store.load(agentId: "payne"))
    }

    func test_attachCoachHint_writesHintOnMatchingSet() throws {
        let queue = try makeQueue()
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        // Force a deviation-carrying set so the log path exercises the full write.
        var plan = makePlan()
        plan = WorkoutPlan(
            workoutId: plan.workoutId, dayName: plan.dayName, week: plan.week,
            intensityLabel: plan.intensityLabel,
            exercises: [ExercisePlan(exerciseSlug: "ex-0", targetSets: 4, targetReps: "8-10",
                                     targetRir: 2, restSec: 120, notes: nil, nameRu: nil,
                                     durationSec: nil, weightKgTarget: 100)],
            imageManifest: [])
        let coord = WorkoutCoordinator(plan: plan, queue: queue, store: store, agentId: "payne", messageId: "m")
        coord.logSet(reps: 10, weight: 100, repsInReserve: 0)
        coord.attachCoachHint(exerciseSlug: "ex-0", setIdx: 0, text: "отдохни дольше")
        XCTAssertEqual(coord.logged[0].sets[0].coachHint, "отдохни дольше")
    }

    func test_attachCoachHint_missingSet_isNoOp() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(), queue: queue)
        coord.attachCoachHint(exerciseSlug: "ex-0", setIdx: 42, text: "should not crash")
        // No assertion — just ensure no crash / no throw.
    }
}
