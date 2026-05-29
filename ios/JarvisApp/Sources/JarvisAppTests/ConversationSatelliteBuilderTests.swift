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

    func testPinnedConversationsAppearAsPinnedKind() {
        let p1 = conv(title: "P1", lastMessageAt: Date().addingTimeInterval(-100), pinned: true)
        let p2 = conv(title: "P2", lastMessageAt: Date().addingTimeInterval(-200), pinned: true)
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: nil,
            lastAssistantTimestamp: nil,
            allConversations: [p2, p1],
            now: Date()
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.kind), [.pinned, .pinned])
        XCTAssertEqual(result.map(\.title), ["P1", "P2"], "pinned satellites sorted by lastMessageAt desc")
    }

    func testPinnedCapAtTwo() {
        let p1 = conv(title: "P1", lastMessageAt: Date().addingTimeInterval(-100), pinned: true)
        let p2 = conv(title: "P2", lastMessageAt: Date().addingTimeInterval(-200), pinned: true)
        let p3 = conv(title: "P3", lastMessageAt: Date().addingTimeInterval(-300), pinned: true)
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: nil,
            lastAssistantTimestamp: nil,
            allConversations: [p1, p2, p3],
            now: Date()
        )
        XCTAssertEqual(result.count, 2, "only 2 pinned slots regardless of how many are pinned")
        XCTAssertEqual(result.map(\.title), ["P1", "P2"], "newest two pinned win")
    }

    func testActivePlusPinnedDedupesWhenActiveIsPinned() {
        let id = UUID()
        let active = conv(id, title: "Active", lastMessageAt: Date(), pinned: true)
        let p2 = conv(title: "P2", lastMessageAt: Date().addingTimeInterval(-200), pinned: true)
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: Date().addingTimeInterval(-3600),
            allConversations: [active, p2],
            now: Date()
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].kind, .active)
        XCTAssertEqual(result[0].id, id)
        XCTAssertEqual(result[1].kind, .pinned)
        XCTAssertEqual(result[1].title, "P2")
    }

    func testActivePlusTwoPinnedTotalsThree() {
        let id = UUID()
        let active = conv(id, title: "Active", lastMessageAt: Date())
        let p1 = conv(title: "P1", lastMessageAt: Date().addingTimeInterval(-100), pinned: true)
        let p2 = conv(title: "P2", lastMessageAt: Date().addingTimeInterval(-200), pinned: true)
        let result = ConversationSatelliteBuilder.build(
            activeConversationId: id,
            lastAssistantTimestamp: Date().addingTimeInterval(-3600),
            allConversations: [active, p1, p2],
            now: Date()
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.kind), [.active, .pinned, .pinned])
    }
}
