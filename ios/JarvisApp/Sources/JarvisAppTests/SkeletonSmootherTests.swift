import XCTest
import CoreGraphics
@testable import Jarvis

final class SkeletonSmootherTests: XCTestCase {
    private func skel(_ x: CGFloat) -> Skeleton {
        Skeleton(joints: [.nose: JointPoint(position: CGPoint(x: x, y: 0.5), confidence: 0.9)])
    }
    func test_first_frame_passes_through() {
        let s = SkeletonSmoother(alpha: 0.5)
        XCTAssertEqual(s.smooth(skel(0.2))?.point(.nose)?.position.x, 0.2)
    }
    func test_second_frame_moves_partway() {
        let s = SkeletonSmoother(alpha: 0.5)
        _ = s.smooth(skel(0.2))
        XCTAssertEqual(s.smooth(skel(0.4))?.point(.nose)?.position.x ?? 0, 0.3, accuracy: 0.0001)
    }
    func test_nil_resets() {
        let s = SkeletonSmoother(alpha: 0.5)
        _ = s.smooth(skel(0.2)); _ = s.smooth(nil)
        XCTAssertEqual(s.smooth(skel(0.8))?.point(.nose)?.position.x, 0.8) // fresh, no blend
    }
}
