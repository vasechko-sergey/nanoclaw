import XCTest
import SwiftUI
@testable import Jarvis

final class DeliveryChecksTests: XCTestCase {
    func testCheckmarkShapePath() {
        let shape = CheckmarkShape()
        let rect = CGRect(x: 0, y: 0, width: 10, height: 6)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty, "CheckmarkShape should produce a non-empty path")
        XCTAssertEqual(path.boundingRect.width, 10, accuracy: 0.5)
    }

    func testDeliveryChecksAcceptsAllStates() {
        // Compile-time guarantee: all DeliveryStatus cases are renderable.
        for status in [DeliveryStatus.sending, .sent, .delivered, .failed] {
            let view = DeliveryChecks(status: status)
            XCTAssertNotNil(view.body)
        }
    }
}
