# a2a Protocol Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the a2a wire format's declaration and its enforcement the same artifact, so the protocol cannot drift from reality the way the prose-in-CLAUDE.md convention did.

**Architecture:** Every `<message>` to an agent destination carries an optional `kind="…"` attribute (omitted = `text`). `poll-loop` lifts it into the `messages_out` envelope; the formatter renders it symmetrically on inbound. The legal kind set for each agent is its `agents/<folder>/agent.json` → `a2a_in` — the same file the shipped registry already publishes to peers. Two gate layers check against it: the container nudges in-turn, the host is the unbypassable backstop. **No descriptor → no gate**, so all code below ships inert and behavior is unchanged until descriptors are authored (a separate rollout, §Rollout).

**Spec:** [`docs/superpowers/specs/2026-07-16-a2a-protocol-normalization-design.md`](../specs/2026-07-16-a2a-protocol-normalization-design.md) — read it before starting. It carries the *why*, which the tasks below assume.

**Tech Stack:** TypeScript. **Two separate package trees that share NO modules:**
- Host `src/` — Node + pnpm, tests with **vitest** (`pnpm exec vitest run <path>`)
- Container `container/agent-runner/src/` — Bun, tests with **bun:test** (`cd container/agent-runner && bun test <path>`)

This split is why Tasks 1 and 2 deliberately duplicate the same logic. Do not try to share a module between them — it will not build. See [`docs/build-and-runtime.md`](../../build-and-runtime.md).

---

## File Structure

**Host (`src/`) — Node, vitest:**

| File | Action | Responsibility |
|---|---|---|
| `src/modules/agent-to-agent/a2a-kinds.ts` | Create | Pure verdict function: is this (kind, body) legal for this target? Host copy. |
| `src/modules/agent-to-agent/a2a-kinds.test.ts` | Create | Tests for the above. |
| `src/agent-registry.ts` | Modify | Add `getLegalKinds()`. Reword `action` → `kind` (semantics only, type unchanged). |
| `src/db/schema.ts` | Modify | `a2a_kinds TEXT` on the `destinations` CREATE TABLE (fresh session DBs). |
| `src/db/session-db.ts` | Modify | Idempotent `ALTER TABLE` for existing session DBs; `DestinationRow.a2a_kinds`; insert it. |
| `src/modules/agent-to-agent/write-destinations.ts` | Modify | Fill `a2a_kinds` from each agent target's descriptor. |
| `src/modules/agent-to-agent/agent-route.ts` | Modify | Layer 2: gate + bounce to sender. |

**Container (`container/agent-runner/src/`) — Bun, bun:test:**

| File | Action | Responsibility |
|---|---|---|
| `container/agent-runner/src/a2a-kinds.ts` | Create | Mirror of the host verdict function. |
| `container/agent-runner/src/a2a-kinds.test.ts` | Create | Tests for the above. |
| `container/agent-runner/src/destinations.ts` | Modify | `DestinationEntry.a2aKinds`; read the new column; **generate the legal-kind list into the system-prompt addendum** (Task 12 — the contract the agent reads comes from the enforced artifact, not from prose). |
| `container/agent-runner/src/poll-loop.ts` | Modify | Regex + attr parse, `blockKey` fix, kind lift, Layer 1 gate + nudge. |
| `container/agent-runner/src/formatter.ts` | Modify | Render `kind=` on inbound. |
| `container/agent-runner/src/mcp-tools/core.ts` | Modify | `add_reaction` rejects agent destinations. |

**Boundaries:** `a2a-kinds.ts` (both copies) is pure — no DB, no fs, no logging. It takes `(kind, body, legalKinds)` and returns a verdict. Everything else is wiring. Keeping it pure is what makes both gate layers testable without a container.

---

## Task 1: Host verdict function

**Files:**
- Create: `src/modules/agent-to-agent/a2a-kinds.ts`
- Test: `src/modules/agent-to-agent/a2a-kinds.test.ts`

- [ ] **Step 1: Write the failing tests**

```ts
// src/modules/agent-to-agent/a2a-kinds.test.ts
import { describe, expect, it } from 'vitest';

import { validateA2aKind } from './a2a-kinds.js';

describe('validateA2aKind', () => {
  it('passes a declared kind', () => {
    expect(validateA2aKind('set_log', '{"reps":8}', ['set_log', 'ack'])).toEqual({ ok: true, kind: 'set_log' });
  });

  it('rejects a kind the target does not declare', () => {
    expect(validateA2aKind('health_trend', '{}', ['finding', 'ack'])).toEqual({
      ok: false,
      code: 'unknown_kind',
      kind: 'health_trend',
    });
  });

  it('treats an omitted kind as text', () => {
    expect(validateA2aKind(null, 'привет', ['finding'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind(undefined, 'привет', ['finding'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind('', 'привет', ['finding'])).toEqual({ ok: true, kind: 'text' });
  });

  it('accepts text without it being declared', () => {
    expect(validateA2aKind('text', 'привет', [])).toEqual({ ok: true, kind: 'text' });
  });

  it('rejects a JSON-object body sent as text — the forgotten-attribute case', () => {
    expect(validateA2aKind(null, '{"exercise":"жим","weight_kg":80}', ['set_log'])).toEqual({
      ok: false,
      code: 'unmarked_json',
      kind: 'text',
    });
    expect(validateA2aKind('text', '  {"a":1}  ', ['set_log'])).toEqual({
      ok: false,
      code: 'unmarked_json',
      kind: 'text',
    });
  });

  it('does not treat JSON arrays or scalars as unmarked structure', () => {
    // Only objects are the drift risk. A prose message that happens to start
    // with a bracket or a number must not bounce.
    expect(validateA2aKind(null, '[1,2,3]', ['set_log'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind(null, '42', ['set_log'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind(null, 'null', ['set_log'])).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind(null, '{не json}', ['set_log'])).toEqual({ ok: true, kind: 'text' });
  });

  it('DISARMS entirely when the target has no descriptor (legalKinds null)', () => {
    // This is the property the whole rollout depends on: code ships inert.
    // Before migration EVERY structured message is "JSON body, no kind attr" —
    // an armed gate here would bounce all of them the moment the code shipped.
    expect(validateA2aKind(null, '{"action":"set_log"}', null)).toEqual({ ok: true, kind: 'text' });
    expect(validateA2aKind('anything_at_all', '{}', null)).toEqual({ ok: true, kind: 'anything_at_all' });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm exec vitest run src/modules/agent-to-agent/a2a-kinds.test.ts`
Expected: FAIL — cannot find module `./a2a-kinds.js`

- [ ] **Step 3: Write the implementation**

