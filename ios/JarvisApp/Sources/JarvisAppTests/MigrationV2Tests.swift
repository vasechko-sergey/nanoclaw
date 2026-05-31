import XCTest
import GRDB
@testable import Jarvis

final class MigrationV2Tests: XCTestCase {
    var tmpDir: URL!
    var store: ConversationStoreV2!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStoreV2(writer: dbq)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Flat-shape (v2 plan / fixture shape)

    func testImportsFlatOutboxAndCache() throws {
        let outboxDir = tmpDir.appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        let outboxJSON = """
        [{"id":"m1","conversationId":"thr-1","text":"hi","status":"sent","ts":1717000000000}]
        """
        try outboxJSON.write(to: outboxDir.appendingPathComponent("queue.json"),
                             atomically: true, encoding: .utf8)

        let cacheDir = tmpDir.appendingPathComponent("MessageCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheJSON = """
        [{"id":"in-1","conversationId":"thr-1","text":"reply","dir":"in","ts":1717000010000}]
        """
        try cacheJSON.write(to: cacheDir.appendingPathComponent("index.json"),
                            atomically: true, encoding: .utf8)

        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)

        XCTAssertEqual(try store.countAllMessages(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboxDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path))
    }

    func testNoLegacyFilesIsANoop() throws {
        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)
        XCTAssertEqual(try store.countAllMessages(), 0)
    }

    func testRunsAtMostOnce() throws {
        let outboxDir = tmpDir.appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        let outboxJSON = """
        [{"id":"m1","conversationId":"thr-1","text":"hi","status":"sent","ts":1717000000000}]
        """
        try outboxJSON.write(to: outboxDir.appendingPathComponent("queue.json"),
                             atomically: true, encoding: .utf8)

        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)
        XCTAssertEqual(try store.countAllMessages(), 1)

        // Second run: directory gone → no-op, count unchanged.
        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)
        XCTAssertEqual(try store.countAllMessages(), 1)
    }

    func testCacheRoleAcceptsRoleAlias() throws {
        let cacheDir = tmpDir.appendingPathComponent("MessageCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheJSON = """
        [
          {"id":"u1","conversationId":"thr-1","text":"hi","role":"user","ts":1717000000000},
          {"id":"a1","conversationId":"thr-1","text":"hello","role":"assistant","ts":1717000001000}
        ]
        """
        try cacheJSON.write(to: cacheDir.appendingPathComponent("index.json"),
                            atomically: true, encoding: .utf8)

        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)
        XCTAssertEqual(try store.countAllMessages(), 2)
    }

    // MARK: - Real legacy shape (ISO8601 dates, role+kind, no conversationId)

    func testImportsRealLegacyOutboxStoreShape() throws {
        let outboxDir = tmpDir.appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)

        // The legacy `OutboxEntry` type has been removed alongside the legacy
        // WebSocketClient (5.2c); reconstruct the on-disk JSON shape by hand so
        // this test still pins MigrationV2's decode path for the real v1 file.
        let createdAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_717_000_000))
        let legacyJSON = """
        [{
          "id": "legacy-out-1",
          "conversationId": "00000000-0000-0000-0000-000000000001",
          "createdAt": "\(createdAt)",
          "attempts": 0,
          "payload": "e30=",
          "textPreview": "hi from v1",
          "hasAttachments": false,
          "deliveryStatus": "sent"
        }]
        """
        try legacyJSON.write(to: outboxDir.appendingPathComponent("queue.json"),
                             atomically: true, encoding: .utf8)

        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)

        XCTAssertEqual(try store.countAllMessages(), 1)
        let stored = try store.fetchById("legacy-out-1")
        XCTAssertEqual(stored?.text, "hi from v1")
        XCTAssertEqual(stored?.dir, .out)
        XCTAssertEqual(stored?.status, .sent)
        XCTAssertEqual(stored?.conversationId, "00000000-0000-0000-0000-000000000001")
        // 1_717_000_000 s → 1_717_000_000_000 ms
        XCTAssertEqual(stored?.ts, 1_717_000_000_000)
    }

    func testImportsRealLegacyMessageCacheShape() throws {
        // The real v1 MessageCache had no conversationId — fallback id is used.
        let cacheDir = tmpDir.appendingPathComponent("MessageCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Build a payload that decodes via the real LegacyCachedMessage path.
        // (We construct it by hand because `CachedMessage` is private to MessageCache.swift.)
        let json = """
        [
          {
            "id": "cache-user-1",
            "role": "user",
            "kind": "text",
            "text": "hello v1",
            "timestamp": "2024-05-29T10:00:00Z",
            "deliveryStatus": "sent"
          },
          {
            "id": "cache-assistant-1",
            "role": "assistant",
            "kind": "text",
            "text": "hello back",
            "timestamp": "2024-05-29T10:00:05Z",
            "deliveryStatus": "delivered"
          },
          {
            "id": "cache-image-1",
            "role": "assistant",
            "kind": "image",
            "imageFile": "cache-image-1.jpg",
            "filename": "pic.jpg",
            "timestamp": "2024-05-29T10:00:10Z"
          },
          {
            "id": "cache-system-1",
            "role": "system",
            "kind": "text",
            "text": "ignored",
            "timestamp": "2024-05-29T10:00:15Z"
          }
        ]
        """
        try json.write(to: cacheDir.appendingPathComponent("index.json"),
                       atomically: true, encoding: .utf8)

        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)

        // user + assistant text rows → 2. image (kind != "text") and system role skipped.
        XCTAssertEqual(try store.countAllMessages(), 2)
        XCTAssertEqual(try store.fetchById("cache-user-1")?.dir, .out)
        XCTAssertEqual(try store.fetchById("cache-assistant-1")?.dir, .in_)
        XCTAssertEqual(
            try store.fetchById("cache-user-1")?.conversationId,
            MigrationV2.legacyFallbackConversationId
        )
    }

    func testImportsPerConversationCacheDirs() throws {
        // Documents/Conversations/<UUID>/index.json — v1 per-thread layout.
        let convRoot = tmpDir.appendingPathComponent("Conversations", isDirectory: true)
        let convId = "11111111-1111-1111-1111-111111111111"
        let convDir = convRoot.appendingPathComponent(convId, isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        let json = """
        [
          {
            "id": "perconv-1",
            "role": "user",
            "kind": "text",
            "text": "scoped",
            "timestamp": "2024-05-29T11:00:00Z"
          }
        ]
        """
        try json.write(to: convDir.appendingPathComponent("index.json"),
                       atomically: true, encoding: .utf8)

        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)

        XCTAssertEqual(try store.countAllMessages(), 1)
        XCTAssertEqual(try store.fetchById("perconv-1")?.conversationId, convId)
        // The per-conversation subdir is consumed and removed…
        XCTAssertFalse(FileManager.default.fileExists(atPath: convDir.path))
        // …but the root `Conversations/` dir is intentionally kept so the v1
        // `ConversationStore`'s `conversations.json` index file (when present)
        // survives the migration. See `liftConversationsIndex` for the read.
    }

    func testLiftsConversationsIndexIntoV2() throws {
        let convRoot = tmpDir.appendingPathComponent("Conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: convRoot, withIntermediateDirectories: true)
        let uuid1 = "22222222-2222-2222-2222-222222222222"
        let uuid2 = "33333333-3333-3333-3333-333333333333"
        // Real v1 `conversations.json` shape with isPinned/messageCount/etc.
        // The migration only consumes id/title/createdAt — extra keys are ignored.
        let json = """
        [
          {
            "id": "\(uuid1)",
            "title": "Утренний чат",
            "createdAt": "2024-05-29T10:00:00Z",
            "lastMessageAt": "2024-05-29T10:05:00Z",
            "messageCount": 3,
            "preview": "hi",
            "isPinned": false
          },
          {
            "id": "\(uuid2)",
            "title": "Новый диалог",
            "createdAt": "2024-05-29T09:00:00Z",
            "lastMessageAt": "2024-05-29T09:00:00Z",
            "messageCount": 0,
            "preview": "",
            "isPinned": true
          }
        ]
        """
        try json.write(to: convRoot.appendingPathComponent("conversations.json"),
                       atomically: true, encoding: .utf8)

        try MigrationV2.runIfNeeded(documentsURL: tmpDir, store: store)

        let summaries = try store.listConversations()
        let ids = Set(summaries.map(\.id))
        XCTAssertTrue(ids.contains(uuid1))
        XCTAssertTrue(ids.contains(uuid2))
        // Title is preserved when non-empty.
        XCTAssertEqual(summaries.first(where: { $0.id == uuid1 })?.title, "Утренний чат")
        // The index file itself is left in place so v1 `ConversationStore`
        // can still load the drawer during the transition period.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: convRoot.appendingPathComponent("conversations.json").path
        ))
    }
}
