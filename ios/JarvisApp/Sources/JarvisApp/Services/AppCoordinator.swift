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

    /// Combine hub for inbound workout envelopes. WorkoutView / SwapSheet /
    /// ChatView subscribe via `.onReceive(coordinator.workoutBus.events)`.
    @ObservationIgnored let workoutBus = WorkoutInboundBus()

    /// Shared disk-backed image cache. Inbound dispatcher writes blobs into
    /// it; views read paths from it. `imageRequestSender` round-trips through
    /// the v2 transport so misses turn into `image_request` envelopes.
    @ObservationIgnored private(set) var imageCache: ExerciseImageCache!

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
        // Build the storage half of the v2 stack now so the MessageTimeline
        // can start observing before splash/home renders. Transport half is
        // built lazily on first `connect(settings:)` (URL/token aren't known
        // at coordinator-init time). Failure leaves `timeline` nil — views
        // read it as empty state.
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
        // Build the shared image cache after `ws` is set so the request sender
        // can read the lazily-built transport once it exists.
        self.imageCache = ExerciseImageCache(
            baseURL: ExerciseImageCache.defaultBaseURL(),
            imageRequestSender: { [weak self] slug in
                Task { @MainActor [weak self] in
                    guard let stack = self?.ws.stack else { return }
                    try? await stack.transport.sendImageRequest(slug: slug)
                }
            }
        )
        // NOTE: `timeline.start()` is intentionally NOT called. It opened a
        // SECOND full-timeline GRDB ValueObservation (limit 500) on the same DB
        // that no view consumes — ChatView reads `ws.messages`, which has its
        // own observation. The duplicate fired a second 500-row re-fetch +
        // array rebuild on the main thread on every message insert. Pure waste.

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

    func sendMessage(_ text: String, viaVoice: Bool = false, attachments: [DraftAttachment] = [], agentId: String = "jarvis") {
        lastSendWasVoice = viaVoice
        // Push a light inline context snapshot (location/health/calendar per the user's
        // privacy toggles) so the agent always has timezone + location + next event +
        // status in-band. The pull model still works on top: the agent can fire
        // `context_request` for a fresher pull when it needs to.
        let emoji = settings.statusEmoji.trimmingCharacters(in: .whitespaces)
        // Trigger lazy refreshes of the CHEAP cached context fields only — the
        // response from build() uses whatever's currently cached. Health is NOT
        // refreshed per message (expensive HK queries); it's excluded from the
        // default context and fetched only on an explicit request_context pull.
        if settings.useLocation { location.requestAndUpdate() }
        if settings.useCalendar { calendar.requestAndFetch()  }
        let ctx = ContextBuilder.build(
            fields: [],
            settings: settings,
            location: location,
            health: health,
            calendar: calendar
        )
        // Request server-side TTS when: any voice-mode send (Orb fullscreen
        // always sets viaVoice=true) or when the user has autoSpeak enabled
        // for dictated messages. `lastSendWasVoice` == `viaVoice` at this point.
        let wantVoiceReply = lastSendWasVoice
        ws.send(
            text: text,
            timezone: TimeZone.current.identifier,
            status: emoji.isEmpty ? nil : emoji,
            attachments: attachments,
            context: ctx,
            agentId: agentId,
            respondByVoice: wantVoiceReply
        )
    }

    /// Speak arbitrary text on demand (manual "Проговорить" from a bubble).
    func speak(_ text: String) {
        speech.speak(text)
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
        // and no server-rendered audio arrived (audio playback is handled by
        // onAudioMessage; this fallback fires only when audio is absent).
        ws.onSpeakableText = { [weak self] text in
            guard let self, self.settings.autoSpeak, self.lastSendWasVoice else { return }
            self.speech.speak(text)
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

        // Bridge inbound workout-family envelopes to the Combine bus.
        ws.onWorkoutEnvelope = { [weak self] env in
            self?.handleWorkoutEnvelope(env)
        }
    }

    // MARK: – Workout inbound routing (P3.T17)

    /// Translate a raw V2 envelope into a `WorkoutInboundEvent` and publish it
    /// on `workoutBus`. Also runs side effects that can't be done by a passive
    /// subscriber (image prefetch, blob writes — both go through the
    /// shared `imageCache`).
    private func handleWorkoutEnvelope(_ env: V2.Envelope) {
        switch env.payload {
        case .workoutPlan(let p):
            // 1. Eagerly prefetch every image referenced by the plan so by the
            //    time WorkoutView opens, the cache is already filling up.
            let manifest = p.image_manifest.map {
                WorkoutPlan.ImageManifestEntry(slug: $0.slug, sha256: $0.sha256)
            }
            imageCache.prefetch(manifest: manifest)

            // 2. Decode the wire shape (workout_id + image_manifest at envelope
            //    level + plan_json carrying day_name/week/intensity/exercises)
            //    into our top-level `WorkoutPlan` model. We splice the two
            //    halves together in a Dictionary, then run JSONDecoder.
            do {
                let plan = try Self.decodeWorkoutPlan(payload: p)
                workoutBus.events.send(.planReceived(plan))
            } catch {
                Log.warn(.ws, "workout_plan decode failed: \(error)")
            }

        case .imageBlob(let b):
            do {
                try imageCache.write(slug: b.slug, sha256: b.sha256, base64: b.base64)
            } catch {
                Log.warn(.ws, "image_blob write failed for slug=\(b.slug): \(error)")
            }

        case .coachMessage(let c):
            // Surface on the bus so a visible WorkoutView can banner it.
            // Persisting into the chat thread as a regular assistant message
            // is deferred — the chat surface already gets coach guidance via
            // the normal message channel from Payne.
            workoutBus.events.send(.coachMessage(text: c.text, workoutId: c.workout_id))

        case .exerciseSwapOptions(let s):
            let resp = SwapResponse(
                accepted: s.accepted.map { .init(slug: $0.slug) },
                rejected: s.rejected.map { .init(slug: $0.slug, reason: $0.reason) },
                alternatives: s.alternatives.map { .init(slug: $0.slug, why: $0.why) }
            )
            workoutBus.events.send(
                .swapOptions(resp, originalSlug: s.original_slug, workoutId: s.workout_id)
            )

        case .programUpdate:
            // Program lives on Payne side today — iOS just notes the update.
            Log.warn(.ws, "program_update received (no-op on iOS in P3)")
            workoutBus.events.send(.programUpdated)

        default:
            // TransportV2 only forwards workout-family envelopes here, but the
            // switch is exhaustive over `V2.Payload`; everything else is a no-op.
            break
        }
    }

    /// Splice envelope-level workout_id + image_manifest with the plan_json
    /// blob (which carries day_name / week / intensity_label / exercises) into
    /// the canonical iOS `WorkoutPlan` shape, then decode.
    private static func decodeWorkoutPlan(payload p: V2.WorkoutPlan) throws -> WorkoutPlan {
        var wrapper: [String: Any] = [:]
        wrapper["workout_id"] = p.workout_id
        wrapper["image_manifest"] = p.image_manifest.map { [
            "slug": $0.slug,
            "sha256": $0.sha256
        ] }
        if case .object = p.plan_json {
            let planAny = p.plan_json.toAny()
            if let planDict = planAny as? [String: Any] {
                for (k, v) in planDict { wrapper[k] = v }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: wrapper)
        return try JSONDecoder().decode(WorkoutPlan.self, from: data)
    }
}
