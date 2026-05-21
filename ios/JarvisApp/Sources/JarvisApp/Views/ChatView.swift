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
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var coordinator: AppCoordinator

    @State private var inputText       = ""
    @State private var showSettings    = false
    @State private var showEmojiPicker = false
    @State private var showConversations = false
    @State private var showProfile     = false
    @State private var fullScreenImage: UIImage? = nil
    @State private var isScrolledUp = false
    @State private var unreadCount  = 0
    @State private var lastSeenCount = 0
    @State private var scrollToBottomAction: (() -> Void)?

    private var ws: WebSocketClient { coordinator.ws }
    private var store: ConversationStore { coordinator.store }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: – Custom header
            header

            // MARK: – Content
            if ws.messages.isEmpty && !ws.isTyping {
                EmptyStateView { suggestion in
                    coordinator.sendMessage(suggestion)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: Theme.scaled(8)) {
                                ForEach(Array(ws.messages.enumerated()), id: \.element.id) { index, msg in
                                    // Date separator
                                    if shouldShowDateSeparator(at: index) {
                                        DateSeparator(date: msg.timestamp)
                                    }
                                    MessageBubble(
                                        message: msg,
                                        onImageTap: { img in fullScreenImage = img },
                                        onFeedback: { messageId, isPositive in
                                            coordinator.sendFeedback(messageId: messageId, value: isPositive, messageText: msg.text)
                                        }
                                    )
                                    .id(msg.id)
                                    .transition(
                                        .asymmetric(
                                            insertion: .opacity
                                                .combined(with: .scale(scale: 0.95, anchor: msg.role == .user ? .bottomTrailing : .bottomLeading))
                                                .combined(with: .offset(y: 8)),
                                            removal: .opacity
                                        )
                                    )
                                }
                                if ws.isTyping {
                                    TypingIndicator()
                                        .id("typing")
                                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
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
                            let scrolledAway = maxY > UIScreen.main.bounds.height + threshold
                            if scrolledAway != isScrolledUp {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if scrolledAway {
                                        isScrolledUp = true
                                        lastSeenCount = ws.messages.count
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
                            lastSeenCount = ws.messages.count
                            // Capture scroll action for FAB outside ScrollViewReader
                            scrollToBottomAction = {
                                if let last = ws.messages.last {
                                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                            if let last = ws.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: ws.messages.count) {
                            if isScrolledUp {
                                let newMessages = ws.messages.count - lastSeenCount
                                unreadCount = max(newMessages, 0)
                            } else {
                                if let last = ws.messages.last {
                                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .onChange(of: ws.isTyping) {
                            if ws.isTyping && !isScrolledUp {
                                withAnimation(.spring(duration: 0.3)) {
                                    proxy.scrollTo("typing", anchor: .bottom)
                                }
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                if ws.isTyping {
                                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                                } else if let last = ws.messages.last {
                                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                        }
                    }

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

            // MARK: – Input
            InputBar(text: $inputText, commands: ws.commands, isDisabled: !ws.isConnected, enterToSend: settings.enterToSend) {
                let trimmed = inputText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                coordinator.sendMessage(trimmed)
                inputText = ""
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: ws.messages.isEmpty)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsView(isInitialSetup: false)
        }
        .sheet(isPresented: $showProfile) {
            ProfileView(store: store, isConnected: ws.isConnected, onReconnect: {
                    coordinator.disconnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        coordinator.connect()
                    }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.background)
        }
        .sheet(isPresented: $showConversations) {
            ConversationListView(store: store) { action in
                showConversations = false
                coordinator.handleAction(action)
                inputText = ""
            }
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
        .onDisappear {
            coordinator.disconnect()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: – Header

    private var header: some View {
        HStack {
            Button { showProfile = true } label: {
                ZStack {
                    Circle()
                        .stroke(ws.isConnected ? Theme.online.opacity(0.2) : Theme.offline.opacity(0.15), lineWidth: 1.5)
                        .frame(width: Theme.scaled(22), height: Theme.scaled(22))
                    Circle()
                        .fill(ws.isConnected ? Theme.online : Theme.offline)
                        .frame(width: Theme.scaled(8), height: Theme.scaled(8))
                }
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .accessibilityLabel(ws.isConnected ? "Статус: подключено. Профиль" : "Статус: отключено. Профиль")

            Spacer()

            Button { showConversations = true } label: {
                VStack(spacing: 3) {
                    Text("J A R V I S")
                        .font(.system(size: Theme.fontTitle, weight: .light))
                        .tracking(Theme.titleTracking)
                        .foregroundStyle(Theme.accent.opacity(0.5))
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: Theme.minTapSize, height: 1)
                }
                .frame(minHeight: Theme.minTapSize)
            }
            .accessibilityLabel("Диалоги")

            Spacer()

            HStack(spacing: 2) {
                Button { showEmojiPicker.toggle() } label: {
                    Text(settings.statusEmoji.isEmpty ? "🙂" : settings.statusEmoji)
                        .font(.system(size: Theme.scaled(22)))
                        .opacity(settings.statusEmoji.isEmpty ? 0.3 : 1)
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .popover(isPresented: $showEmojiPicker) {
                    EmojiPickerView(selected: $settings.statusEmoji)
                        .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("Статус-эмодзи")

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: Theme.scaled(18)))
                        .foregroundStyle(Theme.accent.opacity(0.35))
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .accessibilityLabel("Настройки")
            }
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
        HStack(spacing: Theme.scaled(4)) {
            Image(systemName: "chevron.down")
                .font(.system(size: Theme.scaled(12), weight: .semibold))
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.system(size: Theme.scaled(11), weight: .bold))
            }
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, Theme.scaled(10))
        .padding(.vertical, Theme.scaled(6))
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Theme.accent.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        // Invisible expanded tap area (44pt min)
        .padding(Theme.scaled(8))
        .contentShape(Capsule())
        .onTapGesture {
            scrollToBottomAction?()
            unreadCount = 0
        }
        .padding(.trailing, Theme.scaled(4))
        .padding(.bottom, Theme.scaled(4))
        .accessibilityLabel(unreadCount > 0 ? "Вниз, \(unreadCount) новых" : "Прокрутить вниз")
    }

    // MARK: – Date separators

    private func shouldShowDateSeparator(at index: Int) -> Bool {
        guard index > 0 else { return ws.messages.count > 1 }
        let current = ws.messages[index].timestamp
        let previous = ws.messages[index - 1].timestamp
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }
}

// MARK: – Date Separator Component

private struct DateSeparator: View {
    let date: Date

    var body: some View {
        HStack {
            Spacer()
            Text(formatted)
                .font(.system(size: Theme.fontSmall, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.5))
                .padding(.horizontal, Theme.scaled(12))
                .padding(.vertical, Theme.scaled(4))
                .background(Theme.accent.opacity(0.06))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.vertical, Theme.scaled(4))
    }

    private var formatted: String {
        if Calendar.current.isDateInToday(date) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(date) { return "Вчера" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f.string(from: date)
    }
}

