# Multi-user isolation — host core (phases 1–4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Partition agent memory by a per-human "owner key" so a second person sharing the same agents (Jarvis, Greg) cannot read or write the first person's memory — proven end-to-end on Telegram before any iOS work.

**Architecture:** Add a stable `person_key` above per-channel `users` rows and an `owner_key` on each `session`, set at session creation. Split each agent folder into shared **code** (RO for every container) and per-person **memory** mounted from `data/user-memory/<owner_key>/<folder>/`. The entire isolation guarantee lives in `buildMounts` (`src/container-runner.ts`). Remove agent-side `ncl` and behavior self-editing; scope agent-to-agent routing and cron by `owner_key`.

**Tech Stack:** Node + TypeScript host, `better-sqlite3` central DB, Docker bind mounts, Vitest. This plan touches host code only (`src/`). iOS multi-user identity (spec §8, phases 5–7) is a **separate follow-up plan** written after this one lands.

**Spec:** [docs/superpowers/specs/2026-06-15-multi-user-memory-isolation-design.md](../specs/2026-06-15-multi-user-memory-isolation-design.md)

---

## File Structure

**Create:**
- `src/db/migrations/016-multi-user-identity.ts` — adds `users.person_key` + `sessions.owner_key`.
- `src/person-key.ts` — `resolvePersonKey(userId)` + `OWNER_PERSON_KEY` re-export; one responsibility: map a channel handle to a stable person key.
- `src/user-memory.ts` — `userMemoryRoot()`, `userGlobalRoot()`, `initUserMemory()`; owns the on-disk per-person memory layout + idempotent scaffold.
- `src/person-key.test.ts`, `src/user-memory.test.ts`.
- `scripts/migrate-owner-memory.ts` — one-time move of the owner's memory into `user-memory/<OWNER_PERSON_KEY>/`, with `--dry-run`.
- `scripts/set-person-key.ts` — host helper to assign `person_key` to a user's handles.

**Modify:**
- `src/config.ts` — add `OWNER_PERSON_KEY`.
- `src/types.ts` — `User.person_key`, `Session.owner_key`.
- `src/db/migrations/index.ts` — register migration 016.
- `src/db/sessions.ts` — `createSession` writes `owner_key`.
- `src/modules/permissions/db/users.ts` — `createUser`/`upsertUser` write `person_key`; add `setPersonKey`.
- `src/session-manager.ts` — `resolveSession` accepts/sets `ownerKey`; `initSessionFolder` unchanged.
- `src/router.ts` — `deliverToAgent` resolves `personKey` from `userId` and passes it to `resolveSession`.
- `src/container-runner.ts` — `buildMounts` becomes owner-aware (the isolation core); `syncSkillSymlinks` targets the per-person `.claude` dir.
- `src/modules/agent-to-agent/agent-route.ts` — `resolveTargetSession` scoped by `owner_key`.
- `src/modules/scheduling/db.ts` — recurring-task migration carries `owner_key`.

---

## Phase 1 — Identity plumbing (behavior-neutral)

`owner_key` is recorded but NOT yet consumed by mounts, so the running install behaves exactly as today.

### Task 1: Migration — add `person_key` + `owner_key`

**Files:**
- Create: `src/db/migrations/016-multi-user-identity.ts`
- Modify: `src/db/migrations/index.ts`
- Test: `src/db/db-v2.test.ts` (append a case)

- [ ] **Step 1: Write the migration**

Create `src/db/migrations/016-multi-user-identity.ts`:

```typescript
import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration016: Migration = {
  version: 16,
  name: 'multi-user-identity',
  up(db: Database.Database) {
    // person_key: stable per-human identity above per-channel users rows.
    // NULL → resolver falls back to the user id (each handle isolated) or,
    // for system/headless callers, OWNER_PERSON_KEY.
    db.prepare('ALTER TABLE users ADD COLUMN person_key TEXT').run();
    // owner_key: which person a session's memory belongs to. NULL on pre-
    // migration rows → buildMounts falls back to OWNER_PERSON_KEY.
    db.prepare('ALTER TABLE sessions ADD COLUMN owner_key TEXT').run();
  },
};
```

- [ ] **Step 2: Register it in the barrel**

In `src/db/migrations/index.ts`, add the import after the `migration015` import and append to the `migrations` array after `migration015`:

```typescript
import { migration016 } from './016-multi-user-identity.js';
```
```typescript
  migration015,
  migration016,
];
```

- [ ] **Step 3: Write a test that the columns exist after migration**

