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

    func test_windowedRows_equalTs_stableByInsertionOrder_andEditDoesNotReorder() throws {
        let store = try makeStore()
        // Two messages with the SAME ts (millisecond collision — e.g. a burst of
        // <message> blocks in one turn), inserted A then B.
        try store.writer.write { db in
            try db.execute(
                sql: "INSERT INTO messages (id,dir,seq,text,status,ts,created_at,agent_id,edited) VALUES (?,?,NULL,?,?,?,?,?,0)",
                arguments: ["m-a", "in", "A", "new", 1000, 1000, "jarvis"]
            )
            try db.execute(
                sql: "INSERT INTO messages (id,dir,seq,text,status,ts,created_at,agent_id,edited) VALUES (?,?,NULL,?,?,?,?,?,0)",
                arguments: ["m-b", "in", "B", "new", 1000, 1000, "jarvis"]
            )
        }
        let before = try store.writer.read { db in try ConversationStoreV2.windowedRows(db, perAgent: 500) }
        XCTAssertEqual(before.map(\.id), ["m-a", "m-b"], "equal-ts rows must order by insertion (rowid)")

        // Editing A in place must NOT reorder the timeline (the reported bug).
        _ = try store.updateMessageText(id: "m-a", text: "A-edited")
        let after = try store.writer.read { db in try ConversationStoreV2.windowedRows(db, perAgent: 500) }
        XCTAssertEqual(after.map(\.id), ["m-a", "m-b"], "edit must not reorder equal-ts rows")
        XCTAssertEqual(after.first { $0.id == "m-a" }?.text, "A-edited")
    }

    func test_windowedRows_ordersByServerTs_whenDeviceClockSkewed() throws {
        let store = try makeStore()
        // Reproduces the reported reorder: the phone clock runs ~2h ahead of the
        // VDS. The user's OUTBOUND question is stamped with device-now (skewed
        // far into the future) but the host ack gives it a correct `server_ts`.
        // The agent's INBOUND reply is stamped with the host clock (`ts`, no
        // server_ts). Sorting by raw `ts` puts the reply ABOVE the question
        // (2h earlier); sorting by COALESCE(server_ts, ts) — a single host clock —
        // restores question→reply order.
        try store.writer.write { db in
            // Outbound question: device ts +2h ahead (9_000_000), host ack 1000.
            try db.execute(
                sql: "INSERT INTO messages (id,dir,seq,text,status,ts,server_ts,created_at,agent_id,edited) VALUES (?,?,NULL,?,?,?,?,?,?,0)",
                arguments: ["q", "out", "Q", "sent", 9_000_000, 1000, 9_000_000, "scrooge"]
            )
            // Inbound reply: host ts 2000, no server_ts.
            try db.execute(
                sql: "INSERT INTO messages (id,dir,seq,text,status,ts,created_at,agent_id,edited) VALUES (?,?,NULL,?,?,?,?,?,0)",
                arguments: ["r", "in", "R", "new", 2000, 2000, "scrooge"]
            )
        }
        let rows = try store.writer.read { db in try ConversationStoreV2.windowedRows(db, perAgent: 500) }
        XCTAssertEqual(rows.map(\.id), ["q", "r"],
                       "acked outbound must sort by host server_ts, not skewed device ts")
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

    func test_insertInbound_persistsActions_andMarkAnswered() throws {
        let store = try makeStore()
        let actions = [V2.Action(id: "yes", label: "Yes", style: "primary"),
                       V2.Action(id: "no", label: "No", style: nil)]
        let message = V2.Message(thread_id: "t1", text: "Proceed?", actions: actions)
        let envelope = V2.Envelope(
            v: V2.protocolVersion,
            kind: .data,
            type: .message,
            id: "q1",
            seq: 3,
            ts: "2026-06-22T00:00:00Z",
            payload: .message(message)
        )

        try store.insertInbound(envelope: envelope, message: message)

        let row = try store.fetchById("q1")!
        let stored = try JSONDecoder().decode([StoredAction].self, from: Data(row.actionsJSON!.utf8))
        XCTAssertEqual(stored.map(\.id), ["yes", "no"])
        XCTAssertNil(row.actionChoice)

        try store.markActionAnswered(rowId: "q1", choice: "yes")
        XCTAssertEqual(try store.fetchById("q1")!.actionChoice, "yes")
    }

    func test_insertWorkoutPlan_persistsPlanJSON_idempotent_andMarkDone() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "День груди", week: 3, intensityLabel: "средняя",
            exercises: [
                ExercisePlan(exerciseSlug: "bench", targetSets: 4, targetReps: "8-10", targetRir: 2, restSec: 120, notes: nil),
                ExercisePlan(exerciseSlug: "fly", targetSets: 3, targetReps: "12-15", targetRir: 1, restSec: 90, notes: nil),
            ],
            imageManifest: [])

        try store.insertWorkoutPlan(id: plan.workoutId, agentId: "payne", plan: plan)
        let row = try store.fetchById("w1")!
        XCTAssertNotNil(row.workoutPlanJSON)
        XCTAssertEqual(row.agentId, "payne")
        XCTAssertNil(row.actionChoice)
        let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: Data(row.workoutPlanJSON!.utf8))
        XCTAssertEqual(decoded, plan)

        try store.insertWorkoutPlan(id: plan.workoutId, agentId: "payne", plan: plan)
        let count = try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages WHERE id=?", arguments: ["w1"]) }
        XCTAssertEqual(count, 1)

        try store.markActionAnswered(rowId: "w1", choice: "completed")
        XCTAssertEqual(try store.fetchById("w1")!.actionChoice, "completed")
    }

    func testUpdateMessageTextEditsInPlaceAndMarksEdited() throws {
        let store = try makeStore()

        let env = V2.Envelope(
            v: 2, kind: .data, type: .message,
            id: "msg-1", seq: 3, ts: "2026-06-23T12:00:00.000Z",
            payload: .message(V2.Message(thread_id: "default", text: "oops"))
        )
        try store.insertInbound(envelope: env, message: V2.Message(thread_id: "default", text: "oops"), agentId: "jarvis")

        let changed = try store.updateMessageText(id: "msg-1", text: "corrected")
        XCTAssertTrue(changed)

        let row = try store.fetchById("msg-1")
        XCTAssertEqual(row?.text, "corrected")
        XCTAssertTrue(row?.edited ?? false)

        let missing = try store.updateMessageText(id: "nope", text: "x")
        XCTAssertFalse(missing)
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
