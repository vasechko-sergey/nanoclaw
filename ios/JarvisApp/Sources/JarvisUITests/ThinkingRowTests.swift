import XCTest

final class ThinkingRowTests: XCTestCase {

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
    // See JarvisUITests.swift for the rationale: `accessibilityIdentifier`
    // propagation from ChatView's root ("chat-view") overwrites child
    // identifiers, so we match by label / placeholderValue.

    private func emptyStartTextButton() -> XCUIElement {
        return app.buttons.matching(
            NSPredicate(format: "label == 'Текстом'")
        ).firstMatch
    }

    private func resolveMessageInput() -> XCUIElement {
        return app.textFields.matching(
            NSPredicate(format: "placeholderValue == 'Спросить Jarvis...'")
        ).firstMatch
    }

    private func resolveSendButton() -> XCUIElement {
        return app.buttons.matching(
            NSPredicate(format: "label == 'Отправить'")
        ).firstMatch
    }

    /// Navigate from splash → home → chat with input bar focused.
    private func navigateToChatAndFocusInput() {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "orb-home not found")

        let startChatBtn = app.buttons.matching(
            NSPredicate(format: "label == 'uitest-start-text-chat'")
        ).firstMatch
        XCTAssertTrue(startChatBtn.waitForExistence(timeout: 3))
        startChatBtn.tap()

        // Wait for either the empty-state pill or the input bar.
        let startText = emptyStartTextButton()
        let messageInput = resolveMessageInput()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if startText.exists || messageInput.exists { break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // If empty state shows the "Текстом" pill, tap it to open input bar.
        if !messageInput.exists && startText.exists {
            startText.tap()
        }
    }

    /// See JarvisUITests.tapAndType — vertical SwiftUI TextFields don't
    /// always route XCUITest `tap()` to first responder. Use coordinate tap
    /// + app-level typeText (routes to focused responder).
    private func tapAndType(_ field: XCUIElement, _ text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        Thread.sleep(forTimeInterval: 0.3)
        if app.keyboards.firstMatch.exists {
            app.typeText(text)
        } else {
            field.typeText(text)
        }
    }

    func testThinkingRowVisibleAfterSend() throws {
        navigateToChatAndFocusInput()

        let input = resolveMessageInput()
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Message input not found")
        tapAndType(input, "Привет")

        let sendBtn = resolveSendButton()
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 3), "Send button not found")
        sendBtn.tap()

        // The ThinkingRow's `.accessibilityLabel("Jarvis обрабатывает запрос")`
        // is set on the row but `chat-view` identifier propagation still wins,
        // so we match by label.
        let thinking = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Jarvis обрабатывает запрос'")
        ).firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 10), "thinking-row didn't appear after send")
    }

    func testThinkingRowDisappearsAfterReply() throws {
        // Assistant replies arrive over WSv2 from a live NanoClaw host. In the
        // UI-test environment the socket points at ws://127.0.0.1:8765 with no
        // server listening, so the "disappears after reply" half is
        // unreachable. Enable this when an e2e mock-WS harness is running.
        throw XCTSkip("requires running e2e-harness (mock WS server at 127.0.0.1:8765)")
    }
}
