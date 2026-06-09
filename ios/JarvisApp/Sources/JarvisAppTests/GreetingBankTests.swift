import XCTest
@testable import Jarvis

final class GreetingBankTests: XCTestCase {
    func testScroogeHasGreetingsForEverySlot() {
        for slot in [TimeSlot.morning, .day, .evening, .night] {
            XCTAssertFalse(GreetingBank.pick(agent: .scrooge, slot: slot).isEmpty)
        }
    }
}
