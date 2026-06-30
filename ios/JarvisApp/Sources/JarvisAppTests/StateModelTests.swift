import XCTest
@testable import Jarvis

final class StateModelTests: XCTestCase {
    func testDecodesStatePayload() throws {
        let json = """
        {"levels":{"energy":72,"stress":34,"recovery":81,"readiness":68,"recovery7d":[74,77,81],"updated":"2026-06-12"},
         "agents":[{"key":"greg","title":"Здоровье · Greg","icon":"🩺","summary":"ok","detail":"- a","updated":"2026-06-12"}]}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StateModel.self, from: json)
        XCTAssertEqual(s.levels.energy, 72)
        XCTAssertEqual(s.levels.readiness, 68)
        // recovery7d is still present in the payload here on purpose: the Sparkline
        // was removed, so the field is gone from the model and the decoder must
        // simply ignore the extra key (transitional — greg/host may still emit it).
        XCTAssertEqual(s.agents.first?.key, "greg")
    }
}
