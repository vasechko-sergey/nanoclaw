import XCTest
import GRDB
@testable import Jarvis

final class ConversationStoreV2Tests: XCTestCase {
    var store: ConversationStoreV2!

    override func setUp() async throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStoreV2(writer: dbq)
    }

    func testInsertAndQueryByStatus() throws {
        try store.insertOutboundUserMessage(
            conversationId: "thr-1",
            id: UUID().uuidString,
            text: "hi",
            attachments: [],
            context: nil
        )
        let pending = try store.queuedOutbound()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].status, .queued)
        XCTAssertNil(pending[0].seq)
    }

    func testAllocateSeqIsMonotonic() throws {
        XCTAssertEqual(try store.allocateNextSendSeq(), 1)
        XCTAssertEqual(try store.allocateNextSendSeq(), 2)
        XCTAssertEqual(try store.allocateNextSendSeq(), 3)
    }

    func testCursorReadWriteAtomic() throws {
        try store.setCursor(.lastSeenInbound, 42)
        XCTAssertEqual(try store.cursor(.lastSeenInbound), 42)
        try store.setCursor(.lastSeenInbound, 50)
        XCTAssertEqual(try store.cursor(.lastSeenInbound), 50)
    }

    func testMarkSendingAndAck() throws {
        let id = UUID().uuidString
        try store.insertOutboundUserMessage(
            conversationId: "thr-1", id: id, text: "hi", attachments: [], context: nil
        )
        try store.markSending(id: id, seq: 5)
        XCTAssertEqual(try store.fetchById(id)?.status, .sending)
        XCTAssertEqual(try store.fetchById(id)?.seq, 5)
        try store.markSent(id: id, serverTS: 1717000000000)
        XCTAssertEqual(try store.fetchById(id)?.status, .sent)
    }

    func testReconnectResetSendingToQueued() throws {
        let id = UUID().uuidString
        try store.insertOutboundUserMessage(
            conversationId: "thr-1", id: id, text: "hi", attachments: [], context: nil
        )
        try store.markSending(id: id, seq: 10)
        try store.resetSendingToQueued(maxSeq: 5)  // server hasn't acked seq>5
        XCTAssertEqual(try store.fetchById(id)?.status, .queued)
    }

    func testConfirmAckedUpTo() throws {
        let id = UUID().uuidString
        try store.insertOutboundUserMessage(
            conversationId: "thr-1", id: id, text: "hi", attachments: [], context: nil
        )
        try store.markSending(id: id, seq: 3)
        try store.confirmAckedUpTo(maxSeq: 5)  // server acked seq<=5
        XCTAssertEqual(try store.fetchById(id)?.status, .sent)
    }

    func testInboundDedup() throws {
        XCTAssertFalse(try store.dedupSeen(id: "x"))
        try store.recordDedup(id: "x", seq: 1)
        XCTAssertTrue(try store.dedupSeen(id: "x"))
    }

    func testResetFailedToQueued() throws {
        let id = UUID().uuidString
        try store.insertOutboundUserMessage(conversationId: "thr-1", id: id, text: "hi",
                                            attachments: [], context: nil)
        try store.markSending(id: id, seq: 5)
        try store.markFailed(id: id, reason: "network")
        XCTAssertEqual(try store.fetchById(id)?.status, .failed)
        try store.resetFailedToQueued(id: id)
        let row = try XCTUnwrap(try store.fetchById(id))
        XCTAssertEqual(row.status, .queued)
        XCTAssertNil(row.seq)
        XCTAssertNil(row.failureReason)
    }
}
