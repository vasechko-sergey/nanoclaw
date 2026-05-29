# iOS Voice-Fullscreen ("Glass" Mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a chat-less, orb-driven full-screen voice mode (the "Glass" mode) that mirrors Iron Man's HUD: large central orb, live partial transcript, mood-driven phase transitions, no chat UI. Reuses existing `SpeechManager` (STT) and `SpeechSynthesizer` (TTS) and the existing `WebSocketClient` — no new transport.

**Architecture:** Pure SwiftUI fullscreen cover. A testable `VoiceLoopController` (`@Observable @MainActor`) owns the loop state machine — listening → processing → speaking → (auto-resume listening | calm) — and integrates STT/TTS callbacks. `OrbVoiceView` is a thin presentation layer that observes the controller and renders the orb + transcript + bottom controls. Entry points: tap on home center orb (already wired to `onStartVoiceChat`), pinch-out on chat input-bar MiniOrb, long-press on the left header status dot. Three new `AppSettings` keys for behaviour: `autoResumeListening`, `pushToTalk`, `silenceTimeoutSec`.

**Tech Stack:** Swift / SwiftUI / XCTest. `AVFoundation` (`SFSpeechRecognizer`, `AVSpeechSynthesizer`) already wired in `SpeechManager.swift` and `SpeechSynthesizer.swift`. Uses iPhone 17 Pro simulator for tests.

**Scope note:** This plan is Plan B of the larger `2026-05-28-ios-ui-unified-navigation-design.md` spec. Plan A (navigation cleanup) has landed. Plans C (conversation-as-satellite) and D (Apple Watch + JarvisCore SPM extraction) follow as separate plans.

---

## File Structure

| File | Purpose |
|---|---|
| `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift` (MODIFY) | Add three `@AppStorage` keys: `autoResumeListening` (Bool, default true), `pushToTalk` (Bool, default false), `silenceTimeoutSec` (Int, default 30). |
| `ios/JarvisApp/Sources/JarvisApp/Services/VoiceLoopController.swift` (NEW) | `@Observable @MainActor final class`. Owns: enum `Phase { case listening, processing, speaking, calm, error }`, current partial transcript text, silence-timeout timer, push-to-talk semantics. Public API: `start()`, `stop()`, `handleTranscript(_:isFinal:)`, `handleSynthesizerDidFinish()`, `holdStart()`, `holdEnd()`. State transitions are all the testable surface. |
| `ios/JarvisApp/Sources/JarvisApp/Views/OrbVoiceView.swift` (NEW) | SwiftUI fullscreen view. Owns a `SpeechManager` (STT) and references `coordinator.speech` (TTS). Drives `VoiceLoopController`. Renders: status row, large `OrbView`, transcript `Text`, `[к чату ↑]` and `[×]` buttons. Handles dismiss + WebSocket send. |
| `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift` (MODIFY) | Replace `onStartVoiceChat` (currently `→ ChatView with autoStartVoice`) with `OrbVoiceView` `.fullScreenCover`. Center orb tap opens voice mode directly. |
| `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` (MODIFY) | Add pinch-out gesture on input-bar MiniOrb that opens `OrbVoiceView` `.fullScreenCover`. Add long-press on the left `HeaderStatusDot` that opens the same. |
| `ios/JarvisApp/Sources/JarvisApp/Components/HeaderStatusDot.swift` (MODIFY) | Add optional `onLongPress: (() -> Void)? = nil` and wrap content with `.onLongPressGesture` when provided. |
| `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift` (MODIFY) | Add a "Голосовой режим" section inside `SettingsFormBody`: auto-resume toggle, push-to-talk toggle, silence-timeout segmented picker (15/30/60). |
| `ios/JarvisApp/Sources/JarvisAppTests/VoiceLoopControllerTests.swift` (NEW) | Unit tests for the state machine. |
| `ios/JarvisApp/Sources/JarvisUITests/VoiceFullscreenTests.swift` (NEW) | UI test for entry/exit from the home orb tap path. |

## Test Commands

- **iOS unit tests:** `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/<ClassName>`.
- **iOS UI tests:** same with `-only-testing:JarvisUITests/<ClassName>`.
- **Regen Xcode project after adding files:** `cd ios/JarvisApp && xcodegen generate`.

---

### Task 1: AppSettings — three voice keys

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift`

- [ ] **Step 1: Add three `@AppStorage` properties**

In `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift`, find the existing block of `@AppStorage` lines (lines 7-18). Right after `voicePitch` (line 18), add:

```swift
    // MARK: – Voice-fullscreen ("Glass") mode
    /// After TTS finishes reading the assistant reply, auto-resume the
    /// listening loop instead of waiting for the user to tap the orb.
    @ObservationIgnored @AppStorage("autoResumeListening") var autoResumeListening = true
    /// Push-to-talk: orb held while speaking, released to send. Default off
    /// (taps drive the auto-loop).
    @ObservationIgnored @AppStorage("pushToTalk")          var pushToTalk          = false
    /// Silence-timeout for the listening loop (seconds). Allowed: 15, 30, 60.
    @ObservationIgnored @AppStorage("silenceTimeoutSec")   var silenceTimeoutSec   = 30
