# Workout Runner Layout + Adaptivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-flow the live workout runner to fit one screen with no scroll from iPhone 12 mini to 17 Pro, fix the overall-progress bar, and restructure the logger to two-column wheels.

**Architecture:** 100% iOS (`ios/JarvisApp/`). Drop the `ScrollView`; the image is the only flexible block (16:9-capped, absorbs leftover via a trailing `Spacer`). Progress bar simplifies to equal per-exercise segments + an `N/M` counter (set-level already lives in the image scrim). Logger becomes side-by-side `Повторы`/`Вес` wheels. Pure logic stays in `WorkoutRunnerLogic` (unit-tested); SwiftUI verified by clean build + simulator screenshots on a small and a large device.

**Tech Stack:** SwiftUI/GeometryReader, XCTest (`@testable import Jarvis`), xcodegen, XcodeBuildMCP.

**Spec:** `docs/superpowers/specs/2026-06-26-workout-runner-layout-adaptive-design.md`

---

## Conventions

- **Tests:** `test_sim` with `-only-testing:JarvisAppTests/<Class>`. Build: `build_sim`. New `.swift` file → `cd ios/JarvisApp && xcodegen generate` first. Module `Jarvis`.
- **Screenshots:** `build_run_sim` then `screenshot`. For the adaptivity proof, run on a **small** sim (iPhone 12 mini if installed, else the smallest available — `list_sims`) and a **large** sim (iPhone 17 / 17 Pro). Note which sims were used.
- **Commits** end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; use `--no-verify`.
- Branch `workout-layout-adaptive`; merge to main at the end (no push by the plan).

## File structure

| File | Change |
|------|--------|
| `Models/WorkoutRunnerLogic.swift` | `ProgressSegment.Kind` → `done/active/upcoming`; `progressSegments(total:activeIdx:previewIdx:)`; add `exerciseCounter`, `repsOptions` |
| `Views/WorkoutView.swift` | progress rendering (segmentView/header counter/call) + no-scroll content layout |
| `Views/Workout/RecommendationPanel.swift` | single chip row |
| `Views/Workout/FocusSetCard.swift` | two-column wheels |
| `JarvisAppTests/WorkoutRunnerLogicTests.swift` | replace progress test; add counter + reps tests |
| `project.yml` | build 59 → 60 |

`ExerciseBannerView.swift` is **unchanged** — it already fills `maxHeight: .infinity`, so `WorkoutView`'s `.frame(maxHeight:)` sets the 16:9 height; the scrim already shows the set-level `stateTag`.

---

### Task 0: Branch

- [ ] **Step 1**
```bash
cd /Users/serg/git/nanoclaw && git checkout -b workout-layout-adaptive && git branch --show-current
```

---

### Task 1: `WorkoutRunnerLogic` progress model + counter + reps, and its `WorkoutView` consumer

Changing the model breaks `WorkoutView`'s `segmentView`/`progressSegments` compile, so they update together.

**Files:**
- Modify: `Models/WorkoutRunnerLogic.swift`
- Modify: `Views/WorkoutView.swift`
- Test: `JarvisAppTests/WorkoutRunnerLogicTests.swift`

- [ ] **Step 1: Write/replace the failing tests**

In `WorkoutRunnerLogicTests.swift`, replace `test_progressSegments_activeShowsSetsAndPreviewMark` with:

```swift
    func test_progressSegments_equalKindsAndPreviewMark() {
        let segs = WorkoutRunnerLogic.progressSegments(total: 4, activeIdx: 1, previewIdx: 3)
        XCTAssertEqual(segs.map(\.kind), [.done, .active, .upcoming, .upcoming])
        XCTAssertTrue(segs[3].isPreview)
        XCTAssertFalse(segs[1].isPreview)
    }

    func test_exerciseCounter_oneBased_clamped() {
        XCTAssertEqual(WorkoutRunnerLogic.exerciseCounter(activeIdx: 2, total: 6), "3/6")
        XCTAssertEqual(WorkoutRunnerLogic.exerciseCounter(activeIdx: 5, total: 6), "6/6")
    }

    func test_repsOptions_spans1to30() {
        XCTAssertEqual(WorkoutRunnerLogic.repsOptions.first, 1)
        XCTAssertEqual(WorkoutRunnerLogic.repsOptions.last, 30)
    }
```

