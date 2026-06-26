# Shared Wiki Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give all 5 agents a uniform two-tier wiki memory — a private `memories/` wiki plus a per-person shared zone (`/workspace/shared/`) that every agent reads and writes via a deliberate publish step.

**Architecture:** One new RW mount (`/workspace/shared`, per-person, no `.writer` gate) holds domain-partitioned conclusion blocks (one soft-owned block per agent) and an append-only `log.md`. The mechanism (ingest+lint → private, publish → shared) lives once in the shared `groups/INSTRUCTIONS.md §Wiki memory`; each agent's `CLAUDE.md` references it and names its block.

**Tech Stack:** Node/TypeScript host (vitest), markdown instruction files, Docker bind mounts. Host code (`src/`) ships by git; agent files (`groups/`) are gitignored and ship by scp + container rebirth.

**Deploy split (read before starting):**
- `src/user-memory.ts`, `src/container-runner.ts`, their tests, this plan, the spec → **git-tracked** (Tasks 1–2 commit; Task 9 pushes + VDS `git pull`).
- `groups/INSTRUCTIONS.md`, `groups/<agent>/CLAUDE.md`, deleted AGENT.md → **gitignored** (Tasks 3–8 edit locally, no commit; Task 9 scp's them + rebirths live sessions).

**Block map:** gordon→`nutrition/`, payne→`training/`, greg→`health/`, scrooge→`finance/`, jarvis→`general/`.

**Agent-group-id gotcha (Task 9):** session dirs key on `agentGroupId` from each `groups/<f>/container.json`. greg/gordon/payne/scrooge: id == folder. **jarvis: id = `ag-1778740750341-ru9i6e`** (folder `jarvis`).

---

## Task 1: Host — `userSharedRoot` + shared-wiki scaffold

**Files:**
- Modify: `src/user-memory.ts`
- Test: `src/user-memory.test.ts`

- [ ] **Step 1: Write the failing tests**

Add to `src/user-memory.test.ts`. First extend the import on line 5:

```ts
import { userMemoryRoot, userGlobalRoot, userSharedRoot, initUserMemory } from './user-memory.js';
```

Then add these three tests inside the `describe('user-memory layout', ...)` block (after the existing `idempotent` test, before its closing `});`):

```ts
  it('userSharedRoot is data/user-memory/<key>/shared', () => {
    expect(userSharedRoot(KEY)).toBe(path.join(DATA_DIR, 'user-memory', KEY, 'shared'));
  });

  it('initUserMemory scaffolds the shared wiki: blocks, README, log', () => {
    initUserMemory(KEY, 'jarvis');
    const shared = userSharedRoot(KEY);
    for (const block of ['nutrition', 'training', 'health', 'finance', 'general']) {
      expect(fs.existsSync(path.join(shared, block))).toBe(true);
    }
    expect(fs.existsSync(path.join(shared, 'README.md'))).toBe(true);
    expect(fs.existsSync(path.join(shared, 'log.md'))).toBe(true);
  });

  it('initUserMemory never clobbers an existing shared log.md', () => {
    initUserMemory(KEY, 'jarvis');
    const log = path.join(userSharedRoot(KEY), 'log.md');
    fs.appendFileSync(log, '## [2026-06-26] greg health | test entry\n');
    initUserMemory(KEY, 'gordon'); // second agent, same person → re-scaffold
    expect(fs.readFileSync(log, 'utf8')).toContain('test entry');
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test -- src/user-memory.test.ts`
Expected: FAIL — `userSharedRoot is not exported` (or `not a function`).

- [ ] **Step 3: Implement `userSharedRoot` + scaffold**

In `src/user-memory.ts`, add `userSharedRoot` right after `userGlobalRoot` (after line 17):

```ts
/** data/user-memory/<personKey>/shared — per-person shared wiki, RW for all agents. */
export function userSharedRoot(personKey: string): string {
  return path.join(DATA_DIR, 'user-memory', personKey, 'shared');
}
```

Add the scaffold constants + helper just above `initUserMemory` (before its doc-comment on line 35):

```ts
const SHARED_WIKI_BLOCKS = ['nutrition', 'training', 'health', 'finance', 'general'] as const;

const SHARED_WIKI_README = `# Общая вики-память

Курированные выводы агентов. Каждый пишет только в свой блок; читают все.
Механизм — INSTRUCTIONS §Wiki memory.

- \`nutrition/\` — питание (Gordon)
- \`training/\` — тренировки (Payne)
- \`health/\` — здоровье (Greg)
- \`finance/\` — финансы (Scrooge)
- \`general/\` — общий контекст о владельце (Jarvis)

\`log.md\` — хронология публикаций (append-only).
`;

const SHARED_WIKI_LOG = `# Журнал публикаций общей вики

<!-- 1 строка на публикацию: ## [YYYY-MM-DD] <agent> <domain> | <что> -->
`;

/**
 * Idempotently scaffold the per-person shared wiki at
 * data/user-memory/<person>/shared/: the five domain block dirs, a static
 * README, and an append-only log.md. README/log are written only when absent —
 * the log accumulates publish history and must never be clobbered.
 */
function scaffoldSharedWiki(personKey: string): void {
  const sharedDir = userSharedRoot(personKey);
  for (const block of SHARED_WIKI_BLOCKS) {
    fs.mkdirSync(path.join(sharedDir, block), { recursive: true });
  }
  const readme = path.join(sharedDir, 'README.md');
  if (!fs.existsSync(readme)) fs.writeFileSync(readme, SHARED_WIKI_README);
  const log = path.join(sharedDir, 'log.md');
  if (!fs.existsSync(log)) fs.writeFileSync(log, SHARED_WIKI_LOG);
}
```

Then call it at the end of `initUserMemory`. Change the existing tail:

```ts
  const globalDir = userGlobalRoot(personKey);
  fs.mkdirSync(path.join(globalDir, 'profiles'), { recursive: true });
}
```

to:

```ts
  const globalDir = userGlobalRoot(personKey);
  fs.mkdirSync(path.join(globalDir, 'profiles'), { recursive: true });

  scaffoldSharedWiki(personKey);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test -- src/user-memory.test.ts`
Expected: PASS (all tests, including the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add src/user-memory.ts src/user-memory.test.ts
git commit -m "feat(memory): per-person shared wiki scaffold (userSharedRoot)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Host — mount `/workspace/shared` RW for every agent

**Files:**
- Modify: `src/container-runner.ts:55` (import), after `src/container-runner.ts:490` (mount)
- Test: `src/container-runner.test.ts`

- [ ] **Step 1: Write the failing test**

In `src/container-runner.test.ts`, add this test inside `describe('buildMounts owner isolation', ...)` (after the existing `'mounts the agent dir (RW) ...'` test):

```ts
  it('mounts the shared wiki RW for every agent, under the owner tree', () => {
    const mounts = mountsFor('isomnt');
    const shared = mounts.find((m) => m.containerPath === '/workspace/shared');
    expect(shared?.hostPath).toBe(path.join(DATA_DIR, 'user-memory', 'isomnt', 'shared'));
    expect(shared?.readonly).toBe(false);
  });
