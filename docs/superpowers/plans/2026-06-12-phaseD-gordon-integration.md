# Phase D — Gordon integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out Gordon — his intake pulls weight/height from Health instead of asking, he reads Greg's body-composition trend (`greg.md`) for a recomposition verdict and Payne's training-day from `payne.md`, and his CLAUDE.md reflects the integrated, fragment-reading reality (no more "Фаза 4 pending").

**Architecture:** Gordon-only, all group files (scp). New capabilities are **skill-driven** (intake-pull in the `intake` skill, recomp verdict in a new `recomp` skill, training-day in `daily`) — live-mounted, no rebirth. The one exception is **CLAUDE.md** (status + §Команда reframe + §Скилы +recomp) which is read at session birth, so Gordon gets **one session rebirth** (kill container + delete the `continuation:claude` row) to pick it up. Cross-domain reads use the Phase B fragments at `/workspace/global/profiles/` (RO mount, already live). Pull uses `request_context(["health"])` (Phase A fix + Phase C2 fields).

**Tech Stack:** Gordon group files (Markdown skills + CLAUDE.md), Bun scripts (`targets.js`/`daily-rollup.js`, unchanged), `request_context` MCP tool, scp deploy, session-rebirth via session-DB edit.

**Spec:** [`docs/superpowers/specs/2026-06-11-shared-profiles-and-bodycomp-design.md`](../specs/2026-06-11-shared-profiles-and-bodycomp-design.md) §D. Depends on **A** (request_context — done), **B** (`greg.md`/`payne.md` fragments — done), **C** (body fields in pull + `greg.md` `состав тела` line — code done; real data flows after Sergei's iOS device rebuild).

---

## Graceful-degradation contract (important)

Phase D deploys now, but its new inputs (body weight/height in the pull; `состав тела` in `greg.md`) only carry real data **after Sergei rebuilds the iOS app on his iPhone** (Phase C). So every new path must degrade cleanly until then:
- **intake-pull**: if `request_context(["health"])` returns no `body_mass_kg`/`height_m` (old app build / no scale) → fall back to **asking**, exactly as today. No regression.
- **recomp verdict**: if `greg.md` has no `состав тела:` line → say so honestly ("данных с весов пока нет"), judge from food adherence only.
- **training-day**: if `payne.md` is missing the line → no carb note.

Note: `gordon.md` is already published (Phase B). Phase D does not change publishing.

---

## File Structure (all under `groups/gordon/`, gitignored → scp)

| File | Change |
|------|--------|
| `skills/intake/SKILL.md` | Pull weight/height first; ask only what's missing |
| `skills/recomp/SKILL.md` | **Create** — recomp verdict from `greg.md` + adherence |
| `skills/daily/SKILL.md` | Read `payne.md` training-day → carb note |
| `skills/index.md` | +`recomp` line |
| `CLAUDE.md` | Status + §Команда reframe (reads fragments) + §Скилы +recomp + intake note + team.md note |

No host/iOS/protocol changes. No git commits (group files).

---

### Task 1 — `intake` pulls weight/height

**Modify:** `groups/gordon/skills/intake/SKILL.md`

- [ ] **Step 1: Add a pull-first step**

Replace the section from `# intake — собрать профиль → посчитать таргеты` through the end of `## Что спросить (если нет в профиле)` with:

```markdown
# intake — собрать профиль → посчитать таргеты

Нужны: рост (см), вес (кг), активность, цель. Возраст известен (40), пол — мужской.

## 1. Сначала тяни вес/рост с телефона (не спрашивай зря)
`request_context(["health"])` — в ответе (`context_response`, поле `data.health`) ищи `body_mass_kg` (кг) и `height_m` (м). Запрос дорогой (батарея/iOS) — делай ОДИН раз в начале intake.
- Есть оба → используй: вес = `body_mass_kg`, рост (см) = `height_m × 100`. Ничего не спрашивай по этим двум.
- Пусто/нет поля (старая сборка приложения, нет умных весов, нет данных) → fallback: спроси, как ниже. Это нормально — не алармируй.

## 2. Спроси ТОЛЬКО недостающее
- **Рост** (см) — если не пришёл с телефона и нет в профиле, спроси один раз (`about-sergei.md` его не держит).
- **Вес** (кг) — если не пришёл, спроси текущий или возьми последний названный.
- **Активность** — фактор: малоподвижный 1.2 / лёгкая 1.375 / умеренная (тренировки 3-5×/нед — твой случай с Payne) 1.55 / высокая 1.725. Дефолт 1.55.
- **Цель** — рекомп (дефолт из спека).
```

- [ ] **Step 2: Update the weight note (drop the stale "Фаза 4" line) and keep `--set`**

Confirm the `## Записать` block's `targets.js --set` call is unchanged (it already takes `--height`/`--weight`). The old "В Фазе 4 поедет автоматом" caveat is now removed by Step 1's rewrite. Verify no stray "Фаза 4" text remains: `grep -n "Фаз" groups/gordon/skills/intake/SKILL.md` → no output.

- [ ] **Step 3: Verify**

`grep -n 'request_context\|body_mass_kg\|height_m' groups/gordon/skills/intake/SKILL.md` → shows the pull step. (scp in Task 5.)

---

### Task 2 — `recomp` skill (verdict from `greg.md`)

**Create:** `groups/gordon/skills/recomp/SKILL.md`
**Modify:** `groups/gordon/skills/index.md` (+`recomp` line)

- [ ] **Step 1: Create the skill**

```markdown
---
name: recomp
description: Use when Сергей asks about recomposition / body progress — "как рекомп", "прогресс", "как тело", "работает ли", "сухая/жир". Reads Greg's body-composition trend + your adherence, gives a Ramsay verdict. Read-only.
---

# recomp — вердикт по рекомпозиции

Рекомп = **сухая масса вверх / жир вниз при ровном весе.** Судишь по тренду тела (его держит Грег) + твоей адерентности по еде. Вес сам по себе НЕ критерий.

## Шаги
1. **Тренд тела — у Грега.** Прочитай `/workspace/global/profiles/greg.md`, строку `состав тела:` (вес кг · жир кг и % · сухая кг; за месяц жир ↓/↑, сухая ↑/↓). Механизм фрагментов — INSTRUCTIONS §Public profiles.
   - Строки нет / файл без неё → данных с весов пока нет (весы не каждый день / приложение ещё не пересобрано). Скажи честно: «Данных с весов пока нет — рекомп сужу по еде, тело подключится позже», и переходи к шагу 2 без вердикта по телу.
2. **Адерентность — твоя.** `bun /workspace/agent/scripts/daily-rollup.js` (последний день): добирается ли белок (`protein_hit`), калории около цели (`vs_target.kcal_pct`). При желании — пробегись по нескольким последним дням (`--date YYYY-MM-DD`).
3. **Вердикт (голос Рамзи, простой русский, коротко):**
   - жир ↓ + сухая ↑/ровно при ровном весе → «Вот это работа. Жир вниз, мышцы на месте. Держи белок и не расслабляйся.»
   - сухая ↓ или жир ↑ → проблема: «Сухая уходит. Либо белка мало, либо дефицит злой. Подними белок, перестань резать так агрессивно.»
   - вес скачет / тренд неясен → «По весу не сужу — он гуляет. Состав тела вот что считается, и он пока <тренд или 'без данных'>.»
4. **Свяжи с едой:** если белок системно не добран И сухая падает — назови причину прямо. Это твоя зона: рацион чинишь ты.

## Дисциплина
- Только читаешь `greg.md` — не пишешь туда, не пингуешь Грега (a2a нет). Тренд тела — его, ты трактуешь под питание.
- Нет данных по телу — не выдумывай. Честное «весов нет» лучше выдуманного вердикта.
```

- [ ] **Step 2: Add to the skills catalog**

In `groups/gordon/skills/index.md`, add after the `daily` bullet:

```markdown
- `recomp` — вердикт по рекомпозиции: читает тренд тела из `greg.md` + адерентность → судит сухая↑/жир↓. Триггер: «как рекомп / прогресс / как тело».
```

- [ ] **Step 3: Verify** — `ls groups/gordon/skills/recomp/SKILL.md` + `grep recomp groups/gordon/skills/index.md`. (scp in Task 5.)

---

### Task 3 — `daily` reads Payne's training-day

**Modify:** `groups/gordon/skills/daily/SKILL.md`

- [ ] **Step 1: Add a training-day carb note**

After the `## Реакция (голос Рамзи, прямо Сергею, простой русский)` block (before `## Расписание`), insert:

```markdown
## Трен-день (углеводы)
Загляни в `/workspace/global/profiles/payne.md`, строку `трен-день сегодня:` (механизм — INSTRUCTIONS §Public profiles).
- `да` → тренировочный день, углеводы можно выше нормы (топливо). Отметь, если к месту: «Сегодня тренировка — углеводы выше ок, заслужил.» Не дави, просто контекст.
- `нет` / файла нет / строки нет → без добавки, обычная норма. Не упоминай.
```

- [ ] **Step 2: Verify** — `grep -n 'payne.md\|трен-день' groups/gordon/skills/daily/SKILL.md`. (scp in Task 5.)

---

### Task 4 — Gordon CLAUDE.md reflects the integrated state

**Modify:** `groups/gordon/CLAUDE.md`

- [ ] **Step 1: Status line**

Replace the blockquote:

```markdown
> **Статус:** логирование по фото (`log-meal`), рекомп-таргеты (`intake`/`targets.js`) и дневной итог (`daily`) работают. Командные контракты (Greg/Payne/Jarvis), body-comp и недельный вердикт — Фаза 4.
```

with:

```markdown
> **Статус:** логирование по фото (`log-meal`), рекомп-таргеты (`intake` — тянет вес/рост с телефона), дневной итог (`daily`), рекомп-вердикт (`recomp` — читает тренд тела у Грега) и публичная сводка (`publish`) работают. Кросс-доменный контекст берёшь чтением фрагментов в `/workspace/global/profiles/`, не a2a.
```

- [ ] **Step 2: §Команда — reframe from a2a-pending to fragment-reading**

Replace the `## Команда (a2a)` section body:

```markdown
## Команда (a2a)

Командные контракты с Jarvis / Greg / Payne подключаются в Фазе 4. Пока твой единственный канал — прямой разговор с Сергеем в приложении. Не пытайся слать сообщения другим агентам — destinations ещё не заведены.
```

with:

```markdown
## Команда (фрагменты, не a2a)

Кросс-доменный контекст ты **читаешь** из `/workspace/global/profiles/` (pull, RO-маунт; механизм — INSTRUCTIONS §Public profiles) — не пушишь a2a (destinations к другим агентам у тебя нет):

- `greg.md` — состав тела и тренд (вес/жир/сухая). Источник для рекомп-вердикта (skill `recomp`). Строки `состав тела:` может не быть, пока нет данных с весов — это норма.
- `payne.md` — трен-день (углеводы вверх в тренировочный день — skill `daily`).

Свою сводку ты публикуешь в `memories/public.md` (skill `publish`, хост раздаёт в `profiles/gordon.md`). Прямой канал к Сергею в приложении — как и был.
```

- [ ] **Step 3: §Скилы — add `recomp`**

In the `## Скилы` bullet list, after the `daily` bullet, add:

```markdown
- `recomp` — вердикт по рекомпозиции (сухая↑/жир↓): читает тренд тела из `greg.md` + адерентность. Триггер: «как рекомп / прогресс / как тело».
- `publish` — утренняя публичная сводка (таргеты/адерентность) в `memories/public.md`. Триггер: утренний таск ~08:45.
```

- [ ] **Step 4: §Память — update the team.md note**

Replace:

```markdown
- `memories/team.md` — контракты с другими агентами (заполняется в Фазе 4).
```

with:

```markdown
- `memories/team.md` — заметки по кросс-агентному чтению (какие фрагменты, что в них). Не обязателен — основное в §Команда + INSTRUCTIONS §Public profiles.
```

- [ ] **Step 5: Verify no stale "Фаза 4" remains**

`grep -n "Фаз" groups/gordon/CLAUDE.md` → expect no matches (or only unrelated). (scp + rebirth in Task 5.)

---

### Task 5 — Deploy + rebirth Gordon + verify

**Files:** none (deploy/verify). VDS `root@148.253.211.164`, user `nanoclaw`, repo `/home/nanoclaw/nanoclaw`.

- [ ] **Step 1: scp Gordon's files + chown**

```bash
cd /Users/serg/git/nanoclaw
scp groups/gordon/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/gordon/CLAUDE.md
scp groups/gordon/skills/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/gordon/skills/index.md
scp groups/gordon/skills/intake/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/gordon/skills/intake/SKILL.md
scp groups/gordon/skills/daily/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/gordon/skills/daily/SKILL.md
scp -r groups/gordon/skills/recomp root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/gordon/skills/
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/gordon'
```

- [ ] **Step 2: Rebirth Gordon (CLAUDE.md changed — needs a fresh session)**

CLAUDE.md is read at session birth; a running session resumes via the `continuation:claude` row and ignores the new file. So: delete that row from Gordon's session `outbound.db`, then kill the container — next wake spawns a fresh session loading the new CLAUDE.md. The `intake`/`recomp`/`daily` skills are live-mounted and don't need this, but the §Скилы discovery of `recomp` does.

First confirm the exact session-state key (don't assume) via a tsx heredoc, then delete + kill:

```bash
ssh root@148.253.211.164 'cat > /tmp/rebirth-gordon.ts <<EOF
import { initDb } from "/home/nanoclaw/nanoclaw/src/db/connection.js";
import { getActiveSessions } from "/home/nanoclaw/nanoclaw/src/db/sessions.js";
import { openOutboundDbRw } from "/home/nanoclaw/nanoclaw/src/session-manager.js";
initDb("/home/nanoclaw/nanoclaw/data/v2.db");
const s = getActiveSessions().find((x) => x.agent_group_id === "gordon");
if (!s) { console.log("NO SESSION gordon"); process.exit(0); }
const db = openOutboundDbRw("gordon", s.id);
const rows = db.prepare("SELECT key FROM session_state").all();
console.log("session_state keys:", JSON.stringify(rows));
const r = db.prepare("DELETE FROM session_state WHERE key LIKE 'continuation%'").run();
console.log("deleted continuation rows:", r.changes, "session:", s.id);
db.close();
EOF
chown nanoclaw:nanoclaw /tmp/rebirth-gordon.ts
sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && pnpm -s exec tsx /tmp/rebirth-gordon.ts"
rm -f /tmp/rebirth-gordon.ts'
```

Then kill Gordon's container so it respawns fresh:

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && ./bin/ncl groups restart --id gordon"'
```

Expected: the heredoc prints the `session_state` keys (confirm a `continuation:claude`-style key existed) + `deleted continuation rows: 1`. If the printed keys show a different continuation key name, the `LIKE 'continuation%'` still catches it; if there was no continuation row (Gordon idle, no live session), that's fine — the next spawn is already fresh.

- [ ] **Step 3: Verify recomp degrades correctly (no body data yet)**

`greg.md` currently has no `состав тела:` line (no scale data pre-rebuild). Confirm the recomp skill's "no data" path is what Gordon will hit:

```bash
ssh root@148.253.211.164 'grep -c "состав тела" /home/nanoclaw/nanoclaw/groups/global/profiles/greg.md || true'
```
Expected: `0` (no line yet) → Gordon's `recomp` will correctly say "данных с весов пока нет". After Sergei's iOS rebuild + a scale reading, that line appears and the verdict engages.

- [ ] **Step 4: Live smoke (user-facing) — hand to Sergei**

Two things Sergei verifies in the app (the first works now, the second after his iOS rebuild):
1. **recomp now:** ask Gordon "как рекомп?" → he loads the `recomp` skill, reads `greg.md`, and (no body data yet) replies honestly that scale data isn't in yet, judging from food. Confirms the skill + CLAUDE.md rebirth took.
2. **intake-pull after iOS rebuild:** trigger intake ("пересчитай таргеты") → Gordon pulls weight/height from Health instead of asking. Before the rebuild he falls back to asking (graceful).

- [ ] **Step 5: Update memory**

Update `project_gordon_agent.md`: Phase D shipped — intake pulls weight/height (graceful fallback), `recomp` skill reads `greg.md` for the verdict, `daily` reads `payne.md` training-day, CLAUDE.md de-Phase-4'd; Gordon rebirthed (continuation-row delete + restart). Note the full A→D arc is code-complete; only Sergei's iOS device rebuild gates the body-data end-to-end. Mark the Gordon redesign DONE.

---

## Done criteria

- `intake` pulls `body_mass_kg`/`height_m` via `request_context`, falls back to asking when absent.
- `recomp` skill exists + in the catalog + §Скилы; reads `greg.md`, honest "no data" path.
- `daily` reads `payne.md` training-day.
- Gordon CLAUDE.md: no stale "Фаза 4", §Команда reframed to fragment-reading, §Скилы lists `recomp`+`publish`.
- Deployed; Gordon rebirthed; recomp "no data" path confirmed; smoke handed to Sergei.

## Not in this phase

- **E** — retire the `health_trend → self/health.md` a2a push once fragments are confirmed flowing; drop the morning-brief fallback. Add Payne weekly-tonnage to `payne.md` once `volume-report.js` grows a CLI.
- Proactive weekly recomp ping (currently on-demand) — add later if wanted.
- The body-data end-to-end (intake-pull with real numbers, `состав тела` verdict) activates after Sergei's iOS device rebuild (Phase C handoff).
