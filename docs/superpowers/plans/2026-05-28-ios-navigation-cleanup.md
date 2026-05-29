# iOS Navigation Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify all top-level navigation in the iOS Jarvis app under mirrored side drawers — left for conversations, right for profile + context + settings — replacing the current mix of side drawer + bottom sheets. Replace the in-header MiniOrb (chat) and gearshape buttons (both screens) with one symmetric `HeaderStatusDot` component on each side.

**Architecture:** New `HeaderStatusDot` SwiftUI component (status-coloured dot on the left, phase-coloured dot on the right). Extract embeddable form bodies (`SettingsFormBody`, `ProfileFormBody`) so settings/profile can render inside a drawer instead of a sheet. New `RightDrawerContent` view — single `ScrollView` with Profile / Context / Settings sections, mirroring the structure of the existing `DrawerContent` (left drawer). `ChatView` and `OrbHomeView` each mount both drawers and gate one-open-at-a-time via state. `.sheet(isPresented: $showSettings/$showProfile)` modifiers come out everywhere except the first-run setup card on `SplashView`.

**Tech Stack:** Swift / SwiftUI / XCTest on iOS 18+. xcodegen for project regeneration.

**Scope note:** This plan is Plan A of the larger `2026-05-28-ios-ui-unified-navigation-design.md` spec. Plans B (Voice fullscreen `OrbVoiceView`), C (Conversation-as-satellite on home), and D (Apple Watch companion + `JarvisCore` SPM extraction) follow as separate plans.

---

## File Structure

| File | Purpose |
|---|---|
| `ios/JarvisApp/Sources/JarvisApp/Components/HeaderStatusDot.swift` (NEW) | One symmetric dot. Side enum (`.left` / `.right`) drives fill colour from connection status or orb mood. Tap action passes through. |
| `ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift` (NEW) | Single-`ScrollView` drawer with Profile / Context / Settings sections. Same visual language as `DrawerContent`. |
| `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift` (MODIFY) | Extract row body into `SettingsFormBody` view; `SettingsView` becomes a thin wrapper that uses it for the initial-setup sheet. `RightDrawerContent` embeds the same body. |
| `ios/JarvisApp/Sources/JarvisApp/Views/ProfileView.swift` (MODIFY) | Same pattern — extract `ProfileFormBody`. |
| `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` (MODIFY) | Replace header MiniOrb+dot+gearshape with two `HeaderStatusDot`. Add right-drawer state + mount + edge-swipe gesture. Collision rule — opening either drawer closes the other. Remove `.sheet(isPresented: $showSettings)` and `.sheet(isPresented: $showProfile)` along with the underlying `@State` vars. |
| `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` (MODIFY) | Replace bare status dot + gearshape with two `HeaderStatusDot`. Add right-drawer mount + edge-swipe. Remove ProfileView sheet. |
| `ios/JarvisApp/Sources/JarvisApp/Views/ContentView.swift` (MODIFY) | Drop `showSettings` state + `.sheet`; drop `onShowSettings` argument to `OrbHomeView`. First-run path through `SplashView.setupCard` is unchanged. |
| `ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift` (MODIFY) | Remove the Profile / Settings footer row from `DrawerContent`. Left drawer = conversations only. |
| `ios/JarvisApp/Sources/JarvisAppTests/HeaderStatusDotTests.swift` (NEW) | Color matrix: `(.left, connected)` → online; `(.left, disconnected)` → offline; `(.right, mood)` → accent / accentMedium / offline per spec. |
| `ios/JarvisApp/Sources/JarvisUITests/RightDrawerOpenTest.swift` (NEW) | Right-edge swipe opens drawer; Profile/Context/Settings sections present; tap outside closes. |
| `ios/JarvisApp/Sources/JarvisUITests/DrawerCollisionTest.swift` (NEW) | With left drawer open, right edge-swipe is ignored. Vice versa. |

## Test Commands

- **iOS unit tests:** `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/<ClassName>` (or omit `-only-testing` to run all).
- **iOS UI tests:** same command, `-only-testing:JarvisUITests/<ClassName>` instead.
- **Regenerate Xcode project after adding files:** `cd ios/JarvisApp && xcodegen generate`.

---

### Task 1: HeaderStatusDot component

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Components/HeaderStatusDot.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/HeaderStatusDotTests.swift`

- [ ] **Step 1: Regenerate Xcode project so new files register**

Run from repo root:
```bash
cd ios/JarvisApp && xcodegen generate
```
Expected: `Created project at ...`.

- [ ] **Step 2: Write failing tests**

Create `ios/JarvisApp/Sources/JarvisAppTests/HeaderStatusDotTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Jarvis

@MainActor
final class HeaderStatusDotTests: XCTestCase {

    func testLeftFillOnlineWhenConnected() {
        let dot = HeaderStatusDot(side: .left, isConnected: true, phase: .calm) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.online)
    }

    func testLeftFillOfflineWhenDisconnected() {
        let dot = HeaderStatusDot(side: .left, isConnected: false, phase: .calm) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.offline)
    }

    func testRightFillAccentWhenProcessing() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .processing) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.accent)
    }

    func testRightFillAccentWhenListening() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .listening) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.accent)
    }

    func testRightFillAccentWhenSpeaking() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .speaking) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.accent)
    }

    func testRightFillOfflineWhenError() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .error) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.offline)
    }

    func testRightFillAccentMediumForOtherMoods() {
        let dot = HeaderStatusDot(side: .right, isConnected: true, phase: .calm) {}
        XCTAssertEqual(dot.resolvedFillColor, Theme.accentMedium)
    }
}
```

- [ ] **Step 3: Run tests, confirm failure (HeaderStatusDot undefined)**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/HeaderStatusDotTests 2>&1 | tail -20
```
Expected: build error — `HeaderStatusDot` not in scope.

