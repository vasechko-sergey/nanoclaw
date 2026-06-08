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
}
