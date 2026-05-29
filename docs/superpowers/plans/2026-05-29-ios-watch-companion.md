# iOS Watch Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a minimal watchOS companion app to the iOS Jarvis project. The watch shows the most recent assistant messages and lets the user dictate replies via the watch microphone. All network traffic goes through the paired iPhone via `WCSession` — the watch never owns the WebSocket connection.

**Architecture:** New `JarvisWatch` watchOS app target in `project.yml`. A `WCSession` bridge connects the two apps: iPhone forwards each new assistant message via `transferUserInfo`; the watch decodes the dict, appends to its in-memory list, and renders. The watch's mic button records via `SFSpeechRecognizer` (ru-RU, same as iOS), and sends the dictated text back via `WCSession.sendMessage`; the iPhone receives it and calls the existing `WebSocketClient.send` path. AppSettings gains `watchCompanionEnabled` (default true) — when off, iPhone simply stops emitting `transferUserInfo` calls. The right drawer's settings section gets one new toggle.

**SPM extraction (Plan D2) is deferred:** the spec called for extracting a `JarvisCore` SPM library so the watch could share `WebSocketClient` etc. For a text-only v1 watch app, the only thing the watch needs from iOS is the userInfo dict shape — passing `[String: Any]` directly avoids the entire refactor. If the watch app grows (attachments, drawer, standalone WS), revisit the SPM extraction at that point.

**Tech Stack:** Swift / SwiftUI / WatchConnectivity / Speech / XCTest. Apple Watch Series 11 simulator (watchOS 26.5).

---

## File Structure

| File | Purpose |
|---|---|
| `ios/JarvisApp/project.yml` (MODIFY) | Add `JarvisWatch` watchOS app target. Min watchOS 10. Bundle id `com.vasechko.jarvis.watch`. |
| `ios/JarvisApp/Sources/JarvisWatch/JarvisWatchApp.swift` (NEW) | `@main` watch app entry point. Wires the `WatchAppState` observable into the SwiftUI scene. |
| `ios/JarvisApp/Sources/JarvisWatch/WatchAppState.swift` (NEW) | `@Observable @MainActor` holds the messages list, the WCSession delegate, and the dictation state. |
| `ios/JarvisApp/Sources/JarvisWatch/WatchContentView.swift` (NEW) | Single-view UI: small orb + scrollable last messages + push-to-talk mic button. |
| `ios/JarvisApp/Sources/JarvisWatch/WatchTheme.swift` (NEW) | Minimal `Theme` clone with watch-friendly scale (no `UIScreen`). Same colours / accent as iOS. |
| `ios/JarvisApp/Sources/JarvisWatch/WatchSpeechManager.swift` (NEW) | Thin `SFSpeechRecognizer` wrapper that exposes a transcript callback and start/stop. |
| `ios/JarvisApp/Sources/JarvisApp/Services/WatchConnectivityBridge.swift` (NEW, iOS) | iOS-side `WCSessionDelegate`. Sends `transferUserInfo` on each new assistant message. Handles incoming `sendMessage(_:)` from watch and re-enters `coordinator.sendMessage`. |
| `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift` (MODIFY) | Instantiate `WatchConnectivityBridge`; observe `ws.messages` for new assistant arrivals; forward via the bridge when `settings.watchCompanionEnabled`. |
| `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift` (MODIFY) | Add `watchCompanionEnabled` (Bool, default true) `@AppStorage`. |
| `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift` (MODIFY) | Append a single toggle row in the new "Apple Watch" section of `SettingsFormBody`. |
| `ios/JarvisApp/Sources/JarvisAppTests/WatchConnectivityBridgeTests.swift` (NEW) | Unit tests for payload shape + gating behavior. |

## Test Commands

- **iOS unit tests:** `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/<ClassName>`
- **Watch build (no unit tests in v1):** `xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'`
- **Regen Xcode project after `project.yml` change:** `cd ios/JarvisApp && xcodegen generate`.

---

### Task 1: project.yml — add JarvisWatch target

**Files:**
- Modify: `ios/JarvisApp/project.yml`

