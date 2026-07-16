# Agent Registry + a2a Naming Grounding — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Distribute a shared agent registry (canonical name + role + a2a contract) to every agent, and stamp the sender's canonical name onto inbound a2a rows so a relaying agent never has to invent a peer's name.

**Architecture:** `agent_groups.name` is the single canonical name source (verified: the table has **no** `display_name` column). Each agent's role + accepted a2a actions live in `agents/<folder>/agent.json`. A host-sweep generator merges the two into `agents.json` + `agents.md` and writes them into every person's `data/user-memory/<person>/global/`, which every container mounts read-only at `/workspace/global/`. Separately, `agent-route.ts` stamps `sender`/`senderId` onto forwarded a2a content; the container formatter already renders `content.sender`, so the name arrives as data.

**Tech Stack:** Node + TypeScript + vitest (host, pnpm); Bun + bun:test (container agent-runner); better-sqlite3 (central DB); SQLite session DBs.

**Design spec:** `docs/superpowers/specs/2026-07-16-agent-registry-a2a-grounding-design.md`

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `src/modules/agent-to-agent/agent-route.ts` | **Modify.** Add `stampSenderIdentity()`; call it on forwarded a2a content. | 1 |
| `src/modules/agent-to-agent/agent-route.test.ts` | **Modify.** Unit tests for the stamp. | 1 |
| `container/agent-runner/src/formatter.ts` | **Modify.** Emit `agent="<folder>"` on a2a rows. | 2 |
| `container/agent-runner/src/formatter.test.ts` | **Modify.** a2a identity render tests. | 2 |
| `src/agent-registry.ts` | **Create.** Read descriptors, build registry entries, render markdown, fan out per person. One responsibility: produce+publish the registry. | 3, 4 |
| `src/agent-registry.test.ts` | **Create.** Build/render/fan-out tests. | 3, 4 |
| `src/host-sweep.ts` | **Modify.** Call `writeAgentRegistry` each sweep. | 5 |
| `agents/<folder>/agent.json` ×5 | **Create.** Per-agent role + a2a contract. | 6 |
| `agents/<folder>/CLAUDE.md` ×5 | **Modify.** §Команда → pointer at the registry. | 7 |

**No DB migrations.** Tasks 1–2 are independent of 3–5 and can land in either order; 6 depends on 3–5 being deployed; 7 depends on 6.

---

### Task 1: Stamp the source agent's identity onto a2a content (host)

**Why:** the a2a payload Payne sends is `{"action":"workout_done",…}` with no sender. The target agent has to recall who sent it — which is how «Майор Пейн» became «Паулино». Stamping `sender` makes the formatter render the name for free (it already reads `content.sender`).

**Files:**
- Modify: `src/modules/agent-to-agent/agent-route.ts` (add helper; call it at line ~247)
- Test: `src/modules/agent-to-agent/agent-route.test.ts`

- [ ] **Step 1: Write the failing test**

Append this describe block to `src/modules/agent-to-agent/agent-route.test.ts`. It mirrors the file's existing DB setup idiom (`initTestDb()` → `runMigrations(db)` → `createAgentGroup(...)`, `closeDb()` in `afterEach`).

```ts
describe('stampSenderIdentity', () => {
  beforeEach(() => {
    const db = initTestDb();
    runMigrations(db);
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
  });

  afterEach(() => {
    closeDb();
  });

  it('stamps the source agent canonical name + folder onto JSON content', () => {
    const out = stampSenderIdentity('{"action":"workout_done","type":"Ноги"}', 'payne');
    expect(JSON.parse(out)).toEqual({
      action: 'workout_done',
      type: 'Ноги',
      sender: 'Майор Пейн',
      senderId: 'payne',
    });
  });

  it('never clobbers an existing sender (system notes set their own)', () => {
    const out = stampSenderIdentity('{"text":"hi","sender":"system","senderId":"system"}', 'payne');
    expect(JSON.parse(out).sender).toBe('system');
    expect(JSON.parse(out).senderId).toBe('system');
  });

  it('returns non-JSON content unchanged', () => {
    expect(stampSenderIdentity('plain text', 'payne')).toBe('plain text');
  });

  it('returns non-object JSON content unchanged', () => {
    expect(stampSenderIdentity('"just a string"', 'payne')).toBe('"just a string"');
  });

  it('returns content unchanged when the source group is unknown', () => {
    expect(stampSenderIdentity('{"text":"hi"}', 'ghost')).toBe('{"text":"hi"}');
  });

  it('falls back to the folder id when the group name is empty', () => {
    createAgentGroup({ id: 'noname', name: '', folder: 'noname', agent_provider: null, created_at: now() });
    expect(JSON.parse(stampSenderIdentity('{"text":"hi"}', 'noname')).sender).toBe('noname');
  });
});
```

