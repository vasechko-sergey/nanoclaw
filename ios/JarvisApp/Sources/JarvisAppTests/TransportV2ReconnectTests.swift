import XCTest
import GRDB
@testable import Jarvis

/// Tests for TransportV2 reconnect-guard behaviour. Reuses the same
/// MockWebSocket + harness from TransportV2Tests.swift.
final class TransportV2ReconnectTests: XCTestCase {

    // MARK: - Helpers

    struct TransportHarness {
        let transport: TransportV2
        let socket: MockWebSocket
        let store: ConversationStoreV2
    }

    func makeTransport() throws -> TransportHarness {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        let socket = MockWebSocket()
        let transport = TransportV2(
            store: store, socket: socket, token: "tok",
            ackTimeoutSeconds: 0.2, dispatcherIntervalMs: 50
        )
        return TransportHarness(transport: transport, socket: socket, store: store)
    }

    // MARK: - Task 1: intentional disconnect must not re-arm reconnect

    func testIntentionalDisconnectDoesNotReconnect() async throws {
        let h = try makeTransport()
        // Connect so onClose is wired (state becomes .connecting).
        try await h.transport.connect()
        // Intentional disconnect: sets state = .idle + calls socket.close().
        await h.transport.disconnect()
        // Simulate the close that socket.close() triggers (via task cancellation
        // or URLSession delegate). Before the fix, this re-armed a reconnect.
        h.socket.onClose?(nil)
        // Give any spurious Task a moment to propagate.
        try await Task.sleep(nanoseconds: 200_000_000)
        let s = await h.transport.state
        XCTAssertEqual(s, .idle,
            "intentional disconnect must stay .idle — onClose must not re-arm reconnect")
    }
}
