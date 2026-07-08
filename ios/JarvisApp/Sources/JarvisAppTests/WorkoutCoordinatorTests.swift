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

    func test_logSet_firesOnSetLoggedHook() throws {
        // F23: a live-logged set must nudge the transport to drain the SetLogQueue
        // immediately (so coach hints flow on a stable connection) rather than
        // waiting for the next auth_ok.
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(), queue: queue)
        var drainNudges = 0
        coord.onSetLogged = { drainNudges += 1 }
        coord.logSet(reps: 10, weight: 22.5, repsInReserve: 2)
        XCTAssertEqual(drainNudges, 1)
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
        XCTAssertEqual(coord.loggedForCurrentExercise.first?.deviations.map(\.kind), [.weightUnder])
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

    /// A late `coach_message` arriving after the user aborted or completed
    /// the workout must NOT resurrect the `active_workout` row — otherwise
    /// next launch shows a zombie "Продолжить" card for a done workout.
    func test_attachCoachHint_afterAbort_doesNotResurrectStore() throws {
        let queue = try makeQueue()
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
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
        coord.abort()  // abort clears the store row
        XCTAssertNil(try store.load(agentId: "payne"))
        coord.attachCoachHint(exerciseSlug: "ex-0", setIdx: 0, text: "поздравляю")
        // The store must stay empty — otherwise next launch shows a zombie card.
        XCTAssertNil(try store.load(agentId: "payne"))
    }

    /// Same as above but for the completion path — a coach reply that lands
    /// after `complete()` must not re-persist the finished workout.
    func test_attachCoachHint_afterComplete_doesNotResurrectStore() throws {
        let queue = try makeQueue()
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
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
        _ = coord.complete(sessionFeeling: 3, sessionFeelingLabel: "ok")
        XCTAssertNil(try store.load(agentId: "payne"))
        coord.attachCoachHint(exerciseSlug: "ex-0", setIdx: 0, text: "молодец")
        XCTAssertNil(try store.load(agentId: "payne"))
    }

    // MARK: - Fix N: applySwap + coach hint anchoring after a swap

    /// After a swap the coordinator's plan.exercises[i].exerciseSlug and
    /// logged[i].exerciseSlug must both point at the NEW slug so future
    /// attachCoachHint calls resolve.
    func test_applySwap_updatesPlanAndLogged() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 3), queue: queue)
        coord.applySwap(originalSlug: "ex-1", newSlug: "ex-1-alt")
        XCTAssertEqual(coord.plan.exercises[1].exerciseSlug, "ex-1-alt")
        XCTAssertEqual(coord.logged[1].exerciseSlug, "ex-1-alt")
        // Other exercises untouched.
        XCTAssertEqual(coord.plan.exercises[0].exerciseSlug, "ex-0")
        XCTAssertEqual(coord.plan.exercises[2].exerciseSlug, "ex-2")
    }

    /// applySwap preserves target sets / reps / rest / logged sets.
    func test_applySwap_preservesFieldsAndLoggedSets() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 2, setsPerExercise: 3), queue: queue)
        // Log a set on ex-0, then activate ex-1 and log there.
        coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
        coord.activate(idx: 1)
        coord.logSet(reps: 8, weight: 30, repsInReserve: 1)
        // Swap ex-1 → ex-1-alt.
        coord.applySwap(originalSlug: "ex-1", newSlug: "ex-1-alt")
        XCTAssertEqual(coord.plan.exercises[1].exerciseSlug, "ex-1-alt")
        XCTAssertEqual(coord.plan.exercises[1].targetSets, 3)
        XCTAssertEqual(coord.plan.exercises[1].targetReps, "8-10")
        XCTAssertEqual(coord.logged[1].exerciseSlug, "ex-1-alt")
        XCTAssertEqual(coord.logged[1].sets.count, 1)
        XCTAssertEqual(coord.logged[1].sets[0].reps, 8)
    }

    /// After a swap, `attachCoachHint` with the NEW slug still lands.
    func test_attachCoachHint_afterSwap_landsOnRightSet() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 2), queue: queue)
        coord.activate(idx: 1)
        coord.logSet(reps: 10, weight: 25, repsInReserve: 1)
        coord.applySwap(originalSlug: "ex-1", newSlug: "ex-1-alt")
        coord.attachCoachHint(exerciseSlug: "ex-1-alt", setIdx: 0, text: "поправь наклон")
        XCTAssertEqual(coord.logged[1].sets[0].coachHint, "поправь наклон")
    }

    /// Fallback: if a coach reply races the local swap (Payne's slug reaches
    /// us before applySwap runs), attachCoachHint falls back to the current
    /// exercise when the setIdx fits — belt-and-suspenders.
    func test_attachCoachHint_unknownSlug_fallsBackToCurrentExercise() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 2), queue: queue)
        coord.activate(idx: 1)
        coord.logSet(reps: 10, weight: 25, repsInReserve: 1)
        // Slug not in plan — but setIdx 0 is valid on current exercise.
        coord.attachCoachHint(exerciseSlug: "never-heard-of-it", setIdx: 0, text: "fallback")
        XCTAssertEqual(coord.logged[1].sets[0].coachHint, "fallback")
    }

    /// applySwap is a no-op when the original slug isn't present.
    func test_applySwap_unknownSlug_isNoOp() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 2), queue: queue)
        coord.applySwap(originalSlug: "nope", newSlug: "also-nope")
        XCTAssertEqual(coord.plan.exercises[0].exerciseSlug, "ex-0")
        XCTAssertEqual(coord.plan.exercises[1].exerciseSlug, "ex-1")
    }

    /// applySwap after abort/complete doesn't resurrect state.
    func test_applySwap_afterAbort_isNoOp() throws {
        let queue = try makeQueue()
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let coord = WorkoutCoordinator(plan: makePlan(), queue: queue, store: store, agentId: "payne", messageId: "m")
        coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
        coord.abort()
        XCTAssertNil(try store.load(agentId: "payne"))
        coord.applySwap(originalSlug: "ex-0", newSlug: "ex-0-alt")
        // Plan still shows the old slug post-abort — and no store row resurrects.
        XCTAssertEqual(coord.plan.exercises[0].exerciseSlug, "ex-0")
        XCTAssertNil(try store.load(agentId: "payne"))
    }

    /// A workout paused for a while and then restored must report its true
    /// duration in `session.duration` — the coordinator restores `startedAt`
    /// from the persisted cursor, NOT the last-save wallclock (`updatedAt`),
    /// otherwise a session that ran for an hour would look like it just started.
    func test_restoringInit_preservesOriginalStartedAt() throws {
        let queue = try makeQueue()
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let originalStart = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = makePlan()

        // Fresh coordinator with a specific startedAt, log a set to force persist.
        let first = WorkoutCoordinator(
            plan: plan, queue: queue, startedAt: originalStart,
            store: store, agentId: "payne", messageId: "m"
        )
        first.logSet(reps: 10, weight: 20, repsInReserve: 2, ts: originalStart)

        // Load the persisted row and restore into a new coordinator.
        let record = try XCTUnwrap(store.load(agentId: "payne"))
        // Sanity: the save wallclock (updatedAt) is very different from originalStart.
        XCTAssertGreaterThan(record.updatedAt.timeIntervalSince(originalStart), 60 * 60 * 24)
        let restored = WorkoutCoordinator(restoring: record, queue: queue, store: store)
        let session = restored.complete(sessionFeeling: 3, sessionFeelingLabel: "ok")
        XCTAssertEqual(session.startedAt, originalStart)
    }
}
