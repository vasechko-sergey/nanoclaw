import Foundation
import UIKit

struct ContextBuilder {
    /// Reused formatter — allocating `ISO8601DateFormatter()` per call is costly
    /// and `build` runs on every context request (twice internally).
    private static let iso = ISO8601DateFormatter()

    /// Собирает контекст по запросу агента (pull-модель). `fields` — какие
    /// разделы нужны: "location" | "health" | "device" | "calendar".
    /// Пустой набор трактуется как «все». Настройки приватности (useLocation и т.д.)
    /// всё равно соблюдаются. Всегда добавляются timestamp и timezone.
    @MainActor static func build(
        fields: [String],
        settings: AppSettings,
        location: LocationManager,
        health: HealthManager,
        calendar: CalendarManager
    ) -> [String: Any] {
        // The per-message context (empty `fields`) is the CHEAP always-attached
        // block: cached location, device, calendar, time. Health is deliberately
        // excluded here — HealthKit reads are expensive and health flows to the
        // agent two other ways: the on-demand pull `request_context(["health"])`
        // (which lands in `fields` below) and the periodic health-upload to the
        // host. So an explicit "health" request still returns it; the default
        // does not.
        let want = fields.isEmpty ? ["location", "device", "calendar"] : fields
        var ctx: [String: Any] = [:]

        if want.contains("location"), settings.useLocation, let loc = location.lastLocation,
           Date().timeIntervalSince(loc.timestamp) < 15 * 60 {
            ctx["location"] = [
                "lat":  (loc.coordinate.latitude  * 1e4).rounded() / 1e4,
                "lon":  (loc.coordinate.longitude * 1e4).rounded() / 1e4,
                "city": location.cityName ?? "",
            ]
        }

        if want.contains("health"), settings.useHealth {
            var h: [String: Any] = [:]
            if let s   = health.steps            { h["steps"]            = s   }
            if let hr  = health.heartRate         { h["heartRate"]        = hr  }
            if let ae  = health.activeEnergy      { h["activeEnergy"]     = ae  }
            if let sh  = health.sleepHours        { h["sleepHours"]       = sh  }
            if let rhr = health.restingHeartRate  { h["restingHeartRate"] = rhr }
            if let ex  = health.exerciseMinutes   { h["exerciseMinutes"]  = ex  }
            if !h.isEmpty { ctx["health"] = h }
        }

        if want.contains("device") {
            var device: [String: Any] = [:]
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            if level >= 0 { device["battery"] = Int((level * 100).rounded()) }
            if ProcessInfo.processInfo.isLowPowerModeEnabled { device["lowPower"] = true }
            let net = ConnectivityMonitor.shared.status
            if !net.isEmpty { device["network"] = net }
            if !device.isEmpty { ctx["device"] = device }
        }

        if want.contains("calendar"), settings.useCalendar, let ev = calendar.nextEvent {
            ctx["nextEvent"] = [
                "title": ev.title,
                "start": iso.string(from: ev.start),
            ]
        }

        let emoji = settings.statusEmoji.trimmingCharacters(in: .whitespaces)
        if !emoji.isEmpty { ctx["status"] = emoji }

        // Device-side timestamp and timezone so the server renders the correct local time.
        ctx["timestamp"] = iso.string(from: Date())
        ctx["timezone"] = TimeZone.current.identifier

        return ctx
    }
}
