# Сводка-ready notification — design

**Date:** 2026-06-30
**Status:** Approved (design), pending implementation plan
**Topic:** Notify the iOS user once the morning dashboard cards have formed.

## Problem / context

Jarvis's morning brief is now a silent card-only publish (no DM) — see
`docs/superpowers/specs/2026-06-29-dashboard-content-tweaks-design.md` and the
2026-06-30 trims. Removing the DM also removed the only morning **notification**:
the user no longer learns that the day's Сводка is ready. We want a single
lock-screen notification once the cards have formed, that opens the Сводка board.

All five agents (jarvis `morning-brief`, greg/gordon/payne/scrooge `publish`) fire
on the **same** cron — `45 8 * * *` in the agent TZ (Asia/Makassar / WITA, 00:45
UTC). The spread is run-duration, not schedule: each publish run takes ~1–5 min and
they all wake in one host sweep, so cards land within a short window (~08:46–08:52).

## Goals

- One grouped notification per morning: "Сводка готова · N карточек".
- Fires after the batch has **settled**, adapting to the actual (small) spread.
- True notification: **no chat bubble**; tapping opens the Сводка board.
- Respects quiet hours; independently muteable.
- Once per day; manual midday republishes never fire it.
- **Bonus (same nav plumbing):** tapping a **chat** (agent-message) notification deep-links straight into that agent's chat, instead of just opening the app. Today the default tap does nothing.

## Non-goals (v1)

- No per-agent breakdown in the notification (count only; detail lives in the board).
- No notification for ad-hoc/manual card refreshes outside the morning window.
- Owner device(s) only. Multi-person (Лена) uses the same mechanism later — no redesign.

## Architecture / data flow

```
08:45 cron → 5 agents write memories/public.md
        │
        ▼
host-sweep (60s) → projectAllPublicProfiles() → profiles/<agent>.md   [mtime = "card formed"]
        │                                            (hash-gated write; public-profiles.ts:34-97)
        ▼
summary-notify detector (new module, called from host-sweep.ts:141 right after projection)
   reads profiles/<agent>.md mtimes; debounce inside morning window; once/day
        │  fire
        ▼
adapter.sendEnvelopeToDevice(platform_id, {type:'summary_ready', ...})  [ws-handler.ts:114]
   → outbound_queue (notify type) → WS push (live) and/or GET /ios/pending (background pull)
        │
        ▼
iOS: dispatch summary_ready → LocalNotifier (NotificationGating: quiet hours + «Сводка» toggle)
   → local notification "Сводка готова · N карточек"  (NOT inserted into chat)
   → tap → nav flag → OrbHomeView presents StateBoardView sheet
```

## Component 1 — Host: settle detector

New module `src/modules/summary-notify/` with a **pure decision function** + a thin
host glue that reads mtimes and emits.

**Hook:** in `src/host-sweep.ts` immediately after `projectAllPublicProfiles(...)`
(currently line ~141). The sweep already runs every 60s, which is the detector tick.

**Decision function (pure, unit-tested):**

```
decideSummaryNotify(input) -> { fire: boolean, count: number }

input = {
  nowMs,                       // current time
  tz,                          // person TZ, e.g. "Asia/Makassar"
  cardMtimesMs: number[],      // mtime of each profiles/<agent>.md
  lastNotifiedDate: string|null, // "YYYY-MM-DD" in person TZ, persisted
  cfg: { windowStart: "08:40", windowEnd: "09:15", quietMs: 180_000 }
}
```

Logic, per person, each sweep:
1. Compute today's date in `tz`. If `lastNotifiedDate === today` → `{fire:false}`.
2. `morningCards` = cards whose mtime falls in `[today windowStart, today windowEnd]`.
3. If `morningCards.length === 0` → `{fire:false}`.
4. `settled` = `nowMs - max(morningCards.mtime) >= quietMs` (no new card for ~3 min).
5. `pastDeadline` = `now >= today windowEnd` (slow/dead agent fallback).
6. `fire = settled || pastDeadline`; `count = morningCards.length`.

**State / persistence:** only `lastNotifiedDate` per person must survive restarts
(prevents double-fire). Everything else is derived from file mtimes each sweep, so a
mid-morning host restart simply re-derives and still fires once. Store in central DB
via a new migration:

```
CREATE TABLE summary_notify_log (
  person_key TEXT PRIMARY KEY,
  last_notified_date TEXT NOT NULL   -- "YYYY-MM-DD" in person TZ
);
```

(Migration in `src/db/migrations/`.) On fire, upsert `(person_key, today)`.

