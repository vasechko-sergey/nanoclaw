import SwiftUI
import UIKit

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

/// Carries the chat content's bottom edge (maxY) within the scroll view's
/// coordinate space, so the scroll-to-bottom FAB is driven by the real scroll
/// offset instead of a lazy anchor's unreliable appear/disappear.
private struct ChatScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Reports whether the chat scroll view is scrolled up away from the bottom
/// (beyond `threshold` points) — drives the scroll-to-bottom FAB. iOS 18+ reads
/// it straight from scroll geometry (`onScrollGeometryChange`, the sanctioned,
/// reliable API). Earlier iOS falls back to the `ChatScrollOffsetKey`
/// content-offset preference measured against the viewport height. The old lazy
/// "bottom" anchor's onAppear/onDisappear fired unreliably, and on iOS 18
/// `onPreferenceChange`'s closure is `@Sendable` — so neither alone is
/// trustworthy across versions.
private struct ScrolledUpDetector: ViewModifier {
    let threshold: CGFloat
    let viewportHeight: CGFloat
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                // "Scrolled up" = the content's bottom edge sits more than
                // `threshold` points above the bottom of the visible area.
                // `visibleRect.maxY` is the actual visible content bottom (in
                // content coordinates); at the bottom it equals contentSize.height
                // (distance 0). This avoids the contentOffset-vs-(contentSize -
                // containerSize) calc, which mis-fired against the bottom anchor
                // / safe-area insets and left the FAB always on.
                geo.contentSize.height - geo.visibleRect.maxY > threshold
            } action: { _, scrolledUp in
                onChange(scrolledUp)
            }
        } else {
            content
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(ChatScrollOffsetKey.self) { contentMaxY in
                    onChange(contentMaxY - viewportHeight > threshold)
                }
        }
    }
}

struct ChatView: View {
    @Environment(AppSettings.self) var settings
    @Environment(ActiveAgentState.self) private var active
    var coordinator: AppCoordinator
    var onGoHome: (() -> Void)? = nil
    @Binding var autoStartVoice: Bool

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
    @State private var leftDrawerOpen = false
    @State private var leftDrawerDragOffset: CGFloat = 0
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
    ///
    /// Cached in `@State` and recomputed only when `ws.messages` or the active
    /// agent changes (see `recomputeVisibleMessages()`), rather than on every
    /// `body` evaluation — the filter ran `AgentIdentity(rawValue:)` over the
    /// whole message array and was referenced many times per render.
    @State private var visibleMessages: [ChatMessage] = []

    /// Recompute the cached visible-message list. Filtering semantics are
    /// identical to the previous computed property.
    private func computeVisibleMessages() -> [ChatMessage] {
        return ws.messages.filter { msg in
            guard msg.isVisible else { return false }
            let slug = msg.agentId ?? "jarvis"
            return AgentIdentity(rawValue: slug) == active.active
        }
    }

    private func recomputeVisibleMessages() {
        visibleMessages = computeVisibleMessages()
    }