- [ ] **Step 4: Implement HeaderStatusDot**

Create `ios/JarvisApp/Sources/JarvisApp/Components/HeaderStatusDot.swift`:

```swift
import SwiftUI

/// Symmetric header status dot — one on each side of the unified header.
/// Left side communicates WebSocket connection state; right side communicates
/// agent phase (processing / listening / speaking / idle). Tapping the dot
/// opens the corresponding side drawer.
struct HeaderStatusDot: View {
    enum Side { case left, right }

    let side: Side
    let isConnected: Bool        // meaningful for .left
    let phase: OrbMood           // meaningful for .right
    let action: () -> Void

    /// Exposed for unit tests. Production rendering uses the same value via
    /// `fillColor` inside `body`.
    var resolvedFillColor: Color {
        switch side {
        case .left:
            return isConnected ? Theme.online : Theme.offline
        case .right:
            switch phase {
            case .processing, .listening, .speaking: return Theme.accent
            case .error:                             return Theme.offline
            default:                                 return Theme.accentMedium
            }
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(resolvedFillColor.opacity(0.2), lineWidth: Theme.lineAccent)
                    .frame(width: Theme.scaled(22), height: Theme.scaled(22))
                Circle()
                    .fill(resolvedFillColor)
                    .frame(width: Theme.scaled(8), height: Theme.scaled(8))
                    .shadow(color: resolvedFillColor.opacity(0.8), radius: 4)
            }
            .frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
    }
}
```

- [ ] **Step 5: Regenerate Xcode project + run tests**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/HeaderStatusDotTests 2>&1 | tail -15
```
Expected: 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/HeaderStatusDot.swift \
        ios/JarvisApp/Sources/JarvisAppTests/HeaderStatusDotTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add HeaderStatusDot — symmetric header dot component

Single component for both header positions. Left side fill comes from
isConnected (online/offline); right side fill comes from OrbMood
(processing/listening/speaking → accent, error → offline, otherwise
accentMedium). Unit tests pin the colour matrix so a future Theme
refactor can't silently flip the meaning."
```

---

### Task 2: Extract SettingsFormBody from SettingsView

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift`

This task is a pure refactor — `SettingsView`'s rendered output should be unchanged. The full test target should pass without code change.

- [ ] **Step 1: Read SettingsView.swift end-to-end** to understand its current structure.

The file is ~318 lines: header (close + title), then a `ScrollView` with form sections (server URL, token, voice, toggles, version). The `NavigationStack` wrapping and the header live inside `SettingsView`. The rendered sections live in the middle.

- [ ] **Step 2: Extract the form body into a new top-level view**

In `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift`, add a new view above `SettingsView`:

```swift
/// Embeddable settings form body — used by both `SettingsView` (sheet during
/// initial setup) and `RightDrawerContent` (drawer in normal flow).
/// Renders only the rows, no header or NavigationStack chrome.
struct SettingsFormBody: View {
    var store: ConversationStore? = nil
    var onConversationAction: ((ConversationAction) -> Void)? = nil
    @Environment(AppSettings.self) var settings
    @State private var previewSynth = SpeechSynthesizer()

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        @Bindable var settings = settings
        // MOVE the entire current ScrollView body of SettingsView here, untouched.
        // Everything from the `ScrollView { ... }` block in the current SettingsView's
        // `body`, including all sections, version footer, and any helpers it references
        // (previewSynth, appVersion, buildNumber, store-driven action rows).
        return ... /* paste exact existing ScrollView block here */
    }
}
```

Move the `previewSynth` `@State`, `appVersion`/`buildNumber` computed properties, and the entire `ScrollView { ... }` block from `SettingsView` into `SettingsFormBody`. Any private helper methods or view-builders that the body calls (e.g. row builders) — move them too. Use `Find Occurrences` to make sure nothing is left behind.

- [ ] **Step 3: Slim down SettingsView to delegate to the new body**

`SettingsView` keeps only the header + NavigationStack chrome and embeds `SettingsFormBody`:

```swift
struct SettingsView: View {
    let isInitialSetup: Bool
    var store: ConversationStore? = nil
    var onConversationAction: ((ConversationAction) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !isInitialSetup {
                    header
                }
                SettingsFormBody(store: store, onConversationAction: onConversationAction)
            }
            .background(Theme.background)
            .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.accentMedium)
                    .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            Spacer()
            Text("Настройки")
                .font(.system(size: Theme.fontBody, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.8))
            Spacer()
            Color.clear.frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.vertical, Theme.scaled(10))
    }
}
```

If the existing `SettingsView.swift` wraps its content in additional modifiers (`.background`, `.preferredColorScheme`, etc.), preserve those on the outer `VStack` here.

- [ ] **Step 4: Confirm the app builds and full test target passes**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```
Expected: all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift
git commit -m "ios: extract SettingsFormBody from SettingsView

Pure refactor — splits the rendered rows into a standalone view so
the same content can render inside the right drawer in addition to
the existing initial-setup sheet. No visual or behavioural change."
```

---

### Task 3: Extract ProfileFormBody from ProfileView

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ProfileView.swift`

