import XCTest
import GRDB
import UIKit
@testable import Jarvis

/// Repro for the surf-forecast "пустые ответы" bug: Jarvis answers with an
/// image (send_photo) that has an EMPTY caption. The message lands first as a
/// background pull stub (text-only), then the WS drains the full envelope with
/// the image attachment. The chat must end up showing the image, not an empty
/// bubble.
@MainActor
final class SurfImageBubbleTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurfImageBubbleTests-\(UUID().uuidString)", isDirectory: true)
        ChatImageStore.shared = ChatImageStore(baseURL: tmpDir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        ChatImageStore.shared = ChatImageStore(baseURL: ChatImageStore.defaultBaseURL())
    }

    /// A valid, decodable JPEG (so ChatImageStore.thumbnail can render it).
    private func jpeg() -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        return r.image { ctx in UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24)) }
            .jpegData(compressionQuality: 0.8)!
    }

    private func imageEnvelope(id: String, caption: String) -> (V2.Envelope, V2.Message) {
        let b64 = jpeg().base64EncodedString()
        let att = V2.Attachment(id: "a1", kind: "image", name: "surf_galle_6jul.jpg",
                                mime_type: "image/jpeg", byte_size: jpeg().count,
                                bytes_base64: b64, remote_id: nil)
        let m = V2.Message(thread_id: "t", text: caption, attachments: [att], agent_id: "jarvis")
        let e = V2.Envelope(v: 2, kind: .data, type: .message, id: id, seq: 5,
                            ts: "2026-07-06T12:32:15.000Z", payload: .message(m))
        return (e, m)
    }

    private func mapped(_ dbq: DatabaseQueue) throws -> [ChatMessage] {
        let rows = try dbq.read { try ConversationStoreV2.windowedRows($0, perAgent: 500) }
        return rows.flatMap(WebSocketClientV2.toChatMessage)
    }

    // The exact production sequence: background pull stub first, WS full envelope second.
    func test_emptyCaptionImage_pullThenWS_rendersImage() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        try store.insertInboundFromPull(id: "surf1", seq: 5, text: "", agentId: "jarvis", ts: 1000)
        let (e, m) = imageEnvelope(id: "surf1", caption: "")
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")

        let msgs = try mapped(dbq)
        XCTAssertEqual(msgs.count, 1, "one image bubble, not an empty text bubble")
        guard case .image = msgs[0].content else {
            return XCTFail("expected .image, got \(msgs[0].content) — surf empty-bubble bug")
        }
    }

    // WS-only (no prior pull stub), empty caption.
    func test_emptyCaptionImage_wsOnly_rendersImage() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        let (e, m) = imageEnvelope(id: "surf2", caption: "")
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")

        let msgs = try mapped(dbq)
        XCTAssertEqual(msgs.count, 1)
        guard case .image = msgs[0].content else {
            return XCTFail("expected .image, got \(msgs[0].content)")
        }
    }

    // ROOT CAUSE: ChatImageStore.write() swallows a disk-write failure (`try?`)
    // and returns the sha anyway; StoredAttachment.from() trusts it and NILs the
    // inline bytes_base64 — so a failed persist loses the image forever (thumbnail
    // is nil → the mapper degrades to a .file/empty bubble). On a persist failure
    // the inline bytes must be kept so the image still renders (legacy path).
    func test_storeWriteFails_imageFallsBackToInline_notLost() throws {
        // A regular FILE at the store's baseURL path → createDirectory and every
        // write(to: baseURL/<sha>) fail (the parent is not a directory).
        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocked.path, contents: Data([0x1]))
        defer { try? FileManager.default.removeItem(at: blocked) }
        ChatImageStore.shared = ChatImageStore(baseURL: blocked)
        XCTAssertEqual(ChatImageStore.shared.write(jpeg()), ChatImageStore.sha256Hex(jpeg()))
        XCTAssertFalse(ChatImageStore.shared.has(sha: ChatImageStore.sha256Hex(jpeg())),
                       "precondition: the write must have failed to persist")

        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        let (e, m) = imageEnvelope(id: "surf3", caption: "")
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")

        let msgs = try mapped(dbq)
        XCTAssertEqual(msgs.count, 1)
        guard case .image = msgs[0].content else {
            return XCTFail("store write failed → image must fall back to inline bytes, got \(msgs[0].content)")
        }
    }
}
