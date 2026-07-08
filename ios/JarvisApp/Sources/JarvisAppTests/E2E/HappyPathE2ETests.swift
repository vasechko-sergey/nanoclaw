import XCTest
import GRDB
@testable import Jarvis

/// End-to-end test for the iOS-app v2 transport: drives a real
/// `URLSessionWebSocket` against the Node `e2e-harness` (scenario=`happy`)
/// and verifies the full round trip lands in the GRDB store.
///
/// **Operator must start the harness externally before running this test.**
/// The iOS Simulator can't spawn host subprocesses (`Process` is macOS-only),
/// so the test probes the port via TCP and `XCTSkip`s if nothing is listening:
///
///     E2E_PORT=8801 E2E_SCENARIO=happy pnpm run e2e:harness &
///     xcodebuild test -only-testing:JarvisAppTests/HappyPathE2ETests ...
///
/// `TransportV2.connect()` now wires `socket.onMessage` and `socket.onClose`
/// itself, so this test mirrors the bootstrap internals only to swap in an
/// in-memory DB. No hand-wiring of callbacks needed.
final class HappyPathE2ETests: XCTestCase {
    private let harness = E2EHarness()
    private var stack: AppV2Stack?
    private var socket: URLSessionWebSocket?

    override func setUp() async throws {
        try await super.setUp()
        // On macOS this spawns the harness; on iOS Simulator it's a no-op and
        // we rely on the operator + the reachability probe below.
        try harness.start(scenario: "happy")
        if !E2EHarness.isHarnessReachable() {
            throw XCTSkip("e2e-harness not reachable on ws://127.0.0.1:\(E2EHarness.defaultPort). Start it with `pnpm run e2e:harness` before invoking this test.")
        }
    }

    override func tearDown() async throws {
        socket?.close()
        socket = nil
        stack = nil
        harness.stop()
        try await super.tearDown()
    }

    func testRoundTripUserMessageAndEcho() async throws {
        // Build the stack against an in-memory DB so the on-disk Documents/
        // file doesn't carry state between test runs.
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        let serverURL = URL(string: "ws://127.0.0.1:\(E2EHarness.defaultPort)")!
        let socket = URLSessionWebSocket(url: serverURL)
        self.socket = socket
        let transport = TransportV2(store: store, socket: socket, token: E2EHarness.defaultToken)
        let coordinator = AppContextCoordinator()
        let stack = AppV2Stack(
            store: store,
            transport: transport,
            coordinator: coordinator,
            dbq: dbq,
            setLogQueue: SetLogQueue(writer: dbq),
            controlEventQueue: ControlEventQueue(writer: dbq),
            activeWorkoutStore: ActiveWorkoutStore(writer: dbq)
        )
        self.stack = stack

        await transport.connect_throwing()
        // Wait for auth_ok → authed.
        try await waitForAuthed(transport: transport, timeout: 3.0)

        // Enqueue an outbound user message and kick the dispatcher.
        // Single-chat: no conversation_id; the wire thread_id is pinned to
        // `ios:default` inside TransportV2.
        let messageId = UUID().uuidString
        try store.insertOutboundUserMessage(
            id: messageId,
            text: "ping",
            attachments: [],
            context: nil
        )
        try await transport.tickDispatcher()

        // Wait for the harness echo to arrive and persist as an inbound row.
        try await waitForInbound(dbq: dbq, timeout: 5.0)

        // Final inspection: outbound + inbound both present.
        let messages = try await dbq.read { db in
            try Row.fetchAll(db, sql: """
                SELECT dir, text, status FROM messages
                ORDER BY ts ASC
            """)
        }
        XCTAssertGreaterThanOrEqual(messages.count, 2,
            "expected outbound + inbound rows; got \(messages.count): \(messages)")
        let outbound = messages.first { ($0["dir"] as String?) == "out" }
        let inbound = messages.first { ($0["dir"] as String?) == "in" }
        XCTAssertNotNil(outbound, "no outbound row")
        XCTAssertNotNil(inbound, "no inbound row")
        XCTAssertEqual(outbound?["text"] as String?, "ping")
        let inboundText = inbound?["text"] as String? ?? ""
        XCTAssertTrue(inboundText.contains("echo:"),
            "expected inbound to contain 'echo:', got \(inboundText)")
    }

    // MARK: - Helpers

    private func waitForAuthed(transport: TransportV2, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await transport.state
            if state == .authed { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("transport did not reach .authed within \(timeout)s; final state=\(await transport.state)")
    }

    private func waitForInbound(dbq: DatabaseQueue, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = try await dbq.read { db -> Int in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM messages WHERE dir = 'in'
                """) ?? 0
            }
            if count > 0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("no inbound row arrived within \(timeout)s")
    }
}

/// Convenience: TransportV2.connect throws but tests want it inline.
private extension TransportV2 {
    func connect_throwing() async {
        do { try await connect() }
        catch { XCTFail("transport.connect failed: \(error)") }
    }
}
