# Posing Coach Phase 2 — Pose Coaching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add toggleable real-time pose coaching to `PosingCoachScreen` — encode 6 female-posing heuristics as pure rules over the live 2D skeleton, and surface them as text nudges + a ghost skeleton ("stand like this") + arrows.

**Architecture:** Reuse the entire Phase-1 pipeline (`CameraSession`→`PoseDetector`→`Skeleton`, `HintStabilizer`, `PosingOverlay`). New pure logic: `PoseRule` structs (A–F) → `PoseCoach` aggregates the top-2 by priority into a `PoseGuidance {hints, ghost, arrows}`; the ghost is the current skeleton with each rule's target joint positions applied. The overlay draws the ghost + arrows; the screen gains a "Поза" toggle. All on-device, offline.

**Tech Stack:** Swift, SwiftUI, CoreGraphics. Built via xcodegen + xcodebuild. Tests via XCTest (`@testable import Jarvis`).

**Design spec:** [docs/superpowers/specs/2026-07-04-posing-coach-phase2-pose-coaching-design.md](../specs/2026-07-04-posing-coach-phase2-pose-coaching-design.md)

---

## Codebase Notes (read before starting)

- App module is **`Jarvis`** (tests `@testable import Jarvis`, never `import JarvisApp`). Feature files under `ios/JarvisApp/Sources/JarvisApp/PosingCoach/`; tests under `ios/JarvisApp/Sources/JarvisAppTests/`. xcodegen auto-includes new files after `xcodegen generate` — no manual `.pbxproj` edits for sources.
- **Coordinate convention** (from Phase 1): all `Skeleton` positions are normalized **screen space** — x,y ∈ [0,1], origin top-left, y down. All rule geometry and target deltas are in this space. Tests build `Skeleton` values directly — no camera/Vision needed.
- **Existing types you build on** (already in `PosingTypes.swift`): `BodyJoint` (enum: nose, neck, leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle, root), `JointPoint {position: CGPoint, confidence: Float}`, `Skeleton {joints: [BodyJoint: JointPoint]; point(_:), centerX(), topOfHeadY()}`, `Hint {kind: .composition|.pose, severity: .info|.warn, text, code}`. `Hint.Kind.pose` already exists.
- **Version bump mandatory** (project rule): this is a feature → `MARKETING_VERSION` 1.20.0 → **1.21.0**, `CURRENT_PROJECT_VERSION` 88 → **89** in `project.yml`, then `xcodegen generate`, commit the regenerated pbxproj + Info.plist.
- **Deferred from the spec's 8 rules:** rule **G (chin.neck)** and **H (camera.above)** are NOT in this plan — G needs an unreliable 2D chin proxy, H needs device-pitch plumbing; both are the spec's "gentle/low-priority" rules. They are the first follow-ups. This plan ships the 6 reliable body rules A–F.

### Build & test commands (from `ios/JarvisApp/`)

Run one test class:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:JarvisAppTests/PoseRulesTests 2>&1 | tail -30
```
(If `iPhone 17 Pro` isn't available, `xcrun simctl list devices available` and substitute a booted iOS sim.)

Whole-app build (no install):
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```

---

## Task 1: Pose types + geometry helpers

**Files:**
- Create: `Sources/JarvisApp/PosingCoach/PoseCoaching.swift`
- Create: `Sources/JarvisApp/PosingCoach/PoseGeometry.swift`
- Test: `Sources/JarvisAppTests/PoseGeometryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Sources/JarvisAppTests/PoseGeometryTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class PoseGeometryTests: XCTestCase {
    func test_angle_straight_line_is_180() {
        let a = CGPoint(x: 0, y: 0), v = CGPoint(x: 0, y: 1), b = CGPoint(x: 0, y: 2)
        XCTAssertEqual(PoseGeometry.angle(a, v, b), 180, accuracy: 0.5)
    }
    func test_angle_right_angle_is_90() {
        let a = CGPoint(x: 1, y: 0), v = CGPoint(x: 0, y: 0), b = CGPoint(x: 0, y: 1)
        XCTAssertEqual(PoseGeometry.angle(a, v, b), 90, accuracy: 0.5)
    }
    func test_midpoint() {
        let m = PoseGeometry.midpoint(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        XCTAssertEqual(m.x, 0.5, accuracy: 0.0001); XCTAssertEqual(m.y, 0.5, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseGeometryTests`
