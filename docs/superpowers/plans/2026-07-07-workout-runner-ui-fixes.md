# Workout Runner UI Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four Payne workout-runner gaps: state loss on app kill, silent Payne feedback on deviations, wrong "next" hint on the rest timer, and missing post-workout summary.

**Architecture:** iOS persists workout progress into `jarvis-v2.sqlite` on every mutation and resumes via a "Продолжить тренировку" CTA on the same chat card. iOS computes per-set deviation from planned reps/weight/RIR and tags the outbound `set_log` envelope; Payne is told (via CLAUDE.md rule) to reply with `coach_message` carrying `set_ref` when deviation is present, and iOS anchors that reply as a 💬 badge on the specific set chip. Rest-timer hint scans all exercises for the first unfinished set. Payne CLAUDE.md gains a mandatory post-`workout_complete` summary format.

**Tech Stack:** Swift + SwiftUI + GRDB (iOS), TypeScript + Zod (shared/ios-app-protocol), Bun (agent-runner MCP tools), Node (host bridge).

Spec: [docs/superpowers/specs/2026-07-07-workout-runner-ui-fixes-design.md](../specs/2026-07-07-workout-runner-ui-fixes-design.md).

---

## File Structure

New files:

- `ios/JarvisApp/Sources/JarvisApp/Storage/ActiveWorkoutStore.swift` — GRDB CRUD for the `active_workout` table + Codable payload types.
- `ios/JarvisApp/Sources/JarvisAppTests/ActiveWorkoutStoreTests.swift` — GRDB round-trip tests for the store.

Modified files:

- `shared/ios-app-protocol/v2.ts` — extend `SetLog.payload` with optional `deviation`, `CoachMessage.payload` with optional `set_ref`.
- `shared/ios-app-protocol/fixtures/set_log.json` — extended fixture with a deviation value.
- `shared/ios-app-protocol/fixtures/coach_message.json` — extended fixture with a `set_ref` value.
- `shared/ios-app-protocol/fixtures/set_log_no_deviation.json` — NEW fixture asserting deviation is optional (name pending — created in Task 1.3 if useful).
- `container/agent-runner/src/mcp-tools/workout.ts` — `workout.coach` gains optional `set_ref` param and forwards it in the envelope payload.
- `src/channels/ios-app/v2/workout-bridge.test.ts` — passthrough test for deviation and set_ref.
- `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` — mirror deviation on `SetLog`, `set_ref` on `CoachMessage`.
- `ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift` — `LoggedSet.deviation`, `LoggedSet.coachHint`.
- `ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift` — `SetDeviation`, `SetDeviationKind`, thresholds, `detectDeviation(...)`, new `restHint(logged:exercises:activeIdx:)` signature.
- `ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift` — deviation detection + new rest hint tests.
- `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift` — migration `v12-active-workout` creating the `active_workout` table.
- `ios/JarvisApp/Sources/JarvisApp/Storage/SetLogQueue.swift` — persist optional deviation in queue rows (schema-compatible via NULL columns).
- `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift` — `attachCoachHint(exerciseSlug:setIdx:text:)`, restoring init, per-mutation persistence, deviation computation on `logSet`.
- `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift` — restore, deviation, attachCoachHint tests.
- `ios/JarvisApp/Sources/JarvisApp/Services/AppV2Bootstrap.swift` — construct + inject `ActiveWorkoutStore` into the stack.
- `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` — set_log builder writes deviation payload; coach_message forwards `set_ref` on the bus event.
- `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutInbound.swift` — extend `WorkoutInboundEvent.coachMessage` to carry `setRef: (exerciseSlug: String, setIdx: Int)?`.
- `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift` — route `set_ref` from V2 into the bus event, then in ChatView subscribe to route to coordinator instead of banner.
- `ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift` — restHint uses new signature; keep banner path for coach messages without `set_ref`.
- `ios/JarvisApp/Sources/JarvisApp/Views/Workout/LoggedSetChips.swift` — 💬 badge + tap sheet.
- `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` — resume path + sticky banner + `isResuming` propagation + coach-hint routing.
- `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift` — `WorkoutPlanRow` CTA label + style flip via `isResuming: Bool`.
- `groups/payne/skills/workout-mode/SKILL.md` — set_ref rule on deviation + mandatory summary format after `workout_complete`.
- `ios/JarvisApp/project.yml` — bump `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION`.

Test paths:

- `ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift`
- `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift`
- `ios/JarvisApp/Sources/JarvisAppTests/ActiveWorkoutStoreTests.swift`
- `src/channels/ios-app/v2/workout-bridge.test.ts`

---

## Phase 0 — Wire protocol groundwork

### Task 0.1: Extend `SetLog.payload` with `deviation`

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts:268-281`
- Modify: `shared/ios-app-protocol/fixtures/set_log.json`

- [ ] **Step 1: Update Zod schema for SetLog**

In `shared/ios-app-protocol/v2.ts` locate the `SetLog:` block (starts around line 268) and extend `payload`:

```ts
  SetLog: EnvelopeBase.extend({
    kind: z.literal('data'),
    type: z.literal('set_log'),
    payload: z.object({
      workout_id: z.string().min(1),
      exercise_slug: z.string().min(1),
      set_idx: z.number().int().nonnegative(),
      reps: z.number().int().nonnegative(),
      weight: z.number().nonnegative(),
      reps_in_reserve: z.number().int().min(0).max(10),
      ts: z.string().datetime(),
      agent_id: z.string().min(1).optional(),
      deviation: z.object({
        kind: z.enum([
          'weight_under', 'weight_over',
          'reps_under', 'reps_over',
          'failure', 'too_easy',
        ]),
        magnitude: z.number(),
        target: z.object({
          reps_min: z.number().int().nonnegative(),
          reps_max: z.number().int().nonnegative(),
          weight: z.number().nonnegative().optional(),
          rir: z.number().int().min(0).max(10),
        }),
      }).optional(),
    }),
  }),
```

- [ ] **Step 2: Extend the set_log fixture with a deviation example**

Overwrite `shared/ios-app-protocol/fixtures/set_log.json`:

```json
{
  "v": 2,
  "kind": "data",
  "type": "set_log",
  "id": "22222222-2222-4222-8222-222222222222",
  "seq": 11,
  "ts": "2026-06-09T19:05:00.000Z",
  "payload": {
    "workout_id": "01J6Z8W3K2N5A7B9C1D3E5F7G9",
    "exercise_slug": "incline-db-press",
    "set_idx": 0,
    "reps": 10,
    "weight": 22.5,
    "reps_in_reserve": 3,
    "ts": "2026-06-09T19:05:00.000Z",
    "agent_id": "payne",
    "deviation": {
      "kind": "too_easy",
      "magnitude": 0,
      "target": { "reps_min": 8, "reps_max": 10, "weight": 24, "rir": 2 }
    }
  }
}
```

- [ ] **Step 3: Run TS contract tests**

Run: `pnpm test -- shared/ios-app-protocol/`
Expected: PASS. If a contract fixture test parses the fixture through `Envelopes.SetLog`, the extended schema now accepts the extra field.

- [ ] **Step 4: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/fixtures/set_log.json
git commit -m "feat(protocol): SetLog gains optional deviation payload

Adds kind/magnitude/target snapshot so Payne can act on the deviation
without loading program.json."
```

### Task 0.2: Extend `CoachMessage.payload` with `set_ref`

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts:382-390`
- Modify: `shared/ios-app-protocol/fixtures/coach_message.json`

- [ ] **Step 1: Update Zod schema for CoachMessage**

In `shared/ios-app-protocol/v2.ts` locate `CoachMessage:` (starts around line 382):

```ts
  CoachMessage: EnvelopeBase.extend({
    kind: z.literal('control'),
    type: z.literal('coach_message'),
    payload: z.object({
      text: z.string().min(1),
      workout_id: z.string().optional(),
      agent_id: z.string().min(1).optional(),
      set_ref: z.object({
        exercise_slug: z.string().min(1),
        set_idx: z.number().int().nonnegative(),
      }).optional(),
    }),
  }),
```

- [ ] **Step 2: Extend the coach_message fixture**

Overwrite `shared/ios-app-protocol/fixtures/coach_message.json`:

```json
{
  "v": 2,
  "kind": "control",
  "type": "coach_message",
  "id": "22222222-2222-4222-8222-222222222224",
  "seq": 13,
  "ts": "2026-06-09T19:07:00.000Z",
  "payload": {
    "workout_id": "01J6Z8W3K2N5A7B9C1D3E5F7G9",
    "text": "сбавь до 20 — у тебя падает форма",
    "agent_id": "payne",
    "set_ref": { "exercise_slug": "incline-db-press", "set_idx": 0 }
  }
}
```

- [ ] **Step 3: Run TS contract tests**

Run: `pnpm test -- shared/ios-app-protocol/`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/fixtures/coach_message.json
git commit -m "feat(protocol): CoachMessage gains optional set_ref

Anchors a coach reply to a specific logged set so iOS can render the
comment as a chip on that set card instead of the 4-sec banner."
```

