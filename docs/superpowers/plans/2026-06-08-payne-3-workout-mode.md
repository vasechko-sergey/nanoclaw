# Payne — Plan 3: Workout Mode

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the full structured-workout experience: a `WorkoutView` SwiftUI screen that walks Sergei through each exercise, streams `set_log` events back to Payne in real time, prefetches exercise images on plan receipt, supports exercise swap with intelligent validation, and ends with an automated retro. Includes the rest-timer adaptation rule, weekly volume retro, and on-disk session log persistence.

**Architecture:** New WS envelope types extend the iOS-app v2 protocol. A new `WorkoutBridge` on the host (modelled on the existing `ContextBridge`) routes structured events between iOS and Payne's session DB. iOS holds an in-memory state machine for the live workout (the durable record is on disk inside Payne's group folder) plus a Core-Data backed `SetLogQueue` for at-least-once delivery. Payne uses bun scripts (`progression.js`, `volume-report.js`) for deterministic calculations and writes session JSON to disk via standard file tools — no new MCP tools beyond what the agent runtime already exposes.

**Tech Stack:** TypeScript (host), Bun (agent-runner — `progression.js`, `volume-report.js`), Swift / SwiftUI / Combine / UserNotifications (iOS), Zod (protocol).

**Prerequisites:** Plan 1 (multi-agent routing) **and** Plan 2 (Payne agent foundation) both deployed. Payne is reachable from the Майор Пейн iOS chip and has a `programs/current.json` from intake.

**Spec:** [docs/superpowers/specs/2026-06-08-payne-fitness-coach-design.md](../specs/2026-06-08-payne-fitness-coach-design.md) — §3.2, §3.3, §4, §5.3, §5.4, §5.5, §5.6, §7.2.

---

## File map

### Modify (protocol & host)
- `shared/ios-app-protocol/v2.ts` — new envelope types (see Task 1)
- `shared/ios-app-protocol/v2.test.ts`
- `shared/ios-app-protocol/fixtures/workout_plan.json` (new), `set_log.json` (new), `exercise_swap_options.json` (new), `coach_message.json` (new)
- `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` — Swift mirrors
- `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`
- `src/channels/ios-app/v2/inbound-dispatch.ts` — accept new inbound types, hand to `WorkoutBridge`
- `src/channels/ios-app/v2/inbound-dispatch.test.ts`
- `src/channels/ios-app/v2/types.ts` — minor

### Create (host)
- `src/channels/ios-app/v2/workout-bridge.ts` — round-trip translator (iOS structured event ↔ Payne session message)
- `src/channels/ios-app/v2/workout-bridge.test.ts`

### Create (groups/payne — runs inside the container)
- `groups/payne/scripts/progression.js` — bun helper: given last session JSON + program day, compute next session targets
- `groups/payne/scripts/progression.test.js` — bun-test
- `groups/payne/scripts/volume-report.js` — weekly retro generator
- `groups/payne/scripts/volume-report.test.js`

### Modify (groups/payne)
- `groups/payne/CLAUDE.md` — workout-mode behaviour, swap rule, retro cadence, session-write path

### Create (iOS)
- `ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift` — `WorkoutPlan`, `ExercisePlan`, `LoggedSet`, `WorkoutSession` value types
- `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift` — owns the in-memory state machine for an active workout
- `ios/JarvisApp/Sources/JarvisApp/Services/SetLogQueue.swift` — durable outbound queue for `set_log` events
- `ios/JarvisApp/Sources/JarvisApp/Services/ExerciseImageCache.swift` — disk cache keyed by slug+sha256, fires `image_request` on miss
- `ios/JarvisApp/Sources/JarvisApp/Services/RestTimer.swift` — Combine-backed countdown with local-notification scheduling
- `ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift` — top-level screen
- `ios/JarvisApp/Sources/JarvisApp/Views/Workout/ExerciseCardView.swift`
- `ios/JarvisApp/Sources/JarvisApp/Views/Workout/SetRowView.swift`
- `ios/JarvisApp/Sources/JarvisApp/Views/Workout/SwapSheet.swift`
- `ios/JarvisApp/Sources/JarvisApp/Views/Workout/RestTimerOverlay.swift`
- `ios/JarvisApp/Sources/JarvisApp/Views/Workout/CoachBannerView.swift`
- `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift`
- `ios/JarvisApp/Sources/JarvisAppTests/SetLogQueueTests.swift`

### Modify (iOS)
- `ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcherV2.swift` — recognize new envelope types, route to `WorkoutCoordinator`
- `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` — typed builders for outbound workout envelopes
- `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` — "Начать тренировку" button when last inbound was a `workout_plan`

---

## Task 1: New envelope types in v2.ts

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts`
- Modify: `shared/ios-app-protocol/v2.test.ts`

- [ ] **Step 1: Write failing tests for each new envelope**

Add to `shared/ios-app-protocol/v2.test.ts`:

```ts
describe('workout envelopes', () => {
  const base = {
    v: 2 as const, kind: 'control' as const,
    id: '00000000-0000-4000-8000-000000000099',
    seq: 0, ts: '2026-06-09T18:00:00.000Z',
  };

  it('parses workout_start_request', () => {
    const e = Envelopes.WorkoutStartRequest.parse({
      ...base, type: 'workout_start_request',
      payload: { date: '2026-06-09', agent_id: 'payne' },
    });
    expect(e.payload.date).toBe('2026-06-09');
  });

  it('parses workout_plan with image_manifest', () => {
    const e = Envelopes.WorkoutPlan.parse({
      ...base, type: 'workout_plan',
      payload: {
        workout_id: '01J6Z8W3K2N5A7B9C1D3E5F7G9',
        plan_json: { day_name: 'Верх A', exercises: [] },
        image_manifest: [{ slug: 'incline-db-press', sha256: 'abc' }],
        agent_id: 'payne',
      },
    });
    expect(e.payload.image_manifest).toHaveLength(1);
  });

  it('parses set_log', () => {
    const e = Envelopes.SetLog.parse({
      ...base, kind: 'data', type: 'set_log',
      payload: {
        workout_id: 'w1', exercise_slug: 'incline-db-press',
        set_idx: 0, reps: 10, weight: 22.5, reps_in_reserve: 3,
        ts: '2026-06-09T19:05:00.000Z', agent_id: 'payne',
      },
    });
    expect(e.payload.reps_in_reserve).toBe(3);
  });

  it('parses exercise_swap_request without proposed', () => {
    const e = Envelopes.ExerciseSwapRequest.parse({
      ...base, type: 'exercise_swap_request',
      payload: { workout_id: 'w1', exercise_slug: 'incline-db-press', agent_id: 'payne' },
    });
    expect(e.payload.proposed).toBeUndefined();
  });

  it('parses workout_complete with full session', () => {
    const e = Envelopes.WorkoutComplete.parse({
      ...base, kind: 'data', type: 'workout_complete',
      payload: {
        workout_id: 'w1',
        full_session_json: { date: '2026-06-09', exercises: [] },
        agent_id: 'payne',
      },
    });
    expect(e.payload.workout_id).toBe('w1');
  });

  it('parses coach_message', () => {
    const e = Envelopes.CoachMessage.parse({
      ...base, type: 'coach_message',
      payload: { text: 'сбавь до 20', workout_id: 'w1', agent_id: 'payne' },
    });
    expect(e.payload.text).toBe('сбавь до 20');
  });
});
```

- [ ] **Step 2: Run; expect failures**

```bash
pnpm exec vitest run shared/ios-app-protocol/v2.test.ts
```

- [ ] **Step 3: Add the new envelopes to `v2.ts`**

Inside the `Envelopes` object, add:

```ts
WorkoutStartRequest: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('workout_start_request'),
  payload: z.object({
    date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    agent_id: z.string().min(1).optional(),
  }),
}),
WorkoutPlan: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('workout_plan'),
  payload: z.object({
    workout_id: z.string().min(1),
    plan_json: z.record(z.string(), z.unknown()),
    image_manifest: z.array(z.object({
      slug: z.string().min(1),
      sha256: z.string().min(1),
      url: z.string().optional(),
    })),
    agent_id: z.string().min(1).optional(),
  }),
}),
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
  }),
}),
ExerciseDone: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('exercise_done'),
  payload: z.object({
    workout_id: z.string().min(1),
    exercise_slug: z.string().min(1),
    comment: z.string().optional(),
    agent_id: z.string().min(1).optional(),
  }),
}),
WorkoutComplete: EnvelopeBase.extend({
  kind: z.literal('data'),
  type: z.literal('workout_complete'),
  payload: z.object({
    workout_id: z.string().min(1),
    full_session_json: z.record(z.string(), z.unknown()),
    agent_id: z.string().min(1).optional(),
  }),
}),
WorkoutAbort: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('workout_abort'),
  payload: z.object({
    workout_id: z.string().min(1),
    reason: z.string().optional(),
    agent_id: z.string().min(1).optional(),
  }),
}),
ImageRequest: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('image_request'),
  payload: z.object({
    slug: z.string().min(1),
    agent_id: z.string().min(1).optional(),
  }),
}),
ImageBlob: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('image_blob'),
  payload: z.object({
    slug: z.string().min(1),
    sha256: z.string().min(1),
    base64: z.string().min(1),
    agent_id: z.string().min(1).optional(),
  }),
}),
ExerciseSwapRequest: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('exercise_swap_request'),
  payload: z.object({
    workout_id: z.string().min(1),
    exercise_slug: z.string().min(1),
    proposed: z.string().optional(),
    agent_id: z.string().min(1).optional(),
  }),
}),
ExerciseSwapConfirm: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('exercise_swap_confirm'),
  payload: z.object({
    workout_id: z.string().min(1),
    original_slug: z.string().min(1),
    new_slug: z.string().min(1),
    persist: z.boolean().optional(),
    agent_id: z.string().min(1).optional(),
  }),
}),
ExerciseSwapOptions: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('exercise_swap_options'),
  payload: z.object({
    workout_id: z.string().min(1),
    original_slug: z.string().min(1),
    accepted: z.object({ slug: z.string() }).optional(),
    rejected: z.object({ slug: z.string(), reason: z.string() }).optional(),
    alternatives: z.array(z.object({ slug: z.string(), why: z.string() })),
    agent_id: z.string().min(1).optional(),
  }),
}),
ProgramUpdate: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('program_update'),
  payload: z.object({
    program_json: z.record(z.string(), z.unknown()),
    agent_id: z.string().min(1).optional(),
  }),
}),
CoachMessage: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('coach_message'),
  payload: z.object({
    text: z.string().min(1),
    workout_id: z.string().optional(),
    agent_id: z.string().min(1).optional(),
  }),
}),
IntroRequest: EnvelopeBase.extend({
  kind: z.literal('control'),
  type: z.literal('intro_request'),
  payload: z.object({
    agent_id: z.string().min(1).optional(),
  }),
}),
```

Extend `AnyEnvelope` discriminated union to include all new variants.

- [ ] **Step 4: Run tests until green**

```bash
pnpm exec vitest run shared/ios-app-protocol/v2.test.ts
```

- [ ] **Step 5: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts
git commit -m "feat(protocol): workout-mode envelope types"
```