Append to `src/db/db-v2.test.ts` (inside the existing top-level `describe`, matching its `initTestDb`/`runMigrations` setup — read the file's existing `beforeEach` to reuse it):

```typescript
it('migration 016 adds person_key and owner_key', () => {
  const userCols = getDb().prepare('PRAGMA table_info(users)').all() as { name: string }[];
  const sessionCols = getDb().prepare('PRAGMA table_info(sessions)').all() as { name: string }[];
  expect(userCols.map((c) => c.name)).toContain('person_key');
  expect(sessionCols.map((c) => c.name)).toContain('owner_key');
});
```

`db-v2.test.ts`'s `beforeEach` does `const db = initTestDb(); runMigrations(db);` with `db` LOCAL to that callback, so reference the singleton via `getDb()` instead. Add `getDb` to the existing import from `./index.js` (it is exported there).

- [ ] **Step 4: Run the test**

Run: `pnpm exec vitest run src/db/db-v2.test.ts -t "migration 016"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/db/migrations/016-multi-user-identity.ts src/db/migrations/index.ts src/db/db-v2.test.ts
git commit -m "feat(db): add person_key + owner_key columns (migration 016)"
```

### Task 2: `OWNER_PERSON_KEY` config + `resolvePersonKey`

**Files:**
- Modify: `src/config.ts:9`, `src/types.ts:61-66`, `src/types.ts:122-132`, `src/modules/permissions/db/users.ts`
- Create: `src/person-key.ts`, `src/person-key.test.ts`

- [ ] **Step 1: Add the config value**

In `src/config.ts`, extend the `readEnvFile` list on line 9 to include `OWNER_PERSON_KEY` and add the export after line 13:

```typescript
const envConfig = readEnvFile(['ASSISTANT_NAME', 'ASSISTANT_HAS_OWN_NUMBER', 'CREDENTIAL_PROXY_PORT', 'TZ', 'OWNER_PERSON_KEY']);
```
```typescript
export const OWNER_PERSON_KEY = process.env.OWNER_PERSON_KEY || envConfig.OWNER_PERSON_KEY || 'owner';
```

- [ ] **Step 2: Extend the types**

In `src/types.ts`, add `person_key` to `User` (after `display_name`):

```typescript
export interface User {
  id: string;
  kind: string;
  display_name: string | null;
  /** Stable per-human key above the channel handle. NULL until assigned. */
  person_key: string | null;
  created_at: string;
}
```

And add `owner_key` to `Session` (after `thread_id`):

```typescript
export interface Session {
  id: string;
  agent_group_id: string;
  messaging_group_id: string | null;
  thread_id: string | null;
  /** Person whose memory this session reads/writes. NULL → OWNER_PERSON_KEY. */
  owner_key: string | null;
  agent_provider: string | null;
  status: 'active' | 'closed';
  container_status: 'running' | 'idle' | 'stopped';
  last_active: string | null;
  created_at: string;
}
```

- [ ] **Step 3: Make users CRUD persist `person_key`**

In `src/modules/permissions/db/users.ts`, update `createUser` and `upsertUser` to write `person_key`, and add `setPersonKey`:

```typescript
export function createUser(user: User): void {
  getDb()
    .prepare(
      `INSERT INTO users (id, kind, display_name, person_key, created_at)
       VALUES (@id, @kind, @display_name, @person_key, @created_at)`,
    )
    .run(user);
}

export function upsertUser(user: User): void {
  getDb()
    .prepare(
      `INSERT INTO users (id, kind, display_name, person_key, created_at)
       VALUES (@id, @kind, @display_name, @person_key, @created_at)
       ON CONFLICT(id) DO UPDATE SET
         display_name = COALESCE(excluded.display_name, users.display_name),
         person_key   = COALESCE(excluded.person_key, users.person_key)`,
    )
    .run(user);
}

export function setPersonKey(userId: string, personKey: string): void {
  getDb().prepare('UPDATE users SET person_key = ? WHERE id = ?').run(personKey, userId);
}
```

Any existing caller that builds a `User` literal without `person_key` will now fail typecheck — set `person_key: null` there. Search them: `grep -rn "kind:" src --include=*.ts | grep -i upsertUser` is not reliable; instead after editing run the typecheck in Step 6 and fix each error by adding `person_key: null`. The known caller is `extractAndUpsertUser` in `src/modules/permissions/index.ts:95` (handled in Task 3).

- [ ] **Step 4: Write the resolver + its test**

Create `src/person-key.ts`:

```typescript
import { OWNER_PERSON_KEY } from './config.js';
import { getUser } from './modules/permissions/db/users.js';

export { OWNER_PERSON_KEY };

/**
 * Map a channel handle (namespaced user id) to a stable per-human key.
 *
 * - A user row with an explicit person_key → that key.
 * - A known handle with no person_key → the handle itself (each handle is its
 *   own person until mapped — never silently folded into the owner).
 * - No userId at all (system / headless / a2a default) → OWNER_PERSON_KEY.
 */
export function resolvePersonKey(userId: string | null | undefined): string {
  if (!userId) return OWNER_PERSON_KEY;
  const user = getUser(userId);
  if (user?.person_key) return user.person_key;
  return userId;
}
```

Create `src/person-key.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { initTestDb, closeDb, runMigrations } from './db/index.js';
import { upsertUser, setPersonKey } from './modules/permissions/db/users.js';
import { resolvePersonKey, OWNER_PERSON_KEY } from './person-key.js';

describe('resolvePersonKey', () => {
  beforeEach(() => {
    const db = initTestDb();
    runMigrations(db);
  });
  afterEach(() => closeDb());

  it('returns OWNER_PERSON_KEY when userId is null', () => {
    expect(resolvePersonKey(null)).toBe(OWNER_PERSON_KEY);
  });

  it('returns the handle itself when the user has no person_key', () => {
    upsertUser({ id: 'telegram:111', kind: 'telegram', display_name: null, person_key: null, created_at: new Date().toISOString() });
    expect(resolvePersonKey('telegram:111')).toBe('telegram:111');
  });

  it('returns the assigned person_key when set', () => {
    upsertUser({ id: 'telegram:111', kind: 'telegram', display_name: null, person_key: null, created_at: new Date().toISOString() });
    setPersonKey('telegram:111', 'sergei');
    expect(resolvePersonKey('telegram:111')).toBe('sergei');
  });

  it('returns the handle for an unknown user id', () => {
    expect(resolvePersonKey('telegram:999')).toBe('telegram:999');
  });
});
```

(Confirm `initTestDb` / `closeDb` / `runMigrations` are exported from `src/db/index.js` — they are used the same way in `src/session-manager.test.ts:27`.)

- [ ] **Step 5: Run the test**

Run: `pnpm exec vitest run src/person-key.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 6: Typecheck and fix literal callers**

Run: `pnpm run build`
Expected: PASS. If it fails on a missing `person_key` in a `User` literal, add `person_key: null` to that literal and re-run.

- [ ] **Step 7: Commit**

```bash
git add src/config.ts src/types.ts src/modules/permissions/db/users.ts src/person-key.ts src/person-key.test.ts
git commit -m "feat: person_key resolver + OWNER_PERSON_KEY config"
```

### Task 3: Set `owner_key` at session creation

**Files:**
- Modify: `src/db/sessions.ts:6-13`, `src/session-manager.ts:94-159`, `src/router.ts` (deliverToAgent call site), `src/modules/permissions/index.ts:95`
- Test: `src/session-manager.test.ts`

- [ ] **Step 1: Make `createSession` persist `owner_key`**

In `src/db/sessions.ts`, update the INSERT:

```typescript
export function createSession(session: Session): void {
  getDb()
    .prepare(
      `INSERT INTO sessions (id, agent_group_id, messaging_group_id, thread_id, owner_key, agent_provider, status, container_status, last_active, created_at)
       VALUES (@id, @agent_group_id, @messaging_group_id, @thread_id, @owner_key, @agent_provider, @status, @container_status, @last_active, @created_at)`,
    )
    .run(session);
}
```

- [ ] **Step 2: Thread `ownerKey` through `resolveSession`**

In `src/session-manager.ts`, add the import and an `ownerKey` parameter (default `OWNER_PERSON_KEY`), and set it on the created session literal:

```typescript
import { OWNER_PERSON_KEY } from './config.js';
```

Change the signature (line 94) and the session literal (line 124). `ownerKey` is **optional with no default** — this lets us distinguish "caller specified an owner" (interactive + a2a always do) from "caller left it unset" (rotation, handled in Task 11). When unset here in Phase 1 it resolves to the owner:

```typescript
export function resolveSession(
  agentGroupId: string,
  messagingGroupId: string | null,
  threadId: string | null,
  sessionMode: 'shared' | 'per-thread' | 'agent-shared',
  ownerKey?: string,
): { session: Session; created: boolean } {
```
```typescript
  const session: Session = {
    id,
    agent_group_id: agentGroupId,
    messaging_group_id: messagingGroupId,
    thread_id: lookupThreadId,
    owner_key: ownerKey ?? OWNER_PERSON_KEY, // Task 11 extends this to inherit prior?.owner_key
    agent_provider: null,
    status: 'active',
    container_status: 'stopped',
    last_active: null,
    created_at: new Date().toISOString(),
  };
```

- [ ] **Step 3: Pass the resolved person key from the router**

In `src/router.ts`, add the import:

```typescript
import { resolvePersonKey } from './person-key.js';
```

In `deliverToAgent`, the `userId` parameter is already in scope. At each `resolveSession(agent.agent_group_id, mg.id, event.threadId, effectiveSessionMode)` call (there are three: the `/new` path ~line 461, the `deny` path ~line 479, and the main path ~line 498), add `resolvePersonKey(userId)` as the 5th argument. Example for the main path:

```typescript
  const { session, created } = resolveSession(
    agent.agent_group_id,
    mg.id,
    event.threadId,
    effectiveSessionMode,
    resolvePersonKey(userId),
  );
```

Apply the same 5th argument to the `/new` and `deny` `resolveSession` calls.

- [ ] **Step 4: Set `person_key: null` in the sender upsert**

In `src/modules/permissions/index.ts`, the `upsertUser` call (~line 95) now needs `person_key`:

```typescript
    upsertUser({
      id: userId,
      kind: event.channelType,
      display_name: senderName ?? null,
      person_key: null,
      created_at: new Date().toISOString(),
    });
```

- [ ] **Step 5: Write the test**

Append to `src/session-manager.test.ts` a case asserting the created session carries the owner key. Reuse its `seedAgentAndSession`/`TEST_AG` pattern; the file already imports `resolveSession`? It does not — add `resolveSession` to the import from `./session-manager.js` and `getSession` is already imported from `./db/index.js`:

```typescript
it('resolveSession stamps owner_key from the argument', () => {
  createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });
  const { session } = resolveSession(TEST_AG, null, null, 'agent-shared', 'p2');
  expect(session.owner_key).toBe('p2');
  expect(getSession(session.id)?.owner_key).toBe('p2');
});

