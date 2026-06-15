import XCTest
@testable import Jarvis

// These tests mutate Theme's process-global scale/drawer caches. Each test
// sets the cache via refreshScale/refreshDrawerWidth before asserting, so order
// independence holds; do not read Theme.scale here without setting it first.
final class ThemeScaleTests: XCTestCase {
    func testExplicitWidthDrivesScaleClamped() {
        Theme.refreshScale(width: 390)
        XCTAssertEqual(Theme.scale, 1.0, accuracy: 0.001)
        Theme.refreshScale(width: 1200)            // would be ~3.0, clamps to 1.15
        XCTAssertEqual(Theme.scale, 1.15, accuracy: 0.001)
        Theme.refreshScale(width: 300)             // would be ~0.77, clamps to 0.92
        XCTAssertEqual(Theme.scale, 0.92, accuracy: 0.001)
    }
    func testExplicitWidthDrivesDrawerWidth() {
        Theme.refreshDrawerWidth(width: 1000)
        XCTAssertEqual(Theme.drawerWidth, 780, accuracy: 0.5)
    }
}
