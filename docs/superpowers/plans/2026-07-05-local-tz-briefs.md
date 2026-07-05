# Local-Timezone Briefs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scheduled recurring tasks fire on the owner's current device timezone (auto-captured from the iPhone) instead of the single global `TIMEZONE`, so a traveler's 09:00 brief lands at 09:00 wherever they are.

**Architecture:** iPhone stamps its IANA zone on the background pending-pull → host stores it per person in a new `person_tz` table → `recurrence.ts` and the Сводка-ready detector resolve the owner's tz (falling back to the global). Host + iOS only; the agent-runner and the container clock are untouched. Off-once-then-corrects semantics (the next-run frozen before landing keeps the old zone; every day after is exact).

**Tech Stack:** Node host (TypeScript, `better-sqlite3`, `cron-parser`, vitest), SwiftUI iOS app (XCTest), central `data/v2.db`.

**Spec:** `docs/superpowers/specs/2026-07-05-local-tz-briefs-design.md`

**Isolation:** Run on a git worktree with append-only commits (this repo has concurrent Claude sessions committing to `main`); merge at the end.

---

## File Structure

- `src/db/migrations/024-person-tz.ts` — new `person_tz` table. Registered in `migrations/index.ts`.
- `src/modules/person-tz/db.ts` — `upsertPersonTz` / `getPersonTz` (pure DB, injected `db`).
- `src/modules/person-tz/index.ts` — `noteDeviceTz` / `resolveOwnerTz` (validation + `getDb()`; best-effort, fully guarded).
- `src/modules/person-tz/person-tz.test.ts` — migration + db + module tests.
- `src/modules/scheduling/recurrence.ts` — parse cron in owner tz.
- `src/modules/summary-notify/sweep.ts` — per-owner detector tz.
- `src/channels/ios-app/v2/http-handler.ts` — stamp tz on `/ios/pending` + `/ios/proactive`.
- `ios/…/Utility/ServerConfig.swift` — `httpURL(path:queryItems:)` overload.
- `ios/…/Services/PendingNotifications.swift` — send `tz` query item.
- `ios/…/JarvisAppTests/ServerConfigTests.swift` — overload test.
- `ios/JarvisApp/project.yml` + regenerated `pbxproj` — version bump.

No `src/modules/index.ts` change: `person-tz` is imported directly (like `typing`/`mount-security`), not a self-registering registry module. Only the migration needs registering.

---

## Task 1: Migration `024-person-tz`

**Files:**
- Create: `src/db/migrations/024-person-tz.ts`
- Modify: `src/db/migrations/index.ts`
- Test: `src/modules/person-tz/person-tz.test.ts` (created here; extended in Tasks 2–3)

- [ ] **Step 1: Write the failing test**

Create `src/modules/person-tz/person-tz.test.ts`:
```ts
import { describe, it, expect, beforeEach } from 'vitest';
import Database from 'better-sqlite3';

import { runMigrations } from '../../db/migrations/index.js';

describe('migration 024 person_tz', () => {
  let db: Database.Database;
  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  it('creates the person_tz table', () => {
    const t = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='person_tz'").get();
    expect(t).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/modules/person-tz/person-tz.test.ts`
Expected: FAIL — table `person_tz` does not exist.

- [ ] **Step 3: Create the migration**

Create `src/db/migrations/024-person-tz.ts`:
```ts
import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration024: Migration = {
  version: 24,
  name: 'person-tz',
  up(db: Database.Database) {
    // Last-known device timezone per person (person_key == session.owner_key ==
    // ios person_key). Populated from iOS requests that carry an IANA tz; read
    // by recurrence + the Сводка-ready detector so scheduled tasks fire on the
    // owner's current wall-clock. Separate from ios_tokens because token re-mint
    // DELETEs that row; this must survive it.
    db.prepare(
      `CREATE TABLE person_tz (
         person_key TEXT PRIMARY KEY,
         tz         TEXT NOT NULL,
         updated_at TEXT NOT NULL
       )`,
    ).run();
  },
};
```

- [ ] **Step 4: Register the migration**

In `src/db/migrations/index.ts`, add the import after the `migration023` import:
```ts
import { migration024 } from './024-person-tz.js';
```
and append `migration024,` to the `migrations` array after `migration023,`.

- [ ] **Step 5: Run test to verify it passes**

