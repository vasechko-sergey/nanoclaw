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
        wheelWeight(target ?? lastLogged ?? 20)
    }

    /// A weight the wheel can actually show: on the step, within 0…300. A
    /// Picker whose selection matches no row DISPLAYS the first row but KEEPS
    /// the value — Payne's −5 for pull-ups (2026-09-28) showed as 0 and was
    /// logged as −5. Everything that seeds the wheel goes through here.
    static func wheelWeight(_ w: Double) -> Double {
        let snapped = (w / weightStep).rounded() * weightStep
        return min(max(snapped, weightOptions.first ?? 0), weightOptions.last ?? 300)
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

    /// Sentinel `restHint` returns when nothing remains. The rest overlay
    /// watches for it to auto-dismiss instead of ticking out a full rest period
    /// on a workout that's already over.
    static let workoutFinishedHint = "Тренировка закончена"

    /// Rest-overlay "next" hint: the active exercise's next set while it has sets
    /// left, else the exercise «Дальше» leads to (`nextExerciseIdx`).
    static func restHint(logged: [LoggedExercise], exercises: [ExercisePlan], activeIdx: Int) -> String {
        guard exercises.indices.contains(activeIdx), logged.indices.contains(activeIdx) else {
            return workoutFinishedHint
        }
        let cur = exercises[activeIdx]
        let curDone = logged[activeIdx].sets.count
        if cur.targetSets > 0, curDone < cur.targetSets {
            return "подход \(curDone + 1) — \(cur.displayName)"
        }
        guard let i = nextExerciseIdx(logged: logged, exercises: exercises, activeIdx: activeIdx) else {
            return workoutFinishedHint
        }
        // A cardio/warmup block has no set count to name.
        if exercises[i].isDuration { return "кардио: \(exercises[i].displayName)" }
        return "\(exercises[i].displayName) — подход \(logged[i].sets.count + 1)"
    }

    /// Where «Дальше» leads — the rest screen's line and the header button alike:
    /// the next exercise after the active one in plan order that still has work,
    /// passing over ones already done; once nothing is left ahead, the earliest
    /// one left behind. nil when nothing remains. 2026-10-19: the scan ran from
    /// the top of the plan, so after jumping ahead (machine busy) every rest
    /// pointed back at the skipped exercise, while the button went by number,
    /// done or not.
    static func nextExerciseIdx(logged: [LoggedExercise], exercises: [ExercisePlan], activeIdx: Int) -> Int? {
        let ahead = exercises.indices.filter { $0 > activeIdx }
        let behind = exercises.indices.filter { $0 < activeIdx }
        return (ahead + behind).first { hasWorkLeft($0, logged: logged, exercises: exercises, activeIdx: activeIdx) }
    }

    /// Second line under «Дальше:» — set work left behind the active exercise
    /// (jumped over, or left mid-way), bar the one «Дальше» already names.
    static func skippedHint(logged: [LoggedExercise], exercises: [ExercisePlan], activeIdx: Int) -> String? {
        let next = nextExerciseIdx(logged: logged, exercises: exercises, activeIdx: activeIdx)
        let names = exercises.indices
            .filter { $0 < activeIdx && $0 != next && exercises[$0].targetSets > 0
                && hasWorkLeft($0, logged: logged, exercises: exercises, activeIdx: activeIdx) }
            .map { exercises[$0].displayName }
        return names.isEmpty ? nil : "пропущено: " + names.joined(separator: ", ")
    }

    /// Sets short of the target, or a timed block (warmup, cardio finisher) with
    /// nothing logged. A timed block counts only ahead of the active exercise —
    /// a warmup walked past is not skipped work.
    private static func hasWorkLeft(_ i: Int, logged: [LoggedExercise], exercises: [ExercisePlan], activeIdx: Int) -> Bool {
        guard logged.indices.contains(i), exercises.indices.contains(i) else { return false }
        let e = exercises[i]
        if e.targetSets > 0 { return logged[i].sets.count < e.targetSets }
        return e.isDuration && i > activeIdx && logged[i].sets.isEmpty
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

    /// Hold-time wheels (plank, warmup walk): minutes and 5-second steps.
    static let holdMinuteOptions = Array(0...59)
    static let holdSecondOptions = Array(stride(from: 0, through: 55, by: 5))

    /// A stopwatch reading as the wheels can show it: nearest 5 s, at least 5 s,
    /// at most 59:55.
    static func holdSeconds(_ elapsed: TimeInterval) -> Int {
        let snapped = Int((elapsed / 5).rounded()) * 5
        return min(max(snapped, 5), 59 * 60 + 55)
    }

    /// Wheel start for a timed set: the time just held on this exercise, else
    /// Payne's target, else a minute.
    static func defaultHold(target: Int?, lastLogged: Int?) -> Int {
        lastLogged ?? target ?? 60
    }

    /// One cell of the top progress bar — one per exercise, equal width.
    struct ProgressSegment: Equatable {
        enum Kind: Equatable { case done, partial, active, skipped, upcoming }
        let kind: Kind
        let isPreview: Bool
        /// Share of the bar to fill: 1 for done, sets/target for partial, 0 otherwise.
        let fill: Double
    }

    /// Equal segment per exercise, driven by TRUTH (not position). `.done` once
    /// the sets reach the target (bonus sets too) — or, without a set target
    /// (warmup, cardio), once anything is logged. Sets short of the target are
    /// `.partial` wherever the exercise sits: 2026-10-29 one set of three read
    /// as done. The same rule as `hasWorkLeft` for the rest hints. Nothing
    /// logged behind the cursor is `.skipped`, except a passed timed block
    /// (warmup walked past), which is `.done`. The previewed exercise
    /// (when ≠ active) is marked for an outline.
    static func progressSegments(sets: [Int], targetSets: [Int], isDuration: [Bool],
                                 activeIdx: Int, previewIdx: Int) -> [ProgressSegment] {
        (0..<max(sets.count, 1)).map { i in
            let done = i < sets.count ? sets[i] : 0
            let target = i < targetSets.count ? targetSets[i] : 0
            let timed = i < isDuration.count && isDuration[i]
            let kind: ProgressSegment.Kind
            var fill = 0.0
            if i == activeIdx {
                kind = .active
            } else if done > 0 {
                if target > 0 && done < target {
                    kind = .partial
                    fill = Double(done) / Double(target)
                } else {
                    kind = .done
                    fill = 1
                }
            } else if i < activeIdx {
                kind = timed ? .done : .skipped
                fill = timed ? 1 : 0
            } else {
                kind = .upcoming
            }
            return ProgressSegment(kind: kind, isPreview: i == previewIdx && previewIdx != activeIdx, fill: fill)
        }
    }

    /// Image-scrim tag for an exercise looked at but not active.
    static func previewStateTag(sets: Int, targetSets: Int) -> String {
        if sets == 0 { return "ещё не начато" }
        if targetSets > 0 && sets < targetSets {
            let word = (targetSets % 10 == 1 && targetSets % 100 != 11) ? "подхода" : "подходов"
            return "\(sets) из \(targetSets) \(word)"
        }
        return "пройдено"
    }

    /// Hold-ring header: «ПЛАНКА · ПОДХОД 1»; a warmup (no sets) shows its name.
    static func holdTitle(name: String, isTimedSets: Bool, setIdx: Int) -> String {
        let n = name.uppercased(with: Locale(identifier: "ru_RU"))
        return isTimedSets ? "\(n) · ПОДХОД \(setIdx + 1)" : n
    }

    /// Under the hold-ring digits: the target, then «цель есть · +0:07» past it.
    /// nil without a target.
    static func holdCaption(target: Int, elapsed: Int) -> String? {
        guard target > 0 else { return nil }
        if elapsed >= target { return "цель есть · +\(WorkoutSetFormat.duration(elapsed - target))" }
        return "цель \(WorkoutSetFormat.duration(target))"
    }

    /// "2/5" — exercises actually done over total, clamped. Counts real work, not
    /// cursor position: skip an exercise and the numerator does not advance.
    static func exerciseCounter(done: Int, total: Int) -> String {
        "\(done)/\(max(total, 1))"
    }

    /// Tolerance beyond which a set is called out to Payne.
    static let weightDeviationPct: Double = 0.15
    /// Reps tolerance as a fraction of the target mid. An absolute ±3 band is
    /// 50% of a 6-rep target but only 15% of a 20-rep one — so scale to the
    /// range instead of a fixed count. Floored at ±2 reps (below) so tiny
    /// targets still get a sane band.
    static let repsDeviationFraction: Double = 0.30

    /// Raw values are pinned to the wire enum in `V2.SetLog.Deviation.Kind`
    /// (snake_case) so `set_log` envelopes and `workout_complete.full_session_json`
    /// serialize identical strings for the same kind — otherwise Payne sees
    /// two different vocabularies for the same signal across the two paths.
    enum SetDeviationKind: String, Codable, Equatable {
        case weightUnder = "weight_under"
        case weightOver = "weight_over"
        case repsUnder = "reps_under"
        case repsOver = "reps_over"
        case failure                          // rir == 0
        case tooEasy = "too_easy"             // rir >= 4
    }

    struct DeviationTargetSnapshot: Codable, Equatable {
        let repsMin: Int
        let repsMax: Int
        var weight: Double?
        let rir: Int

        /// Snake_case pinned to the wire enum in `V2.SetLog.DeviationTarget`.
        enum CodingKeys: String, CodingKey {
            case repsMin = "reps_min"
            case repsMax = "reps_max"
            case weight
            case rir
        }
    }

    struct SetDeviation: Codable, Equatable {
        let kind: SetDeviationKind
        /// Percentage delta for weight, absolute delta for reps, 0 for rir kinds.
        let magnitude: Double
        let target: DeviationTargetSnapshot

        enum CodingKeys: String, CodingKey {
            case kind, magnitude, target
        }
    }

    /// Detect every way an actual set deviated from its planned exercise.
    /// Returns ALL hits (weight, then reps, then rir) so a set that went wrong
    /// on multiple axes surfaces each one to Payne — a single-precedence result
    /// would hide "wrong weight AND missed reps AND hit failure" behind just the
    /// weight, which reads as a lighter problem than it is. Empty ⇒ within
    /// tolerance on every axis.
    ///
    /// Comparisons are strict `>`: a set exactly at the tolerance is on-plan.
    /// A non-strict `>=` flips at exactly 15% / the exact rep band, which the
    /// 0.5 kg weight wheel and integer rounding can land on either side of —
    /// strict gives a stable "must exceed the tolerance" rule.
    ///
    /// `intensityLabel` gates the `too_easy` (rir ≥ 4) call-out: on a light /
    /// deload week every warmup and back-off set reads as easy, so surfacing
    /// it there is pure alarm fatigue. `failure` (rir == 0) always fires.
    static func detectDeviation(actualReps: Int, actualWeight: Double, actualRir: Int,
                                exercise: ExercisePlan, intensityLabel: String? = nil) -> [SetDeviation] {
        let range = parseRepsRange(exercise.targetReps)
        let target = DeviationTargetSnapshot(
            repsMin: range.min ?? 0, repsMax: range.max ?? 0,
            weight: exercise.weightKgTarget, rir: exercise.targetRir
        )
        var out: [SetDeviation] = []
        if let weightTarget = exercise.weightKgTarget, weightTarget > 0 {
            let delta = actualWeight / weightTarget - 1.0
            if abs(delta) > weightDeviationPct {
                out.append(SetDeviation(kind: delta < 0 ? .weightUnder : .weightOver, magnitude: delta, target: target))
            }
        }
        if let mid = range.mid {
            let d = actualReps - mid
            let repsThreshold = max(2, Int((Double(mid) * repsDeviationFraction).rounded()))
            if abs(d) > repsThreshold {
                out.append(SetDeviation(kind: d < 0 ? .repsUnder : .repsOver, magnitude: Double(d), target: target))
            }
        }
        if actualRir == 0 {
            out.append(SetDeviation(kind: .failure, magnitude: 0, target: target))
        } else if actualRir >= 4, !isLightWeek(intensityLabel) {
            out.append(SetDeviation(kind: .tooEasy, magnitude: 0, target: target))
        }
        return out
    }

    /// Whether the plan's week label reads as a light / deload week — matches
    /// "лёг…" and "легк…" (лёгкая / лёгкий / легкая). Used to suppress the
    /// `too_easy` call-out where an easy set is expected.
    static func isLightWeek(_ intensityLabel: String?) -> Bool {
        let lc = intensityLabel?.lowercased() ?? ""
        return lc.contains("лёг") || lc.contains("легк")
    }

    /// Parse a target-reps string into (min, max, mid). Handles ranges written
    /// with `-`, `,`, `или`, or `or`; a bare number; an open-ended `N+`
    /// (→ N…N+5, mid N+2); and `AMRAP` in any case (→ 0…50, mid 25 — "as many
    /// as possible", so the band is deliberately wide). Returns all-nil only
    /// when nothing numeric can be extracted (a real warmup with
    /// `target_reps: ""` → reps rule skipped). Internal (not private) so the
    /// parse table can be unit-tested directly.
    static func parseRepsRange(_ s: String) -> (min: Int?, max: Int?, mid: Int?) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        if lowered == "amrap" { return (0, 50, 25) }
        // Open-ended "N+": floor at N, allow up to N+5, mid N+2.
        if trimmed.hasSuffix("+"),
           let n = Int(trimmed.dropLast().trimmingCharacters(in: .whitespaces)) {
            return (n, n + 5, n + 2)
        }
        // Split on any supported range delimiter, then pull out the integers.
        var parts = [lowered]
        for sep in ["-", ",", "или", "or"] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        let nums = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if nums.count >= 2 {
            let lo = nums.min()!, hi = nums.max()!
            return (lo, hi, (lo + hi) / 2)
        }
        if nums.count == 1 { return (nums[0], nums[0], nums[0]) }
        return (nil, nil, nil)
    }
}
