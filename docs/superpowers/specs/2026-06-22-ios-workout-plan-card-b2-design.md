# iOS inline workout-plan card (B2) — design

**Date:** 2026-06-22
**Scope:** Replace Payne's persistent "Начать тренировку" button with an inline chat card: Payne sends a workout plan, it renders as a compact card with a "Начать тренировку" button under it, tapping opens the live WorkoutView with the already-received plan. Part B2 of the chat work. (B1 — generic `ask_user_question` action cards — already shipped.)
**Status:** Design approved, pending implementation plan

## Problem

Today the only way to open the live workout UI is a **persistent button** rendered in `ChatView` whenever the Payne agent is active (`ChatView.swift:198-217`). Tap → `sendWorkoutStartRequest(date)` → host → Payne replies `workout_plan` → iOS **auto-opens** `WorkoutView` (full-screen) via `workoutBus.planReceived`. The button is always on screen in Payne's chat regardless of context, and the plan never appears in the conversation — it just yanks you into a modal.

The inline-actions idea (B1) was meant for exactly this: Payne should **send a plan into the chat** with a "Начать тренировку" button beneath it, and the persistent button should go away.

## Goal

Payne sends a `workout_plan` → it renders in chat as a **compact persisted card** (day name · intensity · N exercises + a "Начать тренировку" button) → tap **opens WorkoutView with the already-held plan** (no round-trip) → on finish/abort the card is **marked done** (button greyed, B1 visual) and stays that way after reload. Remove the persistent button.

## Key realization (scope)

The `workout_plan` envelope **already arrives fully decoded on-device** (`AppCoordinator.handleWorkoutEnvelope` → `decodeWorkoutPlan` → `WorkoutPlan`). Opening the workout is **purely client-side** once the plan is in hand. So B2 needs:
- **No protocol change** (`workout_plan` already exists).
- **No host TypeScript change** (the workout-bridge forwards `workout_plan` unchanged).
- **iOS-only code** + **one Payne-instruction companion change** (deploy-side).

## What already works (do not rebuild)

- **Plan delivery:** Payne `workout_plan` → host workout-bridge → device → `WebSocketClientV2.onWorkoutEnvelope` → `AppCoordinator.handleWorkoutEnvelope` decodes to `WorkoutPlan` (`AppCoordinator.swift:314-388`).
- **Live workout UI:** `WorkoutView` + `Views/Workout/*`, presented via `.fullScreenCover(item: $activeWorkout)` in `ChatView`; `WorkoutCoordinator(plan:queue:)` + `WorkoutPresentation(plan:coord:)`; `onClose(session?)` sends `workout_complete` (session non-nil) or `workout_abort` (nil) (`ChatView.swift:319-350`).
- **B1 persistence + answered visual:** `messages.action_choice` column, `markActionAnswered`, the answered button styling (selected outlined + checkmark, rest greyed + disabled) in `ActionRow` (`MessageRow.swift:462-558`).
- **`WorkoutPlan` model** (Codable, snake_case CodingKeys): `workoutId, dayName, week, intensityLabel, exercises:[ExercisePlan], imageManifest:[ImageManifestEntry]` (`Models/Workout.swift`).

## Design

A new persisted **workout-plan chat card** content type. The plan rides into the store as a message row; the card renders from the stored plan; the Start button opens the held plan; completion marks it done.

### 1. Behavior change — persist instead of auto-open
`AppCoordinator.handleWorkoutEnvelope`, on `workout_plan`: after decoding `plan`, **insert a persisted plan message** into the chat store (`chatStore.insertWorkoutPlan(id: plan.workoutId, agentId: "payne", plan: plan)`) **instead of** firing `workoutBus.events.send(.planReceived(plan))`. The timeline observation renders the card. ChatView's `.onReceive` no longer auto-opens a workout on `.planReceived` (that handler is dropped). The `WorkoutInboundBus` `.planReceived` enum *case* may stay (other code paths and switch exhaustiveness reference the enum) — it simply stops being sent; only the send site and the ChatView open-handler are removed. `.coachMessage`/`.swapOptions`/`.programUpdated` are untouched.

### 2. Storage — `workout_plan_json` on the message row
- `Storage/Schema.swift`: migration `v8-workout-plan` adding `workout_plan_json TEXT`.
- **Done-state reuses the existing `action_choice` column** (B1): set to `"completed"` / `"aborted"` when the workout ends. A plan card with `action_choice != nil` renders done. (Rationale: a plan card *is* an action card with a Start button; `action_choice` = "this card's action was resolved." Avoids a second migration column.)
- `ConversationStoreV2`:
  - `insertWorkoutPlan(id:agentId:plan:)` — JSON-encode the `WorkoutPlan` (its Codable snake_case form), store a compact summary in `text` (e.g. `"🏋️ {dayName} · {intensityLabel} · {n} упр."`), `dir = .in_`, `agent_id = "payne"`, `workout_plan_json = json`. Idempotent on `id` (INSERT OR IGNORE / ON CONFLICT — `id = workoutId`, dedup-safe).
  - `StoredMessage` gains `workoutPlanJSON: String? = nil`; every read-from-row site populates it (mirror the B1 read-path completeness).
  - Done is marked via the existing `markActionAnswered(rowId:choice:)` (reused; `choice` = `"completed"`/`"aborted"`).

