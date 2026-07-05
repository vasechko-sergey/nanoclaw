# Local-Timezone Briefs Design

**Date:** 2026-07-05
**Status:** Approved (design); pending spec review → plan

## Goal

Scheduled morning reports (and every other recurring task a person owns) fire at a
**fixed local wall-clock time on the user's current device timezone**, not on the
host's single global timezone. A traveler who moves between zones gets their 09:00
brief at 09:00 wherever they physically are, without touching anything.

## Problem

Today a single global `TIMEZONE` (`src/config.ts`, from env `TZ` = `Asia/Makassar`
on the VDS) drives cron parsing in `src/modules/scheduling/recurrence.ts`. A cron
`0 9 * * *` therefore always fires at 09:00 WITA. When the user flies to another
zone, the brief keeps landing at 09:00 WITA — a different local time for them.

## Decisions (from brainstorming)

| Axis | Decision | Rationale |
|------|----------|-----------|
| **TZ source** | Auto from iPhone | Device already knows its IANA zone and already ships it on `/ios/proactive`. Zero user effort; tracks travel. No manual pin (YAGNI). |
| **Scope** | All of the person's recurring tasks | The natural fix (owner-tz in recurrence) covers everything that person owns for free. Narrowing to one task would cost *more* (per-task opt-in flag) and desync the brief from the Сводка board. |
| **Arrival-day accuracy** | May be off once, then self-corrects | Keeps the existing frozen-next-run recurrence mechanism. Only the single fire computed *before* landing is off; every day after is exact. User explicitly accepted this over the heavier live-matching rewrite. |
| **Capture path** | Piggyback existing iOS requests | Stamp tz from the background `GET /ios/pending` pull + the already-tz-carrying `/ios/proactive`. No new endpoint, no new iOS background logic. |

