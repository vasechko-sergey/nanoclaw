import XCTest
@testable import Jarvis

@MainActor
final class WatchConnectivityBridgeTests: XCTestCase {

    func testBuildPayloadShape() {
        let payload = WatchConnectivityBridge.buildAssistantPayload(
            id: "abc",
            text: "Привет",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        XCTAssertEqual(payload["type"] as? String, "message")
        XCTAssertEqual(payload["id"] as? String, "abc")
        XCTAssertEqual(payload["text"] as? String, "Привет")
        XCTAssertNotNil(payload["ts"] as? String)
    }

    func testParseSendTextFromWatch() {
        let dict: [String: Any] = ["type": "send_text", "text": "diktovka"]
        let parsed = WatchConnectivityBridge.parseSendText(dict)
        XCTAssertEqual(parsed, "diktovka")
    }

    func testParseSendTextReturnsNilWhenTypeMismatch() {
        let dict: [String: Any] = ["type": "other", "text": "x"]
        XCTAssertNil(WatchConnectivityBridge.parseSendText(dict))
    }

    func testParseSendTextReturnsNilWhenTextMissing() {
        let dict: [String: Any] = ["type": "send_text"]
        XCTAssertNil(WatchConnectivityBridge.parseSendText(dict))
    }
}
