import XCTest
import GRDB
@testable import Jarvis

/// Exercises measured in seconds: the treadmill warmup (no sets) and, from
/// mesocycle 3, planks and isometric holds (sets of N seconds). Before, the
/// warmup's "Засчитать" logged nothing — the session kept `"sets": []` — and a
/// plank with sets would have shown the reps and weight wheels.
@MainActor
final class TimedExerciseTests: XCTestCase {

    private func plan(_ exercises: [ExercisePlan]) -> WorkoutPlan {
        WorkoutPlan(workoutId: "w1", dayName: "Ноги А", week: 1, intensityLabel: "лёгкая",
                    exercises: exercises, imageManifest: [])
    }

    private let warmup = ExercisePlan(exerciseSlug: "hodba", targetSets: 0, targetReps: "", targetRir: 0,
                                      restSec: 0, nameRu: "Ходьба", durationSec: 300)
    private let planka = ExercisePlan(exerciseSlug: "planka", targetSets: 2, targetReps: "", targetRir: 0,
                                      restSec: 60, nameRu: "Планка", durationSec: 120)
    private let zhim = ExercisePlan(exerciseSlug: "zhim", targetSets: 3, targetReps: "8-10", targetRir: 2,
                                    restSec: 120, weightKgTarget: 60)

    private func makeQueue() throws -> SetLogQueue {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return SetLogQueue(writer: dbq)
    }

    // MARK: - Plan shape

    func test_planWithSetsAndDuration_isTimedSets_notWarmup() throws {
        let json = #"{"slug":"planka","name_ru":"Планка","target_sets":2,"target_reps":"","reps_in_reserve":null,"rest_seconds":60,"duration_seconds":120}"#
        let e = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
        XCTAssertTrue(e.isTimed)
        XCTAssertTrue(e.isTimedSets)
        XCTAssertFalse(e.isDuration)
    }

    func test_warmupIsTimed_butHasNoSets() {
        XCTAssertTrue(warmup.isTimed)
        XCTAssertFalse(warmup.isTimedSets)
        XCTAssertFalse(zhim.isTimed)
    }

    // MARK: - Logged set

    func test_loggedSet_carriesHeldSeconds_onTheWire() throws {
        let s = LoggedSet(reps: 0, weight: 0, repsInReserve: 0, ts: Date(timeIntervalSince1970: 0), durationSec: 95)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let obj = try JSONSerialization.jsonObject(with: enc.encode(s)) as? [String: Any]
        XCTAssertEqual(obj?["duration_seconds"] as? Int, 95)
    }

    func test_loggedSet_withoutDuration_omitsTheKey_andDecodesNil() throws {
        let s = LoggedSet(reps: 10, weight: 60, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(s)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(obj?["duration_seconds"])
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        XCTAssertNil(try dec.decode(LoggedSet.self, from: data).durationSec)
    }

    // MARK: - Coordinator

    func test_logTimedSet_recordsSeconds_andAdvancesTheSet() throws {
        let queue = try makeQueue()
        let coord = WorkoutCoordinator(plan: plan([planka, zhim]), queue: queue)
        coord.logTimedSet(seconds: 125)
        XCTAssertEqual(coord.currentSetIdx, 1)
        XCTAssertEqual(coord.loggedForCurrentExercise.map(\.durationSec), [125])
        XCTAssertEqual(coord.loggedForCurrentExercise.first?.deviations, [])
        // A held time is not a set_log: that wire carries reps and weight, and
        // Payne reads the time from workout_complete.
        XCTAssertEqual(try queue.pending().count, 0)
    }

    func test_warmup_loggedTime_reachesTheSession() throws {
        let coord = WorkoutCoordinator(plan: plan([warmup, zhim]), queue: try makeQueue())
        coord.logTimedSet(seconds: 420)
        coord.finishExercise(comment: nil)
        XCTAssertEqual(coord.currentExerciseIdx, 1)
        let session = coord.complete(sessionFeeling: 3, sessionFeelingLabel: "Нормально")
        XCTAssertEqual(session.exercises[0].exerciseSlug, "hodba")
        XCTAssertEqual(session.exercises[0].sets.map(\.durationSec), [420])
    }

    func test_editTimedSet_changesOnlyTheTime() throws {
        let coord = WorkoutCoordinator(plan: plan([planka]), queue: try makeQueue())
        let ts = Date(timeIntervalSince1970: 1_000)
        coord.logTimedSet(seconds: 120, ts: ts)
        coord.editTimedSet(exerciseIdx: 0, setIdx: 0, seconds: 90)
        XCTAssertEqual(coord.loggedForCurrentExercise.first?.durationSec, 90)
        XCTAssertEqual(coord.loggedForCurrentExercise.first?.ts, ts)
        XCTAssertEqual(coord.currentSetIdx, 1)
    }

    func test_logTimedSet_afterFinish_isNoOp() throws {
        let coord = WorkoutCoordinator(plan: plan([planka]), queue: try makeQueue())
        _ = coord.complete(sessionFeeling: 3, sessionFeelingLabel: "Нормально")
        coord.logTimedSet(seconds: 60)
        XCTAssertEqual(coord.logged[0].sets.count, 0)
    }

    // MARK: - Wheel values

    func test_holdSeconds_roundsToFiveSeconds_neverZero() {
        XCTAssertEqual(WorkoutRunnerLogic.holdSeconds(72), 70)
        XCTAssertEqual(WorkoutRunnerLogic.holdSeconds(73), 75)
        XCTAssertEqual(WorkoutRunnerLogic.holdSeconds(0.4), 5)
        XCTAssertEqual(WorkoutRunnerLogic.holdSeconds(4000), 59 * 60 + 55)
    }

    func test_defaultHold_lastLoggedThenTarget() {
        XCTAssertEqual(WorkoutRunnerLogic.defaultHold(target: 120, lastLogged: 95), 95)
        XCTAssertEqual(WorkoutRunnerLogic.defaultHold(target: 120, lastLogged: nil), 120)
        XCTAssertEqual(WorkoutRunnerLogic.defaultHold(target: nil, lastLogged: nil), 60)
    }

    // MARK: - Stopwatch

    func test_holdTimer_countsFromTheWallClock() {
        var clock = Date(timeIntervalSince1970: 0)
        let timer = HoldTimer()
        timer.now = { clock }
        timer.start(targetSec: 90)
        XCTAssertTrue(timer.running)
        clock = clock.addingTimeInterval(72)
        timer.refresh()
        XCTAssertEqual(timer.elapsedSec, 72)
        XCTAssertFalse(timer.reachedTarget)
        clock = clock.addingTimeInterval(20)
        timer.refresh()
        XCTAssertTrue(timer.reachedTarget)
        XCTAssertEqual(timer.stop(), 92)
        XCTAssertFalse(timer.running)
    }

    func test_holdTimer_reset_clearsAWatchLeftRunning() {
        let timer = HoldTimer()
        timer.start(targetSec: 60)
        timer.reset()
        XCTAssertFalse(timer.running)
        XCTAssertEqual(timer.elapsedSec, 0)
    }
}
