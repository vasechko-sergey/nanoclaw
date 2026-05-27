import SwiftUI
import UIKit

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatView: View {
    @Environment(AppSettings.self) var settings
    var coordinator: AppCoordinator
    var onGoHome: (() -> Void)? = nil
    @Binding var autoStartVoice: Bool

    @State private var inputText       = ""
    @State private var inputViaVoice   = false
    @State private var drafts: [DraftAttachment] = []
    @State private var showSettings    = false
    @State private var showProfile     = false
    @State private var fullScreenImage: UIImage? = nil
    @State private var isScrolledUp = false
    @State private var unreadCount  = 0
    @State private var lastSeenCount = 0
    @State private var scrollToBottomAction: (() -> Void)?
    @State private var emptyInputActive = false  // user tapped orb/keyboard in empty state
    @State private var drawerOpen = false
    @State private var drawerDragOffset: CGFloat = 0

    private var ws: WebSocketClient { coordinator.ws }
    private var store: ConversationStore { coordinator.store }

    /// Only messages that should render in the chat (excludes invisible technical messages).
    private var visibleMessages: [ChatMessage] {
        ws.messages.filter { $0.isVisible }
    }

    private var orbMood: OrbMood {
        if !ws.isConnected               { return .error }
        if ws.isBusy                     { return .processing }
        if coordinator.speech.isSpeaking { return .speaking }
        return .calm
    }

    /// Send the current draft (text + attachments) and reset input state.
    private func sendCurrent() {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty || !drafts.isEmpty else { return }
        coordinator.sendMessage(trimmed, viaVoice: inputViaVoice, attachments: drafts)
        inputText = ""
        inputViaVoice = false
        drafts = []
    }

    var body: some View {
        ZStack(alignment: .leading) {
        VStack(spacing: 0) {
            // MARK: – Custom header
            header

            // MARK: – Content
            if visibleMessages.isEmpty && !ws.isBusy && !emptyInputActive {
                EmptyStateView(
                    onSuggestion: { suggestion in
                        coordinator.sendMessage(suggestion)
                    },
                    onStartVoice: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            emptyInputActive = true
                        }
                        autoStartVoice = true
                    },
                    onStartText: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            emptyInputActive = true
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                ZStack(alignment: .bottomTrailing) {
                    GeometryReader { chatGeo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: Theme.scaled(8)) {
                                ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, msg in
                                    // Date separator
                                    if shouldShowDateSeparator(at: index, in: visibleMessages) {
                                        DateSeparator(date: msg.timestamp)
                                    }
                                    MessageRow(
                                        message: msg,
                                        isLast: index == visibleMessages.count - 1,
                                        onImageTap: { img in fullScreenImage = img },
                                        onFeedback: { messageId, isPositive in
                                            coordinator.sendFeedback(messageId: messageId, value: isPositive, messageText: msg.text)
                                        },
                                        onActionTap: { messageId, buttonId, buttonLabel in
                                            coordinator.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
                                        },
                                        onSpeak: { text in coordinator.speak(text) }
                                    )
                                    .id(msg.id)
                                    .onAppear {
                                        if msg.role == .assistant {
                                            ws.sendMessageRead(msg.id, conversationId: ws.conversationId)
                                        }
                                    }
                                    .transition(
                                        .asymmetric(
                                            insertion: .opacity.combined(with: .offset(y: 8)),
                                            removal: .opacity
                                        )
                                    )
                                }
                                if ws.isBusy {
                                    ThinkingRow(detail: ws.thinkingDetail)
                                        .id("thinking")
                                        .transition(.opacity.combined(with: .offset(y: 4)))
                                }

                                // Invisible anchor at bottom for scroll tracking
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ScrollOffsetKey.self,
                                        value: geo.frame(in: .named("chatScroll")).maxY
                                    )
                                }
                                .frame(height: 1)
                                .id("bottom")
                            }
                            .padding(.horizontal)
                            .padding(.top, Theme.scaled(8))
                        }
                        .coordinateSpace(name: "chatScroll")
                        .onPreferenceChange(ScrollOffsetKey.self) { maxY in
                            let threshold: CGFloat = 80
                            let scrolledAway = maxY > chatGeo.size.height + threshold
                            if scrolledAway != isScrolledUp {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if scrolledAway {
                                        isScrolledUp = true
                                        lastSeenCount = visibleMessages.count
                                    } else {
                                        isScrolledUp = false
                                        unreadCount = 0
                                    }
                                }
                            }
                        }
                        .defaultScrollAnchor(.bottom)
                        .scrollDismissesKeyboard(.interactively)
                        .scrollContentBackground(.hidden)
                        .onAppear {
                            lastSeenCount = visibleMessages.count
                            // Capture scroll action for FAB outside ScrollViewReader
                            scrollToBottomAction = {
                                if let last = visibleMessages.last {
                                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                            if let last = visibleMessages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: ws.messages.count) {
                            if isScrolledUp {
                                let newMessages = visibleMessages.count - lastSeenCount
                                unreadCount = max(newMessages, 0)
                            } else {
                                if let last = visibleMessages.last {
                                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .onChange(of: ws.isBusy) {
                            if ws.isBusy && !isScrolledUp {
                                withAnimation(.spring(duration: 0.3)) {
                                    proxy.scrollTo("thinking", anchor: .bottom)
                                }
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(50))
                                if ws.isBusy {
                                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                                } else if let last = ws.messages.last {
                                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                        }
                    }
                    } // GeometryReader

                    // Scroll-to-bottom FAB — outside ScrollViewReader, not blocked by scroll gestures
                    if isScrolledUp {
                        scrollToBottomFAB
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .transition(.opacity)
            }

            Divider().background(Theme.accent.opacity(0.1))

            // MARK: – Connection banner
            ConnectionBanner(isConnected: ws.isConnected) {
                coordinator.connect()
            }

            // MARK: – Stop speaking (visible while TTS is playing a long answer)
            if coordinator.speech.isSpeaking {
                Button(action: { coordinator.speech.stop() }) {
                    HStack(spacing: Theme.scaled(6)) {
                        Image(systemName: "stop.fill")
                        Text("Остановить")
                            .font(.system(size: Theme.fontSubhead, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.scaled(8))
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.inputRadius))
                    .padding(.horizontal, Theme.scaled(8))
                    .padding(.top, Theme.scaled(6))
                }
                .accessibilityLabel("Остановить")
            }

            // MARK: – Input (hidden in empty state until user initiates)
            if !visibleMessages.isEmpty || ws.isBusy || emptyInputActive {
                UnifiedInputBar(text: $inputText, inputViaVoice: $inputViaVoice, drafts: $drafts,
                                commands: ws.commands, isDisabled: !ws.isConnected,
                                enterToSend: settings.enterToSend,
                                autoStartVoice: $autoStartVoice,
                                onSend: sendCurrent)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .gesture(edgeSwipeGesture)

        // Shroud overlay when drawer open
        if drawerOpen {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { drawerOpen = false } }
                .transition(.opacity)
        }

        // Drawer slides in from left
        DrawerContent(
            store: store,
            onAction: { action in
                coordinator.handleAction(action)
                withAnimation { drawerOpen = false; drawerDragOffset = 0 }
            },
            onSettings: {
                withAnimation { drawerOpen = false }
                showSettings = true
            }
        )
        .frame(width: Theme.drawerWidth)
        .offset(x: drawerOpen
                ? max(-Theme.drawerWidth, drawerDragOffset)
                : -Theme.drawerWidth)
        .gesture(drawerDragToClose)
        .shadow(color: .black.opacity(drawerOpen ? 0.4 : 0), radius: 12, x: 4)
        .animation(.spring(duration: 0.35, bounce: 0.05), value: drawerOpen)

        } // ZStack
        .animation(.spring(duration: 0.4, bounce: 0.15), value: visibleMessages.isEmpty)
        .background {
            GeometryReader { geo in
                ZStack {
                    Theme.background
                    // Subtle radial glow at top for depth
                    RadialGradient(
                        colors: [Theme.accent.opacity(0.03), Color.clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: geo.size.height * 0.6
                    )
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(isInitialSetup: false, store: store) { action in
                showSettings = false
                coordinator.handleAction(action)
                inputText = ""
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.background)
        }
        .sheet(isPresented: $showProfile) {
            ProfileView(store: store, isConnected: ws.isConnected, onReconnect: {
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
        .fullScreenCover(item: Binding(
            get: { fullScreenImage.map { IdentifiableImage(image: $0) } },
            set: { fullScreenImage = $0?.image }
        )) { item in
            FullScreenImageView(image: item.image)
        }
        .onAppear {
            // Wire haptics in UI layer
            coordinator.onMessageReceived = {
                Theme.hapticReceive()
            }
        }
        .onChange(of: autoStartVoice) {
            // When entering chat with voice trigger from home, activate input bar
            if autoStartVoice && visibleMessages.isEmpty {
                emptyInputActive = true
            }
        }
        .onDisappear {
            coordinator.disconnect()
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("chat-view")
    }

    // MARK: – Header

    private var header: some View {
        HStack {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.05)) { drawerOpen = true }
            } label: {
                VStack(spacing: 4) {
                    Rectangle().frame(width: 18, height: 1.5)
                    Rectangle().frame(width: 14, height: 1.5)
                    Rectangle().frame(width: 18, height: 1.5)
                }
                .foregroundStyle(Theme.accentMedium)
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .accessibilityIdentifier("hamburger-btn")
            .accessibilityLabel("Открыть список диалогов")

            Button { showProfile = true } label: {
                ZStack(alignment: .bottomTrailing) {
                    MiniOrbView(size: 22, mood: orbMood)
                    Circle()
                        .fill(ws.isConnected ? Theme.online : Theme.offline)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 1))
                }
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .accessibilityLabel(ws.isConnected ? "Статус: подключено. Профиль" : "Статус: отключено. Профиль")

            Spacer()

            Button {
                if let onGoHome {
                    onGoHome()
                }
            } label: {
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
            }
            .disabled(onGoHome == nil)
            .accessibilityLabel("Домой")

            Spacer()

            Button { showSettings = true } label: {
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

    // MARK: – Scroll-to-bottom FAB

    private var scrollToBottomFAB: some View {
        ZStack {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: Theme.scaled(32)))
                .foregroundStyle(Theme.accent)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: Theme.scaled(30), height: Theme.scaled(30))
                )
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.system(size: Theme.scaled(10), weight: .bold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, Theme.scaled(5))
                    .padding(.vertical, Theme.scaled(1))
                    .background(Theme.accent)
                    .clipShape(Capsule())
                    .offset(x: Theme.scaled(12), y: -Theme.scaled(12))
                    .contentTransition(.numericText())
            }
        }
        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
        .contentShape(Circle())
        .onTapGesture {
            scrollToBottomAction?()
            unreadCount = 0
        }
        .padding(.trailing, Theme.scaled(8))
        .padding(.bottom, Theme.scaled(8))
        .accessibilityLabel(unreadCount > 0 ? "Вниз, \(unreadCount) новых" : "Прокрутить вниз")
    }

    // MARK: – Drawer gestures

    private var edgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if value.startLocation.x < 24 && value.translation.width > 0 && !drawerOpen {
                    drawerDragOffset = min(value.translation.width - Theme.drawerWidth, 0)
                }
            }
            .onEnded { value in
                if !drawerOpen && value.startLocation.x < 24 && value.translation.width > 80 {
                    withAnimation(.spring(duration: 0.3)) {
                        drawerOpen = true
                        drawerDragOffset = 0
                    }
                } else if !drawerOpen {
                    withAnimation { drawerDragOffset = 0 }
                }
            }
    }

    private var drawerDragToClose: some Gesture {
        DragGesture()
            .onChanged { value in
                if drawerOpen && value.translation.width < 0 {
                    drawerDragOffset = value.translation.width
                }
            }
            .onEnded { value in
                if drawerOpen && value.translation.width < -60 {
                    withAnimation(.spring(duration: 0.3)) {
                        drawerOpen = false
                        drawerDragOffset = 0
                    }
                } else {
                    withAnimation { drawerDragOffset = 0 }
                }
            }
    }

    // MARK: – Date separators

    private func shouldShowDateSeparator(at index: Int, in msgs: [ChatMessage]) -> Bool {
        guard index > 0 else { return msgs.count > 1 }
        let current = msgs[index].timestamp
        let previous = msgs[index - 1].timestamp
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }
}

// MARK: – Date Separator Component

private struct DateSeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.accent.opacity(0.1)).frame(height: 0.5)
            Text(formatted)
                .font(Theme.metaFont)
                .tracking(1)
                .foregroundStyle(Theme.accent.opacity(0.4))
            Rectangle().fill(Theme.accent.opacity(0.1)).frame(height: 0.5)
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, 8)
    }

    private var formatted: String {
        if Calendar.current.isDateInToday(date) { return "СЕГОДНЯ" }
        if Calendar.current.isDateInYesterday(date) { return "ВЧЕРА" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f.string(from: date).uppercased()
    }
}

