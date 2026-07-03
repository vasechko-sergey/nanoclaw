// Sources/JarvisAppTests/CompositionEngineTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class CompositionEngineTests: XCTestCase {
    private func frame(tilt: Double = 0) -> FrameInfo {
        FrameInfo(size: CGSize(width: 390, height: 844), tiltDegrees: tilt)
    }

    func test_tilt_beyond_threshold_warns() {
        let hints = CompositionEngine.hints(skeleton: Skeleton(joints: [:]), frame: frame(tilt: 10))
        XCTAssertTrue(hints.contains { $0.code == "tilt.level" })
    }

    func test_small_tilt_no_hint() {
        let hints = CompositionEngine.hints(skeleton: Skeleton(joints: [:]), frame: frame(tilt: 2))
        XCTAssertFalse(hints.contains { $0.code == "tilt.level" })
    }

    private func skeleton(noseY: CGFloat) -> Skeleton {
        Skeleton(joints: [.nose: JointPoint(position: CGPoint(x: 0.5, y: noseY), confidence: 0.9)])
    }

    func test_headroom_too_tight_warns() {
        let hints = CompositionEngine.hints(skeleton: skeleton(noseY: 0.02), frame: frame())
        XCTAssertTrue(hints.contains { $0.code == "headroom.tight" })
    }

    func test_headroom_too_loose_infos() {
        let hints = CompositionEngine.hints(skeleton: skeleton(noseY: 0.30), frame: frame())
        XCTAssertTrue(hints.contains { $0.code == "headroom.loose" })
    }

    func test_headroom_ok_no_hint() {
        let hints = CompositionEngine.hints(skeleton: skeleton(noseY: 0.12), frame: frame())
        XCTAssertFalse(hints.contains { $0.code.hasPrefix("headroom") })
    }

    func test_knees_visible_ankles_missing_warns_crop() {
        let s = Skeleton(joints: [
            .leftKnee: JointPoint(position: CGPoint(x: 0.45, y: 0.8), confidence: 0.8),
            .rightKnee: JointPoint(position: CGPoint(x: 0.55, y: 0.8), confidence: 0.8),
        ])
        let hints = CompositionEngine.hints(skeleton: s, frame: frame())
        XCTAssertTrue(hints.contains { $0.code == "crop.ankle" })
    }

    func test_full_legs_visible_no_crop_hint() {
        let s = Skeleton(joints: [
            .leftKnee: JointPoint(position: CGPoint(x: 0.45, y: 0.7), confidence: 0.8),
            .rightKnee: JointPoint(position: CGPoint(x: 0.55, y: 0.7), confidence: 0.8),
            .leftAnkle: JointPoint(position: CGPoint(x: 0.45, y: 0.9), confidence: 0.8),
            .rightAnkle: JointPoint(position: CGPoint(x: 0.55, y: 0.9), confidence: 0.8),
        ])
        let hints = CompositionEngine.hints(skeleton: s, frame: frame())
        XCTAssertFalse(hints.contains { $0.code == "crop.ankle" })
    }

    private func shoulders(centerX: CGFloat) -> Skeleton {
        Skeleton(joints: [
            .leftShoulder: JointPoint(position: CGPoint(x: centerX - 0.05, y: 0.3), confidence: 0.9),
            .rightShoulder: JointPoint(position: CGPoint(x: centerX + 0.05, y: 0.3), confidence: 0.9),
            .nose: JointPoint(position: CGPoint(x: centerX, y: 0.15), confidence: 0.9),
        ])
    }

    func test_dead_center_subject_nudged_to_third() {
        let hints = CompositionEngine.hints(skeleton: shoulders(centerX: 0.5), frame: frame())
        XCTAssertTrue(hints.contains { $0.code == "thirds.center" })
    }

    func test_subject_on_third_no_nudge() {
        let hints = CompositionEngine.hints(skeleton: shoulders(centerX: 1.0/3), frame: frame())
        XCTAssertFalse(hints.contains { $0.code == "thirds.center" })
    }
}
