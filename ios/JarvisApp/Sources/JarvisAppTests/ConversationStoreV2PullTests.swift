import XCTest
import GRDB
@testable import Jarvis

/// Pull-path text-stub insert + WS upsert-upgrade (build 77, Task 6).
final class ConversationStoreV2PullTests: XCTestCase {
    private func makeStore() throws -> ConversationStoreV2 {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return ConversationStoreV2(writer: dbq)
    }

    /// Read one column of a row by id (test seam via the internal `writer`).
    private func col(_ store: ConversationStoreV2, _ id: String, _ name: String) throws -> String? {
        try store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT \(name) FROM messages WHERE id = ?", arguments: [id])
        }
    }

    private func wsMessage(id: String, text: String, attachments: [V2.Attachment]? = nil) -> (V2.Envelope, V2.Message) {
        let m = V2.Message(thread_id: "t", text: text, attachments: attachments, agent_id: "jarvis")
        let e = V2.Envelope(v: 2, kind: .data, type: .message, id: id, seq: 5,
                            ts: "2026-06-30T00:00:01.000Z", payload: .message(m))
        return (e, m)
    }

    func testInsertInboundFromPullIsIdempotent() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "m1", seq: 10, text: "hi", agentId: "jarvis", ts: 1000)
        try store.insertInboundFromPull(id: "m1", seq: 10, text: "hi", agentId: "jarvis", ts: 1000)
        XCTAssertEqual(try store.countAllMessages(), 1) // no duplicate
    }

    func testWSUpsertUpgradesPullStub() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "m1", seq: 5, text: "caption", agentId: "jarvis", ts: 1000)
        XCTAssertNil(try col(store, "m1", "attachments_json")) // stub: text only

        let att = V2.Attachment(id: "a1", kind: "image", name: "p.jpg", mime_type: "image/jpeg",
                                byte_size: 10, bytes_base64: "AAAA", remote_id: nil)
        let (e, m) = wsMessage(id: "m1", text: "caption", attachments: [att])
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")

        XCTAssertEqual(try store.countAllMessages(), 1)              // still one row
        XCTAssertNotNil(try col(store, "m1", "attachments_json"))    // upgraded with attachment
    }

    func testWSUpsertPreservesReadStatus() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "m2", seq: 6, text: "hi", agentId: "jarvis", ts: 1000)
        try store.markRead(ids: ["m2"])
        let (e, m) = wsMessage(id: "m2", text: "hi")
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")
        XCTAssertEqual(try col(store, "m2", "status"), "read")       // NOT reset to 'new'
    }

    func testWSUpsertSkipsEditedRow() throws {
        let store = try makeStore()
        try store.insertInboundFromPull(id: "m3", seq: 7, text: "orig", agentId: "jarvis", ts: 1000)
        _ = try store.updateMessageText(id: "m3", text: "corrected") // edited = 1
        let (e, m) = wsMessage(id: "m3", text: "orig")
        try store.insertInbound(envelope: e, message: m, agentId: "jarvis")
        XCTAssertEqual(try col(store, "m3", "text"), "corrected")    // edit NOT reverted
    }

    // MARK: - Fix J: coach without set_ref injected as chat row

    /// Runner is closed → a `.coachMessage(text: _, workoutId: _, setRef: nil)`
    /// event on the workoutBus must land as a normal Payne chat message so the
    /// user still sees abort acks / global hints. The `coach:*` row id pattern
    /// scopes on workoutId + ts so two coach texts don't collide but a redelivery
    /// of the same text is idempotent.
    @MainActor
    func testCoachRowIdIsDeterministicForSameTs() {
        let idA = AppCoordinator.coachRowId(workoutId: "w1", tsMillis: 1000)
        let idB = AppCoordinator.coachRowId(workoutId: "w1", tsMillis: 1000)
        XCTAssertEqual(idA, idB, "same (workoutId, ts) → same id so redeliveries dedup")
        XCTAssertEqual(idA, "coach:w1:1000")
    }

    @MainActor
    func testCoachRowIdBackToBackTextsGetDistinctIds() {
        let idA = AppCoordinator.coachRowId(workoutId: "w1", tsMillis: 1000)
        let idB = AppCoordinator.coachRowId(workoutId: "w1", tsMillis: 1001)
        XCTAssertNotEqual(idA, idB, "different ts → different rows so both coach texts survive")
    }

    /// End-to-end: a coach text inserted via the same code path
    /// `injectInboundCoachMessage` uses shows up as a Payne row that the chat
    /// timeline would surface. Reproduces the "runner closed → banner missing
    /// → still visible in chat" contract from Fix J.
    @MainActor
    func testCoachTextInsertedForClosedRunnerLandsAsPayneRow() throws {
        let store = try makeStore()
        let id = AppCoordinator.coachRowId(workoutId: "w1", tsMillis: 5000)
        try store.insertInboundFromPull(id: id, seq: nil, text: "Принял, останавливаю тренировку.", agentId: "payne", ts: 5000)

        let text = try col(store, id, "text")
        XCTAssertEqual(text, "Принял, останавливаю тренировку.")
        let agent = try col(store, id, "agent_id")
        XCTAssertEqual(agent, "payne")
    }

    // MARK: - Fix M: workout summary placeholder

    @MainActor
    func testSummaryPlaceholderRowIdIsDeterministic() {
        let a = AppCoordinator.summaryPlaceholderRowId(workoutId: "2026-07-08")
        let b = AppCoordinator.summaryPlaceholderRowId(workoutId: "2026-07-08")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "workout-summary-placeholder-2026-07-08")
    }

    /// Fix M end-to-end at the store layer: the placeholder is inserted,
    /// its text can evolve without acquiring the `edited` tag, and it can
    /// be deleted once Payne's real summary lands.
    @MainActor
    func testSummaryPlaceholderLifecycle() throws {
        let store = try makeStore()
        let id = AppCoordinator.summaryPlaceholderRowId(workoutId: "w1")

        try store.insertInboundFromPull(id: id, seq: nil, text: "Разбираем тренировку…", agentId: "payne", ts: 1000)
        XCTAssertEqual(try col(store, id, "text"), "Разбираем тренировку…")

        _ = try store.updatePlaceholderText(id: id, text: "Пейн задерживается — проверь чуть позже.")
        XCTAssertEqual(try col(store, id, "text"), "Пейн задерживается — проверь чуть позже.")
        // `edited` stays 0 — placeholder mutations are not user-visible corrections.
        let edited = try store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT edited FROM messages WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(edited, 0)

        _ = try store.deleteMessage(id: id)
        XCTAssertNil(try col(store, id, "text"))
    }
}