- [ ] **Step 1: Add the new target**

Open `ios/JarvisApp/project.yml`. Under the existing `targets:` map (alongside `JarvisApp`, `JarvisAppTests`, `JarvisUITests`), append:

```yaml
  JarvisWatch:
    type: application
    platform: watchOS
    deploymentTarget: "10.0"
    sources:
      - path: Sources/JarvisWatch
    info:
      path: Sources/JarvisWatch/Info.plist
      properties:
        WKApplication: true
        WKWatchKitApp: false
        NSMicrophoneUsageDescription: "Микрофон для голосового ввода Jarvis"
        NSSpeechRecognitionUsageDescription: "Распознавание речи для голосового ввода Jarvis"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vasechko.jarvis.watch
        PRODUCT_NAME: JarvisWatch
        INFOPLIST_KEY_CFBundleDisplayName: Jarvis
        SUPPORTS_MACCATALYST: NO
        TARGETED_DEVICE_FAMILY: "4"
        SWIFT_VERSION: "5.9"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: 24Z6S27D7U
        GENERATE_INFOPLIST_FILE: NO
```

- [ ] **Step 2: Create the watch sources directory + minimal stubs**

Create directory `ios/JarvisApp/Sources/JarvisWatch/`. Inside, create a minimal `Info.plist` placeholder so xcodegen's `info.path` resolves:

```bash
mkdir -p ios/JarvisApp/Sources/JarvisWatch
```

Create `ios/JarvisApp/Sources/JarvisWatch/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>WKApplication</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Микрофон для голосового ввода Jarvis</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Распознавание речи для голосового ввода Jarvis</string>
</dict>
</plist>
```

Create a minimal placeholder `ios/JarvisApp/Sources/JarvisWatch/JarvisWatchApp.swift` (gets replaced in Task 2 — needed now so xcodegen has a Swift file to compile):

```swift
import SwiftUI

@main
struct JarvisWatchApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Jarvis")
        }
    }
}
```

- [ ] **Step 3: Regenerate project + verify watch target builds**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED. If `xcodegen` fails because `info.path` doesn't accept inline `properties` for watch apps, fall back to using only `info.path` and rely on the Info.plist file (it has the same keys). If `GENERATE_INFOPLIST_FILE: NO` interacts poorly with `WKApplication`, flip it to `YES` and remove the `Info.plist` file.

Also confirm the iOS app target still builds:

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/project.yml \
        ios/JarvisApp/Sources/JarvisWatch/ \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add JarvisWatch watchOS target scaffold

project.yml gains a JarvisWatch app target (watchOS 10, bundle id
com.vasechko.jarvis.watch). Minimal SwiftUI 'Hello' placeholder so
xcodegen has something to compile. Tasks 2+ replace the placeholder
with the real content."
```

---

### Task 2: WatchTheme + WatchAppState + WatchContentView skeleton

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisWatch/WatchTheme.swift`
- Create: `ios/JarvisApp/Sources/JarvisWatch/WatchAppState.swift`
- Create: `ios/JarvisApp/Sources/JarvisWatch/WatchContentView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisWatch/JarvisWatchApp.swift`

- [ ] **Step 1: WatchTheme**

Create `ios/JarvisApp/Sources/JarvisWatch/WatchTheme.swift`:

```swift
import SwiftUI

/// Minimal theme constants for the watchOS app. Mirrors the colour palette
/// from the iOS Theme but uses fixed font sizes — no UIScreen-based scaling
/// (watch screens are too small + UIScreen behaves differently here).
enum WatchTheme {
    static let background = Color(red: 0.04, green: 0.055, blue: 0.08)
    static let surface    = Color(red: 0.067, green: 0.098, blue: 0.133)
    static let accent     = Color(red: 0.33, green: 0.74, blue: 0.77)
    static let accentMed  = Color(red: 0.258, green: 0.569, blue: 0.598)
    static let online     = Color(red: 0.29, green: 0.87, blue: 0.50)
    static let offline    = Color(red: 0.95, green: 0.26, blue: 0.21)
    static let textPrimary = Color.white
    static let textTertiary = Color(red: 0.568, green: 0.575, blue: 0.586)

    static let messageFont = Font.system(size: 13, design: .default)
    static let metaFont    = Font.system(size: 10, design: .monospaced)
}
```

