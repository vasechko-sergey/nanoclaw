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
    var deviation: WorkoutRunnerLogic.SetDeviation? = nil
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
        let deviationJson: String? = event.deviation.flatMap { d in
            (try? JSONEncoder().encode(d)).flatMap { String(data: $0, encoding: .utf8) }
        }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO set_log_queue
                  (workout_id, exercise_slug, set_idx, reps, weight, reps_in_reserve, ts_iso, deviation_json, delivered)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, arguments: [
                event.workoutId,
                event.exerciseSlug,
                event.setIdx,
                event.reps,
                event.weight,
                event.repsInReserve,
                Self.isoFormatter.string(from: event.ts),
                deviationJson,
            ])
        }
    }

    /// All un-delivered events in deterministic order.
    func pending() throws -> [PendingSetLog] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid AS local_id, workout_id, exercise_slug, set_idx,
                       reps, weight, reps_in_reserve, ts_iso, deviation_json
                FROM set_log_queue
                WHERE delivered = 0
                ORDER BY rowid ASC
            """).map { row in
                let devJson: String? = row["deviation_json"]
                let dev: WorkoutRunnerLogic.SetDeviation? = devJson
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(WorkoutRunnerLogic.SetDeviation.self, from: $0) }
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
                        deviation: dev
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
