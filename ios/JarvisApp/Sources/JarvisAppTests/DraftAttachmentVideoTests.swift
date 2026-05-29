import XCTest
import UIKit
@testable import Jarvis

final class DraftAttachmentVideoTests: XCTestCase {

    private func dummyThumb() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        return renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    func testVideoFactorySetsKindAndFields() {
        let thumb = dummyThumb()
        let data = Data(repeating: 0, count: 1024)
        let v = DraftAttachment.video(name: "test.mp4",
                                      thumbnail: thumb,
                                      duration: 12.0,
                                      data: data,
                                      mimeType: "video/mp4")
        XCTAssertEqual(v.kind, .video)
        XCTAssertEqual(v.name, "test.mp4")
        XCTAssertEqual(v.mimeType, "video/mp4")
        XCTAssertEqual(v.size, 1024)
        XCTAssertEqual(v.duration, 12.0)
        XCTAssertNotNil(v.thumbnail)
        XCTAssertNotNil(v.image, "video preview should populate the image slot so existing chip code works")
    }

    func testVideoPayloadIncludesDuration() {
        let v = DraftAttachment.video(name: "v.mp4", thumbnail: dummyThumb(),
                                      duration: 18.7, data: Data(count: 100),
                                      mimeType: "video/mp4")
        let p = v.payload
        XCTAssertEqual(p["name"] as? String, "v.mp4")
        XCTAssertEqual(p["mimeType"] as? String, "video/mp4")
        XCTAssertEqual(p["size"] as? Int, 100)
        XCTAssertEqual(p["duration"] as? Int, 18, "duration is encoded as integer seconds (truncated)")
        XCTAssertNotNil(p["data"] as? String, "base64 data still present")
    }

    func testImagePayloadOmitsDuration() {
        let img = dummyThumb()
        let a = DraftAttachment.image(img, name: "photo.jpg")!
        XCTAssertNil(a.payload["duration"], "image attachments must not carry a duration key")
    }

    func testSizeCapRejectsAtOneHundredMB() {
        let big = Data(count: 100 * 1024 * 1024 + 1)
        XCTAssertThrowsError(try DraftAttachment.checkVideoSize(big)) { err in
            XCTAssertEqual(err as? DraftAttachment.VideoError, .tooLarge)
        }
    }

    func testSizeCapAllowsBelowOneHundredMB() {
        let ok = Data(count: 100 * 1024 * 1024 - 1)
        XCTAssertNoThrow(try DraftAttachment.checkVideoSize(ok))
    }
}