---

## Task 2: Fixture pins for the new envelopes

**Files:**
- Create: `shared/ios-app-protocol/fixtures/workout_plan.json`, `set_log.json`, `exercise_swap_options.json`, `coach_message.json`
- Modify: `shared/ios-app-protocol/fixtures.test.ts`

- [ ] **Step 1: Create fixture files**

`workout_plan.json`:

```json
{
  "v": 2, "kind": "control", "type": "workout_plan",
  "id": "22222222-2222-4222-8222-222222222221", "seq": 10,
  "ts": "2026-06-09T18:55:00.000Z",
  "payload": {
    "workout_id": "01J6Z8W3K2N5A7B9C1D3E5F7G9",
    "plan_json": {
      "day_name": "Верх A",
      "week": 2,
      "intensity_label": "тяжёлая",
      "exercises": [
        {
          "exercise_slug": "incline-db-press",
          "target_sets": 4,
          "target_reps": "8-10",
          "target_rir": 2,
          "rest_sec": 120
        }
      ]
    },
    "image_manifest": [
      {"slug": "incline-db-press", "sha256": "deadbeefcafebabe"}
    ],
    "agent_id": "payne"
  }
}
```

`set_log.json`:

```json
{
  "v": 2, "kind": "data", "type": "set_log",
  "id": "22222222-2222-4222-8222-222222222222", "seq": 11,
  "ts": "2026-06-09T19:05:00.000Z",
  "payload": {
    "workout_id": "01J6Z8W3K2N5A7B9C1D3E5F7G9",
    "exercise_slug": "incline-db-press",
    "set_idx": 0, "reps": 10, "weight": 22.5,
    "reps_in_reserve": 3,
    "ts": "2026-06-09T19:05:00.000Z",
    "agent_id": "payne"
  }
}
```

`exercise_swap_options.json`:

```json
{
  "v": 2, "kind": "control", "type": "exercise_swap_options",
  "id": "22222222-2222-4222-8222-222222222223", "seq": 12,
  "ts": "2026-06-09T19:06:00.000Z",
  "payload": {
    "workout_id": "01J6Z8W3K2N5A7B9C1D3E5F7G9",
    "original_slug": "incline-db-press",
    "alternatives": [
      {"slug": "flat-db-press", "why": "та же грудь, без наклона"},
      {"slug": "cable-fly", "why": "акцент на сведение, лёгкий вес"}
    ],
    "agent_id": "payne"
  }
}
```

`coach_message.json`:

```json
{
  "v": 2, "kind": "control", "type": "coach_message",
  "id": "22222222-2222-4222-8222-222222222224", "seq": 13,
  "ts": "2026-06-09T19:07:00.000Z",
  "payload": {
    "workout_id": "01J6Z8W3K2N5A7B9C1D3E5F7G9",
    "text": "сбавь до 20 — у тебя падает форма",
    "agent_id": "payne"
  }
}
```

- [ ] **Step 2: Update `fixtures.test.ts` to assert each parses**

Add (or, if the suite already iterates the folder, ensure the new files are included):

```ts
it.each(['workout_plan', 'set_log', 'exercise_swap_options', 'coach_message'])(
  'loads %s.json',
  async (name) => {
    const raw = await import(`./fixtures/${name}.json`, { with: { type: 'json' } });
    expect(() => AnyEnvelope.parse(raw.default)).not.toThrow();
  },
);
```

- [ ] **Step 3: Run tests**

```bash
pnpm exec vitest run shared/ios-app-protocol/
```

- [ ] **Step 4: Commit**

```bash
git add shared/ios-app-protocol/fixtures/ shared/ios-app-protocol/fixtures.test.ts
git commit -m "test(protocol): fixtures for workout envelopes"
```

---

## Task 3: Swift mirrors

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`
- Modify: `ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift`

- [ ] **Step 1: Add new TypeTag cases**

Inside `enum TypeTag`:

```swift
case workoutStartRequest = "workout_start_request"
case workoutPlan = "workout_plan"
case setLog = "set_log"
case exerciseDone = "exercise_done"
case workoutComplete = "workout_complete"
case workoutAbort = "workout_abort"
case imageRequest = "image_request"
case imageBlob = "image_blob"
case exerciseSwapRequest = "exercise_swap_request"
case exerciseSwapConfirm = "exercise_swap_confirm"
case exerciseSwapOptions = "exercise_swap_options"
case programUpdate = "program_update"
case coachMessage = "coach_message"
case introRequest = "intro_request"
```

- [ ] **Step 2: Add `struct` payload types**

For each, mirror the TS shape. Example for `SetLog`:

```swift
struct SetLog: Codable, Equatable {
  let workoutId: String
  let exerciseSlug: String
  let setIdx: Int
  let reps: Int
  let weight: Double
  let repsInReserve: Int
  let ts: String
  let agentId: String?

