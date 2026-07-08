import XCTest
import GRDB
@testable import Jarvis

/// F28 — bound unbounded on-device storage:
///   • `ChatImageStore`      — LRU cap (150 MB OR 300 entries) on the chat-image blob dir.
///   • `ExerciseImageCache`  — LRU cap (60 entries) on the workout-image blob dir.
///   • `inbound_dedup`       — 30-day retention prune on the notification-dedup table.
final class LocalStorageBoundsTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStorageBoundsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - ChatImageStore LRU

    func test_chatImageStore_evictsLeastRecentlyUsed_whenOverEntryCap() throws {
        let store = ChatImageStore(baseURL: tmpRoot, maxBytes: 100 * 1024 * 1024, maxEntries: 3)
        // Write 5 DISTINCT blobs; entry cap is 3 → the 2 oldest writes evict.
        let shas = (0..<5).map { store.write(blob(byte: UInt8($0), count: 64)) }
        XCTAssertFalse(store.has(sha: shas[0]), "oldest write must be evicted")
        XCTAssertFalse(store.has(sha: shas[1]), "2nd-oldest write must be evicted")
        XCTAssertTrue(store.has(sha: shas[2]))
        XCTAssertTrue(store.has(sha: shas[3]))
        XCTAssertTrue(store.has(sha: shas[4]), "newest write must survive")
        XCTAssertEqual(try fileCount(tmpRoot), 3, "on-disk count must equal the cap")
    }

    func test_chatImageStore_evictsByTotalBytes_whenOverByteCap() throws {
        // 4 KB blobs, byte cap 10 KB → at most 2 survive (2·4 KB ≤ 10 KB < 3·4 KB),
        // independent of the (loose) entry cap.
        let store = ChatImageStore(baseURL: tmpRoot, maxBytes: 10 * 1024, maxEntries: 100)
        let shas = (0..<5).map { store.write(blob(byte: UInt8($0), count: 4 * 1024)) }
        let survivors = shas.filter { store.has(sha: $0) }
        XCTAssertLessThanOrEqual(survivors.count, 2, "byte cap must bound survivors to ~2")
        XCTAssertTrue(store.has(sha: shas[4]), "newest write must survive")
    }

    func test_chatImageStore_readBumpsRecency_soViewedBlobSurvives() throws {
        let store = ChatImageStore(baseURL: tmpRoot, maxBytes: 100 * 1024 * 1024, maxEntries: 3)
        let a = store.write(blob(byte: 1, count: 64))
        let b = store.write(blob(byte: 2, count: 64))
        let c = store.write(blob(byte: 3, count: 64))
        _ = store.bytes(sha: a)                              // a viewed → most-recently-used
        let d = store.write(blob(byte: 4, count: 64))
        let e = store.write(blob(byte: 5, count: 64))
        XCTAssertTrue(store.has(sha: a), "read-bumped blob must survive eviction")
        XCTAssertTrue(store.has(sha: d))
        XCTAssertTrue(store.has(sha: e))
        XCTAssertFalse(store.has(sha: b), "least-recently-used blob must be evicted")
        XCTAssertFalse(store.has(sha: c), "least-recently-used blob must be evicted")
        XCTAssertEqual(try fileCount(tmpRoot), 3)
    }

    // MARK: - ExerciseImageCache LRU

    func test_exerciseImageCache_evictsOldest_whenOverEntryCap() throws {
        let cache = ExerciseImageCache(baseURL: tmpRoot, maxEntries: 3) { _ in }
        for i in 0..<5 {
            try cache.store(slug: "ex\(i)", sha256: "sha\(i)", data: jpegBytes())
        }
        XCTAssertFalse(cache.has(slug: "ex0", sha256: "sha0"), "oldest cached image must be evicted")
        XCTAssertFalse(cache.has(slug: "ex1", sha256: "sha1"))
        XCTAssertTrue(cache.has(slug: "ex2", sha256: "sha2"))
        XCTAssertTrue(cache.has(slug: "ex3", sha256: "sha3"))
        XCTAssertTrue(cache.has(slug: "ex4", sha256: "sha4"), "newest cached image must survive")
        XCTAssertEqual(try fileCount(tmpRoot), 3, "on-disk count must equal the cap")
    }

    // MARK: - inbound_dedup retention prune

    func test_pruneDedup_dropsRowsOlderThanRetention_keepsRecent() throws {
        let store = try makeStore()
        let now = Date()
        let dayMs = 24 * 60 * 60 * 1000
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        // Seed one 40-day-old row and one 1-day-old row via the real schema.
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO inbound_dedup (id, seq, received_at) VALUES (?, ?, ?)",
                           arguments: ["old", 1, nowMs - 40 * dayMs])
            try db.execute(sql: "INSERT INTO inbound_dedup (id, seq, received_at) VALUES (?, ?, ?)",
                           arguments: ["new", 2, nowMs - 1 * dayMs])
        }
        try store.pruneDedup(retentionDays: 30, now: now)
        XCTAssertFalse(try store.dedupSeen(id: "old"), "row older than retention must be pruned")
        XCTAssertTrue(try store.dedupSeen(id: "new"), "recent row must be kept")
    }

    // MARK: - Helpers

    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    /// A distinct `count`-byte blob filled with `byte` — distinct content ⇒ distinct sha.
    /// ChatImageStore is content-addressed and does not decode on write, so raw
    /// bytes are a valid fixture for the eviction path.
    private func blob(byte: UInt8, count: Int) -> Data {
        Data(repeating: byte, count: count)
    }

    /// Smallest valid JPEG (1×1) — ExerciseImageCache.store persists raw Data.
    private func jpegBytes() -> Data {
        Data(base64Encoded: "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AKp//9k=")!
    }

    private func fileCount(_ dir: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).count
    }
}
