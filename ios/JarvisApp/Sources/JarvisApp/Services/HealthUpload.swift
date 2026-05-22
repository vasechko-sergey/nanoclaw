import Foundation

/// Uploads daily health aggregates to the server over HTTP — used from background
/// (silent push or HealthKit background delivery) when the WebSocket is offline.
/// Reads serverURL/token from UserDefaults so it works without the app UI.
enum HealthUpload {
    static func upload(requestId: String?, days: [[String: Any]], completion: (() -> Void)? = nil) {
        guard !days.isEmpty else { completion?(); return }
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "serverURL"), !server.isEmpty,
              let token = defaults.string(forKey: "bearerToken"), !token.isEmpty else {
            completion?(); return
        }

        // serverURL is a ws/host string; normalize to http(s) base + /ios/health/upload.
        var base = server
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        else if !base.hasPrefix("http") { base = "http://" + base }
        guard let url = URL(string: base.hasSuffix("/") ? base + "ios/health/upload" : base + "/ios/health/upload") else {
            completion?(); return
        }

        var body: [String: Any] = ["days": days]
        if let requestId { body["requestId"] = requestId }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { completion?(); return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 25

        URLSession.shared.dataTask(with: req) { _, _, _ in
            completion?()
        }.resume()
    }
}
