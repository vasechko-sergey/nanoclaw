import Foundation
import UIKit
import SwiftUI

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

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var reconnectDelay: TimeInterval = 1
    @ObservationIgnored private var heartbeatTimer: Timer?
    @ObservationIgnored internal var lastPongAt: Date = .distantPast
    @ObservationIgnored private let pingInterval: TimeInterval = 25
    @ObservationIgnored private let pongTimeout: TimeInterval = 35
    @ObservationIgnored private var stopped           = false
    @ObservationIgnored private var pendingApnsToken: String?
    @ObservationIgnored private var sentReadIds: Set<String> = []

    @ObservationIgnored let outbox: OutboxStore

    init(outbox: OutboxStore? = nil) {
        self.outbox = outbox ?? OutboxStore()
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

    func connect(settings: AppSettings) {
        self.settings = settings
        stopped = false
        AppDelegate.wsClient = self
        UIApplication.shared.registerForRemoteNotifications()
        ConnectivityMonitor.shared.onSatisfied = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isConnected, !self.stopped, let s = self.settings else { return }
                self.doConnect(settings: s)
            }
        }
        doConnect(settings: settings)
    }

    func disconnect() {
        stopHeartbeat()
        stopped = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    func registerApnsToken(_ hex: String) {
        pendingApnsToken = hex
        if isConnected { sendApnsToken(hex) }
    }

    // MARK: – Conversations

    func sendNewConversation(id: UUID) {
        guard let ws = task, isConnected else { return }
        let payload: [String: Any] = [
            "type": "new_conversation",
            "conversationId": id.uuidString
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { if let e = $0 { print("WS send failed: \(e)") } }
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
            // Outbox full and nothing droppable — surface a system row.
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

    /// Try to send everything currently in the outbox. No-op when WS is down.
    func flushOutbox() {
        guard let ws = task, isConnected else { return }
        let snapshot = outbox.entries
        let now = Date()
        for entry in snapshot {
            guard outbox.shouldRetry(entry.id, now: now) else { continue }
            outbox.bumpAttempt(entry.id)
            ws.send(.data(entry.payload)) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateDeliveryStatus(entry.id, error == nil ? .sent : .failed)
                    // Entry stays in the outbox; removal happens on message_ack.
                }
            }
        }
    }

    func sendFeedback(conversationId: UUID?, messageId: String, value: Bool, messageText: String) {
        guard let ws = task, isConnected else { return }
        var payload: [String: Any] = [
            "type": "feedback",
            "messageId": messageId,
            "value": value,
            "messageText": messageText,
        ]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { if let e = $0 { print("WS send failed: \(e)") } }
    }

    /// Reply to an agent context pull. Technical, not rendered.
    func sendContextResponse(requestId: String, context: [String: Any]) {
        guard let ws = task, isConnected else { return }
        var payload: [String: Any] = [
            "type": "context_response",
            "requestId": requestId,
            "context": context,
        ]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { if let e = $0 { print("WS send(context_response) failed: \(e)") } }
    }

    func sendMessageDelivered(_ messageId: String, conversationId: UUID?) {
        guard let ws = task, isConnected else { return }
        var payload: [String: Any] = ["type": "message_delivered", "messageId": messageId]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { if let e = $0 { print("WS send(message_delivered) failed: \(e)") } }
    }

    func sendMessageRead(_ messageId: String, conversationId: UUID?) {
        guard sentReadIds.insert(messageId).inserted else { return }
        guard let ws = task, isConnected else {
            sentReadIds.remove(messageId)
            return
        }
        var payload: [String: Any] = ["type": "message_read", "messageId": messageId]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { if let e = $0 { print("WS send(message_read) failed: \(e)") } }
    }

    func sendActionResponse(messageId: String, buttonId: String, buttonLabel: String) {
        guard let ws = task, isConnected else { return }
        var payload: [String: Any] = [
            "type": "action_response",
            "messageId": messageId,
            "buttonId": buttonId,
            "buttonLabel": buttonLabel,
        ]
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { if let e = $0 { print("WS send failed: \(e)") } }

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

    private func sendApnsToken(_ hex: String) {
        guard let ws = task, isConnected else { return }
        guard let pay = try? JSONSerialization.data(withJSONObject: ["type": "apns_token", "token": hex]) else { return }
        ws.send(.data(pay)) { if let e = $0 { print("WS send(apns_token) failed: \(e)") } }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        lastPongAt = Date()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickHeartbeat() }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    @MainActor
    internal func tickHeartbeat() {
        guard let ws = task, isConnected else { return }
        if Date().timeIntervalSince(lastPongAt) > pongTimeout {
            forceReconnect(reason: "pong timeout")
            return
        }
        ws.sendPing { [weak self] error in
            Task { @MainActor in
                if error == nil { self?.lastPongAt = Date() }
                else { self?.forceReconnect(reason: "ping failed") }
            }
        }
    }

    /// Test seam: lets tests trigger the heartbeat tick without a live URLSessionWebSocketTask.
    /// The real `tickHeartbeat()` early-returns when `task == nil`, so this inlines just the
    /// stale-pong check.
    @MainActor
    internal func tickHeartbeatForTesting() {
        if Date().timeIntervalSince(lastPongAt) > pongTimeout {
            forceReconnect(reason: "pong timeout (test)")
        }
    }

    @MainActor
    internal func forceReconnect(reason: String) {
        print("WS reconnect: \(reason)")
        task?.cancel(with: .goingAway, reason: nil)
        // Clear all transient UI state on reconnect — fresh slate when the socket drops.
        // If doConnect fails to establish (e.g. invalid URL), the receive() failure branch
        // will schedule a retry via reconnectDelay backoff.
        isConnected = false
        isTyping = false
        lastUserSentAt = nil
        lastAssistantAt = nil
        thinkingDetail = nil
        reconnectDelay = 1
        stopHeartbeat()
        guard !stopped, let settings else { return }
        doConnect(settings: settings)
    }

    @MainActor
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if !isConnected, !stopped, let settings {
                doConnect(settings: settings)
            } else if isConnected {
                tickHeartbeat()
            }
        case .background, .inactive:
            break
        @unknown default:
            break
        }
    }

    private func doConnect(settings: AppSettings) {
        stopHeartbeat()
        guard !stopped else { return }
        let rawUrl: String
        let authToken: String
        if JarvisApp.isUITesting {
            rawUrl = "ws://127.0.0.1:8765"
            authToken = "uitest-token"
        } else {
            guard !settings.serverURL.isEmpty else { return }
            rawUrl = settings.serverURL
            authToken = settings.bearerToken
        }
        var s = rawUrl
        if      s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://")  { s = "ws://"  + s.dropFirst(7) }
        else if !s.hasPrefix("ws")      { s = "ws://"  + s }
        guard let url = URL(string: s) else { return }

        // Cancel any prior task so we never run two concurrent receive loops.
        task?.cancel(with: .normalClosure, reason: nil)

        let ws = URLSession.shared.webSocketTask(with: url)
        self.task = ws
        ws.resume()

        guard let auth = try? JSONSerialization.data(withJSONObject: [
            "type": "auth",
            "token": authToken,
            "platformId": settings.platformId,
        ] as [String: Any]) else { return }
        ws.send(.data(auth)) { if let e = $0 { print("WS send(auth) failed: \(e)") } }
        receive(ws: ws)
    }

    private func receive(ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure:
                    // Ignore failures from a socket we've already replaced.
                    guard self.task === ws else { return }
                    self.isConnected = false
                    self.isTyping    = false
                    self.lastUserSentAt = nil
                    self.lastAssistantAt = nil
                    self.thinkingDetail = nil
                    guard !self.stopped, let settings = self.settings else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.reconnectDelay * 1_000_000_000))
                    self.reconnectDelay = min(self.reconnectDelay * 2, 30)
                    // Re-check: disconnect() may have fired during the sleep.
                    guard !self.stopped else { return }
                    self.doConnect(settings: settings)

                case .success(let msg):
                    self.reconnectDelay = 1
                    let data: Data
                    switch msg {
                    case .data(let d):   data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default:    self.receive(ws: ws); return
                    }
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleIncoming(obj)
                    }
                    // Don't keep reading a socket we've replaced or shut down.
                    guard !self.stopped, self.task === ws else { return }
                    self.receive(ws: ws)
                }
            }
        }
    }

    private func handleIncoming(_ obj: [String: Any]) {
        let t = obj["type"] as? String

        // --- Auth ---
        if t == "auth_ok" {
            isConnected = true
            startHeartbeat()
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
            updateDeliveryStatus(clientMsgId, .delivered)
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
