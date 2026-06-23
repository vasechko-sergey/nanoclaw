# iOS Message Edit (by id) — Design

**Date:** 2026-06-23
**Status:** Approved (design), pending implementation plan

## Problem

Agents already try to correct a message they sent by emitting `{"operation":"edit","messageId":…,"text":…}` (the `edit_message` MCP tool exists, `core.ts:249-287`). But the **ios-app-v2 channel does not handle edit** — no host dispatch, no WS envelope type, no iOS handler — so the operation is silently dropped and the user keeps the stale message. Surfaced live: the factuality gate caught a fabricated prose claim, the agent tried to fix it via edit, the edit no-op'd, the user still saw the wrong text.

Two gaps compound it: (1) edit isn't wired through any layer for ios-app-v2; (2) the agent isn't told the capability exists or how to target a message, so it free-formed a `messageId` (a stray UUID) instead of using the tool.

## Goal

An agent can edit the text of a message it previously sent on ios-app-v2; the iOS app updates that message in place (by id), marks it edited, and re-renders. Agents are told the capability exists and exactly what to pass.

## How ids line up (from the codebase map)

- Agent outbound is written to `messages_out` with a host id `msg-<ts>-<rand>` and an odd `seq`.
- `delivery.ts:389-392` stamps that `msg-…` id into the ios-app-v2 envelope `content.id`; the iOS app stores the message under that **same** id (`ConversationStoreV2.insertInbound`, `id: envelope.id`). **So the host `msg-…` id IS the iOS row id** — editing by it is a direct `UPDATE … WHERE id = ?`.
- The agent references its own message by **seq**; `getMessageIdBySeq(seq)` (`messages-out.ts:138-161`) resolves seq → the `msg-…` id (via the `delivered` table). The `seq` is returned to the agent by the `send_message` MCP tool.

## Decisions (locked)

| Question | Decision |
|----------|----------|
| WS envelope | **New explicit type `update`** (`{ id, text }`) — server→app, in the discriminated-union protocol (TS canonical + Swift + fixtures). Not a payload marker on `message`. |
| Targeting | Agent edits by **seq** via `edit_message`. `seq` omitted ⇒ edit the agent's **most recent user-facing outbound** this session (the "fix what I just said" case, no id needed). Explicit `seq` (from `send_message`) edits an older one. Host resolves seq → `msg-…` id. |
| iOS behavior | `ConversationStoreV2.updateMessageText(id, text)` (GRDB `UPDATE`), set an `edited` flag; SwiftUI re-renders via existing `ValueObservation`. Bubble shows a small **"(ред.)"** marker. |
| Scope | Only the agent's own (outbound) messages on **ios-app-v2**. Other channels unchanged. |
| Failure semantics | Best-effort: no ack back to the agent; an unknown/expired id is a silent no-op on the device. |
| Agent docs | The `edit_message` tool description + a line in `groups/INSTRUCTIONS.md`: you can edit a message you sent — call `edit_message` with the new full text (and a `seq` only to target an older message); **never invent a messageId**. |

## Architecture / flow

```
agent: edit_message(seq?, text)            (container MCP tool — exists)
  └─ resolve seq → msg-id (or "last user-facing outbound" if seq omitted)
  └─ writeMessageOut { operation:"edit", messageId: msg-id, text }   (outbound.db)
        ▼ host delivery.ts polls outbound.db
host ios-app-v2 adapter (index.ts deliver):
  detect content.operation === "edit"
  └─ enqueue WS envelope { v:2, kind:"data", type:"update", id: messageId, payload:{ text } }
        ▼ WebSocket
iOS TransportV2.handleIncoming:
  case .update → ConversationStoreV2.updateMessageText(id, text, edited:true)
  └─ GRDB UPDATE messages SET text=?, edited=1 WHERE id=?
  └─ ValueObservation → SwiftUI re-render, bubble shows "(ред.)"
```

## Components

