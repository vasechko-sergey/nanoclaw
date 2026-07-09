import XCTest
import UIKit
@testable import Jarvis

final class InvertedListCellTests: XCTestCase {
    private let flip = CGAffineTransform(scaleX: 1, y: -1)

    /// The bug: the hosting-config install resets `contentView.transform` to
    /// identity. `layoutSubviews` must restore the counter-flip so content renders
    /// upright from the first paint, not only after a scroll-triggered recycle.
    func test_layoutSubviews_restoresCounterFlipFromIdentity() {
        let cell = InvertedListCell(frame: CGRect(x: 0, y: 0, width: 120, height: 44))
        cell.contentView.transform = .identity
        cell.layoutSubviews()
        XCTAssertEqual(cell.contentView.transform, flip)
    }

    /// Idempotent: once flipped, a further layout pass keeps the same flip (an
    /// assign, not a multiply — so it never oscillates back to identity).
    func test_layoutSubviews_idempotent() {
        let cell = InvertedListCell(frame: CGRect(x: 0, y: 0, width: 120, height: 44))
        cell.layoutSubviews()
        cell.layoutSubviews()
        XCTAssertEqual(cell.contentView.transform, flip)
    }
}
