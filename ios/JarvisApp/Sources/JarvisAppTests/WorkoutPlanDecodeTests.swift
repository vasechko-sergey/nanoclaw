import XCTest
@testable import Jarvis

/// Regression: Payne's `workout_plan.plan_json` uses field names that differ
/// from the canonical model (`slug`/`reps_in_reserve`/`rest_seconds`/
/// `week_label`) and a cardio warmup carries `target_sets: null`. The strict
/// model never decoded it → the workout card/auto-open silently failed. These
/// pin the lenient decode.
final class WorkoutPlanDecodeTests: XCTestCase {
    func test_decodesPaynePlanJSON_withAliasesAndNullWarmup() throws {
        // Shape AppCoordinator.decodeWorkoutPlan feeds in: envelope workout_id +
        // image_manifest spliced onto plan_json (day_name/week/week_label/exercises).
        let json = """
        {
          "workout_id": "2026-06-22",
          "day_name": "Верх А",
          "week": 1,
          "week_label": "лёгкая",
          "exercises": [
            {"slug":"hodba","name_ru":"Ходьба","target_sets":null,"target_reps":"","reps_in_reserve":null,"rest_seconds":0,"duration_seconds":300,"notes":"разминка"},
            {"slug":"zhim","name_ru":"Жим","target_sets":4,"target_reps":"5-6","reps_in_reserve":3,"rest_seconds":180,"weight_kg_target":65}
          ],
          "image_manifest": [{"slug":"hodba","sha256":"abc"}]
        }
        """
        let plan = try JSONDecoder().decode(WorkoutPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.workoutId, "2026-06-22")
        XCTAssertEqual(plan.intensityLabel, "лёгкая")          // from week_label alias
        XCTAssertEqual(plan.exercises.count, 2)
        XCTAssertEqual(plan.imageManifest.count, 1)

        // Warmup: slug alias, null numerics default to 0 (does not sink the plan).
        XCTAssertEqual(plan.exercises[0].exerciseSlug, "hodba")
        XCTAssertEqual(plan.exercises[0].targetSets, 0)
        XCTAssertEqual(plan.exercises[0].targetRir, 0)
        XCTAssertEqual(plan.exercises[0].targetReps, "")

        // Real lift: reps_in_reserve → targetRir, rest_seconds → restSec.
        XCTAssertEqual(plan.exercises[1].exerciseSlug, "zhim")
        XCTAssertEqual(plan.exercises[1].targetSets, 4)
        XCTAssertEqual(plan.exercises[1].targetReps, "5-6")
        XCTAssertEqual(plan.exercises[1].targetRir, 3)
        XCTAssertEqual(plan.exercises[1].restSec, 180)
    }

    func test_roundTripsThroughCanonicalEncode() throws {
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "Ноги", week: 2, intensityLabel: "высокая",
            exercises: [ExercisePlan(exerciseSlug: "squat", targetSets: 5, targetReps: "5",
                                     targetRir: 2, restSec: 180, notes: nil)],
            imageManifest: [WorkoutPlan.ImageManifestEntry(slug: "squat", sha256: "abc")])
        let data = try JSONEncoder().encode(plan)
        let back = try JSONDecoder().decode(WorkoutPlan.self, from: data)
        XCTAssertEqual(back, plan)
    }
}