```ts
// src/modules/agent-to-agent/a2a-kinds.ts
/**
 * The a2a envelope verdict — is this (kind, body) pair legal for this target?
 *
 * Pure by design: no DB, no fs, no logging. Both gate layers (container
 * poll-loop and host agent-route) call it, and neither can share a module with
 * the other — the host is Node/pnpm and the container is Bun, separate package
 * trees. `container/agent-runner/src/a2a-kinds.ts` is a deliberate mirror of
 * this file; change both together.
 *
 * See docs/superpowers/specs/2026-07-16-a2a-protocol-normalization-design.md.
 */

export type A2aKindVerdict =
  | { ok: true; kind: string }
  | { ok: false; code: 'unknown_kind' | 'unmarked_json'; kind: string };

/**
 * @param kind        the `kind=` attribute, or null/undefined/'' when omitted
 * @param body        the message body
 * @param legalKinds  the TARGET's declared kinds, or `null` when the target has
 *                    no descriptor — in which case the gate is DISARMED and
 *                    everything passes. This is not laxity: it is what lets the
 *                    code ship inert and lets each agent.json arm its own agent.
 *                    A malformed descriptor must also land here (fail open), so
 *                    that a typo cannot bounce all of an agent's traffic.
 */
export function validateA2aKind(
  kind: string | null | undefined,
  body: string,
  legalKinds: string[] | null,
): A2aKindVerdict {
  const k = kind || 'text';
  if (legalKinds === null) return { ok: true, kind: k };

  if (k === 'text') {
    // The forgotten-attribute case: an agent means to send `set_log`, omits the
    // attribute, and the structured payload sails through as prose. Silent
    // misclassification is exactly the failure this design exists to make loud.
    // Prose that is incidentally a valid JSON *object* does not occur; arrays
    // and scalars are not the drift risk, so only objects bounce.
    return isJsonObject(body) ? { ok: false, code: 'unmarked_json', kind: 'text' } : { ok: true, kind: 'text' };
  }

  // `text` is always legal and never declared — otherwise every descriptor
  // carries the same boilerplate line, and boilerplate stops being read.
  if (!legalKinds.includes(k)) return { ok: false, code: 'unknown_kind', kind: k };
  return { ok: true, kind: k };
}

function isJsonObject(body: string): boolean {
  const trimmed = body.trim();
  if (!trimmed.startsWith('{')) return false;
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return false;
  }
  return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm exec vitest run src/modules/agent-to-agent/a2a-kinds.test.ts`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent-to-agent/a2a-kinds.ts src/modules/agent-to-agent/a2a-kinds.test.ts
git commit -m "feat(a2a): kind verdict function (host)"
```

---

## Task 2: Container verdict function (mirror)

**Files:**
- Create: `container/agent-runner/src/a2a-kinds.ts`
- Test: `container/agent-runner/src/a2a-kinds.test.ts`

**Context:** A deliberate duplicate of Task 1. The host and container share no modules (Node/pnpm vs Bun, separate trees, separate lockfiles). Keep the two files byte-identical apart from the import in the test (`bun:test` vs `vitest`) and the header comment's direction.

- [ ] **Step 1: Write the failing tests**

Same test bodies as Task 1, with the import line changed:

```ts
// container/agent-runner/src/a2a-kinds.test.ts
import { describe, expect, it } from 'bun:test';

import { validateA2aKind } from './a2a-kinds.js';
```

Copy every `it(...)` block from Task 1's test file verbatim below that import. Do not thin them out — the disarm test in particular is the property the rollout depends on.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd container/agent-runner && bun test src/a2a-kinds.test.ts`
Expected: FAIL — cannot resolve `./a2a-kinds.js`

- [ ] **Step 3: Write the implementation**

Copy `src/modules/agent-to-agent/a2a-kinds.ts` from Task 1 verbatim, changing only the mirror note in the header comment to point back at the host copy:

```
 * `src/modules/agent-to-agent/a2a-kinds.ts` is a deliberate mirror of this
 * file; change both together.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd container/agent-runner && bun test src/a2a-kinds.test.ts`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/a2a-kinds.ts container/agent-runner/src/a2a-kinds.test.ts
