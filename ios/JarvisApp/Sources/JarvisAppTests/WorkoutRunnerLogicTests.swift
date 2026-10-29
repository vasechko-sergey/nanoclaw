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

    /// 2026-09-28: Payne prescribed −5 for pull-ups; the wheel (0…300) showed 0
    /// but held −5, and three sets went to the log at −5 untouched.
    func test_wheelSeed_staysOnTheWheel() {
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: -10, lastLogged: nil), 0)
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: nil, lastLogged: -5), 0)
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: 400, lastLogged: nil), 300)
        XCTAssertEqual(WorkoutRunnerLogic.wheelWeight(-5), 0)
        XCTAssertEqual(WorkoutRunnerLogic.wheelWeight(47.3), 47.5)
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

    // MARK: - What comes next after leaving the plan order

    private func ex(_ name: String, sets: Int) -> ExercisePlan {
        ExercisePlan(exerciseSlug: name, targetSets: sets, targetReps: "10-12", targetRir: 2,
                     restSec: 90, notes: nil, nameRu: name)
    }

    private func done(_ name: String, _ n: Int) -> LoggedExercise {
        LoggedExercise(exerciseSlug: name,
                       sets: (0..<n).map { _ in LoggedSet(reps: 10, weight: 20, repsInReserve: 2, ts: Date()) },
                       comment: nil)
    }

    /// 2026-10-19, Верх А: Хаммер, then the vertical pull ahead of Смит and the
    /// row (machines busy). Every rest on the pull said «Дальше: Смит» — the scan
    /// ran from the top of the plan, not from the exercise in hand.
    func test_restHint_afterJumpingAhead_continuesThePlan() {
        let exs = [ex("Хаммер", sets: 3), ex("Смит", sets: 1), ex("Тяга гориз", sets: 2),
                   ex("Тяга верт", sets: 1), ex("Разгибание", sets: 2)]
        let logged = [done("Хаммер", 3), done("Смит", 0), done("Тяга гориз", 0),
                      done("Тяга верт", 1), done("Разгибание", 0)]
        XCTAssertEqual(WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 3),
                       "Разгибание — подход 1")
        XCTAssertEqual(WorkoutRunnerLogic.skippedHint(logged: logged, exercises: exs, activeIdx: 3),
                       "пропущено: Смит, Тяга гориз")
        XCTAssertEqual(WorkoutRunnerLogic.nextExerciseIdx(logged: logged, exercises: exs, activeIdx: 3), 4)
    }

    /// Back on a skipped exercise: the ones already done ahead of it are passed
    /// over — «Дальше →» from Смит went to the row, done twenty minutes earlier.
    func test_nextExercise_passesOverDoneOnes() {
        let exs = [ex("Смит", sets: 1), ex("Тяга гориз", sets: 2), ex("Тяга верт", sets: 1), ex("Разгибание", sets: 2)]
        let logged = [done("Смит", 2), done("Тяга гориз", 2), done("Тяга верт", 3), done("Разгибание", 0)]
        XCTAssertEqual(WorkoutRunnerLogic.nextExerciseIdx(logged: logged, exercises: exs, activeIdx: 0), 3)
        XCTAssertNil(WorkoutRunnerLogic.skippedHint(logged: logged, exercises: exs, activeIdx: 0))
    }

    /// Nothing left ahead: the earliest skipped one becomes «Дальше», the rest
    /// stay listed as skipped.
    func test_nextExercise_nothingAhead_wrapsToEarliestSkipped() {
        let exs = [ex("A", sets: 2), ex("B", sets: 2), ex("C", sets: 2)]
        let logged = [done("A", 0), done("B", 1), done("C", 2)]
        XCTAssertEqual(WorkoutRunnerLogic.nextExerciseIdx(logged: logged, exercises: exs, activeIdx: 2), 0)
        XCTAssertEqual(WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 2), "A — подход 1")
        XCTAssertEqual(WorkoutRunnerLogic.skippedHint(logged: logged, exercises: exs, activeIdx: 2), "пропущено: B")
    }

    /// A warmup walked past is not skipped work, and nothing left means no next.
    func test_nextExercise_warmupBehindIsNotSkipped() {
        let exs = [
            ExercisePlan(exerciseSlug: "walk", targetSets: 0, targetReps: "", targetRir: 0, restSec: 0,
                         notes: nil, nameRu: "Ходьба", durationSec: 300),
            ex("A", sets: 1),
        ]
        let logged = [done("walk", 0), done("A", 1)]
        XCTAssertNil(WorkoutRunnerLogic.nextExerciseIdx(logged: logged, exercises: exs, activeIdx: 1))
        XCTAssertNil(WorkoutRunnerLogic.skippedHint(logged: logged, exercises: exs, activeIdx: 1))
        // Logged walk ahead of the cursor counts as done too.
        let walked = [LoggedExercise(exerciseSlug: "walk",
                                     sets: [LoggedSet(reps: 0, weight: 0, repsInReserve: 0, ts: Date(), durationSec: 420)],
                                     comment: nil), done("A", 0)]
        XCTAssertEqual(WorkoutRunnerLogic.nextExerciseIdx(logged: walked, exercises: exs, activeIdx: 0), 1)
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
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [3, 3, 0, 0, 0], targetSets: [3, 3, 3, 3, 3],
            isDuration: [false, false, false, false, false], activeIdx: 3, previewIdx: 3)
        XCTAssertEqual(segs.map(\.kind), [.done, .done, .skipped, .active, .upcoming])
        XCTAssertFalse(segs[3].isPreview)
    }

    func test_progressSegments_passedDurationCountsAsDone() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [0, 3, 0], targetSets: [0, 3, 3],
            isDuration: [true, false, false], activeIdx: 2, previewIdx: 2)
        XCTAssertEqual(segs.map(\.kind), [.done, .done, .active])
    }

    func test_progressSegments_workedAfterActiveStaysDone_onJumpBack() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [0, 0, 3], targetSets: [3, 3, 3],
            isDuration: [false, false, false], activeIdx: 0, previewIdx: 0)
        XCTAssertEqual(segs.map(\.kind), [.active, .upcoming, .done])
    }

    func test_progressSegments_previewMarkOnNonActive() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [3, 0, 0, 0], targetSets: [3, 3, 3, 3],
            isDuration: [false, false, false, false], activeIdx: 1, previewIdx: 3)
        XCTAssertEqual(segs.map(\.kind), [.done, .active, .upcoming, .upcoming])
        XCTAssertTrue(segs[3].isPreview)
        XCTAssertFalse(segs[1].isPreview)
    }

    /// 2026-10-29: one set of three on the press, then on to the row — the
    /// header painted the press as done.
    func test_progressSegments_oneOfThreeIsPartial_aThirdFilled() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [3, 1, 0, 0], targetSets: [3, 3, 3, 2],
            isDuration: [false, false, false, false], activeIdx: 2, previewIdx: 2)
        XCTAssertEqual(segs.map(\.kind), [.done, .partial, .active, .upcoming])
        XCTAssertEqual(segs[1].fill, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(segs[0].fill, 1)
        XCTAssertEqual(segs[2].fill, 0)
    }

    func test_progressSegments_partialAheadOfActive_andBonusIsDone() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [4, 0, 2], targetSets: [3, 3, 4],
            isDuration: [false, false, false], activeIdx: 1, previewIdx: 1)
        XCTAssertEqual(segs.map(\.kind), [.done, .active, .partial])
        XCTAssertEqual(segs[2].fill, 0.5, accuracy: 0.0001)
    }

    func test_progressSegments_warmupWithAnyLoggedTimeIsDone() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [1, 0], targetSets: [0, 3], isDuration: [true, false], activeIdx: 1, previewIdx: 1)
        XCTAssertEqual(segs[0].kind, .done)
    }

    func test_previewStateTag() {
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 0, targetSets: 3), "ещё не начато")
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 1, targetSets: 3), "1 из 3 подходов")
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 3, targetSets: 21), "3 из 21 подхода")
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 3, targetSets: 3), "пройдено")
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 1, targetSets: 0), "пройдено")
    }

    func test_holdTitle() {
        XCTAssertEqual(WorkoutRunnerLogic.holdTitle(name: "Планка", isTimedSets: true, setIdx: 0), "ПЛАНКА · ПОДХОД 1")
        XCTAssertEqual(WorkoutRunnerLogic.holdTitle(name: "Ходьба на беговой дорожке", isTimedSets: false, setIdx: 0),
                       "ХОДЬБА НА БЕГОВОЙ ДОРОЖКЕ")
    }

    func test_holdCaption() {
        XCTAssertEqual(WorkoutRunnerLogic.holdCaption(target: 60, elapsed: 42), "цель 1:00")
        XCTAssertEqual(WorkoutRunnerLogic.holdCaption(target: 60, elapsed: 60), "цель есть · +0:00")
        XCTAssertEqual(WorkoutRunnerLogic.holdCaption(target: 60, elapsed: 67), "цель есть · +0:07")
        XCTAssertNil(WorkoutRunnerLogic.holdCaption(target: 0, elapsed: 30))
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

    func test_techniqueLabel() {
        XCTAssertEqual(TechniqueRow.label(steps: 1), "Техника · 1 шаг")
        XCTAssertEqual(TechniqueRow.label(steps: 3), "Техника · 3 шага")
        XCTAssertEqual(TechniqueRow.label(steps: 5), "Техника · 5 шагов")
        XCTAssertEqual(TechniqueRow.label(steps: 0), "Техника")
    }

    func test_isLightWeek_matchesRussianVariants() {
        XCTAssertTrue(WorkoutRunnerLogic.isLightWeek("Лёгкая"))
        XCTAssertTrue(WorkoutRunnerLogic.isLightWeek("легкая неделя"))
        XCTAssertFalse(WorkoutRunnerLogic.isLightWeek("тяжёлая"))
        XCTAssertFalse(WorkoutRunnerLogic.isLightWeek(nil))
    }
}
