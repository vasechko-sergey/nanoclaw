import XCTest
@testable import Jarvis

final class V2SummaryReadyTests: XCTestCase {
    func testDecodesSummaryReady() throws {
        let json = """
        {"v":2,"kind":"data","type":"summary_ready","id":"summary-owner-2026-06-30",
         "seq":12,"ts":"2026-06-30T00:52:00.000Z",
         "payload":{"date":"2026-06-30","count":5,"text":"Сводка готова · 5 карточек","agent_id":"jarvis"}}
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(V2.Envelope.self, from: json)
        XCTAssertEqual(env.type, .summaryReady)
        guard case let .summaryReady(p) = env.payload else { return XCTFail("wrong payload") }
        XCTAssertEqual(p.count, 5)
        XCTAssertEqual(p.date, "2026-06-30")
    }
}
