import Foundation

/// Maps ⌘1…⌘9 (agents by `AgentIdentity.allCases` order).
enum AgentShortcuts {
    static func agent(forNumber n: Int) -> AgentIdentity? {
        let all = AgentIdentity.allCases
        guard n >= 1, n <= all.count else { return nil }
        return all[n - 1]
    }
}
