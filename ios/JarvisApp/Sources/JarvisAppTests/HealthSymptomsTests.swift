import XCTest
import HealthKit
@testable import Jarvis

final class HealthSymptomsTests: XCTestCase {

    // The suffix IS the wire contract — the server stores these strings verbatim
    // and Greg matches on them, so a change here silently breaks the detector.
    func test_symptomKey_strips_the_identifier_prefix() {
        XCTAssertEqual(HealthHistory.symptomKey(.fever), "fever")
        XCTAssertEqual(HealthHistory.symptomKey(.coughing), "coughing")
        XCTAssertEqual(HealthHistory.symptomKey(.shortnessOfBreath), "shortnessOfBreath")
        XCTAssertEqual(HealthHistory.symptomKey(.generalizedBodyAche), "generalizedBodyAche")
    }

    func test_symptomKey_lowercases_only_the_first_character() {
        // lossOfSmell, not lossofsmell and not LossOfSmell — the rest of the
        // camel hump has to survive or the keys stop matching the contract.
        XCTAssertEqual(HealthHistory.symptomKey(.lossOfSmell), "lossOfSmell")
        XCTAssertEqual(HealthHistory.symptomKey(.nightSweats), "nightSweats")
    }

    func test_every_requested_symptom_type_yields_a_distinct_key() {
        let keys = HealthManager.symptomTypes.map { HealthHistory.symptomKey($0) }
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate symptom keys would merge two symptoms into one")
        XCTAssertFalse(keys.contains { $0.hasPrefix("HK") }, "an unstripped identifier leaked into the wire keys")
    }

    func test_day_round_trips_symptoms_and_temperature() throws {
        var day = V2.HealthUpload.Day(date: "2026-08-12")
        day.bodyTemperature = 37.8
        day.symptoms = ["fever", "coughing"]
        let back = try JSONDecoder().decode(
            V2.HealthUpload.Day.self, from: JSONEncoder().encode(day)
        )
        XCTAssertEqual(back.bodyTemperature, 37.8)
        XCTAssertEqual(back.symptoms, ["fever", "coughing"])
    }

    // Absent and empty are different claims: nil means the upload said nothing
    // about symptoms, [] means the queries ran and found none. The encoder must
    // not collapse them, or the server's COALESCE upsert can never clear a
    // symptom the user deleted in Health.app.
    func test_empty_symptoms_survives_encoding_as_distinct_from_absent() throws {
        var logged = V2.HealthUpload.Day(date: "2026-08-12")
        logged.symptoms = []
        let backEmpty = try JSONDecoder().decode(
            V2.HealthUpload.Day.self, from: JSONEncoder().encode(logged)
        )
        XCTAssertEqual(backEmpty.symptoms, [])

        let silent = V2.HealthUpload.Day(date: "2026-08-12")
        let backNil = try JSONDecoder().decode(
            V2.HealthUpload.Day.self, from: JSONEncoder().encode(silent)
        )
        XCTAssertNil(backNil.symptoms)
    }

    func test_day_decodes_a_payload_without_the_new_fields() throws {
        // Older rows and older app builds omit both; decoding must not throw.
        let json = #"{"date":"2026-06-10","steps":1847}"#.data(using: .utf8)!
        let day = try JSONDecoder().decode(V2.HealthUpload.Day.self, from: json)
        XCTAssertNil(day.symptoms)
        XCTAssertNil(day.bodyTemperature)
    }
}
