import Foundation
import GRDB

enum MessageDir: String { case out, in_ = "in" }
enum MessageStatus: String { case queued, sending, sent, delivered, read, failed, new }
enum CursorKey: String {
    case lastSeenInbound = "last_seen_inbound_seq"
    case lastSentOutbound = "last_sent_outbound_seq"
}

/// Lightweight read-model for the drawer/list views. Sourced from the
/// `conversations` table — does NOT carry preview/message-count (those are
/// owned by the legacy `ConversationStore` for now and can be folded in later).
struct ConversationSummary: Equatable, Identifiable {
    let id: String
    let title: String?
    let lastMessageAt: Int
    let archived: Bool
}

struct StoredMessage: Equatable {
    var id: String
    var conversationId: String
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

    private func ensureConversation(_ db: Database, id: String) throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try db.execute(sql: """
            INSERT INTO conversations (id, title, created_at, last_message_at, archived)
            VALUES (?, NULL, ?, ?, 0)
            ON CONFLICT(id) DO NOTHING
        """, arguments: [id, now, now])
    }

    func insertOutboundUserMessage(
        conversationId: String,
        id: String,
        text: String,
        attachments: [V2.Attachment],
        context: V2.InlineContext?
    ) throws {
        try writer.write { db in
            try ensureConversation(db, id: conversationId)
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
                  (id, conversation_id, dir, seq, text, attachments_json, context_json, status, ts, created_at)
                VALUES (?, ?, 'out', NULL, ?, ?, ?, 'queued', ?, ?)
            """, arguments: [id, conversationId, text, attachmentsJSON, contextJSON, now, now])
        }
    }

    func queuedOutbound(limit: Int = 10) throws -> [StoredMessage] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE dir='out' AND status='queued'
                ORDER BY ts ASC LIMIT ?
            """, arguments: [limit])
            return rows.map { row -> StoredMessage in
                StoredMessage(
                    id: row["id"],
                    conversationId: row["conversation_id"],
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
            try ensureConversation(db, id: message.thread_id)
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
                  (id, conversation_id, dir, seq, text, attachments_json, status, ts, created_at)
                VALUES (?, ?, 'in', ?, ?, ?, 'new', ?, ?)
            """, arguments: [envelope.id, message.thread_id, envelope.seq, message.text,
                             attachmentsJSON, now, now])
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

    // MARK: - Migration helpers (one-shot v1→v2 import)

    /// Migration-only: insert an outbound row already marked as `sent` (history import).
    /// Bypasses the queued/sending pipeline — callers must own dedup.
    func insertOutboundHistoryRow(
        conversationId: String,
        id: String,
        text: String,
        ts: Int,
        serverTS: Int?
    ) throws {
        try writer.write { db in
            try ensureConversation(db, id: conversationId)
            let now = Int(Date().timeIntervalSince1970 * 1000)
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages
                  (id, conversation_id, dir, seq, text, status, ts, server_ts, created_at)
                VALUES (?, ?, 'out', NULL, ?, 'sent', ?, ?, ?)
            """, arguments: [id, conversationId, text, ts, serverTS, now])
        }
    }

    /// Migration-only: insert an inbound row at `new` status without going through
    /// the dedup table. Used to import legacy cached history into the v2 store.
    func insertInboundHistoryRow(
        conversationId: String,
        id: String,
        text: String,
        ts: Int
    ) throws {
        try writer.write { db in
            try ensureConversation(db, id: conversationId)
            let now = Int(Date().timeIntervalSince1970 * 1000)
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages
                  (id, conversation_id, dir, seq, text, status, ts, created_at)
                VALUES (?, ?, 'in', NULL, ?, 'new', ?, ?)
            """, arguments: [id, conversationId, text, ts, now])
        }
    }

    // MARK: - Conversations API (drawer + creation)

    /// Insert a conversation row if not already present. Safe to call
    /// repeatedly with the same id — `INSERT OR IGNORE` semantics. Used by
    /// the legacy `ConversationStore` to sync each in-memory conversation
    /// into the v2 store, and by `AppCoordinator.handleAction(.newChat)`
    /// when starting a new chat.
    func createConversation(id: String, title: String? = nil, createdAt: Date = Date()) throws {
        try writer.write { db in
            let ts = Int(createdAt.timeIntervalSince1970 * 1000)
            try db.execute(sql: """
                INSERT OR IGNORE INTO conversations (id, title, created_at, last_message_at, archived)
                VALUES (?, ?, ?, ?, 0)
            """, arguments: [id, title, ts, ts])
            // If row existed but title was null and we now have one, fill it in.
            if title != nil {
                try db.execute(sql: """
                    UPDATE conversations SET title=? WHERE id=? AND (title IS NULL OR title='')
                """, arguments: [title, id])
            }
        }
    }

    /// All non-archived conversations, newest first.
    func listConversations() throws -> [ConversationSummary] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, last_message_at, archived
                FROM conversations
                WHERE archived = 0
                ORDER BY last_message_at DESC
            """).map { row in
                let archivedInt: Int = row["archived"]
                return ConversationSummary(
                    id: row["id"],
                    title: row["title"],
                    lastMessageAt: row["last_message_at"],
                    archived: archivedInt != 0
                )
            }
        }
    }

    /// Soft-delete a conversation (archived=1). Messages remain so the data
    /// is recoverable; the drawer hides archived rows.
    func archiveConversation(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE conversations SET archived=1 WHERE id=?", arguments: [id])
        }
    }

    /// GRDB observation source for live drawer updates. Currently unused —
    /// the drawer reads on-appear via `listConversations()` plus the v1
    /// `ConversationStore` change signal. Kept for forward use once the
    /// legacy store is fully retired.
    func observeConversations() -> ValueObservation<ValueReducers.Fetch<[ConversationSummary]>> {
        ValueObservation.tracking { db -> [ConversationSummary] in
            try Row.fetchAll(db, sql: """
                SELECT id, title, last_message_at, archived
                FROM conversations
                WHERE archived = 0
                ORDER BY last_message_at DESC
            """).map { row in
                let archivedInt: Int = row["archived"]
                return ConversationSummary(
                    id: row["id"],
                    title: row["title"],
                    lastMessageAt: row["last_message_at"],
                    archived: archivedInt != 0
                )
            }
        }
    }

    func fetchById(_ id: String) throws -> StoredMessage? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id=?", arguments: [id]) else {
                return nil
            }
            return StoredMessage(
                id: row["id"],
                conversationId: row["conversation_id"],
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