### 3. Render — `.workoutPlan` content + `WorkoutPlanRow`
- `Models/Message.swift`: new content case `case workoutPlan(WorkoutPlanCardInfo)` and `struct WorkoutPlanCardInfo: Equatable { let plan: WorkoutPlan; var done: Bool; var outcome: String? }`. The card derives `dayName`/`intensityLabel`/`exercises.count` from `plan`.
- `Services/WebSocketClientV2.toChatMessage`: when a row has `workoutPlanJSON`, decode it to `WorkoutPlan`, build `.workoutPlan(WorkoutPlanCardInfo(plan:, done: row.actionChoice != nil, outcome: row.actionChoice))`, return one message. Place this branch alongside the B1 `.action` branch (before text/attachment). Decode failure falls through to text (matches B1 house style).
- `Components/MessageRow.swift`: new `WorkoutPlanRow` — compact card (avatar dot + "PAYNE" + summary line) with a single **"Начать тренировку"** button. Reuse the B1 answered visual: when `done`, the button greys + shows a checkmark + thicker outline and is disabled (`.disabled(done)`). `MessageRow` routes `.workoutPlan` → `WorkoutPlanRow(messageId:, info:, onStart:)`.

### 4. Start tap + done-on-close (ChatView)
- `WorkoutPlanRow.onStart(messageId)` → in `ChatView`: build `WorkoutCoordinator(plan: info.plan, queue:)` + `WorkoutPresentation(plan: info.plan, coord:, messageId: messageId)` → set `activeWorkout` → `fullScreenCover` opens `WorkoutView` (existing). `WorkoutPresentation` gains `let messageId: String?`.
- `onClose(session)` (existing): after sending `workout_complete`/`workout_abort` and setting `activeWorkout = nil`, **mark the card done** — `if let id = presentation.messageId { coordinator.markActionAnswered(rowId: id, choice: session != nil ? "completed" : "aborted") }`. The card re-renders done (timeline observation).

### 5. Remove the persistent button
Delete `ChatView.swift:198-217` (the `if active.active == .payne { Button … }`). Leave `TransportV2.sendWorkoutStartRequest` and the `workout_start_request` protocol type in place (unused now; referenced by fixtures/tests — YAGNI, don't churn them).

## Required companion change (deploy-side, not iOS code)

Removing the button removes the only sender of `workout_start_request`. **Payne must emit `workout_plan` when the user asks for a workout in conversation** (e.g. "давай тренировку на сегодня"), not only in response to the button's structured event. Without this, no card ever appears. This is a Payne-instruction edit (the Payne workout skill / `groups/payne` on the VDS). To be verified and made at deploy time; the agent-runner + group files are host-mounted (no image rebuild).

## Error handling / edge cases

- **App killed mid-workout** (WorkoutView open, never closed) → on relaunch the card is still not-done (`action_choice == nil`) → tappable again → reopens the plan. Acceptable (in-progress set state isn't persisted today either).
- **Duplicate `workout_plan`** (same `workoutId`) → idempotent insert (no duplicate card).
- **Garbage `workout_plan_json`** → decode fails → row falls through to plain text (no crash, matches B1).
- **Old/stale plan card** → tapping Start opens whatever plan the card holds (user's choice); no freshness check.

## Testing

- **iOS (XCTest):**
  - `ConversationStoreV2`: `insertWorkoutPlan` persists `workout_plan_json` + summary text; re-insert with same id is idempotent; `markActionAnswered` sets the done outcome.
  - `toChatMessage`: a row with `workoutPlanJSON` builds `.workoutPlan` with the decoded plan + `done`/`outcome` from `action_choice` (both nil and set cases); a garbage `workoutPlanJSON` falls through to text.
- **No host tests** (no host change).
- **Manual device (build bump):** ask Payne for a workout → compact card appears in chat → tap "Начать тренировку" → WorkoutView opens with that plan → finish (or abort) → card shows done/greyed → survives app relaunch. Confirm the old persistent button is gone.

## Affected files

| File | Change |
|------|--------|
| `Views/ChatView.swift` | Remove persistent button; remove `.planReceived` auto-open; Start-tap builds `WorkoutPresentation`; `onClose` marks card done. |
| `Services/AppCoordinator.swift` | `handleWorkoutEnvelope` `workout_plan` → `insertWorkoutPlan` instead of `.planReceived`; (bus `.planReceived` case removed/retired). |
| `Storage/Schema.swift` | Migration `v8-workout-plan`: `workout_plan_json TEXT`. |
| `Storage/ConversationStoreV2.swift` | `insertWorkoutPlan`; `StoredMessage.workoutPlanJSON`; read-path population; reuse `markActionAnswered` for done. |
| `Services/WebSocketClientV2.swift` | `toChatMessage` builds `.workoutPlan` from `workoutPlanJSON`. |
| `Models/Message.swift` | `.workoutPlan(WorkoutPlanCardInfo)` content case + `WorkoutPlanCardInfo`. |
| `Components/MessageRow.swift` | `WorkoutPlanRow`; route `.workoutPlan`. |
| `Models/Workout.swift` (WorkoutPresentation) | `WorkoutPresentation.messageId: String?`. |
| `ios/JarvisApp/project.yml` | Version/build bump. |
| Tests | store + `toChatMessage` mapping. |
| **Payne instructions (deploy)** | Emit `workout_plan` on conversational workout request. |

## Non-goals

- Exercise preview inside the card (compact only — full list is in WorkoutView).
- Changing the in-workout UI (`WorkoutView` and subviews unchanged).
- Keeping the persistent button as a fallback.
- Persisting in-progress set state across app kill.
- A new protocol envelope (`workout_plan` is sufficient).
