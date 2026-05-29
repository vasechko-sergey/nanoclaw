import XCTest
@testable import Jarvis

@MainActor
final class ProactiveDispatcherTests: XCTestCase {

    /// Records every call the dispatcher tried to ship (WS or HTTP).
    final class RecorderSink: ProactiveSink {
        var calls: [(type: String, payload: [String: Any])] = []
        func send(triggerType: String, payload: [String: Any]) -> Bool {
            calls.append((triggerType, payload))
            return true
        }
    }

    private func makeSettings(allOn: Bool = true) -> AppSettings {
        let s = AppSettings()
        s.proactiveGeofence = allOn
        s.proactiveHealthHR = allOn
        s.proactiveHealthSleep = allOn
        s.proactiveHealthWorkout = allOn
        s.proactiveCalendarWarn = allOn
        return s
    }

    func testRateLimitCollapsesRepeatsWithinInterval() {
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: makeSettings(), sink: sink)
        d.fire(type: "geofence", payload: [:])
        d.fire(type: "geofence", payload: [:])
        XCTAssertEqual(sink.calls.count, 1, "geofence has 60s min-interval — second call collapses")
    }

    func testDifferentTypesNotRateLimitedAgainstEachOther() {
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: makeSettings(), sink: sink)
        d.fire(type: "geofence", payload: [:])
        d.fire(type: "health_hr_spike", payload: [:])
        XCTAssertEqual(sink.calls.count, 2)
    }

    func testDisabledTypeIsSilenced() {
        let s = makeSettings(allOn: true)
        s.proactiveGeofence = false
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: s, sink: sink)
        d.fire(type: "geofence", payload: ["lat": 1.0])
        XCTAssertTrue(sink.calls.isEmpty)
    }

    func testGeofencePayloadShape() {
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: makeSettings(), sink: sink)
        d.fire(type: "geofence", payload: ["lat": 8.6, "lon": 115.1, "city": "Canggu"])
        XCTAssertEqual(sink.calls.count, 1)
        let p = sink.calls.first!.payload
        XCTAssertEqual(p["lat"] as? Double, 8.6)
        XCTAssertEqual(p["lon"] as? Double, 115.1)
        XCTAssertEqual(p["city"] as? String, "Canggu")
    }

    func testHrSpikePayloadIsEmpty() {
        let sink = RecorderSink()
        let d = ProactiveDispatcher(settings: makeSettings(), sink: sink)
        d.fire(type: "health_hr_spike", payload: [:])
        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertTrue((sink.calls.first!.payload as [String: Any]).isEmpty,
                      "HR spike must not leak any data — payload empty by contract")
    }
}
