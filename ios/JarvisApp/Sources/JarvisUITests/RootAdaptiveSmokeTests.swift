import XCTest

final class RootAdaptiveSmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Smoke: after launch, RootAdaptiveView transitions through splash and
    /// lands on the home orb view. Verifies the new root wiring doesn't break
    /// the stacked flow on iPhone.
    ///
    /// Forces portrait so that on iPad (which defaults to landscape, triggering
    /// the split layout) this test still validates the stacked path. The split
    /// path is validated by SplitLayoutTests.
    func testStackedHomeAppearsOnLaunch() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        XCTAssertTrue(app.otherElements["orb-home"].waitForExistence(timeout: 8),
                      "Home view (orb-home) must appear after splash completes")
    }
}
