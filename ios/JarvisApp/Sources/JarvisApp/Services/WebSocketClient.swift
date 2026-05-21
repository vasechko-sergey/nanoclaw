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
        ws.send(.data(data)) { _ in }
    }

    func loadMessages(from store: ConversationStore) {
        guard let cid = conversationId else {
            messages = []
            return
        }
        messages = store.loadMessages(for: cid)
    }

    // MARK: – Private

    private func sendApnsToken(_ hex: String) {
        guard let ws = task, isConnected else { return }
        guard let pay = try? JSONSerialization.data(withJSONObject: ["type": "apns_token", "token": hex]) else { return }
        ws.send(.data(pay)) { _ in }
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
        ws.send(.data(auth)) { _ in }
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
                        let t = obj["type"] as? String
                        if t == "auth_ok" {
                            self.isConnected = true
                            if let tok = self.pendingApnsToken { self.sendApnsToken(tok) }
                            if let cmds = obj["commands"] as? [[String: String]] {
                                self.commands = cmds.compactMap { d in
                                    guard let cmd = d["command"], let desc = d["description"] else { return nil }
                                    return BotCommand(command: cmd, description: desc)
                                }
                            }
                        } else if t == "message",
                                  let text = obj["text"] as? String,
                                  let id   = obj["id"]   as? String {
                            self.isTyping = false
                            self.onAssistantMessage?()
                            self.messages.append(.text(id, role: .assistant, text: text, timestamp: Date()))
                            self.onMessagesChanged?(self.messages)
                        } else if t == "image",
                                  let b64      = obj["data"]     as? String,
                                  let id       = obj["id"]       as? String,
                                  let filename = obj["filename"] as? String,
                                  let imgData  = Data(base64Encoded: b64),
                                  let image    = UIImage(data: imgData) {
                            self.isTyping = false
                            self.onAssistantMessage?()
                            self.messages.append(.image(id, role: .assistant, image: image, filename: filename, timestamp: Date()))
                            self.onMessagesChanged?(self.messages)
                        }
                    }
                    self.receive(ws: ws)
                }
            }
        }
    }

    func send(text: String, context: [String: Any]?) {
        guard let ws = task, isConnected else { return }
        var payload: [String: Any] = ["type": "message", "text": text]
        if let ctx = context { payload["context"] = ctx }
        if let cid = conversationId { payload["conversationId"] = cid.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { _ in }
        isTyping = true
        messages.append(.text(UUID().uuidString, role: .user, text: text, timestamp: Date()))
        onMessagesChanged?(messages)
    }
}