Run: `pnpm exec vitest run src/modules/person-tz/person-tz.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/db/migrations/024-person-tz.ts src/db/migrations/index.ts src/modules/person-tz/person-tz.test.ts
git commit -m "feat(tz): migration 024 person_tz table"
```

---

## Task 2: `person-tz/db.ts` — upsert / get

**Files:**
- Create: `src/modules/person-tz/db.ts`
- Test: `src/modules/person-tz/person-tz.test.ts` (append)

- [ ] **Step 1: Write the failing test**

Add `import { upsertPersonTz, getPersonTz } from './db.js';` to the **top** import area of `src/modules/person-tz/person-tz.test.ts`, then append this describe block at the end:
```ts
describe('person_tz db', () => {
  let db: Database.Database;
  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  it('inserts then reads back a tz', () => {
    upsertPersonTz(db, 'p1', 'Europe/London', '2026-07-05T00:00:00Z');
    expect(getPersonTz(db, 'p1')).toBe('Europe/London');
  });

  it('returns null for an unknown person', () => {
    expect(getPersonTz(db, 'nobody')).toBeNull();
  });

  it('updates tz + updated_at when the zone changes', () => {
    upsertPersonTz(db, 'p1', 'Europe/London', '2026-07-05T00:00:00Z');
    upsertPersonTz(db, 'p1', 'Asia/Tokyo', '2026-07-06T00:00:00Z');
    const row = db.prepare('SELECT tz, updated_at FROM person_tz WHERE person_key=?').get('p1') as {
      tz: string;
      updated_at: string;
    };
    expect(row.tz).toBe('Asia/Tokyo');
    expect(row.updated_at).toBe('2026-07-06T00:00:00Z');
  });

  it('leaves updated_at untouched when the same zone is re-reported', () => {
    upsertPersonTz(db, 'p1', 'Europe/London', '2026-07-05T00:00:00Z');
    upsertPersonTz(db, 'p1', 'Europe/London', '2026-07-09T00:00:00Z');
    const row = db.prepare('SELECT updated_at FROM person_tz WHERE person_key=?').get('p1') as {
      updated_at: string;
    };
    expect(row.updated_at).toBe('2026-07-05T00:00:00Z'); // "here since" — unchanged
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/modules/person-tz/person-tz.test.ts`
Expected: FAIL — cannot import `./db.js`.

- [ ] **Step 3: Write the implementation**

Create `src/modules/person-tz/db.ts`:
```ts
import type Database from 'better-sqlite3';

export interface PersonTzRow {
  person_key: string;
  tz: string;
  updated_at: string;
}

/**
 * Upsert a person's last-known tz. Last-writer-wins on the zone, but the
 * ON CONFLICT WHERE guard skips the UPDATE when the zone is unchanged, so
 * `updated_at` keeps its "here since" meaning.
 */
export function upsertPersonTz(db: Database.Database, personKey: string, tz: string, updatedAt: string): void {
  db.prepare(
    `INSERT INTO person_tz (person_key, tz, updated_at)
     VALUES (@person_key, @tz, @updated_at)
     ON CONFLICT(person_key) DO UPDATE SET tz = excluded.tz, updated_at = excluded.updated_at
       WHERE person_tz.tz <> excluded.tz`,
  ).run({ person_key: personKey, tz, updated_at: updatedAt });
}

/** Read a person's stored tz, or null. */
export function getPersonTz(db: Database.Database, personKey: string): string | null {
  const row = db.prepare('SELECT tz FROM person_tz WHERE person_key = ?').get(personKey) as
    | { tz: string }
    | undefined;
  return row?.tz ?? null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/modules/person-tz/person-tz.test.ts`
Expected: PASS (all describes).

- [ ] **Step 5: Commit**

```bash
git add src/modules/person-tz/db.ts src/modules/person-tz/person-tz.test.ts
git commit -m "feat(tz): person_tz upsert/get db layer"
```

---

## Task 3: `person-tz/index.ts` — noteDeviceTz / resolveOwnerTz

**Files:**
- Create: `src/modules/person-tz/index.ts`
- Test: `src/modules/person-tz/person-tz.test.ts` (append)

- [ ] **Step 1: Write the failing test**

