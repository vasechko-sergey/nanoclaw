# iPad Orb Hub Canvas + device-data expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `JarvisApp` a first-class iPad app — landscape shows a persistent "Orb Hub" left navigator (agent-orbs orbiting the signature orb) beside a chat canvas, while portrait/compact keep the current phone flow — and expand the device-context pull (calendar window, reminders, focus, motion, weather, Pencil/drag-drop).

**Architecture:** A new `RootAdaptiveView` chooses `.split` vs `.stacked` from available width + size-class (not `UIScreen`, not device). `.split` lays out `OrbHubPane | ChatCanvas`; `.stacked` renders the existing `ContentView` phase machine unchanged. The orb cluster is extracted into a reusable `OrbHub` whose satellites are injected (suggestions in narrow home, agents in the wide pane). Device data flows through the existing `request_context` pull: each new field is added in lockstep across the shared TS protocol, the agent-runner tool mirror, and the iOS coordinator/managers.

**Tech Stack:** SwiftUI (iOS 16+, module name `Jarvis`), xcodegen, XCTest/XCUITest, GRDB; TypeScript + zod + vitest (host `src/` and `shared/ios-app-protocol/`); Bun agent-runner (`container/agent-runner/`). EventKit, CoreMotion, Intents (Focus), WeatherKit.

---

## Verification toolbox (referenced by tasks)

- **Regenerate Xcode project** (after any new `.swift` file or `project.yml` change), run from repo root:
  `cd ios/JarvisApp && xcodegen generate`
- **iOS build** (prefer XcodeBuildMCP `build_sim`; CLI fallback):
  `xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme Jarvis -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)'`
- **iOS tests** (XcodeBuildMCP `test_sim`; CLI fallback):
  `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme Jarvis -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' -only-testing:JarvisAppTests/<TestClass>`
- **Test module import:** test files use `@testable import Jarvis` (NOT `JarvisApp`). Wrong name → misleading "unable to resolve module dependency".
- **iPad simulator screenshot** for UI verification: XcodeBuildMCP `build_run_sim` on an iPad sim, then `screenshot`.
- **Shared protocol typecheck:** `pnpm exec tsc -p shared/ios-app-protocol/tsconfig.json --noEmit`
- **Agent-runner typecheck** (forces the `request_context` exhaustive check): `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`
- **Host TS tests:** `pnpm test -- <path>` (vitest). **Container tests:** `cd container/agent-runner && bun test <path>`.
- **Protocol fixture contract:** `pnpm test -- shared/ios-app-protocol/v2.test.ts`

---

# PHASE 1 — Adaptive Orb Hub layout

## Task 1: `LayoutMode` pure resolver

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Utility/LayoutMode.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/LayoutModeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
@testable import Jarvis

