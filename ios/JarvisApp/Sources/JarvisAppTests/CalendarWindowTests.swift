import XCTest
import EventKit
@testable import Jarvis

final class CalendarWindowTests: XCTestCase {
    func testWindowEndForNext7d() {
        let start = ISO8601DateFormatter().date(from: "2026-06-14T00:00:00Z")!
        let end = CalendarManager.windowEnd(window: "next_7d", from: start)
        XCTAssertEqual(end.timeIntervalSince(start), 7 * 24 * 3600, accuracy: 1)
    }
    func testWindowEndDefaultsToToday() {
        let start = ISO8601DateFormatter().date(from: "2026-06-14T00:00:00Z")!
        let end = CalendarManager.windowEnd(window: "today", from: start)
        XCTAssertEqual(end.timeIntervalSince(start), 24 * 3600, accuracy: 1)
    }
    func testWindowEndForNext30d() {
        let start = ISO8601DateFormatter().date(from: "2026-06-14T00:00:00Z")!
        let end = CalendarManager.windowEnd(window: "next_30d", from: start)
        XCTAssertEqual(end.timeIntervalSince(start), 30 * 24 * 3600, accuracy: 1)
    }
}
