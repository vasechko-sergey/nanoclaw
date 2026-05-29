import Foundation
import UIKit
import SwiftUI

// MARK: - Protocol Contract
//
// The full WebSocket + HTTP protocol shared with the NanoClaw host is documented
// at docs/ios-protocol.md. Update both this file and that document together.

struct BotCommand: Equatable {
    let command: String
    let description: String
}

@Observable @MainActor
final class WebSocketClient {
    var messages: [ChatMessage] = []
    var isConnected = false { didSet { if isConnected != oldValue { onConnectionChanged?(isConnected) } } }
    var isTyping    = false
    var commands: [BotCommand] = []
    var lastUserSentAt: Date? = nil
    var lastAssistantAt: Date? = nil
    var thinkingDetail: String? = nil

    /// Persistent "agent is busy" — derived state.
    /// True if: server typing OR user sent < 5min ago and no later assistant reply.
    var isBusy: Bool {
        if isTyping { return true }
        guard let sent = lastUserSentAt else { return false }
        if let got = lastAssistantAt, got >= sent { return false }
        return Date().timeIntervalSince(sent) < Self.busyTimeoutSeconds
    }

    @ObservationIgnored private static let busyTimeoutSeconds: TimeInterval = 300           // 5 minutes
    @ObservationIgnored private static let thinkingDetailClearSeconds: TimeInterval = 30    // auto-clear delay

    @ObservationIgnored private let transport: WSTransport
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var stopped           = false
    @ObservationIgnored private var pendingApnsToken: String?
    @ObservationIgnored private var sentReadIds: Set<String> = []

    @ObservationIgnored let outbox: OutboxStore

    init(outbox: OutboxStore? = nil) {
        self.outbox = outbox ?? OutboxStore()
        self.transport = WSTransport()
        wireTransport()
    }

