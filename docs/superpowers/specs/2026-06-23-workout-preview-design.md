# Workout Preview Screen — Design

**Goal:** Tapping the workout card opens a **preview** (browse exercises with images, swipe between them, replace an exercise) instead of starting the live workout immediately. A "Поехали" button inside the preview enters the existing live runner.

**Architecture:** A new standalone `WorkoutPreviewView` paged over `plan.exercises`. The existing live runner (`WorkoutView`) and its linear `WorkoutCoordinator` are untouched — the coordinator is created only when the user starts from the preview. The dormant-but-complete swap flow (`SwapSheet` + transport + bus) gets wired into the preview for "Заменить упражнение".

**Tech stack:** SwiftUI (`TabView` page style), GRDB-backed plan (already stored on the chat row), existing v2 workout envelopes (`exercise_swap_request` / `exercise_swap_options` / `exercise_swap_confirm`, `workout_plan`, `image_request` / `image_blob`), `ExerciseImageCache`, `WorkoutInboundBus`.

---

## Current state (mapped)

- Card `WorkoutPlanRow` (`Components/MessageRow.swift`): button "Начать тренировку" → `onStart?(plan, messageId)`.
- `onWorkoutStart` threads MessageRow → MessageListView → ChatView.
- `ChatView.startWorkout(plan, messageId)` creates `WorkoutCoordinator(plan, queue)` and sets `activeWorkout` → `.fullScreenCover(item: $activeWorkout)` presents `WorkoutView` (the **live runner**, immediate).
- `WorkoutCoordinator` is **linear-only** (advance via `finishExercise`; `currentExerciseIdx` is `private(set)`; no free prev/next).
- `imageResolver` in ChatView: `plan.imageManifest.first{ $0.slug == slug }` → `imageCache.has/path(slug, sha256)`. Prefetch on inbound plan; `image_blob` writes to cache.
- Swap flow EXISTS but is **dormant**: `ExerciseCardView` "заменить" → `onSwap` → ChatView stub (`// deferred`). `SwapSheet.swift` UI, `WorkoutInboundBus`, `sendExerciseSwapRequest` / `sendExerciseSwapConfirm`, and the inbound `.swapOptions` bus event all already exist.
- `ExerciseCardView(exercise:, imageURL:, onSwap:)` renders image (or `figure.strengthtraining.traditional` placeholder) + title + target spec + notes + "заменить" button.

---

## Components

### 1. `WorkoutPreviewView` (new — `Views/Workout/WorkoutPreviewView.swift`)

Inputs:
```
plan: WorkoutPlan                         // initial; mutable via @State for swap refresh
imageResolver: (_ slug: String) -> URL?   // same resolver ChatView builds for the runner
onStart: () -> Void                        // user tapped "Поехали"
onSwap: (_ exerciseSlug: String) -> Void   // user tapped "Заменить упражнение"
planUpdates: ... (see §5)                  // stream of updated plans (same workout_id)
```

