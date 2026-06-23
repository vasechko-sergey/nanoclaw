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
}
