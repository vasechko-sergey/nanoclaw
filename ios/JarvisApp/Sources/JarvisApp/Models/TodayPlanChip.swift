import Foundation

/// What Payne's `/workout` does right now — a pure function of the chat, so it
/// is testable without a view. (It once drove a chip above the input; the chip
/// is gone, the name stayed.)
///
/// - No plan card for today → ask for one. `workout_start_request` is answered
///   by the agent runner itself (scripts/build-plan.js + Greg's readiness), with
///   no model turn, so the card lands in seconds.
/// - Today's card is there and not done → open it, exactly like its own button.
/// - Today's workout is done → nothing to offer.
enum TodayPlanChip: Equatable {
    case request
    case open(plan: WorkoutPlan, messageId: String)
    case hidden

    /// The latest plan card for `today` (a `workoutId` is the plan's date) decides.
    static func state(messages: [ChatMessage], today: String) -> TodayPlanChip {
        for message in messages.reversed() {
            guard case .workoutPlan(let info) = message.content, info.plan.workoutId == today else { continue }
            return info.done ? .hidden : .open(plan: info.plan, messageId: message.id)
        }
        return .request
    }

    /// The device-local calendar date as YYYY-MM-DD — the `date` a
    /// `workout_start_request` carries. Gregorian + POSIX: a phone set to the
    /// Buddhist or Japanese calendar must not send "2569-10-02".
    static func localDate(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
