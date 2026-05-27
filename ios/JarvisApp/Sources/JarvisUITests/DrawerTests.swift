import XCTest

final class DrawerTests: XCTestCase {
    func testHamburgerOpensDrawer() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "1"]
        app.launch()

        let textStart = app.descendants(matching: .any)
            .matching(identifier: "empty-start-text").firstMatch
        if textStart.waitForExistence(timeout: 5) { textStart.tap() }

        let chatView = app.descendants(matching: .any)
            .matching(identifier: "chat-view").firstMatch
        XCTAssertTrue(chatView.waitForExistence(timeout: 5))

        let hamburger = app.buttons["hamburger-btn"]
        XCTAssertTrue(hamburger.waitForExistence(timeout: 3), "hamburger-btn not found")
        hamburger.tap()

        let drawer = app.descendants(matching: .any)
            .matching(identifier: "conv-drawer").firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 2), "conv-drawer didn't appear after hamburger tap")
    }

    func testEdgeSwipeOpensDrawer() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "1"]
        app.launch()

        let textStart = app.descendants(matching: .any)
            .matching(identifier: "empty-start-text").firstMatch
        if textStart.waitForExistence(timeout: 5) { textStart.tap() }

        let chatView = app.descendants(matching: .any)
            .matching(identifier: "chat-view").firstMatch
        XCTAssertTrue(chatView.waitForExistence(timeout: 5))

        let start = chatView.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = chatView.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        let drawer = app.descendants(matching: .any)
            .matching(identifier: "conv-drawer").firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 2), "conv-drawer didn't appear after edge-swipe")
    }
}