Add `stampSenderIdentity` to the existing import from `./agent-route.js` at the top of the file:

```ts
import { isSafeAttachmentName, resolveTargetSession, routeAgentMessage, stampSenderIdentity } from './agent-route.js';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/modules/agent-to-agent/agent-route.test.ts`
Expected: FAIL — `stampSenderIdentity is not a function` (or a TS/import error).

- [ ] **Step 3: Write the implementation**

In `src/modules/agent-to-agent/agent-route.ts`, add this exported function (place it just above `routeAgentMessage`). `getAgentGroup` is already imported at the top of the file.

```ts
/**
 * Stamp the source agent's identity onto forwarded a2a content.
 *
 * a2a payloads are agent-authored JSON (`{"action":"workout_done",…}`) and carry
 * no sender, so a relaying target would have to *recall* who sent it — which is
 * exactly how a peer's name ends up invented. Adding `sender` (the source's
 * canonical `agent_groups.name`) makes the container formatter render
 * `sender="Майор Пейн"` through its existing `content.sender` path.
 *
 * `agent_groups.name` is the ONLY name source — deliberately not duplicated
 * into any descriptor, since that duplication is the drift this fixes.
 *
 * Never clobbers an existing `sender`/`senderId`: system notes injected back
 * into a session set their own (`sender: 'system'`). Non-JSON and non-object
 * content is returned unchanged — there is no object to stamp.
 */
export function stampSenderIdentity(content: string, sourceAgentGroupId: string): string {
  const group = getAgentGroup(sourceAgentGroupId);
  if (!group) return content;

  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    return content;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return content;

  const obj = parsed as Record<string, unknown>;
  // Fall back to the folder id if a group somehow has no name — naming the
  // sender by id still beats leaving the target to guess.
  if (obj.sender === undefined) obj.sender = group.name || group.folder;
  if (obj.senderId === undefined) obj.senderId = group.folder;
  return JSON.stringify(obj);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/modules/agent-to-agent/agent-route.test.ts`
Expected: PASS (all tests in the file, including the pre-existing routeAgentMessage ones — they assert `JSON.parse(content).text`, so extra keys are harmless).

- [ ] **Step 5: Wire the stamp into routeAgentMessage**

In `src/modules/agent-to-agent/agent-route.ts`, replace this line (~247):

```ts
  const forwardedContent = forwardFileAttachments(msg, a2aMsgId, session, targetAgentGroupId, targetSession.id);
```

with:

```ts
  // Stamp the source agent's identity *after* file forwarding so the sender
  // fields survive that step's re-serialization.
  const forwardedContent = stampSenderIdentity(
    forwardFileAttachments(msg, a2aMsgId, session, targetAgentGroupId, targetSession.id),
    session.agent_group_id,
  );
```

- [ ] **Step 6: Run the full host suite**

Run: `pnpm test`
Expected: PASS — no regressions.

- [ ] **Step 7: Commit**

```bash
git add src/modules/agent-to-agent/agent-route.ts src/modules/agent-to-agent/agent-route.test.ts
git commit -m "feat(a2a): stamp source agent name onto forwarded a2a content"
```

---

### Task 2: Render the agent id on a2a messages (container)

**Why:** `sender="Майор Пейн"` gives the name; `agent="payne"` gives the stable id so the agent can match a peer against the registry's `a2a_in` contracts. Gated on `channel_type === 'agent'` so human messages (which also carry `content.senderId`, e.g. `telegram:123`) never grow a bogus `agent=`.

