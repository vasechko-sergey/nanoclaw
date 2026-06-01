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
    //
    // SwiftUI's `.accessibilityIdentifier("chat-view")` on ChatView's root
    // propagates that identifier to every descendant — silently overwriting
    // any `accessibilityIdentifier(...)` set on child views (the
    // empty-state buttons, the input TextField, the send button, the drawer
    // search field). So queries like `app.buttons["empty-start-text"]` or
    // `app.textFields["message-input"]` return nothing. We work around it by
    // matching on labels (Russian button titles) and on placeholderValue
    // (the TextField prompt), which are preserved through the propagation.

    /// Wait for orb-home, then tap the test-only direct navigation button.
    private func navigateToChat() {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "orb-home not found — splash did not complete")

        let startChatBtn = app.buttons.matching(
            NSPredicate(format: "label == 'uitest-start-text-chat'")
        ).firstMatch
        XCTAssertTrue(startChatBtn.waitForExistence(timeout: 3), "uitest-start-text-chat button not found")
        startChatBtn.tap()

        // Wait for the ChatView input bar to render. Match by placeholderValue
        // since the chat-view parent identifier shadows explicit ones.
        // Note: the legacy empty-state "Текстом" pill was removed when
        // EmptyStateView was rebuilt to match OrbHomeView style — InputBar is
        // now always visible in the empty state.
        let messageInput = resolveMessageInput()
        XCTAssertTrue(
            messageInput.waitForExistence(timeout: 10),
            "ChatView message-input did not render within 10s after navigation"
        )
    }

    /// No-op: InputBar is always visible in the empty state now (EmptyStateView
    /// rebuilt to match OrbHomeView — no more "Текстом" pill to tap).
    /// Kept for call-site compatibility.
    private func openInputBar() {
        _ = resolveMessageInput().waitForExistence(timeout: 3)
    }

    /// Resolve the input TextField by placeholderValue ("Спросить Jarvis...").
    /// The `chat-view` parent identifier overrides the explicit
    /// `message-input` identifier on the TextField, but SwiftUI's
    /// `TextField("Спросить Jarvis...", ...)` prompt is preserved as
    /// `placeholderValue` and uniquely identifies the input bar.
    private func resolveMessageInput() -> XCUIElement {
        return app.textFields.matching(
            NSPredicate(format: "placeholderValue == 'Спросить Jarvis...'")
        ).firstMatch
    }

    /// Resolve the send button by label. When text is in the field,
    /// VoiceButton's accessibility label is "Отправить".
    private func resolveSendButton() -> XCUIElement {
        return app.buttons.matching(
            NSPredicate(format: "label == 'Отправить'")
        ).firstMatch
    }

    // MARK: – Tests

    func testLaunch() throws {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "App did not reach home screen in time")
    }

    func testOrbTapOpensChat() throws {
        navigateToChat()
    }

    /// Set the TextField's text via `XCUIElement.typeText`. The SwiftUI
    /// `TextField(..., axis: .vertical)` in UnifiedInputBar renders as a
    /// UITextView internally; in the simulator, tap+typeText is unreliable
    /// because the inner UITextView doesn't always become first responder
    /// for XCUITest's `hasKeyboardFocus` check. Use `XCUIElement.typeText`
    /// which sets the value directly via the AX setValue path when supported,
    /// falling back to focus + type.
    private func tapAndType(_ field: XCUIElement, _ text: String) {
        // Try coordinate-based tap to raise the underlying UITextView.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        Thread.sleep(forTimeInterval: 0.3)
        // Route to app-level typeText (goes to whatever has focus).
        if app.keyboards.firstMatch.exists {
            app.typeText(text)
        } else {
            // Fallback: direct AX-value injection. XCUITest's UITextField
            // implementation handles this even without first-responder.
            field.typeText(text)
        }
    }

    func testSendMessage() throws {
        navigateToChat()
        openInputBar()

        let messageInput = resolveMessageInput()
        XCTAssertTrue(messageInput.waitForExistence(timeout: 5), "Message input text field not found")
        tapAndType(messageInput, "Привет")

        let sendBtn = resolveSendButton()
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 3), "Send button not found")
        sendBtn.tap()

        let bubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'row-user-'")
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "User message bubble not found after send")
    }

    func testDeliveryFlow() throws {
        navigateToChat()
        openInputBar()

        let messageInput = resolveMessageInput()
        XCTAssertTrue(messageInput.waitForExistence(timeout: 5), "Message input text field not found")
        tapAndType(messageInput, "Test delivery")

        let sendBtn = resolveSendButton()
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 3), "Send button not found")
        sendBtn.tap()

        let bubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'row-user-'")
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))

        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(bubble.exists, "Bubble disappeared after delivery transition")
    }

    func testAssistantReply() throws {
        // Assistant replies arrive over the WebSocket transport from a live
        // NanoClaw host. In the UI-testing environment WSv2 points at
        // ws://127.0.0.1:8765 (WebSocketClientV2.resolveWebSocketURL) where no
        // server is listening, so no assistant message is ever delivered.
        // Enable this test only when an e2e harness is running.
        throw XCTSkip("requires running e2e-harness (mock WS server at 127.0.0.1:8765)")
    }
}
