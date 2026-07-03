# Posing Coach — Phase 2: Pose Coaching (ghost + nudges) — Design

**Date:** 2026-07-04
**Status:** Approved.
**Target:** iOS `JarvisApp` (SwiftUI), the `PosingCoachScreen` shipped in Phase 1.
**Parent spec:** [2026-07-03-ondevice-posing-coach-design.md](2026-07-03-ondevice-posing-coach-design.md) (this is its Phase 2 / Tier-2, replacing the old "curated pose library" approach A with a procedural-rules approach).

## Goal

While photographing a (standing) woman, coach her pose in real time: derive a set of well-known female-posing corrections from her live 2D skeleton, show them as **both** a ghost silhouette ("stand like this") **and** short text nudges + arrows ("shift weight to the far leg"). Fully on-device, offline, reusing the Phase-1 pipeline. Toggleable so it never clutters the frame when not wanted.

## What changed vs the parent spec

The parent spec's Tier-2 approach A was a *hand-curated library of good-pose skeletons* matched by nearest-template. This is replaced by a **procedural posing-rules engine**: a handful of encoded posing heuristics produce nudges directly, and the ghost is synthesized by applying each rule's target deltas to the current skeleton. No library to curate, deterministic, unit-testable. A curated aspirational-pose library remains a possible later addition, not part of this phase.

## Scope

### In scope
- **Subject:** one **standing** woman, full or half body (hips + at least knees visible with confidence). Reuses the Phase-1 photographer-shooting-another-person scenario.
- **Both guidance forms:** ghost silhouette (dashed skeleton = current pose with corrections applied) + text nudges (reusing Phase-1 `Hint` chips) + arrows from current joint → target joint.
- **Rule set (MVP, 8 rules)** — priority order; grounded in female-posing guides, filtered to what a 2D body skeleton can detect:
  1. **weight.shift** (A) — hips ~level AND legs straight → "перенеси вес на дальнюю ногу". Target: tilt the hip line, shift torso.
  2. **knee.bend** (B) — both legs straight → "согни ближнее колено". Target: bend the near knee. (Pairs with A.)
  3. **feet.stagger** (C) — ankles at ~same x → "одну ногу чуть вперёд". Target: offset one ankle.
  4. **body.angle** (D) — shoulders square/wide & level (facing front) → "развернись на ¾, одно плечо ближе". Target: narrow the shoulder line (bring one shoulder in).
  5. **arms.gap** (E) — a wrist close to the torso/hip x → "оторви руки: на бедро / к ключице". Target: move the wrist outward (or to hip).
  6. **elbow.bend** (F) — shoulder-elbow-wrist ~collinear & vertical → "согни локоть, смени угол". Target: bend the elbow.
  7. **chin.neck** (G, gentle/low-priority) — chin raised (nose high relative to neck) → "чуть опусти подбородок, вытяни шею". Target: lower nose slightly.
  8. **camera.above** (H, gentle/low-priority) — device pitch level/upward with a full body → "сними чуть выше — ноги длиннее". Camera hint (from CoreMotion pitch), no ghost delta.
- **Toggle:** a "Поза" button in the existing control bar. Composition + horizon stay always-on. Pose coaching runs only when toggled on **and** a qualifying standing body is detected.
- At most **2** suggestions surfaced at once (highest priority), stabilized to avoid flicker.

### Out of scope (later)
- Sitting, group, selfie/front-camera pose coaching.
- Curated aspirational-pose library (approach B).
- Face/expression/hand-detail guidance beyond the gentle chin rule (Vision body pose gives no fingers, no gaze).
- Rule expansion beyond the 8 (explicitly a "grow later" list).

## Architecture

Reuses the Phase-1 on-device pipeline unchanged. New logic is pure and testable; only the overlay and screen gain rendering + a toggle.

```
CameraSession.skeleton ─▶ PosingCoachScreen.recompute
   ├── CompositionEngine.hints            (always, Phase 1)
   └── if poseMode && standingBody(skeleton):
         PoseCoach.guide(skeleton) ─▶ PoseGuidance { hints, ghostSkeleton, arrows }
   merge hints ─▶ HintStabilizer ─▶ PosingOverlay(grid, horizon, chips, ghost, arrows)
```

