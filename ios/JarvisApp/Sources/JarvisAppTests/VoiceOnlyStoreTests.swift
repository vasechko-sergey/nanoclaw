import XCTest
import GRDB
@testable import Jarvis

final class VoiceOnlyStoreTests: XCTestCase {
    private func makeStore() throws -> ConversationStoreV2 {
        let q = try DatabaseQueue()
        try Schema.migrate(q)
        return ConversationStoreV2(writer: q)
    }

    private func inboundEnvelope(id: String, text: String, voiceOnly: Bool) -> (V2.Envelope, V2.Message) {
        let msg = V2.Message(thread_id: "t", text: text, voice_only: voiceOnly)
        let env = V2.Envelope(
            v: V2.protocolVersion, kind: .data, type: .message,
            id: id, seq: 1,
            ts: ISO8601DateFormatter().string(from: Date()),
            payload: .message(msg)
        )
        return (env, msg)
    }

    func testInsertPersistsVoiceOnly() throws {
        let store = try makeStore()
        let (env, msg) = inboundEnvelope(id: "m1", text: "hi", voiceOnly: true)
        try store.insertInbound(envelope: env, message: msg, agentId: "jarvis")
        let rows = try store.writer.read { try ConversationStoreV2.windowedRows($0, perAgent: 10) }
        XCTAssertEqual(rows.first { $0.id == "m1" }?.voiceOnly, true)
    }

    func testClearVoiceOnlyRevealsText() throws {
        let store = try makeStore()
        let (env, msg) = inboundEnvelope(id: "m2", text: "hi", voiceOnly: true)
        try store.insertInbound(envelope: env, message: msg, agentId: "jarvis")
        let changed = try store.clearVoiceOnly(rowId: "m2")
        XCTAssertTrue(changed)
    }
}