```

Also add shared-dir cleanup to that block's `afterEach` (alongside the existing `global` rmSync):

```ts
    fs.rmSync(path.join(DATA_DIR, 'user-memory', 'isomnt', 'shared'), { recursive: true, force: true });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm test -- src/container-runner.test.ts -t "shared wiki RW"`
Expected: FAIL — `shared` is `undefined` (no such mount).

- [ ] **Step 3: Add the mount**

Extend the `user-memory.js` import on `src/container-runner.ts:55`:

```ts
import { userMemoryRoot, userGlobalRoot, userSharedRoot, initUserMemory } from './user-memory.js';
```

In `buildMounts`, add the shared mount immediately after the existing `/workspace/global` push (after line 490):

```ts
  // Per-person SHARED wiki at /workspace/shared. RW for ALL agents (no .writer
  // gate): domain blocks are soft-owned one-per-agent and the only multi-writer
  // file (log.md) is append-only. Per-person isolation preserved via ownerKey,
  // exactly like /workspace/global above.
  mounts.push({ hostPath: userSharedRoot(ownerKey), containerPath: '/workspace/shared', readonly: false });
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm test -- src/container-runner.test.ts`
Expected: PASS (the new test + all existing `buildMounts owner isolation` tests, including the "never under another person's tree" assertion which the per-person `userSharedRoot(ownerKey)` satisfies).

- [ ] **Step 5: Commit**

```bash
git add src/container-runner.ts src/container-runner.test.ts
git commit -m "feat(memory): mount /workspace/shared RW for all agents

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `INSTRUCTIONS.md §Wiki memory` (the mechanism)

