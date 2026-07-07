# Workout Runner UI Fixes (design)

Date: 2026-07-07
Agent: Payne (iOS WorkoutView)

Four UX gaps in the live workout runner + Payne feedback loop:

1. Killing the app mid-workout wipes cursor/logged-sets from UI (server keeps queued set_log via SetLogQueue, but UI cannot resume).
2. When Sergei logs a set that strongly deviates from the prescribed weight/reps/RIR, Payne does not comment consistently — deviation detection is fully server-side and buried in prose instructions.
3. Rest-timer "next hint" only looks at `current+1`, so if Sergei skipped an exercise and came back later, the hint is wrong.
4. After `workout_complete`, the runner closes and the user has no summary — Payne is instructed to send one but the format is soft, easily skipped.

## Scope

- iOS: WorkoutCoordinator, WorkoutView + subviews, WorkoutRunnerLogic, TransportV2, GRDB schema, ChatView workout-card CTA.
- Wire protocol: extend `set_log` and `coach_message` payloads.
- Host: no code change on ios-app-v2 bridge (envelope pass-through). Payne CLAUDE.md `workout-mode` + `chat-log` skills tightened.

Out of scope: server-side deviation detection, new envelope types, post-workout modal, workout history browser, program.json edits.

---

## Axis 1 — Persist workout progress

### Storage

New GRDB table (migration in `Storage/Schema.swift`):

```sql
CREATE TABLE active_workout (
  agent_id     TEXT PRIMARY KEY,        -- e.g. 'payne'
  workout_id   TEXT NOT NULL,
  plan_json    TEXT NOT NULL,           -- serialized WorkoutPlan
  cursor_json  TEXT NOT NULL,           -- {currentExerciseIdx, currentSetIdx, logged: [LoggedExercise]}
  message_id   TEXT NOT NULL,           -- chat card that started it
  updated_at   REAL NOT NULL            -- unix seconds
);
```

One row per agent (only Payne today; keyed for future coaches). No index needed — PK covers lookup.

### Writer

`WorkoutCoordinator` gains an optional `ActiveWorkoutStore` dependency. It writes on every state-changing mutation:

- `logSet(...)` — after appending to `logged`
- `finishExercise(comment:)` — after advancing indices
- `activate(idx:)` — after moving cursor

Writes are synchronous (better-sqlite3-style GRDB `write`), tolerated because they are ~10-20 per workout total. Any write error is logged and swallowed (does not break UX).

Clears the row on `complete(...)` and `abort()`.

### Restorer

New service `ActiveWorkoutStore` with:

```swift
func save(agentId: String, workoutId: String, plan: WorkoutPlan, cursor: WorkoutCursor, messageId: String)
func load(agentId: String) -> ActiveWorkoutRecord?
func clear(agentId: String)
```

`WorkoutCursor` = `{currentExerciseIdx, currentSetIdx, logged}` (Codable).

`WorkoutCoordinator.init(restoring: ActiveWorkoutRecord, queue: SetLogQueue)` — new initializer that seeds `plan`, `currentExerciseIdx`, `currentSetIdx`, `logged` from the record.

### ChatView wiring

On `.onAppear` and on agent-switch to Payne, `ChatView` queries `ActiveWorkoutStore.load(agentId: "payne")`. If a record exists:

- Store the record in a `@State var activeWorkout: ActiveWorkoutRecord?`.
- The workout-plan card lives in `Components/MessageRow.swift` as `WorkoutPlanRow`. Pass `isResuming: Bool` down. When true for `messageId == record.messageId`:
  - CTA label swaps from "Посмотреть тренировку" to "Продолжить тренировку" and uses `Theme.accent` styling instead of the "done" muted style.
  - Tap dispatches to `resumeWorkout(record)` instead of `startWorkout(...)` — this bypasses `WorkoutPreviewView` and mounts `WorkoutView` directly.
- Fallback if the message-id is not in the current 500-message window: render a sticky banner above the message list — "Незавершённая тренировка · Продолжить" — that opens the runner.

`resumeWorkout` builds `WorkoutCoordinator(restoring: record, queue: queue)` and presents `WorkoutView` via the same `fullScreenCover` (`WorkoutPresentation` with `phase: .running`) the "start" path uses.

### Trade-off

