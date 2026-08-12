import XCTest
@testable import Jarvis

/// A wake day's sleep was reduced with min(start)/max(end) over every interval,
/// so a nap and the night that followed it merged. On 2026-08-09 a 72-minute
/// afternoon sleep at 14:39 joined the 23:17 night, sleepOnsetMin became −560,
/// sleepRegularity scored mod_z 19.53, and Greg sent Jarvis a `critical` finding
/// about a circadian collapse that never happened.
///
/// Two markers separate them, measured on 61 real nights:
///   • stage classification — the watch only assigns phases inside a tracked
///     session, so ad-hoc sleep arrives as asleepUnspecified. 1,726 of 1,734
///     intervals staged; all 8 unstaged ones are sleep outside the night.
///   • a 2-hour gap — the gap distribution is empty between 120 and 240 minutes.
final class SleepBlockSplitTests: XCTestCase {

    private let cal = Calendar.current
    private typealias Input = HealthHistory.SleepSampleInput

    private func iv(_ stage: HealthHistory.SleepStage,
                    day: Int, _ h1: Int, _ m1: Int, toDay: Int? = nil, _ h2: Int, _ m2: Int) -> Input {
        let s = cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: h1, minute: m1))!
        let e = cal.date(from: DateComponents(year: 2026, month: 8, day: toDay ?? day, hour: h2, minute: m2))!
        return Input(stage: stage.rawValue, start: s, end: e)
    }

    // MARK: - splitSleepBlocks

    func testAfternoonNapSplitsFromTheNight() {
        // The real 2026-08-09 shape: a 72-minute nap, then the night.
        let blocks = HealthHistory.splitSleepBlocks([
            iv(.asleepUnspecified, day: 9, 14, 39, 15, 52),
            iv(.asleepCore, day: 9, 23, 17, toDay: 10, 7, 32),
        ], gapMin: 120)
        XCTAssertEqual(blocks.count, 2)
    }

    func testOneNightWithAShortAwakeningStaysOneBlock() {
        // Measured: 419 of the gaps between intervals are under 15 minutes, and
        // every gap in the 30–120 band is a mid-night awakening, not a boundary.
        let blocks = HealthHistory.splitSleepBlocks([
            iv(.asleepCore, day: 11, 23, 20, toDay: 12, 2, 28),
            iv(.asleepREM, day: 12, 3, 32, 7, 20),   // 64-minute awakening between
        ], gapMin: 120)
        XCTAssertEqual(blocks.count, 1, "a 64-minute gap is an awakening, not a new session")
    }

    func testEmptyInputYieldsNoBlocks() {
        XCTAssertTrue(HealthHistory.splitSleepBlocks([], gapMin: 120).isEmpty)
    }

    // MARK: - blockMinutes

    func testBlockMinutesCountsAsleepOnly() {
        let block = [
            iv(.asleepCore, day: 12, 0, 0, 1, 0),   // 60
            iv(.awake, day: 12, 1, 0, 1, 30),       // not counted
            iv(.asleepDeep, day: 12, 1, 30, 2, 0),  // 30
        ]
        XCTAssertEqual(HealthHistory.blockMinutes(block), 90, accuracy: 0.01)
    }

    // MARK: - isStagedBlock

    func testUnstagedBlockIsNotTheNight() {
        XCTAssertFalse(HealthHistory.isStagedBlock([iv(.asleepUnspecified, day: 9, 14, 39, 15, 52)]))
        XCTAssertTrue(HealthHistory.isStagedBlock([iv(.asleepCore, day: 9, 23, 17, 23, 59)]))
    }

    func testAStrayUnstagedFragmentDoesNotDisqualifyTheNight() {
        // Half, not all: a staged night can carry one unspecified fragment.
        let block = [
            iv(.asleepCore, day: 12, 0, 0, 4, 0),           // 240 staged
            iv(.asleepUnspecified, day: 12, 4, 0, 4, 20),   // 20 unstaged
        ]
        XCTAssertTrue(HealthHistory.isStagedBlock(block))
    }

    func testBlockWithNoSleepAtAllIsNotStaged() {
        XCTAssertFalse(HealthHistory.isStagedBlock([iv(.awake, day: 12, 3, 0, 3, 30)]))
    }

    // MARK: - splitStagedRuns

    func testUnstagedMorningDozeSeparatesDespiteAShortGap() {
        // The real 2026-07-01: the doze follows a 47-minute gap, so the 120-minute
        // split keeps it in one block — the stage marker is what separates it.
        let night = iv(.asleepCore, day: 1, 0, 57, 4, 28)
        let doze  = iv(.asleepUnspecified, day: 1, 5, 15, 7, 16)
        let blocks = HealthHistory.splitSleepBlocks([night, doze], gapMin: 120)
        XCTAssertEqual(blocks.count, 1, "47-minute gap keeps them in one block")

        let runs = HealthHistory.splitStagedRuns(blocks[0])
        XCTAssertEqual(runs.night.count, 1)
        XCTAssertEqual(runs.outside.count, 1)
        XCTAssertEqual(HealthHistory.blockMinutes(runs.outside), 121, accuracy: 0.01)
    }

    func testAwakeIntervalsStayWithTheNight() {
        let runs = HealthHistory.splitStagedRuns([
            iv(.asleepCore, day: 12, 0, 0, 1, 0),
            iv(.awake, day: 12, 1, 0, 1, 20),
            iv(.asleepREM, day: 12, 1, 20, 3, 0),
        ])
        XCTAssertEqual(runs.night.count, 3)
        XCTAssertTrue(runs.outside.isEmpty)
    }

    // MARK: - end to end

    func testNapNoLongerBecomesTheNightsOnset() {
        let dayStart = cal.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let samples = [
            iv(.asleepUnspecified, day: 9, 14, 39, 15, 52),          // 73 min nap
            iv(.asleepCore, day: 9, 23, 17, toDay: 10, 3, 0),        // night, part 1
            iv(.asleepDeep, day: 10, 3, 0, 7, 32),                   // night, part 2
        ]
        let r = HealthHistory.reduceSleepDay(samples, dayStart: dayStart)

        // Onset is 23:17 on the 9th = −43 minutes from the 10th's midnight.
        // Before this change it was −560, taken from the nap.
        XCTAssertEqual(r.stages.onsetMin, -43)
        XCTAssertEqual(r.napMin, 73)
        XCTAssertEqual(r.napCount, 1)
        // Night sleep only: 3h43m + 4h32m = 8h15m.
        XCTAssertEqual(r.stages.sleepHours, 8.3, accuracy: 0.05)
    }

    func testAPlainNightReportsNoNap() {
        let dayStart = cal.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let r = HealthHistory.reduceSleepDay([
            iv(.asleepCore, day: 11, 23, 20, toDay: 12, 7, 20),
        ], dayStart: dayStart)
        XCTAssertEqual(r.napMin, 0)
        XCTAssertEqual(r.napCount, 0)
        XCTAssertEqual(r.stages.onsetMin, -40)
    }
}
