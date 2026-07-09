import XCTest
@testable import Jarvis

final class VisibleMessageCacheTests: XCTestCase {
    private func msg(_ id: String, agent: String?, role: ChatMessage.Role = .assistant) -> ChatMessage {
        var m = ChatMessage.text(id, role: role, text: "t", timestamp: Date())
        m.agentId = agent
        return m
    }

    func test_recompute_filtersToActiveAgent() {
        var cache = VisibleMessageCache()
        let all = [msg("a", agent: "jarvis"), msg("b", agent: "payne"), msg("c", agent: "jarvis")]
        cache.recompute(from: all, agent: .jarvis)
        XCTAssertEqual(cache.messages.map(\.id), ["a", "c"])
    }

    func test_recompute_nilAgentTreatedAsJarvis() {
        var cache = VisibleMessageCache()
        cache.recompute(from: [msg("a", agent: nil)], agent: .jarvis)
        XCTAssertEqual(cache.messages.map(\.id), ["a"])
    }

    func test_recompute_excludesSystemRole() {
        var cache = VisibleMessageCache()
        let all = [msg("a", agent: "jarvis"), msg("s", agent: "jarvis", role: .system)]
        cache.recompute(from: all, agent: .jarvis)
        XCTAssertEqual(cache.messages.map(\.id), ["a"])
    }

    func test_version_bumpsOnEveryRecompute() {
        var cache = VisibleMessageCache()
        XCTAssertEqual(cache.version, 0)
        cache.recompute(from: [], agent: .jarvis)
        XCTAssertEqual(cache.version, 1)
        cache.recompute(from: [], agent: .jarvis)
        XCTAssertEqual(cache.version, 2)
    }

    /// The regression guard: switching agents must both swap the messages AND
    /// bump the version, so `MessageListView`'s change-token moves even though
    /// `ws.messagesVersion` would not on a pure switch. Without the version bump,
    /// the fast-path early-return drops the new agent's messages and the chat
    /// stays one switch behind.
    func test_agentSwitch_swapsMessagesAndBumpsVersion() {
        var cache = VisibleMessageCache()
        let all = [msg("j", agent: "jarvis"), msg("p", agent: "payne")]
        cache.recompute(from: all, agent: .jarvis)
        let vAfterJarvis = cache.version
        XCTAssertEqual(cache.messages.map(\.id), ["j"])

        cache.recompute(from: all, agent: .payne)
        XCTAssertEqual(cache.messages.map(\.id), ["p"])
        XCTAssertGreaterThan(cache.version, vAfterJarvis)
    }
}
