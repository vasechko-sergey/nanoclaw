import XCTest

final class HomeViewSmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        // Force portrait so RootAdaptiveView resolves to .stacked and orb-home appears.
        // On iPad Pro 13-inch the default simulator orientation is landscape, which would
        // trigger the split layout and never show orb-home.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    /// Smoke: the home view renders without crash. Catches build-time and
    /// runtime regressions in the orb-home composition.
    func testHomeRenders() {
        let app = launchApp()
        let home = app.otherElements["orb-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5),
                      "Home view must render on launch")
    }
}
