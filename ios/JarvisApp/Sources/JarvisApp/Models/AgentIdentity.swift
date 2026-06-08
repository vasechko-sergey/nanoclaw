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
    /// uppercase fits one line (`J A R V I S`, `M A J   P A Y N E`,
    /// `D R   H O U S E`). Greetings + agent personas still respond in
    /// Russian — this is only the navbar identity.
    var displayName: String {
        switch self {
        case .jarvis: return "Jarvis"
        case .payne:  return "Maj Payne"
        case .greg:   return "Dr House"
        }
    }

    /// Picker accent — desaturated, sits in the same value/saturation range
    /// as the app's teal accent (#54BCC5) so the three agents read as
    /// variants of one calm palette instead of generic system colors.
    /// - Jarvis: the existing app teal.
    /// - Payne: muted military copper.
    /// - Greg/House: sage green, low-key.
    var accentColor: Color {
        switch self {
        case .jarvis: return Color(red: 0.33, green: 0.74, blue: 0.77)  // teal #54BCC5
        case .payne:  return Color(red: 0.78, green: 0.55, blue: 0.30)  // copper #C68C4D
        case .greg:   return Color(red: 0.45, green: 0.70, blue: 0.62)  // sage #73B39E
        }
    }
}
