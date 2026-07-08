import XCTest
import GRDB
@testable import Jarvis

/// F21 — message feedback (👍/👎) must persist per `message.id` so the chosen
/// thumb survives cell recycle, message reload, and app relaunch. Previously the
/// selection lived only in `MessageRow`'s `@State` and was lost on any of those.
/// These cover the store-side persistence; the thumb-lit UI is build-verified.
final class MessageFeedbackTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs.removeAll()
    }

    /// A file-backed store so a second open on the same path simulates relaunch
    /// (an in-memory queue can't be reopened).
    private func makeFileStore() throws -> (ConversationStoreV2, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-\(UUID().uuidString).sqlite")
        tempURLs.append(url)
        let dbq = try DatabaseQueue(path: url.path)
        try Schema.migrate(dbq)
        return (ConversationStoreV2(writer: dbq), url)
    }

    private func openStore(at url: URL) throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue(path: url.path)
        try Schema.migrate(dbq)   // idempotent — DatabaseMigrator skips applied steps
        return ConversationStoreV2(writer: dbq)
    }

    private func seedMessage(_ store: ConversationStoreV2, id: String) throws {
        try store.insertInboundFromPull(id: id, seq: 1, text: "hi", agentId: "jarvis", ts: 1000)
    }

    func testSetThenGetReturnsChosenThumb() throws {
        let (store, _) = try makeFileStore()
        try seedMessage(store, id: "m1")
        try store.setFeedback(messageId: "m1", .up)
        XCTAssertEqual(try store.getFeedback(messageId: "m1"), .up)
    }

    func testDefaultsToNoneForUnratedMessage() throws {
        let (store, _) = try makeFileStore()
        try seedMessage(store, id: "m1")
        XCTAssertEqual(try store.getFeedback(messageId: "m1"), .none)
    }

    func testFeedbackSurvivesFreshStoreOpen() throws {
        let (store, url) = try makeFileStore()
        try seedMessage(store, id: "m1")
        try store.setFeedback(messageId: "m1", .down)

        // Simulate relaunch: a brand-new store on the SAME database file.
        let reopened = try openStore(at: url)
        XCTAssertEqual(try reopened.getFeedback(messageId: "m1"), .down)
    }

    func testDownOverwritesUpThenClearReturnsNone() throws {
        let (store, _) = try makeFileStore()
        try seedMessage(store, id: "m1")

        try store.setFeedback(messageId: "m1", .up)
        XCTAssertEqual(try store.getFeedback(messageId: "m1"), .up)

        try store.setFeedback(messageId: "m1", .down)   // overwrite
        XCTAssertEqual(try store.getFeedback(messageId: "m1"), .down)

        try store.setFeedback(messageId: "m1", .none)   // clear
        XCTAssertEqual(try store.getFeedback(messageId: "m1"), .none)
    }

    func testFeedbackIsPerMessageId() throws {
        let (store, _) = try makeFileStore()
        try seedMessage(store, id: "a")
        try seedMessage(store, id: "b")

        try store.setFeedback(messageId: "a", .up)
        XCTAssertEqual(try store.getFeedback(messageId: "a"), .up)
        XCTAssertEqual(try store.getFeedback(messageId: "b"), .none,
                       "rating one message must not affect another")

        try store.setFeedback(messageId: "b", .down)
        XCTAssertEqual(try store.getFeedback(messageId: "a"), .up,
                       "b's rating must not disturb a")
        XCTAssertEqual(try store.getFeedback(messageId: "b"), .down)
    }
}
