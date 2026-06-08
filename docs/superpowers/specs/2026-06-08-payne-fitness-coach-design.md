# Payne — Fitness Coach Agent (Design)

**Date:** 2026-06-08
**Status:** Approved, ready for implementation plan
**Related:** [iOS App Protocol v2](./2026-05-31-ios-app-protocol-v2-design.md), [Jarvis Persona Refactor](./2026-06-06-jarvis-persona-refactor-design.md), [Greg / Health Agent](./2026-06-05-greg-house-persona-design.md)

## 1. Goal

Add a dedicated fitness-coach agent ("Payne") to the Jarvis VDS deployment. Payne owns:

- training programs (mesocycles, weekly intensity waves, deload)
- exercise library with schematic images cached on disk
- per-set workout logging via a structured iOS "Workout mode"
- adaptive autoregulation based on user effort (reps-in-reserve)
- coordination with Jarvis (scheduling, brief integration) and Greg (health signals)

Personality: "smoothed Major Payne" — drill-instructor character (rubленые команды, безжалостная честность, чёрный юмор) without slurs, caps-shouting, or genuine cruelty. Plain-Russian rule applies: no jargon in user-facing messages (machine-internal JSON keys may stay short).

Scope of this spec covers the agent, its data model, the iOS workout UI, and the host-side routing changes. Apple Watch, voice input, video form-check, body-measurement tracking, and HealthKit-workout integration are explicitly out of scope (future work, listed in §10).

## 2. Architecture

New agent group `payne` lives on the same VDS as `jarvis` and `health-analyzer`. Standard NanoClaw container (Bun runtime, no extra mounts — `groups/payne/` is auto-mounted at `/workspace/agent`).

```
groups/payne/
├── CLAUDE.md                  persona + rules + reference to constraints.md
├── constraints.md             injuries, equipment, frequency, goals
├── profile.md                 filled after intake
├── exercises/                 image cache + per-exercise metadata
│   ├── incline-db-press.jpg
│   ├── incline-db-press.json  { name_ru, name_en, muscle_groups, equipment, axial_load, refs, notes }
│   └── ...
├── programs/
│   ├── current.json           active mesocycle
│   └── archive/YYYY-MM-DD.json
├── sessions/                  per-workout logs
│   └── YYYY-MM-DD.json
├── scripts/                   bun helpers
│   ├── progression.js         compute next session targets from history
│   └── volume-report.js       weekly retro generator
└── memories/                  free-form agent notes (mirrors Jarvis layout)
```

**Wirings (created on deploy via `ncl`):**

- `payne` ↔ `ios-app` messaging group `ios-payne` (new; session-mode shared)
- `payne ↔ jarvis` a2a destinations both ways
- `greg → payne` a2a (one-way) — daily health signal
- `payne → greg` a2a — post-workout summary

**Agent creation follows the recipe in [reference_create_agent](../../../.claude/projects/-Users-serg-git-nanoclaw/memory/reference_create_agent.md):** letter-leading id (`payne`), explicit `createAgentGroup` + `ensureContainerConfig` via tsx script, then `ncl destinations add` for both directions, then `writeDestinations` on Jarvis's live session so the projection picks up the new neighbour without restart.

## 3. Data model

All data is JSON on disk under `groups/payne/`. No SQLite at the group level — files diff cleanly in git (memories repo), agent reads/writes with `bun`.

### 3.1 Exercise card — `exercises/<slug>.json`

```json
{
  "slug": "incline-db-press",
  "name_ru": "Жим гантелей на наклонной",
  "name_en": "Incline Dumbbell Press",
  "muscle_groups": ["chest_upper", "triceps", "delts_front"],
  "equipment": ["dumbbells", "incline_bench"],
  "axial_load": false,
  "image": "incline-db-press.jpg",
  "refs": ["t.me/antitrener/.../12345"],
  "notes": "лопатки сведены, локти ~45°",
  "created_at": "2026-06-08T12:00:00Z"
}
```

`muscle_groups` uses a canonical vocabulary maintained by Payne (`muscle_groups.md` in the group folder). Used for swap validation in §5.4.

`axial_load: true` exercises are forbidden by the lumbar-herniation constraint and are filtered out at program-generation time.

### 3.2 Mesocycle — `programs/current.json`

