import XCTest
import SwiftUI
@testable import Jarvis

final class LayoutModeTests: XCTestCase {
    func testLandscapeRegularWideIsSplit() {
        XCTAssertEqual(LayoutMode.resolve(width: 1194, height: 834, horizontalSizeClass: .regular), .split)
        XCTAssertEqual(LayoutMode.resolve(width: 1000, height: 700, horizontalSizeClass: .regular), .split)
    }
    func testPortraitIsStacked() {
        XCTAssertEqual(LayoutMode.resolve(width: 834, height: 1194, horizontalSizeClass: .regular), .stacked)
        XCTAssertEqual(LayoutMode.resolve(width: 1024, height: 1366, horizontalSizeClass: .regular), .stacked)
    }
    func testCompactIsStacked() {
        XCTAssertEqual(LayoutMode.resolve(width: 1200, height: 800, horizontalSizeClass: .compact), .stacked)
        XCTAssertEqual(LayoutMode.resolve(width: 390, height: 844, horizontalSizeClass: .compact), .stacked)
    }
    func testBelowMinWidthIsStacked() {
        XCTAssertEqual(LayoutMode.resolve(width: 880, height: 600, horizontalSizeClass: .regular), .stacked)
    }
    func testNilSizeClassIsStacked() {
        XCTAssertEqual(LayoutMode.resolve(width: 1200, height: 800, horizontalSizeClass: nil), .stacked)
    }
    func testBoundaryAt900() {
        XCTAssertEqual(LayoutMode.resolve(width: 900, height: 600, horizontalSizeClass: .regular), .split)
        XCTAssertEqual(LayoutMode.resolve(width: 899, height: 600, horizontalSizeClass: .regular), .stacked)
    }
}
