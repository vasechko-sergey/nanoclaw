import SwiftUI

/// The home screen — a large orb with contextual suggestion satellites arranged around it.
/// Long press the orb to reveal action satellites (mic, camera, photo, file).
struct OrbHomeView: View {
    @Environment(AppSettings.self) var settings
    @Environment(ActiveAgentState.self) private var active
    var coordinator: AppCoordinator

    var onStartChat: (String?) -> Void   // nil = open empty chat, String = send immediately
    var onStartVoiceChat: () -> Void    // open chat + auto-start voice recording
    var onContinueChat: () -> Void

    @StateObject private var stateService = StateService()
    @State private var showStateBoard = false

    @State private var showSatellites = false
    @State private var showVoiceFullscreen = false

    @State private var rightDrawerOpen = false
    @State private var rightDrawerDragOffset: CGFloat = 0
    @State private var leftDrawerOpen = false
    @State private var leftDrawerDragOffset: CGFloat = 0

    // Picker triggers
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showDoc = false
    @State private var drafts: [DraftAttachment] = []

    private var hasActiveChat: Bool {
        !coordinator.ws.messages.isEmpty
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let slot: TimeSlot
        switch hour {
        case 5..<12:  slot = .morning
        case 12..<17: slot = .day
        case 17..<22: slot = .evening
        default:      slot = .night
        }
        return GreetingBank.pick(agent: active.active, slot: slot)
    }

    private var greetingLabel: some View {
        Text(greeting)
            .font(.system(size: Theme.scaled(11), weight: .light))
            .tracking(2)
            .foregroundStyle(Theme.accentMedium.opacity(0.7))
            .opacity(showSatellites ? 0.3 : 1)
            .animation(.easeOut(duration: 0.2), value: showSatellites)
            .padding(.bottom, Theme.scaled(12))
            .accessibilityIdentifier("home-greeting")
    }

    private var contextualSuggestions: [AgentSuggestion] {
        active.active.suggestions
    }

    // Action satellites (voice, text, camera, photo, file) — shown on long press
    private var actionSatellites: [(icon: String, label: String, isChat: Bool, action: () -> Void)] {
        var items: [(String, String, Bool, () -> Void)] = [
            ("mic.fill", "Голос", false, {
                onStartVoiceChat()
            }),
            ("keyboard", "Текст", false, {
                onStartChat(nil)
            }),
        ]
        if cameraAvailable {
            items.append(("camera", "Камера", false, { showCamera = true }))
        }
        items.append(contentsOf: [
            ("photo", "Фото", false, { showPhotos = true }),
            ("doc", "Файл", false, { showDoc = true }),
        ])
        return items
    }

