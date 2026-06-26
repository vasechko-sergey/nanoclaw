# Workout Runner Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the iOS live workout runner so Payne's per-exercise recommendations are visible, set entry is fast (weight wheel, RIR buttons, real defaults), exercises are browsable, the rest timer survives screen-off and points at the next exercise, and finishing is an honest full-screen commit with a worded rating.

**Architecture:** 100% iOS client (`ios/JarvisApp/`). Payne already sends `weight_kg_target` + recs in the plan; the host (`WorkoutBridge.handleInbound`) passes `workout_complete` through verbatim, so a new `session_feeling` reaches Payne with no host/agent change. Pure runner logic (defaults, labels, progress segments, hints, feeling map) is consolidated into one view-independent file (`WorkoutRunnerLogic`) and unit-tested; SwiftUI views stay thin and are verified by build + simulator screenshot.

**Tech Stack:** SwiftUI, GRDB, XCTest (`@testable import Jarvis`), xcodegen (`project.yml` is source of truth), XcodeBuildMCP (sim `iPhone 17`, UDID `A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA`, scheme `JarvisApp`).

**Spec:** `docs/superpowers/specs/2026-06-26-workout-runner-redesign-design.md`

---

## Conventions for every task

- **Test runner:** before the first build/test, call XcodeBuildMCP `session_show_defaults` once to confirm scheme `JarvisApp` + sim `iPhone 17`. Run tests with `test_sim` and an `-only-testing:JarvisAppTests/<Class>[/<method>]` filter. Build-only checks use `build_sim`. Visual checks use `build_run_sim` then `screenshot`.
- **New files** are auto-globbed by `project.yml` (`path: Sources/JarvisApp` / `Sources/JarvisAppTests`). After creating ANY new `.swift` file, run `cd ios/JarvisApp && xcodegen generate` before building so the `.xcodeproj` sees it.
- **Module name** for tests is `Jarvis` (product name), not `JarvisApp`: `@testable import Jarvis`.
- **Commits:** every commit message ends with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Work on a branch (see Task 0). Do NOT push; the human pushes after review.

---

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `Models/Workout.swift` | `ExercisePlan` + `WorkoutSession` codable | Modify — add `weightKgTarget`, `sessionFeeling`, `sessionFeelingLabel` |
| `Models/WorkoutRunnerLogic.swift` | Pure runner logic (defaults, labels, segments, hints, feeling map) | **Create** |
| `Services/WorkoutCoordinator.swift` | Live workout state | Modify — `activate(idx:)`, new `complete(...)` |
| `Services/RestTimer.swift` | Inter-set rest countdown | Modify — wall-clock `endDate` + `refresh()` |
| `Views/Workout/RecommendationPanel.swift` | ⅓ Payne-recs panel | **Create** |
| `Views/Workout/WorkoutFinishView.swift` | Full-screen finish + worded rating | **Create** |
| `Views/WorkoutView.swift` | Runner shell: pinned header, scroll, preview/activate, finish | Modify |
| `Views/Workout/ExerciseBannerView.swift` | Image + scrim + swipe | Modify |
| `Views/Workout/FocusSetCard.swift` | Set logger: weight wheel, RIR buttons | Modify |
| `Views/Workout/LoggedSetChips.swift` | Logged chips + position label | Modify |
| `project.yml` | App version | Modify — bump build 57→58, marketing 1.12.0→1.13.0 |
| `JarvisAppTests/WorkoutModelsTests.swift` | Model codable tests | Modify |
| `JarvisAppTests/WorkoutRunnerLogicTests.swift` | Pure-logic tests | **Create** |
| `JarvisAppTests/WorkoutCoordinatorTests.swift` | Coordinator tests | Modify |
| `JarvisAppTests/RestTimerTests.swift` | Timer tests | Modify |

---

### Task 0: Branch

- [ ] **Step 1: Create a feature branch**

```bash
cd /Users/serg/git/nanoclaw
git checkout -b workout-runner-redesign
```

---

### Task 1: Decode `weight_kg_target` on `ExercisePlan`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift`
- Test: `ios/JarvisApp/Sources/JarvisApp/../JarvisAppTests/WorkoutModelsTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `WorkoutModelsTests.swift`:

```swift
func test_exercisePlan_decodesWeightKgTarget() throws {
    let json = """
    {"slug":"zhim","name_ru":"Жим","target_sets":4,"target_reps":"5-6",
     "reps_in_reserve":2,"rest_seconds":180,"weight_kg_target":66.25}
    """
    let ex = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
    XCTAssertEqual(ex.weightKgTarget, 66.25)
}

func test_exercisePlan_nilWeightKgTarget_whenAbsent() throws {
    let json = """
    {"slug":"warmup","target_sets":null,"target_reps":"","reps_in_reserve":null,
     "rest_seconds":0,"duration_seconds":300}
    """
    let ex = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
    XCTAssertNil(ex.weightKgTarget)
}

func test_exercisePlan_weightKgTarget_roundTrips() throws {
    let ex = ExercisePlan(exerciseSlug: "a", targetSets: 3, targetReps: "8",
                          targetRir: 2, restSec: 90, weightKgTarget: 40)
    let data = try JSONEncoder().encode(ex)
    let back = try JSONDecoder().decode(ExercisePlan.self, from: data)
    XCTAssertEqual(back.weightKgTarget, 40)
}
```

- [ ] **Step 2: Run to verify it fails**

Run `test_sim` only-testing `JarvisAppTests/WorkoutModelsTests`.
Expected: compile failure — `ExercisePlan` has no `weightKgTarget` and the `init` has no such parameter.

- [ ] **Step 3: Implement**

In `Models/Workout.swift`, `ExercisePlan`:

Add the stored property after `durationSec`:
```swift
    /// Payne's recommended working weight (kg) for this exercise. Optional —
    /// warmups omit it. Drives the weight-wheel default + the recs panel.
    var weightKgTarget: Double?
