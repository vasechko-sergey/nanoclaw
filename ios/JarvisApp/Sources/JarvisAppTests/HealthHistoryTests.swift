import XCTest
@testable import Jarvis

final class HealthHistoryTests: XCTestCase {
    func test_day_decodes_new_sensor_fields() throws {
        let json = """
        {"date":"2026-06-10","sleepHours":7.2,"deepMin":62,"remMin":95,"coreMin":275,
         "awakeMin":18,"sleepOnsetMin":-42,"hrvMorning":58,"spo2Avg":96.4,"spo2Min":91.0}
        """.data(using: .utf8)!
        let day = try JSONDecoder().decode(V2.HealthUpload.Day.self, from: json)
        XCTAssertEqual(day.deepMin, 62)
        XCTAssertEqual(day.remMin, 95)
        XCTAssertEqual(day.awakeMin, 18)
        XCTAssertEqual(day.sleepOnsetMin, -42)
        XCTAssertEqual(day.hrvMorning, 58)
        XCTAssertEqual(day.spo2Avg, 96.4)
        XCTAssertEqual(day.spo2Min, 91.0)
    }
}