**Files:**
- Modify: `container/agent-runner/src/formatter.ts:220-236` (`formatSingleChat`)
- Test: `container/agent-runner/src/formatter.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `container/agent-runner/src/formatter.test.ts`. The file's existing `insertMessage` helper does not set `channel_type`, so a2a rows need their own insert.

```ts
describe('a2a sender identity', () => {
  function insertA2a(id: string, content: object) {
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, channel_type, platform_id, content)
         VALUES (?, 'chat', ?, 'pending', 'agent', 'payne', ?)`,
      )
      .run(id, new Date().toISOString(), JSON.stringify(content));
  }

  it('renders the stamped agent name and id on an a2a row', () => {
    insertA2a('a1', {
      sender: 'Майор Пейн',
      senderId: 'payne',
      text: '{"action":"workout_done","type":"Ноги"}',
    });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('sender="Майор Пейн"');
    expect(result).toContain('agent="payne"');
  });

  it('does not emit agent= for non-agent (human) messages', () => {
    insertMessage('m1', 'chat', { sender: 'Alice', senderId: 'telegram:1', text: 'hi' });
    const result = formatMessages(getPendingMessages());
    expect(result).toContain('sender="Alice"');
    expect(result).not.toContain('agent=');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/formatter.test.ts`
Expected: FAIL — first test errors on `expect(result).toContain('agent="payne"')` (the attribute is not emitted yet). The second test passes already.

- [ ] **Step 3: Write the implementation**

In `container/agent-runner/src/formatter.ts`, inside `formatSingleChat`, add `agentAttr` after the existing `fromAttr` line (~233):

```ts
  const fromAttr = originAttr(msg);
  // a2a rows carry the source agent's folder in `content.senderId` (stamped
  // host-side by agent-route.ts). Emit it as a stable id alongside the human
  // name in `sender=`. Gated on channel_type: human messages also populate
  // `senderId` (a platform user id), which is not an agent.
  const agentAttr =
    msg.channel_type === 'agent' && content.senderId ? ` agent="${escapeXml(String(content.senderId))}"` : '';
```

and add it to the returned template (same line, after `${fromAttr}`):

```ts
  return `<message${idAttr}${fromAttr}${agentAttr} sender="${escapeXml(sender)}" time="${escapeXml(time)}"${replyAttr}>${replyPrefix}${escapeXml(text)}${attachmentsSuffix}</message>`;
```

- [ ] **Step 4: Run tests + typecheck to verify they pass**

Run: `cd container/agent-runner && bun test src/formatter.test.ts`
Expected: PASS.

Run (from repo root): `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`
Expected: no output (clean).

- [ ] **Step 5: Run the whole container suite**

Run: `cd container/agent-runner && bun test`
Expected: PASS — no regressions.

- [ ] **Step 6: Commit**

```bash
git add container/agent-runner/src/formatter.ts container/agent-runner/src/formatter.test.ts
git commit -m "feat(formatter): render agent id on a2a messages"
```

---

### Task 3: Build the registry from agent_groups + descriptors (host)

**Files:**
- Create: `src/agent-registry.ts`
- Test: `src/agent-registry.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/agent-registry.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { readAgentDescriptor, buildRegistry, renderRegistryMarkdown } from './agent-registry.js';
import { initTestDb, closeDb, runMigrations, createAgentGroup } from './db/index.js';

let tmp: string;

function now(): string {
  return new Date().toISOString();
}

function writeDescriptor(folder: string, body: string): void {
  const dir = path.join(tmp, folder);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'agent.json'), body);
}

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-registry-'));
  const db = initTestDb();
  runMigrations(db);
});

afterEach(() => {
  closeDb();
  fs.rmSync(tmp, { recursive: true, force: true });
});

describe('readAgentDescriptor', () => {
  it('reads a well-formed descriptor', () => {
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' } }));
    expect(readAgentDescriptor(tmp, 'payne')).toEqual({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' } });
  });

  it('returns null when the descriptor is absent', () => {
    expect(readAgentDescriptor(tmp, 'nobody')).toBeNull();
  });

  it('returns null on malformed JSON instead of throwing', () => {
    writeDescriptor('broken', '{not json');
    expect(readAgentDescriptor(tmp, 'broken')).toBeNull();
  });

  it('returns null when the descriptor is not an object', () => {
    writeDescriptor('weird', '["array"]');
    expect(readAgentDescriptor(tmp, 'weird')).toBeNull();
  });
});

describe('buildRegistry', () => {
  it('joins each agent group with its descriptor, name from agent_groups', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог тренировки' } }));

    expect(buildRegistry(tmp)).toEqual([
      {
        id: 'payne',
        name: 'Майор Пейн',
        role: 'фитнес-тренер',
        a2a_in: { workout_done: 'лог тренировки' },
        aka: [],
      },
    ]);
  });

  it('still lists an agent that has no descriptor (name-only entry)', () => {
    createAgentGroup({ id: 'greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    expect(buildRegistry(tmp)).toEqual([{ id: 'greg', name: 'Greg', role: '', a2a_in: {}, aka: [] }]);
  });

  it('returns an empty list when there are no agent groups', () => {
    expect(buildRegistry(tmp)).toEqual([]);
  });
});

describe('renderRegistryMarkdown', () => {
  it('renders a table row per agent with name, role and actions', () => {
    const md = renderRegistryMarkdown([
      { id: 'payne', name: 'Майор Пейн', role: 'фитнес-тренер', a2a_in: { workout_done: 'лог тренировки' }, aka: [] },
    ]);
    expect(md).toContain('| `payne` | Майор Пейн | фитнес-тренер | `workout_done` |');
    expect(md).toContain('- `workout_done` — лог тренировки');
  });

  it('renders a dash for an agent with no role or actions', () => {
    const md = renderRegistryMarkdown([{ id: 'greg', name: 'Greg', role: '', a2a_in: {}, aka: [] }]);
    expect(md).toContain('| `greg` | Greg | — | — |');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/agent-registry.test.ts`
Expected: FAIL — `Cannot find module './agent-registry.js'`.

- [ ] **Step 3: Write the implementation**

Create `src/agent-registry.ts`:

```ts
/**
 * Build and publish the shared agent registry.
 *
 * Every agent needs to know who its peers are — canonical name, role, and which
 * a2a actions they accept. Without that, a relaying agent recalls a peer's name
 * from memory, which is how «Майор Пейн» once became «Паулино».
 *
 * Name comes from `agent_groups.name` — the single source, never duplicated into
 * a descriptor (that duplication is the drift being fixed). Role + a2a contract
 * come from each agent's own `agents/<folder>/agent.json`. The merged result is
 * rendered to `agents.json` (structured) and `agents.md` (what agents read).
 */
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';

import { getAllAgentGroups } from './db/agent-groups.js';
import { log } from './log.js';

/** Shape of `agents/<folder>/agent.json`. Every field optional — a partial descriptor degrades to a name-only entry. */
export interface AgentDescriptor {
  role?: string;
  /** action name → human description of what the agent does with it. */
  a2a_in?: Record<string, string>;
  aka?: string[];
}

export interface RegistryEntry {
  id: string;
  name: string;
  role: string;
  a2a_in: Record<string, string>;
  aka: string[];
}

function sha(s: string): string {
  return crypto.createHash('sha256').update(s).digest('hex');
}

/**
 * Read `<agentsDir>/<folder>/agent.json`. Returns null when absent (not yet
 * authored) or unusable. A bad descriptor must never take the registry down —
 * the agent still appears, name-only.
 */
export function readAgentDescriptor(agentsDir: string, folder: string): AgentDescriptor | null {
  let raw: string;
  try {
    raw = fs.readFileSync(path.join(agentsDir, folder, 'agent.json'), 'utf8');
  } catch {
    return null; // no descriptor yet
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    log.warn('agent-registry: malformed agent.json, ignored', { folder, err });
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    log.warn('agent-registry: agent.json is not an object, ignored', { folder });
    return null;
  }
  return parsed as AgentDescriptor;
}

/**
 * Every agent group joined with its descriptor. The DB is the canonical agent
 * list, so an agent with no descriptor still appears (name only) — the registry
 * is a complete who's-who even before descriptors are authored.
 */
export function buildRegistry(agentsDir: string): RegistryEntry[] {
  return getAllAgentGroups().map((g) => {
    const d = readAgentDescriptor(agentsDir, g.folder);
    return {
      id: g.folder,
      name: g.name,
      role: d?.role ?? '',
      a2a_in: d?.a2a_in ?? {},
      aka: d?.aka ?? [],
    };
  });
}

/** Render the registry as the markdown agents actually read. */
export function renderRegistryMarkdown(entries: RegistryEntry[]): string {
  const lines = [
    '# Реестр агентов',
    '',
    'Кто есть кто в команде. **Генерируется хостом — не редактировать вручную.**',
    'Имя — канон из `agent_groups.name`. `a2a_in` — какие action агент принимает.',
    '',
    '| id | Имя | Роль | Принимает a2a |',
    '|---|---|---|---|',
  ];
  for (const e of entries) {
    const actions = Object.keys(e.a2a_in);
    const actionCell = actions.length > 0 ? actions.map((a) => `\`${a}\``).join(', ') : '—';
    lines.push(`| \`${e.id}\` | ${e.name} | ${e.role || '—'} | ${actionCell} |`);
  }
  for (const e of entries) {
    const actions = Object.entries(e.a2a_in);
    if (actions.length === 0) continue;
    lines.push('', `## ${e.name} (\`${e.id}\`)`);
    if (e.role) lines.push(`Роль: ${e.role}`);
    if (e.aka.length > 0) lines.push(`Также зовут: ${e.aka.join(', ')}`);
    lines.push('');
    for (const [action, desc] of actions) {
      lines.push(`- \`${action}\` — ${desc}`);
    }
  }
  lines.push('');
  return lines.join('\n');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/agent-registry.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent-registry.ts src/agent-registry.test.ts
