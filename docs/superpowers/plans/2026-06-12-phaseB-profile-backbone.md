# Phase B — Public profile backbone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the shared public-profile system — each agent publishes a short domain summary to its own workspace, the host fans it out to a read-only shared dir every sweep — and prove it end-to-end with one publisher (Greg) and one consumer (Jarvis's morning brief).

**Architecture:** "Write your own, host distributes" — the same pattern as the session DBs. An agent writes `memories/public.md` in its workspace; a host-sweep pass copies each `groups/<folder>/memories/public.md` → `groups/global/profiles/<folder>.md` (hash-gated, ~60s). `groups/global/` is already mounted read-only into every container as `/workspace/global/`, so every agent can read `/workspace/global/profiles/<slug>.md` with no new mount. Greg folds a `public.md` write into its existing 08:30 `daily-cycle` skill; Jarvis's `morning-brief` skill switches its health source from the pushed `self/health.md` to the projected `greg.md`. Both changes live in **skills** (live-mounted, no session rebirth); only the shared INSTRUCTIONS convention and host code are infrastructure.

**Tech Stack:** Node + pnpm host (`src/`, **vitest**), better-sqlite3 unaffected, group files deployed via scp (gitignored), systemd `--user` service on the VDS.

**Spec:** [`docs/superpowers/specs/2026-06-11-shared-profiles-and-bodycomp-design.md`](../specs/2026-06-11-shared-profiles-and-bodycomp-design.md) §B. This plan implements the **backbone + Greg publisher + Jarvis consumer**. Fanning the publisher convention out to Gordon/Payne/Scrooge is deferred to the phases where their fragments gain a reader (see "Not in this phase").

---

## Scope decision (read first)

The spec's §B lists every agent publishing. This plan deliberately ships **only Greg's fragment** plus the full mechanism, because:

- **greg.md has two real consumers now:** Jarvis's morning brief (this plan) and Gordon's recomp verdict (Phase D). It's worth building.
- **gordon.md / payne.md / scrooge.md have no reader yet.** Gordon reads greg.md and payne.md in **Phase D**; finance has no consumer at all. Publishing them now is breadth without use (YAGNI). Each lands with its consumer.
- Smaller blast radius: touches **2** live agents (Greg, Jarvis) via skills only — **zero forced session rebirths**.

If you want every agent publishing immediately, that's a larger plan — flag it, don't silently expand this one.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/public-profiles.ts` | Host-side projection of agent `public.md` → shared `profiles/<slug>.md` | **Create** — pure `projectPublicProfiles(groupsDir)` |
| `src/public-profiles.test.ts` | vitest coverage for projection | **Create** |
| `src/host-sweep.ts` | 60s sweep loop | **Modify** — call `projectPublicProfiles(GROUPS_DIR)` once per tick |
| `groups/global/profiles/index.md` | Catalog of fragments (discovery) | **Create** (scp) |
| `groups/INSTRUCTIONS.md` | Shared agent instructions (imported by all via `@./INSTRUCTIONS.md`) | **Modify** — add `## Public profiles` (scp) |
| `groups/greg/skills/daily-cycle/SKILL.md` | Greg's once-a-day cycle (runs ~08:30) | **Modify** — add a "write public.md" step (scp) |
| `groups/greg/memories/public.md` | Greg's published fragment (seed) | **Create** (scp) |
| `groups/greg/memories/index.md` | Greg's memory catalog | **Modify** — add `public.md` line (scp) |
| `groups/jarvis/skills/morning-brief/SKILL.md` | Jarvis's 09:00 brief | **Modify** — §6 reads `greg.md` instead of `self/health.md` (scp) |

Only `src/*` + the plan doc are git-committed. All `groups/*` files are gitignored and deploy via scp (same as Phases 1-3).

---

### Task 1: Host projection — `projectPublicProfiles` (TDD)

**Files:**
- Create: `src/public-profiles.ts`
- Create: `src/public-profiles.test.ts`
- Modify: `src/host-sweep.ts` (imports + one call inside `sweep()`)

- [ ] **Step 1: Write the failing test**

