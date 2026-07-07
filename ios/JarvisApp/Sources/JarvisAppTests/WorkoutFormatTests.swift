import XCTest
@testable import Jarvis

final class WorkoutFormatTests: XCTestCase {
    func test_midReps() {
        XCTAssertEqual(WorkoutSetFormat.midReps(targetReps: "8-10"), 9)
        XCTAssertEqual(WorkoutSetFormat.midReps(targetReps: "12"), 12)
        XCTAssertEqual(WorkoutSetFormat.midReps(targetReps: ""), 8)
    }

    func test_formatWeight() {
        XCTAssertEqual(WorkoutSetFormat.weight(60.0), "60")
        XCTAssertEqual(WorkoutSetFormat.weight(62.5), "62.5")
    }

    func test_displayName_prefersNameRu() {
        let e = ExercisePlan(exerciseSlug: "zhim-shtangi-lezha", targetSets: 4, targetReps: "5-6",
                             targetRir: 2, restSec: 180, nameRu: "Жим штанги лёжа")
        XCTAssertEqual(e.displayName, "Жим штанги лёжа")
    }

    func test_displayName_fallbackPrettifiesSlug() {
        let e = ExercisePlan(exerciseSlug: "zhim-shtangi-lezha", targetSets: 4, targetReps: "5-6",
                             targetRir: 2, restSec: 180, nameRu: nil)
        XCTAssertEqual(e.displayName, "Zhim shtangi lezha")
    }

    func test_nameRu_decodesFromPlanJson() throws {
        let json = #"{"slug":"x","name_ru":"Тяга","target_sets":3,"target_reps":"5","reps_in_reserve":2,"rest_seconds":90}"#
        let e = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
        XCTAssertEqual(e.nameRu, "Тяга")
        XCTAssertEqual(e.displayName, "Тяга")
    }

    func test_formatDuration() {
        XCTAssertEqual(WorkoutSetFormat.duration(300), "5:00")
        XCTAssertEqual(WorkoutSetFormat.duration(90), "1:30")
    }

    func test_durationExercise_decodesAndFlags() throws {
        // Warmup shape: null sets + duration_seconds → isDuration.
        let json = #"{"slug":"hodba","name_ru":"Ходьба","target_sets":null,"target_reps":"","reps_in_reserve":null,"rest_seconds":0,"duration_seconds":300}"#
        let e = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
        XCTAssertEqual(e.durationSec, 300)
        XCTAssertTrue(e.isDuration)
    }

    func test_normalExercise_isNotDuration() throws {
        let json = #"{"slug":"zhim","target_sets":4,"target_reps":"5-6","reps_in_reserve":2,"rest_seconds":180}"#
        let e = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
        XCTAssertNil(e.durationSec)
        XCTAssertFalse(e.isDuration)
    }

    func test_setLog_encodesDeviationRoundTrip() throws {
        let deviation = V2.SetLog.Deviation(
            kind: .failure,
            magnitude: 0,
            target: V2.SetLog.DeviationTarget(reps_min: 8, reps_max: 10, weight: 24, rir: 2)
        )
        let log = V2.SetLog(
            workout_id: "w", exercise_slug: "ex", set_idx: 0,
            reps: 10, weight: 20, reps_in_reserve: 0,
            ts: "2026-01-01T00:00:00Z", agent_id: "payne",
            deviation: deviation
        )
        let data = try JSONEncoder().encode(log)
        let round = try JSONDecoder().decode(V2.SetLog.self, from: data)
        XCTAssertEqual(round.deviation?.kind, .failure)
        XCTAssertEqual(round.deviation?.target.reps_max, 10)
        XCTAssertEqual(round.deviation?.target.weight, 24)
    }
}