git commit -m "feat(registry): build agent registry from agent_groups + descriptors"
```

---

### Task 4: Fan the registry into every person's global dir (host)

**Why:** `/workspace/global` is mounted per person from `data/user-memory/<person>/global`. The registry's content is person-independent, so the same bytes go into every person's dir — that is what makes one uniform `/workspace/global/agents.md` path work for all agents.

**Files:**
- Modify: `src/agent-registry.ts` (add `writeRegistryForPerson`, `writeAgentRegistry`)
- Test: `src/agent-registry.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `src/agent-registry.test.ts`, and extend the import at the top of the file to:

```ts
import {
  readAgentDescriptor,
  buildRegistry,
  renderRegistryMarkdown,
  writeAgentRegistry,
} from './agent-registry.js';
```

```ts
describe('writeAgentRegistry', () => {
  it('writes agents.json + agents.md into every person global dir', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    writeDescriptor('payne', JSON.stringify({ role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' } }));

    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });
    fs.mkdirSync(path.join(userMemoryBase, 'p2'), { recursive: true });

    // 2 files × 2 persons
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(4);

    for (const person of ['owner', 'p2']) {
      const md = fs.readFileSync(path.join(userMemoryBase, person, 'global', 'agents.md'), 'utf8');
      expect(md).toContain('Майор Пейн');
      const json = JSON.parse(fs.readFileSync(path.join(userMemoryBase, person, 'global', 'agents.json'), 'utf8'));
      expect(json).toEqual([
        { id: 'payne', name: 'Майор Пейн', role: 'фитнес-тренер', a2a_in: { workout_done: 'лог' }, aka: [] },
      ]);
    }
  });

  it('does not rewrite unchanged content (hash-gated)', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });

    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(0);
  });

  it('rewrites when a name changes', () => {
    createAgentGroup({ id: 'greg', name: 'Greg', folder: 'greg', agent_provider: null, created_at: now() });
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });
    writeAgentRegistry(userMemoryBase, tmp);

    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(2);
    expect(fs.readFileSync(path.join(userMemoryBase, 'owner', 'global', 'agents.md'), 'utf8')).toContain('Майор Пейн');
  });

  it('returns 0 when the user-memory base does not exist', () => {
    createAgentGroup({ id: 'payne', name: 'Майор Пейн', folder: 'payne', agent_provider: null, created_at: now() });
    expect(writeAgentRegistry(path.join(tmp, 'nonexistent'), tmp)).toBe(0);
  });

  it('returns 0 when there are no agent groups (never publishes an empty registry)', () => {
    const userMemoryBase = path.join(tmp, 'user-memory');
    fs.mkdirSync(path.join(userMemoryBase, 'owner'), { recursive: true });
    expect(writeAgentRegistry(userMemoryBase, tmp)).toBe(0);
    expect(fs.existsSync(path.join(userMemoryBase, 'owner', 'global', 'agents.md'))).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/agent-registry.test.ts`
