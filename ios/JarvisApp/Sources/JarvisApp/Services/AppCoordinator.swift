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
    /// Plays server-rendered voice-note audio attachments.
    private(set) var audioPlayer: AudioPlaybackService
    private(set) var proactiveDispatcher: ProactiveDispatcher!
    private(set) var watchBridge: WatchConnectivityBridge!

    /// Combine hub for inbound workout envelopes. WorkoutView / SwapSheet /
    /// ChatView subscribe via `.onReceive(coordinator.workoutBus.events)`.
    @ObservationIgnored let workoutBus = WorkoutInboundBus()

    /// Shared disk-backed image cache. Inbound dispatcher writes blobs into
    /// it; views read paths from it. `imageRequestSender` round-trips through
    /// the v2 transport so misses turn into `image_request` envelopes.
    @ObservationIgnored private(set) var imageCache: ExerciseImageCache!

    /// Fetches by-reference (`image_ready`) image bytes over HTTP into
    /// `imageCache`, off the main thread. See `ImageFetcher`.
    @ObservationIgnored private(set) var imageFetcher: ImageFetcher!

    /// Held so the one-shot cache prewarm can run in `startBackgroundPrep()`
    /// (after the splash appears) rather than at init (before any UI).
    @ObservationIgnored private var chatStore: ConversationStoreV2?
    @ObservationIgnored private var didStartPrep = false

    // MARK: – Connection state
    var connectionPhase: ConnectionPhase = .idle

    enum ConnectionPhase: Equatable {
        case idle
        case connecting
        case connected
        case failed
    }

    // MARK: – Deep-link nav intents
    /// Set by a tapped notification (via the AppDelegate hooks) and consumed by
    /// the view layer: `ContentView` applies the chat intent (once connected),
    /// `OrbHomeView` applies the board intent. Cleared by the consumer after
    /// applying so a re-render doesn't re-navigate.
    var pendingOpenSummaryBoard = false
    var pendingOpenAgentChat: AgentIdentity?

    func requestOpenSummaryBoard() { pendingOpenSummaryBoard = true }
    func requestOpenAgentChat(_ agent: AgentIdentity) { pendingOpenAgentChat = agent }

    @ObservationIgnored private var settings: AppSettings
    /// Whether the last sent message was dictated — gates auto-speak of the reply.
    @ObservationIgnored private var lastSendWasVoice = false
    /// Whether the last send asked the server to render a voice note. When true,
    /// the Jarvis voice arrives asynchronously as a separate `.audio` message —
    /// so on-device Apple TTS must NOT fire for that reply (it would double up
    /// with, or pre-empt, the server voice). Read by OrbVoiceView too.
    @ObservationIgnored private(set) var lastSendWantedServerVoice = false

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
        self.audioPlayer = AudioPlaybackService()
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
            self.chatStore = storage.store   // prewarmed in startBackgroundPrep (post-splash)
            // Wire the dedup store into the shared notifier. Runs on every
            // launch (foreground or BGTask-driven background), so the pull path
            // has a configured notifier during background wakes too.
            LocalNotifier.shared.configure(store: storage.store)
            NotificationReplySender.shared.configure(store: storage.store)
        }
        self.ws = WebSocketClientV2(
            location: location,
            health: health,
            calendar: calendar,
            storage: storage.map { ($0.dbq, $0.store) }
        )
        // Build the shared image cache after `ws` is set so the request sender
        // can read the lazily-built transport once it exists.
        let imageCache = ExerciseImageCache(
            baseURL: ExerciseImageCache.defaultBaseURL(),
            imageRequestSender: { [weak self] slug in
                Task { @MainActor [weak self] in
                    guard let stack = self?.ws.stack else { return }
                    try? await stack.transport.sendImageRequest(slug: slug)
                }
            }
        )
        self.imageCache = imageCache
        // Fetches by-reference (`image_ready`) image bytes over HTTP, off-main,
        // into the same cache — keeping multi-MB base64 off the realtime stream.
        self.imageFetcher = ImageFetcher(
            cache: imageCache,
            onFetched: { [weak self] slug in
                Task { @MainActor [weak self] in
                    self?.workoutBus.events.send(.imageReceived(slug: slug))
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

        // Wire the dispatcher (cheap). Heavy prep — health observers, calendar
        // fetch, location monitoring, cache prewarm — is deferred to
        // `startBackgroundPrep()`, run from the splash's onAppear so nothing
        // fires before the loading screen.
        location.attachDispatcher(proactiveDispatcher)

        AppDelegate.dispatchProactive = { [weak self] type, payload in
            Task { @MainActor in
                self?.proactiveDispatcher?.fire(type: type, payload: payload)
            }
        }

        // Deep-link nav: a tapped notification routes here via static hooks.
        // Set the nav-intent flags on the main actor; the view layer applies them.
        AppDelegate.openSummaryBoard = { [weak self] in
            Task { @MainActor in self?.requestOpenSummaryBoard() }
        }
        AppDelegate.openAgentChat = { [weak self] agent in
            Task { @MainActor in self?.requestOpenAgentChat(agent) }
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

    /// Heavy startup prep — health observers, calendar fetch, location
    /// monitoring, chat-cache prewarm. Called from the splash's `onAppear` so it
    /// runs WHILE the loading animation spins, never before the screen shows.
    /// Idempotent.
    func startBackgroundPrep() {
        guard !didStartPrep else { return }
        didStartPrep = true
        location.startSignificantLocationMonitoring()
        health.installObservers(dispatcher: proactiveDispatcher)
        calendar.proactiveEnabled = settings.proactiveCalendarWarn
        Task { await calendar.fetchAndScheduleProactive() }
        if let chatStore { ChatPrewarmer.warmAll(store: chatStore) }
    }

    // MARK: – Chat actions

    /// - Parameters:
    ///   - viaVoice: true when the message was dictated (sets `lastSendWasVoice`).
    ///   - forceVoice: true when the caller always wants a server voice reply regardless
    ///     of `autoSpeak` (e.g. Orb fullscreen mode). Dictation without `autoSpeak` should
    ///     NOT produce a voice note; Orb fullscreen always should.
    func sendMessage(_ text: String, viaVoice: Bool = false, forceVoice: Bool = false, attachments: [DraftAttachment] = [], agentId: String = "jarvis") {
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
        // Request server-side TTS when: Orb fullscreen forces it (forceVoice=true),
        // OR when the user has autoSpeak enabled AND the message was dictated.
        // Pure dictation with autoSpeak OFF does NOT produce a server voice note.
        // Voice-only mode forces a server voice reply for every send (typed or
        // dictated). Otherwise the orb / autoSpeak path decides as before.
        let voiceOnly = settings.voiceOnlyMode
        let wantVoiceReply = voiceOnly || forceVoice || (settings.autoSpeak && lastSendWasVoice)
        lastSendWantedServerVoice = wantVoiceReply
        ws.send(
            text: text,
            timezone: TimeZone.current.identifier,
            status: emoji.isEmpty ? nil : emoji,
            attachments: attachments,
            context: ctx,
            agentId: agentId,
            respondByVoice: wantVoiceReply,
            voiceOnly: voiceOnly
        )
    }

    func sendFeedback(messageId: String, value: Bool, messageText: String) {
        ws.sendFeedback(messageId: messageId, value: value, messageText: messageText)
    }

    func sendActionResponse(messageId: String, buttonId: String, buttonLabel: String) {
        ws.sendActionResponse(messageId: messageId, buttonId: buttonId, buttonLabel: buttonLabel)
    }

    /// Persist the user's answer to an inbound action card so the rendered card
    /// stays resolved after reload. Forwards to the GRDB store; no-op if the
    /// store isn't built yet.
    func markActionAnswered(rowId: String, choice: String) {
        try? chatStore?.markActionAnswered(rowId: rowId, choice: choice)
    }

    /// Resolve the workout card for `workoutId` (grey its button) when the
    /// workout finishes — matched by workout_id, not the card's row id, so it
    /// survives a mid-workout swap dropping the runner presentation's
    /// messageId. No-op if the store isn't built.
    func markWorkoutCardDone(workoutId: String) {
        _ = try? chatStore?.markWorkoutCardDone(workoutId: workoutId)
    }

    /// Persist an inbound workout plan as a chat card. No-op if the store isn't
    /// built yet. (Plan also pre-fetched into the image cache by the caller.)
    /// `rowId` is the envelope id — unique per send, stable across retries — so
    /// two workouts on the same calendar day don't collide (Payne's workout_id
    /// is a DATE, and the store INSERTs OR IGNOREs on the row id).
    func insertWorkoutPlan(_ plan: WorkoutPlan, rowId: String) {
        // [delivery] trace + surface the two silent drop modes (store not built /
        // insert throws). This is the device-side proof the card row was actually
        // persisted — pair with `[delivery] recv` above and the host's push/ack.
        guard let chatStore else {
            Log.warn(.ws, "[delivery] inserted-workout SKIPPED id=\(rowId) — chatStore nil")
            return
        }
        do {
            try chatStore.insertWorkoutPlan(id: rowId, agentId: "payne", plan: plan)
            Log.info(.ws, "[delivery] inserted-workout id=\(rowId) ex=\(plan.exercises.count)")
        } catch {
            Log.warn(.ws, "[delivery] inserted-workout FAILED id=\(rowId): \(error)")
        }
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

        // Server-rendered audio: play the voice note directly.
        ws.onAudioMessage = { [weak self] base64 in
            guard let self, let data = Data(base64Encoded: base64) else { return }
            self.audioPlayer.play(data: data)
        }

        // On-device Apple TTS is a FALLBACK ONLY — voice is rendered server-side
        // (the cloned Jarvis voice) and arrives as a separate `.audio` message
        // handled by onAudioMessage above. Suppress local TTS whenever the send
        // requested a server voice note (`lastSendWantedServerVoice`), otherwise
        // the phone would speak the text in the system voice before / alongside
        // the real Jarvis voice. With the current gate this means local TTS never
        // fires for a voice-requested reply; the kept branch is a safety net for
        // any future path that speaks without requesting a server voice.
        ws.onSpeakableText = { [weak self] text in
            guard let self, self.settings.autoSpeak, self.lastSendWasVoice,
                  !self.lastSendWantedServerVoice else { return }
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
                insertWorkoutPlan(plan, rowId: env.id)
                // Let an open WorkoutPreviewView refresh in place (e.g. after a
                // swap, Payne re-sends the updated plan with the same workoutId).
                workoutBus.events.send(.planReceived(plan))
            } catch {
                Log.warn(.ws, "workout_plan decode failed: \(error)")
            }

        case .imageBlob(let b):
            // Legacy inline path — kept for backward compatibility while the
            // host rolls out by-reference delivery (an old host, or one that
            // hasn't seen our `image_ref` capability yet, still sends blobs).
            do {
                try imageCache.write(slug: b.slug, sha256: b.sha256, base64: b.base64)
                // Let an open swap sheet refresh its alternative thumbnails.
                workoutBus.events.send(.imageReceived(slug: b.slug))
            } catch {
                Log.warn(.ws, "image_blob write failed for slug=\(b.slug): \(error)")
            }

        case .imageReady(let r):
            // By-reference path: fetch the bytes over HTTP off-main, then refresh
            // thumbnails (the fetcher fires `.imageReceived` via onFetched).
            Task { [imageFetcher] in
                await imageFetcher?.fetch(slug: r.slug, sha256: r.sha256)
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
    /// blob (which carries day_name / week / week_label / exercises) into
    /// the canonical iOS `WorkoutPlan` shape, then decode.
    static func decodeWorkoutPlan(payload p: V2.WorkoutPlan) throws -> WorkoutPlan {
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