At the **top** of `src/modules/person-tz/person-tz.test.ts`: merge `afterEach` into the existing `from 'vitest'` import, and add:
```ts
import { initTestDb, getDb, closeDb } from '../../db/connection.js';
import { noteDeviceTz, resolveOwnerTz } from './index.js';
```
Then append this describe block at the end:
```ts
describe('noteDeviceTz / resolveOwnerTz (via central getDb)', () => {
  beforeEach(() => {
    initTestDb();
    runMigrations(getDb());
  });
  afterEach(() => closeDb());

  it('stores a valid IANA tz and resolves it back', () => {
    noteDeviceTz('p1', 'Asia/Tokyo');
    expect(resolveOwnerTz('p1')).toBe('Asia/Tokyo');
  });

  it('ignores a non-IANA tz (no row, no throw)', () => {
    noteDeviceTz('p2', 'Mars/Phobos');
    noteDeviceTz('p2', '');
    expect(resolveOwnerTz('p2')).toBeNull();
  });

  it('resolveOwnerTz short-circuits to null on empty/undefined owner', () => {
    expect(resolveOwnerTz(null)).toBeNull();
    expect(resolveOwnerTz(undefined)).toBeNull();
    expect(resolveOwnerTz('')).toBeNull();
  });

  it('resolveOwnerTz returns null for an owner with no stored tz', () => {
    expect(resolveOwnerTz('never-reported')).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/modules/person-tz/person-tz.test.ts`
Expected: FAIL — cannot import `./index.js`.

- [ ] **Step 3: Write the implementation**

Create `src/modules/person-tz/index.ts`:
```ts
/**
 * Per-person last-known device timezone.
 *
 * `noteDeviceTz` is called from iOS request handlers that carry an IANA tz
 * (the background pending-pull + proactive triggers). `resolveOwnerTz` is
 * called from scheduling (recurrence + the Сводка-ready detector) to fire on
 * the owner's current wall-clock, falling back to the global TIMEZONE when a
 * person has never reported. Both are best-effort — a failure here must never
 * break request handling or scheduling.
 */
import { getDb } from '../../db/connection.js';
import { isValidTimezone } from '../../timezone.js';
import { log } from '../../log.js';
import { getPersonTz, upsertPersonTz } from './db.js';

/** Record a device-reported tz. Silently ignores junk / non-IANA values. */
export function noteDeviceTz(personKey: string, rawTz: unknown): void {
  try {
    if (typeof personKey !== 'string' || personKey.length === 0) return;
    if (typeof rawTz !== 'string' || !isValidTimezone(rawTz)) return;
    upsertPersonTz(getDb(), personKey, rawTz, new Date().toISOString());
  } catch (err) {
    log.warn('noteDeviceTz failed', { err });
  }
}

/** Owner's current tz for scheduling, or null → caller falls back to global. */
export function resolveOwnerTz(ownerKey: string | null | undefined): string | null {
  if (!ownerKey) return null;
  try {
    const tz = getPersonTz(getDb(), ownerKey);
    return tz && isValidTimezone(tz) ? tz : null;
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/modules/person-tz/person-tz.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/modules/person-tz/index.ts src/modules/person-tz/person-tz.test.ts
git commit -m "feat(tz): noteDeviceTz + resolveOwnerTz module"
```

---

## Task 4: recurrence parses cron in the owner's tz

**Files:**
- Modify: `src/modules/scheduling/recurrence.ts`
- Test: `src/modules/scheduling/recurrence.test.ts` (append)

- [ ] **Step 1: Write the failing test**

