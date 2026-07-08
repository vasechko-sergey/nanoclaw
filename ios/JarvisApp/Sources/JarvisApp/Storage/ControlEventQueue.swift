import Foundation
import GRDB

/// The workout lifecycle events carried by the durable control-event outbox
/// (F4). Raw values are the wire `type` strings so the drain can rebuild the
/// exact envelope the host already parses.
enum ControlEventKind: String {
    case workoutComplete = "workout_complete"
    case workoutAbort = "workout_abort"
    case exerciseSwapConfirm = "exercise_swap_confirm"
}

/// One un-delivered control event: a stable `localId` (GRDB rowid) the drain
/// marks delivered after the send, plus the wire `kind` + the JSON-encoded V2
/// payload struct.
struct PendingControlEvent: Equatable {
    let localId: Int64
    let kind: String
    let payloadJson: String
    let ts: Date
}

/// Durable, ordered outbox for the three workout lifecycle envelopes
/// (`workout_complete` / `workout_abort` / `exercise_swap_confirm`). Backed by
/// the GRDB `control_event_queue` table (migration v16) so a queued event
/// survives an app kill — the whole point of F4: finishing a workout offline
/// must never lose the record.
///
/// Mirrors `SetLogQueue` (the set-log path this generalizes): the transport
/// drains `pending()` on auth/reconnect and calls `markDelivered(_:)` after the
/// send lands. Ordered by `rowid ASC` alone — insertion order = the order the
/// user actually took the actions (finish, then a later abort/swap), which is
/// what the host reconciles against.
///
/// Generic over `kind` + a JSON payload (rather than typed columns) because the
/// three payloads have different shapes; the typed `enqueue*` helpers below
/// encode the exact V2 struct the direct-send methods build, so the wire stays
/// byte-identical.
final class ControlEventQueue {
    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Persist a control event. `payloadJson` is the JSON-encoded V2 payload
    /// struct for `kind`; the transport decodes it back and wraps it in a fresh
    /// envelope at drain time.
    func enqueue(kind: String, payloadJson: String, ts: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO control_event_queue (kind, payload_json, ts_iso, delivered)
                VALUES (?, ?, ?, 0)
            """, arguments: [kind, payloadJson, Self.isoFormatter.string(from: ts)])
        }
    }

    func enqueueWorkoutComplete(_ payload: V2.WorkoutComplete, ts: Date = Date()) throws {
        try enqueue(kind: ControlEventKind.workoutComplete.rawValue,
                    payloadJson: try Self.encode(payload), ts: ts)
    }

    func enqueueWorkoutAbort(_ payload: V2.WorkoutAbort, ts: Date = Date()) throws {
        try enqueue(kind: ControlEventKind.workoutAbort.rawValue,
                    payloadJson: try Self.encode(payload), ts: ts)
    }

    func enqueueExerciseSwapConfirm(_ payload: V2.ExerciseSwapConfirm, ts: Date = Date()) throws {
        try enqueue(kind: ControlEventKind.exerciseSwapConfirm.rawValue,
                    payloadJson: try Self.encode(payload), ts: ts)
    }

    /// All un-delivered events in insertion (chronological) order.
    func pending() throws -> [PendingControlEvent] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid AS local_id, kind, payload_json, ts_iso
                FROM control_event_queue
                WHERE delivered = 0
                ORDER BY rowid ASC
            """).map { row in
                PendingControlEvent(
                    localId: row["local_id"],
                    kind: row["kind"],
                    payloadJson: row["payload_json"],
                    ts: Self.isoFormatter.date(from: row["ts_iso"]) ?? Date()
                )
            }
        }
    }

    func markDelivered(localId: Int64) throws {
        try writer.write { db in
            try db.execute(sql:
                "UPDATE control_event_queue SET delivered = 1 WHERE rowid = ?",
                arguments: [localId]
            )
        }
    }

    /// Drop already-delivered rows older than the retention horizon so the table
    /// doesn't grow unbounded. Caller picks the policy.
    func pruneDelivered(olderThan cutoff: Date) throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM control_event_queue
                WHERE delivered = 1 AND ts_iso < ?
            """, arguments: [Self.isoFormatter.string(from: cutoff)])
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
