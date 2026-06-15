import SwiftUI

/// App root: owns the splash / connection gate, then branches by layout mode.
///
/// - `.stacked` → existing `ContentView` (phone-style splash→home→chat).
/// - `.split`   → `SplitRootView` placeholder (real panes in Task 7).
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
                        SplitRootView(coordinator: coordinator)
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

// MARK: – Split placeholder (Task 7 will replace this with real panes)

private struct SplitRootView: View {
    var coordinator: AppCoordinator
    var body: some View {
        ContentView(coordinator: coordinator)
    }
}
