import SwiftUI

/// Horizontal chip row at the top of `ChatView`. Lets the user switch the
/// active agent (Jarvis / Payne / Greg). Reads the active selection from
/// the injected `ActiveAgentState`; takes unread counts as a parameter so
/// the parent can recompute lazily from `ConversationStoreV2.countMessages`.
struct AgentSwitcherStrip: View {
    @Environment(ActiveAgentState.self) private var active
    let unreadCounts: [AgentIdentity: Int]

    var body: some View {
        @Bindable var active = active

        HStack(spacing: 8) {
            ForEach(AgentIdentity.allCases) { agent in
                chip(for: agent)
            }
        }
        .padding(.horizontal)
    }

    private func chip(for agent: AgentIdentity) -> some View {
        let isActive = active.active == agent
        let unread = unreadCounts[agent] ?? 0

        return Button {
            active.active = agent
        } label: {
            HStack(spacing: 6) {
                Text(agent.displayName)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                if unread > 0 {
                    Text("\(unread)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isActive ? agent.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().stroke(
                    agent.accentColor.opacity(isActive ? 0.6 : 0.2),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.displayName)\(unread > 0 ? ", непрочитанных \(unread)" : "")")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#Preview {
    let state = ActiveAgentState(initial: .jarvis)
    return AgentSwitcherStrip(unreadCounts: [.payne: 3, .greg: 1])
        .environment(state)
        .padding()
}
