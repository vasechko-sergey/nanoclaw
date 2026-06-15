import XCTest

final class RootAdaptiveSmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Smoke: after launch, RootAdaptiveView transitions through splash and
    /// lands on the home orb view. Verifies the new root wiring doesn't break
    /// the stacked flow on iPhone.
    func testStackedHomeAppearsOnLaunch() {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        XCTAssertTrue(app.otherElements["orb-home"].waitForExistence(timeout: 8),
                      "Home view (orb-home) must appear after splash completes")
    }
}
