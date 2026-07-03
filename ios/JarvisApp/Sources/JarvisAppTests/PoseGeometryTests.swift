// Sources/JarvisAppTests/PoseGeometryTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class PoseGeometryTests: XCTestCase {
    func test_angle_straight_line_is_180() {
        let a = CGPoint(x: 0, y: 0), v = CGPoint(x: 0, y: 1), b = CGPoint(x: 0, y: 2)
        XCTAssertEqual(PoseGeometry.angle(a, v, b), 180, accuracy: 0.5)
    }
    func test_angle_right_angle_is_90() {
        let a = CGPoint(x: 1, y: 0), v = CGPoint(x: 0, y: 0), b = CGPoint(x: 0, y: 1)
        XCTAssertEqual(PoseGeometry.angle(a, v, b), 90, accuracy: 0.5)
    }
    func test_midpoint() {
        let m = PoseGeometry.midpoint(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        XCTAssertEqual(m.x, 0.5, accuracy: 0.0001); XCTAssertEqual(m.y, 0.5, accuracy: 0.0001)
    }
}