Expected: FAIL — `writeAgentRegistry is not a function`.

- [ ] **Step 3: Write the implementation**

Append to `src/agent-registry.ts`:

```ts
/**
 * Write the registry pair into one person's `global/`. Hash-gated, and
 * write-then-rename so a container reading the mount never sees a half-written
 * file (same idiom as public-profiles.ts). Returns files (re)written.
 */
export function writeRegistryForPerson(personRoot: string, json: string, md: string): number {
  const globalDir = path.join(personRoot, 'global');
  const files: Array<[string, string]> = [
    ['agents.json', json],
    ['agents.md', md],
  ];
  let written = 0;
  for (const [name, body] of files) {
    const dest = path.join(globalDir, name);
    let existing: string | null = null;
    try {
      existing = fs.readFileSync(dest, 'utf8');
    } catch {
      // missing → fall through and write
    }
    if (existing !== null && sha(existing) === sha(body)) continue;
    try {
      fs.mkdirSync(globalDir, { recursive: true });
      const tmpPath = `${dest}.tmp`;
      fs.writeFileSync(tmpPath, body);
      fs.renameSync(tmpPath, dest);
      written++;
    } catch (err) {
      log.warn('agent-registry: failed to write registry file', { dest, err });
    }
  }
  return written;
}

/**
 * Build the registry once and fan it into every person's global dir. Content is
 * person-independent — only the destination varies, so each container resolves
 * the same `/workspace/global/agents.md`. Returns total files written.
 */
export function writeAgentRegistry(userMemoryBase: string, agentsDir: string): number {
  const entries = buildRegistry(agentsDir);
  // Never publish an empty registry: a transient DB read returning nothing must
  // not blank out a good file that agents are relying on.
  if (entries.length === 0) return 0;

  const json = JSON.stringify(entries, null, 2) + '\n';
  const md = renderRegistryMarkdown(entries);

  let persons: fs.Dirent[];
  try {
    persons = fs.readdirSync(userMemoryBase, { withFileTypes: true });
  } catch {
    return 0; // user-memory doesn't exist yet (pre-migration) — no-op
  }
  let written = 0;
  for (const p of persons) {
    if (!p.isDirectory()) continue;
    written += writeRegistryForPerson(path.join(userMemoryBase, p.name), json, md);
  }
  return written;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/agent-registry.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent-registry.ts src/agent-registry.test.ts
git commit -m "feat(registry): fan agent registry into every person global dir"
```