### 1. WS protocol — new `update` type
- `shared/ios-app-protocol/v2.ts` — add `update` to the type union + an `{ id: string; text: string }` payload shape; add a fixture under `shared/ios-app-protocol/fixtures/`.
- `ios/.../Protocol/V2.swift` — add `TypeTag.update`, a `Payload.update(Update)` case with `struct Update { let id: String; let text: String }`, and the `init(from:)` decode case (V2.swift:535-590).
- Keep `seq`/envelope framing consistent with `message` (it rides the same `data` kind + seq allocation).

### 2. Host ios-app-v2 adapter — dispatch `edit`
- `src/channels/ios-app/v2/index.ts` `deliver()` (~498-654): before the default message-envelope branch, detect `content.operation === "edit"` (parsed from the messages_out row) and build the `update` envelope (`id = content.messageId`, `payload.text = content.text`) instead of a normal `message`. Route through the same outbound queue / seq allocation as other envelopes.
- Confirm `delivery.ts` passes the `{operation:"edit",…}` content through unchanged to the adapter (it already passes content opaque).

### 3. iOS app — update in place
- `ConversationStoreV2.swift` — add `updateMessageText(id:String, text:String)` → `UPDATE messages SET text = ?, edited = 1 WHERE id = ?`. Add an `edited: Bool` column (migration) on `StoredMessage`.
- `TransportV2.swift` `handleIncoming` (~160-202) — route the new `update` envelope to `updateMessageText`.
- Message bubble view — render a subtle "(ред.)" suffix when `edited`.
- **Version bump:** `CURRENT_PROJECT_VERSION` (+ MARKETING for the feature) + `xcodegen generate` + commit the pbxproj — per the iOS build rule. Build/install on iPhone is the operator's.

### 4. Agent tool + docs (the part to make it usable & discoverable)
- **First verify the tool is actually exposed to the agent** — `edit_message` exists in `core.ts` but the agent free-formed a UUID instead of calling it, which suggests it may not be registered in the MCP server's tool list (`mcp-tools/server.ts` / `index.ts`) or its description is missing. If unregistered, register it; that alone is likely why the 867B incident happened.
- `edit_message` (core.ts): make `seq` **optional** — when omitted, resolve to the agent's most recent user-facing outbound row in this session (query `messages_out` for the latest user-facing seq). Keep explicit `seq` for older targets. Validate that the resolved id exists; on miss, return a clear error to the agent (don't emit a dead edit).
- Tool **description** (and `core.instructions.md`): "Edit a message you already sent on iOS — pass the corrected full text; pass `seq` only to target an older message (the `seq` returned by `send_message`). Editing replaces the whole message. Do not invent a messageId."
- `groups/INSTRUCTIONS.md` (shared, all agents): one line under outbound discipline — corrections to a message you JUST sent should use `edit_message` (it edits your last message), not a fabricated edit envelope.

## Protocol versioning

Single operator (Сергей), single app build — backward compat is moot; he rebuilds the app with the new `update` type. But keep the TS canonical, Swift, and fixtures **in lockstep** (the fixture contract test enforces it). An older app receiving an unknown `update` type should ignore it gracefully (decode default case → drop), not crash — verify the Swift decoder's unknown-type handling.

## Verification

- **Host (vitest):** ios-app-v2 `deliver()` with `{operation:"edit", messageId, text}` → emits an `update` envelope (id + text), not a `message`. seq resolution: `edit_message` omitted-seq → last user-facing outbound (container bun:test on the resolver).
- **Protocol:** fixture round-trips (TS encode ↔ fixture ↔ Swift decode) for `update`.
- **iOS (XcodeBuildMCP sim):** decode an `update` envelope → message text changes in place + "(ред.)" shows; build succeeds on simulator.
- **Live (operator):** agent sends a message, then `edit_message` with new text → the existing bubble updates on the iPhone (not a new message), marked edited.

## Non-goals
- Editing the user's own messages, or messages on other channels (Telegram already supports edit natively; out of scope here).
- Deleting messages; threaded edits/history; ack-back to the agent.
- Using edit as the factuality gate's correction path (the gate suppresses pre-delivery; edit is a general capability).

## Open defaults (flag at review)
- `edit_message` omitted-seq ⇒ "last user-facing outbound" (vs requiring explicit seq always).
- "(ред.)" marker shown (vs silent in-place update).
- New `edited` column via a small GRDB migration (vs reusing an existing field).
