# Сводка-ready Notification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send one lock-screen notification each morning once the dashboard cards have settled; tapping it opens the Сводка board (no chat bubble). Reuse the same deep-link nav so tapping a chat notification opens that agent's chat.

**Architecture:** Host `host-sweep` already projects each agent's `public.md` → `profiles/<agent>.md` every 60s. A new host module observes those projection mtimes, and once the morning batch has settled (debounce inside a morning window, once/day), emits a new `summary_ready` envelope to the owner's device(s) via a registry callback the ios-app-v2 channel plugs into. iOS decodes `summary_ready`, schedules a local notification (gated, not stored as chat), and routes a tap to the existing `StateBoardView` sheet.

**Tech Stack:** Node host (TypeScript, vitest, better-sqlite3), Zod protocol (`shared/ios-app-protocol/v2.ts`), iOS SwiftUI (`@testable import Jarvis`, XCTest), `bun` not involved (host + iOS only).

Spec: `docs/superpowers/specs/2026-06-30-summary-ready-notification-design.md`.

---

## File structure

**Protocol (shared):**
- `shared/ios-app-protocol/v2.ts` — add `Envelopes.SummaryReady` + add to `AnyEnvelope`.

**Host (`src/`):**
- `src/channels/ios-app/v2/types.ts` — add `'summary_ready'` to `NOTIFY_TYPES`.
- `src/db/migrations/022-summary-notify-log.ts` — new table.
- `src/db/migrations/index.ts` — register migration 022.
- `src/modules/summary-notify/detector.ts` — pure `decideSummaryNotify` + tz/plural helpers.
- `src/modules/summary-notify/db.ts` — `getLastNotified` / `setLastNotified`.
- `src/modules/summary-notify/emit-registry.ts` — `registerSummaryEmitter` / `getSummaryEmitter`.
- `src/modules/summary-notify/sweep.ts` — `runSummaryNotify(...)` glue (reads mtimes, calls detector, persists, emits).
- `src/host-sweep.ts` — call `runSummaryNotify` after `projectAllPublicProfiles`.
- `src/channels/ios-app/v2/index.ts` — register the summary emitter on setup (resolve devices, build envelope, `sendEnvelopeToDevice`).
- `src/modules/permissions/db/users.ts` — add `getDevicePlatformIds(personKey, kind)`.

**iOS (`ios/JarvisApp/Sources/JarvisApp/`):**
- `Protocol/V2.swift` — `summaryReady` type tag + `SummaryReady` payload + decode case.
- `Services/LocalNotifier.swift` — `raiseSummaryReady(...)` + injectable `isSummaryEnabled`.
- `Services/NotificationCategories.swift` — `summaryReady` category.
- `Services/TransportV2.swift` — `summary_ready` branch (notify, no store insert).
- `Models/AppSettings.swift` — `summaryNotificationsEnabled`.
- `Views/SettingsView.swift` — «Сводка» toggle row.
- `Services/NotificationTapRouter.swift` — pure tap→target router (board / agent chat / reply).
- `Services/AppCoordinator.swift` — `pendingOpenSummaryBoard` + `pendingOpenAgentChat` intents + hook wiring.
- `JarvisApp.swift` — AppDelegate `didReceive` routes via the router; static hooks.
- `Views/ContentView.swift` — apply intents → `appPhase`/`ActiveAgentState` (cold-launch guard).
- `Views/OrbHomeView.swift` — open `StateBoardView` sheet on the board intent.
- `project.yml` — version bump.

---

## Task 1: Protocol — `summary_ready` envelope

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts` (Envelopes dict; `AnyEnvelope` union ~line 454)
- Test: `shared/ios-app-protocol/v2.test.ts` (create if absent; else append)

- [ ] **Step 1: Write the failing test**

Create/append `shared/ios-app-protocol/v2.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { AnyEnvelope } from './v2.js';

describe('summary_ready envelope', () => {
  it('parses a valid summary_ready envelope', () => {
    const env = {
      v: 2,
      kind: 'data',
      type: 'summary_ready',
      id: 'summary-owner-2026-06-30',
      seq: 12,
      ts: '2026-06-30T00:52:00.000Z',
      payload: { date: '2026-06-30', count: 5, text: 'Сводка готова · 5 карточек', agent_id: 'jarvis' },
    };
    const parsed = AnyEnvelope.parse(env);
    expect(parsed.type).toBe('summary_ready');
    if (parsed.type === 'summary_ready') {
      expect(parsed.payload.count).toBe(5);
      expect(parsed.payload.date).toBe('2026-06-30');
    }
  });

  it('rejects summary_ready with non-integer count', () => {
    const bad = {
      v: 2, kind: 'data', type: 'summary_ready', id: 'x',
      seq: 1, ts: '2026-06-30T00:52:00.000Z',
      payload: { date: '2026-06-30', count: 'five', text: 'x' },
    };
    expect(() => AnyEnvelope.parse(bad)).toThrow();
  });
});
```

- [ ] **Step 2: Run it — verify FAIL**

Run: `pnpm exec vitest run shared/ios-app-protocol/v2.test.ts`
Expected: FAIL — `summary_ready` not in the discriminated union (parse throws "Invalid discriminator value").

- [ ] **Step 3: Add the envelope**

In `shared/ios-app-protocol/v2.ts`, inside the `Envelopes = { ... } as const` dict (alongside `Message`), add:

```typescript
  SummaryReady: EnvelopeBase.extend({
    kind: z.literal('data'),
    type: z.literal('summary_ready'),
    payload: z.object({
      date: z.string().min(1), // YYYY-MM-DD in person TZ
      count: z.number().int().nonnegative(),
      text: z.string(), // notification body; also surfaced by GET /ios/pending
      agent_id: z.string().min(1).optional(),
    }),
  }),
```

Then add `Envelopes.SummaryReady` to the `AnyEnvelope` discriminated union array (after `Envelopes.StatusRead`):

```typescript
  Envelopes.StatusDelivered, Envelopes.StatusRead,
  Envelopes.SummaryReady,
```

- [ ] **Step 4: Run it — verify PASS**

Run: `pnpm exec vitest run shared/ios-app-protocol/v2.test.ts`
Expected: PASS (both cases).

- [ ] **Step 5: Commit**

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/v2.test.ts
git commit -m "feat(protocol): add summary_ready envelope"
```

---

## Task 2: Host — `summary_ready` in NOTIFY_TYPES

**Files:**
- Modify: `src/channels/ios-app/v2/types.ts:52` (`NOTIFY_TYPES`)
- Test: `src/channels/ios-app/v2/outbound-queue.test.ts` (append)

- [ ] **Step 1: Write the failing test**

Append to `src/channels/ios-app/v2/outbound-queue.test.ts` a case that enqueues a `summary_ready` row and asserts `listPendingNotify` returns it. Match the existing test's setup for constructing the queue + db (read the file's top for the exact harness; use the same `makeQueue()`/`openTransportDb` helper already used there). Test body:

```typescript
it('listPendingNotify includes summary_ready rows', () => {
  const { queue } = makeQueue(); // reuse the file's existing helper
  const pid = 'device-1';
  queue.enqueue(pid, {
    id: 'summary-owner-2026-06-30',
    kind: 'data',
    type: 'summary_ready',
    payload: { date: '2026-06-30', count: 5, text: 'Сводка готова · 5 карточек', agent_id: 'jarvis' },
  });
  const rows = queue.listPendingNotify(pid, 0);
  expect(rows.map((r) => r.type)).toContain('summary_ready');
});
```