### Task 0.3: Add workout-bridge passthrough test

**Files:**
- Modify: `src/channels/ios-app/v2/workout-bridge.test.ts`

- [ ] **Step 1: Add failing passthrough tests**

Open the existing test file and append two cases. Use the same style as existing test blocks — the bridge is pure passthrough, so the tests assert the extra fields survive the transform.

```ts
it('passes deviation through on set_log inbound', () => {
  const captured: { text: string; tag: string; trigger: 0 | 1 }[] = [];
  const bridge = new WorkoutBridge({
    writeInboundSystemMessage: ({ text, tag, trigger }) => captured.push({ text, tag, trigger }),
    resolvePlatformForSession: () => 'plat',
    sendEnvelopeToDevice: () => {},
  });
  bridge.handleInbound('sess', {
    v: 2, kind: 'data', type: 'set_log', id: 'i', seq: 1, ts: 'now',
    payload: {
      workout_id: 'w', exercise_slug: 'ex', set_idx: 0,
      reps: 10, weight: 20, reps_in_reserve: 0, ts: 'now',
      deviation: { kind: 'failure', magnitude: 0, target: { reps_min: 8, reps_max: 10, rir: 2 } },
    },
  } as unknown as AnyEnvelope);
  expect(captured).toHaveLength(1);
  const body = JSON.parse(captured[0].text);
  expect(body.payload.deviation.kind).toBe('failure');
});

it('passes set_ref through on coach_message outbound', () => {
  let last: unknown;
  const bridge = new WorkoutBridge({
    writeInboundSystemMessage: () => {},
    resolvePlatformForSession: () => 'plat',
    sendEnvelopeToDevice: (_pid, env) => { last = env; },
  });
  bridge.handleAgentRequest({
    session_id: 'sess',
    content: {
      type: 'coach_message',
      payload: { workout_id: 'w', text: 'go', set_ref: { exercise_slug: 'ex', set_idx: 0 } },
    },
  });
  expect((last as any).type).toBe('coach_message');
  expect((last as any).payload.set_ref.exercise_slug).toBe('ex');
});
```

- [ ] **Step 2: Run bridge tests to verify they pass**

Run: `pnpm test -- src/channels/ios-app/v2/workout-bridge`
Expected: PASS (bridge is pure passthrough; the tests are guards against future refactors that would strip unknown fields).

- [ ] **Step 3: Commit**

```bash
git add src/channels/ios-app/v2/workout-bridge.test.ts
git commit -m "test(workout-bridge): guard deviation + set_ref passthrough"
```

### Task 0.4: Add `set_ref` to `workout.coach` MCP tool

**Files:**
- Modify: `container/agent-runner/src/mcp-tools/workout.ts:104-127`

- [ ] **Step 1: Extend input schema and forward the field**

Replace the `workoutCoach` export:

```ts
export const workoutCoach: McpToolDefinition = {
  tool: {
    name: 'workout.coach',
    description:
      'Short in-workout message. Goes to the workout UI, not the chat scroll. Use sparingly: PR, missed-set pattern, fatigue cue. If replying to a deviating set, include set_ref so iOS anchors the reply on that set chip. Default to silence.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        workout_id: { type: 'string' },
        text: { type: 'string', description: 'One or two sentences, plain language.' },
        set_ref: {
          type: 'object',
          description: 'Anchor this coach reply to a specific logged set. Include when replying to a deviation.',
          properties: {
            exercise_slug: { type: 'string' },
            set_idx: { type: 'number' },
          },
          required: ['exercise_slug', 'set_idx'],
        },
      },
      required: ['workout_id', 'text'],
    },
  },
  async handler(args) {
    const g = guard();
    if (!g.ok) return g.res;
    const payload: Record<string, unknown> = { workout_id: args.workout_id, text: args.text };
    if (args.set_ref && typeof args.set_ref === 'object') {
      payload.set_ref = args.set_ref;
    }
    writeWorkoutOut({ type: 'coach_message', payload });
    return ok('coach_message sent');
  },
};
```

- [ ] **Step 2: Typecheck the container tree**

Run: `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add container/agent-runner/src/mcp-tools/workout.ts
git commit -m "feat(agent-runner): workout.coach accepts optional set_ref

Payne now anchors replies to specific deviating sets."
```

---

## Phase 1 — Swift protocol mirror

### Task 1.1: Mirror `SetLog.deviation` in Swift

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift:324-338`
- Add test: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutFormatTests.swift` (append)

- [ ] **Step 1: Write a failing round-trip test**

Append to `WorkoutFormatTests.swift`:

```swift
func test_setLog_encodesDeviationRoundTrip() throws {
    let deviation = V2.SetLog.Deviation(
        kind: .failure,
        magnitude: 0,
        target: V2.SetLog.DeviationTarget(reps_min: 8, reps_max: 10, weight: 24, rir: 2)
    )
    let log = V2.SetLog(
        workout_id: "w", exercise_slug: "ex", set_idx: 0,
        reps: 10, weight: 20, reps_in_reserve: 0,
        ts: "2026-01-01T00:00:00Z", agent_id: "payne",
        deviation: deviation
    )
    let data = try JSONEncoder().encode(log)
    let round = try JSONDecoder().decode(V2.SetLog.self, from: data)
    XCTAssertEqual(round.deviation?.kind, .failure)
    XCTAssertEqual(round.deviation?.target.reps_max, 10)
    XCTAssertEqual(round.deviation?.target.weight, 24)
}
```

- [ ] **Step 2: Run test to confirm failure**

Run: `xcodebuild test -project ios/JarvisApp/JarvisApp.xcodeproj -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/WorkoutFormatTests/test_setLog_encodesDeviationRoundTrip`
Expected: FAIL (`deviation` and `Deviation` unknown).

- [ ] **Step 3: Extend `V2.SetLog`**

Replace `struct SetLog` in `V2.swift` (around line 324) with:

```swift
struct SetLog: Codable, Equatable {
    let workout_id: String
    let exercise_slug: String
    let set_idx: Int
    let reps: Int
    let weight: Double
    let reps_in_reserve: Int
    let ts: String
    var agent_id: String?
    var deviation: Deviation?

    struct Deviation: Codable, Equatable {
        let kind: Kind
        let magnitude: Double
        let target: DeviationTarget
        enum Kind: String, Codable, Equatable {
            case weight_under, weight_over
            case reps_under, reps_over
            case failure
            case too_easy
        }
    }
    struct DeviationTarget: Codable, Equatable {
        let reps_min: Int
        let reps_max: Int
        var weight: Double?
        let rir: Int
    }

    init(workout_id: String, exercise_slug: String, set_idx: Int, reps: Int, weight: Double,
         reps_in_reserve: Int, ts: String, agent_id: String? = nil, deviation: Deviation? = nil) {
        self.workout_id = workout_id; self.exercise_slug = exercise_slug
        self.set_idx = set_idx; self.reps = reps; self.weight = weight
        self.reps_in_reserve = reps_in_reserve; self.ts = ts
        self.agent_id = agent_id; self.deviation = deviation
    }
}
```

- [ ] **Step 4: Rerun test to confirm pass**

Run: same xcodebuild command as step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutFormatTests.swift
git commit -m "feat(ios): mirror SetLog.deviation in Swift protocol"
```

### Task 1.2: Mirror `CoachMessage.set_ref` in Swift

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift:450-457`
- Add test: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutFormatTests.swift` (append)

- [ ] **Step 1: Write a failing round-trip test**

Append:

```swift
func test_coachMessage_encodesSetRefRoundTrip() throws {
    let msg = V2.CoachMessage(
        text: "go", workout_id: "w", agent_id: "payne",
        set_ref: .init(exercise_slug: "ex", set_idx: 3)
    )
    let data = try JSONEncoder().encode(msg)
    let round = try JSONDecoder().decode(V2.CoachMessage.self, from: data)
    XCTAssertEqual(round.set_ref?.exercise_slug, "ex")
    XCTAssertEqual(round.set_ref?.set_idx, 3)
}
```

- [ ] **Step 2: Run test to confirm failure**

Run: `xcodebuild test … -only-testing:JarvisAppTests/WorkoutFormatTests/test_coachMessage_encodesSetRefRoundTrip`
Expected: FAIL.

- [ ] **Step 3: Extend `V2.CoachMessage`**

Replace the struct:

```swift
struct CoachMessage: Codable, Equatable {
    let text: String
    var workout_id: String?
    var agent_id: String?
    var set_ref: SetRef?

