import Foundation
import GRDB

enum MessageDir: String { case out, in_ = "in" }
enum MessageStatus: String { case queued, sending, sent, delivered, read, failed, new }
/// Per-message 👍/👎 selection (F21). Persisted in `messages.feedback`: a NULL
/// column decodes to `.none`, otherwise the rawValue. `.none` is never written
/// as text — `setFeedback` clears the column to NULL. Assistant messages only.
enum MessageFeedback: String { case none, up, down }
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
    var feedback: MessageFeedback = .none
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
        agentId: String = "jarvis",
        status: MessageStatus = .queued
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
                VALUES (?, 'out', NULL, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, text, attachmentsJSON, contextJSON, status.rawValue, now, now, agentId])
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
            let now = Date()
            try db.execute(sql: "INSERT OR IGNORE INTO inbound_dedup (id, seq, received_at) VALUES (?, ?, ?)",
                           arguments: [id, seq, Int(now.timeIntervalSince1970 * 1000)])
            // Bound the table (Finding F28): sweep rows past the retention window
            // in the same transaction, so it costs no extra write lock.
            try Self.pruneDedup(db, retentionDays: 30, now: now)
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
            let now = Date()
            let nowMs = Int(now.timeIntervalSince1970 * 1000)
            try db.execute(
                sql: """
                INSERT INTO inbound_dedup (id, seq, received_at, notified_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET notified_at = excluded.notified_at
                """,
                arguments: [id, seq, nowMs, nowMs])
            // Bound the table (Finding F28) — same as recordDedup; also covers the
            // pull/notify path, which may insert dedup rows without a prior WS write.
            try Self.pruneDedup(db, retentionDays: 30, now: now)
        }
    }

    /// Retention prune for `inbound_dedup` (Finding F28). The table records one
    /// row per inbound message id (for WS/pull double-delivery + double-notify
    /// dedup) and otherwise grows forever. We prune by AGE — drop rows whose
    /// `received_at` is older than `retentionDays` (default 30) — rather than by
    /// count: dedup relevance is inherently time-bounded (a re-delivery or
    /// background re-pull lands within minutes/hours, never weeks later), so an
    /// age window needs no ordering and self-describes the guarantee. Called
    /// inside every dedup write, so the backlog is swept on the first inbound
    /// after this fix ships and stays bounded thereafter.
    func pruneDedup(retentionDays: Int = 30, now: Date = Date()) throws {
        try writer.write { db in
            try Self.pruneDedup(db, retentionDays: retentionDays, now: now)
        }
    }

    /// Prune within an existing write transaction (shared by `pruneDedup` and
    /// the dedup writers so it costs no extra write lock).
    static func pruneDedup(_ db: Database, retentionDays: Int, now: Date) throws {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let cutoff = nowMs - retentionDays * 24 * 60 * 60 * 1000
        try db.execute(sql: "DELETE FROM inbound_dedup WHERE received_at < ?", arguments: [cutoff])
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
            // UPSERT: a WS delivery is authoritative for CONTENT — it upgrades a
            // prior row (e.g. the text-only stub the background pull path inserts)
            // to the full version (attachments/actions). Two carve-outs:
            //  • status + created_at are NOT in the SET clause → a redelivery of
            //    an already-`read` message doesn't flip it back to unread.
            //  • WHERE edited = 0 → an agent correction (update envelope) is never
            //    reverted by a later redelivery of the original.
            // ON CONFLICT DO UPDATE never throws, so a redelivery stays a safe
            // upgrade-or-no-op (preserves the build-72 "don't strand" guarantee).
            try db.execute(sql: """
                INSERT INTO messages
                  (id, dir, seq, text, attachments_json, actions_json, status, ts, created_at, agent_id, voice_only)
                VALUES (?, 'in', ?, ?, ?, ?, 'new', ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  text = excluded.text,
                  attachments_json = excluded.attachments_json,
                  actions_json = excluded.actions_json,
                  seq = excluded.seq,
                  ts = excluded.ts,
                  agent_id = excluded.agent_id,
                  voice_only = excluded.voice_only
                WHERE messages.edited = 0
            """, arguments: [envelope.id, envelope.seq, message.text, attachmentsJSON, actionsJSON, authored, authored, agentId, (message.voice_only ?? false)])
        }
    }

    /// Idempotent text-row insert for the background PULL path
    /// (`PendingNotifications`). Mirrors `insertInbound`'s row shape minus
    /// attachments/actions. `INSERT OR IGNORE` on the `id` PK so a re-pull
    /// doesn't duplicate; a later WS `insertInbound` UPSERTs over this stub and
    /// upgrades it to the full content. Does NOT advance the inbound cursor or
    /// record dedup — only the WS path owns those.
    func insertInboundFromPull(id: String, seq: Int?, text: String, agentId: String, ts: Int) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages
                  (id, dir, seq, text, status, ts, created_at, agent_id)
                VALUES (?, 'in', ?, ?, 'new', ?, ?, ?)
            """, arguments: [id, seq, text, ts, ts, agentId])
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

    /// Update a message's text WITHOUT marking it edited. Used for locally
    /// injected placeholder rows (Fix M: workout summary) where an evolving
    /// status label ("Разбираем…" → "Пейн задерживается…") should stay a
    /// plain assistant message without acquiring the "(ред.)" chrome.
    @discardableResult
    func updatePlaceholderText(id: String, text: String) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "UPDATE messages SET text = ? WHERE id = ?",
                           arguments: [text, id])
            return db.changesCount > 0
        }
    }

    /// Delete a message row by id. Used to sweep a local placeholder once the
    /// real reply from the same agent lands (Fix M).
    @discardableResult
    func deleteMessage(id: String) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])
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

    /// Persist the user's 👍/👎 selection for a message (F21), keyed by message
    /// id. `.none` clears it (column → NULL). No-op if the id is unknown (the row
    /// was pruned) — same forgiving semantics as `markActionAnswered`. This only
    /// records the LOCAL display selection; the host send stays on the existing
    /// Feedback envelope, fired once on set from `ChatView.onFeedback`.
    func setFeedback(messageId: String, _ feedback: MessageFeedback) throws {
        try writer.write { db in
            let stored: String? = feedback == .none ? nil : feedback.rawValue
            try db.execute(sql: "UPDATE messages SET feedback=? WHERE id=?",
                           arguments: [stored, messageId])
        }
    }

    /// Read the persisted 👍/👎 selection for a message (F21). Unknown id or a
    /// NULL column both decode to `.none`.
    func getFeedback(messageId: String) throws -> MessageFeedback {
        try writer.read { db in
            guard let raw = try String.fetchOne(
                db, sql: "SELECT feedback FROM messages WHERE id=?", arguments: [messageId]
            ) else { return .none }
            return MessageFeedback(rawValue: raw) ?? .none
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

    // MARK: - Per-agent unread (F30)
    //
    // "Unread" reuses the existing `status` vocabulary — no parallel marker.
    // Every inbound row (`dir='in'`) is inserted with `status='new'` (see
    // `insertInbound` / `insertInboundFromPull` / `insertWorkoutPlan`), and
    // nothing flips inbound rows to `read` except `markAgentRead` below (the
    // drawer/chat mark-read). Outbound rows start `queued` and never carry
    // `new`, so the user's own sends never count as unread. Inbound rows never
    // render a delivery tick (MessageRow gates `DeliveryChecks` on the user
    // role), so flipping their status is invisible to the chat UI.

    /// Count unread inbound messages for one agent — inbound rows still in
    /// their insert-time `status='new'` state.
    func countUnread(agentId: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM messages WHERE agent_id=? AND dir='in' AND status='new'",
                arguments: [agentId]) ?? 0
        }
    }

    /// Per-agent unread counts, keyed by `agent_id`, in one GROUP BY. Agents
    /// with zero unread are absent from the map (drives the drawer dots).
    func unreadCountsByAgent() throws -> [String: Int] {
        try writer.read { db in
            var out: [String: Int] = [:]
            let rows = try Row.fetchAll(db, sql:
                "SELECT agent_id AS a, COUNT(*) AS c FROM messages WHERE dir='in' AND status='new' GROUP BY agent_id")
            for row in rows {
                if let a: String = row["a"] { out[a] = row["c"] }
            }
            return out
        }
    }

    /// Mark every unread inbound message for one agent as read — advances that
    /// agent's unread count to 0 without touching other agents' rows or any
    /// outbound delivery state. Returns how many rows were marked.
    @discardableResult
    func markAgentRead(agentId: String) throws -> Int {
        try writer.write { db in
            try db.execute(sql:
                "UPDATE messages SET status='read' WHERE agent_id=? AND dir='in' AND status='new'",
                arguments: [agentId])
            return db.changesCount
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

    // MARK: - Message observation + retention

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
        // Sort key is COALESCE(server_ts, ts) — a SINGLE clock (the host's).
        // Inbound rows carry a host-clock `ts` (authored/enqueue time) and no
        // server_ts, so they sort by `ts`. Outbound rows carry a device-clock
        // `ts` (Date.now() when typed) but ALSO a host-clock `server_ts` once the
        // host acks them; using server_ts puts them on the same clock as inbound.
        // Sorting by raw `ts` compared two independent clocks — a phone running
        // even a few minutes off the VDS reordered the chat (the reported "agent
        // reply shows before my question" bug). Un-acked optimistic outbound has
        // no server_ts yet → falls back to device `ts` (bottom), which is correct.
        //
        // `rowid` (insertion order) stays the stable tiebreaker: the sort key
        // collides when the agent emits several <message> blocks in the same
        // millisecond, and an edit's in-place UPDATE must not reorder equal-key
        // rows. rowid order = arrival/send order = correct display order.
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM (
              SELECT *, rowid AS _rid, COALESCE(server_ts, ts) AS _sortts,
                     ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY COALESCE(server_ts, ts) DESC, rowid DESC) AS _rn
              FROM messages
            )
            WHERE _rn <= ?
            ORDER BY _sortts ASC, _rid ASC
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
            voiceOnly: row["voice_only"] ?? false,
            feedback: MessageFeedback(rawValue: row["feedback"] ?? "") ?? .none
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
                    SELECT id, ROW_NUMBER() OVER (PARTITION BY agent_id ORDER BY COALESCE(server_ts, ts) DESC) AS _rn
                    FROM messages
                  )
                  WHERE _rn > ?
                )
            """, arguments: [keep])
        }
    }
}
