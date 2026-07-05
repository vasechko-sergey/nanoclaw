import XCTest
@testable import Jarvis

final class ServerConfigTests: XCTestCase {

    func test_httpBase_normalizesScheme() {
        XCTAssertEqual(ServerConfig.httpBase(from: "wss://h.test"), "https://h.test")
        XCTAssertEqual(ServerConfig.httpBase(from: "ws://h.test"), "http://h.test")
        XCTAssertEqual(ServerConfig.httpBase(from: "100.64.0.1:3001"), "http://100.64.0.1:3001")
        XCTAssertEqual(ServerConfig.httpBase(from: "https://h.test"), "https://h.test")
        // Already-http strings (incl. a trailing slash) pass through untouched.
        XCTAssertEqual(ServerConfig.httpBase(from: "http://h.test/"), "http://h.test/")
    }

    func test_httpBase_defaultsToServerURL() {
        XCTAssertEqual(ServerConfig.httpBase(), ServerConfig.httpBase(from: ServerConfig.url))
    }

    func test_httpURL_joinsPathOntoBaseWithSingleSlash() {
        let base = ServerConfig.httpBase()
        XCTAssertEqual(
            ServerConfig.httpURL(path: "ios/pending")?.absoluteString,
            base + "/ios/pending"
        )
    }

    func test_httpURL_appendsQueryItems() {
        let url = ServerConfig.httpURL(
            path: "ios/pending",
            queryItems: [URLQueryItem(name: "tz", value: "Europe/London")]
        )
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/ios/pending")
        XCTAssertTrue(comps.queryItems!.contains(URLQueryItem(name: "tz", value: "Europe/London")))
    }
}
