import Foundation

/// Sends a lock-screen reply to the host (`POST /ios/reply`) and, on success,
/// echoes it into the local store so it appears in the chat timeline. Suspend-
/// safe: a plain URLSession POST inside the notification-response window — no WS.
final class NotificationReplySender {
    static let shared = NotificationReplySender()

    private let storeLock = NSLock()
    private var _store: ConversationStoreV2?
    private var store: ConversationStoreV2? { storeLock.withLock { _store } }

    /// Wire the store at app init (same hook as LocalNotifier.configure).
    func configure(store: ConversationStoreV2) { storeLock.withLock { _store = store } }

    func send(agentId: String, text: String, completion: @escaping (Bool) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let token = UserDefaults.standard.string(forKey: "bearerToken"), !token.isEmpty,
              let req = ReplyRequest.build(token: token, agentId: agentId, text: trimmed)
        else { completion(false); return }

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if ok {
                self?.recordEcho(agentId: agentId, text: trimmed)
            } else {
                let detail = err.map { "error: \($0.localizedDescription)" }
                    ?? "status: \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                Log.warn(.outbox, "lock-screen reply POST /ios/reply failed (\(detail)) — queuing for WS drain")
                self?.queueForRetry(agentId: agentId, text: trimmed)
            }
            completion(ok)
        }.resume()
    }

    /// Success-only echo with a terminal status so the outbound WS drain
    /// (queuedOutbound filters status='queued') never re-sends it.
    private func recordEcho(agentId: String, text: String) {
        guard let store else { return }
        try? store.insertOutboundUserMessage(
            id: UUID().uuidString, text: text, attachments: [], context: nil, agentId: agentId, status: .sent
        )
    }

    /// On POST failure, persist the reply as a `queued` outbound row so the WS
    /// transport's dispatcher (queuedOutbound filters status='queued') delivers it
    /// on the next connect, instead of silently dropping the text (F3). At-least-
    /// once: a 200 whose response was lost would double-send, which is preferable
    /// to losing the user's reply.
    private func queueForRetry(agentId: String, text: String) {
        guard let store else { return }
        try? store.insertOutboundUserMessage(
            id: UUID().uuidString, text: text, attachments: [], context: nil, agentId: agentId, status: .queued
        )
    }
}

/// Pure request builder (unit-tested without network). Uses the existing
/// ServerConfig.httpURL to target POST /ios/reply.
enum ReplyRequest {
    static func build(token: String, agentId: String, text: String) -> URLRequest? {
        guard let url = ServerConfig.httpURL(path: "ios/reply") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "agent_id": agentId])
        req.timeoutInterval = 20
        return req
    }
}
