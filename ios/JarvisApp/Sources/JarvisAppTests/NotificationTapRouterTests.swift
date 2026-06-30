import XCTest
import UserNotifications
@testable import Jarvis

final class NotificationTapRouterTests: XCTestCase {
    func testReplyAction() {
        let t = NotificationTapRouter.route(
            categoryId: NotificationCategories.agentMessage,
            actionId: NotificationCategories.replyAction,
            replyText: "ok", userInfo: ["agentId": "greg"])
        XCTAssertEqual(t, .reply(agentId: "greg", text: "ok"))
    }
    func testSummaryTapOpensBoard() {
        let t = NotificationTapRouter.route(
            categoryId: NotificationCategories.summaryReady,
            actionId: UNNotificationDefaultActionIdentifier,
            replyText: nil, userInfo: [:])
        XCTAssertEqual(t, .openSummaryBoard)
    }
    func testChatDefaultTapOpensAgentChat() {
        let t = NotificationTapRouter.route(
            categoryId: NotificationCategories.agentMessage,
            actionId: UNNotificationDefaultActionIdentifier,
            replyText: nil, userInfo: ["agentId": "payne"])
        XCTAssertEqual(t, .openAgentChat(.payne))
    }
    func testUnknownAgentIsNoop() {
        let t = NotificationTapRouter.route(
            categoryId: NotificationCategories.agentMessage,
            actionId: UNNotificationDefaultActionIdentifier,
            replyText: nil, userInfo: ["agentId": "nope"])
        XCTAssertEqual(t, .none)
    }
}
