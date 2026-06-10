import XCTest
@testable import Jarvis

/// Regression: a stored row carrying BOTH a typed caption and an attachment must
/// render as two bubbles (caption + attachment), not just the attachment — the
/// typed text used to be swallowed when a document was attached.
@MainActor
final class MessageMappingTests: XCTestCase {
    private func fileAttachmentJSON() -> String {
        let att = V2.Attachment(
            id: "a1", kind: "file", name: "Statement.pdf",
            mime_type: "application/pdf", byte_size: 64576,
            bytes_base64: nil, remote_id: nil
        )
        return String(data: try! JSONEncoder().encode([att]), encoding: .utf8)!
    }

    private func row(text: String, attachmentsJSON: String?) -> StoredMessage {
        StoredMessage(
            id: "m1", dir: .out, seq: nil, text: text,
            attachmentsJSON: attachmentsJSON, contextJSON: nil,
            status: .queued, failureReason: nil,
            ts: 1_700_000_000_000, serverTS: nil, createdAt: 1_700_000_000_000
        )
    }

    func testTextOnlyRowMapsToSingleTextBubble() {
        let out = WebSocketClientV2.toChatMessage(row(text: "hi", attachmentsJSON: nil))
        XCTAssertEqual(out.count, 1)
        guard case .text(let t) = out[0].content else { return XCTFail("expected a text bubble") }
        XCTAssertEqual(t, "hi")
    }

    func testTextPlusAttachmentMapsToCaptionThenAttachment() {
        let out = WebSocketClientV2.toChatMessage(
            row(text: "Держи выписку", attachmentsJSON: fileAttachmentJSON())
        )
        XCTAssertEqual(out.count, 2, "caption AND attachment must both render")

        guard case .text(let t) = out[0].content else { return XCTFail("first bubble should be the caption") }
        XCTAssertEqual(t, "Держи выписку")

        guard case .file = out[1].content else { return XCTFail("second bubble should be the file") }
        XCTAssertEqual(out[1].id, "m1", "attachment keeps the row id for delivery-status updates")
        XCTAssertNotEqual(out[0].id, out[1].id, "bubbles need distinct ids for ForEach")
    }

    func testAttachmentOnlyRowMapsToSingleAttachmentBubble() {
        let out = WebSocketClientV2.toChatMessage(row(text: "  ", attachmentsJSON: fileAttachmentJSON()))
        XCTAssertEqual(out.count, 1, "blank caption produces no extra bubble")
        guard case .file = out[0].content else { return XCTFail("expected a file bubble") }
    }
}