- [ ] **Step 2: Run it — verify FAIL**

Run: `pnpm exec vitest run src/channels/ios-app/v2/outbound-queue.test.ts`
Expected: FAIL — row enqueued but filtered out (`type` not in `NOTIFY_TYPES`).

- [ ] **Step 3: Add the type**

In `src/channels/ios-app/v2/types.ts`:

```typescript
export const NOTIFY_TYPES = ['message', 'summary_ready'] as const;
```

- [ ] **Step 4: Run it — verify PASS**

Run: `pnpm exec vitest run src/channels/ios-app/v2/outbound-queue.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/types.ts src/channels/ios-app/v2/outbound-queue.test.ts
git commit -m "feat(ios-app): notify on summary_ready type"
```

---

## Task 3: Host — migration + `summary_notify_log` accessor

**Files:**
- Create: `src/db/migrations/022-summary-notify-log.ts`
- Modify: `src/db/migrations/index.ts` (import + array)
- Create: `src/modules/summary-notify/db.ts`
- Test: `src/modules/summary-notify/db.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/modules/summary-notify/db.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from '../../db/migrations/index.js';
import { getLastNotified, setLastNotified } from './db.js';

let db: Database.Database;
beforeEach(() => {
  db = new Database(':memory:');
  runMigrations(db);
});

describe('summary_notify_log', () => {
  it('returns null before any notify', () => {
    expect(getLastNotified(db, 'owner')).toBeNull();
  });
  it('upserts idempotently', () => {
    setLastNotified(db, 'owner', '2026-06-30');
    expect(getLastNotified(db, 'owner')).toBe('2026-06-30');
    setLastNotified(db, 'owner', '2026-07-01');
    expect(getLastNotified(db, 'owner')).toBe('2026-07-01');
  });
});
```

- [ ] **Step 2: Run it — verify FAIL**

Run: `pnpm exec vitest run src/modules/summary-notify/db.test.ts`
Expected: FAIL — `./db.js` + table missing.

- [ ] **Step 3: Create the migration**

`src/db/migrations/022-summary-notify-log.ts`:

```typescript
import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration022: Migration = {
  version: 22,
  name: 'summary-notify-log',
  up(db: Database.Database) {
    // One row per person: the last date (in the person's TZ) we fired the
    // "Сводка готова" notification. Prevents double-fire across host restarts
    // and re-sweeps within the same morning.
    db.prepare(
      `CREATE TABLE summary_notify_log (
         person_key TEXT PRIMARY KEY,
         last_notified_date TEXT NOT NULL
       )`,
    ).run();
  },
};
```

In `src/db/migrations/index.ts`, import and append to the `migrations` array after `migration021`:

```typescript
import { migration022 } from './022-summary-notify-log.js';
```
```typescript
  migration021,
  migration022,
];
```

- [ ] **Step 4: Create the accessor**

`src/modules/summary-notify/db.ts`:

```typescript
import type Database from 'better-sqlite3';

export function getLastNotified(db: Database.Database, personKey: string): string | null {
  const row = db
    .prepare('SELECT last_notified_date FROM summary_notify_log WHERE person_key = ?')
    .get(personKey) as { last_notified_date: string } | undefined;
  return row?.last_notified_date ?? null;
}

export function setLastNotified(db: Database.Database, personKey: string, date: string): void {
  db.prepare(
    `INSERT INTO summary_notify_log (person_key, last_notified_date)
     VALUES (?, ?)
     ON CONFLICT(person_key) DO UPDATE SET last_notified_date = excluded.last_notified_date`,
  ).run(personKey, date);
}
```

- [ ] **Step 5: Run it — verify PASS**

Run: `pnpm exec vitest run src/modules/summary-notify/db.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/db/migrations/022-summary-notify-log.ts src/db/migrations/index.ts src/modules/summary-notify/db.ts src/modules/summary-notify/db.test.ts
git commit -m "feat(summary-notify): summary_notify_log table + accessor"
```

---

## Task 4: Host — pure debounce detector

**Files:**
- Create: `src/modules/summary-notify/detector.ts`
- Test: `src/modules/summary-notify/detector.test.ts`

The detector is pure: no ambient clock, no fs. All time inputs are epoch ms. TZ math via `Intl.DateTimeFormat` (available in Node).

- [ ] **Step 1: Write the failing test**

`src/modules/summary-notify/detector.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { decideSummaryNotify, pluralRu, DEFAULT_SUMMARY_CFG } from './detector.js';

// Helper: epoch ms for a wall-clock time in Asia/Makassar (UTC+8, no DST).
// 08:46 WITA on 2026-06-30 == 00:46 UTC.
const witaToUtcMs = (h: number, m: number) =>
  Date.UTC(2026, 5, 30, h - 8, m, 0); // month is 0-based; June = 5

const cfg = DEFAULT_SUMMARY_CFG; // window 08:40–09:15, quietMs 180000, tz Asia/Makassar

describe('decideSummaryNotify', () => {
  it('does not fire before any card today', () => {
    const r = decideSummaryNotify({ nowMs: witaToUtcMs(8, 46), cardMtimesMs: [], lastNotifiedDate: null, cfg });
    expect(r.fire).toBe(false);
  });

  it('does not fire while batch is still arriving (within quiet window)', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(8, 47),
      cardMtimesMs: [witaToUtcMs(8, 46)], // 1 min ago < 3 min
      lastNotifiedDate: null,
      cfg,
    });
    expect(r.fire).toBe(false);
  });

  it('fires once the batch has settled (no new card for >=3 min)', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(8, 51),
      cardMtimesMs: [witaToUtcMs(8, 46), witaToUtcMs(8, 47), witaToUtcMs(8, 48)],
      lastNotifiedDate: null,
      cfg,
    });
    expect(r.fire).toBe(true);
    expect(r.count).toBe(3);
  });

  it('fires at the deadline even if not settled', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(9, 15), // == windowEnd
      cardMtimesMs: [witaToUtcMs(9, 14)], // only 1 min old, but past deadline
      lastNotifiedDate: null,
      cfg,
    });
    expect(r.fire).toBe(true);
    expect(r.count).toBe(1);
  });

  it('does not fire twice the same day', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(8, 51),
      cardMtimesMs: [witaToUtcMs(8, 46)],
      lastNotifiedDate: '2026-06-30',
      cfg,
    });
    expect(r.fire).toBe(false);
  });

  it('ignores cards outside the morning window (e.g. midday republish)', () => {
    const r = decideSummaryNotify({
      nowMs: witaToUtcMs(12, 0),
      cardMtimesMs: [witaToUtcMs(11, 59)],
      lastNotifiedDate: null,
      cfg,
    });
    expect(r.fire).toBe(false);
  });

  it('pluralRu', () => {
    expect(pluralRu(1)).toBe('1 карточка');
    expect(pluralRu(3)).toBe('3 карточки');
    expect(pluralRu(5)).toBe('5 карточек');
    expect(pluralRu(11)).toBe('11 карточек');
    expect(pluralRu(21)).toBe('21 карточка');
  });
});
```

- [ ] **Step 2: Run it — verify FAIL**

Run: `pnpm exec vitest run src/modules/summary-notify/detector.test.ts`
Expected: FAIL — `./detector.js` not found.

