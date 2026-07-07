import XCTest
import GRDB
@testable import Jarvis

final class ActiveWorkoutStoreTests: XCTestCase {

    private func plan() -> WorkoutPlan {
        WorkoutPlan(
            workoutId: "w1", dayName: "Верх A", week: 2,
            intensityLabel: "тяжёлая",
            exercises: [ExercisePlan(exerciseSlug: "ex", targetSets: 4, targetReps: "8-10",
                                     targetRir: 2, restSec: 90, notes: nil, nameRu: nil,
                                     durationSec: nil, weightKgTarget: 100)],
            imageManifest: []
        )
    }

    func test_save_load_clear_roundtrip() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)

        let cursor = WorkoutCursor(
            currentExerciseIdx: 0, currentSetIdx: 1,
            logged: [LoggedExercise(exerciseSlug: "ex",
                                    sets: [LoggedSet(reps: 10, weight: 100, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0))],
                                    comment: nil)]
        )
        try store.save(agentId: "payne", workoutId: "w1", plan: plan(), cursor: cursor, messageId: "m1")
        let loaded = try store.load(agentId: "payne")
        XCTAssertEqual(loaded?.plan.workoutId, "w1")
        XCTAssertEqual(loaded?.cursor.currentSetIdx, 1)
        XCTAssertEqual(loaded?.cursor.logged.first?.sets.count, 1)
        XCTAssertEqual(loaded?.messageId, "m1")

        try store.clear(agentId: "payne")
        XCTAssertNil(try store.load(agentId: "payne"))
    }

    func test_save_overwrites_existing() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let cursor = WorkoutCursor(currentExerciseIdx: 0, currentSetIdx: 0, logged: [])
        try store.save(agentId: "payne", workoutId: "w1", plan: plan(), cursor: cursor, messageId: "m1")
        try store.save(agentId: "payne", workoutId: "w2", plan: plan(), cursor: cursor, messageId: "m2")
        let loaded = try store.load(agentId: "payne")
        XCTAssertEqual(loaded?.workoutId, "w2")
        XCTAssertEqual(loaded?.messageId, "m2")
    }
}
