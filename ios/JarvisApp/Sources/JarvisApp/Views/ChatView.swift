import SwiftUI
import UIKit
import Combine

private struct FullScreenImagePresentation: Identifiable {
    let id = UUID()
    let sha: String?
    let fallback: UIImage
}

/// Identifiable wrapper for `fullScreenCover(item:)` so SwiftUI can track
/// the current workout session by workoutId.
private struct WorkoutPresentation: Identifiable {
    enum Phase { case preview, running }
    let plan: WorkoutPlan
    var phase: Phase
    var coord: WorkoutCoordinator?   // nil in preview; created on "Поехали"
    let messageId: String?
    var id: String { plan.workoutId }
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
    @State private var fullScreenImage: FullScreenImagePresentation? = nil
    @State private var isScrolledUp = false
    @State private var scrollToBottomToken = 0
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

    // T3.6 — persisted in-progress workout for `payne` (survives app kill /
    // navigating away). Drives the card's "Продолжить тренировку" CTA and the
    // sticky resume banner when the card has scrolled out of the 500-message
    // window. Loaded on appear, on agent switch, and after the workout
    // fullScreenCover is dismissed — see `loadActiveWorkoutRecord()`.
    @State private var activeWorkoutRecord: ActiveWorkoutRecord? = nil

    // Swap-exercise sheet (driven from the preview / runner "Заменить").
    private struct SwapSheetPresentation: Identifiable {
        let workoutId: String
        let originalSlug: String
        var id: String { originalSlug }
    }
    @State private var swapSheet: SwapSheetPresentation? = nil
    @State private var swapResponse: SwapResponse? = nil
    @State private var swapLoading: Bool = false
    @State private var swapImageToken: Int = 0   // bumped on image_blob → refresh swap thumbnails

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

    /// Busy state of the CURRENTLY-ACTIVE agent. Busy is per-agent, so sending
    /// to one agent no longer shows "thinking" in every other agent's chat.
    private var activeBusy: Bool { ws.isBusy(agentId: active.active.rawValue) }

