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
        Button {
            onSelect(agent)
        } label: {
            HStack(spacing: 8) {
                Text(spaced(agent.displayName))
                    .font(.system(size: Theme.fontTitle, weight: .light))
                    .tracking(Theme.titleTracking)
                    .foregroundStyle(isActive
                                     ? agent.accentColor
                                     : agent.accentColor.opacity(0.55))
                Spacer()
            }
            .padding(.horizontal, Theme.hPadding)
            .frame(minHeight: Theme.minTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "Активный агент: \(agent.displayName)"
                                     : "Переключиться на \(agent.displayName)")
    }

    /// Insert U+2009 (thin space) between every character to match the
    /// existing "J A R V I S" letter-spaced look (mirrors `AgentPickerInline`).
    private func spaced(_ s: String) -> String {
        s.uppercased().map { String($0) }.joined(separator: "\u{2009}\u{2009}")
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
