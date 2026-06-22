# Pin `workout_plan.plan_json` to one canonical schema — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the opaque `workout_plan.plan_json` (`z.record(z.unknown())`) with one canonical Zod schema in Payne's vocabulary, mirror it on iOS, pin it with a shared fixture, and validate it at the host — so the plan body is described once and drift is caught loudly.

**Architecture:** Canonical `PlanJsonSchema` in `shared/ios-app-protocol/v2.ts` (auto re-exported via the `export * from './v2.js'` barrel). Host warns-but-forwards on a non-conforming plan. A shared `workout_plan.json` fixture is validated by the TS `AnyEnvelope` round-trip AND decoded through the real iOS path, bridging the two mirrors. iOS keeps its rich `Models/Workout.swift` model (WorkoutView untouched) with CodingKeys switched to the canon and the build-35 dual-key aliases removed.

**Tech Stack:** TypeScript/Zod/vitest (host + shared), Swift/XCTest (iOS). iOS test module `Jarvis`, sim `iPhone 17`. Host tests: `pnpm test -- <path>`.

---

## Conventions
- Canonical vocab (Payne's): exercise `slug` / `target_sets` (nullable) / `target_reps` / `reps_in_reserve` (nullable) / `rest_seconds` / `duration_seconds?` / `weight_kg_target?` / `name_ru?` / `notes?`; plan `day_name` / `week` / `week_label` / `exercises`.
- iOS `WorkoutPlan`/`ExercisePlan` keep their Swift property names; only CodingKeys + encode change. WorkoutView/WorkoutCoordinator are NOT touched.
- Do NOT stage the pre-existing unrelated files (`container/agent-runner/src/mcp-tools/workout.test.ts`, `src/modules/scheduling/actions.test.ts`).

## File Structure
| File | Responsibility | New? |
|------|----------------|------|
| `shared/ios-app-protocol/v2.ts` | `PlanExerciseSchema` + `PlanJsonSchema`; `WorkoutPlan.plan_json` typed. | Modify |
| `shared/ios-app-protocol/plan-json.test.ts` | Zod accept/reject unit tests. | **New** |
| `shared/ios-app-protocol/fixtures/workout_plan.json` | Canonical fixture. | **New** |
| `shared/ios-app-protocol/fixtures.test.ts` | Count 23→24. | Modify |
| `src/channels/ios-app/v2/index.ts` | Validate plan_json (warn+forward) in the workout outbound branch. | Modify |
| `ios/.../JarvisAppTests/ProtocolFixtureTests.swift` | Count 23→24. | Modify |
| `ios/.../Models/Workout.swift` | CodingKeys=canon; drop dual-key; canonical encode. | Modify |
| `ios/.../Services/AppCoordinator.swift` | `decodeWorkoutPlan` → internal (testable). | Modify |
| `ios/.../JarvisAppTests/WorkoutPlanDecodeTests.swift` | Add fixture-bridge test. | Modify |
| `groups/payne/skills/workout-mode/SKILL.md` | Document plan_json = canon (scp+reload). | Modify |
| `ios/JarvisApp/project.yml` | Build 36. | Modify |

---

## Task 1: Canonical `PlanJsonSchema` in the protocol

**Files:** `shared/ios-app-protocol/v2.ts`, test `shared/ios-app-protocol/plan-json.test.ts`

- [ ] **Step 1: Failing test** — create `shared/ios-app-protocol/plan-json.test.ts`:
```ts
import { describe, it, expect } from 'vitest';
import { PlanJsonSchema } from './v2';

const validPlan = {
  day_name: 'Верх А', week: 1, week_label: 'лёгкая',
  exercises: [
    { slug: 'hodba', name_ru: 'Ходьба', target_sets: null, target_reps: '', reps_in_reserve: null, rest_seconds: 0, duration_seconds: 300, notes: 'разминка' },
    { slug: 'zhim', name_ru: 'Жим', target_sets: 4, target_reps: '5-6', reps_in_reserve: 3, rest_seconds: 180, weight_kg_target: 65 },
  ],
};

describe('PlanJsonSchema', () => {
  it('accepts a canonical plan with a null-warmup', () => {
    const r = PlanJsonSchema.safeParse(validPlan);
    expect(r.success).toBe(true);
  });
  it('rejects an exercise missing slug', () => {
    const bad = { ...validPlan, exercises: [{ target_sets: 3, target_reps: '8', reps_in_reserve: 2, rest_seconds: 90 }] };
    expect(PlanJsonSchema.safeParse(bad).success).toBe(false);
  });
  it('rejects a plan missing week_label', () => {
    const { week_label, ...bad } = validPlan;
    expect(PlanJsonSchema.safeParse(bad).success).toBe(false);
  });
});
```

- [ ] **Step 2: Run, verify FAIL** (`PlanJsonSchema` not exported):
```bash
cd /Users/serg/git/nanoclaw && pnpm test -- shared/ios-app-protocol/plan-json.test.ts 2>&1 | tail -15
```

- [ ] **Step 3: Add the schemas** in `shared/ios-app-protocol/v2.ts`. Place ABOVE the `Envelopes` object (so `WorkoutPlan` can reference it). Add:
```ts
export const PlanExerciseSchema = z.object({
  slug: z.string().min(1),
  name_ru: z.string().optional(),
  target_sets: z.number().int().nonnegative().nullable(),
  target_reps: z.string(),
  reps_in_reserve: z.number().int().min(0).max(10).nullable(),
  rest_seconds: z.number().int().nonnegative(),
  duration_seconds: z.number().int().nonnegative().optional(),
  weight_kg_target: z.number().nonnegative().optional(),
  notes: z.string().optional(),
});
export const PlanJsonSchema = z.object({
  day_name: z.string(),
  week: z.number().int().nonnegative(),
  week_label: z.string(),
  exercises: z.array(PlanExerciseSchema),
});
```
Then in the `WorkoutPlan` envelope (line ~188), change `plan_json: z.record(z.string(), z.unknown()),` to `plan_json: PlanJsonSchema,`.

- [ ] **Step 4: Run, verify PASS** + tsc:
```bash
pnpm test -- shared/ios-app-protocol/plan-json.test.ts 2>&1 | tail -8
pnpm exec tsc -p tsconfig.json --noEmit 2>&1 | tail -5
```
(`PlanJsonSchema` auto-exports via the barrel's `export * from './v2.js'` — no barrel edit needed.)

- [ ] **Step 5: Commit**
```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/plan-json.test.ts
git commit -m "feat(proto): canonical PlanJsonSchema (Payne vocab) for workout_plan.plan_json"
```

---

## Task 2: Shared fixture + bump both fixture-count assertions

**Files:** `shared/ios-app-protocol/fixtures/workout_plan.json` (new), `shared/ios-app-protocol/fixtures.test.ts`, `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`

- [ ] **Step 1: Create the fixture** `shared/ios-app-protocol/fixtures/workout_plan.json`:
```json
{
  "v": 2,
  "kind": "control",
  "type": "workout_plan",
  "id": "00000000-0000-4000-8000-0000000000a1",
  "seq": 9,
  "ts": "2026-06-22T10:00:00Z",
  "payload": {
    "workout_id": "2026-06-22",
    "plan_json": {
      "day_name": "Верх А",
      "week": 1,
      "week_label": "лёгкая",
      "exercises": [
        { "slug": "hodba", "name_ru": "Ходьба", "target_sets": null, "target_reps": "", "reps_in_reserve": null, "rest_seconds": 0, "duration_seconds": 300, "notes": "разминка" },
        { "slug": "zhim", "name_ru": "Жим", "target_sets": 4, "target_reps": "5-6", "reps_in_reserve": 3, "rest_seconds": 180, "weight_kg_target": 65 }
      ]
    },
    "image_manifest": [{ "slug": "hodba", "sha256": "abc" }]
  }
}
```

- [ ] **Step 2: Bump the TS count** in `shared/ios-app-protocol/fixtures.test.ts`: change the test title `'covers all 23 expected envelope fixtures'` → `24` and `expect(envelopeFiles).toHaveLength(23)` → `24`.

- [ ] **Step 3: Run TS fixtures — verify the fixture validates through AnyEnvelope** (now that plan_json is typed):
```bash
pnpm test -- shared/ios-app-protocol/fixtures.test.ts 2>&1 | tail -10
```
Expected: all pass incl. `workout_plan.json round-trips through AnyEnvelope` + the count is 24. (If it fails to round-trip, the fixture's plan_json doesn't satisfy `PlanJsonSchema` — fix the fixture, not the schema.)

- [ ] **Step 4: Bump the Swift count** in `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`: change `XCTAssertEqual(urls.count, 23, …)` → `24`.

- [ ] **Step 5: Run Swift fixture test** (the envelope decodes; `V2.WorkoutPlan.plan_json` is `JSONValue`, so it round-trips opaquely):
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/ProtocolFixtureTests 2>&1 | tail -12
```

- [ ] **Step 6: Commit**
```bash
git add shared/ios-app-protocol/fixtures/workout_plan.json shared/ios-app-protocol/fixtures.test.ts ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "test(proto): canonical workout_plan fixture pins plan_json both sides"
```

---

## Task 3: Host validation — warn + forward

**Files:** `src/channels/ios-app/v2/index.ts`, test `src/channels/ios-app/v2/workout-outbound.test.ts`

`logV2Warn` is a LOCAL function in `index.ts` (line ~91). The workout outbound branch is ~line 534.

- [ ] **Step 1: Write the failing test** `src/channels/ios-app/v2/workout-outbound.test.ts`. Mirror the harness in `src/channels/ios-app/v2/agent-routing.test.ts` (real adapter via `createV2Adapter()` → `adapter.deliver()` → read the enqueued row via `OutboundQueue.list()`; set up a resolvable session so the workout branch reaches the bridge — copy that setup verbatim from agent-routing.test.ts). The point: an INVALID plan_json is still forwarded (validation warns, never blocks).
```ts
import { describe, it, expect } from 'vitest';
// import harness pieces exactly as agent-routing.test.ts does

describe('ios-app-v2 workout_plan outbound', () => {
  it('forwards a workout_plan even when plan_json is off-canon (warn, not block)', async () => {
    // ARRANGE: adapter + a resolvable session (per agent-routing.test.ts harness).
    // ACT: deliver content:
    //   { type:'workout_plan', workout_id:'w1',
    //     plan_json: { day_name:'X', exercises:[{ slug:'a' }] },  // missing week/week_label, etc — off-canon
    //     image_manifest: [] }
    // ASSERT: a workout_plan envelope was still enqueued (forwarded).
    //   expect(enqueued.some(e => e.type === 'workout_plan')).toBe(true)
  });

  it('forwards a canonical workout_plan', async () => {
    // deliver a valid plan_json (day_name/week/week_label/exercises) → enqueued workout_plan.
  });
});
```
(Fill ARRANGE/ACT from the real harness. The assertion is forwarding-happens; the warn is a log side-effect of a local fn — not asserted.)

- [ ] **Step 2: Run, verify FAIL or RED-for-right-reason**
```bash
pnpm test -- src/channels/ios-app/v2/workout-outbound.test.ts 2>&1 | tail -20
```
(Before Step 3 the plan still forwards — so this test may PASS immediately for the forward assertion. That's acceptable: the test pins the warn+forward contract so Step 3 can't regress it into reject. If you want a true red first, temporarily assert `enqueued` is empty, see it fail, then flip — optional.)

- [ ] **Step 3: Add validation** in `src/channels/ios-app/v2/index.ts`. Import the schema at the top with the other shared imports:
```ts
import { PlanJsonSchema } from '../../../../shared/ios-app-protocol/index.js';
```
In the workout outbound branch, AFTER the `sessionId` guard and BEFORE `workoutBridge.handleAgentRequest(...)`:
```ts
        if (contentType === 'workout_plan') {
          const parsed = PlanJsonSchema.safeParse((content as { plan_json?: unknown }).plan_json);
          if (!parsed.success) {
            logV2Warn('workout_plan plan_json failed schema — forwarding anyway', {
              issues: parsed.error.issues.slice(0, 8),
            });
          }
        }
```

- [ ] **Step 4: Run, verify PASS** + the full ios-app-v2 suite (no regression):
```bash
pnpm test -- src/channels/ios-app/v2/workout-outbound.test.ts 2>&1 | tail -10
pnpm test -- src/channels/ios-app/v2/ 2>&1 | tail -8
pnpm exec tsc -p tsconfig.json --noEmit 2>&1 | tail -5
```

- [ ] **Step 5: Commit**
```bash
git add src/channels/ios-app/v2/index.ts src/channels/ios-app/v2/workout-outbound.test.ts
git commit -m "feat(ios-app-v2): warn on off-canon workout_plan plan_json (forward anyway)"
```

---

## Task 4: iOS model — CodingKeys=canon, drop dual-key, canonical encode

**Files:** `ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift`

The build-35 model has dual-key CodingKeys + lenient decode. Switch to canon-only keys; keep null-tolerance.

- [ ] **Step 1: Replace `ExercisePlan`'s CodingKeys + `init(from:)` + `encode`** so they use ONLY the canon keys. The struct's stored properties + memberwise init stay unchanged. New CodingKeys:
```swift
    enum CodingKeys: String, CodingKey {
        case exerciseSlug = "slug"
        case targetSets = "target_sets"
        case targetReps = "target_reps"
        case targetRir = "reps_in_reserve"
        case restSec = "rest_seconds"
        case notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseSlug = (try? c.decode(String.self, forKey: .exerciseSlug)) ?? ""
        targetSets = (try? c.decode(Int.self, forKey: .targetSets)) ?? 0   // null warmup → 0
        targetReps = (try? c.decode(String.self, forKey: .targetReps)) ?? ""
        targetRir = (try? c.decode(Int.self, forKey: .targetRir)) ?? 0     // null warmup → 0
        restSec = (try? c.decode(Int.self, forKey: .restSec)) ?? 0
        notes = try? c.decode(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exerciseSlug, forKey: .exerciseSlug)
        try c.encode(targetSets, forKey: .targetSets)
        try c.encode(targetReps, forKey: .targetReps)
        try c.encode(targetRir, forKey: .targetRir)
        try c.encode(restSec, forKey: .restSec)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
```

- [ ] **Step 2: Replace `WorkoutPlan`'s CodingKeys + `init(from:)`** so intensity reads `week_label` only (drop `intensity_label`). Keep the memberwise init + `encode` (encode `intensityLabel` under `week_label`):
```swift
    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case dayName = "day_name"
        case week
        case intensityLabel = "week_label"
        case exercises
        case imageManifest = "image_manifest"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workoutId = (try? c.decode(String.self, forKey: .workoutId)) ?? ""
        dayName = (try? c.decode(String.self, forKey: .dayName)) ?? ""
        week = (try? c.decode(Int.self, forKey: .week)) ?? 0
        intensityLabel = (try? c.decode(String.self, forKey: .intensityLabel)) ?? ""
        exercises = (try? c.decode([ExercisePlan].self, forKey: .exercises)) ?? []
        imageManifest = (try? c.decode([ImageManifestEntry].self, forKey: .imageManifest)) ?? []
    }
```
(The existing `encode(to:)` already encodes each property via its CodingKey — with `intensityLabel = "week_label"` it now emits `week_label`. Keep it.)

- [ ] **Step 3: Run the existing decode test** (`WorkoutPlanDecodeTests` build-35 JSON already uses the canon shape — slug/reps_in_reserve/rest_seconds/week_label — so it still passes; the round-trip now uses canon keys both ways):
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/WorkoutPlanDecodeTests 2>&1 | tail -12
```
Expected: PASS (2 tests). If the round-trip test fails, it's because encode/decode keys disagree — they must both be canon.

- [ ] **Step 4: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift
git commit -m "refactor(ios): WorkoutPlan/ExercisePlan CodingKeys = canonical plan_json vocab"
```

---

## Task 5: iOS fixture-bridge test (real decode path)

**Files:** `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift`, `ios/JarvisApp/Sources/JarvisAppTests/WorkoutPlanDecodeTests.swift`

- [ ] **Step 1: Make `decodeWorkoutPlan` testable** — in `AppCoordinator.swift`, change `private static func decodeWorkoutPlan(payload p: V2.WorkoutPlan) throws -> WorkoutPlan` to `static func decodeWorkoutPlan(payload p: V2.WorkoutPlan) throws -> WorkoutPlan` (drop `private`). (It's the real splice the runtime uses.)

- [ ] **Step 2: Add the bridge test** — append to `WorkoutPlanDecodeTests.swift`. Load the shared fixture the same way `ProtocolFixtureTests` does (`#filePath` walk-up to repo root → `shared/ios-app-protocol/fixtures/workout_plan.json`), decode the envelope, extract the `.workoutPlan` payload, run the real `decodeWorkoutPlan`:
```swift
    func test_sharedFixture_decodesThroughRealPath() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent() // JarvisAppTests/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // JarvisApp/
            .deletingLastPathComponent() // ios/
            .deletingLastPathComponent() // repo root
        let url = repoRoot.appendingPathComponent("shared/ios-app-protocol/fixtures/workout_plan.json")
        let data = try Data(contentsOf: url)
        let env = try JSONDecoder().decode(V2.Envelope.self, from: data)
        guard case let .workoutPlan(payload) = env.payload else { return XCTFail("expected workoutPlan payload") }

        let plan = try AppCoordinator.decodeWorkoutPlan(payload: payload)
        XCTAssertEqual(plan.workoutId, "2026-06-22")
        XCTAssertEqual(plan.intensityLabel, "лёгкая")       // from week_label
        XCTAssertEqual(plan.exercises.count, 2)
        XCTAssertEqual(plan.exercises[0].exerciseSlug, "hodba")
        XCTAssertEqual(plan.exercises[0].targetSets, 0)     // null warmup → 0
        XCTAssertEqual(plan.exercises[1].exerciseSlug, "zhim")
        XCTAssertEqual(plan.exercises[1].targetRir, 3)
        XCTAssertEqual(plan.exercises[1].restSec, 180)
        XCTAssertEqual(plan.imageManifest.count, 1)
    }
```
(If `V2.Envelope.Payload`'s case is named differently than `.workoutPlan`, match the real case from `Protocol/V2.swift`.)

- [ ] **Step 3: Run, verify PASS**
```bash
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests/WorkoutPlanDecodeTests 2>&1 | tail -12
```
Expected: 3 tests pass.

- [ ] **Step 4: Commit**
```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutPlanDecodeTests.swift
git commit -m "test(ios): decode shared workout_plan fixture through the real path"
```

---

## Task 6: Payne skill doc, version bump, full suites

**Files:** `groups/payne/skills/workout-mode/SKILL.md`, `ios/JarvisApp/project.yml`

- [ ] **Step 1: Tighten the skill's plan_json doc** — in `groups/payne/skills/workout-mode/SKILL.md`, update the `plan_json` example in the `workout_start_request` step 5 (and the conversational section's reference) so it matches the canon exactly: include top-level `day_name`, `week`, `week_label`, and `exercises[]` where each exercise is `{ slug, name_ru, target_sets (null for cardio warmup), target_reps, reps_in_reserve (null for warmup), rest_seconds, duration_seconds (cardio, optional), weight_kg_target (optional), notes (optional) }`. Add one explicit note: "Cardio/warmup → `target_sets: null`, `reps_in_reserve: null`, `target_reps: ""`, use `duration_seconds`."

- [ ] **Step 2: Bump** `ios/JarvisApp/project.yml`: `CURRENT_PROJECT_VERSION` → `"36"` (MARKETING stays `"1.8.0"`).

- [ ] **Step 3: Full suites**
```bash
cd /Users/serg/git/nanoclaw/ios/JarvisApp && xcodegen generate && cd /Users/serg/git/nanoclaw
xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JarvisAppTests 2>&1 | tail -6
pnpm test -- shared/ios-app-protocol/ src/channels/ios-app/v2/ 2>&1 | tail -8
pnpm exec tsc -p tsconfig.json --noEmit 2>&1 | tail -5
```
Expected: iOS `TEST SUCCEEDED`; TS all pass; tsc clean. If anything fails, BLOCKED.

- [ ] **Step 4: Commit**
```bash
git add groups/payne/skills/workout-mode/SKILL.md ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj
git commit -m "chore: document canonical plan_json (Payne skill) + bump iOS to build 36"
```

- [ ] **Step 5: Deploy (controller, after review)** — NOT a subagent step:
  - **Host** (schema + validation are host code): `git push`; on VDS `git pull && pnpm run build && systemctl --user restart nanoclaw`.
  - **Payne skill**: scp `groups/payne/skills/workout-mode/SKILL.md` to the VDS, then reload Payne (`docker kill` the live container if any + wipe `continuation:claude` in `data/v2-sessions/payne/*/outbound.db`).
  - **iOS**: Sergei installs build 36.
  - **Manual verify**: ask Payne for a workout → card renders (day · intensity · N exercises + Start).

---

## Self-Review (completed during planning)
- **Spec coverage:** canonical schema → Task 1. Host warn+forward → Task 3. Fixture + both counts → Task 2. iOS model canon CodingKeys / drop dual-key / canonical encode → Task 4. iOS bridge test + expose decodeWorkoutPlan → Task 5. Payne skill doc + bump → Task 6. Non-goals (Payne data files, V2.swift wire typing, workout.ts param, set_log slug) untouched.
- **Type consistency:** `PlanJsonSchema` (Task 1) imported in host (Task 3) + satisfied by the fixture (Task 2). iOS CodingKeys canon (Task 4: `slug`/`reps_in_reserve`/`rest_seconds`/`week_label`) match the fixture (Task 2) decoded by the bridge test (Task 5). `decodeWorkoutPlan` made `static` (Task 5) is the same splice runtime uses. Encode↔decode both canon (Task 4) keeps B2 persist/reload stable.
- **Placeholder check:** Task 3's test ARRANGE/ACT references the real `agent-routing.test.ts` harness (the assertion — forwarding-happens — is concrete); everything else is literal code.
