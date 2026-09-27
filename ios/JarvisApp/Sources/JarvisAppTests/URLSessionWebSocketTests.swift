import XCTest
@testable import Jarvis

final class URLSessionWebSocketTests: XCTestCase {

    func testAcceptsTheLargestFrameTheHostSends() async throws {
        // Regression (Lena, 2026-09-27): an agent's recoloured photo arrived as a
        // 1.9 MB message frame. URLSessionWebSocketTask refuses anything above
        // its default 1 MiB, so the receive failed and the socket closed with
        // 1009; the row was never acked, the host re-drained it first on every
        // reconnect, and the connection never recovered.
        let ws = URLSessionWebSocket(url: URL(string: "ws://127.0.0.1:9")!)
        try await ws.connect()
        defer { ws.close() }

        let limit = try XCTUnwrap(ws.task?.maximumMessageSize)
        // Host contract (src/channels/ios-app/v2/types.ts): up to 30 MiB of
        // attachments per message → 40 MiB of base64 in one frame, plus text and
        // JSON — CLIENT_MAX_FRAME_BYTES = 48 MiB.
        XCTAssertGreaterThanOrEqual(limit, 48 * 1024 * 1024)
    }
}
