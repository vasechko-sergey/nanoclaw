import SwiftUI

/// Top-of-screen agent picker. Renders the active agent's name as a tappable
/// label with a chevron; tap opens a SwiftUI Menu listing all agents.
///
/// Used in both ChatView (header strip) and OrbHomeView (under greeting).
struct AgentSwitcherStrip: View {
    @Environment(ActiveAgentState.self) private var active
    let unreadCounts: [AgentIdentity: Int]

    var body: some View {
        @Bindable var active = active

        Menu {
            ForEach(AgentIdentity.allCases) { agent in
                let unread = unreadCounts[agent] ?? 0
                Button {
                    active.active = agent
                } label: {
                    HStack {
                        Text(agent.displayName)
                        if active.active == agent {
                            Spacer()
                            Image(systemName: "checkmark")
                        } else if unread > 0 {
                            Spacer()
                            Text("\(unread)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(active.active.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let activeUnread = otherAgentsUnread(active: active.active), activeUnread > 0 {
                    Text("\(activeUnread)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(
                Capsule().fill(active.active.accentColor.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(active.active.accentColor.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .accessibilityLabel("Активный агент: \(active.active.displayName)")
        .accessibilityHint("Откройте меню чтобы переключить агента")
    }

    /// Sum of unread badges for non-active agents — shown next to the active
    /// chip so the user notices traffic in other threads without opening the menu.
    private func otherAgentsUnread(active: AgentIdentity) -> Int? {
        let total = unreadCounts.reduce(0) { acc, kv in
            kv.key == active ? acc : acc + kv.value
        }
        return total > 0 ? total : nil
    }
}

#Preview {
    let state = ActiveAgentState(initial: .jarvis)
    return AgentSwitcherStrip(unreadCounts: [.payne: 3, .greg: 1])
        .environment(state)
        .padding()
}
