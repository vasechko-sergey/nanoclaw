# Workout Preview Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping the workout card opens a paged preview (images, swipe, replace-exercise) before the live runner; "Поехали" starts the existing runner.

**Architecture:** New standalone `WorkoutPreviewView` over `plan.exercises`. The live runner (`WorkoutView`) + linear `WorkoutCoordinator` are untouched — the coordinator is created only on "Поехали". The existing-but-dormant swap flow (`SwapSheet` + transport + `workoutBus`) is wired into the preview. Preview refreshes in place via the existing `.planReceived` bus case.

**Tech Stack:** SwiftUI (`TabView` page style), Combine (`workoutBus`), existing v2 workout envelopes, `ExerciseImageCache`.

Reference spec: `docs/superpowers/specs/2026-06-23-workout-preview-design.md`.

Run iOS tests with: `mcp__XcodeBuildMCP__test_sim` (scheme JarvisApp, sim UDID `A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA`) or
`xcodebuild -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -sdk iphonesimulator -destination 'platform=iOS Simulator,id=A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA' test`.
Test target module is imported as `@testable import Jarvis` (NOT JarvisApp).

---

## File Structure

- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutPreviewView.swift` — paged preview + pure refresh helper.
- Create: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutPreviewUpdateTests.swift` — unit tests for the refresh/clamp helper.
- Modify: `Components/MessageRow.swift` — card button label.
- Modify: `Views/ChatView.swift` — preview presentation (phase enum), resolver extract, swap-sheet wiring, bus subscription.
- Modify: `Services/AppCoordinator.swift` — emit `.planReceived` on inbound `workout_plan`.
- Modify: `scripts/fake-ws-debug.ts` — answer image_request / swap_request / swap_confirm to drive the loop in the sim.
- Modify: `ios/JarvisApp/project.yml` — bump `CURRENT_PROJECT_VERSION`.

---

## Task 1: Plan-refresh + page-clamp pure helper

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutPreviewView.swift` (helper only this task)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutPreviewUpdateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/JarvisApp/Sources/JarvisAppTests/WorkoutPreviewUpdateTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class WorkoutPreviewUpdateTests: XCTestCase {
    private func ex(_ slug: String) -> ExercisePlan {
        ExercisePlan(exerciseSlug: slug, targetSets: 3, targetReps: "5", targetRir: 2, restSec: 90)
    }
    private func plan(id: String, _ slugs: [String]) -> WorkoutPlan {
        WorkoutPlan(workoutId: id, dayName: "D", week: 1, intensityLabel: "L",
                    exercises: slugs.map(ex), imageManifest: [])
    }

    func test_matchingWorkoutId_replacesPlanAndKeepsPage() {
        let cur = plan(id: "w1", ["a", "b", "c"])
        let inc = plan(id: "w1", ["a", "x", "c"])
        let r = WorkoutPreviewUpdate.apply(current: cur, incoming: inc, page: 1)
        XCTAssertEqual(r.plan.exercises[1].exerciseSlug, "x")
        XCTAssertEqual(r.page, 1)
    }

    func test_nonMatchingWorkoutId_isIgnored() {
        let cur = plan(id: "w1", ["a", "b"])
        let inc = plan(id: "w2", ["z"])
        let r = WorkoutPreviewUpdate.apply(current: cur, incoming: inc, page: 1)
        XCTAssertEqual(r.plan.workoutId, "w1")
        XCTAssertEqual(r.page, 1)
    }

    func test_pageClampsWhenIncomingHasFewerExercises() {
        let cur = plan(id: "w1", ["a", "b", "c"])
        let inc = plan(id: "w1", ["a"])
        let r = WorkoutPreviewUpdate.apply(current: cur, incoming: inc, page: 2)
        XCTAssertEqual(r.plan.exercises.count, 1)
        XCTAssertEqual(r.page, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the JarvisAppTests suite filtered to `WorkoutPreviewUpdateTests`.
Expected: FAIL — `cannot find 'WorkoutPreviewUpdate' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutPreviewView.swift` with ONLY the helper for now:

```swift
import SwiftUI
import Combine

