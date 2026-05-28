import XCTest
@testable import Jarvis

@MainActor
final class MessageCacheDeliveryStatusTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msgcache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func textMsg(_ id: String, _ text: String, _ status: DeliveryStatus) -> ChatMessage {
        var m = ChatMessage.text(id, role: .user, text: text, timestamp: Date())
        m.deliveryStatus = status
        return m
    }

    func testRoundTripSent() {
        MessageCache.save([textMsg("a", "hi", .sent)], to: tempDir)
        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.first?.deliveryStatus, .sent)
    }

    func testRoundTripDelivered() {
        MessageCache.save([textMsg("b", "hi", .delivered)], to: tempDir)
        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.first?.deliveryStatus, .delivered)
    }

    func testRoundTripFailed() {
        MessageCache.save([textMsg("c", "hi", .failed)], to: tempDir)
        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.first?.deliveryStatus, .failed)
    }

    func testSendingCollapsesToDeliveredOnReload() {
        MessageCache.save([textMsg("d", "hi", .sending)], to: tempDir)
        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.first?.deliveryStatus, .delivered,
                       ".sending is treated as completed on cache reload — outbox is the real source of truth")
    }

    func testLegacyJSONWithoutDeliveryStatusDefaultsToDelivered() throws {
        let indexURL = tempDir.appendingPathComponent("index.json")
        let legacyJSON = """
        [{
          "id":"legacy-1","role":"user","kind":"text","text":"old",
          "timestamp":"\(ISO8601DateFormatter().string(from: Date()))"
        }]
        """
        try legacyJSON.write(to: indexURL, atomically: true, encoding: .utf8)

        let restored = MessageCache.load(from: tempDir)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.deliveryStatus, .delivered,
                       "legacy entries without the field default to .delivered")
    }
}
