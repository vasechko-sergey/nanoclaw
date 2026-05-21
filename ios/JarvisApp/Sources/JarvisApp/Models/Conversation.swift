import Foundation

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var lastMessageAt: Date
    var messageCount: Int
    var preview: String
    var isPinned: Bool

    init(id: UUID = UUID(), title: String = "Новый диалог", createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastMessageAt = createdAt
        self.messageCount = 0
        self.preview = ""
        self.isPinned = false
    }

    // Backwards-compatible decoding (old JSON may lack isPinned)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastMessageAt = try c.decode(Date.self, forKey: .lastMessageAt)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        preview = try c.decode(String.self, forKey: .preview)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
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
