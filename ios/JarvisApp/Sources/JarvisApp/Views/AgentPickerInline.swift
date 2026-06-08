import SwiftUI

/// Inline-expand agent picker. Active agent rendered at top in the app's title
/// style (letter-spaced uppercase, accentColor). Tap expands the other agents
/// below in the same style; tap on any of them selects + collapses. Tap
/// outside collapses without change. No system chrome — all custom to match
/// the dark/teal app palette.
struct AgentPickerInline: View {
    @Environment(ActiveAgentState.self) private var active
    let unreadCounts: [AgentIdentity: Int]
    /// Optional long-press action — e.g. ChatView passes onGoHome here.
    var onLongPress: (() -> Void)? = nil

    @State private var isExpanded = false

    var body: some View {
        @Bindable var active = active

        VStack(spacing: 4) {
            // Active (always shown at top).
            row(for: active.active, isActive: true) {
                if isExpanded {
                    withAnimation(.easeInOut(duration: 0.25)) { isExpanded = false }
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { isExpanded = true }
                }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress?() }
            )

            if isExpanded {
                ForEach(otherAgents) { agent in
                    row(for: agent, isActive: false) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            active.active = agent
                            isExpanded = false
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(for agent: AgentIdentity, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    Spacer()
                    Text(spaced(agent.displayName))
                        .font(.system(size: Theme.fontTitle, weight: .light))
                        .tracking(Theme.titleTracking)
                        .foregroundStyle(isActive
                                         ? agent.accentColor
                                         : agent.accentColor.opacity(0.55))
                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    if !isActive, let unread = unreadCounts[agent], unread > 0 {
                        Text("\(unread)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(agent.accentColor)
                            .padding(.trailing, 12)
                    }
                }
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(isActive
                          ? agent.accentColor.opacity(0.6)
                          : agent.accentColor.opacity(0.35))
                    .frame(width: Theme.minTapSize, height: 1)
            }
            .frame(minHeight: Theme.minTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "Активный агент: \(agent.displayName), нажмите чтобы открыть выбор"
                                     : "Переключиться на \(agent.displayName)")
    }

    private var otherAgents: [AgentIdentity] {
        AgentIdentity.allCases.filter { $0 != active.active }
    }

    /// Insert U+2009 (thin space) between every character to match the
    /// existing "J A R V I S" letter-spaced look without relying solely on
    /// kerning (which can render unevenly with cyrillic + Latin mix).
    private func spaced(_ s: String) -> String {
        s.uppercased().map { String($0) }.joined(separator: "\u{2009}\u{2009}")
    }
}

#Preview {
    let state = ActiveAgentState(initial: .greg)
    return ZStack(alignment: .top) {
        Theme.background.ignoresSafeArea()
        VStack {
            AgentPickerInline(unreadCounts: [.jarvis: 2, .payne: 1])
                .environment(state)
            Spacer()
        }
        .padding(.top, 50)
    }
}
