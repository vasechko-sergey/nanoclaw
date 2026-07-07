import Foundation
import GRDB

/// Cursor to resume a live workout at exactly the same set/exercise/logged state.
struct WorkoutCursor: Codable, Equatable {
    var currentExerciseIdx: Int
    var currentSetIdx: Int
    var logged: [LoggedExercise]
}

/// One row from the `active_workout` table.
struct ActiveWorkoutRecord: Equatable {
    let agentId: String
    let workoutId: String
    let plan: WorkoutPlan
    let cursor: WorkoutCursor
    let messageId: String
    let updatedAt: Date
}

/// Persists the in-progress workout so that a kill/crash restore lands the user
/// back in the runner at the exact set + logged history.
final class ActiveWorkoutStore {
    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    func save(agentId: String, workoutId: String, plan: WorkoutPlan, cursor: WorkoutCursor, messageId: String) throws {
        let planData = try JSONEncoder().encode(plan)
        let cursorData = try JSONEncoder().encode(cursor)
        let planJson = String(data: planData, encoding: .utf8) ?? "{}"
        let cursorJson = String(data: cursorData, encoding: .utf8) ?? "{}"
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO active_workout (agent_id, workout_id, plan_json, cursor_json, message_id, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(agent_id) DO UPDATE SET
                    workout_id = excluded.workout_id,
                    plan_json = excluded.plan_json,
                    cursor_json = excluded.cursor_json,
                    message_id = excluded.message_id,
                    updated_at = excluded.updated_at
            """, arguments: [agentId, workoutId, planJson, cursorJson, messageId, Date().timeIntervalSince1970])
        }
    }

    func load(agentId: String) throws -> ActiveWorkoutRecord? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT workout_id, plan_json, cursor_json, message_id, updated_at
                FROM active_workout WHERE agent_id = ?
            """, arguments: [agentId]) else { return nil }
            let planData = (row["plan_json"] as String).data(using: .utf8) ?? Data()
            let cursorData = (row["cursor_json"] as String).data(using: .utf8) ?? Data()
            let plan = try JSONDecoder().decode(WorkoutPlan.self, from: planData)
            let cursor = try JSONDecoder().decode(WorkoutCursor.self, from: cursorData)
            return ActiveWorkoutRecord(
                agentId: agentId,
                workoutId: row["workout_id"],
                plan: plan,
                cursor: cursor,
                messageId: row["message_id"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    func clear(agentId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM active_workout WHERE agent_id = ?", arguments: [agentId])
        }
    }
}
