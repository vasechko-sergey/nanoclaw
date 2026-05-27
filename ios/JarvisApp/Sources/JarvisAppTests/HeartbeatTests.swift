import XCTest
@testable import Jarvis

@MainActor
final class HeartbeatTests: XCTestCase {
    func testForceReconnectClearsTransientState() {
        let ws = WebSocketClient()
        ws.isTyping = true
        ws.isConnected = true
        ws.lastUserSentAt = Date()

        ws.forceReconnect(reason: "test")

        XCTAssertFalse(ws.isConnected)
        XCTAssertFalse(ws.isTyping)
    }

    func testStaleHeartbeatTriggersReconnect() {
        let ws = WebSocketClient()
        ws.isConnected = true
        ws.lastPongAt = Date().addingTimeInterval(-60)
        ws.tickHeartbeatForTesting()
        XCTAssertFalse(ws.isConnected, "stale pong should force reconnect (mark disconnected)")
    }

    func testFreshHeartbeatNoReconnect() {
        let ws = WebSocketClient()
        ws.isConnected = true
        ws.lastPongAt = Date()
        ws.tickHeartbeatForTesting()
        XCTAssertTrue(ws.isConnected, "fresh pong, no real socket → should remain connected (no force reconnect)")
    }
}