**Files:**
- Modify: `groups/INSTRUCTIONS.md` (gitignored — no commit; deployed in Task 9)

The shared instructions are in **English** (matches `## Memory`, `## Public profiles`). Insert a new `## Wiki memory` section between `## Public profiles` and `## Skills`.

- [ ] **Step 1: Insert the section**

Replace this exact text in `groups/INSTRUCTIONS.md` (end of Public profiles + start of Skills):

```
This is ambient state (refreshed daily, read on demand): "what I am right now." For something that needs an immediate reaction, still use a2a (push), not a fragment.

## Skills
```

with:

```
This is ambient state (refreshed daily, read on demand): "what I am right now." For something that needs an immediate reaction, still use a2a (push), not a fragment.

## Wiki memory

Two knowledge surfaces, one discipline.

**Private wiki** — your own `memories/` (§Memory) plus a `memories/sources/` archive for raw material. Full sources, deep analysis, and drafts live here. Only you read it, so it never clutters another agent's context.

**Shared zone** — `/workspace/shared/`, read-write for every agent. Holds compact, action-oriented conclusions, one block per domain. Read any block; write only your own. Your CLAUDE.md names your block.

Three operations:

**Ingest** (a source → knowledge). Run it in a sub-agent (`Task`) so the long source never enters your main context. The sub-agent reads the source fully, archives raw text to `memories/sources/<name>`, writes deep pages into `memories/`, and updates `memories/index.md`. One source at a time — finish it completely before the next. Stays entirely in your private wiki.

**Lint** (health-check). Also a sub-agent. It checks your **own private** wiki: orphan pages, contradictions between sources, stale claims, missing pages. It never touches the shared zone.

**Publish** (private → shared). A deliberate act you do yourself — the same principle as publishing `public.md` to `profiles/` (§Public profiles). When a private conclusion is worth sharing, distill it to a compact, action-oriented note, write it into your block under `/workspace/shared/<your-domain>/`, and append one line to `/workspace/shared/log.md`:

`## [YYYY-MM-DD] <you> <domain> | <what you published>`

This is the **only** path into the shared zone. Never write raw sources or half-finished notes there; never write another agent's block.

Conventions:
- Each block has its own `index.md`, maintained by that block's owner. There is no shared master index.
- `log.md` is append-only — add your line, never rewrite existing lines.

Sub-agent dispatch for ingest/lint uses an inline prompt — there are no `AGENT.md` files for these:

```
Task({
  description: "wiki ingest",
  prompt: "Read /workspace/agent/INSTRUCTIONS.md §Wiki memory (Ingest) and process this source into the PRIVATE wiki only: <source>",
})
```

## Skills
```

- [ ] **Step 2: Verify the section landed**

Run: `grep -nE '^## Wiki memory|/workspace/shared/log.md|only path into the shared' groups/INSTRUCTIONS.md`
Expected: 3 matching lines.

---

## Task 4: greg `CLAUDE.md` — health block

**Files:**
- Modify: `groups/greg/CLAUDE.md` (gitignored — no commit; deployed in Task 9)

- [ ] **Step 1: Add the shared-wiki line**

Replace this exact paragraph (the first line of `## Память`):

```
Память — `memories/`; механизм (ленивое чтение, индекс, запись) — INSTRUCTIONS §Memory; каталог — `memories/index.md`. Тренды считает `analyze.js` каждый прогон — отдельный дайджест не храним.
```

with:

```
Память — `memories/`; механизм (ленивое чтение, индекс, запись) — INSTRUCTIONS §Memory; каталог — `memories/index.md`. Тренды считает `analyze.js` каждый прогон — отдельный дайджест не храним.

Общая вики — выводы по здоровью публикую в `/workspace/shared/health/` (механизм — INSTRUCTIONS §Wiki memory). Моя зона: `health/`. ingest/lint — только приватная `memories/`.
```

