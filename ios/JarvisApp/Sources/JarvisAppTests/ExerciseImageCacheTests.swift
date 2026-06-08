import XCTest
@testable import Jarvis

final class ExerciseImageCacheTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExerciseImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_prefetch_firesImageRequestForMissingSlugs() {
        var requested: [String] = []
        let cache = ExerciseImageCache(baseURL: tmpDir) { slug in
            requested.append(slug)
        }
        cache.prefetch(manifest: [
            .init(slug: "incline-db-press", sha256: "abc"),
            .init(slug: "flat-db-press", sha256: "def"),
        ])
        XCTAssertEqual(Set(requested), Set(["incline-db-press", "flat-db-press"]))
    }

    func test_prefetch_skipsAlreadyCachedSlugs() throws {
        var requested: [String] = []
        let cache = ExerciseImageCache(baseURL: tmpDir) { slug in
            requested.append(slug)
        }
        // Seed one image on disk.
        try cache.write(slug: "incline-db-press", sha256: "abc", base64: tinyJpegBase64())
        cache.prefetch(manifest: [
            .init(slug: "incline-db-press", sha256: "abc"),
            .init(slug: "flat-db-press", sha256: "def"),
        ])
        XCTAssertEqual(requested, ["flat-db-press"])
    }

    func test_prefetch_dedupsInflightRequests() {
        var requested: [String] = []
        let cache = ExerciseImageCache(baseURL: tmpDir) { slug in
            requested.append(slug)
        }
        cache.prefetch(manifest: [.init(slug: "incline-db-press", sha256: "abc")])
        cache.prefetch(manifest: [.init(slug: "incline-db-press", sha256: "abc")])
        XCTAssertEqual(requested, ["incline-db-press"])
    }

    func test_write_storesFileAndClearsInflight() throws {
        var requested: [String] = []
        let cache = ExerciseImageCache(baseURL: tmpDir) { slug in
            requested.append(slug)
        }
        cache.prefetch(manifest: [.init(slug: "incline-db-press", sha256: "abc")])
        XCTAssertEqual(requested, ["incline-db-press"])
        let url = try cache.write(slug: "incline-db-press", sha256: "abc", base64: tinyJpegBase64())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(cache.has(slug: "incline-db-press", sha256: "abc"))
        // Re-prefetch the same slug must NOT re-request — and must not be blocked by stale inflight marker either.
        cache.prefetch(manifest: [.init(slug: "incline-db-press", sha256: "abc")])
        XCTAssertEqual(requested, ["incline-db-press"])  // unchanged
    }

    func test_differentSha256_treatedAsCacheMiss() throws {
        var requested: [String] = []
        let cache = ExerciseImageCache(baseURL: tmpDir) { slug in
            requested.append(slug)
        }
        try cache.write(slug: "incline-db-press", sha256: "abc", base64: tinyJpegBase64())
        cache.prefetch(manifest: [.init(slug: "incline-db-press", sha256: "DIFFERENT")])
        XCTAssertEqual(requested, ["incline-db-press"])
    }

    // 1x1 JPEG (smallest valid).
    private func tinyJpegBase64() -> String {
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AKp//9k="
    }
}
