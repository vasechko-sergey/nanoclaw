import XCTest
import GRDB
@testable import Jarvis

/// Integration: a persisted workout plan must surface through the SAME windowed
/// query the chat UI observes (`windowedRows`) AND map to a `.workoutPlan` card
/// via `toChatMessage`. The per-task unit tests covered insert + map in
/// isolation; this pins the chain the device actually runs (insert → timeline
/// read → content), which is where a missing read-path field would hide.
final class WorkoutCardIntegrationTests: XCTestCase {
    @MainActor
    func test_insertedWorkoutPlan_surfacesAsCardThroughWindowedRead() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        let plan = WorkoutPlan(
            workoutId: "w-int", dayName: "Верх", week: 1, intensityLabel: "лёгкая",
            exercises: [ExercisePlan(exerciseSlug: "a", targetSets: 4, targetReps: "8",
                                     targetRir: 2, restSec: 90, notes: nil)],
            imageManifest: [])
        try store.insertWorkoutPlan(id: plan.workoutId, agentId: "payne", plan: plan)

        // Read via the exact query the UI's per-agent timeline observes.
        let rows = try dbq.read { try ConversationStoreV2.windowedRows($0, perAgent: 500) }
        let payne = rows.filter { $0.agentId == "payne" }
        XCTAssertEqual(payne.count, 1, "card row must be in the windowed timeline")
        XCTAssertNotNil(payne.first?.workoutPlanJSON, "windowed read must carry workout_plan_json")

        let msgs = WebSocketClientV2.toChatMessage(payne[0])
        XCTAssertEqual(msgs.count, 1)
        guard case .workoutPlan(let info) = msgs[0].content else {
            return XCTFail("expected .workoutPlan, got \(msgs[0].content)")
        }
        XCTAssertEqual(info.plan.workoutId, "w-int")
        XCTAssertEqual(info.plan.exercises.count, 1)
    }

    /// Finishing a workout must resolve its card by `workout_id`, NOT the card's
    /// row id — the runner's presentation can lose its messageId (mid-workout
    /// swap), which left the card tappable even after a completed workout. Row
    /// ids here are deliberately DIFFERENT from the workout ids to prove the
    /// match is on the decoded plan, and an unrelated card must stay active.
    @MainActor
    func test_markWorkoutCardDone_resolvesByWorkoutId_notRowId() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        func plan(_ wid: String, slug: String) -> WorkoutPlan {
            WorkoutPlan(workoutId: wid, dayName: "Верх", week: 1, intensityLabel: "лёгкая",
                        exercises: [ExercisePlan(exerciseSlug: slug, targetSets: 4, targetReps: "8",
                                                 targetRir: 2, restSec: 90, notes: nil)],
                        imageManifest: [])
        }
        // Row id ≠ workout id on purpose.
        try store.insertWorkoutPlan(id: "row-A", agentId: "payne", plan: plan("w-done", slug: "a"))
        try store.insertWorkoutPlan(id: "row-B", agentId: "payne", plan: plan("w-other", slug: "b"))

        func done(_ wid: String) throws -> Bool {
            let rows = try dbq.read { try ConversationStoreV2.windowedRows($0, perAgent: 500) }
            guard let row = rows.first(where: { $0.workoutPlanJSON?.contains("\"\(wid)\"") == true }),
                  case .workoutPlan(let info) = WebSocketClientV2.toChatMessage(row)[0].content else {
                XCTFail("no card for \(wid)")
                return false
            }
            return info.done
        }

        XCTAssertFalse(try done("w-done"), "card starts active")

        let marked = try store.markWorkoutCardDone(workoutId: "w-done")
        XCTAssertEqual(marked, 1, "exactly the finished workout's card is marked")

        XCTAssertTrue(try done("w-done"), "finished workout's card resolves")
        XCTAssertFalse(try done("w-other"), "unrelated card stays active")

        // Idempotent: re-marking finds nothing left open.
        XCTAssertEqual(try store.markWorkoutCardDone(workoutId: "w-done"), 0)
    }

    /// Cancelling a plan card must resolve ONLY the tapped card — even when a
    /// second card shares the same `workout_id`. Payne derives `workout_id` from
    /// the calendar date ("YYYY-MM-DD"), so two plans proposed the same day
    /// collide on it; the by-workoutId finish-matcher greys BOTH. Cancel is a
    /// per-card action (the button knows its own row id) and must key on the row.
    @MainActor
    func test_cancelWorkoutCard_byMessageId_resolvesOnlyTappedCard_sharedWorkoutId() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)

        func plan(slug: String) -> WorkoutPlan {
            WorkoutPlan(workoutId: "2026-07-31", dayName: "Верх", week: 1, intensityLabel: "лёгкая",
                        exercises: [ExercisePlan(exerciseSlug: slug, targetSets: 4, targetReps: "8",
                                                 targetRir: 2, restSec: 90, notes: nil)],
                        imageManifest: [])
        }
        // Two cards, SAME workout_id (same-day double send), DIFFERENT row ids.
        try store.insertWorkoutPlan(id: "row-A", agentId: "payne", plan: plan(slug: "a"))
        try store.insertWorkoutPlan(id: "row-B", agentId: "payne", plan: plan(slug: "b"))

        func done(rowId: String) throws -> Bool {
            let rows = try dbq.read { try ConversationStoreV2.windowedRows($0, perAgent: 500) }
            guard let row = rows.first(where: { $0.id == rowId }),
                  case .workoutPlan(let info) = WebSocketClientV2.toChatMessage(row)[0].content else {
                XCTFail("no card for \(rowId)"); return false
            }
            return info.done
        }

        let marked = try store.markWorkoutCardDone(messageId: "row-A")
        XCTAssertEqual(marked, 1, "exactly the cancelled card is marked")
        XCTAssertTrue(try done(rowId: "row-A"), "cancelled card resolves")
        XCTAssertFalse(try done(rowId: "row-B"), "sibling sharing workout_id stays active")

        // Idempotent: re-cancelling the same card finds nothing open.
        XCTAssertEqual(try store.markWorkoutCardDone(messageId: "row-A"), 0)
    }
}