final class LayoutModeTests: XCTestCase {
    func testLandscapeRegularWideIsSplit() {
        XCTAssertEqual(LayoutMode.resolve(width: 1194, height: 834, horizontalSizeClass: .regular), .split)
        XCTAssertEqual(LayoutMode.resolve(width: 1000, height: 700, horizontalSizeClass: .regular), .split)
    }
    func testPortraitIsStacked() {
        XCTAssertEqual(LayoutMode.resolve(width: 834, height: 1194, horizontalSizeClass: .regular), .stacked)
        XCTAssertEqual(LayoutMode.resolve(width: 1024, height: 1366, horizontalSizeClass: .regular), .stacked)
    }
    func testCompactIsStacked() {
        XCTAssertEqual(LayoutMode.resolve(width: 1200, height: 800, horizontalSizeClass: .compact), .stacked)
        XCTAssertEqual(LayoutMode.resolve(width: 390, height: 844, horizontalSizeClass: .compact), .stacked)
    }
    func testBelowMinWidthIsStacked() {
        XCTAssertEqual(LayoutMode.resolve(width: 880, height: 600, horizontalSizeClass: .regular), .stacked)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the `LayoutModeTests` target. Expected: FAIL to compile — `LayoutMode` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import SwiftUI

/// Chooses the iPad split layout vs the phone-style stacked flow.
/// Driven by the available window area + horizontal size class — never by
/// `UIScreen.main.bounds` or `UIDevice.orientation`, so it stays correct in
/// Stage Manager, Split View, Slide Over, and rotation.
enum LayoutMode: Equatable {
    case split    // Orb Hub left pane + chat canvas right pane
    case stacked  // current phone flow (splash -> home -> chat)

    /// Split only when the window is a wide landscape regular-width area.
    /// `width > height` detects a landscape *window* (works in Stage Manager,
    /// where the window may be any shape). 900pt is the floor below which the
    /// chat canvas would be too cramped.
    static func resolve(width: CGFloat, height: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) -> LayoutMode {
        guard horizontalSizeClass == .regular else { return .stacked }
        guard width > height else { return .stacked }
        guard width >= 900 else { return .stacked }
        return .split
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the `LayoutModeTests` target. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd ios/JarvisApp && xcodegen generate && cd -
git add ios/JarvisApp/Sources/JarvisApp/Utility/LayoutMode.swift ios/JarvisApp/Sources/JarvisAppTests/LayoutModeTests.swift ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): LayoutMode resolver — width+size-class drives split vs stacked"
```

---

## Task 2: Theme accepts explicit width (kill `UIScreen` hardcoding)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Utility/Theme.swift` (around lines 15-37 `refreshScale`/`computeScale`/`scale`, and 100-116 `refreshDrawerWidth`/`computeDrawerWidth`/`drawerWidth`)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/ThemeScaleTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Jarvis

final class ThemeScaleTests: XCTestCase {
    func testExplicitWidthDrivesScaleClamped() {
        Theme.refreshScale(width: 390)
        XCTAssertEqual(Theme.scale, 1.0, accuracy: 0.001)
        Theme.refreshScale(width: 1200)            // would be ~3.0, clamps to 1.15
        XCTAssertEqual(Theme.scale, 1.15, accuracy: 0.001)
        Theme.refreshScale(width: 300)             // would be ~0.77, clamps to 0.92
        XCTAssertEqual(Theme.scale, 0.92, accuracy: 0.001)
    }
    func testExplicitWidthDrivesDrawerWidth() {
        Theme.refreshDrawerWidth(width: 1000)
        XCTAssertEqual(Theme.drawerWidth, 780, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `ThemeScaleTests`. Expected: FAIL to compile — `refreshScale(width:)` / `refreshDrawerWidth(width:)` overloads do not exist.

- [ ] **Step 3: Write minimal implementation**

In `Theme.swift`, add width-taking overloads next to the existing no-arg ones (keep the scene-reading versions as fallback for callers that have no width yet):

```swift
    /// Set the scale from an explicit available-area width (preferred — call
    /// from RootAdaptiveView's GeometryReader). Same clamp as computeScale().
    static func refreshScale(width: CGFloat) {
        _cachedScale = min(max(width / 390, 0.92), 1.15)
    }
```

```swift
    /// Set the drawer width from an explicit available-area width.
    static func refreshDrawerWidth(width: CGFloat) {
        _cachedDrawerWidth = width * 0.78
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run `ThemeScaleTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/Theme.swift ios/JarvisApp/Sources/JarvisAppTests/ThemeScaleTests.swift ios/JarvisApp/JarvisApp.xcodeproj ios/JarvisApp/project.yml
git commit -m "feat(ios): Theme.refreshScale/refreshDrawerWidth accept explicit width"
```

---

## Task 3: `RootAdaptiveView` — new root, owns splash gate, stacked branch only

This task introduces the adaptive root but keeps `.split` as a visible placeholder, so behavior on iPhone is provably unchanged before the panes exist.

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/RootAdaptiveView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ContentView.swift` (remove the `.splash` phase ownership — keep `.home`/`.chat`; see Step 3)
- Modify: the app entry that currently shows `ContentView` (search `ContentView(coordinator`) — likely `JarvisApp.swift` or `AppV2Bootstrap`/`AppCoordinator` wiring
- Test: `ios/JarvisApp/Sources/JarvisUITests/RootAdaptiveSmokeTests.swift`

- [ ] **Step 1: Write the failing UITest**

```swift
import XCTest

final class RootAdaptiveSmokeTests: XCTestCase {
    func testStackedHomeAppearsOnLaunch() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitesting"]
        app.launch()
        XCTAssertTrue(app.otherElements["orb-home"].waitForExistence(timeout: 8))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `RootAdaptiveSmokeTests` on an iPhone simulator. Expected: FAIL only if wiring regresses; if `orb-home` still appears it passes trivially — that is the regression guard. (If it already passes pre-change, keep it; it locks the contract.)

- [ ] **Step 3: Write minimal implementation**

Create `RootAdaptiveView.swift`. It owns the splash gate (moved out of `ContentView`) and the width plumbing into `Theme`:

```swift
import SwiftUI

/// App root. Resolves the layout mode from the available area and routes to
/// either the split iPad layout or the stacked phone flow. Owns the splash /
/// connection gate so both branches share it. Feeds the real available width
/// into Theme (replacing UIScreen-based scaling).
struct RootAdaptiveView: View {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var coordinator: AppCoordinator

    @State private var ready = false

    var body: some View {
        GeometryReader { geo in
            let mode = LayoutMode.resolve(
                width: geo.size.width, height: geo.size.height,
                horizontalSizeClass: hSizeClass
            )
            Group {
                if !ready {
                    SplashView(
                        coordinator: coordinator,
                        settings: settingsBinding,
                        showSetup: $showSetup,
                        onReady: { withAnimation(.easeOut(duration: 0.6)) { ready = true } }
                    )
                } else {
                    switch mode {
                    case .stacked:
                        ContentView(coordinator: coordinator)   // existing home/chat phases
                    case .split:
                        SplitRootView(coordinator: coordinator)  // placeholder until Task 7
                    }
                }
            }
            .onAppear { applyWidth(geo.size.width) }
            .onChange(of: geo.size.width) { applyWidth(geo.size.width) }
        }
    }

    private func applyWidth(_ w: CGFloat) {
        Theme.refreshScale(width: w)
        Theme.refreshDrawerWidth(width: w)
    }

    // settings/showSetup wiring copied from the current ContentView/SplashView owner
    @Environment(AppSettings.self) private var settings
    private var settingsBinding: Bindable<AppSettings> { Bindable(settings) }
    @State private var showSetup = false
}

/// Temporary split placeholder — replaced in Task 7. Proves the branch renders.
private struct SplitRootView: View {
    var coordinator: AppCoordinator
    var body: some View {
        ContentView(coordinator: coordinator)   // fall back to stacked until panes exist
    }
}
```

Then:
- Modify `ContentView.swift`: delete the `.splash` case from `AppPhase` and the `SplashView` overlay block (lines ~54-67 and the `.splash` enum case + `appPhase` initial value). Start `appPhase` at `.home`. `SplashView` itself stays in the file (now driven by `RootAdaptiveView`). Update `onAppear` so connection is triggered by `RootAdaptiveView` instead (move the `coordinator.connect()` / `showSetupOnSplash` logic up to `RootAdaptiveView.applyWidth`/`onAppear`).
- Modify the entry point: replace `ContentView(coordinator:)` with `RootAdaptiveView(coordinator:)` at the app root.

- [ ] **Step 4: Run test to verify it passes**

Run `RootAdaptiveSmokeTests` on an iPhone sim. Expected: PASS — `orb-home` appears after splash. Also run existing `HomeViewSmokeTests`, `JarvisUITests` — expected PASS (no behavior change).

- [ ] **Step 5: Commit**

```bash
cd ios/JarvisApp && xcodegen generate && cd -
git add ios/JarvisApp/Sources/JarvisApp/Views/RootAdaptiveView.swift ios/JarvisApp/Sources/JarvisApp/Views/ContentView.swift ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift ios/JarvisApp/Sources/JarvisUITests/RootAdaptiveSmokeTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): RootAdaptiveView root + splash gate; stacked branch unchanged"
```

---

## Task 4: Extract reusable `OrbHub` core from `OrbHomeView`

Pull the orb cluster (central orb + satellite orbit + long-press action satellites + greeting + health strip) into `OrbHub`, with the satellite *content* injected. Narrow `OrbHomeView` keeps suggestion satellites — behavior unchanged. This unblocks the wide pane (Task 5).

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHub.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` (replace inline `orbCluster` with `OrbHub`; lines ~242-373)
- Test: existing `ios/JarvisApp/Sources/JarvisUITests/HomeViewSmokeTests.swift` is the regression guard

- [ ] **Step 1: Define the injectable satellite + orbit helper (write the type first)**

```swift
import SwiftUI

/// One satellite around the hub orb.
struct OrbSatellite: Identifiable {
    let id: String
    let icon: String?          // SF Symbol for suggestion/action satellites
    let label: String
    let accent: Color          // Theme.accent for suggestions; agent accent for agents
    let isHighlighted: Bool    // active agent / "continue" emphasis
    let action: () -> Void
}

enum OrbOrbit {
    /// Angle+radius for satellite `index` of `count` (top-anchored, clockwise).
    static func position(index: Int, count: Int, radius: CGFloat) -> CGPoint {
        let angle = -.pi / 2 + (2 * .pi / Double(max(count, 1))) * Double(index)
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }
}
```

- [ ] **Step 2: Write `OrbHub` by moving the cluster code**

Create `OrbHub.swift` containing the central `OrbView`, the satellite ring (driven by the injected `[OrbSatellite]`), the long-press action ring (driven by a second injected `[OrbSatellite]`), and `showSatellites` toggle. Move the geometry from `OrbHomeView.orbCluster` (lines ~242-373) verbatim, replacing the two hardcoded `ForEach(defaultSatellites…)` / `ForEach(actionSatellites…)` with the injected arrays and `OrbOrbit.position`. Signature:

```swift
struct OrbHub: View {
    let satellites: [OrbSatellite]          // default ring (suggestions OR agents)
    let actionSatellites: [OrbSatellite]    // revealed on long-press
    var mood: OrbMood = .welcoming
    var coreAccent: Color = Theme.accent
    var onOrbTap: () -> Void                // tap central orb (e.g. voice)
    @State private var showSatellites = false
    // body: the ZStack moved from orbCluster, using satellites/actionSatellites
}
```

Keep the `HomeSatelliteOrb` subview (move it into `OrbHub.swift` or a shared file) but let it take an `accent` color instead of the hardcoded `Theme.accent`, so agent satellites render in their own accent.

- [ ] **Step 3: Rewire `OrbHomeView` to use `OrbHub`**

In `OrbHomeView`, build `satellites` from `contextualSuggestions`/`defaultSatellites` and `actionSatellites` from the existing `actionSatellites` computed property, mapping each into `OrbSatellite` (accent `Theme.accent`, `isHighlighted` only for the "Продолжить" chat item). Replace the inline `orbCluster` usage with `OrbHub(satellites:…, actionSatellites:…, onOrbTap: { showVoiceFullscreen = true })`. Preserve the UI-test-only buttons and identifiers (`home-orb`, `orb-satellites-toggle`, etc.).

- [ ] **Step 4: Run tests to verify no regression**

Run `HomeViewSmokeTests`, `JarvisUITests`, `ThinkingRowTests`, `VoiceFullscreenTests` on an iPhone sim. Expected: PASS — narrow home identical.

- [ ] **Step 5: Commit**

```bash
cd ios/JarvisApp && xcodegen generate && cd -
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHub.swift ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "refactor(ios): extract reusable OrbHub with injectable satellites"
```

---

## Task 5: `OrbHubPane` — wide left pane with agent satellites

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHubPane.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/AgentSatelliteSelectionTests.swift`

- [ ] **Step 1: Write the failing test (selection logic, headless)**

Factor the "non-active agents → satellites" mapping into a static helper so it is testable without a running view:

```swift
import XCTest
import SwiftUI
@testable import Jarvis

final class AgentSatelliteSelectionTests: XCTestCase {
    func testOrbitExcludesActiveAndCoversOthers() {
        let ids = OrbHubPane.satelliteAgents(active: .jarvis).map { $0.rawValue }
        XCTAssertFalse(ids.contains("jarvis"))
        XCTAssertEqual(Set(ids), Set(["payne", "greg", "scrooge", "gordon"]))
    }
    func testActiveAgentDrivesCoreAccent() {
        XCTAssertEqual(OrbHubPane.coreAccent(active: .payne), AgentIdentity.payne.accentColor)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run `AgentSatelliteSelectionTests`. Expected: FAIL to compile — `OrbHubPane` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import SwiftUI

/// Wide-layout left pane: the signature orb as a persistent agent navigator.
/// The centre orb is the active agent; the four other agents orbit it. Tapping
/// a satellite promotes that agent (the chat canvas re-binds via ActiveAgentState).
struct OrbHubPane: View {
    @Environment(ActiveAgentState.self) private var active
    var coordinator: AppCoordinator
    var onOpenProfile: () -> Void

    static func satelliteAgents(active: AgentIdentity) -> [AgentIdentity] {
        AgentIdentity.allCases.filter { $0 != active }
    }
    static func coreAccent(active: AgentIdentity) -> Color { active.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            // status dot + profile entry (mirrors OrbHomeView header affordances)
            HStack {
                HeaderStatusDot(side: .left, isConnected: coordinator.ws.isConnected, phase: .calm,
                                onTap: {}, onLongPress: {})
                Spacer()
                HeaderStatusDot(side: .right, isConnected: coordinator.ws.isConnected, phase: .calm,
                                onTap: onOpenProfile)
            }
            .padding(.horizontal, Theme.scaled(8))
            .frame(minHeight: Theme.headerHeight)

            Spacer()
            OrbHub(
                satellites: Self.satelliteAgents(active: active.active).map { agent in
                    OrbSatellite(
                        id: agent.rawValue, icon: nil, label: agent.displayName,
                        accent: agent.accentColor, isHighlighted: false,
                        action: {
                            Theme.hapticMedium()
                            withAnimation(.easeInOut(duration: 0.4)) { active.active = agent }
                        }
                    )
                },
                actionSatellites: [],            // long-press actions optional in pane; empty for now
                mood: .welcoming,
                coreAccent: Self.coreAccent(active: active.active),
                onOrbTap: {}
            )
            Spacer()
            HealthStripView(levels: nil)         // wired to StateService popover in Task 8
                .padding(.bottom, Theme.scaled(8))
        }
        .background(Theme.background)
    }
}
```

(If `OrbSatellite.icon == nil`, render the agent orb as a colored ring + core in `HomeSatelliteOrb` instead of an SF Symbol — add that branch in `HomeSatelliteOrb`.)

- [ ] **Step 4: Run test to verify it passes**

Run `AgentSatelliteSelectionTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ios/JarvisApp && xcodegen generate && cd -
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHubPane.swift ios/JarvisApp/Sources/JarvisApp/Views/OrbHub.swift ios/JarvisApp/Sources/JarvisAppTests/AgentSatelliteSelectionTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): OrbHubPane — agent satellites orbit the hub orb"
```

---

## Task 6: Embeddable `ChatView` (chat canvas)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` (add an `embedded` flag; gate the "home" affordance + fullscreen-only chrome on it)
- Test: existing `ChatViewAgentFilterTests` is the regression guard

- [ ] **Step 1: Add the `embedded` flag**

Add `var embedded: Bool = false` to `ChatView`. When `embedded`:
- hide the back/"go home" control in the header (there is no home phase in split),
- keep the agent name + status dot + a "новый чат" (`new_conversation`) control,
- keep the message timeline + `UnifiedInputBar` exactly as-is.

Default `embedded = false` preserves the current fullscreen behavior and the `onGoHome` path for the stacked flow.

- [ ] **Step 2: Build to verify it compiles**

Run the iOS build (Verification toolbox). Expected: SUCCESS.

- [ ] **Step 3: Run regression tests**

Run `ChatViewAgentFilterTests`, `MessageTimelineTests`, `MessageMappingTests`. Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): ChatView embedded mode for split canvas"
```

---

## Task 7: Assemble the split layout in `RootAdaptiveView`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/RootAdaptiveView.swift` (replace the `SplitRootView` placeholder)
- Test: `ios/JarvisApp/Sources/JarvisUITests/SplitLayoutTests.swift`

- [ ] **Step 1: Write the failing UITest (iPad landscape)**

```swift
import XCTest

final class SplitLayoutTests: XCTestCase {
    func testSplitShowsHubAndChatCanvas() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitesting"]
        app.launch()
        XCDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["orb-hub-pane"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["chat-canvas"].waitForExistence(timeout: 8))
    }
}
```

- [ ] **Step 2: Run on an iPad sim to verify it fails**

Run `SplitLayoutTests` on `iPad Pro 11-inch (M4)`. Expected: FAIL — placeholder has no `orb-hub-pane`/`chat-canvas` identifiers.

- [ ] **Step 3: Implement the split**

Replace `SplitRootView` with a version that takes the available `width` from the parent `GeometryReader` (no `UIScreen`), and have `RootAdaptiveView` pass `geo.size.width` when it instantiates it (`SplitRootView(coordinator: coordinator, width: geo.size.width)`):

```swift
private struct SplitRootView: View {
    var coordinator: AppCoordinator
    var width: CGFloat
    @State private var showProfile = false

    private var paneWidth: CGFloat { min(max(width * 0.38, 360), 460) }

    var body: some View {
        HStack(spacing: 0) {
            OrbHubPane(coordinator: coordinator, onOpenProfile: { showProfile = true })
                .frame(width: paneWidth)
                .accessibilityIdentifier("orb-hub-pane")
            Rectangle().fill(Theme.accent.opacity(0.08)).frame(width: 0.5)
            ChatView(coordinator: coordinator, onGoHome: {}, autoStartVoice: .constant(false), embedded: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat-canvas")
        }
        .sheet(isPresented: $showProfile) {
            RightDrawerContent(isConnected: coordinator.ws.isConnected, onReconnect: {
                coordinator.disconnect()
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); coordinator.connect() }
            })
        }
    }
}
```

In `RootAdaptiveView`, update the `.split` branch from Task 3 to `SplitRootView(coordinator: coordinator, width: geo.size.width)`.

- [ ] **Step 4: Run test to verify it passes**

Run `SplitLayoutTests` on the iPad sim. Expected: PASS. Then take a screenshot (XcodeBuildMCP) and visually confirm: hub orb + agent satellites left, chat right, dark/teal preserved.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/RootAdaptiveView.swift ios/JarvisApp/Sources/JarvisUITests/SplitLayoutTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): assemble OrbHubPane | ChatCanvas split layout"
```

---

## Task 8: Profile popover + StateBoard popover on wide; agent-switch swaps timeline

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHubPane.swift` (wire `StateService` + health strip tap → popover)
- Test: `ios/JarvisApp/Sources/JarvisUITests/SplitAgentSwitchTests.swift`

- [ ] **Step 1: Write the failing UITest**

```swift
import XCTest

final class SplitAgentSwitchTests: XCTestCase {
    func testTappingAgentSatelliteUpdatesCanvasHeader() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitesting"]
        app.launch()
        XCDevice.shared.orientation = .landscapeLeft
        app.buttons["Maj Payne"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Maj Payne"].waitForExistence(timeout: 4))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run `SplitAgentSwitchTests` on the iPad sim. Expected: FAIL until the satellite buttons carry accessibility labels and the canvas header reflects the active agent.

- [ ] **Step 3: Implement**

In `OrbHubPane`: add `@StateObject private var stateService = StateService()`, `.onAppear { stateService.refresh() }`, pass `stateService.state?.levels` into `HealthStripView`, and present `StateBoardView` as a `.popover` on health-strip tap. Ensure each agent satellite button has `.accessibilityLabel(agent.displayName)`. The chat header already reflects `active.active` (Task 6) — confirm it updates on switch.

- [ ] **Step 4: Run to verify it passes**

Run `SplitAgentSwitchTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHubPane.swift ios/JarvisApp/Sources/JarvisUITests/SplitAgentSwitchTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): wide profile/state popovers + agent-switch swaps canvas"
```

---

## Task 9: Keyboard shortcuts, hover, drag-drop, Scribble

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/RootAdaptiveView.swift` (`.keyboardShortcut` handlers on the split)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHub.swift` (`.hoverEffect` on satellites)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` (`.dropDestination` when `embedded`)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/KeyboardShortcutMapTests.swift`

- [ ] **Step 1: Write the failing test (shortcut→agent map, headless)**

```swift
import XCTest
@testable import Jarvis

final class KeyboardShortcutMapTests: XCTestCase {
    func testNumberKeyMapsToAgentByOrder() {
        XCTAssertEqual(AgentShortcuts.agent(forNumber: 1), .jarvis)
        XCTAssertEqual(AgentShortcuts.agent(forNumber: 5), AgentIdentity.allCases[4])
        XCTAssertNil(AgentShortcuts.agent(forNumber: 6))
        XCTAssertNil(AgentShortcuts.agent(forNumber: 0))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run `KeyboardShortcutMapTests`. Expected: FAIL — `AgentShortcuts` undefined.

- [ ] **Step 3: Implement**

```swift
enum AgentShortcuts {
    static func agent(forNumber n: Int) -> AgentIdentity? {
        let all = AgentIdentity.allCases
        guard n >= 1, n <= all.count else { return nil }
        return all[n - 1]
    }
}
```

Then on the split container add hidden buttons with `.keyboardShortcut`:
- `⌘1…⌘5` → `if let a = AgentShortcuts.agent(forNumber: n) { active.active = a }`
- `⌘N` → new conversation on the active agent
- `⌘↩` → send current input (route into `UnifiedInputBar`'s send)
- `Esc` → resign first responder

Add `.hoverEffect(.lift)` to `HomeSatelliteOrb`. Add `.dropDestination(for: [URL.self, UIImage.self])` to the embedded `ChatView` content that appends `DraftAttachment`s (reuse the existing attachment ingestion path used by `attachmentPickers`). Scribble needs no code — verify in Step 4 that the `UnifiedInputBar` text field accepts Apple-Pencil handwriting on an iPad sim with a connected pencil (or note as manual-device verification).

- [ ] **Step 4: Run tests + manual verify**

Run `KeyboardShortcutMapTests` → PASS. Build to iPad sim; with a hardware keyboard attached to the sim, verify ⌘1–5 switch agents and ⌘N starts a new chat. Drag an image file onto the canvas → becomes an attachment.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/RootAdaptiveView.swift ios/JarvisApp/Sources/JarvisApp/Views/OrbHub.swift ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift ios/JarvisApp/Sources/JarvisApp/Utility/AgentShortcuts.swift ios/JarvisApp/Sources/JarvisAppTests/KeyboardShortcutMapTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): keyboard shortcuts, hover, drag-drop on split canvas"
```

---

## Task 10: Phase 1 full-suite verification

- [ ] **Step 1:** Run the entire iOS test suite on both an iPhone sim and an `iPad Pro 11-inch (M4)` sim. Expected: all green.
- [ ] **Step 2:** Screenshot iPad landscape (split) and iPad portrait (stacked) — confirm portrait is the phone flow, landscape is the hub+canvas, dark/teal/orb identity intact.
- [ ] **Step 3:** Commit nothing new; if any fix was needed, commit it with `fix(ios): …`.

---

# PHASE 2 — device-data expansion

> Pre-check (do once before Task 11): confirm `AppCoordinator` (instantiates `LocationManager`/`HealthManager`/`CalendarManager` at ~lines 55-57) actually passes them into the `AppContextCoordinator` used by `TransportV2`. If they are `nil` at the coordinator, calendar/health pull is dead — wire them through `AppV2Bootstrap.build(..., location:health:calendar:)` first and add a test asserting `AppContextCoordinator`'s managers are non-nil in the production wiring.

## Task 11: Calendar full window (protocol already supports `calendar_window`)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/CalendarManager.swift` (add a range query)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift` (`calendar()` honors the window param; lines 61-77)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` (decode the `calendar_window` param if not already carried)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/CalendarWindowTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import EventKit
@testable import Jarvis

final class CalendarWindowTests: XCTestCase {
    func testWindowEndForNext7d() {
        let start = ISO8601DateFormatter().date(from: "2026-06-14T00:00:00Z")!
        let end = CalendarManager.windowEnd(window: "next_7d", from: start)
        XCTAssertEqual(end.timeIntervalSince(start), 7 * 24 * 3600, accuracy: 1)
    }
    func testWindowEndDefaultsToToday() {
        let start = ISO8601DateFormatter().date(from: "2026-06-14T00:00:00Z")!
        let end = CalendarManager.windowEnd(window: "today", from: start)
        XCTAssertEqual(end.timeIntervalSince(start), 24 * 3600, accuracy: 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run `CalendarWindowTests`. Expected: FAIL — `windowEnd` undefined.

- [ ] **Step 3: Implement**

In `CalendarManager`:

```swift
static func windowEnd(window: String, from start: Date) -> Date {
    switch window {
    case "next_7d":  return start.addingTimeInterval(7 * 24 * 3600)
    case "next_30d": return start.addingTimeInterval(30 * 24 * 3600)
    default:         return start.addingTimeInterval(24 * 3600)   // "today"
    }
}

/// Events between now and the window end, sorted by start.
func events(window: String) -> [(title: String, start: Date, end: Date)] {
    let store = self.store                    // reuse the manager's existing EKEventStore property — confirm its name in CalendarManager
    let now = Date()
    let pred = store.predicateForEvents(withStart: now, end: Self.windowEnd(window: window, from: now), calendars: nil)
    return store.events(matching: pred)
        .sorted { $0.startDate < $1.startDate }
        .map { ($0.title ?? "", $0.startDate, $0.endDate) }
}
```

In `AppContextCoordinator.calendar()`, accept the window param (thread `params.calendar_window` from the request through to here; default `"today"`) and return the full array:

```swift
func calendar(window: String = "today") async throws -> V2.JSONValue {
    guard let c = calendarManager else { return .array([]) }
    let events = await MainActor.run { c.events(window: window) }
    let iso = ISO8601DateFormatter()
    return .array(events.map { e in
        .object([
            "title": .string(e.title),
            "start": .string(iso.string(from: e.start)),
            "end":   .string(iso.string(from: e.end)),
        ])
    })
}
```

Remove the stale single-`nextEvent` TODO. Ensure the request dispatcher passes `params.calendar_window` into this call (check `TransportV2`/the context-response builder where `coordinator.calendar()` is invoked).

- [ ] **Step 4: Run to verify it passes**

Run `CalendarWindowTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/CalendarManager.swift ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/CalendarWindowTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat(ios): calendar pull honors calendar_window, returns full event list"
```

---

## Task 12: New `reminders` context field (full lockstep)

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts` (`ContextFieldEnum`)
- Modify: `container/agent-runner/src/mcp-tools/request_context.ts` (`CONTEXT_FIELDS`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift` (add `reminders()`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/CalendarManager.swift` (EKReminder fetch) or new `RemindersManager.swift`
- Modify: `ios/JarvisApp/project.yml` (Info: `NSRemindersFullAccessUsageDescription`)
- Test: `shared/ios-app-protocol/v2.test.ts` (enum), `container/agent-runner/src/mcp-tools/request_context.test.ts`

- [ ] **Step 1: Write the failing protocol test**

In `shared/ios-app-protocol/v2.test.ts` add:

```ts
import { ContextFieldEnum } from './v2.js';
it('includes reminders context field', () => {
  expect(ContextFieldEnum.options).toContain('reminders');
});
```

- [ ] **Step 2: Run to verify it fails**

Run `pnpm test -- shared/ios-app-protocol/v2.test.ts`. Expected: FAIL — `reminders` not in enum.

- [ ] **Step 3: Implement protocol + tool mirror**

In `shared/ios-app-protocol/v2.ts`:

```ts
export const ContextFieldEnum = z.enum([
  'health', 'calendar', 'device', 'next_event', 'recent_locations', 'screen_state',
  'reminders',
]);
```

In `container/agent-runner/src/mcp-tools/request_context.ts` mirror:

```ts
const CONTEXT_FIELDS = [
  'health', 'calendar', 'device', 'next_event', 'recent_locations', 'screen_state',
  'reminders',
] as const satisfies readonly ContextField[];
```

- [ ] **Step 4: Run protocol test + both typechecks**

`pnpm test -- shared/ios-app-protocol/v2.test.ts` → PASS.
`pnpm exec tsc -p shared/ios-app-protocol/tsconfig.json --noEmit` → clean.
`pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit` → clean (`_exhaustive` stays satisfied).

- [ ] **Step 5: Implement iOS side**

Add `NSRemindersFullAccessUsageDescription` to the app target Info in `project.yml` (follow the existing HealthKit/location usage-string keys). Add reminders fetch:

```swift
func reminders(window: String = "today") async -> [(title: String, due: Date?)] {
    let store = self.store                    // same EKEventStore property as events(window:)
    let ok = (try? await store.requestFullAccessToReminders()) ?? false
    guard ok else { return [] }
    let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil,
              ending: CalendarManager.windowEnd(window: window, from: Date()), calendars: nil)
    return await withCheckedContinuation { cont in
        store.fetchReminders(matching: pred) { rems in
            cont.resume(returning: (rems ?? []).map { ($0.title ?? "", $0.dueDateComponents?.date) })
        }
    }
}
```

In `AppContextCoordinator`:

```swift
func reminders() async throws -> V2.JSONValue {
    guard let c = calendarManager else { return .array([]) }
    let items = await c.reminders()
    let iso = ISO8601DateFormatter()
    return .array(items.map { r in
        var o: [String: V2.JSONValue] = ["title": .string(r.title)]
        if let d = r.due { o["due"] = .string(iso.string(from: d)) }
        return .object(o)
    })
}
```

Wire `reminders` into the field-dispatch switch (where `health`/`calendar`/… map to coordinator calls) in `V2.swift`/`TransportV2`.

- [ ] **Step 6: Run iOS build + commit**

Build iOS (Verification toolbox) → SUCCESS.

```bash
cd ios/JarvisApp && xcodegen generate && cd -
pnpm run build
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts container/agent-runner/src/mcp-tools/request_context.ts ios/JarvisApp/Sources/JarvisApp/Services/CalendarManager.swift ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat: add reminders context field end-to-end"
```

---

## Task 13: New `focus` context field

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`, `container/agent-runner/src/mcp-tools/request_context.ts`
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/FocusManager.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift`, `Protocol/V2.swift`
- Test: `shared/ios-app-protocol/v2.test.ts`

- [ ] **Step 1: Failing protocol test** — add `expect(ContextFieldEnum.options).toContain('focus')`.
- [ ] **Step 2: Run** `pnpm test -- shared/ios-app-protocol/v2.test.ts` → FAIL.
- [ ] **Step 3: Add `'focus'`** to `ContextFieldEnum` and the `CONTEXT_FIELDS` mirror.
- [ ] **Step 4: Run** the protocol test + both typechecks → PASS/clean.
- [ ] **Step 5: iOS** — `FocusManager` returns the bool only (API limit — no specific mode):

```swift
import Intents
struct FocusManager {
    func isFocused() async -> Bool? {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus != .authorized {
            _ = await withCheckedContinuation { c in
                INFocusStatusCenter.default.requestAuthorization { c.resume(returning: $0) }
            }
        }
        guard center.authorizationStatus == .authorized else { return nil }
        return center.focusStatus.isFocused
    }
}
```

In `AppContextCoordinator.focus()` return `.object(["is_focused": .bool(value)])` when known, else `.object([:])`. Wire into the dispatch switch. (No new Info.plist key beyond the Focus authorization prompt, which `requestAuthorization` triggers.)

- [ ] **Step 6: Build iOS + commit**

```bash
cd ios/JarvisApp && xcodegen generate && cd -; pnpm run build
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts container/agent-runner/src/mcp-tools/request_context.ts ios/JarvisApp/Sources/JarvisApp/Services/FocusManager.swift ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat: add focus (is_focused) context field end-to-end"
```

---

## Task 14: New `motion` context field

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`, `container/agent-runner/src/mcp-tools/request_context.ts`
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/MotionManager.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift`, `Protocol/V2.swift`, `ios/JarvisApp/project.yml` (`NSMotionUsageDescription`)
- Test: `shared/ios-app-protocol/v2.test.ts`

- [ ] **Step 1: Failing protocol test** — `expect(ContextFieldEnum.options).toContain('motion')`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Add `'motion'`** to enum + mirror.
- [ ] **Step 4: Run** protocol test + both typechecks → PASS/clean.
- [ ] **Step 5: iOS** — `MotionManager` reads the latest activity classification:

```swift
import CoreMotion
final class MotionManager {
    private let activity = CMMotionActivityManager()
    func currentActivity() async -> String? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        return await withCheckedContinuation { cont in
            let now = Date()
            activity.queryActivityStarting(from: now.addingTimeInterval(-120), to: now,
                                           to: .main) { acts, _ in
                guard let a = acts?.last else { cont.resume(returning: nil); return }
                let label = a.walking ? "walking" : a.running ? "running"
                    : a.automotive ? "automotive" : a.cycling ? "cycling"
                    : a.stationary ? "stationary" : "unknown"
                cont.resume(returning: label)
            }
        }
    }
}
```

In `AppContextCoordinator.motion()` return `.object(["activity": .string(label)])` when known, else `.object([:])`. Add `NSMotionUsageDescription` to `project.yml`. Wire into the dispatch switch.

- [ ] **Step 6: Build iOS + commit**

```bash
cd ios/JarvisApp && xcodegen generate && cd -; pnpm run build
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts container/agent-runner/src/mcp-tools/request_context.ts ios/JarvisApp/Sources/JarvisApp/Services/MotionManager.swift ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat: add motion (activity) context field end-to-end"
```

---

## Task 15: New `weather` context field (LAST — entitlement-gated, optional)

> WeatherKit needs a capability registered in the Apple Developer portal + an entitlement + provisioning. On a Personal Team this may be unavailable; if registration blocks, ship Phase 2 without this field — the others are independent.

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`, `container/agent-runner/src/mcp-tools/request_context.ts`
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/WeatherManager.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift`, `Protocol/V2.swift`, `ios/JarvisApp/project.yml` + `JarvisApp.entitlements` (WeatherKit)
- Test: `shared/ios-app-protocol/v2.test.ts`

- [ ] **Step 1: Failing protocol test** — `expect(ContextFieldEnum.options).toContain('weather')`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Add `'weather'`** to enum + mirror.
- [ ] **Step 4: Run** protocol test + both typechecks → PASS/clean.
- [ ] **Step 5: Provisioning** — add the WeatherKit capability in the Apple Developer portal for `com.vasechko.jarvis`, add the WeatherKit entitlement to `JarvisApp.entitlements`, regenerate. If this step is blocked on a Personal Team, STOP and revert Steps 1-4 (drop the field) — do not ship a non-compiling entitlement.
- [ ] **Step 6: iOS** — `WeatherManager` reads current conditions at the last known location:

```swift
import WeatherKit
import CoreLocation
final class WeatherManager {
    private let service = WeatherService.shared
    func current(at loc: CLLocation) async -> (tempC: Double, condition: String)? {
        guard let w = try? await service.weather(for: loc) else { return nil }
        return (w.currentWeather.temperature.converted(to: .celsius).value,
                w.currentWeather.condition.description)
    }
}
```

In `AppContextCoordinator.weather()`: use `locationManager?.lastLocation`; return `.object(["temp_c": .double(round(t)), "condition": .string(c)])` when known, else `.object([:])`. Wire into dispatch.

- [ ] **Step 7: Build iOS + commit**

```bash
cd ios/JarvisApp && xcodegen generate && cd -; pnpm run build
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts container/agent-runner/src/mcp-tools/request_context.ts ios/JarvisApp/Sources/JarvisApp/Services/WeatherManager.swift ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.entitlements ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "feat: add weather context field end-to-end (WeatherKit)"
```

---

## Task 16: Phase 2 verification + deploy host side

- [ ] **Step 1:** `pnpm test` (host) + `cd container/agent-runner && bun test` — all green; both typechecks clean.
- [ ] **Step 2:** Full iOS suite on iPhone + iPad sims — green.
- [ ] **Step 3:** Deploy host/protocol changes to VDS (the new context fields live in `shared/` + `container/agent-runner/`, which are host-mounted): `pnpm run build && git push`, then on the VDS `git pull && pnpm run build && systemctl --user restart nanoclaw`. (Per the iOS CLAUDE.md deploy block.)
- [ ] **Step 4:** Sergei rebuilds the app on-device (new fields + iPad layout only reach the device on rebuild). Verify on a physical iPad: landscape split, agent switch, a `request_context` pull of `calendar`/`reminders`/`focus`/`motion` returns real values.

---

## Notes for the executor

- **xcodegen after every new `.swift`** — the `.xcodeproj` is generated from `project.yml`; never hand-edit it. New files won't compile until regenerated.
- **agent-runner is Bun, not pnpm** — if you touch `container/agent-runner/` deps, use `bun install` there; for this plan you only edit a TS source file, so `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit` is the check.
- **Keep the `_exhaustive` check happy** — the enum and the `CONTEXT_FIELDS` mirror must change in the same commit, or agent-runner fails to typecheck.
- **Phase 1 and Phase 2 are independent** — Phase 2 ships value even if the iPad layout is still in review, and vice versa.
- **Health-field expansion is explicitly out of scope** (see spec non-goals) — do not add HRV/SpO2/etc. here.
```