---

### Task 5: Wire the registry into the host sweep

**Files:**
- Modify: `src/host-sweep.ts` (import + call inside `sweep()`)

- [ ] **Step 1: Add the import**

In `src/host-sweep.ts`, add the module import next to the existing `projectAllPublicProfiles` import (~line 49):

```ts
import { writeAgentRegistry } from './agent-registry.js';
```

Add `AGENTS_DIR` to the existing `./config.js` import (which already brings in `DATA_DIR`). The result must include both, e.g.:

```ts
import { AGENTS_DIR, DATA_DIR } from './config.js';
```

- [ ] **Step 2: Add the sweep call**

In `sweep()`, immediately after the `projectAllPublicProfiles` try/catch block (which ends ~line 148) and before the summary-notify block, insert:

```ts
  // Publish the shared agent registry (who's who + a2a contracts) into every
  // person's global/ so agents read peer names as data instead of recalling
  // them. Own try so a registry failure never skips the session sweep below.
  try {
    const written = writeAgentRegistry(path.join(DATA_DIR, 'user-memory'), AGENTS_DIR);
    if (written > 0) log.info('Wrote agent registry', { written });
  } catch (err) {
    log.error('Agent registry write error', { err });
  }
```

The first `sweep()` runs at startup (`startHostSweep` → `sweep()`), so no separate startup call is needed.

- [ ] **Step 3: Verify the whole host suite + build**

Run: `pnpm test`
Expected: PASS.

Run: `pnpm run build`
Expected: clean compile, no TS errors.

- [ ] **Step 4: Commit**

```bash
git add src/host-sweep.ts
git commit -m "feat(registry): publish agent registry each host sweep"
```

- [ ] **Step 5: Deploy the host + container code to the VDS**

The agent-runner source is host-mounted, so no image rebuild is needed.

```bash
git push origin main
ssh root@148.253.211.164 'su - nanoclaw -c "cd /home/nanoclaw/nanoclaw && git pull && pnpm run build" && XDG_RUNTIME_DIR=/run/user/1000 sudo -u nanoclaw systemctl --user restart nanoclaw'
```

- [ ] **Step 6: Verify the registry was generated on the VDS**

Wait ~60s for a sweep, then:

```bash
ssh root@148.253.211.164 'ls -la /home/nanoclaw/nanoclaw/data/user-memory/*/global/agents.* && cat /home/nanoclaw/nanoclaw/data/user-memory/owner/global/agents.md'
```

Expected: `agents.json` + `agents.md` exist for each person; the markdown table lists all five agents with `Майор Пейн` present. Roles/actions are empty (`—`) until Task 6 — that is correct at this point.

---

### Task 6: Author the five agent descriptors

> ## ⚠️ SUPERSEDED — do not execute this task as written
>
> This task predates the a2a protocol normalization. It was written when `a2a_in`
> was **decorative** (registry prose). It is now **enforcement**: `a2a_in` is the
> list the transport gate checks, and an undeclared kind is bounced back to the
> sender.
>
> Three things below are now wrong:
>
> 1. **The source.** Steps 1–2 say to transcribe `a2a_in` from each agent's
>    `team.md` / CLAUDE.md §Команда. The 274-message inventory measured that prose
>    as *wrong* — it is the drift this project exists to remove. `a2a_in` must come
>    from the **measured** inventory
>    (`docs/superpowers/specs/2026-07-16-a2a-message-inventory.md`) and the
>    vocabulary table in
>    `docs/superpowers/specs/2026-07-16-a2a-protocol-normalization-design.md` §4,
>    which maps today's traffic to the kind each route becomes.
> 2. **The worked payne example** omits `set_log` (23 live rows, jarvis→payne) and
>    `ack` (18 rows once the six ack spellings merge). Committing it verbatim
>    bounces payne's two highest-volume structured routes.
> 3. **`"a2a_in": {}` is not a name-only entry.** An explicit empty declaration
>    ARMS the gate text-only — every structured message to that agent bounces. A
>    registry-only entry is one that **omits `a2a_in` entirely** (role and/or `aka`
>    only), which leaves the gate disarmed. See `getLegalKinds` in
>    `src/agent-registry.ts`.
>
> **The authoritative procedure is §5 (“Migration — big-bang code, per-agent
> arming”) of the protocol-normalization design.** It also orders the work: arming
> a descriptor and stripping that agent's hand-written CLAUDE.md contract table are
> one step, followed by a rebirth of all five.
>
> Steps 3–5 below (JSON validation, scp deploy, registry verification) still hold —
> only the descriptor *contents* changed.
>
> Left in place rather than deleted: the mechanics are still the reference.

