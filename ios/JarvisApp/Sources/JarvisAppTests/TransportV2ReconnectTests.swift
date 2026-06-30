import XCTest
import GRDB
@testable import Jarvis

/// Variant of MockWebSocket that throws on connect(). Used for Task 2 tests.
final class FailingMockWebSocket: WebSocketLike, @unchecked Sendable {
    struct ConnectError: Error {}
    var sent: [Data] = []
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    func connect() async throws { throw ConnectError() }
    func send(_ data: Data) async throws { sent.append(data) }
    func close() {}
}

/// Variant that connects OK but never delivers auth_ok. Used for watchdog test.
final class NoAuthMockWebSocket: WebSocketLike, @unchecked Sendable {
    var sent: [Data] = []
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    var connectCalled = false

    func connect() async throws { connectCalled = true }
    func send(_ data: Data) async throws { sent.append(data) }
    func close() {}
}

/// Tests for TransportV2 reconnect-guard behaviour. Reuses the same
/// MockWebSocket + harness from TransportV2Tests.swift.
final class TransportV2ReconnectTests: XCTestCase {

    // MARK: - Helpers

    struct TransportHarness {
        let transport: TransportV2
        let socket: WebSocketLike
        let store: ConversationStoreV2
    }

    /// Default harness: plain mock, normal watchdog interval.
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

    /// Harness with a failing connect mock.
    func makeTransport(failingConnect: Bool) throws -> TransportHarness {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        let socket = FailingMockWebSocket()
        let transport = TransportV2(
            store: store, socket: socket, token: "tok",
            ackTimeoutSeconds: 0.2, dispatcherIntervalMs: 50
        )
        return TransportHarness(transport: transport, socket: socket, store: store)
    }

    /// Harness with a short watchdog timeout (connects OK, never auths).
    func makeTransport(watchdogSeconds: Double) throws -> TransportHarness {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        let socket = NoAuthMockWebSocket()
        let transport = TransportV2(
            store: store, socket: socket, token: "tok",
            ackTimeoutSeconds: 0.2, dispatcherIntervalMs: 50,
            connectWatchdogSeconds: watchdogSeconds
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

    // MARK: - Task 2: connect reset-on-failure + auth watchdog

    func testConnectResetsStateOnFailure() async throws {
        // MockWebSocket variant whose connect() throws. Reuse/extend the mock.
        let h = try makeTransport(failingConnect: true)
        try? await h.transport.connect()
        let state = await h.transport.state
        XCTAssertEqual(state, .idle, "a failed connect must not strand .connecting")
    }

    func testAuthWatchdogRecoversStuckConnecting() async throws {
        // Mock connects OK but never delivers auth_ok. Short watchdog for the test.
        let h = try makeTransport(watchdogSeconds: 0.3)
        try? await h.transport.connect()              // → .connecting, no auth_ok
        let mid = await h.transport.state
        XCTAssertEqual(mid, .connecting)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let after = await h.transport.state
        XCTAssertNotEqual(after, .connecting, "watchdog must clear a stuck .connecting")
    }
}
