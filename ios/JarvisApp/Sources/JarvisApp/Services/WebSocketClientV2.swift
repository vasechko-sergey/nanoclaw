import Foundation
import GRDB
import ImageIO
import SwiftUI
import UIKit

/// Slash-command suggestion displayed in `UnifiedInputBar`. Used to populate
/// `WebSocketClientV2.commands` on `auth_ok` — currently unset under v2 since
/// the new protocol's `auth_ok` envelope doesn't carry a commands list. Kept
/// here for view-binding parity until the host re-introduces them.
struct BotCommand: Equatable {
    let command: String
    let description: String
}

// MARK: - WebSocketClientV2
//
// API-parity facade over the v2 transport stack. Mirrors the observable
// surface of `WebSocketClient` (legacy) so SwiftUI views can swap with a
// single property-type change in `AppCoordinator`. Internally drives
// `TransportV2` + `ConversationStoreV2`:
//
//   - `messages` is rebuilt from a GRDB `ValueObservation` over the active
//     conversation. The store is the source of truth; the array is purely a
//     reactive view of it.
//   - `send(text:...)` writes a queued outbound row through the store and
//     pings the transport's dispatcher. The row's status field flows back
//     through the observation: queued → sending → sent → delivered → read.
//   - One-shot control envelopes (`new_conversation`, `feedback`,
//     `action_response`) go straight to the transport via the new
//     `sendControlEnvelope` helper. They do not write to the store.
//   - Status reads / delivered receipts go to the transport via the new
//     `sendStatusEnvelope` helper. We do NOT roundtrip them through the
//     store on the outbound path — that would loop with the inbound-status
//     handler. Sentinel dedup for `sendMessageRead` is kept (same as legacy)
//     so view-level scroll churn doesn't spam the wire.
//
// Conscious gaps vs legacy (see `WebSocketClient.swift`):
//   * No `isTyping` / `thinkingDetail` — the v2 protocol no longer carries a
//     typing signal in the transport layer. `isBusy` falls back to the
//     sent-vs-replied heuristic only.
//   * No `OutboxStore` / `flushOutbox()` / `retrySend(id:)` — the store +
//     dispatcher own queuing + retry. Manual retry would require a store API
//     that resets a failed row back to `queued`; out of scope for 5.2b.
//   * No `commands` population from `auth_ok` (v2 auth_ok doesn't carry them).
//     Property remains for view binding parity; stays empty.
//   * No `sendProactive` (v2 transport's contract for proactive triggers is
//     not yet specified — left as TODO).
//   * No `sendContextResponse` — the v2 protocol routes context replies
//     through `InboundDispatcherV2` + `AppContextCoordinator`. The facade
//     does not own that path.
@Observable @MainActor
final class WebSocketClientV2 {

    // MARK: - Observable surface (mirrors legacy)

    var messages: [ChatMessage] = []
    var isConnected = false { didSet { if isConnected != oldValue { onConnectionChanged?(isConnected) } } }
    var isTyping = false
    var commands: [BotCommand] = []
    var lastUserSentAt: Date? = nil
    var lastAssistantAt: Date? = nil
    var thinkingDetail: String? = nil

    /// Persistent "agent is busy" — derived state.
    /// True if: user sent < 5min ago and no later assistant reply.
    /// (No typing signal in v2, so `isTyping` is permanently false here.)
    var isBusy: Bool {
        if isTyping { return true }
        guard let sent = lastUserSentAt else { return false }
        if let got = lastAssistantAt, got >= sent { return false }
        return Date().timeIntervalSince(sent) < Self.busyTimeoutSeconds
    }

    // MARK: - Callbacks (mirror legacy — view consumer wires these)

    @ObservationIgnored var onAssistantMessage: (() -> Void)?
    @ObservationIgnored var onSpeakableText: ((String) -> Void)?
    @ObservationIgnored var onActionResponse: ((String, String, String) -> Void)?
    @ObservationIgnored var onContextRequest: (([String]) -> [String: Any])?
    @ObservationIgnored var onConnectionChanged: ((Bool) -> Void)?
    @ObservationIgnored var onFlushForTesting: (() -> Void)?

