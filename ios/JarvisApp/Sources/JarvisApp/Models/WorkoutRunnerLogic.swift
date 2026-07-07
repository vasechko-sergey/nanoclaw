import Foundation

/// Pure, view-independent logic for the workout runner. Kept out of the SwiftUI
/// views so it can be unit-tested without a host app or simulator.
enum WorkoutRunnerLogic {

    /// Reps-in-reserve choices offered as buttons (3 omitted — too granular to
    /// feel reliably).
    static let rirButtons = [0, 1, 2, 4]

    /// Snap Payne's target RIR to the nearest available button value.
    /// Ties resolve to the lower value (`min(by:)` keeps the first).
    static func snapRir(_ target: Int) -> Int {
        rirButtons.min(by: { abs($0 - target) < abs($1 - target) }) ?? 2
    }

    /// Wheel weight step (kg).
    static let weightStep = 0.5

    /// Default weight for a set: Payne's target, else last logged, else 20 kg,
    /// rounded to the wheel step.
    static func defaultWeight(target: Double?, lastLogged: Double?) -> Double {
        let raw = target ?? lastLogged ?? 20
        return (raw / weightStep).rounded() * weightStep
    }

    /// All selectable wheel weights, 0…300 kg by `weightStep`.
    static let weightOptions: [Double] = Array(stride(from: 0.0, through: 300.0, by: weightStep))

    /// Index into `weightOptions` nearest a value (clamped to range).
    static func weightIndex(for w: Double) -> Int {
        let clamped = min(max(w, 0), 300)
        return Int((clamped / weightStep).rounded())
    }

    /// Position label shown under the image. `nil` for duration/warmup
    /// (`targetSets == 0`). Past the target → "бонусный подход" (no "4 из 3").
    static func setLabel(currentSetIdx: Int, targetSets: Int) -> String? {
        guard targetSets > 0 else { return nil }
        if currentSetIdx >= targetSets { return "бонусный подход" }
        return "подход \(currentSetIdx + 1) из \(targetSets)"
    }

    /// Rest-overlay "next" hint. Scans all exercises for the first unfinished
    /// set starting from the active exercise, so a skipped-then-returned-to
    /// exercise earlier in the plan is still surfaced instead of being hidden
    /// behind the active exercise's own completed sets.
    static func restHint(logged: [LoggedExercise], exercises: [ExercisePlan], activeIdx: Int) -> String {
        guard exercises.indices.contains(activeIdx), logged.indices.contains(activeIdx) else {
            return "Тренировка закончена"
        }
        let cur = exercises[activeIdx]
        let curDone = logged[activeIdx].sets.count
        if cur.targetSets > 0, curDone < cur.targetSets {
            return "подход \(curDone + 1) — \(cur.displayName)"
        }
        for i in exercises.indices where exercises[i].targetSets > 0 {
            if logged[i].sets.count < exercises[i].targetSets {
                return "\(exercises[i].displayName) — подход \(logged[i].sets.count + 1)"
            }
        }
        return "Тренировка закончена"
    }

    /// Worded 1–5 session rating (1 = tough … 5 = easy).
    static let feelings: [(value: Int, label: String)] = [
        (1, "Тяжело, еле дотянул"),
        (2, "Тяжеловато"),
        (3, "Нормально"),
        (4, "Хорошо, с запасом"),
        (5, "Легко, мог больше"),
    ]

    /// Reps wheel choices.
    static let repsOptions = Array(1...30)

    /// One cell of the top progress bar — one per exercise, equal width.
    struct ProgressSegment: Equatable {
        enum Kind: Equatable { case done, active, upcoming }
        let kind: Kind
        let isPreview: Bool
    }

    /// Equal segment per exercise: before `activeIdx` = done, at = active, after =
    /// upcoming. The previewed exercise (when ≠ active) is marked for an outline.
    /// Set-level progress lives in the image scrim, not here.
    static func progressSegments(total: Int, activeIdx: Int, previewIdx: Int) -> [ProgressSegment] {
        (0..<max(total, 1)).map { i in
            let kind: ProgressSegment.Kind = i < activeIdx ? .done : (i == activeIdx ? .active : .upcoming)
            return ProgressSegment(kind: kind, isPreview: i == previewIdx && previewIdx != activeIdx)
        }
    }

    /// "3/6" — 1-based active index over total, clamped.
    static func exerciseCounter(activeIdx: Int, total: Int) -> String {
        "\(min(activeIdx + 1, max(total, 1)))/\(max(total, 1))"
    }

    /// Tolerance beyond which a set is called out to Payne.
    static let weightDeviationPct: Double = 0.15
    static let repsDeviationAbs: Int = 3

    enum SetDeviationKind: String, Codable, Equatable {
        case weightUnder, weightOver
        case repsUnder, repsOver
        case failure       // rir == 0
        case tooEasy       // rir >= 4
    }

    struct DeviationTargetSnapshot: Codable, Equatable {
        let repsMin: Int
        let repsMax: Int
        var weight: Double?
        let rir: Int
    }

    struct SetDeviation: Codable, Equatable {
        let kind: SetDeviationKind
        /// Percentage delta for weight, absolute delta for reps, 0 for rir kinds.
        let magnitude: Double
        let target: DeviationTargetSnapshot
    }

    /// Detect deviation of an actual set against its planned exercise.
    /// Precedence: weight > reps > rir. Returns nil if within tolerance.
    static func detectDeviation(actualReps: Int, actualWeight: Double, actualRir: Int, exercise: ExercisePlan) -> SetDeviation? {
        let range = parseRepsRange(exercise.targetReps)
        let target = DeviationTargetSnapshot(
            repsMin: range.min ?? 0, repsMax: range.max ?? 0,
            weight: exercise.weightKgTarget, rir: exercise.targetRir
        )
        if let weightTarget = exercise.weightKgTarget, weightTarget > 0 {
            let delta = actualWeight / weightTarget - 1.0
            if abs(delta) >= weightDeviationPct {
                return SetDeviation(kind: delta < 0 ? .weightUnder : .weightOver, magnitude: delta, target: target)
            }
        }
        if let mid = range.mid {
            let d = actualReps - mid
            if abs(d) >= repsDeviationAbs {
                return SetDeviation(kind: d < 0 ? .repsUnder : .repsOver, magnitude: Double(d), target: target)
            }
        }
        if actualRir == 0 { return SetDeviation(kind: .failure, magnitude: 0, target: target) }
        if actualRir >= 4 { return SetDeviation(kind: .tooEasy, magnitude: 0, target: target) }
        return nil
    }

    private static func parseRepsRange(_ s: String) -> (min: Int?, max: Int?, mid: Int?) {
        let parts = s.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2 {
            let mid = (parts[0] + parts[1]) / 2
            return (parts[0], parts[1], mid)
        }
        if parts.count == 1 { return (parts[0], parts[0], parts[0]) }
        return (nil, nil, nil)
    }
}
