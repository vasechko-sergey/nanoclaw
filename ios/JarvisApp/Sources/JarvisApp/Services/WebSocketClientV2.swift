import Foundation
import GRDB
import SwiftUI
import UIKit

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

    /// Current conversation, set by coordinator. Mirrors legacy.
    var conversationId: UUID? {
        didSet { Task { @MainActor in self.restartObservation() } }
    }

    // MARK: - Callbacks (mirror legacy — view consumer wires these)

    @ObservationIgnored var onMessagesChanged: (([ChatMessage]) -> Void)?
    @ObservationIgnored var onAssistantMessage: (() -> Void)?
    @ObservationIgnored var onBackgroundMessage: ((UUID, ChatMessage) -> Void)?
    @ObservationIgnored var onSpeakableText: ((String) -> Void)?
    @ObservationIgnored var onActionResponse: ((String, String, String) -> Void)?
    @ObservationIgnored var onContextRequest: (([String]) -> [String: Any])?
    @ObservationIgnored var onConnectionChanged: ((Bool) -> Void)?
    @ObservationIgnored var onFlushForTesting: (() -> Void)?

    // MARK: - Storage / transport (owned)

    @ObservationIgnored let stack: AppV2Stack
    @ObservationIgnored private var observationCancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var sentReadIds: Set<String> = []

    @ObservationIgnored private static let busyTimeoutSeconds: TimeInterval = 300 // 5 minutes

    // MARK: - Init

    init(stack: AppV2Stack) {
        self.stack = stack
        restartObservation()
    }

    // MARK: - Lifecycle

    /// Production entrypoint. Mirrors the legacy `connect(settings:)` shape
    /// (a single non-async call that hands off async work to a Task) so the
    /// existing `AppCoordinator.connect()` callsite can swap with minimal
    /// surgery. The transport itself is an actor; we just kick off
    /// `connect()` and update `isConnected` from the result.
    func connect(settings: AppSettings) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.stack.transport.connect()
                self.isConnected = true
            } catch {
                Log.warn(.ws, "TransportV2.connect failed: \(error)")
                self.isConnected = false
            }
        }
    }

    /// Symmetric with legacy: stop and drop transient UI state.
    func disconnect() {
        isConnected = false
        isTyping = false
        lastUserSentAt = nil
        lastAssistantAt = nil
        thinkingDetail = nil
        // TransportV2 currently has no explicit close API; the socket close
        // happens when the URLSessionWebSocketTask is torn down. Left as TODO
        // until 5.x grows a teardown path.
    }

    // MARK: - Conversations

    func sendNewConversation(id: UUID) {
        let payload = V2.NewConversation(thread_id: id.uuidString)
        Task { [weak self] in
            await self?.stack.transport.sendControlEnvelope(
                type: .newConversation,
                payload: .newConversation(payload)
            )
        }
    }

    /// API parity with legacy. The store is the source of truth; we just
    /// reset the read-dedup cache and re-derive `messages` for the new
    /// conversation. The `store` parameter is ignored — the legacy
    /// `ConversationStore` is not the v2 source of truth.
    func loadMessages(from store: ConversationStore) {
        sentReadIds.removeAll()
        restartObservation()
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
        context: [String: Any]? = nil
    ) {
        let clientMsgId = UUID().uuidString
        let ts = Date()
        lastUserSentAt = ts

        let inline = makeInlineContext(timezone: timezone, status: status, raw: context)
        let v2Attachments = attachments.compactMap { Self.toV2Attachment($0) }

        let convoString = (conversationId ?? UUID()).uuidString

        do {
            try stack.store.insertOutboundUserMessage(
                conversationId: convoString,
                id: clientMsgId,
                text: text,
                attachments: v2Attachments,
                context: inline
            )
            Task { [weak self] in
                try? await self?.stack.transport.tickDispatcher()
            }
        } catch {
            Log.warn(.ws, "WebSocketClientV2.send failed to enqueue: \(error)")
        }
    }

    func sendFeedback(conversationId: UUID?, messageId: String, value: Bool, messageText: String) {
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

    func sendMessageDelivered(_ messageId: String, conversationId: UUID?) {
        guard isConnected else { return }
        Task { [weak self] in
            await self?.stack.transport.sendStatusEnvelope(type: .delivered, ids: [messageId])
        }
    }

    func sendMessageRead(_ messageId: String, conversationId: UUID?) {
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

    func sendActionResponse(messageId: String, buttonId: String, buttonLabel: String) {
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
            onMessagesChanged?(messages)
        }
        _ = buttonLabel
    }

    // MARK: - Observation

    /// Re-subscribe `messages` to the v2 store, filtered to the current
    /// conversation. Called on init and whenever `conversationId` changes.
    private func restartObservation() {
        observationCancellable?.cancel()
        observationCancellable = nil

        guard let cid = conversationId else {
            messages = []
            return
        }
        let cidString = cid.uuidString

        let observation = ValueObservation.tracking { db -> [StoredMessage] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM messages
                WHERE conversation_id=?
                ORDER BY ts ASC
            """, arguments: [cidString])
            return rows.map { row in
                StoredMessage(
                    id: row["id"],
                    conversationId: row["conversation_id"],
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

        observationCancellable = observation.start(
            in: stack.dbq,
            scheduling: .async(onQueue: .main),
            onError: { error in
                Log.warn(.ws, "WebSocketClientV2 ValueObservation error: \(error)")
            },
            onChange: { [weak self] rows in
                guard let self else { return }
                let mapped = rows.map(Self.toChatMessage)
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
                self.onMessagesChanged?(mapped)
            }
        )
    }

    // MARK: - Mapping

    private static func toChatMessage(_ row: StoredMessage) -> ChatMessage {
        let timestamp = Date(timeIntervalSince1970: TimeInterval(row.ts) / 1000)
        let role: ChatMessage.Role = row.dir == .out ? .user : .assistant

        // Decode first attachment for image rendering (basic — file/text
        // mixed payloads not supported in 5.2b; views can use .text for
        // those).
        if let attJSON = row.attachmentsJSON,
           let data = attJSON.data(using: .utf8),
           let atts = try? JSONDecoder().decode([V2.Attachment].self, from: data),
           let first = atts.first {
            if first.kind == "image",
               let b64 = first.bytes_base64,
               let imgData = Data(base64Encoded: b64),
               let image = UIImage(data: imgData) {
                var msg = ChatMessage.image(row.id, role: role, image: image, filename: first.name, timestamp: timestamp)
                msg.deliveryStatus = mapDelivery(row.status)
                return msg
            }
            let info = FileInfo(name: first.name, size: Int64(first.byte_size),
                                mimeType: first.mime_type, url: nil, thumbnail: nil)
            var msg = ChatMessage.file(row.id, role: role, info: info, timestamp: timestamp)
            msg.deliveryStatus = mapDelivery(row.status)
            return msg
        }

        var msg = ChatMessage.text(row.id, role: role, text: row.text, timestamp: timestamp)
        msg.deliveryStatus = mapDelivery(row.status)
        return msg
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

    private func makeInlineContext(timezone: String, status: String?, raw: [String: Any]?) -> V2.InlineContext? {
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
            locality: locality
        )
    }

    // MARK: - Test seams

    /// Force a synchronous re-derive of `messages` (used by tests that don't
    /// want to wait for the async ValueObservation tick).
    @MainActor
    func refreshMessagesForTesting() {
        guard let cid = conversationId else {
            messages = []
            return
        }
        let cidString = cid.uuidString
        do {
            let rows = try stack.dbq.read { db -> [StoredMessage] in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM messages
                    WHERE conversation_id=?
                    ORDER BY ts ASC
                """, arguments: [cidString]).map { row in
                    StoredMessage(
                        id: row["id"],
                        conversationId: row["conversation_id"],
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
            messages = rows.map(Self.toChatMessage)
        } catch {
            Log.warn(.ws, "refreshMessagesForTesting read failed: \(error)")
        }
    }
}
