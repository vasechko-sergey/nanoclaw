# Multi-Agent Isolation Design

**Date:** 2026-06-09
**Status:** Design
**Author:** Sergei + Jarvis

## Problem

Operator feedback after first live session with three agents (Jarvis, Payne, Greg) over the iOS app:

1. **Payne started empty.** On first contact Payne did not look at his own data (programs, sessions, exercises). Operator had to tell him to read.
2. **Cross-agent leakage.** Messages addressed to Payne were routed into Jarvis's session. Jarvis injected replies into the Payne chat thread.
3. **No visual workout.** Payne ran the entire training session as chat text. The iOS app already has a workout UI (plan, exercise images, rest timer, set log queue) but Payne emitted nothing structured.
4. **Wrong sender label.** When switching to a non-Jarvis agent tab on iOS, outbound replies were stamped `agent_id=jarvis`.
5. **Unclear session model.** Operator expects exactly three sessions per device — one per agent — with no dangling/zombie sessions.

(Item 6 — daily context reset — explicitly deferred. Closing sessions on a cron creates dead sessions the agent keeps writing into, which the operator never receives. For now the operator will manually ask an agent to `/new` when needed.)

## Root Causes

### Inbound routing ignores `agent_id` (causes #2 and #4)

`src/channels/ios-app/v2/index.ts` already resolves `(platform_id, agent_id) → session_id` via `resolveSessionForPlatform` and passes it into the dispatcher. But `onUserMessage` then drops `session_id` and calls `cfg.onInbound(platform_id, threadId, …)`, which goes through `routeInbound` in `src/router.ts`. `routeInbound` re-resolves the agent via `messaging_group_agents` wiring and trigger rules — it does not know about `agent_id`.

Net effect: every text message addressed to any agent on a given device lands in whichever agent is wired to the device's messaging_group via trigger-fanout. Currently only Jarvis is wired, so all messages go to Jarvis's session. Outbound stamp follows `session.agent_group_id`, so replies come back labelled `jarvis` regardless of which iOS chip the operator chose.

The workout-event bridge in the same adapter (`set_log`, `exercise_done`) already uses the resolved `session_id` directly — so the bug is text-message-only.

### `payne`/`greg` not registered as agent_groups (causes #5)

`groups/payne/` and `groups/health-analyzer/` exist on disk with CLAUDE.md and assets, but no `agent_groups` rows. `scripts/create-payne.ts` is a one-shot only run when the operator remembers. Greg has no script at all. Even when `agent_id=payne` arrives, `getAgentGroupByFolder('payne')` returns nothing in the adapter and it falls through to the default session.

### Payne has no proactive bootstrap (causes #1)

`groups/payne/CLAUDE.md` describes the persona but does not instruct Payne to read his data on first contact. There is no system-message injected by the host at session creation that says "read your context".

### Payne has no structured workout API (causes #3)

iOS already understands envelope types `plan`, `image`, `coach`, `swap`, `set_log`, `exercise_done` (workout-bridge.ts). Payne has no MCP tool to emit these envelopes, and no CLAUDE.md instruction telling him the protocol exists. He defaults to plain chat text.

## Design

### Component 1 — Adapter-owned routing by `agent_id`

**Where:** `src/channels/ios-app/v2/index.ts` + new `src/adapter-route.ts`.

**Rule:** the iOS adapter owns routing. `routeInbound`'s trigger-fanout is NOT used for iOS-app-v2 text messages. The router stays for channels without an explicit agent picker (Telegram, Slack, etc.).

**Flow:**
1. Inbound envelope arrives. Dispatcher reads `payload.agent_id` (slug). If absent, defaults to `jarvis` (configurable via `IOS_APP_DEFAULT_AGENT_SLUG`, already exists).
2. `resolveSessionForPlatform(platform_id, agent_id)` returns the session id for `(messaging_group, agent_group)`. If no session yet, `adapterRouteToAgent` creates one eagerly (see below).
3. `adapterRouteToAgent(event, mg, agent_group_id)` runs the same shared path as `routeInbound`:
   - `senderResolver(event)` — upsert users row, get user id
   - `accessGate(event, user_id, mg, agent_group_id)` — policy check; on refusal write `dropped_messages` and stop
   - `ensureSession(mg, agent_group_id)` — find-or-create session, return id
   - `writeSessionMessage(...)` — push into the session's `inbound.db`
   - `wakeContainer(...)` — knock on the container

**Why a shared helper:** `routeInbound` and the adapter both need sender resolution, access gate, session ensure, and wake. Duplicating loses the dropped_messages audit trail. The helper lives in `src/adapter-route.ts`, both call sites invoke it.

