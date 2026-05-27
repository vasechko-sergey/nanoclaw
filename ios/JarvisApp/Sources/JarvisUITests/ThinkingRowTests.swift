import XCTest

final class ThinkingRowTests: XCTestCase {
    func testThinkingRowVisibleAfterSend() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "1"]
        app.launch()

        let textStart = app.descendants(matching: .any)
            .matching(identifier: "empty-start-text").firstMatch
        if textStart.waitForExistence(timeout: 5) { textStart.tap() }

        let input = app.textFields["message-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Привет\n")

        let thinking = app.descendants(matching: .any)
            .matching(identifier: "thinking-row").firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 5), "thinking-row didn't appear after send")
    }

    func testThinkingRowDisappearsAfterReply() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "1"]
        app.launch()

        let textStart = app.descendants(matching: .any)
            .matching(identifier: "empty-start-text").firstMatch
        if textStart.waitForExistence(timeout: 5) { textStart.tap() }

        let input = app.textFields["message-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Привет\n")

        let assistantRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row-assistant-'"))
            .firstMatch
        XCTAssertTrue(assistantRow.waitForExistence(timeout: 10),
                      "assistant reply didn't arrive — check WS test harness")

        let thinking = app.descendants(matching: .any)
            .matching(identifier: "thinking-row").firstMatch
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: thinking)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 2), .completed,
                       "thinking-row didn't disappear after assistant reply")
    }
}
