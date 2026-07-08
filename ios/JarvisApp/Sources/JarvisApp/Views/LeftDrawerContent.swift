import SwiftUI

/// Left slide-out drawer hosting the agent switcher (moved out of the chat
/// header). Mirrors `RightDrawerContent`'s container styling — single
/// `ScrollView`, dark panel background, section header — but lists every
/// `AgentIdentity` as a full-width tappable row in the app's title style
/// (letter-spaced uppercase, accentColor). Tapping a row sets the active agent
/// and closes the drawer via `onSelect`.
struct LeftDrawerContent: View {
    @Environment(ActiveAgentState.self) private var active
    /// Called with the chosen agent. The parent sets the active agent and
    /// closes the drawer (see `ChatView`).
    var onSelect: (AgentIdentity) -> Void
    /// Per-agent unread inbound counts, keyed by `agent_id` (F30). A non-zero
    /// entry renders an unread dot on that agent's row. Defaults to empty so
    /// previews and non-reactive callers can omit it.
    var unreadCounts: [String: Int] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header

                sectionHeader("Агенты")
                VStack(spacing: Theme.scaled(4)) {
                    ForEach(AgentIdentity.allCases) { agent in
                        row(for: agent, isActive: agent == active.active)
                    }
                }
                .padding(.bottom, Theme.scaled(20))
            }
        }
        .background(Color(red: 0.04, green: 0.08, blue: 0.11))
        .accessibilityIdentifier("left-drawer")
    }

    private var header: some View {
        HStack {
            Text("Агенты")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.metaFont)
            .tracking(1)
            .foregroundStyle(Theme.accentMedium)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, Theme.scaled(14))
            .padding(.bottom, Theme.scaled(6))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for agent: AgentIdentity, isActive: Bool) -> some View {
        let unread = unreadCounts[agent.rawValue] ?? 0
        Button {
            onSelect(agent)
        } label: {
            HStack(spacing: 8) {
                // Plain uppercase name — no per-letter thin-spaces. The chat
                // header keeps the wide "J A R V I S" spacing (`spaced()` +
                // titleTracking) because it's a single centered title; in a
                // left-aligned list those gaps read as broken, so the rows use
                // a tight uppercase + light tracking instead.
                Text(agent.displayName.uppercased())
                    .font(.system(size: Theme.fontTitle, weight: .light))
                    .tracking(1)
                    .foregroundStyle(isActive
                                     ? agent.accentColor
                                     : agent.accentColor.opacity(0.55))
                Spacer()
                if unread > 0 { unreadDot(agent) }
            }
            .padding(.horizontal, Theme.hPadding)
            .frame(minHeight: Theme.minTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(agent, isActive: isActive, unread: unread))
    }

    /// Small filled unread dot in the agent's accent, with a soft glow so it
    /// reads on the dark panel (F30).
    private func unreadDot(_ agent: AgentIdentity) -> some View {
        Circle()
            .fill(agent.accentColor)
            .frame(width: Theme.scaled(9), height: Theme.scaled(9))
            .shadow(color: agent.accentColor.opacity(0.6), radius: 3)
            .accessibilityHidden(true)
    }

    private func accessibilityLabel(_ agent: AgentIdentity, isActive: Bool, unread: Int) -> String {
        let base = isActive ? "Активный агент: \(agent.displayName)"
                            : "Переключиться на \(agent.displayName)"
        return unread > 0 ? "\(base), \(unread) непрочитанных" : base
    }
}

#Preview {
    let state = ActiveAgentState(initial: .greg)
    return ZStack(alignment: .leading) {
        Theme.background.ignoresSafeArea()
        LeftDrawerContent(onSelect: { _ in })
            .frame(width: Theme.drawerWidth)
            .environment(state)
    }
}