    struct SetRef: Codable, Equatable {
        let exercise_slug: String
        let set_idx: Int
    }

    init(text: String, workout_id: String? = nil, agent_id: String? = nil, set_ref: SetRef? = nil) {
        self.text = text; self.workout_id = workout_id; self.agent_id = agent_id
        self.set_ref = set_ref
    }
}
```

- [ ] **Step 4: Rerun test to confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutFormatTests.swift
git commit -m "feat(ios): mirror CoachMessage.set_ref in Swift protocol"
```

---

## Phase 2 — iOS deviation detection

### Task 2.1: Add `SetDeviation` types + thresholds + `detectDeviation`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `WorkoutRunnerLogicTests.swift`:

```swift
private func mkExercise(reps: String, weight: Double? = 20, rir: Int = 2) -> ExercisePlan {
    ExercisePlan(exerciseSlug: "ex", targetSets: 4, targetReps: reps, targetRir: rir,
                 restSec: 120, notes: nil, nameRu: nil, durationSec: nil, weightKgTarget: weight)
}

func test_detectDeviation_weightUnder15pct() {
    let ex = mkExercise(reps: "8-10", weight: 100)
    let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 80, actualRir: 2, exercise: ex)
    XCTAssertEqual(d?.kind, .weightUnder)
    XCTAssertEqual(d?.target.weight, 100)
    XCTAssertEqual(d?.target.repsMin, 8)
    XCTAssertEqual(d?.target.repsMax, 10)
}

func test_detectDeviation_weightWithinTolerance() {
    let ex = mkExercise(reps: "8-10", weight: 100)
    let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 90, actualRir: 2, exercise: ex)
    XCTAssertNil(d)
}

func test_detectDeviation_repsUnderByThree() {
    let ex = mkExercise(reps: "8-10", weight: 100)
    // Mid = 9 → actual 5 is 4 below → repsUnder
    let d = WorkoutRunnerLogic.detectDeviation(actualReps: 5, actualWeight: 100, actualRir: 2, exercise: ex)
    XCTAssertEqual(d?.kind, .repsUnder)
}

func test_detectDeviation_failureOnRirZero() {
    let ex = mkExercise(reps: "8-10", weight: 100)
    let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 100, actualRir: 0, exercise: ex)
    XCTAssertEqual(d?.kind, .failure)
}

func test_detectDeviation_tooEasyOnRir4() {
    let ex = mkExercise(reps: "8-10", weight: 100)
    let d = WorkoutRunnerLogic.detectDeviation(actualReps: 10, actualWeight: 100, actualRir: 4, exercise: ex)
    XCTAssertEqual(d?.kind, .tooEasy)
}

func test_detectDeviation_weightPrecedesReps() {
    // Weight AND reps out of tolerance → weight wins.
    let ex = mkExercise(reps: "8-10", weight: 100)
    let d = WorkoutRunnerLogic.detectDeviation(actualReps: 3, actualWeight: 80, actualRir: 2, exercise: ex)
    XCTAssertEqual(d?.kind, .weightUnder)
}
```

- [ ] **Step 2: Run tests to confirm failures**

Run: `xcodebuild test … -only-testing:JarvisAppTests/WorkoutRunnerLogicTests`
Expected: 6 new failures (unknown symbols).

- [ ] **Step 3: Add types + detector to `WorkoutRunnerLogic.swift`**

Append inside the `enum WorkoutRunnerLogic {}` body:

```swift
/// Tolerance beyond which a set is called out to Payne.
static let weightDeviationPct: Double = 0.15
static let repsDeviationAbs: Int = 3

enum SetDeviationKind: String, Codable, Equatable {
    case weightUnder, weightOver
    case repsUnder, repsOver
    case failure       // rir == 0
    case tooEasy       // rir >= 4
}

struct DeviationTargetSnapshot: Codable, Equatable {
    let repsMin: Int
    let repsMax: Int
    var weight: Double?
    let rir: Int
}

struct SetDeviation: Codable, Equatable {
    let kind: SetDeviationKind
    /// Percentage delta for weight, absolute delta for reps, 0 for rir kinds.
    let magnitude: Double
    let target: DeviationTargetSnapshot
}

/// Detect deviation of an actual set against its planned exercise.
/// Precedence: weight > reps > rir. Returns nil if within tolerance.
static func detectDeviation(actualReps: Int, actualWeight: Double, actualRir: Int, exercise: ExercisePlan) -> SetDeviation? {
    let range = parseRepsRange(exercise.targetReps)
    let target = DeviationTargetSnapshot(
        repsMin: range.min ?? 0, repsMax: range.max ?? 0,
        weight: exercise.weightKgTarget, rir: exercise.targetRir
    )
    if let weightTarget = exercise.weightKgTarget, weightTarget > 0 {
        let delta = actualWeight / weightTarget - 1.0
        if abs(delta) >= weightDeviationPct {
            return SetDeviation(kind: delta < 0 ? .weightUnder : .weightOver, magnitude: delta, target: target)
        }
    }
    if let mid = range.mid {
        let d = actualReps - mid
        if abs(d) >= repsDeviationAbs {
            return SetDeviation(kind: d < 0 ? .repsUnder : .repsOver, magnitude: Double(d), target: target)
        }
    }
    if actualRir == 0 { return SetDeviation(kind: .failure, magnitude: 0, target: target) }
    if actualRir >= 4 { return SetDeviation(kind: .tooEasy, magnitude: 0, target: target) }
    return nil
}

private static func parseRepsRange(_ s: String) -> (min: Int?, max: Int?, mid: Int?) {
    let parts = s.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    if parts.count == 2 {
        let mid = (parts[0] + parts[1]) / 2
        return (parts[0], parts[1], mid)
    }
    if parts.count == 1 { return (parts[0], parts[0], parts[0]) }
    return (nil, nil, nil)
}
```

- [ ] **Step 4: Rerun tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift
git commit -m "feat(ios): client-side set-deviation detection

15% weight, ±3 reps, RIR 0 or ≥4. Precedence weight > reps > rir."
```

### Task 2.2: Add `deviation` + `coachHint` to `LoggedSet`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift:146-157`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutModelsTests.swift` (extend)

- [ ] **Step 1: Write failing round-trip test**

Append to `WorkoutModelsTests.swift`:

```swift
func test_loggedSet_persistsDeviationAndCoachHint() throws {
    let dev = WorkoutRunnerLogic.SetDeviation(
        kind: .failure, magnitude: 0,
        target: .init(repsMin: 8, repsMax: 10, weight: 100, rir: 2)
    )
    let set = LoggedSet(
        reps: 10, weight: 20, repsInReserve: 0, ts: Date(timeIntervalSince1970: 0),
        deviation: dev,
        coachHint: "отдохни 3 мин"
    )
    let data = try JSONEncoder().encode(set)
    let round = try JSONDecoder().decode(LoggedSet.self, from: data)
    XCTAssertEqual(round.deviation?.kind, .failure)
    XCTAssertEqual(round.coachHint, "отдохни 3 мин")
}
```

- [ ] **Step 2: Extend `LoggedSet`**

Replace the struct:

```swift
struct LoggedSet: Codable, Equatable {
    let reps: Int
    let weight: Double
    let repsInReserve: Int
    let ts: Date
    var deviation: WorkoutRunnerLogic.SetDeviation?
    var coachHint: String?

    enum CodingKeys: String, CodingKey {
        case reps, weight
        case repsInReserve = "reps_in_reserve"
        case ts
        case deviation
        case coachHint = "coach_hint"
    }

    init(reps: Int, weight: Double, repsInReserve: Int, ts: Date,
         deviation: WorkoutRunnerLogic.SetDeviation? = nil, coachHint: String? = nil) {
        self.reps = reps; self.weight = weight; self.repsInReserve = repsInReserve; self.ts = ts
        self.deviation = deviation; self.coachHint = coachHint
    }
}
```

- [ ] **Step 3: Run tests**

Run: `xcodebuild test … -only-testing:JarvisAppTests/WorkoutModelsTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutModelsTests.swift
git commit -m "feat(ios): LoggedSet gains deviation + coachHint fields"
```

### Task 2.3: Compute deviation in `WorkoutCoordinator.logSet` + tag `SetLogEvent`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/SetLogQueue.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift`

