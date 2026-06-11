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

    func test_bucketSleepStages_splits_minutes_and_onset() {
        let midnight = Date(timeIntervalSince1970: 1_800_000_000)
        func t(_ min: Int) -> Date { midnight.addingTimeInterval(Double(min) * 60) }
        let samples: [HealthHistory.SleepSampleInput] = [
            .init(stage: HealthHistory.SleepStage.asleepDeep.rawValue, start: t(-30), end: t(30)),
            .init(stage: HealthHistory.SleepStage.asleepREM.rawValue,  start: t(30),  end: t(120)),
            .init(stage: HealthHistory.SleepStage.asleepCore.rawValue, start: t(120), end: t(240)),
            .init(stage: HealthHistory.SleepStage.awake.rawValue,      start: t(240), end: t(255)),
            .init(stage: HealthHistory.SleepStage.inBed.rawValue,      start: t(-40), end: t(260)),
        ]
        let r = HealthHistory.bucketSleepStages(samples, dayStart: midnight)
        XCTAssertEqual(r.deepMin, 60)
        XCTAssertEqual(r.remMin, 90)
        XCTAssertEqual(r.coreMin, 120)
        XCTAssertEqual(r.awakeMin, 15)
        XCTAssertEqual(r.onsetMin, -30)
        XCTAssertEqual(r.sleepHours, 4.5, accuracy: 0.05)
    }

    func test_bucketSleepStages_handles_empty_and_all_awake() {
        let midnight = Date(timeIntervalSince1970: 1_800_000_000)
        func t(_ min: Int) -> Date { midnight.addingTimeInterval(Double(min) * 60) }
        let empty = HealthHistory.bucketSleepStages([], dayStart: midnight)
        XCTAssertNil(empty.onsetMin)
        XCTAssertEqual(empty.sleepHours, 0, accuracy: 0.001)
        XCTAssertEqual(empty.deepMin, 0)
        let allAwake = HealthHistory.bucketSleepStages([
            .init(stage: HealthHistory.SleepStage.awake.rawValue, start: t(0), end: t(30)),
        ], dayStart: midnight)
        XCTAssertNil(allAwake.onsetMin)
        XCTAssertEqual(allAwake.sleepHours, 0, accuracy: 0.001)
        XCTAssertEqual(allAwake.awakeMin, 30)
    }
}
