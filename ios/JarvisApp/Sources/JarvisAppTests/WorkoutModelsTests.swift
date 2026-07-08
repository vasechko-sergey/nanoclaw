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

    func test_exercisePlan_decodesWeightKgTarget() throws {
        let json = """
        {"slug":"zhim","name_ru":"Жим","target_sets":4,"target_reps":"5-6",
         "reps_in_reserve":2,"rest_seconds":180,"weight_kg_target":66.25}
        """
        let ex = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
        XCTAssertEqual(ex.weightKgTarget, 66.25)
    }

    func test_exercisePlan_nilWeightKgTarget_whenAbsent() throws {
        let json = """
        {"slug":"warmup","target_sets":null,"target_reps":"","reps_in_reserve":null,
         "rest_seconds":0,"duration_seconds":300}
        """
        let ex = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
        XCTAssertNil(ex.weightKgTarget)
    }

    func test_exercisePlan_weightKgTarget_roundTrips() throws {
        let ex = ExercisePlan(exerciseSlug: "a", targetSets: 3, targetReps: "8",
                              targetRir: 2, restSec: 90, weightKgTarget: 40)
        let data = try JSONEncoder().encode(ex)
        let back = try JSONDecoder().decode(ExercisePlan.self, from: data)
        XCTAssertEqual(back.weightKgTarget, 40)
    }

    func test_workoutSession_encodesSessionFeeling() throws {
        let s = WorkoutSession(
            workoutId: "w", date: "2026-06-26", dayName: "Верх", week: 1,
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: nil, exercises: [],
            perceivedOverallRir: nil, healthSignalAtStart: nil,
            sessionFeeling: 4, sessionFeelingLabel: "Хорошо, с запасом")
        let data = try JSONEncoder().encode(s)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["session_feeling"] as? Int, 4)
        XCTAssertEqual(obj["session_feeling_label"] as? String, "Хорошо, с запасом")
    }

    func test_loggedSet_persistsDeviationsAndCoachHint() throws {
        let devs = [
            WorkoutRunnerLogic.SetDeviation(
                kind: .weightUnder, magnitude: -0.2,
                target: .init(repsMin: 8, repsMax: 10, weight: 100, rir: 2)
            ),
            WorkoutRunnerLogic.SetDeviation(
                kind: .failure, magnitude: 0,
                target: .init(repsMin: 8, repsMax: 10, weight: 100, rir: 2)
            ),
        ]
        let set = LoggedSet(
            reps: 10, weight: 20, repsInReserve: 0, ts: Date(timeIntervalSince1970: 0),
            deviations: devs,
            coachHint: "отдохни 3 мин"
        )
        let data = try JSONEncoder().encode(set)
        let round = try JSONDecoder().decode(LoggedSet.self, from: data)
        XCTAssertEqual(round.deviations.map(\.kind), [.weightUnder, .failure])
        XCTAssertEqual(round.coachHint, "отдохни 3 мин")
    }

    /// A set with no deviations must decode to `[]` (not throw) whether the
    /// `deviations` key is absent entirely or present as an empty array.
    func test_loggedSet_missingDeviations_decodesToEmpty() throws {
        let json = #"{ "reps": 10, "weight": 22.5, "reps_in_reserve": 3, "ts": 0 }"#
        let set = try JSONDecoder().decode(LoggedSet.self, from: Data(json.utf8))
        XCTAssertTrue(set.deviations.isEmpty)
        XCTAssertNil(set.coachHint)
    }

    /// A legacy single `deviation` object (pre-array cursors / records) wraps
    /// into a one-element array on decode.
    func test_loggedSet_legacySingleDeviation_wrapsIntoArray() throws {
        let json = #"""
        { "reps": 10, "weight": 80, "reps_in_reserve": 2, "ts": 0,
          "deviation": { "kind": "weight_under", "magnitude": -0.2,
                         "target": { "reps_min": 8, "reps_max": 10, "weight": 100, "rir": 2 } } }
        """#
        let set = try JSONDecoder().decode(LoggedSet.self, from: Data(json.utf8))
        XCTAssertEqual(set.deviations.map(\.kind), [.weightUnder])
    }
}
