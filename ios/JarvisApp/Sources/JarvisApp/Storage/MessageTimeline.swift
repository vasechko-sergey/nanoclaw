import Foundation
import GRDB

/// `@Observable` UI-facing wrapper around `ConversationStoreV2`. Single source
/// of truth for the chat timeline. Replaces the legacy `ConversationStore`
/// drawer shim now that there is no concept of multiple conversations.
@MainActor
@Observable
final class MessageTimeline {
    private(set) var messages: [StoredMessage] = []

    private let store: ConversationStoreV2
    private let dbq: DatabaseQueue
    private let retention: Int
    private var observationCancellable: AnyDatabaseCancellable?

    init(store: ConversationStoreV2, dbq: DatabaseQueue, retention: Int = 500) {
        self.store = store
        self.dbq = dbq
        self.retention = retention
    }

    /// Begin observing the GRDB-backed message timeline. Idempotent.
    ///
    /// T10: feeds rows from ALL agents into the in-memory stream; per-agent
    /// filtering happens in the view layer (`ChatView.visibleMessages`).
    func start() async throws {
        guard observationCancellable == nil else { return }
        let observation = store.observeAllMessages(perAgent: retention)
        // Seed synchronously so views render on first frame.
        self.messages = try await dbq.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM messages
                ORDER BY ts DESC, rowid DESC
                LIMIT ?
            """, arguments: [self.retention]).reversed().map { row in
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
                    edited: row["edited"] ?? false,
                    voiceOnly: row["voice_only"] ?? false
                )
            }
        }
        observationCancellable = observation.start(
            in: dbq,
            scheduling: .async(onQueue: .main),
            onError: { Log.warn(.cache, "MessageTimeline observation error: \($0)") },
            onChange: { [weak self] rows in
                self?.messages = rows
            }
        )
    }

    @discardableResult
    func insertOutbound(text: String,
                        attachments: [V2.Attachment],
                        context: V2.InlineContext?) throws -> StoredMessage {
        let id = UUID().uuidString
        try store.insertOutboundUserMessage(
            id: id, text: text, attachments: attachments, context: context
        )
        try store.prune(keep: retention)
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return StoredMessage(
            id: id, dir: .out, seq: nil, text: text,
            attachmentsJSON: nil, contextJSON: nil,
            status: .queued, failureReason: nil,
            ts: now,
            serverTS: nil,
            createdAt: now
        )
    }

    func insertInboundIfNew(envelope: V2.Envelope, message: V2.Message) throws {
        if try store.dedupSeen(id: envelope.id) { return }
        try store.recordDedup(id: envelope.id, seq: envelope.seq ?? 0)
        try store.insertInbound(envelope: envelope, message: message, agentId: message.agent_id ?? "jarvis")
        try store.prune(keep: retention)
    }
}
