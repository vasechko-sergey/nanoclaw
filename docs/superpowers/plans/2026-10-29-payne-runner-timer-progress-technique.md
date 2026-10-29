# Workout runner: hold ring, screen awake, partial progress, technique — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full-screen hold ring, screen kept on during timers, partial exercises visible in the header, and an expandable technique block fed from the exercise cards.

**Architecture:** Technique text travels card → `build-plan.js` → runner `normalizeExercise` (whitelist, must pass it) → host (validates, forwards) → iOS `ExercisePlan`. The swap tool attaches the same text to each alternative. iOS logic (segments, captions) goes into `WorkoutRunnerLogic` and `HoldTimer` as pure, unit-tested functions; views stay thin and are checked by render tests.

**Tech Stack:** Bun (Payne scripts, agent-runner, `bun:test`), TypeScript + zod (shared protocol, vitest), SwiftUI + XCTest (iOS, `@testable import Jarvis`).

Spec: `docs/superpowers/specs/2026-10-29-payne-runner-timer-progress-technique-design.md`.

## Global Constraints

- iOS build number: `CURRENT_PROJECT_VERSION` 129 → `"130"` in `ios/JarvisApp/project.yml`, then `xcodegen generate`, commit `project.pbxproj`.
- iOS tests: `xcodebuild -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:JarvisAppTests/<Suite>` — never pipe to `tail`; read `** TEST SUCCEEDED **` / `Test Suite … passed`. Only one xcodebuild at a time (the laptop can't take two).
- Container tests import from `bun:test`; host/shared tests use vitest.
- `groups/payne/` is gitignored: edit there, test there, deploy by scp to VDS `agents/payne/scripts/` after diffing the VDS copy. Never SSH-edit tracked files on the VDS.
- `git add` explicit paths only (a parallel session may work on main). Leave `.claude/settings.local.json` and `deploy/vds/*` untracked files alone.
- Plain Russian in UI copy, no abbreviations. Strings exactly as written in this plan.
- Commit attribution line: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Files

| File | Change |
|---|---|
| `groups/payne/scripts/build-plan.js` | `techniqueFromCard`, `loadCards` (replaces `loadCardNames`), `cardTechnique` param |
| `groups/payne/scripts/build-plan.test.js` | technique tests |
| `container/agent-runner/src/exercise-technique.ts` (new) | `readTechnique(exercisesDir, slug)` |
| `container/agent-runner/src/exercise-technique.test.ts` (new) | tests |
| `container/agent-runner/src/workout-plan.ts` | `normalizeExercise` passes `technique` |
| `container/agent-runner/src/workout-plan.test.ts` | passthrough test |
| `container/agent-runner/src/mcp-tools/workout.ts` | swap alternatives carry `technique` |
| `container/agent-runner/src/mcp-tools/workout.test.ts` | swap technique test |
| `shared/ios-app-protocol/v2.ts` | `TechniqueSchema` on plan exercise + swap alternative |
| `shared/ios-app-protocol/plan-json.test.ts` | schema accepts technique |
| `ios/.../Models/Workout.swift` | `ExerciseTechnique`, `ExercisePlan.technique` |
| `ios/.../Protocol/V2.swift` | `ExerciseSwapAlternative.technique` |
| `ios/.../Views/Workout/SwapSheet.swift` | `Alternative.technique`, `.confirm(…, technique:)` |
| `ios/.../Services/AppCoordinator.swift` | map technique into `SwapResponse` |
| `ios/.../Views/ChatView.swift` | pass technique to `applySwap` |
| `ios/.../Services/WorkoutCoordinator.swift` | `applySwap(…, newTechnique:)` |
| `ios/.../Models/WorkoutRunnerLogic.swift` | partial segments, `previewStateTag`, `holdTitle`, `holdCaption` |
| `ios/.../Services/HoldTimer.swift` | `progress`, `overtimeSec`, `lastHeldSec` |
| `ios/.../Views/Workout/HoldTimerOverlay.swift` (new) | full-screen ring |
| `ios/.../Views/Workout/TimedSetCard.swift` | drop inline stopwatch, read `lastHeldSec` |
| `ios/.../Views/Workout/TechniqueStrip.swift` (new) | collapsed row + expanded text |
| `ios/.../Views/WorkoutView.swift` | overlay, idle timer, partial segment, technique |
| `ios/.../JarvisAppTests/*` | unit + render tests listed per task |

(`ios/...` = `ios/JarvisApp/Sources/JarvisApp`, tests in `ios/JarvisApp/Sources/JarvisAppTests`.)

---

### Task 1: Technique in the plan builder (Payne script)

**Files:**
- Modify: `groups/payne/scripts/build-plan.js` (`buildPlanJson` signature ~line 42, exercise map, `loadCardNames` ~line 167, CLI ~line 237)
- Test: `groups/payne/scripts/build-plan.test.js`

**Interfaces:**
- Produces: `export function techniqueFromCard(card) → { steps: {title,text}[], warnings: string[] } | null`; `buildPlanJson({ …, cardTechnique = new Map() })` adds `technique` to an exercise when the map has it. Wire shape used by every later task:
  `technique: { steps: [{ title: string, text: string }], warnings: string[] }`.

- [ ] **Step 0: Record the starting point** — `sha256sum groups/payne/scripts/build-plan.js groups/payne/scripts/build-plan.test.js` and the same on the VDS (`agents/payne/scripts/`). They must match (synced 2026-10-26); if not, pull the VDS copies first. Write both shas into the task notes — Task 7 compares against them.

- [ ] **Step 1: Write the failing tests** (append to `build-plan.test.js`; add `techniqueFromCard` to the import from `./build-plan.js`)

```js
describe('technique from the exercise card', () => {
  const card = {
    rules: [
      { text: 'Исходное положение', description: 'Спина прижата к спинке.' },
      { text: 'Жим', description: '  ' },
      { text: '', description: 'Без заголовка — шаг всё равно нужен.' },
    ],
    warnings: [{ text: 'Колени по линии стоп.' }, { text: '' }],
  };

  it('maps rules to steps and warnings to lines, dropping empty text', () => {
    expect(techniqueFromCard(card)).toEqual({
      steps: [
        { title: 'Исходное положение', text: 'Спина прижата к спинке.' },
        { title: 'Жим', text: '' },
        { title: '', text: 'Без заголовка — шаг всё равно нужен.' },
      ],
      warnings: ['Колени по линии стоп.'],
    });
  });

  it('is null when the card has nothing to say', () => {
    expect(techniqueFromCard({})).toBeNull();
    expect(techniqueFromCard({ rules: [{ text: ' ', description: '' }], warnings: [] })).toBeNull();
  });

  it('rides on the plan exercise when the card has it, absent otherwise', () => {
    const cardTechnique = new Map([['zhim', techniqueFromCard(card)]]);
    const plan = buildPlanJson({ program, dayKey: 'upper_a', workoutId: 'w', prescriptions, cardNames, cardTechnique });
    const bySlug = Object.fromEntries(plan.exercises.map((e) => [e.slug, e]));
    expect(bySlug.zhim.technique.steps[0].title).toBe('Исходное положение');
    expect(bySlug.tyaga.technique).toBeUndefined();
    expect('technique' in bySlug.hodba).toBe(false);
  });
});
```

A step is dropped only when both title and text are blank; a step with a title and a blank text stays (the title alone is still an instruction).

- [ ] **Step 2: Run, expect FAIL** — `cd groups/payne/scripts && bun test ./build-plan.test.js` → `techniqueFromCard` is not exported.

- [ ] **Step 3: Implement**

In `build-plan.js` add above `buildPlanJson`:

```js
/**
 * The card's technique as the app shows it: antitrainer's `rules` (a step
 * title + its text) and `warnings`. Text goes as the card has it. null when
 * there is nothing to show, so the plan carries no empty block.
 */
export function techniqueFromCard(card) {
  const str = (v) => (typeof v === 'string' ? v.trim() : '');
  const steps = (Array.isArray(card?.rules) ? card.rules : [])
    .map((r) => ({ title: str(r?.text), text: str(r?.description) }))
    .filter((s) => s.title || s.text);
  const warnings = (Array.isArray(card?.warnings) ? card.warnings : [])
    .map((w) => str(w?.text))
    .filter(Boolean);
  return steps.length || warnings.length ? { steps, warnings } : null;
}
```

Signature: `export function buildPlanJson({ program, dayKey, workoutId, prescriptions = new Map(), cardNames = new Map(), cardTechnique = new Map(), healthSignal = null, overrides = null })`; add `@param cardTechnique Map<slug, technique> from exercises/<slug>.json` to the JSDoc. Right after `if (name) out.name_ru = name;`:

```js
    const technique = cardTechnique.get(slug);
    if (technique) out.technique = technique;
```

Replace `loadCardNames` with:

```js
async function loadCards(exercisesDir, slugs) {
  const names = new Map();
  const technique = new Map();
  for (const slug of slugs) {
    try {
      const card = JSON.parse(await Bun.file(`${exercisesDir}/${slug}.json`).text());
      if (typeof card.name_ru === 'string' && card.name_ru) names.set(slug, card.name_ru);
      const t = techniqueFromCard(card);
      if (t) technique.set(slug, t);
    } catch {
      // no card / unreadable → iOS prettifies the slug, no technique block
    }
  }
  return { names, technique };
}
```

CLI: `const { names: cardNames, technique: cardTechnique } = await loadCards(exercisesDir, slugs);` and pass `cardTechnique` to `buildPlanJson`.

- [ ] **Step 4: Run, expect PASS** — `bun test ./build-plan.test.js` (all, not only the new ones; was 23/23 before).

- [ ] **Step 5: Real-card smoke** — the cards live on the VDS only. `ssh root@148.253.211.164 'cat /home/nanoclaw/nanoclaw/data/user-memory/owner/payne/exercises/zhim-nogami.json' > /private/tmp/claude-501/-Users-serg-git-nanoclaw/d401cc92-4624-427c-9e8e-0692a062df4b/scratchpad/zhim-nogami.json`, then from `groups/payne/scripts`: `bun -e "import {techniqueFromCard} from './build-plan.js'; console.log(JSON.stringify(techniqueFromCard(JSON.parse(await Bun.file('/private/tmp/claude-501/-Users-serg-git-nanoclaw/d401cc92-4624-427c-9e8e-0692a062df4b/scratchpad/zhim-nogami.json').text())),null,1))"` → 3 steps, 2 warnings.

No commit (gitignored). Deploy happens in Task 7.

---

### Task 2: Runner + shared schema carry technique

**Files:**
- Create: `container/agent-runner/src/exercise-technique.ts`, `container/agent-runner/src/exercise-technique.test.ts`
- Modify: `container/agent-runner/src/workout-plan.ts` (`normalizeExercise` ~line 188), `container/agent-runner/src/mcp-tools/workout.ts` (swap alternatives ~line 255), `shared/ios-app-protocol/v2.ts` (`PlanExerciseSchema` line 44, swap `alternatives` ~line 399)
- Test: `container/agent-runner/src/workout-plan.test.ts`, `container/agent-runner/src/mcp-tools/workout.test.ts`, `shared/ios-app-protocol/plan-json.test.ts`

**Interfaces:**
- Consumes: wire shape from Task 1.
- Produces: `export interface ExerciseTechnique { steps: { title: string; text: string }[]; warnings: string[] }`, `export function readTechnique(exercisesDir: string, slug: string): ExerciseTechnique | undefined`; zod `TechniqueSchema`; swap alternative key `technique`.

- [ ] **Step 1: Failing tests**

`container/agent-runner/src/exercise-technique.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readTechnique } from './exercise-technique.js';

describe('readTechnique', () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'technique-')); });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('reads steps and warnings from the card', () => {
    writeFileSync(join(dir, 'zhim.json'), JSON.stringify({
      rules: [{ text: 'Жим', description: 'На выдохе.' }, { text: ' ', description: '' }],
      warnings: [{ text: 'Колени не блокировать.' }],
    }));
    expect(readTechnique(dir, 'zhim')).toEqual({
      steps: [{ title: 'Жим', text: 'На выдохе.' }],
      warnings: ['Колени не блокировать.'],
    });
  });

  it('is undefined for no card, a broken card, or an empty one', () => {
    expect(readTechnique(dir, 'missing')).toBeUndefined();
    writeFileSync(join(dir, 'broken.json'), '{');
    expect(readTechnique(dir, 'broken')).toBeUndefined();
    writeFileSync(join(dir, 'empty.json'), JSON.stringify({ rules: [], warnings: [] }));
    expect(readTechnique(dir, 'empty')).toBeUndefined();
  });

  it('refuses a slug that walks out of the directory', () => {
    expect(readTechnique(dir, '../etc/passwd')).toBeUndefined();
  });
});
```

In `workout-plan.test.ts`, inside `describe('sendWorkoutPlan …')`:

```ts
  it('passes the technique block through to the wire', () => {
    const technique = { steps: [{ title: 'Жим', text: 'На выдохе.' }], warnings: ['Колени по линии стоп.'] };
    const plan = { day_name: 'Ноги А', week: 3, week_label: 'тяжёлая', exercises: [{ slug: 'zhim-nogami', target_sets: 4, technique }] };
    sendWorkoutPlan('2026-10-02', plan, { agentDir: dir, exercisesDir: join(dir, 'exercises') });
    const ex = JSON.parse(getUndeliveredMessages()[0].content).payload.plan_json.exercises[0];
    expect(ex.technique).toEqual(technique);
  });
```

In `mcp-tools/workout.test.ts`, inside `describe('swap alternatives carry name_ru + derived sha256')` (it already sets `WORKOUT_EXERCISES_DIR = exDir`):

```ts
    it('attaches the alternative\'s technique from its card', async () => {
      writeFileSync(join(exDir, 'leg_press.json'), JSON.stringify({
        rules: [{ text: 'Жим', description: 'На выдохе.' }],
        warnings: [],
      }));
      await workoutSwap.handler({
        workout_id: 'w1',
        from_exercise_slug: 'squat',
        options: [{ slug: 'leg_press', reason: 'knee' }, { slug: 'no_card', reason: 'x' }],
      });
      const alts = JSON.parse(getUndeliveredMessages()[0].content).payload.alternatives;
      expect(alts[0].technique).toEqual({ steps: [{ title: 'Жим', text: 'На выдохе.' }], warnings: [] });
      expect('technique' in alts[1]).toBe(false);
    });
```

In `shared/ios-app-protocol/plan-json.test.ts` (vitest; follow the file's existing imports of `PlanJsonSchema`):

```ts
  it('accepts an exercise technique block and rejects a malformed one', () => {
    const base = { day_name: 'Верх', week: 1, week_label: 'лёгкая' };
    const ex = { slug: 'zhim', target_sets: 3, target_reps: '8-10', reps_in_reserve: 2, rest_seconds: 120 };
    const ok = PlanJsonSchema.safeParse({ ...base, exercises: [{ ...ex, technique: { steps: [{ title: 'Жим', text: 'На выдохе.' }], warnings: [] } }] });
    expect(ok.success).toBe(true);
    const bad = PlanJsonSchema.safeParse({ ...base, exercises: [{ ...ex, technique: { steps: 'нет' } }] });
    expect(bad.success).toBe(false);
  });
```

- [ ] **Step 2: Run, expect FAIL** — `cd container/agent-runner && bun test src/exercise-technique.test.ts src/workout-plan.test.ts src/mcp-tools/workout.test.ts` (missing module; technique dropped by `normalizeExercise`; no technique on alternatives); `pnpm exec vitest run shared/ios-app-protocol/plan-json.test.ts` (malformed technique accepted — unknown keys are ignored).

- [ ] **Step 3: Implement**

`container/agent-runner/src/exercise-technique.ts`:

```ts
/**
 * Technique text for an exercise, read from its card
 * (`<exercisesDir>/<slug>.json`, antitrainer `rules` + `warnings`). Same
 * mapping as Payne's scripts/build-plan.js `techniqueFromCard` — the plan gets
 * it from there, a swapped-in exercise gets it from here.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface ExerciseTechnique {
  steps: { title: string; text: string }[];
  warnings: string[];
}

const SAFE_SLUG = /^[a-z0-9_-]+$/i;

export function readTechnique(exercisesDir: string, slug: string): ExerciseTechnique | undefined {
  if (!SAFE_SLUG.test(slug)) return undefined;
  let card: { rules?: unknown; warnings?: unknown };
  try {
    card = JSON.parse(readFileSync(join(exercisesDir, `${slug}.json`), 'utf8'));
  } catch {
    return undefined;
  }
  const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '');
  const rules = Array.isArray(card?.rules) ? (card.rules as Array<Record<string, unknown>>) : [];
  const warns = Array.isArray(card?.warnings) ? (card.warnings as Array<Record<string, unknown>>) : [];
  const steps = rules.map((r) => ({ title: str(r?.text), text: str(r?.description) })).filter((s) => s.title || s.text);
  const warnings = warns.map((w) => str(w?.text)).filter(Boolean);
  return steps.length || warnings.length ? { steps, warnings } : undefined;
}
```

`workout-plan.ts` `normalizeExercise`, before `return out;`:

```ts
  // Technique text from the card (build-plan.js) — an object, passed as is.
  if (e.technique && typeof e.technique === 'object') out.technique = e.technique;
```

Also add `technique` to the field list in the JSDoc above `normalizeExercise`.

`mcp-tools/workout.ts`: `import { readTechnique } from '../exercise-technique.js';` and in the `alternatives: options.map((o) => ({ … }))` object add, after the weight line:

```ts
          ...(() => { const t = readTechnique(exercisesDir, o.slug); return t ? { technique: t } : {}; })(),
```

`shared/ios-app-protocol/v2.ts`, above `PlanExerciseSchema`:

```ts
// Technique from the exercise card (antitrainer rules + warnings), shown in
// the runner's collapsible block. Optional — cards without it send nothing.
export const TechniqueSchema = z.object({
  steps: z.array(z.object({ title: z.string(), text: z.string() })),
  warnings: z.array(z.string()),
});
export type TechniqueSchema = z.infer<typeof TechniqueSchema>;
```

Add `technique: TechniqueSchema.optional(),` to `PlanExerciseSchema` and to the swap `alternatives` item object (after `weight_kg_target`).

- [ ] **Step 4: Run, expect PASS** — same commands as Step 2, plus the full suites: `cd container/agent-runner && bun test`, `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`, `pnpm run build`, `pnpm test`.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/exercise-technique.ts container/agent-runner/src/exercise-technique.test.ts container/agent-runner/src/workout-plan.ts container/agent-runner/src/workout-plan.test.ts container/agent-runner/src/mcp-tools/workout.ts container/agent-runner/src/mcp-tools/workout.test.ts shared/ios-app-protocol/v2.ts shared/ios-app-protocol/plan-json.test.ts
git commit -m "feat(workout): carry exercise technique from the card to the app

The plan builder adds the card's rules and warnings to each exercise; the
runner's normalizeExercise whitelist would have dropped them, so it passes
technique through. A swapped-in exercise gets its own from its card.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: iOS model — technique on the plan and through a swap

**Files:**
- Modify: `ios/.../Models/Workout.swift` (`ExercisePlan` lines 10–98), `ios/.../Protocol/V2.swift` (`ExerciseSwapAlternative` ~line 460), `ios/.../Views/Workout/SwapSheet.swift` (`Alternative` line 22, `SwapAction.confirm` line 62, `confirm(newSlug:alt:)` line 243), `ios/.../Services/AppCoordinator.swift` (~line 563), `ios/.../Views/ChatView.swift` (~line 635), `ios/.../Services/WorkoutCoordinator.swift` (`applySwap` line 317)
- Test: `ios/.../JarvisAppTests/WorkoutPlanDecodeTests.swift`, `ActiveWorkoutStoreTests.swift`, `WorkoutCoordinatorTests.swift`, `SwapSheetTests.swift`

**Interfaces:**
- Produces:

```swift
struct ExerciseTechnique: Codable, Equatable {
    struct Step: Codable, Equatable { let title: String; let text: String }
    let steps: [Step]
    let warnings: [String]
}
// ExercisePlan
var technique: ExerciseTechnique?          // key "technique"
// SwapResponse.Alternative
var technique: ExerciseTechnique?
// SwapAction
case confirm(newSlug: String, persist: Bool, nameRu: String?, sha256: String?,
             weightKgTarget: Double?, technique: ExerciseTechnique?)
// WorkoutCoordinator
func applySwap(originalSlug: String, newSlug: String, newName: String? = nil, newSha: String? = nil,
               newWeightTarget: Double? = nil, newTechnique: ExerciseTechnique? = nil)
```

- [ ] **Step 1: Failing tests**

`WorkoutPlanDecodeTests.swift` (add):

```swift
    func test_exercisePlan_decodesTechnique_andToleratesItsAbsence() throws {
        let json = """
        {"slug":"zhim","target_sets":3,"target_reps":"8-10","reps_in_reserve":2,"rest_seconds":120,
         "technique":{"steps":[{"title":"Жим","text":"На выдохе."}],"warnings":["Колени по линии стоп."]}}
        """.data(using: .utf8)!
        let ex = try JSONDecoder().decode(ExercisePlan.self, from: json)
        XCTAssertEqual(ex.technique?.steps, [ExerciseTechnique.Step(title: "Жим", text: "На выдохе.")])
        XCTAssertEqual(ex.technique?.warnings, ["Колени по линии стоп."])

        let bare = try JSONDecoder().decode(ExercisePlan.self, from: #"{"slug":"zhim","target_sets":3,"target_reps":"8","reps_in_reserve":2,"rest_seconds":0}"#.data(using: .utf8)!)
        XCTAssertNil(bare.technique)

        // A malformed block must not cost the whole exercise.
        let broken = try JSONDecoder().decode(ExercisePlan.self, from: #"{"slug":"zhim","target_sets":3,"target_reps":"8","reps_in_reserve":2,"rest_seconds":0,"technique":{"steps":"x"}}"#.data(using: .utf8)!)
        XCTAssertNil(broken.technique)
        XCTAssertEqual(broken.exerciseSlug, "zhim")
    }

    func test_exercisePlan_technique_roundTrips() throws {
        var ex = ExercisePlan(exerciseSlug: "zhim", targetSets: 3, targetReps: "8", targetRir: 2, restSec: 0)
        ex.technique = ExerciseTechnique(steps: [.init(title: "Жим", text: "На выдохе.")], warnings: [])
        let back = try JSONDecoder().decode(ExercisePlan.self, from: JSONEncoder().encode(ex))
        XCTAssertEqual(back.technique, ex.technique)
    }
```

`WorkoutCoordinatorTests.swift` — next to `test_applySwap_updatesNameAndImageManifest`, using the same setup helper that test uses:

```swift
    func test_applySwap_carriesTheNewExercisesTechnique() throws {
        // same plan/queue setup as test_applySwap_updatesNameAndImageManifest
        let tech = ExerciseTechnique(steps: [.init(title: "Жим", text: "На выдохе.")], warnings: ["Спина прижата."])
        coord.applySwap(originalSlug: "ex-1", newSlug: "ex-1-alt", newTechnique: tech)
        XCTAssertEqual(coord.plan.exercises[0].technique, tech)
        coord.applySwap(originalSlug: "ex-1-alt", newSlug: "ex-1-alt-2")
        XCTAssertNil(coord.plan.exercises[0].technique, "no technique from the server → none, not the replaced one's")
    }
```

`SwapSheetTests.test_swapAction_caseEquality`: add `technique: nil` to the `.confirm(…)` construction and bind a sixth value `tech` in the `if case let`, asserting `XCTAssertNil(tech)`.

- [ ] **Step 2: Run, expect FAIL (compile)** — `xcodebuild … test -only-testing:JarvisAppTests/WorkoutPlanDecodeTests -only-testing:JarvisAppTests/WorkoutCoordinatorTests -only-testing:JarvisAppTests/SwapSheetTests`.

- [ ] **Step 3: Implement**

`Workout.swift` — above `struct ExercisePlan`:

```swift
/// How an exercise is done, from its card (antitrainer `rules` + `warnings`),
/// shown in the runner's collapsible block. nil when the card has none.
struct ExerciseTechnique: Codable, Equatable {
    struct Step: Codable, Equatable {
        let title: String
        let text: String
    }
    let steps: [Step]
    let warnings: [String]
}
```

In `ExercisePlan`: property `var technique: ExerciseTechnique?` after `weightKgTarget` with a one-line doc comment («Technique block from the card — nil hides the strip.»); `case technique` in `CodingKeys`; decode `technique = try? c.decode(ExerciseTechnique.self, forKey: .technique)`; encode `try c.encodeIfPresent(technique, forKey: .technique)`. Leave the memberwise `init` as is (callers set `technique` afterwards; it is a `var`).

`V2.swift` `ExerciseSwapAlternative`: `var technique: ExerciseTechnique?` + init param `technique: ExerciseTechnique? = nil`.

`SwapSheet.swift`: `Alternative.technique` (`var technique: ExerciseTechnique?`, init param with default nil); `.confirm` gains `technique: ExerciseTechnique?`; `confirm(newSlug:alt:)` passes `technique: alt?.technique`. Update the doc comment above `.confirm` to mention the technique.

`AppCoordinator.swift` mapping: add `technique: $0.technique` to the `.init(…)`.

`ChatView.swift`: `case .confirm(let newSlug, let persist, let nameRu, let sha256, let weightTarget, let technique):` and pass `newTechnique: technique` to `applySwap`.

`WorkoutCoordinator.applySwap`: add `newTechnique: ExerciseTechnique? = nil` and after building `replaced` set `replaced.technique = newTechnique` (make `replaced` a `var`). Add to the doc comment: «`newTechnique` — the new exercise's own; the replaced one's would describe the wrong movement.»

Check every other `.confirm(` construction or pattern compiles: `grep -rn "\.confirm(" ios/JarvisApp/Sources`.

- [ ] **Step 4: Run, expect PASS** — same `-only-testing` set plus `ActiveWorkoutStoreTests`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisApp/Views/Workout/SwapSheet.swift ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutPlanDecodeTests.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift ios/JarvisApp/Sources/JarvisAppTests/SwapSheetTests.swift
git commit -m "feat(ios): decode exercise technique and keep it through a swap

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: iOS logic — partial segments, captions, hold timer progress

**Files:**
- Modify: `ios/.../Models/WorkoutRunnerLogic.swift` (`ProgressSegment` ~line 140, `progressSegments` ~line 155), `ios/.../Services/HoldTimer.swift`
- Test: `ios/.../JarvisAppTests/WorkoutRunnerLogicTests.swift` (rewrite the four `progressSegments` tests to the new signature + new ones), `TimedExerciseTests.swift`

**Interfaces:**
- Produces:

```swift
struct ProgressSegment: Equatable {
    enum Kind: Equatable { case done, partial, active, skipped, upcoming }
    let kind: Kind
    let isPreview: Bool
    /// Share of the bar to fill: 1 for done, sets/target for partial, 0 otherwise.
    let fill: Double
}
static func progressSegments(sets: [Int], targetSets: [Int], isDuration: [Bool],
                             activeIdx: Int, previewIdx: Int) -> [ProgressSegment]
static func previewStateTag(sets: Int, targetSets: Int) -> String
static func holdTitle(name: String, isTimedSets: Bool, setIdx: Int) -> String
static func holdCaption(target: Int, elapsed: Int) -> String?
// HoldTimer
var progress: Double { get }       // min(1, elapsed/target); 0 without a target
var overtimeSec: Int { get }       // max(0, elapsed − target) once reached; 0 without a target
@Published private(set) var lastHeldSec: Int?   // set by stop(), cleared by start()/reset()
```

- [ ] **Step 1: Failing tests**

`WorkoutRunnerLogicTests.swift` — replace the four existing `test_progressSegments_*` tests with these (same scenarios, new signature) and add the partial ones:

```swift
    func test_progressSegments_skippedIsDistinctFromDone() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [3, 3, 0, 0, 0], targetSets: [3, 3, 3, 3, 3],
            isDuration: [false, false, false, false, false], activeIdx: 3, previewIdx: 3)
        XCTAssertEqual(segs.map(\.kind), [.done, .done, .skipped, .active, .upcoming])
        XCTAssertFalse(segs[3].isPreview)
    }

    func test_progressSegments_passedDurationCountsAsDone() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [0, 3, 0], targetSets: [0, 3, 3],
            isDuration: [true, false, false], activeIdx: 2, previewIdx: 2)
        XCTAssertEqual(segs.map(\.kind), [.done, .done, .active])
    }

    func test_progressSegments_workedAfterActiveStaysDone_onJumpBack() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [0, 0, 3], targetSets: [3, 3, 3],
            isDuration: [false, false, false], activeIdx: 0, previewIdx: 0)
        XCTAssertEqual(segs.map(\.kind), [.active, .upcoming, .done])
    }

    func test_progressSegments_previewMarkOnNonActive() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [3, 0, 0, 0], targetSets: [3, 3, 3, 3],
            isDuration: [false, false, false, false], activeIdx: 1, previewIdx: 3)
        XCTAssertEqual(segs.map(\.kind), [.done, .active, .upcoming, .upcoming])
        XCTAssertTrue(segs[3].isPreview)
        XCTAssertFalse(segs[1].isPreview)
    }

    /// 2026-10-29: one set of three on the press, then on to the row — the
    /// header painted the press as done.
    func test_progressSegments_oneOfThreeIsPartial_aThirdFilled() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [3, 1, 0, 0], targetSets: [3, 3, 3, 2],
            isDuration: [false, false, false, false], activeIdx: 2, previewIdx: 2)
        XCTAssertEqual(segs.map(\.kind), [.done, .partial, .active, .upcoming])
        XCTAssertEqual(segs[1].fill, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(segs[0].fill, 1)
        XCTAssertEqual(segs[2].fill, 0)
    }

    func test_progressSegments_partialAheadOfActive_andBonusIsDone() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [4, 0, 2], targetSets: [3, 3, 4],
            isDuration: [false, false, false], activeIdx: 1, previewIdx: 1)
        XCTAssertEqual(segs.map(\.kind), [.done, .active, .partial])
        XCTAssertEqual(segs[2].fill, 0.5, accuracy: 0.0001)
    }

    func test_progressSegments_warmupWithAnyLoggedTimeIsDone() {
        let segs = WorkoutRunnerLogic.progressSegments(
            sets: [1, 0], targetSets: [0, 3], isDuration: [true, false], activeIdx: 1, previewIdx: 1)
        XCTAssertEqual(segs[0].kind, .done)
    }

    func test_previewStateTag() {
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 0, targetSets: 3), "ещё не начато")
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 1, targetSets: 3), "1 из 3 подходов")
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 3, targetSets: 21), "3 из 21 подхода")
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 3, targetSets: 3), "пройдено")
        XCTAssertEqual(WorkoutRunnerLogic.previewStateTag(sets: 1, targetSets: 0), "пройдено")
    }

    func test_holdTitle() {
        XCTAssertEqual(WorkoutRunnerLogic.holdTitle(name: "Планка", isTimedSets: true, setIdx: 0), "ПЛАНКА · ПОДХОД 1")
        XCTAssertEqual(WorkoutRunnerLogic.holdTitle(name: "Ходьба на беговой дорожке", isTimedSets: false, setIdx: 0),
                       "ХОДЬБА НА БЕГОВОЙ ДОРОЖКЕ")
    }

    func test_holdCaption() {
        XCTAssertEqual(WorkoutRunnerLogic.holdCaption(target: 60, elapsed: 42), "цель 1:00")
        XCTAssertEqual(WorkoutRunnerLogic.holdCaption(target: 60, elapsed: 60), "цель есть · +0:00")
        XCTAssertEqual(WorkoutRunnerLogic.holdCaption(target: 60, elapsed: 67), "цель есть · +0:07")
        XCTAssertNil(WorkoutRunnerLogic.holdCaption(target: 0, elapsed: 30))
    }
```

`TimedExerciseTests.swift` (add):

```swift
    func test_holdTimer_progressAndOvertime() {
        var clock = Date(timeIntervalSince1970: 0)
        let timer = HoldTimer()
        timer.now = { clock }
        timer.start(targetSec: 60)
        clock = clock.addingTimeInterval(30); timer.refresh()
        XCTAssertEqual(timer.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(timer.overtimeSec, 0)
        clock = clock.addingTimeInterval(37); timer.refresh()
        XCTAssertEqual(timer.progress, 1)
        XCTAssertEqual(timer.overtimeSec, 7)
    }

    func test_holdTimer_noTarget_noProgress() {
        var clock = Date(timeIntervalSince1970: 0)
        let timer = HoldTimer()
        timer.now = { clock }
        timer.start(targetSec: 0)
        clock = clock.addingTimeInterval(40); timer.refresh()
        XCTAssertEqual(timer.progress, 0)
        XCTAssertEqual(timer.overtimeSec, 0)
    }

    func test_holdTimer_lastHeld_setOnStop_clearedOnStartAndReset() {
        var clock = Date(timeIntervalSince1970: 0)
        let timer = HoldTimer()
        timer.now = { clock }
        timer.start(targetSec: 60)
        clock = clock.addingTimeInterval(52)
        timer.stop()
        XCTAssertEqual(timer.lastHeldSec, 52)
        timer.start(targetSec: 60)
        XCTAssertNil(timer.lastHeldSec)
        timer.stop()
        timer.reset()
        XCTAssertNil(timer.lastHeldSec)
    }
```

- [ ] **Step 2: Run, expect FAIL (compile)** — `-only-testing:JarvisAppTests/WorkoutRunnerLogicTests -only-testing:JarvisAppTests/TimedExerciseTests`.

- [ ] **Step 3: Implement**

`WorkoutRunnerLogic.swift` — replace `ProgressSegment` and `progressSegments` (keep the doc comment, reworded):

```swift
    /// One cell of the top progress bar — one per exercise, equal width.
    struct ProgressSegment: Equatable {
        enum Kind: Equatable { case done, partial, active, skipped, upcoming }
        let kind: Kind
        let isPreview: Bool
        /// Share of the bar to fill: 1 for done, sets/target for partial, 0 otherwise.
        let fill: Double
    }

    /// Equal segment per exercise, driven by TRUTH (not position). `.done` once
    /// the sets reach the target (bonus sets too) — or, without a set target
    /// (warmup, cardio), once anything is logged. Sets short of the target are
    /// `.partial` wherever the exercise sits: 2026-10-29 one set of three read
    /// as done. The same rule as `hasWorkLeft` for the rest hints. Nothing
    /// logged behind the cursor is `.skipped`, except a passed timed block
    /// (warmup walked past), which is `.done`. The previewed exercise
    /// (when ≠ active) is marked for an outline.
    static func progressSegments(sets: [Int], targetSets: [Int], isDuration: [Bool],
                                 activeIdx: Int, previewIdx: Int) -> [ProgressSegment] {
        (0..<max(sets.count, 1)).map { i in
            let done = i < sets.count ? sets[i] : 0
            let target = i < targetSets.count ? targetSets[i] : 0
            let timed = i < isDuration.count && isDuration[i]
            let kind: ProgressSegment.Kind
            var fill = 0.0
            if i == activeIdx {
                kind = .active
            } else if done > 0 {
                if target > 0 && done < target {
                    kind = .partial
                    fill = Double(done) / Double(target)
                } else {
                    kind = .done
                    fill = 1
                }
            } else if i < activeIdx {
                kind = timed ? .done : .skipped
                fill = timed ? 1 : 0
            } else {
                kind = .upcoming
            }
            return ProgressSegment(kind: kind, isPreview: i == previewIdx && previewIdx != activeIdx, fill: fill)
        }
    }

    /// Image-scrim tag for an exercise looked at but not active.
    static func previewStateTag(sets: Int, targetSets: Int) -> String {
        if sets == 0 { return "ещё не начато" }
        if targetSets > 0 && sets < targetSets {
            let word = (targetSets % 10 == 1 && targetSets % 100 != 11) ? "подхода" : "подходов"
            return "\(sets) из \(targetSets) \(word)"
        }
        return "пройдено"
    }

    /// Hold-ring header: «ПЛАНКА · ПОДХОД 1»; a warmup (no sets) shows its name.
    static func holdTitle(name: String, isTimedSets: Bool, setIdx: Int) -> String {
        let n = name.uppercased(with: Locale(identifier: "ru_RU"))
        return isTimedSets ? "\(n) · ПОДХОД \(setIdx + 1)" : n
    }

    /// Under the hold-ring digits: the target, then «цель есть · +0:07» past it.
    /// nil without a target.
    static func holdCaption(target: Int, elapsed: Int) -> String? {
        guard target > 0 else { return nil }
        if elapsed >= target { return "цель есть · +\(WorkoutSetFormat.duration(elapsed - target))" }
        return "цель \(WorkoutSetFormat.duration(target))"
    }
```

(`WorkoutSetFormat.duration` is `"%d:%02d"`: 0 → «0:00», 7 → «0:07».)

`HoldTimer.swift`: add

```swift
    /// Time of the hold just stopped — the card drops it into its wheels.
    /// nil once a new hold starts or the watch is reset.
    @Published private(set) var lastHeldSec: Int?

    /// Ring fill: elapsed over the target, capped at 1. 0 without a target.
    var progress: Double {
        targetSec > 0 ? min(1, Double(elapsedSec) / Double(targetSec)) : 0
    }

    /// Seconds past the target once reached; 0 before it or without one.
    var overtimeSec: Int {
        targetSec > 0 ? max(0, elapsedSec - targetSec) : 0
    }
```

In `stop()` set `lastHeldSec = Int(elapsed)` before `halt()` (and in the not-running early return leave it as is). `start()` already calls `reset()` — make `reset()` set `lastHeldSec = nil`. Note `stop()` calls `halt()` (not `reset()`), so `lastHeldSec` survives a stop and `targetSec` survives too.

Update the call site in `WorkoutView.progressSegments` so the target compiles (the view work itself is Task 5):

```swift
        WorkoutRunnerLogic.progressSegments(
            sets: coordinator.logged.map { $0.sets.count },
            targetSets: coordinator.plan.exercises.map { $0.targetSets },
            isDuration: coordinator.plan.exercises.map { $0.isDuration },
            activeIdx: coordinator.currentExerciseIdx,
            previewIdx: previewIdx)
```

- [ ] **Step 4: Run, expect PASS** — same suites, then `-only-testing:JarvisAppTests` (whole unit target) to catch other callers.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift ios/JarvisApp/Sources/JarvisApp/Services/HoldTimer.swift ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift ios/JarvisApp/Sources/JarvisAppTests/TimedExerciseTests.swift
git commit -m "feat(ios): partial exercises in the header logic, hold ring progress

One set of three painted the segment as done. A segment is done once the
sets reach the target; short of it, partial with the share filled.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: iOS views — hold ring overlay, screen awake, partial segment

**Files:**
- Create: `ios/.../Views/Workout/HoldTimerOverlay.swift`
- Modify: `ios/.../Views/Workout/TimedSetCard.swift`, `ios/.../Views/WorkoutView.swift`
- Test: `ios/.../JarvisAppTests/WorkoutViewTimedRenderTests.swift` (extend), new `WorkoutViewProgressRenderTests.swift`

**Interfaces:**
- Consumes: Task 4 (`holdTitle`, `holdCaption`, `progress`, `overtimeSec`, `lastHeldSec`, `ProgressSegment.fill`, `.partial`, `previewStateTag`).
- Produces: `struct HoldTimerOverlay: View { @ObservedObject var timer: HoldTimer; let title: String; var onStop: () -> Void }` shown only while `timer.running`; accessibility identifier `"hold-ring"`.

- [ ] **Step 1: Failing render tests**

In `WorkoutViewTimedRenderTests.test_warmupAndPlank_showTimeWheelsAndStopwatch_notWeight`, extend the «Holding» block:

```swift
        XCTAssertTrue(running.contains("ПЛАНКА · ПОДХОД 1"), "running: \(running)")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "screen must stay on during a hold")
        // Past the target: ring full, the count keeps going.
        clock = clock.addingTimeInterval(55)   // 127 s of 120
        hold.refresh()
        spin()
        let over = texts(in: host.view)
        snapshot(window, "3b-plank-overtime")
        XCTAssertTrue(over.contains("цель есть · +0:07"), "over: \(over)")
        // «Стоп» on the ring puts the held time into the wheels.
        hold.stop()
        spin()
        let stopped = texts(in: host.view)
        snapshot(window, "3c-plank-stopped")
        XCTAssertTrue(stopped.contains { $0.contains("Записать 2:05") }, "stopped: \(stopped)")
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "screen locks again once no timer runs")
```

(`holdSeconds` rounds to the nearest 5 s: 127 → 125 = «2:05».) Keep the existing `hold.reset()` after this block.

New `WorkoutViewProgressRenderTests.swift` — copy the `texts`/`spin`/`snapshot` helpers from `WorkoutViewTimedRenderTests` (file prefix `progress-`):

```swift
@MainActor
final class WorkoutViewProgressRenderTests: XCTestCase {
    // texts(in:), spin(_:), snapshot(_:_:) — as in WorkoutViewTimedRenderTests, prefix "progress-"

    func test_oneSetOfThree_readsPartial_inCounterAndPreviewTag() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "Верх", week: 1, intensityLabel: "лёгкая",
            exercises: [
                ExercisePlan(exerciseSlug: "zhim", targetSets: 3, targetReps: "8-10", targetRir: 2,
                             restSec: 120, nameRu: "Жим лёжа", weightKgTarget: 60),
                ExercisePlan(exerciseSlug: "tyaga", targetSets: 3, targetReps: "10-12", targetRir: 2,
                             restSec: 120, nameRu: "Тяга блока", weightKgTarget: 50),
            ],
            imageManifest: []
        )
        let coord = WorkoutCoordinator(plan: plan, queue: SetLogQueue(writer: dbq))
        let view = WorkoutView(coordinator: coord, imageResolver: { _ in nil },
                               coachMessages: Empty<String, Never>().eraseToAnyPublisher(),
                               onClose: { _ in }, onSwap: { _ in })
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        spin()

        coord.logSet(reps: 9, weight: 60, repsInReserve: 2)
        coord.activate(idx: 1)
        spin()
        let t = texts(in: host.view)
        snapshot(window, "1-partial")
        XCTAssertTrue(t.contains("0/2"), "a third of the press is not a done exercise: \(t)")
    }
}
```

The preview tag wording is covered by `test_previewStateTag` (Task 4); here check the counter and look at the PNG for the third-filled segment with its ring.

- [ ] **Step 2: Run, expect FAIL** — `-only-testing:JarvisAppTests/WorkoutViewTimedRenderTests -only-testing:JarvisAppTests/WorkoutViewProgressRenderTests`.

- [ ] **Step 3: Implement**

`HoldTimerOverlay.swift`:

```swift
import SwiftUI

/// Full-screen hold ring for a plank / isometric hold / warmup, opened by
/// «Старт» on the timed card. Built like RestTimerOverlay so it reads from the
/// floor: the ring fills up to the target, then stays full while the count
/// goes on («цель есть · +0:07»). «Стоп» hands the time back to the card.
struct HoldTimerOverlay: View {
    @ObservedObject var timer: HoldTimer
    let title: String
    var onStop: () -> Void

    var body: some View {
        if timer.running {
            ZStack {
                Theme.background.opacity(0.96).ignoresSafeArea()
                VStack(spacing: 28) {
                    Text(title)
                        .font(.subheadline)
                        .tracking(1.5)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 32)

                    ZStack {
                        Circle().stroke(Theme.accent.opacity(0.15), lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: timer.progress)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: timer.progress)
                        VStack(spacing: 4) {
                            Text(WorkoutSetFormat.duration(timer.elapsedSec))
                                .font(.system(size: 52, weight: .ultraLight, design: .rounded).monospacedDigit())
                                .foregroundStyle(timer.reachedTarget ? Theme.accent : .white)
                            if let caption = WorkoutRunnerLogic.holdCaption(target: timer.targetSec, elapsed: timer.elapsedSec) {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(timer.reachedTarget ? Theme.accent : .white.opacity(0.4))
                            }
                        }
                    }
                    .frame(width: 220, height: 220)

                    Button(action: onStop) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 15, weight: .bold))
                            Text("Стоп").font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Theme.accent))
                    }
                    .frame(minHeight: 44)
                }
            }
            .transition(.opacity)
            .accessibilityIdentifier("hold-ring")
        }
    }
}
```

`TimedSetCard.swift`:
- Remove the `stopwatch` view and its use: `body` shows `HoldWheels` always and the idle `HStack` (Старт / Записать) always — delete the `if holdTimer.running { … Стоп … }` branch.
- Remove `private func stop()`.
- Add `.onChange(of: holdTimer.lastHeldSec) { _, held in if let held { set(held) } }` next to the other `onChange`s.
- Update the type's doc comment: «Running: the full-screen HoldTimerOverlay (WorkoutView); its «Стоп» drops the held time into these wheels via `holdTimer.lastHeldSec`.»

`WorkoutView.swift`:
- In `body`'s `ZStack`, after `RestTimerOverlay(…)`:

```swift
            HoldTimerOverlay(timer: holdTimer, title: holdTitle) {
                Theme.hapticSend()
                holdTimer.stop()
            }
            .zIndex(4)
```

with

```swift
    /// «ПЛАНКА · ПОДХОД 1» over the hold ring — the active exercise, whatever is previewed.
    private var holdTitle: String {
        WorkoutRunnerLogic.holdTitle(
            name: coordinator.currentExercise.displayName,
            isTimedSets: coordinator.currentExercise.isTimedSets,
            setIdx: coordinator.currentSetIdx)
    }
```

- Screen awake: add modifiers on the root

```swift
        .onChange(of: holdTimer.running) { _, _ in keepScreenAwake() }
        .onChange(of: restTimer.running) { _, _ in keepScreenAwake() }
        .onDisappear { setIdleTimerDisabled(false) }
```

and in the `extension WorkoutView`:

```swift
    /// The phone lies on the floor during a plank and on the bench during rest:
    /// no auto-lock while either timer runs, normal locking otherwise.
    func keepScreenAwake() {
        setIdleTimerDisabled(holdTimer.running || restTimer.running)
    }

    func setIdleTimerDisabled(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
```

- `segmentView` — handle `.partial` and use `fill`:

```swift
    @ViewBuilder
    private func segmentView(_ seg: WorkoutRunnerLogic.ProgressSegment) -> some View {
        let track = Color.white.opacity(0.2)
        Group {
            switch seg.kind {
            case .done: Capsule().fill(Theme.accent)
            case .active: Capsule().fill(Color(red: 0.5, green: 0.89, blue: 0.92))
            case .skipped: Capsule().fill(Color.clear)   // hollow — copper ring carries "passed, not done"
            case .upcoming: Capsule().fill(track)
            case .partial:
                Capsule().fill(track).overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Theme.accent).frame(width: g.size.width * seg.fill)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 5)
        .overlay(previewRing(seg.kind == .active || seg.isPreview || seg.kind == .skipped || seg.kind == .partial))
    }
```

- `stateTag(for:)` — non-active branch becomes
  `return WorkoutRunnerLogic.previewStateTag(sets: coordinator.logged[idx].sets.count, targetSets: coordinator.plan.exercises[idx].targetSets)`.

- [ ] **Step 4: Run, expect PASS** — the two render suites, then the whole `JarvisAppTests` target. Open the PNGs (`xcrun simctl get_app_container booted <bundle id> data`/Documents `timed-3*.png`, `progress-1-partial.png`) and look: ring full and copper at overtime, third-filled segment with ring.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/HoldTimerOverlay.swift ios/JarvisApp/Sources/JarvisApp/Views/Workout/TimedSetCard.swift ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutViewTimedRenderTests.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutViewProgressRenderTests.swift
git commit -m "feat(ios): full-screen hold ring, screen on during timers, partial segment

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: iOS view — technique strip

**Files:**
- Create: `ios/.../Views/Workout/TechniqueStrip.swift`
- Modify: `ios/.../Views/WorkoutView.swift` (`content`)
- Test: new `ios/.../JarvisAppTests/WorkoutViewTechniqueRenderTests.swift`

**Interfaces:**
- Consumes: `ExercisePlan.technique` (Task 3).
- Produces: `struct TechniqueRow: View { let technique: ExerciseTechnique; @Binding var expanded: Bool }` (id `"technique-row"`), `struct TechniqueText: View { let technique: ExerciseTechnique }` (id `"technique-text"`), `WorkoutRunnerLogic`-free.

- [ ] **Step 1: Failing render test** (helpers copied as in Task 5, prefix `technique-`)

```swift
@MainActor
final class WorkoutViewTechniqueRenderTests: XCTestCase {
    // texts(in:), spin(_:), snapshot(_:_:), tap helper below

    func test_techniqueStrip_collapsedByDefault_expandsOverTheImage_collapsesOnPreviewChange() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        var press = ExercisePlan(exerciseSlug: "zhim-nogami", targetSets: 3, targetReps: "10", targetRir: 2,
                                 restSec: 120, nameRu: "Жим ногами", weightKgTarget: 160)
        press.technique = ExerciseTechnique(
            steps: [.init(title: "Исходное положение", text: "Спина прижата к спинке."),
                    .init(title: "Жим", text: "На выдохе, колени не блокировать."),
                    .init(title: "Возврат", text: "Плавно до 90°.")],
            warnings: ["Колени по линии стоп."])
        let bare = ExercisePlan(exerciseSlug: "tyaga", targetSets: 3, targetReps: "10", targetRir: 2,
                                restSec: 120, nameRu: "Тяга блока")
        let plan = WorkoutPlan(workoutId: "w1", dayName: "Ноги", week: 1, intensityLabel: "лёгкая",
                               exercises: [press, bare], imageManifest: [])
        let coord = WorkoutCoordinator(plan: plan, queue: SetLogQueue(writer: dbq))
        let view = WorkoutView(coordinator: coord, imageResolver: { _ in nil },
                               coachMessages: Empty<String, Never>().eraseToAnyPublisher(),
                               onClose: { _ in }, onSwap: { _ in })
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        spin()

        let collapsed = texts(in: host.view)
        snapshot(window, "1-collapsed")
        XCTAssertTrue(collapsed.contains("Техника · 3 шага"), "collapsed: \(collapsed)")
        XCTAssertFalse(collapsed.contains { $0.contains("Спина прижата") }, "collapsed: \(collapsed)")
    }
}
```

Expanding: SwiftUI taps can't be driven from XCTest here, so `WorkoutView` gets a plain property `var techniqueExpanded: Bool = false` that seeds `techniqueOpen` on appear (see Step 3). Continue the test:

```swift
        // Second host, opened: text over the image, set card still there.
        let openView = WorkoutView(coordinator: coord, imageResolver: { _ in nil },
                                   coachMessages: Empty<String, Never>().eraseToAnyPublisher(),
                                   onClose: { _ in }, onSwap: { _ in }, techniqueExpanded: true)
        let openHost = UIHostingController(rootView: openView)
        window.rootViewController = openHost
        spin()
        let expanded = texts(in: openHost.view)
        snapshot(window, "2-expanded")
        XCTAssertTrue(expanded.contains { $0.contains("Спина прижата к спинке.") }, "expanded: \(expanded)")
        XCTAssertTrue(expanded.contains("Колени по линии стоп."), "expanded: \(expanded)")
        XCTAssertTrue(expanded.contains("Вес"), "the set card stays usable: \(expanded)")

        // An exercise without technique has no strip at all.
        coord.activate(idx: 1)
        spin()
        let other = texts(in: openHost.view)
        snapshot(window, "3-no-technique")
        XCTAssertFalse(other.contains { $0.hasPrefix("Техника") }, "other: \(other)")
```

`texts(in:)` collects accessibility labels; if the step line comes through as one concatenated label (title + text), `contains { $0.contains(…) }` still matches. Pluralisation of the row label is covered by a unit test:

Unit test (in `WorkoutRunnerLogicTests.swift`):

```swift
    func test_techniqueLabel() {
        XCTAssertEqual(TechniqueRow.label(steps: 1), "Техника · 1 шаг")
        XCTAssertEqual(TechniqueRow.label(steps: 3), "Техника · 3 шага")
        XCTAssertEqual(TechniqueRow.label(steps: 5), "Техника · 5 шагов")
        XCTAssertEqual(TechniqueRow.label(steps: 0), "Техника")
    }
```

- [ ] **Step 2: Run, expect FAIL** — `-only-testing:JarvisAppTests/WorkoutViewTechniqueRenderTests -only-testing:JarvisAppTests/WorkoutRunnerLogicTests`.

- [ ] **Step 3: Implement**

`TechniqueStrip.swift`:

```swift
import SwiftUI

/// Collapsed technique row under the runner's header: «Техника · 3 шага».
/// Tapping it opens `TechniqueText` over the image and the ПЕЙН panel.
struct TechniqueRow: View {
    let technique: ExerciseTechnique
    @Binding var expanded: Bool

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    static func label(steps: Int) -> String {
        guard steps > 0 else { return "Техника" }
        let mod10 = steps % 10, mod100 = steps % 100
        let word = (mod10 == 1 && mod100 != 11) ? "шаг"
            : ((2...4).contains(mod10) && !(12...14).contains(mod100)) ? "шага" : "шагов"
        return "Техника · \(steps) \(word)"
    }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "book").font(.system(size: 12)).foregroundStyle(copper)
                Text(Self.label(steps: technique.steps.count)).font(.caption).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.08, green: 0.078, blue: 0.06))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("technique-row")
    }
}

/// The expanded technique: numbered steps (title in copper), then warnings.
/// Lives in an overlay over the image + panel, so the set card keeps its place;
/// scrolls when longer than that area.
struct TechniqueText: View {
    let technique: ExerciseTechnique

    private let copper = Color(red: 0.78, green: 0.57, blue: 0.35)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(technique.steps.enumerated()), id: \.offset) { i, step in
                    (Text("\(i + 1). \(step.title)\(step.title.isEmpty ? "" : ".") ").foregroundColor(copper).bold()
                     + Text(step.text).foregroundColor(.white.opacity(0.92)))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(technique.warnings, id: \.self) { w in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.94, green: 0.62, blue: 0.15))
                            .padding(.top, 2)
                        Text(w).font(.footnote).foregroundStyle(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(red: 0.08, green: 0.078, blue: 0.06).opacity(0.97))
        .accessibilityIdentifier("technique-text")
    }
}
```

`WorkoutView.swift`:
- Properties: `var techniqueExpanded: Bool = false` (declared after `onAppearPrefetch`, so the memberwise init takes it last and existing call sites compile unchanged) and `@State private var techniqueOpen = false`. In the existing `.onAppear` add `techniqueOpen = techniqueExpanded`.
- In `content`, after `pinnedHeader`:

```swift
                if let technique = preview.technique {
                    TechniqueRow(technique: technique, expanded: $techniqueOpen)
                }
```

  and wrap the `ExerciseBannerView(…)…clipped()` and `RecommendationPanel(…)` in a `VStack(spacing: 0) { … }` with

```swift
                .overlay(alignment: .top) {
                    if techniqueOpen, let technique = preview.technique {
                        TechniqueText(technique: technique)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
```

  (`let preview = …` must move above the technique row.)
- `.onChange(of: previewIdx) { _, _ in techniqueOpen = false }` on the root.

- [ ] **Step 4: Run, expect PASS** — the technique suite, the logic suite, then the whole `JarvisAppTests` target. Look at `technique-1-collapsed.png` / `technique-2-expanded.png`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/TechniqueStrip.swift ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutViewTechniqueRenderTests.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift
git commit -m "feat(ios): collapsible technique block at the top of the runner

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Build 130, full verification, deploy

**Files:**
- Modify: `ios/JarvisApp/project.yml` (`CURRENT_PROJECT_VERSION: "129"` → `"130"`), regenerated `ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Bump + regenerate** — edit `project.yml`, `cd ios/JarvisApp && xcodegen generate`.
- [ ] **Step 2: Full iOS unit target** — `xcodebuild -project ios/JarvisApp/JarvisApp.xcodeproj -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:JarvisAppTests` → `** TEST SUCCEEDED **`.
- [ ] **Step 3: Host + container suites** — `pnpm run build && pnpm test`; `cd container/agent-runner && bun test`; `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`.
- [ ] **Step 4: Commit + push**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "chore(ios): build 130 — hold ring, partial progress, technique block

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

- [ ] **Step 5: Deploy Payne script** — first `ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && sha256sum agents/payne/scripts/build-plan.js agents/payne/scripts/build-plan.test.js'` and compare with the shas recorded in Task 1 Step 0. Different = Payne edited them since: stop, pull the VDS copy, merge by hand, re-run Task 1 tests. Same = `scp groups/payne/scripts/build-plan.js groups/payne/scripts/build-plan.test.js root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/payne/scripts/`, `chown nanoclaw:nanoclaw` both, and run the Payne suite in the agent image the way it was run on 2026-10-26 (138 pass before; expect 141).
- [ ] **Step 6: Deploy host + runner** — on the VDS as the service user: `git pull`, `pnpm run build`, restart the service; check `logs/nanoclaw.error.log` for new errors.
- [ ] **Step 7: Live plan check** — on the VDS run the builder for today's day from `agents/payne` (`bun scripts/build-plan.js`) and confirm the exercises carry `technique`. Then the owner installs build 130 and checks on the phone.
- [ ] **Step 8: Memory** — update `project_ios_workout_redesign.md` (short section: build 130, hold ring overlay, idle timer, partial segment rule, technique path + the `normalizeExercise` whitelist gotcha) and its MEMORY.md hook.