    /// Inbound workout-family envelope (`workout_plan`, `image_blob`,
    /// `coach_message`, `exercise_swap_options`, `program_update`).
    /// AppCoordinator subscribes to translate raw payloads into typed
    /// `WorkoutInboundEvent`s on `workoutBus`.
    @ObservationIgnored var onWorkoutEnvelope: ((V2.Envelope) -> Void)?

    // MARK: - Storage / transport (owned)

    /// Production callsites build the stack lazily on first `connect(settings:)`
    /// because the URL/token isn't known at coordinator-init time. Tests inject
    /// a fully-built stack via the `init(stack:)` overload.
    @ObservationIgnored private(set) var stack: AppV2Stack!
    @ObservationIgnored private var observationCancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var sentReadIds: Set<String> = []

    /// Production managers — captured so we can build the stack on first connect.
    @ObservationIgnored private weak var location: LocationManager?
    @ObservationIgnored private weak var health: HealthManager?
    @ObservationIgnored private weak var calendar: CalendarManager?

    /// Pre-built storage (DB queue + ConversationStoreV2) handed to the
    /// transport when `connect(settings:)` finally has a URL/token. The
    /// coordinator builds this at init time so the chat view can render
    /// from the GRDB-backed `MessageTimeline` before the user has configured
    /// the server.
    @ObservationIgnored private var preBuiltStorage: (dbq: GRDB.DatabaseQueue, store: ConversationStoreV2)?

    @ObservationIgnored private static let busyTimeoutSeconds: TimeInterval = 300 // 5 minutes

    // MARK: - Init

    /// Test init — stack already constructed.
    init(stack: AppV2Stack) {
        self.stack = stack
        restartObservation()
        wireAuthOkCallback()
    }

    /// Production init — stack is built lazily on the first `connect(settings:)`
    /// call, since the URL and token live in `AppSettings` and are only known at
    /// that point. The managers are captured so the eventual stack carries them
    /// into the `AppContextCoordinator`.
    init(
        location: LocationManager? = nil,
        health: HealthManager? = nil,
        calendar: CalendarManager? = nil,
        storage: (dbq: GRDB.DatabaseQueue, store: ConversationStoreV2)? = nil
    ) {
        self.stack = nil
        self.location = location
        self.health = health
        self.calendar = calendar
        self.preBuiltStorage = storage
    }

    // MARK: - Lifecycle

    /// Production entrypoint. Mirrors the legacy `connect(settings:)` shape
    /// (a single non-async call that hands off async work to a Task) so the
    /// existing `AppCoordinator.connect()` callsite can swap with minimal
    /// surgery. The transport itself is an actor; we just kick off
    /// `connect()` and update `isConnected` from the result.
    ///
    /// On first call (production path) the v2 stack is built lazily from the
    /// supplied settings — `AppCoordinator` constructs `WebSocketClientV2`
    /// without knowing the URL/token. Subsequent calls reuse the existing stack.
    func connect(settings: AppSettings) {
        if stack == nil {
            guard let url = Self.resolveWebSocketURL(settings: settings) else {
                Log.warn(.ws, "WebSocketClientV2.connect: no valid URL in settings")
                return
            }
            do {
                let built: AppV2Stack
                if let storage = preBuiltStorage {
                    built = AppV2Bootstrap.build(
                        serverURL: url,
                        token: settings.bearerToken,
                        storage: storage,
                        location: location,
                        health: health,
                        calendar: calendar
                    )
                } else {
                    built = try AppV2Bootstrap.build(
                        serverURL: url,
                        token: settings.bearerToken,
                        location: location,
                        health: health,
                        calendar: calendar
                    )
                }
                self.stack = built
                restartObservation()
                wireAuthOkCallback()
            } catch {
                Log.warn(.ws, "AppV2Bootstrap.build failed: \(error)")
                return
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.stack.transport.connect()
                self.isConnected = true
            } catch {
                Log.warn(.ws, "TransportV2.connect failed: \(error)")
                // UI testing: there's no mock WS server running, so the real
                // connect always fails. Force isConnected=true so the input
                // bar (gated on `ws.isConnected`) is hit-testable in tests
                // that exercise send flows. Production behavior is unchanged.
                self.isConnected = JarvisApp.isUITesting
            }
        }
    }

