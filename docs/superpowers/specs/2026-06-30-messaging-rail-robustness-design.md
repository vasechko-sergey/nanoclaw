# Messaging-rail robustness — design (build 77)

**Date:** 2026-06-30
**Status:** Approved (design), pending implementation plan
**Topic:** Two no-APNs messaging-rail bugs found in production after build 76 install — (A) foreground WS reconnect hangs, (B) a backgrounded message can be notified but never rendered into the chat.

## Problem / context

The iOS app uses a no-APNs design (free Personal Team `24Z6S27D7U`): a WebSocket while foreground, and a background self-wake **pull** (`GET /ios/pending` → `PendingNotifications.drain`) that raises local notifications. Two real failures surfaced on 2026-06-30:

**A. Foreground reconnect hangs.** After backgrounding then re-opening the app, the socket often does not reconnect — it "hangs in a timeout, doesn't even try," and only a manual Settings→connect (a couple times) recovers it.

**B. Lost message.** Jarvis's "Auth DSM recap" (jarvis headless seq 135) was delivered to the device as seq 725 at 08:32 while the app was backgrounded on build 74. A notification fired (pull path), but the message never appeared in the chat. Host evidence: `receipts` has `delivered` for `msg-…npic31` but no `read`; the device authed with `lastSeenInbound=725` so the server won't re-deliver it over WS; `outbound_queue` is empty. The pull path notifies but does not render; the chat row comes only from the WS path, which never landed it.

Both live in the same delicate transport core (`TransportV2`, `WebSocketClientV2`, `URLSessionWebSocket`, `PendingNotifications`) that has regressed repeatedly (see [[project_ios_notifications]] build 70/72 history).

## Goals

- Foreground reconnect is prompt and automatic — no manual Settings→connect.
- A backgrounded message is never permanently stranded: if it's notification-worthy, it lands in the chat.
- `isConnected` reflects reality after a background→foreground cycle.

## Non-goals

- APNs (impossible on a free Personal Team).
- A sustainable background WebSocket (not viable; pull remains the background path).
- Rich (attachment/image) rendering via the pull path — pull renders text; the WS path stays authoritative for attachments.

## Component A — Reliable foreground reconnect