**Do not invent contracts.** Each agent's real a2a contract is documented — read it first and transcribe.

**Files:**
- Create: `groups/<folder>/agent.json` ×5 (source) → deploy to `agents/<folder>/agent.json` on the VDS

- [ ] **Step 1: Read the authoritative contracts**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && for f in jarvis greg payne gordon scrooge; do echo "=========== $f ==========="; cat agents/$f/memories/team.md 2>/dev/null | head -60; echo "--- CLAUDE.md §Команда ---"; grep -n -A 12 "### Команда" agents/$f/CLAUDE.md 2>/dev/null; done'
```

`agents/<folder>/memories/team.md` holds the full JSON contracts and loop-guards; each `CLAUDE.md` §Команда lists the a2a actions that agent accepts. Use those two as the source of truth for every `a2a_in` entry below.

- [ ] **Step 2: Write the descriptors**

Create one `groups/<folder>/agent.json` per agent. `payne` is filled in from its CLAUDE.md §Команда (`next_workout` on request; accepts `workout_done` / `reschedule`) plus the `health_signal` / `workout_cancel` actions observed in live a2a traffic — verify against `team.md` before committing:

```json
{
  "role": "фитнес-тренер, программа и прогрессия",
  "a2a_in": {
    "next_workout": "запрос плана тренировки на дату",
    "workout_done": "лог завершённой тренировки",
    "reschedule": "перенос тренировки",
    "health_signal": "сигнал здоровья от greg (yellow/red) — смягчить нагрузку",
    "workout_cancel": "отмена тренировки (sick-day)"
  },
  "aka": ["Пейн", "тренер"]
}
```

Write `greg`, `jarvis`, `gordon`, `scrooge` the same way, each with `role` (one line) and `a2a_in` transcribed from that agent's own `team.md` / §Команда. Omit `aka` when there are no real aliases. If an agent genuinely accepts no a2a actions, use `"a2a_in": {}` — a name-only entry is valid.

- [ ] **Step 3: Validate every descriptor is well-formed JSON**

```bash
for f in groups/*/agent.json; do node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" && echo "OK $f"; done
```

Expected: `OK` for each. A parse error here would silently degrade that agent to a name-only entry.

- [ ] **Step 4: Deploy the descriptors**

```bash
for f in jarvis greg payne gordon scrooge; do
  scp groups/$f/agent.json root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/$f/agent.json
done
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && chown nanoclaw:nanoclaw agents/*/agent.json'
```

`groups/` is gitignored — scp is the deploy mechanism, there is nothing to commit.

- [ ] **Step 5: Verify the registry picked them up**

Wait ~60s for a sweep, then:

```bash
ssh root@148.253.211.164 'cat /home/nanoclaw/nanoclaw/data/user-memory/owner/global/agents.md'
```

Expected: every agent now shows a role and its `a2a_in` actions; `payne` shows `Майор Пейн` with `workout_done` etc. Also confirm no warnings:

```bash
ssh root@148.253.211.164 'grep -i "agent-registry" /home/nanoclaw/nanoclaw/logs/nanoclaw.log | tail -5'
```

Expected: no `malformed agent.json` warnings.

---

### Task 7: Point each CLAUDE.md at the registry

**Why:** this is the de-duplication payoff — contracts stop being hand-copied into five files.

**Files:**
- Modify: `groups/<folder>/CLAUDE.md` ×5 (source) → deploy to `agents/<folder>/CLAUDE.md`

- [ ] **Step 1: Confirm source and live CLAUDE.md are in sync before editing**

```bash
for f in jarvis greg payne gordon scrooge; do
  scp root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/$f/CLAUDE.md /tmp/vds-$f-CLAUDE.md
  diff -q /tmp/vds-$f-CLAUDE.md groups/$f/CLAUDE.md && echo "IN SYNC: $f" || echo "DIFFERS: $f — reconcile before editing"