- [ ] **Step 3: Implement the detector**

`src/modules/summary-notify/detector.ts`:

```typescript
export interface SummaryCfg {
  tz: string;
  windowStartMin: number; // minutes-of-day, inclusive
  windowEndMin: number; // minutes-of-day; also the hard deadline
  quietMs: number; // settle: fire when no new card for this long
}

// Morning publish cron is `45 8 * * *` in the agent TZ (Asia/Makassar). Window
// 08:40–09:15 brackets the batch with margin; v1 owner-only uses this constant
// (multi-person would resolve TZ per person later).
export const DEFAULT_SUMMARY_CFG: SummaryCfg = {
  tz: 'Asia/Makassar',
  windowStartMin: 8 * 60 + 40, // 520
  windowEndMin: 9 * 60 + 15, // 555
  quietMs: 3 * 60 * 1000, // 180000
};

export interface DecideInput {
  nowMs: number;
  cardMtimesMs: number[];
  lastNotifiedDate: string | null; // YYYY-MM-DD in cfg.tz
  cfg: SummaryCfg;
}

export interface DecideResult {
  fire: boolean;
  count: number;
  today: string; // YYYY-MM-DD in cfg.tz (for persisting on fire)
}

// --- TZ helpers (pure; epoch in, derived fields out) ---
function partsInTz(ms: number, tz: string): { date: string; minutes: number } {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  });
  const p: Record<string, string> = {};
  for (const part of fmt.formatToParts(new Date(ms))) p[part.type] = part.value;
  const date = `${p.year}-${p.month}-${p.day}`;
  let hour = parseInt(p.hour, 10);
  if (hour === 24) hour = 0; // some engines emit 24 for midnight
  const minutes = hour * 60 + parseInt(p.minute, 10);
  return { date, minutes };
}

export function decideSummaryNotify(input: DecideInput): DecideResult {
  const { nowMs, cardMtimesMs, lastNotifiedDate, cfg } = input;
  const now = partsInTz(nowMs, cfg.tz);
  const today = now.date;

  if (lastNotifiedDate === today) return { fire: false, count: 0, today };

  // Cards whose projection landed today, within the morning window.
  const morning = cardMtimesMs.filter((ms) => {
    const p = partsInTz(ms, cfg.tz);
    return p.date === today && p.minutes >= cfg.windowStartMin && p.minutes <= cfg.windowEndMin;
  });
  if (morning.length === 0) return { fire: false, count: 0, today };

  const newest = Math.max(...morning);
  const settled = nowMs - newest >= cfg.quietMs;
  const pastDeadline = now.minutes >= cfg.windowEndMin;

  return { fire: settled || pastDeadline, count: morning.length, today };
}

export function pluralRu(n: number): string {
  const noun = ((): string => {
    const mod100 = n % 100;
    const mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return 'карточек';
    if (mod10 === 1) return 'карточка';
    if (mod10 >= 2 && mod10 <= 4) return 'карточки';
    return 'карточек';
  })();
  return `${n} ${noun}`;
}
```

- [ ] **Step 4: Run it — verify PASS**

Run: `pnpm exec vitest run src/modules/summary-notify/detector.test.ts`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add src/modules/summary-notify/detector.ts src/modules/summary-notify/detector.test.ts
git commit -m "feat(summary-notify): pure debounce detector + ru plural"
```

---

## Task 5: Host — emit registry + device query

**Files:**
- Create: `src/modules/summary-notify/emit-registry.ts`
- Modify: `src/modules/permissions/db/users.ts` (add device query)
- Test: `src/modules/summary-notify/emit-registry.test.ts`

The registry decouples the host detector from the channel: the ios-app-v2 channel registers an emitter on setup; the detector calls it if present.

- [ ] **Step 1: Write the failing test**

`src/modules/summary-notify/emit-registry.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import { registerSummaryEmitter, getSummaryEmitter, __resetSummaryEmitter } from './emit-registry.js';

beforeEach(() => __resetSummaryEmitter());

describe('summary emit registry', () => {
  it('returns undefined when nothing registered', () => {
    expect(getSummaryEmitter()).toBeUndefined();
  });
  it('returns the registered emitter', () => {
    const calls: Array<{ p: string; c: number }> = [];
    registerSummaryEmitter((personKey, payload) => calls.push({ p: personKey, c: payload.count }));
    getSummaryEmitter()!('owner', { date: '2026-06-30', count: 5 });
    expect(calls).toEqual([{ p: 'owner', c: 5 }]);
  });
});
```

- [ ] **Step 2: Run it — verify FAIL**

Run: `pnpm exec vitest run src/modules/summary-notify/emit-registry.test.ts`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement the registry**

`src/modules/summary-notify/emit-registry.ts`:

```typescript
export interface SummaryPayload {
  date: string;
  count: number;
}

export type SummaryEmitter = (personKey: string, payload: SummaryPayload) => void;

let emitter: SummaryEmitter | undefined;

/** A channel adapter registers how to deliver the morning summary notification. */
export function registerSummaryEmitter(fn: SummaryEmitter): void {
  emitter = fn;
}

export function getSummaryEmitter(): SummaryEmitter | undefined {
  return emitter;
}

/** Test-only reset. */
export function __resetSummaryEmitter(): void {
  emitter = undefined;
}
```

- [ ] **Step 4: Add the device query**

In `src/modules/permissions/db/users.ts`, add (match the file's existing `getDb()`/query style — read its imports first):

```typescript
/** Platform ids of a person's registered devices for a given channel kind. */
export function getDevicePlatformIds(personKey: string, kind: string): string[] {
  return (
    getDb()
      .prepare('SELECT id FROM users WHERE person_key = ? AND kind = ?')
      .all(personKey, kind) as { id: string }[]
  ).map((r) => r.id);
}
```

(If `users.ts` does not already import `getDb`, use the same db accessor the other functions in that file use.)

- [ ] **Step 5: Run it — verify PASS**

Run: `pnpm exec vitest run src/modules/summary-notify/emit-registry.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/modules/summary-notify/emit-registry.ts src/modules/summary-notify/emit-registry.test.ts src/modules/permissions/db/users.ts
git commit -m "feat(summary-notify): emit registry + per-person device query"
```

---

## Task 6: Host — sweep glue (`runSummaryNotify`)

**Files:**
- Create: `src/modules/summary-notify/sweep.ts`
- Test: `src/modules/summary-notify/sweep.test.ts`

`runSummaryNotify` reads `profiles/<agent>.md` mtimes per person under `data/user-memory`, runs the detector, and on fire persists the date + calls the registered emitter. Clock + emitter are injected for testability.

- [ ] **Step 1: Write the failing test**

`src/modules/summary-notify/sweep.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Database from 'better-sqlite3';
import { runMigrations } from '../../db/migrations/index.js';
import { getLastNotified } from './db.js';
import { runSummaryNotify } from './sweep.js';
import { DEFAULT_SUMMARY_CFG } from './detector.js';

let dir: string;
let db: Database.Database;
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sumnotify-'));
  db = new Database(':memory:');
  runMigrations(db);
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

// Build profiles/<agent>.md with a controlled mtime.
function writeCard(person: string, agent: string, mtimeMs: number) {
  const p = path.join(dir, person, 'global', 'profiles');
  fs.mkdirSync(p, { recursive: true });
  const f = path.join(p, `${agent}.md`);
  fs.writeFileSync(f, '---\nupdated: 2026-06-30\n---\nbody');
  fs.utimesSync(f, mtimeMs / 1000, mtimeMs / 1000);
}

