# Workout Runner Layout + Adaptivity Redesign — Design Spec

**Date:** 2026-06-26
**Surface:** iOS only (`ios/JarvisApp/`), build 60. No host/container/Payne change.
**Goal:** Make the live workout runner fit on **one screen with no scroll**, from iPhone 12 mini up to 17 Pro, fixing the clipping Sergei hit on the 12 mini (build 58/59) and making overall workout progress legible. The image-slot aspect is fixed at **16:9**, which also unblocks the antitrainer gif batch (native crop-free).

## Why (from build 58/59 device feedback, all on a 12 mini)

The current layout is `pinnedHeader + ScrollView{ image(0.66·height) + RecommendationPanel + logger } + toolbar`. The image at `geo.height·0.66` (~480pt) pushes the logger/recs below the fold on a short screen → only the edge of the record button / start button / duration card peeks above the toolbar (#4/#6/#5-bottom). The two-level progress bar (fat active segment with set-ticks) reads as a featureless "monolith" and hides overall progress (#5-top/#7).

## Decisions (from brainstorm, all confirmed)

- **Image slot = 16:9** (not square). Shortest slot → best one-screen fit; full demo frame (no side crop); gif served native 580×326, no crop in the batch. (Square was the initial instinct but is the *tallest* slot — worst for one-screen.)
- **Progress bar A**: one equal segment per exercise + a `N/M` counter; active segment gets a copper outline; warmup is just another segment. The set-level (`подход 1/3`) leaves the bar and lives in the image scrim.
- **Logger = two columns of wheels**: `Повторы` and `Вес` side-by-side wheels (headers above), since a wheel is vertical — stacking two wheel-height rows wastes vertical. `Запас` buttons + `Записать подход` below.
- **No ScrollView**: everything fits; the image absorbs leftover vertical space.

---

## Layout (no scroll)

```
GeometryReader:
  VStack(spacing: 0):
    pinnedHeader        // progress A (segments + N/M) + ✕ + Дальше      [fixed ~48]
    ExerciseBannerView  // 16:9 image + scrim(name · подход 1/3)         [FLEXIBLE]
    RecommendationPanel // single chip row                                [fixed ~48]
    activeArea          // logger (2-col wheels + RIR + Записать)         [fixed]
                        //   or, in preview, "Начать это упражнение"      [fixed, smaller]
    toolbar             // заменить / отдых / финиш                       [fixed ~64]
```

**Image height (the only flexible block):** computed in the `GeometryReader`, deterministic per device:

```
let maxByWidth = geo.size.width * 9.0/16.0          // full 16:9 (~211 at 375pt)
let leftover   = geo.size.height - fixedChunksHeight // header+recs+logger+toolbar+safeareas
let imageH     = min(maxByWidth, max(120, leftover)) // clamp: never below 120, never above 16:9
```

`fixedChunksHeight` is the sum of the fixed blocks' heights (a small set of layout constants, tuned on-device). On a 12 mini `leftover < maxByWidth` → image is a bit shorter than full 16:9 (the gif aspect-fills, cropping a sliver top/bottom). On a 17 Pro `leftover > maxByWidth` → image caps at full 16:9 and the surplus becomes even spacing. The image uses `AnimatedExerciseImage` (already built) with `.scaleAspectFill`, clipped.

This removes the ScrollView entirely. If, on the very smallest device, content still can't fit at `imageH == 120`, the activeArea (logger) is the overflow sink via a *single* inner `ScrollView` around just the logger — but the target is no-scroll, and the math above fits the 12 mini.

## Progress bar A — `pinnedHeader` + `WorkoutRunnerLogic`

Simplify the two-level model to equal segments:

- `WorkoutRunnerLogic.ProgressSegment.Kind` → `{ done, active, upcoming }` (drop `activeSets(done:total:)`).
- `progressSegments(total:activeIdx:previewIdx:)` → one equal segment per exercise: `i < activeIdx` → `done`; `i == activeIdx` → `active`; else `upcoming`; `isPreview = i == previewIdx && previewIdx != activeIdx`.
- New `exerciseCounter(activeIdx:total:) -> String` → `"\(activeIdx + 1)/\(total)"`.
- Header renders: `✕` · `HStack` of equal-width capsules (done = accent, active = bright + copper outline, upcoming = dim) · `N/M` label · `Дальше →`.
- The set-level position label (`подход 1/3` / `бонусный подход`, from `WorkoutRunnerLogic.setLabel`) moves to the **scrim** in `ExerciseBannerView` (it already receives `stateTag`).

This fixes #7 (overall obvious) and #5 (always-divided segments, warmup is a normal segment, no monolith).

## `ExerciseBannerView`

- Image area uses an explicit 16:9 height (passed from `WorkoutView`'s computed `imageH`) instead of the caller's `0.66·height`.
- Scrim (bottom): `displayName` left, `stateTag` right — `stateTag` is the set-level (`подход 1/3` / `бонусный подход` / `ещё не начато`), unchanged source (`WorkoutView.stateTag(for:)`).
- Swipe + chevrons (preview) unchanged.

## `RecommendationPanel`

Collapse to a **single horizontal chip row** (was multi-line): `ПЕЙН:` label + chips `60 кг`, `3×8`, `запас 2`, `2:00`. Drop the separate notes line from the runner panel (notes still available; keep it out of the one-screen budget — or show only if it fits). Height ~44–48pt.

## `FocusSetCard` — two-column wheels

Replace the stacked rows with:

```
HStack:
  VStack { "Повторы";  Picker(.wheel, repsOptions) }     // reps is now a wheel too
  VStack { "Вес, кг";  Picker(.wheel, weightOptions) }   // existing 0…300 by 0.5
Запас:  [0] [1] [2] [4]                                   // buttons (unchanged)
[ Записать подход ]                                        // primary button (unchanged)
```

- Add `WorkoutRunnerLogic.repsOptions = Array(1...30)`; reps default = `WorkoutSetFormat.midReps(targetReps)` snapped into the list.
- Weight wheel, defaults from `weight_kg_target`, RIR snap, prefill — all unchanged from build 58.
- Both wheels share the same height (one wheel-row instead of two stacked) → saves vertical for the 12 mini.

## Unchanged (from build 58/59)

Preview/activate + swipe, `WorkoutFinishView`, RIR buttons `0/1/2/4`, weight wheel + Payne-seeded defaults, bonus-set label, wall-clock `RestTimer` + next-exercise hint, `serveImageRequests` + `AnimatedExerciseImage` + resolver fallback. The redesign only re-flows the runner shell + simplifies the progress bar + restructures the logger.

## Files

| File | Change |
|------|--------|
| `Models/WorkoutRunnerLogic.swift` | `ProgressSegment.Kind` → done/active/upcoming; `progressSegments` equal; add `exerciseCounter`, `repsOptions` |
| `Views/WorkoutView.swift` | no ScrollView; `GeometryReader` image-height clamp; header renders equal segments + `N/M`; pass `imageH` to banner |
| `Views/Workout/ExerciseBannerView.swift` | 16:9 height param; scrim shows set-level `stateTag` |
| `Views/Workout/RecommendationPanel.swift` | single chip row |
| `Views/Workout/FocusSetCard.swift` | two-column wheels (`Повторы` \| `Вес`) + RIR + record |
| `JarvisAppTests/WorkoutRunnerLogicTests.swift` | update `progressSegments` tests; add `exerciseCounter`, `repsOptions` |
| `project.yml` | build 59 → 60 |

## Tests

- `WorkoutRunnerLogicTests`: `progressSegments` yields equal `done/active/upcoming` with the right `isPreview`; `exerciseCounter(activeIdx:2, total:6) == "3/6"`; `repsOptions` spans 1…30.
- Layout (image clamp, no-scroll, two-col wheels) is SwiftUI — verified by clean build + simulator screenshots on **both** an `iPhone 12 mini` and an `iPhone 17 Pro` sim (the adaptive proof). Behavioral confirm = Sergei on-device build 60.

## Out of scope / unblocks

- **Antitrainer gif batch** (99 exercises) is now unblocked: slot is 16:9 = native source aspect → batch converts `mp4 → gif` at 360px/12fps **with no crop**, validates (drop broken), writes `exercises/<slug>.gif`. Runs after this ships. The 35 without `gif_url` still need the antitrainer API.
- Coach rework — separate future round.
