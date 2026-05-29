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

        if let activeId = activeConversationId,
           let lastAt = lastAssistantTimestamp,
           now.timeIntervalSince(lastAt) < freshnessWindow,
           let active = allConversations.first(where: { $0.id == activeId }) {
            result.append(Satellite(id: active.id, title: active.title, kind: .active))
        }

        return Array(result.prefix(maxSatellites))
    }
}
