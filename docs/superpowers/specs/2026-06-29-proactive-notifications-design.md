# Proactive Notifications (local-notif, no-push) — Design

**Date:** 2026-06-29
**Status:** Approved design → ready for implementation plan
**Scope:** Make Jarvis's (and any agent's) messages surface as iOS lock-screen
notifications when the app is not foregrounded — **without APNs**, using only
local notifications raised on-device.

This is the first of four independent sub-projects discussed (proactive
notify/wake → Telegram-as-user → Instagram → email reply flow). Each gets its
own spec/plan/build cycle. This doc covers **only** proactive notify/wake.

---

## 1. Problem

Jarvis already produces proactive output (morning brief, watches, alerts) and
normal replies. When the app is **not foreground-active**, those messages land
silently:

- An incoming `message` envelope is stored in chat but **no local notification
  is raised** — the user never learns it arrived until they open the app.
- `WebSocketClientV2.handleScenePhase(.background)` is a **no-op**
  (`src/.../WebSocketClientV2.swift:378`) — on background wakes the app does not
  reconnect, drain the queue, or notify.

APNs is **not available**: the app is signed with a free Personal Team
(`24Z6S27D7U`, `vasechkoss@gmail.com`), which has no push entitlement. The
declared `remote-notification` UIBackgroundMode is therefore inert. Local
notifications (no paid account required) are the only path.

## 2. Decisions (locked)

| Fork | Decision |
|------|----------|
| **Notification policy** | **Messenger model.** Every user-facing agent message raises a local notification when the app is not foreground-active. No new judgment mechanism — Jarvis's existing proactive discipline (3–4/day cap, 23:00–08:00 quiet hours) bounds frequency. |
| **Reach** | **Self-wake drain, no push.** The app reconnects/pulls and raises local notifs on iOS-initiated background ticks (HealthKit background-delivery, BGProcessing, BGAppRefresh). Reach = "within the next background tick" (minutes during an active day with Apple Watch HR; worse when idle/asleep). App killed → missed, accepted. |
| **Notification dedup** | On-device, via extending the existing `inbound_dedup` table with `notified_at`. No server-side notified tracking. |
| **Background pull** | One shared `PendingPuller` invoked by all three background sources, hitting a new read-only `GET /ios/pending` (and optionally piggybacked on the existing `POST /ios/health/upload` response). |
| **Foreground flag** | Lives in `AppCoordinator` (`isForegroundActive`), set from `handleScenePhase`. |

## 3. Architecture & data flow

Local notifications only. Two delivery paths, device-side dedup.

```
Jarvis emits user-facing <message>   (existing path, UNCHANGED)
   outbound.db → host delivery.ts → ios-app-v2 adapter → sendEnvelopeToDevice
        │
        ├── WS connected ───────────► live push over WS
        │                              device: scenePhase != .active → local notif (dedup by id)
        │                                      scenePhase == .active  → render in chat, no notif
        │
        └── device offline ─────────► outbound_queue (existing)
                                        drained later by:
                                        (A) WS reconnect on app open → render in chat (+ notif if not active)
                                        (B) background self-wake tick → GET /ios/pending → local notifs
```

**Self-wake ticks** (no push, free-tier OK):

- **HealthKit background-delivery** — HR/workout `immediate`, sleep/steps
  `hourly`. Already firing; already issues `POST /ios/health/upload`. Frequent
  during an active day.
- **BGProcessingTask** — ~08:00 morning floor. Already registered
  (`HealthBackgroundTask`).
- **BGAppRefreshTask** — periodic, iOS-throttled. **New**, lightweight.

On each tick → app calls `PendingPuller.pull()` → `GET /ios/pending?since=<cursor>`
→ for each user-facing message not yet notified → raise local notif → mark
notified.

**Reused as-is:** `outbound_queue` + drain, local-notif build pattern
(`RestTimer.swift`, `CalendarManager.swift`), `AppDelegate.willPresent`
foreground presentation, the background health-upload round-trip.

**New:** `GET /ios/pending`; on-device notif-raise + dedup; `BGAppRefreshTask`
tick; scenePhase-gated foreground notif.

## 4. Components

### 4.1 Server (host, TypeScript / vitest)

| File | Change |
|------|--------|
| `src/channels/ios-app/v2/http-handler.ts` | New `GET /ios/pending[?since=<seq>]`. Resolves `platform_id` from token (never from body — existing rule, http-handler comment ~line 52). Returns queued envelopes of `NOTIFY_TYPES` with `seq > since` as JSON. **Read-only — does not consume the queue.** The WS drain remains the chat-render delivery path. |
| `src/channels/ios-app/v2/outbound-queue.ts` | `list(platform_id)` exists; add a filtered read (or filter in the handler) restricted to `NOTIFY_TYPES`. |
| `src/channels/ios-app/v2/types.ts` | `export const NOTIFY_TYPES = ['message'] as const;` (extensible later: `coach_message`, cards). |
| `src/channels/ios-app/v2/http-handler.ts:176` (optional) | Piggyback the same pending list onto the `POST /ios/health/upload` response → zero extra requests on the frequent health ticks. |

No change to `delivery.ts` (it already enqueues to `outbound_queue` on offline)
or to the agent-runner.

### 4.2 iOS (Swift / XCTest)