    private var orbMood: OrbMood {
        if !ws.isConnected               { return .error }
        if activeBusy                    { return .processing }
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

    /// Open the live WorkoutView for a plan delivered as a chat card. Holds the
    /// originating message id so the card can be marked done on close.
    /// Shared slug→cached-image-URL resolver (used by both preview and runner).
    private func resolveImageURL(slug: String, plan: WorkoutPlan) -> URL? {
        // No manifest entry → the plan carries no image for this exercise (e.g.
        // one antitrainer has no demo for). Show the placeholder, NOT a stale
        // cached blob from a past plan — keeps a unified "no demo" look.
        guard let entry = plan.imageManifest.first(where: { $0.slug == slug }) else { return nil }
        if coordinator.imageCache.has(slug: entry.slug, sha256: entry.sha256) {
            return coordinator.imageCache.path(forSlug: entry.slug, sha256: entry.sha256)
        }
        // Manifest entry present but its sha isn't cached yet (sha drift or
        // not-yet-delivered) → newest cached blob for the slug.
        return coordinator.imageCache.latestPath(slug: slug)
    }

    /// Card tap → open the PREVIEW (not the runner). The runner opens from preview.
    private func startWorkout(_ plan: WorkoutPlan, messageId: String) {
        activeWorkout = WorkoutPresentation(plan: plan, phase: .preview, coord: nil, messageId: messageId)
    }

    /// "Поехали" inside the preview → create the coordinator + swap to the
    /// running phase. Same `id` (workoutId) keeps the same fullScreenCover
    /// mounted and just swaps its content from preview to runner.
    private func startRunning(with plan: WorkoutPlan) {
        guard let cur = activeWorkout, let stack = coordinator.ws.stack else {
            Log.warn(.ws, "start running but stack not built — dropping")
            return
        }
        let wc = WorkoutCoordinator(
            plan: plan, queue: stack.setLogQueue,
            store: stack.activeWorkoutStore, agentId: "payne", messageId: cur.messageId
        )
        activeWorkout = WorkoutPresentation(plan: plan, phase: .running, coord: wc, messageId: cur.messageId)
    }

    /// Load (or clear) the persisted active-workout record for `payne`. Only
    /// `payne` runs the workout flow, so any other active agent clears it.
    /// Safe to call repeatedly — cheap single-row lookup.
    ///
    /// A decode failure is logged rather than silently swallowed — a corrupt
    /// row is a bug we want visible in the log, not something that quietly
    /// hides the resume banner.
    private func loadActiveWorkoutRecord() {
        guard active.active == .payne,
              let store = coordinator.ws.stack?.activeWorkoutStore else {
            activeWorkoutRecord = nil
            return
        }
        do {
            activeWorkoutRecord = try store.load(agentId: active.active.rawValue)
        } catch {
            Log.warn(.ws, "activeWorkout load failed: \(error)")
            activeWorkoutRecord = nil
        }
    }

    /// Resume a persisted workout straight into the running phase — the user
    /// already saw the preview when the plan first arrived, so there's no
    /// need to show it again.
    private func resumeWorkout(_ record: ActiveWorkoutRecord) {
        guard let stack = coordinator.ws.stack else { return }
        let wc = WorkoutCoordinator(
            restoring: record, queue: stack.setLogQueue, store: stack.activeWorkoutStore
        )
        activeWorkout = WorkoutPresentation(
            plan: record.plan, phase: .running, coord: wc, messageId: record.messageId
        )
    }

    /// Open the swap sheet for an exercise. The sheet drives the existing
    /// exercise_swap_request / _options / _confirm flow over the transport.
    private func beginSwap(slug: String, workoutId: String) {
        swapResponse = nil
        swapLoading = false
        swapSheet = SwapSheetPresentation(workoutId: workoutId, originalSlug: slug)
    }

    /// Update the scrolled-up state that drives the scroll-to-bottom FAB. Called
    /// from `MessageListView` (via `onScrolledUpChange`) when the list's at-bottom
    /// state flips; wraps the change in an animation so the FAB fades/scales.
    private func setScrolledUp(_ up: Bool) {
        guard up != isScrolledUp else { return }
        withAnimation(.easeOut(duration: Theme.animFast)) {
            isScrolledUp = up
        }
    }

    /// Resign first responder app-wide. Used for tap-to-dismiss and to force the
    /// keyboard closed on agent switch — the chat hosts a SINGLE shared input
    /// bar, so its `@FocusState` otherwise persists across agents and leaves the
    /// next agent's chat rendered keyboard-open.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
        VStack(spacing: 0) {
            // MARK: – Content
            if visibleMessages.isEmpty && !activeBusy && !emptyInputActive {
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
                VStack(spacing: 0) {
                    // T3.6 — sticky resume banner: only when the active-workout
                    // card has scrolled out of the visible (500-message) window.
                    // When the card IS visible, its own CTA flips to "Продолжить
                    // тренировку" instead (see MessageRow's `resumeMessageId`).
                    if let record = activeWorkoutRecord,
                       !visibleMessages.contains(where: { $0.id == record.messageId }) {
                        resumeWorkoutBanner(record)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    ZStack(alignment: .bottomTrailing) {
                        MessageListView(
                            messages: visibleMessages,
                            agentId: active.active.rawValue,
                            isBusy: activeBusy,
                            onImageTap: { thumb, sha in
                                fullScreenImage = FullScreenImagePresentation(sha: sha, fallback: thumb)
                            },
                            onFeedback: { messageId, isPositive in
                                coordinator.sendFeedback(messageId: messageId, value: isPositive, messageText: visibleMessages.first(where: { $0.id == messageId })?.text ?? "")
                            },
                            onActionTap: { messageId, buttonId, buttonLabel in
                                coordinator.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
                                coordinator.markActionAnswered(rowId: messageId, choice: buttonId)
                            },
                            onWorkoutStart: { plan, messageId in
                                if let record = activeWorkoutRecord, record.messageId == messageId {
                                    resumeWorkout(record)
                                } else {
                                    startWorkout(plan, messageId: messageId)
                                }
                            },
                            onWorkoutCancel: { coordinator.markWorkoutCardDone(workoutId: $0) },
                            onRetry: { id in coordinator.ws.retrySend(id: id) },
                            onMessageRead: { id in ws.sendMessageRead(id) },
                            audioPlayer: coordinator.audioPlayer,
                            onScrolledUpChange: { setScrolledUp($0) },
                            scrollToBottomToken: scrollToBottomToken,
                            resumeMessageId: activeWorkoutRecord?.messageId
                        )
                        .ignoresSafeArea(.container, edges: .bottom)

                        if isScrolledUp {
                            scrollToBottomFAB
                                .transition(.scale.combined(with: .opacity))
                        }
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
                            placeholder: "Спросить \(active.active.displayName)...",
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
        .fullScreenCover(item: $fullScreenImage) { item in
            FullScreenImageView(sha: item.sha, fallback: item.fallback)
        }
        .fullScreenCover(isPresented: $showVoiceFullscreen) {
            OrbVoiceView(coordinator: coordinator, onHandoffToChat: nil)
        }
        .fullScreenCover(item: $activeWorkout) { presentation in
            Group {
                switch presentation.phase {
                case .preview:
                    WorkoutPreviewView(
                        plan: presentation.plan,
                        imageResolver: { resolveImageURL(slug: $0, plan: presentation.plan) },
                        planUpdates: coordinator.workoutBus.events
                            .compactMap { if case .planReceived(let p) = $0 { return p } else { return nil } }
                            .eraseToAnyPublisher(),
                        imageUpdates: coordinator.workoutBus.events
                            .compactMap { if case .imageReceived(let s) = $0 { return s } else { return nil } }
                            .eraseToAnyPublisher(),
                        onAppearPrefetch: { coordinator.imageCache.prefetch(manifest: presentation.plan.imageManifest) },
                        onStart: { startRunning(with: $0) },
                        onSwap: { slug in beginSwap(slug: slug, workoutId: presentation.plan.workoutId) },
                        onClose: { activeWorkout = nil }
                    )
                case .running:
                    WorkoutView(
                        coordinator: presentation.coord!,
                        imageResolver: { resolveImageURL(slug: $0, plan: presentation.plan) },
                        onClose: { session in
                            let workoutId = presentation.plan.workoutId
                            if let session {
                                Task { try? await coordinator.ws.stack?.transport.sendWorkoutComplete(session) }
                            } else {
                                Task {
                                    try? await coordinator.ws.stack?.transport.sendWorkoutAbort(
                                        workoutId: workoutId, reason: "user cancelled"
                                    )
                                }
                            }
                            // Grey the card ONLY when the workout was completed.
                            // Match by workout_id (NOT presentation.messageId, which a
                            // mid-workout exercise swap can drop → card stayed active
                            // even though the workout finished) so it reliably resolves.
                            // Abort / view-without-finishing leaves it tappable so
                            // "Посмотреть тренировку" can be reopened.
                            if session != nil {
                                coordinator.markWorkoutCardDone(workoutId: workoutId)
                            }
                            activeWorkout = nil
                            // The coordinator already cleared the DB row (on
                            // complete/abort, above) — drop the stale @State
                            // immediately, then re-check in case something else
                            // (e.g. a fresh workout_plan) is now active.
                            activeWorkoutRecord = nil
                            loadActiveWorkoutRecord()
                        },
                        onSwap: { slug in beginSwap(slug: slug, workoutId: presentation.plan.workoutId) },
                        onAppearPrefetch: { coordinator.imageCache.prefetch(manifest: presentation.plan.imageManifest) }
                    )
                }
            }
            // Attached INSIDE the cover so the swap sheet presents OVER the
            // fullScreenCover. A `.sheet` on ChatView's body would sit behind it
            // and never appear.
            .sheet(item: $swapSheet) { s in
                SwapSheet(
                    originalSlug: s.originalSlug,
                    currentName: activeWorkout?.plan.exercises.first(where: { $0.exerciseSlug == s.originalSlug })?.displayName ?? "",
                    thumbnail: { slug in
                        if let plan = activeWorkout?.plan,
                           let url = resolveImageURL(slug: slug, plan: plan) { return url }
                        return coordinator.imageCache.latestPath(slug: slug)
                    },
                    refreshToken: swapImageToken,
                    response: $swapResponse,
                    loading: $swapLoading
                ) { action in
                    switch action {
                    case .requestSuggestions:
                        swapLoading = true
                        Task { try? await coordinator.ws.stack?.transport.sendExerciseSwapRequest(workoutId: s.workoutId, slug: s.originalSlug, proposed: nil) }
                    case .proposeOwn(let text):
                        swapLoading = true
                        Task { try? await coordinator.ws.stack?.transport.sendExerciseSwapRequest(workoutId: s.workoutId, slug: s.originalSlug, proposed: text) }
                    case .confirm(let newSlug, let persist):
                        Task { try? await coordinator.ws.stack?.transport.sendExerciseSwapConfirm(workoutId: s.workoutId, original: s.originalSlug, new: newSlug, persist: persist) }
                        swapSheet = nil
                    case .cancel:
                        swapSheet = nil
                    }
                }
            }
        }
        .onReceive(coordinator.workoutBus.events) { event in
            switch event {
            case .swapOptions(let resp, _, _):
                swapResponse = resp
                swapLoading = false
                // Fetch a thumbnail for each alternative (Payne answers image_request
                // for any slug it has). The sheet shows placeholders until they land.
                for slug in resp.alternatives.map(\.slug) {
                    Task { try? await coordinator.ws.stack?.transport.sendImageRequest(slug: slug) }
                }
            case .imageReceived:
                swapImageToken += 1
            case .coachMessage(let text, _, let setRef):
                // Deviation replies carry set_ref — anchor the hint on that set's
                // chip (💬 badge, see LoggedSetChips) instead of a banner.
                if let setRef, let coord = activeWorkout?.coord {
                    coord.attachCoachHint(exerciseSlug: setRef.exerciseSlug, setIdx: setRef.setIdx, text: text)
                }
                // When setRef is nil, existing subscribers (e.g. WorkoutView) show the banner.
            case .planReceived, .programUpdated:
                // .planReceived is consumed by the open WorkoutPreviewView's own
                // subscription; program banners are logged only (no UI yet).
                break
            }
        }
        .onAppear {
            // Wire haptics in UI layer
            coordinator.onMessageReceived = {
                Theme.hapticReceive()
            }
            loadActiveWorkoutRecord()
        }
        // Cache the filtered message list (see `visibleMessages`). Recompute on
        // initial appear and whenever the underlying message set or the active
        // agent changes. `ws.messagesVersion` bumps on every change (append,
        // reorder, in-place status / audio-attach) in O(1) — far cheaper than
        // digesting the whole list on each body pass.
        .onAppear { recomputeVisibleMessages() }
        .onChange(of: ws.messagesVersion) { recomputeVisibleMessages() }
        .onChange(of: active.active) {
            // Close the keyboard on switch so the shared input bar's focus state
            // can't leave the next agent's chat rendered keyboard-open.
            dismissKeyboard()
            recomputeVisibleMessages()
            loadActiveWorkoutRecord()
        }
        .onChange(of: autoStartVoice) {
            // When entering chat with voice trigger from home, activate input bar
            if autoStartVoice && visibleMessages.isEmpty {
                emptyInputActive = true
            }
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
        Image(systemName: "arrow.down.circle")
            .font(.system(size: Theme.scaled(32)))
            .foregroundStyle(Theme.accent)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: Theme.scaled(30), height: Theme.scaled(30))
            )
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            .contentShape(Circle())
            .onTapGesture { scrollToBottomToken += 1 }
            .padding(.trailing, Theme.scaled(8))
            .padding(.bottom, Theme.scaled(8))
            .accessibilityLabel("Прокрутить вниз")
    }

    // MARK: – Resume-workout banner

    /// Sticky banner shown above the message list when there's a persisted
    /// in-progress workout whose card has scrolled out of the 500-message
    /// window. Tap resumes straight into the runner (see `resumeWorkout`).
    ///
    /// Copy aligned with the card CTA — both surfaces say "Продолжить
    /// тренировку" so the user sees the same action label everywhere,
    /// styled like a button row in Payne's accent.
    private func resumeWorkoutBanner(_ record: ActiveWorkoutRecord) -> some View {
        Button {
            Theme.hapticSend()
            resumeWorkout(record)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Продолжить тренировку")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, Theme.scaled(10))
            .background(Theme.accent.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.accent.opacity(0.25)).frame(height: Theme.lineHairline)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("resume-workout-banner")
        .accessibilityLabel("Продолжить тренировку")
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

}

// MARK: – Date Separator Component

struct DateSeparator: View {
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

