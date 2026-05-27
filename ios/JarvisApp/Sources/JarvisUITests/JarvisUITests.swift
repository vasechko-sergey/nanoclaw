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

    /// Wait for orb-home, then tap the test-only direct navigation button.
    /// The satellite animation approach is not used: SwiftUI accessibility positions
    /// are snapshotted mid-animation which causes taps to land at the wrong coordinate.
    /// uitest-start-text-chat is a static button at the bottom-leading corner of
    /// OrbHomeView, outside the satellite orbit radius, that directly calls onStartChat.
    private func navigateToChat() {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "orb-home not found — splash did not complete")

        let startChatBtn = app.buttons.matching(
            NSPredicate(format: "label == 'uitest-start-text-chat'")
        ).firstMatch
        XCTAssertTrue(startChatBtn.waitForExistence(timeout: 3), "uitest-start-text-chat button not found")
        startChatBtn.tap()

        // ChatView's VStack does not appear as its own Other element in the accessibility tree
        // (it only propagates identifier 'chat-view' to children). Search across all types.
        let chatView = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'chat-view'")
        ).firstMatch
        XCTAssertTrue(chatView.waitForExistence(timeout: 5), "chat-view not found after tapping uitest-start-text-chat")
    }

    /// Open input bar from empty state.
    private func openInputBar() {
        // If a text field is already visible (cached messages loaded), input bar is already open
        let textField = app.textFields.firstMatch
        if textField.waitForExistence(timeout: 1) { return }
        // Empty state — tap keyboard hint to show input bar
        let startText = app.buttons.matching(
            NSPredicate(format: "identifier == 'empty-start-text'")
        ).firstMatch
        XCTAssertTrue(startText.waitForExistence(timeout: 3), "'empty-start-text' button not found in empty state")
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

        // UnifiedInputBar uses a single text field — no identifier set, firstMatch is reliable
        let messageInput = app.textFields.firstMatch
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3), "Message input text field not found")
        messageInput.tap()
        messageInput.typeText("Привет")

        // VoiceButton label changes to "Отправить" when text is present
        let sendBtn = app.buttons.matching(
            NSPredicate(format: "label == 'Отправить'")
        ).firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 2), "Send button not found")
        sendBtn.tap()

        let bubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'row-user-'")
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "User message bubble not found after send")
    }

    func testDeliveryFlow() throws {
        navigateToChat()
        openInputBar()

        let messageInput = app.textFields.firstMatch
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3), "Message input text field not found")
        messageInput.tap()
        messageInput.typeText("Test delivery")

        let sendBtn = app.buttons.matching(
            NSPredicate(format: "label == 'Отправить'")
        ).firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 2), "Send button not found")
        sendBtn.tap()

        let bubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'row-user-'")
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))

        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(bubble.exists, "Bubble disappeared after delivery transition")
    }

    func testAssistantReply() throws {
        navigateToChat()
        openInputBar()

        let messageInput = app.textFields.firstMatch
        XCTAssertTrue(messageInput.waitForExistence(timeout: 3), "Message input text field not found")
        messageInput.tap()
        messageInput.typeText("Hello")

        let sendBtn = app.buttons.matching(
            NSPredicate(format: "label == 'Отправить'")
        ).firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 2), "Send button not found")
        sendBtn.tap()

        let assistantBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'row-assistant-'")
        ).firstMatch
        XCTAssertTrue(assistantBubble.waitForExistence(timeout: 5), "Assistant reply bubble not found")
    }
}