Same pattern as Task 2. Refactor only.

- [ ] **Step 1: Read ProfileView.swift** to understand structure (~231 lines).

- [ ] **Step 2: Extract a top-level `ProfileFormBody` view**

In `ios/JarvisApp/Sources/JarvisApp/Views/ProfileView.swift`, add above `ProfileView`:

```swift
/// Embeddable profile body — used by both `ProfileView` (legacy sheet, may be
/// dropped after `RightDrawerContent` lands) and `RightDrawerContent` (drawer
/// in normal flow). Renders only the rows, no header chrome.
struct ProfileFormBody: View {
    @Environment(AppSettings.self) var settings
    var store: ConversationStore
    let isConnected: Bool
    var onReconnect: (() -> Void)? = nil

    @State private var showEmojiPicker = false

    private var totalMessages: Int {
        store.conversations.reduce(0) { $0 + $1.messageCount }
    }

    private var memberSince: String {
        guard let oldest = store.conversations.map(\.createdAt).min() else { return "сегодня" }
        let days = Calendar.current.dateComponents([.day], from: oldest, to: Date()).day ?? 0
        if days == 0 { return "сегодня" }
        if days == 1 { return "вчера" }
        return "\(days) дн. назад"
    }

    var body: some View {
        @Bindable var settings = settings
        // MOVE the existing VStack/ScrollView contents from ProfileView's body here,
        // minus the close button + title header.
        return ... /* paste existing rendered body here */
    }
}
```

Move the relevant `@State` vars, computed properties, and the body (excluding the header row that contains the `xmark` button and `Текст("Профиль")`) into `ProfileFormBody`.

- [ ] **Step 3: Slim down ProfileView**

```swift
struct ProfileView: View {
    @Environment(AppSettings.self) var settings
    var store: ConversationStore
    let isConnected: Bool
    var onReconnect: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ProfileFormBody(store: store, isConnected: isConnected, onReconnect: onReconnect)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.accentMedium)
                    .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            Spacer()
            Text("Профиль")
                .font(.system(size: Theme.fontBody, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.8))
            Spacer()
            Color.clear.frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.vertical, Theme.scaled(10))
    }
}
```

- [ ] **Step 4: Build + test**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```
Expected: both succeed.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ProfileView.swift
git commit -m "ios: extract ProfileFormBody from ProfileView

Mirror of the SettingsFormBody extraction — splits the rendered rows
into a reusable view so the right drawer can embed the same content
without duplicating it. No visual change."
```

---

### Task 4: RightDrawerContent view

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift`

- [ ] **Step 1: Regenerate Xcode project** (a new file is being added)

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 2: Implement RightDrawerContent**

Create `ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift`:

```swift
import SwiftUI

/// Single-`ScrollView` right drawer with three sections: Profile, Context,
/// Settings. Mirrors the structure of `DrawerContent` (left drawer) so the
/// language of the app is symmetric: every top-level navigation lives in a
/// side drawer.
struct RightDrawerContent: View {
    @Environment(AppSettings.self) var settings
    var store: ConversationStore
    let isConnected: Bool
    var onReconnect: () -> Void
    var onConversationAction: ((ConversationAction) -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Header with title — symmetry with left drawer's "Диалоги"
                header

                // PROFILE
                sectionHeader("Профиль")
                ProfileFormBody(store: store, isConnected: isConnected, onReconnect: onReconnect)
                    .padding(.bottom, Theme.scaled(12))

                // CONTEXT — placeholder until proactive spec adds the real rows
                sectionHeader("Контекст")
                contextPlaceholder
                    .padding(.bottom, Theme.scaled(12))

                // SETTINGS
                sectionHeader("Настройки")
                SettingsFormBody(store: store, onConversationAction: onConversationAction)
                    .padding(.bottom, Theme.scaled(20))
            }
        }
        .background(Color(red: 0.04, green: 0.08, blue: 0.11))
        .accessibilityIdentifier("right-drawer")
    }

    private var header: some View {
        HStack {
            Text("Профиль и настройки")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.metaFont)
            .tracking(1)
            .foregroundStyle(Theme.accentMedium)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, Theme.scaled(14))
            .padding(.bottom, Theme.scaled(6))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Placeholder Context section — the proactive spec replaces this with live
    /// per-source toggles (location / health / calendar) plus a "force pull"
    /// button. For now the block tells the user what will live here.
    private var contextPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.scaled(6)) {
            Text("Здесь появятся живые сигналы устройства, которые видит Джарвис: геолокация, здоровье, ближайшее событие в календаре.")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.hPadding)
        }
    }
}
```

- [ ] **Step 3: Build and confirm view compiles**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED. No mounting yet — view is unused.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/RightDrawerContent.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add RightDrawerContent — single-scroll Profile/Context/Settings

Right side drawer used by ChatView and OrbHomeView. Single ScrollView
with three section headers in vertical sequence (mirrors the left
drawer's structure for visual symmetry). Profile and Settings embed
the extracted FormBody views directly; the Context section is a
placeholder until the proactive spec wires real per-source toggles."
```

---

### Task 5: ChatView — replace header with HeaderStatusDot, mount right drawer, collision rule

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

This task swaps the header components, adds the right-drawer state + mount + gestures, and enforces the one-drawer-at-a-time invariant. The `showSettings` / `showProfile` `.sheet` paths still exist after this task — Task 6 removes them.

