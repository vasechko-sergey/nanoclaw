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
}