**Why mtime, not the `updated:` field:** `updated:` is date-only (no time), unusable
for intra-morning debounce. `profiles/<agent>.md` mtime is set by the hash-gated
projection write (`public-profiles.ts`), i.e. exactly when the card content changed —
the "card formed" instant. Daily the `updated:` date flips, so content always changes
in the morning → projection rewrites → fresh mtime. Identical-content reruns are
hash-gated (no rewrite, no stale trigger) — acceptable.

**Target resolution:** emit to the person's registered `ios-app-v2` device(s). v1 the
only iOS person is the owner (Сергей); the detector iterates `data/user-memory/<person>`
and emits for the person who owns the cards. Multi-person later keys devices by owner.

**Emit:** build the envelope and call the ios-app-v2 adapter's
`sendEnvelopeToDevice(platform_id, envelope)` (`src/channels/ios-app/v2/ws-handler.ts:114`)
for each target device. This enqueues to `outbound_queue` and pushes if the socket is
live; the background-pull path picks it up otherwise.

## Component 2 — Protocol: `summary_ready` envelope

`shared/ios-app-protocol/v2.ts` (Zod, canonical) + Swift mirror `Protocol/V2.swift`.

- New member of the envelope union: `type: 'summary_ready'`, `kind: 'data'`,
  `payload: { date: string /* YYYY-MM-DD */, count: number }`.
- Add `'summary_ready'` to `NOTIFY_TYPES` (`src/channels/ios-app/v2/types.ts`) so
  `listPendingNotify` returns it on `GET /ios/pending` and it rings while backgrounded.
- Stable envelope `id = "summary-<person_key>-<YYYY-MM-DD>"` → device dedup
  (`inbound_dedup`, by id) collapses a double delivery (WS + pull) into one ring.
- `GET /ios/pending` returns `{id, seq, agent_id, text}` today; for `summary_ready`
  set `text = "Сводка готова · <count> карточек"` and `agent_id = "jarvis"` (icon),
  composed at enqueue time so the pull path needs no special-casing for the body.

## Component 3 — iOS handling

- `Protocol/V2.swift`: decode the `summary_ready` case.
- Dispatch (`TransportV2` / inbound handling): on `summary_ready` **do not** insert
  into `ConversationStoreV2` (no chat bubble). Instead hand to `LocalNotifier`.
- `LocalNotifier` + `NotificationGating` (build 75): schedule a local notification
  "Сводка готова · N карточек", gated by quiet hours **and** a new dedicated «Сводка»
  toggle (independent of per-agent mute). Dedup by the stable id (don't double-schedule
  if both WS and pull deliver). New `UNNotificationCategory` `summary-ready`.
- Tap → opens the Сводка board (see Component 5 — Deep-link navigation).
- Settings: add «Сводка» row under «Уведомления».
- Version: bump `CURRENT_PROJECT_VERSION` (+ `MARKETING_VERSION` for the feature),
  `xcodegen generate`, commit the regenerated `pbxproj`.

## Component 4 — Gating

Reuse build-75 `NotificationGating`. The summary is not per-agent, so it is **not**
subject to per-agent mute. It is subject to: quiet hours, and a new «Сводка» on/off
toggle persisted in the same notification-settings store.

## Component 5 — Deep-link navigation (shared)

Today notification taps don't navigate: the default tap just calls `completionHandler()`
(reply-action excepted). The nav we add for the summary board generalizes into a single
deep-link mechanism, and we reuse it so a **chat** notification tap drops straight into
that agent's chat.

Opening an agent's chat requires two writes: `ActiveAgentState.active = <agent>` and
`ContentView.appPhase = .chat`. The board requires `appPhase = .home` + `OrbHomeView`'s
`showStateBoard = true`. These live in separate state objects, so we route both through
nav-intent flags on the already-`@Observable` `AppCoordinator` (injected into
`ContentView`):

- `AppCoordinator.pendingOpenSummaryBoard: Bool`
- `AppCoordinator.pendingOpenAgentChat: AgentIdentity?`

Flow:
1. `AppDelegate.didReceive` (tap): reply-action path unchanged. Otherwise branch on
   `categoryIdentifier`: `summary-ready` → `AppDelegate.openSummaryBoard?()`;
   `agent-message` (default tap) → `AppDelegate.openAgentChat?(agentId)` (agentId from
   `userInfo`, mapped via `AgentIdentity(rawValue:)`). These static hooks are wired by
   `AppCoordinator` at init (same pattern as the existing `dispatchProactive` hook) to set
   the two flags on the main actor.