- [ ] **Step 1: Replace the header MiniOrb+dot left button with HeaderStatusDot(.left)**

Find the `header` view (line ~357) and the left-side button (line ~359-372). Replace:

```swift
            Button {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) { drawerOpen = true }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    MiniOrbView(size: 28, mood: orbMood)
                    Circle()
                        .fill(ws.isConnected ? Theme.online : Theme.offline)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 1))
                }
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .accessibilityIdentifier("orb-drawer-btn")
            .accessibilityLabel(ws.isConnected ? "Открыть список диалогов. Подключено" : "Открыть список диалогов. Отключено")
```

with:

```swift
            HeaderStatusDot(side: .left, isConnected: ws.isConnected, phase: orbMood) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    if rightDrawerOpen { rightDrawerOpen = false }
                    drawerOpen = true
                }
            }
            .accessibilityIdentifier("orb-drawer-btn")
            .accessibilityLabel(ws.isConnected ? "Открыть список диалогов. Подключено" : "Открыть список диалогов. Отключено")
```

- [ ] **Step 2: Replace the gearshape right-side button with HeaderStatusDot(.right)**

Still in the `header` view, find the gearshape button (line ~397-403):

```swift
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: Theme.scaled(18)))
                    ...
            }
```

Replace with:

```swift
            HeaderStatusDot(side: .right, isConnected: ws.isConnected, phase: orbMood) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    if drawerOpen { drawerOpen = false }
                    rightDrawerOpen = true
                }
            }
            .accessibilityIdentifier("right-drawer-btn")
            .accessibilityLabel("Открыть профиль и настройки")
```

Preserve any surrounding padding modifiers on the original gearshape's wrapping container.

- [ ] **Step 3: Add right-drawer state + drag-offset alongside existing left ones**

Find the existing left-drawer state (line 33-34):

```swift
    @State private var drawerOpen = false
    @State private var drawerDragOffset: CGFloat = 0
```

Add below them:

```swift
    @State private var rightDrawerOpen = false
    @State private var rightDrawerDragOffset: CGFloat = 0
```

- [ ] **Step 4: Add right-drawer mount**

Find the existing left-drawer mount inside the `ZStack` (line ~262-290). Right after it, before the closing `}` of the ZStack, add:

```swift
        // Right drawer — mirror of the left drawer
        if rightDrawerOpen {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { rightDrawerOpen = false } }
                .transition(.opacity)
        }

        RightDrawerContent(
            store: store,
            isConnected: ws.isConnected,
            onReconnect: {
                coordinator.disconnect()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    coordinator.connect()
                }
            },
            onConversationAction: { action in
                coordinator.handleAction(action)
                inputText = ""
                withAnimation { rightDrawerOpen = false; rightDrawerDragOffset = 0 }
            }
        )
        .frame(width: Theme.drawerWidth)
        .offset(x: {
                let screenWidth = UIScreen.main.bounds.width
                if rightDrawerOpen {
                    // open: rightDrawerDragOffset is positive (drag right to close) or 0
                    return min(screenWidth, screenWidth - Theme.drawerWidth + rightDrawerDragOffset)
                } else {
                    // closed: rightDrawerDragOffset is negative (edge-swipe in progress) or 0
                    return screenWidth - max(0, min(-rightDrawerDragOffset, Theme.drawerWidth))
                }
            }())
        .gesture(rightDrawerDragToClose)
        .shadow(color: .black.opacity(rightDrawerOpen ? 0.4 : 0), radius: 12, x: -4)
        .animation(.spring(duration: Theme.animMedium, bounce: 0.05), value: rightDrawerOpen)
```

The ZStack alignment is `.leading` (line 62); the right drawer floats to its own offset, so the alignment is fine.

- [ ] **Step 5: Add right-edge swipe gesture (mirror of left edgeSwipeGesture)**

Find the existing `edgeSwipeGesture` (line ~460). At the same scope, add right-side versions:

```swift
    private var rightEdgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let screenWidth = UIScreen.main.bounds.width
                if value.startLocation.x > screenWidth - Self.edgeSwipeZone
                    && value.translation.width < 0
                    && abs(value.translation.width) > abs(value.translation.height) * 1.2
                    && !rightDrawerOpen
                    && !drawerOpen {  // collision rule
                    rightDrawerDragOffset = max(value.translation.width, -Theme.drawerWidth)
                }
            }
            .onEnded { value in
                let screenWidth = UIScreen.main.bounds.width
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                if !rightDrawerOpen
                    && !drawerOpen
                    && value.startLocation.x > screenWidth - Self.edgeSwipeZone
                    && value.translation.width < -60
                    && horizontal {
                    withAnimation(.spring(duration: 0.3)) {
                        rightDrawerOpen = true
                        rightDrawerDragOffset = 0
                    }
                } else if !rightDrawerOpen {
                    withAnimation { rightDrawerDragOffset = 0 }
                }
            }
    }

    private var rightDrawerDragToClose: some Gesture {
        DragGesture()
            .onChanged { value in
                if rightDrawerOpen && value.translation.width > 0 {
                    rightDrawerDragOffset = value.translation.width
                }
            }
            .onEnded { value in
                if rightDrawerOpen && value.translation.width > 60 {
                    withAnimation(.spring(duration: 0.3)) {
                        rightDrawerOpen = false
                        rightDrawerDragOffset = 0
                    }
                } else {
                    withAnimation { rightDrawerDragOffset = 0 }
                }
            }
    }
```

