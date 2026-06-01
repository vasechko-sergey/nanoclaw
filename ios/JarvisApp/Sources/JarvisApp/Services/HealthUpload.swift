import Foundation
import UIKit

/// Uploads daily health aggregates to the server over HTTP — used from background
/// (silent push or HealthKit background delivery) when the WebSocket is offline.
/// Reads serverURL/token from UserDefaults so it works without the app UI.
/// Body shape pinned by shared/ios-app-protocol/v2.ts:HealthUploadBody.
enum HealthUpload {
    static func upload(requestId: String?, days: [V2.HealthUpload.Day], completion: (() -> Void)? = nil) {
        guard !days.isEmpty else { completion?(); return }
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "serverURL"), !server.isEmpty,
              let token = defaults.string(forKey: "bearerToken"), !token.isEmpty else {
            completion?(); return
        }
        let platformId = defaults.string(forKey: "platformId")
            ?? ("ios:" + (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString))

        // serverURL is a ws/host string; normalize to http(s) base + /ios/health/upload.
        var base = server
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        else if !base.hasPrefix("http") { base = "http://" + base }
        guard let url = URL(string: base.hasSuffix("/") ? base + "ios/health/upload" : base + "/ios/health/upload") else {
            completion?(); return
        }

        let body = V2.HealthUpload.Body(platformId: platformId, requestId: requestId, days: days)
        let encoder = JSONEncoder()
        // Omit absent optionals so the JSON exactly matches the canonical
        // schema (HealthUploadDay uses `.optional()` — absent != null).
        guard let data = try? encoder.encode(body) else { completion?(); return }

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
