import XCTest
@testable import Jarvis

/// Skeletons for the remaining 4 E2E scenarios from the iOS-app v2 plan
/// (Task 6.4). All currently `XCTSkip` so they show up in test reports
/// as "pending" rather than blocking the suite.
///
/// Each will follow the same shape as `HappyPathE2ETests`:
///   1. Start the harness in the named scenario (`offline_queue` / `context`
///      / `reconnect` / `restart`).
///   2. Build an in-memory stack + URLSessionWebSocket.
///   3. Drive `transport.connect()` and verify scenario-specific behaviour:
///      - offline_queue: insertOutbound before connect → message lands after
///        auth_ok via `tickDispatcher` resume.
///      - context: harness sends `context_request`; verify the dispatcher
///        emits a `context_response` once `AppContextCoordinator` is wired
///        (currently a stub in TransportV2.handleIncoming).
///      - reconnect: harness closes mid-session; verify transport reaches
///        `.reconnecting` then `.authed` again.
///      - restart: pretend the app is killed mid-stream; rebuild stack with
///        the same store and confirm queued inbounds resume cleanly.
final class PendingScenariosE2ETests: XCTestCase {

    func testOfflineQueueScenario() throws {
        throw XCTSkip("TODO: E2E sim scenario `offline_queue`; see iOS-app v2 plan §6.4")
    }

    func testContextRequestScenario() throws {
        throw XCTSkip("TODO: E2E sim scenario `context`; depends on TransportV2 wiring InboundDispatcher → ContextCoordinator (see Task 4.5)")
    }

    func testReconnectScenario() throws {
        throw XCTSkip("TODO: E2E sim scenario `reconnect`; depends on TransportV2 auto-reconnect (currently no production loop wires socket.onClose → reconnect)")
    }

    func testRestartScenario() throws {
        throw XCTSkip("TODO: E2E sim scenario `restart`; persists store across simulated app restart")
    }
}
