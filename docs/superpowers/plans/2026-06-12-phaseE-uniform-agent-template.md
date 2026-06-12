# Phase E — Uniform agent template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put all five agents on one template — **publish your own fragment → read others' fragments for ambient context → a2a only for urgent/actionable push** — including Jarvis (who didn't publish), retire the now-redundant routine `health_trend` a2a, normalize Gordon's file structure, and make the `recomp` skill trigger on natural questions.

**Architecture:** Phase B gave 4 analysts a publish skill + the `/workspace/global/profiles/` projection; the shared INSTRUCTIONS §Public profiles already states the read/publish convention. This phase makes the doctrine **uniform across all 5**: Jarvis gains a publish skill (`jarvis.md` = focus/location/next events); every agent's §Команда is reframed to the same shape; the routine daily `health_trend` push (Greg→Jarvis→`self/health.md`) is retired because Jarvis now reads `greg.md`. Urgent/actionable a2a stays (Greg findings/sick-day → Jarvis; Greg `health_signal` → Payne; Scrooge critical ping → Jarvis; Jarvis recheck → agents). Changing CLAUDE.md = **5 session rebirths** (skills are live-mounted, CLAUDE.md isn't).

**Tech Stack:** Group files (Markdown skills + CLAUDE.md), scp deploy, `insertTask` for Jarvis's publish task, session-rebirth via `session_state` delete + restart.

**Spec:** [`docs/superpowers/specs/2026-06-11-shared-profiles-and-bodycomp-design.md`](../specs/2026-06-11-shared-profiles-and-bodycomp-design.md) §E (a2a reform) + the operator's directive "все агенты по одному шаблону: публикация своих / чтение чужих / a2a для экстренного."

---

## Audit baseline (what's non-uniform today)

- **Jarvis**: no `skills/publish/SKILL.md`, no `memories/public.md` (assembler-only). → add both.
- **Gordon**: `skills/index.md` is a bullet list; greg/payne/scrooge/jarvis use a `| Skill | Когда применять |` table. → convert to table.
- **§Команда shape varies**: Greg has none (a2a lives in skills); Payne `### Команда (a2a)`; Scrooge `### Проактивные пинги`; Jarvis `### Команда`; Gordon already reframed (Phase D). → one shape everywhere.
- **Routine `health_trend` a2a**: Greg pushes a daily trend → Jarvis writes `self/health.md` → brief reads it. Redundant now that Greg publishes `greg.md` and the brief reads it. → retire push; keep urgent findings.
- **`recomp` trigger**: "как рекомп" (jargon). → natural ("что по весу / как тело / прогресс / что исправить").

`gordon.md` already published (B); `gordon` already reframed (D) — not re-touched except structure + recomp trigger.

---

### Task 1 — Jarvis publishes (`jarvis.md`)

**Files:**
- Create: `groups/jarvis/skills/publish/SKILL.md`
- Create: `groups/jarvis/memories/public.md`
- Modify: `groups/jarvis/skills/index.md` (+`publish` row)
- Modify: `groups/global/profiles/index.md` (+`jarvis.md` line)

- [ ] **Step 1: Create the publish skill**

`groups/jarvis/skills/publish/SKILL.md`:

```markdown
---
name: publish
description: Use on the scheduled morning publish wake (~08:45) to refresh your public fragment — current focus / location / next events — for the other agents. Terminal, silent, no message to Sergei.
---

# Publish — публичная сводка (Jarvis)

Раз в день (~08:45). Короткая публичная сводка о текущем состоянии Сергея для других агентов — не для Сергея, молча.

## Шаги
1. Локация + фокус — из `memories/self/profile.md` (текущее местоположение, чем сейчас занят).
2. Ближайшие события — календарь на сегодня (skill `mail-cal` → `calendar-events.js`), 1-2 главных. Если недоступно — пропусти строку.
3. Перепиши `memories/public.md`:

   ```
   ---
   updated: <сегодня YYYY-MM-DD>
   ---
   # Jarvis — оператор

   локация: <город/место или «—»>
   фокус: <чем занят сейчас, одна фраза, или «—»>
   сегодня: <1-2 ближайших события или «—»>
   ```

4. Молча. Никому не шли. Это файл для агентов.

## Дисциплина
- Только стабильно-публичное (где Сергей, чем занят) — без чувствительного (почта, личные детали).
- Нет данных по строке → «—», не выдумывай.
```

