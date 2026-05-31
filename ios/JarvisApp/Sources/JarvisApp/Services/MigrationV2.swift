import Foundation

/// One-shot migration: imports the legacy v1 Outbox + MessageCache JSON stores
/// (and the per-conversation MessageCache directories under `Documents/Conversations/`)
/// into the GRDB-backed `ConversationStoreV2`. On success, the legacy directories
/// are removed so the migration runs at most once.
///
/// Field shapes mirror the actual legacy Codable structs in
/// `OutboxStore.swift` and `MessageCache.swift` — not the prose spec.
enum MigrationV2 {

    // MARK: - Legacy shapes

    /// Mirrors `OutboxEntry` in `Services/OutboxStore.swift`.
    /// Decoded with `.iso8601` date strategy.
    private struct LegacyOutboxEntry: Codable {
        let id: String
        let conversationId: UUID?
        let createdAt: Date
        let textPreview: String
        let deliveryStatus: String?
    }

    /// Mirrors `CachedMessage` in `Services/MessageCache.swift`.
    /// Decoded with `.iso8601` date strategy.
    private struct LegacyCachedMessage: Codable {
        let id: String
        let role: String          // "user" | "assistant" | "system"
        let kind: String          // "text" | "image" | "file" | "action" | "status"
        let text: String?
        let timestamp: Date
        let deliveryStatus: String?
    }

    /// Used by tests / future flat-format imports — accepts an explicit
    /// `conversationId` + `dir|role` shape (the format described in the
    /// protocol-v2 plan). Optional — `index.json` decoders try this first
    /// before falling back to the real `LegacyCachedMessage` shape.
    private struct FlatCachedEntry: Codable {
        let id: String
        let conversationId: String
        let text: String
        let dir: String?
        let role: String?
        let ts: Int
    }

    private struct FlatOutboxEntry: Codable {
        let id: String
        let conversationId: String
        let text: String
        let status: String?
        let ts: Int
        let serverTS: Int?
    }

    // MARK: - Entry point

    /// Fallback thread id assigned to legacy cache entries that have no
    /// `conversationId` of their own (the v1 MessageCache was per-folder,
    /// not per-message). Stable so re-runs would idempotently target it.
    static let legacyFallbackConversationId = "legacy-v1"

    static func runIfNeeded(
        documentsURL: URL,
        store: ConversationStoreV2,
        fallbackConversationId: String = legacyFallbackConversationId
    ) throws {
        let fm = FileManager.default

        // Top-level Outbox/queue.json
        let outboxDir = documentsURL.appendingPathComponent("Outbox", isDirectory: true)
        let outboxFile = outboxDir.appendingPathComponent("queue.json")
        if fm.fileExists(atPath: outboxFile.path) {
            try importOutbox(url: outboxFile, store: store, fallback: fallbackConversationId)
            try? fm.removeItem(at: outboxDir)
        }

        // Top-level MessageCache/index.json (v1 single-thread cache)
        let cacheDir = documentsURL.appendingPathComponent("MessageCache", isDirectory: true)
        let cacheFile = cacheDir.appendingPathComponent("index.json")
        if fm.fileExists(atPath: cacheFile.path) {
            try importCache(url: cacheFile, store: store, conversationId: fallbackConversationId)
            try? fm.removeItem(at: cacheDir)
        }

        // Per-conversation MessageCache dirs under Documents/Conversations/<UUID>/.
        // We deliberately do NOT delete the `Conversations/` root afterwards —
        // it also contains `conversations.json`, the v1 `ConversationStore`'s
        // index file. The legacy store still drives the drawer (this is the
        // v1→v2 transition period), so blowing the file away would orphan the
        // user from their own chat list. We do delete the per-conversation
        // message subdirs since their data has been imported into GRDB.
        let convRoot = documentsURL.appendingPathComponent("Conversations", isDirectory: true)
        if fm.fileExists(atPath: convRoot.path) {
            try importConversationsRoot(convRoot, store: store)
            try? cleanUpImportedConversationDirs(convRoot)
        }

        // Lift the v1 conversation metadata (`conversations.json`) into the
        // v2 `conversations` table so the GRDB observation joining on a
        // conversation row finds it even for v1 chats that have never been
        // sent through the v2 transport. Preserves UUIDs so the v1 drawer
        // can hand the same id to `.open(conv)` and the observation matches.
        let convIndex = convRoot.appendingPathComponent("conversations.json")
        if fm.fileExists(atPath: convIndex.path) {
            try? liftConversationsIndex(convIndex, store: store)
        }
    }

    // MARK: - Importers

    private static func importOutbox(
        url: URL,
        store: ConversationStoreV2,
        fallback: String
    ) throws {
        let data = try Data(contentsOf: url)

        // Prefer the flat shape (matches the v2 plan); fall back to the real
        // legacy OutboxEntry shape with ISO8601 dates and UUID conversationId.
        if let flats = try? JSONDecoder().decode([FlatOutboxEntry].self, from: data) {
            for e in flats {
                try store.insertOutboundHistoryRow(
                    conversationId: e.conversationId,
                    id: e.id,
                    text: e.text,
                    ts: e.ts,
                    serverTS: e.serverTS
                )
            }
            return
        }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entries = try dec.decode([LegacyOutboxEntry].self, from: data)
        for e in entries {
            let convId = e.conversationId?.uuidString ?? fallback
            let ts = millis(from: e.createdAt)
            try store.insertOutboundHistoryRow(
                conversationId: convId,
                id: e.id,
                text: e.textPreview,
                ts: ts,
                serverTS: nil
            )
        }
    }

