import XCTest
import UIKit
@testable import Jarvis

final class ChatImageStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var store: ChatImageStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatImageStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = ChatImageStore(baseURL: tmpDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_write_isContentAddressed_andDedupes() {
        let data = jpeg()
        let sha1 = store.write(data)
        let sha2 = store.write(data)
        XCTAssertEqual(sha1, sha2)                       // same bytes → same key
        XCTAssertTrue(store.has(sha: sha1))
        XCTAssertEqual(store.bytes(sha: sha1), data)     // round-trips
    }

    func test_thumbnail_andFullImage_decode() {
        let sha = store.write(jpeg())
        XCTAssertNotNil(store.thumbnail(sha: sha))
        XCTAssertNotNil(store.fullImage(sha: sha, maxPixel: 2048))
    }

    func test_missingKey_returnsNil() {
        XCTAssertNil(store.bytes(sha: "deadbeef"))
        XCTAssertNil(store.thumbnail(sha: "deadbeef"))
        XCTAssertFalse(store.has(sha: "deadbeef"))
    }

    func test_sha256Hex_isStable() {
        XCTAssertEqual(
            ChatImageStore.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // A small valid JPEG rendered at runtime (8x8 red).
    private func jpeg() -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let img = r.image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return img.jpegData(compressionQuality: 0.8)!
    }
}
