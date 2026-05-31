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

        // Per-conversation MessageCache dirs under Documents/Conversations/<UUID>/
        let convRoot = documentsURL.appendingPathComponent("Conversations", isDirectory: true)
        if fm.fileExists(atPath: convRoot.path) {
            try importConversationsRoot(convRoot, store: store)
            try? fm.removeItem(at: convRoot)
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