    /// Normalise `AppSettings.serverURL` (which is a free-form `host:port` /
    /// `http://…` / `wss://…` string) into a `URL` with a ws(s) scheme. Mirrors
    /// the URL-massaging the legacy `WSTransport.doConnect` did.
    private static func resolveWebSocketURL(settings: AppSettings) -> URL? {
        let raw: String
        if JarvisApp.isUITesting {
            raw = "ws://127.0.0.1:8765"
        } else {
            raw = settings.serverURL.trimmingCharacters(in: .whitespaces)
        }
        guard !raw.isEmpty else { return nil }
        var s = raw
        if      s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://")  { s = "ws://"  + s.dropFirst(7) }
        else if !s.hasPrefix("ws")      { s = "ws://"  + s }
        return URL(string: s)
    }

    /// Symmetric with legacy: stop and drop transient UI state.
    func disconnect() {
        isConnected = false
        isTyping = false
        lastUserSentAt = nil
        lastAssistantAt = nil
        thinkingDetail = nil
        sentReadIds.removeAll()
        // Tear down the transport: cancel the reconnect loop + all in-flight
        // ack-retry tasks and close the socket. Previously a no-op, which left
        // the reconnect/ping/retry churn running for the whole process life.
        Task { [weak self] in await self?.stack?.transport.disconnect() }
    }

    // MARK: - Send methods

    /// Mirrors legacy `send(text:timezone:status:attachments:context:)`. The
    /// `timezone` + `status` legacy args are folded into a v2 `InlineContext`
    /// (with whatever the caller already gathered) so the wire shape ends up
    /// the same.
    ///
    /// Legacy returned synchronously and queued the wire push. The v2 store
    /// writes happen synchronously on the calling thread (GRDB writer); the
    /// dispatcher tick is best-effort and the row stays `queued` until the
    /// transport is authed.
    func send(
        text: String,
        timezone: String,
        status: String?,
        attachments: [DraftAttachment] = [],
        context: [String: Any]? = nil,
        agentId: String = "jarvis",
        respondByVoice: Bool = false
    ) {
        guard stack != nil else {
            Log.warn(.ws, "WebSocketClientV2.send: stack not built yet")
            return
        }
        let clientMsgId = UUID().uuidString
        let ts = Date()
        lastUserSentAt = ts

        let inline = makeInlineContext(timezone: timezone, status: status, raw: context,
                                       respondByVoice: respondByVoice ? true : nil)
        let v2Attachments = attachments.compactMap { Self.toV2Attachment($0) }

        do {
            try stack.store.insertOutboundUserMessage(
                id: clientMsgId,
                text: text,
                attachments: v2Attachments,
                context: inline,
                agentId: agentId
            )
            try? stack.store.prune() // global retention; cheap no-op under cap
            Task { [weak self] in
                try? await self?.stack.transport.tickDispatcher()
            }
        } catch {
            Log.warn(.ws, "WebSocketClientV2.send failed to enqueue: \(error)")
        }
    }

    func sendFeedback(messageId: String, value: Bool, messageText: String) {
        guard stack != nil else { return }
        let kind = value ? "up" : "down"
        Task { [weak self] in
            await self?.stack.transport.sendControlEnvelope(
                type: .feedback,
                payload: .feedback(V2.Feedback(message_id: messageId, kind: kind))
            )
        }
        _ = messageText // legacy carries the quoted text inline; v2 server reads it from history
    }

    /// V2 routes context replies through `InboundDispatcherV2`, not the
    /// outbound surface. The facade keeps the method signature for callsite
    /// parity, but it's a no-op here. TODO(5.x): wire to the dispatcher if a
    /// non-router caller ever needs to push a context_response.
    func sendContextResponse(requestId: String, context: [String: Any]) {
        _ = requestId
        _ = context
    }

    func sendMessageDelivered(_ messageId: String) {
        guard stack != nil, isConnected else { return }
        Task { [weak self] in
            await self?.stack.transport.sendStatusEnvelope(type: .delivered, ids: [messageId])
        }
    }

