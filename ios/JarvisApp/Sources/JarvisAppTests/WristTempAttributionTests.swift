import XCTest
@testable import Jarvis

/// Sleeping wrist temperature was the only overnight metric not filed on the
/// wake day. Measured against a raw HealthKit dump of 58 samples: 52 landed on
/// the day sleep BEGAN, 2 on the wake day. On the reference illness that put the
/// fever peak (36.19 °C, night of 08-10 → 08-11) under 08-10, and left 08-12 —
/// the day the sick-day rule ran — null, when the real value was 35.98.
final class WristTempAttributionTests: XCTestCase {

    private let cal = Calendar.current

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    /// A sleep interval beginning 23:20 on the 11th and ending 07:20 on the 12th
    /// describes the night of the 12th, and belongs where hrvMorning, spo2 and
    /// the sleep phases for that same night already go.
    func testOvernightIntervalIsFiledOnTheWakeDay() {
        let start = date(11, 23, 20)
        XCTAssertEqual(
            HealthHistory.sleepWakeDay(start: start, calendar: cal),
            cal.startOfDay(for: date(12, 0, 0))
        )
    }

    /// Bed after midnight: start day and wake day are already the same, so the
    /// correction must be a no-op rather than pushing it a further day out.
    /// This is the common case here — bedtime sits right on midnight.
    func testAfterMidnightIntervalStaysOnItsOwnDay() {
        let start = date(6, 1, 20)
        XCTAssertEqual(
            HealthHistory.sleepWakeDay(start: start, calendar: cal),
            cal.startOfDay(for: start)
        )
    }

    /// The noon cutoff is what separates the two cases; pin it so a later change
    /// to `sleepWakeDay` cannot silently re-break the temperature reader.
    func testNoonIsTheCutoff() {
        XCTAssertEqual(
            HealthHistory.sleepWakeDay(start: date(9, 11, 59), calendar: cal),
            cal.startOfDay(for: date(9, 0, 0))
        )
        XCTAssertEqual(
            HealthHistory.sleepWakeDay(start: date(9, 12, 0), calendar: cal),
            cal.startOfDay(for: date(10, 0, 0))
        )
    }
}