    /// Wire transport callbacks to client behaviour. Called once from init.
    private func wireTransport() {
        transport.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            // Mirror transport connection state into the @Observable bit so views update.
            // The didSet on isConnected fires onConnectionChanged?() for external observers.
            self.isConnected = connected
            if !connected {
                // Drop transient UI state on disconnect — fresh slate on reconnect.
                self.isTyping = false
                self.lastUserSentAt = nil
                self.lastAssistantAt = nil
                self.thinkingDetail = nil
            }
        }
        transport.onMessage = { [weak self] msg in
            guard let self else { return }
            let data: Data
            switch msg {
            case .data(let d):   data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default:    return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handleIncoming(obj)
            }
        }
        transport.onAuthPayload = { settings in
            let token = JarvisApp.isUITesting ? "uitest-token" : settings.bearerToken
            return try? JSONSerialization.data(withJSONObject: [
                "type": "auth",
                "token": token,
                "platformId": settings.platformId,
            ] as [String: Any])
        }
        transport.onConnectedForTesting = { [weak self] in
            self?.onFlushForTesting?()
        }
    }

    /// Current conversation, set by coordinator.
    var conversationId: UUID?

    /// Callback to persist messages through ConversationStore.
    @ObservationIgnored var onMessagesChanged: (([ChatMessage]) -> Void)?

    /// Callback when assistant message arrives (for haptics in UI layer).
    @ObservationIgnored var onAssistantMessage: (() -> Void)?

    /// Callback when a message arrives for a non-active conversation.
    @ObservationIgnored var onBackgroundMessage: ((UUID, ChatMessage) -> Void)?

    /// Callback with assistant text shown in the active conversation (for TTS auto-speak).
    @ObservationIgnored var onSpeakableText: ((String) -> Void)?

    /// Callback when user taps an action button — coordinator handles sending.
    @ObservationIgnored var onActionResponse: ((String, String, String) -> Void)?  // (messageId, buttonId, buttonLabel)

    /// Callback when the agent pulls device context. Returns the gathered context
    /// dict for the requested fields. Set by the coordinator (owns the managers).
    @ObservationIgnored var onContextRequest: (([String]) -> [String: Any])?

    /// Callback when connection state changes (for coordinator to track connection phase).
    @ObservationIgnored var onConnectionChanged: ((Bool) -> Void)?

    /// Test seam: fires whenever the connection-success path calls flushOutbox.
    @ObservationIgnored var onFlushForTesting: (() -> Void)?

    // MARK: – Transport-backed test seams
    //
    // These keep the public API stable for tests that predate the WSTransport
    // extraction. They forward straight through to the transport.

    /// Test seam: mimics the success branch of doConnect.
    @MainActor
    func notifyConnectedForTesting() {
        transport.notifyConnectedForTesting()
        flushOutbox()
    }

    /// Test seam: stale-pong path without a live URLSessionWebSocketTask.
    /// The transport's own `tickHeartbeatForTesting` may early-return when its
    /// `isConnected` is already false (which it always is in pure unit tests
    /// that fake the client state), so we mirror the stale-pong check here.
    @MainActor
    internal func tickHeartbeatForTesting() {
        if Date().timeIntervalSince(lastPongAt) > 35 {
            forceReconnect(reason: "pong timeout (test)")
        }
    }

    /// Test seam: lets tests poke lastPongAt directly.
    internal var lastPongAt: Date {
        get { transport.lastPongAt }
        set { transport.lastPongAt = newValue }
    }

    @MainActor
    internal func forceReconnect(reason: String) {
        // Clear our own UI-side state explicitly. In production this also happens
        // via transport.onConnectionChanged, but tests can fake the client-side
        // `isConnected` directly without ever syncing the transport, so we have
        // to clear here too.
        isConnected = false
        isTyping = false
        lastUserSentAt = nil
        lastAssistantAt = nil
        thinkingDetail = nil
        transport.forceReconnect(reason: reason)
    }

    func connect(settings: AppSettings) {
        self.settings = settings
        stopped = false
        AppDelegate.wsClient = self
        UIApplication.shared.registerForRemoteNotifications()
        ConnectivityMonitor.shared.onSatisfied = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isConnected, !self.stopped, let s = self.settings else { return }
                self.transport.connect(settings: s)
            }
        }
        transport.connect(settings: settings)
    }

    func disconnect() {
        stopped = true
        transport.disconnect()
    }

    func registerApnsToken(_ hex: String) {
        pendingApnsToken = hex
        if isConnected { sendApnsToken(hex) }
    }

    // MARK: – Conversations

    func sendNewConversation(id: UUID) {
        guard isConnected else { return }
        let payload: [String: Any] = [
            "type": "new_conversation",
            "conversationId": id.uuidString
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        transport.send(data) { if let e = $0 { Log.warn(.ws, "send failed: \(e)") } }
    }

    func loadMessages(from store: ConversationStore) {
        sentReadIds.removeAll()
        guard let cid = conversationId else {
            messages = []
            return
        }
        messages = store.loadMessages(for: cid)
    }

    // MARK: – Send methods

    func send(text: String, timezone: String, status: String?, attachments: [DraftAttachment] = [], context: [String: Any]? = nil) {
        let clientMsgId = UUID().uuidString
        let ts = Date()

        // Build the payload up front — same shape whether we send now or later.
        var payload: [String: Any] = [
            "type": "message",
            "text": text,
            "timezone": timezone,
            "clientMessageId": clientMsgId,
        ]
        if let st = status, !st.isEmpty { payload["status"] = st }
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        if !attachments.isEmpty { payload["attachments"] = attachments.map { $0.payload } }
        if let ctx = context, !ctx.isEmpty { payload["context"] = ctx }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        // 1. Append to UI as .sending so the user sees their own message immediately.
        isTyping = true
        lastUserSentAt = Date()
        if !text.isEmpty {
            var msg = ChatMessage.text(clientMsgId, role: .user, text: text, timestamp: ts)
            msg.deliveryStatus = .sending
            messages.append(msg)
        }
        for att in attachments {
            if let img = att.image {
                messages.append(.image(UUID().uuidString, role: .user, image: img, filename: att.name, timestamp: ts))
            } else {
                let info = FileInfo(name: att.name, size: Int64(att.size), mimeType: att.mimeType, url: nil, thumbnail: nil)
                messages.append(.file(UUID().uuidString, role: .user, info: info, timestamp: ts))
            }
        }
        onMessagesChanged?(messages)

        // 2. Enqueue locally — survives crash, offline, anything.
        let added = outbox.enqueue(OutboxEntry(
            id: clientMsgId,
            conversationId: conversationId,
            createdAt: ts,
            payload: data,
            textPreview: text,
            hasAttachments: !attachments.isEmpty
        ))
        if !added {
            // Outbox full and nothing droppable — mark the just-appended user message
            // as .failed so it doesn't sit on the .sending spinner forever, then
            // surface a system row explaining why.
            if let idx = messages.firstIndex(where: { $0.id == clientMsgId }) {
                messages[idx].deliveryStatus = .failed
            }
            let warn = ChatMessage.status(UUID().uuidString,
                                          text: "Очередь переполнена, проверьте соединение",
                                          level: .warning, timestamp: Date())
            messages.append(warn)
            onMessagesChanged?(messages)
            return
        }

        // 3. Best-effort immediate send. flushOutbox handles wire-or-stay decision.
        flushOutbox()
    }

    /// 30s after we marked an entry as .sent, if no message_ack has arrived,
    /// downgrade it to .failed so the next flush re-sends it.
    @MainActor
    func bumpStaleSentEntries(now: Date = Date()) {
        for entry in outbox.entries where entry.deliveryStatus == .sent {
            guard let last = entry.lastAttempt,
                  now.timeIntervalSince(last) > 30 else { continue }
            if let idx = outbox.entries.firstIndex(where: { $0.id == entry.id }) {
                outbox.entries[idx].deliveryStatus = .failed
            }
            updateDeliveryStatus(entry.id, .failed)
        }
        outbox.save()
    }

    /// Test seam.
    @MainActor
    func bumpStaleSentEntriesForTesting(now: Date) {
        bumpStaleSentEntries(now: now)
    }

    /// Manual retry of a single outbox entry — triggered by tapping the red
    /// .failed indicator. Resets attempts/lastAttempt so backoff doesn't
    /// immediately re-skip, sets the row back to .sending, fires a haptic,
    /// and re-flushes.
    @MainActor
    func retrySend(id: String) {
        guard let idx = outbox.entries.firstIndex(where: { $0.id == id }) else { return }
        outbox.entries[idx].attempts = 0
        outbox.entries[idx].lastAttempt = nil
        outbox.entries[idx].deliveryStatus = .sending
        outbox.save()
        updateDeliveryStatus(id, .sending)
        flushOutbox()
        Theme.hapticMedium()
    }

    /// Try to send everything currently in the outbox. No-op when WS is down.
    func flushOutbox() {
        bumpStaleSentEntries()
        guard isConnected else { return }
        let snapshot = outbox.entries
        let now = Date()
        for entry in snapshot {
            guard outbox.shouldRetry(entry.id, now: now) else { continue }
            outbox.bumpAttempt(entry.id)
            transport.send(entry.payload) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // If the ack beat us (very fast server), entry is already removed
                    // and status is .delivered — don't downgrade to .sent.
                    guard self.outbox.entries.contains(where: { $0.id == entry.id }) else { return }
                    self.updateDeliveryStatus(entry.id, error == nil ? .sent : .failed)
                    // Entry stays in the outbox; removal happens on message_ack.
                }
            }
        }
    }

    func sendFeedback(conversationId: UUID?, messageId: String, value: Bool, messageText: String) {
        guard isConnected else { return }
        var payload: [String: Any] = [
            "type": "feedback",
            "messageId": messageId,
            "value": value,
            "messageText": messageText,
        ]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        transport.send(data) { if let e = $0 { Log.warn(.ws, "send failed: \(e)") } }
    }

    /// Reply to an agent context pull. Technical, not rendered.
    func sendContextResponse(requestId: String, context: [String: Any]) {
        guard isConnected else { return }
        var payload: [String: Any] = [
            "type": "context_response",
            "requestId": requestId,
            "context": context,
        ]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        transport.send(data) { if let e = $0 { Log.warn(.ws, "send(context_response) failed: \(e)") } }
    }

    func sendMessageDelivered(_ messageId: String, conversationId: UUID?) {
        guard isConnected else { return }
        var payload: [String: Any] = ["type": "message_delivered", "messageId": messageId]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        transport.send(data) { if let e = $0 { Log.warn(.ws, "send(message_delivered) failed: \(e)") } }
    }

    func sendMessageRead(_ messageId: String, conversationId: UUID?) {
        guard sentReadIds.insert(messageId).inserted else { return }
        guard isConnected else {
            sentReadIds.remove(messageId)
            return
        }
        var payload: [String: Any] = ["type": "message_read", "messageId": messageId]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        transport.send(data) { if let e = $0 { Log.warn(.ws, "send(message_read) failed: \(e)") } }
    }

    /// Emit a `proactive` envelope on the wire. Returns false when the
    /// socket isn't connected — caller (typically ProactiveDispatcher's
    /// WebSocket sink wrapper) is expected to fall back to HTTP.
    @discardableResult
    func sendProactive(triggerType: String, payload: [String: Any]) -> Bool {
        guard isConnected else { return false }
        let envelope: [String: Any] = [
            "type": "proactive",
            "trigger": triggerType,
            "payload": payload,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "tz": TimeZone.current.identifier,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return false }
        transport.send(data) { error in
            if let error { Log.warn(.ws, "sendProactive failed: \(error)") }
        }
        return true
    }

    func sendActionResponse(messageId: String, buttonId: String, buttonLabel: String) {
        guard isConnected else { return }
        var payload: [String: Any] = [
            "type": "action_response",
            "messageId": messageId,
            "buttonId": buttonId,
            "buttonLabel": buttonLabel,
        ]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        transport.send(data) { if let e = $0 { Log.warn(.ws, "send failed: \(e)") } }

        // Mark action as answered locally
        if let idx = messages.firstIndex(where: { $0.id == messageId }),
           case .action(var info) = messages[idx].content {
            info.answered = true
            info.selectedId = buttonId
            messages[idx] = ChatMessage(id: messageId, role: messages[idx].role,
                                        content: .action(info), timestamp: messages[idx].timestamp)
            onMessagesChanged?(messages)
        }
    }

    // MARK: – Private

    private func updateDeliveryStatus(_ id: String, _ status: DeliveryStatus) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].deliveryStatus = status
        onMessagesChanged?(messages)
    }

    /// Server confirmed receipt of a previously-sent client message. Remove the
    /// outbox entry and mark the UI row as `.delivered`. Idempotent: unknown
    /// clientMessageId is a no-op (e.g. server replay after we already removed).
    @MainActor
    func handleMessageAck(clientMessageId: String) {
        guard outbox.entries.contains(where: { $0.id == clientMessageId }) else {
            return
        }
        outbox.remove(clientMessageId)
        updateDeliveryStatus(clientMessageId, .delivered)
    }

    /// Test seam — call `handleMessageAck` directly without a real socket.
    @MainActor
    func handleMessageAckForTesting(clientMessageId: String) {
        handleMessageAck(clientMessageId: clientMessageId)
    }

    private func sendApnsToken(_ hex: String) {
        guard isConnected else { return }
        guard let pay = try? JSONSerialization.data(withJSONObject: ["type": "apns_token", "token": hex]) else { return }
        transport.send(pay) { if let e = $0 { Log.warn(.ws, "send(apns_token) failed: \(e)") } }
    }

    @MainActor
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            transport.handleBecameActive()
        case .background, .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleIncoming(_ obj: [String: Any]) {
        let t = obj["type"] as? String

        // --- Auth ---
        if t == "auth_ok" {
            // Transport already flipped isConnected to true when the socket
            // opened — auth_ok is the server saying "creds accepted". We mirror
            // it as a no-op state set + run post-auth side effects.
            isConnected = true
            flushOutbox()
            onFlushForTesting?()
            transport.startHeartbeat()
            if let tok = pendingApnsToken { sendApnsToken(tok) }
            if let cmds = obj["commands"] as? [[String: String]] {
                commands = cmds.compactMap { d in
                    guard let cmd = d["command"], let desc = d["description"] else { return nil }
                    return BotCommand(command: cmd, description: desc)
                }
            }
            return
        }

        // --- Typing ---
        if t == "typing_start" {
            isTyping = true
            return
        }
        if t == "typing_stop" {
            isTyping = false
            return
        }

        // --- Feedback ack (no UI action needed) ---
        if t == "feedback_ack" {
            return
        }

        // --- Message ack (server confirmed receipt of user message) ---
        if t == "message_ack",
           let clientMsgId = obj["clientMessageId"] as? String {
            handleMessageAck(clientMessageId: clientMsgId)
            return
        }

        // --- Context request (agent pull) — gather and reply, not rendered ---
        if t == "context_request" {
            let fields = obj["fields"] as? [String] ?? []
            let requestId = obj["requestId"] as? String ?? ""
            let ctx = onContextRequest?(fields) ?? [:]
            sendContextResponse(requestId: requestId, context: ctx)
            return
        }

        let convId = (obj["conversationId"] as? String).flatMap(UUID.init(uuidString:))

        // --- Text message ---
        if t == "message",
           let text = obj["text"] as? String,
           let id   = obj["id"]   as? String {
            route(.text(id, role: .assistant, text: text, timestamp: Date()), convId: convId)
        }

        // --- Image ---
        else if t == "image",
                let b64      = obj["data"]     as? String,
                let id       = obj["id"]       as? String,
                let filename = obj["filename"] as? String,
                let imgData  = Data(base64Encoded: b64),
                let image    = UIImage(data: imgData) {
            route(.image(id, role: .assistant, image: image, filename: filename, timestamp: Date()), convId: convId)
        }

        // --- File ---
        else if t == "file",
                let id   = obj["id"]   as? String,
                let name = obj["name"] as? String {
            let info = FileInfo(
                name: name,
                size: obj["size"] as? Int64 ?? 0,
                mimeType: obj["mimeType"] as? String ?? "application/octet-stream",
                url: obj["url"] as? String,
                thumbnail: nil
            )
            route(.file(id, role: .assistant, info: info, timestamp: Date()), convId: convId)
        }

        // --- Action (question with buttons) ---
        else if t == "action",
                let id   = obj["id"]   as? String,
                let text = obj["text"] as? String,
                let btns = obj["buttons"] as? [[String: Any]] {
            let buttons = btns.compactMap { b -> ActionButton? in
                guard let bid = b["id"] as? String, let label = b["label"] as? String else { return nil }
                let style = ActionButton.Style(rawValue: b["style"] as? String ?? "primary") ?? .primary
                return ActionButton(id: bid, label: label, style: style)
            }
            route(.action(id, text: text, buttons: buttons, timestamp: Date()), convId: convId)
        }

        // --- Status ---
        else if t == "status",
                let text = obj["text"] as? String {
            let id = obj["id"] as? String ?? UUID().uuidString
            let level = StatusInfo.Level(rawValue: obj["level"] as? String ?? "info") ?? .info
            let kind = obj["kind"] as? String
            route(.status(id, text: text, level: level, kind: kind, timestamp: Date()), convId: convId)
        }
    }

    /// Route an incoming message to the active list or to a background conversation's store.
    private func route(_ message: ChatMessage, convId: UUID?) {
        onAssistantMessage?()
        if convId == nil || convId == conversationId {
            isTyping = false
            // Dedup: the host re-flushes queued messages on reconnect, so the same
            // id can arrive twice. Skip if already present in the active list.
            if messages.contains(where: { $0.id == message.id }) { return }
            if message.role == .assistant {
                sendMessageDelivered(message.id, conversationId: conversationId)
            }
            messages.append(message)
            onMessagesChanged?(messages)
            if message.role == .assistant {
                lastAssistantAt = Date()
                thinkingDetail = nil
            }
            if case .status(let info) = message.content, info.kind == "system" {
                thinkingDetail = info.text
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.thinkingDetailClearSeconds))
                    if self?.thinkingDetail == info.text { self?.thinkingDetail = nil }
                }
            }
            if message.role == .assistant, case .text(let t) = message.content {
                onSpeakableText?(t)
            }
        } else {
            onBackgroundMessage?(convId!, message)
        }
    }
}