    /// Lightweight `Equatable` digest of the full message set used to detect
    /// when `visibleMessages` must be rebuilt. Changes on append, reorder, and
    /// in-place mutation (delivery status / text). Avoids requiring
    /// `ChatMessage: Equatable` (its `Content` holds `UIImage`/closures).
    private var messagesFingerprint: [String] {
        ws.messages.map { msg in
            // Include attached-audio presence so a voice note merging onto an
            // existing text row (same id/text/status) still triggers a rebuild.
            let audio = msg.attachedAudio?.url?.count ?? 0
            return "\(msg.id)|\(msg.isVisible ? 1 : 0)|\(msg.agentId ?? "")|\(msg.deliveryStatus.rawValue)|\(msg.text)|\(audio)"
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

    /// Update the scrolled-up state that drives the scroll-to-bottom FAB.
    /// Fed by `ScrolledUpDetector` (iOS-18 scroll geometry, or the pre-18
    /// content-offset preference). Clears the unread badge + reseats the
    /// last-seen count when the user returns to the bottom.
    private func setScrolledUp(_ up: Bool) {
        guard up != isScrolledUp else { return }
        withAnimation(.easeOut(duration: Theme.animFast)) {
            isScrolledUp = up
            if !up {
                unreadCount = 0
                lastSeenCount = visibleMessages.count
            }
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
        VStack(spacing: 0) {
            // MARK: – Content
            if visibleMessages.isEmpty && !ws.isBusy && !emptyInputActive {
                EmptyStateView(
                    suggestions: active.active.suggestions,
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
                    GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            // LazyVStack so rows realize on demand as they
                            // scroll into view rather than all at once — long
                            // sessions otherwise build every MessageRow up front.
                            LazyVStack(alignment: .leading, spacing: Theme.scaled(8)) {
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
                                        onRetry: { id in coordinator.ws.retrySend(id: id) },
                                        audioPlayer: coordinator.audioPlayer
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

                                // Scroll target for "jump to bottom" (proxy
                                // scrolls to this id). The scrolled-up state that
                                // drives the FAB is measured from the content
                                // offset (ChatScrollOffsetKey) on the ScrollView —
                                // the old onAppear/onDisappear on this lazy anchor
                                // fired unreliably, so the FAB often never showed.
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom")
                            }
                            .padding(.horizontal)
                            .padding(.top, Theme.scaled(8))
                            .background(
                                GeometryReader { contentGeo in
                                    Color.clear.preference(
                                        key: ChatScrollOffsetKey.self,
                                        value: contentGeo.frame(in: .named("chatScroll")).maxY
                                    )
                                }
                            )
                        }
                        .defaultScrollAnchor(.bottom)
                        .scrollDismissesKeyboard(.interactively)
                        .scrollContentBackground(.hidden)
                        .modifier(
                            ScrolledUpDetector(threshold: 80, viewportHeight: geo.size.height) { up in
                                setScrolledUp(up)
                            }
                        )
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
                            // Refresh the cached list up front so unread-count /
                            // scroll-to-last operate on the post-append set
                            // regardless of `.onChange` ordering this tick.
                            recomputeVisibleMessages()
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
                        .onChange(of: active.active) {
                            // Switching agents swaps the entire message list. The
                            // ScrollView keeps its prior offset, so without an
                            // explicit reset it lands at an arbitrary spot in the
                            // new agent's thread. Jump to the bottom and clear the
                            // scrolled-up / unread state that drives the FAB.
                            isScrolledUp = false
                            unreadCount = 0
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(60))
                                recomputeVisibleMessages()
                                lastSeenCount = visibleMessages.count
                                if let last = visibleMessages.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
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

            // MARK: – Payne workout starter. Kicks off the typed WorkoutView
            // flow: send `workout_start_request` → Payne replies `workout_plan`
            // → `workoutBus.planReceived` presents WorkoutView. Without this
            // trigger there is no way to open the live workout UI (only chat).
            if active.active == .payne {
                Button {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd"
                    let today = df.string(from: Date())
                    Task { try? await coordinator.ws.stack?.transport.sendWorkoutStartRequest(date: today) }
                } label: {
                    Label("Начать тренировку", systemImage: "figure.strengthtraining.traditional")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.scaled(10))
                        .background(Theme.accent.opacity(0.18))
                        .foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.inputRadius))
                }
                .padding(.horizontal, Theme.scaled(8))
                .padding(.bottom, Theme.scaled(4))
                .disabled(!ws.isConnected)
                .accessibilityLabel("Начать тренировку")
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
        .simultaneousGesture(rightEdgeSwipeGesture)
        .simultaneousGesture(leftEdgeSwipeGesture)

        // Left drawer (agent switcher)
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

        // Right drawer
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
        // Cache the filtered message list (see `visibleMessages`). Recompute on
        // initial appear and whenever the underlying message set or the active
        // agent changes. `messagesFingerprint` captures appends, reorders, and
        // in-place mutations (status/text) so cached output stays in sync with
        // the previous per-render computed property.
        .onAppear { recomputeVisibleMessages() }
        .onChange(of: messagesFingerprint) { recomputeVisibleMessages() }
        .onChange(of: active.active) { recomputeVisibleMessages() }
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
    }

    // MARK: – Header

    private var header: some View {
        HStack(alignment: .top) {
            // Left orb opens the agent switcher (the drawer slides from the
            // left, so this is the natural trigger). Voice mode is intentionally
            // off the header orbs for now — reachable from the chat input bar.
            HeaderStatusDot(side: .left, isConnected: ws.isConnected, phase: orbMood) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    leftDrawerOpen = true
                }
            } onLongPress: {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    leftDrawerOpen = true
                }
            }
            .accessibilityIdentifier("agent-switch-btn")
            .accessibilityLabel("Выбор агента")

            Spacer()

            // Active-agent label. Tap returns to the home screen.
            Button {
                onGoHome?()
            } label: {
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Активный агент: \(active.active.displayName). Нажмите чтобы вернуться на главный")

            Spacer()

            HeaderStatusDot(side: .right, isConnected: ws.isConnected, phase: orbMood) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    rightDrawerOpen = true
                }
            }
            .accessibilityIdentifier("right-drawer-btn")
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

    /// Insert U+2009 (thin space) between every character to match the
    /// "J A R V I S" letter-spaced look (mirrors `AgentPickerInline`).
    private func spaced(_ s: String) -> String {
        s.uppercased().map { String($0) }.joined(separator: "\u{2009}\u{2009}")
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

