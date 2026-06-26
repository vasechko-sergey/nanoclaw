import Foundation
import Combine

/// Owns the live state of an in-progress workout. UI binds to its @Published
/// properties; the Coordinator persists every logged set via SetLogQueue and
/// hands the final WorkoutSession back when complete().
///
/// Lifecycle: created with a fresh WorkoutPlan + queue. Caller drives via
/// logSet() and finishExercise(); complete() produces the canonical session
/// payload the transport sends in `workout_complete`.
@MainActor
final class WorkoutCoordinator: ObservableObject {
    @Published private(set) var plan: WorkoutPlan
    @Published private(set) var currentExerciseIdx: Int = 0
    @Published private(set) var currentSetIdx: Int = 0
    @Published private(set) var logged: [LoggedExercise]
    @Published private(set) var lastRepsInReserve: Int = -1
    @Published private(set) var isFinished: Bool = false

    private let queue: SetLogQueue
    private let startedAt: Date

    init(plan: WorkoutPlan, queue: SetLogQueue, startedAt: Date = Date()) {
        self.plan = plan
        self.queue = queue
        self.startedAt = startedAt
        self.logged = plan.exercises.map {
            LoggedExercise(exerciseSlug: $0.exerciseSlug, sets: [], comment: nil)
        }
    }

    // MARK: - Derived

    var currentExercise: ExercisePlan {
        plan.exercises[currentExerciseIdx]
    }

    var loggedForCurrentExercise: [LoggedSet] {
        logged[currentExerciseIdx].sets
    }

    var totalExercises: Int { plan.exercises.count }

    /// True when the user just finished the last exercise of the last set
    /// — UI can switch the "Финиш" button to primary action.
    var readyToComplete: Bool {
        currentExerciseIdx >= plan.exercises.count - 1
            && currentSetIdx >= plan.exercises[currentExerciseIdx].targetSets
    }

    // MARK: - Mutations

    /// Log one set; enqueue for delivery; advance set index.
    func logSet(reps: Int, weight: Double, repsInReserve: Int, ts: Date = Date()) {
        guard !isFinished, currentExerciseIdx < plan.exercises.count else { return }
        let event = SetLogEvent(
            workoutId: plan.workoutId,
            exerciseSlug: currentExercise.exerciseSlug,
            setIdx: currentSetIdx,
            reps: reps,
            weight: weight,
            repsInReserve: repsInReserve,
            ts: ts
        )
        try? queue.enqueue(event)
        logged[currentExerciseIdx].sets.append(
            LoggedSet(reps: reps, weight: weight, repsInReserve: repsInReserve, ts: ts)
        )
        lastRepsInReserve = repsInReserve
        currentSetIdx += 1
    }

    /// Mark current exercise done and advance — or signal end of workout.
    func finishExercise(comment: String?) {
        guard !isFinished, currentExerciseIdx < plan.exercises.count else { return }
        logged[currentExerciseIdx].comment = comment
        if currentExerciseIdx + 1 < plan.exercises.count {
            currentExerciseIdx += 1
            currentSetIdx = 0
        } else {
            // Stay on last exercise; UI shows "финиш" button.
            currentSetIdx = plan.exercises[currentExerciseIdx].targetSets
        }
    }

    /// Switch the active exercise (free order — e.g. machine busy). Resumes the
    /// target exercise's set count so logging continues where it left off.
    func activate(idx: Int) {
        guard !isFinished, plan.exercises.indices.contains(idx) else { return }
        currentExerciseIdx = idx
        currentSetIdx = logged[idx].sets.count
    }

    /// Produce the final WorkoutSession payload for `workout_complete`.
    func complete(perceivedOverallRir: Int, healthSignalAtStart: String? = nil) -> WorkoutSession {
        isFinished = true
        return WorkoutSession(
            workoutId: plan.workoutId,
            date: Self.dateFormatter.string(from: startedAt),
            dayName: plan.dayName,
            week: plan.week,
            startedAt: startedAt,
            finishedAt: Date(),
            exercises: logged,
            perceivedOverallRir: perceivedOverallRir,
            healthSignalAtStart: healthSignalAtStart
        )
    }

    /// Abort without producing a final session — UI uses this for ✕ → confirm → abort.
    /// In-flight queue entries stay queued; transport drains them anyway and
    /// the server reconciles via workout_id.
    func abort() {
        isFinished = true
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