**onUserMessage rewrite:** the iOS dispatcher's `onUserMessage` calls `adapterRouteToAgent(event, mg, agent_group_id)` directly with the resolved `agent_group_id`, no more `cfg.onInbound`. `cfg.onInbound` stays for `new_conversation` and `feedback` envelopes (those are best-effort cross-agent system signals — keep them on the routeInbound path to whichever agent is mg-wired as default).

**Outbound:** no change needed. Outbound already stamps `agent_id` from `session.agent_group_id` → folder. Once the session is the correct per-agent session, the stamp is correct automatically.

### Component 2 — Trio bootstrap on host start

**Where:** new `src/bootstrap-trio.ts`, called from `src/index.ts` after `runMigrations` and before adapter init.

**Behaviour:** idempotent. On every host start:

1. For each of `jarvis`, `payne`, `greg`:
   - If `agent_groups` row missing → create with `id = folder = <slug>`, name from a constant table (`Jarvis`, `Майор Пейн`, `Dr House (Greg)`), `agent_provider=null`. (Letter-leading ids — required by OneCLI, see memory `reference_create_agent`.)
   - `ensureContainerConfig(<slug>)` — guarantees `container_configs` row.
2. For each `messaging_groups` row with `channel_type='ios-app-v2'`:
   - For each of the three slugs, `createMessagingGroupAgent` if no row exists for `(mg_id, agent_group_id)`. `session_mode='shared'`, no trigger rules, priority indexed (jarvis=0, payne=1, greg=2).
3. Eager-create sessions: for each `(ios-app-v2 mg, agent_group)` triple, if `findSessionForAgent(...)` returns nothing → create one session row. `thread_id=null`. This guarantees the operator's "exactly three sessions per device" invariant at startup.
4. Sweep duplicates: for each `(mg_id, agent_group_id, thread_id=null)` triple, keep the most recent session row, close any extras (set `closed_at`). Container kills follow on next sweep.

**Note on `messaging_group_agents` semantics after this change:** with adapter-owned routing, `messaging_group_agents` wiring no longer drives `messages` envelope routing for iOS. It still drives `new_conversation` and `feedback` envelopes (which keep going through `cfg.onInbound → routeInbound`), so the rows must exist. Trigger rules become dead config on this channel — document the exception in `docs/isolation-model.md`.

### Component 3 — Workout MCP tools for Payne

**Where:**
- Container skill: `container/skills/workout-tools/SKILL.md` — documents the tools, when to use each.
- MCP server: `container/agent-runner/src/mcp-tools/workout.ts` — implements the tool surface.
- Tool registration: only enabled for `cli_scope` not equal to `disabled` AND agent group folder is `payne` (skip for Jarvis/Greg). Wire via container_configs MCP server list.

**Tool surface:**

| Tool | Input | Effect |
|---|---|---|
| `workout.start_plan` | `{ plan: { exercises: [{ id, sets, reps, rest_sec, target_rpe, gif_url? }], notes? } }` | Writes outbound envelope `content.type='workout.plan'`. iOS preloads the full plan + caches gifs via `ExerciseImageCache`. Workout proceeds offline. |
| `workout.coach` | `{ text }` | Outbound `content.type='workout.coach'`. Short reaction during/between sets. Goes into the workout UI, not the chat scroll. |
| `workout.swap` | `{ from_exercise_id, to_exercise_id, reason }` | Outbound `content.type='workout.swap'`. Mid-workout exercise replacement. |
| `workout.finish` | `{ summary? }` | Outbound `content.type='workout.finish'`. iOS closes workout UI. Payne also updates INDEX.md (see Component 4). |

**Why no `send_exercise_image`:** all images come pre-referenced in `start_plan`. iOS pre-caches them at plan load. No per-exercise image envelope during the session.

**Inbound side:** Payne's container reads `workout_event` system messages (already produced by WorkoutBridge for `set_log`, `exercise_done`, `rest_skip`) on his normal poll loop. CLAUDE.md instructs him: "react via `workout.coach` only when meaningful — a personal record, a missed set pattern, a fatigue signal. Default: silence."

**CLAUDE.md addition for Payne:** new section `## Ведение тренировки`:
- "Стартуй с `workout.start_plan`. Один вызов — весь план целиком: упражнения, подходы, RPE-цели, gif_url для каждого. iOS закэширует и проведёт сессию даже без связи."
- "По ходу — слушай `set_log`/`exercise_done`. Реагируй через `workout.coach` редко: PR, явный провал серии, признак усталости. Молчание — норма."
- "Подмена упражнения — `workout.swap`, с причиной."
- "В конце — `workout.finish` + обнови INDEX.md."

