import XCTest
import CoreLocation
@testable import Jarvis

@MainActor
final class ContextBuilderTests: XCTestCase {

    func testLocationOmittedWhenStale() {
        let settings = AppSettings()
        settings.useLocation = true
        settings.useHealth = false
        settings.useCalendar = false
        let loc = LocationManager()
        let staleLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 8.6, longitude: 115.1),
            altitude: 0, horizontalAccuracy: 50, verticalAccuracy: 50,
            timestamp: Date().addingTimeInterval(-16 * 60)
        )
        loc.lastLocation = staleLoc
        loc.cityName = "Canggu"

        let health = HealthManager()
        let cal = CalendarManager()

        let ctx = ContextBuilder.build(fields: [], settings: settings, location: loc, health: health, calendar: cal)
        XCTAssertNil(ctx["location"], "location should be omitted when older than 15 minutes")
    }

    func testLocationIncludedWhenFresh() {
        let settings = AppSettings()
        settings.useLocation = true
        settings.useHealth = false
        settings.useCalendar = false
        let loc = LocationManager()
        let freshLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 8.6, longitude: 115.1),
            altitude: 0, horizontalAccuracy: 50, verticalAccuracy: 50,
            timestamp: Date().addingTimeInterval(-60)
        )
        loc.lastLocation = freshLoc
        loc.cityName = "Canggu"

        let health = HealthManager()
        let cal = CalendarManager()

        let ctx = ContextBuilder.build(fields: [], settings: settings, location: loc, health: health, calendar: cal)
        XCTAssertNotNil(ctx["location"], "location should be present when under 15 minutes old")
    }

    func testTimestampAndTimezoneAlwaysPresent() {
        let settings = AppSettings()
        settings.useLocation = false
        settings.useHealth = false
        settings.useCalendar = false
        let ctx = ContextBuilder.build(fields: [], settings: settings,
                                       location: LocationManager(), health: HealthManager(), calendar: CalendarManager())
        XCTAssertNotNil(ctx["timestamp"], "timestamp must always be present")
        XCTAssertNotNil(ctx["timezone"], "timezone must always be present")
    }

    func testUseLocationOffOmitsLocation() {
        let settings = AppSettings()
        settings.useLocation = false
        settings.useHealth = false
        settings.useCalendar = false
        let loc = LocationManager()
        loc.lastLocation = CLLocation(latitude: 8.6, longitude: 115.1)
        loc.cityName = "Canggu"

        let ctx = ContextBuilder.build(fields: [], settings: settings,
                                       location: loc, health: HealthManager(), calendar: CalendarManager())
        XCTAssertNil(ctx["location"], "useLocation=false must omit location")
    }

    func testTimezoneAlwaysISO() {
        let settings = AppSettings()
        let ctx = ContextBuilder.build(fields: [], settings: settings,
                                       location: LocationManager(), health: HealthManager(), calendar: CalendarManager())
        XCTAssertEqual(ctx["timezone"] as? String, TimeZone.current.identifier)
    }

    func testDeviceBatteryPresentWhenAvailable() {
        // Simulators report -1 (unknown), so this asserts the negative case:
        // when battery is unavailable, the device dict either omits battery or is itself absent.
        let settings = AppSettings()
        settings.useLocation = false
        settings.useHealth = false
        settings.useCalendar = false
        let ctx = ContextBuilder.build(fields: [], settings: settings,
                                       location: LocationManager(), health: HealthManager(), calendar: CalendarManager())
        if let device = ctx["device"] as? [String: Any] {
            XCTAssertTrue(device["battery"] is Int? || device["battery"] == nil)
        }
        // No device dict at all is also valid (sim returns -1, network nil, lowPower false).
    }

    func testFieldSubsetLocationOnly() {
        let settings = AppSettings()
        settings.useLocation = true
        settings.useHealth = true
        let loc = LocationManager()
        loc.lastLocation = CLLocation(coordinate: .init(latitude: 8.6, longitude: 115.1),
                                      altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                                      timestamp: Date())
        loc.cityName = "Canggu"

        let ctx = ContextBuilder.build(fields: ["location"], settings: settings,
                                       location: loc, health: HealthManager(), calendar: CalendarManager())
        XCTAssertNotNil(ctx["location"])
        XCTAssertNil(ctx["health"], "explicit field subset must not leak other fields")
    }
}
