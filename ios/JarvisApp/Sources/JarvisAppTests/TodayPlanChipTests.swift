import XCTest
@testable import Jarvis

/// Payne's "plan for today" chip: ask the runner for today's card when there is
/// none, open today's card when it's there, stay out of the way once the
/// workout is done.
final class TodayPlanChipTests: XCTestCase {
    private func plan(_ workoutId: String) -> WorkoutPlan {
        WorkoutPlan(
            workoutId: workoutId, dayName: "Ноги А", week: 3, intensityLabel: "тяжёлая",
            exercises: [ExercisePlan(exerciseSlug: "zhim-nogami", targetSets: 4, targetReps: "8-10",
                                     targetRir: 0, restSec: 180, notes: nil)],
            imageManifest: []
        )
    }

    private func card(_ id: String, workoutId: String, done: Bool = false) -> ChatMessage {
        ChatMessage(id: id, role: .assistant,
                    content: .workoutPlan(WorkoutPlanCardInfo(plan: plan(workoutId), done: done)),
                    timestamp: Date())
    }

    private func text(_ id: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: .text("Готово"), timestamp: Date())
    }

    func test_noCardForToday_requestsOne() {
        XCTAssertEqual(TodayPlanChip.state(messages: [text("m1")], today: "2026-10-02"), .request)
    }

    func test_yesterdaysCard_stillRequestsToday() {
        let messages = [card("c1", workoutId: "2026-10-01")]
        XCTAssertEqual(TodayPlanChip.state(messages: messages, today: "2026-10-02"), .request)
    }

    func test_todaysCard_opensIt() {
        let messages = [text("m1"), card("c2", workoutId: "2026-10-02"), text("m3")]
        XCTAssertEqual(TodayPlanChip.state(messages: messages, today: "2026-10-02"),
                       .open(plan: plan("2026-10-02"), messageId: "c2"))
    }

    func test_todaysWorkoutDone_hidesTheChip() {
        let messages = [card("c2", workoutId: "2026-10-02", done: true), text("m3")]
        XCTAssertEqual(TodayPlanChip.state(messages: messages, today: "2026-10-02"), .hidden)
    }

    func test_latestCardForToday_wins() {
        let messages = [card("c1", workoutId: "2026-10-02", done: true), card("c2", workoutId: "2026-10-02")]
        XCTAssertEqual(TodayPlanChip.state(messages: messages, today: "2026-10-02"),
                       .open(plan: plan("2026-10-02"), messageId: "c2"))
    }

    func test_localDate_isTheDeviceCalendarDay() {
        // 2026-10-02T02:50:41Z — 10:50 in Bali, still Oct 1 in Los Angeles.
        let instant = Date(timeIntervalSince1970: 1_790_909_441)
        XCTAssertEqual(TodayPlanChip.localDate(instant, timeZone: TimeZone(identifier: "Asia/Makassar")!), "2026-10-02")
        XCTAssertEqual(TodayPlanChip.localDate(instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!), "2026-10-01")
    }

    func test_paynesStarter_asksForThePlan_othersSayText() {
        XCTAssertEqual(AgentIdentity.payne.suggestions.first?.action, .todayPlan)
        XCTAssertTrue(AgentIdentity.jarvis.suggestions.allSatisfy { $0.action == .say })
    }
}
