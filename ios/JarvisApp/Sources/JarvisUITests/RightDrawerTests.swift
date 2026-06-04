import XCTest

final class RightDrawerTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    /// Navigate from splash → home → chat. In UI-testing mode, splash auto-skips
    /// straight to home (see SplashView.startAnimation). ChatView's root
    /// `.accessibilityIdentifier("chat-view")` propagates to every descendant, so
    /// we cannot match drawer buttons by their finer-grained identifiers
    /// (`right-drawer-btn`, `orb-drawer-btn`, `right-drawer`, `conv-drawer`).
    /// Tests rely on the buttons' accessibilityLabels and on the distinctive
    /// drawer header text instead.
    private func navigateToChat(_ app: XCUIApplication) {
        let startChatBtn = app.buttons.matching(
            NSPredicate(format: "label == 'uitest-start-text-chat'")
        ).firstMatch
        XCTAssertTrue(startChatBtn.waitForExistence(timeout: 8),
                      "uitest-start-text-chat not found — splash/home transition stalled")
        startChatBtn.tap()

        // Wait for the chat input field to appear, signalling ChatView is active.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8),
                      "chat input never appeared — ChatView did not activate")
    }

    /// The right HeaderStatusDot button — identified by its accessibilityLabel
    /// because the root `chat-view` identifier propagates down and overrides
    /// the dot's finer-grained `right-drawer-btn` identifier.
    private func rightDot(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label == 'Открыть профиль и настройки'")
        ).firstMatch
    }

    func testRightDrawerOpensViaDotTap() {
        let app = launchApp()
        navigateToChat(app)

        let dot = rightDot(app)
        XCTAssertTrue(dot.waitForExistence(timeout: 5))
        dot.tap()

        // The right drawer's distinctive header text confirms it's now on screen.
        XCTAssertTrue(app.staticTexts["Профиль и настройки"].waitForExistence(timeout: 2),
                      "right drawer did not open")
    }

    func testRightDrawerClosesByTappingShroud() {
        let app = launchApp()
        navigateToChat(app)

        let dot = rightDot(app)
        XCTAssertTrue(dot.waitForExistence(timeout: 5))
        dot.tap()

        let drawerHeader = app.staticTexts["Профиль и настройки"]
        XCTAssertTrue(drawerHeader.waitForExistence(timeout: 2), "right drawer did not open")
        // The drawer's header is only hittable when the drawer is on-screen — both
        // drawers are mounted at all times and slide via offset; `exists` stays true.
        XCTAssertTrue(drawerHeader.isHittable, "right drawer header should be hittable when open")

        // Tap the left edge of the screen (outside the drawer's frame, on the shroud).
        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        coordinate.tap()

        // Drawer closes — its header slides off-screen, so `isHittable` flips to false.
        let predicate = NSPredicate(format: "hittable == false")
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: drawerHeader)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 2), .completed,
                       "right drawer did not close after shroud tap")
    }

}
