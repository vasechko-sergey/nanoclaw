# Phase B — Public profile backbone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the shared public-profile system — each analyst agent publishes a short domain summary to its own workspace, the host fans it out to a read-only shared dir every sweep — and roll it out **uniformly to all four analyst agents (Greg, Gordon/Ramzi, Payne, Scrooge)**, with Jarvis's morning brief as the first consumer.

**Architecture:** "Write your own, host distributes" — same pattern as the session DBs. Each agent gets an identical `publish` skill that runs its own analysis script and writes `memories/public.md`; a host-sweep pass (Task 1, already done) copies each `groups/<folder>/memories/public.md` → `groups/global/profiles/<folder>.md` (hash-gated, ~60s). `groups/global/` is already mounted read-only into every container as `/workspace/global/`, so every agent reads `/workspace/global/profiles/<slug>.md` with no new mount. Each agent's publish runs on a **recurring 08:45 Asia/Makassar task** — a `messages_in` row with `kind='task'` (the same primitive `schedule_task` uses), injected directly per agent. The publish logic lives in a **live-mounted skill** named by the task prompt, so **no agent CLAUDE.md changes and no forced session rebirths**.

**Tech Stack:** Node + pnpm host (`src/`, vitest), Bun agent scripts (live-mounted), group files via scp (gitignored), scheduled tasks via `insertTask` (`src/modules/scheduling/db.ts`), systemd `--user` on the VDS.