    // Default satellites — always visible. Continues active chat when one exists.
    private var defaultSatellites: [(icon: String, label: String, isChat: Bool, action: () -> Void)] {
        var items: [(String, String, Bool, () -> Void)] = contextualSuggestions.map { suggestion in
            (suggestion.icon, suggestion.text, false, {
                Theme.hapticSend()
                SuggestionEngine.recordUsage(suggestion.text)
                onStartChat(suggestion.text)
            })
        }
        if hasActiveChat {
            items.append(("bubble.left.fill", "Продолжить", true, {
                onContinueChat()
            }))
        }
        return items
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                // Header
                header

                // Content — offset upward to align orb with splash position
                VStack(spacing: 0) {
                    Spacer()

                    orbCluster
                        .offset(y: -Theme.headerHeight)

                    Spacer()

                    SummaryEntryView(agents: stateService.state?.agents ?? [])
                        .onTapGesture { showStateBoard = true }
                        .padding(.horizontal, Theme.hPadding)
                        .padding(.bottom, Theme.scaled(8))
                }
            }
            .safeAreaInset(edge: .bottom) { greetingLabel }
            .background {
                GeometryReader { geo in
                    ZStack {
                        Theme.background
                        RadialGradient(
                            colors: [Theme.accent.opacity(0.04), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: geo.size.height * 0.5
                        )
                    }
                }
                .ignoresSafeArea()
            }
            .preferredColorScheme(.dark)
            .accessibilityIdentifier("orb-home")
            // UI-test-only: stable tap target for navigating to text chat, placed
            // at bottom-leading corner well outside the satellite orbit radius.
            .overlay(alignment: .bottomLeading) {
                if JarvisApp.isUITesting {
                    Button(action: { onStartChat(nil) }) {
                        Rectangle()
                            .fill(Color.white.opacity(0.01))
                            .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                    }
                    .accessibilityLabel("uitest-start-text-chat")
                    .padding(.bottom, Theme.scaled(4))
                }
            }

            // Left drawer (agent switcher) — mirrors ChatView.
            if leftDrawerOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { leftDrawerOpen = false } }
                    .transition(.opacity)
            }

            LeftDrawerContent(
                onSelect: { agent in
                    active.active = agent
                    withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                        leftDrawerOpen = false
                    }
                }
            )
            .frame(width: Theme.drawerWidth)
            .offset(x: {
                    if leftDrawerOpen {
                        return max(-Theme.drawerWidth, min(0, leftDrawerDragOffset))
                    } else {
                        return -Theme.drawerWidth + max(0, min(leftDrawerDragOffset, Theme.drawerWidth))
                    }
                }())
            .gesture(leftDrawerDragToClose)
            .shadow(color: .black.opacity(leftDrawerOpen ? 0.4 : 0), radius: 12, x: 4)
            .animation(.spring(duration: Theme.animMedium, bounce: 0.05), value: leftDrawerOpen)

            // Shroud
            if rightDrawerOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { rightDrawerOpen = false }
                    }
                    .transition(.opacity)
            }

            // Right drawer
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
            .frame(width: Theme.drawerWidth)
            .offset(x: {
                    let screenWidth = UIScreen.main.bounds.width
                    if rightDrawerOpen {
                        return min(screenWidth, screenWidth - Theme.drawerWidth + rightDrawerDragOffset)
                    } else {
                        return screenWidth - max(0, min(-rightDrawerDragOffset, Theme.drawerWidth))
                    }
                }())
            .gesture(rightDrawerDragToClose)
            .shadow(color: .black.opacity(rightDrawerOpen ? 0.4 : 0), radius: 12, x: -4)
            .animation(.spring(duration: Theme.animMedium, bounce: 0.05), value: rightDrawerOpen)
        }
        .simultaneousGesture(rightEdgeSwipeGesture)
        .simultaneousGesture(leftEdgeSwipeGesture)
        .attachmentPickers(drafts: $drafts, showPhotos: $showPhotos, showCamera: $showCamera, showDoc: $showDoc)
        .onChange(of: drafts) {
            if !drafts.isEmpty {
                // Attachment picked — go to chat with it
                onStartChat(nil)
            }
        }
        .onAppear {
            stateService.refresh()
            openSummaryBoardIfRequested()
        }
        // Deep-link: a summary-ready tap routes here. Covers both "flag already
        // true at mount" (cold launch) via onAppear and "becomes true while
        // mounted" via onChange.
        .onChange(of: coordinator.pendingOpenSummaryBoard) { _, _ in openSummaryBoardIfRequested() }
        .sheet(isPresented: $showStateBoard) {
            NavigationView { StateBoardView(service: stateService) }
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showVoiceFullscreen) {
            OrbVoiceView(coordinator: coordinator, onHandoffToChat: {
                onStartVoiceChat()
            })
        }
    }

    // MARK: – Header

    private var header: some View {
        HStack(alignment: .top) {
            // Left orb opens the agent switcher (mirrors ChatView). Voice mode
            // is intentionally off the header orbs for now.
            HeaderStatusDot(side: .left,
                            isConnected: coordinator.ws.isConnected,
                            phase: .calm) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    leftDrawerOpen = true
                }
            } onLongPress: {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    leftDrawerOpen = true
                }
            }
            .accessibilityLabel("Выбор агента")

            Spacer()

            // Active-agent label — display only on home. Agent switching lives on
            // the left orb; the center "go home" tap (used in chat) is a no-op
            // here since this IS the home screen.
            Text(spaced(active.active.displayName))
                .font(.system(size: Theme.fontTitle, weight: .light))
                .tracking(Theme.titleTracking)
                .foregroundStyle(active.active.accentColor)
                .fixedSize()
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(active.active.accentColor.opacity(0.6))
                        .frame(height: 1)
                        .offset(y: 4)
                }
                .frame(minHeight: Theme.minTapSize)
                .accessibilityLabel("Активный агент: \(active.active.displayName)")

            Spacer()

            HeaderStatusDot(side: .right,
                            isConnected: coordinator.ws.isConnected,
                            phase: .calm) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    rightDrawerOpen = true
                }
            }
            .accessibilityLabel("Открыть профиль и настройки")
        }
        .padding(.horizontal, Theme.scaled(8))
        .frame(minHeight: Theme.headerHeight)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.accent.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    // MARK: – Orb cluster

    private var orbCluster: some View {
        ZStack {
            // Default satellites (suggestions) — visible when action satellites are hidden
            ForEach(Array(defaultSatellites.enumerated()), id: \.offset) { index, sat in
                let count = defaultSatellites.count
                let angle = -.pi / 2 + (2 * .pi / Double(count)) * Double(index)
                let radius = Theme.scaled(defaultSatellites.count > 6 ? 150 : 130)
                let x = cos(angle) * radius
                let y = sin(angle) * radius

                HomeSatelliteOrb(
                    icon: sat.icon,
                    label: sat.label,
                    isChat: sat.isChat
                ) {
                    sat.action()
                }
                .offset(x: showSatellites ? 0 : x, y: showSatellites ? 0 : y)
                .scaleEffect(showSatellites ? 0.3 : 1.0)
                .opacity(showSatellites ? 0 : 1.0)
                .allowsHitTesting(!showSatellites)
                .animation(
                    .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.06),
                    value: showSatellites
                )
            }

            // Action satellites (mic, camera, photo, file) — shown on long press
            ForEach(Array(actionSatellites.enumerated()), id: \.offset) { index, sat in
                let count = actionSatellites.count
                let angle = -.pi / 2 + (2 * .pi / Double(count)) * Double(index)
                let radius = Theme.scaled(defaultSatellites.count > 6 ? 150 : 130)
                let x = cos(angle) * radius
                let y = sin(angle) * radius

                HomeSatelliteOrb(
                    icon: sat.icon,
                    label: sat.label,
                    isChat: sat.isChat
                ) {
                    sat.action()
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                        showSatellites = false
                    }
                }
                .offset(x: showSatellites ? x : 0, y: showSatellites ? y : 0)
                .scaleEffect(showSatellites ? 1.0 : 0.3)
                .opacity(showSatellites ? 1.0 : 0)
                .allowsHitTesting(showSatellites)
                .animation(
                    // Skip animation in UITesting so satellites jump to final position
                    // immediately — lets XCUITest tap them at the correct coordinate.
                    JarvisApp.isUITesting ? nil : .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.06),
                    value: showSatellites
                )
            }

            // Central orb
            VStack(spacing: Theme.scaled(8)) {
                ZStack {
                    OrbView(size: Theme.orbSize, mood: showSatellites ? .heroic : .welcoming)
                        .scaleEffect(showSatellites ? 1.08 : 1.0)
                        .animation(.spring(duration: 0.3), value: showSatellites)
                        .onTapGesture {
                            if showSatellites {
                                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                                    showSatellites = false
                                }
                            } else {
                                Theme.hapticSend()
                                showVoiceFullscreen = true
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.3) {
                            Theme.hapticMedium()
                            withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                                showSatellites.toggle()
                            }
                        }
                        .accessibilityLabel("Начать диалог")
                        .accessibilityIdentifier("home-orb")

                    // UI-test-only: reliable Button tap target that opens the voice
                    // fullscreen. The OrbView's `.onTapGesture` is not always picked
                    // up by XCUITest (TimelineView + custom rendering + parent
                    // identifier propagation interfere with hit-test discovery).
                    if JarvisApp.isUITesting && !showSatellites {
                        Button(action: {
                            showVoiceFullscreen = true
                        }) {
                            Rectangle()
                                .fill(Color.white.opacity(0.01))
                                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                        }
                        .accessibilityLabel("uitest-home-orb")
                        .accessibilityIdentifier("home-orb-uitest")
                    }
                }
            }

            // UI-test-only: tap target to reveal action satellites.
            // Offset off the central orb so taps on the orb itself (which open the
            // voice fullscreen) are not intercepted by this overlay. Only present
            // when satellites are hidden — once visible, action satellites must
            // receive taps directly.
            if JarvisApp.isUITesting && !showSatellites {
                Button(action: {
                    withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                        showSatellites = true
                    }
                }) {
                    Rectangle()
                        .fill(Color.white.opacity(0.01))
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .accessibilityLabel("Toggle satellite menu")
                .accessibilityIdentifier("orb-satellites-toggle")
                // Park near the top of the cluster, clear of the central orb's hit area.
                .offset(y: -Theme.scaled(170))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.scaled(360))
        .contentShape(Rectangle())
        .onTapGesture {
            if showSatellites {
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                    showSatellites = false
                }
            }
        }
    }

    // MARK: – Drawer gestures

    private static let edgeSwipeZone: CGFloat = 40

    private var rightEdgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let screenWidth = UIScreen.main.bounds.width
                if value.startLocation.x > screenWidth - Self.edgeSwipeZone
                    && value.translation.width < 0
                    && abs(value.translation.width) > abs(value.translation.height) * 1.2
                    && !rightDrawerOpen {
                    rightDrawerDragOffset = max(value.translation.width, -Theme.drawerWidth)
                }
            }
            .onEnded { value in
                let screenWidth = UIScreen.main.bounds.width
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                if !rightDrawerOpen
                    && value.startLocation.x > screenWidth - Self.edgeSwipeZone
                    && value.translation.width < -60
                    && horizontal {
                    withAnimation(.spring(duration: 0.3)) {
                        rightDrawerOpen = true
                        rightDrawerDragOffset = 0
                    }
                } else if !rightDrawerOpen {
                    withAnimation { rightDrawerDragOffset = 0 }
                }
            }
    }

    private var rightDrawerDragToClose: some Gesture {
        DragGesture()
            .onChanged { value in
                if rightDrawerOpen && value.translation.width > 0 {
                    rightDrawerDragOffset = value.translation.width
                }
            }
            .onEnded { value in
                if rightDrawerOpen && value.translation.width > 60 {
                    withAnimation(.spring(duration: 0.3)) {
                        rightDrawerOpen = false
                        rightDrawerDragOffset = 0
                    }
                } else {
                    withAnimation { rightDrawerDragOffset = 0 }
                }
            }
    }

    /// Mirror of `rightEdgeSwipeGesture`, anchored to the LEFT screen edge:
    /// a rightward swipe starting within `edgeSwipeZone` of the left edge opens
    /// the left (agent-switcher) drawer.
    private var leftEdgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if value.startLocation.x < Self.edgeSwipeZone
                    && value.translation.width > 0
                    && abs(value.translation.width) > abs(value.translation.height) * 1.2
                    && !leftDrawerOpen {
                    leftDrawerDragOffset = min(value.translation.width, Theme.drawerWidth)
                }
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                if !leftDrawerOpen
                    && value.startLocation.x < Self.edgeSwipeZone
                    && value.translation.width > 60
                    && horizontal {
                    withAnimation(.spring(duration: 0.3)) {
                        leftDrawerOpen = true
                        rightDrawerOpen = false
                        leftDrawerDragOffset = 0
                    }
                } else if !leftDrawerOpen {
                    withAnimation { leftDrawerDragOffset = 0 }
                }
            }
    }

    private var leftDrawerDragToClose: some Gesture {
        DragGesture()
            .onChanged { value in
                if leftDrawerOpen && value.translation.width < 0 {
                    leftDrawerDragOffset = value.translation.width
                }
            }
            .onEnded { value in
                if leftDrawerOpen && value.translation.width < -60 {
                    withAnimation(.spring(duration: 0.3)) {
                        leftDrawerOpen = false
                        leftDrawerDragOffset = 0
                    }
                } else {
                    withAnimation { leftDrawerDragOffset = 0 }
                }
            }
    }

    /// Present the Сводка board if a notification tap requested it, then clear
    /// the flag so a re-render doesn't re-present.
    private func openSummaryBoardIfRequested() {
        guard coordinator.pendingOpenSummaryBoard else { return }
        showStateBoard = true
        coordinator.pendingOpenSummaryBoard = false
    }

    /// Insert U+2009 (thin space) between every character to match the
    /// "J A R V I S" letter-spaced look (mirrors `ChatView`).
    private func spaced(_ s: String) -> String {
        s.uppercased().map { String($0) }.joined(separator: "\u{2009}\u{2009}")
    }

}

// MARK: – Home Satellite Orb

private struct HomeSatelliteOrb: View {
    let icon: String
    let label: String
    var isChat: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.scaled(6)) {
                ZStack {
                    // Outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Theme.accent.opacity(isChat ? 0.12 : 0.06),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: Theme.scaled(20),
                                endRadius: Theme.scaled(36)
                            )
                        )
                        .frame(width: Theme.scaled(60), height: Theme.scaled(60))

                    // Main circle
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Theme.surface.opacity(0.9),
                                    Theme.background.opacity(0.7)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: Theme.scaled(50), height: Theme.scaled(50))
                        .overlay(
                            Circle().stroke(
                                isChat ? Theme.accent.opacity(0.5) : Theme.accent.opacity(0.15),
                                lineWidth: Theme.lineHairline
                            )
                        )
                    Image(systemName: icon)
                        .font(.system(size: Theme.scaled(20), weight: .light))
                        .foregroundStyle(isChat ? Theme.accent : Theme.accentMedium.opacity(0.8))
                }
                Text(label)
                    .font(.system(size: Theme.scaled(10), weight: .medium))
                    .foregroundStyle(Theme.accentMedium.opacity(0.7))
            }
        }
        .accessibilityLabel(label)
    }
}
