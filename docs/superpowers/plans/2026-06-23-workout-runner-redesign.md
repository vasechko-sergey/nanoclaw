# Workout Runner Redesign (Variant B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** Redesign the live runner (`WorkoutView`) into a flexible ~50/50 screen — large adaptive image hero on top, controls below; circular rest-timer ring after logging a set; dark visualized swap sheet; fix transliterated names (`name_ru`).

**Architecture:** Rework `WorkoutView` body into a `GeometryReader` split. New focused subviews (`ExerciseBannerView`, `FocusSetCard`, `LoggedSetChips`). `RestTimerOverlay` → circular ring. `SwapSheet` → dark + thumbnails. Reuse `WorkoutCoordinator`/`RestTimer`/`CoachBannerView`. Pure logic extracted for tests.

**Tech Stack:** SwiftUI, existing `WorkoutCoordinator`, `RestTimer`, `ExerciseImageCache`, `WorkoutInboundBus`.

Spec: `docs/superpowers/specs/2026-06-23-workout-runner-redesign-design.md`.
Tests: sim UDID `A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA`, `@testable import Jarvis`. Build: `xcodebuild -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -sdk iphonesimulator -destination 'platform=iOS Simulator,id=…' -derivedDataPath /tmp/jarvis-dd`. New files → `xcodegen generate` from `ios/JarvisApp/` first.

---

## Task 1: Pure helpers — set formatting + name_ru/displayName (TDD)

**Files:** Create `Models/WorkoutSetFormat.swift`; modify `Models/Workout.swift` (`ExercisePlan`); Test `Sources/JarvisAppTests/WorkoutFormatTests.swift`.

- [ ] **Step 1: failing tests**

`Sources/JarvisAppTests/WorkoutFormatTests.swift`:
```swift
import XCTest
@testable import Jarvis

final class WorkoutFormatTests: XCTestCase {
    func test_midReps() {
        XCTAssertEqual(WorkoutSetFormat.midReps(targetReps: "8-10"), 9)
        XCTAssertEqual(WorkoutSetFormat.midReps(targetReps: "12"), 12)
        XCTAssertEqual(WorkoutSetFormat.midReps(targetReps: ""), 8)
    }
    func test_formatWeight() {
        XCTAssertEqual(WorkoutSetFormat.weight(60.0), "60")
        XCTAssertEqual(WorkoutSetFormat.weight(62.5), "62.5")
    }
    func test_displayName_prefersNameRu() {
        let e = ExercisePlan(exerciseSlug: "zhim-shtangi-lezha", targetSets: 4, targetReps: "5-6", targetRir: 2, restSec: 180, nameRu: "Жим штанги лёжа")
        XCTAssertEqual(e.displayName, "Жим штанги лёжа")
    }
    func test_displayName_fallbackPrettifiesSlug() {
        let e = ExercisePlan(exerciseSlug: "zhim-shtangi-lezha", targetSets: 4, targetReps: "5-6", targetRir: 2, restSec: 180, nameRu: nil)
        XCTAssertEqual(e.displayName, "Zhim shtangi lezha")
    }
    func test_nameRu_decodesFromPlanJson() throws {
        let json = #"{"slug":"x","name_ru":"Тяга","target_sets":3,"target_reps":"5","reps_in_reserve":2,"rest_seconds":90}"#
        let e = try JSONDecoder().decode(ExercisePlan.self, from: Data(json.utf8))
        XCTAssertEqual(e.nameRu, "Тяга")
        XCTAssertEqual(e.displayName, "Тяга")
    }
}
```

- [ ] **Step 2: run → fail** (no `WorkoutSetFormat`, no `nameRu` param).

- [ ] **Step 3: implement**

`Models/WorkoutSetFormat.swift`:
```swift
import Foundation

/// Pure formatting/derivation helpers for set logging (extracted from
/// ActiveSetRowView so they're unit-testable).
enum WorkoutSetFormat {
    /// "8-10" → 9, "12" → 12, "" → 8.
    static func midReps(targetReps: String) -> Int {
        let parts = targetReps.split(separator: "-").compactMap { Int($0) }
        if parts.count == 2 { return (parts[0] + parts[1]) / 2 }
        if parts.count == 1 { return parts[0] }
        return 8
    }
    /// 60.0 → "60", 62.5 → "62.5".
    static func weight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(w)) : String(format: "%.1f", w)
    }
}
```

