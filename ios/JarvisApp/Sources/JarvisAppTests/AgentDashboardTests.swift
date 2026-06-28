import XCTest
@testable import Jarvis

final class AgentDashboardTests: XCTestCase {
    func testAgentRowDecodesMetricsAndAction() throws {
        let json = """
        {"key":"greg","title":"t","icon":"x","summary":"s","detail":"d","updated":"2026-06-13",
         "action":"Лёгкий день","metrics":[{"v":"68","l":"готовность","t":"warn"},{"v":"6.2ч","l":"сон"}]}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(StateModel.AgentRow.self, from: json)
        XCTAssertEqual(row.action, "Лёгкий день")
        XCTAssertEqual(row.metrics?.count, 2)
        XCTAssertEqual(row.metrics?.first?.v, "68")
        XCTAssertEqual(row.metrics?.first?.t, "warn")
        XCTAssertNil(row.metrics?.last?.t)
    }

    func testAgentRowDecodesWithoutNewFields() throws {
        let json = #"{"key":"x","title":"t","icon":"i","summary":"s","detail":"d","updated":null}"#.data(using: .utf8)!
        let row = try JSONDecoder().decode(StateModel.AgentRow.self, from: json)
        XCTAssertNil(row.metrics)
        XCTAssertNil(row.action)
    }
}
