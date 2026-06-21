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
}

final class ConversationStoreV2 {
    let writer: any DatabaseWriter
    init(writer: any DatabaseWriter) { self.writer = writer }

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
                    agentId: row["agent_id"] ?? "jarvis"
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

    func insertInbound(envelope: V2.Envelope, message: V2.Message, agentId: String = "jarvis") throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let encoder = JSONEncoder()
            let attachmentsJSON: String?
            if let atts = message.attachments, !atts.isEmpty {
                attachmentsJSON = String(data: try encoder.encode(atts), encoding: .utf8)
            } else {
                attachmentsJSON = nil
            }
            try db.execute(sql: """
                INSERT INTO messages
                  (id, dir, seq, text, attachments_json, status, ts, created_at, agent_id)
                VALUES (?, 'in', ?, ?, ?, 'new', ?, ?, ?)
            """, arguments: [envelope.id, envelope.seq, message.text, attachmentsJSON, now, now, agentId])
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
            var atts: [V2.Attachment] = []
            if let json: String = row["attachments_json"], let data = json.data(using: .utf8) {
                atts = (try? JSONDecoder().decode([V2.Attachment].self, from: data)) ?? []
            }
            atts.append(attachment)
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
                agentId: row["agent_id"] ?? "jarvis"
            )
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
                ORDER BY ts DESC
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
                    agentId: row["agent_id"] ?? "jarvis"
                )
            }
        }
    }

    /// Observe the entire `messages` table across ALL agents. The chat view
    /// renders one unified stream and filters per-agent at the view layer
    /// (see `ChatView.visibleMessages`), so the timeline subscription must
    /// not pre-filter by `agent_id`. Returns rows oldest-first to match
    /// `observeMessages`.
    func observeAllMessages(limit: Int = 500)
        -> ValueObservation<ValueReducers.Fetch<[StoredMessage]>>
    {
        ValueObservation.tracking { db -> [StoredMessage] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM messages
                ORDER BY ts DESC
                LIMIT ?
            """, arguments: [limit])
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
                    agentId: row["agent_id"] ?? "jarvis"
                )
            }
        }
    }

    /// Hard-cap retention, per agent. Deletes messages in this agent's bucket
    /// beyond `keep` newest, and any orphaned attachments rows. Called by
    /// `MessageTimeline` after each insert.
    /// Keep only the most recent `keep` messages across ALL agents — matches the
    /// global 500-row timeline fetch. Was previously per-agent with a default
    /// `agentId: "jarvis"`, so non-jarvis timelines (payne/greg/scrooge) were
    /// never pruned and the table grew unbounded. Cheap no-op while under cap
    /// (the count pre-check avoids the NOT IN scan in steady state).
    func prune(keep: Int = 500) throws {
        try writer.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
            guard count > keep else { return }
            try db.execute(sql: """
                DELETE FROM messages
                WHERE id NOT IN (SELECT id FROM messages ORDER BY ts DESC LIMIT ?)
            """, arguments: [keep])
            try db.execute(sql: """
                DELETE FROM attachments
                WHERE message_id NOT IN (SELECT id FROM messages)
            """)
        }
    }
}
