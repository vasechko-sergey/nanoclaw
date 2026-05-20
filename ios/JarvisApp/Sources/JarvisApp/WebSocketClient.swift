import Foundation
import UIKit

@MainActor
final class WebSocketClient: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isConnected = false
    @Published var isTyping    = false

    private var task: URLSessionWebSocketTask?
    private var settings: AppSettings?
    private var reconnectDelay: TimeInterval = 1
    private var stopped           = false
    private var pendingApnsToken: String?

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

    private func sendApnsToken(_ hex: String) {
        guard let ws = task, isConnected else { return }
        let pay = try! JSONSerialization.data(withJSONObject: ["type": "apns_token", "token": hex])
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

        let auth = try! JSONSerialization.data(withJSONObject: [
            "type": "auth",
            "token": settings.bearerToken,
            "platformId": settings.platformId,
        ] as [String: Any])
        ws.send(.data(auth)) { _ in }
        receive(ws: ws, settings: settings)
    }

    private func receive(ws: URLSessionWebSocketTask, settings: AppSettings) {
        ws.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure:
                    self.isConnected = false
                    self.isTyping    = false
                    guard !self.stopped else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.reconnectDelay * 1_000_000_000))
                    self.reconnectDelay = min(self.reconnectDelay * 2, 30)
                    self.doConnect(settings: settings)

                case .success(let msg):
                    self.reconnectDelay = 1
                    let data: Data
                    switch msg {
                    case .data(let d):   data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default:    self.receive(ws: ws, settings: settings); return
                    }
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let t = obj["type"] as? String
                        if t == "auth_ok" {
                            self.isConnected = true
                            if let tok = self.pendingApnsToken { self.sendApnsToken(tok) }
                        } else if t == "message",
                                  let text = obj["text"] as? String,
                                  let id   = obj["id"]   as? String {
                            self.isTyping = false
                            self.messages.append(.text(id, role: .assistant, text: text, timestamp: Date()))
                        } else if t == "image",
                                  let b64      = obj["data"]     as? String,
                                  let id       = obj["id"]       as? String,
                                  let filename = obj["filename"] as? String,
                                  let imgData  = Data(base64Encoded: b64),
                                  let image    = UIImage(data: imgData) {
                            self.isTyping = false
                            self.messages.append(.image(id, role: .assistant, image: image, filename: filename, timestamp: Date()))
                        }
                    }
                    self.receive(ws: ws, settings: settings)
                }
            }
        }
    }

    func send(text: String, context: [String: Any]?) {
        guard let ws = task, isConnected else { return }
        var payload: [String: Any] = ["type": "message", "text": text]
        if let ctx = context { payload["context"] = ctx }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ws.send(.data(data)) { _ in }
        isTyping = true
        messages.append(.text(UUID().uuidString, role: .user, text: text, timestamp: Date()))
    }
}
