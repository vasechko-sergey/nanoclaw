# Posing Coach — Composition MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device camera screen to JarvisApp that shows real-time composition hints (framing) while the user photographs another person — the first shippable slice of the posing coach.

**Architecture:** `AVFoundation` camera → `Vision` body-pose keypoints → a pure `CompositionEngine` that turns a skeleton + frame info into text hints → a SwiftUI overlay (thirds grid + hint chips). All on-device, offline, zero inference cost. This plan covers **Phase 0 (spike)** and **Phase 1 (composition MVP)** from the design. Pose-library / ghost-silhouette (Phase 2) is a separate later plan.

**Tech Stack:** Swift, SwiftUI, AVFoundation, Vision, CoreMotion. Built via xcodegen + xcodebuild. Tests via `bun`-free XCTest (`@testable import Jarvis`).

**Design spec:** [docs/superpowers/specs/2026-07-03-ondevice-posing-coach-design.md](../specs/2026-07-03-ondevice-posing-coach-design.md)

---

## Codebase Notes (read before starting — you have zero context here)

- **App module name is `Jarvis`** (product `Jarvis.app`), even though the SPM/xcodegen target is named `JarvisApp`. Test files use `@testable import Jarvis`. Do NOT write `import JarvisApp`.
- **Feature lives in a self-contained folder:** create everything under `Sources/JarvisApp/PosingCoach/`. xcodegen's `JarvisApp` target uses `sources: [Sources/JarvisApp]`, so any new file under that path is auto-included after `xcodegen generate` — **no manual .pbxproj edits for source files.**
- **Tests go in** `Sources/JarvisAppTests/` (flat, matches existing convention).
- **Coordinate convention for this feature:** all `Skeleton` joint positions are **normalized screen space**: `x,y ∈ [0,1]`, origin **top-left**, `y` increases **downward** (SwiftUI convention). Vision returns normalized points with origin **bottom-left, y up** — `PoseDetector` flips `y` when converting. `CompositionEngine` and all tests reason purely in screen space, so tests construct `Skeleton` values directly with no camera or Vision involved.
- **Camera permission string already exists** in `project.yml` (`NSCameraUsageDescription`). Task 11 updates its wording to mention posing.
- **Version bump is mandatory for any iOS change** (project rule): bump `MARKETING_VERSION` (per feature) and `CURRENT_PROJECT_VERSION` (every installed build) in `project.yml`, then `xcodegen generate`, then commit the regenerated `.xcodeproj`. Currently `1.19.2` / build `79`.

### Build & test commands (run from `ios/JarvisApp/`)

Regenerate project after adding/removing files or editing `project.yml`:
```bash
cd ios/JarvisApp && xcodegen generate
```

Run one test class on a simulator:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:JarvisAppTests/CompositionEngineTests 2>&1 | tail -30
```
(If `iPhone 16` isn't installed, run `xcrun simctl list devices available` and substitute any booted iOS simulator name. Confirm the scheme with `xcodebuild -list -project JarvisApp.xcodeproj`.)

Clean build of the whole app (no install):
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```

---

## Task 1: Phase 0 spike — measure Vision body-pose fps on a real device

> This is a throwaway de-risking spike, not TDD. Goal: prove `VNDetectHumanBodyPoseRequest` runs at a usable frame rate on a real iPhone before investing in Phase 1. If it can't hit ~20+ fps on target hardware, stop and revisit the design.

**Files:**
- Create (throwaway): `Sources/JarvisApp/PosingCoach/_SpikeCameraView.swift`

- [ ] **Step 1: Write a minimal camera + Vision preview**

```swift
// Sources/JarvisApp/PosingCoach/_SpikeCameraView.swift
// THROWAWAY SPIKE — delete after Task 1. Proves Vision pose fps on device.
import SwiftUI
import AVFoundation
import Vision

struct _SpikeCameraView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> _SpikeVC { _SpikeVC() }
    func updateUIViewController(_ vc: _SpikeVC, context: Context) {}
}

final class _SpikeVC: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "spike.camera")
    private var lastLog = Date()
    private var frames = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        session.sessionPreset = .high
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        DispatchQueue.global().async { self.session.startRunning() }
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput buf: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(buf) else { return }
        let req = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([req])
        frames += 1
        if Date().timeIntervalSince(lastLog) >= 1 {
            print("SPIKE fps=\(frames) joints=\((req.results?.first?.availableJointNames.count) ?? 0)")
            frames = 0; lastLog = Date()
        }
    }
}
```

