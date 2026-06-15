import XCTest

/// Verifies that tapping an agent satellite in the split-layout OrbHubPane
/// promotes that agent to active, demoting the previous active agent to a satellite.
final class SplitAgentSwitchTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testTappingAgentSatelliteSwapsActiveAgent() {
        // Orientation must be set before launch so LayoutMode.resolve sees
        // regular-width on first render and returns .split immediately.
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()

        // Wait for the split pane to be visible.
        XCTAssertTrue(app.otherElements["orb-hub-pane"].waitForExistence(timeout: 10),
                      "OrbHubPane must be present in landscape split")

        // Jarvis starts active → Payne is a satellite in the orbit.
        // HomeSatelliteOrb applies .accessibilityLabel(label) where label = agent.displayName.
        // displayName for .payne == "Maj Payne".
        let payne = app.buttons["Maj Payne"]
        XCTAssertTrue(payne.waitForExistence(timeout: 5),
                      "Payne satellite must exist before tap (Jarvis is active)")
        payne.tap()

        // After the tap, Payne is active → Jarvis is now a non-active satellite.
        // displayName for .jarvis == "Jarvis".
        XCTAssertTrue(app.buttons["Jarvis"].waitForExistence(timeout: 5),
                      "Jarvis satellite must appear after promoting Payne (proves the switch happened)")
    }
}