    func sendMessageRead(_ messageId: String) {
        guard stack != nil else { return }
        guard sentReadIds.insert(messageId).inserted else { return }
        guard isConnected else {
            sentReadIds.remove(messageId)
            return
        }
        Task { [weak self] in
            await self?.stack.transport.sendStatusEnvelope(type: .read, ids: [messageId])
        }
    }

    /// Stub for legacy parity. V2's proactive surface is TBD — see header
    /// note. Returns false so the legacy caller falls back to its HTTP path.
    @discardableResult
    func sendProactive(triggerType: String, payload: [String: Any]) -> Bool {
        _ = triggerType
        _ = payload
        return false
    }

    /// Manual retry of a failed outbound row. Flips the store row back to
    /// `queued` and nudges the dispatcher so it picks the row up immediately
    /// when authed (otherwise the next `auth_ok` will drain it). Sync facade
    /// over async store + transport work — mirrors `send(text:...)`.
    func retrySend(id: String) {
        guard let stack else {
            Log.warn(.ws, "WebSocketClientV2.retrySend: stack not built yet")
            return
        }
        do {
            try stack.store.resetFailedToQueued(id: id)
        } catch {
            Log.warn(.ws, "WebSocketClientV2.retrySend store reset failed: \(error)")
            return
        }
        Task { [weak self] in
            try? await self?.stack.transport.tickDispatcher()
        }
    }

    /// Called by `JarvisApp` on scene-phase transitions. On `.active` we nudge
    /// the dispatcher to flush anything that queued up while backgrounded. The
    /// transport handles its own reconnect on socket-close, so there's no
    /// equivalent to the legacy `handleBecameActive` URL-task lifecycle here.
    func handleScenePhase(_ phase: ScenePhase) {
        guard stack != nil else { return }
        switch phase {
        case .active:
            Task { [weak self] in
                try? await self?.stack.transport.tickDispatcher()
            }
        case .background, .inactive:
            break
        @unknown default:
            break
        }
    }

    func sendActionResponse(messageId: String, buttonId: String, buttonLabel: String) {
        guard stack != nil else { return }
        let payload = V2.ActionResponse(action_id: messageId, choice: buttonId)
        Task { [weak self] in
            await self?.stack.transport.sendControlEnvelope(
                type: .actionResponse,
                payload: .actionResponse(payload)
            )
        }

        // Mark action as answered locally so the UI updates immediately.
        // (The store-backed observation will reconcile on the next refresh.)
        if let idx = messages.firstIndex(where: { $0.id == messageId }),
           case .action(var info) = messages[idx].content {
            info.answered = true
            info.selectedId = buttonId
            messages[idx] = ChatMessage(id: messageId, role: messages[idx].role,
                                        content: .action(info), timestamp: messages[idx].timestamp)
        }
        _ = buttonLabel
    }

    // MARK: - Observation

    /// Re-subscribe `messages` to the v2 store's single timeline. Called on
    /// init and after the stack is built lazily on first `connect(settings:)`.
    private func restartObservation() {
        observationCancellable?.cancel()
        observationCancellable = nil

        // Stack hasn't been built yet (production: pre-`connect`).
        guard let stack else {
            messages = []
            return
        }

        // T10: subscribe to ALL agents' rows; ChatView filters by active chip.
        let observation = stack.store.observeAllMessages()

        observationCancellable = observation.start(
            in: stack.dbq,
            scheduling: .async(onQueue: .main),
            onError: { error in
                Log.warn(.ws, "WebSocketClientV2 ValueObservation error: \(error)")
            },
            onChange: { [weak self] rows in
                guard let self else { return }
                let mapped = rows.flatMap(Self.toChatMessage)
                // Detect new assistant arrivals for haptic + auto-speak hooks.
                let oldIds = Set(self.messages.map { $0.id })
                let newAssistant = mapped.filter {
                    $0.role == .assistant && !oldIds.contains($0.id)
                }
                self.messages = mapped
                if !newAssistant.isEmpty {
                    // Use wall-clock instead of the row's stored ts so the
                    // `lastAssistantAt >= lastUserSentAt` comparison in
                    // `isBusy` isn't tripped by millisecond truncation when
                    // send + inbound land in the same millisecond.
                    self.lastAssistantAt = Date()
                }
                for msg in newAssistant {
                    self.onAssistantMessage?()
                    if case .text(let t) = msg.content, !t.isEmpty {
                        self.onSpeakableText?(t)
                    }
                }
            }
        )
    }

