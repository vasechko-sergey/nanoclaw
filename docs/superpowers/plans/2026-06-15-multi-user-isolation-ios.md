# Multi-user isolation — iOS multi-user (phases 5–7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a second person a distinct iOS identity so her iPhone reaches the same 5 agents (jarvis/greg/gordon/payne/scrooge) with her own private memory + health data — closing the iOS half of multi-user isolation that the host core (phases 1–4) already established for Telegram.

**Architecture:** An `ios_tokens` registry maps each bearer token → `{platform_id, person_key}`. Both the WebSocket auth (`validateToken`) and the HTTP routes (`requireToken`) resolve identity through it; on auth a `users` row is upserted (`id=platform_id, person_key=…`) so the existing `resolvePersonKey` chain stamps `session.owner_key`. The iOS inbound path (`adapter-route.ts`) passes that owner through to `resolveSession`. Health uploads + `/ios/state` route by the token's person into `user-memory/<person>/…`. The second person is provisioned by minting a token and wiring her one iOS messaging-group to all 5 agent groups.

**Tech Stack:** Node + TypeScript host, `better-sqlite3`, Vitest. **No Swift/Xcode changes** — the app already has a user-entered server-URL + token (`ios/JarvisApp/.../Models/AppSettings.swift`) and a hardcoded all-agent picker (`.../Models/AgentIdentity.swift`).

**Depends on:** phases 1–4 (merged to `main` at `405b89c`): `users.person_key`, `sessions.owner_key`, `resolvePersonKey`, owner-aware `buildMounts`, `user-memory.ts` (`userMemoryRoot`/`userGlobalRoot`/`initUserMemory`).

**Spec:** [docs/superpowers/specs/2026-06-15-multi-user-memory-isolation-design.md](../specs/2026-06-15-multi-user-memory-isolation-design.md) §8, §15.

---

## Prerequisite findings (from the phase-1–4 final review + iOS code read)

- **`src/adapter-route.ts`** (iOS inbound) has 3 `resolveSession(...)` calls (lines 95, 118, 136) that omit the owner key — Task 3 below fixes them (spec §15.1).
- **`src/modules/health-trigger/sick-day.ts`** wakes a health-agent session; must target the person's session under multi-user (Task 6).
- **iOS WS auth** sends only `token` (`ios/JarvisApp/.../Services/TransportV2.swift:106-114`, `Protocol/V2.swift:90-94`) — no device_id — so the token alone is the discriminator. Good: a per-person token suffices, no protocol change.
- **HTTP routes** (`src/channels/ios-app/v2/http-handler.ts`) auth with a single shared `Bearer ${token}` (line 88) and health-upload routing currently keys off `IOS_HEALTH_HISTORY_DIR` override or `resolveAgentFolderForPlatform(body.platformId)`. Both become token→person routing.
- **`validateToken`** today (`src/channels/ios-app/v2/index.ts:383-401`) returns the constant `ios-app-v2:default` for any matching token.

**Deploy-ordering (spec §15.2):** this plan's health-ingest re-path (Task 5) is the piece that must ship *with* the phase-1–4 migration. Sequence the VDS rollout as: deploy (1–4 + this plan) → stop service → back up → run `migrate-owner-memory.ts` → unset `IOS_HEALTH_HISTORY_DIR` → restart → provision the second person.

---

## File Structure

**Create:**
- `src/db/migrations/017-ios-tokens.ts` — `ios_tokens` table.
- `src/channels/ios-app/v2/token-registry.ts` — token CRUD + `resolveIosToken(rawToken) → {platform_id, person_key} | null` (+ sha256 hashing). One responsibility: the token→identity map.
- `src/channels/ios-app/v2/token-registry.test.ts`.
- `scripts/mint-ios-token.ts` — operator: mint a token for a person (insert registry row), print the token once.

