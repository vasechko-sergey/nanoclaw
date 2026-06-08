import XCTest
@testable import Jarvis

/// Pins the `ChatMessage.agentId` model contract that `ChatView` relies on
/// for per-agent filtering. Doesn't exercise the SwiftUI layer — that would
/// need a UI host. The filter rule itself
/// (`(msg.agentId ?? "jarvis") == activeSlug`) is asserted indirectly by
/// guaranteeing the field starts out `nil` and survives a round-trip set.
@MainActor
final class ChatViewAgentFilterTests: XCTestCase {
    func test_chatMessage_defaultsAgentIdToNil() {
        let msg = ChatMessage.text("m1", role: .user, text: "hi", timestamp: Date())
        XCTAssertNil(msg.agentId)
    }

    func test_chatMessage_agentIdRoundTrips() {
        var msg = ChatMessage.text("m2", role: .assistant, text: "hi", timestamp: Date())
        msg.agentId = "payne"
        XCTAssertEqual(msg.agentId, "payne")
    }
}