const witaToUtcMs = (h: number, m: number) => Date.UTC(2026, 5, 30, h - 8, m, 0);

describe('runSummaryNotify', () => {
  it('fires once for the settled morning batch and persists the date', () => {
    writeCard('owner', 'jarvis', witaToUtcMs(8, 46));
    writeCard('owner', 'greg', witaToUtcMs(8, 47));
    writeCard('owner', 'payne', witaToUtcMs(8, 48));
    const calls: Array<{ p: string; c: number }> = [];

    runSummaryNotify({
      userMemoryBase: dir,
      db,
      nowMs: witaToUtcMs(8, 51), // settled (>3min after newest)
      cfg: DEFAULT_SUMMARY_CFG,
      emit: (personKey, payload) => calls.push({ p: personKey, c: payload.count }),
    });

    expect(calls).toEqual([{ p: 'owner', c: 3 }]);
    expect(getLastNotified(db, 'owner')).toBe('2026-06-30');

    // Second sweep same day → no re-fire.
    runSummaryNotify({
      userMemoryBase: dir, db, nowMs: witaToUtcMs(8, 55),
      cfg: DEFAULT_SUMMARY_CFG, emit: (p, pl) => calls.push({ p, c: pl.count }),
    });
    expect(calls).toHaveLength(1);
  });

  it('does not fire when no emitter-relevant cards / before settle', () => {
    writeCard('owner', 'jarvis', witaToUtcMs(8, 46));
    const calls: number[] = [];
    runSummaryNotify({
      userMemoryBase: dir, db, nowMs: witaToUtcMs(8, 47), // 1 min — not settled
      cfg: DEFAULT_SUMMARY_CFG, emit: () => calls.push(1),
    });
    expect(calls).toHaveLength(0);
    expect(getLastNotified(db, 'owner')).toBeNull();
  });
});
```

- [ ] **Step 2: Run it — verify FAIL**

Run: `pnpm exec vitest run src/modules/summary-notify/sweep.test.ts`
Expected: FAIL — `./sweep.js` missing.

- [ ] **Step 3: Implement the sweep glue**

`src/modules/summary-notify/sweep.ts`:

```typescript
import fs from 'node:fs';
import path from 'node:path';
import type Database from 'better-sqlite3';
import { log } from '../../log.js';
import { decideSummaryNotify, type SummaryCfg } from './detector.js';
import { getLastNotified, setLastNotified } from './db.js';
import { getSummaryEmitter, type SummaryEmitter } from './emit-registry.js';

export interface RunSummaryNotifyDeps {
  userMemoryBase: string; // data/user-memory
  db: Database.Database; // central db (summary_notify_log)
  nowMs: number;
  cfg: SummaryCfg;
  emit?: SummaryEmitter; // default: the registered emitter (channel-provided)
}

function profileMtimes(personDir: string): number[] {
  const profilesDir = path.join(personDir, 'global', 'profiles');
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(profilesDir, { withFileTypes: true });
  } catch {
    return [];
  }
  const out: number[] = [];
  for (const e of entries) {
    if (!e.isFile() || !e.name.endsWith('.md') || e.name === 'index.md') continue;
    try {
      out.push(fs.statSync(path.join(profilesDir, e.name)).mtimeMs);
    } catch {
      /* ignore */
    }
  }
  return out;
}

export function runSummaryNotify(deps: RunSummaryNotifyDeps): void {
  const emit = deps.emit ?? getSummaryEmitter();
  if (!emit) return; // no channel registered an emitter — nothing to do

  let persons: fs.Dirent[];
  try {
    persons = fs.readdirSync(deps.userMemoryBase, { withFileTypes: true });
  } catch {
    return;
  }

  for (const p of persons) {
    if (!p.isDirectory()) continue;
    const personKey = p.name;
    const cardMtimesMs = profileMtimes(path.join(deps.userMemoryBase, personKey));
    if (cardMtimesMs.length === 0) continue;

    const decision = decideSummaryNotify({
      nowMs: deps.nowMs,
      cardMtimesMs,
      lastNotifiedDate: getLastNotified(deps.db, personKey),
      cfg: deps.cfg,
    });
    if (!decision.fire) continue;

    try {
      emit(personKey, { date: decision.today, count: decision.count });
      setLastNotified(deps.db, personKey, decision.today);
      log.info('Summary-ready notification emitted', { personKey, date: decision.today, count: decision.count });
    } catch (err) {
      log.error('Summary-ready emit failed', { personKey, err });
    }
  }
}
```

- [ ] **Step 4: Run it — verify PASS**

Run: `pnpm exec vitest run src/modules/summary-notify/sweep.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/modules/summary-notify/sweep.ts src/modules/summary-notify/sweep.test.ts
git commit -m "feat(summary-notify): sweep glue reads profile mtimes + fires once/day"
```

---

## Task 7: Host — wire detector into host-sweep

**Files:**
- Modify: `src/host-sweep.ts` (sweep(), ~line 125-145)
- Test: covered by Task 6 (the glue is unit-tested); this task is wiring only.

- [ ] **Step 1: Add the call**

In `src/host-sweep.ts`, add imports near the other module imports:

```typescript
import { runSummaryNotify } from './modules/summary-notify/sweep.js';
import { DEFAULT_SUMMARY_CFG } from './modules/summary-notify/detector.js';
import { getDb } from './db/index.js';
```

(If `getDb` is already imported in this file, don't duplicate.)

Then in `sweep()`, right after the `projectAllPublicProfiles` try/catch block, add:

```typescript
  // After projection, observe the morning card batch and fire one grouped
  // "Сводка готова" notification once it settles (host-only; channel provides
  // the emitter via registerSummaryEmitter). Own try so it never skips sessions.
  try {
    runSummaryNotify({
      userMemoryBase: path.join(DATA_DIR, 'user-memory'),
      db: getDb(),
      nowMs: Date.now(),
      cfg: DEFAULT_SUMMARY_CFG,
    });
  } catch (err) {
    log.error('Summary-notify sweep error', { err });
  }
```

- [ ] **Step 2: Typecheck + full host test run**

Run: `pnpm run build && pnpm test`
Expected: build clean; all tests pass (no regressions).

- [ ] **Step 3: Commit**

```bash
git add src/host-sweep.ts
git commit -m "feat(host): run summary-notify detector each sweep"
```

---

## Task 8: Host — ios-app-v2 registers the emitter

**Files:**
- Modify: `src/channels/ios-app/v2/index.ts` (setup path; near where `handler` is created, ~line 419)
- Test: `src/channels/ios-app/v2/integration.test.ts` (append a focused case) OR a new `summary-emit.test.ts`

The emitter resolves the person's ios-app-v2 devices, builds the `summary_ready` envelope (with a stable per-day id and a `text` body for the pull path), and calls `handler.sendEnvelopeToDevice` for each.

- [ ] **Step 1: Write the failing test**

Create `src/channels/ios-app/v2/summary-emit.test.ts`. Use the test harness already used by other ios-app/v2 tests (read `testing/harness.ts` for the helper that builds a wired adapter + in-memory transport db + a fake socket). The test should: register a device (insert a `users` row with `person_key='owner'`, `kind='ios-app-v2'` and a `devices`/token row as the harness does), start the adapter (which calls `registerSummaryEmitter`), invoke `getSummaryEmitter()!('owner', {date:'2026-06-30', count:5})`, then assert a `summary_ready` row is enqueued for that device with `payload.text` containing `5`:

```typescript
import { describe, it, expect } from 'vitest';
import { getSummaryEmitter } from '../../../modules/summary-notify/emit-registry.js';
// ...import the harness used by the sibling tests...