**Modify:**
- `src/db/migrations/index.ts` — register migration 017.
- `src/config.ts` — add `HEALTH_AGENT_FOLDER` (default `'greg'`).
- `src/channels/ios-app/v2/index.ts` — `validateToken` → registry + upsert `users` row on auth; thread person resolution into the HTTP handler; seed the owner's `IOS_APP_TOKEN` on startup.
- `src/channels/ios-app/v2/http-handler.ts` — `requireToken` → registry (returns identity); `/ios/health/upload` writes to `user-memory/<person>/<HEALTH_AGENT_FOLDER>/health/`; `/ios/state` reads `user-memory/<person>/global/profiles/`; `/ios/health/requests` keyed by the token's platform_id.
- `src/adapter-route.ts` — pass `resolvePersonKey(userId)` to its 3 `resolveSession` calls.
- `src/modules/health-trigger/sick-day.ts` — target the person's health-agent session.

**No change:** the iOS Swift app, the WS protocol, `buildMounts`/`user-memory.ts` (already owner-aware).

---

## Phase 5 — host iOS multi-user identity

### Task 1: Migration 017 — `ios_tokens` table

**Files:** Create `src/db/migrations/017-ios-tokens.ts`; Modify `src/db/migrations/index.ts`; Test `src/db/db-v2.test.ts`.

- [ ] **Step 1: Write the migration.** Create `src/db/migrations/017-ios-tokens.ts`:

```typescript
import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration017: Migration = {
  version: 17,
  name: 'ios-tokens',
  up(db: Database.Database) {
    // Per-person iOS bearer tokens. token_hash = sha256(rawToken) hex — the
    // raw token is never stored. platform_id is the channel identity used for
    // the messaging_group; person_key stamps session.owner_key + per-person paths.
    db.exec(`
      CREATE TABLE IF NOT EXISTS ios_tokens (
        token_hash  TEXT PRIMARY KEY,
        platform_id TEXT NOT NULL UNIQUE,
        person_key  TEXT NOT NULL,
        label       TEXT,
        created_at  TEXT NOT NULL
      );
    `);
  },
};
```

- [ ] **Step 2: Register it.** In `src/db/migrations/index.ts`, import `migration017` after `migration016` and append it to the `migrations` array after `migration016`.

- [ ] **Step 3: Test the columns exist.** Append to `src/db/db-v2.test.ts` (use `getDb()`, own `beforeEach`/`afterEach` mirroring the other describes):

```typescript
describe('migration 017 ios_tokens', () => {
  beforeEach(() => { const db = initTestDb(); runMigrations(db); });
  afterEach(() => closeDb());
  it('creates ios_tokens with the expected columns', () => {
    const cols = getDb().prepare('PRAGMA table_info(ios_tokens)').all() as { name: string }[];
    const names = cols.map((c) => c.name).sort();
    expect(names).toEqual(['created_at', 'label', 'person_key', 'platform_id', 'token_hash']);
  });
});
```

- [ ] **Step 4: Run.** `pnpm exec vitest run src/db/db-v2.test.ts -t "migration 017"` → PASS.

- [ ] **Step 5: Commit.**
```bash
git add src/db/migrations/017-ios-tokens.ts src/db/migrations/index.ts src/db/db-v2.test.ts
git commit -m "feat(db): ios_tokens registry table (migration 017)"
```

### Task 2: Token registry module

**Files:** Create `src/channels/ios-app/v2/token-registry.ts`, `src/channels/ios-app/v2/token-registry.test.ts`.

