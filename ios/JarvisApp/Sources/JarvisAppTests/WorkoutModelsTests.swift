import XCTest
@testable import Jarvis

final class WorkoutModelsTests: XCTestCase {

    func test_workoutPlan_roundTripsThroughJSON() throws {
        let plan = WorkoutPlan(
            workoutId: "w1",
            dayName: "Верх A",
            week: 2,
            intensityLabel: "тяжёлая",
            exercises: [
                ExercisePlan(exerciseSlug: "incline-db-press",
                             targetSets: 4, targetReps: "8-10",
                             targetRir: 2, restSec: 120, notes: nil)
            ],
            imageManifest: [
                .init(slug: "incline-db-press", sha256: "deadbeef")
            ]
        )
        let data = try JSONEncoder().encode(plan)
        let back = try JSONDecoder().decode(WorkoutPlan.self, from: data)
        XCTAssertEqual(back, plan)
    }

    func test_workoutSession_decodesSnakeCase() throws {
        let json = #"""
        {
          "workout_id": "w1",
          "date": "2026-06-09",
          "day_name": "Верх A",
          "week": 2,
          "started_at": "2026-06-09T19:03:00Z",
          "finished_at": "2026-06-09T20:14:00Z",
          "exercises": [
            {
              "exercise_slug": "incline-db-press",
              "sets": [
                { "reps": 10, "weight": 22.5, "reps_in_reserve": 3, "ts": "2026-06-09T19:05:00Z" }
              ]
            }
          ],
          "perceived_overall_rir": 1
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(WorkoutSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.workoutId, "w1")
        XCTAssertEqual(session.exercises[0].sets[0].repsInReserve, 3)
    }
}