- [ ] **Step 2: Seed `public.md`**

`groups/jarvis/memories/public.md`:

```markdown
---
updated: 2026-06-01
---
# Jarvis — оператор

локация: —
фокус: —
сегодня: (появится на утреннем прогоне ~08:45)
```

- [ ] **Step 3: Add to Jarvis skills catalog (table format)**

In `groups/jarvis/skills/index.md`, add a row in the existing table:

```markdown
| `publish` | Утренний таск (~08:45): фокус/локация/события → `memories/public.md` (публичный фрагмент Jarvis для агентов). Терминально, молча. |
```

- [ ] **Step 4: Add `jarvis.md` to the profiles catalog**

In `groups/global/profiles/index.md`, add:

```markdown
- `jarvis.md` — оператор: текущий фокус, локация, ближайшие события. Read for "where is Sergei / what's he doing" context.
```

- [ ] **Step 5: Verify** — `ls groups/jarvis/skills/publish/SKILL.md groups/jarvis/memories/public.md` + `grep -c publish groups/jarvis/skills/index.md`.

---

### Task 2 — Uniform §Команда across all 5

Each agent's team section becomes the same shape: **publish / read / a2a-urgent**, tailored content. Re-read each CLAUDE.md before editing for the exact anchor.

- [ ] **Step 1: Greg — ADD `## Команда (фрагменты + a2a)`** (Greg has none; insert after `## Скилы`, before `## Специфика`):

```markdown
## Команда (фрагменты + a2a)

Кросс-доменный контекст — через общие профили (pull), не постоянный a2a. Механизм — INSTRUCTIONS §Public profiles.

- **Публикуешь** `memories/public.md` (skill `publish`, утренний таск ~08:45): готовность/восстановление/тренд/состав тела. Хост раздаёт в `profiles/greg.md`. **Это твой штатный канал к Джарвису** — он читает фрагмент для утреннего брифа. Рутинный дневной `health_trend` в a2a больше НЕ шлёшь (он в фрагменте).
- **Читаешь** при необходимости `profiles/gordon.md` (питание): мог ли недобор белка / злой дефицит объяснить просадку восстановления — для differential.
- **a2a — только срочное / actionable:**
  - **Джарвису** — `finding` `severity: warn/critical` + sick-day (требует реакции сейчас → он гейтит Сергею).
  - **Пейну** — `health_signal` (готовность гейтит интенсивность тренировки; actionable под тренировку, остаётся a2a — см. skill `payne-signal`).
```

- [ ] **Step 2: Payne — REPLACE `### Команда (a2a)`** with:

```markdown
### Команда (фрагменты + a2a)

Кросс-доменный контекст — через общие профили (pull); a2a — только actionable. Механизм — INSTRUCTIONS §Public profiles.

- **Публикуешь** `memories/public.md` (skill `publish`, утренний таск ~08:45): программа/последняя/следующая/трен-день. → `profiles/payne.md`.
- **Читаешь** `profiles/greg.md` (готовность/восстановление) — фон для калибровки нагрузки, в дополнение к срочному `health_signal`.
- **a2a — actionable:**
  - **Джарвис** — `next_workout(date)` по запросу (`{"day_name","duration_estimate_min","main_exercises","intensity"}`); `workout_done`; `reschedule_request`.
  - **Грег** — принимаешь `health_signal {date, level, factors, recommendation}`: `yellow` → `set_modifier *= 0.9`, `rir` +1; `red` → отдых / лёгкое кардио, дождись подтверждения. По завершении тренировки шлёшь Грегу `workout_done {tonnage_kg, duration_min, perceived_overall_rir}`.
```

- [ ] **Step 3: Scrooge — REPLACE `### Проактивные пинги`** with:

```markdown
### Команда (фрагменты + a2a)

- **Публикуешь** `memories/public.md` (skill `publish`, утренний таск ~08:45): огрублённый запас / тренд трат (только полосы, без сумм). → `profiles/scrooge.md`.
- **Читаешь**: обычно ничего (финансы автономны).
- **a2a — только срочное → Джарвис:** критический finance-пинг (провал runway / крупная утечка), `send_message(to="jarvis", "<кратко>")`. Триггер — только сигнал из `weekly-scan`. Anti-spam: suppress в `state.md`, уважай 👎. Голос: «Bah! Подписка X — $12/мес, не трогал 3 месяца. Режь.» Рутину не шлёшь.
```

