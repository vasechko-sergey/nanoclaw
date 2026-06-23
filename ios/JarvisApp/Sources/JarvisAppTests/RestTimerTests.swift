import XCTest
@testable import Jarvis

final class RestTimerTests: XCTestCase {

    func test_effectiveDuration_failureSetAddsRest() {
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 120, rir: 0), 150)
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 60, rir: 0), 90)
    }

    func test_effectiveDuration_easySetCutsRest() {
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 120, rir: 4), 105)
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 120, rir: 5), 105)
    }

    func test_effectiveDuration_neutralRangeHoldsPlanned() {
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 120, rir: 1), 120)
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 120, rir: 2), 120)
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 120, rir: 3), 120)
    }

    func test_effectiveDuration_neverBelowFloor() {
        // Easy set on a short planned rest must clamp to 30s minimum.
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 40, rir: 4), 30)
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 30, rir: 4), 30)
        XCTAssertEqual(RestTimer.effectiveDuration(planned: 20, rir: 4), 30)
    }

    @MainActor
    func test_start_setsRemainingAndRunning() {
        let timer = RestTimer()
        timer.start(planned: 60, lastRepsInReserve: 2)
        XCTAssertEqual(timer.remainingSec, 60)
        XCTAssertTrue(timer.running)
        timer.skip()
        XCTAssertFalse(timer.running)
    }

    @MainActor
    func test_start_setsTotalAndProgressZero() {
        let timer = RestTimer()
        timer.start(planned: 120, lastRepsInReserve: 2)   // rir 2 → planned
        XCTAssertEqual(timer.totalSec, 120)
        XCTAssertEqual(timer.progress, 0, accuracy: 0.001)
        timer.skip()
    }

    @MainActor
    func test_totalReflectsAdaptedDuration() {
        let timer = RestTimer()
        timer.start(planned: 120, lastRepsInReserve: 0)   // +30
        XCTAssertEqual(timer.totalSec, 150)
        timer.skip()
    }

    @MainActor
    func test_skipResetsTotal() {
        let timer = RestTimer()
        timer.start(planned: 90, lastRepsInReserve: 2)
        timer.skip()
        XCTAssertEqual(timer.totalSec, 0)
        XCTAssertEqual(timer.progress, 0, accuracy: 0.001)
    }
}