- [ ] **Step 2: Verify**

Run: `grep -n '/workspace/shared/health/' groups/greg/CLAUDE.md`
Expected: 1 match.

---

## Task 5: gordon `CLAUDE.md` — nutrition block

**Files:**
- Modify: `groups/gordon/CLAUDE.md` (gitignored — no commit; deployed in Task 9)

- [ ] **Step 1: Add the shared-wiki line**

Replace this exact paragraph (the first line of `## Память`):

```
Память — `memories/`; механизм (ленивое чтение, индекс, запись) — INSTRUCTIONS §Memory; каталог — `memories/index.md`.
```

with:

```
Память — `memories/`; механизм (ленивое чтение, индекс, запись) — INSTRUCTIONS §Memory; каталог — `memories/index.md`.

Общая вики — выводы по питанию публикую в `/workspace/shared/nutrition/` (механизм — INSTRUCTIONS §Wiki memory). Моя зона: `nutrition/`. ingest/lint — только приватная `memories/`.
```

> Note: gordon's existing line "Общая память о человеке … `/workspace/global/about.md`, read-only" stays — that's the identity baseline, distinct from the shared wiki.

- [ ] **Step 2: Verify**

Run: `grep -n '/workspace/shared/nutrition/' groups/gordon/CLAUDE.md`
Expected: 1 match.

---

## Task 6: payne `CLAUDE.md` — training block

**Files:**
- Modify: `groups/payne/CLAUDE.md` (gitignored — no commit; deployed in Task 9)

- [ ] **Step 1: Add the shared-wiki line**

Replace this exact paragraph (the first line of `## Память`):

```
`memories/` — `profile.md` (профиль бойца), `constraints.md` (травмы и запреты), `muscle_groups.md` (словарь слагов), `retro/YYYY-WW.md` (архив ретроспектив). Каталог — `memories/index.md`.
```

with:

```
`memories/` — `profile.md` (профиль бойца), `constraints.md` (травмы и запреты), `muscle_groups.md` (словарь слагов), `retro/YYYY-WW.md` (архив ретроспектив). Каталог — `memories/index.md`.

Общая вики — выводы по тренировкам публикую в `/workspace/shared/training/` (механизм — INSTRUCTIONS §Wiki memory). Моя зона: `training/`. ingest/lint — только приватная `memories/`.
```

- [ ] **Step 2: Verify**

Run: `grep -n '/workspace/shared/training/' groups/payne/CLAUDE.md`
Expected: 1 match.

---

## Task 7: scrooge `CLAUDE.md` — finance block

**Files:**
- Modify: `groups/scrooge/CLAUDE.md` (gitignored — no commit; deployed in Task 9)

- [ ] **Step 1: Add the shared-wiki line**

Replace this exact paragraph (the first line of `## Память`):

```
Память — `memories/`; механизм — INSTRUCTIONS §Memory; каталог — `memories/index.md`.
```

with:

```
Память — `memories/`; механизм — INSTRUCTIONS §Memory; каталог — `memories/index.md`.

Общая вики — выводы по финансам публикую в `/workspace/shared/finance/` (механизм — INSTRUCTIONS §Wiki memory). Моя зона: `finance/`. ingest/lint — только приватная `memories/`. Суммы/балансы в общее НЕ публикую — только выводы и полосы тренда (балансы всегда из `networth.js`).
```

- [ ] **Step 2: Verify**

Run: `grep -n '/workspace/shared/finance/' groups/scrooge/CLAUDE.md`
Expected: 1 match.

---

## Task 8: jarvis migration — general block + retire bespoke wiki machinery

jarvis already has the full wiki machinery embedded. Migrate it onto the shared mechanism: keep his private CRM structure, move the generic mechanism to INSTRUCTIONS, add the `general/` shared block, and delete the two `AGENT.md` files (now inline-prompt). **Do this last** — it touches a working agent.

**Files:**
- Modify: `groups/jarvis/CLAUDE.md` (gitignored)
- Delete: `groups/jarvis/agents/wiki-ingest/`, `groups/jarvis/agents/wiki-lint/` (gitignored)

