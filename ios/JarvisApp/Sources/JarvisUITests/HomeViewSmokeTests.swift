import XCTest

final class HomeViewSmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
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