- [ ] **Step 6: Add the right-edge swipe to the same parent that hosts the left one**

Find the line `.simultaneousGesture(edgeSwipeGesture)` (line 252). Add immediately after it:

```swift
        .simultaneousGesture(rightEdgeSwipeGesture)
```

- [ ] **Step 7: Enforce collision rule from existing left-drawer gesture**

In `edgeSwipeGesture` (line ~460-484), add a `&& !rightDrawerOpen` guard to the `onChanged` and `onEnded` conditions so left swipe is ignored when right is open. Edit the `onChanged` condition from:

```swift
                if value.startLocation.x < Self.edgeSwipeZone
                    && value.translation.width > 0
                    && abs(value.translation.width) > abs(value.translation.height) * 1.2
                    && !drawerOpen {
```

to:

```swift
                if value.startLocation.x < Self.edgeSwipeZone
                    && value.translation.width > 0
                    && abs(value.translation.width) > abs(value.translation.height) * 1.2
                    && !drawerOpen
                    && !rightDrawerOpen {
```

Apply the same `&& !rightDrawerOpen` to the `onEnded` condition.

- [ ] **Step 8: Regenerate, build, run full test target**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED + all JarvisAppTests pass. UI behaviour: top-left dot opens left drawer; top-right dot opens right drawer; the legacy gearshape `.sheet(isPresented: $showSettings)` and the long-press orb `.sheet(isPresented: $showProfile)` paths are no longer reachable from the header (but the state vars still exist — Task 6 cleans them up).

- [ ] **Step 9: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "ios(chat): swap header for HeaderStatusDot pair, mount right drawer

Top-left now opens the existing left conversations drawer; top-right
opens the new right drawer (profile + settings). Edge-swipe gestures
on both sides, with a one-open-at-a-time invariant. Sheet handlers
still exist temporarily for safety; Task 6 removes them."
```

---

### Task 6: ChatView — remove .sheet paths + state, drop MiniOrb header import dead code

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Remove `showSettings` and `showProfile` state vars**

In ChatView's body / state declarations (line ~25-26), delete:

```swift
    @State private var showSettings    = false
    @State private var showProfile     = false
```

- [ ] **Step 2: Remove the two `.sheet(isPresented:)` modifiers**

Find and delete lines ~308-329 (the entire `.sheet(isPresented: $showSettings) { ... }` and `.sheet(isPresented: $showProfile) { ... }` blocks).

- [ ] **Step 3: Remove the drawer footer `onSettings` / `onProfile` callbacks**

Find the `DrawerContent(...)` call (line ~262). Remove the `onSettings:` and `onProfile:` arguments — the conversations drawer no longer has those buttons after Task 10. For now, pass `{}` empty closures if those arguments are still required by `DrawerContent`'s API (they will be removed in Task 10):

```swift
        DrawerContent(
            store: store,
            onAction: { action in
                coordinator.handleAction(action)
                withAnimation { drawerOpen = false; drawerDragOffset = 0 }
            },
            onSettings: {},
            onProfile: {}
        )
```

- [ ] **Step 4: Build + run full test target**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```
Expected: clean build + tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "ios(chat): drop showSettings/showProfile sheets — right drawer covers both

Settings and profile now live in the right drawer (Task 5). The legacy
.sheet handlers and their @State backing are gone. DrawerContent's
onSettings/onProfile callbacks become no-ops until Task 10 removes
them from the conversations drawer footer entirely."
```

---

### Task 7: OrbHomeView — replace header dots, mount right drawer

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`

- [ ] **Step 1: Read OrbHomeView's header method** (line ~145-195) to find the existing status circle button (line ~148-160) and the gearshape (line ~178-185).

- [ ] **Step 2: Add right-drawer + left-drawer state on OrbHomeView**

Near the top of `OrbHomeView` (alongside `showProfile`), add:

```swift
    @State private var leftDrawerOpen = false
    @State private var leftDrawerDragOffset: CGFloat = 0
    @State private var rightDrawerOpen = false
    @State private var rightDrawerDragOffset: CGFloat = 0
```

Note: home view never had a conversations drawer before; this task introduces it so home and chat share the same model. `showProfile` stays for now and is removed in Task 8.

- [ ] **Step 3: Replace the header's left status-circle button**

Find the button at OrbHomeView.swift:148-160 (the bare status circle inside an opacity-styled stroke). Replace with:

```swift
            HeaderStatusDot(side: .left,
                            isConnected: coordinator.ws.isConnected,
                            phase: .calm) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    if rightDrawerOpen { rightDrawerOpen = false }
                    leftDrawerOpen = true
                }
            }
            .accessibilityLabel(coordinator.ws.isConnected ? "Открыть список диалогов. Подключено" : "Открыть список диалогов. Отключено")
```

- [ ] **Step 4: Replace the header's right gearshape**

Find the button at OrbHomeView.swift:178-185. Replace with:

```swift
            HeaderStatusDot(side: .right,
                            isConnected: coordinator.ws.isConnected,
                            phase: .calm) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    if leftDrawerOpen { leftDrawerOpen = false }
                    rightDrawerOpen = true
                }
            }
            .accessibilityLabel("Открыть профиль и настройки")
```

- [ ] **Step 5: Wrap the existing body in a `ZStack(alignment: .leading)` and mount both drawers**