  enum CodingKeys: String, CodingKey {
    case workoutId = "workout_id"
    case exerciseSlug = "exercise_slug"
    case setIdx = "set_idx"
    case reps, weight
    case repsInReserve = "reps_in_reserve"
    case ts
    case agentId = "agent_id"
  }
}
```

Repeat for `WorkoutPlan`, `WorkoutStartRequest`, `ExerciseDone`, `WorkoutComplete`, `WorkoutAbort`, `ImageRequest`, `ImageBlob`, `ExerciseSwapRequest`, `ExerciseSwapConfirm`, `ExerciseSwapOptions`, `ProgramUpdate`, `CoachMessage`, `IntroRequest`.

- [ ] **Step 3: Extend the `Payload` enum + decode/encode switch**

Add a case per new payload struct. Make sure the dispatch in `V2.decode(_:)` handles each type tag.

- [ ] **Step 4: Extend the fixture tests**

```swift
func test_setLog_fixture_roundtrips() throws {
  let url = Bundle.module.url(forResource: "set_log", withExtension: "json")!
  let data = try Data(contentsOf: url)
  let env = try V2.decode(data)
  guard case let .setLog(s) = env.payload else { return XCTFail("expected setLog") }
  XCTAssertEqual(s.repsInReserve, 3)
}
```

(Repeat for `workout_plan`, `exercise_swap_options`, `coach_message`.)

- [ ] **Step 5: Run iOS protocol tests**

```bash
cd ios/JarvisApp
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing JarvisAppTests/ProtocolFixtureTests
```

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/ProtocolFixtureTests.swift
git commit -m "feat(ios-protocol): mirror workout envelopes in Swift"
```

---

## Task 4: `WorkoutBridge` host module

**Files:**
- Create: `src/channels/ios-app/v2/workout-bridge.ts`
- Create: `src/channels/ios-app/v2/workout-bridge.test.ts`

The bridge has two responsibilities:
1. **Inbound from iOS** (set_log, exercise_done, workout_complete, workout_abort, exercise_swap_request, exercise_swap_confirm, image_request, intro_request, workout_start_request) → write as a structured `messages_in` entry into Payne's session DB so Payne can read on next poll.
2. **Outbound from Payne** (workout_plan, coach_message, exercise_swap_options, program_update, image_blob) → resolve session → platform_id, send envelope to that device.

The same pattern already exists for `ContextBridge` — copy its shape.

- [ ] **Step 1: Tests first**

```ts
import { describe, it, expect, beforeEach } from 'vitest';
import { WorkoutBridge } from './workout-bridge.js';

describe('WorkoutBridge', () => {
  let writes: any[]; let sends: any[]; let bridge: WorkoutBridge;
  beforeEach(() => {
    writes = []; sends = [];
    bridge = new WorkoutBridge({
      writeInboundSystemMessage: (input) => writes.push(input),
      resolvePlatformForSession: () => 'ios-app:dev1',
      sendEnvelopeToDevice: (pid, env) => sends.push({ pid, env }),
    });
  });

  it('writes set_log as a structured inbound system message', () => {
    bridge.handleInbound('sess-payne', {
      type: 'set_log',
      payload: {
        workout_id: 'w1', exercise_slug: 'incline-db-press',
        set_idx: 0, reps: 10, weight: 22.5, reps_in_reserve: 3,
        ts: '2026-06-09T19:05:00Z',
      },
    } as any);
    expect(writes).toHaveLength(1);
    expect(writes[0].session_id).toBe('sess-payne');
    const body = JSON.parse(writes[0].text);
    expect(body.event).toBe('set_log');
    expect(body.payload.reps_in_reserve).toBe(3);
  });

  it('forwards workout_plan outbound to the device', () => {
    bridge.handleOutbound('sess-payne', {
      type: 'workout_plan',
      payload: { workout_id: 'w1', plan_json: {}, image_manifest: [] },
    } as any);
    expect(sends).toHaveLength(1);
    expect(sends[0].pid).toBe('ios-app:dev1');
    expect((sends[0].env as any).type).toBe('workout_plan');
  });
});
```

- [ ] **Step 2: Implement `workout-bridge.ts`**

```ts
import { randomUUID } from 'node:crypto';
import type { AnyEnvelope } from '../../../../shared/ios-app-protocol/index.js';

export interface WorkoutBridgeDeps {
  writeInboundSystemMessage: (input: { session_id: string; text: string; tag: string }) => void;
  resolvePlatformForSession: (session_id: string) => string | null;
  sendEnvelopeToDevice: (platform_id: string, envelope: unknown) => void;
}

const IOS_TO_AGENT_TYPES = new Set([
  'workout_start_request', 'set_log', 'exercise_done', 'workout_complete',
  'workout_abort', 'exercise_swap_request', 'exercise_swap_confirm',
  'image_request', 'intro_request',
]);

const AGENT_TO_IOS_TYPES = new Set([
  'workout_plan', 'coach_message', 'exercise_swap_options',
  'program_update', 'image_blob',
]);

export class WorkoutBridge {
  constructor(private deps: WorkoutBridgeDeps) {}

  /** True if this envelope type is a workout-bridge type. Used by the inbound dispatcher. */
  handlesInbound(type: string): boolean { return IOS_TO_AGENT_TYPES.has(type); }

  handleInbound(session_id: string, env: AnyEnvelope): void {
    if (!this.handlesInbound(env.type)) return;
    const body = JSON.stringify({ event: env.type, payload: (env as any).payload });
    this.deps.writeInboundSystemMessage({ session_id, text: body, tag: 'workout' });
  }

  /** Called by the outbound projector when the agent emits one of the bridged types. */
  handleOutbound(session_id: string, env: AnyEnvelope): void {
    if (!AGENT_TO_IOS_TYPES.has(env.type)) return;
    const platform_id = this.deps.resolvePlatformForSession(session_id);
    if (!platform_id) return;
    this.deps.sendEnvelopeToDevice(platform_id, {
      ...env,
      id: (env as any).id ?? randomUUID(),
      ts: (env as any).ts ?? new Date().toISOString(),
    });
  }
}
```

- [ ] **Step 3: Run tests**

```bash
pnpm exec vitest run src/channels/ios-app/v2/workout-bridge.test.ts
```

- [ ] **Step 4: Commit**

```bash
git add src/channels/ios-app/v2/workout-bridge.ts src/channels/ios-app/v2/workout-bridge.test.ts
git commit -m "feat(ios-app): WorkoutBridge for iOS ↔ payne event routing"
```

---

## Task 5: Wire `WorkoutBridge` into inbound dispatch and outbound projection

**Files:**
- Modify: `src/channels/ios-app/v2/inbound-dispatch.ts`
- Modify: `src/channels/ios-app/v2/inbound-dispatch.test.ts`
- Modify: `src/channels/ios-app/v2/index.ts` (or wherever the outbound projector / queue draining lives — find via grep)

- [ ] **Step 1: Inbound — short-circuit on workout types**

In `inbound-dispatch.ts`, before the `switch (env.type)` block:

```ts
if (this.deps.workoutBridge?.handlesInbound(env.type)) {
  if (session_id) this.deps.workoutBridge.handleInbound(session_id, env);
  return { kind: 'ack' as const };
}
```

Extend `DispatcherDeps` with `workoutBridge?: WorkoutBridge`.

- [ ] **Step 2: Outbound — extend the projector**

Find where outbound messages from the agent become WS envelopes (search: `grep -nE 'sendEnvelopeToDevice\|outbound_queue' src/channels/ios-app/v2/`). Where the projector decides envelope type from the outbound row, add a branch: if the row is tagged as a workout-bridge type (the agent writes it via the standard message-out path with a JSON body that includes `event: <type>`), construct the matching envelope and pass through `workoutBridge.handleOutbound`.

- [ ] **Step 3: Inbound test**

Update `inbound-dispatch.test.ts`:

```ts
it('routes set_log through workout bridge instead of onUserMessage', () => {
  const bridgeCalls: any[] = [];
  const dispatcher = makeDispatcher({
    workoutBridge: { handlesInbound: (t) => t === 'set_log', handleInbound: (sid, e) => bridgeCalls.push({ sid, e }) } as any,
    onUserMessage: () => { throw new Error('should not be called'); },
  });
  dispatcher.dispatch('ios-app:dev1', setLogEnvelope({ workout_id: 'w1' }));
  expect(bridgeCalls).toHaveLength(1);
});
```

- [ ] **Step 4: Run all channel tests**

```bash
pnpm exec vitest run src/channels/ios-app/v2/
```

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/inbound-dispatch.ts src/channels/ios-app/v2/inbound-dispatch.test.ts src/channels/ios-app/v2/index.ts
git commit -m "feat(ios-app): wire WorkoutBridge into inbound dispatch + outbound projector"
```

---

## Task 6: Payne's `progression.js` script

**Files:**
- Create: `groups/payne/scripts/progression.js`
- Create: `groups/payne/scripts/progression.test.js`

The script reads the most recent session for a given program day, computes per-exercise targets for the next session of that day, and prints JSON to stdout. Payne invokes it via `bun groups/payne/scripts/progression.js --day-idx 0 --program-id <id>`.

- [ ] **Step 1: Failing test (bun-test)**

```js
import { test, expect } from 'bun:test';
import { computeNextTargets } from './progression.js';