- [ ] **Step 2: WatchAppState**

Create `ios/JarvisApp/Sources/JarvisWatch/WatchAppState.swift`:

```swift
import Foundation

/// In-memory model for the watch app. The iOS companion pushes new
/// assistant messages via WCSession.transferUserInfo. The watch keeps the
/// last `maxMessages` rendered.
@Observable @MainActor final class WatchAppState {

    struct ReceivedMessage: Identifiable, Equatable {
        let id: String
        let text: String
        let timestamp: Date
    }

    var messages: [ReceivedMessage] = []
    var isConnectedToPhone: Bool = false
    var isRecording: Bool = false

    /// Latest dictated transcript shown under the mic button while listening.
    var partialTranscript: String = ""

    static let maxMessages = 50

    func append(id: String, text: String, timestamp: Date) {
        messages.append(.init(id: id, text: text, timestamp: timestamp))
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }
}
```

- [ ] **Step 3: WatchContentView**

Create `ios/JarvisApp/Sources/JarvisWatch/WatchContentView.swift`:

```swift
import SwiftUI

struct WatchContentView: View {
    @Environment(WatchAppState.self) var state
    /// Injected from WatchAppDelegate (Task 3) — drives the mic recording lifecycle.
    var onPushToTalkStart: () -> Void = {}
    var onPushToTalkEnd: () -> Void = {}

    var body: some View {
        ZStack {
            WatchTheme.background.ignoresSafeArea()

            VStack(spacing: 4) {
                // Connection dot
                HStack(spacing: 4) {
                    Circle()
                        .fill(state.isConnectedToPhone ? WatchTheme.online : WatchTheme.offline)
                        .frame(width: 6, height: 6)
                    Text(state.isConnectedToPhone ? "iPhone" : "off")
                        .font(WatchTheme.metaFont)
                        .foregroundStyle(WatchTheme.accentMed)
                    Spacer()
                }
                .padding(.horizontal, 6)

                // Messages — newest at bottom
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(state.messages) { m in
                                Text(m.text)
                                    .font(WatchTheme.messageFont)
                                    .foregroundStyle(WatchTheme.textPrimary.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(m.id)
                            }
                            if state.isRecording && !state.partialTranscript.isEmpty {
                                Text(state.partialTranscript)
                                    .font(WatchTheme.messageFont)
                                    .foregroundStyle(WatchTheme.accent.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: state.messages.last?.id) {
                        if let last = state.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                // Push-to-talk button
                pttButton
                    .padding(.bottom, 4)
            }
        }
    }

    private var pttButton: some View {
        Image(systemName: state.isRecording ? "mic.fill" : "mic")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(WatchTheme.accent)
            .padding(10)
            .background(
                Circle()
                    .fill(state.isRecording ? WatchTheme.accent.opacity(0.18) : WatchTheme.surface)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !state.isRecording { onPushToTalkStart() }
                    }
                    .onEnded { _ in
                        if state.isRecording { onPushToTalkEnd() }
                    }
            )
            .accessibilityLabel("Удерживайте для голоса")
    }
}
```

- [ ] **Step 4: Update JarvisWatchApp.swift**

Replace `ios/JarvisApp/Sources/JarvisWatch/JarvisWatchApp.swift`:

```swift
import SwiftUI

@main
struct JarvisWatchApp: App {
    @State private var state = WatchAppState()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(state)
        }
    }
}
```

- [ ] **Step 5: Build the watch target**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisWatch/ \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios(watch): theme + state + content view skeleton

WatchTheme minimal palette. WatchAppState @Observable holds messages
+ recording state. WatchContentView renders connection dot, scroll of
last messages, and a hold-to-record mic button. No WCSession wiring
yet — Task 3 connects the watch to the iPhone."
```

---

### Task 3: WCSession bridge — iOS side

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/WatchConnectivityBridge.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/WatchConnectivityBridgeTests.swift`

