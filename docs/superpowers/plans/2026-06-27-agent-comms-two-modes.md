# Two Communication Modes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give all 5 agents a uniform "direct (human) vs team (a2a)" communication model; remove Greg's stale "Jarvis-only" framing that contradicts app reality.

**Architecture:** Instruction-only. One shared section added to `groups/INSTRUCTIONS.md` (@-included by every agent), plus targeted edits to each agent's `groups/<agent>/CLAUDE.md`. Mode is detected at read-time from the inbound `<message from="...">` attribute (already emitted by `container/agent-runner/src/formatter.ts:233`). No code, no schema, no routing changes.

**Tech Stack:** Markdown instruction files. Deploy via scp to VDS + agent rebirth (continuation wipe).

**Spec:** `docs/superpowers/specs/2026-06-27-agent-comms-two-modes-design.md`

---

## Important execution notes (read first)

- **`groups/` is gitignored.** These files are NOT committed to git — they deploy by **scp** to the VDS. So edit tasks have **no per-task git commit and no unit tests**. Each edit task verifies by re-reading / grepping the file. The only git commit in this plan is the plan doc itself (already in `docs/`, tracked).
- **Edits must be exact.** Every task gives the exact `old_string` → `new_string` for the `Edit` tool. Read the file first (Edit requires it), then apply.
- **Deploy (Task 9) is a guarded, main-thread operation** — it touches the production VDS and wipes live SDK continuations. Do NOT run it via a blind subagent; the main thread executes it with live verification.
- **`feedback_agent_instruction_reload`:** CLAUDE.md edits do NOT reach a live agent on restart alone — the SDK session resumes via `continuation:claude` in `outbound.db`. Instructions are only re-read when a session is born. So deploy = scp + kill container + DELETE the continuation row, per affected session.

---

## File Structure

| File | Change |
|------|--------|
| `groups/INSTRUCTIONS.md` | + new section `## Два режима связи` (after §Agent-to-agent) |
| `groups/greg/CLAUDE.md` | rewrite persona line + language bullet (drop "Jarvis-only") |
| `groups/payne/CLAUDE.md` | + 1 pointer line in §Команда |
| `groups/gordon/CLAUDE.md` | extend existing "прямой канал" line with §pointer |
| `groups/scrooge/CLAUDE.md` | + 1 pointer line in §Команда |
| `groups/jarvis/CLAUDE.md` | + 1 "hub, not sole relay" line in §Команда |

---

## Task 1: Shared model — `groups/INSTRUCTIONS.md`

**Files:**
- Modify: `groups/INSTRUCTIONS.md` (insert new section before `## Behavior defaults`)

- [ ] **Step 1: Read the file** to confirm the anchor exists.

Run: `Read groups/INSTRUCTIONS.md` (the section `## Behavior defaults` follows `## Agent-to-agent (a2a)`).

- [ ] **Step 2: Insert the new section** with `Edit`.

`old_string`:
```
## Behavior defaults

Baseline defaults. Your persona can tighten them; nothing should loosen them without an explicit reason in your CLAUDE.md.
```

`new_string`:
```
## Два режима связи

Ты получаешь сообщения из двух источников и ведёшь себя по-разному. Определяй режим по атрибуту `from` входящего `<message>` (твои destination-имена перечислены в рантайм-аддендуме каждого хода):

- `from` = имя другого агента (jarvis / payne / greg / gordon / scrooge) → **командный режим (a2a)**.
- иначе (`from` = человеческий канал, напр. `ios-app-v2:*` или telegram; `sender` = имя человека) → **прямой режим**.

Дискриминатор — именно `from`. У a2a `sender` часто `Unknown` — на него не опирайся.

| | Прямой (человек) | Командный (a2a/агент) |
|---|---|---|
| Кому отвечаешь | человеку | агенту-источнику по вашему контракту |
| Форма | живой диалог в своей персоне, простой язык | структурный payload (finding / signal / JSON) |
| Уточнения | можно спрашивать, идти туда-обратно | терминально: один ответ, без авто-пингов (hop-cap 5) |
| Гейт к человеку | сам | принимающий агент (обычно Jarvis) решает, что показать |

Человек может прийти к любому агенту напрямую — **Jarvis это хаб-оркестратор, не обязательный передатчик.** a2a — для кросс-домен пуша (срочное / actionable), а не «всё через Jarvis».

Не зависит от режима: §Factual discipline, твои дисклеймеры, quiet hours, no-flattery, простой русский — действуют в обоих.

## Behavior defaults

Baseline defaults. Your persona can tighten them; nothing should loosen them without an explicit reason in your CLAUDE.md.
```