test('weight bumps when reps_in_reserve was higher than target', () => {
  const lastSession = {
    exercises: [{
      exercise_slug: 'flat-db-press',
      sets: [
        { reps: 10, weight: 20, reps_in_reserve: 4 },
        { reps: 10, weight: 20, reps_in_reserve: 4 },
        { reps: 10, weight: 20, reps_in_reserve: 4 },
        { reps: 9,  weight: 20, reps_in_reserve: 3 },
      ],
    }],
  };
  const dayPlan = {
    exercises: [{ exercise_slug: 'flat-db-press', target_sets: 4, target_reps: '8-10', target_rir: 2 }],
  };
  const next = computeNextTargets(lastSession, dayPlan);
  expect(next.exercises[0].suggested_weight).toBeGreaterThan(20);
  expect(next.exercises[0].rationale).toMatch(/слишком легко/);
});

test('weight holds when reps_in_reserve hit target', () => {
  const lastSession = {
    exercises: [{
      exercise_slug: 'flat-db-press',
      sets: [
        { reps: 10, weight: 22.5, reps_in_reserve: 2 },
        { reps: 9,  weight: 22.5, reps_in_reserve: 1 },
      ],
    }],
  };
  const dayPlan = {
    exercises: [{ exercise_slug: 'flat-db-press', target_sets: 4, target_reps: '8-10', target_rir: 2 }],
  };
  const next = computeNextTargets(lastSession, dayPlan);
  expect(next.exercises[0].suggested_weight).toBe(22.5);
});

test('weight drops when last session collapsed under target', () => {
  const lastSession = {
    exercises: [{
      exercise_slug: 'flat-db-press',
      sets: [
        { reps: 8, weight: 25, reps_in_reserve: 0 },
        { reps: 6, weight: 25, reps_in_reserve: 0 },
        { reps: 5, weight: 25, reps_in_reserve: 0 },
      ],
    }],
  };
  const dayPlan = {
    exercises: [{ exercise_slug: 'flat-db-press', target_sets: 4, target_reps: '8-10', target_rir: 2 }],
  };
  const next = computeNextTargets(lastSession, dayPlan);
  expect(next.exercises[0].suggested_weight).toBeLessThan(25);
});
```

- [ ] **Step 2: Implement `progression.js`**

```js
// groups/payne/scripts/progression.js
// Bun-runnable. Pure function: no I/O at module scope.

export function computeNextTargets(lastSession, dayPlan) {
  const out = { exercises: [] };
  for (const planned of dayPlan.exercises) {
    const last = lastSession.exercises.find(e => e.exercise_slug === planned.exercise_slug);
    if (!last || last.sets.length === 0) {
      out.exercises.push({
        exercise_slug: planned.exercise_slug,
        suggested_weight: null,
        rationale: 'нет данных, диагностируем',
      });
      continue;
    }
    const avgRir = last.sets.reduce((s, x) => s + x.reps_in_reserve, 0) / last.sets.length;
    const targetRir = planned.target_rir ?? 2;
    const lastWeight = last.sets[0].weight;

    let suggested = lastWeight;
    let rationale = '';
    if (avgRir >= targetRir + 2) {
      // Too easy: bump 5%.
      suggested = roundWeight(lastWeight * 1.05);
      rationale = 'слишком легко (средний запас выше цели)';
    } else if (avgRir < targetRir - 1) {
      // Too hard: drop 5%.
      suggested = roundWeight(lastWeight * 0.95);
      rationale = 'слишком тяжело (средний запас ниже цели)';
    } else {
      rationale = 'держим тот же вес';
    }
    out.exercises.push({
      exercise_slug: planned.exercise_slug,
      suggested_weight: suggested,
      rationale,
    });
  }
  return out;
}

function roundWeight(kg) {
  // Round to 0.5 kg.
  return Math.round(kg * 2) / 2;
}

if (import.meta.main) {
  // CLI mode: read program path + day-idx from argv, last session from disk.
  const args = Object.fromEntries(process.argv.slice(2).map((a, i, arr) =>
    a.startsWith('--') ? [a.slice(2), arr[i + 1]] : null).filter(Boolean));
  const programPath = args['program'] || './programs/current.json';
  const sessionsDir = args['sessions-dir'] || './sessions';
  const dayIdx = Number(args['day-idx']);

  const program = JSON.parse(await Bun.file(programPath).text());
  const dayPlan = program.days[dayIdx];

  // Find most recent session for this day_idx.
  const glob = new Bun.Glob('*.json');
  const files = [];
  for await (const f of glob.scan(sessionsDir)) files.push(`${sessionsDir}/${f}`);
  files.sort().reverse();
  let last = null;
  for (const f of files) {
    const s = JSON.parse(await Bun.file(f).text());
    if (s.day_idx === dayIdx) { last = s; break; }
  }
  if (!last) {
    console.log(JSON.stringify({ exercises: dayPlan.exercises.map(e =>
      ({ exercise_slug: e.exercise_slug, suggested_weight: null, rationale: 'первая сессия' })) }, null, 2));
    process.exit(0);
  }

  console.log(JSON.stringify(computeNextTargets(last, dayPlan), null, 2));
}
```

- [ ] **Step 3: Run bun-test**

```bash
cd groups/payne/scripts
bun test progression.test.js
```

- [ ] **Step 4: Commit**

```bash
git add groups/payne/scripts/progression.js groups/payne/scripts/progression.test.js
git commit -m "feat(payne): progression.js — compute next-session targets"
```

---

## Task 7: Payne's `volume-report.js` script

**Files:**
- Create: `groups/payne/scripts/volume-report.js`
- Create: `groups/payne/scripts/volume-report.test.js`

The script scans the past 7 days of sessions and emits a JSON retro: tonnage per major lift, avg reps_in_reserve, week-over-week delta, regressions detected.

- [ ] **Step 1: Failing test**

```js
import { test, expect } from 'bun:test';
import { computeWeekReport } from './volume-report.js';

test('aggregates tonnage and reports regressions', () => {
  const sessions = [
    { date: '2026-06-02', exercises: [{ exercise_slug: 'flat-db-press', sets: [
      { reps: 10, weight: 22.5, reps_in_reserve: 2 },
      { reps: 10, weight: 22.5, reps_in_reserve: 2 },
      { reps: 9, weight: 22.5, reps_in_reserve: 1 },
    ]}] },
    { date: '2026-06-09', exercises: [{ exercise_slug: 'flat-db-press', sets: [
      { reps: 8, weight: 22.5, reps_in_reserve: 0 },
      { reps: 6, weight: 22.5, reps_in_reserve: 0 },
      { reps: 5, weight: 22.5, reps_in_reserve: 0 },
    ]}] },
  ];
  const report = computeWeekReport({
    sessions,
    weekStart: '2026-06-08', weekEnd: '2026-06-14',
    previousWeekStart: '2026-06-01', previousWeekEnd: '2026-06-07',
  });
  expect(report.regressions).toContain('flat-db-press');
  expect(report.this_week.flat-db-press || report.this_week['flat-db-press'].tonnage_kg)
    .toBeDefined();
});
```

- [ ] **Step 2: Implement**

```js
// groups/payne/scripts/volume-report.js

export function computeWeekReport({ sessions, weekStart, weekEnd, previousWeekStart, previousWeekEnd }) {
  const thisWeek = bucket(sessions.filter(s => s.date >= weekStart && s.date <= weekEnd));
  const prevWeek = bucket(sessions.filter(s => s.date >= previousWeekStart && s.date <= previousWeekEnd));

  const regressions = [];
  for (const slug of Object.keys(thisWeek)) {
    if (!prevWeek[slug]) continue;
    if (thisWeek[slug].tonnage_kg < prevWeek[slug].tonnage_kg * 0.85) regressions.push(slug);
  }
  return { this_week: thisWeek, previous_week: prevWeek, regressions };
}

function bucket(sessions) {
  const out = {};
  for (const s of sessions) {
    for (const ex of s.exercises) {
      const t = out[ex.exercise_slug] ?? (out[ex.exercise_slug] = { tonnage_kg: 0, sets: 0, avg_rir: 0 });
      let rirSum = t.avg_rir * t.sets;
      for (const set of ex.sets) {
        t.tonnage_kg += set.reps * set.weight;
        rirSum += set.reps_in_reserve;
      }
      t.sets += ex.sets.length;
      t.avg_rir = t.sets ? rirSum / t.sets : 0;
    }
  }
  return out;
}