- [ ] **Step 2: Run — expect compile failure**

`test_sim` only-testing `JarvisAppTests/WorkoutRunnerLogicTests` → FAIL (`.activeSets` gone / `exerciseCounter`/`repsOptions` undefined).

- [ ] **Step 3: Update `WorkoutRunnerLogic.swift`**

Replace the `ProgressSegment` struct + `progressSegments` func (lines ~62-90) with:

```swift
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
```

- [ ] **Step 4: Update `WorkoutView.swift` progress rendering**

Replace `progressSegments` (lines ~141-148):
```swift
    private var progressSegments: [WorkoutRunnerLogic.ProgressSegment] {
        WorkoutRunnerLogic.progressSegments(
            total: coordinator.totalExercises,
            activeIdx: coordinator.currentExerciseIdx,
            previewIdx: previewIdx)
    }
```

Replace `segmentView` (lines ~150-171) with an equal capsule:
```swift
    @ViewBuilder
    private func segmentView(_ seg: WorkoutRunnerLogic.ProgressSegment) -> some View {
        let fill: Color = {
            switch seg.kind {
            case .done: return Theme.accent
            case .active: return Color(red: 0.5, green: 0.89, blue: 0.92)
            case .upcoming: return Color.white.opacity(0.2)
            }
        }()
        Capsule().fill(fill).frame(height: 5)
            .overlay(previewRing(seg.kind == .active || seg.isPreview))
    }
```

In `pinnedHeader` (lines ~123-139), add the counter between the segments and the Дальше button — replace the body with:
```swift
    private var pinnedHeader: some View {
        HStack(spacing: 10) {
            Button { showAbortConfirm = true } label: {
                Image(systemName: "xmark").font(.body).foregroundStyle(.white).frame(width: 32, height: 32)
            }
            HStack(spacing: 3) {
                ForEach(Array(progressSegments.enumerated()), id: \.offset) { _, seg in
                    segmentView(seg)
                }
            }
            Text(WorkoutRunnerLogic.exerciseCounter(activeIdx: coordinator.currentExerciseIdx, total: coordinator.totalExercises))
                .font(.caption).monospacedDigit().foregroundStyle(.white)
            Button(action: advance) {
                Text(isLastExercise ? "Финиш" : "Дальше →").font(.subheadline).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.background)
    }
```

- [ ] **Step 5: Run + build**

`test_sim` only-testing `JarvisAppTests/WorkoutRunnerLogicTests` → PASS. `build_sim` → BUILD SUCCEEDED.

- [ ] **Step 6: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift
git commit --no-verify   # "feat(ios/workout): equal-segment progress bar + N/M counter" + co-author
```

---

### Task 2: `WorkoutView` no-scroll one-screen layout

**Files:**
- Modify: `Views/WorkoutView.swift`

- [ ] **Step 1: Replace `content`**

Replace the `content` computed property (lines ~80-121) with the no-scroll layout — image is the only flexible block (16:9-capped via `maxHeight: width*9/16`), a trailing `Spacer` absorbs slack on tall screens:

```swift
    @ViewBuilder
    private var content: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                pinnedHeader

                let preview = coordinator.plan.exercises[previewIdx]
                ExerciseBannerView(
                    exercise: preview,
                    imageURL: imageResolver(preview.exerciseSlug),
                    stateTag: stateTag(for: previewIdx),
                    canPrev: previewIdx > 0,
                    canNext: previewIdx < coordinator.totalExercises - 1,
                    onPreview: movePreview
                )
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: geo.size.width * 9.0 / 16.0)
                .clipped()

                RecommendationPanel(exercise: preview)

                if previewIdx == coordinator.currentExerciseIdx {
                    if coordinator.currentExercise.isDuration {
                        DurationCard(exercise: coordinator.currentExercise, onDone: advance)
                            .padding(.horizontal, 16).padding(.top, 12)
                    } else {
                        VStack(spacing: 10) {
                            LoggedSetChips(
                                logged: coordinator.loggedForCurrentExercise,
                                currentSetIdx: coordinator.currentSetIdx,
                                targetSets: coordinator.currentExercise.targetSets)
                            FocusSetCard(coordinator: coordinator, restTimer: restTimer)
                        }
                        .padding(.horizontal, 16).padding(.top, 10)
                    }
                } else {
                    startExerciseButton
                }

                Spacer(minLength: 0)
                toolbar
            }
        }
    }
