# Workout Runner Redesign (Variant B — focus controls) — Design

**Goal:** Redesign the live workout runner (`WorkoutView`) into a cohesive, gym-friendly "one set at a time" screen, fixing three concrete complaints: (1) the swap sheet clashes with the dark app background, (2) the exercise image wasn't showing, (3) elements are scattered.

**Architecture:** Rework `WorkoutView`'s body into stacked sections (image banner → logged-set chips → big focus card → primary log button → icon toolbar). Replace the multi-row `ActiveSetRowView` with a large-control focus card. Dark-theme `SwapSheet`. Reuse the existing `WorkoutCoordinator` API, `RestTimer`/`RestTimerOverlay`, `CoachBannerView`, and the slug→manifest→sha256→cache `imageResolver` unchanged.

**Tech Stack:** SwiftUI, existing `WorkoutCoordinator` (`logSet`/`finishExercise`/`complete`/`currentSetIdx`/`loggedForCurrentExercise`/`readyToComplete`/`currentExercise`/`currentExerciseIdx`/`totalExercises`), `ExerciseImageCache`.

Chosen variant: **B** (focus controls) from the two mockups presented 2026-06-23.

---

## Current state (mapped)

- `WorkoutView` body: `navbar` (✕ / day+week / spacer) → `progressDots` → `ScrollView`(`ExerciseCardView` + logged `LoggedSetRow`s + `ActiveSetRowView`) → `bottomBar` ("закончить упражнение" / "Финиш"). Overlays: `CoachBannerView`, `RestTimerOverlay`. `.preferredColorScheme(.dark)`. Abort alert + finish sheet.
- `ActiveSetRowView` (`SetRowView.swift`): three stacked `Stepper` rows (повторы / вес / запас) + a small ✓ circle that calls `coordinator.logSet(...)` + `restTimer.start(...)`. Pre-fills from last set; reacts to set/exercise index changes.
- `LoggedSetRow`: read-only "#n reps × weight кг · ещё мог N · ✓".
- `ExerciseCardView`: image (resolver) or `figure.strengthtraining.traditional` placeholder + title + spec + notes + "заменить" → `onSwap`.
- `SwapSheet`: `NavigationStack` with DEFAULT (light/grouped) styling → clashes with the dark app. Inputs: `originalSlug`, `@Binding response`, `@Binding loading`, `onAction`.
- Coordinator advance is linear: `logSet` advances `currentSetIdx`; `finishExercise` advances `currentExerciseIdx` (or flips to ready-to-complete); `readyToComplete` true on last exercise after its sets; `complete(perceivedOverallRir:)` ends.

---

## New `WorkoutView` layout (Variant B)

Top → bottom, all on `Theme.background`:

1. **Top bar:** ✕ (abort, left) · thin segmented progress (one segment per exercise, filled ≤ current) · "Дальше →" (right) that advances the exercise (`finishExercise`); on the last exercise it reads "Финиш" and opens the finish sheet. Day/week/intensity as a small caption under the bar.

2. **Image banner** (`ExerciseBannerView`, new): full-width, ~150pt tall, `Theme.radius`. Loads `imageResolver(currentExercise.exerciseSlug)`; on nil/missing shows the `figure.strengthtraining.traditional` placeholder centered on `Theme.surface`. Exercise name + "{idx+1}/{total}" overlaid on a SOLID scrim band (`Color.black.opacity(0.72)`) at the bottom (no gradients).

3. **Logged-set chips** (`LoggedSetChips`, new): horizontal wrap of compact chips, one per logged set of the current exercise ("✓ {reps}×{weight}"), plus a muted "подход {currentSetIdx+1} из {targetSets}" chip and a "RIR {targetRir}" chip. Replaces the stacked `LoggedSetRow` list.

4. **Focus card** (`FocusSetCard`, replaces `ActiveSetRowView`): `Theme.surface` rounded card with two big stepper rows — **Повторы** and **Вес, кг** — each: label left; right = a 34pt "−" circle, a 26pt value, a 34pt "+" circle (large tap targets). A third compact row for **запас (RIR)** (smaller −/+). State (`reps`/`weight`/`rir`) + pre-fill/on-change logic carried over verbatim from `ActiveSetRowView`.

