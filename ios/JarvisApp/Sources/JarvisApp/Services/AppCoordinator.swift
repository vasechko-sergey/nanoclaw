import Foundation
import GRDB

/// Central coordinator that owns all services and wires them together.
/// Views observe this instead of owning services directly.
@Observable @MainActor
final class AppCoordinator {

    // MARK: – Services (owned)
    private(set) var ws: WebSocketClientV2
    /// `@Observable` UI wrapper over the GRDB-backed `ConversationStoreV2`.
    /// Single source of truth for the chat timeline. Optional because the
    /// storage half of the v2 stack is built best-effort at init time — if
    /// the DB can't be opened (rare), the app still runs but the timeline
    /// stays empty. All view sites that read `coordinator.timeline` handle
    /// the nil case by rendering empty state.
    private(set) var timeline: MessageTimeline!
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
        let storage: (dbq: GRDB.DatabaseQueue, store: ConversationStoreV2, timeline: MessageTimeline)?
        do {
            storage = try AppV2Bootstrap.buildStorage()
        } catch {
            Log.warn(.ws, "AppCoordinator buildStorage failed: \(error)")
            storage = nil
        }
        if let storage {
            self.timeline = storage.timeline
        }
        self.ws = WebSocketClientV2(
            location: location,
            health: health,
            calendar: calendar,
            storage: storage.map { ($0.dbq, $0.store) }
        )
        if storage != nil {
            Task { @MainActor [weak self] in
                try? await self?.timeline.start()
            }
        }

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
        // `timeline` observation was started at init time — no post-connect
        // backfill needed; views already see the GRDB-backed message stream.
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
        ws.sendFeedback(messageId: messageId, value: value, messageText: messageText)
    }

    func sendActionResponse(messageId: String, buttonId: String, buttonLabel: String) {
        ws.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
    }

    // MARK: – Wiring

    private func wireUp() {
        // With @Observable, nested objects are tracked automatically —
        // no manual objectWillChange forwarding needed.

        // Forward haptic callback when a message arrives from assistant
        ws.onAssistantMessage = { [weak self] in
            self?.onMessageReceived?()
            guard let self else { return }
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