Currently `OrbHomeView`'s `body` is a `VStack(spacing: 0)` (line 79). Wrap the entire VStack and its trailing modifiers in a `ZStack(alignment: .leading)`:

```swift
    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                header
                ...existing content...
            }
            // existing modifiers (.background, .preferredColorScheme, etc.) stay on the VStack

            // Shroud overlay when either drawer open
            if leftDrawerOpen || rightDrawerOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { leftDrawerOpen = false; rightDrawerOpen = false }
                    }
                    .transition(.opacity)
            }

            // Left drawer
            DrawerContent(
                store: coordinator.store,
                onAction: { action in
                    coordinator.handleAction(action)
                    withAnimation { leftDrawerOpen = false; leftDrawerDragOffset = 0 }
                },
                onSettings: {},
                onProfile: {}
            )
            .frame(width: Theme.drawerWidth)
            .offset(x: {
                    if leftDrawerOpen {
                        return max(-Theme.drawerWidth, leftDrawerDragOffset)
                    } else {
                        return -Theme.drawerWidth + max(0, min(leftDrawerDragOffset, Theme.drawerWidth))
                    }
                }())
            .gesture(leftDrawerDragToClose)
            .shadow(color: .black.opacity(leftDrawerOpen ? 0.4 : 0), radius: 12, x: 4)
            .animation(.spring(duration: Theme.animMedium, bounce: 0.05), value: leftDrawerOpen)

            // Right drawer (mirror)
            RightDrawerContent(
                store: coordinator.store,
                isConnected: coordinator.ws.isConnected,
                onReconnect: {
                    coordinator.disconnect()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        coordinator.connect()
                    }
                },
                onConversationAction: { action in
                    coordinator.handleAction(action)
                    withAnimation { rightDrawerOpen = false; rightDrawerDragOffset = 0 }
                }
            )
            .frame(width: Theme.drawerWidth)
            .offset(x: {
                    let screenWidth = UIScreen.main.bounds.width
                    if rightDrawerOpen {
                        return min(screenWidth, screenWidth - Theme.drawerWidth + rightDrawerDragOffset)
                    } else {
                        return screenWidth - max(0, min(-rightDrawerDragOffset, Theme.drawerWidth))
                    }
                }())
            .gesture(rightDrawerDragToClose)
            .shadow(color: .black.opacity(rightDrawerOpen ? 0.4 : 0), radius: 12, x: -4)
            .animation(.spring(duration: Theme.animMedium, bounce: 0.05), value: rightDrawerOpen)
        }
        .simultaneousGesture(leftEdgeSwipeGesture)
        .simultaneousGesture(rightEdgeSwipeGesture)
    }
```

- [ ] **Step 6: Add the four gesture helpers**

At the same scope level as other `private var` helpers in `OrbHomeView`, add:

```swift
    private static let edgeSwipeZone: CGFloat = 40

    private var leftEdgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if value.startLocation.x < Self.edgeSwipeZone
                    && value.translation.width > 0
                    && abs(value.translation.width) > abs(value.translation.height) * 1.2
                    && !leftDrawerOpen
                    && !rightDrawerOpen {
                    leftDrawerDragOffset = min(value.translation.width, Theme.drawerWidth)
                }
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                if !leftDrawerOpen
                    && !rightDrawerOpen
                    && value.startLocation.x < Self.edgeSwipeZone
                    && value.translation.width > 60
                    && horizontal {
                    withAnimation(.spring(duration: 0.3)) {
                        leftDrawerOpen = true
                        leftDrawerDragOffset = 0
                    }
                } else if !leftDrawerOpen {
                    withAnimation { leftDrawerDragOffset = 0 }
                }
            }
    }

    private var leftDrawerDragToClose: some Gesture {
        DragGesture()
            .onChanged { value in
                if leftDrawerOpen && value.translation.width < 0 {
                    leftDrawerDragOffset = value.translation.width
                }
            }
            .onEnded { value in
                if leftDrawerOpen && value.translation.width < -60 {
                    withAnimation(.spring(duration: 0.3)) {
                        leftDrawerOpen = false
                        leftDrawerDragOffset = 0
                    }
                } else {
                    withAnimation { leftDrawerDragOffset = 0 }
                }
            }
    }

    private var rightEdgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let screenWidth = UIScreen.main.bounds.width
                if value.startLocation.x > screenWidth - Self.edgeSwipeZone
                    && value.translation.width < 0
                    && abs(value.translation.width) > abs(value.translation.height) * 1.2
                    && !rightDrawerOpen
                    && !leftDrawerOpen {
                    rightDrawerDragOffset = max(value.translation.width, -Theme.drawerWidth)
                }
            }
            .onEnded { value in
                let screenWidth = UIScreen.main.bounds.width
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                if !rightDrawerOpen
                    && !leftDrawerOpen
                    && value.startLocation.x > screenWidth - Self.edgeSwipeZone
                    && value.translation.width < -60
                    && horizontal {
                    withAnimation(.spring(duration: 0.3)) {
                        rightDrawerOpen = true
                        rightDrawerDragOffset = 0
                    }
                } else if !rightDrawerOpen {
                    withAnimation { rightDrawerDragOffset = 0 }
                }
            }
    }

    private var rightDrawerDragToClose: some Gesture {
        DragGesture()
            .onChanged { value in
                if rightDrawerOpen && value.translation.width > 0 {
                    rightDrawerDragOffset = value.translation.width
                }
            }
            .onEnded { value in
                if rightDrawerOpen && value.translation.width > 60 {
                    withAnimation(.spring(duration: 0.3)) {
                        rightDrawerOpen = false
                        rightDrawerDragOffset = 0
                    }
                } else {
                    withAnimation { rightDrawerDragOffset = 0 }
                }
            }
    }
```

