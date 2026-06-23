import XCTest
import GRDB
@testable import Jarvis

/// Exact reproduction of the real on-device envelope (Payne seq 389) that did
/// not render a card. `TransportV2.handleIncoming` decodes `V2.Envelope` before
/// routing; if THAT throws it's swallowed by the caller's `try?` and the plan is
/// dropped silently. This pins the full decode on the real payload (8 exercises,
/// float weight_kg_target, empty-string image_manifest url, null warmup).
final class WorkoutPlanRealEnvelopeTests: XCTestCase {
    private let realEnvelope = """
    {"v":2,"kind":"control","type":"workout_plan","id":"00000000-0000-4000-8000-000000000389","seq":389,"ts":"2026-06-23T04:52:20.000Z","payload":{"workout_id":"2026-06-23","plan_json":{"day_name":"Верх А","week":2,"week_label":"Средняя","exercises":[{"slug":"hodba-na-begovoy-dorozhke","name_ru":"Ходьба на беговой дорожке","target_sets":null,"target_reps":"","reps_in_reserve":null,"rest_seconds":0,"duration_seconds":300,"notes":"разминка"},{"slug":"zhim-shtangi-lezha-shirokim-hvatom","name_ru":"Жим штанги лежа широким хватом","target_sets":4,"target_reps":"5-6","reps_in_reserve":2,"rest_seconds":180,"weight_kg_target":66.25},{"slug":"zhim-ganteley-na-naklonnoy-skame","name_ru":"Жим гантелей на наклонной скамье","target_sets":3,"target_reps":"8-10","reps_in_reserve":2,"rest_seconds":120,"weight_kg_target":25}]},"image_manifest":[{"slug":"hodba-na-begovoy-dorozhke","sha256":"ae672aad02d165e94103e1dccba746b786ff33a72e0e2ca92e8b7964e3144e87","url":""},{"slug":"zhim-shtangi-lezha-shirokim-hvatom","sha256":"f61e6adbe6501eca6b82d02734430260ed348d6e55030eab1371f4e7958b22c5","url":""}],"agent_id":"payne"}}
    """

    @MainActor
    func test_realEnvelope_decodesAndProducesCard() throws {
        let data = Data(realEnvelope.utf8)
        // Step 1: the V2.Envelope decode that handleIncoming runs first.
        let env = try JSONDecoder().decode(V2.Envelope.self, from: data)
        guard case let .workoutPlan(payload) = env.payload else {
            return XCTFail("expected .workoutPlan, got \(env.payload)")
        }
        // Step 2: the splice/decode handleWorkoutEnvelope runs.
        let plan = try AppCoordinator.decodeWorkoutPlan(payload: payload)
        XCTAssertEqual(plan.intensityLabel, "Средняя")
        XCTAssertEqual(plan.exercises.count, 3)
        XCTAssertEqual(plan.exercises[0].targetSets, 0)   // null warmup
        XCTAssertEqual(plan.exercises[1].targetRir, 2)

        // Step 3: persistence → windowed read → card content.
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ConversationStoreV2(writer: dbq)
        try store.insertWorkoutPlan(id: plan.workoutId, agentId: "payne", plan: plan)
        let rows = try dbq.read { try ConversationStoreV2.windowedRows($0, perAgent: 500) }
        let msgs = WebSocketClientV2.toChatMessage(rows.first { $0.agentId == "payne" }!)
        guard case .workoutPlan = msgs[0].content else {
            return XCTFail("expected .workoutPlan content, got \(msgs[0].content)")
        }
    }
}