if (import.meta.main) {
  // CLI mode would read sessions/ directory and weekStart from argv.
  // Omitted for brevity — Payne calls computeWeekReport directly when needed.
}
```

- [ ] **Step 3: Run bun-test**

```bash
cd groups/payne/scripts
bun test volume-report.test.js
```

- [ ] **Step 4: Commit**

```bash
git add groups/payne/scripts/volume-report.js groups/payne/scripts/volume-report.test.js
git commit -m "feat(payne): volume-report.js — weekly retro aggregation"
```

---

## Task 8: Extend Payne CLAUDE.md with workout-mode instructions

**Files:**
- Modify: `groups/payne/CLAUDE.md`

- [ ] **Step 1: Add a "Workout mode" section after the existing "Что ты делаешь"**

```markdown
## Workout-режим (структурный)

iOS-приложение шлёт тебе структурированные события (`set_log`, `exercise_done`,
`workout_complete`, `workout_start_request`, `exercise_swap_request`,
`exercise_swap_confirm`, `image_request`, `intro_request`, `workout_abort`).
Они попадают в твой `messages_in` помеченными как `tag: workout` и содержат
JSON: `{"event": "<тип>", "payload": {...}}`.

### Жизненный цикл тренировки

1. Получил `workout_start_request {date}` → загрузи `programs/current.json`,
   определи день по сплиту + текущей неделе, применяй модификаторы из
   `weekly_intensity_pattern`, и отвечай эмиссией `workout_plan`:

   ```
   {
     "event": "workout_plan",
     "payload": {
       "workout_id": "<ULID>",
       "plan_json": { "day_name": "...", "week": N, "intensity_label": "...",
                       "exercises": [ ... ] },
       "image_manifest": [{"slug": "...", "sha256": "..."}, ...]
     }
   }
   ```

   `workout_id` ты генерируешь сам (ULID). `image_manifest` — список упражнений
   с sha256 файлов из `exercises/<slug>.jpg` (вычисли через bun).

2. `set_log` приходит после каждого подхода. **Не отвечай на каждый**.
   Копи в `sessions/.in-progress-<workout_id>.json` (или в memory). Это
   рабочий снимок; финальная запись — после `workout_complete`.

3. По ходу можешь периодически эмитить `coach_message {text, workout_id}`
   когда:
   - юзер падает по `reps_in_reserve = 0` два подхода подряд при цели > 0
     → «сбавь до X»
   - юзер закончил с `reps_in_reserve >= 4` → «повысь вес» или «добавь подход»
   - первый подход был калибровочный → подтверди расчётный рабочий вес.

   Без злоупотребления: 1–3 coach_message за тренировку максимум.

4. `exercise_done {workout_id, exercise_slug, comment?}` — закрывает упражнение.
   Можно отреагировать кратким coach_message по итогу упражнения.

5. `workout_complete {workout_id, full_session_json}` — финал. Сохрани
   `sessions/YYYY-MM-DD.json` из payload (merge с in-progress если был),
   обнови `programs/current.json` если нужно (например, прогрессии веса
   по `progression.js`), и пошли retro в обычный чат: что сделано, тоннаж,
   средний запас, что меняем в следующей сессии. Эмить `program_update`
   если в программу внесены изменения.

6. `workout_abort {workout_id, reason}` — сохрани частичные результаты,
   мягко спроси что случилось, не обвиняй.

### Замена упражнения

`exercise_swap_request {workout_id, exercise_slug, proposed?}`:
- Без `proposed`: подбери 2–3 кандидата по правилу из основной инструкции
  (пересечение `primary_muscle_groups` + соответствие `constraints.md`),
  эмить `exercise_swap_options` с `alternatives`.
- С `proposed`: распарси текст в slug (или создай stub-карточку с
  `image: null` и заметкой "нужна картинка"), применяй правило. Если
  принято — `accepted: {slug}`. Если нет — `rejected: {slug, reason}` +
  `alternatives`.

`exercise_swap_confirm {workout_id, original_slug, new_slug, persist?}`:
- Если `persist=true` — обнови `programs/current.json` в этой день/упражнении,
  эмить `program_update`.
- Если `persist=false` — только in-session, в `programs` не лезь.

### Картинки упражнений

`image_request {slug}` — прочти `exercises/<slug>.jpg` с диска, отдай
`image_blob {slug, sha256, base64}`. Sha256 ты уже посчитал и положил
в `image_manifest`.

### intro_request

Первое сообщение в пустой нити Пейна. Запусти intake (см. основную
инструкцию).

### Еженедельная ретроспектива

В воскресенье 20:00 локального (или после последней тренировки недели —
что раньше), запусти `bun scripts/volume-report.js`, прочти JSON,
интерпретируй и пошли пользователю человеческий retro: «неделя 2,
тяжёлая. Тоннаж +N% к прошлой неделе. Жим лёжа просел на третьем
подходе всех тренировок — на следующей неделе снижаю объём, увеличиваю
отдых.» Запиши копию в `memories/retro/YYYY-WW.md`.
```

- [ ] **Step 2: Commit**

```bash
git add groups/payne/CLAUDE.md
git commit -m "feat(payne): workout-mode instructions in CLAUDE.md"
```

---

## Task 9: iOS — `Workout.swift` models

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift`

- [ ] **Step 1: Write the value types**

```swift
import Foundation

struct ExercisePlan: Codable, Equatable, Identifiable {
  let exerciseSlug: String
  let targetSets: Int
  let targetReps: String     // e.g. "8-10"
  let targetRir: Int
  let restSec: Int
  let notes: String?
  var id: String { exerciseSlug }

  enum CodingKeys: String, CodingKey {
    case exerciseSlug = "exercise_slug"
    case targetSets = "target_sets"
    case targetReps = "target_reps"
    case targetRir = "target_rir"
    case restSec = "rest_sec"
    case notes
  }
}

struct WorkoutPlan: Codable, Equatable {
  let workoutId: String
  let dayName: String
  let week: Int
  let intensityLabel: String
  let exercises: [ExercisePlan]
  let imageManifest: [ImageManifestEntry]

  struct ImageManifestEntry: Codable, Equatable {
    let slug: String
    let sha256: String
  }
}

struct LoggedSet: Codable, Equatable {
  let reps: Int
  let weight: Double
  let repsInReserve: Int
  let ts: Date

  enum CodingKeys: String, CodingKey {
    case reps, weight
    case repsInReserve = "reps_in_reserve"
    case ts
  }
}

struct LoggedExercise: Codable, Equatable {
  let exerciseSlug: String
  var sets: [LoggedSet]
  var comment: String?

  enum CodingKeys: String, CodingKey {
    case exerciseSlug = "exercise_slug"
    case sets, comment
  }
}

struct WorkoutSession: Codable, Equatable {
  let workoutId: String
  let date: String
  let dayName: String
  let week: Int
  let startedAt: Date
  var finishedAt: Date?
  var exercises: [LoggedExercise]
  var perceivedOverallRir: Int?
  var healthSignalAtStart: String?

  enum CodingKeys: String, CodingKey {
    case workoutId = "workout_id"
    case date, dayName = "day_name", week
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case exercises
    case perceivedOverallRir = "perceived_overall_rir"
    case healthSignalAtStart = "health_signal_at_start"
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift
git commit -m "feat(ios): workout model value types"
```

---

## Task 10: iOS — `SetLogQueue` durable queue

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/SetLogQueue.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/SetLogQueueTests.swift`

- [ ] **Step 1: Test**

```swift
final class SetLogQueueTests: XCTestCase {
  func test_enqueue_drainsInOrder() throws {
    let q = SetLogQueue.inMemory()
    try q.enqueue(.init(workoutId: "w1", exerciseSlug: "x", setIdx: 0, reps: 10, weight: 20, repsInReserve: 2, ts: Date()))
    try q.enqueue(.init(workoutId: "w1", exerciseSlug: "x", setIdx: 1, reps: 9,  weight: 20, repsInReserve: 1, ts: Date()))
    let pending = try q.pending()
    XCTAssertEqual(pending.map(\.setIdx), [0, 1])
  }

