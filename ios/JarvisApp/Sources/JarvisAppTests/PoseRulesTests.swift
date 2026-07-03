// Sources/JarvisAppTests/PoseRulesTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class PoseRulesTests: XCTestCase {
    // A symmetric, straight, front-facing standing skeleton (screen space, y down).
    static func standingStraight() -> Skeleton {
        func p(_ x: CGFloat, _ y: CGFloat) -> JointPoint {
            JointPoint(position: CGPoint(x: x, y: y), confidence: 0.9)
        }
        return Skeleton(joints: [
            .nose: p(0.50, 0.12),
            .leftShoulder: p(0.42, 0.24), .rightShoulder: p(0.58, 0.24),
            .leftElbow: p(0.36, 0.40), .rightElbow: p(0.64, 0.40),
            .leftWrist: p(0.30, 0.54), .rightWrist: p(0.70, 0.54),  // arms out & diagonal (neutral)
            .leftHip: p(0.45, 0.55), .rightHip: p(0.55, 0.55),
            .leftKnee: p(0.45, 0.75), .rightKnee: p(0.55, 0.75),
            .leftAnkle: p(0.45, 0.94), .rightAnkle: p(0.55, 0.94),
        ])
    }

    func test_weightShift_fires_on_symmetric_straight_stance() {
        let sug = WeightShiftRule().evaluate(Self.standingStraight())
        XCTAssertEqual(sug?.code, "weight.shift")
        // hips get tilted: one hip target moves down, the other up.
        XCTAssertNotEqual(sug?.targetDeltas[.leftHip]?.y, sug?.targetDeltas[.rightHip]?.y)
    }

    func test_weightShift_silent_when_hips_already_tilted() {
        var joints = Self.standingStraight().joints
        joints[.rightHip] = JointPoint(position: CGPoint(x: 0.55, y: 0.50), confidence: 0.9) // raised
        XCTAssertNil(WeightShiftRule().evaluate(Skeleton(joints: joints)))
    }
}
