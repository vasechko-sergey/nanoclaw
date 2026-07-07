import XCTest
@testable import Jarvis

final class WorkoutRunnerLogicTests: XCTestCase {
    func test_snapRir_picksNearestButton() {
        XCTAssertEqual(WorkoutRunnerLogic.snapRir(2), 2)
        XCTAssertEqual(WorkoutRunnerLogic.snapRir(3), 2)   // tie 2 vs 4 → 2 (first min)
        XCTAssertEqual(WorkoutRunnerLogic.snapRir(5), 4)
        XCTAssertEqual(WorkoutRunnerLogic.snapRir(0), 0)
    }

    func test_defaultWeight_prefersTargetThenLastThen20() {
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: 66.25, lastLogged: 50), 66.5)
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: nil, lastLogged: 47.5), 47.5)
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: nil, lastLogged: nil), 20)
    }

    func test_setLabel_bonusPastTarget() {
        XCTAssertEqual(WorkoutRunnerLogic.setLabel(currentSetIdx: 1, targetSets: 4), "подход 2 из 4")
        XCTAssertEqual(WorkoutRunnerLogic.setLabel(currentSetIdx: 3, targetSets: 3), "бонусный подход")
        XCTAssertEqual(WorkoutRunnerLogic.setLabel(currentSetIdx: 4, targetSets: 3), "бонусный подход")
        XCTAssertNil(WorkoutRunnerLogic.setLabel(currentSetIdx: 0, targetSets: 0))   // warmup
    }

    func test_restHint_showsCurrentSetWhenMoreRemain() {
        let exs = [ExercisePlan(exerciseSlug: "a", targetSets: 3, targetReps: "8", targetRir: 2,
                                restSec: 60, notes: nil, nameRu: "A")]
        let logged = [LoggedExercise(exerciseSlug: "a", sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date())], comment: nil)]
        let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 0)
        XCTAssertEqual(hint, "подход 2 — A")
    }

    func test_restHint_scansEarlierUnfinishedWhenCurrentDone() {
        let exs = [
            ExercisePlan(exerciseSlug: "a", targetSets: 2, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "A"),
            ExercisePlan(exerciseSlug: "b", targetSets: 2, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "B"),
        ]
        let logged = [
            LoggedExercise(exerciseSlug: "a", sets: [], comment: nil),
            LoggedExercise(exerciseSlug: "b", sets: [
                LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date()),
                LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date()),
            ], comment: nil),
        ]
        let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 1)
        XCTAssertEqual(hint, "A — подход 1")
    }

    func test_restHint_allDone_returnsFinished() {
        let exs = [
            ExercisePlan(exerciseSlug: "a", targetSets: 1, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "A"),
        ]
        let logged = [LoggedExercise(exerciseSlug: "a", sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date())], comment: nil)]
        let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 0)
        XCTAssertEqual(hint, "Тренировка закончена")
    }

    func test_restHint_skipsDurationExercises() {
        let exs = [
            ExercisePlan(exerciseSlug: "cardio", targetSets: 0, targetReps: "", targetRir: 0, restSec: 0, notes: nil, nameRu: "Кардио", durationSec: 300),
            ExercisePlan(exerciseSlug: "a", targetSets: 1, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "A"),
        ]
        let logged = [
            LoggedExercise(exerciseSlug: "cardio", sets: [], comment: nil),
            LoggedExercise(exerciseSlug: "a", sets: [], comment: nil),
        ]
        let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 1)
        XCTAssertEqual(hint, "подход 1 — A")
    }

    func test_weightIndex_roundsToHalfStep() {
        XCTAssertEqual(WorkoutRunnerLogic.weightOptions.first, 0)
        XCTAssertEqual(WorkoutRunnerLogic.weightOptions.last, 300)
        XCTAssertEqual(WorkoutRunnerLogic.weightOptions[WorkoutRunnerLogic.weightIndex(for: 66.25)], 66.5)
        XCTAssertEqual(WorkoutRunnerLogic.weightOptions[WorkoutRunnerLogic.weightIndex(for: 999)], 300)
    }

    func test_feelings_fiveGraded() {
        XCTAssertEqual(WorkoutRunnerLogic.feelings.count, 5)
        XCTAssertEqual(WorkoutRunnerLogic.feelings.map(\.value), [1, 2, 3, 4, 5])
        XCTAssertEqual(WorkoutRunnerLogic.feelings.first(where: { $0.value == 4 })?.label, "Хорошо, с запасом")
    }

    func test_progressSegments_equalKindsAndPreviewMark() {
        let segs = WorkoutRunnerLogic.progressSegments(total: 4, activeIdx: 1, previewIdx: 3)
        XCTAssertEqual(segs.map(\.kind), [.done, .active, .upcoming, .upcoming])
        XCTAssertTrue(segs[3].isPreview)
        XCTAssertFalse(segs[1].isPreview)
    }

    func test_exerciseCounter_oneBased_clamped() {
        XCTAssertEqual(WorkoutRunnerLogic.exerciseCounter(activeIdx: 2, total: 6), "3/6")
        XCTAssertEqual(WorkoutRunnerLogic.exerciseCounter(activeIdx: 5, total: 6), "6/6")
    }

    func test_repsOptions_spans1to30() {
        XCTAssertEqual(WorkoutRunnerLogic.repsOptions.first, 1)
        XCTAssertEqual(WorkoutRunnerLogic.repsOptions.last, 30)
    }

    private func mkExercise(reps: String, weight: Double? = 20, rir: Int = 2) -> ExercisePlan {
        ExercisePlan(exerciseSlug: "ex", targetSets: 4, targetReps: reps, targetRir: rir,
                     restSec: 120, notes: nil, nameRu: nil, durationSec: nil, weightKgTarget: weight)
    }

    func test_detectDeviation_weightUnder15pct() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 80, actualRir: 2, exercise: ex)
        XCTAssertEqual(d?.kind, .weightUnder)
        XCTAssertEqual(d?.target.weight, 100)
        XCTAssertEqual(d?.target.repsMin, 8)
        XCTAssertEqual(d?.target.repsMax, 10)
    }

    func test_detectDeviation_weightWithinTolerance() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 90, actualRir: 2, exercise: ex)
        XCTAssertNil(d)
    }

    func test_detectDeviation_repsUnderByThree() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        // Mid = 9 → actual 5 is 4 below → repsUnder
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 5, actualWeight: 100, actualRir: 2, exercise: ex)
        XCTAssertEqual(d?.kind, .repsUnder)
    }

    func test_detectDeviation_failureOnRirZero() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 100, actualRir: 0, exercise: ex)
        XCTAssertEqual(d?.kind, .failure)
    }

    func test_detectDeviation_tooEasyOnRir4() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 100, actualRir: 4, exercise: ex)
        XCTAssertEqual(d?.kind, .tooEasy)
    }

    func test_detectDeviation_weightPrecedesReps() {
        // Weight AND reps out of tolerance → weight wins.
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 3, actualWeight: 80, actualRir: 2, exercise: ex)
        XCTAssertEqual(d?.kind, .weightUnder)
    }
}