2. `ContentView` observes both flags (and re-applies on the splash→connected transition so
   a **cold launch** from a tap still navigates): `pendingOpenAgentChat` → set
   `active.active` + `appPhase = .chat`; `pendingOpenSummaryBoard` → `appPhase = .home`
   (so `OrbHomeView` is mounted). Clear each flag after applying.
3. `OrbHomeView` opens the board: `.onAppear` + `.onChange(of: coordinator.pendingOpenSummaryBoard)`
   → `showStateBoard = true`, then clears the flag (covers both "already true at mount"
   from a cold launch and "becomes true while mounted").

Chat notifications already carry `userInfo["agentId"]`. `AgentIdentity(rawValue:)` maps
the slug (`jarvis`/`payne`/`greg`/`scrooge`/`gordon`) to the enum; unknown slug → no-op.

## Error handling / edge cases

- **Agent dies / never publishes:** deadline (`09:15`) fires with whatever landed; `count`
  reflects only formed cards. Cards that arrive after the fire are not re-notified.
- **Host restart mid-morning:** re-derives from mtimes; `lastNotifiedDate` prevents
  double-fire if already sent.
- **Socket offline at fire:** envelope enqueued; delivered on reconnect or next pull.
- **Manual midday republish (e.g. ops trigger):** mtime outside morning window → ignored.
- **Quiet hours / toggle off:** iOS suppresses the local notification (the card data
  still updates `/ios/state`; only the ring is gated).
- **DST / TZ:** window evaluated in the person TZ each sweep; no stored wall-clock.

## Testing

- **Host (vitest):** `decideSummaryNotify` pure-function table — before-window,
  in-window-not-settled, settled, past-deadline, already-notified-today, zero-cards,
  TZ boundary. No DB, no clock dependency (inject `nowMs`).
- **Host (vitest):** migration applies; upsert idempotent.
- **Protocol:** `summary_ready` Zod parse round-trip; rejects bad payload.
- **iOS (XCTest, `@testable import Jarvis`):** `summary_ready` routes to notifier and
  **not** to the conversation store; gating respects quiet hours + «Сводка» toggle; tap
  flag flips board presentation. Verify via unit tests + clean build — no prod-token run.

## Files touched (anchors verified)

Host:
- `src/host-sweep.ts` (~141) — call detector after `projectAllPublicProfiles`.
- `src/modules/summary-notify/` — new: pure decision + glue + reads `profiles/<agent>.md` mtimes + emit. (`public-profiles.ts` unchanged — detector reads mtimes directly.)
- `src/db/migrations/` — new migration for `summary_notify_log`.
- `src/channels/ios-app/v2/types.ts` — add `summary_ready` to `NOTIFY_TYPES`.
- `src/channels/ios-app/v2/ws-handler.ts` (114) — emit path (reuse `sendEnvelopeToDevice`).
- `src/channels/ios-app/v2/http-handler.ts` (383) — `/ios/pending` carries `summary_ready` text.
(Host `inbound-dispatch.ts` is device→host and not on this path; device-side dedup-by-id lives in iOS — Component 3.)

Protocol:
- `shared/ios-app-protocol/v2.ts` — `summary_ready` envelope.

iOS (`ios/JarvisApp/Sources/JarvisApp/`):
- `Protocol/V2.swift` — decode `summary_ready` case.
- `Services/TransportV2.swift` — route `summary_ready` to notifier, not chat.
- `Services/LocalNotifier.swift` + `Models/NotificationGating.swift` — schedule + gate (+ «Сводка» toggle closure).
- `Services/NotificationCategories.swift` — `summary-ready` category.
- `Models/AppSettings.swift` — `summaryNotificationsEnabled`.
- `Views/SettingsView.swift` — «Сводка» toggle row.
- `Services/AppCoordinator.swift` — `pendingOpenSummaryBoard` + `pendingOpenAgentChat` intents + hook wiring.
- `JarvisApp.swift` — `AppDelegate` `didReceive` routing (summary tap + chat default-tap) + static hooks.
- `Views/ContentView.swift` — observe intents → `appPhase`/`ActiveAgentState` (incl. cold-launch apply).
- `Views/OrbHomeView.swift` — open `StateBoardView` sheet on the board intent.
- `project.yml` — version bump; regenerate pbxproj.

## Out of scope / future

- Лена / multi-person fan-out (mechanism already per-person).
- Notification on manual full-refresh.
- Per-agent lines or rich content in the notification body.
