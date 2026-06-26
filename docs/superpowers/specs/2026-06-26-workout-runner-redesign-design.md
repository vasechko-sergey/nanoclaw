# Workout Runner Redesign — Design Spec

**Date:** 2026-06-26
**Surface:** iOS app only (`ios/JarvisApp/`). Zero host build, zero Payne skill edit.
**Goal:** Rework the live workout runner (`WorkoutView` + subviews) to fix 11 usability gaps Sergei reported, surfacing Payne's per-exercise recommendations, making set entry fast, and making the rest timer + finish flow honest.

## Why iOS-only

- Payne already sends every recommendation the UI needs. The real on-device envelope (`WorkoutPlanRealEnvelopeTests.swift`) carries `weight_kg_target` per exercise (e.g. `66.25`, `25`); `target_reps`, `reps_in_reserve`, `rest_seconds`, `notes` are also present. The runner just never decodes/shows them.
- The finish-feedback change adds a field to `workout_complete`'s session JSON. `WorkoutBridge.handleInbound` (`src/channels/ios-app/v2/workout-bridge.ts:71`) does `JSON.stringify({ event, payload })` — verbatim pass-through, no schema, no field stripping. A new `session_feeling` reaches Payne unaltered. Payne is an LLM; it reads the worded label without a parser change.

## Confirmed decisions (from brainstorm)

- **Logger access:** scroll model. Pinned progress bar → image ⅔ viewport → recommendations ⅓ → set logger below the fold (revealed by scroll).
- **Browse exercises:** swipe/chevrons **preview** another exercise (read-only); a "Начать это упражнение" button **activates** it for logging. Active index and preview index are distinct.
- **Finish rating:** 5 **worded** gradations (not numbers, not emoji), full-screen terminal step (not a swipeable sheet).
- **Weight wheel:** `0.5 kg` step.

---

## Feature → change map

| # | Complaint | Change |
|---|-----------|--------|
| 1 | Finish asks redundant overall-RIR (per-set RIR already logged) | Replace with 5-point worded "как прошла" → `session_feeling` (+label) to Payne |
| 2 | Rest timer freezes when screen sleeps | Wall-clock `endDate` + `refresh()` on foreground; notification unchanged |
| 3 | Payne's recommendations invisible during workout | New `RecommendationPanel` (⅓ screen) under the image |
| 4 | Can't browse to another exercise (machine busy) | Swipe/chevron preview + "Начать это упражнение" to activate |
| 5 | Rest timer shows "подход N" even after last set | When current exercise's sets done → show **next exercise** name + recs |
| 6 | "4 подход из 3" reads absurd | Past target → label "бонусный подход" |
| 7 | Defaults are arbitrary | Pre-fill weight/reps/запас from Payne's plan (`weight_kg_target`/`target_reps`/`reps_in_reserve`) |
| 8 | RIR stepper too granular | 4 buttons `0 / 1 / 2 / 4` (no 3) |
| 9 | Weight needs many +taps | Wheel picker (`.wheel`), 0.5 kg step |
| 10 | Top bar one color (exercises only) | Two-level bar: done exercises solid + active exercise split into set-ticks |

---

## Data model — `Models/Workout.swift`

**`ExercisePlan`**
- Add `var weightKgTarget: Double?`, CodingKey `weight_kg_target`. Decode tolerant (`try?`), encode `encodeIfPresent` (B2 round-trip stays stable).

**`WorkoutSession`**
- Add `var sessionFeeling: Int?` (1–5), CodingKey `session_feeling`.
- Add `var sessionFeelingLabel: String?`, CodingKey `session_feeling_label`.
- Stop populating `perceivedOverallRir` (leave the field for back-compat; finish flow sends `nil`).

**Feeling map (single source of truth, e.g. `WorkoutFinishView.feelings`)**
```
1 "Тяжело, еле дотянул"
2 "Тяжеловато"
3 "Нормально"
4 "Хорошо, с запасом"
5 "Легко, мог больше"
```

## Coordinator — `Services/WorkoutCoordinator.swift`

