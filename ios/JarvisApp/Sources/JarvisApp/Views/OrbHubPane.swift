import SwiftUI

/// Wide-layout left pane: the signature orb as a persistent agent navigator.
/// The centre orb is the active agent; the four other agents orbit it as
/// satellites. Tapping a satellite promotes that agent — the chat canvas
/// re-binds via `ActiveAgentState`.
struct OrbHubPane: View {
    @Environment(ActiveAgentState.self) private var active
    var coordinator: AppCoordinator
    var onOpenProfile: () -> Void

    @StateObject private var stateService = StateService()
    @State private var showStateBoard = false
    @State private var showSatellites = false

    // MARK: – Static helpers (pure, headless-testable)

    /// The non-active agents that orbit the hub.
    static func satelliteAgents(active: AgentIdentity) -> [AgentIdentity] {
        AgentIdentity.allCases.filter { $0 != active }
    }

    /// The hub orb's core colour — matches the active agent's accent.
    static func coreAccent(active: AgentIdentity) -> Color { active.accentColor }

    // MARK: – Body

    var body: some View {
        VStack(spacing: 0) {
            // Header row: connection dot (left) + profile entry (right)
            HStack {
                HeaderStatusDot(
                    side: .left,
                    isConnected: coordinator.ws.isConnected,
                    phase: .calm,
                    action: {} // status indicator only — no tap action in the pane
                )
                .accessibilityLabel("Статус подключения")
                Spacer()
                HeaderStatusDot(
                    side: .right,
                    isConnected: coordinator.ws.isConnected,
                    phase: .calm,
                    action: onOpenProfile
                )
                .accessibilityLabel("Открыть профиль и настройки")
            }
            .padding(.horizontal, Theme.scaled(8))
            .frame(minHeight: Theme.headerHeight)

            Spacer()

            OrbHub(
                satellites: Self.satelliteAgents(active: active.active).map { agent in
                    OrbSatellite(
                        id: agent.rawValue,
                        icon: nil,
                        label: agent.displayName,
                        accent: agent.accentColor,
                        isHighlighted: false,
                        action: {
                            Theme.hapticMedium()
                            withAnimation(.easeInOut(duration: 0.4)) {
                                active.active = agent
                            }
                        }
                    )
                },
                actionSatellites: [],
                mood: .welcoming,
                coreAccent: Self.coreAccent(active: active.active),
                showSatellites: $showSatellites,
                onOrbTap: {}
            )

            Spacer()

            // Health strip — wired to StateService; popover presents StateBoardView.
            HealthStripView(levels: stateService.state?.levels)
                .onTapGesture { showStateBoard = true }
                .accessibilityLabel("Здоровье")
                .accessibilityAddTraits(.isButton)
                .padding(.bottom, Theme.scaled(8))
        }
        .background(Theme.background)
        .accessibilityIdentifier("orb-hub-pane")
        .onAppear { stateService.refresh() }
        .popover(isPresented: $showStateBoard) {
            NavigationView { StateBoardView(service: stateService) }
        }
    }
}