describe('ios-app-v2 summary emitter', () => {
  it('enqueues a summary_ready envelope with a body to the person\'s device', async () => {
    const h = await makeWiredAdapter(); // harness: wires adapter, registers emitter, returns { queue, db, platformId, personKey='owner' }
    getSummaryEmitter()!(h.personKey, { date: '2026-06-30', count: 5 });
    const rows = h.queue.listPendingNotify(h.platformId, 0);
    const summary = rows.find((r) => r.type === 'summary_ready');
    expect(summary).toBeTruthy();
    const payload = JSON.parse(summary!.payload_json);
    expect(payload.text).toContain('5');
    expect(payload.date).toBe('2026-06-30');
  });
});
```

(Adapt the harness call to the actual helper names in `testing/harness.ts` — read it first. If no helper exposes `queue`, assert via `GET /ios/pending` instead.)

- [ ] **Step 2: Run it — verify FAIL**

Run: `pnpm exec vitest run src/channels/ios-app/v2/summary-emit.test.ts`
Expected: FAIL — emitter not registered (getSummaryEmitter() undefined).

- [ ] **Step 3: Register the emitter on setup**

In `src/channels/ios-app/v2/index.ts`, add imports at top:

```typescript
import { registerSummaryEmitter } from '../../../modules/summary-notify/emit-registry.js';
import { getDevicePlatformIds } from '../../../modules/permissions/db/users.js';
import { pluralRu } from '../../../modules/summary-notify/detector.js';
```

After `handler = new WsHandler({ ... })` is assigned (so `handler` is in scope), add:

```typescript
  // Morning "Сводка готова" notification. The host detector calls this when the
  // card batch settles; we fan it out to the person's registered devices as a
  // notify-only summary_ready envelope (no chat bubble — iOS handles the type).
  registerSummaryEmitter((personKey, payload) => {
    const platformIds = getDevicePlatformIds(personKey, CHANNEL_TYPE);
    if (platformIds.length === 0) return;
    const body = `Сводка готова · ${pluralRu(payload.count)}`;
    for (const platformId of platformIds) {
      handler.sendEnvelopeToDevice(platformId, {
        kind: 'data',
        type: 'summary_ready',
        id: `summary-${personKey}-${payload.date}`,
        payload: { date: payload.date, count: payload.count, text: body, agent_id: 'jarvis' },
      });
    }
  });
```

(`CHANNEL_TYPE` is the `'ios-app-v2'` constant already defined in this file.)

- [ ] **Step 4: Run it — verify PASS**

Run: `pnpm exec vitest run src/channels/ios-app/v2/summary-emit.test.ts`
Expected: PASS.

- [ ] **Step 5: Full host suite + commit**

Run: `pnpm run build && pnpm test`
Expected: clean.

```bash
git add src/channels/ios-app/v2/index.ts src/channels/ios-app/v2/summary-emit.test.ts
git commit -m "feat(ios-app): register summary_ready emitter, fan out to devices"
```

---

## Task 9: iOS — protocol `summary_ready`

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/V2SummaryReadyTests.swift` (create)

- [ ] **Step 1: Write the failing test**

`ios/JarvisApp/Sources/JarvisAppTests/V2SummaryReadyTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class V2SummaryReadyTests: XCTestCase {
    func testDecodesSummaryReady() throws {
        let json = """
        {"v":2,"kind":"data","type":"summary_ready","id":"summary-owner-2026-06-30",
         "seq":12,"ts":"2026-06-30T00:52:00.000Z",
         "payload":{"date":"2026-06-30","count":5,"text":"Сводка готова · 5 карточек","agent_id":"jarvis"}}
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(V2.Envelope.self, from: json)
        XCTAssertEqual(env.type, .summaryReady)
        guard case let .summaryReady(p) = env.payload else { return XCTFail("wrong payload") }
        XCTAssertEqual(p.count, 5)
        XCTAssertEqual(p.date, "2026-06-30")
    }
}
```

- [ ] **Step 2: Run it — verify FAIL**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/V2SummaryReadyTests 2>&1 | tail -20`
Expected: FAIL — `.summaryReady` not a member.

- [ ] **Step 3: Add type tag, payload struct, decode case**

In `V2.swift`, add to `TypeTag` enum:

```swift
    case summaryReady = "summary_ready"
```

Add the payload struct (near `Message`):

```swift
struct SummaryReady: Codable, Equatable {
    let date: String
    let count: Int
    var text: String?
    var agent_id: String?
    init(date: String, count: Int, text: String? = nil, agent_id: String? = nil) {
        self.date = date; self.count = count; self.text = text; self.agent_id = agent_id
    }
}
```

Add to `Payload` enum:

```swift
    case summaryReady(SummaryReady)
```

In `Envelope.init(from:)` switch, add:

```swift
        case .summaryReady:
            payload = .summaryReady(try V2.SummaryReady(from: payloadDecoder))
```

(If the `Envelope` also has an `encode(to:)` that switches on payload, add a matching `case .summaryReady(let p): try p.encode(to: ...)` branch following the existing `message` pattern.)

- [ ] **Step 4: Run it — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/V2SummaryReadyTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift ios/JarvisApp/Sources/JarvisAppTests/V2SummaryReadyTests.swift
git commit -m "feat(ios): decode summary_ready envelope"
```

---

## Task 10: iOS — LocalNotifier.raiseSummaryReady + category + gating

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/LocalNotifier.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/NotificationCategories.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/SummaryNotifierTests.swift` (create)

Gating differs from `raise()`: respects global enable + quiet hours + a **new** «Сводка» toggle; **not** per-agent mute. Reuses `notifiedSeen`/`recordNotified` for WS+pull dedup by the stable id.

- [ ] **Step 1: Write the failing test**

`ios/JarvisApp/Sources/JarvisAppTests/SummaryNotifierTests.swift`. Use the same mock-center pattern the existing LocalNotifier tests use (read the current LocalNotifier test file for `NotificationScheduling` mock). Test that: (a) with summary enabled + not quiet + background → schedules one request; (b) with summary toggle off → schedules nothing; (c) per-agent mute of "jarvis" does NOT suppress it.

```swift
import XCTest
@testable import Jarvis

final class SummaryNotifierTests: XCTestCase {
    func testSchedulesWhenEnabled() {
        let center = MockCenter() // same mock used by existing LocalNotifier tests
        let n = LocalNotifier(
            center: center,
            isForeground: { false },
            isEnabled: { true },
            isMuted: { _ in true },       // per-agent mute ON — must be ignored for summary
            inQuietHours: { false },
            isSummaryEnabled: { true }
        )
        n.configure(store: makeMemoryStore())
        n.raiseSummaryReady(id: "summary-owner-2026-06-30", date: "2026-06-30", count: 5, agentId: "jarvis")
        XCTAssertEqual(center.scheduled.count, 1)
        XCTAssertTrue(center.scheduled[0].content.body.contains("5"))
    }