Create `src/public-profiles.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { projectPublicProfiles } from './public-profiles.js';

let tmp: string;

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'profiles-'));
});
afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

function writePublic(folder: string, body: string): void {
  const dir = path.join(tmp, folder, 'memories');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'public.md'), body);
}

describe('projectPublicProfiles', () => {
  it('projects each group public.md to global/profiles/<folder>.md', () => {
    writePublic('greg', '# greg\nreadiness: 72\n');
    const n = projectPublicProfiles(tmp);
    expect(n).toBe(1);
    expect(
      fs.readFileSync(path.join(tmp, 'global', 'profiles', 'greg.md'), 'utf8'),
    ).toBe('# greg\nreadiness: 72\n');
  });

  it('skips the reserved global folder', () => {
    fs.mkdirSync(path.join(tmp, 'global', 'memories'), { recursive: true });
    fs.writeFileSync(path.join(tmp, 'global', 'memories', 'public.md'), 'nope');
    projectPublicProfiles(tmp);
    expect(fs.existsSync(path.join(tmp, 'global', 'profiles', 'global.md'))).toBe(false);
  });

  it('skips groups with no public.md', () => {
    fs.mkdirSync(path.join(tmp, 'payne', 'memories'), { recursive: true });
    expect(projectPublicProfiles(tmp)).toBe(0);
  });

  it('does not rewrite unchanged content (hash-gated)', () => {
    writePublic('greg', 'same');
    expect(projectPublicProfiles(tmp)).toBe(1);
    expect(projectPublicProfiles(tmp)).toBe(0);
  });

  it('rewrites when content changes', () => {
    writePublic('greg', 'v1');
    projectPublicProfiles(tmp);
    writePublic('greg', 'v2');
    expect(projectPublicProfiles(tmp)).toBe(1);
    expect(
      fs.readFileSync(path.join(tmp, 'global', 'profiles', 'greg.md'), 'utf8'),
    ).toBe('v2');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm exec vitest run src/public-profiles.test.ts`
Expected: FAIL — cannot resolve `./public-profiles.js` (module not created yet).

- [ ] **Step 3: Write minimal implementation**

Create `src/public-profiles.ts`:

```typescript
/**
 * Project each agent group's self-authored public summary
 * (`groups/<folder>/memories/public.md`) into the shared, read-only profiles
 * directory (`groups/global/profiles/<folder>.md`) that every container
 * mounts at `/workspace/global/profiles/`.
 *
 * "Write your own, host distributes" — same pattern as the session DBs. The
 * agent only ever writes its own workspace; the host fans the fragment out so
 * no agent writes another's file and nothing cross-mount-locks. Copy is
 * hash-gated so an unchanged fragment costs one read, not a write, per sweep.
 *
 * Returns the number of fragments (re)written this pass.
 */
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';

import { isValidGroupFolder } from './group-folder.js';
import { log } from './log.js';

function sha(s: string): string {
  return crypto.createHash('sha256').update(s).digest('hex');
}

export function projectPublicProfiles(groupsDir: string): number {
  const profilesDir = path.join(groupsDir, 'global', 'profiles');
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(groupsDir, { withFileTypes: true });
  } catch {
    return 0;
  }

  let written = 0;
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const folder = entry.name;
    // isValidGroupFolder rejects the reserved `global` folder and any
    // non-conforming name, so only real agent groups project.
    if (!isValidGroupFolder(folder)) continue;

    const srcPath = path.join(groupsDir, folder, 'memories', 'public.md');
    let src: string;
    try {
      src = fs.readFileSync(srcPath, 'utf8');
    } catch {
      continue; // agent hasn't published yet
    }

    const destPath = path.join(profilesDir, `${folder}.md`);
    let dest: string | null = null;
    try {
      dest = fs.readFileSync(destPath, 'utf8');
    } catch {
      // dest missing → fall through and write
    }
    if (dest !== null && sha(dest) === sha(src)) continue;

    try {
      fs.mkdirSync(profilesDir, { recursive: true });
      fs.writeFileSync(destPath, src);
      written++;
    } catch (err) {
      log.warn('Failed to project public profile', { folder, err });
    }
  }
  return written;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm exec vitest run src/public-profiles.test.ts`
Expected: PASS — 5 passed.

- [ ] **Step 5: Wire the projection into the sweep**