```

- [ ] **Step 2: Build + run full test target**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED + 50 tests pass (no new tests added in this task — just storage keys).

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift
git commit -m "ios: AppSettings — voice-mode keys (auto-resume, push-to-talk, timeout)

Three new @AppStorage keys behind the Glass voice loop:
- autoResumeListening (Bool, default true) — after TTS finish, resume STT
- pushToTalk (Bool, default false) — alternative gesture model
- silenceTimeoutSec (Int, default 30) — silence cutoff while listening"
```

---

### Task 2: VoiceLoopController — state machine + transitions

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/VoiceLoopController.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/VoiceLoopControllerTests.swift`

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 2: Write failing tests for the basic state machine**

Create `ios/JarvisApp/Sources/JarvisAppTests/VoiceLoopControllerTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class VoiceLoopControllerTests: XCTestCase {

    func testInitialPhaseIsCalm() {
        let c = VoiceLoopController()
        XCTAssertEqual(c.phase, .calm)
        XCTAssertEqual(c.transcript, "")
    }

    func testStartTransitionsToListening() {
        let c = VoiceLoopController()
        c.start()
        XCTAssertEqual(c.phase, .listening)
    }

    func testHandleFinalTranscriptTransitionsToProcessing() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("привет", isFinal: true)
        XCTAssertEqual(c.phase, .processing)
        XCTAssertEqual(c.transcript, "привет")
    }

    func testHandlePartialTranscriptStaysListening() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("прив", isFinal: false)
        XCTAssertEqual(c.phase, .listening)
        XCTAssertEqual(c.transcript, "прив")
    }

    func testHandleAssistantArrivalTransitionsToSpeaking() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("привет", isFinal: true)   // .processing
        c.handleAssistantTextArrived("здравствуйте")
        XCTAssertEqual(c.phase, .speaking)
    }

    func testStopTransitionsToCalm() {
        let c = VoiceLoopController()
        c.start()
        c.stop()
        XCTAssertEqual(c.phase, .calm)
    }

    func testErrorTransitionsToError() {
        let c = VoiceLoopController()
        c.start()
        c.handleError(.sttUnavailable)
        XCTAssertEqual(c.phase, .error)
    }
}
```

- [ ] **Step 3: Verify build error**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/VoiceLoopControllerTests 2>&1 | tail -20
```

Expected: build error — `VoiceLoopController` undefined.

- [ ] **Step 4: Implement VoiceLoopController**

Create `ios/JarvisApp/Sources/JarvisApp/Services/VoiceLoopController.swift`:

```swift
import Foundation

/// Drives the voice-fullscreen ("Glass") loop. Owns the phase state machine,
/// the current partial transcript, and the integration callbacks. STT/TTS
/// services are owned by the presenting view; the controller stays pure so
/// it can be unit-tested without a microphone or audio session.
@Observable @MainActor final class VoiceLoopController {

    enum Phase: Equatable {
        case calm         // idle, waiting for tap or auto-resume
        case listening    // STT running
        case processing   // user finalised, awaiting agent reply
        case speaking     // TTS playing
        case error        // STT/permissions failure
    }

    enum VoiceError: Equatable {
        case sttUnavailable
        case micDenied
        case unknown
    }

    private(set) var phase: Phase = .calm
    private(set) var transcript: String = ""
    private(set) var lastError: VoiceError? = nil

    /// Called by the presenting view to begin a listening session.
    func start() {
        transcript = ""
        lastError = nil
        phase = .listening
    }

    /// Called by the presenting view to fully stop the loop (X tap).
    func stop() {
        phase = .calm
    }

    /// Called by the SpeechManager.onTranscript callback. `isFinal == true`
    /// transitions us to .processing; partials only update the transcript.
    func handleTranscript(_ text: String, isFinal: Bool) {
        transcript = text
        if isFinal {
            phase = .processing
        }
    }

    /// Called when the assistant's reply lands. The view kicks off TTS and
    /// notifies the controller so the orb mood updates.
    func handleAssistantTextArrived(_ text: String) {
        phase = .speaking
    }

    /// Called by SpeechSynthesizerDelegate.didFinish (forwarded by the view).
    /// When `autoResumeListening` is on, the loop returns to listening;
    /// otherwise it parks on `.calm` waiting for a tap.
    func handleSynthesizerDidFinish(autoResume: Bool) {
        if autoResume {
            transcript = ""
            phase = .listening
        } else {
            phase = .calm
        }
    }

    /// Called by the view when STT or mic permission fails.
    func handleError(_ err: VoiceError) {
        lastError = err
        phase = .error
    }
}
```