- [ ] **Step 1: Write failing test**

Append to `WorkoutCoordinatorTests.swift`:

```swift
func test_logSet_taggsDeviationOnLoggedSet() throws {
    let queue = try makeQueue()
    // 100 kg target; log 80 → weightUnder
    var plan = makePlan()
    plan = WorkoutPlan(
        workoutId: plan.workoutId, dayName: plan.dayName, week: plan.week,
        intensityLabel: plan.intensityLabel,
        exercises: [ExercisePlan(exerciseSlug: "ex-0", targetSets: 4, targetReps: "8-10",
                                 targetRir: 2, restSec: 120, notes: nil, nameRu: nil,
                                 durationSec: nil, weightKgTarget: 100)],
        imageManifest: [])
    let coord = WorkoutCoordinator(plan: plan, queue: queue)
    coord.logSet(reps: 10, weight: 80, repsInReserve: 2)
    XCTAssertEqual(coord.loggedForCurrentExercise.first?.deviation?.kind, .weightUnder)
}
```

- [ ] **Step 2: Add migration `v12-set-log-deviation`**

In `Schema.swift`, append after `v11-dedup-notified-at`:

```swift
m.registerMigration("v12-set-log-deviation") { db in
    try db.execute(sql: "ALTER TABLE set_log_queue ADD COLUMN deviation_json TEXT;")
}
```

- [ ] **Step 3: Extend `SetLogEvent` + `SetLogQueue` to carry deviation**

In `SetLogQueue.swift` replace `SetLogEvent`:

```swift
struct SetLogEvent: Equatable {
    let workoutId: String
    let exerciseSlug: String
    let setIdx: Int
    let reps: Int
    let weight: Double
    let repsInReserve: Int
    let ts: Date
    var deviation: WorkoutRunnerLogic.SetDeviation?
}
```

Extend `enqueue`:

```swift
func enqueue(_ event: SetLogEvent) throws {
    let deviationJson: String? = event.deviation.flatMap { d in
        (try? JSONEncoder().encode(d)).flatMap { String(data: $0, encoding: .utf8) }
    }
    try writer.write { db in
        try db.execute(sql: """
            INSERT INTO set_log_queue
              (workout_id, exercise_slug, set_idx, reps, weight, reps_in_reserve, ts_iso, deviation_json, delivered)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
        """, arguments: [
            event.workoutId, event.exerciseSlug, event.setIdx,
            event.reps, event.weight, event.repsInReserve,
            Self.isoFormatter.string(from: event.ts),
            deviationJson,
        ])
    }
}
```

Extend `pending()` to read `deviation_json` and decode back into the event:

```swift
func pending() throws -> [PendingSetLog] {
    try writer.read { db in
        try Row.fetchAll(db, sql: """
            SELECT rowid AS local_id, workout_id, exercise_slug, set_idx,
                   reps, weight, reps_in_reserve, ts_iso, deviation_json
            FROM set_log_queue
            WHERE delivered = 0
            ORDER BY workout_id ASC, set_idx ASC, rowid ASC
        """).map { row in
            let devJson: String? = row["deviation_json"]
            let dev: WorkoutRunnerLogic.SetDeviation? = devJson
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(WorkoutRunnerLogic.SetDeviation.self, from: $0) }
            return PendingSetLog(
                localId: row["local_id"],
                event: SetLogEvent(
                    workoutId: row["workout_id"],
                    exerciseSlug: row["exercise_slug"],
                    setIdx: row["set_idx"],
                    reps: row["reps"], weight: row["weight"],
                    repsInReserve: row["reps_in_reserve"],
                    ts: Self.isoFormatter.date(from: row["ts_iso"]) ?? Date(),
                    deviation: dev
                )
            )
        }
    }
}
```

- [ ] **Step 4: Update `WorkoutCoordinator.logSet`**

Replace the body of `logSet`:

```swift
func logSet(reps: Int, weight: Double, repsInReserve: Int, ts: Date = Date()) {
    guard !isFinished, currentExerciseIdx < plan.exercises.count else { return }
    let dev = WorkoutRunnerLogic.detectDeviation(
        actualReps: reps, actualWeight: weight, actualRir: repsInReserve,
        exercise: currentExercise
    )
    let event = SetLogEvent(
        workoutId: plan.workoutId, exerciseSlug: currentExercise.exerciseSlug,
        setIdx: currentSetIdx, reps: reps, weight: weight,
        repsInReserve: repsInReserve, ts: ts, deviation: dev
    )
    try? queue.enqueue(event)
    logged[currentExerciseIdx].sets.append(
        LoggedSet(reps: reps, weight: weight, repsInReserve: repsInReserve, ts: ts, deviation: dev)
    )
    lastRepsInReserve = repsInReserve
    currentSetIdx += 1
}
```

- [ ] **Step 5: Run tests**

Run: `xcodebuild test … -only-testing:JarvisAppTests/WorkoutCoordinatorTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/SetLogQueue.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift \
        ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift
git commit -m "feat(ios): Coordinator tags each set with deviation

Persist in the durable SetLogQueue so drain includes it."
```

### Task 2.4: Transport writes deviation into the outbound envelope

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutPlanRealEnvelopeTests.swift` OR create a small new test.

- [ ] **Step 1: Locate the set_log builder in TransportV2**

Run: `grep -n "SetLog\b\|set_log" ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift`
Note the builder function that maps `PendingSetLog.event` → `V2.SetLog`.

- [ ] **Step 2: Write a failing test asserting deviation makes it into the envelope**

Add to an existing transport-oriented test file (e.g. `WorkoutPlanRealEnvelopeTests.swift`) or add `TransportV2SetLogDeviationTests.swift` if none fits. Minimal:

```swift
func test_transport_setLog_carriesDeviation() {
    let event = SetLogEvent(
        workoutId: "w", exerciseSlug: "ex", setIdx: 0,
        reps: 10, weight: 20, repsInReserve: 0, ts: Date(timeIntervalSince1970: 0),
        deviation: .init(kind: .failure, magnitude: 0)
    )
    let payload = TransportV2.buildSetLogPayload(event: event, agentId: "payne")
    XCTAssertEqual(payload.deviation?.kind, .failure)
    XCTAssertEqual(payload.agent_id, "payne")
}
```

- [ ] **Step 3: Add a static builder method in TransportV2**

If TransportV2 currently builds set_log inline in a closure, extract:

```swift
static func buildSetLogPayload(event: SetLogEvent, agentId: String?) -> V2.SetLog {
    var payload = V2.SetLog(
        workout_id: event.workoutId,
        exercise_slug: event.exerciseSlug,
        set_idx: event.setIdx,
        reps: event.reps,
        weight: event.weight,
        reps_in_reserve: event.repsInReserve,
        ts: ISO8601DateFormatter().string(from: event.ts),
        agent_id: agentId
    )
    if let d = event.deviation {
        payload.deviation = V2.SetLog.Deviation(
            kind: {
                switch d.kind {
                case .weightUnder: return .weight_under
                case .weightOver: return .weight_over
                case .repsUnder: return .reps_under
                case .repsOver: return .reps_over
                case .failure: return .failure
                case .tooEasy: return .too_easy
                }
            }(),
            magnitude: d.magnitude,
            target: V2.SetLog.DeviationTarget(
                reps_min: d.target.repsMin,
                reps_max: d.target.repsMax,
                weight: d.target.weight,
                rir: d.target.rir
            )
        )
    }
    return payload
}
```

Because `SetDeviation` already carries `target` (populated in `detectDeviation`, Task 2.1), the transport builder is a pure map — no lookup back to the plan needed.

- [ ] **Step 4: Rerun tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift \
        ios/JarvisApp/Sources/JarvisAppTests/  # whichever test file was touched
git commit -m "feat(ios): TransportV2 forwards deviation on set_log envelope"
```

---

## Phase 3 — Persistence + resume