done
```

For any file reported as `DIFFERS`, the VDS copy has drifted (runtime self-edit); reconcile by hand — do **not** blindly overwrite it in Step 3.

- [ ] **Step 2: Edit the §Команда a2a block in each CLAUDE.md**

Replace the hand-copied per-peer contract bullets with a pointer. For `groups/jarvis/CLAUDE.md`, the a2a block currently reads:

```
- **a2a — только срочное:**
  - **`greg`** — принимаешь `finding` `warn/critical` + sick-day → гейтишь владельцу. Recheck-запросы шлёшь ему по требованию.
  - **`payne`** — фитнес-тренер; в чате владельцу всегда называй его **«Пейн»** (он же «Майор Пейн»). `workout_done` приходит **без подписи отправителя** — имя не выдумывай, автор отчёта всегда Пейн (в июле сбивался на «Паулино» — это ошибка). `next_workout(date)` по запросу; принимаешь `workout_done` / `reschedule`.
  - **`scrooge`** — принимаешь критический finance-пинг → гейтишь как health. Запрос сводки (баланс/net worth/траты) делегируешь ему.
```

Replace it with:

```
- **a2a — только срочное:**
  - **Кто есть кто + какие action кто принимает — `/workspace/global/agents.md`** (реестр, генерит хост). Имя отправителя приходит в самом сообщении: `<message sender="Майор Пейн" agent="payne">`. **Имена не выдумывай — бери из `sender=` или из реестра.**
  - **`greg`** — принимаешь `finding` `warn/critical` + sick-day → гейтишь владельцу. Recheck-запросы шлёшь ему по требованию.
  - **`payne`** — `next_workout(date)` по запросу; принимаешь `workout_done` / `reschedule`.
  - **`scrooge`** — принимаешь критический finance-пинг → гейтишь как health. Запрос сводки (баланс/net worth/траты) делегируешь ему.
```

The «Пейн» anchor from the interim patch is removed here — the name now arrives in `sender=` (Task 1) and is listed in the registry (Task 6), so keeping a hand-written name would reintroduce the very duplication this removes. The routing/gating semantics (who gates what) stay in CLAUDE.md; only the *identity + action list* moves to the registry.

Apply the equivalent edit to `greg`, `payne`, `gordon`, `scrooge` — add the same registry-pointer line to their §Команда block and delete any hand-copied peer name/action lists.

- [ ] **Step 3: Deploy and rebirth**

CLAUDE.md is read at container start, and the running session's continuation would otherwise replay the old text.

```bash
for f in jarvis greg payne gordon scrooge; do
  scp groups/$f/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/$f/CLAUDE.md
done
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && chown nanoclaw:nanoclaw agents/*/CLAUDE.md'
```

Then restart each agent so it re-reads CLAUDE.md:

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && for g in jarvis greg payne gordon scrooge; do ./ncl groups restart --id $g; done'
```

- [ ] **Step 4: Verify end to end**

Confirm an agent sees the registry and a stamped sender. After the next real `workout_done` (or by inspecting the next a2a inbound row):

```bash
ssh root@148.253.211.164 'grep -c "Agent message routed" /home/nanoclaw/nanoclaw/logs/nanoclaw.log'
```

Then read the newest a2a inbound row of the target session and confirm the stamp landed:

```bash
ssh root@148.253.211.164 'cat > /tmp/chk.js <<"EOF"
const D = require("/home/nanoclaw/nanoclaw/node_modules/better-sqlite3");
const db = new D(process.argv[2], { readonly: true });
console.log(JSON.stringify(db.prepare("SELECT content FROM messages_in WHERE channel_type=\"agent\" ORDER BY seq DESC LIMIT 3").all(), null, 1));
db.close();
EOF
chmod 644 /tmp/chk.js && /usr/bin/node /tmp/chk.js /home/nanoclaw/nanoclaw/data/v2-sessions/ag-1778740750341-ru9i6e/sess-1780961542852-xnpin3/inbound.db; rm -f /tmp/chk.js'
```

Expected: recent a2a rows contain `"sender":"Майор Пейн","senderId":"payne"`.

**Success criteria for the whole plan:** Jarvis's next relayed workout report names the coach «Пейн»/«Майор Пейн» — because the name arrived in `sender=`, not from recall.

---

## Notes

- **Names come from `agent_groups.name` only.** `greg`/`scrooge`/`jarvis` currently hold English names there ("Greg", "Scrooge", "Jarvis") while chat is Russian. If those should read «Грег»/«Скрудж» in chat, update `agent_groups.name` — one row, one source. That is a data edit, deliberately not part of this plan.
- **`groups/` is gitignored** — group/agent files deploy by scp, never by git. Host and container source under `src/` and `container/` are git-tracked and deploy by `git pull` on the VDS.
- **No image rebuild** anywhere in this plan: `container/agent-runner/src` is host-mounted into the container.