In `Models/Workout.swift`, extend `ExercisePlan`: add stored `var nameRu: String?`; add to the memberwise init (default `nil`); decode/encode key `name_ru`; add `displayName`. The init gains a trailing `nameRu: String? = nil` param (keep existing call sites working). In `init(from:)` add `nameRu = try? c.decode(String.self, forKey: .nameRu)`; in `encode` add `try c.encodeIfPresent(nameRu, forKey: .nameRu)`; add `case nameRu = "name_ru"` to `CodingKeys`. Then:
```swift
var displayName: String {
    if let n = nameRu, !n.isEmpty { return n }
    let pretty = exerciseSlug.replacingOccurrences(of: "-", with: " ")
    return pretty.prefix(1).uppercased() + pretty.dropFirst()
}
```

- [ ] **Step 4: run → pass.**

- [ ] **Step 5: commit** `feat(workout): name_ru/displayName + WorkoutSetFormat helpers`.

---

## Task 2: RestTimer.totalSec + progress (TDD)

**Files:** modify `Services/RestTimer.swift`; Test `Sources/JarvisAppTests/RestTimerTests.swift`.

- [ ] **Step 1: failing test**
```swift
import XCTest
@testable import Jarvis

@MainActor
final class RestTimerTests: XCTestCase {
    func test_startSetsTotalAndProgressZero() {
        let t = RestTimer()
        t.start(planned: 120, lastRepsInReserve: 2)   // rir 2 → planned
        XCTAssertEqual(t.totalSec, 120)
        XCTAssertEqual(t.remainingSec, 120)
        XCTAssertEqual(t.progress, 0, accuracy: 0.001)
    }
    func test_adaptedTotal_rirZeroAddsThirty() {
        let t = RestTimer()
        t.start(planned: 120, lastRepsInReserve: 0)   // +30
        XCTAssertEqual(t.totalSec, 150)
    }
    func test_skipResetsTotal() {
        let t = RestTimer()
        t.start(planned: 90, lastRepsInReserve: 2)
        t.skip()
        XCTAssertEqual(t.totalSec, 0)
        XCTAssertEqual(t.progress, 0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: run → fail** (no `totalSec`/`progress`).

- [ ] **Step 3: implement** — in `RestTimer`: add `@Published private(set) var totalSec: Int = 0`; in `start` set `totalSec = effective` right after computing `effective`; in `stop()` set `totalSec = 0`. Add:
```swift
var progress: Double { totalSec > 0 ? Double(totalSec - remainingSec) / Double(totalSec) : 0 }
```

- [ ] **Step 4: run → pass. Step 5: commit** `feat(workout): RestTimer.totalSec + progress for ring`.

---

## Task 3: RestTimerOverlay → circular ring (view)

**Files:** rewrite `Views/Workout/RestTimerOverlay.swift`. Add a `nextHint: String?` input (e.g. "подход 3 · 60 кг") passed from `WorkoutView`.

- [ ] **Step 1: rewrite**
```swift
import SwiftUI

struct RestTimerOverlay: View {
    @ObservedObject var timer: RestTimer
    var nextHint: String? = nil

