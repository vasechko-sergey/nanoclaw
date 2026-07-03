// Sources/JarvisAppTests/HintStabilizerTests.swift
import XCTest
@testable import Jarvis

final class HintStabilizerTests: XCTestCase {
    private func hint(_ code: String) -> Hint {
        Hint(kind: .composition, severity: .info, text: code, code: code)
    }

    func test_hint_appears_only_after_threshold_frames() {
        let s = HintStabilizer(appearFrames: 3, disappearFrames: 3)
        XCTAssertTrue(s.step([hint("a")]).isEmpty)   // frame 1
        XCTAssertTrue(s.step([hint("a")]).isEmpty)   // frame 2
        XCTAssertEqual(s.step([hint("a")]).map(\.code), ["a"]) // frame 3 → shown
    }

    func test_hint_persists_through_brief_dropout() {
        let s = HintStabilizer(appearFrames: 1, disappearFrames: 3)
        _ = s.step([hint("a")])                       // shown immediately
        XCTAssertEqual(s.step([]).map(\.code), ["a"]) // 1 missing frame → still shown
        XCTAssertEqual(s.step([]).map(\.code), ["a"]) // 2 missing → still shown
        XCTAssertTrue(s.step([]).isEmpty)             // 3 missing → dropped
    }
}