- [ ] **Step 7: Build**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

Run UI tests to make sure existing flows still work:

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```
Expected: all unit tests still pass. (Pre-existing UI tests may need updates if they relied on the gearshape; if so, this is acceptable mid-refactor — Task 11 reviews UI tests at the end.)

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "ios(home): mirror ChatView navigation — dots + both drawers

OrbHomeView now mounts the same left + right drawer pair as ChatView,
gated by mirrored HeaderStatusDot taps and edge swipes. showProfile
sheet is still wired to satisfy the existing onShowSettings flow into
ContentView; Task 8 removes it once ContentView's sheet path is gone."
```

---

### Task 8: OrbHomeView + ContentView — remove legacy profile sheet and onShowSettings

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ContentView.swift`

- [ ] **Step 1: Remove `showProfile` state from OrbHomeView**

In `OrbHomeView` (line 15), delete:

```swift
    @State private var showProfile = false
```

Find and remove the entire `.sheet(isPresented: $showProfile) { ... }` modifier (line ~122-133).

- [ ] **Step 2: Remove the `onShowSettings` callback property and its only call site**

In `OrbHomeView`, delete:

```swift
    var onShowSettings: () -> Void
```

Find any tap handler that calls `onShowSettings()` (there should be none after Task 7's gearshape removal; check for stragglers via grep).

- [ ] **Step 3: Update OrbHomeView's call site in ContentView**

In `ios/JarvisApp/Sources/JarvisApp/Views/ContentView.swift` line ~26-49, remove `onShowSettings: { showSettings = true }` from the OrbHomeView arguments. After the change, the call looks like:

```swift
                OrbHomeView(
                    coordinator: coordinator,
                    onStartChat: { message in ... },
                    onStartVoiceChat: { ... },
                    onContinueChat: { ... }
                )
```

- [ ] **Step 4: Remove `showSettings` state + `.sheet` from ContentView**

Delete line 9:
```swift
    @State private var showSettings = false
```

Delete the entire `.sheet(isPresented: $showSettings) { ... }` block (line ~70-81).

- [ ] **Step 5: Build + full test target**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```
Expected: both succeed. The settings/profile path now goes exclusively through the right drawer everywhere.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/ContentView.swift
git commit -m "ios: drop legacy showSettings/showProfile sheets app-wide

ContentView no longer hosts the settings sheet, and OrbHomeView no
longer carries onShowSettings or showProfile. Settings and profile
are reachable exclusively via the right drawer in both ChatView and
OrbHomeView. First-run setup remains on SplashView.setupCard."
```

---

### Task 9: ConversationListView (DrawerContent) — remove Profile / Settings footer

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift`

- [ ] **Step 1: Remove the bottom Profile / Settings footer from `DrawerContent`**

In `ConversationListView.swift`, find the `Divider().background(Theme.hairlineColor)` near the bottom of `DrawerContent.body` followed by the `HStack(spacing: 0)` that contains the Profile and Settings buttons (lines ~420-444). Delete the entire footer block, from `Divider().background(...)` through the closing `}` of that `HStack`.

- [ ] **Step 2: Remove the `onSettings` and `onProfile` callback properties**

At the top of `DrawerContent`, delete:

```swift
    var onSettings: () -> Void = {}
    var onProfile: () -> Void = {}
```

- [ ] **Step 3: Remove the now-unused arguments at call sites**

`ChatView.swift` and `OrbHomeView.swift` both pass `onSettings: {}, onProfile: {}` after Tasks 6 and 7. Find each `DrawerContent(...)` call and remove those two argument lines.

- [ ] **Step 4: Build + test**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```
Expected: clean build + tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ConversationListView.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "ios(drawer): remove Profile/Settings footer from left drawer

The left drawer is now purely the conversation list — profile and
settings live exclusively in the right drawer. DrawerContent's
onSettings/onProfile callbacks are gone from both the API and every
call site."
```

---

### Task 10: UI tests — right drawer open mechanics + collision rule

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisUITests/RightDrawerTests.swift`

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 2: Write UI tests**

Create `ios/JarvisApp/Sources/JarvisUITests/RightDrawerTests.swift`:

```swift
import XCTest