### Component 4 — Payne reads context on session start

**Where:**
- `groups/payne/INDEX.md` — new file. Hand-written initial version + Payne maintains it.
- Bootstrap message logic: extend Component 2 — when `bootstrap-trio.ts` eager-creates Payne's session, write one initial inbound message.

**INDEX.md shape (one screen, no fluff):**
```
# Payne INDEX

## Текущая программа
<short summary: name, week, focus>

## Последняя тренировка
<date>: <exercises completed, key PRs, RPE trend>

## Активный мышечный цикл
<which groups loaded this week, which need work>

## Заметки
<short bullet list of operator preferences, injuries, current goals>
```

**Bootstrap inbound message** (written by `bootstrap-trio.ts` immediately after session create, kind=`system`, `trigger=0`):
```
[bootstrap] Прочитай INDEX.md и memories/self/profile.md. Дальше работай как обычно — без рапорта, без приветствия. Молчи до явного запроса Сергея.
```

`trigger=0` means the container reads + processes context but does not generate a chat reply. Payne loads context into memory, stays silent, replies normally to the first real user message.

**Maintenance:** CLAUDE.md `## Ведение тренировки` ends with: "После `workout.finish` — обнови INDEX.md: последняя тренировка, тренд RPE, что изменилось в недельном объёме."

### Component 5 — outbound signature (resolved by Component 1)

No additional work. Outbound already does `session.agent_group_id → folder → payload.agent_id`. Once routing puts the message in Payne's session, the stamp is `payne` automatically. iOS filters chat scroll by `active.rawValue`, so the Payne chip shows only Payne's replies.

## Data flow (after change)

```
iOS chip=payne
  ↓ envelope { type:'message', payload:{ text, agent_id:'payne', ... } }
WS handler → InboundDispatcher
  ↓ resolveSessionForPlatform(pid, 'payne') → sess-payne-id
adapterRouteToAgent(event, mg, 'payne')
  ↓ senderResolver → accessGate → ensureSession → writeSessionMessage → wake
Payne container reads inbound.db
  ↓ reply: workout.start_plan(...) MCP call OR plain chat text
Outbound message written with session.agent_group_id='payne'
adapter.deliver:
  ↓ stamp payload.agent_id='payne', send envelope
iOS receives → ChatView filters by active=='payne' → shows in Payne thread

Jarvis container never sees this message. Jarvis chip in iOS never sees Payne's reply.
```

## Error handling

- **`agent_id` slug unknown** (e.g. typo, agent not bootstrapped): adapter logs warn, falls back to `jarvis`. Operator sees the message in Jarvis chip.
- **Bootstrap fails for one agent** (e.g. OneCLI rejects letter-id): host logs error, continues with the other two. Operator hits the missing agent and sees "agent not available" via access gate refusal.
- **Workout tool called by non-Payne agent**: MCP tool checks `process.env.AGENT_GROUP_ID === 'payne'`, refuses otherwise. Defensive only — registration should already exclude.
- **INDEX.md missing**: bootstrap message still fires. Payne reads CLAUDE.md, replies normally, creates INDEX.md on first workout finish.

## Testing

- `src/adapter-route.test.ts` — shared helper unit tests (sender resolve, access gate refusal path, ensureSession, write+wake).
- `src/channels/ios-app/v2/inbound-dispatch.test.ts` — extend: agent_id=payne routes to Payne session, agent_id missing falls back to jarvis, unknown agent_id logs and falls back.
- `src/bootstrap-trio.test.ts` — idempotency, partial state recovery, sweep of duplicate sessions.
- `container/agent-runner/src/mcp-tools/workout.test.ts` — each tool produces a correctly-shaped outbound envelope. Refusal when AGENT_GROUP_ID≠payne.
- E2E: extend `scripts/test-v2-channel-e2e.ts` — three concurrent sessions, message-to-payne does not surface in jarvis session, workout.start_plan envelope reaches device.

## Out of scope

- Daily context reset (deferred — dead-session problem unresolved).
- Workout history queries from chat (Payne can grep `groups/payne/sessions/` himself).
- Greg's data bootstrap analogue (cover separately once we see how Payne's INDEX.md pattern lands).
- Per-agent unread badges on iOS chip (UI concern, separate spec).

## Open Questions

None blocking. INDEX.md initial content can be hand-written by operator after first Payne workout if not auto-generated.
