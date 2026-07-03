// Sources/JarvisAppTests/PoseDetectorMappingTests.swift
import XCTest
import Vision
@testable import Jarvis

final class PoseDetectorMappingTests: XCTestCase {
    func test_maps_known_vision_joints() {
        XCTAssertEqual(PoseDetector.map(.nose), .nose)
        XCTAssertEqual(PoseDetector.map(.leftShoulder), .leftShoulder)
        XCTAssertEqual(PoseDetector.map(.rightAnkle), .rightAnkle)
    }

    func test_flips_y_from_vision_to_screen_space() {
        // Vision origin bottom-left (y up); screen origin top-left (y down).
        let p = PoseDetector.toScreen(CGPoint(x: 0.3, y: 0.8))
        XCTAssertEqual(p.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(p.y, 0.2, accuracy: 0.0001)
    }
}