In `src/modules/scheduling/recurrence.test.ts`, add imports at the top:
```ts
import { initTestDb, getDb, closeDb } from '../../db/connection.js';
import { runMigrations } from '../../db/migrations/index.js';
import { upsertPersonTz } from '../person-tz/db.js';
```
and add this test inside `describe('handleRecurrence', ...)`:
```ts
it('computes the next run on the owner’s stored timezone (09:00 there)', async () => {
  initTestDb();
  runMigrations(getDb());
  upsertPersonTz(getDb(), 'owner-london', 'Europe/London', new Date('2026-07-01T00:00:00Z').toISOString());
  try {
    const db = freshDb();
    insertTask(db, {
      id: 'task-tz',
      processAfter: '2020-01-01T00:00:00.000Z',
      recurrence: '0 9 * * *',
      platformId: null,
      channelType: null,
      threadId: null,
      content: JSON.stringify({ prompt: 'brief' }),
    });
    db.prepare(`UPDATE messages_in SET status='completed' WHERE id='task-tz'`).run();

    await handleRecurrence(db, { ...fakeSession(), owner_key: 'owner-london' } as Session);

    const follow = db.prepare(`SELECT process_after FROM messages_in WHERE id != 'task-tz'`).get() as {
      process_after: string;
    };
    // DST-proof: assert the wall-clock in Europe/London is exactly 09:00.
    const parts = new Intl.DateTimeFormat('en-GB', {
      timeZone: 'Europe/London',
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    }).formatToParts(new Date(follow.process_after));
    const hour = parts.find((p) => p.type === 'hour')!.value;
    const minute = parts.find((p) => p.type === 'minute')!.value;
    expect(`${hour}:${minute}`).toBe('09:00');
  } finally {
    closeDb();
  }
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/modules/scheduling/recurrence.test.ts`
Expected: FAIL — next run is computed in the global `TIMEZONE`, so its Europe/London wall-clock is not 09:00 (unless the global happens to be Europe/London).

- [ ] **Step 3: Modify `recurrence.ts`**

Add the import near the other imports:
```ts
import { resolveOwnerTz } from '../person-tz/index.js';
```
Replace the cron-parse line:
```ts
      const interval = CronExpressionParser.parse(msg.recurrence, { tz: TIMEZONE });
```
with:
```ts
      const ownerTz = resolveOwnerTz(session.owner_key) ?? TIMEZONE;
      const interval = CronExpressionParser.parse(msg.recurrence, { tz: ownerTz });
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/modules/scheduling/recurrence.test.ts`
Expected: PASS. The two pre-existing tests (fakeSession has no `owner_key` → `resolveOwnerTz` short-circuits to null → global fallback) stay green.

- [ ] **Step 5: Commit**

```bash
git add src/modules/scheduling/recurrence.ts src/modules/scheduling/recurrence.test.ts
git commit -m "feat(tz): recurrence fires on the owner's timezone"
```

---

## Task 5: Сводка-ready detector uses the owner's tz

**Files:**
- Modify: `src/modules/summary-notify/sweep.ts`
- Test: `src/modules/summary-notify/sweep.test.ts` (append)

- [ ] **Step 1: Write the failing test**

In `src/modules/summary-notify/sweep.test.ts`, add imports:
```ts
import { initTestDb, getDb, closeDb } from '../../db/connection.js';
import { upsertPersonTz } from '../person-tz/db.js';
```
and add this test (Tokyo is UTC+9; a Tokyo person's morning window sits at a different UTC instant than WITA's, so cards written at 08:46 **Tokyo** must be seen as "this morning" only when the detector uses Tokyo):
```ts
it('resolves the per-owner tz into the detector cfg (Tokyo person)', () => {
  initTestDb();
  runMigrations(getDb());
  upsertPersonTz(getDb(), 'tokyo-person', 'Asia/Tokyo', '2026-06-30T00:00:00Z');
  try {
    const tokyoToUtcMs = (h: number, m: number) => Date.UTC(2026, 5, 30, h - 9, m, 0);
    writeCard('tokyo-person', 'jarvis', tokyoToUtcMs(8, 46));
    writeCard('tokyo-person', 'greg', tokyoToUtcMs(8, 47));
    const calls: Array<{ p: string; c: number }> = [];
    runSummaryNotify({
      userMemoryBase: dir,
      db: getDb(),
      nowMs: tokyoToUtcMs(8, 51), // settled, in Tokyo's window
      cfg: DEFAULT_SUMMARY_CFG, // default tz is Asia/Makassar — must be overridden per owner
      emit: (personKey, payload) => calls.push({ p: personKey, c: payload.count }),
    });
    expect(calls).toEqual([{ p: 'tokyo-person', c: 2 }]);
  } finally {
    closeDb();
  }
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/modules/summary-notify/sweep.test.ts`
Expected: FAIL — with the hardcoded Makassar cfg, 08:46 Tokyo (= 23:46 UTC prev day = 07:46 WITA) is read on the wrong date/window, so no fire.

- [ ] **Step 3: Modify `sweep.ts`**

