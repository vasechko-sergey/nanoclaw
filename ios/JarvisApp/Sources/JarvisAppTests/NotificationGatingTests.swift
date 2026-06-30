import XCTest
@testable import Jarvis

final class NotificationGatingTests: XCTestCase {
    func testQuietHoursOvernightWrap() {
        // 23:00 (1380) → 08:00 (480)
        XCTAssertTrue(QuietHours.contains(minutes: 1410, start: 1380, end: 480, enabled: true))  // 23:30
        XCTAssertTrue(QuietHours.contains(minutes: 420, start: 1380, end: 480, enabled: true))   // 07:00
        XCTAssertTrue(QuietHours.contains(minutes: 1380, start: 1380, end: 480, enabled: true))  // exactly 23:00
        XCTAssertFalse(QuietHours.contains(minutes: 480, start: 1380, end: 480, enabled: true))  // exactly 08:00
        XCTAssertFalse(QuietHours.contains(minutes: 720, start: 1380, end: 480, enabled: true))  // 12:00
    }

    func testQuietHoursSameDayWindow() {
        // 08:00 (480) → 23:00 (1380)
        XCTAssertTrue(QuietHours.contains(minutes: 600, start: 480, end: 1380, enabled: true))   // 10:00
        XCTAssertFalse(QuietHours.contains(minutes: 60, start: 480, end: 1380, enabled: true))   // 01:00
        XCTAssertFalse(QuietHours.contains(minutes: 1380, start: 480, end: 1380, enabled: true)) // exactly 23:00
    }

    func testQuietHoursDisabledOrZeroWidth() {
        XCTAssertFalse(QuietHours.contains(minutes: 1410, start: 1380, end: 480, enabled: false))
        XCTAssertFalse(QuietHours.contains(minutes: 600, start: 600, end: 600, enabled: true))
    }

    func testMutedAgentsRoundTrip() {
        XCTAssertEqual(MutedAgents.decode("[]"), [])
        XCTAssertEqual(MutedAgents.decode("garbage"), [])
        let encoded = MutedAgents.encode(["greg", "gordon"])
        XCTAssertEqual(MutedAgents.decode(encoded), ["greg", "gordon"])
    }
}
