import XCTest
@testable import Jarvis

final class MessageOrderingTests: XCTestCase {
    func testEpochMillisFromISO() {
        // 2023-11-14T22:13:20Z == 1_700_000_000 s
        XCTAssertEqual(ConversationStoreV2.epochMillis(fromISO: "2023-11-14T22:13:20.000Z"), 1_700_000_000_000)
        XCTAssertEqual(ConversationStoreV2.epochMillis(fromISO: "2023-11-14T22:13:20Z"), 1_700_000_000_000)
    }

    func testEpochMillisRejectsGarbage() {
        XCTAssertNil(ConversationStoreV2.epochMillis(fromISO: "not-a-date"))
        XCTAssertNil(ConversationStoreV2.epochMillis(fromISO: ""))
    }
}
