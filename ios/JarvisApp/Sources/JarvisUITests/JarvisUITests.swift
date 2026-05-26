import XCTest

final class JarvisUITests: XCTestCase {

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

    // MARK: – Helpers

    /// Wait for orb-home and navigate to chat via long press → Текст satellite
    private func navigateToChat() {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "orb-home not found — splash did not complete")

        let homeOrb = app.otherElements["home-orb"]
        XCTAssertTrue(homeOrb.waitForExistence(timeout: 3))
        homeOrb.press(forDuration: 0.5)

        let textBtn = app.buttons["Текст"]
        XCTAssertTrue(textBtn.waitForExistence(timeout: 2))
        textBtn.tap()

        let chatView = app.otherElements["chat-view"]
        XCTAssertTrue(chatView.waitForExistence(timeout: 5), "chat-view not found after tapping Текст")
    }

    /// Open input bar from empty state
    private func openInputBar() {
        let startText = app.buttons["empty-start-text"]
        XCTAssertTrue(startText.waitForExistence(timeout: 3))
        startText.tap()
    }

    // MARK: – Tests

    func testLaunch() throws {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "App did not reach home screen in time")
    }

    func testOrbTapOpensChat() throws {
        navigateToChat()
    }

    func testSendMessage() throws {
        navigateToChat()
        openInputBar()

        let messageInput = app.textFields["message-input"]
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3))
        messageInput.tap()
        messageInput.typeText("Привет")

        let sendBtn = app.buttons["send-btn"]
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 2))
        sendBtn.tap()

        let bubble = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bubble-user-'")
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "User message bubble not found after send")
    }

    func testDeliveryFlow() throws {
        navigateToChat()
        openInputBar()

        let messageInput = app.textFields["message-input"]
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3))
        messageInput.tap()
        messageInput.typeText("Test delivery")

        app.buttons["send-btn"].tap()

        let bubble = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bubble-user-'")
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))

        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(bubble.exists, "Bubble disappeared after delivery transition")
    }

    func testAssistantReply() throws {
        navigateToChat()
        openInputBar()

        let messageInput = app.textFields["message-input"]
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3))
        messageInput.tap()
        messageInput.typeText("Hello")

        app.buttons["send-btn"].tap()

        let assistantBubble = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'bubble-assistant-'")
        ).firstMatch
        XCTAssertTrue(assistantBubble.waitForExistence(timeout: 5), "Assistant reply bubble not found")
    }
}