it('resolveSession defaults owner_key to OWNER_PERSON_KEY', () => {
  createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });
  const { session } = resolveSession(TEST_AG, null, null, 'agent-shared');
  expect(session.owner_key).toBe(OWNER_PERSON_KEY);
});
```

`beforeEach` sets a fresh unique `TEST_AG` and resets the in-memory DB but creates **no** agent group and **no** session — so each test calls `createAgentGroup` itself (with no pre-existing session, so the `agent-shared` lookup misses and `resolveSession` creates fresh). `createAgentGroup`, `now`, and `resolveSession` must be imported; add `import { OWNER_PERSON_KEY } from './config.js';`.

- [ ] **Step 6: Run the test**

Run: `pnpm exec vitest run src/session-manager.test.ts -t "owner_key"`
Expected: PASS (2 tests).

- [ ] **Step 7: Run the full host suite to catch fixture breakage**

Run: `pnpm test`
Expected: PASS. Any failure is a `Session`/`User` literal missing the new field — add `owner_key: null` (sessions) or `person_key: null` (users) to that fixture. Known fixtures to update: `src/session-manager.test.ts` `seedAgentAndSession` (its `createSession` literal), and `src/modules/agent-to-agent/agent-route.test.ts` (the `S1`/`S2` session literals). The `createSession` INSERT now binds `@owner_key`, so a literal omitting it throws at runtime too, not just at typecheck.

- [ ] **Step 8: Commit**

```bash
git add src/db/sessions.ts src/session-manager.ts src/router.ts src/modules/permissions/index.ts src/session-manager.test.ts
git commit -m "feat: stamp session.owner_key from sender person_key"
```

---

## Phase 2 — Memory/code split + buildMounts + owner migration (isolation core)

### Task 4: Per-person memory layout module

**Files:**
- Create: `src/user-memory.ts`, `src/user-memory.test.ts`

- [ ] **Step 1: Write the test first**

Create `src/user-memory.test.ts`:

```typescript
import fs from 'fs';
import path from 'path';
import { describe, it, expect, afterEach } from 'vitest';
import { DATA_DIR } from './config.js';
import { userMemoryRoot, userGlobalRoot, initUserMemory } from './user-memory.js';

const KEY = 'test-person-xyz';

afterEach(() => {
  fs.rmSync(path.join(DATA_DIR, 'user-memory', KEY), { recursive: true, force: true });
});

describe('user-memory layout', () => {
  it('userMemoryRoot is data/user-memory/<key>/<folder>', () => {
    expect(userMemoryRoot(KEY, 'jarvis')).toBe(path.join(DATA_DIR, 'user-memory', KEY, 'jarvis'));
  });

  it('userGlobalRoot is data/user-memory/<key>/global', () => {
    expect(userGlobalRoot(KEY)).toBe(path.join(DATA_DIR, 'user-memory', KEY, 'global'));
  });

  it('initUserMemory creates memory subdirs, .claude, and global', () => {
    initUserMemory(KEY, 'jarvis');
    const root = userMemoryRoot(KEY, 'jarvis');
    for (const sub of ['memories', 'conversations', 'health', 'scratch', '.claude', '.claude/skills']) {
      expect(fs.existsSync(path.join(root, sub))).toBe(true);
    }
    expect(fs.existsSync(path.join(root, '.claude', 'settings.json'))).toBe(true);
    expect(fs.existsSync(path.join(userGlobalRoot(KEY), 'profiles'))).toBe(true);
  });

  it('initUserMemory is idempotent', () => {
    initUserMemory(KEY, 'jarvis');
    expect(() => initUserMemory(KEY, 'jarvis')).not.toThrow();
  });
});
```

- [ ] **Step 2: Run it (fails — module missing)**

Run: `pnpm exec vitest run src/user-memory.test.ts`
Expected: FAIL — "Cannot find module './user-memory.js'".

- [ ] **Step 3: Implement the module**

Create `src/user-memory.ts`. Reuse the settings.json content from `group-init.ts` by exporting it; for now inline the same default to avoid a refactor:

```typescript
import fs from 'fs';
import path from 'path';

