import XCTest
@testable import Jarvis

final class WorkoutPreviewUpdateTests: XCTestCase {
    private func ex(_ slug: String) -> ExercisePlan {
        ExercisePlan(exerciseSlug: slug, targetSets: 3, targetReps: "5", targetRir: 2, restSec: 90)
    }
    private func plan(id: String, _ slugs: [String]) -> WorkoutPlan {
        WorkoutPlan(workoutId: id, dayName: "D", week: 1, intensityLabel: "L",
                    exercises: slugs.map(ex), imageManifest: [])
    }

    func test_matchingWorkoutId_replacesPlanAndKeepsPage() {
        let cur = plan(id: "w1", ["a", "b", "c"])
        let inc = plan(id: "w1", ["a", "x", "c"])
        let r = WorkoutPreviewUpdate.apply(current: cur, incoming: inc, page: 1)
        XCTAssertEqual(r.plan.exercises[1].exerciseSlug, "x")
        XCTAssertEqual(r.page, 1)
    }

    func test_nonMatchingWorkoutId_isIgnored() {
        let cur = plan(id: "w1", ["a", "b"])
        let inc = plan(id: "w2", ["z"])
        let r = WorkoutPreviewUpdate.apply(current: cur, incoming: inc, page: 1)
        XCTAssertEqual(r.plan.workoutId, "w1")
        XCTAssertEqual(r.page, 1)
    }

    func test_pageClampsWhenIncomingHasFewerExercises() {
        let cur = plan(id: "w1", ["a", "b", "c"])
        let inc = plan(id: "w1", ["a"])
        let r = WorkoutPreviewUpdate.apply(current: cur, incoming: inc, page: 2)
        XCTAssertEqual(r.plan.exercises.count, 1)
        XCTAssertEqual(r.page, 0)
    }
}