    private static func importCache(
        url: URL,
        store: ConversationStoreV2,
        conversationId: String
    ) throws {
        let data = try Data(contentsOf: url)

        // Flat shape first (matches the v2 plan / test fixtures):
        if let flats = try? JSONDecoder().decode([FlatCachedEntry].self, from: data) {
            for e in flats {
                guard let normalized = normalize(dir: e.dir, role: e.role) else { continue }
                switch normalized {
                case .inbound:
                    try store.insertInboundHistoryRow(
                        conversationId: e.conversationId,
                        id: e.id,
                        text: e.text,
                        ts: e.ts
                    )
                case .outbound:
                    try store.insertOutboundHistoryRow(
                        conversationId: e.conversationId,
                        id: e.id,
                        text: e.text,
                        ts: e.ts,
                        serverTS: e.ts
                    )
                }
            }
            return
        }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entries = try dec.decode([LegacyCachedMessage].self, from: data)
        try importCachedMessages(entries, conversationId: conversationId, store: store)
    }

    private static func importConversationsRoot(_ root: URL, store: ConversationStoreV2) throws {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let convId = child.lastPathComponent  // UUID string
            let indexFile = child.appendingPathComponent("index.json")
            guard fm.fileExists(atPath: indexFile.path),
                  let data = try? Data(contentsOf: indexFile),
                  let entries = try? dec.decode([LegacyCachedMessage].self, from: data) else {
                continue
            }
            try importCachedMessages(entries, conversationId: convId, store: store)
        }
    }

    /// Decoder shape matching the v1 `Conversation` struct just enough to
    /// extract the fields we need (id, title, createdAt). We don't import
    /// preview / messageCount / isPinned — preview will re-derive from any
    /// imported messages, count is recomputed on demand, and pin state stays
    /// owned by the legacy v1 store for now.
    private struct LegacyConversationIndexEntry: Codable {
        let id: UUID
        let title: String?
        let createdAt: Date
        let lastMessageAt: Date?
        let isPinned: Bool?
    }

    private static func liftConversationsIndex(_ url: URL, store: ConversationStoreV2) throws {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // The v1 JSON stores title/createdAt/lastMessageAt/isPinned etc.
        // We lift everything the new schema can hold (`messageCount` and
        // `preview` are derived from the `messages` table at query time so
        // there's nothing to copy for those).
        let entries = (try? dec.decode([LegacyConversationIndexEntry].self, from: data)) ?? []
        for e in entries {
            let title: String?
            if let t = e.title, !t.isEmpty { title = t } else { title = nil }
            try store.createConversation(
                id: e.id.uuidString,
                title: title,
                createdAt: e.createdAt,
                lastMessageAt: e.lastMessageAt,
                isPinned: e.isPinned ?? false
            )
        }
    }

    /// Remove only the per-conversation message subdirs (UUID-named), not
    /// the top-level `conversations.json` index file. Called after
    /// `importConversationsRoot` has lifted the index files into GRDB.
    private static func cleanUpImportedConversationDirs(_ root: URL) throws {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Only delete directories named like a UUID — never touch other files
            // (notably `conversations.json` which lives at the root).
            if UUID(uuidString: child.lastPathComponent) != nil {
                try? fm.removeItem(at: child)
            }
        }
    }

    private static func importCachedMessages(
        _ entries: [LegacyCachedMessage],
        conversationId: String,
        store: ConversationStoreV2
    ) throws {
        for e in entries {
            guard e.kind == "text", let text = e.text else { continue }  // skip image/file/action/status for now
            guard let normalized = normalize(dir: nil, role: e.role) else { continue }
            let ts = millis(from: e.timestamp)
            switch normalized {
            case .inbound:
                try store.insertInboundHistoryRow(
                    conversationId: conversationId,
                    id: e.id,
                    text: text,
                    ts: ts
                )
            case .outbound:
                try store.insertOutboundHistoryRow(
                    conversationId: conversationId,
                    id: e.id,
                    text: text,
                    ts: ts,
                    serverTS: ts
                )
            }
        }
    }

    // MARK: - Helpers

    private enum NormalizedDir { case inbound, outbound }

    /// Maps the legacy `dir`/`role` strings onto v2's `dir` column.
    /// - "in"        → inbound (assistant → user)
    /// - "assistant" → inbound
    /// - "out"       → outbound (user → assistant)
    /// - "user"      → outbound
    /// - anything else (incl. "system") → nil, caller skips.
    private static func normalize(dir: String?, role: String?) -> NormalizedDir? {
        if let d = dir {
            switch d {
            case "in", "assistant": return .inbound
            case "out", "user":     return .outbound
            default: break
            }
        }
        if let r = role {
            switch r {
            case "assistant": return .inbound
            case "user":      return .outbound
            default: return nil
            }
        }
        return nil
    }

    private static func millis(from date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }
}
