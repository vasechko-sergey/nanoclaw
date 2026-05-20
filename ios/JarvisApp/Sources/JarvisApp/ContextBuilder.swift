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
            if let s  = health.steps        { h["steps"]        = s  }
            if let hr = health.heartRate     { h["heartRate"]    = hr }
            if let ae = health.activeEnergy  { h["activeEnergy"] = ae }
            if !h.isEmpty { ctx["health"] = h }
        }

        let notes = settings.customContext
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !notes.isEmpty { ctx["custom"] = notes }

        return ctx.isEmpty ? nil : ctx
    }
}
