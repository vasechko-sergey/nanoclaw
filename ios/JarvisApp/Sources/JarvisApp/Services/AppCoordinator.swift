import Foundation
import GRDB

/// Central coordinator that owns all services and wires them together.
/// Views observe this instead of owning services directly.
@Observable @MainActor
final class AppCoordinator {

    // MARK: – Services (owned)
    private(set) var ws: WebSocketClientV2
    /// Drawer-facing shim over the GRDB-backed `ConversationStoreV2`. Owns
    /// the live in-memory `conversations` array + active id. Optional because
    /// the storage half of the v2 stack is built best-effort at init time —
    /// if the DB can't be opened (rare), the app still runs but the drawer
    /// stays empty. All view sites that read `coordinator.store` handle the
    /// nil case by rendering empty state.
    private(set) var store: ConversationStore!
    private(set) var location: LocationManager
    private(set) var health: HealthManager
    private(set) var calendar: CalendarManager
    private(set) var speech: SpeechSynthesizer
    private(set) var proactiveDispatcher: ProactiveDispatcher!
    private(set) var watchBridge: WatchConnectivityBridge!

    // MARK: – Connection state
    var connectionPhase: ConnectionPhase = .idle

    enum ConnectionPhase: Equatable {
        case idle
        case connecting
        case connected
        case failed
    }

    @ObservationIgnored private var settings: AppSettings
    /// Whether the last sent message was dictated — gates auto-speak of the reply.
    @ObservationIgnored private var lastSendWasVoice = false

    // MARK: – Haptic callback (keeps Service layer UI-free)
    @ObservationIgnored var onMessageReceived: (() -> Void)?

    // MARK: – Init

    init(settings: AppSettings) {
        self.settings = settings
        let location = LocationManager()
        let health = HealthManager()
        let calendar = CalendarManager()
        self.location = location
        self.health = health
        self.calendar = calendar
        self.speech = SpeechSynthesizer()
        // Build the storage half of the v2 stack now so the drawer shim is
        // populated before splash/home renders. The transport half is still
        // built lazily on first `connect(settings:)` (URL/token aren't known
        // at coordinator-init time). Failure leaves `store` nil — views read
        // it as empty state.
        let storage: (dbq: GRDB.DatabaseQueue, store: ConversationStoreV2)?
        do {
            storage = try AppV2Bootstrap.buildStorage()
        } catch {
            Log.warn(.ws, "AppCoordinator buildStorage failed: \(error)")
            storage = nil
        }
        if let storage {
            self.store = ConversationStore(v2: storage.store)
        }
        self.ws = WebSocketClientV2(
            location: location,
            health: health,
            calendar: calendar,
            storage: storage
        )

        let sink = WebSocketProactiveSink(ws: ws, settings: settings)
        self.proactiveDispatcher = ProactiveDispatcher(settings: settings, sink: sink)

        // Wire trigger sources
        location.attachDispatcher(proactiveDispatcher)
        // Always start sources — dispatcher.fire gates per-type opt-ins.
        // The OS-level cost of significant-change monitoring is negligible.
        location.startSignificantLocationMonitoring()
        health.installObservers(dispatcher: proactiveDispatcher)

        calendar.proactiveEnabled = settings.proactiveCalendarWarn
        Task { await calendar.fetchAndScheduleProactive() }

        AppDelegate.dispatchProactive = { [weak self] type, payload in
            Task { @MainActor in
                self?.proactiveDispatcher?.fire(type: type, payload: payload)
            }
        }

        self.watchBridge = WatchConnectivityBridge()
        watchBridge.onWatchDictation = { [weak self] text in
            Task { @MainActor in
                self?.sendMessage(text, viaVoice: true)
            }
        }

        wireUp()

        AppDelegate.onOpenConversation = { [weak self] id in
            self?.openConversation(id: id)
        }
    }

    /// Replace settings reference (needed because ContentView gets @Environment after init).
    func updateSettings(_ s: AppSettings) {
        self.settings = s
    }

    // MARK: – Lifecycle

    /// Begin connection. Call from splash when settings are configured.
    func connect() {
        guard settings.isConfigured else { return }
        connectionPhase = .connecting
        ws.connect(settings: settings)
        // Drawer state is already wired to GRDB via the `ConversationStore`
        // shim built at init time — no post-connect backfill needed.
        if settings.useLocation { location.requestAndUpdate() }
        if settings.useHealth   { health.requestAndFetch()    }
        if settings.useCalendar { calendar.requestAndFetch()  }
        // Drain any pending server-side health fetch requests over HTTP (no APNs).
        if settings.useHealth { HealthRequests.drain() }
    }

    func disconnect() {
        ws.disconnect()
        connectionPhase = .idle
    }

    // MARK: – Chat actions