**Spec:** [`docs/superpowers/specs/2026-06-11-shared-profiles-and-bodycomp-design.md`](../specs/2026-06-11-shared-profiles-and-bodycomp-design.md) §B. Scope: **all four analyst agents publish** (per the operator's directive); Jarvis is consumer-only (assembler — no fragment). Body-comp data (C), Gordon's recomp-verdict reads (D) follow in their phases.

---

## Key mechanism facts (verified)

- **Scheduled tasks are `messages_in` rows**, `kind='task'`, `content = JSON.stringify({prompt, script})`, optional `recurrence` (cron, interpreted in `config.TIMEZONE` = `Asia/Makassar`), `process_after` (ISO). `insertTask(inDb, {...})` in `src/modules/scheduling/db.ts`. `handleRecurrence` (host-sweep) re-fans the series after each completion.
- **A due task wakes the container** (host-sweep step 2). So injecting a recurring task with `processAfter = now` runs publish **immediately** (bootstrap) and then every 08:45.
- **Skills are live-mounted** (`/workspace/agent/skills/`, loaded via the Skill tool); **only CLAUDE.md is read at session birth.** Keeping publish in a skill + naming it in the task prompt ⇒ no CLAUDE.md edit, no rebirth.
- `groups/global/` is RW only for the `.writer` (Jarvis), RO for everyone — but the **host** writes `profiles/*.md` directly (Task 1), unaffected by the container mount mode.

---

## Uniform fragment format

Every agent writes `memories/public.md` in this shape (fixed headings, plain Russian, jargon expanded):

```
---
updated: <YYYY-MM-DD — date of the underlying data, not the run date>
---
# <Имя> — <домен>

<field>: <value>
<field>: <value>
```

Per-agent fields are defined in each publish skill (Tasks 4-7).

---

## File Structure

| File | Change |
|------|--------|
| `src/public-profiles.ts`, `src/public-profiles.test.ts`, `src/host-sweep.ts` | **Done (Task 1, commit `5a8c3a5`)** — host projection |
| `groups/global/profiles/index.md` | Create — catalog (Task 2) |
| `groups/INSTRUCTIONS.md` | Add `## Public profiles` (Task 3) |
| `groups/{greg,gordon,payne,scrooge}/skills/publish/SKILL.md` | Create — uniform publish skill (Tasks 4-7) |
| `groups/{greg,gordon,payne,scrooge}/skills/index.md` | Add `publish` line (Tasks 4-7) |
| `groups/{greg,gordon,payne,scrooge}/memories/public.md` | Create — seed (Tasks 4-7) |
| `groups/{greg,gordon,payne,scrooge}/memories/index.md` | Add `public.md` line (Tasks 4-7) |
| `groups/jarvis/skills/morning-brief/SKILL.md` | §6 reads `greg.md` (Task 8) |

Only `src/*` + the plan doc are git-committed. All `groups/*` are gitignored → scp. **No CLAUDE.md edits anywhere.**

---

### Task 1 — Host projection ✅ DONE

`projectPublicProfiles(GROUPS_DIR)` wired into `sweep()`, hash-gated, atomic write-then-rename, 5 vitest cases. Commit `5a8c3a5` (spec ✅ + quality ✅).

---

### Task 2 — Profiles directory + discovery catalog

**Create:** `groups/global/profiles/index.md`

```markdown
# Public profiles — catalog

One short fragment per agent summarizing its domain. Read-only — the host
projects each agent's `memories/public.md` here every ~60s. When a question
touches another agent's area, read the relevant fragment before answering
(continuity reflex), the same way you check your own memory.

- `greg.md` — health: readiness, recovery, body trend, active flags. Read for energy / sleep / recovery / body-composition questions.
- `gordon.md` — nutrition: recomp targets, adherence, goal. Read for food / weight / recomp questions.
- `payne.md` — training: program, last/next workout, training-day yes/no. Read for fitness / fueling questions.
- `scrooge.md` — finance, rounded bands only (no exact sums). Read for money / spend questions.
```

Verify: `ls groups/global/profiles/index.md`. (scp in Task 9.)

---

### Task 3 — Shared INSTRUCTIONS `## Public profiles`

**Modify:** `groups/INSTRUCTIONS.md` — insert between `## Memory` (ends line 42) and `## Skills` (line 43):

```markdown
## Public profiles

Cross-domain state lives in `/workspace/global/profiles/` — one short fragment per agent, each summarizing that agent's own domain. Read-only, mounted like `about-sergei.md`.

Read: when a question touches another agent's domain, check `/workspace/global/profiles/index.md`, then read the relevant `<agent>.md` before answering — the same continuity reflex you apply to your own memory. Don't guess another domain when its fragment exists.

Publish: keep your own summary current in `memories/public.md`. A `publish` skill (run by your morning ~08:45 task) writes it. The host projects it to `/workspace/global/profiles/<you>.md` within ~60s — you never write the shared dir yourself.

This is ambient state (refreshed daily, read on demand): "what I am right now." For something that needs an immediate reaction, still use a2a (push), not a fragment.
```

Verify: `grep -n '^## ' groups/INSTRUCTIONS.md` shows `## Public profiles` between Memory and Skills. (scp in Task 9.)

---

### Task 4 — Greg `publish` skill + files

**Create:** `groups/greg/skills/publish/SKILL.md`

```markdown
---
name: publish
description: Use on the scheduled morning publish wake (~08:45) to refresh the public health summary. Runs analyze.js, writes memories/public.md (host projects it to /workspace/global/profiles/greg.md). Terminal, silent — no chat output.
---

# Publish — публичная сводка здоровья

Раз в день (утренний таск ~08:45). Короткая публичная сводка для других агентов. Никому ничего не отправляешь — только пишешь файл.

## Шаги
1. `bun /workspace/agent/scripts/analyze.js --out /tmp/anomalies.json`
2. Прочти `/tmp/anomalies.json`: `readiness.score`, `readiness.band` (`green`/`yellow`/`red`), `latest.recovery`, `latest_line`, `generated_at` (дата последнего РЕАЛЬНОГО дня). Активные флаги — аномалии из `anomalies[]` (`metric`+`direction`) и/или раздел «Уже доложено» в `memories/state.md`.
3. Перепиши `memories/public.md` РОВНО так (простой русский, меджаргон разворачивай):

   ```
   ---
   updated: <generated_at, YYYY-MM-DD>
   ---
   # Greg — здоровье

   готовность: <score>/100 (<зелёный|жёлтый|красный>)
   восстановление: <↑ хорошее | ↓ просело | ровно>
   тренд: <latest_line дословно>
   флаги: <активные аномалии человеческим языком через «; », или «—»>
   ```

4. Всё. Не шли сообщений, не буди никого.

## Дисциплина
- `updated` — дата ДАННЫХ (`generated_at`), не «сегодня».
- Никогда не читай `raw.jsonl` в контекст — только через `analyze.js`.
- Файл для агентов, не для Сергея — тон нейтральный, без House-яда.
```

**Create:** `groups/greg/memories/public.md`

```markdown
---
updated: 2026-06-01
---
# Greg — здоровье

готовность: —
восстановление: —
тренд: (сводка появится на ближайшем утреннем прогоне ~08:45)
флаги: —
```

**Modify:** `groups/greg/skills/index.md` — add a row in the existing table format:

```markdown
| `publish` | Утренний таск (~08:45): `analyze.js` → `memories/public.md` (публичная сводка здоровья для агентов). Терминально, молча. |
```

**Modify:** `groups/greg/memories/index.md` — add (match its `- name: desc | tags` format):

```markdown
- public.md: публичная сводка здоровья для агентов (готовность/восстановление/тренд/флаги); пишется publish-скилом, хост раздаёт в /workspace/global/profiles/greg.md | public,profile
```

(scp in Task 9.)

---

### Task 5 — Gordon (Ramzi) `publish` skill + files

**Create:** `groups/gordon/skills/publish/SKILL.md`

```markdown
---
name: publish
description: Use on the scheduled morning publish wake (~08:45) to refresh the public nutrition summary. Runs targets.js + daily-rollup.js, writes memories/public.md (host projects it to /workspace/global/profiles/gordon.md). Terminal, silent.
---

# Publish — публичная сводка питания

Раз в день (~08:45). Короткая публичная сводка для агентов. Ничего не отправляешь.

## Шаги
1. `bun /workspace/agent/scripts/targets.js` → `kcal`, `protein_g`.
2. `bun /workspace/agent/scripts/daily-rollup.js --date $(date +%Y-%m-%d)` → `vs_target.kcal_pct`, `protein_hit`, `date`. Если за сегодня приёмов ещё нет — возьми вчера (`--date <вчера>`).
3. Перепиши `memories/public.md`:

   ```
   ---
   updated: <date из rollup>
   ---
   # Гордон (Рамзи) — питание

   цель: рекомпозиция
   таргеты: <kcal> ккал · белок <protein_g> г
   последний день: <kcal_pct>% калорий, белок <«добор» если protein_hit, иначе «недобор»>
   ```

4. Всё. Молча.

## Дисциплина
- Не читай `meals.db` в контекст — только скрипты.
- Файл для агентов — без Рамзи-огня, нейтрально.
```

**Create:** `groups/gordon/memories/public.md`

```markdown
---
updated: 2026-06-01
---
# Гордон (Рамзи) — питание

цель: рекомпозиция
таргеты: (появятся на ближайшем утреннем прогоне ~08:45)
последний день: —
```

**Modify:** `groups/gordon/skills/index.md` — add (Gordon uses a flat bullet list):

```markdown
- `publish` — утренний таск (~08:45): targets+rollup → `memories/public.md` (публичная сводка питания). Молча.
```

**Modify:** `groups/gordon/memories/index.md` — add (Gordon's `- \`name\` — desc` format):

```markdown
- `public.md` — публичная сводка питания для агентов (цель/таргеты/адерентность); publish-скил → /workspace/global/profiles/gordon.md.
```

(scp in Task 9.)

---

### Task 6 — Payne `publish` skill + files

**Create:** `groups/payne/skills/publish/SKILL.md`

```markdown
---
name: publish
description: Use on the scheduled morning publish wake (~08:45) to refresh the public training summary. Reads programs/current.json + sessions/, writes memories/public.md (host projects it to /workspace/global/profiles/payne.md). Terminal, silent.
---

# Publish — публичная сводка тренировок

Раз в день (~08:45). Короткая публичная сводка для агентов. Ничего не отправляешь.

## Шаги
1. Прочти `programs/current.json`: `name`, `current_week`, `total_weeks`, `weekly_intensity_pattern[current_week-1].label`, `split` (массив дней), `next_day_index`.
2. Последняя тренировка: самый свежий файл в `sessions/` по дате в имени → его `date` и `day` (тип дня).
3. Трен-день сегодня: есть ли `sessions/<сегодня>*.json`? Да → тренировка сегодня была/идёт. Нет → следующая по плану = `split[next_day_index % split.length]`.
4. Перепиши `memories/public.md`:

   ```
   ---
   updated: <сегодня, YYYY-MM-DD>
   ---
   # Пейн — тренировки

   программа: <name>, неделя <current_week>/<total_weeks> (<intensity label>)
   последняя: <date> <тип дня>
   следующая: <тип следующего дня из split>
   трен-день сегодня: <да | нет>
   ```

5. Всё. Молча. (Недельный тоннаж — позже: у `volume-report.js` нет CLI.)

## Дисциплина
- Файл для агентов — без Пейн-крика, нейтрально.
```

**Create:** `groups/payne/memories/public.md`

```markdown
---
updated: 2026-06-01
---
# Пейн — тренировки

программа: (появится на ближайшем утреннем прогоне ~08:45)
последняя: —
следующая: —
трен-день сегодня: —
```

**Modify:** `groups/payne/skills/index.md` — add (Payne uses a table):

```markdown
| `publish` | Утренний таск (~08:45): программа+сессии → `memories/public.md` (публичная сводка тренировок). Терминально, молча. |
```

**Modify:** `groups/payne/memories/index.md` — add (Payne's `- name: desc | tags` format):

```markdown
- public.md: публичная сводка тренировок для агентов (программа/последняя/следующая/трен-день); publish-скил → /workspace/global/profiles/payne.md | public,profile
```

(scp in Task 9.)

---

### Task 7 — Scrooge `publish` skill + files

**Create:** `groups/scrooge/skills/publish/SKILL.md`

```markdown
---
name: publish
description: Use on the scheduled morning publish wake (~08:45) to refresh the public finance summary. Runs analyze.js, writes memories/public.md (host projects it to /workspace/global/profiles/scrooge.md) — ROUNDED BANDS ONLY, never exact sums. Terminal, silent.
---

# Publish — публичная сводка финансов (огрублённо)

Раз в день (~08:45). Короткая публичная сводка для агентов. Ничего не отправляешь.

## ⚠️ ЖЁСТКО: только огрублённые полосы. НИКОГДА не пиши точные суммы (`*_usd`, балансы, денежные дельты). Только полосы и направления.

## Шаги
1. `bun /workspace/agent/scripts/analyze.js --out /tmp/findings.json`
2. Прочти `/tmp/findings.json`: `capital.runway_liquid_months` (число), `spend_delta_pct` (число, %), `capital.income_covers_burn` (bool), `capital.asof` (дата). **НЕ** читай `*_usd`/`*.total` поля в сводку.
3. Огрубление:
   - запас: `runway_liquid_months` → `<3` → «меньше 3 мес»; 3–6 → «3–6 мес»; 6–12 → «6–12 мес»; `>12` → «больше года».
   - траты (30 дней): `spend_delta_pct` → `> +5` «растут (~<pct>%)»; `< −5` «падают (~<pct>%)»; иначе «ровно».
   - доход покрывает: `income_covers_burn` → «да» / «нет».
4. Перепиши `memories/public.md`:

   ```
   ---
   updated: <asof, YYYY-MM-DD>
   ---
   # Скрудж — финансы (огрублённо)

   запас: <полоса>
   траты (30 дней): <направление>
   доход покрывает траты: <да | нет>
   ```

5. Всё. Молча.

## Дисциплина
- Точные суммы — НИКОГДА. Сомневаешься — публикуй полосу шире.
- Файл для агентов.
```

**Create:** `groups/scrooge/memories/public.md`

```markdown
---
updated: 2026-06-01
---
# Скрудж — финансы (огрублённо)

запас: (появится на ближайшем утреннем прогоне ~08:45)
траты (30 дней): —
доход покрывает траты: —
```

**Modify:** `groups/scrooge/skills/index.md` — add (Scrooge uses a table):

```markdown
| `publish` | Утренний таск (~08:45): `analyze.js` → `memories/public.md` (огрублённая финсводка для агентов; только полосы, без сумм). Терминально, молча. |
```

**Modify:** `groups/scrooge/memories/index.md` — add (Scrooge's `- name: desc | tags` format):

```markdown
- public.md: публичная огрублённая финсводка для агентов (запас/тренд трат) — только полосы, без сумм; publish-скил → /workspace/global/profiles/scrooge.md | public,profile
```

(scp in Task 9.)

---

### Task 8 — Jarvis morning-brief reads `greg.md`

**Modify:** `groups/jarvis/skills/morning-brief/SKILL.md` — replace the entire `### 6. Health trend` block (lines 68–74) with:

```markdown
### 6. Health trend
Read `/workspace/global/profiles/greg.md` (Greg publishes it on his ~08:45 task; the host projects it here within ~60s). Take the `updated:` front-matter date **и** строку `тренд:`. **`updated` = дата РЕАЛЬНЫХ данных (последний день в выгрузке), а не дата прогона.** Датируй по `updated`, не предполагай «сегодня»:
- `updated` == сегодня → `Здоровье: <тренд>`.
- `updated` == вчера → ночные данные ещё не синкнулись. Честно, с датой, НЕ как сегодняшнее: `Здоровье (за <DD месяца>): <тренд>. Ночь ещё не синхронизировалась.`
- `updated` старше 2 дней, либо файл пуст/отсутствует → skip: публикация Грега застряла, старое за сегодня не выдавай.

Никогда не печатай строку здоровья без привязки к её дате — это была причина бага «бриф показывает вчерашние данные как сегодняшние».

**Fallback (переходный):** если `/workspace/global/profiles/greg.md` отсутствует, прочитай по тем же правилам legacy `memories/self/health.md` (его Грег пишет через `health_trend` a2a). Убрать, когда фрагменты подтверждённо текут.
```

Verify: `grep -n 'profiles/greg.md\|Fallback' groups/jarvis/skills/morning-brief/SKILL.md`. (scp in Task 9.)

---

### Task 9 — Deploy to VDS + bootstrap publish tasks + verify

VDS: `root@148.253.211.164`, user `nanoclaw`, repo `/home/nanoclaw/nanoclaw`, systemd `--user` unit `nanoclaw`. Host code via git pull+build+restart; group files via scp; recurring publish tasks injected directly. **No image rebuild, no session rebirths.**

- [ ] **Step 1 — Push host code**

```bash
git -C /Users/serg/git/nanoclaw push origin main
```

- [ ] **Step 2 — VDS pull + build + restart (projection live)**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && git pull --ff-only origin main && pnpm run build"'
ssh root@148.253.211.164 'sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw && sleep 3 && sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user is-active nanoclaw'
```
Expected: build clean; `active`.

- [ ] **Step 3 — scp group files + chown**

```bash
cd /Users/serg/git/nanoclaw
scp groups/INSTRUCTIONS.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md
scp -r groups/global/profiles root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/global/
for a in greg gordon payne scrooge; do
  scp -r groups/$a/skills/publish root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/$a/skills/
  scp groups/$a/skills/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/$a/skills/index.md
  scp groups/$a/memories/public.md groups/$a/memories/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/$a/memories/
done
scp groups/jarvis/skills/morning-brief/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/skills/morning-brief/SKILL.md
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups'
```

- [ ] **Step 4 — Inject the recurring publish tasks (bootstrap)**

Write a tsx heredoc on the VDS that injects, per agent, a recurring `kind='task'` row that runs publish now (`processAfter=now`) and every 08:45 (`recurrence='45 8 * * *'`, interpreted in `TIMEZONE=Asia/Makassar`):

```bash
ssh root@148.253.211.164 'cat > /tmp/bootstrap-publish.ts <<'"'"'EOF'"'"'
import { initDb } from "/home/nanoclaw/nanoclaw/src/db/connection.js";
import { getActiveSessions } from "/home/nanoclaw/nanoclaw/src/db/sessions.js";
import { openInboundDb } from "/home/nanoclaw/nanoclaw/src/session-manager.js";
import { insertTask } from "/home/nanoclaw/nanoclaw/src/modules/scheduling/db.js";
initDb("/home/nanoclaw/nanoclaw/data/v2.db");
const now = new Date().toISOString();
const sessions = getActiveSessions();
for (const ag of ["greg","gordon","payne","scrooge"]) {
  const s = sessions.find((x) => x.agent_group_id === ag);
  if (!s) { console.log("NO SESSION", ag); continue; }
  const db = openInboundDb(ag, s.id);
  insertTask(db, {
    id: `task-publish-${ag}`,
    processAfter: now,
    recurrence: "45 8 * * *",
    platformId: null, channelType: null, threadId: null,
    content: JSON.stringify({ prompt: "Load the `publish` skill and run it now — write memories/public.md. Terminal: no chat output, do not message anyone.", script: null }),
  });
  db.close();
  console.log("SCHEDULED", ag, s.id);
}
EOF
chown nanoclaw:nanoclaw /tmp/bootstrap-publish.ts
sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && pnpm -s exec tsx /tmp/bootstrap-publish.ts"
rm -f /tmp/bootstrap-publish.ts'
```
Expected: `SCHEDULED greg …`, `SCHEDULED gordon …`, `SCHEDULED payne …`, `SCHEDULED scrooge …`. If any prints `NO SESSION <agent>`, that agent has no active session — note it (its publish will start once a session exists / it next wakes); do not block the others. Host-sweep wakes each agent within ~60s, it loads the `publish` skill and writes `memories/public.md`.

- [ ] **Step 5 — Verify projection produced all four fragments**

```bash
ssh root@148.253.211.164 'sleep 120; ls -la /home/nanoclaw/nanoclaw/groups/global/profiles/ && for a in greg gordon payne scrooge; do echo "=== $a ==="; cat /home/nanoclaw/nanoclaw/groups/global/profiles/$a.md 2>/dev/null || echo MISSING; done'
```
Expected: `greg.md gordon.md payne.md scrooge.md` all present with real `updated:` dates (today) and populated fields — proof each agent ran publish and the host projected it. A fragment still showing `updated: 2026-06-01` means that agent hasn't run publish yet (seed) — check its container ran (logs / `ncl sessions list`); the task retries on the next sweep.

- [ ] **Step 6 — Verify a container reads a fragment at the mounted path**

```bash
ssh root@148.253.211.164 'docker run --rm -v /home/nanoclaw/nanoclaw/groups/global:/workspace/global:ro --entrypoint sh nanoclaw-agent-v2-16111809:latest -c "cat /workspace/global/profiles/greg.md && echo OK-READABLE"'
```
Expected: greg fragment prints + `OK-READABLE`. (Confirm the image tag with `docker images | grep nanoclaw-agent` if it changed.)

- [ ] **Step 7 — Confirm Scrooge published NO exact sums (guardrail)**

```bash
ssh root@148.253.211.164 'grep -iE "\$|usd|[0-9]{4,}" /home/nanoclaw/nanoclaw/groups/global/profiles/scrooge.md || echo "CLEAN — no raw sums"'
```
Expected: `CLEAN — no raw sums` (only bands/percentages, no 4+ digit numbers or currency). If it leaks a sum, fix the scrooge publish skill's guardrail and re-run its task.

- [ ] **Step 8 — Update project memory**

Update `/Users/serg/.claude/projects/-Users-serg-git-nanoclaw/memory/project_gordon_agent.md`: Phase B shipped — host projection live; all four analysts (greg/gordon/payne/scrooge) publish `public.md` via a uniform `publish` skill on a recurring 08:45 task; Jarvis brief reads `greg.md`. Record the deploy facts: tasks = `messages_in kind='task'` injected via `insertTask` heredoc; publish in live-mounted skill ⇒ no CLAUDE.md edits / no rebirths; recurrence cron in `TIMEZONE`.

---

## Done criteria

- Host projection committed + deployed; service `active`.
- All four of `greg.md gordon.md payne.md scrooge.md` exist in `groups/global/profiles/` with today's `updated:` and real content; readable in a container at `/workspace/global/profiles/`.
- Scrooge's fragment carries only rounded bands (no exact sums).
- Jarvis morning-brief §6 sources health from `greg.md` (date logic intact + fallback).
- Recurring 08:45 publish task live for each agent; no CLAUDE.md edits, no rebirths, no image rebuild.

## Not in this phase

- **C** — body-comp (iOS `bodyMass`/`height`/`bodyFatPercentage`/`leanBodyMass` → Greg trend; `greg.md` gains a body-trend line). iOS rebuild.
- **D** — Gordon reads `greg.md`/`payne.md` for the recomp verdict; intake pulls weight/height (needs A + C).
- **E** — retire the `health_trend → self/health.md` a2a push once fragments are confirmed; drop the morning-brief fallback. Add Payne weekly-tonnage to `payne.md` once `volume-report.js` grows a CLI.
```