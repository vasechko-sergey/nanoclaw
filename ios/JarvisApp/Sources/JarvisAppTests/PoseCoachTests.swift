// Sources/JarvisAppTests/PoseCoachTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class PoseCoachTests: XCTestCase {
    func test_guide_caps_at_two_hints_and_builds_ghost() {
        let g = PoseCoach.guide(PoseRulesTests.standingStraight())
        XCTAssertEqual(g.hints.count, 2)                 // top-2 by priority
        XCTAssertEqual(g.hints.first?.code, "weight.shift") // priority 0 wins
        XCTAssertTrue(g.hints.allSatisfy { $0.kind == .pose })
        XCTAssertNotNil(g.ghost)
        XCTAssertFalse(g.arrows.isEmpty)
    }

    func test_guide_empty_without_standing_body() {
        // Only a face — no hips/knees → not a standing body.
        let s = Skeleton(joints: [.nose: JointPoint(position: CGPoint(x: 0.5, y: 0.1), confidence: 0.9)])
        let g = PoseCoach.guide(s)
        XCTAssertTrue(g.hints.isEmpty)
        XCTAssertNil(g.ghost)
    }

    func test_applyDeltas_moves_only_targeted_joints() {
        let base = PoseRulesTests.standingStraight()
        let moved = PoseCoach.applyDeltas(base, [.leftHip: CGPoint(x: 0.1, y: 0.2)])
        XCTAssertEqual(moved.point(.leftHip)?.position, CGPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(moved.point(.rightHip)?.position, base.point(.rightHip)?.position)
    }

    func test_cameraAbove_fires_when_level_and_full_body() {
        XCTAssertEqual(PoseCoach.cameraAboveHint(pitchDegrees: 0, fullBody: true)?.code, "camera.above")
    }
    func test_cameraAbove_silent_without_full_body() {
        XCTAssertNil(PoseCoach.cameraAboveHint(pitchDegrees: 0, fullBody: false))
    }
    func test_cameraAbove_silent_when_pointing_down() {
        XCTAssertNil(PoseCoach.cameraAboveHint(pitchDegrees: 30, fullBody: true))
    }
}
