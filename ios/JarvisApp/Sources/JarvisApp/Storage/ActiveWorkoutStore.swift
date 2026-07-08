import Foundation
import GRDB

/// Cursor to resume a live workout at exactly the same set/exercise/logged state.
///
/// `startedAt` is the wallclock at which the workout was created (via
/// `WorkoutCoordinator.init`), NOT the last save time. Persisting it means a
/// restored coordinator can report the true `session.duration` on complete —
/// otherwise a workout paused for hours would look like it just started.
///
/// Defaults to `nil` for records saved before the field was added; the
/// restoring init treats absence as "fall back to `updatedAt`" so old rows
/// still hydrate.
struct WorkoutCursor: Codable, Equatable {
    var currentExerciseIdx: Int
    var currentSetIdx: Int
    var logged: [LoggedExercise]
    var startedAt: Date? = nil
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

    /// Load the current agent's persisted workout, if any and if fresh enough.
    ///
    /// - `maxAge`: rows older than this are treated as stale and dropped
    ///   inline (default 3 days). Without this, a workout kicked off days
    ///   ago and abandoned would forever surface a "Продолжить" card.
    /// - Throws on decode failure — callers must decide what to do with a
    ///   corrupt row (usually: log + clear). Silently returning nil there
    ///   would hide bugs.
    func load(agentId: String, maxAge: TimeInterval = 72 * 3600) throws -> ActiveWorkoutRecord? {
        let row: Row? = try writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT workout_id, plan_json, cursor_json, message_id, updated_at
                FROM active_workout WHERE agent_id = ?
            """, arguments: [agentId])
        }
        guard let row else { return nil }
        let updatedAt = Date(timeIntervalSince1970: row["updated_at"])
        if Date().timeIntervalSince(updatedAt) > maxAge {
            // Stale row — drop inline so it doesn't rot forever.
            try clear(agentId: agentId)
            return nil
        }
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
            updatedAt: updatedAt
        )
    }

    func clear(agentId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM active_workout WHERE agent_id = ?", arguments: [agentId])
        }
    }
}