    func testSuppressedWhenSummaryToggleOff() {
        let center = MockCenter()
        let n = LocalNotifier(
            center: center, isForeground: { false }, isEnabled: { true },
            isMuted: { _ in false }, inQuietHours: { false }, isSummaryEnabled: { false }
        )
        n.configure(store: makeMemoryStore())
        n.raiseSummaryReady(id: "x", date: "2026-06-30", count: 5, agentId: "jarvis")
        XCTAssertEqual(center.scheduled.count, 0)
    }
}
```

(Reuse `MockCenter`/`makeMemoryStore` helpers from the existing LocalNotifier test file; if names differ, match them.)

- [ ] **Step 2: Run it — verify FAIL**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/SummaryNotifierTests 2>&1 | tail -20`
Expected: FAIL — `isSummaryEnabled` param + `raiseSummaryReady` missing.

- [ ] **Step 3: Add the category**

In `NotificationCategories.swift`:

```swift
    static let summaryReady = "summary-ready"
```

Add a category (tap-only, no actions) and include it in `register()`:

```swift
    static func summaryReadyCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: summaryReady, actions: [], intentIdentifiers: [], options: [])
    }

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories([
            agentMessageCategory(),
            summaryReadyCategory(),
        ])
    }
```

- [ ] **Step 4: Add the gating closure + method**

In `LocalNotifier.swift`, add an `isSummaryEnabled` closure to the `init` (default reads UserDefaults), store it, and add `raiseSummaryReady`:

```swift
    private let isSummaryEnabled: () -> Bool
```

Add to `init(...)` params (with default):

```swift
        isSummaryEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: "summaryNotificationsEnabled") as? Bool ?? true
        }
```

Assign in the init body: `self.isSummaryEnabled = isSummaryEnabled`.

Add the method:

```swift
    func raiseSummaryReady(id: String, date: String, count: Int, agentId: String) {
        guard !isForeground() else { return }
        guard isEnabled() else { return }
        guard isSummaryEnabled() else { return }   // dedicated «Сводка» toggle (not per-agent mute)
        guard !inQuietHours() else { return }
        guard let store else { return }
        if (try? store.notifiedSeen(id: id)) == true { return }

        let content = UNMutableNotificationContent()
        content.title = "Сводка"
        content.body = "Сводка готова · \(count) карточек"
        content.sound = .default
        content.threadIdentifier = "summary"
        content.categoryIdentifier = NotificationCategories.summaryReady
        content.userInfo = ["summary": true, "date": date]

        let req = UNNotificationRequest(identifier: "summary-\(id)", content: content, trigger: nil)
        center.schedule(req)
        try? store.recordNotified(id: id, seq: 0)
    }
```

(Body uses a fixed `карточек` form for the iOS string; the precise plural already comes from the host `text` field when shown via the pull path — see note in Task 11. If you prefer the host-composed body, set `content.body = text` and thread `text` through `SummaryReady` — but `count` is always present, so the simple form is fine.)

- [ ] **Step 5: Run it — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/SummaryNotifierTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/LocalNotifier.swift ios/JarvisApp/Sources/JarvisApp/Services/NotificationCategories.swift ios/JarvisApp/Sources/JarvisAppTests/SummaryNotifierTests.swift
git commit -m "feat(ios): LocalNotifier.raiseSummaryReady + summary category + gating"
```

---

## Task 11: iOS — TransportV2 summary_ready branch

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift` (main inbound switch, ~line 162-221)
- Test: `ios/JarvisApp/Sources/JarvisAppTests/TransportSummaryTests.swift` (create)

The branch must: NOT insert into the store, schedule the summary notification, ack delivered, advance the cursor, and record dedup.

- [ ] **Step 1: Write the failing test**

`ios/JarvisApp/Sources/JarvisAppTests/TransportSummaryTests.swift`. Mirror the existing TransportV2 test harness (read the current TransportV2 test for how an envelope is fed + how a memory store + fake sender are built). Assert: after feeding a `summary_ready` envelope, the store has **no** new message rows, and a `delivered` status was sent.

```swift
import XCTest
@testable import Jarvis

final class TransportSummaryTests: XCTestCase {
    func testSummaryReadyDoesNotInsertChat() async throws {
        let h = try makeTransportHarness() // existing helper: { transport, store, sentStatuses }
        let env = V2.Envelope(
            v: 2, kind: .data, type: .summaryReady,
            id: "summary-owner-2026-06-30", seq: 12,
            ts: "2026-06-30T00:52:00.000Z",
            payload: .summaryReady(.init(date: "2026-06-30", count: 5, text: "Сводка готова · 5 карточек", agent_id: "jarvis"))
        )
        let before = try h.store.messageCount()
        try await h.transport.handleInbound(env)   // use the actual inbound entrypoint name
        XCTAssertEqual(try h.store.messageCount(), before) // no chat row
        XCTAssertTrue(h.sentStatuses.contains { $0 == .delivered }) // acked
    }
}
```

(Adapt `makeTransportHarness`, `handleInbound`, `messageCount`, `sentStatuses` to the real names — read the existing TransportV2 test + `ConversationStoreV2` first.)

- [ ] **Step 2: Run it — verify FAIL**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/TransportSummaryTests 2>&1 | tail -20`
Expected: FAIL — no `.summaryReady` case → falls into `default: break` (no delivered sent), or compile error if `messageCount` missing (add a tiny test-only count helper to the store if needed).

- [ ] **Step 3: Add the branch**

In `TransportV2.swift` main inbound switch (the one with `case .message(let m):`), add:

```swift
        case .summaryReady(let sr):
            // Notify-only: never insert a chat row. Dedup across WS + pull by id.
            if try store.dedupSeen(id: env.id) {
                try await sendStatus(.delivered, ids: [env.id])
                try advanceInboundCursor(env.seq)
                return
            }
            LocalNotifier.shared.raiseSummaryReady(
                id: env.id, date: sr.date, count: sr.count, agentId: sr.agent_id ?? "jarvis"
            )
            try await sendStatus(.delivered, ids: [env.id])
            try advanceInboundCursor(env.seq)
            try store.recordDedup(id: env.id, seq: env.seq ?? 0)
```

(Place it alongside the other `case` entries in that switch. The switch arm style — `try await` — matches the surrounding cases. If the switch is `exhaustive`, removing `default:`-reliance: add this explicit case so the compiler is satisfied.)

- [ ] **Step 4: Run it — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/TransportSummaryTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/TransportV2.swift ios/JarvisApp/Sources/JarvisAppTests/TransportSummaryTests.swift
git commit -m "feat(ios): TransportV2 routes summary_ready to notifier, not chat"
```

---

## Task 12: iOS — «Сводка» settings toggle

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/AppSettingsSummaryTests.swift` (create)

- [ ] **Step 1: Write the failing test**

`ios/JarvisApp/Sources/JarvisAppTests/AppSettingsSummaryTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class AppSettingsSummaryTests: XCTestCase {
    func testSummaryDefaultsOnAndPersists() {
        let d = UserDefaults(suiteName: "summary-test")!
        d.removePersistentDomain(forName: "summary-test")
        let s = AppSettings(defaults: d) // match AppSettings' injectable-defaults init if present
        XCTAssertTrue(s.summaryNotificationsEnabled)
        s.summaryNotificationsEnabled = false
        XCTAssertEqual(d.object(forKey: "summaryNotificationsEnabled") as? Bool, false)
    }
}
```

(If `AppSettings` has no injectable-defaults init, follow the exact pattern its other Bool settings use — read `AppSettings.swift` first and mirror `notificationsEnabled`.)

- [ ] **Step 2: Run it — verify FAIL**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/AppSettingsSummaryTests 2>&1 | tail -20`
Expected: FAIL — property missing.