```

- [ ] **Step 2: Build**

`build_sim` → BUILD SUCCEEDED.

- [ ] **Step 3: Visual check on small + large sims**

`list_sims`. Pick a small device (iPhone 12 mini if present, else smallest) and a large (iPhone 17 / 17 Pro). For each: `build_run_sim` (targeting that sim) → start a workout → `screenshot`. Confirm: no scroll, record button fully visible (not clipped), image 16:9, progress bar = equal segments + `N/M`. Note the two sims used. (Offline sim can't source a real plan — if the runner can't be reached without a server, fall back to verifying the layout compiles + a static preview; the on-device proof is Sergei on build 60.)

- [ ] **Step 4: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift
git commit --no-verify   # "feat(ios/workout): one-screen no-scroll runner (16:9 image absorbs slack)" + co-author
```

---

### Task 3: `RecommendationPanel` single row

**Files:**
- Modify: `Views/Workout/RecommendationPanel.swift`

- [ ] **Step 1: Replace `body`**

```swift
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(copper)
            Text("ПЕЙН").font(.caption2).foregroundStyle(copper)
            if let w = exercise.weightKgTarget { chip("\(WorkoutSetFormat.weight(w)) кг") }
            if exercise.targetSets > 0 { chip("\(exercise.targetSets)×\(exercise.targetReps)") }
            chip("запас \(exercise.targetRir)")
            if exercise.restSec > 0 { chip(restLabel(exercise.restSec)) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(red: 0.08, green: 0.078, blue: 0.06))
        .overlay(alignment: .top) { Rectangle().fill(copper.opacity(0.35)).frame(height: 1) }
    }
```

And shrink the chip to caption so 4 chips fit at 375pt — replace `chip`:
```swift
    private func chip(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
    }
```

- [ ] **Step 2: Build**

`build_sim` → BUILD SUCCEEDED.

- [ ] **Step 3: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/RecommendationPanel.swift
git commit --no-verify   # "feat(ios/workout): single-row recommendation panel" + co-author
```

---

### Task 4: `FocusSetCard` two-column wheels

**Files:**
- Modify: `Views/Workout/FocusSetCard.swift`

- [ ] **Step 1: Replace `body` + `weightRow`/`stepperRow` with two wheel columns**

Replace the `body` (lines ~19-49):
```swift
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                wheelColumn(title: "Повторы") {
                    Picker("Повторы", selection: $reps) {
                        ForEach(WorkoutRunnerLogic.repsOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                wheelColumn(title: "Вес, кг") {
                    Picker("Вес", selection: $weight) {
                        ForEach(WorkoutRunnerLogic.weightOptions, id: \.self) { Text(WorkoutSetFormat.weight($0)).tag($0) }
                    }
                }
            }
            rirRow

            Button(action: logCurrent) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold))
                    Text("Записать подход").font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Capsule().fill(Theme.accent))
            }
            .disabled(coordinator.isFinished)
        }
        .onAppear(perform: prefill)
        .onChange(of: coordinator.currentSetIdx) { _, _ in prefillKeepWeight() }
        .onChange(of: coordinator.currentExerciseIdx) { _, _ in prefill() }
    }

    @ViewBuilder
    private func wheelColumn<P: View>(title: String, @ViewBuilder picker: () -> P) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.6))
            picker()
                .pickerStyle(.wheel)
                .frame(height: 100)
                .clipped()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
    }