- [ ] **Step 1: Write the test first.** Create `src/channels/ios-app/v2/token-registry.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { initTestDb, closeDb, runMigrations, getDb } from '../../../db/index.js';
import { upsertIosToken, resolveIosToken, hashToken } from './token-registry.js';

describe('ios token registry', () => {
  beforeEach(() => { const db = initTestDb(); runMigrations(db); });
  afterEach(() => closeDb());

  it('resolves a stored token to its platform_id + person_key', () => {
    upsertIosToken({ rawToken: 'secret-abc', platformId: 'ios-app-v2:p2', personKey: 'p2', label: 'anna phone' });
    expect(resolveIosToken('secret-abc')).toEqual({ platform_id: 'ios-app-v2:p2', person_key: 'p2' });
  });

  it('returns null for an unknown token', () => {
    expect(resolveIosToken('nope')).toBeNull();
  });

  it('stores only the hash of the token, never the raw value', () => {
    upsertIosToken({ rawToken: 'secret-abc', platformId: 'ios-app-v2:p2', personKey: 'p2', label: null });
    // hashToken is deterministic and not the identity function.
    expect(hashToken('secret-abc')).toBe(hashToken('secret-abc'));
    expect(hashToken('secret-abc')).not.toBe('secret-abc');
    // The persisted row holds the hash, and the raw token appears in no column.
    const row = getDb().prepare('SELECT * FROM ios_tokens WHERE platform_id = ?').get('ios-app-v2:p2') as Record<string, unknown>;
    expect(row.token_hash).toBe(hashToken('secret-abc'));
    expect(Object.values(row)).not.toContain('secret-abc');
  });

  it('upsert is idempotent on platform_id (re-mint updates the hash)', () => {
    upsertIosToken({ rawToken: 'old', platformId: 'ios-app-v2:p2', personKey: 'p2', label: null });
    upsertIosToken({ rawToken: 'new', platformId: 'ios-app-v2:p2', personKey: 'p2', label: null });
    expect(resolveIosToken('old')).toBeNull();
    expect(resolveIosToken('new')).toEqual({ platform_id: 'ios-app-v2:p2', person_key: 'p2' });
  });
});
```

- [ ] **Step 2: Run it (fails — module missing).** `pnpm exec vitest run src/channels/ios-app/v2/token-registry.test.ts` → FAIL.

- [ ] **Step 3: Implement.** Create `src/channels/ios-app/v2/token-registry.ts`:

