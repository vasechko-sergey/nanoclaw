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

    /// A row older than `maxAge` must be treated as absent AND cleared
    /// inline — otherwise a workout kicked off days ago and abandoned would
    /// forever surface a stale "Продолжить" card and rot the table.
    func test_load_dropsExpiredRowAndClears() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let cursor = WorkoutCursor(currentExerciseIdx: 0, currentSetIdx: 0, logged: [])
        try store.save(agentId: "payne", workoutId: "w1", plan: plan(), cursor: cursor, messageId: "m1")
        // Backdate the persisted row by a week.
        try dbq.write { db in
            try db.execute(sql: "UPDATE active_workout SET updated_at = ? WHERE agent_id = 'payne'",
                           arguments: [Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970])
        }
        // Load with the default 3-day horizon → treated as absent.
        XCTAssertNil(try store.load(agentId: "payne"))
        // And the row must be gone (not just filtered out on read).
        let count = try dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM active_workout WHERE agent_id = 'payne'") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    /// A row within the max-age horizon must still load — regression guard
    /// for an overly aggressive expiration.
    func test_load_keepsFreshRow() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let cursor = WorkoutCursor(currentExerciseIdx: 0, currentSetIdx: 0, logged: [])
        try store.save(agentId: "payne", workoutId: "w1", plan: plan(), cursor: cursor, messageId: "m1")
        XCTAssertNotNil(try store.load(agentId: "payne"))
    }

    /// A corrupt cursor row must surface as a throw so the caller can log —
    /// silently returning nil hides the bug and makes the resume banner
    /// vanish without a trace.
    func test_load_throwsOnCorruptCursor() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO active_workout (agent_id, workout_id, plan_json, cursor_json, message_id, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                "payne", "w1", "{}", "not-json-at-all", "m1",
                Date().timeIntervalSince1970,
            ])
        }
        XCTAssertThrowsError(try store.load(agentId: "payne"))
    }
}
