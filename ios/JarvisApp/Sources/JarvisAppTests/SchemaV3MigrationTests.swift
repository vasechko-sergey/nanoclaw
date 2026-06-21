import XCTest
import GRDB
@testable import Jarvis

final class SchemaV3MigrationTests: XCTestCase {
    func test_v3_drops_conversations_and_kv_and_recreates_messages_without_conv_id() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)

        try dbq.read { db in
            // conversations + kv should be gone
            let conv = try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='conversations')")!
            XCTAssertFalse(conv, "conversations table should be dropped")
            let kv = try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='kv')")!
            XCTAssertFalse(kv, "kv table should be dropped")

            // messages must exist without conversation_id
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(messages)")
                .map { $0["name"] as String }
            XCTAssertTrue(cols.contains("id"))
            XCTAssertTrue(cols.contains("dir"))
            XCTAssertTrue(cols.contains("ts"))
            XCTAssertFalse(cols.contains("conversation_id"), "messages must not have conversation_id")

            // supporting tables present. NOTE: `attachments` is intentionally
            // NOT here — migration v6 drops that dead table (image bytes now live
            // in ChatImageStore on disk). Its removal is covered by
            // AttachmentMigrationTests.test_dropsAttachmentsTable.
            for t in ["inbound_dedup", "cursors"] {
                let exists = try Bool.fetchOne(db, sql:
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
                    arguments: [t])!
                XCTAssertTrue(exists, "\(t) table missing")
            }
        }
    }

    func test_v3_idx_msg_ts_exists() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        try dbq.read { db in
            let idx = try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_msg_ts')")!
            XCTAssertTrue(idx)
        }
    }
}