- [ ] **Step 5: Regenerate + run tests**

```bash
cd ios/JarvisApp && xcodegen generate
cd ../..
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/VoiceLoopControllerTests 2>&1 | tail -15
```

Expected: 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/VoiceLoopController.swift \
        ios/JarvisApp/Sources/JarvisAppTests/VoiceLoopControllerTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add VoiceLoopController — state machine for the Glass voice loop

@Observable @MainActor class. Phase enum (calm/listening/processing/
speaking/error), partial transcript, public transitions: start, stop,
handleTranscript(isFinal:), handleAssistantTextArrived,
handleSynthesizerDidFinish(autoResume:), handleError. Pure — no audio
session or microphone dependencies, so it unit-tests cleanly."
```

---

### Task 3: VoiceLoopController — silence timeout

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/VoiceLoopController.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/VoiceLoopControllerTests.swift`

- [ ] **Step 1: Add failing tests for silence-timeout behaviour**

Append inside `VoiceLoopControllerTests`:

```swift
    func testSilenceTimeoutTransitionsToCalmWhenNoPartial() {
        let c = VoiceLoopController()
        c.start()
        c.tickSilenceTimerForTesting(elapsed: 31, threshold: 30)
        XCTAssertEqual(c.phase, .calm, "no partial in window → return to calm")
    }

    func testSilenceTimeoutDoesNothingIfPartialReceived() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("прив", isFinal: false)
        c.tickSilenceTimerForTesting(elapsed: 31, threshold: 30)
        XCTAssertEqual(c.phase, .listening, "partial within window keeps us listening")
    }

    func testSilenceTimeoutOnlyAppliesWhenListening() {
        let c = VoiceLoopController()
        c.start()
        c.handleTranscript("привет", isFinal: true)   // → processing
        c.tickSilenceTimerForTesting(elapsed: 999, threshold: 30)
        XCTAssertEqual(c.phase, .processing, "silence timeout ignored when not listening")
    }
```

- [ ] **Step 2: Verify build error**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/VoiceLoopControllerTests 2>&1 | tail -15
```

Expected: build error — `tickSilenceTimerForTesting` not defined.

- [ ] **Step 3: Implement silence-timeout logic**

In `VoiceLoopController.swift`, add tracking state above `phase`:

```swift
    private(set) var lastPartialAt: Date?
```

In `start()`, after `phase = .listening`, append:

```swift
        lastPartialAt = Date()
```

In `handleTranscript(_:isFinal:)`, BEFORE the `isFinal` check, add:

```swift
        lastPartialAt = Date()
```

Add a new method at the end of the class:

```swift
    /// Production seam — the presenting view runs a 1Hz timer that calls this
    /// with `elapsed = now - lastPartialAt` and `threshold = settings.silenceTimeoutSec`.
    /// In `.listening` phase only, an over-threshold silence parks the loop on `.calm`.
    func tickSilence(elapsed: TimeInterval, threshold: TimeInterval) {
        guard phase == .listening else { return }
        if elapsed > threshold {
            phase = .calm
        }
    }

    /// Test seam — same as `tickSilence` with explicit args so unit tests
    /// don't have to set up a real clock.
    func tickSilenceTimerForTesting(elapsed: TimeInterval, threshold: TimeInterval) {
        tickSilence(elapsed: elapsed, threshold: threshold)
    }
```

- [ ] **Step 4: Run tests**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/VoiceLoopControllerTests 2>&1 | tail -15
```

Expected: 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/VoiceLoopController.swift \
        ios/JarvisApp/Sources/JarvisAppTests/VoiceLoopControllerTests.swift
git commit -m "ios: VoiceLoopController — silence-timeout transition to .calm

While in .listening, if elapsed time since the last partial transcript
exceeds the configured threshold (default 30s), the loop returns to
.calm. Tap restarts. Partials reset the clock. Tests use a synchronous
seam so no real timer is needed."
```

---

### Task 4: VoiceLoopController — push-to-talk mode

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/VoiceLoopController.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/VoiceLoopControllerTests.swift`

- [ ] **Step 1: Add failing tests for push-to-talk gestures**

Append inside `VoiceLoopControllerTests`:

```swift
    func testHoldStartTransitionsToListening() {
        let c = VoiceLoopController()
        c.holdStart()
        XCTAssertEqual(c.phase, .listening)
    }

    func testHoldEndWithEmptyTranscriptReturnsCalm() {
        let c = VoiceLoopController()
        c.holdStart()
        // transcript stays empty (user released without speaking)
        c.holdEnd()
        XCTAssertEqual(c.phase, .calm)
    }

    func testHoldEndWithPartialTranscriptTransitionsToProcessing() {
        let c = VoiceLoopController()
        c.holdStart()
        c.handleTranscript("привет", isFinal: false)
        c.holdEnd()
        XCTAssertEqual(c.phase, .processing,
                       "hold-release with non-empty partial finalises and ships the text")
    }
```