- Chose GRDB table over the `kv` bag because the payload is structurally rich (nested logged array) and worth its own schema.
- Chose per-mutation writes over batched flush-on-background because a crash between two writes must not desync UI from server. GRDB writes are cheap enough.

---

## Axis 2 — Client-side deviation detection + set-anchored coach chip

### Thresholds

Added to `WorkoutRunnerLogic`:

```swift
enum SetDeviationKind: String, Codable {
    case weightUnder, weightOver
    case repsUnder, repsOver
    case failure       // rir == 0
    case tooEasy       // rir >= 4
}

struct SetDeviation: Codable, Equatable {
    let kind: SetDeviationKind
    let magnitude: Double   // % for weight, abs delta for reps, ignored for rir
}

/// Detect deviation for a logged set against the exercise plan.
/// Returns the FIRST matching kind (weight > reps > rir), or nil if within tolerance.
static func detectDeviation(actualReps: Int, actualWeight: Double, actualRir: Int,
                            exercise: ExercisePlan) -> SetDeviation?
```

Rules (const on `WorkoutRunnerLogic`):

- `weightDeviationPct = 0.15` — trigger if `|actual/target - 1| >= 0.15`
- `repsDeviationAbs = 3` — trigger if `|actual - mid(targetReps)| >= 3`
- `rir == 0` → `failure`; `rir >= 4` → `tooEasy`

Precedence weight → reps → rir so a single deviation is surfaced per set. If the exercise has no target weight, weight rule skips.

### Wire protocol

Extend `V2.SetLog.payload` (Swift mirror + TS canonical in `shared/ios-app-protocol/v2.ts` + fixture):

```ts
setLog: {
  workout_id: string
  exercise_slug: string
  set_idx: number
  reps: number
  weight: number
  reps_in_reserve: number
  ts: string
  // NEW:
  deviation?: {
    kind: 'weight_under'|'weight_over'|'reps_under'|'reps_over'|'failure'|'too_easy'
    magnitude: number
    target: { reps_min: number, reps_max: number, weight?: number, rir: number }
  }
}
```

`deviation` present ⇒ set fell outside tolerance. `target` snapshot lets Payne comment without loading `program.json`.

Extend `V2.CoachMessage.payload`:

```ts
coachMessage: {
  workout_id: string
  text: string
  // NEW:
  set_ref?: { exercise_slug: string; set_idx: number }
}
```

`set_ref` present ⇒ anchor to a specific set chip. Absent ⇒ falls back to the existing 4-sec top banner.

### iOS render

`WorkoutCoordinator` stores per-set coach hints in `logged[exIdx].sets[setIdx].coachHint: String?`. `InboundDispatcherV2` on `coach_message` with `set_ref` calls `coordinator.attachCoachHint(exerciseSlug:setIdx:text:)` instead of surfacing the banner.

`LoggedSetChips` reads `set.coachHint`. If non-nil:

- chip gets a `bubble.left.fill` (💬) badge in the accent color at 12pt bottom-trailing
- tap opens a `.sheet` with `Text(set.coachHint!)`, close button, 200pt height max

### Server side (Payne)

Update `groups/payne/skills/workout-mode/SKILL.md`:

- If `set_log.deviation` is present, `workout.coach` MUST be called with `set_ref: {exercise_slug, set_idx}` matching the deviating set, else the deviation is invisible.
- If `set_log.deviation` is absent, keep the "по умолчанию молчи" rule.
- Payne no longer needs to look up target values — they are in the deviation payload.

`workout.coach` MCP tool signature (`container/agent-runner/src/mcp-tools/workout.ts`) gains optional `set_ref` param passed through to the envelope payload.

### Trade-off

- Thresholds in iOS = deterministic client-side gate + works offline (queued in SetLogQueue with flag). Payne only formats prose.
- Duplication risk: if we later want to tune thresholds without shipping an iOS build, the CLAUDE.md rule is prose only. Acceptable — thresholds are stable.

---

## Axis 3 — Rest-timer next hint

### New algorithm

Refactor `WorkoutRunnerLogic.restHint` signature:

```swift
static func restHint(
    logged: [LoggedExercise],
    exercises: [ExercisePlan],
    activeIdx: Int
) -> String
```

Body:

