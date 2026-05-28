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
        _ = store.enqueue(e)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, "abc")

        let reloaded = OutboxStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.id, "abc")
        XCTAssertEqual(reloaded.entries.first?.textPreview, "hello")
    }

    func testRemoveErasesEntry() {
        let store = OutboxStore(directory: tempDir)
        _ = store.enqueue(makeEntry(id: "a"))
        _ = store.enqueue(makeEntry(id: "b"))
        store.remove("a")
        XCTAssertEqual(store.entries.map(\.id), ["b"])

        let reloaded = OutboxStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.map(\.id), ["b"])
    }

    func testEnqueueAfterReloadStillPersists() {
        // Exercises the replaceItemAt path on a populated queue.json,
        // not just the initial-write-to-empty-dir path.
        let s1 = OutboxStore(directory: tempDir)
        _ = s1.enqueue(makeEntry(id: "first"))

        let s2 = OutboxStore(directory: tempDir)
        XCTAssertEqual(s2.entries.map(\.id), ["first"])
        _ = s2.enqueue(makeEntry(id: "second"))

        let s3 = OutboxStore(directory: tempDir)
        XCTAssertEqual(s3.entries.map(\.id), ["first", "second"],
                       "replace-on-populated path must preserve all entries in order")
    }

    func testCapAllowsExactly100Entries() {
        let store = OutboxStore(directory: tempDir)
        for i in 0..<100 {
            _ = store.enqueue(makeEntry(id: "id-\(i)"))
        }
        XCTAssertEqual(store.entries.count, 100, "100 entries should fit")
    }

    func test101stWithOneFailedAtFrontDropsOldestFailed() {
        let store = OutboxStore(directory: tempDir)
        var failed = makeEntry(id: "failed-old")
        failed.deliveryStatus = .failed
        _ = store.enqueue(failed)
        for i in 1..<100 {
            _ = store.enqueue(makeEntry(id: "id-\(i)"))
        }
        XCTAssertEqual(store.entries.count, 100)

        let added = store.enqueue(makeEntry(id: "newcomer"))
        XCTAssertTrue(added, "enqueue must succeed when an older .failed entry can be dropped")
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertFalse(store.entries.contains { $0.id == "failed-old" }, "oldest .failed should be removed")
        XCTAssertTrue(store.entries.contains { $0.id == "newcomer" })
    }

    func test101stWithNoFailedRefuses() {
        let store = OutboxStore(directory: tempDir)
        for i in 0..<100 {
            var e = makeEntry(id: "id-\(i)")
            e.deliveryStatus = .sending
            _ = store.enqueue(e)
        }
        let added = store.enqueue(makeEntry(id: "newcomer"))
        XCTAssertFalse(added, "enqueue must refuse when no .failed entry to evict")
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertFalse(store.entries.contains { $0.id == "newcomer" })
    }

    func testBumpAttemptIncrementsAndPersists() {
        let store = OutboxStore(directory: tempDir)
        _ = store.enqueue(makeEntry(id: "a"))
        store.bumpAttempt("a")
        XCTAssertEqual(store.entries.first?.attempts, 1)
        XCTAssertNotNil(store.entries.first?.lastAttempt)

        let reloaded = OutboxStore(directory: tempDir)
        XCTAssertEqual(reloaded.entries.first?.attempts, 1)
    }

    func testShouldRetryTrueWhenAttemptsLow() {
        let store = OutboxStore(directory: tempDir)
        _ = store.enqueue(makeEntry(id: "a"))
        XCTAssertTrue(store.shouldRetry("a", now: Date()))
    }

    func testShouldRetryFalseAfterFiveQuickAttempts() {
        let store = OutboxStore(directory: tempDir)
        _ = store.enqueue(makeEntry(id: "a"))
        let now = Date()
        for _ in 0..<5 { store.bumpAttempt("a") }
        XCTAssertFalse(store.shouldRetry("a", now: now), "5+ attempts in 60s window should be skipped")
    }

    func testShouldRetryTrueAfter60sWindow() {
        let store = OutboxStore(directory: tempDir)
        _ = store.enqueue(makeEntry(id: "a"))
        for _ in 0..<5 { store.bumpAttempt("a") }
        let future = Date().addingTimeInterval(61)
        XCTAssertTrue(store.shouldRetry("a", now: future), "after 60s window passes, retry is allowed again")
    }
}
