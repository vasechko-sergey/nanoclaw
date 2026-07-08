import Foundation
import GRDB

/// In-flight set_log event before delivery to Payne. Carries the same fields
/// the WS envelope expects, plus a stable `localId` (GRDB rowid) so the
/// transport can mark each row delivered after ack.
struct SetLogEvent: Equatable {
    let workoutId: String
    let exerciseSlug: String
    let setIdx: Int
    let reps: Int
    let weight: Double
    let repsInReserve: Int
    let ts: Date
    /// All deviations for this set (weight/reps/rir). Empty ⇒ on-plan.
    var deviations: [WorkoutRunnerLogic.SetDeviation] = []
}

struct PendingSetLog: Equatable {
    let localId: Int64
    let event: SetLogEvent
}

/// Durable, ordered queue of set_log events backed by GRDB. The transport
/// layer drains `pending()` and calls `markDelivered(_:)` after the server
/// ack lands. Ordered by `rowid ASC` alone — insertion order = chronological
/// order in a single-writer setup, so two overlapping workouts (paused A +
/// start B) drain in the order the user actually logged them. Sorting by
/// `workout_id` first would lexically interleave the two — Payne would see
/// them out of order.
final class SetLogQueue {
    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    func enqueue(_ event: SetLogEvent) throws {
        // Write only the new `deviations_json` (array) column going forward. The
        // legacy `deviation_json` column stays in the table (SQLite can't drop it
        // cheaply) but is left NULL for new rows.
        let deviationsJson: String? = event.deviations.isEmpty ? nil
            : (try? JSONEncoder().encode(event.deviations)).flatMap { String(data: $0, encoding: .utf8) }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO set_log_queue
                  (workout_id, exercise_slug, set_idx, reps, weight, reps_in_reserve, ts_iso, deviations_json, delivered)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, arguments: [
                event.workoutId,
                event.exerciseSlug,
                event.setIdx,
                event.reps,
                event.weight,
                event.repsInReserve,
                Self.isoFormatter.string(from: event.ts),
                deviationsJson,
            ])
        }
    }

    /// All un-delivered events in deterministic order.
    func pending() throws -> [PendingSetLog] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid AS local_id, workout_id, exercise_slug, set_idx,
                       reps, weight, reps_in_reserve, ts_iso, deviations_json, deviation_json
                FROM set_log_queue
                WHERE delivered = 0
                ORDER BY rowid ASC
            """).map { row in
                // Prefer the new array column; fall back to a legacy single
                // `deviation_json` object (rows enqueued by a pre-array build).
                let devs: [WorkoutRunnerLogic.SetDeviation]
                if let devsJson: String = row["deviations_json"],
                   let data = devsJson.data(using: .utf8),
                   let arr = try? JSONDecoder().decode([WorkoutRunnerLogic.SetDeviation].self, from: data) {
                    devs = arr
                } else if let legacyJson: String = row["deviation_json"],
                          let data = legacyJson.data(using: .utf8),
                          let single = try? JSONDecoder().decode(WorkoutRunnerLogic.SetDeviation.self, from: data) {
                    devs = [single]
                } else {
                    devs = []
                }
                return PendingSetLog(
                    localId: row["local_id"],
                    event: SetLogEvent(
                        workoutId: row["workout_id"],
                        exerciseSlug: row["exercise_slug"],
                        setIdx: row["set_idx"],
                        reps: row["reps"],
                        weight: row["weight"],
                        repsInReserve: row["reps_in_reserve"],
                        ts: Self.isoFormatter.date(from: row["ts_iso"]) ?? Date(),
                        deviations: devs
                    )
                )
            }
        }
    }

    func markDelivered(localId: Int64) throws {
        try writer.write { db in
            try db.execute(sql:
                "UPDATE set_log_queue SET delivered = 1 WHERE rowid = ?",
                arguments: [localId]
            )
        }
    }

    /// Drop already-delivered rows older than the retention horizon (so the
    /// table doesn't grow unbounded). Caller picks the policy.
    func pruneDelivered(olderThan cutoff: Date) throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM set_log_queue
                WHERE delivered = 1 AND ts_iso < ?
            """, arguments: [Self.isoFormatter.string(from: cutoff)])
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
