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

    @State private var showVoiceFullscreen = false

    @State private var rightDrawerOpen = false
    @State private var rightDrawerDragOffset: CGFloat = 0

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
            .padding(.bottom, Theme.scaled(12))
            .accessibilityIdentifier("home-greeting")
    }

    private var contextualSuggestions: [String] {
        SuggestionEngine.suggestions(count: 4)
    }

    // Default ring satellites — always visible. Continues active chat when one exists.
    private var satellites: [OrbSatellite] {
        var items: [OrbSatellite] = contextualSuggestions.map { text in
            OrbSatellite(
                id: text,
                icon: SuggestionEngine.icon(for: text),
                label: text,
                accent: Theme.accent,
                isHighlighted: false,
                action: {
                    Theme.hapticSend()
                    SuggestionEngine.recordUsage(text)
                    onStartChat(text)
                }
            )
        }
        if hasActiveChat {
            items.append(OrbSatellite(
                id: "Продолжить",
                icon: "bubble.left.fill",
                label: "Продолжить",
                accent: Theme.accent,
                isHighlighted: true,
                action: { onContinueChat() }
            ))
        }
        return items
    }

    // Action ring satellites (voice, text, camera, photo, file) — revealed on long-press.
    private var actionSatellites: [OrbSatellite] {
        var items: [OrbSatellite] = [
            OrbSatellite(id: "Голос",   icon: "mic.fill",  label: "Голос",  accent: Theme.accent, isHighlighted: false, action: { onStartVoiceChat() }),
            OrbSatellite(id: "Текст",   icon: "keyboard",  label: "Текст",  accent: Theme.accent, isHighlighted: false, action: { onStartChat(nil) }),
        ]
        if cameraAvailable {
            items.append(OrbSatellite(id: "Камера", icon: "camera", label: "Камера", accent: Theme.accent, isHighlighted: false, action: { showCamera = true }))
        }
        items.append(contentsOf: [
            OrbSatellite(id: "Фото", icon: "photo", label: "Фото", accent: Theme.accent, isHighlighted: false, action: { showPhotos = true }),
            OrbSatellite(id: "Файл", icon: "doc",   label: "Файл", accent: Theme.accent, isHighlighted: false, action: { showDoc   = true }),
        ])
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

                    OrbHub(
                        satellites: satellites,
                        actionSatellites: actionSatellites,
                        onOrbTap: { showVoiceFullscreen = true }
                    )
                    .offset(y: -Theme.headerHeight)

                    Spacer()

                    HealthStripView(levels: stateService.state?.levels)
                        .onTapGesture { showStateBoard = true }
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
        .attachmentPickers(drafts: $drafts, showPhotos: $showPhotos, showCamera: $showCamera, showDoc: $showDoc)
        .onChange(of: drafts) {
            if !drafts.isEmpty {
                // Attachment picked — go to chat with it
                onStartChat(nil)
            }
        }
        .onAppear { stateService.refresh() }
        .sheet(isPresented: $showStateBoard) {
            NavigationView { StateBoardView(service: stateService) }
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
            HeaderStatusDot(side: .left,
                            isConnected: coordinator.ws.isConnected,
                            phase: .calm) {
                showVoiceFullscreen = true
            } onLongPress: {
                showVoiceFullscreen = true
            }
            .accessibilityLabel(coordinator.ws.isConnected ? "Голосовой режим. Подключено" : "Голосовой режим. Отключено")

            Spacer()

            // Agent picker — same component as ChatView header, in app style.
            AgentPickerInline()

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

}