In `src/host-sweep.ts`, add to the imports near the top (after the existing `import fs from 'fs';`):

```typescript
import { GROUPS_DIR } from './config.js';
import { projectPublicProfiles } from './public-profiles.js';
```

Then, inside `async function sweep()`, add a projection pass at the very start of the function body — before the existing `try { const sessions = ... }` block. Change:

```typescript
async function sweep(): Promise<void> {
  if (!running) return;

  try {
    const sessions = getActiveSessions();
```

to:

```typescript
async function sweep(): Promise<void> {
  if (!running) return;

  // Fan out each agent's public.md → groups/global/profiles/<slug>.md.
  // Own try so a projection failure never skips the session sweep below.
  try {
    const written = projectPublicProfiles(GROUPS_DIR);
    if (written > 0) log.info('Projected public profiles', { written });
  } catch (err) {
    log.error('Public profile projection error', { err });
  }

  try {
    const sessions = getActiveSessions();
```

- [ ] **Step 6: Typecheck + full host test suite**

Run: `pnpm run build` then `pnpm test`
Expected: build clean; vitest suite green (incl. the 5 new projection tests). Pre-existing unrelated failures, if any, are not introduced by this change.

- [ ] **Step 7: Commit**

```bash
git -C /Users/serg/git/nanoclaw add src/public-profiles.ts src/public-profiles.test.ts src/host-sweep.ts
git -C /Users/serg/git/nanoclaw commit -m "feat(host): project agent public.md fragments to shared profiles dir

Host-sweep now fans each groups/<folder>/memories/public.md out to
groups/global/profiles/<folder>.md (hash-gated, ~60s). groups/global is
already mounted read-only into every container, so agents read each other's
domain summaries at /workspace/global/profiles/<slug>.md with no new mount.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Profiles directory + discovery catalog

**Files:**
- Create: `groups/global/profiles/index.md`

The host projects `<slug>.md` files into this dir; the catalog tells agents what each fragment holds and when to read it. Static, hand-authored, scp'd.

- [ ] **Step 1: Create the catalog**

Create `groups/global/profiles/index.md`:

```markdown
# Public profiles — catalog

One short fragment per agent summarizing its domain. Read-only — the host
projects each agent's `memories/public.md` here every ~60s. When a question
touches another agent's area, read the relevant fragment before answering
(continuity reflex), the same way you check your own memory.

- `greg.md` — health: readiness, recovery, body trend, active flags. Read for energy / sleep / recovery / body-composition questions.
- `gordon.md` — nutrition: recomp targets, adherence, goal. Read for food / weight / recomp questions. *(published in Phase D)*
- `payne.md` — training: program, load, training-day yes/no. Read for fitness / fueling questions. *(later)*
- `scrooge.md` — finance, rounded bands only (no exact sums). Read for money / spend questions. *(later)*
```

- [ ] **Step 2: Verify the directory exists for projection**

Run: `ls -la /Users/serg/git/nanoclaw/groups/global/profiles/`
Expected: `index.md` present. (No commit — gitignored; deploys via scp in Task 6.)

---

### Task 3: Shared INSTRUCTIONS — `## Public profiles`

**Files:**
- Modify: `groups/INSTRUCTIONS.md` (add a section after `## Memory`, before `## Skills`)

`INSTRUCTIONS.md` is in English and imported by every agent via `@./INSTRUCTIONS.md` at session birth. The section lands now as the convention; it activates per agent on its next natural rebirth. Phase B function (Greg publish, Jarvis read) is skill-driven and does not depend on it.

- [ ] **Step 1: Insert the section**

In `groups/INSTRUCTIONS.md`, find the end of the `## Memory` section — the line immediately before `## Skills` (currently line 43). Insert this new section between them, so the order becomes `## Memory` → `## Public profiles` → `## Skills`:

```markdown
## Public profiles

Cross-domain state lives in `/workspace/global/profiles/` — one short fragment per agent, each summarizing that agent's own domain. Read-only, mounted like `about-sergei.md`.

Read: when a question touches another agent's domain, check `/workspace/global/profiles/index.md`, then read the relevant `<agent>.md` before answering — the same continuity reflex you apply to your own memory. Don't guess another domain when its fragment exists.

Publish: keep your own summary current in `memories/public.md`. Your CLAUDE.md or a skill says what to put there and when (usually your daily cycle). The host projects it to `/workspace/global/profiles/<you>.md` within ~60s — you never write the shared dir yourself.

This is ambient state (refreshed on a daily cycle, read on demand): "what I am right now." For something that needs an immediate reaction, still use a2a (push), not a fragment.
```

- [ ] **Step 2: Sanity-check the file still reads cleanly**

Run: `grep -n '^## ' /Users/serg/git/nanoclaw/groups/INSTRUCTIONS.md | head -20`
Expected: `## Public profiles` appears between `## Memory` and `## Skills`. (No commit — scp in Task 6.)

---

### Task 4: Greg publishes `greg.md` (daily-cycle skill + seed)

**Files:**
- Modify: `groups/greg/skills/daily-cycle/SKILL.md` (add a publish step before `/clear`)
- Create: `groups/greg/memories/public.md` (seed)
- Modify: `groups/greg/memories/index.md` (add a `public.md` line)

Greg's `daily-cycle` runs once a day ~08:30 Makassar and already has all the data loaded (readiness, recovery, the `line` it sends Jarvis). Folding the fragment write in there means **no new schedule and no rebirth** (skills are live-mounted). The fragment carries an `updated:` date so Jarvis's brief can apply the same staleness logic it uses today.

- [ ] **Step 1: Add the publish step to `daily-cycle`**

In `groups/greg/skills/daily-cycle/SKILL.md`, the working cycle currently ends:

```markdown
8. Заверши прогон командой `/clear` (ты stateless — вся память в `state.md`, не в транскрипте).
```

Replace that single line with a new step 8 (publish) + renumbered step 9 (`/clear`):

```markdown
8. **Публичная сводка (фрагмент `greg.md`) — ОБЯЗАТЕЛЬНО каждый прогон.** Перепиши `memories/public.md` короткой сводкой для других агентов (хост раздаёт её в `/workspace/global/profiles/greg.md`; механизм — INSTRUCTIONS §Public profiles). Данные уже на руках из шагов 1-2 — не считай заново. Формат (фиксированные заголовки, простой русский — жаргон разворачивай как в §Манера):

   ```
   ---
   updated: <дата последнего РЕАЛЬНОГО дня из анализа, YYYY-MM-DD — та же, что в health_trend шага 6>
   ---
   # Greg — здоровье

   готовность: <readiness 0-100> (<green|yellow|red>)
   восстановление: <↑ / ↓ / ровно, одно-два слова>
   тренд: <та же одна строка `line`, что ушла Джарвису в шаге 6>
   флаги: <активные аномалии из state.md через запятую, или «—»>
   ```

   `updated` — дата ДАННЫХ, не дата прогона (та же дисциплина, что у дневного тренда). Пиши молча: это файл для агентов, Сергею ничего не шли.
9. Заверши прогон командой `/clear` (ты stateless — вся память в `state.md`, не в транскрипте).
```

Also update the skill's frontmatter `description:` — append `; пишет публичную сводку в memories/public.md (раздаётся хостом в profiles/greg.md)` to the end of the existing description string, so the catalog stays accurate.

- [ ] **Step 2: Seed `greg/memories/public.md`**

Create `groups/greg/memories/public.md` with a deliberately stale `updated:` so Jarvis's brief skips it until Greg's first real cycle overwrites it (the brief skips fragments older than 2 days — see Task 5):

```markdown
---
updated: 2026-06-01
---
# Greg — здоровье

готовность: —
восстановление: —
тренд: (ещё не сформирован — обновится на ближайшем daily-cycle)
флаги: —
```

- [ ] **Step 3: Add the catalog line to Greg's memory index**

Read `groups/greg/memories/index.md` to match its existing line format, then add one entry for `public.md` in the same style, e.g.:

```markdown
- `public.md` — публичная сводка здоровья для других агентов (readiness/recovery/тренд/флаги); пишется в daily-cycle, хост раздаёт в `/workspace/global/profiles/greg.md`.
```

- [ ] **Step 4: Verify files are well-formed**

