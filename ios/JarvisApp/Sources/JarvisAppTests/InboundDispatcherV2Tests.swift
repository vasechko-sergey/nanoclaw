import XCTest
@testable import Jarvis

private final class MockCoordinator: ContextCoordinatorV2 {
    let healthHandler: () async throws -> V2.JSONValue
    let calendarHandler: (String) async throws -> V2.JSONValue
    let deviceHandler: () async throws -> V2.JSONValue
    let nextEventHandler: () async throws -> V2.JSONValue?
    let locationsHandler: (Int) async throws -> V2.JSONValue
    let screenStateHandler: () async throws -> V2.JSONValue
    let remindersHandler: (String) async throws -> V2.JSONValue
    let focusHandler: () async throws -> V2.JSONValue

    init(
        health: @escaping () async throws -> V2.JSONValue = { .object([:]) },
        calendar: @escaping (String) async throws -> V2.JSONValue = { _ in .array([]) },
        device: @escaping () async throws -> V2.JSONValue = { .object([:]) },
        nextEvent: @escaping () async throws -> V2.JSONValue? = { nil },
        locations: @escaping (Int) async throws -> V2.JSONValue = { _ in .array([]) },
        screenState: @escaping () async throws -> V2.JSONValue = { .string("foreground") },
        reminders: @escaping (String) async throws -> V2.JSONValue = { _ in .array([]) },
        focus: @escaping () async throws -> V2.JSONValue = { .object([:]) }
    ) {
        self.healthHandler = health
        self.calendarHandler = calendar
        self.deviceHandler = device
        self.nextEventHandler = nextEvent
        self.locationsHandler = locations
        self.screenStateHandler = screenState
        self.remindersHandler = reminders
        self.focusHandler = focus
    }

    func health() async throws -> V2.JSONValue { try await healthHandler() }
    func calendar(window: String) async throws -> V2.JSONValue { try await calendarHandler(window) }
    func device() async throws -> V2.JSONValue { try await deviceHandler() }
    func nextEvent() async throws -> V2.JSONValue? { try await nextEventHandler() }
    func recentLocations(hours: Int) async throws -> V2.JSONValue {
        try await locationsHandler(hours)
    }
    func screenState() async throws -> V2.JSONValue { try await screenStateHandler() }
    func reminders(window: String) async throws -> V2.JSONValue { try await remindersHandler(window) }
    func focus() async throws -> V2.JSONValue { try await focusHandler() }
}

final class InboundDispatcherV2Tests: XCTestCase {
    func testContextRequestProducesResponseWithRequestedFields() async throws {
        let coord = MockCoordinator(
            health: { .object(["steps": .int(4123)]) },
            calendar: { _ in .array([.object(["title": .string("Standup")])]) },
            device: { .object(["battery": .double(0.5)]) }
        )
        let dispatcher = InboundDispatcherV2(coordinator: coord)
        let response = await dispatcher.gather(requestID: "r-1", fields: ["health", "device"], params: nil)
        XCTAssertEqual(response.request_id, "r-1")
        guard case .object(let obj) = response.data else {
            XCTFail("expected object data")
            return
        }
        XCTAssertNotNil(obj["health"])
        XCTAssertNotNil(obj["device"])
        XCTAssertNil(obj["calendar"])
        XCTAssertNil(response.errors)
    }

    func testFieldErrorsReportedSeparately() async throws {
        let coord = MockCoordinator(
            health: { throw InboundDispatcherFieldError.denied },
            calendar: { _ in .array([]) },
            device: { .object(["battery": .double(0.5)]) },
            locations: { _ in .object([:]) }
        )
        let dispatcher = InboundDispatcherV2(coordinator: coord)
        let response = await dispatcher.gather(requestID: "r-2", fields: ["health", "device"], params: nil)
        guard case .object(let obj) = response.data else {
            XCTFail("expected object data")
            return
        }
        XCTAssertNil(obj["health"])
        XCTAssertEqual(response.errors?["health"], "denied")
        XCTAssertNotNil(obj["device"])
    }

    func testRecentLocationsHonorsHoursParam() async throws {
        actor Captured { var hours: Int = -1; func set(_ v: Int) { hours = v } }
        let captured = Captured()
        let coord = MockCoordinator(
            locations: { h in
                await captured.set(h)
                return .array([])
            }
        )
        let dispatcher = InboundDispatcherV2(coordinator: coord)
        _ = await dispatcher.gather(
            requestID: "r-3",
            fields: ["recent_locations"],
            params: .object(["locations_hours": .int(48)])
        )
        let value = await captured.hours
        XCTAssertEqual(value, 48)
    }

    func testUnsupportedFieldReportedAsError() async throws {
        let coord = MockCoordinator()
        let dispatcher = InboundDispatcherV2(coordinator: coord)
        let response = await dispatcher.gather(requestID: "r-4", fields: ["bogus_field"], params: nil)
        guard case .object(let obj) = response.data else {
            XCTFail("expected object data")
            return
        }
        XCTAssertTrue(obj.isEmpty)
        XCTAssertEqual(response.errors?["bogus_field"], "unsupported")
    }
}
