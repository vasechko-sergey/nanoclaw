import Foundation
import GRDB

enum MessageDir: String { case out, in_ = "in" }
enum MessageStatus: String { case queued, sending, sent, delivered, read, failed, new }
enum CursorKey: String {
    case lastSeenInbound = "last_seen_inbound_seq"
    case lastSentOutbound = "last_sent_outbound_seq"
}

struct StoredMessage: Equatable {
    var id: String
    var dir: MessageDir
    var seq: Int?
    var text: String
    var attachmentsJSON: String?
    var contextJSON: String?
    var status: MessageStatus
    var failureReason: String?
    var ts: Int
    var serverTS: Int?
    var createdAt: Int
    var agentId: String = "jarvis"
    var actionsJSON: String? = nil
    var actionChoice: String? = nil
    var workoutPlanJSON: String? = nil
    var edited: Bool = false
    var voiceOnly: Bool = false
}

final class ConversationStoreV2 {
    let writer: any DatabaseWriter
    init(writer: any DatabaseWriter) { self.writer = writer }

    /// Parse a wire `ts` (ISO-8601 from the host, e.g. "2026-06-27T09:16:58.000Z")
    /// to epoch milliseconds. Returns nil on unparseable input so callers can
    /// fall back to local time.
    static func epochMillis(fromISO s: String) -> Int? {
        if let d = isoWithFraction.date(from: s) { return Int((d.timeIntervalSince1970 * 1000).rounded()) }
        if let d = isoPlain.date(from: s) { return Int((d.timeIntervalSince1970 * 1000).rounded()) }
        return nil
    }
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    func insertOutboundUserMessage(
        id: String,
        text: String,
        attachments: [V2.Attachment],
        context: V2.InlineContext?,
        agentId: String = "jarvis"
    ) throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let encoder = JSONEncoder()
            let attachmentsJSON: String?
            if attachments.isEmpty {
                attachmentsJSON = nil
            } else {
                let stored = attachments.map(StoredAttachment.from)
                attachmentsJSON = String(data: try encoder.encode(stored), encoding: .utf8)
            }
            let contextJSON: String?
            if let c = context {
                contextJSON = String(data: try encoder.encode(c), encoding: .utf8)
            } else {
                contextJSON = nil
            }
            try db.execute(sql: """
                INSERT INTO messages
                  (id, dir, seq, text, attachments_json, context_json, status, ts, created_at, agent_id)
                VALUES (?, 'out', NULL, ?, ?, ?, 'queued', ?, ?, ?)
            """, arguments: [id, text, attachmentsJSON, contextJSON, now, now, agentId])
        }
    }

    func queuedOutbound(agentId: String? = nil, limit: Int = 10) throws -> [StoredMessage] {
        try writer.read { db in
            let rows: [Row]
            if let agentId {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM messages
                    WHERE dir='out' AND status='queued' AND agent_id=?
                    ORDER BY ts ASC LIMIT ?
                """, arguments: [agentId, limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM messages
                    WHERE dir='out' AND status='queued'
                    ORDER BY ts ASC LIMIT ?
                """, arguments: [limit])
            }
            return rows.map { row in
                StoredMessage(
                    id: row["id"],
                    dir: MessageDir(rawValue: row["dir"]) ?? .out,
                    seq: row["seq"],
                    text: row["text"],
                    attachmentsJSON: row["attachments_json"],
                    contextJSON: row["context_json"],
                    status: MessageStatus(rawValue: row["status"]) ?? .queued,
                    failureReason: row["failure_reason"],
                    ts: row["ts"],
                    serverTS: row["server_ts"],
                    createdAt: row["created_at"],
                    agentId: row["agent_id"] ?? "jarvis",
                    actionsJSON: row["actions_json"],
                    actionChoice: row["action_choice"],
                    workoutPlanJSON: row["workout_plan_json"]
                )
            }
        }
    }

    func markSending(id: String, seq: Int) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET status='sending', seq=? WHERE id=?",
                           arguments: [seq, id])
        }
    }

    func markSent(id: String, serverTS: Int) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET status='sent', server_ts=? WHERE id=?",
                           arguments: [serverTS, id])
        }
    }

    func markFailed(id: String, reason: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET status='failed', failure_reason=? WHERE id=?",
                           arguments: [reason, id])
        }
    }

    func markDelivered(ids: [String]) throws {
        try writer.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE messages SET status='delivered' WHERE id=? AND status IN ('sent','sending')",
                               arguments: [id])
            }
        }
    }

    func markRead(ids: [String]) throws {
        try writer.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE messages SET status='read' WHERE id=? AND status IN ('sent','sending','delivered','new')",
                               arguments: [id])
            }
        }
    }

    func resetSendingToQueued(maxSeq: Int) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET status='queued' WHERE dir='out' AND status='sending' AND seq>?",
                           arguments: [maxSeq])
        }
    }

    /// User-driven retry: flip a failed outbound message back to queued so the
    /// dispatcher can pick it up on its next tick.
    func resetFailedToQueued(id: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE messages SET status='queued', failure_reason=NULL, seq=NULL
                WHERE id=? AND dir='out' AND status='failed'
            """, arguments: [id])
        }
    }

    func confirmAckedUpTo(maxSeq: Int) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET status='sent' WHERE dir='out' AND status='sending' AND seq<=?",
                           arguments: [maxSeq])
        }
    }

    func dedupSeen(id: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM inbound_dedup WHERE id=?)",
                              arguments: [id]) ?? false
        }
    }

    func recordDedup(id: String, seq: Int) throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            try db.execute(sql: "INSERT OR IGNORE INTO inbound_dedup (id, seq, received_at) VALUES (?, ?, ?)",
                           arguments: [id, seq, now])
        }
    }

    /// True if this inbound id has already raised a local notification.
    func notifiedSeen(id: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM inbound_dedup WHERE id=? AND notified_at IS NOT NULL)",
                arguments: [id]) ?? false
        }
    }

    /// Stamp an inbound id as notified. Upserts: the live path already wrote a
    /// dedup row (only notified_at flips); the pull path may insert fresh.
    func recordNotified(id: String, seq: Int) throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            try db.execute(
                sql: """
                INSERT INTO inbound_dedup (id, seq, received_at, notified_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET notified_at = excluded.notified_at
                """,
                arguments: [id, seq, now, now])
        }
    }

    func insertInbound(envelope: V2.Envelope, message: V2.Message, agentId: String = "jarvis") throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let encoder = JSONEncoder()
            let attachmentsJSON: String?
            if let atts = message.attachments, !atts.isEmpty {
                let stored = atts.map(StoredAttachment.from)
                attachmentsJSON = String(data: try encoder.encode(stored), encoding: .utf8)
            } else {
                attachmentsJSON = nil
            }
            let actionsJSON: String?
            if let acts = message.actions, !acts.isEmpty {
                let stored = acts.map(StoredAction.from)
                actionsJSON = String(data: try encoder.encode(stored), encoding: .utf8)
            } else {
                actionsJSON = nil
            }
            // Order by AUTHORED time (server `ts`), not local receipt: an
            // offline-queued reply drained late must not sort after newer
            // messages. Fall back to `now` if the wire ts can't be parsed.
            let authored = Self.epochMillis(fromISO: envelope.ts) ?? now
            try db.execute(sql: """
                INSERT INTO messages
                  (id, dir, seq, text, attachments_json, actions_json, status, ts, created_at, agent_id, voice_only)
                VALUES (?, 'in', ?, ?, ?, ?, 'new', ?, ?, ?, ?)
            """, arguments: [envelope.id, envelope.seq, message.text, attachmentsJSON, actionsJSON, authored, authored, agentId, (message.voice_only ?? false)])
        }
    }

    /// Persist an inbound workout plan as a chat message. The plan JSON is
    /// stored so the card (and the WorkoutView opened from it) survive reload.
    /// Idempotent on `id` (= workoutId) so a duplicate `workout_plan` envelope
    /// doesn't double the card. `text` holds a compact summary for the row's
    /// fallback/voiceover; the card view renders its own layout from the plan.
    func insertWorkoutPlan(id: String, agentId: String, plan: WorkoutPlan) throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let json = String(data: try JSONEncoder().encode(plan), encoding: .utf8)
            let summary = "🏋️ \(plan.dayName) · \(plan.intensityLabel) · \(plan.exercises.count) упр."
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages
                  (id, dir, seq, text, status, ts, created_at, agent_id, workout_plan_json)
                VALUES (?, 'in', NULL, ?, 'new', ?, ?, ?, ?)
            """, arguments: [id, summary, now, now, agentId, json])
        }
    }

    /// Edit a message's text in place (agent correction) and mark it edited so
    /// the UI can show a "(ред.)" tag. Returns whether a row was updated —
    /// false means the id is unknown (e.g. pruned), which is a silent no-op.
    @discardableResult
    func updateMessageText(id: String, text: String) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET text = ?, edited = 1 WHERE id = ?",
                           arguments: [text, id])
            return db.changesCount > 0
        }
    }

    /// Record the user's answer to an inbound action card. Persisted so the
    /// answered state survives reload (the rendered card shows the chosen option).
    func markActionAnswered(rowId: String, choice: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET action_choice=? WHERE id=?",
                           arguments: [choice, rowId])
        }
    }

    /// Mark every still-open workout-plan card whose plan carries `workoutId`
    /// as completed (greys its "Посмотреть тренировку" button). Matches by the
    /// decoded `workout_id`, NOT a transient in-memory row id, so the card
    /// resolves on finish even when the runner's presentation lost its
    /// `messageId` (e.g. a mid-workout exercise swap re-presented it). The
    /// persisted `action_choice` keeps it resolved across reloads. Returns how
    /// many cards were marked.
    @discardableResult
    func markWorkoutCardDone(workoutId: String) throws -> Int {
        try writer.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, workout_plan_json FROM messages WHERE workout_plan_json IS NOT NULL AND action_choice IS NULL"
            )
            var marked = 0
            for row in rows {
                guard let json: String = row["workout_plan_json"],
                      let data = json.data(using: .utf8),
                      let plan = try? JSONDecoder().decode(WorkoutPlan.self, from: data),
                      plan.workoutId == workoutId else { continue }
                let id: String = row["id"]
                try db.execute(sql: "UPDATE messages SET action_choice = 'completed' WHERE id = ?",
                               arguments: [id])
                marked += 1
            }
            return marked
        }
    }

    /// Clear the voice-only flag on a row (render failed → reveal its text).
    /// Returns whether a row changed.
    @discardableResult
    func clearVoiceOnly(rowId: String) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET voice_only=0 WHERE id=?", arguments: [rowId])
            return db.changesCount > 0
        }
    }

    /// Append an attachment to an existing message row. Used to merge a
    /// server-rendered voice note onto the text bubble it replies to (one
    /// combined bubble: audio + text) instead of inserting a separate row.
    /// Returns false if no row with `id` exists yet — the caller then falls
    /// back to a normal insert (the audio shows as its own bubble).
    @discardableResult
    func appendAttachment(toRowId id: String, attachment: V2.Attachment) throws -> Bool {
        try writer.write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT attachments_json FROM messages WHERE id=?", arguments: [id]
            ) else { return false }
            var atts: [StoredAttachment] = []
            if let json: String = row["attachments_json"], let data = json.data(using: .utf8) {
                atts = (try? JSONDecoder().decode([StoredAttachment].self, from: data)) ?? []
            }
            atts.append(StoredAttachment.from(attachment))
            let merged = String(data: try JSONEncoder().encode(atts), encoding: .utf8)
            try db.execute(sql: "UPDATE messages SET attachments_json=? WHERE id=?", arguments: [merged, id])
            return true
        }
    }

    func cursor(_ k: CursorKey) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT v FROM cursors WHERE k=?",
                             arguments: [k.rawValue]) ?? 0
        }
    }

    func setCursor(_ k: CursorKey, _ v: Int) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO cursors (k, v) VALUES (?, ?)
                ON CONFLICT(k) DO UPDATE SET v=excluded.v
            """, arguments: [k.rawValue, v])
        }
    }

    func allocateNextSendSeq() throws -> Int {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO cursors (k, v) VALUES (?, 1)
                ON CONFLICT(k) DO UPDATE SET v=v+1
            """, arguments: [CursorKey.lastSentOutbound.rawValue])
            return try Int.fetchOne(db, sql: "SELECT v FROM cursors WHERE k=?",
                                    arguments: [CursorKey.lastSentOutbound.rawValue]) ?? 0
        }
    }

    func countAllMessages() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
    }

    /// Count messages for a specific agent. Useful for per-agent badges/stats.
    func countMessages(agentId: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE agent_id=?",
                             arguments: [agentId]) ?? 0
        }
    }

    /// Fetch by primary key. `id` is globally unique across agents, so this is
    /// not agent-scoped; the returned row carries its `agentId` for the caller
    /// to verify if it cares about isolation.
    func fetchById(_ id: String) throws -> StoredMessage? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id=?", arguments: [id]) else {
                return nil
            }
            return StoredMessage(
                id: row["id"],
                dir: MessageDir(rawValue: row["dir"]) ?? .out,
                seq: row["seq"],
                text: row["text"],
                attachmentsJSON: row["attachments_json"],
                contextJSON: row["context_json"],
                status: MessageStatus(rawValue: row["status"]) ?? .queued,
                failureReason: row["failure_reason"],
                ts: row["ts"],
                serverTS: row["server_ts"],
                createdAt: row["created_at"],
                agentId: row["agent_id"] ?? "jarvis",
                actionsJSON: row["actions_json"],
                actionChoice: row["action_choice"],
                workoutPlanJSON: row["workout_plan_json"],
                edited: row["edited"] ?? false
            )
        }
    }

    /// All stored rows (across agents), for the startup cache prewarm. GRDB
    /// serializes the read, so this is safe to call from a background task.
    func allRows() throws -> [StoredMessage] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages").map { row in
                StoredMessage(
                    id: row["id"],
                    dir: MessageDir(rawValue: row["dir"]) ?? .out,
                    seq: row["seq"],
                    text: row["text"],
                    attachmentsJSON: row["attachments_json"],
                    contextJSON: row["context_json"],
                    status: MessageStatus(rawValue: row["status"]) ?? .queued,
                    failureReason: row["failure_reason"],
                    ts: row["ts"],
                    serverTS: row["server_ts"],
                    createdAt: row["created_at"],
                    agentId: row["agent_id"] ?? "jarvis",
                    actionsJSON: row["actions_json"],
                    actionChoice: row["action_choice"],
                    workoutPlanJSON: row["workout_plan_json"],
                    edited: row["edited"] ?? false
                )
            }
        }
    }

    // MARK: - Single-timeline observation + retention

    /// Live view of the last `limit` messages for a specific agent, ordered
    /// ascending by `ts`. Drives the chat list UI via `MessageTimeline`.
    func observeMessages(agentId: String = "jarvis", limit: Int = 500)
        -> ValueObservation<ValueReducers.Fetch<[StoredMessage]>>
    {
        ValueObservation.tracking { db -> [StoredMessage] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE agent_id=?
                ORDER BY ts DESC, rowid DESC
                LIMIT ?
            """, arguments: [agentId, limit])
            return rows.reversed().map { row in
                StoredMessage(
                    id: row["id"],
                    dir: MessageDir(rawValue: row["dir"]) ?? .out,
                    seq: row["seq"],
                    text: row["text"],
                    attachmentsJSON: row["attachments_json"],
                    contextJSON: row["context_json"],
                    status: MessageStatus(rawValue: row["status"]) ?? .queued,
                    failureReason: row["failure_reason"],
                    ts: row["ts"],
                    serverTS: row["server_ts"],
                    createdAt: row["created_at"],
                    agentId: row["agent_id"] ?? "jarvis",
                    actionsJSON: row["actions_json"],
                    actionChoice: row["action_choice"],
                    workoutPlanJSON: row["workout_plan_json"],
                    edited: row["edited"] ?? false
                )
            }
        }
    }

    /// Observe each agent's own newest `perAgent` messages, unioned across all
    /// agents into one stream (the chat view filters by the active chip). The
    /// window is PER AGENT — not a single global newest-N — so a low-traffic
    /// agent's history is never evicted from the window by a chatty agent (the
    /// bug that left a rarely-used agent's chat blank). Rows are returned
    /// oldest-first by `ts` to match the chat list order.
    func observeAllMessages(perAgent: Int = 500)
        -> ValueObservation<ValueReducers.Fetch<[StoredMessage]>>
    {
        ValueObservation.tracking { db -> [StoredMessage] in
            try Self.windowedRows(db, perAgent: perAgent)
        }
    }

    /// Each agent's newest `perAgent` rows (partitioned by `agent_id`),
    /// oldest-first overall. Shared by the observation and unit tests. Uses a
    /// window function (SQLite ≥ 3.25, well below the iOS floor).
    static func windowedRows(_ db: Database, perAgent: Int) throws -> [StoredMessage] {
        // `rowid` (insertion order) is the stable tiebreaker: `ts` collides when
        // the agent emits several <message> blocks in the same millisecond, and
        // `created_at == ts` at insert so it can't break the tie. Without this,
        // any re-fetch (e.g. triggered by an edit's in-place UPDATE) can reorder
        // equal-ts rows. rowid order = arrival/send order = correct display order.
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM (
              SELECT *, rowid AS _rid, ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY ts DESC, rowid DESC) AS _rn
              FROM messages
            )
            WHERE _rn <= ?
            ORDER BY ts ASC, _rid ASC
        """, arguments: [perAgent])
        return rows.map(Self.mapRow)
    }

    /// Map a `messages` row to `StoredMessage`. Single source of truth for the
    /// column decode (was duplicated across every fetch method).
    static func mapRow(_ row: Row) -> StoredMessage {
        StoredMessage(
            id: row["id"],
            dir: MessageDir(rawValue: row["dir"]) ?? .out,
            seq: row["seq"],
            text: row["text"],
            attachmentsJSON: row["attachments_json"],
            contextJSON: row["context_json"],
            status: MessageStatus(rawValue: row["status"]) ?? .queued,
            failureReason: row["failure_reason"],
            ts: row["ts"],
            serverTS: row["server_ts"],
            createdAt: row["created_at"],
            agentId: row["agent_id"] ?? "jarvis",
            actionsJSON: row["actions_json"],
            actionChoice: row["action_choice"],
            workoutPlanJSON: row["workout_plan_json"],
            edited: row["edited"] ?? false,
            voiceOnly: row["voice_only"] ?? false
        )
    }

    /// Hard-cap retention PER AGENT: keep only each agent's newest `keep`
    /// messages. Per-agent (not global) so a chatty agent can't evict a quiet
    /// agent's history out of the DB. Cheap no-op unless some agent actually
    /// exceeds `keep` (the MAX-per-agent pre-check skips the window scan in
    /// steady state). Called after each insert.
    func prune(keep: Int = 500) throws {
        try writer.write { db in
            let maxPerAgent = try Int.fetchOne(db, sql: """
                SELECT MAX(c) FROM (SELECT COUNT(*) AS c FROM messages GROUP BY agent_id)
            """) ?? 0
            guard maxPerAgent > keep else { return }
            try db.execute(sql: """
                DELETE FROM messages WHERE id IN (
                  SELECT id FROM (
                    SELECT id, ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY ts DESC) AS _rn
                    FROM messages
                  )
                  WHERE _rn > ?
                )
            """, arguments: [keep])
        }
    }
}