Layout (matches approved mockup):
- Header: ✕ (dismiss) · centered `dayName` + `нед. {week} · {intensityLabel}`.
- Page dots + "{idx+1} из {count}" (mirror the runner's `progressDots` styling).
- `TabView(selection: $page)` `.tabViewStyle(.page(indexDisplayMode: .never))` over `plan.exercises` — swipe paging. Each page reuses `ExerciseCardView(exercise:, imageURL: imageResolver(slug), onSwap: { onSwap(slug) })`.
- Bottom: primary "Поехали" button → `onStart()`.

State:
- `@State private var page: Int = 0`
- `@State private var plan: WorkoutPlan` (seeded from the input; replaced on a matching `.planUpdated`).

### 2. Card change (`WorkoutPlanRow`, `Components/MessageRow.swift`)

- Button label: "Начать тренировку" → **"Посмотреть тренировку"**.
- No callback signature change; `onStart` now opens the preview (wiring in ChatView).

### 3. ChatView wiring (`Views/ChatView.swift`)

- Replace the direct runner presentation. New flow:
  - `@State private var activePreview: PreviewPresentation?` (holds `plan`, `messageId`).
  - Card tap → `activePreview = .init(plan:, messageId:)` → `.fullScreenCover(item: $activePreview)` presents `WorkoutPreviewView`.
  - Preview `onStart`: dismiss preview, then set the existing `activeWorkout` (create `WorkoutCoordinator`) → the existing runner cover presents. (Sequence the two covers so they don't fight: set `activeWorkout` in the preview's dismiss completion, or use a single enum state `workoutPhase = .none | .preview(p) | .running(p)`.)
  - Preview `onSwap`: drive the swap sheet (see §4).
- Keep `imageResolver` exactly as today; pass the same closure to the preview.

**Decision:** model presentation as one `@State workoutPhase` enum (`none` / `preview(Presentation)` / `running(Presentation)`) to avoid two `fullScreenCover`s racing. `preview → running` is a single state transition.

### 4. Replace flow — wire the dormant `SwapSheet`

- Preview "Заменить упражнение" (per current exercise) → ChatView presents `SwapSheet` as a `.sheet` over the preview, bound to `@State swapResponse: SwapResponse?` + `@State swapLoading: Bool` + the current `workoutId` + `originalSlug`.
- `SwapSheet` "Предложи варианты" → `transport.sendExerciseSwapRequest(workoutId:, slug:, proposed: nil)`; own-text → `proposed: text`.
- Inbound `exercise_swap_options` → AppCoordinator → `workoutBus.events.send(.swapOptions(resp, originalSlug, workoutId))` (already wired). ChatView subscribes (`.onReceive(coordinator.workoutBus.events)`) → set `swapResponse`, clear `swapLoading`.
- User confirms a slug → `transport.sendExerciseSwapConfirm(workoutId:, original:, new:, persist:)` → close sheet.

### 5. Preview refresh after swap

- Add bus case: `enum WorkoutInboundEvent { …; case planUpdated(WorkoutPlan) }`.
- `AppCoordinator.handleWorkoutEnvelope`'s `.workoutPlan` branch: after decode + insert, also `workoutBus.events.send(.planUpdated(plan))`.
- `WorkoutPreviewView` subscribes (`.onReceive`); if `updated.workoutId == plan.workoutId` → `self.plan = updated` (page index clamped to new count) → re-renders the swapped exercise; image prefetch already fired on the inbound plan, so the resolver will find it once the `image_blob` lands.
- The updated plan ALSO lands as a fresh chat card (no dedup) — accepted as-is.

### 6. Images — verify + fix if broken

- The user explicitly wants images confirmed loading. Manifest `url` is `""`; images arrive only when Payne answers `image_request` with an `image_blob`. Verification path:
  - On preview open, prefetch already requested misses; confirm `image_request` is sent, Payne replies `image_blob`, cache writes `<slug>_<sha256>.jpg`, resolver returns the path, `ExerciseCardView` renders it.
  - Verify against the fake-WS harness (extend `scripts/fake-ws-debug.ts` to answer `image_request` with a small `image_blob`) AND/OR on the sim against prod.
  - If blobs never arrive (Payne side not sending), fix is out of this view's scope but must be surfaced (it's a Payne/host gap, not the preview).

---

## Data flow

```
card "Посмотреть тренировку"
  → ChatView workoutPhase = .preview(plan)
  → WorkoutPreviewView (swipe exercises; images via resolver)
      ├─ "Заменить" → SwapSheet → sendExerciseSwapRequest
      │     → Payne exercise_swap_options → bus .swapOptions → SwapSheet
      │     → pick → sendExerciseSwapConfirm
      │     → Payne workout_plan (updated) → AppCoordinator → bus .planUpdated
      │     → preview swaps plan in place
      └─ "Поехали" → workoutPhase = .running(plan)
            → WorkoutCoordinator(plan) → WorkoutView (existing runner, unchanged)
```

## Testing

- **`WorkoutPreviewViewTests`** (iOS): build a `WorkoutPlan`; assert paging clamps within `0..<count`; assert `.planUpdated` with matching `workoutId` replaces the plan and a non-matching one is ignored; assert the page index clamps when the new plan has fewer exercises.
- **Decode/bus**: a `.planUpdated` bus event is emitted on inbound `workout_plan` (extend an AppCoordinator-level test or the existing workout inbound tests).
- **Manual/sim**: card → preview opens (not the runner); swipe works; images render; "Заменить" → SwapSheet → options → confirm → preview reflects the swap; "Поехали" → runner opens with the (possibly swapped) plan.
- **Fake-WS harness**: extend `scripts/fake-ws-debug.ts` to (a) answer `image_request` with an `image_blob`, (b) on `exercise_swap_request` send `exercise_swap_options`, (c) on `exercise_swap_confirm` re-send an updated `workout_plan` — so the whole loop is drivable in the simulator.

## File structure

- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutPreviewView.swift`
- Modify: `Components/MessageRow.swift` (button label), `Views/ChatView.swift` (workoutPhase state + preview/swap wiring), `Services/AppCoordinator.swift` (`.planUpdated` emit), the `WorkoutInboundBus` event enum (`planUpdated` case).
- Test: `Sources/JarvisAppTests/WorkoutPreviewViewTests.swift`; extend `scripts/fake-ws-debug.ts`.
- Bump `CURRENT_PROJECT_VERSION` + `xcodegen generate`.

## Out of scope

- Local exercise catalog (swap stays fully Payne-driven).
- Card de-duplication when an updated plan arrives (a 2nd card is acceptable).
- Changes to the live runner (`WorkoutView`) or `WorkoutCoordinator` internals.