- [ ] **Step 1: Add the mechanism reference + general block to `## Память`**

Replace this exact paragraph (the intro line of `## Память`):

```
Память — wiki в `/workspace/agent/memories/`. Живая книга знаний: досье людей, записи встреч, контекст о владельце и его проектах.
```

with:

```
Память — wiki в `/workspace/agent/memories/`. Живая книга знаний: досье людей, записи встреч, контекст о владельце и его проектах.

Механизм wiki (ingest / lint / publish) — INSTRUCTIONS §Wiki memory. Общая вики — кросс-доменные выводы о владельце и жизни публикую в `/workspace/shared/general/`. Моя зона: `general/`. ingest/lint работают только с приватной `memories/`.
```

- [ ] **Step 2: Point the "Источники" line at the central mechanism**

Replace:

```
**Источники** (статья, документ, URL) → делегируешь субагенту `wiki-ingest` (см. §Суб-агенты).
```

with:

```
**Источники** (статья, документ, URL) → ingest через субагент инлайн-промптом (механизм — INSTRUCTIONS §Wiki memory).
```

- [ ] **Step 3: Drop the wiki rows from the §Суб-агенты table**

Replace:

```
| «добавь в вики», «запомни [документ / ссылку]», `/wiki ingest` | `wiki-ingest` |
| `/wiki lint`, «проверь вики» | `wiki-lint` |
| «прогноз серфа», «волны сегодня», «куда катать» | `surf-forecast` |
```

with:

```
| «прогноз серфа», «волны сегодня», «куда катать» | `surf-forecast` |

Wiki ingest/lint — без `AGENT.md`: `Task` с инлайн-промптом «Прочти INSTRUCTIONS §Wiki memory (Ingest / Lint) и …» (см. INSTRUCTIONS §Wiki memory).
```

- [ ] **Step 4: Delete the retired sub-agent files**

```bash
rm -rf groups/jarvis/agents/wiki-ingest groups/jarvis/agents/wiki-lint
```

- [ ] **Step 5: Verify**

Run:
```bash
grep -n '/workspace/shared/general/' groups/jarvis/CLAUDE.md
grep -c 'wiki-ingest\|wiki-lint' groups/jarvis/CLAUDE.md   # expect 0
ls groups/jarvis/agents/ 2>/dev/null                       # expect: only surf-forecast (no wiki-*)
```
Expected: general/ line present; zero `wiki-ingest`/`wiki-lint` references; the two dirs gone.

---

## Task 9: Deploy + verify

Ships host code by git, agent files by scp, then rebirths live sessions so they reload the new instructions.

> VDS: `root@148.253.211.164`, app dir `/home/nanoclaw`, service account `nanoclaw`. Confirm exact paths/service-manager against the `reference_vds_workflow` / `project_jarvis_vds` memories before running — adjust commands if they differ.

- [ ] **Step 1: Full host test + build (local)**

Run: `pnpm test && pnpm run build`
Expected: all tests PASS, build succeeds with no TS errors.

- [ ] **Step 2: Push host code, pull + build + restart on VDS**

```bash
git push origin main
ssh root@148.253.211.164 'cd /home/nanoclaw && sudo -u nanoclaw git pull && sudo -u nanoclaw pnpm run build && systemctl restart nanoclaw'
```
Expected: VDS pulls the two host commits, builds, host restarts. No image rebuild needed (mount logic is host code; nothing in `container/` changed).

- [ ] **Step 3: scp the gitignored agent files to VDS**

```bash
scp groups/INSTRUCTIONS.md      root@148.253.211.164:/home/nanoclaw/groups/INSTRUCTIONS.md
scp groups/greg/CLAUDE.md       root@148.253.211.164:/home/nanoclaw/groups/greg/CLAUDE.md
scp groups/gordon/CLAUDE.md     root@148.253.211.164:/home/nanoclaw/groups/gordon/CLAUDE.md
scp groups/payne/CLAUDE.md      root@148.253.211.164:/home/nanoclaw/groups/payne/CLAUDE.md
scp groups/scrooge/CLAUDE.md    root@148.253.211.164:/home/nanoclaw/groups/scrooge/CLAUDE.md
scp groups/jarvis/CLAUDE.md     root@148.253.211.164:/home/nanoclaw/groups/jarvis/CLAUDE.md
ssh root@148.253.211.164 'rm -rf /home/nanoclaw/groups/jarvis/agents/wiki-ingest /home/nanoclaw/groups/jarvis/agents/wiki-lint && chown -R nanoclaw:nanoclaw /home/nanoclaw/groups'
```
Expected: files land, jarvis wiki sub-agent dirs removed on VDS, ownership restored to `nanoclaw`.