/// Pure refresh logic for the preview: when an updated plan arrives (same
/// workoutId, e.g. after a swap), replace the displayed plan and clamp the
/// current page into the new exercise range. A different workoutId is ignored.
enum WorkoutPreviewUpdate {
    static func apply(current: WorkoutPlan, incoming: WorkoutPlan, page: Int) -> (plan: WorkoutPlan, page: Int) {
        guard incoming.workoutId == current.workoutId else { return (current, page) }
        let clampedPage = min(max(0, page), max(0, incoming.exercises.count - 1))
        return (incoming, clampedPage)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run `WorkoutPreviewUpdateTests`. Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/serg/git/nanoclaw
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutPreviewView.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutPreviewUpdateTests.swift
git commit -m "feat(workout): preview plan-refresh + page-clamp helper"
```

---

## Task 2: `WorkoutPreviewView` (the paged view)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutPreviewView.swift`

No unit test (SwiftUI view) — verified by compile here + manual sim run in Task 6.

- [ ] **Step 1: Add the view below the helper**

Append to `WorkoutPreviewView.swift`:

```swift
/// Paged preview of a workout plan, shown BEFORE the live runner. Swipe between
/// exercises, see images, replace an exercise (drives the Payne swap flow), then
/// "Поехали" to start. Refreshes in place when an updated plan arrives.
struct WorkoutPreviewView: View {
    @State private var plan: WorkoutPlan
    @State private var page: Int = 0

    let imageResolver: (_ slug: String) -> URL?
    /// Stream of inbound plans (workoutBus `.planReceived`); used to refresh after a swap.
    let planUpdates: AnyPublisher<WorkoutPlan, Never>
    let onStart: () -> Void
    let onSwap: (_ exerciseSlug: String) -> Void
    let onClose: () -> Void

    init(plan: WorkoutPlan,
         imageResolver: @escaping (_ slug: String) -> URL?,
         planUpdates: AnyPublisher<WorkoutPlan, Never>,
         onStart: @escaping () -> Void,
         onSwap: @escaping (_ exerciseSlug: String) -> Void,
         onClose: @escaping () -> Void) {
        _plan = State(initialValue: plan)
        self.imageResolver = imageResolver
        self.planUpdates = planUpdates
        self.onStart = onStart
        self.onSwap = onSwap
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            progressDots
            TabView(selection: $page) {
                ForEach(Array(plan.exercises.enumerated()), id: \.element.id) { idx, exercise in
                    ScrollView {
                        ExerciseCardView(
                            exercise: exercise,
                            imageURL: imageResolver(exercise.exerciseSlug),
                            onSwap: { onSwap(exercise.exerciseSlug) }
                        )
                        .padding()
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            startBar
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onReceive(planUpdates) { incoming in
            let r = WorkoutPreviewUpdate.apply(current: plan, incoming: incoming, page: page)
            plan = r.plan
            page = r.page
        }
        .accessibilityIdentifier("workout-preview")
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(plan.dayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("нед. \(plan.week) · \(plan.intensityLabel)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<plan.exercises.count, id: \.self) { i in
                Circle()
                    .fill(i == page ? Theme.accent : Theme.accent.opacity(0.2))
                    .frame(width: 8, height: 8)
            }
            Text("\(min(page + 1, plan.exercises.count)) из \(plan.exercises.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)
        }
        .padding(.vertical, 12)
    }

    private var startBar: some View {
        Button(action: onStart) {
            Text("Поехали")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(Theme.accent))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Build the app for the sim. Expected: BUILD SUCCEEDED (the view is unreferenced yet — that's fine).

- [ ] **Step 3: Commit**

```bash
cd /Users/serg/git/nanoclaw
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/WorkoutPreviewView.swift
git commit -m "feat(workout): WorkoutPreviewView paged plan browser"
```

---

## Task 3: Emit `.planReceived` on inbound plan

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift` (in `handleWorkoutEnvelope`, `.workoutPlan` branch)

The bus case `case planReceived(WorkoutPlan)` already exists in `Services/WorkoutInbound.swift` but is never sent. The preview subscribes to it for refresh.

- [ ] **Step 1: Add the emit after insert**

In `handleWorkoutEnvelope`, the `.workoutPlan` branch currently ends:

```swift
            do {
                let plan = try Self.decodeWorkoutPlan(payload: p)
                insertWorkoutPlan(plan, rowId: env.id)
            } catch {
                Log.warn(.ws, "workout_plan decode failed: \(error)")
            }
```

Change the `do` body to also publish on the bus:

```swift
            do {
                let plan = try Self.decodeWorkoutPlan(payload: p)
                insertWorkoutPlan(plan, rowId: env.id)
                // Let an open WorkoutPreviewView refresh in place (e.g. after a
                // swap, Payne re-sends the updated plan with the same workoutId).
                workoutBus.events.send(.planReceived(plan))
            } catch {
                Log.warn(.ws, "workout_plan decode failed: \(error)")
            }
```

- [ ] **Step 2: Verify it compiles**

Build for the sim. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
cd /Users/serg/git/nanoclaw
git add ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift
git commit -m "feat(workout): emit .planReceived bus event on inbound plan"
```

---

## Task 4: Card label + ChatView preview presentation

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift` (button label)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` (presentation phase + resolver extract)

- [ ] **Step 1: Rename the card button**

In `Components/MessageRow.swift`, inside `WorkoutPlanRow`, change the button label text:

```swift
                            Text("Посмотреть тренировку")
                                .font(.system(size: 13, weight: .medium))
```

(was `Text("Начать тренировку")`.)

- [ ] **Step 2: Add a phase to `WorkoutPresentation`**

In `Views/ChatView.swift`, replace the `WorkoutPresentation` struct (lines ~12-17):

```swift
private struct WorkoutPresentation: Identifiable {
    enum Phase { case preview, running }
    let plan: WorkoutPlan
    var phase: Phase
    var coord: WorkoutCoordinator?   // nil in preview; created on "Поехали"
    let messageId: String?
    var id: String { plan.workoutId }
}
```

- [ ] **Step 3: Extract the image resolver + change `startWorkout` to open the preview**

Replace `startWorkout(_:messageId:)` (lines ~101-108) with:

```swift
    /// Shared slug→cached-image-URL resolver (used by both preview and runner).
    private func resolveImageURL(slug: String, plan: WorkoutPlan) -> URL? {
        guard let entry = plan.imageManifest.first(where: { $0.slug == slug }) else { return nil }
        return coordinator.imageCache.has(slug: entry.slug, sha256: entry.sha256)
            ? coordinator.imageCache.path(forSlug: entry.slug, sha256: entry.sha256)
            : nil
    }

    /// Card tap → open the PREVIEW (not the runner). Runner opens from preview.
    private func startWorkout(_ plan: WorkoutPlan, messageId: String) {
        activeWorkout = WorkoutPresentation(plan: plan, phase: .preview, coord: nil, messageId: messageId)
    }

    /// "Поехали" inside the preview → create the coordinator + swap to the runner
    /// phase. Same `id` (workoutId) keeps the same fullScreenCover mounted and
    /// just swaps its content from preview to runner.
    private func startRunning() {
        guard let cur = activeWorkout, let queue = coordinator.ws.stack?.setLogQueue else {
            Log.warn(.ws, "start running but stack not built — dropping")
            return
        }
        let wc = WorkoutCoordinator(plan: cur.plan, queue: queue)
        activeWorkout = WorkoutPresentation(plan: cur.plan, phase: .running, coord: wc, messageId: cur.messageId)
    }
```

- [ ] **Step 4: Switch the fullScreenCover content on phase**

Replace the `.fullScreenCover(item: $activeWorkout) { presentation in WorkoutView(...) }` block (lines ~307-341) with:

```swift
        .fullScreenCover(item: $activeWorkout) { presentation in
            switch presentation.phase {
            case .preview:
                WorkoutPreviewView(
                    plan: presentation.plan,
                    imageResolver: { resolveImageURL(slug: $0, plan: presentation.plan) },
                    planUpdates: coordinator.workoutBus.events
                        .compactMap { if case .planReceived(let p) = $0 { return p } else { return nil } }
                        .eraseToAnyPublisher(),
                    onStart: { startRunning() },
                    onSwap: { slug in beginSwap(slug: slug, workoutId: presentation.plan.workoutId) },
                    onClose: { activeWorkout = nil }
                )
            case .running:
                WorkoutView(
                    coordinator: presentation.coord!,
                    imageResolver: { resolveImageURL(slug: $0, plan: presentation.plan) },
                    onClose: { session in
                        let workoutId = presentation.plan.workoutId
                        if let session {
                            Task { try? await coordinator.ws.stack?.transport.sendWorkoutComplete(session) }
                        } else {
                            Task { try? await coordinator.ws.stack?.transport.sendWorkoutAbort(workoutId: workoutId, reason: "user cancelled") }
                        }
                        if let mid = presentation.messageId {
                            coordinator.markActionAnswered(rowId: mid, choice: session != nil ? "completed" : "aborted")
                        }
                        activeWorkout = nil
                    },
                    onSwap: { slug in beginSwap(slug: slug, workoutId: presentation.plan.workoutId) }
                )
            }
        }
```

(`beginSwap` is added in Task 5; this references it. Add a temporary no-op `private func beginSwap(slug: String, workoutId: String) {}` at the end of `ChatView` now so Task 4 compiles, then fill it in Task 5.)

- [ ] **Step 5: Add `import Combine` to ChatView if not present**

At the top of `Views/ChatView.swift`, ensure `import Combine` is present (needed for `eraseToAnyPublisher`). Add it if missing.

- [ ] **Step 6: Verify it compiles**

Build for the sim. Expected: BUILD SUCCEEDED. (`beginSwap` is a no-op stub for now.)

- [ ] **Step 7: Commit**

```bash
cd /Users/serg/git/nanoclaw
git add ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "feat(workout): card opens preview; runner opens from preview"
```

---

## Task 5: Wire the swap flow (SwapSheet)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Add swap state**

In `ChatView`, near `@State private var activeWorkout`, add:

```swift
    private struct SwapSheetPresentation: Identifiable {
        let workoutId: String
        let originalSlug: String
        var id: String { originalSlug }
    }
    @State private var swapSheet: SwapSheetPresentation? = nil
    @State private var swapResponse: SwapResponse? = nil
    @State private var swapLoading: Bool = false
```

- [ ] **Step 2: Replace the `beginSwap` stub with the real opener**

```swift
    /// Open the swap sheet for an exercise. The sheet drives the existing
    /// exercise_swap_request / _options / _confirm flow over the transport.
    private func beginSwap(slug: String, workoutId: String) {
        swapResponse = nil
        swapLoading = false
        swapSheet = SwapSheetPresentation(workoutId: workoutId, originalSlug: slug)
    }
```

- [ ] **Step 3: Present the SwapSheet**

Add this modifier right after the `.fullScreenCover(item: $activeWorkout)` block:

```swift
        .sheet(item: $swapSheet) { s in
            SwapSheet(originalSlug: s.originalSlug, response: $swapResponse, loading: $swapLoading) { action in
                switch action {
                case .requestSuggestions:
                    swapLoading = true
                    Task { try? await coordinator.ws.stack?.transport.sendExerciseSwapRequest(workoutId: s.workoutId, slug: s.originalSlug, proposed: nil) }
                case .proposeOwn(let text):
                    swapLoading = true
                    Task { try? await coordinator.ws.stack?.transport.sendExerciseSwapRequest(workoutId: s.workoutId, slug: s.originalSlug, proposed: text) }
                case .confirm(let newSlug, let persist):
                    Task { try? await coordinator.ws.stack?.transport.sendExerciseSwapConfirm(workoutId: s.workoutId, original: s.originalSlug, new: newSlug, persist: persist) }
                    swapSheet = nil
                case .cancel:
                    swapSheet = nil
                }
            }
        }
```

- [ ] **Step 4: Feed swap responses from the bus**

Update the existing `.onReceive(coordinator.workoutBus.events)` switch (lines ~342-353) to set the swap response (leave `.planReceived` to the preview's own subscription):

```swift
        .onReceive(coordinator.workoutBus.events) { event in
            switch event {
            case .swapOptions(let resp, _, _):
                swapResponse = resp
                swapLoading = false
            case .planReceived, .coachMessage, .programUpdated:
                break
            }
        }
```

- [ ] **Step 5: Verify it compiles**

Build for the sim. Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
cd /Users/serg/git/nanoclaw
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "feat(workout): wire SwapSheet from preview (replace exercise)"
```

---

## Task 6: Fake-WS harness loop + manual e2e + version bump

**Files:**
- Modify: `scripts/fake-ws-debug.ts`
- Modify: `ios/JarvisApp/project.yml` (CURRENT_PROJECT_VERSION)

- [ ] **Step 1: Extend the fake server to drive the full loop**

In `scripts/fake-ws-debug.ts`, inside `ws.on('message', ...)` after the existing `auth` branch, add handlers (use a tiny 1x1 transparent PNG base64 for the blob):

```ts
    if (env.type === 'image_request') {
      const slug = env.payload?.slug;
      const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='; // valid 1x1 PNG
      ws.send(JSON.stringify({
        v: 2, kind: 'control', type: 'image_blob', id: randomUUID(), seq: null, ts: ts(),
        payload: { slug, sha256: 'fakesha', base64: png },
      }));
      log(`➡️  image_blob slug=${slug}`);
    }
    if (env.type === 'exercise_swap_request') {
      const wid = env.payload?.workout_id;
      const slug = env.payload?.exercise_slug;
      ws.send(JSON.stringify({
        v: 2, kind: 'control', type: 'exercise_swap_options', id: randomUUID(), seq: null, ts: ts(),
        payload: { workout_id: wid, original_slug: slug, alternatives: [
          { slug: 'zhim-ganteley-na-naklonnoy-skame', why: 'меньше нагрузка на плечо' },
          { slug: 'otzhimaniya-na-brusyah', why: 'свой вес' },
        ] },
      }));
      log(`➡️  exercise_swap_options for ${slug}`);
    }
    if (env.type === 'exercise_swap_confirm') {
      const wid = env.payload?.workout_id;
      const updated = JSON.parse(JSON.stringify(PLAN_PAYLOAD));
      updated.workout_id = wid;
      updated.plan_json.exercises[1] = { slug: env.payload?.new_slug, name_ru: 'Заменённое упражнение', target_sets: 3, target_reps: '8-10', reps_in_reserve: 2, rest_seconds: 120, weight_kg_target: 25 };
      ws.send(JSON.stringify({
        v: 2, kind: 'control', type: 'workout_plan', id: randomUUID(), seq: 2, ts: ts(),
        payload: updated,
      }));
      log(`➡️  workout_plan (updated after swap) wid=${wid}`);
    }
```

(Note: the sha256 in the blob must match the manifest entry for the resolver to find it. For the harness, set the manifest entries' `sha256` to `'fakesha'` so `image_blob.sha256='fakesha'` lands at the path the resolver looks up. Adjust `PLAN_PAYLOAD.image_manifest` sha256 values to `'fakesha'` for this test.)

- [ ] **Step 2: Bump the build**

In `ios/JarvisApp/project.yml`, bump `CURRENT_PROJECT_VERSION` by 1, then from `ios/JarvisApp/` run `xcodegen generate`.

- [ ] **Step 3: Manual e2e in the simulator**

```bash
# from repo root
pnpm exec tsx scripts/fake-ws-debug.ts   # background
# build + install + launch pointed at the fake server:
xcodebuild -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -sdk iphonesimulator -destination 'platform=iOS Simulator,id=A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA' -derivedDataPath /tmp/jarvis-dd build
xcrun simctl install A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA /tmp/jarvis-dd/Build/Products/Debug-iphonesimulator/Jarvis.app
xcrun simctl spawn A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA defaults write com.vasechko.jarvis bearerToken debugtoken
SIMCTL_CHILD_JARVIS_WS_URL=ws://127.0.0.1:8765 xcrun simctl launch --terminate-running-process A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA com.vasechko.jarvis
```

Verify (screenshot via `mcp__computer-use__screenshot`, open Payne chat):
1. Card button reads "Посмотреть тренировку".
2. Tapping it opens the PREVIEW (not the logging runner).
3. Swiping pages exercises; the dots + "N из M" track.
4. Each exercise shows its image (the fake `image_blob` lands → image renders, not the placeholder).
5. "Заменить упражнение" opens the SwapSheet; "Предложи варианты" lists alternatives; confirming one → the preview's exercise updates in place (the fake server's updated plan).
6. "Поехали" opens the live runner (`WorkoutView`).

Kill the fake server when done: `pkill -f fake-ws-debug`.

- [ ] **Step 4: Run the full iOS test suite**

Run JarvisAppTests. Expected: all green (incl. `WorkoutPreviewUpdateTests`).

- [ ] **Step 5: Commit**

```bash
cd /Users/serg/git/nanoclaw
git add scripts/fake-ws-debug.ts ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "test(workout): fake-WS drives image/swap/refresh loop; bump build"
```

---

## Notes for the implementer

- **`@testable import Jarvis`** (module is `Jarvis`, not `JarvisApp`) — wrong name gives a misleading "unable to resolve module dependency" error.
- **Bump `CURRENT_PROJECT_VERSION` + `xcodegen generate` + commit `project.pbxproj`** on the build-affecting task (Task 6) — the app reports its build to the host on connect.
- The runner (`WorkoutView`) and `WorkoutCoordinator` are deliberately untouched. Do not add a preview mode to the coordinator.
- The preview→runner transition reuses ONE `fullScreenCover` with a stable `id` (workoutId) and swaps content on `phase`. If SwiftUI fails to swap content in place on a real device, fall back to: dismiss preview (`activeWorkout = nil`) then present the runner in an `onDismiss` closure — but try the in-place swap first.
- After this lands, `groups/payne/skills/workout-mode/SKILL.md` should mention the user now sees a preview first (deploy via scp, gitignored) — out of scope for this plan; note for follow-up.
