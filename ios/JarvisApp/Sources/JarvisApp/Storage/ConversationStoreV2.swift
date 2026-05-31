import Foundation
import GRDB

enum MessageDir: String { case out, in_ = "in" }
enum MessageStatus: String { case queued, sending, sent, delivered, read, failed, new }
enum CursorKey: String {
    case lastSeenInbound = "last_seen_inbound_seq"
    case lastSentOutbound = "last_sent_outbound_seq"
}

/// Lightweight read-model for the drawer/list views. Sourced from joining
/// `conversations` with an aggregate over `messages` (count + latest text
/// preview). `messageCount` / `preview` were owned by the legacy v1
/// `ConversationStore`'s JSON index — they're derived from GRDB now that the
/// legacy shim has been retired.
struct ConversationSummary: Equatable, Identifiable {
    let id: String
    let title: String?
    let createdAt: Int
    let lastMessageAt: Int
    let archived: Bool
    let isPinned: Bool
    let messageCount: Int
    let preview: String
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
    func createConversation(
        id: String,
        title: String? = nil,
        createdAt: Date = Date(),
        lastMessageAt: Date? = nil,
        isPinned: Bool = false
    ) throws {
        try writer.write { db in
            let createdTS = Int(createdAt.timeIntervalSince1970 * 1000)
            let lastTS = lastMessageAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? createdTS
            try db.execute(sql: """
                INSERT OR IGNORE INTO conversations
                  (id, title, created_at, last_message_at, archived, is_pinned)
                VALUES (?, ?, ?, ?, 0, ?)
            """, arguments: [id, title, createdTS, lastTS, isPinned ? 1 : 0])
            // If row existed but title was null and we now have one, fill it in.
            if title != nil {
                try db.execute(sql: """
                    UPDATE conversations SET title=? WHERE id=? AND (title IS NULL OR title='')
                """, arguments: [title, id])
            }
        }
    }

    /// Shared SQL for the drawer summary view. Joins the row with a tiny
    /// aggregate that gives the message count and the latest text preview so
    /// the drawer can render `title / preview / N сообщ.` without a second
    /// query per row.
    private static let conversationSummarySQL = """
        SELECT
          c.id              AS id,
          c.title           AS title,
          c.created_at      AS created_at,
          c.last_message_at AS last_message_at,
          c.archived        AS archived,
          c.is_pinned       AS is_pinned,
          COALESCE(agg.cnt, 0) AS message_count,
          COALESCE(agg.last_text, '') AS preview
        FROM conversations c
        LEFT JOIN (
          SELECT
            conversation_id,
            COUNT(*) AS cnt,
            (SELECT text FROM messages m2
              WHERE m2.conversation_id = m.conversation_id
              ORDER BY m2.ts DESC LIMIT 1) AS last_text
          FROM messages m
          GROUP BY conversation_id
        ) AS agg ON agg.conversation_id = c.id
        WHERE c.archived = 0
        ORDER BY c.is_pinned DESC, c.last_message_at DESC
    """

    private static func mapSummary(_ row: Row) -> ConversationSummary {
        let archivedInt: Int = row["archived"]
        let pinnedInt: Int = row["is_pinned"]
        return ConversationSummary(
            id: row["id"],
            title: row["title"],
            createdAt: row["created_at"],
            lastMessageAt: row["last_message_at"],
            archived: archivedInt != 0,
            isPinned: pinnedInt != 0,
            messageCount: row["message_count"],
            preview: row["preview"] ?? ""
        )
    }

    /// All non-archived conversations, newest first (pinned float to the top).
    func listConversations() throws -> [ConversationSummary] {
        try writer.read { db in
            try Row.fetchAll(db, sql: Self.conversationSummarySQL).map(Self.mapSummary)
        }
    }

    /// Soft-delete a conversation (archived=1). Messages remain so the data
    /// is recoverable; the drawer hides archived rows. Used as the destructive
    /// path when the user swipes-to-delete in the drawer.
    func archiveConversation(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE conversations SET archived=1 WHERE id=?", arguments: [id])
        }
    }

    /// Hard-delete a conversation row and all its messages. Mirrors the legacy
    /// v1 `ConversationStore.deleteConversation` semantic so re-running a
    /// migration on a device the user has already cleaned up doesn't bring
    /// orphan rows back. Triggered by the drawer's "Удалить" confirmation.
    func deleteConversation(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE conversation_id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM conversations WHERE id=?", arguments: [id])
        }
    }

    /// Set the title for a conversation. The shim's auto-title logic
    /// (`Conversation.autoTitle(from:)`) calls this when the first user message
    /// is sent into a fresh "Новый диалог". `nil` clears the title.
    func renameConversation(id: String, title: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE conversations SET title=? WHERE id=?", arguments: [title, id])
        }
    }

    /// Flip the pin flag. Used by the drawer's leading-edge swipe + context menu.
    func togglePinned(id: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE conversations SET is_pinned = CASE is_pinned WHEN 1 THEN 0 ELSE 1 END
                WHERE id=?
            """, arguments: [id])
        }
    }

    /// Bump `last_message_at` so the conversation floats to the top of the
    /// drawer. Called by the shim whenever a new message arrives on either
    /// direction. Cheap update — the trigger volume is one per send/receive.
    func touchLastMessageAt(id: String, ts: Int) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE conversations SET last_message_at=?
                WHERE id=? AND last_message_at < ?
            """, arguments: [ts, id, ts])
        }
    }

    // MARK: - Active conversation persistence (kv table)
    //
    // The active conversation pointer used to live in the legacy
    // `ConversationStore` as an `@Observable` `UUID?` property — lost on every
    // app launch. Persisting it lets the user resume the last chat they had
    // open, even after a cold start, without re-implementing scene restoration.

    private static let kActiveConversation = "active_conversation_id"

    func getKV(_ key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT v FROM kv WHERE k=?", arguments: [key])
        }
    }

    func setKV(_ key: String, _ value: String?) throws {
        try writer.write { db in
            if let value {
                try db.execute(sql: """
                    INSERT INTO kv (k, v) VALUES (?, ?)
                    ON CONFLICT(k) DO UPDATE SET v=excluded.v
                """, arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM kv WHERE k=?", arguments: [key])
            }
        }
    }

    func setActiveConversationId(_ id: String?) throws {
        try setKV(Self.kActiveConversation, id)
    }

    func activeConversationId() throws -> String? {
        try getKV(Self.kActiveConversation)
    }

    /// GRDB observation source for live drawer updates. The shim subscribes to
    /// this so any path that mutates conversations (send / receive / archive /
    /// rename / pin) reflects in the drawer without manual notifications.
    func observeConversations() -> ValueObservation<ValueReducers.Fetch<[ConversationSummary]>> {
        ValueObservation.tracking { db -> [ConversationSummary] in
            try Row.fetchAll(db, sql: Self.conversationSummarySQL).map(Self.mapSummary)
        }
    }

    /// Observation source for the persisted active-conversation pointer.
    /// Lets the shim react to active-id changes from any actor (e.g. proactive
    /// push deep-link) without a callback chain.
    func observeActiveConversationId() -> ValueObservation<ValueReducers.Fetch<String?>> {
        ValueObservation.tracking { db -> String? in
            try String.fetchOne(db, sql: "SELECT v FROM kv WHERE k=?",
                                arguments: [Self.kActiveConversation])
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