- [ ] **Step 3: Add the setting**

In `AppSettings.swift`, mirror the existing `notificationsEnabled` property exactly (same `@AppStorage`/`didSet`/UserDefaults idiom the file uses) with key `"summaryNotificationsEnabled"`, default `true`.

- [ ] **Step 4: Add the toggle row**

In `SettingsView.swift`, inside the `settingsSection(title: "Уведомления")` block, after the quiet-hours rows (still inside `if settings.notificationsEnabled`), add:

```swift
            settingsDivider()
            settingsToggle(icon: "square.text.square", label: "Сводка", isOn: $settings.summaryNotificationsEnabled)
```

- [ ] **Step 5: Run it — verify PASS + build**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/AppSettingsSummaryTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift ios/JarvisApp/Sources/JarvisApp/Views/SettingsView.swift ios/JarvisApp/Sources/JarvisAppTests/AppSettingsSummaryTests.swift
git commit -m "feat(ios): «Сводка» notification toggle in settings"
```

---

## Task 13: iOS — deep-link navigation (Сводка board + chat)

One mechanism for both deep-links. A **pure** `NotificationTapRouter` maps a tapped
notification → a target; `AppCoordinator` holds two nav intents; `ContentView` applies
them (with a cold-launch guard); `OrbHomeView` opens the board. Chat-notification taps
now deep-link into that agent's chat (today the default tap does nothing).

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Services/NotificationTapRouter.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift` (AppDelegate)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ContentView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/NotificationTapRouterTests.swift`, `.../CoordinatorNavTests.swift`

- [ ] **Step 1: Write the failing router test**

`ios/JarvisApp/Sources/JarvisAppTests/NotificationTapRouterTests.swift`:

```swift
import XCTest
import UserNotifications
@testable import Jarvis

final class NotificationTapRouterTests: XCTestCase {
    func testReplyAction() {
        let t = NotificationTapRouter.route(
            categoryId: NotificationCategories.agentMessage,
            actionId: NotificationCategories.replyAction,
            replyText: "ok", userInfo: ["agentId": "greg"])
        XCTAssertEqual(t, .reply(agentId: "greg", text: "ok"))
    }
    func testSummaryTapOpensBoard() {
        let t = NotificationTapRouter.route(
            categoryId: NotificationCategories.summaryReady,
            actionId: UNNotificationDefaultActionIdentifier,
            replyText: nil, userInfo: [:])
        XCTAssertEqual(t, .openSummaryBoard)
    }
    func testChatDefaultTapOpensAgentChat() {
        let t = NotificationTapRouter.route(
            categoryId: NotificationCategories.agentMessage,
            actionId: UNNotificationDefaultActionIdentifier,
            replyText: nil, userInfo: ["agentId": "payne"])
        XCTAssertEqual(t, .openAgentChat(.payne))
    }
    func testUnknownAgentIsNoop() {
        let t = NotificationTapRouter.route(
            categoryId: NotificationCategories.agentMessage,
            actionId: UNNotificationDefaultActionIdentifier,
            replyText: nil, userInfo: ["agentId": "nope"])
        XCTAssertEqual(t, .none)
    }
}
```

- [ ] **Step 2: Run it — verify FAIL**

Run: `cd ios/JarvisApp && xcodegen generate && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/NotificationTapRouterTests 2>&1 | tail -20`
Expected: FAIL — `NotificationTapRouter` missing.

- [ ] **Step 3: Implement the pure router**

`ios/JarvisApp/Sources/JarvisApp/Services/NotificationTapRouter.swift`:

```swift
import UserNotifications

enum NotificationTapTarget: Equatable {
    case reply(agentId: String, text: String)
    case openSummaryBoard
    case openAgentChat(AgentIdentity)
    case none
}

enum NotificationTapRouter {
    static func route(
        categoryId: String,
        actionId: String,
        replyText: String?,
        userInfo: [AnyHashable: Any]
    ) -> NotificationTapTarget {
        if actionId == NotificationCategories.replyAction, let text = replyText {
            let agentId = userInfo["agentId"] as? String ?? "jarvis"
            return .reply(agentId: agentId, text: text)
        }
        switch categoryId {
        case NotificationCategories.summaryReady:
            return .openSummaryBoard
        case NotificationCategories.agentMessage:
            let slug = userInfo["agentId"] as? String ?? "jarvis"
            if let agent = AgentIdentity(rawValue: slug) { return .openAgentChat(agent) }
            return .none
        default:
            return .none
        }
    }
}
```

- [ ] **Step 4: Run it — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/NotificationTapRouterTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Write the failing coordinator test**

`ios/JarvisApp/Sources/JarvisAppTests/CoordinatorNavTests.swift`:

```swift
import XCTest
@testable import Jarvis

@MainActor
final class CoordinatorNavTests: XCTestCase {
    func testNavIntents() {
        let c = AppCoordinator(settings: AppSettings())
        XCTAssertFalse(c.pendingOpenSummaryBoard)
        XCTAssertNil(c.pendingOpenAgentChat)
        c.requestOpenSummaryBoard()
        XCTAssertTrue(c.pendingOpenSummaryBoard)
        c.requestOpenAgentChat(.greg)
        XCTAssertEqual(c.pendingOpenAgentChat, .greg)
    }
}
```

- [ ] **Step 6: Run it — verify FAIL**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/CoordinatorNavTests 2>&1 | tail -20`
Expected: FAIL — members missing.

- [ ] **Step 7: Add coordinator intents + hook wiring**

In `AppCoordinator.swift` (an `@Observable @MainActor final class`), add:

```swift
    var pendingOpenSummaryBoard = false
    var pendingOpenAgentChat: AgentIdentity?

    func requestOpenSummaryBoard() { pendingOpenSummaryBoard = true }
    func requestOpenAgentChat(_ agent: AgentIdentity) { pendingOpenAgentChat = agent }
```

In the coordinator's init (where `AppDelegate.dispatchProactive` is wired), add:

```swift
        AppDelegate.openSummaryBoard = { [weak self] in
            Task { @MainActor in self?.requestOpenSummaryBoard() }
        }
        AppDelegate.openAgentChat = { [weak self] agent in
            Task { @MainActor in self?.requestOpenAgentChat(agent) }
        }
```

- [ ] **Step 8: Run it — verify PASS**

Run: `cd ios/JarvisApp && xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/CoordinatorNavTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Route taps in AppDelegate**

In `JarvisApp.swift` `AppDelegate`, add the static hooks next to `dispatchProactive`:

```swift
    static var openSummaryBoard: (() -> Void)?
    static var openAgentChat: ((AgentIdentity) -> Void)?
```

Replace the body of `userNotificationCenter(_:didReceive:withCompletionHandler:)` with router-driven dispatch (keeps the existing reply behavior):

```swift
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        let target = NotificationTapRouter.route(
            categoryId: response.notification.request.content.categoryIdentifier,
            actionId: response.actionIdentifier,
            replyText: replyText,
            userInfo: response.notification.request.content.userInfo
        )
        switch target {
        case let .reply(agentId, text):
            NotificationReplySender.shared.send(agentId: agentId, text: text) { _ in completionHandler() }
            return
        case .openSummaryBoard:
            AppDelegate.openSummaryBoard?()
        case let .openAgentChat(agent):
            AppDelegate.openAgentChat?(agent)
        case .none:
            break
        }
        completionHandler()
    }