Minimal, low-risk. Logging stays per-exercise (the `logged: [LoggedExercise]` array is already indexed by exercise).

- Add `func activate(idx: Int)`: guard `0..<plan.exercises.count`; set `currentExerciseIdx = idx`; set `currentSetIdx = logged[idx].sets.count`. Enables free order and resuming a half-done exercise.
- `finishExercise`'s linear advance becomes `activate(currentExerciseIdx + 1)` when not last (same observable behavior).
- No other state changes. `currentSetIdx` may exceed `targetSets` (bonus) exactly as today — only the *label* changes (see views).
- Add read helpers if needed: `func exercise(at:) -> ExercisePlan`, `func logged(at:) -> [LoggedSet]` for the preview panel.

## Views

### `Views/Workout/ExerciseBannerView.swift`
The banner keeps the **image + bottom scrim + swipe/chevrons**. The top controls (progress bar, ✕, "Дальше →") move to `WorkoutView`'s pinned header (the bar component itself can live here and be hosted by the header).
- **Two-level progress bar** (rendered in the pinned header) replacing the flat capsule row:
  - Completed exercises (`i < active`): solid accent capsule.
  - Active exercise: a wider segment subdivided into `targetSets` ticks; `loggedCount` filled bright, rest dim. (Warmup/duration exercise `targetSets == 0` → render as a single solid tick.)
  - Upcoming (`i > active`): dim.
  - If `previewIdx != active`: outline marker on the preview segment.
- **Swipe:** `DragGesture` on the image → prev/next `previewIdx` (clamped). Chevron buttons do the same. Both call an `onPreview(delta:)` closure owned by `WorkoutView`.
- Bottom scrim shows the **previewed** exercise's `displayName` + a state tag ("ещё не начато" / position).

### `Views/Workout/RecommendationPanel.swift` (new)
- Inputs: an `ExercisePlan` (the previewed one).
- Copper-accented panel: header "РЕКОМЕНДАЦИЯ ПЕЙНА"; chips for `weightKgTarget` ("66 кг", omit if nil), `targetSets × targetReps` ("4 × 5-6"), `запас targetRir`, `отдых restSec` (mm:ss); then `notes` text if present.
- Plain-language only (no abbreviations) per house style.

### `Views/WorkoutView.swift`
- Owns `@State private var previewIdx: Int` (init = `coordinator.currentExerciseIdx`); resets to active whenever `currentExerciseIdx` changes.
- **Layout (scroll model):** extract the top controls (progress bar + close ✕ + "Дальше →") out of `ExerciseBannerView` into a **pinned header** so they stay visible while the image scrolls away. The banner keeps only the image + bottom scrim.
  ```
  VStack(spacing 0):
    pinnedHeader          // two-level progress bar + ✕ + Дальше → (always visible)
    ScrollView:
      ExerciseBannerView  // image + scrim, height = geo.height * 0.66 (scrolls)
      RecommendationPanel(exercise: coordinator.exercise(at: previewIdx))
      if previewIdx == coordinator.currentExerciseIdx:
        FocusSetCard(...)         // the logger
      else:
        startExerciseButton      // "Начать это упражнение" → coordinator.activate(previewIdx)
    toolbar                // заменить / отдых / финиш (kept)
  ```