- [ ] **Step 2: Temporarily present it and run on a real device**

Add a temporary `.fullScreenCover` or a debug button that shows `_SpikeCameraView()`. Build and run on a **physical iPhone** (simulator has no camera). Watch the Xcode console for `SPIKE fps=…` lines.

Run:
```bash
cd ios/JarvisApp && xcodegen generate
# then build+run on a connected device from Xcode (Cmd-R) or XcodeBuildMCP build_run on device
```
Expected: console prints `SPIKE fps=…` with `fps` ≥ ~20 and `joints` > 0 when a person is in frame.

- [ ] **Step 3: Record the result, then delete the spike**

Note the observed fps and device model in the task's commit message. Delete `_SpikeCameraView.swift` and remove the temporary presentation.

- [ ] **Step 4: Commit**

```bash
git rm ios/JarvisApp/Sources/JarvisApp/PosingCoach/_SpikeCameraView.swift
git add -A
git commit -m "spike(posing): measure Vision body-pose fps on device (<model>: <fps> fps)"
```

**Gate:** if fps is unacceptable, stop here and revisit the design before Task 2.

---

## Task 2: Core types — `BodyJoint`, `Skeleton`, `Hint`

**Files:**
- Create: `Sources/JarvisApp/PosingCoach/PosingTypes.swift`
- Test: `Sources/JarvisAppTests/PosingTypesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Sources/JarvisAppTests/PosingTypesTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class PosingTypesTests: XCTestCase {
    func test_skeleton_point_lookup_and_centerX() {
        let s = Skeleton(joints: [
            .leftShoulder: JointPoint(position: CGPoint(x: 0.4, y: 0.3), confidence: 0.9),
            .rightShoulder: JointPoint(position: CGPoint(x: 0.6, y: 0.3), confidence: 0.9),
        ])
        XCTAssertEqual(s.point(.leftShoulder)?.position.x, 0.4)
        XCTAssertNil(s.point(.leftAnkle))
        XCTAssertEqual(s.centerX()!, 0.5, accuracy: 0.0001)
    }

    func test_centerX_falls_back_to_hips_then_nil() {
        let hips = Skeleton(joints: [
            .leftHip: JointPoint(position: CGPoint(x: 0.2, y: 0.6), confidence: 0.8),
            .rightHip: JointPoint(position: CGPoint(x: 0.4, y: 0.6), confidence: 0.8),
        ])
        XCTAssertEqual(hips.centerX()!, 0.3, accuracy: 0.0001)
        XCTAssertNil(Skeleton(joints: [:]).centerX())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PosingTypesTests` (see Codebase Notes)
Expected: FAIL — `cannot find 'Skeleton' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/JarvisApp/PosingCoach/PosingTypes.swift
import CoreGraphics

/// Body joints we care about. Subset of Vision's VNHumanBodyPoseObservation.JointName.
public enum BodyJoint: String, CaseIterable {
    case nose, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
    case root
}

/// One detected joint in normalized SCREEN space:
/// x,y in [0,1], origin top-left, y increases downward.
public struct JointPoint: Equatable {
    public let position: CGPoint
    public let confidence: Float
    public init(position: CGPoint, confidence: Float) {
        self.position = position
        self.confidence = confidence
    }
}

public struct Skeleton: Equatable {
    public let joints: [BodyJoint: JointPoint]
    public init(joints: [BodyJoint: JointPoint]) { self.joints = joints }

    public func point(_ j: BodyJoint) -> JointPoint? { joints[j] }

    /// Horizontal center of the subject: mid-shoulders, else mid-hips, else nil.
    public func centerX() -> CGFloat? {
        if let l = joints[.leftShoulder], let r = joints[.rightShoulder] {
            return (l.position.x + r.position.x) / 2
        }
        if let l = joints[.leftHip], let r = joints[.rightHip] {
            return (l.position.x + r.position.x) / 2
        }
        return nil
    }

    /// Top-most visible head/torso y (smaller = higher on screen): nose, else neck, else nil.
    public func topOfHeadY() -> CGFloat? {
        joints[.nose]?.position.y ?? joints[.neck]?.position.y
    }
}

public struct Hint: Equatable {
    public enum Kind: Equatable { case composition, pose }
    public enum Severity: Equatable { case info, warn }
    public let kind: Kind
    public let severity: Severity
    public let text: String
    /// Stable identifier for testing / dedup, e.g. "tilt.level".
    public let code: String
    public init(kind: Kind, severity: Severity, text: String, code: String) {
        self.kind = kind; self.severity = severity; self.text = text; self.code = code
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PosingTypesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PosingTypes.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PosingTypesTests.swift
git commit -m "feat(posing): core Skeleton/Hint types"
```