```

- [ ] **Step 10: Apply intents in ContentView (incl. cold launch)**

In `ContentView.swift`, add modifiers to the root `ZStack` (the view owning `appPhase`):

```swift
        .onChange(of: coordinator.pendingOpenAgentChat) { _, _ in applyPendingNav() }
        .onChange(of: coordinator.pendingOpenSummaryBoard) { _, _ in applyPendingNav() }
        .onChange(of: coordinator.connectionPhase) { _, _ in applyPendingNav() }
```

Add the method (in the `ContentView` struct; `active` is its existing `@Environment(ActiveAgentState.self)`, `appPhase` its `@State`):

```swift
    private func applyPendingNav() {
        // Wait past splash on cold launch — only navigate once connected.
        guard coordinator.connectionPhase == .connected else { return }
        if let agent = coordinator.pendingOpenAgentChat {
            active.active = agent
            coordinator.pendingOpenAgentChat = nil
            withAnimation(.easeOut(duration: 0.4)) { appPhase = .chat }
        } else if coordinator.pendingOpenSummaryBoard {
            // Ensure home is mounted; OrbHomeView presents the board sheet.
            withAnimation(.easeOut(duration: 0.4)) { appPhase = .home }
        }
    }
```

- [ ] **Step 11: Open the board in OrbHomeView**

In `OrbHomeView.swift`, on the view owning the `.sheet(isPresented: $showStateBoard)`:

```swift
        .onAppear { openSummaryBoardIfRequested() }
        .onChange(of: coordinator.pendingOpenSummaryBoard) { _, _ in openSummaryBoardIfRequested() }
```

Add the method:

```swift
    private func openSummaryBoardIfRequested() {
        guard coordinator.pendingOpenSummaryBoard else { return }
        showStateBoard = true
        coordinator.pendingOpenSummaryBoard = false
    }
```

(`coordinator` is already `var coordinator: AppCoordinator` on `OrbHomeView`.)

- [ ] **Step 12: Full clean build + test**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **` (whole JarvisAppTests suite green, clean build).

- [ ] **Step 13: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/NotificationTapRouter.swift ios/JarvisApp/Sources/JarvisApp/Services/AppCoordinator.swift ios/JarvisApp/Sources/JarvisApp/JarvisApp.swift ios/JarvisApp/Sources/JarvisApp/Views/ContentView.swift ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift ios/JarvisApp/Sources/JarvisAppTests/NotificationTapRouterTests.swift ios/JarvisApp/Sources/JarvisAppTests/CoordinatorNavTests.swift
git commit -m "feat(ios): deep-link nav — summary tap → board, chat tap → agent chat"
```

---

## Task 14: iOS version bump + final build

**Files:**
- Modify: `ios/JarvisApp/project.yml` (`CURRENT_PROJECT_VERSION` + `MARKETING_VERSION`)

Per the project rule: any iOS change bumps `CURRENT_PROJECT_VERSION`; a new feature bumps `MARKETING_VERSION`.

- [ ] **Step 1: Bump versions**

In `project.yml` `settings.base`: bump `CURRENT_PROJECT_VERSION` "74" → "75", and `MARKETING_VERSION` "1.16.0" → "1.17.0".

(Confirm the current values first — if a prior build already advanced them, increment from the actual current values.)

- [ ] **Step 2: Regenerate + clean build + full test**

Run:
```bash
cd ios/JarvisApp && xcodegen generate && \
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Verify pbxproj diff is only the version bump**

Run: `git diff --stat ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj`
Expected: only `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` lines changed (×2 each).

- [ ] **Step 4: Commit**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "chore(ios): bump build 75 / 1.17.0 — сводка-ready notification"
```

---

## Task 15: Deploy host + verify

**Files:** none (deploy + verification only)

- [ ] **Step 1: Push host + protocol**

```bash
git push origin main
```

- [ ] **Step 2: Deploy on VDS**

```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -lc "cd /home/nanoclaw/nanoclaw && git pull --ff-only && pnpm install --frozen-lockfile && pnpm run build"'
```
Then restart the host: `systemctl --user restart nanoclaw` (run with the XDG/DBUS env the VDS workflow requires — see memory `reference_vds_workflow`).

- [ ] **Step 3: Confirm migration applied**

```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -lc "cd /home/nanoclaw/nanoclaw && pnpm exec tsx scripts/q.ts data/v2.db \"SELECT name FROM schema_version WHERE name = '\''summary-notify-log'\''\""'
```
Expected: one row `summary-notify-log`.

- [ ] **Step 4: Real verification (next morning batch)**

The detector only fires inside the 08:40–09:15 WITA window. After the host is live, the next 08:45 WITA publish batch should produce one `summary_ready` notification once cards settle. Confirm via host log:

```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -lc "cd /home/nanoclaw/nanoclaw && grep -a \"Summary-ready notification emitted\" logs/nanoclaw.log | tail -3"'
```
Expected (after ~08:50 WITA): a line with `personKey=owner`, `count=N`.

(Optional same-day smoke test without waiting: temporarily set the detector window/now via a one-off tsx that calls `runSummaryNotify` with an injected `nowMs` inside the window and a fake `emit` that logs — proves wiring end to end without touching production state. Do NOT inject a real device notification outside the morning unless you intend to.)

- [ ] **Step 5: Install iOS build 75** — user builds + installs on his Mac (notification + board tap ship in build 75).

---

## Self-review notes

- **Spec coverage:** flow (T6/T7/T8), debounce detector (T4), morning-window + once/day (T4/T6), protocol envelope (T1), NOTIFY_TYPES + pull body (T2/T8), iOS notify-only no-bubble (T11), gating + «Сводка» toggle (T10/T12), deep-link nav — summary tap→board + chat tap→agent chat, incl. cold launch (Component 5 → T13), tests every task, version bump (T14), owner-only + deploy (T8 device query / T15). All spec sections map to a task.
- **Type consistency:** `summary_ready` (wire) ↔ `.summaryReady` (Swift) ↔ `SummaryReady` payload `{date, count, text?, agent_id?}` consistent across T1/T8/T9/T11. `SummaryPayload {date,count}` (host registry) vs envelope payload (adds `text`,`agent_id` at emit) — intentional: the registry passes minimal data; the channel composes the body. `decideSummaryNotify` / `runSummaryNotify` / `registerSummaryEmitter` / `getDevicePlatformIds` names consistent across T4/T5/T6/T7/T8. Nav (T13): `NotificationTapTarget` cases ↔ `AppCoordinator.pendingOpenSummaryBoard`/`pendingOpenAgentChat` ↔ `AppDelegate.openSummaryBoard`/`openAgentChat` hooks ↔ category ids `summary-ready`/`agent-message` — consistent; `AgentIdentity(rawValue:)` is the single slug→enum map.
- **Placeholders:** none — every code step shows real code. Harness-specific helper names (iOS `MockCenter`, `makeTransportHarness`; host `makeQueue`, `testing/harness.ts`) are flagged to match the existing test files because those are pre-existing test utilities the implementer must read, not invent.