```json
{
  "id": "mesocycle-2026-06",
  "started_at": "2026-06-09",
  "block": "hypertrophy",
  "weeks": 5,
  "current_week": 1,
  "split": "upper-lower-rest-push-pull",
  "weekly_intensity_pattern": [
    {"week": 1, "intensity": "medium",  "set_modifier": 1.0,  "weight_modifier": 1.0,   "rir_target": 3},
    {"week": 2, "intensity": "heavy",   "set_modifier": 1.0,  "weight_modifier": 1.05,  "rir_target": 2},
    {"week": 3, "intensity": "light",   "set_modifier": 0.7,  "weight_modifier": 0.9,   "rir_target": 4},
    {"week": 4, "intensity": "heavy",   "set_modifier": 1.0,  "weight_modifier": 1.075, "rir_target": 1},
    {"week": 5, "intensity": "deload",  "set_modifier": 0.5,  "weight_modifier": 0.7,   "rir_target": 4}
  ],
  "days": [
    {
      "day_idx": 0,
      "name": "Верх A",
      "exercises": [
        {
          "exercise_slug": "incline-db-press",
          "target_sets": 4,
          "target_reps": "8-10",
          "target_rir": 2,
          "rest_sec": 120,
          "notes": "первый подход — калибровочный"
        }
      ]
    }
  ],
  "deload_at_week": 5
}
```

Base program is defined for the "medium" week. When generating today's `workout_plan` (§4.2), Payne applies the active week's modifiers:

- `target_sets_effective = round(target_sets * set_modifier)`
- `target_weight_effective = baseline_weight * weight_modifier`
- `target_rir_effective = weekly.rir_target` (overrides per-exercise default)

### 3.3 Session log — `sessions/YYYY-MM-DD.json`

```json
{
  "workout_id": "01J6Z8W3K2N5A7B9C1D3E5F7G9",
  "date": "2026-06-09",
  "program_id": "mesocycle-2026-06",
  "week": 1,
  "day_idx": 0,
  "started_at": "2026-06-09T19:03:00Z",
  "finished_at": "2026-06-09T20:14:00Z",
  "exercises": [
    {
      "exercise_slug": "incline-db-press",
      "sets": [
        { "reps": 10, "weight": 22.5, "reps_in_reserve": 3, "ts": "2026-06-09T19:05:00Z" },
        { "reps": 9,  "weight": 22.5, "reps_in_reserve": 2, "ts": "2026-06-09T19:08:00Z" },
        { "reps": 8,  "weight": 22.5, "reps_in_reserve": 1, "ts": "2026-06-09T19:11:00Z" },
        { "reps": 7,  "weight": 22.5, "reps_in_reserve": 0, "ts": "2026-06-09T19:14:00Z" }
      ],
      "comments": ["четвёртый подход — недобрал, форма поплыла"]
    }
  ],
  "health_signal_at_start": "green",
  "perceived_overall_rir": 1
}
```

`workout_id` is a ULID generated by iOS at workout-start time. Used as the dedup key — Payne's session-writer merges in-flight `set_log` events against the final `workout_complete` payload by `(workout_id, exercise_slug, set_idx)`.

### 3.4 `constraints.md` (initial state)

```markdown
- НЕТ осевых нагрузок и нагрузки на поясницу под нагрузкой (грыжа поясничного отдела):
  без приседа со штангой на спине, армейского жима стоя, становой со штангой,
  румынки и любых вариантов с наклоном корпуса под нагрузкой
- Альтернативы:
  - ноги: гак-машина, жим ногами, болгарские выпады с гантелями в руках,
    разгибания/сгибания в тренажёре, ягодичный мост со штангой (поясница лежит)
  - спина: вертикальная и горизонтальная тяга в тренажёре, тяга гантели в наклоне
    с упором коленом и одной рукой (корпус разгружен), пуловер
  - плечи: жим гантелей сидя со спинкой, разводки, обратные разводки
```

Payne extends this file during intake and over time.

## 4. WebSocket protocol — iOS ↔ Payne

Extends `src/channels/ios-app.ts` with hidden message types (same pattern as `context_request`/`context_response` from the pull-context model). These types do **not** render as chat bubbles.

### 4.1 iOS → server