- [ ] **Step 2: Verify build error**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/VoiceLoopControllerTests 2>&1 | tail -15
```

Expected: build error — `holdStart` / `holdEnd` not defined.

- [ ] **Step 3: Implement push-to-talk methods**

In `VoiceLoopController.swift`, add at the end:

```swift
    /// Push-to-talk: gesture began on the orb. Same effect as `start()` but
    /// named so the call site reads as a gesture lifecycle.
    func holdStart() {
        start()
    }

    /// Push-to-talk: gesture ended. If we have any transcript, treat as
    /// final → .processing; otherwise return to .calm (user released without
    /// speaking).
    func holdEnd() {
        if transcript.isEmpty {
            phase = .calm
        } else {
            phase = .processing
        }
    }
```

- [ ] **Step 4: Run tests**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/VoiceLoopControllerTests 2>&1 | tail -15
```

Expected: 13 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/VoiceLoopController.swift \
        ios/JarvisApp/Sources/JarvisAppTests/VoiceLoopControllerTests.swift
git commit -m "ios: VoiceLoopController — push-to-talk holdStart/holdEnd

When pushToTalk is enabled in settings, the presenting view drives
the loop with hold gestures: holdStart = begin listening, holdEnd =
finalise (if transcript present, → .processing; else → .calm).
Auto-resume is not triggered by holdEnd — push-to-talk is explicit."
```

---

### Task 5: OrbVoiceView fullscreen UI

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/OrbVoiceView.swift`

This task creates the fullscreen view. No new behavioural tests beyond what the controller already covers; this is the SwiftUI shell.

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 2: Implement OrbVoiceView**

Create `ios/JarvisApp/Sources/JarvisApp/Views/OrbVoiceView.swift`:

```swift
import SwiftUI

/// Fullscreen voice mode. Presented over ChatView or OrbHomeView. Renders the
/// large orb, live partial transcript, and bottom controls. Drives a
/// `VoiceLoopController` and integrates SpeechManager (STT) + the shared
/// `coordinator.speech` (TTS).
struct OrbVoiceView: View {
    @Environment(AppSettings.self) var settings
    @Environment(\.dismiss) private var dismiss
    var coordinator: AppCoordinator
    /// When non-nil, dismiss handoff goes here (e.g., "к чату" tap). When nil,
    /// dismiss just closes the cover and returns to the presenting screen.
    var onHandoffToChat: (() -> Void)?

    @State private var controller = VoiceLoopController()
    @State private var speech = SpeechManager()
    @State private var silenceTimer: Timer?

    private var orbMood: OrbMood {
        switch controller.phase {
        case .calm:       return .calm
        case .listening:  return .listening
        case .processing: return .processing
        case .speaking:   return .speaking
        case .error:      return .error
        }
    }

    private var orbSize: CGFloat {
        min(UIScreen.main.bounds.width * 0.6, 280)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Thin status row at the top
                statusRow
                    .padding(.horizontal, Theme.hPadding)
                    .padding(.top, Theme.scaled(12))

                Spacer()

                // Central orb + transcript
                VStack(spacing: Theme.scaled(20)) {
                    OrbView(size: orbSize, mood: orbMood)
                        .onTapGesture { handleOrbTap() }
                        .gesture(
                            settings.pushToTalk
                                ? AnyGesture(holdGesture.map { _ in () })
                                : nil
                        )

                    transcriptText
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Theme.hPadding)
                }

                Spacer()

                // Bottom controls
                bottomControls
                    .padding(.horizontal, Theme.hPadding)
                    .padding(.bottom, Theme.scaled(28))
            }
        }
        .accessibilityIdentifier("orb-voice-view")
        .onAppear { onAppear() }
        .onDisappear { onDisappear() }
        .onChange(of: coordinator.ws.messages.last?.id) {
            handleNewAssistantMessage()
        }
    }

    // MARK: – Subviews

    private var statusRow: some View {
        HStack(spacing: Theme.scaled(8)) {
            Circle()
                .fill(coordinator.ws.isConnected ? Theme.online : Theme.offline)
                .frame(width: 6, height: 6)
            Text(coordinator.ws.isConnected ? "online" : "offline")
                .font(.system(size: Theme.fontSmall, design: .monospaced))
                .foregroundStyle(Theme.accentMedium)
            Spacer()
            Text(Date(), style: .time)
                .font(.system(size: Theme.fontSmall, design: .monospaced))
                .foregroundStyle(Theme.accentMedium)
        }
    }

    private var transcriptText: some View {
        Text(controller.transcript)
            .font(.system(size: Theme.scaled(16), design: .monospaced))
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .animation(.easeOut(duration: 0.2), value: controller.transcript)
    }

    private var bottomControls: some View {
        HStack {
            Button {
                handoff()
            } label: {
                Label("к чату", systemImage: "arrow.up")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundStyle(Theme.accentMedium)
            }
            .accessibilityIdentifier("voice-handoff-btn")

            Spacer()

            Button {
                handleClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Theme.scaled(32)))
                    .foregroundStyle(Theme.accentMedium)
            }
            .accessibilityIdentifier("voice-close-btn")
        }
    }

    // MARK: – Lifecycle

    private func onAppear() {
        // Wire SpeechManager → controller
        speech.onTranscript = { [controller, speech] partial in
            Task { @MainActor in
                let isFinal = !speech.isRecording   // SpeechManager flips on result.isFinal
                controller.handleTranscript(partial, isFinal: isFinal)
            }
        }
        // Begin listening unless push-to-talk mode (then we wait for hold)
        if !settings.pushToTalk {
            controller.start()
            speech.start()
        }
        startSilenceTimer()
    }

    private func onDisappear() {
        speech.stop()
        coordinator.speech.stop()
        silenceTimer?.invalidate()
        silenceTimer = nil
        controller.stop()
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard let last = controller.lastPartialAt else { return }
                let elapsed = Date().timeIntervalSince(last)
                controller.tickSilence(elapsed: elapsed,
                                       threshold: TimeInterval(settings.silenceTimeoutSec))
            }
        }
    }

    // MARK: – Orb interactions

    private func handleOrbTap() {
        switch controller.phase {
        case .calm, .error:
            controller.start()
            speech.start()
        case .listening:
            // Force-finalise: stop STT, controller falls into .processing
            speech.stop()
            controller.handleTranscript(controller.transcript, isFinal: true)
            sendIfReady()
        case .processing, .speaking:
            break  // ignore taps while awaiting reply or speaking
        }
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if controller.phase != .listening {
                    controller.holdStart()
                    speech.start()
                }
            }
            .onEnded { _ in
                speech.stop()
                controller.holdEnd()
                sendIfReady()
            }
    }

    private func sendIfReady() {
        guard controller.phase == .processing, !controller.transcript.isEmpty else { return }
        coordinator.sendMessage(controller.transcript, viaVoice: true)
    }

    private func handleNewAssistantMessage() {
        guard let msg = coordinator.ws.messages.last,
              msg.role == .assistant,
              !msg.text.isEmpty else { return }
        controller.handleAssistantTextArrived(msg.text)
        coordinator.speech.speak(msg.text,
                                 voiceId: settings.voiceId,
                                 rate: settings.voiceRate,
                                 pitch: settings.voicePitch)
        observeSynthesizerFinish()
    }

    private func observeSynthesizerFinish() {
        // Poll: AVSpeechSynthesizer's delegate is owned by SpeechSynthesizer,
        // but `isSpeaking` is observable. When it falls from true to false,
        // forward to the controller.
        Task { @MainActor in
            while coordinator.speech.isSpeaking {
                try? await Task.sleep(for: .milliseconds(150))
            }
            controller.handleSynthesizerDidFinish(autoResume: settings.autoResumeListening)
            if settings.autoResumeListening {
                speech.start()
            }
        }
    }

    private func handoff() {
        speech.stop()
        coordinator.speech.stop()
        dismiss()
        onHandoffToChat?()
    }

    private func handleClose() {
        dismiss()
    }
}
```

- [ ] **Step 3: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbVoiceView.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "ios: add OrbVoiceView — Glass mode fullscreen voice UI

SwiftUI fullscreen cover. Owns SpeechManager (STT), borrows
coordinator.speech (TTS), drives VoiceLoopController. Renders status
row + large orb + live partial transcript + handoff/close controls.
Supports auto-loop and push-to-talk gesture model based on settings.
A 1Hz timer wakes the controller's silence-timeout check."
```

---

### Task 6: Wire OrbHomeView center orb → OrbVoiceView

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`

Current behaviour: tapping the home center orb sets `autoStartVoice = true` and switches `appPhase = .chat`. The new behaviour: open `OrbVoiceView` as a `.fullScreenCover` directly. The user can still hand off to chat from inside voice mode via the "к чату" button.

- [ ] **Step 1: Add @State for the fullScreenCover binding**

In `OrbHomeView`, near other state vars, add:

```swift
    @State private var showVoiceFullscreen = false
```

- [ ] **Step 2: Replace the `onTapGesture` body of the center orb**

Find the center orb tap handler — `onStartVoiceChat()` call site. Replace its body so the local fullScreenCover toggles instead of delegating to the parent:

```swift
    // BEFORE (somewhere around the central orb):
    //     OrbView(...)
    //         .onTapGesture {
    //             onStartVoiceChat()
    //         }
    //
    // AFTER:
        OrbView(...)
            .onTapGesture {
                showVoiceFullscreen = true
            }
```

Keep `onStartVoiceChat` as the parameter to `OrbHomeView` for now (other call sites still use it). The handoff-to-chat path inside `OrbVoiceView` will call it via the `onHandoffToChat` closure (next step).

- [ ] **Step 3: Mount the fullScreenCover**

Find the bottom of OrbHomeView's body where other modifiers chain. Add:

```swift
        .fullScreenCover(isPresented: $showVoiceFullscreen) {
            OrbVoiceView(coordinator: coordinator, onHandoffToChat: {
                onStartVoiceChat()  // existing path: home → chat, voice-armed
            })
        }
```

- [ ] **Step 4: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "ios(home): center orb tap → OrbVoiceView fullScreenCover

Direct entry into Glass mode from the home orb. The existing
onStartVoiceChat callback is now invoked only when the user explicitly
hands off from voice to chat via the in-view 'к чату' button, not
on every orb tap."
```

---

### Task 7: Wire ChatView input-bar MiniOrb pinch-out → OrbVoiceView

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/UnifiedInputBar.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

The input bar already contains a `MiniOrbView`. We add an optional `onPinchOut: (() -> Void)?` callback and the matching gesture so ChatView can react.

- [ ] **Step 1: Add a callback parameter to UnifiedInputBar**

In `ios/JarvisApp/Sources/JarvisApp/Components/UnifiedInputBar.swift`, find the property list at the top of the struct. Add:

```swift
    var onPinchOut: (() -> Void)? = nil
```

Find where the `MiniOrbView` is instantiated inside the input bar (search for `MiniOrbView`). Attach a `MagnifyGesture` (iOS 17+) or `MagnificationGesture` (iOS 16 fallback) so that scaling > 1.4 fires the callback:

```swift
            MiniOrbView(...)
                .gesture(
                    MagnifyGesture()
                        .onEnded { value in
                            if value.magnification > 1.4 {
                                onPinchOut?()
                            }
                        }
                )
```

If the project targets iOS 18 only (per `project.yml`), `MagnifyGesture` is fine. If it targets older versions, fall back to `MagnificationGesture`. Check `project.yml`'s `deploymentTarget` first — based on existing CLAUDE.md, the project is iOS 18+, so `MagnifyGesture` works.

- [ ] **Step 2: Wire the callback in ChatView**

In `ChatView.swift`, find the `UnifiedInputBar(...)` instantiation (around line 243-247). It currently looks like:

```swift
                UnifiedInputBar(text: $inputText, inputViaVoice: $inputViaVoice, drafts: $drafts,
                                commands: ws.commands, isDisabled: !ws.isConnected,
                                enterToSend: settings.enterToSend,
                                autoStartVoice: $autoStartVoice,
                                onSend: sendCurrent)
```

Add the new argument:

```swift
                UnifiedInputBar(text: $inputText, inputViaVoice: $inputViaVoice, drafts: $drafts,
                                commands: ws.commands, isDisabled: !ws.isConnected,
                                enterToSend: settings.enterToSend,
                                autoStartVoice: $autoStartVoice,
                                onSend: sendCurrent,
                                onPinchOut: { showVoiceFullscreen = true })
```

- [ ] **Step 3: Add `showVoiceFullscreen` state + fullScreenCover on ChatView**

Near other state vars in ChatView (around line 25-35), add:

```swift
    @State private var showVoiceFullscreen = false
```

In the body's modifier chain (next to other `.sheet` modifiers — wait, those are gone — next to `.fullScreenCover(item: ...)` for image preview), add:

```swift
        .fullScreenCover(isPresented: $showVoiceFullscreen) {
            OrbVoiceView(coordinator: coordinator, onHandoffToChat: nil)
        }
```

`onHandoffToChat: nil` because ChatView IS the chat — no handoff needed; the in-view "к чату" button just dismisses.

- [ ] **Step 4: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/UnifiedInputBar.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "ios(chat): pinch-out on input-bar MiniOrb → OrbVoiceView

UnifiedInputBar gains an optional onPinchOut callback wired to a
MagnifyGesture on the MiniOrb. ChatView shows OrbVoiceView as a
fullScreenCover when fired. The 'к чату' button inside Glass mode
just dismisses (we're already in chat)."
```

---

### Task 8: HeaderStatusDot long-press + ChatView/OrbHomeView wiring

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/HeaderStatusDot.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`

Add long-press support so the left header dot opens Glass mode in addition to its short-tap (drawer-open) behaviour.

- [ ] **Step 1: Add `onLongPress` parameter to HeaderStatusDot**

In `ios/JarvisApp/Sources/JarvisApp/Components/HeaderStatusDot.swift`, add a new property next to `action`:

```swift
    var onLongPress: (() -> Void)? = nil
