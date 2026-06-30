import XCTest
@testable import Jarvis

@MainActor
final class CoordinatorNavTests: XCTestCase {
    func testNavIntents() {
        let c = AppCoordinator(settings: AppSettings())
        XCTAssertFalse(c.pendingOpenSummaryBoard)
        XCTAssertNil(c.pendingOpenAgentChat)
        c.requestOpenSummaryBoard()
        XCTAssertTrue(c.pendingOpenSummaryBoard)
        c.requestOpenAgentChat(.greg)
        XCTAssertEqual(c.pendingOpenAgentChat, .greg)
    }
}