```

Add to the `init`:
```swift
    init(exerciseSlug: String, targetSets: Int, targetReps: String, targetRir: Int, restSec: Int, notes: String? = nil, nameRu: String? = nil, durationSec: Int? = nil, weightKgTarget: Double? = nil) {
        self.exerciseSlug = exerciseSlug
        self.targetSets = targetSets
        self.targetReps = targetReps
        self.targetRir = targetRir
        self.restSec = restSec
        self.notes = notes
        self.nameRu = nameRu
        self.durationSec = durationSec
        self.weightKgTarget = weightKgTarget
    }
```

Add the CodingKey:
```swift
        case weightKgTarget = "weight_kg_target"
```

Add to `init(from:)`:
```swift
        weightKgTarget = try? c.decode(Double.self, forKey: .weightKgTarget)
```

Add to `encode(to:)`:
```swift
        try c.encodeIfPresent(weightKgTarget, forKey: .weightKgTarget)
```

- [ ] **Step 4: Run to verify it passes**

Run `test_sim` only-testing `JarvisAppTests/WorkoutModelsTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutModelsTests.swift
git commit   # message: "feat(ios/workout): decode weight_kg_target on ExercisePlan" + co-author trailer
```

---

### Task 2: `session_feeling` on `WorkoutSession`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutModelsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func test_workoutSession_encodesSessionFeeling() throws {
    let s = WorkoutSession(
        workoutId: "w", date: "2026-06-26", dayName: "Верх", week: 1,
        startedAt: Date(timeIntervalSince1970: 0), finishedAt: nil, exercises: [],
        perceivedOverallRir: nil, healthSignalAtStart: nil,
        sessionFeeling: 4, sessionFeelingLabel: "Хорошо, с запасом")
    let data = try JSONEncoder().encode(s)
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(obj["session_feeling"] as? Int, 4)
    XCTAssertEqual(obj["session_feeling_label"] as? String, "Хорошо, с запасом")
}
```

- [ ] **Step 2: Run to verify it fails**

Run `test_sim` only-testing `JarvisAppTests/WorkoutModelsTests`. Expected: compile failure — `WorkoutSession` init has no `sessionFeeling`/`sessionFeelingLabel`.

- [ ] **Step 3: Implement**

In `Models/Workout.swift`, `WorkoutSession`, add the two stored properties **at the end** with `= nil` defaults (so the existing memberwise-init caller in `TransportV2WorkoutTests.swift:85` still compiles):

```swift
    var healthSignalAtStart: String?
    /// Subjective 1–5 rating of the whole session (1 = tough … 5 = easy),
    /// replacing the redundant overall-RIR. Sent to Payne in workout_complete.
    var sessionFeeling: Int? = nil
    /// Human label for `sessionFeeling` so Payne reads the scale without guessing.
    var sessionFeelingLabel: String? = nil
```

Add the CodingKeys:
```swift
        case sessionFeeling = "session_feeling"
        case sessionFeelingLabel = "session_feeling_label"
```

- [ ] **Step 4: Run to verify it passes**

Run `test_sim` only-testing `JarvisAppTests/WorkoutModelsTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutModelsTests.swift
git commit   # "feat(ios/workout): add session_feeling to WorkoutSession" + co-author trailer
```

---

### Task 3: `WorkoutRunnerLogic` — pure helpers

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift`
- Create test: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift`

- [ ] **Step 1: Write the failing test**

Create `WorkoutRunnerLogicTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class WorkoutRunnerLogicTests: XCTestCase {
    func test_snapRir_picksNearestButton() {
        XCTAssertEqual(WorkoutRunnerLogic.snapRir(2), 2)
        XCTAssertEqual(WorkoutRunnerLogic.snapRir(3), 2)   // tie 2 vs 4 → 2 (first min)
        XCTAssertEqual(WorkoutRunnerLogic.snapRir(5), 4)
        XCTAssertEqual(WorkoutRunnerLogic.snapRir(0), 0)
    }

    func test_defaultWeight_prefersTargetThenLastThen20() {
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: 66.25, lastLogged: 50), 66.5)
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: nil, lastLogged: 47.5), 47.5)
        XCTAssertEqual(WorkoutRunnerLogic.defaultWeight(target: nil, lastLogged: nil), 20)
    }

    func test_setLabel_bonusPastTarget() {
        XCTAssertEqual(WorkoutRunnerLogic.setLabel(currentSetIdx: 1, targetSets: 4), "подход 2 из 4")
        XCTAssertEqual(WorkoutRunnerLogic.setLabel(currentSetIdx: 3, targetSets: 3), "бонусный подход")
        XCTAssertEqual(WorkoutRunnerLogic.setLabel(currentSetIdx: 4, targetSets: 3), "бонусный подход")
        XCTAssertNil(WorkoutRunnerLogic.setLabel(currentSetIdx: 0, targetSets: 0))   // warmup
    }

    func test_restHint_nextExerciseWhenSetsDone() {
        XCTAssertEqual(WorkoutRunnerLogic.restHint(setsDone: 2, targetSets: 4, nextExerciseName: "Тяга"), "подход 3")
        XCTAssertEqual(WorkoutRunnerLogic.restHint(setsDone: 4, targetSets: 4, nextExerciseName: "Тяга"), "Тяга")
        XCTAssertEqual(WorkoutRunnerLogic.restHint(setsDone: 4, targetSets: 4, nextExerciseName: nil), "подход 5")
    }

    func test_weightIndex_roundsToHalfStep() {
        XCTAssertEqual(WorkoutRunnerLogic.weightOptions.first, 0)
        XCTAssertEqual(WorkoutRunnerLogic.weightOptions.last, 300)
        XCTAssertEqual(WorkoutRunnerLogic.weightOptions[WorkoutRunnerLogic.weightIndex(for: 66.25)], 66.5)
        XCTAssertEqual(WorkoutRunnerLogic.weightOptions[WorkoutRunnerLogic.weightIndex(for: 999)], 300)
    }

    func test_feelings_fiveGraded() {
        XCTAssertEqual(WorkoutRunnerLogic.feelings.count, 5)
        XCTAssertEqual(WorkoutRunnerLogic.feelings.map(\.value), [1, 2, 3, 4, 5])
        XCTAssertEqual(WorkoutRunnerLogic.feelings.first(where: { $0.value == 4 })?.label, "Хорошо, с запасом")
    }

    func test_progressSegments_activeShowsSetsAndPreviewMark() {
        let segs = WorkoutRunnerLogic.progressSegments(
            total: 3, activeIdx: 1, setsDone: 2, targetSets: 4, previewIdx: 2)
        XCTAssertEqual(segs[0].kind, .doneExercise)
        XCTAssertEqual(segs[1].kind, .activeSets(done: 2, total: 4))
        XCTAssertEqual(segs[2].kind, .upcoming)
        XCTAssertTrue(segs[2].isPreview)
        XCTAssertFalse(segs[1].isPreview)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run `test_sim` only-testing `JarvisAppTests/WorkoutRunnerLogicTests`. Expected: compile failure — `WorkoutRunnerLogic` undefined.

- [ ] **Step 3: Implement**

Create `Models/WorkoutRunnerLogic.swift`:

```swift
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

    /// One cell of the two-level top progress bar.
    struct ProgressSegment: Equatable {
        enum Kind: Equatable {
            case doneExercise
            case activeSets(done: Int, total: Int)
            case upcoming
        }
        let kind: Kind
        let isPreview: Bool
    }

    /// Build the progress row: exercises before `activeIdx` are done; the active
    /// one shows its set fill; later ones are upcoming. The previewed exercise
    /// (when different from active) is marked for an outline.
    static func progressSegments(total: Int, activeIdx: Int, setsDone: Int,
                                 targetSets: Int, previewIdx: Int) -> [ProgressSegment] {
        (0..<max(total, 1)).map { i in
            let kind: ProgressSegment.Kind
            if i < activeIdx {
                kind = .doneExercise
            } else if i == activeIdx {
                let tot = max(targetSets, 1)
                kind = .activeSets(done: min(setsDone, tot), total: tot)
            } else {
                kind = .upcoming
            }
            return ProgressSegment(kind: kind, isPreview: i == previewIdx && previewIdx != activeIdx)
        }
    }
}
```

- [ ] **Step 4: Regenerate + run**

```bash
cd ios/JarvisApp && xcodegen generate
```
Run `test_sim` only-testing `JarvisAppTests/WorkoutRunnerLogicTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit   # "feat(ios/workout): pure runner logic (defaults, labels, segments, feelings)" + co-author trailer
```

---

### Task 4: Coordinator `activate(idx:)`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `WorkoutCoordinatorTests.swift`:

```swift
func test_activate_switchesActiveAndResumesSetCount() throws {
    let queue = try makeQueue()
    let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 3, setsPerExercise: 4), queue: queue)
    // Log one set on exercise 0, then jump to exercise 2.
    coord.logSet(reps: 8, weight: 40, repsInReserve: 2)
    coord.activate(idx: 2)
    XCTAssertEqual(coord.currentExerciseIdx, 2)
    XCTAssertEqual(coord.currentSetIdx, 0)            // exercise 2 has no sets yet
    coord.logSet(reps: 10, weight: 30, repsInReserve: 1)
    // Jump back to exercise 0 — set count resumes from what was logged there.
    coord.activate(idx: 0)
    XCTAssertEqual(coord.currentExerciseIdx, 0)
    XCTAssertEqual(coord.currentSetIdx, 1)
    XCTAssertEqual(coord.loggedForCurrentExercise.count, 1)
}

func test_activate_outOfRange_isNoOp() throws {
    let queue = try makeQueue()
    let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 2), queue: queue)
    coord.activate(idx: 9)
    XCTAssertEqual(coord.currentExerciseIdx, 0)
}
```

- [ ] **Step 2: Run to verify it fails**

Run `test_sim` only-testing `JarvisAppTests/WorkoutCoordinatorTests`. Expected: compile failure — no `activate(idx:)`.

- [ ] **Step 3: Implement**

In `Services/WorkoutCoordinator.swift`, add under `// MARK: - Mutations`:

```swift
    /// Switch the active exercise (free order — e.g. machine busy). Resumes the
    /// target exercise's set count so logging continues where it left off.
    func activate(idx: Int) {
        guard !isFinished, plan.exercises.indices.contains(idx) else { return }
        currentExerciseIdx = idx
        currentSetIdx = logged[idx].sets.count
    }
```

- [ ] **Step 4: Run to verify it passes**