### Components (each one job, independently testable)

1. **`PoseSuggestion`** (value type) — `{ code: String, text: String, priority: Int, targetDeltas: [BodyJoint: CGPoint], arrows: [(BodyJoint)] }`. `targetDeltas` = absolute target positions (screen space) for the joints a rule wants moved; `arrows` = joints that changed (draw current→target).
2. **`PoseRule`** (protocol) — `func evaluate(_ s: Skeleton) -> PoseSuggestion?`. Pure; returns nil when the rule doesn't apply or its required joints aren't confidently visible.
3. **Concrete rules** — one struct per rule (A–H) conforming to `PoseRule`, each in a focused file or grouped by body region. Pure geometry over `Skeleton`.
4. **`PoseCoach`** — holds the ordered rule list; `guide(_ s: Skeleton) -> PoseGuidance`. Runs all rules, keeps the top ≤2 by priority, builds:
   - `hints: [Hint]` (kind `.pose`) from suggestion text,
   - `ghostSkeleton: Skeleton?` = `applyDeltas(current, mergedTargetDeltas)`,
   - `arrows: [(CGPoint, CGPoint)]` current→target for changed joints.
5. **`standingBody(_ s:) -> Bool`** — gate: hips present + at least one knee, confidently. (Lives in `PoseCoach` or a small helper.)
6. **Ghost synthesis** — `PoseCoach.applyDeltas(_ base: Skeleton, _ deltas:) -> Skeleton`: copy base, overwrite the delta'd joints. Pure.
7. **`PosingOverlay`** additions — draw the ghost as a dashed accent-colored skeleton (line segments between joints) and the arrows; pose text chips flow through the existing chip stack. Ghost/arrows only shown in pose mode.
8. **`PosingCoachScreen`** additions — `@State poseMode`, a "Поза" toggle button (SF Symbol, e.g. `figure.stand`), pass ghost/arrows/pose-hints into the overlay. Stabilize pose hints via the existing `HintStabilizer` (pose + composition hints share the stabilizer, keyed by `code`).

### Data types
- `PoseGuidance` — `{ hints: [Hint], ghost: Skeleton?, arrows: [(CGPoint, CGPoint)] }`.
- Reuses `Skeleton`, `BodyJoint`, `JointPoint`, `Hint` (add `Hint.Kind.pose` — already exists).

## 2D reliability handling

2D keypoints can't see depth/rotation precisely, so rules are deliberately conservative:
- Each rule requires its input joints present with confidence ≥ the detector threshold; otherwise it stays silent (no guessing).
- Thresholds are lenient (only fire on clear cases, e.g. legs *clearly* straight, shoulders *clearly* square).
- At most 2 suggestions at once; hints + ghost run through smoothing so nothing flickers.
- Gentle rules (chin, camera-above) sit at the bottom of the priority list so body-shape rules win.

## Testing
- **Unit (pure):** each `PoseRule` against synthetic skeletons — asserts it fires (or not) on the intended configuration and that `targetDeltas` move the right joint in the right direction. `PoseCoach` — priority capping (≤2), `standingBody` gating, ghost synthesis (`applyDeltas` moves exactly the delta'd joints). Module `@testable import Jarvis`.
- **Manual device pass:** toggle "Поза" on a real iPhone with a standing subject — ghost draws and tracks, nudges read sensibly, no flicker, composition/horizon unaffected, toggle off = clean frame.
- **Versioning:** bump `MARKETING_VERSION` (feature) + `CURRENT_PROJECT_VERSION`, `xcodegen generate`, commit the pbxproj.

## Integration notes
- All new source under `ios/JarvisApp/Sources/JarvisApp/PosingCoach/` (feature folder from Phase 1); xcodegen auto-includes.
- No server / DB / messaging changes — purely iOS, offline.
- Current live build is 88 on `main`; this phase bumps from there.

## Open questions for later (post-MVP)
- Grow the rule set (more female-posing tips; expression/hands need face+hand landmarks).
- Aspirational curated-pose library as an optional "goal" ghost.
- Per-shot-type packs (portrait / fashion / full-body).
- Make the ghost look more natural (currently a corrected copy of the current skeleton).
