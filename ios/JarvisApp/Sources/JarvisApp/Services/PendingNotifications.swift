import Foundation

/// Pulls notification-worthy queued messages over HTTP (`GET /ios/pending`) and
/// raises a local notification for each via `LocalNotifier`. Invoked on every
/// background self-wake (HealthKit observers, the morning BGProcessing task, and
/// the dedicated BGAppRefresh task). No APNs. Dedup is per-id in LocalNotifier,
/// so re-pulling an un-acked message is a harmless no-op.
enum PendingNotifications {
    struct PendingMessage: Decodable {
        let id: String
        let seq: Int
        let agent_id: String?
        let text: String
    }
    private struct Envelope: Decodable { let messages: [PendingMessage] }

    /// Pure decode seam (unit-tested). Tolerant: any decode failure → empty.
    static func parse(_ data: Data) -> [PendingMessage] {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.messages ?? []
    }

    static func drain(completion: (() -> Void)? = nil) {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "bearerToken"), !token.isEmpty else {
            completion?(); return
        }
        guard let url = ServerConfig.httpURL(path: "ios/pending") else {
            completion?(); return
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data else { completion?(); return }
            let messages = parse(data)
            for m in messages {
                LocalNotifier.shared.raise(id: m.id, agentId: m.agent_id ?? "jarvis", text: m.text, seq: m.seq)
            }
            completion?()
        }.resume()
    }
}