- [ ] **Step 4: Jarvis — REPLACE `### Команда`** with:

```markdown
### Команда (фрагменты + a2a)

Ты ассемблер: читаешь фрагменты всех агентов и собираешь бриф. **Теперь ты тоже публикуешь свой фрагмент** (единый шаблон).

- **Публикуешь** `memories/public.md` (skill `publish`, утренний таск ~08:45): текущий фокус / локация / ближайшие события. Хост раздаёт в `profiles/jarvis.md`.
- **Читаешь** `profiles/{greg,gordon,payne,scrooge}.md` — для брифа (см. `morning-brief`) и по запросу, когда тема смежная. **Тренд здоровья берёшь из `greg.md`** (строки `тренд:` + `состав тела:`), не из a2a — Грег рутинный `health_trend` больше не шлёт, и `self/health.md` ты больше не пишешь.
- **a2a — только срочное:**
  - **`greg`** — принимаешь `finding` `warn/critical` + sick-day → гейтишь Сергею. Recheck-запросы шлёшь ему по требованию.
  - **`payne`** — `next_workout(date)` по запросу; принимаешь `workout_done` / `reschedule`.
  - **`scrooge`** — принимаешь критический finance-пинг → гейтишь как health. Запрос сводки (баланс/net worth/траты) делегируешь ему.

Полные контракты (JSON-формы, loop-guards) — `memories/team.md`.
```

- [ ] **Step 5: Verify** — `grep -l "Команда (фрагменты" groups/{greg,payne,scrooge,jarvis}/CLAUDE.md` (all 4) + `grep -L "Проактивные пинги" groups/scrooge/CLAUDE.md` (gone).

---

### Task 3 — Retire the routine `health_trend` a2a push