| Type | Payload | When |
|------|---------|------|
| `workout_start_request` | `{date}` | User taps "Начать тренировку" |
| `set_log` | `{workout_id, exercise_slug, set_idx, reps, weight, reps_in_reserve, ts}` | After every completed set (queued, fire-and-forget) |
| `exercise_done` | `{workout_id, exercise_slug, comment?}` | User taps "Закончить упражнение" |
| `workout_complete` | `{workout_id, full_session_json}` | End of workout; carries the full session as a safety net |
| `workout_abort` | `{workout_id, reason}` | User abandoned |
| `image_request` | `{slug}` | iOS missing local image cache for this exercise |
| `exercise_swap_request` | `{workout_id, exercise_slug, proposed?: string}` | User tapped "🔁 Заменить" |
| `exercise_swap_confirm` | `{workout_id, original_slug, new_slug, persist?: boolean}` | User picked a swap; `persist=true` rewrites `programs/current.json` |
| `intro_request` | `{}` | iOS opening Payne thread for the first time, history empty |

### 4.2 Server → iOS

| Type | Payload | When |
|------|---------|------|
| `workout_plan` | `{workout_id, plan_json, image_manifest: [{slug, sha256, url?}]}` | Response to `workout_start_request` |
| `coach_message` | `{workout_id?, text}` | Async coach reply during a workout (renders as overlay banner + duplicates into normal chat thread) |
| `program_update` | `{program_json}` | Payne edited the active mesocycle |
| `image_blob` | `{slug, sha256, base64}` | Response to `image_request` |
| `exercise_swap_options` | `{workout_id, original_slug, accepted?: {slug}, rejected?: {slug, reason}, alternatives: [{slug, why}]}` | Response to `exercise_swap_request` |

### 4.3 Image delivery

- iOS holds a local disk cache keyed `exercises/<slug>_<sha256>.jpg`
- `workout_plan` includes `image_manifest` (slug + sha256 only — no bytes)
- iOS reconciles against the cache. Misses → `image_request` → Payne reads from disk and sends `image_blob` (base64). One transport (WS), one auth (Tailscale), no separate HTTP route.

### 4.4 Reliability queue

- iOS persists every outgoing `set_log` to a Core-Data queue with `delivered=false`
- A background sender drains the queue over WS; ack flips the flag
- On reconnect, all `delivered=false` events get re-sent (idempotent on Payne by `(workout_id, exercise_slug, set_idx)`)
- `workout_complete` always carries the full session JSON — even if every `set_log` was lost, Payne can rebuild from this payload

## 5. Agent behaviour

### 5.1 Persona

"Smoothed Major Payne":
- На «ты», обращение «солдат» (default), по имени когда серьёзно
- Cели и план — холодно и конкретно (подходы / повторы / запас), без лирики
- Похвала редкая, ценная: за PR, за честный лог, за выход после плохого дня
- На пропуски — без вины, без жалости: «вчера пропустил — сегодня компенсируем X»
- На красный health-signal от Грега — смягчается, переключает на восстановление без морали
- В чате никогда не использует жаргон/аббревиатуры (RPE/RIR/HRV/volume/deload). Переводы:
  - RPE 8 → «тяжесть подхода 8 из 10» (информативно, но default — следующая)
  - RIR 2 → «запас 2 повтора» (предпочтительный формат)
  - HRV → «вариабельность пульса»
  - RHR → «пульс покоя»
  - deload → «разгрузочная неделя»
  - volume → «недельный объём»

These rules live in `groups/payne/CLAUDE.md`.

### 5.2 Onboarding (first run)

Triggered by `intro_request` from iOS (sent when the user opens an empty Payne thread).

1. **Intake** — five questions, one at a time:
   1. Цель? (массанабор / сила / общая форма / похудение / поддержание, multi-select)
   2. Сколько раз в неделю в зал? (2 / 3 / 4 / 5)
   3. Где тренируешься? (полноценный зал / домашний с гантелями / гибрид)
   4. Опыт? (новичок <1 года / средний 1–3 / опытный 3+)
   5. Травмы и ограничения? (free text; Сергей will mention lumbar herniation)
2. **Optional baseline import** — Payne asks: «Есть прошлые рабочие веса? Кидай свободным текстом или скриншоты из антитренера. Если нет — соберём за неделю 0.» Parses into a synthetic `sessions/baseline.json` and stores numerics in `profile.md`.
3. **Diagnostic week 0** — generates a 5–7 day micro-block (or 2–3 days if baseline imported) of calibration sessions. Each calibration set has `is_calibration: true` and asks for "до отказа" with weight X; Payne estimates 1RM by Epley and derives starting working weights.
4. **Mesocycle build** — Payne writes `programs/current.json` for a 5-week hypertrophy or strength block depending on goal. Starts next Monday or immediately, user's choice.

