import SwiftUI

/// Identity of one of the agent_groups multiplexed over a single iOS-app
/// WebSocket. The `rawValue` must match the agent_group's `folder` slug on
/// the host (the same value carried in the `agent_id` field of v2 envelopes
/// and stamped into the `messages.agent_id` storage column).
enum AgentIdentity: String, CaseIterable, Identifiable, Codable {
    case jarvis
    case payne
    case greg

    var id: String { rawValue }

    /// Compact English title used in the navbar picker so letter-spaced
    /// uppercase fits one line (`J A R V I S`, `M A J .   P A Y N E`,
    /// `D R .   H O U S E`). Greetings + agent personas still respond in
    /// Russian — this is only the navbar identity.
    var displayName: String {
        switch self {
        case .jarvis: return "Jarvis"
        case .payne:  return "Maj. Payne"
        case .greg:   return "Dr. House"
        }
    }

    /// Chip / banner accent. Matches the spec's "smoothed Major Payne" palette
    /// hint (orange = drill instructor) and the existing Jarvis teal hue.
    var accentColor: Color {
        switch self {
        case .jarvis: return .blue
        case .payne:  return .orange
        case .greg:   return .green
        }
    }
}