---

## Task 3: `CompositionEngine` skeleton + tilt rule

**Files:**
- Create: `Sources/JarvisApp/PosingCoach/CompositionEngine.swift`
- Test: `Sources/JarvisAppTests/CompositionEngineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Sources/JarvisAppTests/CompositionEngineTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class CompositionEngineTests: XCTestCase {
    private func frame(tilt: Double = 0) -> FrameInfo {
        FrameInfo(size: CGSize(width: 390, height: 844), tiltDegrees: tilt)
    }

    func test_tilt_beyond_threshold_warns() {
        let hints = CompositionEngine.hints(skeleton: Skeleton(joints: [:]), frame: frame(tilt: 10))
        XCTAssertTrue(hints.contains { $0.code == "tilt.level" })
    }

    func test_small_tilt_no_hint() {
        let hints = CompositionEngine.hints(skeleton: Skeleton(joints: [:]), frame: frame(tilt: 2))
        XCTAssertFalse(hints.contains { $0.code == "tilt.level" })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:JarvisAppTests/CompositionEngineTests`
Expected: FAIL — `cannot find 'FrameInfo' / 'CompositionEngine' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/JarvisApp/PosingCoach/CompositionEngine.swift
import CoreGraphics

/// Frame-level context for composition rules.
public struct FrameInfo: Equatable {
    public let size: CGSize
    /// Device roll relative to horizontal, degrees. + = tilted, sign-agnostic here.
    public let tiltDegrees: Double
    public init(size: CGSize, tiltDegrees: Double) {
        self.size = size; self.tiltDegrees = tiltDegrees
    }
}

/// Pure: skeleton (screen space) + frame → composition hints. No I/O, fully testable.
public enum CompositionEngine {
    static let tiltThresholdDegrees = 4.0

    public static func hints(skeleton: Skeleton, frame: FrameInfo) -> [Hint] {
        var out: [Hint] = []
        if let h = tiltHint(frame) { out.append(h) }
        return out
    }

    static func tiltHint(_ frame: FrameInfo) -> Hint? {
        guard abs(frame.tiltDegrees) > tiltThresholdDegrees else { return nil }
        return Hint(kind: .composition, severity: .warn,
                    text: "Выровняй горизонт", code: "tilt.level")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test … -only-testing:JarvisAppTests/CompositionEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/CompositionEngine.swift \
        ios/JarvisApp/Sources/JarvisAppTests/CompositionEngineTests.swift
git commit -m "feat(posing): CompositionEngine + tilt rule"
```

---

## Task 4: Head-room rule

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/CompositionEngine.swift`
- Modify: `Sources/JarvisAppTests/CompositionEngineTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `CompositionEngineTests`:
```swift
    private func skeleton(noseY: CGFloat) -> Skeleton {
        Skeleton(joints: [.nose: JointPoint(position: CGPoint(x: 0.5, y: noseY), confidence: 0.9)])
    }

    func test_headroom_too_tight_warns() {
        let hints = CompositionEngine.hints(skeleton: skeleton(noseY: 0.02), frame: frame())
        XCTAssertTrue(hints.contains { $0.code == "headroom.tight" })
    }

    func test_headroom_too_loose_infos() {
        let hints = CompositionEngine.hints(skeleton: skeleton(noseY: 0.30), frame: frame())
        XCTAssertTrue(hints.contains { $0.code == "headroom.loose" })
    }

    func test_headroom_ok_no_hint() {
        let hints = CompositionEngine.hints(skeleton: skeleton(noseY: 0.12), frame: frame())
        XCTAssertFalse(hints.contains { $0.code.hasPrefix("headroom") })
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/CompositionEngineTests`
Expected: FAIL — new tests fail (no headroom hints produced yet).