Add the import:
```ts
import { resolveOwnerTz } from '../person-tz/index.js';
```
Inside the `for (const p of persons)` loop, replace the `decideSummaryNotify({...})` call so it uses a per-owner cfg:
```ts
    const cfg = { ...deps.cfg, tz: resolveOwnerTz(personKey) ?? deps.cfg.tz };
    const decision = decideSummaryNotify({
      nowMs: deps.nowMs,
      cardMtimesMs,
      lastNotifiedDate: getLastNotified(deps.db, personKey),
      cfg,
    });
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/modules/summary-notify/sweep.test.ts`
Expected: PASS. Existing tests stay green — their `getDb()` is uninitialized, so `resolveOwnerTz` catches and returns null → falls back to the passed-in `deps.cfg.tz` (Makassar).

- [ ] **Step 5: Commit**

```bash
git add src/modules/summary-notify/sweep.ts src/modules/summary-notify/sweep.test.ts
git commit -m "feat(tz): Сводка-ready detector uses the owner's timezone"
```

---

## Task 6: host stamps the device tz on iOS requests

**Files:**
- Modify: `src/channels/ios-app/v2/http-handler.ts`
- Test: `src/channels/ios-app/v2/http-routes.test.ts` (append)

- [ ] **Step 1: Write the failing test**

In `src/channels/ios-app/v2/http-routes.test.ts`, add imports at the top:
```ts
import { initTestDb, getDb, closeDb } from '../../../db/connection.js';
import { runMigrations } from '../../../db/migrations/index.js';
import { getPersonTz } from '../../../modules/person-tz/db.js';
```
Add a new `describe` block (its own central DB — the default harness runs without one):
```ts
describe('device tz capture', () => {
  let h: Harness;
  beforeEach(async () => {
    initTestDb();
    runMigrations(getDb());
    h = await bootHarness();
  });
  afterEach(async () => {
    await h.close();
    closeDb();
  });

  it('GET /ios/pending?tz=… stores the caller’s timezone', async () => {
    const r = await fetchJson(`${h.url}/ios/pending?tz=Europe/London`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    expect(getPersonTz(getDb(), PERSON)).toBe('Europe/London');
  });

  it('ignores a junk tz (no row written)', async () => {
    const r = await fetchJson(`${h.url}/ios/pending?tz=Mars/Phobos`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    expect(getPersonTz(getDb(), PERSON)).toBeNull();
  });
});
```
> Note: confirm `bootHarness`, `fetchJson`, `Harness`, `TOKEN`, `PERSON` are visible at this point in the file (they are module-level in `http-routes.test.ts`). If `fetchJson` is defined lower, hoist the new `describe` below it or move the helper up.

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts`
Expected: FAIL — `getPersonTz` returns null; the handler doesn't stamp yet.

- [ ] **Step 3: Modify `http-handler.ts`**

Add the import near the top:
```ts
import { noteDeviceTz } from '../../../modules/person-tz/index.js';
```
In the `GET /ios/pending` block, right after the `if (!id) {…401…}` guard:
```ts
      noteDeviceTz(id.person_key, url.searchParams.get('tz') ?? '');
```
In the `POST /ios/proactive` block, right after `const tz = obj.tz ?? '';`:
```ts
          noteDeviceTz(id.person_key, tz);
```
(`noteDeviceTz` is guarded — empty/invalid tz is a silent no-op, and it never throws into the request path.)

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts`
Expected: PASS (new + existing route tests).

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/http-handler.ts src/channels/ios-app/v2/http-routes.test.ts
git commit -m "feat(tz): stamp device tz on /ios/pending + /ios/proactive"
```

---

## Task 7: iOS sends its timezone + version bump

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Utility/ServerConfig.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/PendingNotifications.swift:34`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/ServerConfigTests.swift`
- Modify: `ios/JarvisApp/project.yml` (+ regenerated `pbxproj`)

- [ ] **Step 1: Write the failing test**

Append to `ServerConfigTests.swift`:
```swift
    func test_httpURL_appendsQueryItems() {
        let url = ServerConfig.httpURL(
            path: "ios/pending",
            queryItems: [URLQueryItem(name: "tz", value: "Europe/London")]
        )
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/ios/pending")
        XCTAssertTrue(comps.queryItems!.contains(URLQueryItem(name: "tz", value: "Europe/London")))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `ios/JarvisApp`): `xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/ServerConfigTests`
Expected: FAIL / does-not-compile — no `httpURL(path:queryItems:)` overload.

- [ ] **Step 3: Add the overload**