Expected: FAIL — `cannot find 'PoseGeometry' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/JarvisApp/PosingCoach/PoseGeometry.swift
import CoreGraphics
import Foundation

enum PoseGeometry {
    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
    /// Interior angle at `vertex` between vertex→a and vertex→b, degrees in [0, 180].
    static func angle(_ a: CGPoint, _ vertex: CGPoint, _ b: CGPoint) -> CGFloat {
        let v1 = CGVector(dx: a.x - vertex.x, dy: a.y - vertex.y)
        let v2 = CGVector(dx: b.x - vertex.x, dy: b.y - vertex.y)
        let dot = v1.dx * v2.dx + v1.dy * v2.dy
        let m1 = hypot(v1.dx, v1.dy), m2 = hypot(v2.dx, v2.dy)
        guard m1 > 0, m2 > 0 else { return 180 }
        let cos = max(-1, min(1, dot / (m1 * m2)))
        return acos(cos) * 180 / .pi
    }
}
```

```swift
// Sources/JarvisApp/PosingCoach/PoseCoaching.swift
import CoreGraphics

/// One pose correction a rule wants to make.
public struct PoseSuggestion: Equatable {
    public let code: String
    public let text: String
    /// Lower = higher priority (surfaced first).
    public let priority: Int
    /// Absolute target positions (screen space) for the joints this rule moves.
    public let targetDeltas: [BodyJoint: CGPoint]
    /// Joints that changed — arrows are drawn current → target for these.
    public let changedJoints: [BodyJoint]
    public init(code: String, text: String, priority: Int,
                targetDeltas: [BodyJoint: CGPoint], changedJoints: [BodyJoint]) {
        self.code = code; self.text = text; self.priority = priority
        self.targetDeltas = targetDeltas; self.changedJoints = changedJoints
    }
}

/// A pure posing heuristic over a 2D skeleton. Returns nil when it doesn't apply
/// or its required joints aren't present (detector already confidence-filters).
public protocol PoseRule {
    func evaluate(_ s: Skeleton) -> PoseSuggestion?
}

/// Aggregated coaching output for one frame.
public struct PoseGuidance {
    public let hints: [Hint]
    public let ghost: Skeleton?
    public let arrows: [(CGPoint, CGPoint)]
    public init(hints: [Hint], ghost: Skeleton?, arrows: [(CGPoint, CGPoint)]) {
        self.hints = hints; self.ghost = ghost; self.arrows = arrows
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseGeometryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseGeometry.swift \
        ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseCoaching.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseGeometryTests.swift
git commit -m "feat(posing): pose-coaching types + geometry helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Rule A — weight.shift (+ shared test helpers)

**Files:**
- Create: `Sources/JarvisApp/PosingCoach/PoseRules.swift`
- Test: `Sources/JarvisAppTests/PoseRulesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Sources/JarvisAppTests/PoseRulesTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class PoseRulesTests: XCTestCase {
    // A symmetric, straight, front-facing standing skeleton (screen space, y down).
    static func standingStraight() -> Skeleton {
        func p(_ x: CGFloat, _ y: CGFloat) -> JointPoint {
            JointPoint(position: CGPoint(x: x, y: y), confidence: 0.9)
        }
        return Skeleton(joints: [
            .nose: p(0.50, 0.12),
            .leftShoulder: p(0.42, 0.24), .rightShoulder: p(0.58, 0.24),
            .leftElbow: p(0.36, 0.40), .rightElbow: p(0.64, 0.40),
            .leftWrist: p(0.30, 0.54), .rightWrist: p(0.70, 0.54),  // arms out & diagonal (neutral)
            .leftHip: p(0.45, 0.55), .rightHip: p(0.55, 0.55),
            .leftKnee: p(0.45, 0.75), .rightKnee: p(0.55, 0.75),
            .leftAnkle: p(0.45, 0.94), .rightAnkle: p(0.55, 0.94),
        ])
    }

    func test_weightShift_fires_on_symmetric_straight_stance() {
        let sug = WeightShiftRule().evaluate(Self.standingStraight())
        XCTAssertEqual(sug?.code, "weight.shift")
        // hips get tilted: one hip target moves down, the other up.
        XCTAssertNotEqual(sug?.targetDeltas[.leftHip]?.y, sug?.targetDeltas[.rightHip]?.y)
    }

    func test_weightShift_silent_when_hips_already_tilted() {
        var joints = Self.standingStraight().joints
        joints[.rightHip] = JointPoint(position: CGPoint(x: 0.55, y: 0.50), confidence: 0.9) // raised
        XCTAssertNil(WeightShiftRule().evaluate(Skeleton(joints: joints)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: FAIL — `cannot find 'WeightShiftRule' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/JarvisApp/PosingCoach/PoseRules.swift
import CoreGraphics

// Shared thresholds (normalized screen space).
private let levelTol: CGFloat = 0.03      // "level" y-difference
private let straightAngle: CGFloat = 165  // knee/elbow angle counted as straight (deg)

/// A: legs straight + hips level → shift weight to the far leg (creates the S-curve).
public struct WeightShiftRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let lh = s.point(.leftHip)?.position, let rh = s.point(.rightHip)?.position,
              let lk = s.point(.leftKnee)?.position, let rk = s.point(.rightKnee)?.position,
              let la = s.point(.leftAnkle)?.position, let ra = s.point(.rightAnkle)?.position,
              let ls = s.point(.leftShoulder)?.position, let rs = s.point(.rightShoulder)?.position
        else { return nil }
        let hipsLevel = abs(lh.y - rh.y) < levelTol
        let legsStraight = PoseGeometry.angle(lh, lk, la) > straightAngle
            && PoseGeometry.angle(rh, rk, ra) > straightAngle
        guard hipsLevel && legsStraight else { return nil }
        let tilt: CGFloat = 0.04
        let deltas: [BodyJoint: CGPoint] = [
            .leftHip: CGPoint(x: lh.x, y: lh.y + tilt),
            .rightHip: CGPoint(x: rh.x, y: rh.y - tilt),
            .leftShoulder: CGPoint(x: ls.x, y: ls.y - tilt * 0.5),
            .rightShoulder: CGPoint(x: rs.x, y: rs.y + tilt * 0.5),
        ]
        return PoseSuggestion(code: "weight.shift", text: "Перенеси вес на дальнюю ногу",
                              priority: 0, targetDeltas: deltas,
                              changedJoints: [.leftHip, .rightHip, .leftShoulder, .rightShoulder])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseRules.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseRulesTests.swift
git commit -m "feat(posing): rule A weight.shift

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Rule B — knee.bend

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/PoseRules.swift`
- Modify: `Sources/JarvisAppTests/PoseRulesTests.swift`

- [ ] **Step 1: Add failing test**

Append to `PoseRulesTests`:
```swift
    func test_kneeBend_fires_when_both_legs_straight() {
        let sug = KneeBendRule().evaluate(Self.standingStraight())
        XCTAssertEqual(sug?.code, "knee.bend")
        XCTAssertNotNil(sug?.targetDeltas[.leftKnee])
    }

    func test_kneeBend_silent_when_a_knee_already_bent() {
        var joints = Self.standingStraight().joints
        joints[.leftKnee] = JointPoint(position: CGPoint(x: 0.38, y: 0.74), confidence: 0.9) // bent in
        XCTAssertNil(KneeBendRule().evaluate(Skeleton(joints: joints)))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: FAIL — `cannot find 'KneeBendRule'`.

- [ ] **Step 3: Implement**

Append to `PoseRules.swift`:
```swift
/// B: both legs straight → bend the near (model's-left) knee. Pairs with A.
public struct KneeBendRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let lh = s.point(.leftHip)?.position, let rh = s.point(.rightHip)?.position,
              let lk = s.point(.leftKnee)?.position, let rk = s.point(.rightKnee)?.position,
              let la = s.point(.leftAnkle)?.position, let ra = s.point(.rightAnkle)?.position
        else { return nil }
        let legsStraight = PoseGeometry.angle(lh, lk, la) > straightAngle
            && PoseGeometry.angle(rh, rk, ra) > straightAngle
        guard legsStraight else { return nil }
        let hipsMidX = (lh.x + rh.x) / 2
        // Push the near knee toward center + slightly up → a soft bend.
        let target = CGPoint(x: lk.x + (hipsMidX - lk.x) * 0.4, y: lk.y - 0.02)
        return PoseSuggestion(code: "knee.bend", text: "Согни ближнее колено",
                              priority: 1, targetDeltas: [.leftKnee: target],
                              changedJoints: [.leftKnee])
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseRules.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseRulesTests.swift
git commit -m "feat(posing): rule B knee.bend

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Rule C — feet.stagger

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/PoseRules.swift`
- Modify: `Sources/JarvisAppTests/PoseRulesTests.swift`

- [ ] **Step 1: Add failing test**

Append to `PoseRulesTests`:
```swift
    func test_feetStagger_fires_when_feet_side_by_side() {
        let sug = FeetStaggerRule().evaluate(Self.standingStraight())
        XCTAssertEqual(sug?.code, "feet.stagger")
    }

    func test_feetStagger_silent_when_feet_already_staggered() {
        var joints = Self.standingStraight().joints
        joints[.leftAnkle] = JointPoint(position: CGPoint(x: 0.40, y: 0.90), confidence: 0.9) // forward+up
        XCTAssertNil(FeetStaggerRule().evaluate(Skeleton(joints: joints)))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: FAIL — `cannot find 'FeetStaggerRule'`.

- [ ] **Step 3: Implement**

Append to `PoseRules.swift`:
```swift
/// C: ankles side by side (same level, close in x) → stagger one foot forward.
public struct FeetStaggerRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let la = s.point(.leftAnkle)?.position, let ra = s.point(.rightAnkle)?.position
        else { return nil }
        let sameLevel = abs(la.y - ra.y) < 0.02
        let close = abs(la.x - ra.x) < 0.12
        guard sameLevel && close else { return nil }
        let target = CGPoint(x: la.x - 0.04, y: la.y + 0.03) // forward + slightly lower
        return PoseSuggestion(code: "feet.stagger", text: "Одну ногу чуть вперёд",
                              priority: 2, targetDeltas: [.leftAnkle: target],
                              changedJoints: [.leftAnkle])
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseRules.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseRulesTests.swift
git commit -m "feat(posing): rule C feet.stagger

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Rule D — body.angle

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/PoseRules.swift`
- Modify: `Sources/JarvisAppTests/PoseRulesTests.swift`

- [ ] **Step 1: Add failing test**

Append to `PoseRulesTests`:
```swift
    func test_bodyAngle_fires_when_shoulders_square_and_wide() {
        let sug = BodyAngleRule().evaluate(Self.standingStraight())
        XCTAssertEqual(sug?.code, "body.angle")
        XCTAssertNotNil(sug?.targetDeltas[.rightShoulder])
    }

    func test_bodyAngle_silent_when_shoulders_narrow() {
        var joints = Self.standingStraight().joints
        joints[.leftShoulder] = JointPoint(position: CGPoint(x: 0.48, y: 0.24), confidence: 0.9)
        joints[.rightShoulder] = JointPoint(position: CGPoint(x: 0.52, y: 0.24), confidence: 0.9)
        XCTAssertNil(BodyAngleRule().evaluate(Skeleton(joints: joints)))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: FAIL — `cannot find 'BodyAngleRule'`.

- [ ] **Step 3: Implement**

Append to `PoseRules.swift`:
```swift
/// D: shoulders square to camera (wide + level) → turn to a 3/4 angle.
public struct BodyAngleRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        guard let ls = s.point(.leftShoulder)?.position, let rs = s.point(.rightShoulder)?.position,
              let lh = s.point(.leftHip)?.position, let rh = s.point(.rightHip)?.position
        else { return nil }
        let shoulderW = abs(ls.x - rs.x)
        let hipW = abs(lh.x - rh.x)
        let shouldersLevel = abs(ls.y - rs.y) < levelTol
        let torsoH = abs(PoseGeometry.midpoint(ls, rs).y - PoseGeometry.midpoint(lh, rh).y)
        let facingFront = shoulderW > max(hipW, torsoH * 0.5) && shouldersLevel
        guard facingFront else { return nil }
        let cx = PoseGeometry.midpoint(ls, rs).x
        // Narrow the shoulder line: pull the right shoulder toward center (and left a touch).
        let deltas: [BodyJoint: CGPoint] = [
            .rightShoulder: CGPoint(x: rs.x + (cx - rs.x) * 0.35, y: rs.y),
            .leftShoulder: CGPoint(x: ls.x + (cx - ls.x) * 0.15, y: ls.y),
        ]
        return PoseSuggestion(code: "body.angle", text: "Развернись на ¾ к камере",
                              priority: 3, targetDeltas: deltas,
                              changedJoints: [.rightShoulder, .leftShoulder])
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseRules.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseRulesTests.swift
git commit -m "feat(posing): rule D body.angle

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Rule E — arms.gap

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/PoseRules.swift`
- Modify: `Sources/JarvisAppTests/PoseRulesTests.swift`

- [ ] **Step 1: Add failing test**

Append to `PoseRulesTests`:
```swift
    func test_armsGap_fires_when_wrist_glued_to_hip() {
        var joints = Self.standingStraight().joints
        joints[.leftWrist] = JointPoint(position: CGPoint(x: 0.45, y: 0.56), confidence: 0.9) // at hip x
        let sug = ArmsGapRule().evaluate(Skeleton(joints: joints))
        XCTAssertEqual(sug?.code, "arms.gap")
    }

    func test_armsGap_silent_when_arms_already_out() {
        var joints = Self.standingStraight().joints
        joints[.leftWrist] = JointPoint(position: CGPoint(x: 0.30, y: 0.56), confidence: 0.9) // out
        joints[.rightWrist] = JointPoint(position: CGPoint(x: 0.70, y: 0.56), confidence: 0.9)
        XCTAssertNil(ArmsGapRule().evaluate(Skeleton(joints: joints)))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: FAIL — `cannot find 'ArmsGapRule'`.

- [ ] **Step 3: Implement**

Append to `PoseRules.swift`:
```swift
/// E: a wrist hugging the torso (near its hip's x) → create a gap / hand on hip.
public struct ArmsGapRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        let gap: CGFloat = 0.06
        if let lw = s.point(.leftWrist)?.position, let lh = s.point(.leftHip)?.position,
           abs(lw.x - lh.x) < gap {
            return PoseSuggestion(code: "arms.gap", text: "Оторви руки — рука на бедро или к ключице",
                                  priority: 4, targetDeltas: [.leftWrist: CGPoint(x: lw.x - 0.09, y: lw.y)],
                                  changedJoints: [.leftWrist])
        }
        if let rw = s.point(.rightWrist)?.position, let rh = s.point(.rightHip)?.position,
           abs(rw.x - rh.x) < gap {
            return PoseSuggestion(code: "arms.gap", text: "Оторви руки — рука на бедро или к ключице",
                                  priority: 4, targetDeltas: [.rightWrist: CGPoint(x: rw.x + 0.09, y: rw.y)],
                                  changedJoints: [.rightWrist])
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseRules.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseRulesTests.swift
git commit -m "feat(posing): rule E arms.gap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Rule F — elbow.bend

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/PoseRules.swift`
- Modify: `Sources/JarvisAppTests/PoseRulesTests.swift`

- [ ] **Step 1: Add failing test**

Append to `PoseRulesTests`:
```swift
    func test_elbowBend_fires_on_straight_vertical_arm() {
        var joints = Self.standingStraight().joints
        // left arm straight & vertical: shoulder, elbow, wrist all ~x=0.42
        joints[.leftShoulder] = JointPoint(position: CGPoint(x: 0.42, y: 0.24), confidence: 0.9)
        joints[.leftElbow] = JointPoint(position: CGPoint(x: 0.42, y: 0.40), confidence: 0.9)
        joints[.leftWrist] = JointPoint(position: CGPoint(x: 0.42, y: 0.56), confidence: 0.9)
        let sug = ElbowBendRule().evaluate(Skeleton(joints: joints))
        XCTAssertEqual(sug?.code, "elbow.bend")
    }

    func test_elbowBend_silent_when_elbow_bent_out() {
        var joints = Self.standingStraight().joints
        // Left arm vertical shoulder↔wrist but elbow kicked out → bent, must stay silent.
        // (Right arm in the fixture is diagonal, so it never fires.)
        joints[.leftShoulder] = JointPoint(position: CGPoint(x: 0.42, y: 0.24), confidence: 0.9)
        joints[.leftElbow] = JointPoint(position: CGPoint(x: 0.30, y: 0.40), confidence: 0.9)
        joints[.leftWrist] = JointPoint(position: CGPoint(x: 0.42, y: 0.56), confidence: 0.9)
        XCTAssertNil(ElbowBendRule().evaluate(Skeleton(joints: joints)))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: FAIL — `cannot find 'ElbowBendRule'`.

- [ ] **Step 3: Implement**

Append to `PoseRules.swift`:
```swift
/// F: a straight, near-vertical arm (shoulder-elbow-wrist in a line) → bend the elbow.
public struct ElbowBendRule: PoseRule {
    public init() {}
    public func evaluate(_ s: Skeleton) -> PoseSuggestion? {
        func straightVertical(_ sh: CGPoint, _ el: CGPoint, _ wr: CGPoint) -> Bool {
            PoseGeometry.angle(sh, el, wr) > straightAngle
                && abs(sh.x - wr.x) < 0.05 && wr.y > sh.y
        }
        if let sh = s.point(.leftShoulder)?.position, let el = s.point(.leftElbow)?.position,
           let wr = s.point(.leftWrist)?.position, straightVertical(sh, el, wr) {
            return PoseSuggestion(code: "elbow.bend", text: "Согни локоть, смени угол",
                                  priority: 5, targetDeltas: [.leftElbow: CGPoint(x: el.x - 0.06, y: el.y)],
                                  changedJoints: [.leftElbow])
        }
        if let sh = s.point(.rightShoulder)?.position, let el = s.point(.rightElbow)?.position,
           let wr = s.point(.rightWrist)?.position, straightVertical(sh, el, wr) {
            return PoseSuggestion(code: "elbow.bend", text: "Согни локоть, смени угол",
                                  priority: 5, targetDeltas: [.rightElbow: CGPoint(x: el.x + 0.06, y: el.y)],
                                  changedJoints: [.rightElbow])
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseRulesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseRules.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseRulesTests.swift
git commit -m "feat(posing): rule F elbow.bend

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: `PoseCoach` — gate, aggregate top-2, synthesize ghost

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/PoseCoaching.swift`
- Test: `Sources/JarvisAppTests/PoseCoachTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Sources/JarvisAppTests/PoseCoachTests.swift
import XCTest
import CoreGraphics
@testable import Jarvis

final class PoseCoachTests: XCTestCase {
    func test_guide_caps_at_two_hints_and_builds_ghost() {
        let g = PoseCoach.guide(PoseRulesTests.standingStraight())
        XCTAssertEqual(g.hints.count, 2)                 // top-2 by priority
        XCTAssertEqual(g.hints.first?.code, "weight.shift") // priority 0 wins
        XCTAssertTrue(g.hints.allSatisfy { $0.kind == .pose })
        XCTAssertNotNil(g.ghost)
        XCTAssertFalse(g.arrows.isEmpty)
    }

    func test_guide_empty_without_standing_body() {
        // Only a face — no hips/knees → not a standing body.
        let s = Skeleton(joints: [.nose: JointPoint(position: CGPoint(x: 0.5, y: 0.1), confidence: 0.9)])
        let g = PoseCoach.guide(s)
        XCTAssertTrue(g.hints.isEmpty)
        XCTAssertNil(g.ghost)
    }

    func test_applyDeltas_moves_only_targeted_joints() {
        let base = PoseRulesTests.standingStraight()
        let moved = PoseCoach.applyDeltas(base, [.leftHip: CGPoint(x: 0.1, y: 0.2)])
        XCTAssertEqual(moved.point(.leftHip)?.position, CGPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(moved.point(.rightHip)?.position, base.point(.rightHip)?.position)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseCoachTests`
Expected: FAIL — `cannot find 'PoseCoach'`.

- [ ] **Step 3: Implement**

Append to `PoseCoaching.swift`:
```swift
public enum PoseCoach {
    public static let rules: [PoseRule] = [
        WeightShiftRule(), KneeBendRule(), FeetStaggerRule(),
        BodyAngleRule(), ArmsGapRule(), ElbowBendRule(),
    ]
    public static let maxSuggestions = 2

    /// Only coach when a standing body is framed (hips + at least one knee visible).
    public static func standingBody(_ s: Skeleton) -> Bool {
        let hips = s.point(.leftHip) != nil || s.point(.rightHip) != nil
        let knees = s.point(.leftKnee) != nil || s.point(.rightKnee) != nil
        return hips && knees
    }

    public static func guide(_ s: Skeleton) -> PoseGuidance {
        guard standingBody(s) else { return PoseGuidance(hints: [], ghost: nil, arrows: []) }
        let picked = rules.compactMap { $0.evaluate(s) }
            .sorted { $0.priority < $1.priority }
            .prefix(maxSuggestions)
        guard !picked.isEmpty else { return PoseGuidance(hints: [], ghost: nil, arrows: []) }
        var deltas: [BodyJoint: CGPoint] = [:]
        var changed: [BodyJoint] = []
        var hints: [Hint] = []
        for sug in picked {
            hints.append(Hint(kind: .pose, severity: .info, text: sug.text, code: sug.code))
            for (j, p) in sug.targetDeltas { deltas[j] = p }
            changed.append(contentsOf: sug.changedJoints)
        }
        let ghost = applyDeltas(s, deltas)
        let arrows: [(CGPoint, CGPoint)] = changed.compactMap { j in
            guard let from = s.point(j)?.position, let to = deltas[j] else { return nil }
            return (from, to)
        }
        return PoseGuidance(hints: hints, ghost: ghost, arrows: arrows)
    }

    /// Return a copy of `base` with the given joints moved to their target positions.
    public static func applyDeltas(_ base: Skeleton, _ deltas: [BodyJoint: CGPoint]) -> Skeleton {
        var joints = base.joints
        for (j, p) in deltas {
            let conf = base.joints[j]?.confidence ?? 1
            joints[j] = JointPoint(position: p, confidence: conf)
        }
        return Skeleton(joints: joints)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test … -only-testing:JarvisAppTests/PoseCoachTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PoseCoaching.swift \
        ios/JarvisApp/Sources/JarvisAppTests/PoseCoachTests.swift
git commit -m "feat(posing): PoseCoach — gate, top-2 aggregation, ghost synthesis

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Ghost + arrows in `PosingOverlay`

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/PosingOverlay.swift`

> Draws the ghost skeleton (dashed accent bones) and arrows. All in normalized space → multiply by the `GeometryReader` size. No unit test (SwiftUI drawing); verified in the build + manual pass.

- [ ] **Step 1: Add a bones list + ghost/arrows params and rendering**

Add these params to `PosingOverlay` (alongside `hints`, `tiltDegrees`, `rollDegrees`):
```swift
    /// Ghost target pose to draw (nil = none).
    var ghost: Skeleton? = nil
    /// Arrows current → target (normalized points).
    var arrows: [(CGPoint, CGPoint)] = []
```
Add a static bones list to `PosingOverlay`:
```swift
    private static let bones: [(BodyJoint, BodyJoint)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.neck, .nose),
    ]
    private static let ghostBlue = Color(red: 0.48, green: 0.63, blue: 1.0)
```
Inside `body`'s `ZStack`, after the horizon block, add a `GeometryReader` that draws the ghost + arrows:
```swift
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                if let ghost {
                    Path { p in
                        for (a, b) in Self.bones {
                            guard let pa = ghost.point(a)?.position, let pb = ghost.point(b)?.position else { continue }
                            p.move(to: CGPoint(x: pa.x * w, y: pa.y * h))
                            p.addLine(to: CGPoint(x: pb.x * w, y: pb.y * h))
                        }
                    }
                    .stroke(Self.ghostBlue, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 4]))
                    .opacity(0.9)
                }
                ForEach(Array(arrows.enumerated()), id: \.offset) { _, seg in
                    Path { p in
                        p.move(to: CGPoint(x: seg.0.x * w, y: seg.0.y * h))
                        p.addLine(to: CGPoint(x: seg.1.x * w, y: seg.1.y * h))
                    }
                    .stroke(Self.ghostBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PosingOverlay.swift
git commit -m "feat(posing): draw ghost skeleton + nudge arrows in overlay

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: "Поза" toggle + wire `PoseCoach` in `PosingCoachScreen` + version bump

**Files:**
- Modify: `Sources/JarvisApp/PosingCoach/PosingCoachScreen.swift`
- Modify: `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`)

- [ ] **Step 1: Add pose state + recompute wiring**

Add state vars near the others:
```swift
    @State private var poseMode = false
    @State private var ghost: Skeleton?
    @State private var arrows: [(CGPoint, CGPoint)] = []
```
Pass ghost/arrows to the overlay — change the `PosingOverlay(...)` call to:
```swift
                PosingOverlay(hints: hints, tiltDegrees: tilt.tiltDegrees, rollDegrees: tilt.rollDegrees,
                              ghost: poseMode ? ghost : nil, arrows: poseMode ? arrows : [])
                    .ignoresSafeArea()
```
Replace `recompute(skeleton:)` with:
```swift
    private func recompute(skeleton: Skeleton?) {
        let frame = FrameInfo(size: frameSize, tiltDegrees: tilt.tiltDegrees)
        var raw = skeleton.map { CompositionEngine.hints(skeleton: $0, frame: frame) } ?? []
        if skeleton == nil, let t = CompositionEngine.tiltHint(frame) {
            raw.append(t)
        }
        if poseMode, let skeleton {
            let g = PoseCoach.guide(skeleton)
            raw.append(contentsOf: g.hints)
            ghost = g.ghost
            arrows = g.arrows
        } else {
            ghost = nil
            arrows = []
        }
        hints = stabilizer.step(raw)
    }
```

- [ ] **Step 2: Add the "Поза" toggle button**

In the top-right control row (where flash/torch `iconButton`s live), add a pose toggle whose tint reflects state. Change that `HStack(spacing: 14)` to include it:
```swift
                    HStack(spacing: 14) {
                        Button { poseMode.toggle() } label: {
                            Image(systemName: "figure.stand")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(poseMode ? .yellow : .white)
                                .frame(width: 40, height: 40)
                                .background(.black.opacity(0.4), in: Circle())
                        }
                        .buttonStyle(.plain)
                        iconButton(flashIcon) { camera.cycleFlash() }
                        iconButton(camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                            camera.toggleTorch()
                        }
                    }
```

- [ ] **Step 3: Bump versions**

In `project.yml`:
```yaml
        MARKETING_VERSION: "1.21.0"
        CURRENT_PROJECT_VERSION: "89"
```

- [ ] **Step 4: Regenerate + build**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild build -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit (include regenerated pbxproj + Info.plist)**

```bash
git add ios/JarvisApp/Sources/JarvisApp/PosingCoach/PosingCoachScreen.swift \
        ios/JarvisApp/project.yml \
        ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj \
        ios/JarvisApp/Info.plist
git commit -m "feat(posing): 'Поза' toggle wires PoseCoach ghost+nudges (v1.21.0, build 89)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: Full test + build sweep, then manual device pass

**Files:** none (verification only)

- [ ] **Step 1: Run the whole unit suite**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild test -project JarvisApp.xcodeproj -scheme JarvisApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`, including `PoseGeometryTests`, `PoseRulesTests`, `PoseCoachTests`, and all pre-existing suites. (A pre-existing `JarvisUITests.testDeliveryFlow` keyboard-focus flake is unrelated — only `JarvisAppTests` matters.)

- [ ] **Step 2: Manual device pass**

Install on a physical iPhone. Open Settings → «Съёмка» → «Помощник по позированию». Point at a standing person, tap the **figure.stand** ("Поза") button and confirm:
- ghost (dashed blue skeleton) draws and tracks the subject;
- text nudges appear (≤2), e.g. «Перенеси вес на дальнюю ногу», «Согни ближнее колено»;
- arrows point from current joints toward targets;
- as the subject fixes the stance, nudges progress to the next rules;
- toggling «Поза» off → clean frame, composition + horizon still work;
- no flicker/stutter; fps stays reasonable.

- [ ] **Step 3: Record outcome**

Note device + observations. No commit unless a fix is needed (then loop back to the relevant task).

---

## Notes: deferred rules (first follow-ups, NOT in this plan)

- **G — chin.neck** (gentle): needs a reliable 2D chin/neck proxy (Vision body pose gives nose but no gaze/jaw); deferred until a proxy is validated on-device.
- **H — camera.above** (gentle): "снимай чуть выше — ноги длиннее" needs device **pitch** (add `pitchDegrees` to `TiltProvider` from CoreMotion attitude) + a pure `PoseCoach.cameraAboveHint(pitchDegrees:fullBody:)`. Small, but device-tune-dependent — deferred.
- Both are low-priority per the spec; the 6 body rules deliver the core value.
