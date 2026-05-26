import SwiftUI

/// The home screen — a large orb with contextual suggestion satellites arranged around it.
/// Long press the orb to reveal action satellites (mic, camera, photo, file).
struct OrbHomeView: View {
    @Environment(AppSettings.self) var settings
    var coordinator: AppCoordinator

    var onStartChat: (String?) -> Void   // nil = open empty chat, String = send immediately
    var onStartVoiceChat: () -> Void    // open chat + auto-start voice recording
    var onContinueChat: () -> Void
    var onShowSettings: () -> Void

    @State private var showSatellites = false
    @State private var showProfile = false

    // Picker triggers
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showDoc = false
    @State private var drafts: [DraftAttachment] = []

    private var hasActiveChat: Bool {
        coordinator.store.activeConversationId != nil && !coordinator.ws.messages.isEmpty
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Доброе утро"
        case 12..<17: return "Добрый день"
        case 17..<22: return "Добрый вечер"
        default:      return "Доброй ночи"
        }
    }

    private var contextualSuggestions: [String] {
        SuggestionEngine.suggestions(count: 4)
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

    // Default satellites (suggestions + optional dialog) — always visible
    private var defaultSatellites: [(icon: String, label: String, isChat: Bool, action: () -> Void)] {
        var items: [(String, String, Bool, () -> Void)] = contextualSuggestions.map { text in
            (SuggestionEngine.icon(for: text), text, false, {
                Theme.hapticSend()
                SuggestionEngine.recordUsage(text)
                onStartChat(text)
            })
        }
        if hasActiveChat {
            items.append(("bubble.left.and.bubble.right", "Диалог", true, {
                onContinueChat()
            }))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Content — offset upward to align orb with splash position
            VStack(spacing: 0) {
                Spacer()

                orbCluster
                    .offset(y: -Theme.headerHeight)

                Spacer()
            }
        }
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
        .sheet(isPresented: $showProfile) {
            ProfileView(store: coordinator.store, isConnected: coordinator.ws.isConnected, onReconnect: {
                coordinator.disconnect()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    coordinator.connect()
                }
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.background)
        }
        .attachmentPickers(drafts: $drafts, showPhotos: $showPhotos, showCamera: $showCamera, showDoc: $showDoc)
        .onChange(of: drafts) {
            if !drafts.isEmpty {
                // Attachment picked — go to chat with it
                onStartChat(nil)
            }
        }
    }

    // MARK: – Header

    private var header: some View {
        HStack {
            // Status dot → Profile
            Button { showProfile = true } label: {
                ZStack {
                    Circle()
                        .stroke(coordinator.ws.isConnected ? Theme.online.opacity(0.2) : Theme.offline.opacity(0.15), lineWidth: 1.5)
                        .frame(width: Theme.scaled(22), height: Theme.scaled(22))
                    Circle()
                        .fill(coordinator.ws.isConnected ? Theme.online : Theme.offline)
                        .frame(width: Theme.scaled(8), height: Theme.scaled(8))
                        .shadow(color: (coordinator.ws.isConnected ? Theme.online : Theme.offline).opacity(0.8), radius: 4)
                }
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .accessibilityLabel(coordinator.ws.isConnected ? "Статус: подключено. Профиль" : "Статус: отключено. Профиль")

            Spacer()

            // Title (decorative on home)
            VStack(spacing: 3) {
                Text("J A R V I S")
                    .font(.system(size: Theme.fontTitle, weight: .light))
                    .tracking(Theme.titleTracking)
                    .foregroundStyle(Theme.accentMedium)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Theme.accentSubtle.opacity(0.2))
                    .frame(width: Theme.minTapSize, height: 1)
            }
            .frame(minHeight: Theme.minTapSize)

            Spacer()

            // Settings
            Button { onShowSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: Theme.scaled(18)))
                    .foregroundStyle(Theme.accentMedium)
                    .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .accessibilityLabel("Настройки")
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
                let radius = Theme.scaled(130)
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
                .animation(
                    .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.06),
                    value: showSatellites
                )
            }

            // Action satellites (mic, camera, photo, file) — shown on long press
            ForEach(Array(actionSatellites.enumerated()), id: \.offset) { index, sat in
                let count = actionSatellites.count
                let angle = -.pi / 2 + (2 * .pi / Double(count)) * Double(index)
                let radius = Theme.scaled(130)
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
                .animation(
                    .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.06),
                    value: showSatellites
                )
            }

            // Central orb + greeting label
            VStack(spacing: Theme.scaled(8)) {
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
                            onStartVoiceChat()
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

                Text(greeting)
                    .font(.system(size: Theme.scaled(11), weight: .light))
                    .tracking(2)
                    .foregroundStyle(Theme.accentMedium.opacity(0.7))
                    .opacity(showSatellites ? 0.3 : 1)
                    .animation(.easeOut(duration: 0.2), value: showSatellites)
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
                                lineWidth: 0.5
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