```

Replace the `Button(action: action) { ... }` with a button that also attaches a long-press recognizer. SwiftUI's clean way is to attach `.onLongPressGesture` to the Button's label and let the button handle short taps. But because long press and tap conflict on the same element, use `.simultaneousGesture` so both can fire independently:

```swift
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
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.6)
                .onEnded { _ in
                    onLongPress?()
                }
        )
    }
```

- [ ] **Step 2: Wire ChatView left dot to open OrbVoiceView on long press**

Find the left `HeaderStatusDot(side: .left, ...)` instantiation in ChatView's header. Add the `onLongPress` argument:

```swift
            HeaderStatusDot(side: .left, isConnected: ws.isConnected, phase: orbMood) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    if rightDrawerOpen { rightDrawerOpen = false }
                    drawerOpen = true
                }
            } onLongPress: {
                showVoiceFullscreen = true
            }
            .accessibilityIdentifier("orb-drawer-btn")
            .accessibilityLabel(ws.isConnected ? "Открыть список диалогов. Подключено" : "Открыть список диалогов. Отключено")
```

- [ ] **Step 3: Wire OrbHomeView left dot the same way**

In OrbHomeView's header, find the left `HeaderStatusDot(side: .left, ...)`. Add:

```swift
            HeaderStatusDot(side: .left,
                            isConnected: coordinator.ws.isConnected,
                            phase: .calm) {
                withAnimation(.spring(duration: Theme.animMedium, bounce: 0.05)) {
                    if rightDrawerOpen { rightDrawerOpen = false }
                    leftDrawerOpen = true
                }
            } onLongPress: {
                showVoiceFullscreen = true
            }
            .accessibilityLabel(coordinator.ws.isConnected ? "Открыть список диалогов. Подключено" : "Открыть список диалогов. Отключено")
```

- [ ] **Step 4: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/HeaderStatusDot.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift
git commit -m "ios: long-press on left header dot → OrbVoiceView

HeaderStatusDot gains an optional onLongPress (0.6s threshold) wired
through simultaneousGesture so the short-tap drawer-open path keeps
working. Both ChatView and OrbHomeView use it to open Glass mode."
```

---

