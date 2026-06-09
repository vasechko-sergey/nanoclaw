import Foundation
import Observation

/// Per-agent "last seen at" persisted in UserDefaults. Drives the unread
/// badge counter on `AgentPickerInline`. Missing entries default to
/// `.distantPast` so the first render shows everything as unread until the
/// active chip is opened (`ChatView.onAppear` marks it seen immediately).
@Observable
@MainActor
final class LastSeenStore {
    private let defaults: UserDefaults
    private static func key(for agent: AgentIdentity) -> String { "LastSeen.\(agent.rawValue)" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastSeen(for agent: AgentIdentity) -> Date {
        defaults.object(forKey: Self.key(for: agent)) as? Date ?? .distantPast
    }

    func markSeen(_ agent: AgentIdentity, at when: Date = Date()) {
        defaults.set(when, forKey: Self.key(for: agent))
    }
}