  func test_markDelivered_removesFromPending() throws {
    let q = SetLogQueue.inMemory()
    try q.enqueue(.init(workoutId: "w1", exerciseSlug: "x", setIdx: 0, reps: 10, weight: 20, repsInReserve: 2, ts: Date()))
    let row = try XCTUnwrap(q.pending().first)
    try q.markDelivered(localId: row.localId)
    XCTAssertEqual(try q.pending().count, 0)
  }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import GRDB  // or whichever SQLite layer the app uses; check existing Storage/Schema.swift

struct SetLogEvent: Codable, Equatable {
  let workoutId: String
  let exerciseSlug: String
  let setIdx: Int
  let reps: Int
  let weight: Double
  let repsInReserve: Int
  let ts: Date
}

struct PendingSetLog {
  let localId: Int64
  let event: SetLogEvent
  var setIdx: Int { event.setIdx }
}

final class SetLogQueue {
  private let dbQueue: DatabaseQueue
  init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }
  static func inMemory() throws -> SetLogQueue { /* ... */ fatalError() }

  func enqueue(_ event: SetLogEvent) throws {
    try dbQueue.write { db in
      try db.execute(sql: """
        INSERT INTO set_log_queue
          (workout_id, exercise_slug, set_idx, reps, weight, reps_in_reserve, ts_iso, delivered)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0)
        """, arguments: [event.workoutId, event.exerciseSlug, event.setIdx,
                         event.reps, event.weight, event.repsInReserve,
                         ISO8601DateFormatter().string(from: event.ts)])
    }
  }

  func pending() throws -> [PendingSetLog] {
    try dbQueue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM set_log_queue WHERE delivered = 0 ORDER BY set_idx ASC, rowid ASC")
        .map { row in /* hydrate PendingSetLog */ fatalError() }
    }
  }

  func markDelivered(localId: Int64) throws {
    try dbQueue.write { try $0.execute(sql: "UPDATE set_log_queue SET delivered = 1 WHERE rowid = ?", arguments: [localId]) }
  }
}
```

Plus a migration in `Schema.swift`:

```swift
db.execute("""
  CREATE TABLE IF NOT EXISTS set_log_queue (
    workout_id TEXT NOT NULL,
    exercise_slug TEXT NOT NULL,
    set_idx INTEGER NOT NULL,
    reps INTEGER NOT NULL,
    weight REAL NOT NULL,
    reps_in_reserve INTEGER NOT NULL,
    ts_iso TEXT NOT NULL,
    delivered INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS set_log_queue_pending_idx ON set_log_queue(delivered, set_idx);
""")
```

(Match the actual storage layer the codebase uses — if it's not GRDB, mirror the existing iOS Storage patterns.)

- [ ] **Step 3: Run tests**

```bash
cd ios/JarvisApp
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing JarvisAppTests/SetLogQueueTests
```

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/SetLogQueue.swift ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift ios/JarvisApp/Sources/JarvisAppTests/SetLogQueueTests.swift
git commit -m "feat(ios): SetLogQueue with durable delivery"
```

---

## Task 11: iOS — `ExerciseImageCache`

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/ExerciseImageCache.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import UIKit

final class ExerciseImageCache {
  private let baseURL: URL
  private let pendingPrefetches = NSLock()
  private var inflightSlugs = Set<String>()
  private let imageRequestSender: (_ slug: String) -> Void

  init(baseURL: URL, imageRequestSender: @escaping (_ slug: String) -> Void) {
    self.baseURL = baseURL
    self.imageRequestSender = imageRequestSender
    try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
  }

  func path(forSlug slug: String, sha256: String) -> URL {
    baseURL.appendingPathComponent("\(slug)_\(sha256).jpg")
  }

  func has(slug: String, sha256: String) -> Bool {
    FileManager.default.fileExists(atPath: path(forSlug: slug, sha256: sha256).path)
  }

  /// Diffs the manifest against the cache and fires image_request for every miss in parallel.
  func prefetch(manifest: [WorkoutPlan.ImageManifestEntry]) {
    pendingPrefetches.lock(); defer { pendingPrefetches.unlock() }
    for entry in manifest where !has(slug: entry.slug, sha256: entry.sha256) {
      guard !inflightSlugs.contains(entry.slug) else { continue }
      inflightSlugs.insert(entry.slug)
      imageRequestSender(entry.slug)
    }
  }

  func write(slug: String, sha256: String, base64: String) throws {
    guard let data = Data(base64Encoded: base64) else { throw NSError(domain: "ImageCache", code: 1) }
    try data.write(to: path(forSlug: slug, sha256: sha256))
    pendingPrefetches.lock(); inflightSlugs.remove(slug); pendingPrefetches.unlock()
  }

