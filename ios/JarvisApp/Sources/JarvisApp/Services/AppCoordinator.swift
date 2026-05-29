import Foundation

/// Central coordinator that owns all services and wires them together.
/// Views observe this instead of owning services directly.
@Observable @MainActor
final class AppCoordinator {

    // MARK: – Services (owned)
    private(set) var outbox: OutboxStore
    private(set) var ws: WebSocketClient
    private(set) var store: ConversationStore
    private(set) var location: LocationManager
    private(set) var health: HealthManager
    private(set) var calendar: CalendarManager
    private(set) var speech: SpeechSynthesizer
    private(set) var proactiveDispatcher: ProactiveDispatcher!

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
        let outbox = OutboxStore()
        self.outbox = outbox
        self.ws = WebSocketClient(outbox: outbox)
        self.store = ConversationStore()
        self.location = LocationManager()
        self.health = HealthManager()
        self.calendar = CalendarManager()
        self.speech = SpeechSynthesizer()

        let sink = WebSocketProactiveSink(ws: ws, settings: settings)
        self.proactiveDispatcher = ProactiveDispatcher(settings: settings, sink: sink)

        // Wire trigger sources
        location.attachDispatcher(proactiveDispatcher)
        if settings.proactiveGeofence {
            location.startSignificantLocationMonitoring()
        }
        if settings.proactiveHealthHR || settings.proactiveHealthSleep || settings.proactiveHealthWorkout {
            health.installObservers(dispatcher: proactiveDispatcher)
        }

        AppDelegate.dispatchProactive = { [weak self] type, payload in
            Task { @MainActor in
                self?.proactiveDispatcher?.fire(type: type, payload: payload)
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
            let conv = store.createNew()
            ws.conversationId = conv.id
            ws.sendNewConversation(id: conv.id)
            ws.messages = []

        case .newChatWithContext(let context):
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
            store.activeConversationId = conversation.id
            ws.conversationId = conversation.id
            ws.loadMessages(from: store)
        }
    }

    /// Open a conversation by id (used by proactive-push deep-link).
    func openConversation(id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        store.activeConversationId = uuid
        ws.conversationId = uuid
        ws.loadMessages(from: store)
    }

    // MARK: – Wiring

    private func wireUp() {
        // With @Observable, nested objects are tracked automatically —
        // no manual objectWillChange forwarding needed.

        // Set initial conversation
        ws.conversationId = store.activeConversationId
        ws.loadMessages(from: store)

        // Persist messages when they change
        ws.onMessagesChanged = { [weak self] messages in
            guard let self, let cid = self.store.activeConversationId else { return }
            self.store.saveMessages(messages, for: cid)
        }

        // Forward haptic callback when a message arrives from assistant
        ws.onAssistantMessage = { [weak self] in
            self?.onMessageReceived?()
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

        // Persist messages that arrive for a non-active conversation
        ws.onBackgroundMessage = { [weak self] convId, message in
            guard let self else { return }
            var msgs = self.store.loadMessages(for: convId)
            guard !msgs.contains(where: { $0.id == message.id }) else { return }
            msgs.append(message)
            self.store.saveMessages(msgs, for: convId)
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
