# Pin `workout_plan.plan_json` to one canonical schema — design

**Date:** 2026-06-23
**Scope:** Replace the opaque `plan_json: z.record(z.unknown())` in the v2 protocol with a single canonical schema (Payne's vocabulary), mirror it, fixture it, and validate it at the host — so the workout-plan body is described once and drift is caught loudly instead of silently failing the iOS decode.
**Status:** Design approved, pending implementation plan

## Problem

The v2 protocol is "describe once" — `shared/ios-app-protocol/v2.ts` (Zod) mirrored in `Protocol/V2.swift`, pinned by fixture tests. That discipline holds for the envelope, `image_manifest`, and the typed workout sub-messages (`set_log`, `exercise_done`, `workout_complete`, swaps — all use `exercise_slug`/`reps_in_reserve` in the canon). It **stops at one field**: `WorkoutPlan.payload.plan_json` is typed `z.record(z.string(), z.unknown())` (`v2.ts:188`) / `JSONValue` (`V2.swift:248`) — the plan body was left opaque.

Consequence: the plan/exercise shape was hand-defined in two un-synced places, with no fixture bridging them:
- **Payne emitter** (`workout.ts` tool param `{type:'object'}` + `workout-mode` SKILL.md prose): `slug` / `reps_in_reserve` / `rest_seconds` / `week_label`, cardio warmup carries `target_sets: null`.
- **iOS consumer** (`Models/Workout.swift`, hand-written): `exercise_slug` / `target_rir` / `rest_sec` / `intensity_label`, non-optional `Int`.

They drifted. `AppCoordinator.decodeWorkoutPlan` threw → `handleWorkoutEnvelope` swallowed the error → the workout card never rendered (workout flow never worked e2e). Build 35 shipped a tactical lenient decode (accepts both key sets). This spec is the structural fix: pin `plan_json` once, in Payne's vocabulary.

## Decisions (from brainstorm)

- **Canonical vocabulary = Payne's** (`slug`/`reps_in_reserve`/`rest_seconds`/`week_label`) — his data files (`programs/current.json`, `sessions/*`, exercise cards) and the skill already use it; only the iOS model + protocol typing change.
- **Host validation = warn + forward** — the bridge Zod-parses `plan_json`; on mismatch it logs loudly (`logV2Warn`) but still forwards. Visibility without breaking delivery.
- **iOS model = keep the rich model, CodingKeys = canon** — `Models/Workout.swift` `WorkoutPlan`/`ExercisePlan` keep their Swift property names (WorkoutView/WorkoutCoordinator untouched); only CodingKeys + encode switch to the canon. Drop the build-35 dual-key aliases; keep null-tolerance for the warmup.

## Design

### 1. Canonical schema — `shared/ios-app-protocol/v2.ts`
Replace `plan_json: z.record(z.string(), z.unknown())` (line 188) with an exported schema:
```ts
export const PlanExerciseSchema = z.object({
  slug: z.string().min(1),
  name_ru: z.string().optional(),
  target_sets: z.number().int().nonnegative().nullable(),      // null = cardio warmup
  target_reps: z.string(),                                     // may be ""
  reps_in_reserve: z.number().int().min(0).max(10).nullable(), // null = cardio warmup
  rest_seconds: z.number().int().nonnegative(),
  duration_seconds: z.number().int().nonnegative().optional(), // cardio
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
Reference it in the `WorkoutPlan` envelope: `plan_json: PlanJsonSchema`.

### 2. Host validation — `src/channels/ios-app/v2/index.ts`
In the outbound workout branch (the `if (contentType && workoutBridge.handlesOutbound(contentType))` block, ~line 534), before `handleAgentRequest`, validate when it's a plan:
```ts
if (contentType === 'workout_plan') {
  const parsed = PlanJsonSchema.safeParse(content.plan_json);
  if (!parsed.success) {
    logV2Warn('workout_plan plan_json failed schema — forwarding anyway', {
      issues: parsed.error.issues.slice(0, 8),
    });
  }
}
```
`WorkoutBridge` stays pure (validation lives at the call site where `logV2Warn` is). Forward unconditionally (warn, don't reject).

### 3. Fixture — `shared/ios-app-protocol/fixtures/workout_plan.json`
A real `workout_plan` envelope (valid UUID `id`) whose `plan_json` includes one real lift **and** a null-warmup:
```json
{ "v":2, "kind":"control", "type":"workout_plan", "id":"<valid-uuid>", "seq":9, "ts":"2026-06-22T10:00:00Z",
  "payload": { "workout_id":"2026-06-22",
    "plan_json": { "day_name":"Верх А", "week":1, "week_label":"лёгкая", "exercises":[
      {"slug":"hodba","name_ru":"Ходьба","target_sets":null,"target_reps":"","reps_in_reserve":null,"rest_seconds":0,"duration_seconds":300,"notes":"разминка"},
      {"slug":"zhim","name_ru":"Жим","target_sets":4,"target_reps":"5-6","reps_in_reserve":3,"rest_seconds":180,"weight_kg_target":65}
    ]},
    "image_manifest":[{"slug":"hodba","sha256":"abc"}] } }
```
Now that `plan_json` is typed, `shared/ios-app-protocol/fixtures.test.ts` (`AnyEnvelope.parse` over every fixture) validates the inner shape — the fixture's plan_json must satisfy the canon. Bump its count assertion (23→24) and the Swift `ProtocolFixtureTests` count (23→24).

### 4. iOS model — `Models/Workout.swift`
Keep `WorkoutPlan`/`ExercisePlan` Swift property names (so `WorkoutView`/`WorkoutCoordinator` are untouched). Change:
- **CodingKeys → canon only:** `exerciseSlug = "slug"`, `targetRir = "reps_in_reserve"`, `restSec = "rest_seconds"`; WorkoutPlan `intensityLabel = "week_label"`. Remove the build-35 dual-key alias cases.
- **Decode:** keep null-tolerance — `target_sets`/`reps_in_reserve` decode via `try? decode ?? 0` (warmup null → 0). Other fields strict-with-default as today.
- **Encode:** switch to the canon keys (so B2's `insertWorkoutPlan` encode → `toChatMessage` decode round-trip stays self-consistent on the new vocab).
- Optional fields not used by WorkoutView (`name_ru`, `duration_seconds`, `weight_kg_target`) remain ignored by the model (Codable skips unknown keys) — no need to add them unless WorkoutView grows to use them (YAGNI).

### 5. iOS bridge test
Decode the **shared** `workout_plan.json` fixture through the real path: load it via the same loader `ProtocolFixtureTests` uses, decode the envelope, run the actual `AppCoordinator` splice/`decodeWorkoutPlan` equivalent → `WorkoutPlan`, and assert: `intensityLabel == "лёгкая"`, exercises count, warmup `targetSets == 0`, lift `targetRir == 3`/`restSec == 180`. This ties the Swift model to the same fixture the TS schema validates — the cross-language bridge that was missing. Update/replace the build-35 `WorkoutPlanDecodeTests` to load the fixture (keep the round-trip test).

### 6. Payne skill — `groups/payne/skills/workout-mode/SKILL.md`
Tighten the documented `plan_json` (step 5 / structure block) to the canon exactly: include `week`, `week_label`, the warmup pattern (`target_sets: null`, `target_reps: ""`, `reps_in_reserve: null`, `duration_seconds`), and confirm `slug`/`reps_in_reserve`/`rest_seconds`. Deploy: scp + reload (kill live container + continuation wipe).

## Error handling / edge cases
- **Warmup nulls** are canonical (`.nullable()`), not drift — validate clean, decode to 0 on iOS.
- **Payne emits an off-canon plan** → host warns (visible in logs), still forwards; iOS decodes leniently-on-defaults where it can. Loud, not silent.
- **Unknown extra keys** in plan_json (e.g. a future field) → Zod `.object` strips them by default (non-strict); iOS Codable ignores them. Non-breaking.

## Testing
- **TS:** `PlanJsonSchema` accepts the canon (incl. null-warmup) + rejects a missing `slug`; the new fixture round-trips through `AnyEnvelope` (`fixtures.test.ts`, count 24).
- **Host (vitest):** outbound `workout_plan` with a bad `plan_json` → `logV2Warn` called + still forwarded; good plan → no warn.
- **iOS (XCTest):** model decodes the shared fixture (warmup→0, lift fields); canonical encode round-trip; `ProtocolFixtureTests` count 24.
- **Manual (build 36):** ask Payne → card renders with the day/intensity/exercise count.

## Affected files
| File | Change |
|------|--------|
| `shared/ios-app-protocol/v2.ts` | `PlanExerciseSchema` + `PlanJsonSchema`; `WorkoutPlan.plan_json` typed. |
| `shared/ios-app-protocol/fixtures/workout_plan.json` | **New** canonical fixture. |
| `shared/ios-app-protocol/fixtures.test.ts` | Count 23→24. |
| `src/channels/ios-app/v2/index.ts` | Validate `plan_json` (warn+forward) in the workout outbound branch. |
| `ios/.../Protocol/…` `ProtocolFixtureTests.swift` | Count 23→24. |
| `ios/.../Models/Workout.swift` | CodingKeys = canon; drop dual-key; canonical encode; keep null-tolerance. |
| `ios/.../JarvisAppTests/WorkoutPlanDecodeTests.swift` | Load the shared fixture; keep round-trip. |
| `groups/payne/skills/workout-mode/SKILL.md` | Document `plan_json` = canon (scp + reload). |
| `ios/JarvisApp/project.yml` | Build 36. |

## Non-goals
- Changing Payne's data files (`programs`/`sessions`/cards already use this vocab).
- Typing V2.swift's wire `plan_json` (`JSONValue` stays; the rich `Models/Workout.swift` is the Swift mirror, pinned via the fixture test).
- A JSON-schema on the `workout.ts` tool param (host validation + skill doc cover it).
- Reconciling `set_log`'s `exercise_slug` with the plan's `slug` (separate, already-shipped envelope; out of scope).