  func image(slug: String, sha256: String) -> UIImage? {
    UIImage(contentsOfFile: path(forSlug: slug, sha256: sha256).path)
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/ExerciseImageCache.swift
git commit -m "feat(ios): ExerciseImageCache with eager prefetch"
```

---

## Task 12: iOS — `RestTimer`

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/RestTimer.swift`

- [ ] **Step 1: Implement** (Combine-backed countdown + local notification)

```swift
import Foundation
import Combine
import UserNotifications

final class RestTimer: ObservableObject {
  @Published private(set) var remainingSec: Int = 0
  @Published private(set) var running: Bool = false
  private var cancellable: AnyCancellable?

  /// Adapts duration per spec §5.5: last-set reps_in_reserve drives the override.
  func start(planned: Int, lastRepsInReserve: Int) {
    let effective = effectiveDuration(planned: planned, rir: lastRepsInReserve)
    remainingSec = effective
    running = true
    cancellable = Timer.publish(every: 1, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        guard let self else { return }
        if self.remainingSec > 0 { self.remainingSec -= 1 }
        else { self.stop() }
      }
    scheduleLocalNotification(after: effective)
  }

  func skip() { stop(); cancelLocalNotification() }

  private func stop() {
    cancellable?.cancel(); cancellable = nil; running = false
  }

  static func effectiveDuration(planned: Int, rir: Int) -> Int {
    if rir == 0 { return planned + 30 }
    if rir >= 4 { return max(planned - 15, 30) }
    return planned
  }

  // MARK: - Local notification
  private let nid = "RestTimer.done"
  private func scheduleLocalNotification(after sec: Int) {
    cancelLocalNotification()
    let c = UNMutableNotificationContent()
    c.title = "Отдых закончился"; c.body = "Готов?"; c.sound = .default
    let req = UNNotificationRequest(identifier: nid, content: c,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(sec), repeats: false))
    UNUserNotificationCenter.current().add(req)
  }
  private func cancelLocalNotification() {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [nid])
  }
}
```

Provide a Swift unit test for `effectiveDuration` covering the three branches.

- [ ] **Step 2: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/RestTimer.swift ios/JarvisApp/Sources/JarvisAppTests/RestTimerTests.swift
git commit -m "feat(ios): RestTimer with adaptive duration + local notification"
```

---

## Task 13: iOS — `WorkoutCoordinator`

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift`

The coordinator owns the in-memory state machine of an active workout: which exercise / set is current, accumulated `LoggedExercise[]`, and exposes Published properties for the SwiftUI view.

- [ ] **Step 1: Test (key behaviours)**

```swift
final class WorkoutCoordinatorTests: XCTestCase {
  func test_logSet_movesToNextSet() throws {
    let plan = WorkoutPlan.sample()  // helper that builds a plan with 2 exercises × 4 sets each
    let coordinator = WorkoutCoordinator(plan: plan, queue: SetLogQueue.inMemoryStub(), images: .stub)
    XCTAssertEqual(coordinator.currentExerciseIdx, 0)
    XCTAssertEqual(coordinator.currentSetIdx, 0)
    coordinator.logSet(reps: 10, weight: 22.5, repsInReserve: 2)
    XCTAssertEqual(coordinator.currentSetIdx, 1)
  }

  func test_finishExercise_movesToNext() {
    let plan = WorkoutPlan.sample()
    let coordinator = WorkoutCoordinator(plan: plan, queue: SetLogQueue.inMemoryStub(), images: .stub)
    coordinator.finishExercise(comment: nil)
    XCTAssertEqual(coordinator.currentExerciseIdx, 1)
    XCTAssertEqual(coordinator.currentSetIdx, 0)
  }

  func test_finalSession_carriesAllLoggedSets() {
    let plan = WorkoutPlan.sample()
    let coordinator = WorkoutCoordinator(plan: plan, queue: SetLogQueue.inMemoryStub(), images: .stub)
    coordinator.logSet(reps: 10, weight: 20, repsInReserve: 2)
    coordinator.finishExercise(comment: nil)
    coordinator.logSet(reps: 8, weight: 20, repsInReserve: 0)
    let final = coordinator.complete(overallRir: 1)
    XCTAssertEqual(final.exercises.flatMap(\.sets).count, 2)
    XCTAssertEqual(final.workoutId, plan.workoutId)
  }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import Combine

final class WorkoutCoordinator: ObservableObject {
  @Published private(set) var plan: WorkoutPlan
  @Published private(set) var currentExerciseIdx: Int = 0
  @Published private(set) var currentSetIdx: Int = 0
  @Published private(set) var logged: [LoggedExercise]
  @Published private(set) var lastRepsInReserve: Int = -1

  private let queue: SetLogQueue
  private let images: ExerciseImageCache

  init(plan: WorkoutPlan, queue: SetLogQueue, images: ExerciseImageCache) {
    self.plan = plan
    self.queue = queue
    self.images = images
    self.logged = plan.exercises.map { LoggedExercise(exerciseSlug: $0.exerciseSlug, sets: [], comment: nil) }
  }

  var currentExercise: ExercisePlan { plan.exercises[currentExerciseIdx] }

  func logSet(reps: Int, weight: Double, repsInReserve: Int) {
    let event = SetLogEvent(
      workoutId: plan.workoutId,
      exerciseSlug: currentExercise.exerciseSlug,
      setIdx: currentSetIdx,
      reps: reps, weight: weight,
      repsInReserve: repsInReserve, ts: Date(),
    )
    try? queue.enqueue(event)
    logged[currentExerciseIdx].sets.append(.init(reps: reps, weight: weight, repsInReserve: repsInReserve, ts: event.ts))
    lastRepsInReserve = repsInReserve
    currentSetIdx += 1
  }

  func finishExercise(comment: String?) {
    logged[currentExerciseIdx].comment = comment
    if currentExerciseIdx + 1 < plan.exercises.count {
      currentExerciseIdx += 1
      currentSetIdx = 0
    } else {
      currentSetIdx = -1   // signal "ready to complete"
    }
  }

  func complete(overallRir: Int) -> WorkoutSession {
    WorkoutSession(
      workoutId: plan.workoutId,
      date: ISO8601DateFormatter.yyyymmdd.string(from: Date()),
      dayName: plan.dayName,
      week: plan.week,
      startedAt: Date(),
      finishedAt: Date(),
      exercises: logged,
      perceivedOverallRir: overallRir,
      healthSignalAtStart: nil,
    )
  }
}
```

- [ ] **Step 3: Run tests**

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift ios/JarvisApp/Sources/JarvisAppTests/WorkoutCoordinatorTests.swift
git commit -m "feat(ios): WorkoutCoordinator state machine"
```

---

## Task 14: iOS — `WorkoutView` and subviews

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/ExerciseCardView.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/SetRowView.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/RestTimerOverlay.swift`
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/CoachBannerView.swift`

- [ ] **Step 1: `WorkoutView` skeleton**

```swift
import SwiftUI

struct WorkoutView: View {
  @StateObject var coordinator: WorkoutCoordinator
  @StateObject var restTimer = RestTimer()
  @State private var showSwap = false
  @State private var coachBanner: String?
  @Environment(\.dismiss) var dismiss

  var body: some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 0) {
        navbar
        progressDots
        ExerciseCardView(
          exercise: coordinator.currentExercise,
          imageCache: coordinator.imagesPublic,
          onSwap: { showSwap = true },
        )
        ScrollView {
          ForEach(coordinator.loggedSetsForCurrent.indices, id: \.self) { idx in
            SetRowView(set: coordinator.loggedSetsForCurrent[idx], idx: idx, isActive: false)
          }
          ActiveSetRow(coordinator: coordinator, restTimer: restTimer)
        }
        bottomBar
      }
      if restTimer.running { RestTimerOverlay(timer: restTimer) }
      if let banner = coachBanner { CoachBannerView(text: banner).transition(.move(edge: .bottom)) }
    }
    .sheet(isPresented: $showSwap) {
      SwapSheet(coordinator: coordinator)
    }
  }

  private var navbar: some View { /* day name + week + intensity + ✕ */ EmptyView() }
  private var progressDots: some View { /* dots view */ EmptyView() }
  private var bottomBar: some View {
    HStack {
      Button("+ подход") { /* coordinator.addCustomSet() */ }
      Button("🔁 заменить") { showSwap = true }
      Spacer()
      Button("Финиш") { /* present finish sheet */ }
    }
    .padding()
  }
}
```

- [ ] **Step 2: `SetRowView` with steppers**

```swift
struct ActiveSetRow: View {
  @ObservedObject var coordinator: WorkoutCoordinator
  @ObservedObject var restTimer: RestTimer
  @State private var reps: Int = 10
  @State private var weight: Double = 0
  @State private var rir: Int = 2

  var body: some View {
    HStack(spacing: 12) {
      Text("#\(coordinator.currentSetIdx + 1)")
      Stepper("повторы \(reps)", value: $reps, in: 0...30)
      Stepper("вес \(weight, format: .number) кг", value: $weight, in: 0...500, step: 0.5)
      Stepper("ещё мог \(rir)", value: $rir, in: 0...10)
      Button("✓") {
        coordinator.logSet(reps: reps, weight: weight, repsInReserve: rir)
        restTimer.start(planned: coordinator.currentExercise.restSec, lastRepsInReserve: rir)
      }
    }
    .padding()
  }
}
```

Provide the matching `SetRowView` (read-only) and `RestTimerOverlay` (large countdown + skip button) and `CoachBannerView` (sliding banner with auto-dismiss after 4 s).

- [ ] **Step 3: Smoke test in simulator**

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift ios/JarvisApp/Sources/JarvisApp/Views/Workout/
git commit -m "feat(ios): WorkoutView + subviews"
```

---

