import XCTest
@testable import Jarvis

@MainActor
final class WebSocketClientOutboxTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-outbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testOfflineSendKeepsMessageAndEnqueues() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        XCTAssertFalse(ws.isConnected)

        ws.send(text: "hello offline", timezone: "Asia/Makassar", status: nil, attachments: [], context: nil)

        XCTAssertEqual(ws.messages.count, 1, "the user message must still appear in the UI list")
        XCTAssertEqual(ws.messages.first?.text, "hello offline")
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .sending)
        XCTAssertEqual(outbox.entries.count, 1, "outbox must contain exactly one entry")
        XCTAssertEqual(outbox.entries.first?.textPreview, "hello offline")
    }

    func testOfflineSendIdMatchesMessageId() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        ws.send(text: "x", timezone: "UTC", status: nil, attachments: [], context: nil)
        XCTAssertEqual(ws.messages.first?.id, outbox.entries.first?.id,
                       "ChatMessage.id and OutboxEntry.id must match — same clientMessageId")
    }
}
