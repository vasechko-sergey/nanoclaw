import Foundation

/// In-memory drawer row. Mirrors the legacy v1 shape (`UUID id` etc.) so the
/// six view sites that consume it didn't have to change when the GRDB-backed
/// `ConversationStore` shim replaced the file-based legacy store. Source of
/// truth lives in `ConversationStoreV2.observeConversations()`; the shim
/// converts each `ConversationSummary` row into one of these.
struct Conversation: Identifiable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var lastMessageAt: Date
    var messageCount: Int
    var preview: String
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String = "Новый диалог",
        createdAt: Date = Date(),
        lastMessageAt: Date? = nil,
        messageCount: Int = 0,
        preview: String = "",
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt ?? createdAt
        self.messageCount = messageCount
        self.preview = preview
        self.isPinned = isPinned
    }

    /// Generate a short title from the first user message.
    static func autoTitle(from text: String) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let words = cleaned.split(separator: " ").prefix(5).joined(separator: " ")
        if words.count > 40 {
            return String(words.prefix(40)) + "…"
        }
        return words.isEmpty ? "Новый диалог" : words
    }
}

extension Conversation {
    /// Convert a GRDB summary row into the view-facing model. Falls back to a
    /// fresh UUID if the row's id isn't a valid UUID string — should never
    /// happen post-migration (all ids are UUIDs) but keeps the call total.
    init?(summary: ConversationSummary) {
        guard let uuid = UUID(uuidString: summary.id) else { return nil }
        self.id = uuid
        self.title = summary.title ?? "Новый диалог"
        self.createdAt = Date(timeIntervalSince1970: TimeInterval(summary.createdAt) / 1000)
        self.lastMessageAt = Date(timeIntervalSince1970: TimeInterval(summary.lastMessageAt) / 1000)
        self.messageCount = summary.messageCount
        self.preview = summary.preview
        self.isPinned = summary.isPinned
    }
}