For unknown exercises, Payne asks the user to send reference images in the chat. When the user sends an image with context ("вот референс на жим гантелей на наклонной"), Payne attempts to auto-route it into `exercises/<slug>.jpg` with metadata. Ambiguous → asks.

### 5.3 In-workout

- On `workout_start_request`, Payne loads `programs/current.json`, picks the day per the split + `current_week`, applies the week's intensity modifiers, and emits `workout_plan` with an `image_manifest`.
- `set_log` events are written to a session-in-progress JSON (held in memory or scratch file) keyed by `workout_id`. Payne does **not** synchronously respond to every set — UI must not block.
- Payne may emit `coach_message` mid-workout when:
  - User goes 2+ reps below target with `reps_in_reserve=0` on two consecutive sets → "сбавь до X"
  - User finishes early with `reps_in_reserve >= 4` → "добавь подход" or "повысь вес"
  - First set is a calibration → confirms the resulting working weight back
- On `workout_complete`, Payne writes `sessions/YYYY-MM-DD.json` (merging streamed sets with the final payload), runs `scripts/progression.js` to compute deltas for the next session of the same day, and posts a short retro to the chat thread.

### 5.4 Exercise swap

- **Without `proposed`:** Payne picks 2–3 exercises with ≥50% overlap of the original's `muscle_groups`, filtered by `constraints.md`, sorted by equipment proximity. Returns `exercise_swap_options` with `alternatives`.
- **With `proposed`:** Payne resolves the free-text proposal to a slug (matching existing `exercises/*.json` or creating a stub card with `image: null` and `notes: "нужна картинка"`). Compares `muscle_groups` against the original — if overlap ≥ 50% and constraints satisfied, returns `accepted`. If not, returns `rejected` with a human explanation and `alternatives`.
- On `exercise_swap_confirm` with `persist=true`, Payne rewrites the active day's exercise list in `programs/current.json` and emits `program_update`. With `persist=false`, swap is in-session only.

### 5.5 Rest timer adaptation

The adaptation rule is owned by iOS (no extra WS round-trip per set). After every set, iOS computes effective rest from the last set's `reps_in_reserve`:

- `reps_in_reserve = 0` → planned `rest_sec` + 30
- `reps_in_reserve >= 4` → planned `rest_sec` − 15 (and the UI surfaces a soft hint "вес похоже лёгкий")
- otherwise → planned `rest_sec` from the program

Payne may still override via a `coach_message` ("дай себе отдышаться, отдых +60") — that's a text hint, not a structured field. The local rule is the default.

### 5.6 Weekly retro

Cron 20:00 local Sunday (or on the last workout of the week, whichever first). Payne runs `scripts/volume-report.js` which scans the week's sessions, calculates tonnage deltas, average `reps_in_reserve` per major lift, identifies regressions, and writes a short message to the user. Plus a structured summary entry in `memories/retro/YYYY-WW.md`.

## 6. a2a integration

### 6.1 Destinations

Created via `ncl destinations add` on the VDS:

| From | To | local_name |
|------|-----|------------|
| jarvis | payne | `payne` |
| payne | jarvis | `jarvis` |
| greg | payne | `payne` |
| payne | greg | `greg` |

### 6.2 Message contracts

**`jarvis → payne` `next_workout`** — Jarvis morning-brief asks. Reply:
```json
{"day_name": "Верх A", "duration_estimate_min": 75,
 "main_exercises": ["жим гантелей на наклонной", "тяга в наклоне"],
 "intensity": "тяжёлая (неделя 2)"}
```

**`payne → jarvis` `workout_done`** — after `workout_complete`:
```json
{"action": "workout_done", "date": "2026-06-09", "type": "Верх A",
 "duration_min": 72, "perceived_overall_rir": 1, "notes": "жим просел"}
```

**`payne → jarvis` `reschedule_request`** — if a skip pattern emerges:
```json
{"action": "reschedule_request", "from_date": "2026-06-09", "reason": "пропуск"}
```
Jarvis consults gcal MCP, replies `reschedule_confirm {new_date}`.

