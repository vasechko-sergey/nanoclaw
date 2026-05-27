import XCTest

final class DrawerTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Navigate from splash → home → chat. Mirrors JarvisUITests.navigateToChat.
    private func navigateToChat() {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "orb-home not found — splash did not complete")

        let startChatBtn = app.buttons.matching(
            NSPredicate(format: "label == 'uitest-start-text-chat'")
        ).firstMatch
        XCTAssertTrue(startChatBtn.waitForExistence(timeout: 3), "uitest-start-text-chat button not found")
        startChatBtn.tap()

        let chatView = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'chat-view'")
        ).firstMatch
        XCTAssertTrue(chatView.waitForExistence(timeout: 5), "chat-view not found")
    }

    func testEdgeSwipeOpensDrawer() {
        navigateToChat()

        let chatView = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'chat-view'")
        ).firstMatch
        XCTAssertTrue(chatView.waitForExistence(timeout: 3))

        let start = chatView.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = chatView.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        let drawerTitle = app.staticTexts["Диалоги"]
        XCTAssertTrue(drawerTitle.waitForExistence(timeout: 2), "drawer header 'Диалоги' didn't appear after edge-swipe")
    }
}
