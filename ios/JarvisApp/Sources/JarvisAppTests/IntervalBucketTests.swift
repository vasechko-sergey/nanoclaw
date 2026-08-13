import XCTest
@testable import Jarvis

/// Sub-daily bucketing. Everything under test is pure — `bucketize` and the two
/// attribution helpers take values, not a HealthKit store — which is the whole
/// reason the derivation stays off the phone: these can be reasoned about, and
/// the metrics built on top of them live in analyze.js where they stay editable.
final class IntervalBucketTests: XCTestCase {

    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: minutes * 60) }

    // MARK: - bucketize

    func testSamplesGroupIntoThirtyMinuteBuckets() {
        let samples = [
            (value: 60.0, date: at(0)), (value: 62.0, date: at(10)), (value: 58.0, date: at(29)),
            (value: 90.0, date: at(31)),
        ]
        let out = HealthHistory.bucketize(samples, metric: "heartRate", widthMin: 30, stageAt: { _ in nil })
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].n, 3)
        XCTAssertEqual(out[0].mean, 60, accuracy: 0.01)
        XCTAssertEqual(out[0].lo, 58)
        XCTAssertEqual(out[0].hi, 62)
        XCTAssertEqual(out[1].n, 1)
        XCTAssertEqual(out[1].mean, 90, accuracy: 0.01)
    }

    /// Aligned to the epoch, not to the first sample: buckets from different days
    /// and different metrics have to line up or they cannot be compared.
    func testBucketStartIsAlignedToTheWidth() {
        let out = HealthHistory.bucketize(
            [(value: 60.0, date: at(47))], metric: "heartRate", widthMin: 30, stageAt: { _ in nil }
        )
        XCTAssertEqual(out[0].start, Int(at(30).timeIntervalSince1970 * 1000))
    }

    func testBucketsComeOutInTimeOrder() {
        let out = HealthHistory.bucketize(
            [(value: 1.0, date: at(200)), (value: 2.0, date: at(10)), (value: 3.0, date: at(100))],
            metric: "hrv", widthMin: 30, stageAt: { _ in nil }
        )
        XCTAssertEqual(out.map(\.start), out.map(\.start).sorted())
    }

    func testStageIsTakenFromTheBucketMidpoint() {
        let out = HealthHistory.bucketize(
            [(value: 55.0, date: at(5))], metric: "heartRate", widthMin: 30, stageAt: { _ in "deep" }
        )
        XCTAssertEqual(out[0].stage, "deep")
    }

    func testEmptyInputYieldsNoBuckets() {
        XCTAssertTrue(HealthHistory.bucketize([], metric: "hrv", widthMin: 30, stageAt: { _ in nil }).isEmpty)
    }

    /// A zero or negative width would divide by zero and emit garbage starts.
    func testNonPositiveWidthYieldsNoBuckets() {
        XCTAssertTrue(
            HealthHistory.bucketize(
                [(value: 60.0, date: at(0))], metric: "heartRate", widthMin: 0, stageAt: { _ in nil }
            ).isEmpty
        )
    }

    // MARK: - stage resolution

    private func sleep(_ stage: HealthHistory.SleepStage, _ fromMin: Double, _ toMin: Double)
        -> HealthHistory.SleepSampleInput {
        .init(stage: stage.rawValue, start: at(fromMin), end: at(toMin))
    }

    /// HealthKit emits an `inBed` interval spanning the whole night AND the staged
    /// intervals inside it, so the two overlap by design. The staged one has to
    /// win or every bucket would read "inBed" and the night/wake split collapses.
    func testAStagedIntervalBeatsAnOverlappingInBedOne() {
        let samples = [sleep(.inBed, 0, 480), sleep(.asleepDeep, 60, 90)]
        XCTAssertEqual(HealthHistory.stageFor(at(75), in: samples), "deep")
        XCTAssertEqual(HealthHistory.stageFor(at(200), in: samples), "inBed")
    }

    func testAMomentOutsideEverySleepIntervalHasNoStage() {
        XCTAssertNil(HealthHistory.stageFor(at(600), in: [sleep(.asleepCore, 0, 480)]))
    }

    /// `asleepUnspecified` is sleep the watch picked up outside a tracked session
    /// — in practice a nap. It shares the neutral `inBed` label on purpose: the
    /// derived metrics count `core|deep|rem` as asleep and `awake|absent` as
    /// awake, so anything labelled `inBed` is excluded from BOTH. A nap must not
    /// join the night's mean, and it is not an awake resting pulse either.
    func testUnstagedSleepIsNeitherAsleepNorAwake() {
        XCTAssertEqual(HealthHistory.stageFor(at(10), in: [sleep(.asleepUnspecified, 0, 60)]), "inBed")
    }

    func testAwakeIntervalsKeepTheirOwnLabel() {
        XCTAssertEqual(HealthHistory.stageFor(at(10), in: [sleep(.awake, 0, 60)]), "awake")
    }

    // MARK: - day attribution

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func moment(_ isoDay: String, _ hour: Int) -> Date {
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return utc.date(byAdding: .hour, value: hour, to: f.date(from: isoDay)!)!
    }

    /// The same rule `bucketOvernight` applies at its evening edge: from 20:00 a
    /// bucket belongs to the day you wake up on, so a night's buckets and that
    /// night's `hrvMorning` describe the same row.
    func testEveningBucketsBelongToTheNextDay() {
        XCTAssertEqual(iso(HealthHistory.intervalDay(moment("2026-08-11", 23), calendar: utc)), "2026-08-12")
        XCTAssertEqual(iso(HealthHistory.intervalDay(moment("2026-08-11", 20), calendar: utc)), "2026-08-12")
    }

    /// Where this parts company with `bucketOvernight`, which drops 11:00–20:00
    /// entirely. Those hours are the awake resting pulse — the signal the
    /// whole-day `heartRate` average was burying.
    func testDaytimeBucketsStayOnTheirOwnDay() {
        XCTAssertEqual(iso(HealthHistory.intervalDay(moment("2026-08-12", 3), calendar: utc)), "2026-08-12")
        XCTAssertEqual(iso(HealthHistory.intervalDay(moment("2026-08-12", 14), calendar: utc)), "2026-08-12")
        XCTAssertEqual(iso(HealthHistory.intervalDay(moment("2026-08-12", 19), calendar: utc)), "2026-08-12")
    }
}
