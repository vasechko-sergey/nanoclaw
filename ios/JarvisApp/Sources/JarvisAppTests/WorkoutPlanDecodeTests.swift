import XCTest
@testable import Jarvis

/// Regression: the workout_plan never decoded on iOS because the model's keys
/// drifted from Payne's `plan_json` (`slug`/`reps_in_reserve`/`rest_seconds`/
/// `week_label`) and a cardio warmup carries `target_sets: null`. The schema is
/// now pinned to that canonical vocab (with null-tolerance for the warmup);
/// these pin the canonical decode + the shared-fixture bridge.
final class WorkoutPlanDecodeTests: XCTestCase {
    func test_decodesPaynePlanJSON_withNullWarmup() throws {
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

    @MainActor
    func test_sharedFixture_decodesThroughRealPath() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JarvisAppTests/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // JarvisApp/
            .deletingLastPathComponent()  // ios/
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appendingPathComponent("shared/ios-app-protocol/fixtures/workout_plan.json")
        let data = try Data(contentsOf: url)
        let env = try JSONDecoder().decode(V2.Envelope.self, from: data)
        guard case let .workoutPlan(payload) = env.payload else { return XCTFail("expected workoutPlan payload") }

        let plan = try AppCoordinator.decodeWorkoutPlan(payload: payload)
        XCTAssertEqual(plan.workoutId, "01J6Z8W3K2N5A7B9C1D3E5F7G9")
        XCTAssertEqual(plan.intensityLabel, "тяжёлая")       // from week_label
        XCTAssertEqual(plan.exercises.count, 2)
        XCTAssertEqual(plan.exercises[0].exerciseSlug, "hodba")
        XCTAssertEqual(plan.exercises[0].targetSets, 0)      // null warmup → 0
        XCTAssertEqual(plan.exercises[0].targetRir, 0)       // null warmup → 0
        XCTAssertEqual(plan.exercises[1].exerciseSlug, "incline-db-press")
        XCTAssertEqual(plan.exercises[1].targetSets, 4)
        XCTAssertEqual(plan.exercises[1].targetRir, 2)
        XCTAssertEqual(plan.exercises[1].restSec, 120)
        XCTAssertEqual(plan.imageManifest.count, 1)
    }

    /// F19: a plan_json with an empty (or absent) `exercises` array decodes fine
    /// — the tolerant decoder defaults it to `[]`. Mounting the preview/runner on
    /// such a plan index-crashed (`WorkoutCoordinator.currentExercise`, the
    /// preview cursor). `isRunnable` gates the entry points so it can't.
    func test_emptyExercisesPlanIsNotRunnable() throws {
        let empty = WorkoutPlan(
            workoutId: "w0", dayName: "Пусто", week: 1, intensityLabel: "",
            exercises: [], imageManifest: [])
        XCTAssertFalse(empty.isRunnable)

        let ok = WorkoutPlan(
            workoutId: "w1", dayName: "Ноги", week: 1, intensityLabel: "лёгкая",
            exercises: [ExercisePlan(exerciseSlug: "squat", targetSets: 3, targetReps: "5",
                                     targetRir: 2, restSec: 120, notes: nil)],
            imageManifest: [])
        XCTAssertTrue(ok.isRunnable)
    }
}
