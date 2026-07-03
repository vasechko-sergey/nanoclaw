# On-Device Posing Coach — Design / Feasibility

**Date:** 2026-07-03
**Status:** Approved (MVP scope). Pose library is an iterate-later track.
**Target:** iOS `JarvisApp` (SwiftUI).

## Goal

While the user aims the phone camera at another person, show real-time on-screen guidance for a better photo: composition hints (framing) and body-pose coaching (how the subject should stand), delivered as text chips plus a visual overlay (grid + ghost silhouette). Everything runs offline on the device — no server, no API, no per-inference cost.

## Scope

### In scope (this design)
- **Scenario:** photographer shoots another person (full or half body). The photographer looks at the screen; hints are for the photographer.
- **Tier 1 — Composition** (MVP, high confidence): rule-of-thirds placement, horizon/tilt, joint-cropping avoidance ("don't cut at the ankle/knee/elbow"), head-room, where the subject should stand in frame.
- **Tier 2 — Pose coaching, approach A** (R&D track): a curated library of "good pose" skeletons; match the subject's current skeleton to the nearest good template; render that template as a ghost silhouette and derive text deltas ("turn your shoulders", "shift weight to one leg").
- Integration as a standalone camera screen inside `JarvisApp`, loosely coupled.

### Out of scope (explicitly not doing now)
- Selfie mode (front camera, self-posing) — different UX, deferred.
- A trained aesthetic model (approach B) — real ML R&D, months, high risk. Revisit only if the library approach hits a ceiling.
- On-device VLM "analyze this frame" (approach C) — not real-time, heavy, weak quality for this niche.
- Sending captured shots to the agent / cloud analysis.

## Why this is feasible (the "model" is nearly weightless)

The "offline model" is **not** a single trained neural black box. It is:
1. **Apple `Vision`** — `VNDetectHumanBodyPoseRequest` yields 19 body keypoints, on-device, real-time (~30 fps on Neural Engine, A12+), built into iOS 14+. **Zero added app size, zero inference cost.**
2. **A small JSON pose library** (KBs) of curated good-pose skeletons.
3. **Plain geometry** on top of the keypoints for composition and pose matching.

No training, no dataset labeling, no server, no API keys.

## Architecture

All on-device, per-frame at camera frame rate:

```
AVFoundation camera frames
   → Vision (VNDetectHumanBodyPoseRequest) → normalized skeleton (19 keypoints)
       ├── Composition engine (geometry rules) → hint chips
       └── Pose matcher (nearest good template) → ghost silhouette + text deltas
   → Overlay renderer (SwiftUI/Metal): grid + hint chips + ghost silhouette
```

### Components (each independently understandable/testable)

1. **CameraSession** — `AVCaptureSession` wrapper; vends `CVPixelBuffer` frames, handles permissions, orientation, lifecycle. Interface: start/stop + a frame callback. Depends on: AVFoundation, camera permission.
2. **PoseDetector** — wraps `VNDetectHumanBodyPoseRequest`; input frame → `Skeleton` (19 named joints + confidence). Normalizes to a scale/translation-invariant form. Interface: `detect(frame) -> Skeleton?`. Depends on: Vision.
3. **CompositionEngine** — pure function `Skeleton + frameSize + deviceTilt -> [Hint]`. Rules: thirds placement, tilt (from CoreMotion or shoulder line), joint-cropping near edges, head-room. No I/O, fully unit-testable with synthetic skeletons.
4. **PoseLibrary** — loads curated good-pose templates from bundled JSON; categorized (standing-full, standing-half, sitting, leaning). Interface: `templates(for: category) -> [PoseTemplate]`.
5. **PoseMatcher** — `Skeleton + PoseLibrary -> (bestTemplate, [Hint])`. Normalizes current skeleton, finds nearest good template (joint-angle distance / Procrustes), computes per-joint deltas → text hints. Pure, unit-testable.
6. **OverlayRenderer** — SwiftUI/Metal view drawing thirds grid, hint chips, and the ghost silhouette anchored (scale + position) to the subject. Includes temporal smoothing to kill jitter.
7. **PosingCoachScreen** — SwiftUI screen wiring the above; the single integration point into `JarvisApp` (a new entry, e.g. a "Позинг" button/tab). Loose coupling — no changes to messaging/transport.

### Data types
- `Skeleton` — 19 named joints, each `(point: CGPoint (normalized), confidence: Float)`.
- `Hint` — `{ kind: composition|pose, severity, text: String, anchor? }`.
- `PoseTemplate` — `{ id, category, joints: [named normalized points], meta }`.

## Phases & effort (1 developer)

- **Phase 0 — Spike (2–3 days):** camera + Vision skeleton drawn on a real iPhone; measure fps on target device. De-risks the core assumption (real-time keypoints). Gate: if fps is unacceptable on target hardware, revisit before investing.
- **Phase 1 — Composition MVP (2–3 weeks):** CameraSession + PoseDetector + CompositionEngine + OverlayRenderer (grid + chips) + PosingCoachScreen wired into JarvisApp. Shippable on its own.
- **Phase 2 — Pose library v1 (3–4 weeks):** PoseLibrary (15–30 curated poses) + PoseMatcher + ghost-silhouette overlay + text deltas. Bulk of the taste/curation work is here (design, not code).
- **Phase 3 — Polish (ongoing):** more poses, smoothing tuning, UX, category detection.

**Total to a solid v1 of both tiers ≈ 1.5–2 months.** Inference cost: zero.

## Resources & constraints
- **No cloud / server / API.** Fully offline; private.
- **App size:** Vision is built-in (0 MB); pose library is a small JSON (KBs).
- **Device floor:** comfortable on A12+ (iPhone XS and newer); older devices run but slower.
- **Skills:** Swift + Vision + a bit of geometry/linear algebra; design/taste for the pose library.

## Risks / unknowns
- Anchoring the ghost silhouette convincingly to the real subject (scale + position) — fiddly UX work.
- Curating a genuinely useful pose library — taste + time, not code.
- Hint jitter frame-to-frame — needs temporal smoothing/hysteresis or it annoys.
- Deciding *which* template is "better than current" — needs a current-pose category classifier + a ranked good set.
- Older-device performance.

## Testing
- **Unit (pure logic):** CompositionEngine and PoseMatcher against synthetic skeletons — deterministic, fast, `@testable import Jarvis` (module name is `Jarvis`, not `JarvisApp`).
- **Fixture skeletons:** capture a handful of real skeletons as JSON fixtures; assert expected hints.
- **Manual device pass:** on a real iPhone for camera + fps + overlay feel (per project rule: verify iOS via unit tests + clean build; device runtime check is a manual pass, not a prod-token connection).
- **iOS versioning:** any iOS change bumps `CURRENT_PROJECT_VERSION` (+`MARKETING_VERSION` per feature), runs xcodegen, commits the pbxproj.

## Integration notes (JarvisApp)
- New standalone module + one SwiftUI screen; no coupling to transport/messaging/agent code.
- Camera usage requires an `NSCameraUsageDescription` Info.plist entry.
- Entry point: a new button/tab in the app (exact placement decided during Phase 1).

## Open questions for later (post-MVP, to maximize usefulness)
- Grow/curate the pose library (biggest lever on quality).
- Auto-detect pose category (standing/sitting/leaning) to pick relevant templates.
- Optional: feed a captured shot to the agent for a natural-language critique (uses existing JarvisApp ↔ agent path; not part of the offline core).
- Optional: per-genre pose packs (portrait, fashion, couple, group).
