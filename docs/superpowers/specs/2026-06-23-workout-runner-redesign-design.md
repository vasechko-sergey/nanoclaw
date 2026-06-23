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

Flexible ~50/50 split via `GeometryReader` — top ~half is the image, bottom ~half is the controls, all on `Theme.background`:

1. **Image hero — top ~half** (`ExerciseBannerView`, new): fills the top ~46% of the available height (`geo.size.height * 0.46`, so it adapts across devices and is properly visible — not a thin banner). Loads `imageResolver(currentExercise.exerciseSlug)` and renders `.scaledToFill().clipped()` (aspect-fill, "ресайз" = scales to fill its area); on nil/missing shows the `figure.strengthtraining.traditional` placeholder centered on `Theme.surface`. **Overlaid** (not separate rows): a top translucent bar — ✕ (abort) · thin segmented progress (one segment per exercise, filled ≤ current) · "Дальше →" (advances via `finishExercise`; reads "Финиш" + opens the finish sheet on the last exercise); a bottom solid scrim (`Color.black.opacity(0.74)`) with the exercise `displayName` + "{idx+1}/{total}".

2. **Controls — bottom ~half:** the remaining height holds, compact, top→bottom: logged-set chips → focus card → primary button → icon toolbar (items 3–6 below). Day/week/intensity is a small caption (e.g. above the chips or in the scrim).

3. **Logged-set chips** (`LoggedSetChips`, new): horizontal wrap of compact chips, one per logged set of the current exercise ("✓ {reps}×{weight}"), plus a muted "подход {currentSetIdx+1} из {targetSets}" chip. Replaces the stacked `LoggedSetRow` list.

4. **Focus card** (`FocusSetCard`, replaces `ActiveSetRowView`): `Theme.surface` rounded card with THREE identical-layout rows — **Повторы**, **Вес, кг**, **Запас** — separated by hairlines. Each row: label left (`Theme.textSecondary`); right = a fixed control group `[− circle] [value] [+ circle]` with the SAME sizes across all three rows (32pt circles, value `width:44` centered) so the +/− columns line up vertically. No inline unit suffixes (no "повт"/"кг" after the number — the unit lives in the label). State (`reps`/`weight`/`rir`) + pre-fill/on-change logic carried over verbatim from `ActiveSetRowView`. Weight steps 0.5; reps/rir step 1.

5. **Primary button:** full-width "Записать подход" (`Theme.accent` fill) → `coordinator.logSet(reps:weight:repsInReserve:ts:)` + `restTimer.start(planned:lastRepsInReserve:)` (same as today's ✓).

6. **Icon toolbar:** three icon+label items — **заменить** (`arrow.2.squarepath` → `onSwap(currentExercise.exerciseSlug)`), **отдых** (`timer` → `restTimer.start(planned:lastRepsInReserve:)` to show/restart the overlay), **финиш** (`flag` → opens the finish sheet → `complete`).

Overlays unchanged: `CoachBannerView` (coach_message) + `RestTimerOverlay`. Abort alert + finish sheet unchanged in behavior (finish sheet may be lightly restyled for dark consistency).

**Advance/finish semantics:** logging is the primary button (log as many sets as you want — warmup has `targetSets:0`). Navigation between exercises is the top-right "Дальше →" (`finishExercise`). Finishing the whole workout is the toolbar "финиш" (and "Дальше →" becomes "Финиш" on the last exercise). This separates log / navigate / finish cleanly — no scattered bottom bar.

## Swap sheet — dark theme + visualization (fix #1 + "no swap visualization")

Theming:
- `.presentationBackground(Theme.background)` + `.preferredColorScheme(.dark)` on the `SwapSheet` (min target 18.0). Restyle content to dark: containers on `Theme.surface`, text `Theme.textPrimary`/secondary, CTAs `Theme.accent`, hairline separators. Drop default `Form`/grouped-list chrome. "Отмена" tinted `Theme.accent`.

Visualization (every exercise shows its image, not just a slug):
- **Current exercise** row at top: real thumbnail from the plan manifest (slug+sha256 → cache, already prefetched) + name + "меняем" label.
- **Alternatives** as image-card rows: thumbnail + `name_ru`/slug + `why`; the selected one gets a `Theme.accent` border + a filled check; the confirm CTA names the choice ("Заменить на «…»").
- Alternative thumbnails: the swap-options payload carries only slugs, so on `exercise_swap_options` arrival the app fires `transport.sendImageRequest(slug:)` for each alternative slug (best-effort; Payne answers with `image_blob` if it has the image). Until a blob lands, the card shows the `figure.strengthtraining.traditional` placeholder.
- Because an alternative's `sha256` isn't known up front (it arrives WITH the blob), add `ExerciseImageCache.latestPath(slug:) -> URL?` (newest `<slug>_*.jpg` on disk) for slug-only lookup. The current exercise still uses the exact slug+sha256 path.
- Re-render when a blob lands: add bus case `WorkoutInboundEvent.imageReceived(slug: String)`; `AppCoordinator.handleWorkoutEnvelope`'s `.imageBlob` branch emits it after `imageCache.write(...)`. The swap sheet (driven from ChatView) bumps a `@State` token on `.imageReceived` to re-resolve thumbnails.

Note (dependency): real alternative thumbnails require Payne to answer `image_request` for arbitrary exercise slugs (it already serves plan slugs). If Payne has no image for a slug, the placeholder stays — the sheet is still fully usable. No protocol change; reuses image_request/image_blob.

## Images (fix #2)

- The banner uses the same resolver the preview proved working. On `WorkoutView.onAppear`, also call the image prefetch for the plan's manifest (so images are fetched even if the runner is opened without going through the preview's prefetch). Prefetch is the existing `ExerciseImageCache.prefetch(manifest:)`; thread it via a new `onAppearPrefetch: () -> Void` closure passed from ChatView (which has `coordinator.imageCache`), OR pass the cache's prefetch directly. Placeholder shows until the `image_blob` lands; the banner re-renders when the cache fills (resolver re-queried on body eval / coordinator change).

