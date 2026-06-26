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

    func test_restHint_nextExerciseWhenSetsDone() {
        XCTAssertEqual(WorkoutRunnerLogic.restHint(setsDone: 2, targetSets: 4, nextExerciseName: "Тяга"), "подход 3")
        XCTAssertEqual(WorkoutRunnerLogic.restHint(setsDone: 4, targetSets: 4, nextExerciseName: "Тяга"), "Тяга")
        XCTAssertEqual(WorkoutRunnerLogic.restHint(setsDone: 4, targetSets: 4, nextExerciseName: nil), "подход 5")
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

    func test_progressSegments_activeShowsSetsAndPreviewMark() {
        let segs = WorkoutRunnerLogic.progressSegments(
            total: 3, activeIdx: 1, setsDone: 2, targetSets: 4, previewIdx: 2)
        XCTAssertEqual(segs[0].kind, .doneExercise)
        XCTAssertEqual(segs[1].kind, .activeSets(done: 2, total: 4))
        XCTAssertEqual(segs[2].kind, .upcoming)
        XCTAssertTrue(segs[2].isPreview)
        XCTAssertFalse(segs[1].isPreview)
    }
}
