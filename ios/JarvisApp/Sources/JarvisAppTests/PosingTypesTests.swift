// Sources/JarvisAppTests/PosingTypesTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class PosingTypesTests: XCTestCase {
    func test_skeleton_point_lookup_and_centerX() {
        let s = Skeleton(joints: [
            .leftShoulder: JointPoint(position: CGPoint(x: 0.4, y: 0.3), confidence: 0.9),
            .rightShoulder: JointPoint(position: CGPoint(x: 0.6, y: 0.3), confidence: 0.9),
        ])
        XCTAssertEqual(s.point(.leftShoulder)?.position.x, 0.4)
        XCTAssertNil(s.point(.leftAnkle))
        XCTAssertEqual(s.centerX()!, 0.5, accuracy: 0.0001)
    }

    func test_centerX_falls_back_to_hips_then_nil() {
        let hips = Skeleton(joints: [
            .leftHip: JointPoint(position: CGPoint(x: 0.2, y: 0.6), confidence: 0.8),
            .rightHip: JointPoint(position: CGPoint(x: 0.4, y: 0.6), confidence: 0.8),
        ])
        XCTAssertEqual(hips.centerX()!, 0.3, accuracy: 0.0001)
        XCTAssertNil(Skeleton(joints: [:]).centerX())
    }
}
