import XCTest
@testable import Jarvis

final class AgentIdentityTests: XCTestCase {
    func testScroogeIsAValidCase() {
        XCTAssertTrue(AgentIdentity.allCases.contains(.scrooge))
        XCTAssertEqual(AgentIdentity(rawValue: "scrooge"), .scrooge)
        XCTAssertEqual(AgentIdentity.scrooge.rawValue, "scrooge")
        XCTAssertFalse(AgentIdentity.scrooge.displayName.isEmpty)
    }

    func testGordonIsAValidCase() {
        XCTAssertTrue(AgentIdentity.allCases.contains(.gordon))
        XCTAssertEqual(AgentIdentity(rawValue: "gordon"), .gordon)
        XCTAssertEqual(AgentIdentity.gordon.rawValue, "gordon")
        XCTAssertEqual(AgentIdentity.gordon.displayName, "Ramzi")
    }
}