In `ServerConfig.swift`, add after the existing `httpURL(path:)`:
```swift
    /// `httpURL(path:)` with query items appended via `URLComponents`. Used by
    /// the background pending-pull to report the device timezone. `nil` if the
    /// base path isn't a valid URL.
    static func httpURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        guard let base = httpURL(path: path),
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = queryItems
        return comps.url
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:JarvisAppTests/ServerConfigTests`
Expected: PASS.

- [ ] **Step 5: Send the tz on the pending pull**

In `PendingNotifications.swift`, replace the URL guard at line 34:
```swift
        guard let url = ServerConfig.httpURL(path: "ios/pending") else {
            completion?(); return
        }
```
with:
```swift
        guard let url = ServerConfig.httpURL(
            path: "ios/pending",
            queryItems: [URLQueryItem(name: "tz", value: TimeZone.current.identifier)]
        ) else {
            completion?(); return
        }
```

- [ ] **Step 6: Version bump + regenerate**

In `ios/JarvisApp/project.yml`, bump `CURRENT_PROJECT_VERSION` by 1 and `MARKETING_VERSION` by a minor (user-visible behavior). Read the current values first:
```bash
grep -nE 'CURRENT_PROJECT_VERSION|MARKETING_VERSION' ios/JarvisApp/project.yml
```
Then regenerate the pbxproj:
```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 7: Clean build + full test target**

Run: `xcodebuild build test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED, all `JarvisAppTests` pass. **No prod-token connection** (per repo policy — verification is unit tests + clean build only).

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Utility/ServerConfig.swift \
        ios/JarvisApp/Sources/JarvisApp/Services/PendingNotifications.swift \
        ios/JarvisApp/Sources/JarvisAppTests/ServerConfigTests.swift \
        ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit -m "feat(tz): iOS reports device timezone on the pending pull"
```

---

## Task 8: Full verify + host deploy

**Files:** none (verification + deploy).

- [ ] **Step 1: Host — full test suite + typecheck + build**

```bash
pnpm test
pnpm exec tsc -p tsconfig.json --noEmit
pnpm run build
```
Expected: all green (host vitest full suite, typecheck clean, build succeeds).

- [ ] **Step 2: Merge the worktree branch to main**

Follow superpowers:finishing-a-development-branch. Fast-forward / append-only merge onto `main`; push.

- [ ] **Step 3: Deploy host to the VDS**

```bash
ssh root@148.253.211.164 "cd /home/nanoclaw/nanoclaw && sudo -u nanoclaw git pull && sudo -u nanoclaw pnpm run build"
ssh root@148.253.211.164 "sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/\$(id -u nanoclaw) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u nanoclaw)/bus systemctl --user restart nanoclaw"
```
Migration 024 runs on startup. Verify:
```bash
ssh root@148.253.211.164 "cd /home/nanoclaw/nanoclaw && sudo -u nanoclaw pnpm exec tsx scripts/q.ts data/v2.db \"SELECT name FROM sqlite_master WHERE type='table' AND name='person_tz'\""
```
Expected: prints `person_tz`. (Exact VDS path / restart env per the VDS-workflow memory; adjust if the checkout dir differs.)

- [ ] **Step 4: Handoff — iOS build + behavioral check (user)**

The host tolerates the old iOS build (no tz reported → global fallback = current behavior). Once the user installs the new build, the phone starts reporting its zone. Confirm end-to-end after a real or simulated zone change:
```bash
ssh root@148.253.211.164 "cd /home/nanoclaw/nanoclaw && sudo -u nanoclaw pnpm exec tsx scripts/q.ts data/v2.db 'SELECT person_key, tz, updated_at FROM person_tz'"
```
Expected: a row appears for the owner with the device's current IANA tz after the app has run a pending-pull.

---

## Notes for the executor

- **TIMEZONE fallback is load-bearing:** every `resolveOwnerTz` returns null for an unknown/never-reported owner, so behavior is identical to today until the phone reports. Don't "helpfully" default to anything else.
- **Container clock is a deliberate non-goal:** do not touch `container-runner.ts`'s `TZ=${TIMEZONE}`. Flipping it would shift greg/scrooge date-boundary logic.
- **agent-runner is untouched:** this feature is host + iOS only. No `container/agent-runner/` changes, no image rebuild.
- **Deploy order is free:** host can ship before the iOS build lands.
