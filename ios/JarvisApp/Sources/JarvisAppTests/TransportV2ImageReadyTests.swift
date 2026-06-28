import XCTest
import GRDB
@testable import Jarvis

/// `image_ready` must route exactly like the other workout-family envelopes:
/// forwarded to `onWorkoutEnvelope` (where AppCoordinator kicks the HTTP fetch)
/// and acked by id (it's exempt from the host's chat-cursor `ackUpTo`, so the
/// per-id `delivered` is the only thing that drops it from the host queue).
final class TransportV2ImageReadyTests: XCTestCase {
    var store: ConversationStoreV2!
    var transport: TransportV2!
    var socket: MockWebSocket!
    var dbq: DatabaseQueue!

    override func setUp() async throws {
        dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        store = ConversationStoreV2(writer: dbq)
        socket = MockWebSocket()
        transport = TransportV2(store: store, socket: socket, token: "tok")
    }

    private func imageReadyData() -> Data {
        Data("""
        {"v":2,"kind":"control","type":"image_ready","id":"img-1","seq":9,\
        "ts":"2026-06-28T00:00:00.000Z","payload":{"slug":"ex","sha256":"abc","agent_id":"payne"}}
        """.utf8)
    }

    func test_handleIncoming_imageReady_firesWorkoutEnvelope() async throws {
        let capture = WorkoutCapture()
        await transport.setOnWorkoutEnvelope { env in capture.store(env) }

        try await transport.handleIncoming(imageReadyData())

        let env = try XCTUnwrap(capture.value, "image_ready must reach onWorkoutEnvelope")
        XCTAssertEqual(env.type, .imageReady)
        guard case let .imageReady(p) = env.payload else {
            return XCTFail("expected .imageReady payload, got \(env.payload)")
        }
        XCTAssertEqual(p.slug, "ex")
        XCTAssertEqual(p.sha256, "abc")
    }

    func test_handleIncoming_imageReady_sendsDeliveredAckById() async throws {
        await transport.setOnWorkoutEnvelope { _ in }

        try await transport.handleIncoming(imageReadyData())

        let delivered = socket.sent
            .compactMap { try? JSONDecoder().decode(V2.Envelope.self, from: $0) }
            .first { $0.type == .delivered }
        let env = try XCTUnwrap(delivered, "image_ready must be acked by id so the host drops it")
        guard case let .statusBatch(s) = env.payload else {
            return XCTFail("expected statusBatch payload, got \(env.payload)")
        }
        XCTAssertEqual(s.ids, ["img-1"])
    }
}