Run `test_sim` only-testing `JarvisAppTests/WorkoutCoordinatorTests`. Expected: PASS (existing tests still green).

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift
git commit   # "feat(ios/workout): coordinator.activate for free exercise order" + co-author trailer
```

---

### Task 5: Finish flow — `complete()` feeling + full-screen `WorkoutFinishView`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutFinishView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

In `WorkoutCoordinatorTests.swift`, replace the two `complete(perceivedOverallRir:)` call sites and add a feeling assertion:

```swift
func test_complete_returnsSessionWithAllLoggedSets() throws {
    let queue = try makeQueue()
    let coord = WorkoutCoordinator(plan: makePlan(), queue: queue)
    coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
    coord.finishExercise(comment: nil)
    coord.logSet(reps: 8, weight: 20, repsInReserve: 0)
    let session = coord.complete(sessionFeeling: 4, sessionFeelingLabel: "Хорошо, с запасом")
    XCTAssertEqual(session.workoutId, "w1")
    XCTAssertEqual(session.exercises.flatMap(\.sets).count, 2)
    XCTAssertEqual(session.sessionFeeling, 4)
    XCTAssertEqual(session.sessionFeelingLabel, "Хорошо, с запасом")
    XCTAssertNil(session.perceivedOverallRir)
    XCTAssertTrue(coord.isFinished)
}

