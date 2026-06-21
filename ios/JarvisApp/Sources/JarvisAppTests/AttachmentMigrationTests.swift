import XCTest
import GRDB
@testable import Jarvis

final class AttachmentMigrationTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentMigrationTests-\(UUID().uuidString)", isDirectory: true)
        ChatImageStore.shared = ChatImageStore(baseURL: tmpDir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        ChatImageStore.shared = ChatImageStore(baseURL: ChatImageStore.defaultBaseURL())
    }

    func test_run_convertsLegacyInlineImageToRef() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        // Seed a legacy inline-image row by hand (V2.Attachment-shaped JSON).
        let b64 = Data("abc".utf8).base64EncodedString()
        let json = "[{\"id\":\"a\",\"kind\":\"image\",\"name\":\"p.jpg\",\"mime_type\":\"image/jpeg\",\"byte_size\":3,\"bytes_base64\":\"\(b64)\",\"remote_id\":null}]"
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO messages (id, dir, seq, text, attachments_json, status, ts, created_at, agent_id)
                VALUES ('leg1','in',1,'',?,'delivered',1,1,'jarvis')
            """, arguments: [json])
        }

        try AttachmentMigration.run(writer: dbq, store: ChatImageStore.shared)

        let migrated = try store.fetchById("leg1")!.attachmentsJSON!
        XCTAssertFalse(migrated.contains("bytes_base64"))
        XCTAssertTrue(migrated.contains("sha256"))
        let atts = try JSONDecoder().decode([StoredAttachment].self, from: Data(migrated.utf8))
        XCTAssertTrue(ChatImageStore.shared.has(sha: atts[0].sha256!))

        // Idempotent: a second run must not change the row or re-process it.
        try AttachmentMigration.run(writer: dbq, store: ChatImageStore.shared)
        let after2 = try store.fetchById("leg1")!.attachmentsJSON!
        XCTAssertEqual(after2, migrated, "second run must be a no-op")
    }

    func test_dropsAttachmentsTable() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let exists = try dbq.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='attachments')") ?? false
        }
        XCTAssertFalse(exists, "dead attachments table should be dropped by migration v6")
    }
}
