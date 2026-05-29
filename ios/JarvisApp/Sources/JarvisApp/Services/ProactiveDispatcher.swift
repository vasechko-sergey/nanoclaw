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