func test_logSet_afterFinished_isNoOp() throws {
    let queue = try makeQueue()
    let coord = WorkoutCoordinator(plan: makePlan(exerciseCount: 1, setsPerExercise: 1), queue: queue)
    _ = coord.complete(sessionFeeling: 3, sessionFeelingLabel: "Нормально")
    coord.logSet(reps: 5, weight: 10, repsInReserve: 0)
    XCTAssertEqual(try queue.pending().count, 0)
}
```

- [ ] **Step 2: Run to verify it fails**

Run `test_sim` only-testing `JarvisAppTests/WorkoutCoordinatorTests`. Expected: compile failure — `complete` signature mismatch.

- [ ] **Step 3: Implement the coordinator change**

In `Services/WorkoutCoordinator.swift`, replace `complete(perceivedOverallRir:healthSignalAtStart:)`:

```swift
    /// Produce the final WorkoutSession payload for `workout_complete`.
    func complete(sessionFeeling: Int, sessionFeelingLabel: String, healthSignalAtStart: String? = nil) -> WorkoutSession {
        isFinished = true
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
```

- [ ] **Step 4: Create the finish view**

Create `Views/Workout/WorkoutFinishView.swift`:

```swift
import SwiftUI

/// Full-screen terminal "workout done" step. NOT a sheet — finishing is a
/// commit, so there is nothing to minimize to. An explicit "Отмена" returns to
/// the runner (the toolbar "финиш" is tappable mid-workout). Готово commits the
/// session with a worded 1–5 feeling.
struct WorkoutFinishView: View {
    let dayName: String
    let exerciseCount: Int
    let setCount: Int
    var onCancel: () -> Void
    var onDone: (_ feeling: Int, _ label: String) -> Void

    @State private var selected = 4   // default "Хорошо, с запасом"

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: onCancel) {
                        Label("Отмена", systemImage: "chevron.left")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Text("к тренировке").font(.caption).foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 16).padding(.top, 10)

                VStack(spacing: 6) {
                    Image(systemName: "flag")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Theme.accent.opacity(0.15)))
                    Text("Тренировка завершена").font(.title3.weight(.medium)).foregroundStyle(.white)
                    Text("\(dayName) · \(exerciseCount) упражнений · \(setCount) подходов")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 26)

                Text("Как прошла?").font(.subheadline).foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 22).padding(.bottom, 4)

                VStack(spacing: 9) {
                    ForEach(WorkoutRunnerLogic.feelings, id: \.value) { f in
                        Button { selected = f.value } label: {
                            HStack(spacing: 10) {
                                Text("\(f.value)")
                                    .font(.caption).frame(width: 16)
                                    .foregroundStyle(selected == f.value ? Color(red: 0.02, green: 0.16, blue: 0.17) : .white.opacity(0.3))
                                Text(f.label)
                                    .font(.body)
                                    .foregroundStyle(selected == f.value ? Color(red: 0.02, green: 0.16, blue: 0.17) : .white.opacity(0.7))
                                if selected == f.value {
                                    Spacer(); Image(systemName: "checkmark").foregroundStyle(Color(red: 0.02, green: 0.16, blue: 0.17))
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(selected == f.value ? Theme.accent : Color.white.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)

                Spacer()

                Button {
                    let label = WorkoutRunnerLogic.feelings.first { $0.value == selected }?.label ?? ""
                    onDone(selected, label)
                } label: {
                    Text("Готово").font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 18).padding(.bottom, 22)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("workout-finish-view")
    }
}
```

- [ ] **Step 5: Wire it into `WorkoutView`**

In `Views/WorkoutView.swift`:

Remove the now-unused finish state and replace the sheet. Change:
```swift
    @State private var showFinishSheet = false
    @State private var finishOverallRir: Int = 2
```
to:
```swift
    @State private var showFinish = false
```

In `body`, replace `.sheet(isPresented: $showFinishSheet) { finishSheet }` with:
```swift
        .fullScreenCover(isPresented: $showFinish) {
            WorkoutFinishView(
                dayName: coordinator.plan.dayName,
                exerciseCount: coordinator.totalExercises,
                setCount: coordinator.logged.reduce(0) { $0 + $1.sets.count },
                onCancel: { showFinish = false },
                onDone: { feeling, label in
                    let session = coordinator.complete(sessionFeeling: feeling, sessionFeelingLabel: label)
                    restTimer.skip()
                    showFinish = false
                    onClose(session)
                }
            )
        }
```

Update the two places that set `showFinishSheet = true` (in `advance()` and the `toolbar` "финиш" button) to `showFinish = true`.

Delete the entire `private var finishSheet: some View { … }` computed property.

- [ ] **Step 6: Regenerate, build, run tests**

```bash
cd ios/JarvisApp && xcodegen generate
```
Run `test_sim` only-testing `JarvisAppTests/WorkoutCoordinatorTests`. Expected: PASS.
Run `build_sim` (full app). Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Visual check**

`build_run_sim`, open the workout, tap финиш, `screenshot`. Confirm: full screen (no grabber), "Отмена" top-left, worded rows, default "4" selected.

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutFinishView.swift ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit   # "feat(ios/workout): full-screen finish with worded rating → session_feeling" + co-author trailer
```

---

### Task 6: `FocusSetCard` — weight wheel, RIR buttons, defaults from Payne

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/FocusSetCard.swift`

Logic is already tested in Task 3 (`defaultWeight`, `snapRir`, `weightOptions`). This task wires it into the UI; verification is build + visual.

- [ ] **Step 1: Replace the weight stepper with a wheel and RIR stepper with buttons**

Rewrite `FocusSetCard.swift` body + helpers. Replace the stored `weight`/`rir` defaults' wiring and the three `stepperRow`s:

```swift
struct FocusSetCard: View {
    @ObservedObject var coordinator: WorkoutCoordinator
    @ObservedObject var restTimer: RestTimer

    @State private var reps = 8
    @State private var weight: Double = 20
    @State private var rir = 2

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                stepperRow(label: "Повторы", value: "\(reps)",
                           onMinus: { reps = max(0, reps - 1) },
                           onPlus: { reps = min(30, reps + 1) })
                Divider().overlay(Color.white.opacity(0.06))
                weightRow
                Divider().overlay(Color.white.opacity(0.06))
                rirRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07), lineWidth: 0.5))

            Button(action: logCurrent) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold))
                    Text("Записать подход").font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(Theme.accent))
            }
            .disabled(coordinator.isFinished)
        }
        .onAppear(perform: prefill)
        .onChange(of: coordinator.currentSetIdx) { _, _ in prefillKeepWeight() }
        .onChange(of: coordinator.currentExerciseIdx) { _, _ in prefill() }
    }

    private var weightRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Вес, кг").foregroundStyle(.white.opacity(0.65))
                Spacer()
                if let t = coordinator.currentExercise.weightKgTarget {
                    Text("Пейн: \(WorkoutSetFormat.weight(t))").font(.caption).foregroundStyle(Color(red: 0.78, green: 0.57, blue: 0.35))
                }
            }
            Picker("Вес", selection: $weight) {
                ForEach(WorkoutRunnerLogic.weightOptions, id: \.self) { w in
                    Text(WorkoutSetFormat.weight(w)).tag(w)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 110)
            .clipped()
        }
        .padding(.vertical, 8)
    }

    private var rirRow: some View {
        HStack {
            Text("Запас").foregroundStyle(.white.opacity(0.65))
            Spacer()
            HStack(spacing: 8) {
                ForEach(WorkoutRunnerLogic.rirButtons, id: \.self) { v in
                    Button { Theme.hapticSend(); rir = v } label: {
                        Text("\(v)")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 40, height: 36)
                            .foregroundStyle(rir == v ? Color(red: 0.02, green: 0.16, blue: 0.17) : .white.opacity(0.6))
                            .background(RoundedRectangle(cornerRadius: 10).fill(rir == v ? Theme.accent : Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 11)
    }

    private func logCurrent() {
        Theme.hapticSend()
        coordinator.logSet(reps: reps, weight: weight, repsInReserve: rir, ts: Date())
        restTimer.start(planned: coordinator.currentExercise.restSec, lastRepsInReserve: rir)
    }

    private func prefill() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = prev?.reps ?? WorkoutSetFormat.midReps(targetReps: coordinator.currentExercise.targetReps)
        weight = WorkoutRunnerLogic.defaultWeight(
            target: coordinator.currentExercise.weightKgTarget, lastLogged: prev?.weight)
        rir = WorkoutRunnerLogic.snapRir(coordinator.currentExercise.targetRir)
    }

    private func prefillKeepWeight() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = prev?.reps ?? reps
        if let w = prev?.weight { weight = w }
        rir = WorkoutRunnerLogic.snapRir(coordinator.currentExercise.targetRir)
    }

    @ViewBuilder
    private func stepperRow(label: String, value: String,
                            onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.65))
            Spacer()
            HStack(spacing: 14) {
                circle("minus", onMinus)
                Text(value)
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                    .frame(width: 44)
                    .foregroundStyle(.white)
                circle("plus", onPlus)
            }
        }
        .padding(.vertical, 11)
    }

    private func circle(_ sys: String, _ act: @escaping () -> Void) -> some View {
        Button(action: { Theme.hapticSend(); act() }) {
            Image(systemName: sys)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}
```

Note: the weight `Picker(selection:)` binds to a `Double` whose value must exist in `weightOptions`; `prefill`/`prefillKeepWeight` go through `WorkoutRunnerLogic.defaultWeight` (already rounded to the 0.5 step) so the selection is always a valid tag.

- [ ] **Step 2: Build**

`build_sim`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Visual check**

`build_run_sim`, start a workout, `screenshot`. Confirm: weight is a wheel (center value highlighted), запас is 4 buttons `0/1/2/4` with the snapped target selected, weight pre-set near Payne's target.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/FocusSetCard.swift
git commit   # "feat(ios/workout): weight wheel + RIR buttons + Payne-seeded defaults" + co-author trailer
```

---

### Task 7: `LoggedSetChips` — bonus-set label

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/LoggedSetChips.swift`

Logic (`setLabel`) is tested in Task 3. Wire it in.

- [ ] **Step 1: Replace the position chip**

In `LoggedSetChips.swift` body, replace:
```swift
            if targetSets > 0 {
                chip("подход \(currentSetIdx + 1) из \(targetSets)", filled: false)
            }
```
with:
```swift
            if let label = WorkoutRunnerLogic.setLabel(currentSetIdx: currentSetIdx, targetSets: targetSets) {
                chip(label, filled: false)
            }
```

- [ ] **Step 2: Build**

`build_sim`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/LoggedSetChips.swift
git commit   # "feat(ios/workout): bonus-set label past target" + co-author trailer
```

---

### Task 8: `RecommendationPanel` — Payne's recs (⅓ panel)

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/RecommendationPanel.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// The ⅓-screen panel under the image showing Payne's recommendation for the
/// (previewed) exercise. All data comes from the plan — nothing computed here.
/// Plain language, no abbreviations (house style).
struct RecommendationPanel: View {
    let exercise: ExercisePlan

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.badge.a").font(.system(size: 13)).foregroundStyle(copper)
                Text("РЕКОМЕНДАЦИЯ ПЕЙНА").font(.caption2).tracking(0.3).foregroundStyle(copper)
            }
            HStack(spacing: 7) {
                if let w = exercise.weightKgTarget { chip("\(WorkoutSetFormat.weight(w)) кг") }
                if exercise.targetSets > 0 { chip("\(exercise.targetSets) × \(exercise.targetReps)") }
                chip("запас \(exercise.targetRir)")
                if exercise.restSec > 0 { chip("отдых \(restLabel(exercise.restSec))") }
            }
            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes).font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(red: 0.08, green: 0.078, blue: 0.06))
        .overlay(alignment: .top) { Rectangle().fill(copper.opacity(0.35)).frame(height: 1) }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.subheadline).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }

    private func restLabel(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}