```swift
let cur = exercises[activeIdx]
let curDone = logged[activeIdx].sets.count
if cur.targetSets > 0, curDone < cur.targetSets {
    return "подход \(curDone+1) — \(cur.displayName)"
}
for i in exercises.indices where exercises[i].targetSets > 0 {
    if logged[i].sets.count < exercises[i].targetSets {
        return "\(exercises[i].displayName) — подход \(logged[i].sets.count+1)"
    }
}
return "Тренировка закончена"
```

Exercises with `targetSets == 0` (duration/warmup) are skipped in the scan — they are handled by `DurationCard`, not the set flow.

### Caller

`WorkoutView.restHint` computed property forwards the full `logged` array and `plan.exercises` instead of just the neighbor name. `RestTimerOverlay` unchanged (still consumes a `String?`).

### Tests

Three unit-test cases in `WorkoutRunnerLogicTests`:

1. Current exercise has sets remaining → shows current + next set number.
2. Current done, earlier exercise skipped (0 sets logged) → shows that earlier exercise.
3. All exercises complete → "Тренировка закончена".

---

## Axis 4 — Payne post-workout summary (chat message)

No new envelope, no modal. Enforce the format in `groups/payne/skills/workout-mode/SKILL.md` under the existing `workout_complete` handler:

> После `workout_complete` ОБЯЗАТЕЛЬНО одно сообщение в чат Сергея в этом формате:
> ```
> Готово · <day_name>
> Тоннаж <N> кг · <M> мин · подходов <done>/<planned>
>
> <1–2 предложения — что было сильно/слабо, ключевой сигнал>
>
> Следующая: <day_name следующего дня>. <одно действие: вес/подход/отдых>.
> ```
> - Тоннаж = sum(reps × weight) по всем сданным подходам.
> - `<done>/<planned>` = сумма подходов из `session.exercises[].sets.length` над суммой `targetSets`.
> - Совет — одно конкретное действие. Не «продолжай в том же духе».
> - Никаких эмодзи-солнышек и «молодец». Личность — жёсткий тренер.

Runner closes automatically via existing `onClose(session)` — chat opens on Payne thread, summary appears at bottom. Sergei sees it without extra taps.

### Trade-off

- No new envelope type, no waiting modal, no timeout logic. Minimum viable.
- Risk: Payne may skip the summary. Mitigation: the rule is explicit and factuality-gated agents already comply with hard rules. Verified by manual smoke after Payne CLAUDE.md deploy.

---

## Data flow diagram (end-to-end)

```
Sergei taps "Записать подход"
      ↓
FocusSetCard.logCurrent()
      ↓
WorkoutCoordinator.logSet(reps, weight, rir)
      ├─ detectDeviation(...) → SetDeviation?
      ├─ logged[cur].sets.append(LoggedSet + deviation)
      ├─ SetLogQueue.enqueue(event + deviation)   ← durable, drains on WS reconnect
      └─ ActiveWorkoutStore.save(...)              ← durable, drives restore
             ↓
TransportV2 drains queue → set_log envelope (with deviation) → Payne
                                                                    ↓
                                    Payne reads deviation, sends coach_message
                                    { text, set_ref: {slug, set_idx} }
                                                                    ↓
InboundDispatcherV2 → coordinator.attachCoachHint(slug, idx, text)
                                                                    ↓
                     LoggedSetChips shows 💬 badge → tap → sheet
```

Kill app mid-workout:

```
Any state mutation → GRDB row updated
      ↓
App killed
      ↓
Cold start → ChatView appears on Payne → ActiveWorkoutStore.load()
      ↓
Workout card CTA shows "Продолжить тренировку"
(or sticky banner if card is out of window)
      ↓
Tap → WorkoutCoordinator(restoring: record, queue) → WorkoutView opens at exact cursor
```

Finish flow:

```
User taps "Финиш" → WorkoutFinishView → onDone(feeling, label)
      ↓
WorkoutCoordinator.complete() → WorkoutSession
      ├─ ActiveWorkoutStore.clear(agentId: "payne")   ← record gone
      └─ TransportV2 sends workout_complete envelope
             ↓
Payne receives workout_complete
      ↓
Payne runs skill `progression`
      ↓
Payne sends ONE chat message in the mandatory summary format
      ↓
Runner already closed via onClose; Sergei sees message on Payne thread
```

