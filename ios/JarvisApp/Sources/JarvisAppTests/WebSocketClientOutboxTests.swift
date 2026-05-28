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

    func testCapRefusalMarksUserMessageFailedNotStuckSending() {
        let outbox = OutboxStore(directory: tempDir)
        // Fill outbox with 100 .sending entries — none .failed to evict
        for i in 0..<100 {
            var e = OutboxEntry(
                id: "filler-\(i)",
                conversationId: nil,
                createdAt: Date().addingTimeInterval(Double(i) * -1),
                payload: Data(),
                textPreview: "filler",
                hasAttachments: false
            )
            e.deliveryStatus = .sending
            _ = outbox.enqueue(e)
        }
        XCTAssertEqual(outbox.entries.count, 100)

        let ws = WebSocketClient(outbox: outbox)
        ws.send(text: "doomed", timezone: "UTC", status: nil, attachments: [], context: nil)

        // User message must be marked .failed, not stuck on .sending
        let userMsgs = ws.messages.filter { $0.role == .user }
        XCTAssertEqual(userMsgs.count, 1)
        XCTAssertEqual(userMsgs.first?.deliveryStatus, .failed,
                       "cap-refusal must surface as .failed on the user row, not stay on .sending")

        // System warning row also appended
        let warnings = ws.messages.filter {
            if case .status = $0.content { return true } else { return false }
        }
        XCTAssertEqual(warnings.count, 1)
    }

    func testFlushOutboxNoOpWhenDisconnected() {
        let outbox = OutboxStore(directory: tempDir)
        _ = outbox.enqueue(OutboxEntry(id: "x", conversationId: nil, createdAt: Date(),
                                       payload: Data(), textPreview: "x", hasAttachments: false))
        let ws = WebSocketClient(outbox: outbox)
        XCTAssertFalse(ws.isConnected)
        ws.flushOutbox()
        XCTAssertEqual(outbox.entries.count, 1)
        XCTAssertEqual(outbox.entries.first?.attempts, 0, "no attempt should be recorded when WS is down")
    }

    func testReconnectTriggersFlush() {
        let outbox = OutboxStore(directory: tempDir)
        _ = outbox.enqueue(OutboxEntry(id: "x", conversationId: nil, createdAt: Date(),
                                       payload: Data(), textPreview: "x", hasAttachments: false))
        let ws = WebSocketClient(outbox: outbox)
        var flushCalls = 0
        ws.onFlushForTesting = { flushCalls += 1 }
        ws.notifyConnectedForTesting()
        XCTAssertEqual(flushCalls, 1, "on transition to connected, flushOutbox must be invoked")
    }
}