```

- [ ] **Step 2: Regenerate + build**

```bash
cd ios/JarvisApp && xcodegen generate
```
`build_sim`. Expected: BUILD SUCCEEDED (the view isn't shown yet — wired in Task 9).

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/RecommendationPanel.swift ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit   # "feat(ios/workout): RecommendationPanel for Payne's per-exercise recs" + co-author trailer
```

---

### Task 9: `WorkoutView` + `ExerciseBannerView` — pinned header, two-level bar, scroll layout, swipe-preview + activate

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/ExerciseBannerView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift`

The two-level bar math (`progressSegments`) is tested in Task 3; this task renders it + restructures layout. Verification is build + screenshots.

- [ ] **Step 1: Slim `ExerciseBannerView` to image + scrim + swipe**

Replace `ExerciseBannerView.swift` body. Drop the top control bar (moves to the pinned header in `WorkoutView`); keep the image, bottom scrim (showing the **previewed** exercise + a state tag), chevrons, and a horizontal drag that calls `onPreview(delta:)`:

```swift
import SwiftUI

/// Image hero for the runner. Shows the *previewed* exercise; swipe / chevrons
/// move the preview. Top controls (progress, close, advance) live in the
/// pinned header owned by WorkoutView.
struct ExerciseBannerView: View {
    let exercise: ExercisePlan
    let imageURL: URL?
    let stateTag: String          // "подход 2 из 4" / "ещё не начато" / "бонусный подход"
    var canPrev: Bool
    var canNext: Bool
    var onPreview: (_ delta: Int) -> Void

    var body: some View {
        ZStack {
            if let url = imageURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Theme.surface
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 70)).foregroundStyle(Theme.accent.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .leading) {
            if canPrev { chevron("chevron.left") { onPreview(-1) } }
        }
        .overlay(alignment: .trailing) {
            if canNext { chevron("chevron.right") { onPreview(1) } }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(exercise.displayName).font(.headline).foregroundStyle(.white)
                Spacer()
                Text(stateTag).font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.black.opacity(0.74))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { v in
                    if v.translation.width < -40 { onPreview(1) }
                    else if v.translation.width > 40 { onPreview(-1) }
                }
        )
    }

    private func chevron(_ sys: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: sys).foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, height: 48)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(6)
    }
}
```

- [ ] **Step 2: Add the pinned header + two-level progress bar to `WorkoutView`**

In `Views/WorkoutView.swift`, add a `previewIdx` state and a `scenePhase` env (the latter used in Task 10):

```swift
    @Environment(\.scenePhase) private var scenePhase
    @State private var previewIdx: Int = 0
```

Add a computed pinned header that renders the two-level bar via `WorkoutRunnerLogic.progressSegments`:

```swift
    private var pinnedHeader: some View {
        HStack(spacing: 12) {
            Button { showAbortConfirm = true } label: {
                Image(systemName: "xmark").font(.body).foregroundStyle(.white).frame(width: 36, height: 36)
            }
            HStack(spacing: 3) {
                ForEach(Array(progressSegments.enumerated()), id: \.offset) { _, seg in
                    segmentView(seg)
                }
            }
            Button(action: advance) {
                Text(isLastExercise ? "Финиш" : "Дальше →").font(.subheadline).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.background)
    }

    private var progressSegments: [WorkoutRunnerLogic.ProgressSegment] {
        WorkoutRunnerLogic.progressSegments(
            total: coordinator.totalExercises,
            activeIdx: coordinator.currentExerciseIdx,
            setsDone: coordinator.loggedForCurrentExercise.count,
            targetSets: coordinator.currentExercise.targetSets,
            previewIdx: previewIdx)
    }

    @ViewBuilder
    private func segmentView(_ seg: WorkoutRunnerLogic.ProgressSegment) -> some View {
        let preview = seg.isPreview
        switch seg.kind {
        case .doneExercise:
            Capsule().fill(Theme.accent).frame(height: 4)
                .overlay(previewRing(preview))
        case .upcoming:
            Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                .overlay(previewRing(preview))
        case let .activeSets(done, total):
            HStack(spacing: 2) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule().fill(i < done ? Color(red: 0.5, green: 0.89, blue: 0.92) : Color.white.opacity(0.12))
                }
            }
            .frame(height: 9)
            .padding(1.5)
            .background(Capsule().fill(Theme.accent.opacity(0.16)))
            .frame(minWidth: 40)
            .layoutPriority(1)
        }
    }

    private func previewRing(_ on: Bool) -> some View {
        Capsule().stroke(Color(red: 0.78, green: 0.57, blue: 0.35), lineWidth: on ? 1.5 : 0)
    }