    var body: some View {
        if timer.running {
            ZStack {
                Theme.background.opacity(0.94).ignoresSafeArea()
                VStack(spacing: 28) {
                    Text("ОТДЫХ").font(.subheadline).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.45))
                    ZStack {
                        Circle().stroke(Theme.accent.opacity(0.15), lineWidth: 12)
                        Circle().trim(from: 0, to: timer.progress)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: timer.progress)
                        VStack(spacing: 4) {
                            Text(format(timer.remainingSec))
                                .font(.system(size: 52, weight: .ultraLight, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                            Text("из \(format(timer.totalSec))")
                                .font(.caption).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(width: 220, height: 220)
                    if let nextHint { Text("Дальше: \(nextHint)").font(.subheadline).foregroundStyle(.white.opacity(0.5)) }
                    Button { timer.skip() } label: {
                        Text("Пропустить").font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 40).padding(.vertical, 13)
                            .background(Capsule().fill(Theme.accent.opacity(0.16)))
                    }.frame(minHeight: 44)
                }
            }
            .transition(.opacity)
        }
    }
    private func format(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}
```

- [ ] **Step 2: build → SUCCEEDED. Step 3: commit** `feat(workout): rest timer circular ring`.

---

## Task 4: FocusSetCard (replaces ActiveSetRowView)

**Files:** Create `Views/Workout/FocusSetCard.swift`; remove `ActiveSetRowView` from `SetRowView.swift` (keep `LoggedSetRow` for now — `WorkoutView` won't use it after Task 6, remove if unreferenced then).

- [ ] **Step 1: implement** — `FocusSetCard` migrates `ActiveSetRowView`'s state + pre-fill/on-change logic verbatim (using `WorkoutSetFormat.midReps`), with three aligned `stepperRow(label:value:onMinus:onPlus:)` rows (Повторы / Вес, кг / Запас) — each: label left, `[− 32pt circle] [value width 44] [+ 32pt circle]` right, hairline separators. The "Записать подход" primary lives in `WorkoutView` (Task 6), so expose the current values + a `log()` the parent calls — OR keep logging inside the card via a `primary` button. Decision: card owns reps/weight/rir state + renders the three rows ONLY; `WorkoutView` reads them via a binding-free callback. Simplest: card takes `coordinator` + `restTimer` (like ActiveSetRowView) and renders rows + the primary "Записать подход" button itself (calls `coordinator.logSet` + `restTimer.start`), so state stays encapsulated. Pre-fill (`onAppear`/`onChange` of `currentSetIdx`/`currentExerciseIdx`) carried over verbatim. Use `WorkoutSetFormat.weight` for the weight display.

```swift
import SwiftUI

struct FocusSetCard: View {
    @ObservedObject var coordinator: WorkoutCoordinator
    @ObservedObject var restTimer: RestTimer

    @State private var reps = 8
    @State private var weight: Double = 20
    @State private var rir = 2

    var body: some View {
        VStack(spacing: 0) {
            stepperRow(label: "Повторы", value: "\(reps)",
                       onMinus: { reps = max(0, reps - 1) }, onPlus: { reps = min(30, reps + 1) })
            Divider().overlay(Color.white.opacity(0.06))
            stepperRow(label: "Вес, кг", value: WorkoutSetFormat.weight(weight),
                       onMinus: { weight = max(0, weight - 0.5) }, onPlus: { weight = min(500, weight + 0.5) })
            Divider().overlay(Color.white.opacity(0.06))
            stepperRow(label: "Запас", value: "\(rir)",
                       onMinus: { rir = max(0, rir - 1) }, onPlus: { rir = min(10, rir + 1) })
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
        .onAppear(perform: prefill)
        .onChange(of: coordinator.currentSetIdx) { _, _ in prefillKeepWeight() }
        .onChange(of: coordinator.currentExerciseIdx) { _, _ in prefill() }
    }

    func logCurrent() {
        coordinator.logSet(reps: reps, weight: weight, repsInReserve: rir, ts: Date())
        restTimer.start(planned: coordinator.currentExercise.restSec, lastRepsInReserve: rir)
    }

    private func prefill() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = prev?.reps ?? WorkoutSetFormat.midReps(targetReps: coordinator.currentExercise.targetReps)
        weight = prev?.weight ?? weight
        rir = coordinator.currentExercise.targetRir
    }
    private func prefillKeepWeight() {
        let prev = coordinator.loggedForCurrentExercise.last
        reps = prev?.reps ?? reps
        weight = prev?.weight ?? weight
        rir = coordinator.currentExercise.targetRir
    }

    @ViewBuilder
    private func stepperRow(label: String, value: String, onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.65))
            Spacer()
            HStack(spacing: 14) {
                circle("minus", onMinus)
                Text(value).font(.system(size: 22, weight: .medium).monospacedDigit())
                    .frame(width: 44).foregroundStyle(.white)
                circle("plus", onPlus)
            }
        }
        .padding(.vertical, 10)
    }
    private func circle(_ sys: String, _ act: @escaping () -> Void) -> some View {
        Button(action: { Theme.hapticSend(); act() }) {
            Image(systemName: sys).font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white).frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
    }
}
```
(If `Theme.hapticSend` isn't available in this scope, drop it.)

- [ ] **Step 2: build → SUCCEEDED. Step 3: commit** `feat(workout): FocusSetCard big aligned set controls`.

---

## Task 5: ExerciseBannerView + LoggedSetChips

**Files:** Create `Views/Workout/ExerciseBannerView.swift`, `Views/Workout/LoggedSetChips.swift`.

- [ ] **Step 1: ExerciseBannerView** — image hero with overlaid top bar + bottom scrim. Inputs: `exercise: ExercisePlan`, `imageURL: URL?`, `indexLabel: String` ("2/8"), `progress: (current: Int, total: Int)`, `onClose`, `onAdvance`, `isLast: Bool`.
```swift
import SwiftUI

