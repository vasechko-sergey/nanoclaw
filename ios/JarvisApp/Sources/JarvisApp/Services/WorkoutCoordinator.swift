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
    private let store: ActiveWorkoutStore?
    private let agentId: String?
    private let messageId: String?

    init(plan: WorkoutPlan, queue: SetLogQueue, startedAt: Date = Date(),
         store: ActiveWorkoutStore? = nil, agentId: String? = nil, messageId: String? = nil) {
        self.plan = plan
        self.queue = queue
        self.startedAt = startedAt
        self.logged = plan.exercises.map {
            LoggedExercise(exerciseSlug: $0.exerciseSlug, sets: [], comment: nil)
        }
        self.store = store
        self.agentId = agentId
        self.messageId = messageId
    }

    /// Restore a coordinator from a persisted `ActiveWorkoutRecord` — kill/crash
    /// resume lands the user back at the exact set/exercise/logged state.
    ///
    /// `startedAt` reads from the cursor first — `updatedAt` is the last save
    /// wallclock, not the workout start, so a paused session that ran for a
    /// while and got restored would otherwise report a fake `session.duration`.
    /// Cursors saved before `startedAt` was added fall back to `updatedAt`.
    init(restoring record: ActiveWorkoutRecord, queue: SetLogQueue, store: ActiveWorkoutStore) {
        self.plan = record.plan
        self.queue = queue
        self.startedAt = record.cursor.startedAt ?? record.updatedAt
        self.logged = record.cursor.logged
        self.currentExerciseIdx = record.cursor.currentExerciseIdx
        self.currentSetIdx = record.cursor.currentSetIdx
        self.store = store
        self.agentId = record.agentId
        self.messageId = record.messageId
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
        let devs = WorkoutRunnerLogic.detectDeviation(
            actualReps: reps, actualWeight: weight, actualRir: repsInReserve,
            exercise: currentExercise
        )
        let event = SetLogEvent(
            workoutId: plan.workoutId,
            exerciseSlug: currentExercise.exerciseSlug,
            setIdx: currentSetIdx,
            reps: reps,
            weight: weight,
            repsInReserve: repsInReserve,
            ts: ts,
            deviations: devs
        )
        try? queue.enqueue(event)
        logged[currentExerciseIdx].sets.append(
            LoggedSet(reps: reps, weight: weight, repsInReserve: repsInReserve, ts: ts, deviations: devs)
        )
        lastRepsInReserve = repsInReserve
        currentSetIdx += 1
        persist()
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
        persist()
    }

    /// Switch the active exercise (free order — e.g. machine busy). Resumes the
    /// target exercise's set count so logging continues where it left off.
    func activate(idx: Int) {
        guard !isFinished, plan.exercises.indices.contains(idx) else { return }
        currentExerciseIdx = idx
        currentSetIdx = logged[idx].sets.count
        persist()
    }

    /// Attach a coach reply to a specific already-logged set, keyed by
    /// exercise slug + set index (from `CoachMessage.set_ref`). A missing
    /// exercise or out-of-range setIdx (stale/racing reply) is a no-op rather
    /// than a crash. Persists so the hint survives a kill.
    ///
    /// After `complete()`/`abort()` this is a no-op — a late coach message
    /// on a finished workout would otherwise re-create an `active_workout`
    /// row and resurrect a zombie "Продолжить" card on next launch.
    ///
    /// Fix N: belt-and-suspenders fallback for the race window where Payne's
    /// coach reply references the NEW slug (from an accepted swap) but the
    /// local `applySwap` hasn't run yet. Falls back to `currentExerciseIdx`
    /// only when `setIdx` fits — the primary fix is to call `applySwap` on
    /// user confirm so this branch stays a rare backstop.
    func attachCoachHint(exerciseSlug: String, setIdx: Int, text: String) {
        guard !isFinished else { return }
        let exIdx: Int
        if let found = plan.exercises.firstIndex(where: { $0.exerciseSlug == exerciseSlug }) {
            exIdx = found
        } else if plan.exercises.indices.contains(currentExerciseIdx),
                  logged[currentExerciseIdx].sets.indices.contains(setIdx) {
            // TODO: remove once server-side swap-apply is guaranteed to precede
            // any coach_message that references the new slug (Fix N context).
            exIdx = currentExerciseIdx
        } else {
            return
        }
        guard logged[exIdx].sets.indices.contains(setIdx) else { return }
        logged[exIdx].sets[setIdx].coachHint = text
        persist()
    }

    /// Fix N: fold an accepted exercise swap into the local plan + logged so
    /// future `coach_message.set_ref.exercise_slug` (which will reference the
    /// NEW slug once Payne accepts) still resolves via `attachCoachHint`.
    ///
    /// Rebuilds the ExercisePlan / LoggedExercise at the matching index rather
    /// than mutating fields (both `exerciseSlug` are `let`). Copies over all
    /// other fields so weights / target reps / logged sets survive the swap.
    /// No-op if the workout is finished or the slug isn't in the plan (e.g.
    /// swap arrived for an already-swapped exercise).
    func applySwap(originalSlug: String, newSlug: String) {
        guard !isFinished else { return }
        guard let idx = plan.exercises.firstIndex(where: { $0.exerciseSlug == originalSlug }) else { return }
        guard originalSlug != newSlug else { return }
        let old = plan.exercises[idx]
        let replaced = ExercisePlan(
            exerciseSlug: newSlug,
            targetSets: old.targetSets,
            targetReps: old.targetReps,
            targetRir: old.targetRir,
            restSec: old.restSec,
            notes: old.notes,
            nameRu: old.nameRu,
            durationSec: old.durationSec,
            weightKgTarget: old.weightKgTarget
        )
        var newExercises = plan.exercises
        newExercises[idx] = replaced
        plan = WorkoutPlan(
            workoutId: plan.workoutId,
            dayName: plan.dayName,
            week: plan.week,
            intensityLabel: plan.intensityLabel,
            exercises: newExercises,
            imageManifest: plan.imageManifest
        )
        let oldLogged = logged[idx]
        logged[idx] = LoggedExercise(exerciseSlug: newSlug, sets: oldLogged.sets, comment: oldLogged.comment)
        persist()
    }

    /// Produce the final WorkoutSession payload for `workout_complete`.
    func complete(sessionFeeling: Int, sessionFeelingLabel: String, healthSignalAtStart: String? = nil) -> WorkoutSession {
        isFinished = true
        if let store, let agentId { try? store.clear(agentId: agentId) }
        return WorkoutSession(
            workoutId: plan.workoutId,
            date: Self.dateFormatter.string(from: startedAt),
            dayName: plan.dayName,
            week: plan.week,
            startedAt: startedAt,
            finishedAt: Date(),
            exercises: logged,
            perceivedOverallRir: nil,
            healthSignalAtStart: healthSignalAtStart,
            sessionFeeling: sessionFeeling,
            sessionFeelingLabel: sessionFeelingLabel
        )
    }

    /// Abort without producing a final session — UI uses this for ✕ → confirm → abort.
    /// In-flight queue entries stay queued; transport drains them anyway and
    /// the server reconciles via workout_id.
    func abort() {
        isFinished = true
        if let store, let agentId { try? store.clear(agentId: agentId) }
    }

    // MARK: - Helpers

    private func persist() {
        guard let store, let agentId, let messageId else { return }
        let cursor = WorkoutCursor(
            currentExerciseIdx: currentExerciseIdx,
            currentSetIdx: currentSetIdx,
            logged: logged,
            startedAt: startedAt
        )
        try? store.save(agentId: agentId, workoutId: plan.workoutId,
                        plan: plan, cursor: cursor, messageId: messageId)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
