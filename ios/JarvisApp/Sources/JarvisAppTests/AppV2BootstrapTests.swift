import XCTest
import GRDB
@testable import Jarvis

/// Light-touch coverage for the v2 production glue. The bootstrap itself
/// writes to `Documents/` and isn't easily redirectable without changing its
/// signature, so we exercise the inner pieces (Schema, ConversationStoreV2,
/// TransportV2, AppContextCoordinator) here and rely on Phase 6.4 E2E for
/// the full disk-side `build()` path.
final class AppV2BootstrapTests: XCTestCase {

    func testInnerComponentsWireTogether() throws {
        // Mirror what AppV2Bootstrap.build does, but against an in-memory DB
        // so we don't depend on the simulator's Documents directory.
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        _ = store // silence unused

        // Production WebSocket isn't connected — just instantiable.
        let url = URL(string: "ws://localhost:1")!
        let socket = URLSessionWebSocket(url: url)
        let transport = TransportV2(store: store, socket: socket, token: "test-token")

        // Coordinator with all-nil managers must not crash.
        let coord = AppContextCoordinator()

        XCTAssertNotNil(socket)
        XCTAssertNotNil(transport)
        XCTAssertNotNil(coord)
    }

    func testCoordinatorNoManagersReturnsEmptyShapes() async throws {
        let coord = AppContextCoordinator()

        // health → empty object, not an error.
        let h = try await coord.health()
        if case .object(let obj) = h {
            XCTAssertTrue(obj.isEmpty)
        } else {
            XCTFail("expected object, got \(h)")
        }

        // calendar → empty array.
        let c = try await coord.calendar()
        if case .array(let arr) = c {
            XCTAssertTrue(arr.isEmpty)
        } else {
            XCTFail("expected array, got \(c)")
        }

        // recentLocations → empty array.
        let r = try await coord.recentLocations(hours: 12)
        if case .array(let arr) = r {
            XCTAssertTrue(arr.isEmpty)
        } else {
            XCTFail("expected array, got \(r)")
        }

        // nextEvent → nil.
        let n = try await coord.nextEvent()
        XCTAssertNil(n)
    }

    func testCoordinatorDeviceAndScreenStateAlwaysProduced() async throws {
        let coord = AppContextCoordinator()

        let d = try await coord.device()
        guard case .object(let obj) = d else {
            XCTFail("device must return object")
            return
        }
        XCTAssertNotNil(obj["model"])
        XCTAssertNotNil(obj["os_version"])

        let s = try await coord.screenState()
        guard case .string(let str) = s else {
            XCTFail("screen_state must return string")
            return
        }
        XCTAssertTrue(str == "foreground" || str == "background")
    }
}
