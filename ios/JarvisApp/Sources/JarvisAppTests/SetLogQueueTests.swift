import XCTest
import GRDB
@testable import Jarvis

final class SetLogQueueTests: XCTestCase {

    private func makeQueue() throws -> SetLogQueue {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        return SetLogQueue(writer: dbq)
    }

    private func sample(workout: String = "w1", setIdx: Int, reps: Int = 10, rir: Int = 2) -> SetLogEvent {
        SetLogEvent(
            workoutId: workout,
            exerciseSlug: "incline-db-press",
            setIdx: setIdx,
            reps: reps,
            weight: 22.5,
            repsInReserve: rir,
            ts: Date()
        )
    }

    func test_enqueue_drainsInOrder() throws {
        let q = try makeQueue()
        try q.enqueue(sample(setIdx: 0))
        try q.enqueue(sample(setIdx: 1))
        try q.enqueue(sample(setIdx: 2))
        let pending = try q.pending()
        XCTAssertEqual(pending.map(\.event.setIdx), [0, 1, 2])
    }

    func test_markDelivered_removesFromPending() throws {
        let q = try makeQueue()
        try q.enqueue(sample(setIdx: 0))
        let row = try XCTUnwrap(q.pending().first)
        try q.markDelivered(localId: row.localId)
        XCTAssertEqual(try q.pending().count, 0)
    }

    func test_multipleWorkouts_orderedDeterministically() throws {
        let q = try makeQueue()
        try q.enqueue(sample(workout: "w2", setIdx: 0))
        try q.enqueue(sample(workout: "w1", setIdx: 1))
        try q.enqueue(sample(workout: "w1", setIdx: 0))
        let pending = try q.pending()
        // Ordered by workout_id ASC, set_idx ASC.
        XCTAssertEqual(pending.map { "\($0.event.workoutId):\($0.event.setIdx)" },
                       ["w1:0", "w1:1", "w2:0"])
    }

    func test_pruneDelivered_removesOldDelivered_keepsPending() throws {
        let q = try makeQueue()
        let now = Date()
        let oldEvent = SetLogEvent(
            workoutId: "w1", exerciseSlug: "ex", setIdx: 0,
            reps: 1, weight: 1, repsInReserve: 1,
            ts: now.addingTimeInterval(-3600)
        )
        try q.enqueue(oldEvent)
        try q.enqueue(sample(setIdx: 1))
        let pendingBefore = try q.pending()
        XCTAssertEqual(pendingBefore.count, 2)
        try q.markDelivered(localId: pendingBefore[0].localId)
        try q.pruneDelivered(olderThan: now.addingTimeInterval(-60))
        let pendingAfter = try q.pending()
        // Only the still-pending set remains.
        XCTAssertEqual(pendingAfter.map(\.event.setIdx), [1])
    }
}