```

- [ ] **Step 3: Rebuild `content` as the scroll layout + preview/activate**

Replace the `content` computed property:

```swift
    @ViewBuilder
    private var content: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                pinnedHeader
                ScrollView {
                    VStack(spacing: 0) {
                        let preview = coordinator.plan.exercises[previewIdx]
                        ExerciseBannerView(
                            exercise: preview,
                            imageURL: imageResolver(preview.exerciseSlug),
                            stateTag: stateTag(for: previewIdx),
                            canPrev: previewIdx > 0,
                            canNext: previewIdx < coordinator.totalExercises - 1,
                            onPreview: movePreview
                        )
                        .frame(height: geo.size.height * 0.66)

                        RecommendationPanel(exercise: preview)

                        if previewIdx == coordinator.currentExerciseIdx {
                            VStack(spacing: 14) {
                                if coordinator.currentExercise.isDuration {
                                    DurationCard(exercise: coordinator.currentExercise, onDone: advance)
                                } else {
                                    LoggedSetChips(
                                        logged: coordinator.loggedForCurrentExercise,
                                        currentSetIdx: coordinator.currentSetIdx,
                                        targetSets: coordinator.currentExercise.targetSets)
                                    FocusSetCard(coordinator: coordinator, restTimer: restTimer)
                                }
                            }
                            .padding(.horizontal, 16).padding(.top, 14)
                        } else {
                            startExerciseButton
                        }
                    }
                }
                toolbar
            }
        }
    }

    private var startExerciseButton: some View {
        Button {
            coordinator.activate(idx: previewIdx)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text("Начать это упражнение").font(.body.weight(.medium))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().stroke(Theme.accent, lineWidth: 1).background(Capsule().fill(Theme.accent.opacity(0.16))))
        }
        .padding(.horizontal, 16).padding(.top, 16)
    }

    private func movePreview(_ delta: Int) {
        let next = previewIdx + delta
        guard coordinator.plan.exercises.indices.contains(next) else { return }
        previewIdx = next
    }

    private func stateTag(for idx: Int) -> String {
        if idx == coordinator.currentExerciseIdx {
            return WorkoutRunnerLogic.setLabel(
                currentSetIdx: coordinator.currentSetIdx,
                targetSets: coordinator.currentExercise.targetSets) ?? ""
        }
        return coordinator.logged[idx].sets.isEmpty ? "ещё не начато" : "пройдено"
    }
```

Keep `previewIdx` synced to the active exercise when it changes (so advancing/activating snaps the preview back). Add to the `ZStack` in `body`:
```swift
        .onAppear { previewIdx = coordinator.currentExerciseIdx; onAppearPrefetch() }
        .onChange(of: coordinator.currentExerciseIdx) { _, new in previewIdx = new }
```
…and remove the now-duplicated `.onAppear { onAppearPrefetch() }`.

Remove the old top-bar arguments from any remaining `ExerciseBannerView(...)` call (there is only the one in `content`). The `isLastExercise` helper and `toolbar` stay as-is. Note `RestTimerOverlay`'s `nextHint` is upgraded in Task 10.

- [ ] **Step 4: Regenerate, build**

```bash
cd ios/JarvisApp && xcodegen generate
```
`build_sim`. Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Visual check (two screenshots)**

`build_run_sim`, start a workout, `screenshot` (main: pinned bar with active set-ticks, image ⅔, recs panel, logger below on scroll). Then swipe the image to a later exercise, `screenshot` (preview: "ПРОСМОТР"/state tag + "Начать это упражнение", preview marker on the bar).

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift ios/JarvisApp/Sources/JarvisApp/Views/Workout/ExerciseBannerView.swift
git commit   # "feat(ios/workout): scroll layout, two-level progress bar, swipe-preview + activate" + co-author trailer
```

---

### Task 10: `RestTimer` wall-clock + next-exercise hint

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/RestTimer.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/RestTimerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `RestTimerTests.swift`:

```swift
@MainActor
func test_remaining_derivesFromEndDate_acrossGap() {
    let timer = RestTimer()
    var fake = Date(timeIntervalSince1970: 1000)
    timer.now = { fake }
    timer.start(planned: 60, lastRepsInReserve: 2)        // ends at 1060
    XCTAssertEqual(timer.remainingSec, 60)

    fake = Date(timeIntervalSince1970: 1045)              // simulate 45s screen-off gap
    timer.refresh()
    XCTAssertEqual(timer.remainingSec, 15)                // not frozen at 60

    fake = Date(timeIntervalSince1970: 1100)              // past the end
    timer.refresh()
    XCTAssertEqual(timer.remainingSec, 0)
    XCTAssertFalse(timer.running)
}
```

- [ ] **Step 2: Run to verify it fails**

Run `test_sim` only-testing `JarvisAppTests/RestTimerTests`. Expected: compile failure — no `now`/`refresh`.

- [ ] **Step 3: Implement wall-clock**

In `Services/RestTimer.swift`:

Add an injectable clock and an end-date:
```swift
    /// Injectable clock so the countdown derives from wall time (survives
    /// screen-off) and is unit-testable.
    var now: () -> Date = { Date() }
    private var endDate: Date?
```

Rewrite `start` so it stamps `endDate` and the tick recomputes from wall time:
```swift
    func start(planned: Int, lastRepsInReserve: Int) {
        stop()
        let effective = Self.effectiveDuration(planned: planned, rir: lastRepsInReserve)
        endDate = now().addingTimeInterval(TimeInterval(effective))
        totalSec = effective
        remainingSec = effective
        running = true
        cancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        scheduleLocalNotification(after: TimeInterval(effective))
    }
```

