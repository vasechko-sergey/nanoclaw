import Foundation
import Observation

/// Single source of truth for which agent chip is active in `ChatView`.
/// Persisted via UserDefaults so the user returns to the same thread on
/// relaunch.
@Observable
@MainActor
final class ActiveAgentState {
    private static let storageKey = "ActiveAgentState.active"

    /// Updates trigger SwiftUI re-renders and persist to UserDefaults.
    var active: AgentIdentity {
        didSet {
            UserDefaults.standard.set(active.rawValue, forKey: Self.storageKey)
        }
    }

    /// Optional initial override (e.g. tests). Otherwise reads UserDefaults
    /// and falls back to `.jarvis`.
    init(initial: AgentIdentity? = nil) {
        if let initial {
            self.active = initial
        } else {
            let raw = UserDefaults.standard.string(forKey: Self.storageKey)
            self.active = raw.flatMap(AgentIdentity.init(rawValue:)) ?? .jarvis
        }
    }
}
