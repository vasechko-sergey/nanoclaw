import Foundation
import UIKit

/// Uploads daily health aggregates to the server over HTTP — used from background
/// (silent push or HealthKit background delivery) when the WebSocket is offline.
/// Reads serverURL/token from UserDefaults so it works without the app UI.
/// Body shape pinned by shared/ios-app-protocol/v2.ts:HealthUploadBody.
enum HealthUpload {
    static func upload(requestId: String?, days: [V2.HealthUpload.Day], completion: ((Bool) -> Void)? = nil) {
        guard !days.isEmpty else { completion?(false); return }
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "bearerToken"), !token.isEmpty else {
            completion?(false); return
        }
        let platformId = defaults.string(forKey: "platformId")
            ?? ("ios:" + (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString))

        guard let url = ServerConfig.httpURL(path: "ios/health/upload") else {
            completion?(false); return
        }

        let body = V2.HealthUpload.Body(platformId: platformId, requestId: requestId, days: days)
        let encoder = JSONEncoder()
        // Omit absent optionals so the JSON exactly matches the canonical
        // schema (HealthUploadDay uses `.optional()` — absent != null).
        guard let data = try? encoder.encode(body) else { completion?(false); return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 25

        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            completion?(ok)
        }.resume()
    }
}