    // MARK: - Mapping

    /// Bounded cache of decoded + downsampled chat images, keyed by row id.
    /// Stops the ValueObservation from re-decoding the whole image history on
    /// every insert and caps retained bitmap memory.
    private static let imageCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        return c
    }()

    /// Decode `base64` into a UIImage downsampled to ~720px on the longest edge
    /// (chat bubbles render at ~240pt — full-res photos are pointless and cost
    /// ~48MB each decoded). Result cached by `rowId` so repeated observation
    /// rebuilds reuse the bitmap instead of re-decoding on the main thread.
    private static func cachedDownsampledImage(rowId: String, base64: String) -> UIImage? {
        let key = rowId as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let data = Data(base64Encoded: base64) else { return nil }
        let maxPixel: CGFloat = 720
        let img: UIImage?
        if let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixel,
           ] as CFDictionary) {
            img = UIImage(cgImage: cg)
        } else {
            img = UIImage(data: data)
        }
        if let img { imageCache.setObject(img, forKey: key) }
        return img
    }

    // A single stored row may carry BOTH a text caption and an attachment
    // (e.g. "Держи выписку" + Statement.pdf). The ChatMessage.Content enum holds
    // only one of those, so such a row maps to TWO bubbles: the caption first,
    // then the attachment. Returning an array (flat-mapped at the call sites)
    // keeps the typed text visible instead of being swallowed by the attachment.
    static func toChatMessage(_ row: StoredMessage) -> [ChatMessage] {
        let timestamp = Date(timeIntervalSince1970: TimeInterval(row.ts) / 1000)
        let role: ChatMessage.Role = row.dir == .out ? .user : .assistant

        if let attJSON = row.attachmentsJSON,
           let data = attJSON.data(using: .utf8),
           let atts = try? JSONDecoder().decode([V2.Attachment].self, from: data),
           let first = atts.first {
            var out: [ChatMessage] = []

            // Caption bubble (if the user/agent typed text alongside the file).
            let caption = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty {
                var t = ChatMessage.text(row.id + "-text", role: role, text: row.text, timestamp: timestamp)
                t.deliveryStatus = mapDelivery(row.status)
                t.agentId = row.agentId
                out.append(t)
            }

            // Attachment bubble keeps the bare `row.id` so delivery-status
            // updates (looked up by the stored row id) still land on it.
            var attMsg: ChatMessage
            // Decode through an id-keyed cache + downsample. Without the cache,
            // the ValueObservation re-decoded EVERY image in the 500-row window
            // on every insert (main-thread JPEG decode storm → hangs); without
            // downsampling each decoded UIImage held its full-res bitmap
            // (~48MB for a 12MP photo → memory jetsam). Row content is immutable
            // for a given id, so caching by row.id is safe.
            if first.kind == "image", let b64 = first.bytes_base64,
               let image = cachedDownsampledImage(rowId: row.id, base64: b64) {
                attMsg = ChatMessage.image(row.id, role: role, image: image, filename: first.name, timestamp: timestamp)
            } else {
                let info = FileInfo(name: first.name, size: Int64(first.byte_size),
                                    mimeType: first.mime_type, url: nil, thumbnail: nil)
                attMsg = ChatMessage.file(row.id, role: role, info: info, timestamp: timestamp)
            }
            attMsg.deliveryStatus = mapDelivery(row.status)
            attMsg.agentId = row.agentId
            out.append(attMsg)
            return out
        }

        var msg = ChatMessage.text(row.id, role: role, text: row.text, timestamp: timestamp)
        msg.deliveryStatus = mapDelivery(row.status)
        msg.agentId = row.agentId
        return [msg]
    }

    private static func mapDelivery(_ s: MessageStatus) -> DeliveryStatus {
        switch s {
        case .queued, .new: return .sending
        case .sending: return .sending
        case .sent: return .sent
        case .delivered: return .delivered
        case .read: return .delivered
        case .failed: return .failed
        }
    }

    private static func toV2Attachment(_ d: DraftAttachment) -> V2.Attachment? {
        return V2.Attachment(
            id: UUID().uuidString,
            kind: d.kind == .image ? "image" : "file",
            name: d.name,
            mime_type: d.mimeType,
            byte_size: d.size,
            bytes_base64: d.data.base64EncodedString(),
            remote_id: nil
        )
    }

    private func makeInlineContext(timezone: String, status: String?, raw: [String: Any]?,
                                   respondByVoice: Bool? = nil) -> V2.InlineContext? {
        // We don't try to round-trip the legacy free-form dict here; the v2
        // protocol has a stricter shape. We only populate timezone +
        // timestamp (always-on) and a coarse locality if the legacy dict
        // carried one. Anything richer comes via `context_request` over the
        // pull surface.
        let now = ISO8601DateFormatter().string(from: Date())
        var locality: String? = nil
        var location: V2.InlineContext.Location? = nil
        if let raw {
            if let loc = raw["location"] as? [String: Any] {
                if let lat = loc["lat"] as? Double, let lon = loc["lon"] as? Double {
                    location = V2.InlineContext.Location(lat: lat, lon: lon, accuracy: loc["accuracy"] as? Double)
                }
                locality = loc["locality"] as? String ?? loc["cityName"] as? String
            }
        }
        _ = status // V2.InlineContext has no `status` field — folded into agent's overall context picture.
        return V2.InlineContext(
            location: location,
            timestamp: now,
            timezone: timezone,
            locality: locality,
            respond_by_voice: respondByVoice
        )
    }

    // MARK: - Auth_ok callback wiring

    /// Subscribe to the transport's `auth_ok` payload stream so we can lift the
    /// (optional) command catalogue onto the `commands` observable. Called from
    /// both init paths once `stack` is non-nil.
    private func wireAuthOkCallback() {
        guard let stack else { return }
        let transport = stack.transport
        let queue = stack.setLogQueue
        Task {
            await transport.setOnAuthOkPayload { [weak self] payload in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.commands = (payload.commands ?? []).map {
                        BotCommand(command: $0.command, description: $0.description)
                    }
                }
                // Drain any persisted set_log events that accumulated while
                // offline. Fire-and-forget — failures are logged inside the
                // transport and retried on the next connect.
                Task {
                    await transport.drainSetLogQueue(queue)
                }
            }
            await transport.setOnWorkoutEnvelope { [weak self] env in
                Task { @MainActor [weak self] in
                    self?.onWorkoutEnvelope?(env)
                }
            }
        }
    }

    // MARK: - Test seams

    /// Force a synchronous re-derive of `messages` (used by tests that don't
    /// want to wait for the async ValueObservation tick).
    @MainActor
    func refreshMessagesForTesting() {
        guard let stack else { messages = []; return }
        do {
            let rows = try stack.dbq.read { db -> [StoredMessage] in
                let rs = try Row.fetchAll(db, sql: """
                    SELECT * FROM messages
                    ORDER BY ts DESC
                    LIMIT 500
                """)
                return rs.reversed().map { row in
                    StoredMessage(
                        id: row["id"],
                        dir: MessageDir(rawValue: row["dir"]) ?? .out,
                        seq: row["seq"],
                        text: row["text"],
                        attachmentsJSON: row["attachments_json"],
                        contextJSON: row["context_json"],
                        status: MessageStatus(rawValue: row["status"]) ?? .queued,
                        failureReason: row["failure_reason"],
                        ts: row["ts"],
                        serverTS: row["server_ts"],
                        createdAt: row["created_at"]
                    )
                }
            }
            messages = rows.flatMap(Self.toChatMessage)
        } catch {
            Log.warn(.ws, "refreshMessagesForTesting read failed: \(error)")
        }
    }
}
