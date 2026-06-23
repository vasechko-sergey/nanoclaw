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
}