    func sendMessage(_ text: String, viaVoice: Bool = false, attachments: [DraftAttachment] = []) {
        lastSendWasVoice = viaVoice
        // Update conversation metadata (auto-title + last_message_at) so the
        // drawer reflects the send immediately. The actual message row goes
        // into GRDB via `ws.send` → `ConversationStoreV2.insertOutboundUserMessage`.
        if let store, let cid = store.activeConversationId {
            store.recordUserSend(conversationId: cid, text: text)
        }
        // Push a light inline context snapshot (location/health/calendar per the user's
        // privacy toggles) so the agent always has timezone + location + next event +
        // status in-band. The pull model still works on top: the agent can fire
        // `context_request` for a fresher pull when it needs to.
        let emoji = settings.statusEmoji.trimmingCharacters(in: .whitespaces)
        // Trigger lazy refreshes — the response from build() uses whatever's currently cached
        if settings.useLocation { location.requestAndUpdate() }
        if settings.useHealth   { health.requestAndFetch()    }
        if settings.useCalendar { calendar.requestAndFetch()  }
        let ctx = ContextBuilder.build(
            fields: [],
            settings: settings,
            location: location,
            health: health,
            calendar: calendar
        )
        ws.send(
            text: text,
            timezone: TimeZone.current.identifier,
            status: emoji.isEmpty ? nil : emoji,
            attachments: attachments,
            context: ctx
        )
    }

    /// Speak arbitrary text on demand (manual "Проговорить" from a bubble).
    func speak(_ text: String) {
        speech.speak(text, voiceId: settings.voiceId, rate: settings.voiceRate, pitch: settings.voicePitch)
    }

    func sendFeedback(messageId: String, value: Bool, messageText: String) {
        ws.sendFeedback(conversationId: ws.conversationId, messageId: messageId, value: value, messageText: messageText)
    }

    func sendActionResponse(messageId: String, buttonId: String, buttonLabel: String) {
        ws.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
    }

    func handleAction(_ action: ConversationAction) {
        switch action {
        case .newChat:
            guard let store else { return }
            let conv = store.createNew()
            ws.conversationId = conv.id
            ws.sendNewConversation(id: conv.id)
            ws.messages = []

        case .newChatWithContext(let context):
            guard let store else { return }
            let conv = store.createNew()
            ws.conversationId = conv.id
            ws.sendNewConversation(id: conv.id)
            ws.messages = []
            // Small delay so the new conversation is established
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.sendMessage("/context Контекст предыдущего диалога: \(context)")
            }

        case .open(let conversation):
            store?.activeConversationId = conversation.id
            ws.conversationId = conversation.id
            ws.reloadActiveConversation()
        }
    }

    /// Open a conversation by id (used by proactive-push deep-link).
    func openConversation(id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        store?.activeConversationId = uuid
        ws.conversationId = uuid
        ws.reloadActiveConversation()
    }

    // MARK: – Wiring

    private func wireUp() {
        // With @Observable, nested objects are tracked automatically —
        // no manual objectWillChange forwarding needed.

        // Set initial conversation
        ws.conversationId = store?.activeConversationId
        ws.reloadActiveConversation()

        // Forward haptic callback when a message arrives from assistant
        ws.onAssistantMessage = { [weak self] in
            self?.onMessageReceived?()
            guard let self else { return }
            // Bump conversation row's last_message_at so the drawer floats the
            // chat up; the inbound message body is already persisted in GRDB
            // by `WebSocketClientV2.restartObservation`.
            if let store = self.store, let cid = self.ws.conversationId {
                store.recordIncoming(conversationId: cid)
            }
            // Push to watch — gated by user setting
            if self.settings.watchCompanionEnabled,
               let last = self.ws.messages.last,
               last.role == .assistant,
               !last.text.isEmpty {
                self.watchBridge.pushAssistantMessage(id: last.id, text: last.text, timestamp: last.timestamp)
            }
        }

        // Agent pulls device context — gather requested fields on demand.
        ws.onContextRequest = { [weak self] fields in
            guard let self else { return [:] }
            // Kick a refresh so the next pull is fresher; respond with current snapshot.
            if settings.useLocation { self.location.requestAndUpdate() }
            if settings.useHealth   { self.health.requestAndFetch()    }
            if settings.useCalendar { self.calendar.requestAndFetch()  }
            return ContextBuilder.build(
                fields: fields,
                settings: self.settings,
                location: self.location,
                health: self.health,
                calendar: self.calendar
            )
        }

        // Auto-speak assistant text only when the triggering message was dictated
        ws.onSpeakableText = { [weak self] text in
            guard let self, self.settings.autoSpeak, self.lastSendWasVoice else { return }
            self.speech.speak(text, voiceId: self.settings.voiceId, rate: self.settings.voiceRate, pitch: self.settings.voicePitch)
        }

        // Track connection state via callback (replaces Combine $isConnected sink)
        ws.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            if connected {
                self.connectionPhase = .connected
            } else if self.connectionPhase == .connecting || self.connectionPhase == .connected {
                self.connectionPhase = .failed
            }
        }
    }
}