struct ExerciseBannerView: View {
    let exercise: ExercisePlan
    let imageURL: URL?
    let indexLabel: String
    let current: Int
    let total: Int
    let isLast: Bool
    var onClose: () -> Void
    var onAdvance: () -> Void

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
        .frame(maxWidth: .infinity).clipped()
        .overlay(alignment: .top) {
            HStack(spacing: 12) {
                Button(action: onClose) { Image(systemName: "xmark").font(.body).foregroundStyle(.white).frame(width: 40, height: 40) }
                HStack(spacing: 3) {
                    ForEach(0..<max(total, 1), id: \.self) { i in
                        Capsule().fill(i <= current ? Theme.accent : Color.white.opacity(0.25)).frame(height: 3)
                    }
                }
                Button(action: onAdvance) { Text(isLast ? "Финиш" : "Дальше →").font(.subheadline).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.black.opacity(0.45))
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(exercise.displayName).font(.headline).foregroundStyle(.white)
                Spacer()
                Text(indexLabel).font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.black.opacity(0.74))
        }
    }
}
```

- [ ] **Step 2: LoggedSetChips**
```swift
import SwiftUI

struct LoggedSetChips: View {
    let logged: [LoggedSet]
    let currentSetIdx: Int
    let targetSets: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(logged.enumerated()), id: \.offset) { _, s in
                chip("✓ \(s.reps)×\(WorkoutSetFormat.weight(s.weight))", filled: true)
            }
            if targetSets > 0 { chip("подход \(currentSetIdx + 1) из \(targetSets)", filled: false) }
            Spacer(minLength: 0)
        }
    }
    private func chip(_ t: String, filled: Bool) -> some View {
        Text(t).font(.caption)
            .foregroundStyle(filled ? Theme.accent : .white.opacity(0.6))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(filled ? Theme.accent.opacity(0.15) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(filled ? .clear : Color.white.opacity(0.08), lineWidth: 0.5))
    }
}
```

- [ ] **Step 3: build → SUCCEEDED. Step 4: commit** `feat(workout): ExerciseBannerView hero + LoggedSetChips`.

---

## Task 6: WorkoutView body — 50/50 split + toolbar

**Files:** rewrite `Views/WorkoutView.swift` body. Add `onAppearPrefetch: () -> Void = {}` input.

- [ ] **Step 1: rewrite** `content` to a `GeometryReader` split: top `geo.size.height * 0.46` = `ExerciseBannerView` (onClose→abort confirm, onAdvance→`coordinator.finishExercise(comment:nil)` or finish-sheet if `readyToComplete`/last); bottom = `ScrollView { LoggedSetChips; FocusSetCard(coordinator,restTimer); primary "Записать подход" (calls the card's `logCurrent` — hold the card in an `@StateObject`-free way OR move the primary into the card and drop it here) ; iconToolbar }`. Keep `RestTimerOverlay(timer:restTimer, nextHint:)` + `CoachBannerView` overlays, abort alert, finish sheet. `.onAppear { onAppearPrefetch() }`.
  - Decision: keep "Записать подход" INSIDE `FocusSetCard` (Task 4 has `logCurrent`; render the button in the card too) to avoid cross-view state plumbing. So `WorkoutView` bottom = chips + FocusSetCard (which includes the primary) + toolbar. Update Task 4's card to render the primary button after the three rows.
  - Toolbar: `заменить` (`onSwap(coordinator.currentExercise.exerciseSlug)`), `отдых` (`restTimer.start(planned:currentExercise.restSec, lastRepsInReserve: coordinator.currentExercise.targetRir)`), `финиш` (`showFinishSheet = true`).
  - `nextHint` for the ring: "подход \(coordinator.currentSetIdx + 1) · \(WorkoutSetFormat.weight(lastWeight)) кг" (best-effort; or just "подход N").
- [ ] **Step 2: build → SUCCEEDED.** Remove the now-unused `navbar`/`progressDots`/`bottomBar` helpers + `ExerciseCardView` usage from WorkoutView.
- [ ] **Step 3: commit** `feat(workout): runner 50/50 split — banner hero + focus controls + toolbar`.

---

## Task 7: Swap visualization — cache slug-lookup, bus, dark sheet, wiring

**Files:** `Services/ExerciseImageCache.swift`, `Services/WorkoutInbound.swift`, `Services/AppCoordinator.swift`, `Views/Workout/SwapSheet.swift`, `Views/ChatView.swift`.

- [ ] **Step 1: ExerciseImageCache.latestPath**
```swift
/// Newest cached file for a slug regardless of sha (alternatives' sha isn't
/// known until the blob lands).
func latestPath(slug: String) -> URL? {
    let items = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return items.filter { $0.lastPathComponent.hasPrefix("\(slug)_") && $0.pathExtension == "jpg" }
        .sorted { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da > db
        }.first
}
```
- [ ] **Step 2: bus** — add `case imageReceived(slug: String)` to `WorkoutInboundEvent` (`Services/WorkoutInbound.swift`). In `AppCoordinator.handleWorkoutEnvelope` `.imageBlob` branch, after `imageCache.write(...)`, add `workoutBus.events.send(.imageReceived(b.slug))`. Update ChatView's `.onReceive` switch to handle the new case (bump a token; default no-op elsewhere).
- [ ] **Step 3: SwapSheet dark + thumbnails** — `.presentationBackground(Theme.background)` + `.preferredColorScheme(.dark)`; restyle to dark surfaces; add a `thumbnail: (_ slug: String) -> URL?` input + a `refreshToken: Int` input (changes on `.imageReceived` to re-resolve). Render the current exercise row (real thumbnail via the plan resolver) + alternative rows with thumbnail (via `thumbnail(slug)` → `UIImage(contentsOfFile:)` or placeholder), selected highlighted, confirm CTA names the choice.
- [ ] **Step 4: ChatView wiring** — `@State private var swapImageToken = 0`. On `.swapOptions(resp, _, _)`: set `swapResponse`, `swapLoading=false`, and fire `transport.sendImageRequest(slug:)` for each `resp.alternatives.map(\.slug)`. On `.imageReceived`: `swapImageToken += 1`. Pass into `SwapSheet`: `thumbnail: { coordinator.imageCache.latestPath(slug: $0) }`, `refreshToken: swapImageToken`.
- [ ] **Step 5: build → SUCCEEDED. Step 6: commit** `feat(workout): dark visualized swap sheet (alternative thumbnails)`.

---

## Task 8: ChatView prefetch on runner open + build bump + e2e

**Files:** `Views/ChatView.swift` (`onAppearPrefetch`), `ios/JarvisApp/project.yml`.

- [ ] **Step 1:** pass `onAppearPrefetch: { coordinator.imageCache.prefetch(manifest: presentation.plan.imageManifest.map { .init(slug: $0.slug, sha256: $0.sha256) }) }` into `WorkoutView` (running phase). (Manifest is `[WorkoutPlan.ImageManifestEntry]`; `prefetch` takes that type.)
- [ ] **Step 2:** bump `CURRENT_PROJECT_VERSION` (+ `MARKETING_VERSION` if a feature bump) in `project.yml`; `xcodegen generate`.
- [ ] **Step 3: full test suite** → JarvisAppTests green (incl. new WorkoutFormatTests / RestTimerTests).
- [ ] **Step 4: sim e2e via fake-WS** (`scripts/fake-ws-debug.ts` already answers image/swap/plan): open runner → big image hero (fake image_blob) + Russian name; three aligned controls; "Записать подход" → circular rest ring fills + "Пропустить"; "заменить" → DARK swap sheet with thumbnails → confirm; "Дальше →"/«финиш». Screenshot-verify.
- [ ] **Step 5: commit** `test(workout): runner redesign e2e + build bump` and push.

---

## Notes
- `@testable import Jarvis` (module `Jarvis`).
- Don't touch `WorkoutCoordinator` internals / `CoachBannerView`.
- Bump build on the install task; `xcodegen generate` after adding files.
- Alternatives' Russian names need `name_ru` in `exercise_swap_options` (protocol) — follow-up, out of scope.
- Payne `workout-mode` SKILL.md must answer `exercise_swap_request` on prod (sim uses the fake server) — follow-up.