### Task 3.1: Schema migration for `active_workout` table

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift`

- [ ] **Step 1: Add migration `v13-active-workout`**

Append after `v12-set-log-deviation`:

```swift
m.registerMigration("v13-active-workout") { db in
    try db.execute(sql: """
        CREATE TABLE active_workout (
          agent_id    TEXT PRIMARY KEY,
          workout_id  TEXT NOT NULL,
          plan_json   TEXT NOT NULL,
          cursor_json TEXT NOT NULL,
          message_id  TEXT NOT NULL,
          updated_at  REAL NOT NULL
        );
    """)
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift
git commit -m "feat(ios): GRDB migration v13-active-workout"
```

### Task 3.2: Add `ActiveWorkoutStore` + tests

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Storage/ActiveWorkoutStore.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/ActiveWorkoutStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Create the test file:

```swift
import XCTest
import GRDB
@testable import Jarvis

final class ActiveWorkoutStoreTests: XCTestCase {

    private func plan() -> WorkoutPlan {
        WorkoutPlan(
            workoutId: "w1", dayName: "Верх A", week: 2,
            intensityLabel: "тяжёлая",
            exercises: [ExercisePlan(exerciseSlug: "ex", targetSets: 4, targetReps: "8-10",
                                     targetRir: 2, restSec: 90, notes: nil, nameRu: nil,
                                     durationSec: nil, weightKgTarget: 100)],
            imageManifest: []
        )
    }

    func test_save_load_clear_roundtrip() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)

        let cursor = WorkoutCursor(
            currentExerciseIdx: 0, currentSetIdx: 1,
            logged: [LoggedExercise(exerciseSlug: "ex",
                                    sets: [LoggedSet(reps: 10, weight: 100, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0))],
                                    comment: nil)]
        )
        try store.save(agentId: "payne", workoutId: "w1", plan: plan(), cursor: cursor, messageId: "m1")
        let loaded = try store.load(agentId: "payne")
        XCTAssertEqual(loaded?.plan.workoutId, "w1")
        XCTAssertEqual(loaded?.cursor.currentSetIdx, 1)
        XCTAssertEqual(loaded?.cursor.logged.first?.sets.count, 1)
        XCTAssertEqual(loaded?.messageId, "m1")

        try store.clear(agentId: "payne")
        XCTAssertNil(try store.load(agentId: "payne"))
    }

    func test_save_overwrites_existing() throws {
        let dbq = try DatabaseQueue()
        try Schema.migrate(dbq)
        let store = ActiveWorkoutStore(writer: dbq)
        let cursor = WorkoutCursor(currentExerciseIdx: 0, currentSetIdx: 0, logged: [])
        try store.save(agentId: "payne", workoutId: "w1", plan: plan(), cursor: cursor, messageId: "m1")
        try store.save(agentId: "payne", workoutId: "w2", plan: plan(), cursor: cursor, messageId: "m2")
        let loaded = try store.load(agentId: "payne")
        XCTAssertEqual(loaded?.workoutId, "w2")
        XCTAssertEqual(loaded?.messageId, "m2")
    }
}
```

- [ ] **Step 2: Run to confirm failures**

Expected: build fail (unknown symbols `ActiveWorkoutStore`, `WorkoutCursor`, `ActiveWorkoutRecord`).

- [ ] **Step 3: Create `ActiveWorkoutStore.swift`**

```swift
import Foundation
import GRDB

/// Cursor to resume a live workout at exactly the same set/exercise/logged state.
struct WorkoutCursor: Codable, Equatable {
    var currentExerciseIdx: Int
    var currentSetIdx: Int
    var logged: [LoggedExercise]
}

/// One row from the `active_workout` table.
struct ActiveWorkoutRecord: Equatable {
    let agentId: String
    let workoutId: String
    let plan: WorkoutPlan
    let cursor: WorkoutCursor
    let messageId: String
    let updatedAt: Date
}

