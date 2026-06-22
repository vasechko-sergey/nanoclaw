import Foundation

/// Persistence shape for an inbound action button, stored in `messages.actions_json`.
/// Distinct from the wire `V2.Action` (kept minimal). Synthesized Codable.
struct StoredAction: Codable, Equatable {
    let id: String
    let label: String
    let style: String?   // "primary" | "danger" | "secondary"

    static func from(_ a: V2.Action) -> StoredAction {
        StoredAction(id: a.id, label: a.label, style: a.style)
    }
}
