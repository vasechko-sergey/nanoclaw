import XCTest
@testable import Jarvis

final class PendingNotificationsTests: XCTestCase {
    func testParseValidBody() throws {
        let json = """
        {"messages":[
          {"id":"m1","seq":3,"agent_id":"jarvis","text":"hi"},
          {"id":"m2","seq":5,"agent_id":"greg","text":"готовность 68"}
        ]}
        """.data(using: .utf8)!
        let msgs = PendingNotifications.parse(json)
        XCTAssertEqual(msgs.map(\.id), ["m1", "m2"])
        XCTAssertEqual(msgs[1].agent_id, "greg")
        XCTAssertEqual(msgs[1].seq, 5)
    }

    func testParseToleratesNullAgentAndEmpty() throws {
        XCTAssertEqual(PendingNotifications.parse(Data("{}".utf8)).count, 0)
        XCTAssertEqual(PendingNotifications.parse(Data("garbage".utf8)).count, 0)
        let nullAgent = Data(#"{"messages":[{"id":"m1","seq":1,"agent_id":null,"text":"x"}]}"#.utf8)
        let msgs = PendingNotifications.parse(nullAgent)
        XCTAssertEqual(msgs.first?.agent_id, nil)
    }
}
