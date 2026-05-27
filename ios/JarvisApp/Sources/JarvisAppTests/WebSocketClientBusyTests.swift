import XCTest
@testable import Jarvis

@MainActor
final class WebSocketClientBusyTests: XCTestCase {
    func testIsBusyTrueWhenTyping() {
        let ws = WebSocketClient()
        ws.isTyping = true
        XCTAssertTrue(ws.isBusy)
    }

    func testIsBusyTrueWhenUserSentNoReply() {
        let ws = WebSocketClient()
        ws.lastUserSentAt = Date()
        ws.lastAssistantAt = nil
        XCTAssertTrue(ws.isBusy)
    }

    func testIsBusyFalseAfterAssistantReply() {
        let ws = WebSocketClient()
        let now = Date()
        ws.lastUserSentAt = now
        ws.lastAssistantAt = now.addingTimeInterval(1)
        XCTAssertFalse(ws.isBusy)
    }

    func testIsBusyFalseAfterFiveMinuteTimeout() {
        let ws = WebSocketClient()
        ws.lastUserSentAt = Date().addingTimeInterval(-400)
        ws.lastAssistantAt = nil
        XCTAssertFalse(ws.isBusy)
    }

    func testIsBusyFalseWhenNoUserMessage() {
        let ws = WebSocketClient()
        XCTAssertFalse(ws.isBusy)
    }
}