- [ ] **Step 3: Verify** the section landed and appears once.

Run: `grep -n "## Два режима связи" groups/INSTRUCTIONS.md`
Expected: exactly one match, before `## Behavior defaults`.

---

## Task 2: Greg persona line — `groups/greg/CLAUDE.md`

**Files:**
- Modify: `groups/greg/CLAUDE.md` (the `## Личность` opening sentence, ~line 7)

- [ ] **Step 1: Read** `groups/greg/CLAUDE.md` (confirm the sentence below is present verbatim).

- [ ] **Step 2: Replace** with `Edit`.

`old_string`:
```
Ты — Грег, узкий автономный аналитик здоровья своего человека. Ты **не** общаешься с человеком напрямую. Твой единственный собеседник — агент Jarvis. Ты считаешь числа скриптом и трактуешь только то, что он флагнул.
```

`new_string`:
```
Ты — Грег, автономный аналитик здоровья своего человека. Работаешь в **двух режимах** (см. INSTRUCTIONS §Два режима связи): **напрямую с человеком** — он пишет тебе в приложении (вопрос о здоровье, прислал анализы, разбор самочувствия → живой диалог в твоём голосе, можешь уточнять) — и **в команде** — a2a с Jarvis и Пейном (findings/signals, терминально). Числа всегда считаешь скриптом и трактуешь данные, а не память.
```

- [ ] **Step 3: Verify** the old framing is gone.

Run: `grep -c "не.* общаешься с человеком напрямую" groups/greg/CLAUDE.md`
Expected: `0`.

---

## Task 3: Greg language bullet — `groups/greg/CLAUDE.md`

**Files:**
- Modify: `groups/greg/CLAUDE.md` (the `## Манера общения` language bullet, ~line 26)

- [ ] **Step 1: Read** the file (confirm the bullet below is present verbatim).

- [ ] **Step 2: Replace** with `Edit`.

`old_string`:
```
- Язык — русский. Твои сообщения уходят к Jarvis, но `house_quote` и `observation` в конечном итоге попадают человеку через Jarvis-брифы verbatim. Пиши простым русским — медицинский жаргон и аббревиатуры разворачивай:
```

`new_string`:
```
- Язык — русский. В прямом режиме говоришь человеку сам; в командном — `house_quote` и `observation` попадают человеку через Jarvis-брифы verbatim. В обоих режимах простой русский — медицинский жаргон и аббревиатуры разворачивай:
```

- [ ] **Step 3: Verify.**

Run: `grep -c "В прямом режиме говоришь человеку сам" groups/greg/CLAUDE.md`
Expected: `1`.

---

## Task 4: Payne pointer — `groups/payne/CLAUDE.md`

**Files:**
- Modify: `groups/payne/CLAUDE.md` (§Команда intro, ~line 63)

- [ ] **Step 1: Read** the file (confirm the sentence below).

- [ ] **Step 2: Replace** with `Edit`.

`old_string`:
```
Кросс-доменный контекст — через общие профили (pull); a2a — только actionable. Механизм — INSTRUCTIONS §Public profiles.
```

`new_string`:
```
Кросс-доменный контекст — через общие профили (pull); a2a — только actionable. Механизм — INSTRUCTIONS §Public profiles.

Каналы — два режима (напрямую с человеком + командный a2a), см. INSTRUCTIONS §Два режима связи.
```

- [ ] **Step 3: Verify.**

Run: `grep -c "Два режима связи" groups/payne/CLAUDE.md`
Expected: `1`.

---

## Task 5: Gordon pointer — `groups/gordon/CLAUDE.md`

**Files:**
- Modify: `groups/gordon/CLAUDE.md` (the existing "прямой канал" line, ~line 60)

- [ ] **Step 1: Read** the file (confirm the sentence below).

- [ ] **Step 2: Replace** with `Edit`.