final class RightDrawerTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "YES"]
        app.launch()
        return app
    }

    func testRightDrawerOpensViaDotTap() {
        let app = launchApp()
        let rightDot = app.buttons["right-drawer-btn"]
        XCTAssertTrue(rightDot.waitForExistence(timeout: 5))
        rightDot.tap()
        XCTAssertTrue(app.otherElements["right-drawer"].waitForExistence(timeout: 2))
    }

    func testRightDrawerClosesByTappingShroud() {
        let app = launchApp()
        let rightDot = app.buttons["right-drawer-btn"]
        XCTAssertTrue(rightDot.waitForExistence(timeout: 5))
        rightDot.tap()
        let drawer = app.otherElements["right-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 2))

        // Tap the left edge of the screen (outside the drawer's frame)
        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        coordinate.tap()

        XCTAssertFalse(drawer.waitForExistence(timeout: 1.5))
    }

    func testLeftAndRightDoNotOpenTogether() {
        let app = launchApp()
        let leftDot = app.buttons["orb-drawer-btn"]
        XCTAssertTrue(leftDot.waitForExistence(timeout: 5))
        leftDot.tap()

        let leftDrawer = app.otherElements["conv-drawer"]
        XCTAssertTrue(leftDrawer.waitForExistence(timeout: 2))

        // Tap the right dot — should switch (close left, open right)
        let rightDot = app.buttons["right-drawer-btn"]
        rightDot.tap()

        XCTAssertTrue(app.otherElements["right-drawer"].waitForExistence(timeout: 2))
        XCTAssertFalse(leftDrawer.exists, "left drawer must close when right opens")
    }
}
```

- [ ] **Step 3: Run UI tests**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisUITests/RightDrawerTests 2>&1 | tail -20
```
Expected: 3 tests PASS.

If a test flakes on simulator timing (UI tests are slower than unit tests), increase the `waitForExistence` timeout to 5s and rerun. Do not change the assertion semantics.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisUITests/RightDrawerTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "test(ios-ui): right drawer mechanics + drawer collision

Three UI tests pin the new navigation: right dot tap opens the drawer,
tapping outside closes it, opening one drawer when the other is open
switches between them (never both open at once)."
```

---

### Task 11: Final smoke pass

**Files:** none modified — verification only.

- [ ] **Step 1: Full app build for the simulator**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED, zero warnings introduced by this plan.

- [ ] **Step 2: Run the full unit test target**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```
Expected: all unit tests pass (43 from reliability plan + 7 new from HeaderStatusDot).

- [ ] **Step 3: Run the full UI test target**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisUITests 2>&1 | tail -20
```
Expected: pre-existing UI tests pass plus the 3 new ones. If any pre-existing UI test breaks because it tapped the legacy gearshape, **fix the test** to tap the new `right-drawer-btn` instead. Update those tests in-place rather than reintroducing the gearshape.

- [ ] **Step 4: Grep sweep for dead references**

Run from repo root to confirm no stragglers remain:

```bash
grep -rn "showSettings\|showProfile\|onShowSettings" ios/JarvisApp/Sources/ | grep -v "//\|SplashView" || echo "Clean"
```

Expected: `Clean`. If any matches surface, examine — `SplashView`'s first-run setup card is allowed to keep its own state, but `ChatView`, `OrbHomeView`, `ContentView`, and `DrawerContent` must be free of these.

- [ ] **Step 5: Commit any UI-test fixups**

If Step 3 required UI test updates:

```bash
git add ios/JarvisApp/Sources/JarvisUITests/
git commit -m "test(ios-ui): retarget legacy gearshape taps onto right-drawer-btn

Existing UI tests that opened settings by tapping the gearshape now
tap the right-drawer status dot instead. Same end state — drawer
opens with the settings section — but via the new navigation."
```

If Step 3 had no failures, skip this commit.

---

## Self-Review

**Spec coverage** (against the navigation portion of `2026-05-28-ios-ui-unified-navigation-design.md`):

| Spec requirement | Task |
|---|---|
| `HeaderStatusDot` component | Task 1 |
| Replace ChatView TL MiniOrb+dot | Task 5 |
| Replace ChatView TR gearshape | Task 5 |
| Replace OrbHomeView TL status circle | Task 7 |
| Replace OrbHomeView TR gearshape | Task 7 |
| One orb per screen (remove header MiniOrb) | Task 5 |
| `RightDrawerContent` single-scroll view | Task 4 |
| `SettingsFormBody` extraction | Task 2 |
| `ProfileFormBody` extraction | Task 3 |
| Right-drawer mounting + edge swipe in ChatView | Task 5 |
| Right-drawer mounting + edge swipe in OrbHomeView | Task 7 |
| Drawer collision rule | Tasks 5 + 7 (gesture guards) |
| Remove `.sheet` modifiers from ChatView | Task 6 |
| Remove `.sheet` modifier + state from ContentView | Task 8 |
| Remove `.sheet` modifier from OrbHomeView | Task 8 |
| Remove `Профиль/Настройки` footer from left drawer | Task 9 |
| First-run flow unchanged (`SplashView.setupCard`) | preserved — none of the tasks touches SplashView |
| UI tests for drawer mechanics | Task 10 |

**Out of scope of this plan** (covered by separate plans B / C / D from the same spec):

- `OrbVoiceView` voice-fullscreen mode → Plan B
- Conversation-as-satellite on home cluster → Plan C
- `AppSettings` voice/watch keys → Plan B and Plan D
- `JarvisCore` SPM target + `JarvisWatch` target + `WCSession` bridge → Plan D
- Live-context chip in right drawer (Context section is a placeholder here)

**Placeholder scan:** every step shows the actual change. No `TODO` / `fill in details` / generic `add error handling` markers.

**Type consistency:** `rightDrawerOpen` / `leftDrawerOpen` / `rightDrawerDragOffset` / `leftDrawerDragOffset` names are consistent across ChatView and OrbHomeView (Tasks 5 and 7). `HeaderStatusDot` constructor signature `(side:isConnected:phase:action:)` is identical at all three call sites. `RightDrawerContent` arguments `(store:isConnected:onReconnect:onConversationAction:)` are identical at both call sites.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-28-ios-navigation-cleanup.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
