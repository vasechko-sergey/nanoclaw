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

// NOTE: `init?(summary: ConversationSummary)` was removed alongside the
// `ConversationSummary` type when v3-single-chat dropped grouped conversations.
// The whole `Conversation` model is scheduled for deletion in the next task of
// the single-chat plan; this struct stays only long enough to keep the
// remaining drawer-related view files compiling during the transition.