- [ ] **Step 3: Implement the rule**

In `CompositionEngine`, add to `hints(...)` after the tilt line:
```swift
        if let h = headroomHint(skeleton) { out.append(h) }
```
Add the method:
```swift
    static let headroomTight = 0.05
    static let headroomLoose = 0.22

    static func headroomHint(_ s: Skeleton) -> Hint? {
        guard let top = s.topOfHeadY() else { return nil }
        if top < headroomTight {
            return Hint(kind: .composition, severity: .warn,
                        text: "Мало места над головой — приподними камеру",
                        code: "headroom.tight")
        }
        if top > headroomLoose {
            return Hint(kind: .composition, severity: .info,
                        text: "Много пустоты сверху — опусти камеру",
                        code: "headroom.loose")
        }
        return nil
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/CompositionEngineTests`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/CompositionEngine.swift \
        ios/JarvisApp/Sources/JarvisAppTests/CompositionEngineTests.swift
git commit -m "feat(posing): head-room composition rule"
```

---

## Task 5: Joint-cropping rule

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/CompositionEngine.swift`
- Modify: `Sources/JarvisAppTests/CompositionEngineTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `CompositionEngineTests`:
```swift
    func test_knees_visible_ankles_missing_warns_crop() {
        let s = Skeleton(joints: [
            .leftKnee: JointPoint(position: CGPoint(x: 0.45, y: 0.8), confidence: 0.8),
            .rightKnee: JointPoint(position: CGPoint(x: 0.55, y: 0.8), confidence: 0.8),
        ])
        let hints = CompositionEngine.hints(skeleton: s, frame: frame())
        XCTAssertTrue(hints.contains { $0.code == "crop.ankle" })
    }

    func test_full_legs_visible_no_crop_hint() {
        let s = Skeleton(joints: [
            .leftKnee: JointPoint(position: CGPoint(x: 0.45, y: 0.7), confidence: 0.8),
            .rightKnee: JointPoint(position: CGPoint(x: 0.55, y: 0.7), confidence: 0.8),
            .leftAnkle: JointPoint(position: CGPoint(x: 0.45, y: 0.9), confidence: 0.8),
            .rightAnkle: JointPoint(position: CGPoint(x: 0.55, y: 0.9), confidence: 0.8),
        ])
        let hints = CompositionEngine.hints(skeleton: s, frame: frame())
        XCTAssertFalse(hints.contains { $0.code == "crop.ankle" })
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/CompositionEngineTests`
Expected: FAIL — `crop.ankle` not produced.

- [ ] **Step 3: Implement the rule**

In `hints(...)` add:
```swift
        out.append(contentsOf: cropHints(skeleton))
```
Add:
```swift
    static func cropHints(_ s: Skeleton) -> [Hint] {
        var out: [Hint] = []
        let kneesVisible = s.point(.leftKnee) != nil || s.point(.rightKnee) != nil
        let anklesVisible = s.point(.leftAnkle) != nil || s.point(.rightAnkle) != nil
        if kneesVisible && !anklesVisible {
            out.append(Hint(kind: .composition, severity: .warn,
                            text: "Не режь по щиколотке — влезь целиком или кадрируй выше колена",
                            code: "crop.ankle"))
        }
        return out
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/CompositionEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/CompositionEngine.swift \
        ios/JarvisApp/Sources/JarvisAppTests/CompositionEngineTests.swift
git commit -m "feat(posing): joint-cropping composition rule"
```

---

## Task 6: Rule-of-thirds placement rule

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/CompositionEngine.swift`
- Modify: `Sources/JarvisAppTests/CompositionEngineTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `CompositionEngineTests`:
```swift
    private func shoulders(centerX: CGFloat) -> Skeleton {
        Skeleton(joints: [
            .leftShoulder: JointPoint(position: CGPoint(x: centerX - 0.05, y: 0.3), confidence: 0.9),
            .rightShoulder: JointPoint(position: CGPoint(x: centerX + 0.05, y: 0.3), confidence: 0.9),
            .nose: JointPoint(position: CGPoint(x: centerX, y: 0.15), confidence: 0.9),
        ])
    }

    func test_dead_center_subject_nudged_to_third() {
        let hints = CompositionEngine.hints(skeleton: shoulders(centerX: 0.5), frame: frame())
        XCTAssertTrue(hints.contains { $0.code == "thirds.center" })
    }

    func test_subject_on_third_no_nudge() {
        let hints = CompositionEngine.hints(skeleton: shoulders(centerX: 1.0/3), frame: frame())
        XCTAssertFalse(hints.contains { $0.code == "thirds.center" })
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/CompositionEngineTests`
Expected: FAIL — `thirds.center` not produced.

- [ ] **Step 3: Implement the rule**

In `hints(...)` add:
```swift
        if let h = thirdsHint(skeleton) { out.append(h) }
```
Add:
```swift
    static let centerBand = 0.06      // how close to 0.5 counts as "dead center"
    static let thirdClearance = 0.10  // must be this far from a third line to bother nudging

    static func thirdsHint(_ s: Skeleton) -> Hint? {
        guard let cx = s.centerX() else { return nil }
        let nearestThird = min(abs(cx - 1.0/3), abs(cx - 2.0/3))
        let toCenter = abs(cx - 0.5)
        if toCenter < centerBand && nearestThird > thirdClearance {
            return Hint(kind: .composition, severity: .info,
                        text: "Поставь модель на линию трети",
                        code: "thirds.center")
        }
        return nil
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/CompositionEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/CompositionEngine.swift \
        ios/JarvisApp/Sources/JarvisAppTests/CompositionEngineTests.swift
git commit -m "feat(posing): rule-of-thirds placement rule"
```

---

## Task 7: Hint smoothing (anti-jitter)

> Frame-to-frame the engine may flicker hints on/off at threshold boundaries. `HintStabilizer` only surfaces a hint after it has been present for N consecutive frames, and only drops it after N absent frames. Pure and testable.

**Files:**
- Create: `Sources/JarvisApp/PosingCoach/HintStabilizer.swift`
- Test: `Sources/JarvisAppTests/HintStabilizerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Sources/JarvisAppTests/HintStabilizerTests.swift
import XCTest
@testable import Jarvis

final class HintStabilizerTests: XCTestCase {
    private func hint(_ code: String) -> Hint {
        Hint(kind: .composition, severity: .info, text: code, code: code)
    }

    func test_hint_appears_only_after_threshold_frames() {
        let s = HintStabilizer(appearFrames: 3, disappearFrames: 3)
        XCTAssertTrue(s.step([hint("a")]).isEmpty)   // frame 1
        XCTAssertTrue(s.step([hint("a")]).isEmpty)   // frame 2
        XCTAssertEqual(s.step([hint("a")]).map(\.code), ["a"]) // frame 3 → shown
    }

    func test_hint_persists_through_brief_dropout() {
        let s = HintStabilizer(appearFrames: 1, disappearFrames: 3)
        _ = s.step([hint("a")])                       // shown immediately
        XCTAssertEqual(s.step([]).map(\.code), ["a"]) // 1 missing frame → still shown
        XCTAssertEqual(s.step([]).map(\.code), ["a"]) // 2 missing → still shown
        XCTAssertTrue(s.step([]).isEmpty)             // 3 missing → dropped
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/HintStabilizerTests`
Expected: FAIL — `cannot find 'HintStabilizer' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/JarvisApp/PosingCoach/HintStabilizer.swift

/// Debounces hint appearance/disappearance across frames to stop UI flicker.
public final class HintStabilizer {
    private let appearFrames: Int
    private let disappearFrames: Int
    private var presentStreak: [String: Int] = [:]   // code → consecutive present frames
    private var absentStreak: [String: Int] = [:]    // code → consecutive absent frames
    private var shown: [String: Hint] = [:]          // currently surfaced

    public init(appearFrames: Int = 4, disappearFrames: Int = 6) {
        self.appearFrames = appearFrames
        self.disappearFrames = disappearFrames
    }

    /// Feed this frame's raw hints; get the stabilized set to render.
    public func step(_ raw: [Hint]) -> [Hint] {
        let codes = Set(raw.map(\.code))
        let byCode = Dictionary(raw.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })

        for h in raw {
            presentStreak[h.code, default: 0] += 1
            absentStreak[h.code] = 0
            if presentStreak[h.code]! >= appearFrames { shown[h.code] = h }
        }
        for code in Array(shown.keys) where !codes.contains(code) {
            absentStreak[code, default: 0] += 1
            presentStreak[code] = 0
            if absentStreak[code]! >= disappearFrames { shown[code] = nil }
        }
        // Keep shown hints fresh with their latest text when still present.
        for (code, h) in byCode where shown[code] != nil { shown[code] = h }
        // Stable order: warnings before infos, then by code.
        return shown.values.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity == .warn }
            return lhs.code < rhs.code
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/HintStabilizerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/HintStabilizer.swift \
        ios/JarvisApp/Sources/JarvisAppTests/HintStabilizerTests.swift
git commit -m "feat(posing): HintStabilizer anti-jitter debounce"
```

---

## Task 8: `PoseDetector` — Vision joint mapping + detect wrapper

> The pure part is the Vision→`BodyJoint` name mapping (unit-tested). The `detect(pixelBuffer:)` path needs a real frame and is verified in Task 1 / manual device runs.

**Files:**
- Create: `Sources/JarvisApp/PosingCoach/PoseDetector.swift`
- Test: `Sources/JarvisAppTests/PoseDetectorMappingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Sources/JarvisAppTests/PoseDetectorMappingTests.swift
import XCTest
import Vision
@testable import Jarvis

final class PoseDetectorMappingTests: XCTestCase {
    func test_maps_known_vision_joints() {
        XCTAssertEqual(PoseDetector.map(.nose), .nose)
        XCTAssertEqual(PoseDetector.map(.leftShoulder), .leftShoulder)
        XCTAssertEqual(PoseDetector.map(.rightAnkle), .rightAnkle)
    }

    func test_flips_y_from_vision_to_screen_space() {
        // Vision origin bottom-left (y up); screen origin top-left (y down).
        let p = PoseDetector.toScreen(CGPoint(x: 0.3, y: 0.8))
        XCTAssertEqual(p.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(p.y, 0.2, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseDetectorMappingTests`
Expected: FAIL — `type 'PoseDetector' has no member 'map'`.

- [ ] **Step 3: Implement**

```swift
// Sources/JarvisApp/PosingCoach/PoseDetector.swift
import Vision
import CoreGraphics
import CoreVideo

public enum PoseDetector {
    /// Map Vision joint names to our BodyJoint. Returns nil for joints we ignore.
    public static func map(_ name: VNHumanBodyPoseObservation.JointName) -> BodyJoint? {
        switch name {
        case .nose: return .nose
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        case .root: return .root
        default: return nil
        }
    }

    /// Vision normalized (origin bottom-left, y up) → screen normalized (top-left, y down).
    public static func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }

    static let minConfidence: Float = 0.3

    /// Run body-pose detection on a camera frame. Nil if no body found.
    public static func detect(pixelBuffer: CVPixelBuffer,
                              orientation: CGImagePropertyOrientation = .up) throws -> Skeleton? {
        let req = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([req])
        guard let obs = req.results?.first else { return nil }
        var joints: [BodyJoint: JointPoint] = [:]
        for (name, point) in (try? obs.recognizedPoints(.all)) ?? [:] {
            guard point.confidence >= minConfidence, let j = map(name) else { continue }
            joints[j] = JointPoint(position: toScreen(point.location), confidence: point.confidence)
        }
        return joints.isEmpty ? nil : Skeleton(joints: joints)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseDetectorMappingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseDetector.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseDetectorMappingTests.swift
git commit -m "feat(posing): PoseDetector Vision mapping + detect wrapper"
```

---

## Task 9: `CameraSession` + `TiltProvider` (device-bound, manual verify)

> AVFoundation + CoreMotion plumbing. Not unit-tested (needs hardware); verified when the screen runs in Task 10 on a device.

**Files:**
- Create: `Sources/JarvisApp/PosingCoach/CameraSession.swift`
- Create: `Sources/JarvisApp/PosingCoach/TiltProvider.swift`

- [ ] **Step 1: Implement CameraSession**

```swift
// Sources/JarvisApp/PosingCoach/CameraSession.swift
import AVFoundation
import CoreVideo

/// Owns the capture session and vends latest detected Skeleton on the main actor.
@MainActor
public final class CameraSession: NSObject, ObservableObject {
    @Published public private(set) var skeleton: Skeleton?
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posing.camera")
    private var configured = false

    public func start() {
        configureIfNeeded()
        let s = session
        queue.async { if !s.isRunning { s.startRunning() } }
    }

    public func stop() {
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .high
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
        }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    public nonisolated func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let detected = try? PoseDetector.detect(pixelBuffer: pb, orientation: .right)
        Task { @MainActor [weak self] in self?.skeleton = detected }
    }
}
```

- [ ] **Step 2: Implement TiltProvider**

```swift
// Sources/JarvisApp/PosingCoach/TiltProvider.swift
import CoreMotion
import Foundation

/// Publishes device roll (degrees from horizontal) for the tilt composition rule.
@MainActor
public final class TiltProvider: ObservableObject {
    @Published public private(set) var tiltDegrees: Double = 0
    private let motion = CMMotionManager()

    public func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            // Roll around the vertical shooting axis: 0 when upright portrait.
            self?.tiltDegrees = atan2(g.x, -g.y) * 180 / .pi
        }
    }

    public func stop() { motion.stopDeviceMotionUpdates() }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/CameraSession.swift \
        ios/JarvisApp/Sources/JarvisApp/PosingCoach/TiltProvider.swift
git commit -m "feat(posing): CameraSession + TiltProvider"
```

---

## Task 10: `PosingCoachScreen` — camera preview + overlay

**Files:**
- Create: `Sources/JarvisApp/PosingCoach/CameraPreviewView.swift`
- Create: `Sources/JarvisApp/PosingCoach/PosingOverlay.swift`
- Create: `Sources/JarvisApp/PosingCoach/PosingCoachScreen.swift`

- [ ] **Step 1: Camera preview UIViewRepresentable**

```swift
// Sources/JarvisApp/PosingCoach/CameraPreviewView.swift
import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
```

- [ ] **Step 2: Overlay (thirds grid + hint chips)**

```swift
// Sources/JarvisApp/PosingCoach/PosingOverlay.swift
import SwiftUI

struct PosingOverlay: View {
    let hints: [Hint]

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Path { p in
                    let w = geo.size.width, h = geo.size.height
                    for f in [1.0/3, 2.0/3] {
                        p.move(to: CGPoint(x: w*f, y: 0)); p.addLine(to: CGPoint(x: w*f, y: h))
                        p.move(to: CGPoint(x: 0, y: h*f)); p.addLine(to: CGPoint(x: w, y: h*f))
                    }
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
            }
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    ForEach(hints, id: \.code) { hint in
                        Text(hint.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(hint.severity == .warn ? Color(red: 1, green: 0.72, blue: 0.3)
                                                               : Color(red: 0.24, green: 0.86, blue: 0.52),
                                        in: Capsule())
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .allowsHitTesting(false)
    }
}
```

- [ ] **Step 3: Screen wiring the pipeline together**

```swift
// Sources/JarvisApp/PosingCoach/PosingCoachScreen.swift
import SwiftUI

public struct PosingCoachScreen: View {
    @StateObject private var camera = CameraSession()
    @StateObject private var tilt = TiltProvider()
    @Environment(\.dismiss) private var dismiss
    private let stabilizer = HintStabilizer()
    @State private var hints: [Hint] = []

    public init() {}

    public var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session).ignoresSafeArea()
            PosingOverlay(hints: hints).ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title).foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
        .onAppear { camera.start(); tilt.start() }
        .onDisappear { camera.stop(); tilt.stop() }
        .onReceive(camera.$skeleton) { recompute(skeleton: $0) }
        .onReceive(tilt.$tiltDegrees) { _ in recompute(skeleton: camera.skeleton) }
    }

    private func recompute(skeleton: Skeleton?) {
        let frame = FrameInfo(size: UIScreen.main.bounds.size, tiltDegrees: tilt.tiltDegrees)
        let raw = skeleton.map { CompositionEngine.hints(skeleton: $0, frame: frame) } ?? []
        hints = stabilizer.step(raw)
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/CameraPreviewView.swift \
        ios/JarvisApp/Sources/JarvisApp/PosingCoach/PosingOverlay.swift \
        ios/JarvisApp/Sources/JarvisApp/PosingCoach/PosingCoachScreen.swift
git commit -m "feat(posing): PosingCoachScreen preview + overlay"
```

---

## Task 11: Entry point in Settings + camera-permission wording + version bump

**Files:**
- Modify: `Sources/JarvisApp/Views/SettingsView.swift` (add a section+button in `SettingsFormBody`)
- Modify: `project.yml` (`NSCameraUsageDescription`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`)

- [ ] **Step 1: Add a presented state + section to `SettingsFormBody`**

In `SettingsFormBody`, add a state var near the other `@State`s:
```swift
    @State private var showPosingCoach = false
```
Add a new section inside `body`, alongside the existing `settingsSection(...)` calls (e.g. right after the "Агент" section at line ~37):
```swift
                settingsSection(title: "Съёмка") {
                    Button {
                        showPosingCoach = true
                    } label: {
                        Label("Помощник по позированию", systemImage: "camera.viewfinder")
                    }
                }
```
Attach the cover to the outermost container returned by `body` (the same view the sections live in):
```swift
                .fullScreenCover(isPresented: $showPosingCoach) {
                    PosingCoachScreen()
                }
```

- [ ] **Step 2: Update camera-permission wording**

In `project.yml`, change the existing key (line ~51):
```yaml
        NSCameraUsageDescription: "Камера нужна для съёмки, вложений и подсказок по позированию"
```

- [ ] **Step 3: Bump versions**

In `project.yml` (lines ~75-76):
```yaml
        MARKETING_VERSION: "1.20.0"
        CURRENT_PROJECT_VERSION: "80"
```

- [ ] **Step 4: Regenerate and build**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit (include regenerated pbxproj)**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift \
        ios/JarvisApp/project.yml \
        ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "feat(posing): Settings entry point + camera string + v1.20.0 (build 80)"
```

---

## Task 12: Full test + build sweep, then manual device pass

**Files:** none (verification only)

- [ ] **Step 1: Run the whole test suite**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`, including `PosingTypesTests`, `CompositionEngineTests`, `HintStabilizerTests`, `PoseDetectorMappingTests`, and all pre-existing suites still green.

- [ ] **Step 2: Manual device pass (per project rule — runtime feel can't be unit-tested)**

Install on a physical iPhone. Open Settings → «Съёмка» → «Помощник по позированию». Point at a person and confirm:
- thirds grid draws;
- tilting the phone surfaces «Выровняй горизонт»;
- framing so the person's head hugs the top surfaces «Мало места над головой»;
- cropping at the shins surfaces «Не режь по щиколотке»;
- hints don't flicker rapidly (stabilizer working);
- no obvious frame-rate stutter.

- [ ] **Step 3: Record outcome**

Note device model + observations. No commit unless a fix is needed (then loop back to the relevant task).

---

## Notes for the next plan (Phase 2 — out of scope here)

Pose-library / ghost-silhouette coaching gets its own spec-driven plan: `PoseLibrary` (bundled JSON of curated good-pose skeletons), `PoseMatcher` (normalize + nearest-template by joint-angle distance), ghost-silhouette rendering anchored to the subject, and text deltas. It reuses `Skeleton`, `Hint`, `PoseDetector`, `CameraSession`, and `PosingOverlay` from this plan unchanged.
