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

    func test_kneeBend_fires_when_both_legs_straight() {
        let sug = KneeBendRule().evaluate(Self.standingStraight())
        XCTAssertEqual(sug?.code, "knee.bend")
        XCTAssertNotNil(sug?.targetDeltas[.leftKnee])
    }

    func test_kneeBend_silent_when_a_knee_already_bent() {
        var joints = Self.standingStraight().joints
        joints[.leftKnee] = JointPoint(position: CGPoint(x: 0.38, y: 0.74), confidence: 0.9) // bent in
        XCTAssertNil(KneeBendRule().evaluate(Skeleton(joints: joints)))
    }

    func test_feetStagger_fires_when_feet_side_by_side() {
        let sug = FeetStaggerRule().evaluate(Self.standingStraight())
        XCTAssertEqual(sug?.code, "feet.stagger")
    }

    func test_feetStagger_silent_when_feet_already_staggered() {
        var joints = Self.standingStraight().joints
        joints[.leftAnkle] = JointPoint(position: CGPoint(x: 0.40, y: 0.90), confidence: 0.9) // forward+up
        XCTAssertNil(FeetStaggerRule().evaluate(Skeleton(joints: joints)))
    }

    func test_bodyAngle_fires_when_shoulders_square_and_wide() {
        let sug = BodyAngleRule().evaluate(Self.standingStraight())
        XCTAssertEqual(sug?.code, "body.angle")
        XCTAssertNotNil(sug?.targetDeltas[.rightShoulder])
    }

    func test_bodyAngle_silent_when_shoulders_narrow() {
        var joints = Self.standingStraight().joints
        joints[.leftShoulder] = JointPoint(position: CGPoint(x: 0.48, y: 0.24), confidence: 0.9)
        joints[.rightShoulder] = JointPoint(position: CGPoint(x: 0.52, y: 0.24), confidence: 0.9)
        XCTAssertNil(BodyAngleRule().evaluate(Skeleton(joints: joints)))
    }

    func test_armsGap_fires_when_wrist_glued_to_hip() {
        var joints = Self.standingStraight().joints
        joints[.leftWrist] = JointPoint(position: CGPoint(x: 0.45, y: 0.56), confidence: 0.9) // at hip x
        let sug = ArmsGapRule().evaluate(Skeleton(joints: joints))
        XCTAssertEqual(sug?.code, "arms.gap")
    }

    func test_armsGap_silent_when_arms_already_out() {
        var joints = Self.standingStraight().joints
        joints[.leftWrist] = JointPoint(position: CGPoint(x: 0.30, y: 0.56), confidence: 0.9) // out
        joints[.rightWrist] = JointPoint(position: CGPoint(x: 0.70, y: 0.56), confidence: 0.9)
        XCTAssertNil(ArmsGapRule().evaluate(Skeleton(joints: joints)))
    }

    func test_elbowBend_fires_on_straight_vertical_arm() {
        var joints = Self.standingStraight().joints
        // left arm straight & vertical: shoulder, elbow, wrist all ~x=0.42
        joints[.leftShoulder] = JointPoint(position: CGPoint(x: 0.42, y: 0.24), confidence: 0.9)
        joints[.leftElbow] = JointPoint(position: CGPoint(x: 0.42, y: 0.40), confidence: 0.9)
        joints[.leftWrist] = JointPoint(position: CGPoint(x: 0.42, y: 0.56), confidence: 0.9)
        let sug = ElbowBendRule().evaluate(Skeleton(joints: joints))
        XCTAssertEqual(sug?.code, "elbow.bend")
    }

    func test_elbowBend_silent_when_elbow_bent_out() {
        var joints = Self.standingStraight().joints
        // Left arm vertical shoulder↔wrist but elbow kicked out → bent, must stay silent.
        // (Right arm in the fixture is diagonal, so it never fires.)
        joints[.leftShoulder] = JointPoint(position: CGPoint(x: 0.42, y: 0.24), confidence: 0.9)
        joints[.leftElbow] = JointPoint(position: CGPoint(x: 0.30, y: 0.40), confidence: 0.9)
        joints[.leftWrist] = JointPoint(position: CGPoint(x: 0.42, y: 0.56), confidence: 0.9)
        XCTAssertNil(ElbowBendRule().evaluate(Skeleton(joints: joints)))
    }

    func test_chinNeck_fires_when_neck_short() {
        var joints = Self.standingStraight().joints
        joints[.nose] = JointPoint(position: CGPoint(x: 0.50, y: 0.20), confidence: 0.9) // close to shoulders
        XCTAssertEqual(ChinNeckRule().evaluate(Skeleton(joints: joints))?.code, "chin.neck")
    }
    func test_chinNeck_silent_when_neck_long() {
        // standingStraight nose is high (0.12) → long neck → silent
        XCTAssertNil(ChinNeckRule().evaluate(Self.standingStraight()))
    }
}
