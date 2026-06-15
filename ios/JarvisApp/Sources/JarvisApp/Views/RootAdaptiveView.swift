import SwiftUI

/// App root: owns the splash / connection gate, then branches by layout mode.
///
/// - `.stacked` → existing `ContentView` (phone-style splash→home→chat).
/// - `.split`   → `SplitRootView`: OrbHubPane (38%) | hairline | ChatView(embedded: true).
///
/// `GeometryReader` feeds the real available width into `Theme.refreshScale`
/// and `Theme.refreshDrawerWidth`, replacing the UIScreen-based call that
/// previously ran on scene-phase changes.
struct RootAdaptiveView: View {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(AppSettings.self) private var settings
    var coordinator: AppCoordinator

    @State private var ready = false
    @State private var showSetup = false

    var body: some View {
        GeometryReader { geo in
            let mode = LayoutMode.resolve(
                width: geo.size.width,
                height: geo.size.height,
                horizontalSizeClass: hSizeClass
            )
            Group {
                if !ready {
                    SplashView(
                        coordinator: coordinator,
                        settings: settings,
                        showSetup: $showSetup,
                        onReady: {
                            withAnimation(.easeOut(duration: 0.6)) { ready = true }
                        }
                    )
                } else {
                    switch mode {
                    case .stacked:
                        ContentView(coordinator: coordinator)
                    case .split:
                        SplitRootView(coordinator: coordinator, width: geo.size.width)
                    }
                }
            }
            .onAppear {
                applyWidth(geo.size.width)
                if settings.isConfigured {
                    coordinator.connect()
                } else {
                    showSetup = true
                }
            }
            .onChange(of: geo.size.width) { _, w in
                applyWidth(w)
            }
        }
    }

    private func applyWidth(_ w: CGFloat) {
        Theme.refreshScale(width: w)
        Theme.refreshDrawerWidth(width: w)
    }
}

// MARK: – Split layout: OrbHubPane | divider | ChatView(embedded:true)

private struct SplitRootView: View {
    var coordinator: AppCoordinator
    var width: CGFloat

    @Environment(ActiveAgentState.self) private var active
    @State private var showProfile = false

    /// Hub pane width: 38% of available width, clamped to [360, 460] pt.
    private var paneWidth: CGFloat { min(max(width * 0.38, 360), 460) }

    var body: some View {
        HStack(spacing: 0) {
            // Left pane: persistent agent navigator (orb hub).
            // onOpenProfile routes to a sheet rather than the fullscreen
            // right-edge drawer that ChatView uses in stacked mode.
            OrbHubPane(coordinator: coordinator, onOpenProfile: { showProfile = true })
                .frame(width: paneWidth)

            // Hairline column divider using the accent colour at low opacity.
            Rectangle()
                .fill(Theme.accent.opacity(0.08))
                .frame(width: 0.5)

            // Right canvas: chat in embedded mode — own right-drawer is
            // suppressed so it doesn't conflict with the hub pane.
            ChatView(coordinator: coordinator,
                     onGoHome: {},
                     autoStartVoice: .constant(false),
                     embedded: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat-canvas")
        }
        // Profile/settings sheet owned by this pane — the hub header dot
        // triggers it; ChatView's own drawer is disabled when embedded.
        .sheet(isPresented: $showProfile) {
            RightDrawerContent(
                isConnected: coordinator.ws.isConnected,
                onReconnect: {
                    coordinator.disconnect()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        coordinator.connect()
                    }
                }
            )
        }
        // MARK: – Hardware keyboard shortcuts (iPad)
        // Hidden zero-opacity buttons carrying .keyboardShortcut so that UIKit
        // responder chain picks them up regardless of which subview has focus.
        // .accessibilityHidden(true) keeps them out of VoiceOver.
        .background {
            Group {
                // ⌘1…⌘N — switch to agent N (by allCases order)
                ForEach(1...AgentIdentity.allCases.count, id: \.self) { n in
                    Button("") {
                        if let a = AgentShortcuts.agent(forNumber: n) {
                            active.active = a
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                // ⌘N — new conversation for the currently-active agent
                Button("") {
                    coordinator.ws.sendNewConversation(agentId: active.active.rawValue)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}