**`greg → payne` `health_signal`** — emitted at 09:00 UTC after Greg's analysis:
```json
{"action": "health_signal", "date": "2026-06-09", "level": "yellow",
 "factors": ["low_sleep_score", "elevated_resting_hr"],
 "recommendation": "снизить недельный объём на 20%"}
```
Payne consults the latest `health_signal` when generating today's `workout_plan`. Yellow → softer modifiers on the fly. Red → proposes rest or light cardio in chat and asks for confirmation.

**`payne → greg` `workout_done`**:
```json
{"action": "workout_done", "date": "2026-06-09", "type": "Верх A",
 "tonnage_kg": 12450, "duration_min": 72, "perceived_overall_rir": 1}
```
Greg incorporates training load into recovery analysis.

### 6.3 Skip detection

Owned by Jarvis. If `programs/current.json` says today is a workout day and no `workout_done` from Payne by 22:00 local, Jarvis next-morning brief includes "вчера пропустил тренировку. Перенести на сегодня или сдвинуть неделю?" Tap → Jarvis emits `reschedule_request` to Payne.

## 7. iOS app changes

### 7.1 Multi-agent routing

Currently the iOS channel maps to one messaging group (`ios-jarvis`). We extend to three: `ios-jarvis`, `ios-payne`, `ios-greg`. One WebSocket connection per device; messages carry `target_agent` (outgoing) and `from_agent` (incoming).

