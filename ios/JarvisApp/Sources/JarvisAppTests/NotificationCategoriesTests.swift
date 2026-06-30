import XCTest
import UserNotifications
@testable import Jarvis

final class NotificationCategoriesTests: XCTestCase {
    func testAgentMessageCategory() {
        let c = NotificationCategories.agentMessageCategory()
        XCTAssertEqual(c.identifier, "agent-message")
        XCTAssertEqual(c.actions.count, 1)
        XCTAssertEqual(c.actions.first?.identifier, "reply")
        XCTAssertTrue(c.actions.first is UNTextInputNotificationAction)
    }
}
