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
    /// and falls back to `.jarvis`. UI tests (`--uitesting`) always start on
    /// `.jarvis` so test runs don't inherit a chip choice persisted by manual
    /// testing — outbound messages are always tagged `jarvis` today (T11/T12
    /// pending), so a non-jarvis chip would filter them out of `ChatView`.
    init(initial: AgentIdentity? = nil) {
        if let initial {
            self.active = initial
        } else if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            self.active = .jarvis
        } else {
            let raw = UserDefaults.standard.string(forKey: Self.storageKey)
            self.active = raw.flatMap(AgentIdentity.init(rawValue:)) ?? .jarvis
        }
    }
}