The daily trend now lives in `greg.md` (Greg's publish skill) which the brief reads. Drop the redundant push.

- [ ] **Step 1: Greg `daily-cycle` — drop the routine trend send (keep findings)**

In `groups/greg/skills/daily-cycle/SKILL.md`, the step that sends `health_trend` to Jarvis every run (step 6, "Дневной тренд Джарвису — ОБЯЗАТЕЛЬНО каждый прогон") — replace it so only the **urgent finding** is sent:

```markdown
6. **Срочный finding Джарвису — ТОЛЬКО при новой аномалии** (нет в `state.md`, не под suppress) → `send_message(to="jarvis", <finding-JSON или список>)`. Рутинный дневной тренд в a2a больше НЕ шлёшь — он уходит в `memories/public.md` (skill `publish`, отдельный утренний таск ~08:45), Джарвис читает `profiles/greg.md`. Нет новой аномалии — Джарвису ничего.
```

Leave step 7 (payne-signal) intact — that a2a stays. Update the skill's frontmatter `description` if it claims "ALWAYS sends a `health_trend`" — change to "sends a finding only on a new anomaly."

- [ ] **Step 2: Jarvis `morning-brief` §6 — drop the `self/health.md` fallback**

In `groups/jarvis/skills/morning-brief/SKILL.md` §6 (added in Phase B), remove the trailing **Fallback** paragraph (the one pointing to legacy `memories/self/health.md`). `greg.md` is now the sole source. Keep the `greg.md` read + the `updated`-date staleness logic. If `greg.md` is missing/stale → skip the health line (already covered by the date rules).

- [ ] **Step 3: Verify** — `grep -c 'health_trend' groups/greg/skills/daily-cycle/SKILL.md` (now only the deprecation note) + `grep -c 'self/health.md' groups/jarvis/skills/morning-brief/SKILL.md` (0).

Note: `groups/jarvis/memories/self/health.md` becomes vestigial (no longer written/read) — leave the file, harmless. Greg's `health-trend` skill becomes unused — leave it.

---

### Task 4 — Gordon: normalize structure + naturalize `recomp` trigger

- [ ] **Step 1: `skills/index.md` bullets → table**

Rewrite `groups/gordon/skills/index.md` to the table format the other 4 agents use:

```markdown
# Скилы Гордона — каталог

Скилы лежат в `skills/<name>/SKILL.md`. Читай нужный по необходимости — не загружай всё сразу.

| Skill | Когда применять |
|-------|------|
| `log-meal` | Фото/текст еды → пайплайн identify→quantify→critique → запись в meals.db → реакция. Триггер: вложение-картинка, «залогируй», «что я съел». |
| `intake` | Собрать рост/вес/активность/цель → рекомп-таргеты (тянет вес/рост с телефона). Триггер: нет профиля, «пересчитай таргеты», «мой вес X». |
| `daily` | Вечерний итог дня vs таргеты (~21:00 Makassar) или «как по еде сегодня». |
| `publish` | Утренний таск (~08:45): targets+rollup → `memories/public.md` (публичная сводка питания). Молча. |
| `recomp` | Вопрос про вес/тело/прогресс/что исправить: читает тренд тела из `greg.md` + адерентность → вердикт сухая↑/жир↓. |
```

- [ ] **Step 2: Naturalize `recomp` trigger — skill description**

In `groups/gordon/skills/recomp/SKILL.md`, change the frontmatter `description` to natural phrasing:

```markdown
description: Use when Сергей asks about weight / body / nutrition progress / what to fix — «что по весу», «как тело / фигура», «прогресс», «худею/набираю ли», «что исправить (по телу/составу)». Reads Greg's body-composition trend + your adherence, gives a Ramsay verdict. Read-only.
```

- [ ] **Step 3: Naturalize `recomp` trigger — Gordon CLAUDE.md §Скилы**

In `groups/gordon/CLAUDE.md`, the `recomp` bullet in §Скилы — change its trigger to:

```markdown
- `recomp` — вердикт по рекомпозиции (сухая↑/жир↓): читает тренд тела из `greg.md` + адерентность. Триггер: «что по весу / как тело / прогресс / что исправить».
```

(Gordon's CLAUDE.md is re-touched here, so it rides the rebirth in Task 5.)

- [ ] **Step 4: Verify** — `head -6 groups/gordon/skills/index.md | grep -q '| Skill'` (table) + `grep -c 'как рекомп' groups/gordon/` should not surface the old jargon trigger as the primary.

---

### Task 5 — Deploy + rebirth all touched agents + bootstrap Jarvis publish

Touched CLAUDE.md: **greg, payne, scrooge, jarvis, gordon** (5 rebirths). New skills/files: live-mounted (no rebirth). Jarvis needs a new 08:45 publish task.

- [ ] **Step 1: scp all touched group files + chown**

```bash
cd /Users/serg/git/nanoclaw
# Jarvis (publish skill + seed + index + CLAUDE + morning-brief)
scp -r groups/jarvis/skills/publish root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/skills/
scp groups/jarvis/memories/public.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/memories/
scp groups/jarvis/skills/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/skills/index.md
scp groups/jarvis/skills/morning-brief/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/skills/morning-brief/SKILL.md
scp groups/jarvis/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/CLAUDE.md
# Greg (CLAUDE + daily-cycle)
scp groups/greg/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/CLAUDE.md
scp groups/greg/skills/daily-cycle/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/skills/daily-cycle/SKILL.md
# Payne, Scrooge (CLAUDE)
scp groups/payne/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/payne/CLAUDE.md
scp groups/scrooge/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/scrooge/CLAUDE.md
# Gordon (skills/index + recomp + CLAUDE)
scp groups/gordon/skills/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/gordon/skills/index.md
scp groups/gordon/skills/recomp/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/gordon/skills/recomp/SKILL.md
scp groups/gordon/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/gordon/CLAUDE.md
# Catalog
scp groups/global/profiles/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/global/profiles/index.md
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups'
```

- [ ] **Step 2: Rebirth the 5 agents (CLAUDE.md changed)**

Reuse the Phase D rebirth pattern but loop over all 5: a tsx heredoc that, for each of `greg,payne,scrooge,jarvis,gordon`, finds the active session, opens `outbound.db` RW, deletes `continuation%` rows; then `ncl groups restart --id <each>`.

```bash
ssh root@148.253.211.164 'cat > /tmp/rebirth-all.ts <<EOF
import { initDb } from "/home/nanoclaw/nanoclaw/src/db/connection.js";
import { getActiveSessions } from "/home/nanoclaw/nanoclaw/src/db/sessions.js";
import { openOutboundDbRw } from "/home/nanoclaw/nanoclaw/src/session-manager.js";
initDb("/home/nanoclaw/nanoclaw/data/v2.db");
const sessions = getActiveSessions();
for (const ag of ["greg","payne","scrooge","jarvis","gordon"]) {
  const s = sessions.find((x) => x.agent_group_id === ag);
  if (!s) { console.log("no session", ag); continue; }
  const db = openOutboundDbRw(ag, s.id);
  const r = db.prepare("DELETE FROM session_state WHERE key LIKE 'continuation%'").run();
  db.close();
  console.log("rebirth", ag, "deleted", r.changes);
}
EOF
chown nanoclaw:nanoclaw /tmp/rebirth-all.ts
sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && pnpm -s exec tsx /tmp/rebirth-all.ts"
rm -f /tmp/rebirth-all.ts'
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && for a in greg payne scrooge jarvis gordon; do ./bin/ncl groups restart --id \$a; done"'
```

- [ ] **Step 3: Bootstrap Jarvis's 08:45 publish task**

Reuse the Phase B `insertTask` pattern for `jarvis` only:

```bash
ssh root@148.253.211.164 'cat > /tmp/jarvis-publish.ts <<EOF
import { initDb } from "/home/nanoclaw/nanoclaw/src/db/connection.js";
import { getActiveSessions } from "/home/nanoclaw/nanoclaw/src/db/sessions.js";
import { openInboundDb } from "/home/nanoclaw/nanoclaw/src/session-manager.js";
import { insertTask } from "/home/nanoclaw/nanoclaw/src/modules/scheduling/db.js";
initDb("/home/nanoclaw/nanoclaw/data/v2.db");
const now = new Date().toISOString();
const s = getActiveSessions().find((x) => x.agent_group_id === "jarvis");
if (!s) { console.log("NO SESSION jarvis"); process.exit(0); }
const db = openInboundDb("jarvis", s.id);
insertTask(db, { id: "task-publish-jarvis", processAfter: now, recurrence: "45 8 * * *", platformId: null, channelType: null, threadId: null, content: JSON.stringify({ prompt: "Load the \`publish\` skill and run it now — write memories/public.md. Terminal: no chat output, do not message anyone.", script: null }) });
db.close();
console.log("SCHEDULED jarvis", s.id);
EOF
chown nanoclaw:nanoclaw /tmp/jarvis-publish.ts
sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && pnpm -s exec tsx /tmp/jarvis-publish.ts"
rm -f /tmp/jarvis-publish.ts'
```

- [ ] **Step 4: Verify all 5 fragments project (jarvis now among them)**

```bash
ssh root@148.253.211.164 'sleep 90; ls /home/nanoclaw/nanoclaw/groups/global/profiles/ && echo "--- jarvis.md ---" && cat /home/nanoclaw/nanoclaw/groups/global/profiles/jarvis.md 2>/dev/null || echo "jarvis not published yet"'
```
Expected: `greg.md gordon.md jarvis.md payne.md scrooge.md index.md`; `jarvis.md` populated (or seed until its task runs).

- [ ] **Step 5: Update memory** — `project_gordon_agent.md` / a new note: uniform agent template shipped (all 5 publish + read + a2a-urgent; Jarvis publishes; routine health_trend retired; Gordon structure+recomp trigger fixed; 5 rebirths). Note Stream E mostly closed.

---

## Done criteria

- All 5 agents have `skills/publish/SKILL.md` + `memories/public.md`; `skills/index.md` all tables; all 5 §Команда use the same publish/read/a2a-urgent shape.
- `jarvis.md` projects into `profiles/`; catalog lists 5.
- Routine `health_trend` a2a gone (Greg sends findings only; brief reads `greg.md`, no `self/health.md` fallback).
- `recomp` triggers on natural weight/body/progress questions.
- 5 agents rebirthed; Jarvis publish task live.

## Risks / notes

- **5 rebirths** — the agents resume fresh on next message; no data loss, just new instructions. Jarvis is interactive (you talk to him) — his rebirth is the only user-visible one (next message starts a fresh session).
- **Retiring `health_trend`** assumes `greg.md` is reliably fresh by 09:00 (it is — 08:45 publish, ≤60s projection). If a publish run fails, the brief skips health that day (graceful) rather than showing stale.
- Health-data end-to-end still gated on Sergei's iOS rebuild (Phase C) — unchanged by this phase.