- [ ] **Step 1: Write failing tests for the payload shape and gating**

Create `ios/JarvisApp/Sources/JarvisAppTests/WatchConnectivityBridgeTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class WatchConnectivityBridgeTests: XCTestCase {

    func testBuildPayloadShape() {
        let payload = WatchConnectivityBridge.buildAssistantPayload(
            id: "abc",
            text: "Привет",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        XCTAssertEqual(payload["type"] as? String, "message")
        XCTAssertEqual(payload["id"] as? String, "abc")
        XCTAssertEqual(payload["text"] as? String, "Привет")
        XCTAssertNotNil(payload["ts"] as? String)
    }

    func testParseSendTextFromWatch() {
        let dict: [String: Any] = ["type": "send_text", "text": "diktovka"]
        let parsed = WatchConnectivityBridge.parseSendText(dict)
        XCTAssertEqual(parsed, "diktovka")
    }

    func testParseSendTextReturnsNilWhenTypeMismatch() {
        let dict: [String: Any] = ["type": "other", "text": "x"]
        XCTAssertNil(WatchConnectivityBridge.parseSendText(dict))
    }

    func testParseSendTextReturnsNilWhenTextMissing() {
        let dict: [String: Any] = ["type": "send_text"]
        XCTAssertNil(WatchConnectivityBridge.parseSendText(dict))
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/WatchConnectivityBridgeTests 2>&1 | tail -15
```

Expected: build error — `WatchConnectivityBridge` undefined.

- [ ] **Step 3: Implement WatchConnectivityBridge**

Create `ios/JarvisApp/Sources/JarvisApp/Services/WatchConnectivityBridge.swift`:

```swift
import Foundation
import WatchConnectivity

/// iOS-side WCSession bridge. The iPhone forwards new assistant messages to
/// the watch via `transferUserInfo`, and receives dictated text from the watch
/// via `didReceiveMessage`. The bridge itself is stateless — payload-building
/// and parsing are static so they unit-test without a live WCSession.
@MainActor final class WatchConnectivityBridge: NSObject, WCSessionDelegate {

    /// Called when the watch sends dictated text. AppCoordinator routes it to
    /// `coordinator.sendMessage(text, viaVoice: true)`.
    var onWatchDictation: ((String) -> Void)?

    private let session: WCSession?

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        if let s = session {
            s.delegate = self
            s.activate()
        }
    }

    /// Push a fresh assistant message to the paired watch. Best-effort —
    /// returns false when the session isn't reachable.
    @discardableResult
    func pushAssistantMessage(id: String, text: String, timestamp: Date) -> Bool {
        guard let s = session, s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else {
            return false
        }
        let payload = Self.buildAssistantPayload(id: id, text: text, timestamp: timestamp)
        s.transferUserInfo(payload)
        return true
    }

    // MARK: – Payload helpers (testable)

    static func buildAssistantPayload(id: String, text: String, timestamp: Date) -> [String: Any] {
        return [
            "type": "message",
            "id": id,
            "text": text,
            "ts": ISO8601DateFormatter().string(from: timestamp),
        ]
    }

    static func parseSendText(_ dict: [String: Any]) -> String? {
        guard let type = dict["type"] as? String, type == "send_text" else { return nil }
        guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: – WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error { print("[WC] activation error: \(error)") }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // iOS recommends re-activating after deactivation when the user pairs
        // a different watch.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let text = Self.parseSendText(message) else { return }
        Task { @MainActor [weak self] in
            self?.onWatchDictation?(text)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        if let text = Self.parseSendText(message) {
            Task { @MainActor [weak self] in
                self?.onWatchDictation?(text)
            }
        }
        replyHandler(["ok": true])
    }
}
```

- [ ] **Step 4: Wire in AppCoordinator**

In `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift`:

a. Add a property near other services:

```swift
    private(set) var watchBridge: WatchConnectivityBridge!
```

b. In `init`, after the existing service wiring, add:

```swift
        self.watchBridge = WatchConnectivityBridge()
        watchBridge.onWatchDictation = { [weak self] text in
            Task { @MainActor in
                self?.sendMessage(text, viaVoice: true)
            }
        }
```

c. Find the existing observation of `ws.messages` (or the haptic-on-receive hook in `wireUp()` — search for `onMessageReceived` / `onAssistantMessage`). Add a hook that pushes new assistant messages to the watch when `settings.watchCompanionEnabled` is true:

If the existing `wireUp` already routes assistant messages, add inside that path:

```swift
        ws.onAssistantMessage = { [weak self] in
            self?.onMessageReceived?()
            guard let self else { return }
            // Push to watch if companion is enabled and we have a fresh assistant message
            if self.settings.watchCompanionEnabled,
               let last = self.ws.messages.last,
               last.role == .assistant,
               !last.text.isEmpty {
                self.watchBridge.pushAssistantMessage(id: last.id, text: last.text, timestamp: last.timestamp)
            }
        }
```

If `onAssistantMessage` is already attached, modify the existing closure to add the push call rather than replacing it. The intent is additive — keep haptics intact.

(`settings.watchCompanionEnabled` is added in Task 5; for now use a hardcoded `true` and replace with the real read in Task 5. Or, if `AppSettings` already gained the key, use it directly.)

- [ ] **Step 5: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED + tests pass (existing + 4 new WatchConnectivityBridge tests).

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WatchConnectivityBridge.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WatchConnectivityBridgeTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: WatchConnectivityBridge — push assistant text to watch, receive dictation

@MainActor wrapper over WCSession. Payload builders + parsers are
static so they unit-test without a live session (4 tests). AppCoordinator
instantiates it, forwards assistant messages via transferUserInfo when
the companion toggle is on, and routes dictated text back into
sendMessage(viaVoice: true)."
```

---

### Task 4: WatchSpeechManager — dictation on watch

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisWatch/WatchSpeechManager.swift`
- Modify: `ios/JarvisApp/Sources/JarvisWatch/WatchAppState.swift`
- Modify: `ios/JarvisApp/Sources/JarvisWatch/JarvisWatchApp.swift`

- [ ] **Step 1: WatchSpeechManager**

Create `ios/JarvisApp/Sources/JarvisWatch/WatchSpeechManager.swift`:

```swift
import AVFoundation
import Foundation
import Speech

/// On-device Russian dictation for the watch app. Mirrors SpeechManager from
/// the iOS app but with no shared types (the two apps don't share a module).
@MainActor final class WatchSpeechManager {

    /// Latest partial / final transcript.
    var onTranscript: ((String, _ isFinal: Bool) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async -> Bool {
        let authed = await Self.requestAuthorisations()
        guard authed, let recognizer, recognizer.isAvailable else { return false }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { return false }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    Task { @MainActor in
                        self.onTranscript?(text, result.isFinal)
                    }
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.stop() }
            }
        }
        return true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestAuthorisations() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        let micOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        return micOK
    }
}
```

- [ ] **Step 2: Wire dictation into WatchAppState**

In `WatchAppState.swift`, add the speech manager reference + dictation methods. Replace the file with:

```swift
import Foundation
import WatchConnectivity

/// In-memory model for the watch app. Pulls assistant messages over WCSession
/// from the iPhone and exposes a push-to-talk dictation interface.
@Observable @MainActor final class WatchAppState: NSObject, WCSessionDelegate {

    struct ReceivedMessage: Identifiable, Equatable {
        let id: String
        let text: String
        let timestamp: Date
    }

    var messages: [ReceivedMessage] = []
    var isConnectedToPhone: Bool = false
    var isRecording: Bool = false
    var partialTranscript: String = ""

    static let maxMessages = 50

    @ObservationIgnored private let speech = WatchSpeechManager()
    @ObservationIgnored private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    override init() {
        super.init()
        speech.onTranscript = { [weak self] text, isFinal in
            guard let self else { return }
            self.partialTranscript = text
            if isFinal { self.sendDictatedTextToPhone(text) }
        }
        if let s = session {
            s.delegate = self
            s.activate()
            isConnectedToPhone = (s.activationState == .activated && s.isCompanionAppInstalled)
        }
    }

    // MARK: – Receiving assistant messages

    private func appendIfMessage(_ dict: [String: Any]) {
        guard let type = dict["type"] as? String, type == "message",
              let id = dict["id"] as? String,
              let text = dict["text"] as? String else { return }
        let ts: Date = {
            if let s = dict["ts"] as? String, let d = ISO8601DateFormatter().date(from: s) { return d }
            return Date()
        }()
        messages.append(.init(id: id, text: text, timestamp: ts))
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    // MARK: – Push-to-talk

    func startDictation() {
        partialTranscript = ""
        isRecording = true
        Task { @MainActor in
            let ok = await speech.start()
            if !ok { self.isRecording = false }
        }
    }

    func endDictation() {
        guard isRecording else { return }
        let text = partialTranscript
        speech.stop()
        isRecording = false
        if !text.isEmpty { sendDictatedTextToPhone(text) }
        partialTranscript = ""
    }

    private func sendDictatedTextToPhone(_ text: String) {
        guard let s = session, s.isReachable else { return }
        s.sendMessage(["type": "send_text", "text": text], replyHandler: nil) { error in
            print("[Watch WC] sendMessage error: \(error)")
        }
    }

    // MARK: – WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor [weak self] in
            self?.isConnectedToPhone = (activationState == .activated)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in
            self?.appendIfMessage(userInfo)
        }
    }
}
```

- [ ] **Step 3: Update JarvisWatchApp.swift to drive the gestures**

Replace `ios/JarvisApp/Sources/JarvisWatch/JarvisWatchApp.swift`:

```swift
import SwiftUI

@main
struct JarvisWatchApp: App {
    @State private var state = WatchAppState()

    var body: some Scene {
        WindowGroup {
            WatchContentView(
                onPushToTalkStart: { state.startDictation() },
                onPushToTalkEnd: { state.endDictation() }
            )
            .environment(state)
        }
    }
}
```

- [ ] **Step 4: Build watch + iOS targets**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | tail -15
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
```

Expected: watch BUILD SUCCEEDED + iOS BUILD SUCCEEDED + tests pass.

If `AVAudioApplication.requestRecordPermission` is unavailable on the watch (older watchOS / API version), fall back to `AVAudioSession.sharedInstance().requestRecordPermission { ... }`. If `WCSession.isCompanionAppInstalled` isn't available, drop the check — `activationState == .activated` is enough for v1.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisWatch/ \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios(watch): dictation + WCSession receive

WatchSpeechManager wraps SFSpeechRecognizer (ru-RU). WatchAppState
now conforms to WCSessionDelegate, appends incoming user-info dicts
as ReceivedMessage, and exposes startDictation/endDictation that the
hold-to-talk gesture drives. On dictation final or hold-release, the
state ships {type: send_text, text} via session.sendMessage."
```

---

### Task 5: AppSettings + settings row + final wiring

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift`

- [ ] **Step 1: Add `watchCompanionEnabled` to AppSettings**

After the proactive keys, append:

```swift
    // MARK: – Watch companion
    @ObservationIgnored @AppStorage("watchCompanionEnabled") var watchCompanionEnabled = true
```

- [ ] **Step 2: Read the real setting in AppCoordinator**

If Task 3 used a hardcoded `true`, replace with `settings.watchCompanionEnabled`:

```swift
            if self.settings.watchCompanionEnabled,
               let last = self.ws.messages.last,
               last.role == .assistant,
               !last.text.isEmpty {
                self.watchBridge.pushAssistantMessage(id: last.id, text: last.text, timestamp: last.timestamp)
            }
```

- [ ] **Step 3: Add a "Apple Watch" section in SettingsFormBody**

In `SettingsView.swift`, find `SettingsFormBody`. Add a new section after the proactive/voice sections (and before the System/About footer). Use the existing `settingsSection` + `settingsToggle` helpers:

```swift
                if !isInitialSetup {
                    settingsSection(title: "Apple Watch") {
                        settingsToggle(
                            icon: "applewatch",
                            label: "Слать ответы Джарвиса на часы",
                            isOn: $settings.watchCompanionEnabled
                        )
                    }
                }