Add `refresh()` (also called by the view on foreground):
```swift
    /// Recompute remaining from the wall clock. Stops at zero. Safe to call any
    /// time (e.g. when the app returns to foreground after the screen slept).
    func refresh() {
        guard running, let end = endDate else { return }
        let rem = Int(ceil(end.timeIntervalSince(now())))
        if rem <= 0 {
            remainingSec = 0
            stop()
            cancelLocalNotification()
        } else {
            remainingSec = rem
        }
    }
```

In `stop()`, clear the end-date too:
```swift
    private func stop() {
        cancellable?.cancel()
        cancellable = nil
        running = false
        totalSec = 0
        endDate = nil
    }
```

(`skip()`, `effectiveDuration`, and the notification helpers are unchanged.)

- [ ] **Step 4: Run to verify it passes**

Run `test_sim` only-testing `JarvisAppTests/RestTimerTests`. Expected: PASS (existing timer tests still green — `start` still sets `remainingSec`/`totalSec`/`running`, `skip`/`stop` still zero `totalSec`).

- [ ] **Step 5: Wire foreground refresh + next-exercise hint into `WorkoutView`**

In `Views/WorkoutView.swift`, change the `RestTimerOverlay` line to compute the hint via `WorkoutRunnerLogic.restHint`:
```swift
            RestTimerOverlay(timer: restTimer, nextHint: restHint)
                .zIndex(3)
```
Add the helper:
```swift
    private var restHint: String {
        let next = coordinator.currentExerciseIdx + 1 < coordinator.totalExercises
            ? coordinator.plan.exercises[coordinator.currentExerciseIdx + 1].displayName
            : nil
        return WorkoutRunnerLogic.restHint(
            setsDone: coordinator.loggedForCurrentExercise.count,
            targetSets: coordinator.currentExercise.targetSets,
            nextExerciseName: next)
    }
```
Add the foreground refresh modifier to the `body` `ZStack`:
```swift
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restTimer.refresh() }
        }
```

- [ ] **Step 6: Build**

`build_sim`. Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/RestTimer.swift ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift ios/JarvisApp/Sources/JarvisAppTests/RestTimerTests.swift
git commit   # "feat(ios/workout): wall-clock rest timer + next-exercise rest hint" + co-author trailer
```

---

### Task 11: Version bump + full verification

**Files:**
- Modify: `ios/JarvisApp/project.yml`

- [ ] **Step 1: Bump version**

In `ios/JarvisApp/project.yml`, under `JarvisApp.settings.base`:
```yaml
        MARKETING_VERSION: "1.13.0"
        CURRENT_PROJECT_VERSION: "58"
```

- [ ] **Step 2: Regenerate**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 3: Full test suite**

Run `test_sim` only-testing `JarvisAppTests` (whole bundle). Expected: PASS — all workout model/logic/coordinator/timer tests plus the pre-existing suite (`WorkoutCardIntegrationTests`, `WorkoutPlanRealEnvelopeTests`, `TransportV2WorkoutTests`, etc.) green.

- [ ] **Step 4: Clean release build**

`build_sim` (Release config if available, else Debug). Expected: BUILD SUCCEEDED, no warnings from the touched files.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit   # "chore(ios): bump to 1.13.0 build 58 — workout runner redesign" + co-author trailer
```

---

## Self-review

**Spec coverage** (each of the 11 items → task):
1. Worded finish / `session_feeling` → Tasks 2, 5 ✓
2. Wall-clock rest timer → Task 10 ✓
3. Recs panel ⅓ + scroll layout → Tasks 8, 9 ✓
4. Browse (swipe-preview + activate) → Tasks 4, 9 ✓
5. Next-exercise rest hint → Tasks 3, 10 ✓
6. Bonus-set label → Tasks 3, 7 ✓
7. Defaults from Payne (`weight_kg_target` decode + prefill) → Tasks 1, 3, 6 ✓
8. RIR buttons 0/1/2/4 → Tasks 3, 6 ✓
9. Weight wheel → Tasks 3, 6 ✓
10. Two-level progress bar → Tasks 3, 9 ✓

**Type/signature consistency:** `complete(sessionFeeling:sessionFeelingLabel:healthSignalAtStart:)` defined in Task 5, called in Task 5's `WorkoutView` wiring and the Task-5 tests — consistent. `WorkoutSession` new fields are trailing `= nil` defaults so `TransportV2WorkoutTests:85`'s memberwise init is untouched. `ExercisePlan.weightKgTarget` (Task 1) used by `defaultWeight`/`RecommendationPanel`/`FocusSetCard` (Tasks 3/6/8). `WorkoutRunnerLogic` symbols (`snapRir`, `defaultWeight`, `weightOptions`, `setLabel`, `restHint`, `feelings`, `progressSegments`, `ProgressSegment`) defined in Task 3, consumed in Tasks 5/6/7/9/10 — names match. `ExerciseBannerView`'s new signature (Task 9, Step 1) matches its only call site (Task 9, Step 3).

**Placeholder scan:** no TBD/TODO; every code step shows full code; commands are concrete (`test_sim`/`build_sim`/`xcodegen generate`).

**Sequencing:** each task compiles on its own. Task 5 changes `complete()` and all its callers together. Tasks 8 (RecommendationPanel) and 9 (its use) are split but Task 8 builds standalone (view unused until 9).

**Risk note:** `Picker(.wheel)` with ~601 `Double` tags is heavier than a stepper but acceptable (SwiftUI lazily renders wheel rows). If the wheel feels sluggish on-device, a follow-up can narrow `weightOptions` to a window around the target — out of scope here.