`old_string`:
```
Свою сводку ты публикуешь в `memories/public.md` (skill `publish`, хост раздаёт в `profiles/gordon.md`). Прямой канал к человеку в приложении — как и был.
```

`new_string`:
```
Свою сводку ты публикуешь в `memories/public.md` (skill `publish`, хост раздаёт в `profiles/gordon.md`). Прямой канал к человеку в приложении — как и был. Два режима связи (напрямую с человеком + командный приём a2a) — см. INSTRUCTIONS §Два режима связи.
```

- [ ] **Step 3: Verify.**

Run: `grep -c "Два режима связи" groups/gordon/CLAUDE.md`
Expected: `1`.

---

## Task 6: Scrooge pointer — `groups/scrooge/CLAUDE.md`

**Files:**
- Modify: `groups/scrooge/CLAUDE.md` (§Команда header, ~line 90)

- [ ] **Step 1: Read** the file (confirm the header + first bullet below).

- [ ] **Step 2: Replace** with `Edit`.

`old_string`:
```
### Команда (фрагменты + a2a)

- **Публикуешь** `memories/public.md` (skill `publish`, утренний таск ~08:45): огрублённый запас / тренд трат (только полосы, без сумм). → `profiles/scrooge.md`.
```

`new_string`:
```
### Команда (фрагменты + a2a)

Каналы — два режима (напрямую с человеком + срочный a2a Джарвису), см. INSTRUCTIONS §Два режима связи.

- **Публикуешь** `memories/public.md` (skill `publish`, утренний таск ~08:45): огрублённый запас / тренд трат (только полосы, без сумм). → `profiles/scrooge.md`.
```

- [ ] **Step 3: Verify.**

Run: `grep -c "Два режима связи" groups/scrooge/CLAUDE.md`
Expected: `1`.

---

## Task 7: Jarvis hub-not-relay — `groups/jarvis/CLAUDE.md`

**Files:**
- Modify: `groups/jarvis/CLAUDE.md` (§Команда intro, ~line 199)

- [ ] **Step 1: Read** the file (confirm the sentence below).

- [ ] **Step 2: Replace** with `Edit`.

`old_string`:
```
Ты ассемблер: читаешь фрагменты всех агентов и собираешь бриф. **Теперь ты тоже публикуешь свой фрагмент** (единый шаблон).
```

`new_string`:
```
Ты ассемблер: читаешь фрагменты всех агентов и собираешь бриф. **Теперь ты тоже публикуешь свой фрагмент** (единый шаблон).

Специалисты доступны человеку и **напрямую** (он выбирает их в приложении) — ты хаб-оркестратор и автор брифа, **не** единственный канал. См. INSTRUCTIONS §Два режима связи.
```

- [ ] **Step 3: Verify.**

Run: `grep -c "Два режима связи" groups/jarvis/CLAUDE.md`
Expected: `1`.

---

## Task 8: Local verification pass

**Files:** none (read-only checks)

- [ ] **Step 1: Confirm the shared section is present and unique.**

Run: `grep -rc "## Два режима связи" groups/INSTRUCTIONS.md`
Expected: `1`.

- [ ] **Step 2: Confirm all 5 agents reference it.**

Run: `for a in jarvis payne greg gordon scrooge; do echo -n "$a: "; grep -c "Два режима связи" groups/$a/CLAUDE.md; done`
Expected: each prints `1`.

- [ ] **Step 3: Confirm Greg's stale framing is fully gone.**

Run: `grep -nE "единственный собеседник|не\*?\*? общаешься с человеком напрямую" groups/greg/CLAUDE.md`
Expected: no output (exit 1).

- [ ] **Step 4: Sanity — no accidental dup headers anywhere.**

Run: `grep -rn "## Behavior defaults" groups/INSTRUCTIONS.md`
Expected: exactly one match (we inserted before it, not duplicated it).

---

## Task 9: Deploy to VDS (main-thread, guarded)

> Production VDS `root@148.253.211.164`, repo `/home/nanoclaw/nanoclaw`, service account `nanoclaw`. This wipes live SDK continuations so the agents re-read instructions on next wake. Execute step-by-step, verifying each.

**Files:** the 6 edited files above.

- [ ] **Step 1: scp the 6 files** to the VDS (preserve paths under `groups/`).

