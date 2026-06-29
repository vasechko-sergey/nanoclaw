import XCTest
import GRDB
@testable import Jarvis

final class StoreNotifiedTests: XCTestCase {
    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    func testNotifiedRoundTrip() throws {
        let store = try makeStore()
        XCTAssertFalse(try store.notifiedSeen(id: "a"))
        try store.recordNotified(id: "a", seq: 5)
        XCTAssertTrue(try store.notifiedSeen(id: "a"))
        // Idempotent — second record doesn't throw and stays seen.
        try store.recordNotified(id: "a", seq: 5)
        XCTAssertTrue(try store.notifiedSeen(id: "a"))
    }

    func testRecordNotifiedUpsertsOntoAnExistingDedupRow() throws {
        let store = try makeStore()
        // Simulate the live path: dedup recorded first (no notified_at), then notified.
        try store.recordDedup(id: "b", seq: 9)
        XCTAssertFalse(try store.notifiedSeen(id: "b"))
        try store.recordNotified(id: "b", seq: 9)
        XCTAssertTrue(try store.notifiedSeen(id: "b"))
    }
}