```

Match the exact helper signatures used by other rows in the file (read a sibling settingsToggle to confirm — the proactive section provides a template).

- [ ] **Step 4: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -10
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | tail -10
```

Expected: iOS + tests + watch all green.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift
git commit -m "ios: watch companion toggle in settings + AppCoordinator gate

AppSettings.watchCompanionEnabled (default true). The push to the
watch only fires when the setting is on. Settings 'Apple Watch'
section adds a single toggle row. When the user flips it off, the
watch stops receiving new messages — the iPhone simply stops
emitting transferUserInfo calls."
```

---

### Task 6: Smoke test — boot both sims + manual verify

**Files:** none changed — verification only.

- [ ] **Step 1: Boot the watch simulator**

```bash
xcrun simctl boot "Apple Watch Series 11 (46mm)" 2>&1 | head -5
open -a Simulator
```

- [ ] **Step 2: Install + run the watch app**

```bash
xcodebuild -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -derivedDataPath /tmp/jarvis-watch-build \
  build 2>&1 | tail -10
xcrun simctl install "Apple Watch Series 11 (46mm)" \
  /tmp/jarvis-watch-build/Build/Products/Debug-watchsimulator/JarvisWatch.app
xcrun simctl launch "Apple Watch Series 11 (46mm)" com.vasechko.jarvis.watch
```

- [ ] **Step 3: Verify smoke**

Manually check:
- Watch app launches without crash
- "off" status text initially (no paired iPhone in this simulator pairing)
- Mic button visible

The full pairing flow requires installing JarvisApp on a paired iPhone simulator — out of scope for v1 smoke. Document this as a manual end-to-end check the user does on real hardware.

- [ ] **Step 4: Commit (only if any UI test or doc fix needed)**

If everything builds + boots cleanly, no commit needed for this task.

If you discovered an issue (e.g. the watch app immediately crashes), fix it inline and commit:

```bash
git add ios/JarvisApp/Sources/JarvisWatch/
git commit -m "ios(watch): smoke-test fix — <one-line description>"
```

---

## Self-Review

**Spec coverage** against the Apple Watch section of `2026-05-28-ios-ui-unified-navigation-design.md`:

| Spec requirement | Task |
|---|---|
| New watchOS app target | Task 1 |
| Minimum watchOS 10 | Task 1 |
| Bundle id `com.vasechko.jarvis.watch` | Task 1 |
| Small orb + last messages + push-to-talk button | Task 2 |
| Watch SFSpeechRecognizer ru-RU | Task 4 |
| iPhone → watch transferUserInfo on assistant message | Task 3 |
| Watch → iPhone sendMessage for dictation | Task 4 |
| Settings toggle `watchCompanionEnabled` | Task 5 |
| Toggle off stops transferUserInfo | Tasks 3 + 5 |
| Text-only v1 (no attachments / drawer / standalone WS) | by omission |

**Deferred (originally in spec but out of scope for this plan):**

- `JarvisCore` SPM extraction — kept iOS and watch as fully separate targets to avoid an invasive cross-file refactor. Watch decodes plain `[String: Any]` dicts. Re-evaluate after the watch app gets a second use case.
- Right-drawer toggle (the navigation spec planned to expose the toggle in the right drawer). v1 lives in `SettingsFormBody` instead, which the drawer already embeds.
- APNs forwarding from iPhone to watch — Apple Watch already mirrors iOS notifications by default; no extra work needed.

**Placeholder scan:** every step shows the actual change.

**Type consistency:** `WatchConnectivityBridge.buildAssistantPayload` and `WatchAppState.appendIfMessage` use the same dict shape (`type:"message", id, text, ts`). `parseSendText` and `WatchAppState.sendDictatedTextToPhone` use the same `{type:"send_text", text}` shape. `ReceivedMessage` on the watch side is private to `WatchAppState` — never crosses the WCSession boundary.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-ios-watch-companion.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