5. **Primary button:** full-width "Записать подход" (`Theme.accent` fill) → `coordinator.logSet(reps:weight:repsInReserve:ts:)` + `restTimer.start(planned:lastRepsInReserve:)` (same as today's ✓).

6. **Icon toolbar:** three icon+label items — **заменить** (`arrow.2.squarepath` → `onSwap(currentExercise.exerciseSlug)`), **отдых** (`timer` → `restTimer.start(planned:lastRepsInReserve:)` to show/restart the overlay), **финиш** (`flag` → opens the finish sheet → `complete`).

Overlays unchanged: `CoachBannerView` (coach_message) + `RestTimerOverlay`. Abort alert + finish sheet unchanged in behavior (finish sheet may be lightly restyled for dark consistency).

**Advance/finish semantics:** logging is the primary button (log as many sets as you want — warmup has `targetSets:0`). Navigation between exercises is the top-right "Дальше →" (`finishExercise`). Finishing the whole workout is the toolbar "финиш" (and "Дальше →" becomes "Финиш" on the last exercise). This separates log / navigate / finish cleanly — no scattered bottom bar.

## Swap sheet theming (fix #1)

- Add `.presentationBackground(Theme.background)` to the `SwapSheet`'s `NavigationStack` (iOS 16.4+; min target is 18.0 so available).
- Restyle `SwapSheet` content to dark: section containers on `Theme.surface`, text `Theme.textPrimary`/secondary, the "Предложи варианты" + confirm CTAs use `Theme.accent`, the alternatives list uses `Theme.surface` rows with hairline separators. Remove reliance on default `Form`/grouped-list chrome. Toolbar "Отмена" tinted `Theme.accent`.
- `.preferredColorScheme(.dark)` on the sheet for system controls (toggle/stepper) consistency.

## Images (fix #2)

- The banner uses the same resolver the preview proved working. On `WorkoutView.onAppear`, also call the image prefetch for the plan's manifest (so images are fetched even if the runner is opened without going through the preview's prefetch). Prefetch is the existing `ExerciseImageCache.prefetch(manifest:)`; thread it via a new `onAppearPrefetch: () -> Void` closure passed from ChatView (which has `coordinator.imageCache`), OR pass the cache's prefetch directly. Placeholder shows until the `image_blob` lands; the banner re-renders when the cache fills (resolver re-queried on body eval / coordinator change).

## Cohesion (fix #3)

The scattered navbar/dots/card/rows/bottombar become five ordered sections (banner → chips → focus card → primary → toolbar) on one background, with the focus card as the single visual anchor.

## Components / files

- Modify: `Views/WorkoutView.swift` — new body layout (top bar, banner, chips, focus card, primary, toolbar); keep overlays + alert + finish sheet; add `onAppearPrefetch`.
- Create: `Views/Workout/ExerciseBannerView.swift` — image banner + name/scrim overlay (+ placeholder).
- Create: `Views/Workout/FocusSetCard.swift` — big-control set logger (migrated from `ActiveSetRowView`, same coordinator wiring + pre-fill logic).
- Create: `Views/Workout/LoggedSetChips.swift` — compact logged-set chip strip.
- Modify: `Views/Workout/SwapSheet.swift` — dark theming + `presentationBackground`.
- Modify: `Views/ChatView.swift` — pass `onAppearPrefetch` (calls `coordinator.imageCache.prefetch(manifest:)`) into `WorkoutView`.
- Remove `ActiveSetRowView` from `SetRowView.swift` once `FocusSetCard` replaces it (keep `LoggedSetRow` only if still referenced; otherwise remove). `progressDots` / `navbar` / `bottomBar` private helpers in `WorkoutView` are replaced.

## Testing

- **`FocusSetCardLogicTests`** (iOS unit): the pre-fill helper (`midReps`) and weight formatting are pure — extract `midReps`/`formatWeight` into a tiny testable helper (`WorkoutSetFormat`) and unit-test ("8-10"→9, "12"→12, ""→8; 60.0→"60", 62.5→"62.5"). This is the only non-view logic; the rest is verified visually.
- **Manual/sim (fake-WS harness):** open runner → image banner shows (fake `image_blob`); big steppers adjust reps/weight; "Записать подход" logs a set → chip appears + rest timer; "Дальше →" advances exercise; toolbar "заменить" opens the DARK swap sheet (no light clash) → options → confirm; "финиш" → finish sheet → complete. Drive with `scripts/fake-ws-debug.ts` (already answers image/swap/plan).
- Re-run full `JarvisAppTests` (must stay green — 201).

## Out of scope

- `WorkoutCoordinator` internals, `RestTimer`/`RestTimerOverlay`, `CoachBannerView` behavior.
- The preview screen (`WorkoutPreviewView`) — already shipped; only the runner + swap sheet change here.
- Real exercise imagery from Payne (depends on `image_blob`; the pipeline is reused, not changed).
- Bump `CURRENT_PROJECT_VERSION` (+MARKETING) + `xcodegen generate` on the build task.