```

Delete the now-unused `weightRow` (lines ~51-70) and `stepperRow` + `circle` (lines ~113-140). Keep `rirRow`, `logCurrent`, `prefill`, `prefillKeepWeight`.

- [ ] **Step 2: Clamp reps default into the wheel range**

In `prefill` and `prefillKeepWeight`, ensure `reps` is always a valid `repsOptions` member (a logged 0 or >30 would blank the wheel). Replace the `reps = …` lines:

In `prefill`:
```swift
        reps = min(max(prev?.reps ?? WorkoutSetFormat.midReps(targetReps: coordinator.currentExercise.targetReps), 1), 30)
```
In `prefillKeepWeight`:
```swift
        reps = min(max(prev?.reps ?? reps, 1), 30)
```

- [ ] **Step 3: Build**

`build_sim` → BUILD SUCCEEDED.

- [ ] **Step 4: Visual check**

`build_run_sim` (small sim) → start a workout → `screenshot`. Confirm: `Повторы` and `Вес` wheels side by side (headers above), `Запас` buttons + Записать below, everything on one screen.

- [ ] **Step 5: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/FocusSetCard.swift
git commit --no-verify   # "feat(ios/workout): two-column reps/weight wheels" + co-author
```

---

### Task 5: Version bump + full verify

**Files:**
- Modify: `ios/JarvisApp/project.yml`

- [ ] **Step 1: Bump**

`project.yml`: `CURRENT_PROJECT_VERSION: "59"` → `"60"` (leave `MARKETING_VERSION: "1.13.0"`).

- [ ] **Step 2: Regenerate + full suite + clean build**

```bash
cd ios/JarvisApp && xcodegen generate
```
`test_sim` only-testing `JarvisAppTests` (whole bundle) → all pass (esp. `WorkoutRunnerLogicTests`). `build_sim` → BUILD SUCCEEDED.

- [ ] **Step 3: Commit**
```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit --no-verify   # "chore(ios): bump to build 60 — one-screen adaptive runner" + co-author
```

---

### Task 6: Merge

- [ ] **Step 1** (after all tasks pass — use finishing-a-development-branch)
```bash
git checkout main && git merge --ff-only workout-layout-adaptive && git branch -d workout-layout-adaptive
```
Then this unblocks the **antitrainer gif batch** (separate follow-up): 99 `mp4 → gif` at 360px/12fps, no crop (16:9 native), validate + drop broken, write `exercises/<slug>.gif`.

---

## Self-review

**Spec coverage:** 16:9 one-screen layout → Task 2 (image `maxHeight: width*9/16` + `Spacer`, no ScrollView) ✓; progress bar A → Task 1 (equal segments + `exerciseCounter`) ✓; logger 2-col wheels → Task 4 ✓; recs single row → Task 3 ✓; build 60 → Task 5 ✓; banner unchanged (confirmed — fills caller frame) ✓; gif batch unblocked → Task 6 note ✓.

**Type/signature consistency:** `progressSegments(total:activeIdx:previewIdx:)` defined Task 1, called Task 1's `WorkoutView` update; `ProgressSegment.Kind` `done/active/upcoming` used in `segmentView` + tests; `exerciseCounter` + `repsOptions` defined Task 1, used in `pinnedHeader` (Task 1) + `FocusSetCard` (Task 4) + tests. `WorkoutSetFormat.weight/midReps`, `WorkoutRunnerLogic.weightOptions/defaultWeight/snapRir/rirButtons` unchanged.

**Placeholder scan:** every code step shows full code; commands concrete. The one soft spot — `RecommendationPanel` 4 chips fitting at 375pt — is mitigated (caption font, `lineLimit(1)`); confirmed by the Task 3 build + Task 2 small-sim screenshot.

**Risk:** SwiftUI layout (image flex + Spacer) is screenshot-verified, not unit-tested — the `WorkoutRunnerLogicTests` cover the pure logic only; the no-scroll fit is proven on small + large sims (Task 2/4) and on-device build 60 by Sergei. If the small sim can't reach a live runner offline, the layout is build-verified and the fit is confirmed on-device.
