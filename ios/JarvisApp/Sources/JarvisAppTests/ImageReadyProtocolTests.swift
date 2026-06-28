import XCTest
@testable import Jarvis

/// Wire-contract tests for the by-reference `image_ready` envelope (replaces the
/// inline `image_blob` on the realtime stream for `image_ref`-capable clients).
final class ImageReadyProtocolTests: XCTestCase {

    func test_imageReady_decodesFromWire() throws {
        let json = """
        {"v":2,"kind":"control","type":"image_ready","id":"id-1","seq":3,\
        "ts":"2026-06-28T00:00:00.000Z","payload":{"slug":"incline-db-press",\
        "sha256":"abc123","agent_id":"payne"}}
        """
        let env = try JSONDecoder().decode(V2.Envelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.type, .imageReady)
        guard case let .imageReady(p) = env.payload else {
            return XCTFail("expected .imageReady payload, got \(env.payload)")
        }
        XCTAssertEqual(p.slug, "incline-db-press")
        XCTAssertEqual(p.sha256, "abc123")
        XCTAssertEqual(p.agent_id, "payne")
    }

    func test_imageReady_agentIdOptional() throws {
        let json = """
        {"v":2,"kind":"control","type":"image_ready","id":"id-2","seq":4,\
        "ts":"2026-06-28T00:00:00.000Z","payload":{"slug":"ex","sha256":"h"}}
        """
        let env = try JSONDecoder().decode(V2.Envelope.self, from: Data(json.utf8))
        guard case let .imageReady(p) = env.payload else {
            return XCTFail("expected .imageReady payload")
        }
        XCTAssertNil(p.agent_id)
    }

    func test_imageReady_encodeRoundTrips() throws {
        let env = V2.Envelope(
            v: 2, kind: .control, type: .imageReady,
            id: "id-3", seq: 5, ts: "2026-06-28T00:00:00.000Z",
            payload: .imageReady(V2.ImageReady(slug: "ex", sha256: "h", agent_id: "payne"))
        )
        let data = try JSONEncoder().encode(env)
        let back = try JSONDecoder().decode(V2.Envelope.self, from: data)
        XCTAssertEqual(back.type, .imageReady)
        guard case let .imageReady(p) = back.payload else {
            return XCTFail("expected .imageReady payload after round-trip")
        }
        XCTAssertEqual(p.slug, "ex")
        XCTAssertEqual(p.sha256, "h")
    }
}