import { DATA_DIR } from './config.js';

/** The four writable memory subdirs that move out of groups/<folder>/ per person. */
export const MEMORY_SUBDIRS = ['memories', 'conversations', 'health', 'scratch'] as const;

/** data/user-memory/<personKey>/<agentFolder> — private memory root for one (person, agent). */
export function userMemoryRoot(personKey: string, agentFolder: string): string {
  return path.join(DATA_DIR, 'user-memory', personKey, agentFolder);
}

/** data/user-memory/<personKey>/global — per-person shared-facts + cross-agent profiles. */
export function userGlobalRoot(personKey: string): string {
  return path.join(DATA_DIR, 'user-memory', personKey, 'global');
}

const DEFAULT_CLAUDE_SETTINGS =
  JSON.stringify(
    {
      env: {
        CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1',
        CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD: '1',
        CLAUDE_CODE_DISABLE_AUTO_MEMORY: '0',
      },
      hooks: {
        PreCompact: [{ hooks: [{ type: 'command', command: 'bun /app/src/compact-instructions.ts' }] }],
      },
    },
    null,
    2,
  ) + '\n';

/**
 * Idempotently scaffold the per-person memory tree for one (person, agent):
 * memory subdirs, a private .claude (settings.json + skills/), and the
 * per-person global dir (profiles/). Safe to call on every container spawn.
 */
export function initUserMemory(personKey: string, agentFolder: string): void {
  const root = userMemoryRoot(personKey, agentFolder);
  for (const sub of MEMORY_SUBDIRS) {
    fs.mkdirSync(path.join(root, sub), { recursive: true });
  }
  const claudeDir = path.join(root, '.claude');
  fs.mkdirSync(path.join(claudeDir, 'skills'), { recursive: true });
  const settingsFile = path.join(claudeDir, 'settings.json');
  if (!fs.existsSync(settingsFile)) fs.writeFileSync(settingsFile, DEFAULT_CLAUDE_SETTINGS);

  const globalDir = userGlobalRoot(personKey);
  fs.mkdirSync(path.join(globalDir, 'profiles'), { recursive: true });
}
```

- [ ] **Step 4: Run the test**

Run: `pnpm exec vitest run src/user-memory.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/user-memory.ts src/user-memory.test.ts
git commit -m "feat: per-person memory layout module (user-memory.ts)"
```

### Task 5: Refactor `buildMounts` to be owner-aware (THE isolation core)

**Files:**
- Modify: `src/container-runner.ts:372-460` (`buildMounts`), `src/container-runner.ts:472-557` (`syncSkillSymlinks` target dir)
- Test: `src/container-runner.test.ts`

- [ ] **Step 1: Write the failing isolation test**

Append to `src/container-runner.test.ts`. `buildMounts` is module-private today — add `export` to its declaration in Step 3, then import it here. `buildMounts` has side effects (it calls `initGroupFilesystem` → `ensureContainerConfig` → `getDb()`, and creates real dirs), so the test needs a live in-memory DB, a seeded agent group, and a **throwaway folder** + teardown so no real `groups/` data is touched. Ensure the file's vitest import includes `beforeEach, afterEach`.

```typescript
import { buildMounts } from './container-runner.js';
import { DATA_DIR, GROUPS_DIR, OWNER_PERSON_KEY } from './config.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup } from './db/index.js';
import fs from 'fs';
import path from 'path';

const ISO_AG = 'ag-test-iso';
const ISO_FOLDER = 'test-iso-mounts'; // throwaway — never a real agent folder

function mountsFor(ownerKey: string | null) {
  const agentGroup = { id: ISO_AG, name: 'Iso', folder: ISO_FOLDER, agent_provider: null, created_at: 'now' };
  const session = {
    id: 'sess-iso', agent_group_id: ISO_AG, messaging_group_id: null, thread_id: null,
    owner_key: ownerKey, agent_provider: null, status: 'active' as const,
    container_status: 'stopped' as const, last_active: null, created_at: 'now',
  };
  // skills: [] keeps syncSkillSymlinks from enumerating the real shared skills.
  const cfg = { provider: 'claude', skills: [] as string[], additionalMounts: [] } as any;
  return buildMounts(agentGroup as any, session as any, cfg, {});
}