/// Persists the in-progress workout so that a kill/crash restore lands the user
/// back in the runner at the exact set + logged history.
final class ActiveWorkoutStore {
    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    func save(agentId: String, workoutId: String, plan: WorkoutPlan, cursor: WorkoutCursor, messageId: String) throws {
        let planData = try JSONEncoder().encode(plan)
        let cursorData = try JSONEncoder().encode(cursor)
        let planJson = String(data: planData, encoding: .utf8) ?? "{}"
        let cursorJson = String(data: cursorData, encoding: .utf8) ?? "{}"
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO active_workout (agent_id, workout_id, plan_json, cursor_json, message_id, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(agent_id) DO UPDATE SET
                    workout_id = excluded.workout_id,
                    plan_json = excluded.plan_json,
                    cursor_json = excluded.cursor_json,
                    message_id = excluded.message_id,
                    updated_at = excluded.updated_at
            """, arguments: [agentId, workoutId, planJson, cursorJson, messageId, Date().timeIntervalSince1970])
        }
    }

    func load(agentId: String) throws -> ActiveWorkoutRecord? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT workout_id, plan_json, cursor_json, message_id, updated_at
                FROM active_workout WHERE agent_id = ?
            """, arguments: [agentId]) else { return nil }
            let planData = (row["plan_json"] as String).data(using: .utf8) ?? Data()
            let cursorData = (row["cursor_json"] as String).data(using: .utf8) ?? Data()
            let plan = try JSONDecoder().decode(WorkoutPlan.self, from: planData)
            let cursor = try JSONDecoder().decode(WorkoutCursor.self, from: cursorData)
            return ActiveWorkoutRecord(
                agentId: agentId,
                workoutId: row["workout_id"],
                plan: plan,
                cursor: cursor,
                messageId: row["message_id"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    func clear(agentId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM active_workout WHERE agent_id = ?", arguments: [agentId])
        }
    }
}
```

- [ ] **Step 4: Rerun tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Storage/ActiveWorkoutStore.swift \
        ios/JarvisApp/Sources/JarvisAppTests/ActiveWorkoutStoreTests.swift
git commit -m "feat(ios): ActiveWorkoutStore — GRDB persist for in-progress workout"
```

### Task 3.3: Inject `ActiveWorkoutStore` into the stack

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppV2Bootstrap.swift`

- [ ] **Step 1: Extend `AppV2Stack`**

Add:

```swift
struct AppV2Stack {
    let store: ConversationStoreV2
    let transport: TransportV2
    let coordinator: AppContextCoordinator
    let dbq: DatabaseQueue
    let setLogQueue: SetLogQueue
    let activeWorkoutStore: ActiveWorkoutStore   // NEW
}
```

Both `build` functions: construct `ActiveWorkoutStore(writer: dbq / storage.dbq)` and pass it in.

- [ ] **Step 2: Build once, confirm compile**

Run: `xcodegen generate` in `ios/JarvisApp/`, then `xcodebuild build -project ios/JarvisApp/JarvisApp.xcodeproj -scheme Jarvis -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/AppV2Bootstrap.swift
git commit -m "feat(ios): expose ActiveWorkoutStore on AppV2Stack"
```

### Task 3.4: `WorkoutCoordinator` persists on every mutation + restoring init

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift`

- [ ] **Step 1: Write failing restore test**

Append to tests:

```swift
func test_restoringInit_reproducesCursorAndLogged() throws {
    let queue = try makeQueue()
    let dbq = try DatabaseQueue()
    try Schema.migrate(dbq)
    let store = ActiveWorkoutStore(writer: dbq)
    let plan = makePlan(exerciseCount: 2, setsPerExercise: 3)
    let cursor = WorkoutCursor(
        currentExerciseIdx: 1, currentSetIdx: 2,
        logged: [
            LoggedExercise(exerciseSlug: "ex-0",
                           sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0))],
                           comment: nil),
            LoggedExercise(exerciseSlug: "ex-1",
                           sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0)),
                                  LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date(timeIntervalSince1970: 0))],
                           comment: nil),
        ]
    )
    try store.save(agentId: "payne", workoutId: plan.workoutId, plan: plan, cursor: cursor, messageId: "m")
    let record = try store.load(agentId: "payne")!

    let coord = WorkoutCoordinator(restoring: record, queue: queue, store: store)
    XCTAssertEqual(coord.currentExerciseIdx, 1)
    XCTAssertEqual(coord.currentSetIdx, 2)
    XCTAssertEqual(coord.loggedForCurrentExercise.count, 2)
}

func test_logSet_persistsToActiveWorkoutStore() throws {
    let queue = try makeQueue()
    let dbq = try DatabaseQueue()
    try Schema.migrate(dbq)
    let store = ActiveWorkoutStore(writer: dbq)
    let plan = makePlan()
    let coord = WorkoutCoordinator(plan: plan, queue: queue, store: store, agentId: "payne", messageId: "m")
    coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
    let rec = try store.load(agentId: "payne")
    XCTAssertEqual(rec?.cursor.currentSetIdx, 1)
    XCTAssertEqual(rec?.cursor.logged.first?.sets.count, 1)
}

func test_complete_clearsActiveWorkoutStore() throws {
    let queue = try makeQueue()
    let dbq = try DatabaseQueue()
    try Schema.migrate(dbq)
    let store = ActiveWorkoutStore(writer: dbq)
    let coord = WorkoutCoordinator(plan: makePlan(), queue: queue, store: store, agentId: "payne", messageId: "m")
    coord.logSet(reps: 10, weight: 20, repsInReserve: 2)
    _ = coord.complete(sessionFeeling: 4, sessionFeelingLabel: "ok")
    XCTAssertNil(try store.load(agentId: "payne"))
}
```

- [ ] **Step 2: Add optional store + agentId/messageId to `WorkoutCoordinator`**

At the top of the class (after existing published fields):

```swift
private let store: ActiveWorkoutStore?
private let agentId: String?
private let messageId: String?
```

Add two initializers — extended standard init and a restore init:

```swift
init(plan: WorkoutPlan, queue: SetLogQueue, startedAt: Date = Date(),
     store: ActiveWorkoutStore? = nil, agentId: String? = nil, messageId: String? = nil) {
    self.plan = plan
    self.queue = queue
    self.startedAt = startedAt
    self.logged = plan.exercises.map {
        LoggedExercise(exerciseSlug: $0.exerciseSlug, sets: [], comment: nil)
    }
    self.store = store
    self.agentId = agentId
    self.messageId = messageId
}

init(restoring record: ActiveWorkoutRecord, queue: SetLogQueue, store: ActiveWorkoutStore) {
    self.plan = record.plan
    self.queue = queue
    self.startedAt = record.updatedAt
    self.logged = record.cursor.logged
    self.currentExerciseIdx = record.cursor.currentExerciseIdx
    self.currentSetIdx = record.cursor.currentSetIdx
    self.store = store
    self.agentId = record.agentId
    self.messageId = record.messageId
}
```

Add a private helper:

```swift
private func persist() {
    guard let store, let agentId, let messageId else { return }
    let cursor = WorkoutCursor(
        currentExerciseIdx: currentExerciseIdx,
        currentSetIdx: currentSetIdx,
        logged: logged
    )
    try? store.save(agentId: agentId, workoutId: plan.workoutId,
                    plan: plan, cursor: cursor, messageId: messageId)
}
```

Call `persist()` at the end of `logSet`, `finishExercise`, `activate(idx:)`.

Extend `complete(...)` and `abort()`:

```swift
func complete(...) -> WorkoutSession {
    isFinished = true
    if let store, let agentId { try? store.clear(agentId: agentId) }
    return WorkoutSession(...)
}

func abort() {
    isFinished = true
    if let store, let agentId { try? store.clear(agentId: agentId) }
}
```

- [ ] **Step 3: Rerun tests**

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift
git commit -m "feat(ios): Coordinator persists cursor and can restore

Kill-and-resume produces identical state; complete/abort clears record."
```

### Task 3.5: `MessageRow.WorkoutPlanRow` — `isResuming` label + style

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift:647-...`

- [ ] **Step 1: Add `isResuming` and flip CTA text/style**

Extend `WorkoutPlanRow`:

```swift
struct WorkoutPlanRow: View {
    let messageId: String
    let info: WorkoutPlanCardInfo
    var onStart: ((WorkoutPlan, String) -> Void)?
    var onCancel: ((String) -> Void)?
    let isLast: Bool
    var isResuming: Bool = false   // NEW
```

Replace the CTA label branch inside `body`:

```swift
Text(info.done
     ? "Посмотреть тренировку"
     : (isResuming ? "Продолжить тренировку" : "Посмотреть тренировку"))
    .font(.system(size: 13, weight: .medium))
```

- [ ] **Step 2: Wire caller in `Components/MessageRow.swift`**

Search for `WorkoutPlanRow(` construction inside `MessageRow` and add:

```swift
WorkoutPlanRow(
    messageId: messageId,
    info: info,
    onStart: ...,
    onCancel: ...,
    isLast: isLast,
    isResuming: isResuming
)
```

The `isResuming` flag will be threaded from `ChatView` via a new property on `MessageRow`. Extend `MessageRow` to expose `let resumeMessageId: String?` and compute:

```swift
private var isResuming: Bool { resumeMessageId == messageId }
```

- [ ] **Step 3: Build**

Run: `xcodebuild build …`
Expected: clean build (ChatView not yet passing the property — default value `nil` keeps behavior).

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift
git commit -m "feat(ios): WorkoutPlanRow CTA flips to Продолжить on resume"
```

### Task 3.6: `ChatView` restores + drives `isResuming` + sticky banner

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`

- [ ] **Step 1: Add resume state + load on appear**

At the top of `ChatView`:

```swift
@State private var activeWorkout: ActiveWorkoutRecord? = nil
```

In `onAppear` (or the closest equivalent lifecycle hook) for Payne:

```swift
if active.active.rawValue == "payne" {
    activeWorkout = try? coordinator.stack?.activeWorkoutStore.load(agentId: "payne")
}
```

Also refresh in `onChange(of: active.active)` — reload when the user switches to Payne.

- [ ] **Step 2: Add resume routing**

Add:

```swift
private func resumeWorkout(_ record: ActiveWorkoutRecord) {
    guard let stack = coordinator.stack else { return }
    let wc = WorkoutCoordinator(
        restoring: record, queue: stack.setLogQueue, store: stack.activeWorkoutStore
    )
    activeWorkout = nil  // remove sticky banner immediately
    self.activeWorkout = record  // clear on close via onDismiss? Actually clear on complete/abort.
    let presentation = WorkoutPresentation(
        plan: record.plan, phase: .running, coord: wc, messageId: record.messageId
    )
    self.activeWorkout = record
    self.activeWorkout = nil
    self.activeWorkoutPresentation(presentation)  // helper: sets activeWorkout state used by fullScreenCover
}
```

Simplify: reuse whatever state variable already drives `fullScreenCover` for the runner (in `ChatView` this is `activeWorkout: WorkoutPresentation?`). Assign:

```swift
private func resumeWorkout(_ record: ActiveWorkoutRecord) {
    guard let stack = coordinator.stack else { return }
    let wc = WorkoutCoordinator(
        restoring: record, queue: stack.setLogQueue, store: stack.activeWorkoutStore
    )
    activeWorkout = WorkoutPresentation(
        plan: record.plan, phase: .running, coord: wc, messageId: record.messageId
    )
}
```

(Where `activeWorkout` is the existing `WorkoutPresentation?` state driving `fullScreenCover`.)

- [ ] **Step 3: Thread `resumeMessageId` into `MessageRow`**

In the `MessageListView` construction site pass:

```swift
resumeMessageId: activeWorkoutRecord?.messageId
```

Where `activeWorkoutRecord` is a `@State` holding the loaded record (rename from `activeWorkout` if that name collides with the runner presentation state). Prop-drill through `MessageListView` → `MessageRow` → `WorkoutPlanRow`.

Also add a tap handler on `WorkoutPlanRow` for the resume path — when `isResuming == true`, tap invokes `resumeWorkout(record)` instead of the standard `startWorkout(...)`. Simplest: make `onStart` a closure with two forms — but you can also add a second callback `onResume: ((String) -> Void)?` and have `WorkoutPlanRow` pick which one to call in the tap based on `isResuming`.

- [ ] **Step 4: Add sticky banner fallback**

At the top of the `MessageListView` block:

```swift
if let record = activeWorkoutRecord, !visibleMessages.contains(where: { $0.id == record.messageId }) {
    HStack {
        Text("Незавершённая тренировка")
        Spacer()
        Button("Продолжить") { resumeWorkout(record) }
            .foregroundStyle(Theme.accent)
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .background(Theme.accent.opacity(0.12))
}
```

- [ ] **Step 5: Clear on close**

Where `onClose(session)` fires (finish/abort), also clear `activeWorkoutRecord = nil`. The coordinator already deleted the store row.

- [ ] **Step 6: Build + smoke on simulator**

Run: `xcodebuild build … -scheme Jarvis`
Expected: clean build. Then simulator smoke: start a workout, kill app (Cmd-Q on simulator), relaunch → observe the card CTA reads "Продолжить тренировку".

- [ ] **Step 7: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift \
        ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift
git commit -m "feat(ios): ChatView loads and resumes active workout

Card CTA flips to Продолжить тренировку; sticky banner when the card
scrolled out of the 500-message window."
```

---

## Phase 4 — Coach hint anchored on set chip

### Task 4.1: `WorkoutInboundEvent.coachMessage` carries `setRef`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutInbound.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift:432-437`

- [ ] **Step 1: Extend the event**

Replace `case coachMessage(text: String, workoutId: String?)`:

```swift
case coachMessage(text: String, workoutId: String?, setRef: (exerciseSlug: String, setIdx: Int)?)
```

- [ ] **Step 2: Propagate from AppCoordinator dispatch**

In `AppCoordinator.swift` at the `.coachMessage(let c)` case:

```swift
case .coachMessage(let c):
    let setRef = c.set_ref.map { (exerciseSlug: $0.exercise_slug, setIdx: $0.set_idx) }
    workoutBus.events.send(.coachMessage(text: c.text, workoutId: c.workout_id, setRef: setRef))
```

- [ ] **Step 3: Update ChatView `.onReceive`**

Locate `ChatView` line around 446 (`case .planReceived, .coachMessage, .programUpdated:`) and split the coachMessage handling:

```swift
case .coachMessage(let text, _, let setRef):
    if let setRef, let coord = activeWorkout?.coord {
        coord.attachCoachHint(exerciseSlug: setRef.exerciseSlug, setIdx: setRef.setIdx, text: text)
    } else if let wv = presentedWorkoutView {
        wv.surfaceCoachMessage(text)
    }
```

(`attachCoachHint` will be added in Task 4.2; wire tests will fail until then.)

- [ ] **Step 4: Build (expect fail for unknown attachCoachHint — next task adds it)**

Skip to Task 4.2, then re-run build.

- [ ] **Step 5: Commit after 4.2 passes**

(Deferred to Task 4.2's commit or a joint commit.)

### Task 4.2: `WorkoutCoordinator.attachCoachHint`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift`

- [ ] **Step 1: Write failing test**

Append:

```swift
func test_attachCoachHint_writesHintOnMatchingSet() throws {
    let queue = try makeQueue()
    let dbq = try DatabaseQueue()
    try Schema.migrate(dbq)
    let store = ActiveWorkoutStore(writer: dbq)
    // Force a deviation-carrying set so the log path exercises the full write.
    var plan = makePlan()
    plan = WorkoutPlan(
        workoutId: plan.workoutId, dayName: plan.dayName, week: plan.week,
        intensityLabel: plan.intensityLabel,
        exercises: [ExercisePlan(exerciseSlug: "ex-0", targetSets: 4, targetReps: "8-10",
                                 targetRir: 2, restSec: 120, notes: nil, nameRu: nil,
                                 durationSec: nil, weightKgTarget: 100)],
        imageManifest: [])
    let coord = WorkoutCoordinator(plan: plan, queue: queue, store: store, agentId: "payne", messageId: "m")
    coord.logSet(reps: 10, weight: 100, repsInReserve: 0)
    coord.attachCoachHint(exerciseSlug: "ex-0", setIdx: 0, text: "отдохни дольше")
    XCTAssertEqual(coord.logged[0].sets[0].coachHint, "отдохни дольше")
}

func test_attachCoachHint_missingSet_isNoOp() throws {
    let queue = try makeQueue()
    let coord = WorkoutCoordinator(plan: makePlan(), queue: queue)
    coord.attachCoachHint(exerciseSlug: "ex-0", setIdx: 42, text: "should not crash")
}
```

- [ ] **Step 2: Add method**

In `WorkoutCoordinator`:

```swift
func attachCoachHint(exerciseSlug: String, setIdx: Int, text: String) {
    guard let exIdx = plan.exercises.firstIndex(where: { $0.exerciseSlug == exerciseSlug }) else { return }
    guard logged[exIdx].sets.indices.contains(setIdx) else { return }
    logged[exIdx].sets[setIdx].coachHint = text
    persist()
}
```

- [ ] **Step 3: Rerun tests**

Expected: PASS.

- [ ] **Step 4: Commit (bundles 4.1 + 4.2)**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WorkoutInbound.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift
git commit -m "feat(ios): coach_message with set_ref anchors on the set chip

Falls back to the top banner when set_ref is absent."
```

### Task 4.3: 💬 badge + tap sheet in `LoggedSetChips`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/LoggedSetChips.swift`

- [ ] **Step 1: Render badge**

Replace the chip loop:

```swift
ForEach(Array(logged.enumerated()), id: \.offset) { idx, s in
    Button {
        if s.coachHint != nil { tappedIdx = idx }
    } label: {
        HStack(spacing: 3) {
            Text("✓ \(s.reps)×\(WorkoutSetFormat.weight(s.weight))")
            if s.coachHint != nil {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.15)))
    }
    .buttonStyle(.plain)
    .disabled(s.coachHint == nil)
}
```

Add `@State private var tappedIdx: Int? = nil` and a `.sheet(item: $tappedIdxWrapper)` (or use `.sheet(isPresented:)` bound to `tappedIdx != nil`) rendering the coach text with a Close button.

Simplest concrete implementation:

```swift
struct LoggedSetChips: View {
    let logged: [LoggedSet]
    let currentSetIdx: Int
    let targetSets: Int
    @State private var tappedIdx: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(logged.enumerated()), id: \.offset) { idx, s in
                chipButton(idx: idx, set: s)
            }
            if let label = WorkoutRunnerLogic.setLabel(currentSetIdx: currentSetIdx, targetSets: targetSets) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: Binding(
            get: { tappedIdx != nil },
            set: { if !$0 { tappedIdx = nil } }
        )) {
            if let idx = tappedIdx, logged.indices.contains(idx),
               let text = logged[idx].coachHint {
                VStack(spacing: 12) {
                    Text("Пейн").font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(text).font(.body).multilineTextAlignment(.leading)
                    Button("Закрыть") { tappedIdx = nil }
                }
                .padding(20)
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private func chipButton(idx: Int, set: LoggedSet) -> some View {
        Button {
            if set.coachHint != nil { tappedIdx = idx }
        } label: {
            HStack(spacing: 3) {
                Text("✓ \(set.reps)×\(WorkoutSetFormat.weight(set.weight))")
                if set.coachHint != nil {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10))
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .disabled(set.coachHint == nil)
    }
}
```

- [ ] **Step 2: Build + simulator smoke**

Run: `xcodebuild build …`. Expected: clean build. In simulator, log a set with deviation, receive a set_ref coach — chip shows 💬, tap opens sheet.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/LoggedSetChips.swift
git commit -m "feat(ios): LoggedSetChips shows 💬 badge for sets with coach hint"
```

---

## Phase 5 — Rest timer next hint

### Task 5.1: Refactor `restHint` to scan for first-unfinished from start

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift:200-208`

- [ ] **Step 1: Write failing tests**

Append:

```swift
func test_restHint_showsCurrentSetWhenMoreRemain() {
    let exs = [ExercisePlan(exerciseSlug: "a", targetSets: 3, targetReps: "8", targetRir: 2,
                            restSec: 60, notes: nil, nameRu: "A")]
    let logged = [LoggedExercise(exerciseSlug: "a", sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date())], comment: nil)]
    let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 0)
    XCTAssertEqual(hint, "подход 2 — A")
}

func test_restHint_scansEarlierUnfinishedWhenCurrentDone() {
    let exs = [
        ExercisePlan(exerciseSlug: "a", targetSets: 2, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "A"),
        ExercisePlan(exerciseSlug: "b", targetSets: 2, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "B"),
    ]
    // User did all of B first (2 sets), current now on B; A never touched.
    let logged = [
        LoggedExercise(exerciseSlug: "a", sets: [], comment: nil),
        LoggedExercise(exerciseSlug: "b", sets: [
            LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date()),
            LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date()),
        ], comment: nil),
    ]
    let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 1)
    XCTAssertEqual(hint, "A — подход 1")
}

func test_restHint_allDone_returnsFinished() {
    let exs = [
        ExercisePlan(exerciseSlug: "a", targetSets: 1, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "A"),
    ]
    let logged = [LoggedExercise(exerciseSlug: "a", sets: [LoggedSet(reps: 8, weight: 20, repsInReserve: 2, ts: Date())], comment: nil)]
    let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 0)
    XCTAssertEqual(hint, "Тренировка закончена")
}

func test_restHint_skipsDurationExercises() {
    let exs = [
        ExercisePlan(exerciseSlug: "cardio", targetSets: 0, targetReps: "", targetRir: 0, restSec: 0, notes: nil, nameRu: "Кардио", durationSec: 300),
        ExercisePlan(exerciseSlug: "a", targetSets: 1, targetReps: "8", targetRir: 2, restSec: 60, notes: nil, nameRu: "A"),
    ]
    let logged = [
        LoggedExercise(exerciseSlug: "cardio", sets: [], comment: nil),
        LoggedExercise(exerciseSlug: "a", sets: [], comment: nil),
    ]
    let hint = WorkoutRunnerLogic.restHint(logged: logged, exercises: exs, activeIdx: 1)
    XCTAssertEqual(hint, "подход 1 — A")
}
```

- [ ] **Step 2: Confirm failure**

Expected: 4 failures (wrong signature).

- [ ] **Step 3: Replace `restHint`**

Delete the old:

```swift
static func restHint(setsDone: Int, targetSets: Int, nextExerciseName: String?) -> String {
    if targetSets > 0, setsDone >= targetSets, let next = nextExerciseName {
        return next
    }
    return "подход \(setsDone + 1)"
}
```

Add:

```swift
static func restHint(logged: [LoggedExercise], exercises: [ExercisePlan], activeIdx: Int) -> String {
    guard exercises.indices.contains(activeIdx), logged.indices.contains(activeIdx) else {
        return "Тренировка закончена"
    }
    let cur = exercises[activeIdx]
    let curDone = logged[activeIdx].sets.count
    if cur.targetSets > 0, curDone < cur.targetSets {
        return "подход \(curDone + 1) — \(cur.displayName)"
    }
    for i in exercises.indices where exercises[i].targetSets > 0 {
        if logged[i].sets.count < exercises[i].targetSets {
            return "\(exercises[i].displayName) — подход \(logged[i].sets.count + 1)"
        }
    }
    return "Тренировка закончена"
}
```

- [ ] **Step 4: Update the WorkoutView call site**

In `WorkoutView.swift` around line 200:

```swift
private var restHint: String {
    WorkoutRunnerLogic.restHint(
        logged: coordinator.logged,
        exercises: coordinator.plan.exercises,
        activeIdx: coordinator.currentExerciseIdx
    )
}
```

- [ ] **Step 5: Rerun tests + build**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift \
        ios/JarvisApp/Sources/JarvisAppTests/WorkoutRunnerLogicTests.swift \
        ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift
git commit -m "feat(ios): rest timer scans for first unfinished set

Handles skipped-then-returned exercises. Says Тренировка закончена
when nothing left."
```

---

## Phase 6 — Payne CLAUDE.md rules

### Task 6.1: Set_ref-on-deviation rule + summary-format rule

**Files:**
- Modify: `groups/payne/skills/workout-mode/SKILL.md`

- [ ] **Step 1: Add set_ref-on-deviation rule under `set_log` handling**

Locate the `set_log` block in the skill (search for `set_log { exercise_slug, set_index...` heading) and replace the body:

```markdown
### `set_log { exercise_slug, set_idx, weight_kg, reps, rir, deviation? }`

Запиши в `sessions/YYYY-MM-DD.json` (создай если нет, append подход в `exercises[].sets[]`).

- Если `deviation` **отсутствует** — молчи. iOS сам показывает прогресс.
- Если `deviation` **присутствует** — обязательно вызови `workout.coach` с `set_ref: {exercise_slug, set_idx}` того же подхода. Без `set_ref` ответ не привязывается к чипу и теряется.
  - `weight_under` / `weight_over` — коммент к весу и к следующему подходу.
  - `reps_under` — что мешало добить, что делать в следующий раз.
  - `reps_over` — накинуть вес.
  - `failure` (rir=0) — коротко: отдых больше, форма ок?
  - `too_easy` (rir≥4) — накинуть вес или пропустить лишний подход.
- Совет — одно действие. Не «продолжай в том же духе».
```

- [ ] **Step 2: Add mandatory summary format under `workout_complete`**

Locate `workout_complete { session_id, duration_min, ...`, append/replace the outbound section:

```markdown
### `workout_complete { session_id, duration_min, perceived_overall_rir, notes? }`

Финал тренировки.

1. Запиши финальные поля в `sessions/<session_id>.json`.
2. Обнови `memories/index.md` (последняя тренировка, тренд тяжести, сдвиг недельного объёма).
3. Запусти skill `progression` → обновит `programs/current.json` если все подходы сданы.
4. Эмиттни Джарвису и Грегу через a2a (форматы ниже).
5. **Обязательно** отправь одно сообщение в чат Сергея в этом формате:

    ```
    Готово · <day_name>
    Тоннаж <N> кг · <M> мин · подходов <done>/<planned>

    <1–2 предложения — что было сильно/слабо, ключевой сигнал>

    Следующая: <day_name следующего дня>. <одно действие: вес/подход/отдых>.
    ```

    - Тоннаж = sum(reps × weight) по всем сданным подходам.
    - `<done>/<planned>` = сумма `session.exercises[].sets.length` над суммой `targetSets` из плана дня.
    - Совет — одно конкретное действие.
    - Без эмодзи-солнышек и «молодец».
```

- [ ] **Step 3: Commit**

```bash
git add groups/payne/skills/workout-mode/SKILL.md
git commit -m "feat(payne): mandatory set_ref on deviation + post-workout summary format"
```

---

## Phase 7 — iOS version bump + deploy

### Task 7.1: Bump project version + regenerate

**Files:**
- Modify: `ios/JarvisApp/project.yml`

- [ ] **Step 1: Read current versions**

Run: `grep -E 'CURRENT_PROJECT_VERSION|MARKETING_VERSION' ios/JarvisApp/project.yml`

- [ ] **Step 2: Bump CURRENT_PROJECT_VERSION +1 and MARKETING_VERSION +0.0.1**

Edit `project.yml` — increment both fields.

- [ ] **Step 3: Regenerate + rebuild**

Run: `cd ios/JarvisApp && xcodegen generate && cd - && xcodebuild build …`

- [ ] **Step 4: Commit including the regenerated pbxproj**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "chore(ios): bump build for workout runner UI fixes"
```

### Task 7.2: Deploy host + agent-runner + Payne skill to VDS

**Files:**
- None (deploy commands).

- [ ] **Step 1: Push host code**

```bash
git push origin main
```

- [ ] **Step 2: Pull + build on VDS**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw"'
```

- [ ] **Step 3: Rebuild container image (agent-runner deps didn't change but MCP tool schema did — rebuild the image)**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./container/build.sh"'
```

- [ ] **Step 4: Deploy Payne skill (gitignored)**

```bash
COPYFILE_DISABLE=1 tar cz groups/payne/skills/workout-mode > /tmp/payne-workout-mode.tgz
scp /tmp/payne-workout-mode.tgz root@148.253.211.164:/tmp/payne-workout-mode.tgz
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && tar xzf /tmp/payne-workout-mode.tgz -C agents/ && find agents/payne -name \"._*\" -delete 2>/dev/null; pnpm exec tsx scripts/reload-claude-md.ts payne"'
```

(Note: shared-code mount path per project memory is `agents/<folder>` for Payne. If deployment fails because the target is `groups/payne/...`, adjust the tar destination to `groups/` per current install layout.)

- [ ] **Step 5: Smoke test on device**

- Install new iOS build.
- Start a workout in the runner. Log a set with weight 20% under target → expect a coach chip 💬 on that set within a few seconds.
- Skip an exercise, come back — rest-timer hint says the skipped exercise's name.
- Kill the app mid-workout, relaunch → card CTA reads "Продолжить тренировку".
- Finish the workout via Финиш → Payne posts the formatted summary in chat.

- [ ] **Step 6: Commit — none (deploy only).**

---

## Self-Review

**Spec coverage**

- Axis 1 (persist): Tasks 3.1 (schema), 3.2 (store), 3.3 (bootstrap), 3.4 (coordinator persist + restore), 3.5 (CTA flip), 3.6 (ChatView load + resume + sticky banner) — full coverage.
- Axis 2 (deviation): Tasks 0.1 (wire), 1.1 (Swift mirror), 2.1 (detection), 2.2 (model fields), 2.3 (coordinator), 2.4 (transport payload), 0.2/1.2 (coach_message set_ref), 4.1/4.2 (bus event + attachCoachHint), 4.3 (chip render + sheet), 0.3 (bridge passthrough test), 0.4 (MCP tool arg), 6.1 (Payne rule) — full coverage.
- Axis 3 (rest timer): Task 5.1 (algorithm + call site + tests) — full coverage.
- Axis 4 (post-workout summary): Task 6.1 (mandatory format) — full coverage.

**Placeholder scan**: no TBD/TODO/"add appropriate…". `SetDeviation` carries the target snapshot inline (populated by `detectDeviation`) so the transport-side builder in Task 2.4 is a pure map.

**Type consistency**: `SetDeviationKind` case names are `weightUnder/weightOver/repsUnder/repsOver/failure/tooEasy` in Swift, mapped explicitly to snake-case wire values inside Task 2.4's builder. `WorkoutCursor`, `ActiveWorkoutRecord`, `ActiveWorkoutStore` names consistent across Tasks 3.2-3.4. `attachCoachHint(exerciseSlug:setIdx:text:)` signature consistent across 4.1/4.2.
