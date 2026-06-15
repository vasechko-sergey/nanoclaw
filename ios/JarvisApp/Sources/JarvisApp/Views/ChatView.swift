import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Identifiable wrapper for `fullScreenCover(item:)` so SwiftUI can track
/// the current workout session by workoutId.
private struct WorkoutPresentation: Identifiable {
    let plan: WorkoutPlan
    let coord: WorkoutCoordinator
    var id: String { plan.workoutId }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatView: View {
    @Environment(AppSettings.self) var settings
    @Environment(ActiveAgentState.self) private var active
    var coordinator: AppCoordinator
    var onGoHome: (() -> Void)? = nil
    @Binding var autoStartVoice: Bool
    /// When `true`, ChatView is mounted as the right-hand canvas in the iPad split
    /// layout. The home/back affordance (onGoHome long-press on the agent picker) is
    /// hidden — the orb hub pane is always visible on the left — and a "new chat"
    /// button is shown instead. All other chrome (agent name, status, timeline,
    /// input bar) is identical to the fullscreen path. Default `false` preserves
    /// the existing fullscreen behaviour byte-for-byte.
    var embedded: Bool = false

    @State private var inputText       = ""
    @State private var inputViaVoice   = false
    @State private var drafts: [DraftAttachment] = []
    @State private var fullScreenImage: UIImage? = nil
    @State private var isScrolledUp = false
    @State private var unreadCount  = 0
    @State private var lastSeenCount = 0
    @State private var scrollToBottomAction: (() -> Void)?
    @State private var emptyInputActive = false  // user tapped orb/keyboard in empty state
    @State private var rightDrawerOpen = false
    @State private var rightDrawerDragOffset: CGFloat = 0
    @State private var showVoiceFullscreen = false
    @AppStorage("v3MigrationShown") private var v3MigrationShown = false
    @State private var showingV3Toast = false

    // P3.T17 — workout flow presentation. `activeWorkout` is set when an
    // inbound `workout_plan` envelope arrives on `coordinator.workoutBus`.
    @State private var activeWorkout: WorkoutPresentation? = nil

    private var ws: WebSocketClientV2 { coordinator.ws }

    /// Only messages that should render in the chat (excludes invisible technical messages).
    /// T10: also filtered by the currently-active agent chip. Rows missing
    /// `agentId` (pre-T7 storage) are treated as legacy `jarvis` traffic.
    /// Comparison goes through `AgentIdentity(rawValue:)` so folder-name
    /// aliases (e.g. `health-analyzer` → `.greg`) match correctly.
    private var visibleMessages: [ChatMessage] {
        return ws.messages.filter { msg in
            guard msg.isVisible else { return false }
            let slug = msg.agentId ?? "jarvis"
            return AgentIdentity(rawValue: slug) == active.active
        }
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
        coordinator.sendMessage(trimmed, viaVoice: inputViaVoice, attachments: drafts, agentId: active.active.rawValue)
        inputText = ""
        inputViaVoice = false
        drafts = []
    }

    var body: some View {
        ZStack(alignment: .leading) {
        VStack(spacing: 0) {
            // MARK: – Content
            if visibleMessages.isEmpty && !ws.isBusy && !emptyInputActive {
                EmptyStateView(
                    onSuggestion: { suggestion in
                        coordinator.sendMessage(suggestion, agentId: active.active.rawValue)
                    },
                    onStartVoice: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            emptyInputActive = true
                        }
                        autoStartVoice = true
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
                                        onSpeak: { text in coordinator.speak(text) },
                                        onRetry: { id in coordinator.ws.retrySend(id: id) }
                                    )
                                    .id(msg.id)
                                    .onAppear {
                                        if msg.role == .assistant {
                                            ws.sendMessageRead(msg.id)
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
                                withAnimation(.easeOut(duration: Theme.animFast)) {
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
                                // Defer one tick so SwiftUI renders the ThinkingRow before we scroll
                                // to it. Otherwise the "thinking" id isn't yet in the scroll-view's
                                // registry and the scroll is a no-op, leaving the orb below the fold.
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(50))
                                    withAnimation(.spring(duration: 0.3)) {
                                        proxy.scrollTo("bottom", anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(50))
                                if ws.isBusy {
                                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                                } else if let last = visibleMessages.last {
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

            // MARK: – Input (always visible — empty state shows orb+satellites above)
            UnifiedInputBar(text: $inputText, inputViaVoice: $inputViaVoice, drafts: $drafts,
                            commands: ws.commands, isDisabled: !ws.isConnected,
                            enterToSend: settings.enterToSend,
                            autoStartVoice: $autoStartVoice,
                            onSend: sendCurrent,
                            onPinchOut: { showVoiceFullscreen = true })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        // Header lives in a TOP safe-area inset rather than as the first child
        // of the VStack. The software keyboard insets only the BOTTOM safe
        // area; keeping the header in the top inset makes it immune to the
        // keyboard-avoidance offset, so the agent picker (which grows tall when
        // expanded) no longer drifts upward when the keyboard is open.
        .safeAreaInset(edge: .top, spacing: 0) { header }
        // Right-edge swipe to open drawer. In embedded mode the gesture fires
        // but all branches return early, so the drawer state is never mutated
        // (the hub pane's sheet owns profile access in the split layout).
        .simultaneousGesture(rightEdgeSwipeGesture)

        // Right drawer — suppressed in embedded mode to avoid a duplicate
        // profile route conflicting with the hub pane's sheet presentation.
        if !embedded {
            if rightDrawerOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { rightDrawerOpen = false } }
                    .transition(.opacity)
            }

            RightDrawerContent(
                isConnected: ws.isConnected,
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

            // ⌘↩ — send shortcut, embedded (split canvas) only.
            // Placed here so sendCurrent() is in scope; disabled in fullscreen
            // so the plain-Return / enterToSend behaviour is unchanged.
            Button("") { sendCurrent() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
                .disabled(!embedded)
        }
        .fullScreenCover(item: Binding(
            get: { fullScreenImage.map { IdentifiableImage(image: $0) } },
            set: { fullScreenImage = $0?.image }
        )) { item in
            FullScreenImageView(image: item.image)
        }
        .fullScreenCover(isPresented: $showVoiceFullscreen) {
            OrbVoiceView(coordinator: coordinator, onHandoffToChat: nil)
        }
        .fullScreenCover(item: $activeWorkout) { presentation in
            WorkoutView(
                coordinator: presentation.coord,
                imageResolver: { slug in
                    guard let entry = presentation.plan.imageManifest.first(where: { $0.slug == slug })
                    else { return nil }
                    return coordinator.imageCache.has(slug: entry.slug, sha256: entry.sha256)
                        ? coordinator.imageCache.path(forSlug: entry.slug, sha256: entry.sha256)
                        : nil
                },
                onClose: { session in
                    let workoutId = presentation.plan.workoutId
                    if let session {
                        Task {
                            try? await coordinator.ws.stack?.transport.sendWorkoutComplete(session)
                        }
                    } else {
                        Task {
                            try? await coordinator.ws.stack?.transport.sendWorkoutAbort(
                                workoutId: workoutId, reason: "user cancelled"
                            )
                        }
                    }
                    activeWorkout = nil
                },
                onSwap: { _ in
                    // T17.5: open SwapSheet — deferred. Bus is in place; the
                    // sheet wiring (binding the SwapResponse from
                    // `workoutBus.events.swapOptions`) lands in a follow-up.
                }
            )
        }
        .onReceive(coordinator.workoutBus.events) { event in
            switch event {
            case .planReceived(let plan):
                guard let queue = coordinator.ws.stack?.setLogQueue else {
                    Log.warn(.ws, "workout_plan arrived but stack not built — dropping")
                    return
                }
                let wc = WorkoutCoordinator(plan: plan, queue: queue)
                activeWorkout = WorkoutPresentation(plan: plan, coord: wc)
            case .coachMessage, .swapOptions, .programUpdated:
                // Banner + sheet wiring lives in WorkoutView itself once it
                // subscribes to the bus directly (T17 follow-up).
                break
            }
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
        .onAppear {
            if !v3MigrationShown && !JarvisApp.isUITesting {
                showingV3Toast = true
                v3MigrationShown = true
            }
        }
        .alert("История чата обновлена",
               isPresented: $showingV3Toast) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text("Jarvis теперь один непрерывный чат. Локальная история диалогов до обновления была удалена. Контекст агента сохранён на сервере.")
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("chat-view")
        // MARK: – Drag & drop onto the chat canvas (iPad pointer / Files)
        // Accepts images (NSItemProviderReading via UIImage) and file URLs.
        // Mirrors the security-scoped-resource + MIME pattern from AttachmentBar:
        // DraftAttachment.image / .file so the send flow (AttachmentChips → sendCurrent) is unchanged.
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Read file once; probe for image first, fall back to generic file.
                if let data = try? Data(contentsOf: url) {
                    if let img = UIImage(data: data),
                       let draft = DraftAttachment.image(img, name: url.lastPathComponent) {
                        drafts.append(draft)
                    } else {
                        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                            ?? "application/octet-stream"
                        drafts.append(.file(data: data, name: url.lastPathComponent, mimeType: mime))
                    }
                    added = true
                }
            }
            if added { Theme.hapticSend() }
            return added
        }
        .dropDestination(for: Data.self) { dataItems, _ in
            var added = false
            for data in dataItems {
                if let img = UIImage(data: data),
                   let draft = DraftAttachment.image(img, name: "dropped-image-\(Int(Date().timeIntervalSince1970)).jpg") {
                    drafts.append(draft)
                    added = true
                }
            }
            if added { Theme.hapticSend() }
            return added
        }
    }

    // MARK: – Header

    private var header: some View {
        HStack(alignment: .top) {
            // Left status dot — voice mode in fullscreen; absent in embedded
            // (the orb hub pane on the left owns voice access in split layout).
            if !embedded {
                HeaderStatusDot(side: .left, isConnected: ws.isConnected, phase: orbMood) {
                    showVoiceFullscreen = true
                } onLongPress: {
                    showVoiceFullscreen = true
                }
                .accessibilityIdentifier("orb-drawer-btn")
                .accessibilityLabel(ws.isConnected ? "Голосовой режим. Подключено" : "Голосовой режим. Отключено")
            }

            Spacer()

            // Agent name + status. In fullscreen, long-press goes home.
            // In embedded, there is no home phase — long-press is omitted.
            AgentPickerInline(onLongPress: embedded ? nil : onGoHome)

            Spacer()

            // Right side: settings drawer in fullscreen; "new chat" in embedded.
            if embedded {
                Button {
                    ws.sendNewConversation(agentId: active.active.rawValue)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: Theme.scaled(18)))
                        .foregroundStyle(Theme.accentMedium)
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .accessibilityLabel("Новый чат")
                .accessibilityIdentifier("new-chat-btn")
            } else {
                HeaderStatusDot(side: .right, isConnected: ws.isConnected, phase: orbMood) {
                    withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                        rightDrawerOpen = true
                    }
                }
                .accessibilityIdentifier("right-drawer-btn")
                .accessibilityLabel("Открыть профиль и настройки")
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

    /// Edge-swipe trigger zone. Widened to 40pt so the gesture is reliable;
    /// iOS 26's left-edge back-gesture protector consumes the first ~16pt on
    /// some devices, so a narrow 24pt zone misses many real attempts.
    private static let edgeSwipeZone: CGFloat = 40

    private var rightEdgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // In embedded (split) layout the hub pane owns profile; no drawer here.
                guard !embedded else { return }
                let screenWidth = UIScreen.main.bounds.width
                if value.startLocation.x > screenWidth - Self.edgeSwipeZone
                    && value.translation.width < 0
                    && abs(value.translation.width) > abs(value.translation.height) * 1.2
                    && !rightDrawerOpen {
                    rightDrawerDragOffset = max(value.translation.width, -Theme.drawerWidth)
                }
            }
            .onEnded { value in
                // In embedded (split) layout the hub pane owns profile; no drawer here.
                guard !embedded else { return }
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