- **Rest hint (#5):** compute and pass to `RestTimerOverlay`:
  - if `logged(at: active).count >= targetSets` (sets done) and not last → `"<следующее упражнение>"` + its recs summary;
  - else → `"подход \(currentSetIdx + 1)"`.
- **Finish (#1):** replace `.sheet(isPresented:)`/`finishSheet`/`finishOverallRir`/`.presentationDetents` with `.fullScreenCover(isPresented: $showFinish) { WorkoutFinishView(...) }`.

### `Views/Workout/WorkoutFinishView.swift` (new)
- Full-screen, solid background, **no grabber, no peek-behind**.
- Top-left "‹ Отмена" → dismiss, coordinator untouched (returns to runner; "финиш" is tappable mid-workout so a real escape is required).
- Header: flag icon + "Тренировка завершена" + summary line ("`dayName` · N упражнений · M подходов" from `logged`).
- 5 worded rows (the feeling map); single selection; default = feeling `4` ("Хорошо, с запасом").
- "Готово" (pinned bottom) → `coordinator.complete(sessionFeeling: sel, sessionFeelingLabel: feelings[sel])` → `restTimer.skip()` → `onClose(session)`.
- `coordinator.complete` signature changes from `complete(perceivedOverallRir:)` to `complete(sessionFeeling:sessionFeelingLabel:healthSignalAtStart:)`.

### `Views/Workout/FocusSetCard.swift`
- **Weight (#9):** replace the +/- stepper row with `Picker(.wheel)` over `Array(stride(from: 0.0, through: 300.0, by: 0.5))`, bound to a weight value. Default selection = nearest step to `weightKgTarget ?? prevLoggedWeight ?? 20`.
- **Запас (#8):** replace the stepper with 4 buttons `[0, 1, 2, 4]`. Default = nearest member to `targetRir`. Selected = accent fill.
- **Reps:** keep the stepper. Default = `WorkoutSetFormat.midReps(targetReps)`.
- `prefill`/`prefillKeepWeight` updated to seed weight from `weightKgTarget` on the first set of an exercise (fall back to last logged, then 20).

### `Views/Workout/LoggedSetChips.swift`
- **Bonus label (#6):** position chip is `currentSetIdx >= targetSets ? "бонусный подход" : "подход \(currentSetIdx + 1) из \(targetSets)"`. Suppress entirely for `targetSets == 0` (duration/warmup).

### `Services/RestTimer.swift`
- **Wall-clock (#2):** store `endDate: Date` on `start`. `remainingSec = max(0, ceil(endDate - now))`. The 1 Hz `Timer.publish` recomputes from wall clock (not decrement). Add `func refresh()` that recomputes `remainingSec` from `endDate`; `WorkoutView` calls it on `scenePhase == .active`. Local notification scheduling stays as-is.
- Result: backgrounded/locked → on return the displayed countdown is correct (no freeze, no drift).

## Tests — `Sources/JarvisAppTests/`

- `WorkoutModelsTests` (or new): `ExercisePlan` decodes `weight_kg_target` from the real envelope; `WorkoutSession` encodes `session_feeling` + `session_feeling_label`.
- `WorkoutCoordinatorTests`: `activate(idx:)` sets active + `currentSetIdx = logged.count`; logging into a non-linear index appends to the right exercise; resuming a half-done exercise continues its set count.
- Bonus-label boundary: `currentSetIdx == targetSets` → "бонусный подход"; `< targetSets` → "подход N из M".
- `RestTimerTests`: `remainingSec` derives from `endDate` — inject a clock / simulate a time jump and assert the value is correct after a gap (proves no freeze/drift). `effectiveDuration` rule unchanged.

## Version + project

- `ios/JarvisApp/project.yml`: `CURRENT_PROJECT_VERSION` 57 → 58; `MARKETING_VERSION` 1.12.0 → 1.13.0 (feature).
- Run `xcodegen generate`; commit the regenerated `project.pbxproj`.

## Files

**New (2):** `Views/Workout/RecommendationPanel.swift`, `Views/Workout/WorkoutFinishView.swift`
**Modified (8):** `Models/Workout.swift`, `Services/WorkoutCoordinator.swift`, `Services/RestTimer.swift`, `Views/WorkoutView.swift`, `Views/Workout/ExerciseBannerView.swift`, `Views/Workout/FocusSetCard.swift`, `Views/Workout/LoggedSetChips.swift`, `project.yml`
**Tests:** `WorkoutModelsTests.swift`, `WorkoutCoordinatorTests.swift`, `RestTimerTests.swift` (extend existing)

## Out of scope / non-goals

- No host or Payne changes. (Optional later: a one-line note in Payne's skill that `session_feeling` is 1=tough…5=easy — not required since the label text is self-describing.)
- The existing `2026-06-26` workout card already in the chat won't change retroactively.
- No change to image prefetch, swap flow, abort flow, or the set-log delivery queue.
