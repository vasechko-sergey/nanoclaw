# iOS inline action cards (B1) — design

**Date:** 2026-06-22
**Scope:** Wire the existing `ask_user_question` primitive to the iOS app — the agent can send a multiple-choice question that renders as tappable buttons in the chat. Part B1 of the chat work. (B2 — workout plan as an inline card — is a separate spec.)
**Status:** Design approved, pending implementation plan

## Problem

The agent has an `ask_user_question(title, question, options)` MCP tool (blocking) backed by a host `ask_question` primitive (`src/channels/ask-question.ts`) with `pending_questions` persistence and an `onAction(questionId, choice, userId)` response router. It works on other channels. On **iOS it doesn't**: the v2 `message` payload carries no buttons, the ios-app-v2 adapter sends the question as plain text (options dropped), and `toChatMessage` can't produce `.action` content. So an `ask_user_question` to an iOS user shows un-answerable text and the blocking tool times out. The iOS `ActionInfo`/`ActionRow`/`sendActionResponse` exist but are dormant (no inbound path).

## Goal

Agent calls `ask_user_question` → the iOS user sees a card (question text + buttons) → taps a choice → the agent's blocking call returns that choice. Generic mechanism (any agent, any multiple-choice question), reusing what already exists.

## What already works (do not rebuild)

- **Agent tool** `ask_user_question` + `ask_question` payload (`{questionId, title, question, options:[{label, selectedLabel, value}]}`) with option normalization — `container/agent-runner/src/mcp-tools/interactive.ts`, `src/channels/ask-question.ts`.
- **Host pending-question persistence** — `pending_questions` table (`src/db/schema.ts:119`), `src/db/sessions.ts` (insert/get/delete + render-metadata resolver).
- **Host inbound routing** — ios-app-v2 `action_response` → `onAction({platform_id, envelope})` (`inbound-dispatch.ts:111`) → `onAction(questionId, selectedOption, userId)` (`index.ts:301`) → records the response (so `findQuestionResponse` returns) + clears the pending question.
- **iOS outbound** — `sendActionResponse(messageId, buttonId, label)` → `action_response{action_id, choice}` (`WebSocketClientV2.swift:377`).
- **iOS render component** — `ActionRow` + `ActionInfo` (text + buttons + answered checkmark) in `MessageRow.swift`.

## Design

The only new surface: carry `actions[]` over the v2 protocol; have the adapter populate it for `ask_question`; have iOS persist + render it and reuse the existing tap→response path. Correlation rides on the message id: the card's envelope `id` = `questionId`, so the iOS `action_response{action_id}` equals the `questionId` the host router already keys on.

### 1. Protocol — `actions[]` on the `message` payload
`shared/ios-app-protocol/v2.ts` (canonical) + `Sources/JarvisApp/Protocol/V2.swift` (Swift mirror) + the fixture contract test:
- Add to the `message` payload: `actions?: Action[]`, where `Action = { id: string, label: string, style?: "primary" | "danger" | "secondary" }`.
- `style` maps to the existing `ActionButton.Style` (default `primary`).
- Add a fixture (`shared/ios-app-protocol/fixtures/`) with a message carrying `actions`, exercised by `ProtocolFixtureTests` (Swift) so encode/decode round-trips.

### 2. Host outbound — render `ask_question` with `actions[]`
`src/channels/ios-app/v2/index.ts`, the outbound delivery (the default `data:message` build around line 528): add a branch for `contentType === 'ask_question'`:
- Emit a v2 `message` envelope with `id` = the payload's `questionId`, `text` = the question (title used as a lead line if present), and `actions` = `options.map(o => ({ id: o.value, label: o.label, style: 'primary' }))`.
- Pending-question persistence stays as-is (already happens via the host primitive); this branch only changes what the device receives. Non-question messages are unchanged (no `actions`).

