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

    func test_restHint_surfacesDurationFinisherWhenSetsDone() {
        // All set work done; a cardio finisher remains after the active exercise.
        let exs = [
            ExercisePlan(exerciseSlug: "bench", targetSets: 1, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "Жим"),
            ExercisePlan(exerciseSlug: "treadmill", targetSets: 0, targetReps: "", targetRir: 0, restSec: 0, notes: nil, nameRu: "Дорожка", durationSec: 600),
        ]
        let logged = [
            LoggedExercise(exerciseSlug: "bench", sets: [LoggedSet(reps: 8, weight: 40, repsInReserve: 2, ts: Date())], comment: nil),
            LoggedExercise(exerciseSlug: "treadmill", sets: [], comment: nil),
        ]
        let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 0)
        XCTAssertEqual(hint, "кардио: Дорожка")
    }

    func test_restHint_doneDurationWarmupNotResurfaced() {
        // A duration warmup the user already advanced past (before activeIdx)
        // must not be resurfaced once the set work is done.
        let exs = [
            ExercisePlan(exerciseSlug: "warmup", targetSets: 0, targetReps: "", targetRir: 0, restSec: 0, notes: nil, nameRu: "Разминка", durationSec: 300),
            ExercisePlan(exerciseSlug: "bench", targetSets: 1, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "Жим"),
        ]
        let logged = [
            LoggedExercise(exerciseSlug: "warmup", sets: [], comment: nil),
            LoggedExercise(exerciseSlug: "bench", sets: [LoggedSet(reps: 8, weight: 40, repsInReserve: 2, ts: Date())], comment: nil),
        ]
        let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 1)
        XCTAssertEqual(hint, WorkoutRunnerLogic.workoutFinishedHint)
    }

    func test_restHint_allDone_matchesFinishedSentinel() {
        // The all-done string the rest overlay watches for must equal the sentinel.
        let exs = [ExercisePlan(exerciseSlug: "a", targetSets: 1, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "A")]
        let logged = [LoggedExercise(exerciseSlug: "a", sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date())], comment: nil)]
        let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 0)
        XCTAssertEqual(hint, WorkoutRunnerLogic.workoutFinishedHint)
        XCTAssertEqual(WorkoutRunnerLogic.workoutFinishedHint, "Тренировка закончена")
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

    func test_progressSegments_skippedIsDistinctFromDone() {
        // did 0,1 (sets logged) · skipped 2 (no sets) · active 3 · upcoming 4 — all strength.
        // Old positional logic painted 2 as .done (i < activeIdx); it must be .skipped.
        let segs = WorkoutRunnerLogic.progressSegments(
            worked: [true, true, false, false, false],
            isDuration: [false, false, false, false, false],
            activeIdx: 3, previewIdx: 3)
        XCTAssertEqual(segs.map(\.kind), [.done, .done, .skipped, .active, .upcoming])
        XCTAssertFalse(segs[3].isPreview)   // preview == active → no separate mark, active ring covers it
    }

    func test_progressSegments_passedDurationCountsAsDone() {
        // treadmill warmup (duration, zero sets) at idx0 gets passed → done, not skipped.
        let segs = WorkoutRunnerLogic.progressSegments(
            worked: [false, true, false],
            isDuration: [true, false, false],
            activeIdx: 2, previewIdx: 2)
        XCTAssertEqual(segs.map(\.kind), [.done, .done, .active])
    }

    func test_progressSegments_workedAfterActiveStaysDone_onJumpBack() {
        // did idx2, jumped back to idx0 — idx2 keeps .done though it sits after active.
        let segs = WorkoutRunnerLogic.progressSegments(
            worked: [false, false, true],
            isDuration: [false, false, false],
            activeIdx: 0, previewIdx: 0)
        XCTAssertEqual(segs.map(\.kind), [.active, .upcoming, .done])
    }

    func test_progressSegments_previewMarkOnNonActive() {
        let segs = WorkoutRunnerLogic.progressSegments(
            worked: [true, false, false, false],
            isDuration: [false, false, false, false],
            activeIdx: 1, previewIdx: 3)
        XCTAssertEqual(segs.map(\.kind), [.done, .active, .upcoming, .upcoming])
        XCTAssertTrue(segs[3].isPreview)
        XCTAssertFalse(segs[1].isPreview)
    }

    func test_exerciseCounter_countsDoneNotPosition() {
        // skip scenario: 2 done of 5. Positional (activeIdx+1) would wrongly read 4/5.
        XCTAssertEqual(WorkoutRunnerLogic.exerciseCounter(done: 2, total: 5), "2/5")
        XCTAssertEqual(WorkoutRunnerLogic.exerciseCounter(done: 6, total: 6), "6/6")
        XCTAssertEqual(WorkoutRunnerLogic.exerciseCounter(done: 0, total: 0), "0/1")  // total clamped ≥1
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
        XCTAssertEqual(d.map(\.kind), [.weightUnder])
        XCTAssertEqual(d.first?.target.weight, 100)
        XCTAssertEqual(d.first?.target.repsMin, 8)
        XCTAssertEqual(d.first?.target.repsMax, 10)
    }

    func test_detectDeviation_weightWithinTolerance() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 90, actualRir: 2, exercise: ex)
        XCTAssertTrue(d.isEmpty)
    }

    func test_detectDeviation_repsUnderByThree() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        // Mid = 9 → actual 5 is 4 below → repsUnder
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 5, actualWeight: 100, actualRir: 2, exercise: ex)
        XCTAssertEqual(d.map(\.kind), [.repsUnder])
    }

    func test_detectDeviation_failureOnRirZero() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 100, actualRir: 0, exercise: ex)
        XCTAssertEqual(d.map(\.kind), [.failure])
    }

    func test_detectDeviation_tooEasyOnRir4() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 100, actualRir: 4, exercise: ex)
        XCTAssertEqual(d.map(\.kind), [.tooEasy])
    }

    func test_detectDeviation_weightAndRepsBothSurface() {
        // Weight AND reps out of tolerance → BOTH surface, in order weight→reps.
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 3, actualWeight: 80, actualRir: 2, exercise: ex)
        XCTAssertEqual(d.map(\.kind), [.weightUnder, .repsUnder])
    }

    func test_detectDeviation_allThreeAxesSurface() {
        // Under weight, missed reps, AND hit failure → every axis surfaces, in
        // order weight→reps→rir. This is the whole point of the array: a set
        // that went sideways everywhere no longer hides behind just the weight.
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 3, actualWeight: 80, actualRir: 0, exercise: ex)
        XCTAssertEqual(d.map(\.kind), [.weightUnder, .repsUnder, .failure])
    }

    // MARK: - parseRepsRange (Fix P delimiters + open-ended + AMRAP)

    private func assertRange(_ s: String, _ expected: (Int?, Int?, Int?),
                             file: StaticString = #filePath, line: UInt = #line) {
        let r = WorkoutRunnerLogic.parseRepsRange(s)
        XCTAssertEqual(r.min, expected.0, "min for \(s)", file: file, line: line)
        XCTAssertEqual(r.max, expected.1, "max for \(s)", file: file, line: line)
        XCTAssertEqual(r.mid, expected.2, "mid for \(s)", file: file, line: line)
    }

    func test_parseRepsRange_hyphen() { assertRange("8-10", (8, 10, 9)) }
    func test_parseRepsRange_comma() { assertRange("8,10", (8, 10, 9)) }
    func test_parseRepsRange_ili() { assertRange("8 или 10", (8, 10, 9)) }
    func test_parseRepsRange_or() { assertRange("8 or 10", (8, 10, 9)) }
    func test_parseRepsRange_singleNumber() { assertRange("12", (12, 12, 12)) }
    func test_parseRepsRange_openEnded() { assertRange("8+", (8, 13, 10)) }
    func test_parseRepsRange_amrapAnyCase() {
        assertRange("AMRAP", (0, 50, 25))
        assertRange("amrap", (0, 50, 25))
    }
    func test_parseRepsRange_unparsable_returnsNil() {
        assertRange("", (nil, nil, nil))
        assertRange("до отказа", (nil, nil, nil))
    }

    // MARK: - reps threshold scales to the target range (Fix P)

    func test_detectDeviation_repsMissWithinRelativeBand_onWideRange() {
        // 15-20 (mid 17) → band = max(2, round(17*0.30)=5) = 5. A ±3 miss (14)
        // is inside the band, so no reps deviation. weight nil ⇒ weight rule
        // skipped, so the result is purely the reps decision.
        let ex = mkExercise(reps: "15-20", weight: nil)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 14, actualWeight: 0, actualRir: 2, exercise: ex)
        XCTAssertTrue(d.isEmpty)
    }

    func test_detectDeviation_repsMissBeyondRelativeBand_onNarrowRange() {
        // 6-8 (mid 7) → band = max(2, round(7*0.30)=2) = 2. A ±3 miss (4) is
        // outside the band → repsUnder. Same ±3 that stayed quiet above fires
        // here because the range is tighter.
        let ex = mkExercise(reps: "6-8", weight: nil)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 4, actualWeight: 0, actualRir: 2, exercise: ex)
        XCTAssertEqual(d.map(\.kind), [.repsUnder])
    }

    // MARK: - strict tolerance boundary (Fix Q)

    func test_detectDeviation_repsExactlyAtThreshold_notFlagged() {
        // 8-10 (mid 9) → band 3. actualReps 6 is exactly 3 below: the strict
        // `>` keeps it on-plan where a non-strict `>=` would have flagged it.
        // weight nil isolates the reps decision.
        let ex = mkExercise(reps: "8-10", weight: nil)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 6, actualWeight: 0, actualRir: 2, exercise: ex)
        XCTAssertTrue(d.isEmpty)
    }

    func test_detectDeviation_weightAtFifteenPercent_withinTolerance() {
        // A set right at the 15% line is on-plan under the strict comparison —
        // the 0.5 kg wheel shouldn't tip a boundary set into a call-out.
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 9, actualWeight: 115, actualRir: 2, exercise: ex)
        XCTAssertTrue(d.isEmpty)
    }

    // MARK: - too_easy intensity gating (Fix Q)

    func test_detectDeviation_tooEasy_suppressedOnLightWeek() {
        // rir ≥ 4 on a light / deload week is expected, not a signal.
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 9, actualWeight: 100, actualRir: 4,
                                                   exercise: ex, intensityLabel: "лёгкая")
        XCTAssertTrue(d.isEmpty)
    }

    func test_detectDeviation_tooEasy_firesOnHeavyWeek() {
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 9, actualWeight: 100, actualRir: 4,
                                                   exercise: ex, intensityLabel: "тяжёлая")
        XCTAssertEqual(d.map(\.kind), [.tooEasy])
    }

    func test_detectDeviation_failure_firesEvenOnLightWeek() {
        // Failure (rir=0) always matters — even on a deload week.
        let ex = mkExercise(reps: "8-10", weight: 100)
        let d = WorkoutRunnerLogic.detectDeviation(actualReps: 9, actualWeight: 100, actualRir: 0,
                                                   exercise: ex, intensityLabel: "лёгкая")
        XCTAssertEqual(d.map(\.kind), [.failure])
    }

    func test_isLightWeek_matchesRussianVariants() {
        XCTAssertTrue(WorkoutRunnerLogic.isLightWeek("Лёгкая"))
        XCTAssertTrue(WorkoutRunnerLogic.isLightWeek("легкая неделя"))
        XCTAssertFalse(WorkoutRunnerLogic.isLightWeek("тяжёлая"))
        XCTAssertFalse(WorkoutRunnerLogic.isLightWeek(nil))
    }
}