Files: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift`, `Services/WebSocketClientV2.swift`.

`TransportV2.State` is `.idle | .connecting | .authed | .reconnecting(delaySeconds:)`. Three confirmed defects + fixes:

**Defect 1 — `state` stranded at `.connecting`.** `connect()` sets `state = .connecting` (line ~92) before `await socket.connect()` + `sendEnvelope(auth)`. A socket resumed while backgrounded can hang with no `onClose` and no `auth_ok` → `state` stays `.connecting` forever → the reentrancy guard `if state == .connecting || state == .authed { return }` (line ~91) makes every later `connect()` (including manual) a silent no-op.

Fix:
- Wrap the open+auth in do/catch; on throw, reset `state = .idle` (so a failure never strands `.connecting`).
- Add an **auth watchdog**: when `connect()` enters `.connecting`, capture a token (e.g. an incrementing `connectGeneration: Int`); schedule `Task.sleep(~8s)`; if still `.connecting` for the same generation (auth never arrived), reset `state = .idle` and `scheduleReconnect()`. The generation guard prevents a stale watchdog from killing a later healthy connection.

**Defect 2 — intentional `disconnect()` re-arms a reconnect.** `disconnect()` sets `state = .idle`, cancels `reconnectTask`, and `socket.close()`. `close()` cancels the URLSession task → the receive loop errors → `fireCloseOnce` → `onClose` → `handleSocketClose`. With `state == .idle` (not `.reconnecting`), `handleSocketClose` proceeds to set `.reconnecting` + schedule a new `reconnectTask` and bump `reconnectAttempt`. So a deliberate disconnect silently re-arms the loop and inflates backoff toward the 60s cap.

Fix:
- `handleSocketClose`: early-return when `state == .idle` — an intentional disconnect must not auto-reconnect. (Keep the existing `if case .reconnecting = state { return }` coalesce.)

**Defect 3 — `isConnected` not updated on foreground reconnect.** `WebSocketClientV2.connect(settings:)` sets `isConnected` from the result (lines ~197/204), but `handleScenePhase(.active)` calls `transport.connect()` in a bare `Task` and never updates `isConnected`. So a successful background→foreground reconnect leaves the observable (and the UI) showing offline; Settings→connect is the only thing that flips it.

Fix:
- `handleScenePhase(.active)`: force a **clean** reconnect, then reflect state:
  - `await transport.disconnect()` (→ `.idle`, cancels pending reconnect, closes socket),
  - `await transport.resetReconnectBackoff()` (new tiny actor method: `reconnectAttempt = 0`),
  - `await transport.connect()`,
  - set `self.isConnected = (await transport.isAuthed())` (new actor read), then `tickDispatcher()`.
  - This clears any stuck `.connecting`/pending `.reconnecting`, guarantees the reentrancy guard passes, restarts backoff fresh, and updates the UI.
- Also make the transport publish auth state changes so `isConnected` tracks later drops/reconnects, not just the foreground moment. Minimal approach: an `onStateChange` / `onAuthed` callback the facade wires (set `isConnected` true on `.authed`, false on `.reconnecting`/`.idle`). This subsumes the manual set above and keeps the UI honest across the whole session.

**Ordering note:** `handleScenePhase` fires from `JarvisApp.onChange(scenePhase)`; `.background` already calls `disconnect()`. With Defect-2 fixed, `.background` cleanly parks at `.idle` (no churn), and `.active` does the clean reconnect.

## Component B — Pull path renders the message

Files: host `src/channels/ios-app/v2/http-handler.ts`; iOS `Services/PendingNotifications.swift`, `Storage/ConversationStoreV2.swift`.

**Host — `/ios/pending` carries render fields.** The response map currently returns `{ id, seq, type, agent_id, text }`. Add `thread_id`, `ts`, `has_attachments` parsed from `payload_json` (the `message` envelope payload carries `thread_id`; `attachments` presence → `has_attachments`; `ts` from the row's `created_at` or the envelope ts). Backward-compatible additive fields.

**iOS — `drain()` renders text messages.** In `PendingNotifications.drain()`, for each message row:
- `type == "summary_ready"` → `raiseSummaryReady` (unchanged).
- else (agent message):
  - notify via `raise(...)` (unchanged), AND
  - if `has_attachments == false` and `thread_id != nil`: persist the chat row idempotently via a new store method `insertInboundFromPull(id:threadId:agentId:text:seq:ts:)` (`INSERT OR IGNORE`, `dir = .in`, `status = .delivered`). Row identity = the message `id`, matching what the WS path's `insertInbound` uses, so a later WS delivery is a no-op (`INSERT OR IGNORE`) and the WS path still records dedup + advances the cursor normally.
  - with attachments → notify only (WS renders the rich version; a text-only pull insert would strand the attachment under `INSERT OR IGNORE`).

`insertInboundFromPull` does NOT advance `lastSeenInbound` and does NOT `recordDedup` — only the WS path owns the cursor + dedup. This guarantees: (1) the message is rendered even if WS never re-delivers it; (2) if WS does deliver, it's idempotent.

**Why not "fix the cursor so WS re-delivers"?** The cursor advanced past 725 on the device; making the server re-deliver `delivered`-but-not-`read` messages would change the protocol's cursor contract and risk re-delivery storms. Rendering on the pull path is local, additive, and closes the gap without protocol changes.

## Error handling / edge cases

- **Pure-attachment message (no caption) stranded via pull:** notify-only (has_attachments=true); renders when WS reconnects. Accepted — rare, and not a text loss.
- **Watchdog vs slow auth:** the generation token ensures the watchdog only resets the connection it was scheduled for; a later healthy `.authed` is untouched.
- **Double reconnect (pending `reconnectTask` + foreground clean reconnect):** the foreground path cancels the pending task via `disconnect()` before connecting; the reentrancy guard prevents overlap.
- **`drain()` insert before the store/timeline exists:** drain runs in background self-wake after `AppV2Bootstrap`; the store is available. If not, the insert is a guarded no-op (notify still fires).

## Testing

Host (vitest): `/ios/pending` returns `thread_id`/`ts`/`has_attachments`; a `summary_ready` row and a `message` row both surface their fields; a message with attachments sets `has_attachments=true`.

iOS (XCTest, `@testable import Jarvis`):
- `TransportV2`: `connect()` failure path resets `state` to `.idle` (injectable failing `WebSocketLike`); `handleSocketClose` no-ops when `state == .idle`; watchdog resets a stuck `.connecting` after the interval (inject a socket that never auths + a short watchdog interval); `resetReconnectBackoff`/`isAuthed` behave.
- `WebSocketClientV2`: `handleScenePhase(.active)` drives disconnect→connect and sets `isConnected` on auth (fake transport/stack).
- `PendingNotifications`: a no-attachment message row → `insertInboundFromPull` called (route assertion at the decode/dispatch seam, mirroring the existing summary test limitation); attachment row → notify only.
- `ConversationStoreV2`: `insertInboundFromPull` inserts a text row idempotently (second call / later `insertInbound` with same id = no duplicate).

## Files touched

Host:
- `src/channels/ios-app/v2/http-handler.ts` — `/ios/pending` map adds `thread_id`/`ts`/`has_attachments`.
- `src/channels/ios-app/v2/http-routes.test.ts` — extend pending assertions.

iOS (`ios/JarvisApp/Sources/JarvisApp/`):
- `Services/TransportV2.swift` — connect reset-on-failure + auth watchdog + `handleSocketClose` idle-guard + `resetReconnectBackoff()` + `isAuthed()` + state-change callback.
- `Services/WebSocketClientV2.swift` — `handleScenePhase(.active)` clean reconnect + `isConnected` wiring.
- `Services/PendingNotifications.swift` — `PendingMessage` gains `thread_id`/`ts`/`has_attachments`; `drain()` inserts text rows.
- `Storage/ConversationStoreV2.swift` — `insertInboundFromPull(...)`.
- Tests: `TransportV2*Tests`, `WebSocketClientV2Tests` (or new), `PendingNotificationsTests`, `ConversationStoreV2Tests`.
- `project.yml` — build 77 / 1.19.0 (single final bump).

## Out of scope / future

- APNs; sustainable background WS.
- Rich pull rendering (attachments).
- A deeper investigation of *why* seq 725's WS render was skipped (cursor advanced without insert) — the pull-render fix makes it moot; if it recurs for text, revisit the WS dedup/cursor interaction.