**Host-side (`src/channels/ios-app.ts`):**
- Config: replace `IOS_APP_TARGET_MESSAGING_GROUP` with a map `{ jarvis: <mg_id>, payne: <mg_id>, greg: <mg_id> }`
- Inbound dispatch: route by `target_agent` field on the WS payload
- Outbound: tag outgoing messages with `from_agent` (derive from sending agent_group's slug)

**App-side:**
- Core Data: new `ChatThread` entity with `agent_id` (`jarvis` | `payne` | `greg`), 1-to-many with existing `Message`
- UI: top-of-chat segment control or chip row with three names; selecting a chip switches the active `ChatThread`
- Per-thread unread badges
- APNs: payload carries `agent_id`; tapping opens the right thread

**Greg DM side-effect:** Greg gains an iOS DM channel, no longer headless. Existing 09:00 UTC cron and a2a path to Jarvis are unchanged. Initial `intro_request` to Greg triggers a short hello in his persona.

### 7.2 WorkoutView

A new full-screen modal launched from:
- Payne chat: a button on the most recent `workout_plan` ("Начать тренировку")
- Home screen: a "Тренировка" tile when a program day is scheduled for today

**Layout (top → bottom):**

```
[ navbar: "Тренировка ног · нед. 2 (тяжёлая) / день 2"   ✕ ]
[ прогресс упражнений:  ● ● ◐ ○ ○   3 из 5 ]
[ КАРТИНКА упражнения (тап → fullscreen) ]
[ Название · Цель: 4×8-10, запас 2 повтора · Отдых: 2 мин ]
[ заметка тренера курсивом ]
[ ────  ПОДХОДЫ  ──── ]
[ #1   повторы [10 ▲▼]  вес [90 ▲▼] кг  ещё мог [2 ▲▼]   ✓ ]
[ #2   ... ]
[ [ + подход ]   [ 🔁 заменить ]   [ финиш ] ]
[ ─ баннер тренера (если есть) ─ ]
```

**Behaviour:**
- Steppers: reps ±1; weight ±0.5/1/2.5/5 (long-press accelerates). Plate-math affordance "📏" expands to show plate combination ("штанга 20 + 2×20 + 2×5").
- Pre-fill: last session's same exercise at the same set index; missing history → program target.
- Tap ✓ on a set: enqueue `set_log` and immediately show a full-screen rest timer overlay with "пропустить" button. Timer respects adaptation rules from §5.5.
- "🔁 Заменить" — opens swap sheet: free-text "свой вариант" field + "предложи мне" button → produces `exercise_swap_options` UI; toggle "оставить в программе" controls `persist`.
- "финиш" or completing the last set of the last exercise: a sheet asking "общее ощущение (запас по тренировке)" + free comment → emits `workout_complete`.
- ✕ → confirm → `workout_abort`.
- `coach_message` arriving with active workout: shows as a sliding bottom banner for 4 sec; persists in the regular Payne thread.
- `AsyncImage` with local disk cache keyed by `slug+sha256`; misses trigger `image_request`.

**Local rest-timer notification:** scheduled as a local iOS notification at timer-fire time so a locked phone still alerts. Cancelled if the user taps "пропустить" or starts the next set early.

## 8. Build / deploy

1. **Local:** scaffold `groups/payne/` (CLAUDE.md, constraints.md, scripts/, exercises/, programs/, sessions/, memories/). Commit to nanoclaw repo.
2. **VDS:** `git pull` as user `nanoclaw`; `pnpm run build` (per the VDS-build feedback memory).
3. **DB scaffold:** run a tsx script to `createAgentGroup({id:"payne", ...})` + `ensureContainerConfig("payne")`. Confirm OneCLI agent gets created with the letter-leading id.
4. **OneCLI:** if Payne needs any external API access (initially: none — all data is local), follow the "selective vs all" gotcha from CLAUDE.md.
5. **Messaging groups + wirings:** create `ios-payne` and `ios-greg`, wire to `payne` / `greg` (session-mode shared).
6. **Destinations:** add `jarvis↔payne`, `greg↔payne` via `ncl destinations add`. Run `writeDestinations` on Jarvis's live session via tsx script so the projection updates without restart.
7. **iOS app:** ship multi-agent routing + WorkoutView in a single TestFlight build.
8. **Bootstrap message:** first WS connection from the updated iOS picks Payne in the agent switcher → app sends `intro_request` → Payne wakes and runs the 5-question intake.

## 9. Observability

- Per-set events: traced via `set_log` writes to `data/v2-sessions/<payne-session>/inbound.db`. Cross-reference with `sessions/YYYY-MM-DD.json` for a full picture.
- Image cache health: `groups/payne/exercises/` directory listing + count of stubs (`image: null`).
- Coach quality: weekly retro in `memories/retro/YYYY-WW.md` doubles as a journal — easy to scan for "did Payne actually adapt this week?"
- Health-signal influence: Payne logs to `memories/health_signals/YYYY-MM.md` whenever it modifies a `workout_plan` due to a yellow/red signal.

## 10. Out of scope (future work)

- **Voice input** for set logging in WorkoutView (`SFSpeechRecognizer`, parse "10 по 90 запас 2").
- **Apple Watch app** — rest timer on wrist, HR monitoring, voice log.
- **HealthKit workout integration** — iOS writes a "Strength Training" session during WorkoutView; Greg pulls HR/calories to validate `reps_in_reserve` claims (high HR vs claimed-easy = mismatch).
- **Form-check via video** — user films a set, Payne reviews via vision-capable Claude. Watch token cost and false positives.
- **Body-progress tracking** — waist/biceps/weight measurements, progress photos. Likely Greg's portfolio, not Payne's.
- **Workout export** — CSV/PDF of a mesocycle for a physiotherapist or doctor.
- **Animated exercise media** — GIF/MP4 alongside JPG for technique cues; UI picks whichever exists.

## 11. Open questions (deferred to plan)

1. **Synthetic baseline session schema** — `sessions/baseline.json` shape is a slim variant of §3.3 (no streamed timestamps, no `workout_id`). Will be finalized in the plan.
2. **Muscle-groups vocabulary file** — exact list of canonical group slugs (`chest_upper`, `delts_front`, ...) and the overlap-percentage threshold for swap acceptance. Default is 50%; the plan will commit a starter vocabulary and the rule.
3. **Manifest-only image policy edge case** — what happens when the user signs in on a fresh device with zero local image cache and the first `workout_plan` carries 8 exercises. Naïve flow = 8 sequential `image_request`/`image_blob` round-trips. The plan should decide between batch fetch and serial-on-render.

## 12. Acceptance criteria

- Sergei can open the iOS app, switch to "Payne" in the agent strip, get a 5-question intake, optionally import past weights, and receive a `programs/current.json` he can review in plain language.
- "Начать тренировку" opens WorkoutView, walks through the planned exercises, logs every set, survives WS disconnect/reconnect without losing data, and ends with a posted retro from Payne in chat.
- Exercise swap works both ways: "предложи" returns three constraint-respecting alternatives; "свой вариант: <X>" either accepts or rejects with a human reason and alternatives.
- A yellow or red `health_signal` from Greg measurably changes today's plan (smaller modifiers or rest proposal).
- Greg becomes reachable as a regular chat in iOS without breaking his existing cron/a2a behaviour.