git commit -m "feat(a2a): kind verdict function (container mirror)"
```

---

## Task 3: `getLegalKinds` + action→kind wording

**Files:**
- Modify: `src/agent-registry.ts`
- Test: `src/agent-registry.test.ts` (exists — add to it)

**Context:** `AgentDescriptor.a2a_in` is already `Record<string, string>`. **The type does not change** — only its meaning (action name → kind name) and the wording it produces. `readAgentDescriptor(agentsDir, folder)` already returns `null` for both "not authored" and "malformed", which is exactly the fail-open behavior the gate wants.

- [ ] **Step 1: Write the failing tests**

Append to `src/agent-registry.test.ts`. Follow the existing tests' fixture style in that file (they create a temp `agentsDir` with `agent.json` files); reuse whatever helper is already there rather than inventing a new one.

```ts
describe('getLegalKinds', () => {
  it('returns the declared kinds for an authored descriptor', () => {
    // write agents/payne/agent.json with a2a_in {set_log, ack}
    expect(getLegalKinds(agentsDir, 'payne')).toEqual(['set_log', 'ack']);
  });

  it('returns null when no descriptor is authored — gate disarmed', () => {
    expect(getLegalKinds(agentsDir, 'nobody')).toBeNull();
  });

  it('returns null for a malformed descriptor — fails OPEN, never bounces everything', () => {
    // write agents/broken/agent.json containing `{"a2a_in": "not-an-object"}`
    expect(getLegalKinds(agentsDir, 'broken')).toBeNull();
  });

  it('returns an empty array for a descriptor that declares no kinds', () => {
    // write agents/mute/agent.json containing `{"role":"наблюдатель"}`
    // Distinct from null: this agent HAS a descriptor and accepts text only.
    expect(getLegalKinds(agentsDir, 'mute')).toEqual([]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm exec vitest run src/agent-registry.test.ts`
Expected: FAIL — `getLegalKinds` is not exported

- [ ] **Step 3: Write the implementation**

Add to `src/agent-registry.ts`:

```ts
/**
 * The kinds this agent accepts over a2a, or `null` when it has no usable
 * descriptor — which DISARMS the gate for it (see a2a-kinds.ts).
 *
 * `null` deliberately conflates "not authored" with "malformed": both must fail
 * open. A typo in agent.json bouncing every message the agent receives would be
 * far worse than the drift the gate prevents.
 *
 * An empty array is NOT null — it means "has a descriptor, declares no kinds",
 * i.e. text-only. That agent's gate is armed.
 */
export function getLegalKinds(agentsDir: string, folder: string): string[] | null {
  const d = readAgentDescriptor(agentsDir, folder);
  if (!d) return null;
  return Object.keys(d.a2a_in ?? {});
}
```

Then reword — semantics only, no type or behavior change:
- Line 27 doc comment: `/** action name → human description of what the agent does with it. */` → `/** kind name → human description of what the agent does with it. */`
- In `renderRegistryMarkdown`: `'Имя — канон из `agent_groups.name`. `a2a_in` — какие action агент принимает.'` → `…какие kind агент принимает.`
- In `renderRegistryMarkdown`, rename the local variables `actions` / `actionCell` / `action` to `kinds` / `kindCell` / `kind`, and the table header `| Принимает a2a |` stays as-is.
- In `ident()`'s doc comment: `(ids, action names)` → `(ids, kind names)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm exec vitest run src/agent-registry.test.ts`
Expected: PASS — all pre-existing tests still green plus the 4 new ones

- [ ] **Step 5: Commit**

```bash
git add src/agent-registry.ts src/agent-registry.test.ts
git commit -m "feat(a2a): getLegalKinds; descriptor a2a_in now means kind not action"
```

---

## Task 4: `destinations.a2a_kinds` column

**Files:**
- Modify: `src/db/schema.ts` (the `destinations` CREATE TABLE, ~line 205)
- Modify: `src/db/session-db.ts` (`DestinationRow`, `replaceDestinations`, migration)
- Test: `src/db/session-db.test.ts` (exists — add to it)

**Context:** Session DBs are created with `CREATE TABLE IF NOT EXISTS`, so a new column does NOT reach existing session DBs. `src/db/session-db.ts:302-344` already has the established idempotent pattern for this (`PRAGMA table_info` → conditional `ALTER TABLE`). Find the function that runs those migrations and add to it — do not invent a second mechanism.

- [ ] **Step 1: Write the failing tests**

Append to `src/db/session-db.test.ts`, matching the file's existing in-memory-DB style:

```ts
it('adds a2a_kinds to a destinations table created before the column existed', () => {
  const db = new Database(':memory:');
  // Simulate an old session DB: the pre-column schema.
  db.exec(`CREATE TABLE destinations (
    name TEXT PRIMARY KEY, display_name TEXT, type TEXT NOT NULL,
    channel_type TEXT, platform_id TEXT, agent_group_id TEXT)`);

  migrateInboundDb(db); // ← use whatever the real migration entry point is named

  const cols = (db.prepare("PRAGMA table_info('destinations')").all() as Array<{ name: string }>).map((c) => c.name);
  expect(cols).toContain('a2a_kinds');
});

it('round-trips a2a_kinds through replaceDestinations', () => {
  const db = new Database(':memory:');
  db.exec(INBOUND_SCHEMA);
  replaceDestinations(db, [
    { name: 'payne', display_name: 'Майор Пейн', type: 'agent', channel_type: null,
      platform_id: null, agent_group_id: 'ag-1', a2a_kinds: '["set_log","ack"]' },
    { name: 'family', display_name: 'Семья', type: 'channel', channel_type: 'telegram',
      platform_id: '-100', agent_group_id: null, a2a_kinds: null },
  ]);
  const rows = db.prepare('SELECT name, a2a_kinds FROM destinations ORDER BY name').all();
  expect(rows).toEqual([
    { name: 'family', a2a_kinds: null },
    { name: 'payne', a2a_kinds: '["set_log","ack"]' },
  ]);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm exec vitest run src/db/session-db.test.ts`
Expected: FAIL — no such column: `a2a_kinds`

- [ ] **Step 3: Write the implementation**

In `src/db/schema.ts`, add the column to the `destinations` CREATE TABLE:

```sql
CREATE TABLE IF NOT EXISTS destinations (
  name            TEXT PRIMARY KEY,
  display_name    TEXT,
  type            TEXT NOT NULL,   -- 'channel' | 'agent'
  channel_type    TEXT,            -- for type='channel'
  platform_id     TEXT,            -- for type='channel'
  agent_group_id  TEXT,            -- for type='agent'
  a2a_kinds       TEXT             -- for type='agent': JSON array of the kinds the
                                   -- TARGET accepts, or NULL when it has no
                                   -- descriptor (gate disarmed). Host-written.
);
```

In `src/db/session-db.ts`, add to `DestinationRow`:

```ts
export interface DestinationRow {
  name: string;
  display_name: string | null;
  type: 'channel' | 'agent';
  channel_type: string | null;
  platform_id: string | null;
  agent_group_id: string | null;
  /** JSON array of kinds the target accepts; null = no descriptor = gate off. */
  a2a_kinds: string | null;
}
```

Update the insert in `replaceDestinations`:

```ts
    const stmt = db.prepare(
      `INSERT INTO destinations (name, display_name, type, channel_type, platform_id, agent_group_id, a2a_kinds)
       VALUES (@name, @display_name, @type, @channel_type, @platform_id, @agent_group_id, @a2a_kinds)`,
    );
```

Add the idempotent migration alongside the existing ones (~line 302-344), following their exact shape:

```ts
  const destCols = new Set(
    (db.prepare("PRAGMA table_info('destinations')").all() as Array<{ name: string }>).map((c) => c.name),
  );
  if (!destCols.has('a2a_kinds')) {
    db.prepare('ALTER TABLE destinations ADD COLUMN a2a_kinds TEXT').run();
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm exec vitest run src/db/session-db.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/db/schema.ts src/db/session-db.ts src/db/session-db.test.ts
git commit -m "feat(a2a): destinations.a2a_kinds column + idempotent migration"
```

---

## Task 5: Fill `a2a_kinds` when projecting destinations

**Files:**
- Modify: `src/modules/agent-to-agent/write-destinations.ts`
- Test: `src/modules/agent-to-agent/write-destinations.test.ts` (create if absent)

**Context:** `writeDestinations` projects the central `agent_destinations` rows into a session's `inbound.db` on every container wake. For each **agent** target, it must now also record what that target accepts. Channel rows always get `a2a_kinds: null`.

`AGENTS_DIR` comes from `src/config.ts` — check how `src/host-sweep.ts` imports it and follow that.

- [ ] **Step 1: Write the failing test**

```ts
it('stamps the agent target\'s legal kinds onto its destination row', () => {
  // Given an agent destination pointing at a group whose folder has an
  // agent.json declaring {set_log, ack}, the projected row carries them.
  writeDestinations('ag-source', 'sess-1');
  const row = readDestination('sess-1', 'payne');
  expect(row.a2a_kinds).toBe('["set_log","ack"]');
});

it('leaves a2a_kinds null for an agent target with no descriptor — gate disarmed', () => {
  writeDestinations('ag-source', 'sess-1');
  const row = readDestination('sess-1', 'undescribed');
  expect(row.a2a_kinds).toBeNull();
});

it('leaves a2a_kinds null for channel destinations', () => {
  writeDestinations('ag-source', 'sess-1');
  const row = readDestination('sess-1', 'family');
  expect(row.a2a_kinds).toBeNull();
});
```

Use the mocking/fixture approach already used by the sibling tests in `src/modules/agent-to-agent/` (see `agent-route.test.ts`). If no test file exists for `write-destinations.ts`, model the setup on `agent-route.test.ts`'s.

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm exec vitest run src/modules/agent-to-agent/write-destinations.test.ts`
Expected: FAIL — `a2a_kinds` is undefined / property missing

- [ ] **Step 3: Write the implementation**

In `src/modules/agent-to-agent/write-destinations.ts`, add the imports:

```ts
import { getLegalKinds } from '../../agent-registry.js';
import { AGENTS_DIR } from '../../config.js';
```

Channel branch — add the field:

```ts
      resolved.push({
        name: row.local_name,
        display_name: mg.name ?? row.local_name,
        type: 'channel',
        channel_type: mg.channel_type,
        platform_id: mg.platform_id,
        agent_group_id: null,
        a2a_kinds: null,
      });
```

Agent branch — look up the target's declared kinds:

```ts
    } else if (row.target_type === 'agent') {
      const ag = getAgentGroup(row.target_id);
      if (!ag) continue;
      // What the TARGET accepts, from the target's own descriptor — the same
      // file the registry publishes to peers. null = no descriptor = gate off.
      const kinds = getLegalKinds(AGENTS_DIR, ag.folder);
      resolved.push({
        name: row.local_name,
        display_name: ag.name,
        type: 'agent',
        channel_type: null,
        platform_id: null,
        agent_group_id: ag.id,
        a2a_kinds: kinds === null ? null : JSON.stringify(kinds),
      });
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm exec vitest run src/modules/agent-to-agent/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent-to-agent/write-destinations.ts src/modules/agent-to-agent/write-destinations.test.ts
git commit -m "feat(a2a): project target legal kinds into session destinations"
```

---

## Task 6: Container reads `a2aKinds`

**Files:**
- Modify: `container/agent-runner/src/destinations.ts`
- Test: `container/agent-runner/src/destinations.test.ts` (exists — add to it)

- [ ] **Step 1: Write the failing test**

```ts
it('exposes a2aKinds parsed from the destination row', () => {
  // seed destinations with a2a_kinds = '["set_log","ack"]'
  expect(findByName('payne')?.a2aKinds).toEqual(['set_log', 'ack']);
});

it('exposes a2aKinds as null when the column is null — gate disarmed', () => {
  expect(findByName('undescribed')?.a2aKinds).toBeNull();
});

it('exposes a2aKinds as null when the column holds unparseable JSON', () => {
  // A corrupt row must fail OPEN, matching getLegalKinds host-side.
  expect(findByName('corrupt')?.a2aKinds).toBeNull();
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd container/agent-runner && bun test src/destinations.test.ts`
Expected: FAIL — `a2aKinds` does not exist

- [ ] **Step 3: Write the implementation**

In `container/agent-runner/src/destinations.ts`:

```ts
export interface DestinationEntry {
  name: string;
  displayName: string;
  type: 'channel' | 'agent';
  channelType?: string;
  platformId?: string;
  agentGroupId?: string;
  /**
   * Kinds this destination's target accepts over a2a, or null when it has no
   * descriptor (gate disarmed). Host-written on every wake from the target's
   * agent.json. Unparseable JSON is treated as null — fail open, never bounce
   * everything over a corrupt row.
   */
  a2aKinds?: string[] | null;
}

interface DestRow {
  name: string;
  display_name: string | null;
  type: 'channel' | 'agent';
  channel_type: string | null;
  platform_id: string | null;
  agent_group_id: string | null;
  a2a_kinds: string | null;
}

function parseKinds(raw: string | null): string[] | null {
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  return Array.isArray(parsed) ? parsed.filter((k): k is string => typeof k === 'string') : null;
}

function rowToEntry(row: DestRow): DestinationEntry {
  return {
    name: row.name,
    displayName: row.display_name ?? row.name,
    type: row.type,
    channelType: row.channel_type ?? undefined,
    platformId: row.platform_id ?? undefined,
    agentGroupId: row.agent_group_id ?? undefined,
    a2aKinds: parseKinds(row.a2a_kinds),
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd container/agent-runner && bun test src/destinations.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/destinations.ts container/agent-runner/src/destinations.test.ts
git commit -m "feat(a2a): container reads target legal kinds from destinations"
```

---

## Task 7: `kind=` attribute — parse and lift

**Files:**
- Modify: `container/agent-runner/src/poll-loop.ts` (`MESSAGE_BLOCK_RE` ~1131, `blockKey` ~1141, `dispatchCompleteBlocks` ~1162, `dispatchResultText` ~1198, `sendToDestination` ~1250)
- Test: `container/agent-runner/src/poll-loop.test.ts` (exists — add to it)

**Context — three traps:**

1. `to=` must stay **required** for a block to be dispatchable. If the regex starts matching `<message>` without `to=`, those blocks get consumed, `blockCount` rises, and `hasUnwrapped` (`blockCount === 0 && !!scratchpad`) goes false — silently killing the existing no-wrap nudge. The lookahead below requires `to=` without consuming it, so behavior is preserved exactly.
2. Capture groups shift: today `match[1]`=toName, `match[2]`=body. After the change `match[1]`=attribute blob, `match[2]`=body. **Both** `dispatchCompleteBlocks` and `dispatchResultText` read these — update both.
3. `blockKey` currently reads `` `${toName} ${body.trim()}` `` while its comment promises a NUL separator. Since `kind` must join the key (same body + different kind = a different message), fix the separator to match the documented intent in the same change.

- [ ] **Step 1: Write the failing tests**

```ts
it('lifts kind= into the outbound envelope for agent destinations', () => {
  dispatchResultText('<message to="payne" kind="set_log">{"reps":8}</message>', routing, new Set());
  expect(lastOut().content).toBe(JSON.stringify({ text: '{"reps":8}', kind: 'set_log' }));
});

it('defaults an omitted kind to text for agent destinations', () => {
  dispatchResultText('<message to="payne">норм</message>', routing, new Set());
  expect(lastOut().content).toBe(JSON.stringify({ text: 'норм', kind: 'text' }));
});

it('never writes kind for channel destinations', () => {
  dispatchResultText('<message to="family">Ужин в 8</message>', routing, new Set());
  expect(lastOut().content).toBe(JSON.stringify({ text: 'Ужин в 8' }));
});

it('accepts kind= before to=', () => {
  dispatchResultText('<message kind="ack" to="payne">ок</message>', routing, new Set());
  expect(lastOut().content).toBe(JSON.stringify({ text: 'ок', kind: 'ack' }));
});

it('still ignores a <message> with no to= so the no-wrap nudge survives', () => {
  const r = dispatchResultText('<message kind="set_log">{"a":1}</message>', routing, new Set());
  expect(r.newlySent).toBe(0);
  expect(r.hasUnwrapped).toBe(true);
});

it('treats same body with different kind as different messages', () => {
  const dispatched = new Set<string>();
  dispatchResultText('<message to="payne" kind="set_log">{}</message>', routing, dispatched);
  dispatchResultText('<message to="payne" kind="ack">{}</message>', routing, dispatched);
  expect(outCount()).toBe(2);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd container/agent-runner && bun test src/poll-loop.test.ts`
Expected: FAIL — kind is not in the envelope

- [ ] **Step 3: Write the implementation**

Replace `MESSAGE_BLOCK_RE` and `blockKey`:

```ts
/**
 * A dispatchable block. The lookahead requires `to="…"` WITHOUT consuming it, so
 * a <message> lacking `to=` still does not match — exactly as before. That is
 * load-bearing: if such blocks matched, they would be consumed, blockCount would
 * rise, and `hasUnwrapped` would go false, silently killing the no-wrap nudge.
 * Group 1 is the attribute blob (to= and optional kind=, either order), group 2
 * the body.
 */
const MESSAGE_BLOCK_RE = /<message\s+(?=[^>]*\bto=")([^>]*?)\s*>([\s\S]*?)<\/message>/g;

function attrOf(blob: string, name: string): string | null {
  const m = new RegExp(`\\b${name}="([^"]*)"`).exec(blob);
  return m ? m[1] : null;
}

/**
 * Dedupe key for a (toName, kind, body) triple. NUL separators so a value
 * containing another (or the separator) cannot collide. `kind` is part of the
 * key: the same body under a different kind is a different message.
 */
function blockKey(toName: string, kind: string | null, body: string): string {
  return `${toName}\0${kind ?? ''}\0${body.trim()}`;
}
```

In **both** `dispatchCompleteBlocks` and `dispatchResultText`, replace the group reads:

```ts
    const blob = match[1];
    const toName = attrOf(blob, 'to')!; // the lookahead guarantees this matches
    const kind = attrOf(blob, 'kind');
    const body = match[2].trim();
```

and update every `blockKey(toName, body)` call to `blockKey(toName, kind, body)`, and every `sendToDestination(dest, body, routing)` call to `sendToDestination(dest, body, routing, kind)`.

Update `sendToDestination`:

```ts
function sendToDestination(dest: DestinationEntry, body: string, routing: RoutingContext, kind?: string | null): void {
  const platformId = dest.type === 'channel' ? dest.platformId! : dest.agentGroupId!;
  const channelType = dest.type === 'channel' ? dest.channelType! : 'agent';
  const destRouting = resolveDestinationThread(channelType, platformId);
  // `kind` is an a2a concept only — channels never carry one. Agent messages
  // always carry it explicitly (defaulting to 'text') so the host reads one
  // field rather than inferring from absence.
  const content =
    dest.type === 'agent' ? { text: body, kind: kind || 'text' } : { text: body };
  writeMessageOut({
    id: generateId(),
    in_reply_to: destRouting?.inReplyTo ?? routing.inReplyTo,
    kind: 'chat',
    platform_id: platformId,
    channel_type: channelType,
    thread_id: destRouting?.threadId ?? null,
    content: JSON.stringify(content),
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd container/agent-runner && bun test src/poll-loop.test.ts`
Expected: PASS — new tests plus every pre-existing poll-loop test still green

- [ ] **Step 5: Typecheck**

Run: `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`
Expected: no errors

- [ ] **Step 6: Commit**

```bash
git add container/agent-runner/src/poll-loop.ts container/agent-runner/src/poll-loop.test.ts
git commit -m "feat(a2a): parse kind= and lift it into the outbound envelope"
```

---

## Task 8: Formatter renders `kind=`

**Files:**
- Modify: `container/agent-runner/src/formatter.ts` (`formatSingleChat`, ~line 220)
- Test: `container/agent-runner/src/formatter.test.ts` (exists — add to it)

**Context:** This closes the symmetry loop — the agent sees on inbound exactly the shape it must produce on outbound, every turn. That is what replaces "remember the convention from CLAUDE.md", which is what failed. `kind="text"` is not printed: the majority path must stay noise-free.

- [ ] **Step 1: Write the failing tests**

```ts
it('renders kind= for a structured a2a message', () => {
  const out = formatSingleChat(a2aRow({ kind: 'set_log', senderId: 'jarvis', sender: 'Jarvis', text: '{"reps":8}' }));
  expect(out).toContain('kind="set_log"');
  expect(out).toContain('agent="jarvis"');
});

it('omits kind for text — no noise on the majority path', () => {
  const out = formatSingleChat(a2aRow({ kind: 'text', sender: 'Jarvis', text: 'привет' }));
  expect(out).not.toContain('kind=');
});

it('omits kind when the envelope has none (pre-migration rows)', () => {
  const out = formatSingleChat(a2aRow({ sender: 'Jarvis', text: 'привет' }));
  expect(out).not.toContain('kind=');
});

it('never renders kind on a non-agent message', () => {
  // A channel message whose content happens to carry a `kind` key must not
  // sprout the attribute — same gating rationale as agent=.
  const out = formatSingleChat(channelRow({ kind: 'set_log', text: 'привет' }));
  expect(out).not.toContain('kind=');
});

it('escapes a kind containing markup', () => {
  const out = formatSingleChat(a2aRow({ kind: 'a"><script>', sender: 'X', text: 'y' }));
  expect(out).not.toContain('<script>');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd container/agent-runner && bun test src/formatter.test.ts`
Expected: FAIL — no `kind=` in output

- [ ] **Step 3: Write the implementation**

In `formatSingleChat`, next to the existing `agentAttr`:

```ts
  // Symmetry with the outbound form: the agent sees `kind=` on every structured
  // inbound, so it never has to recall the convention from CLAUDE.md — which is
  // precisely how the old prose contract drifted. `text` is the implicit default
  // and is not printed: the 55% freeform majority stays noise-free. Gated on
  // channel_type for the same reason as `agent=` — kind is an a2a concept.
  const kindAttr =
    msg.channel_type === 'agent' && content.kind && content.kind !== 'text'
      ? ` kind="${escapeXml(String(content.kind))}"`
      : '';

  return `<message${idAttr}${fromAttr}${agentAttr}${kindAttr} sender="${escapeXml(sender)}" time="${escapeXml(time)}"${replyAttr}>${replyPrefix}${escapeXml(text)}${attachmentsSuffix}</message>`;
```

Add `kind?: string` to the parsed-content type used by `parseContent` if that type is explicit.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd container/agent-runner && bun test src/formatter.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/formatter.ts container/agent-runner/src/formatter.test.ts
git commit -m "feat(a2a): render kind= on inbound a2a messages"
```

---

## Task 9: Layer 1 — container gate + nudge

**Files:**
- Modify: `container/agent-runner/src/poll-loop.ts`
- Test: `container/agent-runner/src/poll-loop.test.ts`

**Context:** The gate runs **before** the block is written to `messages_out` — an illegal block is never emitted. Rejects are collected and turned into ONE `<system>` nudge per turn at result time, in the exact shape of the existing `unwrappedNudged` path (poll-loop ~1049). The unknown-destination case (today: silently dropped at ~1173, agent never learns) joins the same nudge.

- [ ] **Step 1: Write the failing tests**

```ts
it('does not emit a block whose kind the target does not accept', () => {
  // payne's a2aKinds = ['set_log','ack']
  dispatchResultText('<message to="payne" kind="health_trend">{}</message>', routing, new Set());
  expect(outCount()).toBe(0);
});

it('does not emit a JSON-object body sent without kind=', () => {
  dispatchResultText('<message to="payne">{"exercise":"жим"}</message>', routing, new Set());
  expect(outCount()).toBe(0);
});

it('emits normally when the target has no descriptor — gate disarmed', () => {
  // undescribed.a2aKinds = null
  dispatchResultText('<message to="undescribed" kind="whatever">{"a":1}</message>', routing, new Set());
  expect(outCount()).toBe(1);
});

it('reports rejects so the caller can nudge once per turn', () => {
  const r = dispatchResultText('<message to="payne" kind="health_trend">{}</message>', routing, new Set());
  expect(r.rejects).toHaveLength(1);
  expect(r.rejects[0]).toMatchObject({ to: 'payne', kind: 'health_trend', code: 'unknown_kind' });
});

it('reports an unknown destination as a reject instead of dropping it silently', () => {
  const r = dispatchResultText('<message to="nobody">привет</message>', routing, new Set());
  expect(r.rejects).toHaveLength(1);
  expect(r.rejects[0]).toMatchObject({ to: 'nobody', code: 'unknown_destination' });
});

it('builds a nudge naming the legal kinds', () => {
  const text = buildRejectNudge([{ to: 'payne', kind: 'health_trend', code: 'unknown_kind', legal: ['set_log', 'ack'] }]);
  expect(text).toContain('health_trend');
  expect(text).toContain('set_log');
  expect(text).toContain('payne');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd container/agent-runner && bun test src/poll-loop.test.ts`
Expected: FAIL — `rejects` is not returned

- [ ] **Step 3: Write the implementation**

Add the reject type and nudge builder to `poll-loop.ts`:

```ts
import { validateA2aKind } from './a2a-kinds.js';

export interface BlockReject {
  to: string;
  kind: string | null;
  code: 'unknown_kind' | 'unmarked_json' | 'unknown_destination';
  legal?: string[];
}

/**
 * One nudge per turn describing every rejected block, in the same shape as the
 * established no-wrap nudge (see the `unwrappedNudged` path). The agent fixes it
 * in the same turn with full context — the strongest correction available, and
 * the reason Layer 1 exists at all despite the host being authoritative.
 */
export function buildRejectNudge(rejects: BlockReject[]): string {
  const lines = rejects.map((r) => {
    if (r.code === 'unknown_destination') return `• to="${r.to}" — такого адресата нет.`;
    if (r.code === 'unmarked_json') {
      return `• to="${r.to}" — тело похоже на структурное сообщение, но kind= не указан. Поставь kind, либо пришли прозой.`;
    }
    return `• to="${r.to}" kind="${r.kind}" — такой kind не принимается. Легальные: ${(r.legal ?? []).concat('text').join(', ')}.`;
  });
  return (
    `<system>Часть сообщений НЕ доставлена:\n${lines.join('\n')}\n` +
    `Формат: <message to="имя" kind="вид">тело</message>; kind можно опустить для обычного текста. ` +
    `Перешли исправленное.</system>`
  );
}
```

In `dispatchCompleteBlocks` and `dispatchResultText`, gate before sending. Both must return the rejects they saw; `dispatchResultText`'s return type becomes `{ newlySent, hasUnwrapped, rejects }` and `dispatchCompleteBlocks`'s becomes `{ remainder, rejects }` (its callers currently use the bare string return — update them).

```ts
    const dest = findByName(toName);
    if (!dest) {
      log(`Unknown destination in <message to="${toName}">, dropping block`);
      rejects.push({ to: toName, kind, code: 'unknown_destination' });
      dispatched.add(key);
      continue;
    }
    if (dest.type === 'agent') {
      const verdict = validateA2aKind(kind, body, dest.a2aKinds ?? null);
      if (!verdict.ok) {
        log(`Rejected <message to="${toName}" kind="${kind ?? ''}">: ${verdict.code}`);
        rejects.push({ to: toName, kind, code: verdict.code, legal: dest.a2aKinds ?? undefined });
        dispatched.add(key);
        continue;
      }
    }
    sendToDestination(dest, body, routing, kind);
```

At both result-time call sites (~1042 and ~1062), after the existing `hasUnwrapped` nudge block, add the reject nudge — guarded by its own once-per-turn flag declared next to `unwrappedNudged`:

```ts
                if (rejects.length > 0 && !rejectNudged) {
                  rejectNudged = true;
                  resultReceived = false;
                  query.push(buildRejectNudge(rejects));
                }
```

Rejects collected during streaming must survive to result time — accumulate them in a turn-scoped array alongside `dispatchedKeys`, and clear it where `dispatchedKeys` is reset.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd container/agent-runner && bun test`
Expected: PASS — full container suite

- [ ] **Step 5: Typecheck**

Run: `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`
Expected: no errors

- [ ] **Step 6: Commit**

```bash
git add container/agent-runner/src/poll-loop.ts container/agent-runner/src/poll-loop.test.ts
git commit -m "feat(a2a): layer 1 — container kind gate with in-turn nudge"
```

---

## Task 10: Layer 2 — host gate + bounce

**Files:**
- Modify: `src/modules/agent-to-agent/agent-route.ts`
- Test: `src/modules/agent-to-agent/agent-route.test.ts` (exists — add to it)

**Context:** `routeAgentMessage` is the single chokepoint — every a2a message passes through it regardless of emit path. This layer should almost never fire in steady state; its value is that the declaration becomes *binding* rather than aspirational. Without it an agent that skips poll-loop is unchecked, and a gate with a bypass is a document again.

The bounce reuses the **established** self-note shape (`src/container-restart.ts:28-38`, `src/modules/approvals/primitive.ts:137`): write into the sender's OWN inbound with `platformId` = the sender's own group id, `sender: 'system'`, `senderId: 'system'`. The formatter renders it `agent="system"` — which is exactly why the `system` folder is reserved (`src/group-folder.ts`). `stampSenderIdentity` will not clobber a truthy `sender`, so `'system'` survives.

**Loop safety:** the bounce is written directly to inbound and never passes through `routeAgentMessage`, so it cannot bounce a bounce.

- [ ] **Step 1: Write the failing tests**

```ts
it('does not route a kind the target does not accept', async () => {
  await routeAgentMessage(agentMsg({ kind: 'health_trend', to: 'ag-greg' }), sourceSession);
  expect(targetInbound()).toHaveLength(0);
});

it('bounces a rejected message into the SENDER\'s inbound as a system note', async () => {
  await routeAgentMessage(agentMsg({ kind: 'health_trend', to: 'ag-greg' }), sourceSession);
  const [note] = sourceInbound();
  const content = JSON.parse(note.content);
  expect(content.sender).toBe('system');
  expect(content.senderId).toBe('system');
  expect(content.text).toContain('health_trend');
  expect(note.platform_id).toBe(sourceSession.agent_group_id); // self-note
});

it('routes normally when the target has no descriptor — gate disarmed', async () => {
  await routeAgentMessage(agentMsg({ kind: 'whatever', to: 'ag-undescribed' }), sourceSession);
  expect(targetInbound()).toHaveLength(1);
});

it('routes a declared kind', async () => {
  await routeAgentMessage(agentMsg({ kind: 'finding', to: 'ag-greg' }), sourceSession);
  expect(targetInbound()).toHaveLength(1);
});

it('rejects a JSON-object body with no kind — the MCP send_message path', async () => {
  // send_message writes {text} with no kind, so it can only ever be kind:'text'.
  // That makes this plug the only violation reachable on that path — and the
  // one that matters: structured JSON quietly shipped as prose.
  await routeAgentMessage(agentMsg({ kind: undefined, body: '{"severity":"high"}', to: 'ag-greg' }), sourceSession);
  expect(targetInbound()).toHaveLength(0);
  expect(sourceInbound()).toHaveLength(1);
});

it('never gates a self-message system note', async () => {
  // System notes are injected with sender:'system' and must always land.
  await routeAgentMessage(systemNote({ to: sourceSession.agent_group_id }), sourceSession);
  expect(targetInbound()).toHaveLength(1);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm exec vitest run src/modules/agent-to-agent/agent-route.test.ts`
Expected: FAIL — the message routes despite an illegal kind

- [ ] **Step 3: Write the implementation**

In `agent-route.ts`, add imports (`getLegalKinds` from `../../agent-registry.js`, `AGENTS_DIR` from `../../config.js`, `validateA2aKind` from `./a2a-kinds.js`) and gate inside `routeAgentMessage`, **after** the destination/permission checks and **before** `resolveTargetSession`:

```ts
  const targetGroup = getAgentGroup(targetAgentGroupId);
  if (!targetGroup) {
    throw new Error(`target agent group ${targetAgentGroupId} not found for message ${msg.id}`);
  }

  // Layer 2 — the authoritative gate. Layer 1 (container poll-loop) catches
  // essentially everything in-turn with better context; this exists so the
  // declaration is BINDING: an emit path that skips poll-loop (MCP send_message,
  // an older agent-runner, anything future) is still checked. A gate with a
  // bypass is a document again, which is what we are replacing.
  const reject = checkA2aKind(msg, targetGroup);
  if (reject) {
    bounceToSender(reject, msg, session);
    return;
  }
```

Replace the existing `if (!getAgentGroup(targetAgentGroupId))` check with the `targetGroup` lookup above so the group is fetched once.

Add the two helpers:

```ts
/**
 * Returns a human-readable reason when this message must not be routed, or null
 * when it is fine. Parse failures return null — a non-JSON content string has no
 * envelope to judge, and Layer 1 already saw it.
 */
function checkA2aKind(msg: RoutableAgentMessage, targetGroup: { folder: string; name: string }): string | null {
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(msg.content);
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
  // System notes are injected by the host itself (approvals, restarts,
  // bounces). They are not agent-authored protocol and must always land —
  // this is also what stops a bounce from bouncing.
  if (parsed.sender === 'system') return null;

  const legal = getLegalKinds(AGENTS_DIR, targetGroup.folder);
  const verdict = validateA2aKind(
    typeof parsed.kind === 'string' ? parsed.kind : null,
    typeof parsed.text === 'string' ? parsed.text : '',
    legal,
  );
  if (verdict.ok) return null;

  const legalList = (legal ?? []).concat('text').join(', ');
  return verdict.code === 'unmarked_json'
    ? `Сообщение для «${targetGroup.name}» не доставлено: тело выглядит структурным, но kind= не указан. Легальные kind: ${legalList}.`
    : `Сообщение для «${targetGroup.name}» не доставлено: kind="${verdict.kind}" не принимается. Легальные kind: ${legalList}.`;
}

/**
 * Write the rejection into the SENDER's own inbound as a system self-note and
 * wake it — the established shape (see container-restart.ts, approvals/
 * primitive.ts). Without this the message would die silently in the retry path,
 * which is the "cuts live traffic" failure the owner ruled out.
 */
function bounceToSender(reason: string, msg: RoutableAgentMessage, session: Session): void {
  log.warn('Agent message rejected: illegal a2a kind', {
    from: session.agent_group_id,
    fromSession: session.id,
    sourceMsgId: msg.id,
    reason,
  });
  writeSessionMessage(session.agent_group_id, session.id, {
    id: `a2a-reject-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    kind: 'chat',
    timestamp: new Date().toISOString(),
    platformId: session.agent_group_id,
    channelType: 'agent',
    threadId: null,
    content: JSON.stringify({
      text: `<system>${reason} Исправь kind и перешли.</system>`,
      sender: 'system',
      senderId: 'system',
    }),
    sourceSessionId: session.id,
  });
}
```

Note `bounceToSender` does not call `wakeContainer` — the sender's container is by definition alive (it just emitted this) and will see the note on its next poll. Waking it would race its own turn.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm exec vitest run src/modules/agent-to-agent/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent-to-agent/agent-route.ts src/modules/agent-to-agent/agent-route.test.ts
git commit -m "feat(a2a): layer 2 — authoritative host kind gate with bounce to sender"
```

---

## Task 11: `add_reaction` rejects agent destinations

**Files:**
- Modify: `container/agent-runner/src/mcp-tools/core.ts` (`addReaction`, ~line 379-412)
- Test: `container/agent-runner/src/mcp-tools/core.test.ts` (exists — add to it)

**Context:** `add_reaction` mints `{operation:'reaction', messageId, emoji}` and sends it to the session's `routing`. When the session is agent-typed the reaction lands in a peer's inbound — where **the host has no handling for it at all** (zero references in `delivery.ts` or `modules/agent-to-agent/`). It is JSON noise in the peer's context: reactions are a platform affordance, and between agents there is nothing to render them. 13 live rows. Killing this also removes `operation` — the fourth rival discriminator.

- [ ] **Step 1: Write the failing tests**

```ts
it('errors instead of sending a reaction to an agent destination', async () => {
  // session routing resolves to channel_type 'agent'
  const res = await addReaction.handler({ messageId: 3, emoji: 'thumbs_up' });
  expect(res.isError).toBe(true);
  expect(res.content[0].text).toContain('reaction');
  expect(outCount()).toBe(0);
});

it('still sends a reaction to a channel destination', async () => {
  const res = await addReaction.handler({ messageId: 3, emoji: 'thumbs_up' });
  expect(res.isError).toBeUndefined();
  expect(outCount()).toBe(1);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd container/agent-runner && bun test src/mcp-tools/core.test.ts`
Expected: FAIL — the reaction is sent to the agent destination

- [ ] **Step 3: Write the implementation**

In `addReaction`'s handler, after the existing routing resolution and its null check:

```ts
    // Reactions are a platform affordance — the host renders them on Telegram,
    // Slack, etc. Between agents there is nothing to render: the host has no a2a
    // reaction handling at all, so the payload lands as raw JSON noise in the
    // peer's context. Refuse rather than emit garbage.
    if (routing.channel_type === 'agent') {
      return err('Reactions are not supported for agent destinations — send a message instead.');
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd container/agent-runner && bun test src/mcp-tools/core.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/mcp-tools/core.ts container/agent-runner/src/mcp-tools/core.test.ts
git commit -m "feat(a2a): add_reaction refuses agent destinations"
```

---

## Task 12: The system prompt teaches `kind=` — generated, not written

**Files:**
- Modify: `container/agent-runner/src/destinations.ts` (`buildDestinationsSection`)
- Test: `container/agent-runner/src/destinations.test.ts`

**Context — this is the most important task in the plan, not a polish step.**
`buildDestinationsSection()` generates the "## Sending messages" system-prompt
addendum from the live `destinations` table, on every wake. That table now carries
`a2a_kinds`, so the addendum can list each agent destination's legal kinds **from
the same descriptor the gate enforces**.

That is the whole project in one function: the contract the agent reads is
*generated from the enforced artifact* instead of hand-copied into CLAUDE.md prose.
Hand-copied prose is what drifted. If this task is skipped, the agent learns the new
format only from prose — and we have rebuilt the thing we are removing.

Only agent destinations with a non-null `a2aKinds` list kinds. A `null` (no
descriptor) prints exactly as today — nothing to teach, nothing enforced.

- [ ] **Step 1: Write the failing tests**

```ts
it('lists legal kinds for an agent destination that has a descriptor', () => {
  // payne: a2aKinds = ['set_log','ack']
  const out = buildDestinationsSection();
  expect(out).toContain('`payne`');
  expect(out).toContain('kind: set_log, ack');
});

it('says nothing about kinds for an agent destination with no descriptor', () => {
  // undescribed: a2aKinds = null → gate disarmed → nothing to teach
  const out = buildDestinationsSection();
  expect(out).toMatch(/`undescribed`[^\n]*$/m);
  expect(out).not.toContain('undescribed` — kind:');
});

it('says nothing about kinds for channel destinations', () => {
  const out = buildDestinationsSection();
  expect(out).not.toMatch(/`family`[^\n]*kind:/);
});

it('documents the kind= attribute when any destination declares kinds', () => {
  const out = buildDestinationsSection();
  expect(out).toContain('kind=');
});

it('does not mention kind= at all when no destination declares kinds', () => {
  // Pre-rollout state: every a2aKinds is null. The addendum must read exactly as
  // it does today — this is the ship-inert property, visible in the prompt.
  const out = buildDestinationsSection();
  expect(out).not.toContain('kind');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd container/agent-runner && bun test src/destinations.test.ts`
Expected: FAIL — no kind information in the addendum

- [ ] **Step 3: Write the implementation**

In `buildDestinationsSection()`, append the kind list to each destination's bullet
and add the format line only when at least one destination declares kinds:

```ts
function kindSuffix(d: DestinationEntry): string {
  // Only an agent WITH a descriptor has anything to teach. null = gate disarmed.
  if (d.type !== 'agent' || !d.a2aKinds || d.a2aKinds.length === 0) return '';
  return ` — kind: ${d.a2aKinds.join(', ')}`;
}
```

Use it in both the single-destination and multi-destination branches. Then, after
the existing `<message to="name">` wrapping paragraph, add — **guarded** so the
pre-rollout prompt is byte-identical to today's:

```ts
  const anyKinds = all.some((d) => d.type === 'agent' && d.a2aKinds && d.a2aKinds.length > 0);
  if (anyKinds) {
    lines.push('');
    lines.push(
      'Для агентов-адресатов, у которых указаны `kind`, структурные сообщения помечай атрибутом: ' +
        '`<message to="имя" kind="вид">{…}</message>`. Обычный текст шлётся без `kind`. ' +
        'Непомеченное сообщение с JSON-телом и незнакомый `kind` не доставляются — ты получишь ' +
        '`<system>` с причиной и списком допустимых `kind`.',
    );
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd container/agent-runner && bun test src/destinations.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/destinations.ts container/agent-runner/src/destinations.test.ts
git commit -m "feat(a2a): system prompt lists legal kinds, generated from the descriptor"
```

---

## Task 13: Full verification

- [ ] **Step 1: Host suite**

Run: `pnpm test`
Expected: PASS (835+ tests)

- [ ] **Step 2: Container suite**

Run: `cd container/agent-runner && bun test`
Expected: PASS (279+ tests)

- [ ] **Step 3: Both typechecks**

```bash
pnpm run build
pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit
```
Expected: no errors

- [ ] **Step 4: Confirm the code is inert**

No `agent.json` exists yet, so every `getLegalKinds` returns null and every gate is disarmed. Verify by inspection that no test needed a descriptor to make **existing** behavior pass — if any pre-existing test changed expectations, the ship-inert property is broken and that is a bug, not a test to update.

---

## Rollout (NOT subagent work — owner-in-the-loop)

Tasks 1-13 ship **inert**: zero descriptors exist, so every gate is off, the system prompt is byte-identical to today's, and behavior is unchanged. Arming is a separate, deliberate step.

1. **Deploy the code.** Push, `git pull` on the VDS, `pnpm run build` (dist/ is gitignored), rebuild the container image, restart the service.
2. **Author 5 descriptors** — `agents/<folder>/agent.json` for jarvis, greg, payne, gordon, scrooge, using the vocabulary table in the spec (§4). Ground the payload hints in live data, not memory: re-run the inventory query to read real key sets per kind. **VDS gotcha:** `pnpm exec tsx scripts/q.ts` does not work there (root shell Node 20 vs the service's Node 22 `better-sqlite3` build) — write a `.js` using `require("/home/nanoclaw/nanoclaw/node_modules/better-sqlite3")` and run it with `/usr/bin/node`.
3. **Delete** the hand-written a2a contract tables from the 5 CLAUDE.md files — Task 12's generated addendum and `/workspace/global/agents.md` now carry that content from the descriptor. Keep only what a descriptor cannot express (when to send what, and why). Re-stating the kind list in prose would recreate the hand-maintained duplicate this project exists to remove. `groups/` is gitignored → deploy by scp, never git. `agents/<folder>/` is the live mount and `groups/<folder>/` the source mirror; update both.
4. **Rebirth all five together**, in a quiet hour: kill containers **and** `DELETE FROM session_state WHERE key LIKE 'continuation:%'` — CLAUDE.md changes need both.
5. **Verify**: each agent's first post-rebirth a2a exchange lands; `logs/nanoclaw.error.log` shows no `Agent message rejected` storm. A burst of Layer-2 rejects means a descriptor disagrees with what the agents were actually told — fix the descriptor, not the gate.

In-flight a2a rows already sitting in an `inbound.db` at switchover are old-format and already past the gate; they render as text with JSON bodies. Single digits. Do not build a converter.
