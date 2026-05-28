import XCTest
@testable import Jarvis

@MainActor
final class OutboxStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeEntry(id: String = UUID().uuidString, text: String = "hi") -> OutboxEntry {
        OutboxEntry(
            id: id,
            conversationId: nil,
            createdAt: Date(),
            lastAttempt: nil,
            attempts: 0,
            payload: Data("payload-\(id)".utf8),
            textPreview: text,
            hasAttachments: false,
            deliveryStatus: .sending
        )
    }

    func testEmptyOnFirstInit() {
        let store = OutboxStore(directory: tempDir)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEnqueuePersistsAcrossReload() {
        let store = OutboxStore(directory: tempDir)
        let e = makeEntry(id: "abc", text: "hello")
        store.enqueue(e)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, "abc")

        let reloaded = OutboxStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.id, "abc")
        XCTAssertEqual(reloaded.entries.first?.textPreview, "hello")
    }

    func testRemoveErasesEntry() {
        let store = OutboxStore(directory: tempDir)
        store.enqueue(makeEntry(id: "a"))
        store.enqueue(makeEntry(id: "b"))
        store.remove("a")
        XCTAssertEqual(store.entries.map(\.id), ["b"])

        let reloaded = OutboxStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.map(\.id), ["b"])
    }
}