```bash
cd /Users/serg/git/nanoclaw
scp groups/INSTRUCTIONS.md \
    root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md
for a in jarvis payne greg gordon scrooge; do
  scp groups/$a/CLAUDE.md \
      root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/$a/CLAUDE.md
done
```

- [ ] **Step 2: chown to the service account.**

```bash
ssh root@148.253.211.164 'chown nanoclaw:nanoclaw \
  /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md \
  /home/nanoclaw/nanoclaw/groups/{jarvis,payne,greg,gordon,scrooge}/CLAUDE.md'
```

- [ ] **Step 3: Enumerate active sessions per agent group** (jarvis folder is the UUID `ag-1778740750341-ru9i6e`, NOT "jarvis" — get the real mapping from the DB).

```bash
ssh root@148.253.211.164 "cd /home/nanoclaw/nanoclaw && \
  sudo -u nanoclaw pnpm exec tsx scripts/q.ts data/v2.db \
  \"SELECT s.id, s.agent_group_id, ag.workspace_folder FROM sessions s \
    JOIN agent_groups ag ON ag.id=s.agent_group_id \
    WHERE s.status='active'\""
```
Expected: rows mapping each active session id → agent_group_id → folder. Note the on-disk session dir is `data/v2-sessions/<agent_group_id>/<session_id>/`.

- [ ] **Step 4: Wipe the Claude continuation** for every active session (forces a fresh SDK session that re-reads CLAUDE.md/INSTRUCTIONS). For each `<agent_group_id>/<session_id>` from Step 3:

```bash
ssh root@148.253.211.164 "cd /home/nanoclaw/nanoclaw && \
  sudo -u nanoclaw pnpm exec tsx scripts/q.ts \
  data/v2-sessions/<agent_group_id>/<session_id>/outbound.db \
  \"DELETE FROM session_state WHERE key='continuation:claude'\""
```
(Run once per session dir. A short loop over the Step-3 output is fine.)

- [ ] **Step 5: Kill running agent containers** so the next wake spawns fresh (with continuation gone). Identify and kill:

```bash
ssh root@148.253.211.164 'docker ps --format "{{.ID}} {{.Names}}" | grep -E "nanoclaw|agent"'
# then for each agent container:
ssh root@148.253.211.164 'docker kill <container_id>'
```
Containers respawn on the next inbound message (or via a scheduled wake). No `--message` needed — this is a passive reload.

- [ ] **Step 6: Confirm the files on the VDS match local** (spot-check the shared section).

```bash
ssh root@148.253.211.164 'grep -c "## Два режима связи" /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md'
```
Expected: `1`.

---

## Task 10: End-to-end verification (Сергей, post-deploy)

**Files:** none (behavioral probes on the live app)

- [ ] **Probe 1 — Greg direct mode.** In the app, pick **Greg**, send a health question (e.g. «почему я не выспался?»). Expected: Greg answers the human directly, conversationally, in House voice — NOT a finding-JSON, NOT "спроси у Jarvis".

- [ ] **Probe 2 — Greg team mode (regression).** Trigger a Jarvis→Greg a2a recheck (ask Jarvis to recheck a metric). Expected: Greg returns a structured finding, terminally, as before. No regression.

- [ ] **Probe 3 — others intact (spot).** Confirm a Payne workout start (direct) still works and a Greg→Payne `health_signal` still lands. Existing flows unaffected.

If any probe fails, report which and the observed output before patching.

---

## Self-Review (done at write time)

- **Spec coverage:** §Изменение 1 → Task 1; §Изменение 2 (Greg) → Tasks 2-3; §Изменение 3 (Payne/Gordon/Scrooge) → Tasks 4-6; §Изменение 4 (Jarvis) → Task 7; §Деплой → Task 9; §Верификация → Task 10. Local-verify (Task 8) added for safety. All spec sections covered.
- **Placeholders:** none — every edit has exact old/new strings; deploy commands are concrete (the only `<...>` are per-session ids enumerated in Task 9 Step 3, which is unavoidable runtime data, with the exact query to obtain them).
- **Consistency:** the marker `Два режима связи` is identical across all 7 edits and the verification greps. Continuation key `continuation:claude` matches `session-state.ts:17`.
