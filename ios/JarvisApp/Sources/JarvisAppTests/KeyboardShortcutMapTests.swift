import XCTest
@testable import Jarvis

final class KeyboardShortcutMapTests: XCTestCase {
    func testNumberKeyMapsToAgentByOrder() {
        XCTAssertEqual(AgentShortcuts.agent(forNumber: 1), .jarvis)
        XCTAssertEqual(AgentShortcuts.agent(forNumber: 5), AgentIdentity.allCases[4])
        XCTAssertNil(AgentShortcuts.agent(forNumber: 6))
        XCTAssertNil(AgentShortcuts.agent(forNumber: 0))
    }
}