```typescript
import { createHash } from 'node:crypto';

import { getDb } from '../../../db/connection.js';

export function hashToken(rawToken: string): string {
  return createHash('sha256').update(rawToken, 'utf8').digest('hex');
}

export interface IosTokenIdentity {
  platform_id: string;
  person_key: string;
}

/**
 * Insert or re-mint a token for a platform_id. Re-minting (same platform_id,
 * new raw token) replaces the row so the old hash stops resolving. person_key
 * stamps session.owner_key + per-person paths for this device's owner.
 */
export function upsertIosToken(args: {
  rawToken: string;
  platformId: string;
  personKey: string;
  label: string | null;
}): void {
  const db = getDb();
  // One platform_id ↔ one current token: clear any prior row for this
  // platform_id before inserting the new hash.
  db.prepare('DELETE FROM ios_tokens WHERE platform_id = ?').run(args.platformId);
  db.prepare(
    `INSERT INTO ios_tokens (token_hash, platform_id, person_key, label, created_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(token_hash) DO UPDATE SET
       platform_id = excluded.platform_id,
       person_key  = excluded.person_key,
       label       = excluded.label`,
  ).run(hashToken(args.rawToken), args.platformId, args.personKey, args.label, new Date().toISOString());
}

/** Resolve a raw bearer token to its identity, or null if unknown. */
export function resolveIosToken(rawToken: string): IosTokenIdentity | null {
  const row = getDb()
    .prepare('SELECT platform_id, person_key FROM ios_tokens WHERE token_hash = ?')
    .get(hashToken(rawToken)) as IosTokenIdentity | undefined;
  return row ?? null;
}
```

- [ ] **Step 4: Run.** `pnpm exec vitest run src/channels/ios-app/v2/token-registry.test.ts` → 4 PASS. NOTE: these are host tests but live under the container-adjacent `ios-app/v2` path — confirm they run under the host Vitest config (they import from `../../../db/index.js`, the host DB; the `ios-app/v2` tests like `transport-db.test.ts` already run under host Vitest). Then `pnpm run build` → clean.

- [ ] **Step 5: Commit.**
```bash
git add src/channels/ios-app/v2/token-registry.ts src/channels/ios-app/v2/token-registry.test.ts
git commit -m "feat(ios): token registry (token -> platform_id + person_key)"
```

### Task 3: `validateToken` via registry + owner_key for iOS sessions

**Files:** Modify `src/channels/ios-app/v2/index.ts`, `src/adapter-route.ts`. Test: `src/adapter-route.test.ts` (if present; else add a focused test).

This has two halves: (3a) auth resolves identity from the registry and makes `resolvePersonKey` work for the device; (3b) the iOS inbound path stamps the resolved owner.

- [ ] **Step 1 (3a): registry-backed `validateToken` + users-row upsert + owner backfill.** In `src/channels/ios-app/v2/index.ts`, add imports:

```typescript
import { resolveIosToken, upsertIosToken } from './token-registry.js';
import { upsertUser, getUser } from '../../../modules/permissions/db/users.js';
import { OWNER_PERSON_KEY } from '../../../config.js';
```

Replace the `validateToken` body (currently lines ~383-401, the single-token `clientToken !== token` check) with a registry lookup that also ensures a `users` row exists so `resolvePersonKey(platform_id)` resolves the person:

```typescript
    validateToken: async (clientToken) => {
      const identity = resolveIosToken(clientToken);
      if (!identity) return null;
      // Ensure a users row keyed by the platform_id carries this device's
      // person_key, so resolvePersonKey(senderId=platform_id) → person_key
      // and adapter-route stamps session.owner_key correctly.
      const existing = getUser(identity.platform_id);
      if (!existing || existing.person_key !== identity.person_key) {
        upsertUser({
          id: identity.platform_id,
          kind: CHANNEL_TYPE,
          display_name: existing?.display_name ?? null,
          person_key: identity.person_key,
          created_at: new Date().toISOString(),
        });
      }
      return identity.platform_id;
    },
```

Then, where the adapter is constructed (in `createV2Adapter`, after `const token = env.IOS_APP_TOKEN;` ~line 149), seed the owner's existing token into the registry on startup so the current single-token install keeps working with zero manual steps. Add right after the token is known and the DB is available (the host DB is initialized before adapters register):

```typescript
  // Back-compat: the legacy single shared token maps to the owner's existing
  // platform_id. Seeded idempotently so the owner's device keeps authenticating
  // after the cutover to the registry. New people get their own tokens via
  // scripts/mint-ios-token.ts.
  if (token) {
    try {
      upsertIosToken({ rawToken: token, platformId: `${CHANNEL_TYPE}:default`, personKey: OWNER_PERSON_KEY, label: 'owner (legacy IOS_APP_TOKEN)' });
    } catch (err) {
      logV2Warn('failed to seed owner ios token', { err: err instanceof Error ? err.message : String(err) });
    }
  }
```

(`token` may now be optional — the factory currently returns null if `!token`. Keep that guard: an install with no `IOS_APP_TOKEN` and an empty registry simply authenticates nobody until a token is minted. If you want the adapter to bind with only registry tokens, relax the `if (!token) return null;` at line 150 to also bind when `IOS_APP_V2_PORT` is set — but that is OPTIONAL; default behavior keeps the `IOS_APP_TOKEN`-present requirement.)

- [ ] **Step 2 (3b): iOS inbound stamps owner_key.** In `src/adapter-route.ts`, add `import { resolvePersonKey } from './person-key.js';`. The `userId` is resolved at line 63. Pass `resolvePersonKey(userId)` as the 5th arg to ALL THREE `resolveSession(agentGroup.id, mg.id, event.threadId, sessionMode)` calls (the `/new` path ~line 95, the `deny` path ~line 118, the main path ~line 136). Example (main path, line 136):

```typescript
  const { session } = resolveSession(agentGroup.id, mg.id, event.threadId, sessionMode, resolvePersonKey(userId));
```

- [ ] **Step 3: Test (3b) — adapter-route stamps owner_key.** In `src/adapter-route.test.ts` (create the file if it does not exist, mirroring `src/router.test.ts`'s harness: `initTestDb`+`runMigrations`, create a messaging group via `createMessagingGroup`, an agent group, a wiring, and a `users` row with `person_key`). Assert the session created by `adapterRouteToAgent` carries the sender's person key:

```typescript
it('adapterRouteToAgent stamps session.owner_key from the sender person_key', async () => {
  // Arrange: messaging group on ios-app-v2 + agent group + member + users row with person_key='p2'.
  // (Use the same setup helpers router.test.ts uses; the sender resolver derives userId from senderId.)
  upsertUser({ id: 'ios-app-v2:p2', kind: 'ios-app-v2', display_name: null, person_key: 'p2', created_at: new Date().toISOString() });
  // ... create mg (channel_type 'ios-app-v2', platform_id 'ios-app-v2:p2'), agent group 'ag-jarvis', wiring, member ...
  const res = await adapterRouteToAgent(
    { channelType: 'ios-app-v2', platformId: 'ios-app-v2:p2', threadId: null,
      message: { id: 'm1', kind: 'chat', content: JSON.stringify({ text: 'hi', senderId: 'ios-app-v2:p2' }), timestamp: new Date().toISOString() } },
    'ag-jarvis', { wake: false },
  );
  expect(res.delivered).toBe(true);
  expect(getSession(res.sessionId!)?.owner_key).toBe('p2');
});
```

If standing up the full `adapterRouteToAgent` harness (access gate, sender resolver registration via importing the permissions module) proves heavy, the minimum viable assertion is a unit test that `resolveSession(..., resolvePersonKey('ios-app-v2:p2'))` stamps `owner_key='p2'` given the users row — but prefer the integration test through `adapterRouteToAgent` since that is the path being fixed. Register the permissions module hooks the same way `router.test.ts` does (import `../modules/permissions/index.js` so `senderResolver`/`accessGate` are installed), and make `p2` a member so the access gate allows it.

- [ ] **Step 4: Run + build.** `pnpm exec vitest run src/adapter-route.test.ts` → PASS; `pnpm test` (full) → PASS; `pnpm run build` → clean.

- [ ] **Step 5: Commit.**
```bash
git add src/channels/ios-app/v2/index.ts src/adapter-route.ts src/adapter-route.test.ts
git commit -m "feat(ios): registry-backed validateToken + owner_key on iOS inbound"
```

### Task 4: `HEALTH_AGENT_FOLDER` config

**Files:** Modify `src/config.ts`.

- [ ] **Step 1: Add the config.** In `src/config.ts`, add `HEALTH_AGENT_FOLDER` to the `readEnvFile([...])` list and export it:

```typescript
export const HEALTH_AGENT_FOLDER = process.env.HEALTH_AGENT_FOLDER || envConfig.HEALTH_AGENT_FOLDER || 'greg';
```

(The daily HealthKit upload is owned by one health agent; `greg` is the convention in this install. `gordon`/`payne` consume health via per-person profiles/a2a, not the raw `health.db`, so only the health agent's folder receives the write.)

- [ ] **Step 2: Build + commit.** `pnpm run build` → clean.
```bash
git add src/config.ts
git commit -m "feat(config): HEALTH_AGENT_FOLDER (default greg)"
```

### Task 5: HTTP routes resolve person from token → per-person paths

**Files:** Modify `src/channels/ios-app/v2/http-handler.ts`, `src/channels/ios-app/v2/index.ts`. Test: `src/channels/ios-app/v2/http-routes.test.ts` (exists).

This re-points health-upload + `/ios/state` at the per-person tree and replaces the single-token bearer check with the registry. **This is the spec §15.2 deploy-critical change.**

- [ ] **Step 1: Read the current tests + handler.** Read `src/channels/ios-app/v2/http-routes.test.ts` to learn how it constructs `createIosHttpHandler` deps and asserts; you will update the deps shape there too.

- [ ] **Step 2: Change the handler deps + routing.** In `src/channels/ios-app/v2/http-handler.ts`:
  - Replace the `token: string` dep with `resolveToken: (rawToken: string) => { platform_id: string; person_key: string } | null`.
  - Add deps `healthAgentFolder: string` and import `userMemoryRoot`, `userGlobalRoot` from `../../../user-memory.js`.
  - Remove `groupsDir`, `healthOverrideDir`, and `resolveAgentFolderForPlatform` from the health/state routing (they are replaced by token→person).
  - Rewrite `requireToken` to resolve identity and return it (or 401):

```typescript
  const authIdentity = (req: http.IncomingMessage): { platform_id: string; person_key: string } | null => {
    const auth = req.headers.authorization ?? '';
    if (!auth.startsWith('Bearer ')) return null;
    return resolveToken(auth.slice('Bearer '.length));
  };
```
  Each authed route does `const id = authIdentity(req); if (!id) { 401 }` then uses `id.person_key` / `id.platform_id`.

  - `/ios/health/upload`: ignore `body.platformId` for routing (it is the client's local id and may not match the server platform_id); write to the person's health agent folder:
```typescript
    const root = userMemoryRoot(id.person_key, healthAgentFolder); // data/user-memory/<person>/<healthAgent>
    // appendHealthHistory(writeRoot, writeFolder, days) joins writeRoot/writeFolder/health/health.db,
    // so split: writeRoot = dirname(root), writeFolder = basename(root).
    appendHealthHistory(path.dirname(root), path.basename(root), days);
```
  (Keep `appendHealthHistory`'s existing `join(root, folder, 'health', 'health.db')` contract; passing `dirname`/`basename` of `userMemoryRoot(person, healthAgent)` yields `data/user-memory/<person>/<healthAgent>/health/health.db` — exactly what `buildMounts` mounts for that person's health agent.) The `sickDayCheck` block stays but now reads from the same per-person path (`loadAllHealthRows(path.dirname(root), path.basename(root))`).
  - `/ios/state`: read the person's profiles:
```typescript
    const profilesDir = join(userGlobalRoot(id.person_key), 'profiles');
```
  - `/ios/health/requests`: key by `id.platform_id` (from the token), not the query param — or keep the query param but validate it equals `id.platform_id`.

- [ ] **Step 3: Wire the new deps in `index.ts`.** In `createV2Adapter`'s `createIosHttpHandler({...})` call (`src/channels/ios-app/v2/index.ts:424-433`), pass `resolveToken: resolveIosToken`, `healthAgentFolder: HEALTH_AGENT_FOLDER` (import it), and drop `token`/`groupsDir`/`healthOverrideDir`/`resolveAgentFolderForPlatform` from the health/state surface. (Keep `resolveAgentFolderForPlatform` only if some other route still needs it; health + state no longer do.)

- [ ] **Step 4: Update the http-routes test.** In `src/channels/ios-app/v2/http-routes.test.ts`, change the deps to the new shape: provide a `resolveToken` stub that maps `'tok-p2' → { platform_id: 'ios-app-v2:p2', person_key: 'p2' }`, `healthAgentFolder: 'greg'`. Add/adjust assertions:
  - health upload with `Authorization: Bearer tok-p2` writes to `data/user-memory/p2/greg/health/health.db` (assert the file exists under that path; use a temp `DATA_DIR`-relative check or read it back via `openHealthDb`/`readHealthDays`). Clean up the `user-memory/p2` dir in teardown.
  - `/ios/state` with `Bearer tok-p2` reads `user-memory/p2/global/profiles/` (seed a `greg.md` profile there, assert it appears in the response `agents`).
  - an unknown token → 401.

- [ ] **Step 5: Run.** `pnpm exec vitest run src/channels/ios-app/v2/http-routes.test.ts` → PASS; full `pnpm test`; `pnpm run build`. Fix any other caller of `createIosHttpHandler` deps shape (grep `createIosHttpHandler`).

- [ ] **Step 6: Commit.**
```bash
git add src/channels/ios-app/v2/http-handler.ts src/channels/ios-app/v2/index.ts src/channels/ios-app/v2/http-routes.test.ts
git commit -m "feat(ios): route health-upload + /ios/state by token person into user-memory"
```

### Task 6: sick-day trigger targets the person's health-agent session

**Files:** Modify `src/modules/health-trigger/sick-day.ts`, `src/channels/ios-app/v2/http-handler.ts` (caller). Test: `src/modules/health-trigger/sick-day.test.ts`.

- [ ] **Step 1: Read `sick-day.ts`.** Learn how `sickDayCheck({ agentGroupId, allRows })` picks the session to wake (it currently finds an active session for `agentGroupId`). Under multi-user it must wake the active session of that agent group **owned by the uploading person**.

- [ ] **Step 2: Add an owner filter.** Change `sickDayCheck`'s input to accept `ownerKey: string` and, when selecting the target session, filter to `(session.owner_key || OWNER_PERSON_KEY) === ownerKey` (use `getSessionsByAgentGroup` + filter, mirroring the a2a owner-scoping in `src/modules/agent-to-agent/agent-route.ts`). If no owned active session exists, skip the wake (log), exactly as it already skips when no active session exists.

- [ ] **Step 3: Pass the owner from the upload handler.** In `http-handler.ts` `/ios/health/upload`, pass `ownerKey: id.person_key` into `sickDayCheck({ agentGroupId: targetAgentGroupId, ownerKey: id.person_key, allRows })`.

- [ ] **Step 4: Test.** In `sick-day.test.ts`, add a case: two active sessions of the health agent group (owners `sergei` and `p2`), a firing health signal, `ownerKey='p2'` → only the `p2` session is woken (assert the wake target is the p2 session; the file already mocks/observes the wake — mirror its existing assertions). Confirm the existing single-owner tests still pass (they pass `ownerKey` = owner, or default).

- [ ] **Step 5: Run + commit.** `pnpm exec vitest run src/modules/health-trigger/sick-day.test.ts` → PASS; `pnpm test`; `pnpm run build`.
```bash
git add src/modules/health-trigger/sick-day.ts src/channels/ios-app/v2/http-handler.ts src/modules/health-trigger/sick-day.test.ts
git commit -m "feat(ios): sick-day trigger wakes the uploading person's health session"
```

### Task 7: `mint-ios-token.ts` provisioning script

**Files:** Create `scripts/mint-ios-token.ts`.

- [ ] **Step 1: Write the script.** Create `scripts/mint-ios-token.ts`:

```typescript
/**
 * Mint an iOS bearer token for a person and register it.
 *   pnpm exec tsx scripts/mint-ios-token.ts <person_key> [label]
 * Prints the raw token ONCE (only its hash is stored). Give it to the person
 * to enter in the app's Settings (server URL + token). The platform_id is
 * derived as `ios-app-v2:<person_key>`. Wiring her to agent groups + adding
 * membership + creating her user-memory tree is a separate step (see the
 * provisioning runbook in the plan).
 */
import path from 'path';
import { randomBytes } from 'node:crypto';
import { DATA_DIR } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { upsertIosToken } from '../src/channels/ios-app/v2/token-registry.js';

const [personKey, label] = process.argv.slice(2);
if (!personKey) {
  console.error('usage: mint-ios-token.ts <person_key> [label]');
  process.exit(1);
}
initDb(path.join(DATA_DIR, 'v2.db'));
const rawToken = randomBytes(24).toString('base64url');
const platformId = `ios-app-v2:${personKey}`;
upsertIosToken({ rawToken, platformId, personKey, label: label ?? null });
console.log(`person_key:  ${personKey}`);
console.log(`platform_id: ${platformId}`);
console.log(`TOKEN (give to the person, store nowhere else):\n  ${rawToken}`);
```

- [ ] **Step 2: Verify safe-mode run.** `pnpm exec tsx scripts/mint-ios-token.ts test-person "dry"` against the LOCAL `data/v2.db` — confirm it prints a token + platform_id `ios-app-v2:test-person` and exits 0. Then remove the test row so it doesn't linger: `pnpm exec tsx scripts/q.ts data/v2.db "DELETE FROM ios_tokens WHERE platform_id='ios-app-v2:test-person'"`. (Local `data/v2.db` may lack migration 017 until the host runs migrations; if so, run the host once or apply the migration — note this in your report rather than guessing.)

- [ ] **Step 3: Build + commit.** `pnpm run build` → clean.
```bash
git add scripts/mint-ios-token.ts
git commit -m "feat(ios): mint-ios-token provisioning script"
```

---

## Phase 6 — iOS Swift app

**No code changes.** The app already:
- lets the user enter the server URL + bearer token (`ios/JarvisApp/Sources/JarvisApp/Models/AppSettings.swift` `@AppStorage("serverURL"|"bearerToken")`; UI in `ContentView.swift` splash + `SettingsView.swift` drawer), and
- shows all 5 agents (`Models/AgentIdentity.swift` enum, `ActiveAgentState`), tagging each outbound with `agent_id` (`Services/TransportV2.swift`).

The second person installs the same build on her iPhone and enters her own token (from Task 7) + the server URL. **One caveat to verify, not fix:** the WS singleton-socket is per `platform_id` — two devices sharing one person's token would supersede each other (close 4004). Fine for one-device-per-person; note it if she ever runs two devices.

---

## Phase 7 — provision the second person (operator runbook, on the VDS)

Run after phases 1–4 + phase-5 code are deployed and the owner migration (`migrate-owner-memory.ts`) is done. Replace `<p2>` with her chosen person key and `<id-*>` with the real agent-group ids (`ncl groups list`).

```bash
# 1. Mint her token (prints it once; give it to her for the app).
pnpm exec tsx scripts/mint-ios-token.ts <p2> "<her name> phone"
#    → platform_id ios-app-v2:<p2>

# 2. Her iOS messaging group is auto-created on her first authenticated WS
#    connect (router auto-creates on mention/DM). To wire BEFORE she connects,
#    create it explicitly, then wire all 5 agents + add membership:
ncl messaging-groups create --channel-type ios-app-v2 --platform-id ios-app-v2:<p2>
#    (capture the mg id), then for each of the 5 agent groups:
for AG in <id-jarvis> <id-greg> <id-gordon> <id-payne> <id-scrooge>; do
  ncl wirings create --messaging-group <mg-id> --agent-group "$AG" --session-mode shared --sender-scope known
  ncl members add --user-id ios-app-v2:<p2> --id "$AG"
done

# 3. Her user-memory tree is created lazily by initUserMemory on first spawn;
#    nothing to pre-create. (Optional: seed her global/.writer so HER jarvis
#    is the writer of her shared facts:)
mkdir -p data/user-memory/<p2>/global && printf 'jarvis' > data/user-memory/<p2>/global/.writer

# 4. She enters server URL + token in the app → authenticates as ios-app-v2:<p2>
#    → her messages create p2-owned sessions → buildMounts mounts only
#    user-memory/<p2>/...  Health uploads land in user-memory/<p2>/greg/health/.
```

Verification: from her phone, message each agent; confirm (host log / `ncl sessions list`) the sessions carry `owner_key=<p2>`; confirm a health upload writes `data/user-memory/<p2>/greg/health/health.db` and nothing under the owner's tree; confirm `/ios/state` with her token returns HER rings (empty until her Greg publishes).

---

## Deferred cleanup (track, not blocking)

- `src/group-init.ts:65-86` still scaffolds the now-unmounted per-agent-group `.claude-shared`. Remove it once migration is proven on the VDS (it is dead but harmless). Update the stale `.claude-shared` doc references in `container/agent-runner/src/compact-instructions.ts:9` at the same time.

---

## Self-review notes (coverage map)

- Spec §8.1 token registry → Tasks 1–2. §8.2 provisioning → Task 7 + `mint-ios-token`. §8.3 Swift app → Phase 6 (no-op, already built). §8.4 health-ingest person path + remove `IOS_HEALTH_HISTORY_DIR` → Tasks 4–5. §8 `/ios/state` person-scoped → Task 5. §15.1 adapter-route + sick-day owner_key → Tasks 3, 6. §15.2 deploy-ordering → "Prerequisite findings" + Phase 7.
- "All agents at once" (user constraint) → Phase 7 wires the one iOS messaging-group to all 5 agent groups; health routes only to `HEALTH_AGENT_FOLDER` (greg); the app already lists all 5.
- Runtime-dependent spots flagged for the implementer/operator rather than guessed: whether `IOS_HEALTH_HISTORY_DIR` is currently set on the VDS (must be unset post-migration); whether local `data/v2.db` has migration 017 when verifying scripts; the exact `http-routes.test.ts` deps shape (read before editing).
