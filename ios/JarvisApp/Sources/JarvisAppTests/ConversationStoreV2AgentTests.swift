import XCTest
import GRDB
@testable import Jarvis

final class ConversationStoreV2AgentTests: XCTestCase {

    private func makeStore() throws -> ConversationStoreV2 {
        let queue = try DatabaseQueue() // in-memory
        try Schema.migrate(queue)
        return ConversationStoreV2(writer: queue)
    }

    func test_insertedMessage_isolatedByAgentId() throws {
        let store = try makeStore()

        try store.insertOutboundUserMessage(
            id: "msg-jarvis-1",
            text: "hi jarvis",
            attachments: [],
            context: nil,
            agentId: "jarvis"
        )
        try store.insertOutboundUserMessage(
            id: "msg-payne-1",
            text: "hi payne",
            attachments: [],
            context: nil,
            agentId: "payne"
        )
        try store.insertOutboundUserMessage(
            id: "msg-payne-2",
            text: "second hi payne",
            attachments: [],
            context: nil,
            agentId: "payne"
        )

        // Queued outbound for each agent matches what we inserted.
        let jarvisQueue = try store.queuedOutbound(agentId: "jarvis", limit: 10)
        let payneQueue  = try store.queuedOutbound(agentId: "payne", limit: 10)

        XCTAssertEqual(jarvisQueue.map(\.id), ["msg-jarvis-1"])
        XCTAssertEqual(Set(payneQueue.map(\.id)), Set(["msg-payne-1", "msg-payne-2"]))

        // agent_id round-trips through StoredMessage.
        XCTAssertEqual(jarvisQueue.first?.agentId, "jarvis")
        XCTAssertTrue(payneQueue.allSatisfy { $0.agentId == "payne" })

        // Per-agent count helper.
        XCTAssertEqual(try store.countMessages(agentId: "jarvis"), 1)
        XCTAssertEqual(try store.countMessages(agentId: "payne"), 2)
    }

    func test_defaultAgentId_isJarvis_forBackCompat() throws {
        let store = try makeStore()

        // Call without explicit agentId — should land in the 'jarvis' bucket.
        try store.insertOutboundUserMessage(
            id: "msg-default-1",
            text: "no agent specified",
            attachments: [],
            context: nil
        )

        let jarvisQueue = try store.queuedOutbound(limit: 10)
        XCTAssertEqual(jarvisQueue.map(\.id), ["msg-default-1"])
        XCTAssertEqual(jarvisQueue.first?.agentId, "jarvis")

        let payneQueue = try store.queuedOutbound(agentId: "payne", limit: 10)
        XCTAssertTrue(payneQueue.isEmpty)
    }

    func test_prune_isPerAgent_doesNotEvictOtherAgentsMessages() throws {
        let store = try makeStore()
        // Chatty jarvis (5) + quiet payne (2).
        for i in 0..<5 {
            try store.insertOutboundUserMessage(
                id: "j-\(i)", text: "j\(i)", attachments: [], context: nil, agentId: "jarvis"
            )
        }
        for i in 0..<2 {
            try store.insertOutboundUserMessage(
                id: "p-\(i)", text: "p\(i)", attachments: [], context: nil, agentId: "payne"
            )
        }
        // Per-agent prune keep=3: jarvis trimmed to its 3 newest; payne (2 ≤ 3)
        // is untouched — a chatty agent must NOT evict a quiet agent's history.
        try store.prune(keep: 3)
        XCTAssertEqual(try store.countMessages(agentId: "jarvis"), 3, "chatty agent trimmed to keep")
        XCTAssertEqual(try store.countMessages(agentId: "payne"), 2, "quiet agent NOT evicted")
    }

    func test_windowedRows_isPerAgent_keepsQuietAgentInWindow() throws {
        let queue = try DatabaseQueue() // in-memory
        try Schema.migrate(queue)
        let store = ConversationStoreV2(writer: queue)
        // Chatty jarvis (10) + quiet payne (1). A GLOBAL newest-N window with a
        // small N would drop payne entirely (the blank-chat bug); the per-agent
        // window must keep payne present.
        for i in 0..<10 {
            try store.insertOutboundUserMessage(
                id: "j-\(i)", text: "j\(i)", attachments: [], context: nil, agentId: "jarvis"
            )
        }
        try store.insertOutboundUserMessage(
            id: "p-0", text: "p0", attachments: [], context: nil, agentId: "payne"
        )

        let windowed = try queue.read { db in
            try ConversationStoreV2.windowedRows(db, perAgent: 3)
        }
        XCTAssertEqual(windowed.filter { $0.agentId == "jarvis" }.count, 3,
                       "chatty agent windowed to its newest `perAgent`")
        XCTAssertEqual(windowed.filter { $0.agentId == "payne" }.count, 1,
                       "quiet agent present in the window (not starved)")
        XCTAssertEqual(windowed.map(\.ts), windowed.map(\.ts).sorted(),
                       "rows returned oldest-first by ts")
    }

    func test_queuedOutbound_nilAgentId_returnsAllAgents() throws {
        let store = try makeStore()
        try store.insertOutboundUserMessage(
            id: "j-1", text: "j", attachments: [], context: nil, agentId: "jarvis"
        )
        try store.insertOutboundUserMessage(
            id: "p-1", text: "p", attachments: [], context: nil, agentId: "payne"
        )
        try store.insertOutboundUserMessage(
            id: "g-1", text: "g", attachments: [], context: nil, agentId: "greg"
        )
        let all = try store.queuedOutbound(limit: 100)
        XCTAssertEqual(Set(all.map(\.id)), Set(["j-1", "p-1", "g-1"]))
    }

    func test_v4Migration_addsAgentIdColumn_andIndex() throws {
        let queue = try DatabaseQueue()
        try Schema.migrate(queue)

        try queue.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(messages)")
                .map { $0["name"] as String }
            XCTAssertTrue(cols.contains("agent_id"), "messages must have agent_id column")

            let idxExists = try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_msg_agent_ts')")!
            XCTAssertTrue(idxExists, "idx_msg_agent_ts index missing")
        }
    }
}