Semantics are **follow-the-device** (09:00 in the phone's current zone), not
anchor-to-home.

## Architecture / Data Flow

```
iPhone (TimeZone.current.identifier)
   │  tz=Europe/London  (query item on the background pending-pull URL)
   ▼
GET /ios/pending?tz=Europe/London                [host, authenticated]
   │  id.person_key from bearer token
   ▼
noteDeviceTz(person_key, tz)                       [validate IANA, upsert]
   ▼
person_tz(person_key, tz, updated_at)              [central v2.db, migration 024]
   ▲
   │  resolveOwnerTz(ownerKey) ?? global TIMEZONE
   ├── src/modules/scheduling/recurrence.ts   → cron parsed in owner tz
   └── src/modules/summary-notify/sweep.ts    → Сводка-ready window in owner tz
```

The container is **not** in this path: recurrence fires host-side before any
container runs, so the tz must live host-side. (This is why the on-demand
`request_context` option was rejected — architecturally impossible to gate
host recurrence timing on a container→device pull.)

## Storage — migration `024-person-tz`

```sql
CREATE TABLE person_tz (
  person_key TEXT PRIMARY KEY,   -- == session.owner_key / ios person_key
  tz         TEXT NOT NULL,      -- IANA identifier, validated before write
  updated_at TEXT NOT NULL       -- ISO8601; semantically "here since"
);
```

A **separate table** rather than a column on `ios_tokens`, because token re-mint
`DELETE`s the token row (`token-registry.ts:upsertIosToken`) and would drop the
tz. Decoupled from the channel and keyed by the stable `person_key`.

## New host module `src/modules/person-tz/`

### `db.ts`
```ts
export interface PersonTzRow { person_key: string; tz: string; updated_at: string }

/** Upsert last-writer-wins; only bump updated_at when the zone actually changes. */
export function upsertPersonTz(db: Database.Database, personKey: string, tz: string): void

/** Read the stored tz for a person, or null. */
export function getPersonTz(db: Database.Database, personKey: string): string | null
```

### `index.ts`
```ts
/** Record a device-reported tz. Silently ignores junk (non-IANA). Best-effort. */
export function noteDeviceTz(personKey: string, rawTz: string): void
//   isValidTimezone(rawTz) gate (reuses src/timezone.ts) → upsertPersonTz

/** Resolve a person's current tz for scheduling, or null → caller falls back. */
export function resolveOwnerTz(ownerKey: string | null): string | null
//   null ownerKey → null; stored invalid → null; else the stored tz
```

- **No staleness expiry.** Last-known location beats the home-zone guess for a
  traveler whose phone was briefly off. Only a *never-reported* person falls back.
- `noteDeviceTz` is fully guarded (validation + try/catch at call sites) — a bad
  tz value must never break request handling.

## Consume — two call sites

### `src/modules/scheduling/recurrence.ts`
```ts
// was: CronExpressionParser.parse(msg.recurrence, { tz: TIMEZONE })
const ownerTz = resolveOwnerTz(session.owner_key) ?? TIMEZONE;
const interval = CronExpressionParser.parse(msg.recurrence, { tz: ownerTz });
```
`session.owner_key` is already on the `Session` type (`src/types.ts:132`) and
populated for headless recurring sessions (`session-manager.ts:129`). This single
change makes every recurring task that person owns fire on their current wall-clock.

### `src/modules/summary-notify/sweep.ts`
The `runSummaryNotify` loop already iterates per `personKey`. Pass a per-owner tz
into the detector instead of the hardcoded `Asia/Makassar` default:
```ts
const cfg = { ...deps.cfg, tz: resolveOwnerTz(personKey) ?? deps.cfg.tz };
const decision = decideSummaryNotify({ ..., cfg });
```
Without this, moving the publishes' fire time would leave the "Сводка ready"
notification window stranded on WITA and it would misfire on travel days.
(`detector.ts` already carries a TODO: "multi-person would resolve TZ per person later".)

## Capture — `src/channels/ios-app/v2/http-handler.ts`

Both handlers already authenticate and hold `id.person_key`:

- **`GET /ios/pending`** (primary; runs in the background without user action):
  read optional `tz` query param → `noteDeviceTz(id.person_key, tz)`.
- **`POST /ios/proactive`** (already parses `obj.tz`): add
  `noteDeviceTz(id.person_key, obj.tz)` — free freshness, no protocol change.

Freshness = however often the background pull runs (many times/day), which is
more than enough for the "corrects by the next recompute" semantics.

## iOS change (build bump required)

The pending pull currently builds a **bare** URL — `ServerConfig.httpURL(path: "ios/pending")`
with no query (`PendingNotifications.swift:34`; the host's `?since=` is
server-side-optional and the client never sends it). Add a `tz` query item:
build `URLComponents` from that URL and append
`URLQueryItem(name: "tz", value: TimeZone.current.identifier)` (or add a
`ServerConfig.httpURL(path:queryItems:)` overload and route the existing
`ServerConfigTests` through it). Only `PendingNotifications.drain` sends it —
`/ios/proactive` already carries tz on the host side.

Per repo policy (feedback: iOS version bump): bump `CURRENT_PROJECT_VERSION` +1
and `MARKETING_VERSION` minor (user-visible behavior change), run `xcodegen`,
commit the regenerated `pbxproj`. Exact numbers read from `project.yml` at
implementation time.

## Fallback chain

```
resolveOwnerTz(owner_key)  →  valid stored IANA tz
   else                    →  global TIMEZONE (env; == current behavior)
```
New user, or a phone that has never reported, behaves exactly as today. Safe,
non-breaking default.

## Accepted limitation

The single next-run frozen **before** landing stays on the old zone. First brief
after a long hop (e.g. Bali→London, +7h) may land at the old 09:00 (02:00 London),
then self-corrects to 09:00 London every subsequent day. This is the explicit
"off-once" choice.

## Explicit non-goal (with risk note)

**Container `TZ` env stays global** (`container-runner.ts:698` unchanged). Flipping
the agent's own clock per-owner would shift date-boundary logic inside agents —
greg's wake-day health bucketing, scrooge's date math — a real regression for a
cosmetic gain. So the agent's *internal* clock stays home-tz while the brief's
*arrival time* is correct. Near-midnight date wording could read one day off on
rare hops; noted as possible future polish, not v1. If wording accuracy is ever
needed, the agent can pull live tz/time via `request_context`.

## Files touched

| File | Change |
|------|--------|
| `src/db/migrations/024-person-tz.ts` | new `person_tz` table |
| `src/db/migrations/index.ts` | register migration 024 |
| `src/modules/person-tz/db.ts` | `upsertPersonTz` / `getPersonTz` |
| `src/modules/person-tz/index.ts` | `noteDeviceTz` / `resolveOwnerTz` |
| `src/modules/scheduling/recurrence.ts` | owner-tz cron parse |
| `src/modules/summary-notify/sweep.ts` | per-owner detector tz |
| `src/channels/ios-app/v2/http-handler.ts` | stamp tz on `/ios/pending` + `/ios/proactive` |
| `ios/…/Services/PendingNotifications.swift` (+ maybe `Utility/ServerConfig.swift`) | add `tz` query item to the pending-pull URL |
| `ios/JarvisApp/project.yml` + regenerated `pbxproj` | version bump |

Tests: `src/modules/person-tz/person-tz.test.ts`, additions to
`recurrence.test.ts` and the summary-notify sweep test, an iOS unit test for the
URL param.

## Test plan (host vitest + container/iOS)

Host (vitest, `better-sqlite3` in-memory):
- migration 024 creates `person_tz`.
- `noteDeviceTz`: valid IANA upserts; junk (`"Mars/Phobos"`, `""`) is ignored (no row / no throw); re-report of a new zone updates tz + `updated_at`; same zone leaves `updated_at`.
- `resolveOwnerTz`: null owner → null; unknown owner → null; stored valid → that tz.
- `recurrence`: with `person_tz` = `Europe/London`, `0 9 * * *` next-run differs from the `Asia/Makassar` global by the offset; with no row, equals the global (regression guard).
- `summary-notify sweep`: a person with a stored tz gets that tz in the detector cfg; without, keeps the default.

iOS (unit test, `@testable import Jarvis`):
- the pending-pull URL built in `PendingNotifications.drain` (or the new
  `ServerConfig.httpURL(path:queryItems:)` overload) carries `tz=<identifier>`.
- clean build passes. **No prod-token connection** (per repo policy).

## Rollout / deploy

- Host code + migration: local edit → commit → `git pull` on VDS → `pnpm run build`
  → restart service. Migration 024 runs on startup.
- agent-runner: **not touched** (this feature is entirely host + iOS).
- iOS: build, bump, install manually.
- Order-independent: host can ship first (fallback = current behavior until the
  phone starts reporting tz); iOS build then starts populating `person_tz`.

## Isolation note for implementation

Per repo convention (concurrent Claude sessions commit to this repo's `main`),
run the implementation on a **git worktree** with append-only commits, then merge.