---

## Files touched

**iOS (Swift)**
- `ios/JarvisApp/Sources/JarvisApp/Storage/Schema.swift` — migration for `active_workout` table
- `ios/JarvisApp/Sources/JarvisApp/Storage/ActiveWorkoutStore.swift` — NEW
- `ios/JarvisApp/Sources/JarvisApp/Services/AppV2Bootstrap.swift` — construct + inject store
- `ios/JarvisApp/Sources/JarvisApp/Services/WorkoutCoordinator.swift` — restoring init, per-mutation persist, attachCoachHint
- `ios/JarvisApp/Sources/JarvisApp/Services/InboundDispatcherV2.swift` — route coach_message.set_ref to coordinator instead of banner
- `ios/JarvisApp/Sources/JarvisApp/Models/WorkoutRunnerLogic.swift` — SetDeviation types, detectDeviation, new restHint signature
- `ios/JarvisApp/Sources/JarvisApp/Models/Workout.swift` — LoggedSet.coachHint, LoggedSet.deviation
- `ios/JarvisApp/Sources/JarvisApp/Storage/SetLogQueue.swift` — persist deviation in queue rows
- `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` — set_log builder adds deviation
- `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` — deviation on SetLog, set_ref on CoachMessage
- `ios/JarvisApp/Sources/JarvisApp/Views/WorkoutView.swift` — restHint call site
- `ios/JarvisApp/Sources/JarvisApp/Views/Workout/LoggedSetChips.swift` — 💬 badge + tap sheet
- `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift` — resume path + sticky banner + `isResuming` propagation
- `ios/JarvisApp/Sources/JarvisApp/Components/MessageRow.swift` — `WorkoutPlanRow` CTA label + style flip for the active card
- Tests: `WorkoutRunnerLogicTests`, `WorkoutCoordinatorTests` (new: restore, deviation, attachHint), `ActiveWorkoutStoreTests` (NEW)
- `ios/JarvisApp/project.yml` — bump CURRENT_PROJECT_VERSION (+MARKETING)

**Wire protocol (TS)**
- `shared/ios-app-protocol/v2.ts` — SetLog.deviation, CoachMessage.set_ref
- fixtures under `shared/ios-app-protocol/fixtures/` — extend one set_log fixture + one coach_message

**Host + agent-runner**
- `container/agent-runner/src/mcp-tools/workout.ts` — `workout.coach` accepts optional `set_ref` param, forwards in envelope
- `src/channels/ios-app/v2/workout-bridge.ts` — no change (pass-through), plus test that deviation and set_ref survive round-trip

**Payne skills**
- `groups/payne/skills/workout-mode/SKILL.md` — set_ref rule on deviation; mandatory summary format under workout_complete

## Deploy

- **Host + agent-runner**: `pnpm run build`, `./container/build.sh` if agent-runner deps changed, git push, `ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw"'`.
- **Payne skill files** (`groups/payne/skills/workout-mode/SKILL.md`): `groups/*` is gitignored — deploy via `tar cz groups/payne/skills/workout-mode | ssh … tar xz` into the agents/payne shared-code path, then run `pnpm exec tsx scripts/reload-claude-md.ts payne` to kill the container + clear `continuation:%` rows so the next message picks up the new instructions.
- **iOS**: bump `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` in `project.yml`, `xcodegen generate`, install on device via TestFlight or direct install.

## Non-goals

- Server-side deviation detection or tunable thresholds (would require host change + config).
- Waiting modal after Finish with Payne spinner (chose chat-message path instead).
- Persisting draft `reps/weight/rir` from FocusSetCard between kills — only committed sets persist. Fresh set is prefilled from previous.
- Multi-workout history from the runner — that stays in chat scroll.

## Open risks

- If GRDB migration fails on an existing install, the store falls back to no-op and restore is silently disabled. Acceptable — no data corruption.
- If Payne sends a `coach_message` with `set_ref` pointing to a set that no longer exists (race with `activate` moving cursor), `attachCoachHint` is a no-op. No crash.
- If a set is logged offline, the deviation ships when the queue drains — but by then the user may already be on the next exercise. The chip still appears on the correct historic set card. Acceptable.
