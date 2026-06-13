import XCTest
@testable import Jarvis

final class StateBoardViewTests: XCTestCase {
    func testFreshnessLabel() {
        XCTAssertEqual(StateBoardView.freshness(updated: "2026-06-13", today: "2026-06-13"), .today)
        XCTAssertEqual(StateBoardView.freshness(updated: "2026-06-12", today: "2026-06-13"), .stale)
        XCTAssertEqual(StateBoardView.freshness(updated: nil, today: "2026-06-13"), .unknown)
    }
}
