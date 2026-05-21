import Foundation

struct ContextBuilder {
    static func build(
        settings: AppSettings,
        location: LocationManager,
        health: HealthManager
    ) -> [String: Any]? {
        var ctx: [String: Any] = [:]

        if settings.useLocation, let loc = location.lastLocation {
            ctx["location"] = [
                "lat":  (loc.coordinate.latitude  * 1e4).rounded() / 1e4,
                "lon":  (loc.coordinate.longitude * 1e4).rounded() / 1e4,
                "city": location.cityName ?? "",
            ]
        }

        if settings.useHealth {
            var h: [String: Any] = [:]
            if let s   = health.steps            { h["steps"]            = s   }
            if let hr  = health.heartRate         { h["heartRate"]        = hr  }
            if let ae  = health.activeEnergy      { h["activeEnergy"]     = ae  }
            if let sh  = health.sleepHours        { h["sleepHours"]       = sh  }
            if let rhr = health.restingHeartRate  { h["restingHeartRate"] = rhr }
            if let ex  = health.exerciseMinutes   { h["exerciseMinutes"]  = ex  }
            if !h.isEmpty { ctx["health"] = h }
        }

        let emoji = settings.statusEmoji.trimmingCharacters(in: .whitespaces)
        if !emoji.isEmpty { ctx["status"] = emoji }

        // Device-side timestamp and timezone so the server renders the correct local time.
        ctx["timestamp"] = ISO8601DateFormatter().string(from: Date())
        ctx["timezone"] = TimeZone.current.identifier

        return ctx.isEmpty ? nil : ctx
    }
}