### 3. iOS persistence — `actions_json` on the message row
Rendering goes through the stored row (`toChatMessage` reads from the DB via the observation), so actions must persist:
- `Storage/Schema.swift`: migration adding `actions_json TEXT` to `messages`.
- `Storage/ConversationStoreV2.swift`: `insertInbound` writes `actions_json` when the inbound `message` carries `actions`; `StoredMessage` gains `actionsJSON`; `mapRow` decodes it.
- **Answered state:** on tap, persist the chosen option id onto the row (a small `markActionAnswered(rowId:choice:)` update, mirroring the `appendAttachment` pattern) so the card stays answered after reload and can't be re-answered.

### 4. iOS render + respond
- `WebSocketClientV2.toChatMessage`: when a row has `actions_json`, build `.action(ActionInfo(text: row.text, buttons:, answered:, selectedId:))` content (text + the persisted answered state). This is the new inbound path for the dormant `ActionInfo`.
- `ActionRow` (exists) renders it. Tap → `coordinator.sendActionResponse(messageId, buttonId, label)` (exists) AND `markActionAnswered` (persist) → the card shows the checkmark.
- `action_response{action_id: messageId, choice: buttonId}` flows to the host's existing `onAction` → the blocking `ask_user_question` returns `choice`.

### 5. Decode-shape note
`StoredAttachment`-style: actions persist as a small `[StoredAction]` (`{id, label, style}`) JSON, distinct from the wire `V2.Action` (kept minimal). `ActionInfo` is built from the stored actions + the row text + answered state.

## Error handling / edge cases

- **Question times out server-side** before the user taps → the host's `findQuestionResponse` already returned (timeout); the late `action_response` is a no-op there. The card still marks answered locally (harmless).
- **Reload mid-question** → the card re-renders from `actions_json` with its persisted answered state; an unanswered card stays tappable (a late answer is the no-op above).
- **Message with no `actions`** → unchanged plain text/attachment rendering.

## Testing

- **Protocol:** fixture round-trip — a `message` with `actions[]` encodes/decodes (Swift `ProtocolFixtureTests`; TS schema parse).
- **Host (vitest):** the ios-app-v2 outbound maps an `ask_question` row → a v2 `message` with `id == questionId` and `actions` mapped from options; a normal message has no `actions`.
- **iOS (XCTest):** `toChatMessage` builds `.action` content from a row with `actions_json` (with + without persisted answered state); `insertInbound` persists `actions_json`; `markActionAnswered` updates the row.
- **Manual device:** agent `ask_user_question` → card with buttons appears → tap → agent receives the choice; card shows answered; survives reload.

## Affected files

| File | Change |
|------|--------|
| `shared/ios-app-protocol/v2.ts` | `actions?` on `message` payload + `Action` type. |
| `shared/ios-app-protocol/fixtures/…` | New fixture: message with actions. |
| `Sources/JarvisApp/Protocol/V2.swift` | Mirror `actions` + `V2.Action`. |
| `src/channels/ios-app/v2/index.ts` | Outbound `ask_question` → v2 message with `actions[]`, `id = questionId`. |
| `Storage/Schema.swift` | Migration: `actions_json` column. |
| `Storage/ConversationStoreV2.swift` | Persist/read `actions_json`; `markActionAnswered`; `StoredMessage.actionsJSON`; `mapRow`. |
| `Models/StoredAction.swift` | **New** — `[StoredAction]` persistence shape. |
| `Services/WebSocketClientV2.swift` | `toChatMessage` builds `.action` from `actions_json`. |
| `Components/MessageRow.swift` | `ActionRow` reused; tap also calls `markActionAnswered` (via callback). |
| Tests | protocol fixture, host outbound, iOS mapping + persistence. |

Version bump + `xcodegen generate` per the iOS rule when it lands.

## Non-goals

- B2 (workout plan inline card + Start button) — separate spec.
- Free-form text replies — multiple-choice only (`ask_user_question`'s contract).
- New agent tooling — `ask_user_question` already exists.
- Changing other channels' question rendering.
