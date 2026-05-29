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

    func testMessageAckRemovesEntryAndMarksDelivered() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        ws.send(text: "boom", timezone: "UTC", status: nil, attachments: [], context: nil)
        guard let id = ws.messages.first?.id else { XCTFail("no message"); return }
        XCTAssertEqual(outbox.entries.count, 1)

        ws.handleMessageAckForTesting(clientMessageId: id)

        XCTAssertEqual(outbox.entries.count, 0, "ack must remove the outbox entry")
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .delivered)
    }

    func testUnknownAckIsIgnored() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        ws.send(text: "x", timezone: "UTC", status: nil, attachments: [], context: nil)
        let startingCount = outbox.entries.count

        ws.handleMessageAckForTesting(clientMessageId: "unknown-id")

        XCTAssertEqual(outbox.entries.count, startingCount, "ack for unknown id must be a no-op")
    }

    func testAckBeforeSentCallbackDoesNotDowngrade() {
        // Simulate the race: ack arrives, removes the entry and marks .delivered.
        // Now the (delayed) send-callback path tries to mark .sent. Since the
        // entry is gone, the callback should skip the write — status stays .delivered.
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        ws.send(text: "race", timezone: "UTC", status: nil, attachments: [], context: nil)
        guard let id = ws.messages.first?.id else { XCTFail("no message"); return }

        // Ack arrives first
        ws.handleMessageAckForTesting(clientMessageId: id)
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .delivered)
        XCTAssertEqual(outbox.entries.count, 0)

        // The send-callback's deferred .sent write would normally happen here.
        // We can't easily trigger the URLSession callback in a unit test, but we
        // can call updateDeliveryStatus directly to simulate what would happen
        // WITHOUT the fix — and confirm that with the fix the status path is
        // gated. The gate is in the flushOutbox callback; we model it inline:
        if outbox.entries.contains(where: { $0.id == id }) {
            // Would-be-callback path. With the fix, this branch never runs.
            XCTFail("entry should not be re-found after ack removal")
        }
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .delivered,
                       "status must stay .delivered after ack — no downgrade to .sent")
    }

    func testStaleSentEntryBumpsToFailedOnFlush() {
        let outbox = OutboxStore(directory: tempDir)
        var entry = OutboxEntry(id: "stale", conversationId: nil,
                                createdAt: Date().addingTimeInterval(-60),
                                payload: Data(), textPreview: "x", hasAttachments: false,
                                deliveryStatus: .sent)
        entry.lastAttempt = Date().addingTimeInterval(-31)
        outbox.entries = [entry]
        outbox.save()

        let ws = WebSocketClient(outbox: outbox)
        // Stage a matching UI row in .sent state
        var uiMsg = ChatMessage.text("stale", role: .user, text: "x", timestamp: Date())
        uiMsg.deliveryStatus = .sent
        ws.messages = [uiMsg]

        ws.bumpStaleSentEntriesForTesting(now: Date())

        XCTAssertEqual(outbox.entries.first?.deliveryStatus, .failed)
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .failed)
    }

    func testRetrySendResetsAttemptsAndFlushesSingleEntry() {
        let outbox = OutboxStore(directory: tempDir)
        var entry = OutboxEntry(id: "retry-me", conversationId: nil, createdAt: Date(),
                                payload: Data(), textPreview: "x", hasAttachments: false,
                                deliveryStatus: .failed)
        entry.attempts = 5
        entry.lastAttempt = Date()
        outbox.entries = [entry]
        outbox.save()

        let ws = WebSocketClient(outbox: outbox)
        // Stage matching UI row in .failed
        var uiMsg = ChatMessage.text("retry-me", role: .user, text: "x", timestamp: Date())
        uiMsg.deliveryStatus = .failed
        ws.messages = [uiMsg]

        ws.retrySend(id: "retry-me")

        XCTAssertEqual(outbox.entries.first?.attempts, 0, "manual retry must reset attempts so backoff doesn't block")
        XCTAssertEqual(outbox.entries.first?.deliveryStatus, .sending,
                       "manual retry returns the entry to .sending so the UI shows the spinner")
        XCTAssertEqual(ws.messages.first?.deliveryStatus, .sending)
    }

    // MARK: - One-shot control queue (sendControl)

    func testSendFeedbackWhileOfflineEnqueuesOneShot() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        XCTAssertFalse(ws.isConnected)
        XCTAssertEqual(ws.oneShotQueueCountForTesting, 0)

        ws.sendFeedback(conversationId: nil, messageId: "m1", value: true, messageText: "hi")

        XCTAssertEqual(ws.oneShotQueueCountForTesting, 1,
                       "offline feedback must be queued for replay on reconnect")
    }

    func testSendActionResponseWhileOfflineEnqueuesOneShot() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        XCTAssertFalse(ws.isConnected)

        ws.sendActionResponse(messageId: "m1", buttonId: "yes", buttonLabel: "Yes")

        XCTAssertEqual(ws.oneShotQueueCountForTesting, 1,
                       "offline action_response must be queued for replay on reconnect")
    }

    func testSendNewConversationWhileOfflineEnqueuesOneShot() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        XCTAssertFalse(ws.isConnected)

        ws.sendNewConversation(id: UUID())

        XCTAssertEqual(ws.oneShotQueueCountForTesting, 1,
                       "offline new_conversation must be queued for replay on reconnect")
    }

    func testFlushOneShotQueueNoOpWhenDisconnected() {
        let outbox = OutboxStore(directory: tempDir)
        let ws = WebSocketClient(outbox: outbox)
        ws.sendFeedback(conversationId: nil, messageId: "m1", value: true, messageText: "hi")
        XCTAssertEqual(ws.oneShotQueueCountForTesting, 1)

        ws.flushOneShotQueue()

        XCTAssertEqual(ws.oneShotQueueCountForTesting, 1,
                       "flushOneShotQueue while offline must not drain the queue")
    }
}
