import Foundation
import UIKit

struct BotCommand: Equatable {
    let command: String
    let description: String
}

@MainActor
final class WebSocketClient: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isConnected = false
    @Published var isTyping    = false
    @Published var commands: [BotCommand] = []

    private var task: URLSessionWebSocketTask?
    private var settings: AppSettings?
    private var reconnectDelay: TimeInterval = 1
    private var stopped           = false
    private var pendingApnsToken: String?

    /// Current conversation, set by coordinator.
    var conversationId: UUID?

    /// Callback to persist messages through ConversationStore.
    var onMessagesChanged: (([ChatMessage]) -> Void)?

    /// Callback when assistant message arrives (for haptics in UI layer).
    var onAssistantMessage: (() -> Void)?

    /// Callback when a message arrives for a non-active conversation.
    var onBackgroundMessage: ((UUID, ChatMessage) -> Void)?

    /// Callback with assistant text shown in the active conversation (for TTS auto-speak).
    var onSpeakableText: ((String) -> Void)?

    /// Callback when user taps an action button — coordinator handles sending.
    var onActionResponse: ((String, String, String) -> Void)?  // (messageId, buttonId, buttonLabel)

    /// Callback when the agent pulls device context. Returns the gathered context
    /// dict for the requested fields. Set by the coordinator (owns the managers).
    var onContextRequest: (([String]) -> [String: Any])?

    func connect(settings: AppSettings) {
        self.settings = settings
        stopped = false
        AppDelegate.wsClient = self
        UIApplication.shared.registerForRemoteNotifications()
        doConnect(settings: settings)
    }

    func disconnect() {
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
        guard let cid = conversationId else {
            messages = []
            return
        }
        messages = store.loadMessages(for: cid)
    }

    // MARK: – Send methods

    func send(text: String, timezone: String, status: String?) {
        guard let ws = task, isConnected else { return }
        var payload: [String: Any] = ["type": "message", "text": text, "timezone": timezone]
        if let st = status, !st.isEmpty { payload["status"] = st }
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { if let e = $0 { print("WS send(message) failed: \(e)") } }
        isTyping = true
        messages.append(.text(UUID().uuidString, role: .user, text: text, timestamp: Date()))
        onMessagesChanged?(messages)
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

    private func sendApnsToken(_ hex: String) {
        guard let ws = task, isConnected else { return }
        guard let pay = try? JSONSerialization.data(withJSONObject: ["type": "apns_token", "token": hex]) else { return }
        ws.send(.data(pay)) { if let e = $0 { print("WS send(apns_token) failed: \(e)") } }
    }

    private func doConnect(settings: AppSettings) {
        guard !stopped, !settings.serverURL.isEmpty else { return }
        var s = settings.serverURL
        if      s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://")  { s = "ws://"  + s.dropFirst(7) }
        else if !s.hasPrefix("ws")      { s = "ws://"  + s }
        guard let url = URL(string: s) else { return }

        let ws = URLSession.shared.webSocketTask(with: url)
        self.task = ws
        ws.resume()

        guard let auth = try? JSONSerialization.data(withJSONObject: [
            "type": "auth",
            "token": settings.bearerToken,
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
                    self.isConnected = false
                    self.isTyping    = false
                    guard !self.stopped, let settings = self.settings else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.reconnectDelay * 1_000_000_000))
                    self.reconnectDelay = min(self.reconnectDelay * 2, 30)
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
            messages.append(message)
            onMessagesChanged?(messages)
            if message.role == .assistant, case .text(let t) = message.content {
                onSpeakableText?(t)
            }
        } else {
            onBackgroundMessage?(convId!, message)
        }
    }
}
