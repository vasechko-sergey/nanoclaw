import SwiftUI

/// Inline-expand agent picker. Active agent rendered at top in the app's title
/// style (letter-spaced uppercase, accentColor). Tap expands the other agents
/// below in the same style; tap on any of them selects + collapses. Tap
/// outside collapses without change. No system chrome — all custom to match
/// the dark/teal app palette.
struct AgentPickerInline: View {
    @Environment(ActiveAgentState.self) private var active
    /// Optional long-press action — e.g. ChatView passes onGoHome here.
    var onLongPress: (() -> Void)? = nil
    /// Optional external control of the expanded state so a parent can collapse
    /// the picker on an outside tap. Defaults to internal state — existing call
    /// sites that don't pass it keep working unchanged.
    var externalExpanded: Binding<Bool>? = nil

    @State private var internalExpanded = false
    private var expanded: Binding<Bool> { externalExpanded ?? $internalExpanded }

    var body: some View {
        @Bindable var active = active

        // Stable layout: when expanded, render every agent in the fixed
        // AgentIdentity.allCases order so tap positions don't shift when the
        // user switches chips. The active row also occupies its own canonical
        // slot rather than being lifted to the top. Collapsed: only the
        // active row is visible.
        VStack(spacing: 4) {
            ForEach(AgentIdentity.allCases) { agent in
                let isActive = agent == active.active
                if isActive || expanded.wrappedValue {
                    row(for: agent, isActive: isActive) {
                        if isActive {
                            withAnimation(.easeInOut(duration: 0.25)) { expanded.wrappedValue.toggle() }
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                active.active = agent
                                expanded.wrappedValue = false
                            }
                        }
                    }
                    // highPriority (not simultaneous): a long press on the
                    // active row must NOT also fire the Button's tap (which
                    // would toggle the picker open right as we navigate home).
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            if isActive { onLongPress?() }
                        }
                    )
                    .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(for agent: AgentIdentity, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer()
                Text(spaced(agent.displayName))
                    .font(.system(size: Theme.fontTitle, weight: .light))
                    .tracking(Theme.titleTracking)
                    .foregroundStyle(isActive
                                     ? agent.accentColor
                                     : agent.accentColor.opacity(0.55))
                    .fixedSize()
                    .overlay(alignment: .bottom) {
                        // Underline spans full text width; ~3pt below baseline.
                        Rectangle()
                            .fill(isActive
                                  ? agent.accentColor.opacity(0.6)
                                  : agent.accentColor.opacity(0.35))
                            .frame(height: 1)
                            .offset(y: 4)
                    }
                Spacer()
            }
            .frame(minHeight: Theme.minTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "Активный агент: \(agent.displayName), нажмите чтобы открыть выбор"
                                     : "Переключиться на \(agent.displayName)")
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
            AgentPickerInline()
                .environment(state)
            Spacer()
        }
        .padding(.top, 50)
    }
}
