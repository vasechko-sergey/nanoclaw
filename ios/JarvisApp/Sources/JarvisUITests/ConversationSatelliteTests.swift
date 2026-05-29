import XCTest

final class ConversationSatelliteTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    /// Smoke: the home view renders without crash after the satellite
    /// refactor. Catches build-time and runtime regressions in the new
    /// computed-property path even though we can't tap individual satellites
    /// reliably from XCUITest.
    func testHomeRendersWithConversationSatelliteRefactor() {
        let app = launchApp()
        let home = app.otherElements["orb-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5),
                      "Home view must still render after the satellite refactor")
    }
}
