import CoreLocation
import Foundation
import UIKit

/// Production `ContextCoordinatorV2` implementation that bridges the existing
/// per-feature managers (`LocationManager`, `HealthManager`, `CalendarManager`)
/// into the V2 protocol's `context_request` field surface.
///
/// Each manager is optional so a partially-authorized device (e.g. HealthKit denied)
/// still produces a useful response. Missing managers map to empty values, not errors —
/// the agent treats "field present, value empty" as "user has it off", which matches
/// the unknown-sender / opt-in story everywhere else in the app.
///
/// All UI-touching reads go through `@MainActor.run`. The managers themselves
/// (HealthManager / CalendarManager) are not `@MainActor`-isolated but mutate their
/// public state on the main queue via `DispatchQueue.main.async`, so we read them
/// from the main thread to avoid torn reads.
final class AppContextCoordinator: ContextCoordinatorV2 {
    private let locationManager: LocationManager?
    private let healthManager: HealthManager?
    private let calendarManager: CalendarManager?

    init(
        location: LocationManager? = nil,
        health: HealthManager? = nil,
        calendar: CalendarManager? = nil
    ) {
        self.locationManager = location
        self.healthManager = health
        self.calendarManager = calendar
    }

    // MARK: - ContextCoordinatorV2

    func health() async throws -> V2.JSONValue {
        guard let h = healthManager else { return .object([:]) }
        // Kick a fresh fetch (cheap; cached HKHealthStore reads). The fields read
        // below come from whatever's currently cached on the manager.
        await MainActor.run { h.requestAndFetch() }
        let steps = await MainActor.run { h.steps }
        let hr = await MainActor.run { h.heartRate }
        let restingHR = await MainActor.run { h.restingHeartRate }
        let active = await MainActor.run { h.activeEnergy }
        let sleep = await MainActor.run { h.sleepHours }
        let exercise = await MainActor.run { h.exerciseMinutes }
        let bodyMass = await MainActor.run { h.bodyMass }
        let height = await MainActor.run { h.height }

        var obj: [String: V2.JSONValue] = [:]
        if let v = steps { obj["steps_today"] = .int(v) }
        if let v = hr { obj["hr_latest"] = .int(v) }
        if let v = restingHR { obj["hr_resting"] = .int(v) }
        if let v = active { obj["active_energy"] = .int(v) }
        if let v = sleep { obj["sleep_hours"] = .double(v) }
        if let v = exercise { obj["exercise_minutes"] = .int(v) }
        if let v = bodyMass { obj["body_mass_kg"] = .double(v) }
        if let v = height { obj["height_m"] = .double(v) }
        return .object(obj)
    }

    func calendar(window: String = "today") async throws -> V2.JSONValue {
        guard let c = calendarManager else { return .array([]) }
        let evs = await MainActor.run { c.events(window: window) }
        let iso = ISO8601DateFormatter()
        return .array(evs.map { e in
            .object([
                "title": .string(e.title),
                "start": .string(iso.string(from: e.start)),
                "end":   .string(iso.string(from: e.end)),
            ])
        })
    }

    func device() async throws -> V2.JSONValue {
        let snapshot = await MainActor.run { () -> (String, String, Float) in
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            return (device.model, device.systemVersion, device.batteryLevel)
        }
        var obj: [String: V2.JSONValue] = [
            "model": .string(snapshot.0),
            "os_version": .string(snapshot.1),
        ]
        // batteryLevel returns -1.0 when monitoring is unavailable; only include
        // when the OS gave us a real value.
        if snapshot.2 >= 0 {
            obj["battery"] = .double(Double(snapshot.2))
        }
        return .object(obj)
    }

    func nextEvent() async throws -> V2.JSONValue? {
        guard let c = calendarManager else { return nil }
        let next: (title: String, start: Date)? = await MainActor.run { c.nextEvent }
        guard let next else { return nil }
        return .object([
            "title": .string(next.title),
            "start": .string(ISO8601DateFormatter().string(from: next.start)),
        ])
    }

    func recentLocations(hours: Int) async throws -> V2.JSONValue {
        guard let l = locationManager else { return .array([]) }
        // The legacy LocationManager doesn't keep a history — only `lastLocation`.
        // Return that one point (if recent enough) so the agent has something to
        // work with. A real history buffer is tracked as a follow-up.
        // TODO: add a ring-buffer of recent CLLocations to LocationManager and
        //       return the last `hours` worth here.
        let snapshot: (CLLocation?, String?) = await MainActor.run {
            (l.lastLocation, l.cityName)
        }
        guard let loc = snapshot.0 else { return .array([]) }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        guard loc.timestamp >= cutoff else { return .array([]) }
        var entry: [String: V2.JSONValue] = [
            "lat": .double(loc.coordinate.latitude),
            "lon": .double(loc.coordinate.longitude),
            "ts": .string(ISO8601DateFormatter().string(from: loc.timestamp)),
        ]
        if let city = snapshot.1 { entry["locality"] = .string(city) }
        return .array([.object(entry)])
    }

    func screenState() async throws -> V2.JSONValue {
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        return .string(active ? "foreground" : "background")
    }

    func reminders(window: String = "today") async throws -> V2.JSONValue {
        guard let c = calendarManager else { return .array([]) }
        let items = await c.reminders(window: window)
        let iso = ISO8601DateFormatter()
        return .array(items.map { r in
            var o: [String: V2.JSONValue] = ["title": .string(r.title)]
            if let d = r.due { o["due"] = .string(iso.string(from: d)) }
            return .object(o)
        })
    }

    func focus() async throws -> V2.JSONValue {
        let manager = FocusManager()
        guard let isFocused = await manager.isFocused() else { return .object([:]) }
        return .object(["is_focused": .bool(isFocused)])
    }
}

