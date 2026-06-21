import XCTest
import GRDB
@testable import Jarvis

final class StoredAttachmentTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        ChatImageStore.shared = ChatImageStore(baseURL: tmpDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        ChatImageStore.shared = ChatImageStore(baseURL: ChatImageStore.defaultBaseURL())
    }

    func test_decodesLegacyV2AttachmentJSON() throws {
        // Legacy shape: has `id`, inline `bytes_base64`, no `sha256`.
        let json = """
        [{"id":"a1","kind":"image","name":"p.jpg","mime_type":"image/jpeg","byte_size":3,"bytes_base64":"YWJj","remote_id":null}]
        """
        let atts = try JSONDecoder().decode([StoredAttachment].self, from: Data(json.utf8))
        XCTAssertEqual(atts.count, 1)
        XCTAssertEqual(atts[0].kind, "image")
        XCTAssertEqual(atts[0].bytes_base64, "YWJj")
        XCTAssertNil(atts[0].sha256)
    }

    func test_fromWire_movesImageBytesToStore() {
        let wire = V2.Attachment(id: "x", kind: "image", name: "p.jpg",
                                 mime_type: "image/jpeg", byte_size: 3,
                                 bytes_base64: Data("abc".utf8).base64EncodedString(),
                                 remote_id: nil)
        let stored = StoredAttachment.from(wire)
        XCTAssertNil(stored.bytes_base64)                       // bytes left the row
        XCTAssertNotNil(stored.sha256)
        XCTAssertTrue(ChatImageStore.shared.has(sha: stored.sha256!))
    }

    func test_fromWire_keepsAudioInline() {
        let wire = V2.Attachment(id: "x", kind: "audio", name: "v.m4a",
                                 mime_type: "audio/m4a", byte_size: 3,
                                 bytes_base64: "YWJj", remote_id: nil)
        let stored = StoredAttachment.from(wire)
        XCTAssertEqual(stored.bytes_base64, "YWJj")             // audio stays inline
        XCTAssertNil(stored.sha256)
    }

    func test_encode_omitsNilOptionals() throws {
        let stored = StoredAttachment(kind: "image", name: "p.jpg", mime_type: "image/jpeg",
                                      byte_size: 3, sha256: "abc", bytes_base64: nil, remote_id: nil)
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"sha256\":\"abc\""))
        XCTAssertFalse(json.contains("bytes_base64"))           // nil optional omitted
    }

    func test_insertOutbound_movesImageBytesToStore() throws {
        let dbq = try DatabaseQueue()           // in-memory
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        let wire = V2.Attachment(id: "x", kind: "image", name: "p.jpg",
                                 mime_type: "image/jpeg", byte_size: 3,
                                 bytes_base64: Data("abc".utf8).base64EncodedString(),
                                 remote_id: nil)
        try store.insertOutboundUserMessage(id: "m1", text: "hi", attachments: [wire], context: nil)

        let stored = try store.fetchById("m1")!
        let json = stored.attachmentsJSON!
        XCTAssertFalse(json.contains("bytes_base64"), "bytes must not stay in the row")
        XCTAssertTrue(json.contains("sha256"))
        let atts = try JSONDecoder().decode([StoredAttachment].self, from: Data(json.utf8))
        XCTAssertTrue(ChatImageStore.shared.has(sha: atts[0].sha256!))
    }

    func test_insertInbound_movesImageBytes_keepsAudioInline() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        let img = V2.Attachment(id: "i", kind: "image", name: "p.jpg", mime_type: "image/jpeg",
                                byte_size: 3, bytes_base64: Data("abc".utf8).base64EncodedString(), remote_id: nil)
        let env = V2.Envelope(v: 2, kind: .data, type: .message, id: "in1", seq: 3,
                              ts: "2026-06-21T00:00:00Z",
                              payload: .message(V2.Message(thread_id: "t", text: "look", attachments: [img])))
        try store.insertInbound(envelope: env, message: V2.Message(thread_id: "t", text: "look", attachments: [img]))
        let json = try store.fetchById("in1")!.attachmentsJSON!
        XCTAssertFalse(json.contains("bytes_base64"))
        XCTAssertTrue(json.contains("sha256"))

        // appendAttachment (audio voice-note merge) keeps the bytes inline.
        let audio = V2.Attachment(id: "v", kind: "audio", name: "v.m4a", mime_type: "audio/m4a",
                                  byte_size: 3, bytes_base64: "YWJj", remote_id: nil)
        XCTAssertTrue(try store.appendAttachment(toRowId: "in1", attachment: audio))
        let merged = try store.fetchById("in1")!.attachmentsJSON!
        let atts = try JSONDecoder().decode([StoredAttachment].self, from: Data(merged.utf8))
        XCTAssertEqual(atts.last?.bytes_base64, "YWJj")
    }

    func test_hydrateForWire_loadsBytesFromStore() {
        let sha = ChatImageStore.shared.write(Data("abc".utf8))
        let stored = StoredAttachment(kind: "image", name: "p.jpg", mime_type: "image/jpeg",
                                      byte_size: 3, sha256: sha, bytes_base64: nil, remote_id: nil)
        let wire = TransportV2.hydrateForWire([stored])
        XCTAssertEqual(wire.count, 1)
        XCTAssertEqual(wire[0].bytes_base64, Data("abc".utf8).base64EncodedString())
        XCTAssertEqual(wire[0].kind, "image")
    }

    func test_hydrateForWire_passesInlineBytesThrough() {
        let stored = StoredAttachment(kind: "audio", name: "v.m4a", mime_type: "audio/m4a",
                                      byte_size: 3, sha256: nil, bytes_base64: "YWJj", remote_id: nil)
        let wire = TransportV2.hydrateForWire([stored])
        XCTAssertEqual(wire[0].bytes_base64, "YWJj")
    }
}