| File | Change |
|------|--------|
| **New** `Services/LocalNotifier.swift` | Builds + raises a `UNNotificationRequest` from a decoded message: `title = AgentIdentity(rawValue: agent_id)?.displayName` (Jarvis/Грег/Пейн/Скрудж), `body = message text` trimmed to ~160 chars (markdown stripped to plain), `threadIdentifier = agent_id` for grouping. Gated on `AppSettings.notificationsEnabled` and the notified-dedup. No-ops gracefully if notification authorization was denied. |
| `Storage/Schema.swift` | Migration: add `notified_at` to `inbound_dedup` (or a parallel `notified` set). Add store methods `notifiedSeen(id) -> Bool` and `recordNotified(id, seq)`. |
| `Services/TransportV2.swift` (`.message`, ~line 169) | After storing: if `!coordinator.isForegroundActive` && `!notifiedSeen(id)` → `LocalNotifier.raise(...)` + `recordNotified(...)`. Foreground-active → chat only. |
| `Services/AppCoordinator.swift` | Hold `isForegroundActive: Bool`, set from `handleScenePhase` (`.active` → true; `.background`/`.inactive` → false). |
| **New** `Services/PendingPuller.swift` | `pull()`: `GET /ios/pending?since=<notified-cursor>` (cursor = max notified seq, stored in `kv` or derived) → for each returned message → `LocalNotifier.raise` + `recordNotified`. Single shared instance; idempotent. |
| `Services/HealthSync.swift`, `Services/HealthBackgroundTask.swift`, **new** `BGAppRefreshTask` handler | Each background wake calls `PendingPuller.pull()`. HealthSync can read the piggybacked list from the upload response instead of a second request. |
| `Sources/JarvisApp/JarvisApp.swift` | Register + schedule `BGAppRefreshTask` alongside `HealthBackgroundTask` (`register()` before launch finishes; reschedule on `.background`). |
| `Models/AppSettings.swift` | `@AppStorage("notificationsEnabled") var notificationsEnabled = true` (master). Optional per-agent toggles later. |

## 5. Edge cases

- **Double-notify** — `notified_at` gates both paths. Live-push marks notified →
  pull skips; pull marks notified → WS drain on open renders chat but does not
  re-notify.
- **App killed** — no ticks → no pull → missed (accepted). On open, WS drain
  flushes the backlog into chat (foreground, no notif). Nothing is lost, it just
  didn't buzz.
- **Quiet hours** — no separate client gate. Proactive 23:00–08:00 is already
  suppressed by Jarvis (morning-brief skill). A direct reply at night (user
  asked) **should** buzz. iOS Focus/DND handles the rest at the system level.
- **Reach ∝ HealthKit wake frequency** — frequent daytime with Apple Watch (HR
  `immediate`), sparse when idle/asleep; `BGAppRefresh` is iOS-throttled. Honest
  limitation of the no-push model.
- **Notification authorization denied** — `LocalNotifier` no-ops; surface a hint
  in Settings.
- **Notification tap** — opens app → foreground → drain → chat. Per-agent
  deep-link on tap is **out of MVP**.
- **Queue retention** — `outbound_queue` caps at `MAX_QUEUE_PER_DEVICE` (drops
  oldest). A flood while killed drops the oldest from both notif and chat — the
  existing behavior, accepted.

## 6. Out of scope (MVP)

- APNs / silent push — impossible on the free Personal Team.
- Server-side universal quiet-hours / rate gate — rely on Jarvis doctrine + iOS
  DND.
- Notifications for non-`message` types (workout `coach_message`, cards) —
  `NOTIFY_TYPES` is extensible later.
- Per-agent deep-link on notification tap.
- Message-style copying — the user's separate task.

## 7. Doctrine note (not code)

One line in `groups/INSTRUCTIONS.md`: proactive messages now surface as phone
notifications, so the 3–4/day discipline matters more. Deployed via scp (the
`groups/` tree is gitignored), not git.

## 8. Testing

Verification is unit tests + a clean build — **not** a production-token
connection (per standing rule). Runtime behavior is exercised with stubs / a
fake transport.

**Server (vitest, `pnpm test`):** new `pending-endpoint.test.ts`:
- returns only `NOTIFY_TYPES`;
- respects `since` (returns only `seq > since`);
- scopes by token → `platform_id` (cannot read another device's queue);
- **does not consume** — the queue is unchanged after a pull.

**iOS (XCTest, `@testable import Jarvis`):**
- `LocalNotifierTests` — content (title = agent displayName, body trim),
  dedup skips an already-notified id, no-op when `notificationsEnabled == false`.
- `PendingPullerTests` — parses a `/ios/pending` response → raises N notifs →
  advances the cursor; empty response → no notif.
- `TransportV2` foreground gate — `.message` while `!isForegroundActive` →
  notifier called; while active → not called. Extends existing transport tests,
  reusing the `ProactiveSink`-style stub precedent.
- Schema migration — `notified_at` added; `notifiedSeen` / `recordNotified`
  round-trip.

**Build:** `xcodegen generate` (from `ios/JarvisApp/`) + a clean build. Bump
`CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` (new feature) and commit the
generated `pbxproj`.

**Container:** no agent-runner changes → no bun tests required.

## 9. Deploy

- Host (`src/channels/ios-app/v2/`): `pnpm run build` + git push → on VDS
  `git pull && pnpm run build && systemctl --user restart nanoclaw`.
- iOS: build → install on device.
- `groups/INSTRUCTIONS.md` doctrine line: scp to VDS (gitignored), then a live
  agent will pick it up on its next container respawn.