describe('buildMounts owner isolation', () => {
  beforeEach(() => {
    const db = initTestDb();
    runMigrations(db);
    createAgentGroup({ id: ISO_AG, name: 'Iso', folder: ISO_FOLDER, agent_provider: null, created_at: 'now' });
  });
  afterEach(() => {
    closeDb();
    fs.rmSync(path.join(GROUPS_DIR, ISO_FOLDER), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'user-memory', 'p2', ISO_FOLDER), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'user-memory', OWNER_PERSON_KEY, ISO_FOLDER), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'user-memory', 'p2', 'global'), { recursive: true, force: true });
    fs.rmSync(path.join(DATA_DIR, 'v2-sessions', ISO_AG), { recursive: true, force: true });
  });

  it('mounts memory + .claude from the session owner tree, never another person', () => {
    const mounts = mountsFor('p2');
    const p2Root = path.join(DATA_DIR, 'user-memory', 'p2');
    const memMount = mounts.find((m) => m.containerPath === '/workspace/agent/memories');
    expect(memMount?.hostPath).toBe(path.join(p2Root, ISO_FOLDER, 'memories'));
    expect(memMount?.readonly).toBe(false);
    const claudeMount = mounts.find((m) => m.containerPath === '/home/node/.claude');
    expect(claudeMount?.hostPath).toBe(path.join(p2Root, ISO_FOLDER, '.claude'));
    // No mount may point under any OTHER person's user-memory tree.
    const ownerRoot = path.join(DATA_DIR, 'user-memory', OWNER_PERSON_KEY);
    expect(mounts.some((m) => m.hostPath.startsWith(ownerRoot + path.sep))).toBe(false);
  });

  it('mounts the shared code dir read-only for every session', () => {
    const mounts = mountsFor('p2');
    const codeMount = mounts.find((m) => m.containerPath === '/workspace/agent');
    expect(codeMount?.hostPath).toBe(path.join(GROUPS_DIR, ISO_FOLDER));
    expect(codeMount?.readonly).toBe(true);
  });

  it('falls back to OWNER_PERSON_KEY when owner_key is null', () => {
    const mounts = mountsFor(null);
    const memMount = mounts.find((m) => m.containerPath === '/workspace/agent/memories');
    expect(memMount?.hostPath).toBe(path.join(DATA_DIR, 'user-memory', OWNER_PERSON_KEY, ISO_FOLDER, 'memories'));
  });
});
```

- [ ] **Step 2: Run it (fails)**

Run: `pnpm exec vitest run src/container-runner.test.ts -t "owner isolation"`
Expected: FAIL — current code mounts `groups/jarvis` RW at `/workspace/agent` and has no `/workspace/agent/memories` mount.

- [ ] **Step 3: Rewrite `buildMounts`**

In `src/container-runner.ts`, add imports near the top:

```typescript
import { OWNER_PERSON_KEY } from './config.js';
import { userMemoryRoot, userGlobalRoot, initUserMemory, MEMORY_SUBDIRS } from './user-memory.js';
```

Mark `buildMounts` exported (`export function buildMounts(`). Replace the body's mount construction (lines ~389-436, from `const mounts: VolumeMount[] = [];` through the `.claude-shared` mount) with:

```typescript
  const mounts: VolumeMount[] = [];
  const sessDir = sessionDir(agentGroup.id, session.id);
  const groupDir = path.resolve(GROUPS_DIR, agentGroup.folder);

  // Per-person memory root. owner_key is set at session creation; pre-migration
  // sessions (null) fall back to the owner. THIS is the isolation boundary:
  // the only writable user-data mounts below resolve under this person's tree.
  const ownerKey = session.owner_key || OWNER_PERSON_KEY;
  initUserMemory(ownerKey, agentGroup.folder);
  const memRoot = userMemoryRoot(ownerKey, agentGroup.folder);

  // Session folder at /workspace (inbound.db, outbound.db, outbox/). Per-session
  // already, so naturally isolated.
  mounts.push({ hostPath: sessDir, containerPath: '/workspace', readonly: false });

  // Shared code at /workspace/agent — READ-ONLY for every session. No agent
  // edits its own behavior; behavior changes happen via host edits + redeploy.
  mounts.push({ hostPath: groupDir, containerPath: '/workspace/agent', readonly: true });

  // Per-person writable memory, nested over the RO code dir at the same paths
  // the agent already uses today.
  for (const sub of MEMORY_SUBDIRS) {
    mounts.push({ hostPath: path.join(memRoot, sub), containerPath: `/workspace/agent/${sub}`, readonly: false });
  }

  // container.json — RO nested (unchanged).
  const containerJsonPath = path.join(groupDir, 'container.json');
  if (fs.existsSync(containerJsonPath)) {
    mounts.push({ hostPath: containerJsonPath, containerPath: '/workspace/agent/container.json', readonly: true });
  }

  // CLAUDE.md — RO nested (unchanged).
  const claudeMdPath = path.join(groupDir, 'CLAUDE.md');
  if (fs.existsSync(claudeMdPath)) {
    mounts.push({ hostPath: claudeMdPath, containerPath: '/workspace/agent/CLAUDE.md', readonly: true });
  }

  // Shared INSTRUCTIONS.md — RO (unchanged).
  const instructionsPath = path.join(GROUPS_DIR, 'INSTRUCTIONS.md');
  if (fs.existsSync(instructionsPath)) {
    mounts.push({ hostPath: instructionsPath, containerPath: '/workspace/agent/INSTRUCTIONS.md', readonly: true });
  }

  // Per-person global memory at /workspace/global. Writable only when this
  // person's writer agent (named in their global/.writer) is this folder.
  const globalDir = userGlobalRoot(ownerKey);
  const writable = isGlobalMemoryWriter(globalDir, agentGroup.folder);
  mounts.push({ hostPath: globalDir, containerPath: '/workspace/global', readonly: !writable });

  // Per-person Claude home (state, settings, skill symlinks). Was per-agent-
  // group .claude-shared — that shared Claude history/todos across people.
  const claudeDir = path.join(memRoot, '.claude');
  syncSkillSymlinks(claudeDir, containerConfig, agentGroup);
  mounts.push({ hostPath: claudeDir, containerPath: '/home/node/.claude', readonly: false });

  // Shared agent-runner source — RO (unchanged).
  const agentRunnerSrc = path.join(projectRoot, 'container', 'agent-runner', 'src');
  mounts.push({ hostPath: agentRunnerSrc, containerPath: '/app/src', readonly: true });

  // Shared skills — RO (unchanged).
  const skillsSrc = path.join(projectRoot, 'container', 'skills');
  if (fs.existsSync(skillsSrc)) {
    mounts.push({ hostPath: skillsSrc, containerPath: '/app/skills', readonly: true });
  }
```

Remove the now-dead lines that computed the old per-agent-group `claudeDir` (line 386) and called `syncSkillSymlinks` before the loop, and the old `globalDir`/`.claude-shared` mount block — they are replaced above. Keep `initGroupFilesystem(agentGroup)` at the top of `buildMounts` (it still ensures the code dir + container_configs row). Keep the `additionalMounts` and `providerContribution.mounts` blocks at the end unchanged.

- [ ] **Step 4: Run the isolation test**

Run: `pnpm exec vitest run src/container-runner.test.ts -t "owner isolation"`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the whole container-runner suite + typecheck**

Run: `pnpm exec vitest run src/container-runner.test.ts && pnpm run build`
Expected: PASS. Fix any pre-existing test that asserted the old RW `/workspace/agent` mount by updating its expectation to `readonly: true` + the new memory mounts.

- [ ] **Step 6: Commit**

```bash
git add src/container-runner.ts src/container-runner.test.ts
git commit -m "feat: owner-scoped per-person memory mounts in buildMounts (isolation core)"
```

### Task 6: Owner-memory migration script

**Files:**
- Create: `scripts/migrate-owner-memory.ts`, `scripts/set-person-key.ts`

This runs once on the VDS. It does NOT change running behavior on its own — it relocates the owner's existing memory to the path `buildMounts` (Task 5) now expects.

- [ ] **Step 1: Write the migration script**

Create `scripts/migrate-owner-memory.ts`:

```typescript
/**
 * One-time: move the owner's memory out of groups/<folder>/ and the per-agent-
 * group .claude-shared into data/user-memory/<OWNER_PERSON_KEY>/<folder>/, so
 * the owner-aware buildMounts finds it. Idempotent per path (skips if target
 * exists). Run with --dry-run first.
 *
 *   pnpm exec tsx scripts/migrate-owner-memory.ts --dry-run
 *   pnpm exec tsx scripts/migrate-owner-memory.ts
 */
import fs from 'fs';
import path from 'path';
import { DATA_DIR, GROUPS_DIR, OWNER_PERSON_KEY } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { getAllAgentGroups } from '../src/db/agent-groups.js';
import { MEMORY_SUBDIRS, userMemoryRoot, userGlobalRoot } from '../src/user-memory.js';

const dryRun = process.argv.includes('--dry-run');
// initDb requires the central DB path (it is not no-arg). getAllAgentGroups is
// exported from src/db/agent-groups.ts — both verified against the codebase.

function move(src: string, dst: string): void {
  if (!fs.existsSync(src)) return;
  if (fs.existsSync(dst)) {
    console.log(`SKIP (target exists): ${dst}`);
    return;
  }
  console.log(`${dryRun ? 'WOULD MOVE' : 'MOVE'}: ${src} -> ${dst}`);
  if (dryRun) return;
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.renameSync(src, dst);
}

initDb(path.join(DATA_DIR, 'v2.db'));
const key = OWNER_PERSON_KEY;
for (const ag of getAllAgentGroups()) {
  const groupDir = path.join(GROUPS_DIR, ag.folder);
  const memRoot = userMemoryRoot(key, ag.folder);
  for (const sub of MEMORY_SUBDIRS) {
    move(path.join(groupDir, sub), path.join(memRoot, sub));
  }
  move(path.join(DATA_DIR, 'v2-sessions', ag.id, '.claude-shared'), path.join(memRoot, '.claude'));
}
// Shared global → owner's per-person global.
const oldGlobal = path.join(GROUPS_DIR, 'global');
const newGlobal = userGlobalRoot(key);
for (const entry of fs.existsSync(oldGlobal) ? fs.readdirSync(oldGlobal) : []) {
  move(path.join(oldGlobal, entry), path.join(newGlobal, entry));
}
console.log(dryRun ? 'Dry run complete.' : 'Migration complete.');
```

Verified exports: `initDb(dbPath: string)` from `src/db/connection.ts` (returns the handle; needs the path), `getAllAgentGroups()` from `src/db/agent-groups.ts`. The central DB lives at `data/v2.db` (`path.join(DATA_DIR, 'v2.db')`).

- [ ] **Step 2: Write the person-key helper**

Create `scripts/set-person-key.ts`:

```typescript
/**
 * Assign a person_key to one or more user handles.
 *   pnpm exec tsx scripts/set-person-key.ts sergei telegram:123 ios-app-v2:default
 */
import path from 'path';
import { DATA_DIR } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { setPersonKey, getUser } from '../src/modules/permissions/db/users.js';

const [personKey, ...handles] = process.argv.slice(2);
if (!personKey || handles.length === 0) {
  console.error('usage: set-person-key.ts <person_key> <handle> [handle...]');
  process.exit(1);
}
initDb(path.join(DATA_DIR, 'v2.db'));
for (const h of handles) {
  if (!getUser(h)) {
    console.warn(`WARN: user ${h} not found — skipping (it must have messaged at least once)`);
    continue;
  }
  setPersonKey(h, personKey);
  console.log(`set ${h} -> ${personKey}`);
}
```

Confirm `getUser` is exported from `src/modules/permissions/db/users.ts` (it is) and adjust the `initDb` import to match Step 1.

- [ ] **Step 3: Typecheck the scripts**

Run: `pnpm exec tsc --noEmit -p tsconfig.json` (or `pnpm run build`).
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/migrate-owner-memory.ts scripts/set-person-key.ts
git commit -m "feat: owner-memory migration + set-person-key scripts"
```

- [ ] **Step 5: DEPLOY-TIME runbook (do NOT run locally; documented for the VDS operator)**

This block is executed by the owner on the VDS during rollout, not by the implementing agent:
```bash
# 1. stop the service; 2. back up
launchctl unload ~/Library/LaunchAgents/com.nanoclaw.plist   # or: systemctl --user stop nanoclaw
cp -a groups groups.bak && cp -a data data.bak
# 3. set OWNER_PERSON_KEY in .env (e.g. OWNER_PERSON_KEY=sergei) — must match the migration target
# 4. dry-run, eyeball the moves, then run for real
pnpm exec tsx scripts/migrate-owner-memory.ts --dry-run
pnpm exec tsx scripts/migrate-owner-memory.ts
# 5. map the owner's handles to the same key
pnpm exec tsx scripts/set-person-key.ts sergei telegram:<owner-tg-id> ios-app-v2:default
# 6. restart; confirm agents resume against migrated memory (health.db reads, profiles, brief)
```

### Task 7: Remove behavior self-editing (`self-customize`)

**Files:**
- Modify: container skills selection / `container/skills/` (remove `self-customize` from the shared set)
- Modify: `groups/INSTRUCTIONS.md` and any per-agent `CLAUDE.md` referencing self-customize (Phase 3 covers content; here just stop mounting/symlinking it)

- [ ] **Step 1: Locate the self-customize wiring**

Run: `grep -rn "self-customize" container src groups --include=*.ts --include=*.md --include=*.json`
Expected: hits in `container/skills/self-customize/`, possibly a `container.json` `skills` list, and instruction files.

- [ ] **Step 2: Remove it from the shared skills set**

If any `groups/<folder>/container.json` lists `"self-customize"` in `skills`, remove that entry. If `skills` is `"all"`, the symlink is auto-created from `container/skills/` — delete the `container/skills/self-customize/` directory so it is no longer a shared skill:

```bash
git rm -r container/skills/self-customize
```

- [ ] **Step 3: Verify it no longer symlinks**

`syncSkillSymlinks` (`src/container-runner.ts`) builds the desired set from `container/skills/`; with the dir gone it can't be selected. No code change needed. Confirm:

Run: `grep -rn "self-customize" src container`
Expected: no results.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: remove self-customize skill (agents no longer self-edit behavior)"
```

---

## Phase 3 — De-personalize shared code

Shared code must contain no person-specific facts (they now live in per-person `global/about-<person>.md`) and no `ncl` usage. This is content work; the "test" is a grep that returns clean.

### Task 8: Audit and de-personalize CLAUDE.md / INSTRUCTIONS / skills

**Files:**
- Modify: `groups/INSTRUCTIONS.md`, `groups/<folder>/CLAUDE.md` (each in-scope agent), per-group skills

- [ ] **Step 1: Find person-specific references**

Run: `grep -rinE "sergei|about-sergei|owner('s)? name|ncl " groups --include=*.md`
List every hit.

- [ ] **Step 2: Move personal facts into per-person global**

For each hardcoded fact about the owner, replace it in the shared file with a pointer to `/workspace/global/about-<person>.md` (which differs per session by owner_key), and ensure the fact exists in `data/user-memory/<OWNER_PERSON_KEY>/global/about-<owner>.md` (already moved by Task 6 from `groups/global/about-sergei.md`). Rename references from `about-sergei.md` to the per-person convention if the agent reads a fixed filename — prefer having the agent read whatever `about-*.md` is in `/workspace/global`.

- [ ] **Step 3: Strip ncl instructions**

Remove any "you can run `ncl …`" guidance from `groups/INSTRUCTIONS.md` and per-agent CLAUDE.md. (cli_scope=disabled in Task 9 already excludes the auto-generated ncl block; this removes hand-written references.)

- [ ] **Step 4: Verify clean**

Run: `grep -rinE "about-sergei|ncl " groups --include=*.md`
Expected: no results (or only inside per-person `user-memory`, which is not under `groups/`).

- [ ] **Step 5: Commit**

```bash
git add groups
git commit -m "chore: de-personalize shared agent code (person facts -> per-person global)"
```

### Task 9: Disable agent-side `ncl` everywhere

**Files:**
- Data change (central DB) via host; no source change beyond verification.

- [ ] **Step 1: Set cli_scope=disabled for all agent groups**

On the host (this is the host admin tool — `ncl` on the host stays; only the *agent-side* cli goes away). For each agent group:

```bash
ncl groups config update --id <agent-group-id> --cli-scope disabled
```

Or directly: `pnpm exec tsx scripts/q.ts data/v2.db "UPDATE container_configs SET cli_scope='disabled'"`.

- [ ] **Step 2: Verify dispatch rejects cli_request**

Confirm by reading `src/cli/dispatch.ts` that `cli_scope='disabled'` rejects `cli_request` (per CLAUDE.md "Host dispatch rejects any cli_request"). Confirm `src/claude-md-compose.ts` excludes the ncl instruction block when disabled.

Run: `grep -n "disabled" src/cli/dispatch.ts src/claude-md-compose.ts`
Expected: both gate on `'disabled'`.

- [ ] **Step 3: Commit (if any config-defaults source changed)**

If you change the *default* cli_scope for newly created groups (optional), do it in the relevant create path and commit; otherwise this task is a data change with no commit.

---

## Phase 4 — a2a + cron owner-scoping

### Task 10: Scope agent-to-agent routing by owner_key

**Files:**
- Modify: `src/modules/agent-to-agent/agent-route.ts:146-169` (`resolveTargetSession`)
- Test: `src/modules/agent-to-agent/agent-route.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `src/modules/agent-to-agent/agent-route.test.ts` (reuse its existing DB/session setup helpers — read the file's top for the pattern). The intent: a source session owned by `p2` sending to a target agent group with both an owner-owned and a p2-owned active session must resolve to the **p2** session.

```typescript
it('resolveTargetSession picks the session matching the source owner_key', () => {
  // Two active sessions of the target agent group, different owners.
  const tgt = 'ag-greg';
  createAgentGroup({ id: tgt, name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
  createSession({ id: 's-owner', agent_group_id: tgt, messaging_group_id: null, thread_id: null, owner_key: 'sergei', agent_provider: null, status: 'active', container_status: 'stopped', last_active: null, created_at: now() });
  createSession({ id: 's-p2', agent_group_id: tgt, messaging_group_id: null, thread_id: null, owner_key: 'p2', agent_provider: null, status: 'active', container_status: 'stopped', last_active: null, created_at: now() });

  const sourceSession = { id: 's-src', agent_group_id: 'ag-jarvis', messaging_group_id: null, thread_id: null, owner_key: 'p2', agent_provider: null, status: 'active' as const, container_status: 'stopped' as const, last_active: null, created_at: now() };
  const picked = resolveTargetSessionForTest({ id: 'm1', platform_id: tgt, content: '{}', in_reply_to: null }, sourceSession, tgt);
  expect(picked.owner_key).toBe('p2');
  expect(picked.id).toBe('s-p2');
});
```

`resolveTargetSession` is module-private; export it under a test alias by adding `export { resolveTargetSession as resolveTargetSessionForTest };` at the bottom of `agent-route.ts`, or mark it `export`. Import it in the test.

- [ ] **Step 2: Run it (fails)**

Run: `pnpm exec vitest run src/modules/agent-to-agent/agent-route.test.ts -t "matching the source owner_key"`
Expected: FAIL — current layer-3 fallback returns the newest active session (`s-p2` or `s-owner` by created_at), not owner-matched; and layers 1–2 don't filter by owner.

- [ ] **Step 3: Implement owner-scoping**

In `src/modules/agent-to-agent/agent-route.ts`, change `resolveTargetSession` so every candidate is owner-matched and the fallback creates/uses an owner-scoped session. Add an import for the sessions query and `OWNER_PERSON_KEY`:

```typescript
import { getSessionsByAgentGroup } from '../../db/sessions.js';
import { OWNER_PERSON_KEY } from '../../config.js';
```

Replace the function:

```typescript
function resolveTargetSession(msg: RoutableAgentMessage, sourceSession: Session, targetAgentGroupId: string): Session {
  const ownerKey = sourceSession.owner_key || OWNER_PERSON_KEY;
  const srcDb = openInboundDb(sourceSession.agent_group_id, sourceSession.id);
  let originSessionId: string | null = null;
  try {
    if (msg.in_reply_to) originSessionId = getInboundSourceSessionId(srcDb, msg.in_reply_to);
    if (!originSessionId) originSessionId = getMostRecentPeerSourceSessionId(srcDb, targetAgentGroupId);
  } finally {
    srcDb.close();
  }
  // Return-path / peer-affinity candidate — accept ONLY if it belongs to the
  // same person. A candidate owned by a different person would be a cross-user
  // leak; fall through to an owner-scoped session instead.
  if (originSessionId) {
    const candidate = getSession(originSessionId);
    if (
      candidate &&
      candidate.agent_group_id === targetAgentGroupId &&
      candidate.status === 'active' &&
      (candidate.owner_key || OWNER_PERSON_KEY) === ownerKey
    ) {
      return candidate;
    }
  }
  // Newest active session of the target group OWNED BY THIS PERSON.
  const owned = getSessionsByAgentGroup(targetAgentGroupId)
    .filter((s) => s.status === 'active' && (s.owner_key || OWNER_PERSON_KEY) === ownerKey)
    .sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
  if (owned[0]) return owned[0];
  // None yet — create a fresh session stamped with this owner_key. Use
  // 'per-thread' + null thread, NOT 'agent-shared': the agent-shared branch
  // reuses the newest active session of the group regardless of owner (via
  // findSessionByAgentGroup), which would adopt another person's session.
  // With messagingGroupId=null and sessionMode='per-thread', resolveSession
  // skips all reuse branches and creates a fresh session stamped with ownerKey
  // (verified against src/session-manager.ts:94-159).
  return resolveSession(targetAgentGroupId, null, null, 'per-thread', ownerKey).session;
}
```

- [ ] **Step 4: Run the test**

Run: `pnpm exec vitest run src/modules/agent-to-agent/agent-route.test.ts`
Expected: PASS (new case + existing cases still green).

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent-to-agent/agent-route.ts src/modules/agent-to-agent/agent-route.test.ts
git commit -m "fix(a2a): scope target-session resolution by owner_key (prevent cross-user routing)"
```

### Task 11: Carry owner_key through recurring-task session inheritance

**Files:**
- Modify: `src/session-manager.ts:121-155` (the `migrateRecurringTasks` block in `resolveSession`)
- Test: `src/session-manager.test.ts`

- [ ] **Step 1: Inspect the inheritance path**

`resolveSession` already locates a `prior` session and migrates its recurring tasks into the fresh one. The fresh session's `owner_key` comes from the `ownerKey` argument. When a headless cron session rotates, the caller must pass the prior owner. Read `src/modules/scheduling/db.ts` `migrateRecurringTasks` — it copies task rows, not owner. The owner must come from the new session's `ownerKey`.

- [ ] **Step 2: Inherit the prior session's owner when the caller didn't specify one**

`prior` (from `findLatestSession`) is already computed just above the session literal (line ~122). Extend the `owner_key` literal you set in Task 3 to fall back to the predecessor's owner:

```typescript
    owner_key: ownerKey ?? prior?.owner_key ?? OWNER_PERSON_KEY,
```

Because `ownerKey` is optional (Task 3, no default), an explicit caller key always wins — interactive (`resolvePersonKey(userId)`) and a2a (`sourceSession.owner_key || OWNER_PERSON_KEY`) both pass one, so they are never affected by inheritance. Only a rotation path that calls `resolveSession` *without* an owner key inherits the closed predecessor's owner, falling back to `OWNER_PERSON_KEY` when there is no prior. This is what fixes the bug where a defaulted owner key was indistinguishable from an explicitly-passed owner key.

- [ ] **Step 3: Write the test**

Append to `src/session-manager.test.ts`:

```typescript
it('a rotated session inherits the prior session owner_key', () => {
  createAgentGroup({ id: TEST_AG, name: 'Test', folder: TEST_AG, agent_provider: null, created_at: now() });
  // First (prior) session for the agent, owned by p2, then closed.
  const first = resolveSession(TEST_AG, null, null, 'agent-shared', 'p2').session;
  updateSession(first.id, { status: 'closed' });
  // New session with no owner arg should inherit p2 from the (closed) prior.
  const second = resolveSession(TEST_AG, null, null, 'agent-shared').session;
  expect(second.owner_key).toBe('p2');
});
```

Import `updateSession` from `./db/sessions.js` (where it is defined — `agent-route.test.ts` imports it the same way).

- [ ] **Step 4: Run the test**

Run: `pnpm exec vitest run src/session-manager.test.ts -t "inherits the prior session owner_key"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/session-manager.ts src/session-manager.test.ts
git commit -m "feat: rotated sessions inherit prior owner_key (headless cron stays per-person)"
```

---

## Phase 4 validation — Telegram two-person isolation

### Task 12: End-to-end isolation check on Telegram

This proves the core before any iOS work. Performed against the running install (VDS or a local dev host with Telegram wired).

- [ ] **Step 1: Provision a second test person**

```bash
# the second handle must have DM'd the bot at least once so its users row exists
pnpm exec tsx scripts/set-person-key.ts p2 telegram:<second-handle-id>
ncl members add --user-id telegram:<second-handle-id> --id <jarvis-agent-group-id>
```

- [ ] **Step 2: Seed a private fact as the owner**

From the owner's Telegram, tell Jarvis a unique secret fact ("remember my codeword is ALPHA-7"). Confirm it is written under `data/user-memory/<OWNER_PERSON_KEY>/jarvis/memories/`.

- [ ] **Step 3: Try to read it as the second person**

From the second handle's Telegram, ask Jarvis "what is my codeword?". Expected: it has no knowledge of ALPHA-7. Confirm the second person's container mounted `data/user-memory/p2/jarvis/` — inspect `logs/nanoclaw.log` for the spawn, or `pnpm exec tsx scripts/q.ts data/v2.db "SELECT id, owner_key FROM sessions WHERE agent_group_id='<jarvis-id>' ORDER BY created_at DESC LIMIT 2"`.

- [ ] **Step 4: Assert no cross-mount**

While the second person's container is up: `docker inspect <container> --format '{{json .Mounts}}'` (or the Apple-container equivalent). Expected: every writable mount source is under `data/user-memory/p2/`; none under `data/user-memory/<OWNER_PERSON_KEY>/`; `/workspace/agent` source is `groups/jarvis` mounted `ro`.

- [ ] **Step 5: Document the result**

Record pass/fail in the spec's §13 testing section (append a dated "Verified" note). If any assertion fails, STOP and debug before declaring the core done — this is the security gate.

---

## Self-review notes (coverage map)

- Spec §3 person identity → Tasks 1–3. §4 invariant → Task 5 (asserted by the isolation test). §5/§6 layout + mounts → Tasks 4–5. §7 per-person global → Task 4 (`userGlobalRoot`/`initUserMemory`) + Task 5 mount. §9 access/ncl/a2a/cron → Tasks 9 (ncl), 10 (a2a), 11 (cron); member access uses existing `canAccessAgentGroup` (no change — verified in Task 12 step 1). §10 de-personalization → Task 8. §11 migration → Task 6. §12 phases 1–4 → this plan; phases 5–7 (iOS) → separate follow-up plan. §13 testing → Task 12.
- `self-mod` package tools (§2) are intentionally untouched (kept, admin-approved) — no task, by design.
- Out of plan (phases 5–7): `ios_tokens` registry, `validateToken`, health-ingest person path, `/ios/state`, iOS Swift app, second-person iOS provisioning. These get their own plan once this lands and the owner_key plumbing is proven.
