import XCTest
import UIKit
@testable import Jarvis

@MainActor
final class ChatImageMappingTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatImageMappingTests-\(UUID().uuidString)", isDirectory: true)
        ChatImageStore.shared = ChatImageStore(baseURL: tmpDir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        ChatImageStore.shared = ChatImageStore(baseURL: ChatImageStore.defaultBaseURL())
    }

    private func row(attachmentsJSON: String) -> StoredMessage {
        StoredMessage(id: "r1", dir: .in_, seq: 1, text: "", attachmentsJSON: attachmentsJSON,
                      contextJSON: nil, status: .delivered, failureReason: nil,
                      ts: 1_700_000_000_000, serverTS: nil, createdAt: 1_700_000_000_000,
                      agentId: "jarvis")
    }

    func test_refImage_buildsThumbnailBubbleWithSHA() throws {
        let sha = ChatImageStore.shared.write(jpeg())
        let json = "[{\"kind\":\"image\",\"name\":\"p.jpg\",\"mime_type\":\"image/jpeg\",\"byte_size\":3,\"sha256\":\"\(sha)\"}]"
        let msgs = WebSocketClientV2.toChatMessage(row(attachmentsJSON: json))
        XCTAssertEqual(msgs.count, 1)
        guard case .image = msgs[0].content else { return XCTFail("expected image content") }
        XCTAssertEqual(msgs[0].imageSHA, sha)
    }

    func test_legacyInlineImage_stillRenders() throws {
        let b64 = jpeg().base64EncodedString()
        let json = "[{\"id\":\"a\",\"kind\":\"image\",\"name\":\"p.jpg\",\"mime_type\":\"image/jpeg\",\"byte_size\":3,\"bytes_base64\":\"\(b64)\",\"remote_id\":null}]"
        let msgs = WebSocketClientV2.toChatMessage(row(attachmentsJSON: json))
        guard case .image = msgs[0].content else { return XCTFail("expected image content") }
        XCTAssertNil(msgs[0].imageSHA)   // legacy → no store ref yet
    }

    func test_fileRef_buildsFileBubble() throws {
        let json = "[{\"kind\":\"file\",\"name\":\"doc.pdf\",\"mime_type\":\"application/pdf\",\"byte_size\":10,\"sha256\":\"abc\"}]"
        let msgs = WebSocketClientV2.toChatMessage(row(attachmentsJSON: json))
        guard case .file = msgs[0].content else { return XCTFail("expected file content") }
    }

    private func jpeg() -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return r.image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
            .jpegData(compressionQuality: 0.8)!
    }
}
