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

    /// Rest-overlay "next" hint. After the active exercise's sets are done and a
    /// next exercise exists → its name; otherwise the next set of this exercise.
    static func restHint(setsDone: Int, targetSets: Int, nextExerciseName: String?) -> String {
        if targetSets > 0, setsDone >= targetSets, let next = nextExerciseName {
            return next
        }
        return "подход \(setsDone + 1)"
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
}
