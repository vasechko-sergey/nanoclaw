import Foundation

/// Fetches GET /ios/state. Mirrors HealthUpload's UserDefaults config
/// (serverURL/bearerToken) and ws→http normalization.
@MainActor
final class StateService: ObservableObject {
    @Published var state: StateModel?
    @Published var lastError: String?

    func refresh() {
        let defaults = UserDefaults.standard
        let server = ServerConfig.url
        guard let token = defaults.string(forKey: "bearerToken"), !token.isEmpty else { return }
        var base = server
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        else if !base.hasPrefix("http") { base = "http://" + base }
        guard let url = URL(string: base.hasSuffix("/") ? base + "ios/state" : base + "/ios/state") else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let data, err == nil, let decoded = try? JSONDecoder().decode(StateModel.self, from: data) else {
                Task { @MainActor in self?.lastError = err?.localizedDescription ?? "decode failed" }
                return
            }
            Task { @MainActor in self?.state = decoded }
        }.resume()
    }
}