Run: `head -20 /Users/serg/git/nanoclaw/groups/greg/memories/public.md && grep -n 'Публичная сводка' /Users/serg/git/nanoclaw/groups/greg/skills/daily-cycle/SKILL.md`
Expected: seed fragment prints with `updated: 2026-06-01`; the publish step is present in the skill. (No commit — scp in Task 6.)

---

### Task 5: Jarvis morning-brief reads `greg.md`

**Files:**
- Modify: `groups/jarvis/skills/morning-brief/SKILL.md` (§6 Health trend — source switch + fallback)

The brief currently reads `memories/self/health.md`, which Greg keeps fresh via a `health_trend` a2a push. Switch the source to the projected fragment `/workspace/global/profiles/greg.md`, preserving the existing `updated:`-date staleness logic (that logic fixed a real "yesterday shown as today" bug — keep it). Keep a fallback to `self/health.md` during the transition. Greg's a2a push stays (harmless dup; removed later per spec §E).

- [ ] **Step 1: Rewrite §6**

In `groups/jarvis/skills/morning-brief/SKILL.md`, replace the entire `### 6. Health trend` block (currently lines 68–74, from the `### 6. Health trend` heading through the line ending `...причина бага «бриф показывает вчерашние данные как сегодняшние».`) with:

```markdown
### 6. Health trend
Read `/workspace/global/profiles/greg.md` (Greg publishes it on his morning daily-cycle; the host projects it here within ~60s). Take the `updated:` front-matter date **и** строку `тренд:`. **`updated` = дата РЕАЛЬНЫХ данных (последний день в выгрузке с телефона), а не дата прогона.** Датируй строку по `updated`, не предполагай «сегодня»:
- `updated` == сегодня → подавай как сегодняшнее: `Здоровье: <тренд>`.
- `updated` == вчера → ночные данные ещё не синкнулись к моменту брифа. Подай честно, с датой, НЕ как сегодняшнее: `Здоровье (за <DD месяца>): <тренд>. Ночь ещё не синхронизировалась.`
- `updated` старше 2 дней, либо файл пуст/отсутствует → skip: дневной цикл Грега застрял, старое за сегодня не выдавай.

Никогда не печатай строку здоровья без привязки к её дате — это была причина бага «бриф показывает вчерашние данные как сегодняшние».

**Fallback (переходный):** если `/workspace/global/profiles/greg.md` отсутствует (проекция ещё не поднялась), прочитай по тем же правилам legacy-файл `memories/self/health.md` (его Грег пишет через `health_trend` a2a). Убрать fallback, когда фрагменты подтверждённо текут.
```

- [ ] **Step 2: Verify**

Run: `grep -n 'profiles/greg.md\|Fallback' /Users/serg/git/nanoclaw/groups/jarvis/skills/morning-brief/SKILL.md`
Expected: §6 now references `/workspace/global/profiles/greg.md` and the fallback line is present. (No commit — scp in Task 6.)

---

### Task 6: Deploy to VDS + verify end-to-end

**Files:** none (deploy + verification)

VDS: `root@148.253.211.164`, service user `nanoclaw`, repo `/home/nanoclaw/nanoclaw`, systemd `--user` unit `nanoclaw`. Host code (Task 1) deploys via git pull + build + restart. Group files (Tasks 2-5) deploy via scp + chown. **No forced session rebirths** — Greg's publish and Jarvis's read are in live-mounted skills; the INSTRUCTIONS convention activates on each agent's next natural rebirth.

- [ ] **Step 1: Push host code**

```bash
git -C /Users/serg/git/nanoclaw push origin main
```
Expected: Task 1 commit (+ this plan doc, if committed) on `origin/main`.

