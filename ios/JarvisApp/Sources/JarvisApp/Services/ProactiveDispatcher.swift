import Foundation

/// Outbound surface the dispatcher pushes events to. Production: WebSocketClient
/// (with HTTP fallback inside). Tests: a recording stub.
protocol ProactiveSink {
    func send(triggerType: String, payload: [String: Any]) -> Bool
}

/// Owns proactive trigger orchestration: opt-in gating, rate limits, and
/// fan-out to a `ProactiveSink`. Trigger sources (LocationManager,
/// HealthManager, CalendarManager) call `fire(type:payload:)` from any
/// thread that eventually hops to MainActor.
@Observable @MainActor final class ProactiveDispatcher {

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sink: ProactiveSink
    @ObservationIgnored private var lastFireByType: [String: Date] = [:]

    /// Per-trigger minimum interval between successive fires. Zero = no limit.
    @ObservationIgnored static let minIntervalByType: [String: TimeInterval] = [
        "geofence":              60,
        "health_hr_spike":      300,
        "health_sleep_end":    3600,
        "health_workout_end":     0,
        "calendar_warn":          0,
    ]

    init(settings: AppSettings, sink: ProactiveSink) {
        self.settings = settings
        self.sink = sink
    }

    /// Fire a proactive trigger. No-op if disabled in settings or within the
    /// type's min-interval window. Returns true if the event was actually
    /// shipped via the sink.
    @discardableResult
    func fire(type: String, payload: [String: Any]) -> Bool {
        guard settings.proactiveEnabled(type) else { return false }
        let minInt = Self.minIntervalByType[type] ?? 60
        if minInt > 0, let last = lastFireByType[type],
           Date().timeIntervalSince(last) < minInt {
            return false
        }
        lastFireByType[type] = Date()
        return sink.send(triggerType: type, payload: payload)
    }
}

/// Production sink — tries WS first, then POSTs to /ios/proactive over HTTP.
@MainActor final class WebSocketProactiveSink: ProactiveSink {
    private let ws: WebSocketClient
    private let settings: AppSettings

    init(ws: WebSocketClient, settings: AppSettings) {
        self.ws = ws
        self.settings = settings
    }

    nonisolated func send(triggerType: String, payload: [String: Any]) -> Bool {
        Task { @MainActor [ws, settings] in
            if ws.sendProactive(triggerType: triggerType, payload: payload) {
                return  // shipped via WS
            }
            await Self.postOverHTTP(triggerType: triggerType, payload: payload, settings: settings)
        }
        return true
    }

    private static func postOverHTTP(triggerType: String,
                                     payload: [String: Any],
                                     settings: AppSettings) async {
        guard let server = serverHost(from: settings.serverURL),
              let url = URL(string: "\(server)/ios/proactive"),
              !settings.bearerToken.isEmpty else { return }
        let body: [String: Any] = [
            "platformId": settings.platformId,
            "trigger": triggerType,
            "payload": payload,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "tz": TimeZone.current.identifier,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.bearerToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Normalise the user-typed serverURL (host:port) into an http(s) origin.
    private static func serverHost(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "http://" + s
        }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