### Task 9: Settings UI — voice-mode rows

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift`

Add a "Голосовой режим" section inside `SettingsFormBody` with the three new keys.

- [ ] **Step 1: Locate the right insertion point**

In `SettingsView.swift`, find `SettingsFormBody`. Identify the ScrollView's child stack containing the existing sections (Agent / Connection / Context / Voice / Input / System / About). The new section goes between **Voice** (TTS voice picker) and **Input** (enterToSend, etc.), grouped logically with other voice-related settings.

- [ ] **Step 2: Add the new section block**

Insert this block in the appropriate place inside `SettingsFormBody.body`:

```swift
                if !isInitialSetup {
                    settingsSection("Голосовой режим") {
                        settingsToggle("Авто-возобновление слушания",
                                       isOn: $settings.autoResumeListening,
                                       subtitle: "После ответа Джарвиса снова начать слушать без тапа.")

                        settingsToggle("Зажать орб для записи",
                                       isOn: $settings.pushToTalk,
                                       subtitle: "Push-to-talk. Без него — авто-цикл по тапу.")

                        VStack(alignment: .leading, spacing: Theme.scaled(6)) {
                            Text("Тайм-аут тишины")
                                .font(.system(size: Theme.fontCaption))
                                .foregroundStyle(Theme.accentMedium)

                            Picker("Тайм-аут тишины",
                                   selection: Binding(
                                    get: { settings.silenceTimeoutSec },
                                    set: { settings.silenceTimeoutSec = $0 })) {
                                Text("15 с").tag(15)
                                Text("30 с").tag(30)
                                Text("60 с").tag(60)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, Theme.scaled(4))
                    }
                }
```

If `settingsSection` / `settingsToggle` signatures in the existing file differ (e.g. take a `String` and a `@ViewBuilder`), match them exactly — read the existing usage in SettingsFormBody first.

- [ ] **Step 3: Build + tests**

```bash
xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED + tests pass.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift
git commit -m "ios: settings — Glass mode rows (auto-resume, hold-to-talk, timeout)

New 'Голосовой режим' section in the settings form with three
controls bound to the AppSettings keys added earlier. Visible only
when not in the initial-setup flow."
```

---

### Task 10: UI test — entry/exit from home center orb

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisUITests/VoiceFullscreenTests.swift`

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 2: Write UI tests**

Create `ios/JarvisApp/Sources/JarvisUITests/VoiceFullscreenTests.swift`:

```swift
import XCTest

final class VoiceFullscreenTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        return app
    }

    func testHomeOrbTapPresentsVoiceFullscreen() {
        let app = launchApp()
        // Home orb has accessibility identifier "home-orb" set in OrbHomeView
        let homeOrb = app.otherElements["home-orb"]
        XCTAssertTrue(homeOrb.waitForExistence(timeout: 5))
        homeOrb.tap()

        let voiceView = app.otherElements["orb-voice-view"]
        XCTAssertTrue(voiceView.waitForExistence(timeout: 3),
                      "Tapping the home center orb must open Glass mode fullscreen")
    }

    func testCloseButtonDismissesVoiceFullscreen() {
        let app = launchApp()
        let homeOrb = app.otherElements["home-orb"]
        XCTAssertTrue(homeOrb.waitForExistence(timeout: 5))
        homeOrb.tap()

        let voiceView = app.otherElements["orb-voice-view"]
        XCTAssertTrue(voiceView.waitForExistence(timeout: 3))

        let closeBtn = app.buttons["voice-close-btn"]
        XCTAssertTrue(closeBtn.waitForExistence(timeout: 2))
        closeBtn.tap()

        // The fullscreen cover should disappear within a couple of seconds.
        let gone = NSPredicate(format: "hittable == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: voiceView)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 3), .completed)
    }
}
```

- [ ] **Step 3: Run UI tests**

```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisUITests/VoiceFullscreenTests 2>&1 | tail -25
```

Expected: 2 UI tests PASS.

If `home-orb` identifier is not currently set, find OrbHomeView's central `OrbView` and add `.accessibilityIdentifier("home-orb")` to it before rerunning.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisUITests/VoiceFullscreenTests.swift \
        ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "test(ios-ui): Glass mode entry from home orb + close

Two UI tests: tapping the home center orb opens the fullscreen voice
view; tapping its close button dismisses. Uses identifiers wired in
OrbVoiceView (orb-voice-view / voice-close-btn) and OrbHomeView
(home-orb)."
```

---

## Self-Review

**Spec coverage** against the OrbVoiceView section of `2026-05-28-ios-ui-unified-navigation-design.md`:

| Spec requirement | Task |
|---|---|
| OrbVoiceView fullscreen cover | Task 5 |
| 5 phases: listening / processing / speaking / calm / error | Task 2 |
| Entry: home center orb tap | Task 6 |
| Entry: ChatView pinch-out on MiniOrb | Task 7 |
| Entry: long-press top-left dot | Task 8 |
| Loop step 1: orb `.listening`, SpeechManager.start | Task 5 |
| Loop step 2: partials → render under orb | Task 5 |
| Loop step 3: final → SpeechManager.stop, ws.send | Task 5 (sendIfReady) |
| Loop step 4: assistant → speaking + TTS | Task 5 (handleNewAssistantMessage) |
| Loop step 5: TTS didFinish → auto-resume or calm | Task 5 (observeSynthesizerFinish) + Task 2 (handleSynthesizerDidFinish) |
| Loop step 6: silence timeout → calm | Task 3 |
| Loop step 7: "к чату" hands off, preserves history | Task 5 (handoff) + Task 6 (onHandoffToChat) |
| Loop step 8: × stops STT + TTS, dismiss | Task 5 (handleClose + onDisappear) |
| Push-to-talk mode | Tasks 4 + 5 (holdGesture) |
| Settings keys: autoResumeListening, pushToTalk, silenceTimeoutSec | Task 1 |
| `viaVoice: true` on send | Task 5 (sendIfReady → coordinator.sendMessage(text, viaVoice: true)) |

**Out of scope of this plan** (deferred to other plans):

- Apple Watch integration → Plan D
- Conversation-as-satellite on home → Plan C
- Live-context chip in right drawer → proactive spec
- Server-side `viaVoice` flag forwarding to agent → already handled by existing `sendMessage` path; the agent personality work that consumes it lives in the proactive spec persona section.

**Placeholder scan:** every step shows the actual change. No `TBD` / `add appropriate handling` markers.

**Type consistency:** `VoiceLoopController.Phase` (`.calm/.listening/.processing/.speaking/.error`) is used in Tasks 2-5 and maps 1:1 to `OrbMood`. The mapping happens in `OrbVoiceView.orbMood` (Task 5). `showVoiceFullscreen: Bool` @State name is consistent across ChatView (Tasks 7, 8) and OrbHomeView (Tasks 6, 8). `onHandoffToChat: (() -> Void)?` parameter on `OrbVoiceView` is used at both call sites (home passes a real closure; chat passes nil). `onLongPress: (() -> Void)?` parameter on `HeaderStatusDot` introduced in Task 8 is used by both Chat and Home headers in the same task.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-ios-voice-fullscreen.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
