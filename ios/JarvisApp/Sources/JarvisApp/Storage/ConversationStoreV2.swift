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
}

final class ConversationStoreV2 {
    let writer: any DatabaseWriter
    init(writer: any DatabaseWriter) { self.writer = writer }

    func insertOutboundUserMessage(
        id: String,
        text: String,
        attachments: [V2.Attachment],
        context: V2.InlineContext?
    ) throws {
        try writer.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let encoder = JSONEncoder()
            let attachmentsJSON: String?
            if attachments.isEmpty {
                attachmentsJSON = nil
            } else {
                attachmentsJSON = String(data: try encoder.encode(attachments), encoding: .utf8)
            }
            let contextJSON: String?
            if let c = context {
                contextJSON = String(data: try encoder.encode(c), encoding: .utf8)
            } else {
                contextJSON = nil
            }
            try db.execute(sql: """
                INSERT INTO messages
                  (id, dir, seq, text, attachments_json, context_json, status, ts, created_at)
                VALUES (?, 'out', NULL, ?, ?, ?, 'queued', ?, ?)
            """, arguments: [id, text, attachmentsJSON, contextJSON, now, now])
        }
    }

    func queuedOutbound(limit: Int = 10) throws -> [StoredMessage] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE dir='out' AND status='queued'
                ORDER BY ts ASC LIMIT ?
            """, arguments: [limit])
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
                    createdAt: row["created_at"]
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

    func insertInbound(envelope: V2.Envelope, message: V2.Message) throws {
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
                  (id, dir, seq, text, attachments_json, status, ts, created_at)
                VALUES (?, 'in', ?, ?, ?, 'new', ?, ?)
            """, arguments: [envelope.id, envelope.seq, message.text, attachmentsJSON, now, now])
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
                createdAt: row["created_at"]
            )
        }
    }

    // MARK: - Single-timeline observation + retention

    /// Live view of the last `limit` messages, ordered ascending by `ts`.
    /// Drives the chat list UI via the `MessageTimeline` wrapper.
    func observeMessages(limit: Int = 500)
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
                    createdAt: row["created_at"]
                )
            }
        }
    }

    /// Hard-cap retention. Deletes messages beyond `keep` newest, and any
    /// orphaned attachments rows. Called by `MessageTimeline` after each insert.
    func prune(keep: Int = 500) throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM messages
                WHERE id NOT IN (
                  SELECT id FROM messages ORDER BY ts DESC LIMIT ?
                )
            """, arguments: [keep])
            try db.execute(sql: """
                DELETE FROM attachments
                WHERE message_id NOT IN (SELECT id FROM messages)
            """)
        }
    }
}
