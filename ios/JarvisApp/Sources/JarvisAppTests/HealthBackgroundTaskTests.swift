import XCTest
@testable import Jarvis

final class HealthBackgroundTaskTests: XCTestCase {
    /// Fixed UTC calendar so the date math is timezone- and DST-independent.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return calendar.date(from: c)!
    }

    func test_beforeMorning_returnsSameDayAt0800() {
        let now = date(2026, 6, 12, 6, 30)
        let run = HealthBackgroundTask.nextRun(after: now, calendar: calendar, hour: 8)
        XCTAssertEqual(run, date(2026, 6, 12, 8, 0))
    }

    func test_afterMorning_returnsNextDayAt0800() {
        let now = date(2026, 6, 12, 10, 15)
        let run = HealthBackgroundTask.nextRun(after: now, calendar: calendar, hour: 8)
        XCTAssertEqual(run, date(2026, 6, 13, 8, 0))
    }

    func test_exactlyMorning_returnsNextDay() {
        // 08:00 is not strictly after 08:00, so the next eligible run is tomorrow.
        let now = date(2026, 6, 12, 8, 0)
        let run = HealthBackgroundTask.nextRun(after: now, calendar: calendar, hour: 8)
        XCTAssertEqual(run, date(2026, 6, 13, 8, 0))
    }

    func test_afterMorningOnMonthBoundary_rollsToFirstOfNextMonth() {
        // 30 June 09:00 → 1 July 08:00: the +1 day add crosses the month boundary.
        let now = date(2026, 6, 30, 9, 0)
        let run = HealthBackgroundTask.nextRun(after: now, calendar: calendar, hour: 8)
        XCTAssertEqual(run, date(2026, 7, 1, 8, 0))
    }
}