- [ ] **Step 4: Rebirth live sessions so agents reload CLAUDE.md + INSTRUCTIONS**

A running agent keeps its old instructions (SDK resumes via `continuation:*` in `outbound.db`). Wipe continuation across every session of all 5 agents, then kill their containers so they respawn fresh. **Use `agentGroupId` for the session dir — jarvis is the UUID, not `jarvis`.**

To avoid ssh quote-escaping hell, pipe a heredoc to a remote shell (the `'EOF'` is single-quoted, so nothing expands locally):

```bash
ssh root@148.253.211.164 'bash -s' <<'EOF'
cd /home/nanoclaw
for AG in greg gordon payne scrooge ag-1778740750341-ru9i6e; do
  find "data/v2-sessions/$AG" -name outbound.db -print0 2>/dev/null |
  while IFS= read -r -d '' db; do
    sudo -u nanoclaw pnpm exec tsx scripts/q.ts "$db" "DELETE FROM session_state WHERE key LIKE 'continuation:%'"
  done
done
# Kill ALL agent containers (filter by image, so jarvis's UUID-named one is included
# too); each respawns fresh on its next message/wake.
docker ps -q --filter ancestor=nanoclaw-agent:latest | xargs -r docker kill
EOF
```

Expected: continuation rows deleted (`find`, not glob, per the rebirth gotcha); all `nanoclaw-agent:latest` containers killed. Next inbound message to each agent spawns a fresh container that mounts `/workspace/shared`, scaffolds the shared dirs, and reads the new instructions.

> If `scripts/q.ts` only accepts a db **alias** (not a path) in this install, run the `DELETE` via a one-off throwaway agent container instead (see `feedback_agent_instruction_reload` memory) — the SQL and table/key are unchanged.

- [ ] **Step 5: Smoke-check the mount + scaffold on VDS**

Send any agent one message (or wait for a scheduled wake), then:

```bash
ssh root@148.253.211.164 'ls -la /home/nanoclaw/data/user-memory/*/shared/ 2>/dev/null'
```
Expected: a `shared/` tree per person with `nutrition/ training/ health/ finance/ general/`, `README.md`, `log.md`.

- [ ] **Step 6: e2e behavioral verification (manual — Сергей)**

1. **Greg ingest:** send Greg a medical article (URL/PDF). Confirm raw lands in his private `memories/sources/`, deep pages in `memories/`, and the shared zone is still untouched.
2. **Greg publish:** ask Greg to publish a conclusion. Confirm a page appears under `/workspace/shared/health/` and one line is appended to `/workspace/shared/log.md`.
3. **Cross-read:** ask Gordon something that touches Greg's published health conclusion. Confirm Gordon reads `/workspace/shared/health/`, and that Gordon writes only `/workspace/shared/nutrition/`.
4. **Lint scope:** ask Greg to lint. Confirm it reports on his private wiki only and does not modify the shared zone.

---

## Notes for the implementer

- **TDD only applies to Tasks 1–2** (host code). Tasks 3–8 are instruction/markdown edits with grep-based verification — there is nothing to unit-test, and the files are gitignored so they are not committed.
- **Do not** `git add` anything under `groups/` — it is gitignored by design; forcing it in would break the per-person/VDS canonical model.
- **Order:** Tasks 1→2 (host, committed) can land first. Tasks 3→7 are independent of each other. Task 8 (jarvis) goes last. Task 9 deploys everything together — host code and agent files must both be live before rebirth, or agents reload instructions that reference a mount the host isn't yet providing.
- If a step's `old_string` does not match (an agent CLAUDE.md drifted on VDS vs local), Read the section first and re-anchor — the **local** `groups/` copy is the edit surface, then scp overwrites VDS.
