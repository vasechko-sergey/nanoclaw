import XCTest
@testable import Jarvis

final class ConversationSatelliteBuilderTests: XCTestCase {

    private func conv(_ id: UUID = UUID(), title: String = "x",
                      lastMessageAt: Date = Date(),
                      pinned: Bool = false) -> Conversation {
        var c = Conversation(id: id, title: title)
        c.lastMessageAt = lastMessageAt
        c.isPinned = pinned
        return c
    }

    func testEmptyInputsProduceEmptyResult() {
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: nil,
            lastAssistantTimestamp: nil,
            allConversations: [],
            now: Date()
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testActiveWithFreshAssistantWithin24hAppearsAsActive() {
        let id = UUID()
        let active = conv(id, title: "Test", lastMessageAt: Date())
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: Date().addingTimeInterval(-3600),
            allConversations: [active],
            now: Date()
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, id)
        XCTAssertEqual(result.first?.kind, .active)
        XCTAssertEqual(result.first?.title, "Test")
    }

    func testActiveOlderThan24hIsExcluded() {
        let id = UUID()
        let active = conv(id, title: "Old", lastMessageAt: Date())
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: Date().addingTimeInterval(-25 * 3600),
            allConversations: [active],
            now: Date()
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testActiveWithoutLastAssistantIsExcluded() {
        let id = UUID()
        let active = conv(id, title: "NoReply", lastMessageAt: Date())
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: nil,
            allConversations: [active],
            now: Date()
        )
        XCTAssertTrue(result.isEmpty)
    }
}
