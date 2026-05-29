import Foundation

/// Picks which conversations from `ConversationStore` should appear as
/// orbiting satellites on the home cluster. Pure — no SwiftUI dependency,
/// so the selection logic is unit-testable in isolation.
enum ConversationSatelliteBuilder {

    enum Kind: Equatable { case active, pinned }

    struct Satellite: Equatable {
        let id: UUID
        let title: String
        let kind: Kind
    }

    /// 24-hour freshness window for the active conversation's last assistant reply.
    private static let freshnessWindow: TimeInterval = 24 * 3600

    /// Maximum total conversation satellites surfaced at once.
    static let maxSatellites = 3

    static func build(
        activeConversationId: UUID?,
        lastAssistantTimestamp: Date?,
        allConversations: [Conversation],
        now: Date
    ) -> [Satellite] {
        var result: [Satellite] = []

        // 1. Active satellite — only when fresh assistant reply exists within 24h.
        var activeId: UUID? = nil
        if let aid = activeConversationId,
           let lastAt = lastAssistantTimestamp,
           now.timeIntervalSince(lastAt) < freshnessWindow,
           let active = allConversations.first(where: { $0.id == aid }) {
            result.append(Satellite(id: active.id, title: active.title, kind: .active))
            activeId = active.id
        }

        // 2. Up to 2 pinned satellites, sorted by lastMessageAt descending,
        //    excluding the active one (so it doesn't appear twice).
        let pinned = allConversations
            .filter { $0.isPinned && $0.id != activeId }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
            .prefix(2)

        for conv in pinned {
            result.append(Satellite(id: conv.id, title: conv.title, kind: .pinned))
        }

        return Array(result.prefix(maxSatellites))
    }
}