## Russian names (fix: transliteration on device)

On the real device exercise names render as transliterated slugs ("zhim shtangi lezha …") because `ExercisePlan` never decodes `name_ru` — the UI falls back to the hyphen-split slug. The plan_json DOES carry `name_ru` per exercise (canonical `PlanExerciseSchema.name_ru`).

- `ExercisePlan` (`Models/Workout.swift`): add `var nameRu: String?`, decode/encode key `name_ru` (lenient `try?`, optional — warmups/older plans may omit it).
- Add `ExercisePlan.displayName`: `nameRu` if non-empty, else the current prettified slug (hyphens→spaces). Capitalize the slug fallback's first letter.
- Use `displayName` everywhere a name shows: the new banner, `FocusSetCard` (if it shows a name), `LoggedSetChips`, AND the already-shipped `WorkoutPreviewView`/`ExerciseCardView` (so the preview is fixed too).
- Swap alternatives: `SwapResponse.Alternative` carries only `slug`+`why`, so alternative rows show the prettified slug for now. Real Russian names for alternatives need `name_ru` added to the `exercise_swap_options` payload (shared `v2.ts` + Swift + Payne) — noted as a follow-up, out of scope here.

## Cohesion (fix #3)

The scattered navbar/dots/card/rows/bottombar become five ordered sections (banner → chips → focus card → primary → toolbar) on one background, with the focus card as the single visual anchor.

## Components / files

- Modify: `Views/WorkoutView.swift` — new body layout (top bar, banner, chips, focus card, primary, toolbar); keep overlays + alert + finish sheet; add `onAppearPrefetch`.
- Create: `Views/Workout/ExerciseBannerView.swift` — image banner + name/scrim overlay (+ placeholder).
- Create: `Views/Workout/FocusSetCard.swift` — big-control set logger (migrated from `ActiveSetRowView`, same coordinator wiring + pre-fill logic).
- Create: `Views/Workout/LoggedSetChips.swift` — compact logged-set chip strip.
- Modify: `Models/Workout.swift` — `ExercisePlan.nameRu` (decode `name_ru`) + `displayName` helper; fixes transliteration everywhere names show (banner, chips, preview/`ExerciseCardView`).
- Modify: `Views/Workout/SwapSheet.swift` — dark theming + `presentationBackground` + visualized current/alternative cards with thumbnails (slug→`latestPath`/manifest → cache; placeholder fallback).
- Modify: `Services/ExerciseImageCache.swift` — add `latestPath(slug:) -> URL?` (newest `<slug>_*.jpg`) for slug-only thumbnail lookup of alternatives.
- Modify: `Services/WorkoutInbound.swift` — add `case imageReceived(slug: String)` to `WorkoutInboundEvent`.
- Modify: `Services/AppCoordinator.swift` — `.imageBlob` branch emits `workoutBus.events.send(.imageReceived(b.slug))` after cache write.
- Modify: `Views/ChatView.swift` — pass `onAppearPrefetch` (calls `coordinator.imageCache.prefetch(manifest:)`) into `WorkoutView`; on `.swapOptions` fire `transport.sendImageRequest(slug:)` for each alternative slug + thread an image-resolver + an `.imageReceived` re-render token into `SwapSheet`.
- Remove `ActiveSetRowView` from `SetRowView.swift` once `FocusSetCard` replaces it (keep `LoggedSetRow` only if still referenced; otherwise remove). `progressDots` / `navbar` / `bottomBar` private helpers in `WorkoutView` are replaced.

## Testing

- **`FocusSetCardLogicTests`** (iOS unit): the pre-fill helper (`midReps`) and weight formatting are pure — extract `midReps`/`formatWeight` into a tiny testable helper (`WorkoutSetFormat`) and unit-test ("8-10"→9, "12"→12, ""→8; 60.0→"60", 62.5→"62.5").
- **`ExercisePlanNameTests`** (iOS unit): `name_ru` decodes from a plan_json exercise; `displayName` returns `name_ru` when present, else the capitalized prettified slug ("zhim-shtangi-lezha" → "Zhim shtangi lezha") when `name_ru` absent/empty. (Real plans always carry `name_ru`; the fallback is the safety net.)
- **Manual/sim (fake-WS harness):** open runner → image banner shows (fake `image_blob`); big steppers adjust reps/weight; "Записать подход" logs a set → chip appears + rest timer; "Дальше →" advances exercise; toolbar "заменить" opens the DARK swap sheet (no light clash) → options → confirm; "финиш" → finish sheet → complete. Drive with `scripts/fake-ws-debug.ts` (already answers image/swap/plan).
- Re-run full `JarvisAppTests` (must stay green — 201).

## Out of scope

- `WorkoutCoordinator` internals, `RestTimer`/`RestTimerOverlay`, `CoachBannerView` behavior.
- The preview screen (`WorkoutPreviewView`) — already shipped; only the runner + swap sheet change here.
- Real exercise imagery from Payne (depends on `image_blob`; the pipeline is reused, not changed).
- Bump `CURRENT_PROJECT_VERSION` (+MARKETING) + `xcodegen generate` on the build task.