- [ ] **Step 2: VDS — pull + build + restart (projection goes live)**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && git pull --ff-only origin main && pnpm run build"'
ssh root@148.253.211.164 'sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw && sleep 3 && sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user is-active nanoclaw'
```
Expected: build clean; `is-active` prints `active`. The sweep now runs `projectPublicProfiles` every 60s. No agent image rebuild needed — host-only change.

- [ ] **Step 3: scp the group files + fix ownership**

```bash
cd /Users/serg/git/nanoclaw
scp groups/INSTRUCTIONS.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md
scp -r groups/global/profiles root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/global/
scp groups/greg/skills/daily-cycle/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/skills/daily-cycle/SKILL.md
scp groups/greg/memories/public.md groups/greg/memories/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/memories/
scp groups/jarvis/skills/morning-brief/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/skills/morning-brief/SKILL.md
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/global /home/nanoclaw/nanoclaw/groups/greg /home/nanoclaw/nanoclaw/groups/jarvis/skills/morning-brief /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md'
```
Expected: all copies succeed; ownership is `nanoclaw:nanoclaw`.

- [ ] **Step 4: Verify projection runs (deterministic, within ~60s)**

The seeded `greg/memories/public.md` is now on the VDS. Wait one sweep, then confirm the host projected it:

```bash
ssh root@148.253.211.164 'sleep 65; ls -la /home/nanoclaw/nanoclaw/groups/global/profiles/ && echo "--- greg.md ---" && cat /home/nanoclaw/nanoclaw/groups/global/profiles/greg.md'
```
Expected: `greg.md` exists in `profiles/` and its content matches the seeded fragment (`updated: 2026-06-01`, the Greg health headings). If absent, check `logs/nanoclaw.error.log` for "Public profile projection error".

- [ ] **Step 5: Verify a container reads it at the mounted path**

Confirm the fragment is visible where agents actually read it (`/workspace/global/profiles/`), via a throwaway container mounting `groups/global` read-only exactly as the host does:

```bash
ssh root@148.253.211.164 'docker run --rm -v /home/nanoclaw/nanoclaw/groups/global:/workspace/global:ro --entrypoint sh nanoclaw-agent-v2-16111809:latest -c "cat /workspace/global/profiles/greg.md && echo OK-READABLE"'
```
Expected: the fragment prints followed by `OK-READABLE`. (Image tag is the current agent image — confirm with `docker images | grep nanoclaw-agent` if it has changed.)

- [ ] **Step 6: (Optional) Confirm Greg's publish step end-to-end**

Greg overwrites the seed with real data on its next 08:30 cycle. To confirm sooner without waiting, wake Greg to run the cycle once (send its session a `daily-cycle` trigger the way the recurring task does — e.g. via the app or `ncl`), then re-run Step 4 and confirm `greg.md` now shows today's `updated:` and a real `тренд:` line. If you don't trigger it, it self-confirms at the next 08:30 run.

- [ ] **Step 7: Update project memory**

Update `/Users/serg/.claude/projects/-Users-serg-git-nanoclaw/memory/project_gordon_agent.md`: mark Phase B (profile backbone) shipped — host projection live, Greg publishes greg.md, Jarvis brief reads it; note the "skills are live-mounted, only CLAUDE.md needs rebirth" deploy fact and that Gordon/Payne/Scrooge publishing is deferred to their consumer phases.

---

## Done criteria

- `pnpm test` green incl. the 5 `projectPublicProfiles` cases; `pnpm run build` clean.
- Host commit on `origin/main`; VDS pulled, built, service `active`.
- `groups/global/profiles/greg.md` exists on the VDS and is readable inside a container at `/workspace/global/profiles/greg.md`.
- Jarvis's morning-brief §6 sources health from the fragment (with the date-staleness logic intact and a transitional fallback).
- Zero agent sessions forcibly rebirthed; no agent image rebuilt.

## Not in this phase (separate plans / later phases)

- **Gordon/Payne/Scrooge publishing** (`public.md` + CLAUDE.md §publish + ~08:30 schedule). Each lands with its first reader: **gordon.md** in **Phase D** (Gordon integration), **payne.md** in Phase D (Gordon's training-day input) or when the brief grows a training line, **scrooge.md** when a finance consumer exists.
- **C** — body-comp data (iOS `bodyMass`/`height`/`bodyFatPercentage`/`leanBodyMass` → Greg trend; greg.md gains a body-trend line). iOS rebuild.
- **D** — Gordon reads `greg.md` for the recomp verdict, intake pulls weight/height (needs Phase A + C), publishes `gordon.md`.
- **E** — retire the now-redundant `health_trend → self/health.md` a2a push once fragments are confirmed flowing (then drop the morning-brief fallback).
