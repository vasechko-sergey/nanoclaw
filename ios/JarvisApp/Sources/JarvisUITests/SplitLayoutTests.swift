import XCTest

final class SplitLayoutTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Verifies the iPad landscape split assembles both panes: the orb hub
    /// (left) and the chat canvas (right). Orientation is set to landscapeLeft
    /// before launch so the GeometryReader sees regular-width on first render
    /// and LayoutMode.resolve returns .split immediately.
    func testSplitShowsHubAndChatCanvas() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        XCTAssertTrue(app.otherElements["orb-hub-pane"].waitForExistence(timeout: 10),
                      "OrbHubPane must be visible in iPad landscape split")
        XCTAssertTrue(app.otherElements["chat-canvas"].waitForExistence(timeout: 10),
                      "Chat canvas must be visible in iPad landscape split")
    }
}