## Task 15: iOS — `SwapSheet`

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/SwapSheet.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct SwapSheet: View {
  @ObservedObject var coordinator: WorkoutCoordinator
  @Environment(\.dismiss) var dismiss
  @State private var proposed: String = ""
  @State private var persist: Bool = false
  @State private var options: [(slug: String, why: String)] = []
  @State private var rejection: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Свой вариант") {
          TextField("например, жим гантелей сидя", text: $proposed)
          Toggle("Оставить в программе", isOn: $persist)
          Button("Отправить") { sendProposed() }
        }
        Section("Или попроси у Пейна") {
          Button("Предложи мне 2-3 варианта") { askPayne() }
        }
        if !options.isEmpty {
          Section("Альтернативы") {
            ForEach(options, id: \.slug) { opt in
              Button { confirm(slug: opt.slug) } label: {
                VStack(alignment: .leading) {
                  Text(opt.slug).font(.headline)
                  Text(opt.why).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        if let reason = rejection {
          Section("Не подойдёт") { Text(reason).foregroundStyle(.red) }
        }
      }
      .navigationTitle("Замена упражнения")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
    }
  }

  private func sendProposed() { /* TransportV2.shared.sendExerciseSwapRequest(workoutId, slug, proposed, persist) */ }
  private func askPayne()     { /* TransportV2.shared.sendExerciseSwapRequest(workoutId, slug, nil, persist) */ }
  private func confirm(slug: String) { /* sendExerciseSwapConfirm(... persist) ; dismiss() */ }
}
```

- [ ] **Step 2: Wire it to receive `exercise_swap_options` from `InboundDispatcherV2` and update `options` / `rejection`**

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/SwapSheet.swift
git commit -m "feat(ios): exercise swap sheet"
```

---

## Task 16: iOS — `TransportV2` typed builders

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift`

- [ ] **Step 1: Add builders for each new outbound envelope**

```swift
extension TransportV2 {
  func sendWorkoutStartRequest(date: String) {
    let env = V2.Envelope.workoutStartRequest(.init(date: date, agentId: "payne"))
    queue.enqueue(env)
  }
  func sendSetLog(_ event: SetLogEvent) {
    let env = V2.Envelope.setLog(.init(/* map fields */))
    queue.enqueue(env)
  }
  func sendExerciseDone(workoutId: String, slug: String, comment: String?) { /* ... */ }
  func sendWorkoutComplete(_ session: WorkoutSession) { /* ... */ }
  func sendWorkoutAbort(workoutId: String, reason: String) { /* ... */ }
  func sendImageRequest(slug: String) { /* ... */ }
  func sendExerciseSwapRequest(workoutId: String, slug: String, proposed: String?) { /* ... */ }
  func sendExerciseSwapConfirm(workoutId: String, original: String, new: String, persist: Bool) { /* ... */ }
  func sendIntroRequest() { /* ... */ }
}
```

- [ ] **Step 2: Drain `SetLogQueue` on each WS connect**

In `TransportV2.didConnect`:

```swift
Task {
  for pending in (try? setLogQueue.pending()) ?? [] {
    sendSetLog(pending.event)
    try? setLogQueue.markDelivered(localId: pending.localId)
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift
git commit -m "feat(ios): transport builders for workout envelopes + queue drain"
```

---

## Task 17: iOS — Inbound dispatch for workout types

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcherV2.swift`

- [ ] **Step 1: Branch on workout envelope types**

```swift
switch env.payload {
case .workoutPlan(let p):
  imageCache.prefetch(manifest: p.imageManifest.map { .init(slug: $0.slug, sha256: $0.sha256) })
  NotificationCenter.default.post(name: .workoutPlanReceived, object: p)
case .imageBlob(let b):
  try? imageCache.write(slug: b.slug, sha256: b.sha256, base64: b.base64)
case .coachMessage(let c):
  NotificationCenter.default.post(name: .coachMessageReceived, object: c)
case .exerciseSwapOptions(let s):
  NotificationCenter.default.post(name: .swapOptionsReceived, object: s)
case .programUpdate(let u):
  NotificationCenter.default.post(name: .programUpdated, object: u)
default:
  // existing flows
}
```

(Or use a delegate / observable injection instead of `NotificationCenter` if that fits the codebase better.)

- [ ] **Step 2: ChatView "Начать тренировку" button**

In `ChatView.swift`, when the latest message in the Payne thread is a `workout_plan`, show a primary button at the bottom that presents `WorkoutView`.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcherV2.swift ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift
git commit -m "feat(ios): route workout envelopes to coordinator + open WorkoutView"
```

---

## Task 18: End-to-end vitest covering inbound + outbound bridge

**Files:**
- Modify: `src/channels/ios-app/v2/integration.test.ts`

- [ ] **Step 1: Add a scenario that exercises the full bridge**

```ts
it('end-to-end: set_log envelopes land in payne session as workout-tagged inbound', async () => {
  const h = await makeIntegrationHarness({
    agentRouting: { defaultAgentSlug: 'jarvis', agents: { jarvis: 'mg-j', payne: 'mg-p' } },
  });
  h.deviceSend(setLogEnvelope({ workout_id: 'w1', set_idx: 0, reps: 10, weight: 22.5, reps_in_reserve: 2, agent_id: 'payne' }));
  await h.flush();
  const rows = h.readSessionInbound(h.payneSessionId, { tag: 'workout' });
  expect(rows).toHaveLength(1);
  const body = JSON.parse(rows[0].text);
  expect(body.event).toBe('set_log');
});
```

- [ ] **Step 2: Run**

```bash
pnpm exec vitest run src/channels/ios-app/v2/integration.test.ts
```

- [ ] **Step 3: Commit**

```bash
git add src/channels/ios-app/v2/integration.test.ts
git commit -m "test(ios-app): end-to-end set_log bridge integration"
```

---

## Task 19: Deploy + smoke

- [ ] **Step 1: Push, pull, build on VDS** (same flow as Plan 1 & 2)

- [ ] **Step 2: Restart**

```bash
ssh root@148.253.211.164 'systemctl --machine=nanoclaw@.host --user restart nanoclaw'
```

- [ ] **Step 3: Build new TestFlight or device-tethered iOS build**

```bash
cd ios/JarvisApp
xcodebuild -scheme JarvisApp -destination 'generic/platform=iOS' -configuration Release archive -archivePath ./build/JarvisApp.xcarchive
```

(or use the existing CI/Fastlane recipe — check `ios/JarvisApp/project.yml`.)

- [ ] **Step 4: Smoke test**

1. Open the app, switch to **Майор Пейн** chip.
2. Ask "что у меня сегодня?". Expected: Payne emits a `workout_plan`. A "Начать тренировку" button appears.
3. Tap the button → `WorkoutView` opens. First exercise image is **already cached** (eager prefetch from §4.3) — no loading spinner.
4. Run the first set: log reps/weight/запас, tap ✓. Rest timer overlay appears.
5. Lock the phone — when the timer expires, the local notification fires.
6. Unlock, log set #2 with `запас 0`. Tap ✓. The rest timer is **30 s longer** (per §5.5 rule).
7. Tap "🔁 заменить", type "разводки на наклонной", tap "Отправить". Expect Payne to either accept (and show "confirm" affordance) or reject with reason + alternatives.
8. Finish the workout via "Финиш" → `workout_complete` sent → Payne emits a retro `coach_message` in the chat.
9. Verify on the VDS that `groups/payne/sessions/YYYY-MM-DD.json` exists with the logged data.

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "ls -la /home/nanoclaw/nanoclaw/groups/payne/sessions/"'
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cat /home/nanoclaw/nanoclaw/groups/payne/sessions/$(date +%Y-%m-%d).json"'
```

- [ ] **Step 5: Tag**

```bash
git tag -a payne-workout-mode -m "Payne workout mode shipped"
git push origin payne-workout-mode
```

---

## Acceptance

- All ios-app channel tests pass: `pnpm exec vitest run src/channels/ios-app/v2/`
- All protocol fixture tests pass on both TS and Swift sides
- `progression.js` and `volume-report.js` bun-tests pass
- iOS end-to-end smoke from Task 19 step 4 passes
- `groups/payne/sessions/YYYY-MM-DD.json` written by Payne after `workout_complete`
- Weekly retro lands (let one Sunday tick by; check `memories/retro/`)
- Yellow `health_signal` from Greg measurably softens the next day's `workout_plan` (lower `set_modifier` or fewer exercises). Manual verify by injecting a fake yellow signal:

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && ./bin/ncl destinations send --from greg --to payne --payload \"{\\\"action\\\":\\\"health_signal\\\",\\\"date\\\":\\\"$(date +%Y-%m-%d)\\\",\\\"level\\\":\\\"yellow\\\",\\\"factors\\\":[\\\"low_sleep_score\\\"],\\\"recommendation\\\":\\\"снизить объём на 20%\\\"}\""'
```

(if `ncl destinations send` doesn't exist, write a small one-off tsx script with `routeAgentMessage`.)

---

## Self-review notes

1. **Spec coverage**:
   - §3.2 (mesocycle JSON shape) — referenced in Task 6 progression tests; Payne writes the file per CLAUDE.md instructions.
   - §3.3 (session JSON shape) — produced by Payne on `workout_complete`; tested via Task 19 smoke.
   - §4 (WS protocol) — all envelope types in Task 1; fixtures Task 2; Swift mirror Task 3; bridge Task 4; wired Task 5.
   - §5.3 (in-workout coach behaviour) — instructed in CLAUDE.md (Task 8).
   - §5.4 (swap rule) — instructed in CLAUDE.md; UI Task 15.
   - §5.5 (rest timer adaptation) — Task 12 `RestTimer.effectiveDuration`.
   - §5.6 (weekly retro) — `volume-report.js` Task 7 + CLAUDE.md instructions Task 8.
   - §7.2 (WorkoutView UX) — Tasks 9–17.
2. **Type consistency:** `reps_in_reserve` is the field name in JSON (Task 1 schema, Task 2 fixture, Task 6 progression), `repsInReserve` in Swift (Task 3 mirror, Tasks 9–13). `workout_id` / `workoutId`. ULID at iOS-side. `agent_id` is optional everywhere.
3. **Backwards compat:** All new envelope types are additive — the discriminated union extends; existing types unchanged.
4. **What this plan does NOT cover** (future work per spec §10): voice input, Apple Watch, HealthKit workout integration, video form-check, body measurements, animated media.
5. **Risk:** the outbound projection from Payne's session DB to typed WS envelopes (Task 5 Step 2) is the trickiest integration point. The pattern is "agent writes a structured outbound row → channel detects the `event` key → constructs the right envelope → sends". If the agent-runner side doesn't already expose a way to write structured outbound (just text), Task 5 may need a small companion change inside `container/agent-runner/` to add a "structured destination emit" helper. Verify before starting Task 5.
