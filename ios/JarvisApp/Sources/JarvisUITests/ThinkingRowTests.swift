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

    /// Navigate from splash → home → chat with input bar focused.
    private func navigateToChatAndFocusInput() {
        let orbHome = app.otherElements["orb-home"]
        XCTAssertTrue(orbHome.waitForExistence(timeout: 8), "orb-home not found")

        let startChatBtn = app.buttons.matching(
            NSPredicate(format: "label == 'uitest-start-text-chat'")
        ).firstMatch
        XCTAssertTrue(startChatBtn.waitForExistence(timeout: 3))
        startChatBtn.tap()

        let chatView = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'chat-view'")
        ).firstMatch
        XCTAssertTrue(chatView.waitForExistence(timeout: 5))

        // If empty state shows the "Текстом" pill, tap it to open input bar
        let startText = app.buttons.matching(
            NSPredicate(format: "identifier == 'empty-start-text'")
        ).firstMatch
        if startText.waitForExistence(timeout: 2) { startText.tap() }
    }

    func testThinkingRowVisibleAfterSend() {
        navigateToChatAndFocusInput()

        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Message input not found")
        input.tap()
        input.typeText("Привет")

        let sendBtn = app.buttons.matching(
            NSPredicate(format: "label == 'Отправить'")
        ).firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 2), "Send button not found")
        sendBtn.tap()

        let thinking = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Jarvis обрабатывает запрос'")
        ).firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 5), "thinking-row didn't appear after send")
    }

    func testThinkingRowDisappearsAfterReply() {
        navigateToChatAndFocusInput()

        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Привет")

        let sendBtn = app.buttons.matching(
            NSPredicate(format: "label == 'Отправить'")
        ).firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 2))
        sendBtn.tap()

        let assistantRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row-assistant-'"))
            .firstMatch
        XCTAssertTrue(assistantRow.waitForExistence(timeout: 10),
                      "assistant reply didn't arrive — mock WS server not running?")

        let thinking = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Jarvis обрабатывает запрос'")
        ).firstMatch
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: thinking)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 3), .completed,
                       "thinking-row didn't disappear after assistant reply")
    }
}
