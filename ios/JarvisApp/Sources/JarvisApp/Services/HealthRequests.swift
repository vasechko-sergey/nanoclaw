import Foundation

/// Drains server-side health fetch requests over HTTP (no APNs). The app polls
/// `GET /ios/health/requests` on foreground and on each HealthKit background-delivery
/// wake, fetches each window, and uploads via `HealthUpload` (which clears the request
/// server-side). Plan "Заход 3" — HTTP-poll variant.
enum HealthRequests {
    private struct Pending: Decodable { let requestId: String; let from: String; let to: String }
    private struct Envelope: Decodable { let requests: [Pending] }

    static func drain(completion: (() -> Void)? = nil) {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "serverURL"), !server.isEmpty,
              let token = defaults.string(forKey: "bearerToken"), !token.isEmpty else {
            completion?(); return
        }
        var base = server
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        else if !base.hasPrefix("http") { base = "http://" + base }
        guard let url = URL(string: base.hasSuffix("/") ? base + "ios/health/requests" : base + "/ios/health/requests") else {
            completion?(); return
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let env = try? JSONDecoder().decode(Envelope.self, from: data), !env.requests.isEmpty else {
                completion?(); return
            }
            let group = DispatchGroup()
            for r in env.requests {
                group.enter()
                HealthHistory.fetch(from: r.from, to: r.to) { days in
                    HealthUpload.upload(requestId: r.requestId, days: days) { group.leave() }
                }
            }
            group.notify(queue: .main) { completion?() }
        }.resume()
    }
}
