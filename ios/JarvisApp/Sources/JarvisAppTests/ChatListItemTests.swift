import XCTest
import CoreGraphics
@testable import Jarvis

final class ChatListItemTests: XCTestCase {

    private func msg(_ id: String, _ ts: Date) -> ChatMessage {
        ChatMessage.text(id, role: .user, text: id, timestamp: ts)
    }

    func test_buildChatItems_dateSeparatorsAndThinking() {
        let cal = Calendar.current
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)        // some day
        let day2 = day1.addingTimeInterval(26 * 3600)                // next calendar day
        let items = buildChatItems(
            [msg("a", day1), msg("b", day1.addingTimeInterval(60)), msg("c", day2)],
            isBusy: true
        )
        XCTAssertEqual(items, [
            .date(cal.startOfDay(for: day1)),
            .message("a"),
            .message("b"),
            .date(cal.startOfDay(for: day2)),
            .message("c"),
            .thinking,
        ])
    }

    func test_buildChatItems_singleMessage_noSeparator_noThinkingWhenIdle() {
        let items = buildChatItems([msg("a", Date(timeIntervalSince1970: 1_700_000_000))], isBusy: false)
        XCTAssertEqual(items, [.message("a")])  // count==1 → no leading separator (matches old rule)
    }

    func test_isNearBottom() {
        XCTAssertTrue(isNearBottom(offsetY: 900, contentHeight: 1000, boundsHeight: 100, bottomInset: 0, threshold: 160))
        XCTAssertFalse(isNearBottom(offsetY: 100, contentHeight: 1000, boundsHeight: 100, bottomInset: 0, threshold: 160))
        XCTAssertTrue(isNearBottom(offsetY: 0, contentHeight: 50, boundsHeight: 100, bottomInset: 0, threshold: 160))
    }
}
