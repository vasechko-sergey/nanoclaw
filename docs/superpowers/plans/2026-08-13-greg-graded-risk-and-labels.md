# Greg: graded illness signal, labelled days, three numbers on the card face

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single fire/no-fire illness verdict with a graded number the owner can act on, start accumulating confirmed-healthy days so that number can eventually be validated, and put the three numbers he actually reads on the face of the card instead of behind a tap.

**Architecture:** Three independent deliverables, ordered so the ones that start a clock ship first. Phase 1 adds a one-tap daily state question and stores its answer as a label beside the existing subjective channel — every day it is not shipped is a day of labels not collected. Phase 2 computes an honest graded signal from data already stored: how far today's physiology sits from this person's own recent normal, in the direction illness moves, expressed as a percentile of his own history. Phase 3 carries that number through the existing `levels` frontmatter → host → iOS chain and surfaces stress, illness signal and recovery on the home entry.

**Tech Stack:** Bun (`groups/greg/scripts/`, `bun:test`), Node + vitest (`src/channels/ios-app/v2/`), SwiftUI + XCTest (`ios/JarvisApp/`). No new dependencies anywhere.

## Global Constraints

- **The number is not a probability and must never be presented as one.** A calibrated `P(illness within 2 days)` requires labelled positives; there is exactly one labelled episode and its `label` field is `null`. Every user-facing string says percentile or band, never percent-chance. This is the same rule that produced `## Factual discipline` in `groups/INSTRUCTIONS.md`.
- **No threshold, weight or band in this plan may be tuned to fire on 2026-08-10.** Bands come from the healthy distribution only. The plan's standing rule: pick from the alarm budget, never from the episodes.
- `groups/*` is gitignored. Greg's scripts and skills deploy by `scp` to `/home/nanoclaw/nanoclaw/agents/greg/`, not by `git pull`. Only `src/`, `ios/`, `shared/` and `docs/` are committed.
- Scripts under `agents/<folder>/scripts` are live-mounted — an `scp` is enough. **Instruction files (`CLAUDE.md`, `skills/*/SKILL.md`) need a rebirth**: `DELETE FROM session_state WHERE key LIKE 'continuation%'` on every greg session plus a container kill.
- Container tests are `bun:test`; host tests are vitest; iOS tests are XCTest. Never mix.
- Any iOS change bumps `CURRENT_PROJECT_VERSION` in `ios/JarvisApp/project.yml`, then `xcodegen generate` from `ios/JarvisApp/`, and the regenerated `.pbxproj` is committed.
- Verify greg scripts inside the real image, not just locally: `docker run --rm --entrypoint bun -v /home/nanoclaw/nanoclaw/agents/greg/scripts:/s:ro nanoclaw-agent-v2-16111809:latest test /s/analyze.test.js`.
- Commits end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `groups/greg/scripts/log-subjective.js` | gains `--state`, a closed four-value scale, written into `subjective.jsonl` | 1 |
| `groups/greg/scripts/log-subjective.test.js` | `--state` validation, both-optional guard | 1 |
| `groups/greg/scripts/analyze.js` | `mergeSubjective` carries state; `stateLoggedOn`; `illnessSignal`; `levels.illness` | 1, 2 |
| `groups/greg/scripts/analyze.test.js` | state merge, `illnessSignal` behaviour, band boundaries | 1, 2 |
| `groups/greg/skills/daily-cycle/SKILL.md` | asks how he woke, branches to free text, records the answer | 1 |
| `groups/greg/skills/evening-check/SKILL.md` | **new** — asks at 21:00 how the day went; asks and records, nothing else | 1 |
| `groups/greg/skills/index.md` | registers `evening-check` | 1 |
| `groups/greg/skills/sick-day/SKILL.md` | requires `label` when appending an episode | 1 |
| `groups/greg/CLAUDE.md` | data dictionary for `state` and the illness signal; the not-a-probability rule | 1, 2 |
| `groups/greg/skills/publish/SKILL.md` | writes `illness` into the `levels:` frontmatter line | 3 |
| `src/channels/ios-app/v2/profiles.ts` | `Levels.illness` + parser | 3 |
| `src/channels/ios-app/v2/profiles.test.ts` | parses `illness` | 3 |
| `src/channels/ios-app/v2/http-handler.ts:383-388` | serves `illness` | 3 |
| `ios/JarvisApp/Sources/JarvisApp/Models/StateModel.swift` | `Levels.illness` | 3 |
| `ios/JarvisApp/Sources/JarvisApp/Components/SummaryEntryView.swift` | three numbers on the home entry | 3 |
| `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift:114` | passes `levels` in | 3 |
| `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift` | entry rendering + decode | 3 |

**Deliberately out of scope, to be its own plan:** running a published algorithm (NightSignal / RHR-Diff) beside ours and logging both daily for a three-month comparison. It cannot be written without reading the paper's exact parameters, and it is harvested no earlier than November — it must not delay the two phases that start clocks. Write it as `docs/superpowers/plans/<date>-greg-estimator-bakeoff.md` after Phase 3 lands.

---

## Phase 1 — The daily label

Today a "healthy day" means "no episode was written", which is an assumption, not an observation. Four of the five recorded false alarms cluster on the July relocation week and nobody knows whether he actually felt bad then, which is why the plan records 5–7% as an upper bound rather than a rate. Two taps a day fix that, and they also produce the only series that could ever lead the sensors: days he feels off while the watch is quiet.

**Each question is about something already known when it is asked.** The morning card asks how he *woke* — not how the day will go, which nobody can answer at 09:00, and a guess recorded as an observation is worse than a gap because something will later be measured on it. The evening card asks how the day *went*, at 21:00, when it effectively has. The morning answer is also the one that pairs tightest with the data: every signal the detector runs on is measured during the night that just ended.

### Task 1: `--state` on the subjective log

**Files:**
- Modify: `groups/greg/scripts/log-subjective.js`
- Test: `groups/greg/scripts/log-subjective.test.js`

**Interfaces:**
- Consumes: `buildEntry(opts, now)` and `parseArgs(argv)` as they exist today.
- Produces: `SUBJECTIVE_STATES` (a `Set` of `"great" | "ok" | "off" | "bad"`) and `SUBJECTIVE_SCOPES` (a `Set` of `"morning" | "day"`) exported from `log-subjective.js`; `buildEntry` return object gains `state: string | null` and `scope: string | null`.

**Why two scopes.** A single "how was today?" asked in the morning is a question
nobody can answer — the day has not happened — and a garbage label is worse than
a missing one, because something will later be measured on it. So the scale is
asked twice, each time about something already known:

- `morning` — how he feels **on waking**, asked by the daily cycle. This is the
  one that pairs tightest with the data: every signal the detector runs on
  (resting pulse, morning HRV, respiratory rate, awake minutes, wrist
  temperature, sleep stages) is measured during the night that just ended, so
  the waking feeling is the human reading of exactly those numbers. It is also
  when a prodrome is usually first noticed.
- `day` — how the day went overall, asked at 21:00 when it effectively has.

Both attach to the same date. Neither requires a forecast.

- [ ] **Step 1: Write the failing tests**

Append to `groups/greg/scripts/log-subjective.test.js`:

```javascript
describe("--state", () => {
  it("records a morning state with no symptoms", () => {
    const e = buildEntry({ date: "2026-08-14", symptoms: null, state: "great", scope: "morning", note: null, temp: null });
    expect(e.state).toBe("great");
    expect(e.scope).toBe("morning");
    // null, not []: the morning card never asks about symptoms, and an empty
    // array here would read downstream as "asked, nothing reported".
    expect(e.symptoms).toBeNull();
  });

  it("rejects a state outside the scale", () => {
    expect(() => buildEntry({ date: "2026-08-14", symptoms: null, state: "нормально", scope: "morning", note: null, temp: null }))
      .toThrow(/unknown state/);
  });

  it("rejects a scope outside the two", () => {
    expect(() => buildEntry({ date: "2026-08-14", symptoms: null, state: "ok", scope: "evening", note: null, temp: null }))
      .toThrow(/unknown scope/);
  });

  it("requires a scope with a state — an unscoped label cannot be interpreted", () => {
    expect(() => buildEntry({ date: "2026-08-14", symptoms: null, state: "ok", scope: null, note: null, temp: null }))
      .toThrow(/--scope is required/);
  });

  it("still requires one of --symptoms or --state", () => {
    expect(() => buildEntry({ date: "2026-08-14", symptoms: null, state: null, scope: null, note: null, temp: null }))
      .toThrow(/--symptoms or --state/);
  });

  it("carries a state alongside symptoms", () => {
    const e = buildEntry({ date: "2026-08-14", symptoms: "soreThroat", state: "off", scope: "morning", note: null, temp: null });
    expect(e.state).toBe("off");
    expect(e.symptoms).toEqual(["soreThroat"]);
  });

  it("leaves state and scope null when only symptoms are given", () => {
    const e = buildEntry({ date: "2026-08-14", symptoms: "", state: null, scope: null, note: null, temp: null });
    expect(e.state).toBeNull();
    expect(e.scope).toBeNull();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd groups/greg/scripts && bun test log-subjective.test.js`
Expected: FAIL — `--symptoms is required (pass "" for none reported)` thrown where a state was given.

- [ ] **Step 3: Implement**

In `groups/greg/scripts/log-subjective.js`, add above `parseArgs`:

```javascript
// A closed four-point scale, asked as a one-tap card. It is closed for the same
// reason SYMPTOM_KEYS is: an ordinal label is only comparable across 90 days if
// every day used the same words. Free text would need an LLM mapping step every
// single day, and that step is where vocabulary drifts. «Норм» and «Отлично»
// are kept apart deliberately — an ordinary day and a good day are different
// evidence about the same body.
export const SUBJECTIVE_STATES = new Set(["great", "ok", "off", "bad"]);

// WHEN the answer is about. Asking "how was today?" in the morning is a request
// for a forecast, and a forecast recorded as an observation is worse than no
// label at all — something will be measured on it later.
//   morning — how he feels on waking. Contemporaneous with every overnight
//             signal the detector actually runs on, and the moment a prodrome
//             is usually first noticed.
//   day     — how the whole day went, asked at 21:00 when it effectively has.
export const SUBJECTIVE_SCOPES = new Set(["morning", "day"]);
```

In `parseArgs`, add `state: null, scope: null` to the defaults object and these branches beside the others:

```javascript
    else if (a === "--state") o.state = argv[++i];
    else if (a === "--scope") o.scope = argv[++i];
```

In `buildEntry`, replace the `--symptoms is required` guard with:

```javascript
  if (opts.symptoms === null && !opts.state) {
    throw new Error('one of --symptoms or --state is required (pass --symptoms "" for none reported)');
  }
  if (opts.state && !SUBJECTIVE_STATES.has(opts.state)) {
    throw new Error(
      `unknown state: ${opts.state}\nthe scale is fixed — pick from:\n  ${[...SUBJECTIVE_STATES].join(", ")}`,
    );
  }
  // An unscoped label is uninterpretable: "ok" could mean the night or the day,
  // and the two answer different questions about different halves of the row.
  if (opts.state && !opts.scope) {
    throw new Error(`--scope is required with --state — one of: ${[...SUBJECTIVE_SCOPES].join(", ")}`);
  }
  if (opts.scope && !SUBJECTIVE_SCOPES.has(opts.scope)) {
    throw new Error(
      `unknown scope: ${opts.scope}\npick from:\n  ${[...SUBJECTIVE_SCOPES].join(", ")}`,
    );
  }
```

Change the `keys` line to tolerate an absent `--symptoms`:

```javascript
  const keys = (opts.symptoms ?? "").split(",").map((s) => s.trim()).filter(Boolean);
```

Change the `symptoms` line of the returned object so an unasked question is not
recorded as an answered one — the morning card sends `--state` with no
`--symptoms` at all, and an empty array there would read downstream as "asked
and nothing reported":

```javascript
    symptoms: opts.symptoms === null ? null : [...new Set(keys)],
```

And add both new fields after it:

```javascript
    state: opts.state ?? null,
    scope: opts.state ? opts.scope : null,
```

Update the two existing tests that assert `symptoms` on a symptom-only entry if
they pass `symptoms: null` — they must now expect `null`, not `[]`. Tests that
pass `symptoms: ""` keep expecting `[]`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd groups/greg/scripts && bun test`
Expected: PASS, and every pre-existing test in both files still passes.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-08-13-greg-graded-risk-and-labels.md
git commit -m "docs(plan): daily state label, graded illness signal, card face"
```

`groups/` is gitignored, so this commit carries the plan only. Deploy the script:

```bash
scp groups/greg/scripts/log-subjective.js groups/greg/scripts/log-subjective.test.js root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/scripts/
```

---

### Task 2: The state reaches the row, and Greg can tell whether he already asked

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (`loadSubjective`, `mergeSubjective`, normal-mode result)
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: `loadSubjective(path)` returning a `Map<date, entry>`, `mergeSubjective(rows, byDate)`.
- Produces: entries gain `morningState` / `dayState`; rows gain `morningState` / `dayState`; `stateLoggedOn(byDate, date, scope): boolean` exported — reads the subjective log, not the rows; normal-mode output gains `subjective_state: {date: string, morning: boolean, day: boolean}` keyed on the owner's calendar date.

**The load is now field-wise, not record-wise.** `loadSubjective` currently does
`byDate.set(r.date, {...})` — last line per date replaces the whole record. That
was right when a second line could only be a correction. It is wrong the moment
two lines answer *different questions*: the 21:00 answer would silently erase the
09:00 one, and the labels this whole phase exists to collect would quietly halve.
Each line now updates only the fields it actually carries.

- [ ] **Step 1: Write the failing tests**

Append to `groups/greg/scripts/analyze.test.js`:

```javascript
describe("daily state label", () => {
  const write = (dir, lines) => {
    const p = `${dir}/subjective.jsonl`;
    writeFileSync(p, lines.map((l) => JSON.stringify(l)).join("\n"));
    return p;
  };

  it("keeps the morning and the evening answers apart", () => {
    const dir = mkdtempSync(join(tmpdir(), "subj-"));
    const p = write(dir, [
      { date: "2026-08-14", symptoms: null, state: "ok", scope: "morning" },
      { date: "2026-08-14", symptoms: null, state: "off", scope: "day" },
    ]);
    const e = loadSubjective(p).get("2026-08-14");
    expect(e.morningState).toBe("ok");
    expect(e.dayState).toBe("off");
  });

  it("lets a later line correct the same scope", () => {
    const dir = mkdtempSync(join(tmpdir(), "subj-"));
    const p = write(dir, [
      { date: "2026-08-14", symptoms: null, state: "ok", scope: "morning" },
      { date: "2026-08-14", symptoms: null, state: "bad", scope: "morning" },
    ]);
    expect(loadSubjective(p).get("2026-08-14").morningState).toBe("bad");
  });

  it("does not let a state-only line erase symptoms logged earlier that day", () => {
    const dir = mkdtempSync(join(tmpdir(), "subj-"));
    const p = write(dir, [
      { date: "2026-08-14", symptoms: ["fever"], bodyTemperature: 38.1 },
      { date: "2026-08-14", symptoms: null, state: "off", scope: "day" },
    ]);
    const e = loadSubjective(p).get("2026-08-14");
    expect(e.symptoms).toEqual(["fever"]);
    expect(e.bodyTemperature).toBe(38.1);
    expect(e.dayState).toBe("off");
  });

  it("merges both labels onto the matching row", () => {
    const rows = [{ date: "2026-08-13" }, { date: "2026-08-14" }];
    mergeSubjective(rows, new Map([["2026-08-14",
      { symptoms: [], bodyTemperature: null, note: null, morningState: "ok", dayState: "off" }]]));
    expect(rows[1].morningState).toBe("ok");
    expect(rows[1].dayState).toBe("off");
    expect(rows[0].morningState).toBeUndefined();
  });

  it("reports per scope whether an answer already exists", () => {
    // Deliberately no health_days row anywhere in sight: on the morning path
    // the phone has often not uploaded yet, and the answer must still count.
    const logged = new Map([["2026-08-14", { morningState: "ok", dayState: null }]]);
    expect(stateLoggedOn(logged, "2026-08-14", "morning")).toBe(true);
    expect(stateLoggedOn(logged, "2026-08-14", "day")).toBe(false);
    expect(stateLoggedOn(logged, "2026-01-01", "morning")).toBe(false);
  });
});
```

Add `stateLoggedOn` and `loadSubjective` to the import list at the top of
`analyze.test.js`, and `writeFileSync` / `mkdtempSync` / `tmpdir` / `join` if the
file does not already import them for its other filesystem tests.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd groups/greg/scripts && bun test analyze.test.js`
Expected: FAIL — `stateLoggedOn is not a function`, and `morningState` undefined where `"ok"` is expected.

- [ ] **Step 3: Implement the field-wise load**

Replace the body of the loop in `loadSubjective`:

```javascript
    if (!r || !r.date) continue;
    // Field-wise, not record-wise. Two lines a day is now the normal case —
    // the 09:00 card and the 21:00 card answer different questions — so a
    // wholesale replace would silently drop whichever came first. Each line
    // updates only what it carries; last-wins still applies per field, which
    // is what keeps "a correction is just another append" true.
    const prev = byDate.get(r.date) ?? {
      symptoms: [], bodyTemperature: null, note: null,
      morningState: null, dayState: null, asked_at: null,
    };
    if (Array.isArray(r.symptoms)) {
      prev.symptoms = r.symptoms.filter((k) => SYMPTOM_KEYS.has(k));
    }
    if (typeof r.bodyTemperature === "number") prev.bodyTemperature = r.bodyTemperature;
    if (typeof r.note === "string") prev.note = r.note;
    if (r.state && r.scope === "morning") prev.morningState = r.state;
    if (r.state && r.scope === "day") prev.dayState = r.state;
    if (r.asked_at) prev.asked_at = r.asked_at;
    byDate.set(r.date, prev);
```

In `mergeSubjective`, after the `if (s.note) r.subjectiveNote = s.note;` line:

```javascript
    // Labels, not measurements: neither enters METRICS and neither scores.
    // They exist so that in three months "healthy day" is an observation
    // instead of the absence of an episode.
    if (s.morningState) r.morningState = s.morningState;
    if (s.dayState) r.dayState = s.dayState;
```

Add below `mergeSubjective`:

```javascript
// Whether that scope already carries an answer for the date. A one-tap card is
// cheap to send and therefore easy to send twice.
//
// Reads the subjective log, NOT the rows. The answer lands in subjective.jsonl
// the moment he taps, while a `health_days` row for today exists only after the
// phone has uploaded. On the morning path — the one this whole feature is built
// around — the row is routinely absent, and a row-anchored check would report
// "never asked" about a question just answered and ask it again.
export function stateLoggedOn(byDate, date, scope) {
  const e = byDate.get(date);
  if (!e) return false;
  return Boolean(scope === "morning" ? e.morningState : e.dayState);
}
```

In the normal-mode `result` object in the CLI block, beside `ask_subjective`:

```javascript
      // What he has answered for TODAY — keyed on the owner's calendar date, not
      // on the newest row. Those differ whenever the phone has not uploaded yet,
      // and keying on the row would have the morning card asking "already
      // answered?" about yesterday and then skipping itself.
      subjective_state: (() => {
        const today = ownerToday();
        return {
          date: today,
          morning: stateLoggedOn(subjective, today, "morning"),
          day: stateLoggedOn(subjective, today, "day"),
        };
      })(),
```

Both fields are booleans, and the skill reads them as booleans. `subjective` is
the map already in hand from `loadSubjective(opts.subjectiveLog)` earlier in the
block; `ownerToday()` reads `OWNER_TZ` and is used elsewhere in the same block.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd groups/greg/scripts && bun test`
Expected: PASS.

- [ ] **Step 5: Verify against the live database**

```bash
scp groups/greg/scripts/analyze.js root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/scripts/
ssh root@148.253.211.164 "cp /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/health.db /tmp/h.db && chmod 666 /tmp/h.db && docker run --rm --entrypoint bun -v /home/nanoclaw/nanoclaw/agents/greg/scripts:/s:ro -v /tmp:/w nanoclaw-agent-v2-16111809:latest /s/analyze.js /w/h.db | head -20"
```

Expected: valid JSON, `subjective_state` with today's date and both `morning` and `day` `false` (nothing has been logged with a state yet), `n_days: 98`.

- [ ] **Step 6: Commit the plan progress**

```bash
git commit --allow-empty -m "chore(greg): daily state label reaches the row (scripts are scp-deployed)"
```

---

### Task 3: Greg asks twice a day, one tap each, never about the future

**Files:**
- Modify: `groups/greg/skills/daily-cycle/SKILL.md`
- Create: `groups/greg/skills/evening-check/SKILL.md`
- Modify: `groups/greg/skills/index.md`
- Modify: `groups/greg/skills/sick-day/SKILL.md`
- Modify: `groups/greg/CLAUDE.md`

**Interfaces:**
- Consumes: `subjective_state` (`{date, morning, day}`) from normal-mode `analyze.js` output; `ask_user_question` MCP tool (`container/agent-runner/src/mcp-tools/interactive.ts:37`) with `{title, question, options, timeout}`, options as `{label, value}`; `schedule_task` MCP tool (`container/agent-runner/src/mcp-tools/scheduling.ts:78`) with `{prompt, processAfter, recurrence}`, cron evaluated in the owner's timezone; `scripts/log-subjective.js --state --scope`.
- Produces: nothing programmatic — instruction text plus one recurring task.

- [ ] **Step 1: Add the morning question to `daily-cycle/SKILL.md`**

Insert as a numbered step immediately after the step that sends the morning brief:

```markdown
### Спроси, как он проснулся — одним касанием

Пропусти шаг, если `subjective_state.morning` — `true`: на сегодня уже ответил.

**Спрашивай про СЕЙЧАС, а не про день.** Утром он не знает, каким будет день,
и ответ на такой вопрос был бы догадкой, записанной как наблюдение. А «как
проснулся» — это ещё и человеческое прочтение ровно тех чисел, на которых
работает детектор: пульс покоя, утренняя вариабельность, дыхание, фазы сна —
всё измерено этой ночью.

Вызови `ask_user_question`:

- `title`: «Как проснулся?»
- `question`: «Про сейчас, не про день. Одно касание.»
- `options`: `[{label: "Отлично", value: "great"}, {label: "Норм", value: "ok"}, {label: "Так себе", value: "off"}, {label: "Плохо", value: "bad"}]`
- `timeout`: `90`

**Таймаут — не ответ.** Вызов вернёт ошибку, если он не нажал за 90 секунд.
Это нормально и не значит ничего: карточка осталась в чате, и нажатие придёт
позже обычным сообщением. Не переспрашивай, не додумывай, не записывай ничего.
Продолжай цикл.

Когда ответ есть — сразу запиши:

    bun scripts/log-subjective.js --state <value> --scope morning

**Развилка.** Если ответ `off` или `bad` — спроси текстом одним сообщением:
«Что именно? Опиши как есть.» Его ответ отобрази на `SYMPTOM_KEYS` и допиши
той же командой с `--symptoms` и `--note` (сырая фраза обязательна — в списке
может не быть слова для того, что он сказал). Если `great` или `ok` — больше
ничего не спрашивай.
```

- [ ] **Step 2: Add the late-answer rule to `daily-cycle/SKILL.md`**

Append to the same section:

```markdown
**Ответ, пришедший позже.** Нажатие после таймаута приходит отдельным
сообщением с полями `questionId` и `selectedOption`. Увидев такое — запиши его
с тем `--scope`, к которому относился заданный вопрос. Дату руками не
подставляй: скрипт возьмёт сегодняшнюю по часовому поясу владельца.
```

- [ ] **Step 3: Create the evening check skill**

Create `groups/greg/skills/evening-check/SKILL.md`:

```markdown
---
name: evening-check
description: Вечером спросить одним касанием, как прошёл день, и записать метку. Ничего не считает и ничего не докладывает.
---

# Вечерняя отметка

Один вопрос, одно касание, никакого анализа. Смысл — накопить дни, про которые
ИЗВЕСТНО, что человек был здоров. Сейчас «здоровый день» означает «эпизод не
записан», то есть предположение; через три месяца это должно означать
наблюдение.

Пропусти, если `subjective_state.day` — `true`: уже ответил.

Вызови `ask_user_question`:

- `title`: «Как прошёл день?»
- `question`: «В целом, одним касанием.»
- `options`: `[{label: "Отлично", value: "great"}, {label: "Норм", value: "ok"}, {label: "Так себе", value: "off"}, {label: "Плохо", value: "bad"}]`
- `timeout`: `120`

Записывай:

    bun scripts/log-subjective.js --state <value> --scope day

Если `off` или `bad` — один уточняющий вопрос текстом и дозапись с
`--symptoms`/`--note`, как в утреннем цикле.

**Не пиши сводку, не считай `analyze.js`, не докладывай находки.** Это не
второй дневной цикл. Вопрос, ответ, запись — и всё. Если он не ответил за
таймаут, молчи: нажатие придёт позже само.

**Не переноси вопрос на утро.** «Как вчера?» через двенадцать часов и сон — это
уже воспоминание, а не наблюдение.
```

- [ ] **Step 4: Register the skill**

Add a line to `groups/greg/skills/index.md` in the same format as the existing entries:

```markdown
- `evening-check` — вечерняя отметка самочувствия одним касанием (21:00).
```

- [ ] **Step 5: Schedule it**

Ask Greg, in a normal message, to schedule it. He calls `schedule_task` with:

- `prompt`: `«Запусти скилл evening-check.»`
- `processAfter`: the next `21:00:00` in naive local form, e.g. `2026-08-14T21:00:00`
- `recurrence`: `0 21 * * *`

Cron is evaluated in the owner's timezone, so no offset arithmetic is needed.

Scheduled tasks are **not** in the central DB — they are rows in the session's
own `inbound.db` (`messages_in`, with `process_after` and `recurrence` columns),
which the host sweep fans out. Confirm across Greg's sessions:

```bash
ssh root@148.253.211.164 "cd /home/nanoclaw/nanoclaw && for d in data/v2-sessions/greg/*/; do sudo -u nanoclaw pnpm exec tsx scripts/q.ts \$d/inbound.db \"SELECT recurrence || '  ' || process_after || '  ' || substr(content,1,60) FROM messages_in WHERE recurrence IS NOT NULL AND content LIKE '%evening-check%'\"; done"
```

Expected: one row, `0 21 * * *`, with the first run at 21:00 owner-local.

- [ ] **Step 6: Require a label on every episode in `sick-day/SKILL.md`**

Find the instruction that appends to `episodes.jsonl` and add beneath it:

```markdown
**`label` обязателен.** Не оставляй `null`. Ожидаемая величина сигнала разная
у разных причин, и без метки нельзя отличить «метод промолчал» от «болезнь
была тихая». Значения: `cold`, `flu`, `gi` (ЖКТ), `food` (отравление),
`overtraining`, `sleep_debt`, `other`. Не знаешь — спроси его прямо, одним
вопросом с этими вариантами.
```

- [ ] **Step 7: Add the data dictionary entry to `groups/greg/CLAUDE.md`**

Add to the data-dictionary bullet list:

```markdown
- **`morningState` / `dayState`** — что он сам сказал: `great` / `ok` / `off` /
  `bad`. `morningState` — про пробуждение, `dayState` — про весь день, спрошено
  вечером. Разделены потому, что утром человек не может знать, каким будет
  день, а утреннее самочувствие не обязано дожить до вечера. **Это метки, а не
  измерения**: они не входят в `METRICS`, ничего не детектируют и не участвуют
  в вердикте. Их смысл — накопить дни, про которые ИЗВЕСТНО, что он был
  здоров, чтобы через месяцы честно измерить, опережает ли самочувствие
  датчики. Не выдавай их за состояние на сейчас: это его слова в тот момент.
  `morningState` ближе всех к ночным датчикам — пульс покоя, вариабельность,
  дыхание и фазы сна измерены той же ночью.
```

- [ ] **Step 8: Deploy and rebirth**

Instruction files need a rebirth — scripts are live-mounted, `SKILL.md` and `CLAUDE.md` are not.

```bash
scp -r groups/greg/skills groups/greg/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/
```

Then, on the VDS, wipe continuation rows for every greg session and kill any running container:

```bash
ssh root@148.253.211.164 "cd /home/nanoclaw/nanoclaw && for d in data/v2-sessions/greg/*/; do sudo -u nanoclaw pnpm exec tsx scripts/q.ts \$d/outbound.db \"DELETE FROM session_state WHERE key LIKE 'continuation%'\"; done && docker ps --filter name=greg -q | xargs -r docker kill"
```

- [ ] **Step 9: Verify both questions render and neither erases the other**

Ask Greg to run the daily cycle. Expected on the phone: an action card «Как проснулся?» with four buttons. Tap «Норм».

Then ask him to run `evening-check`. Expected: a second card «Как прошёл день?». Tap «Так себе», then answer the follow-up in text.

```bash
ssh root@148.253.211.164 "tail -3 /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/subjective.jsonl"
```

Expected: two lines for today — one `{"state":"ok","scope":"morning"}`, one `{"state":"off","scope":"day"}` — and the date is today in `Asia/Colombo`. Then confirm the loader keeps both:

```bash
ssh root@148.253.211.164 "docker run --rm --entrypoint bun -v /home/nanoclaw/nanoclaw/agents/greg/scripts:/s:ro -v /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health:/h:ro nanoclaw-agent-v2-16111809:latest -e \"
import { loadSubjective } from '/s/analyze.js';
console.log(JSON.stringify([...loadSubjective('/h/subjective.jsonl')].slice(-2)));\""
```

Expected: the newest date carries **both** `morningState` and `dayState`. If either is `null`, the field-wise load of Task 2 did not deploy — that is the failure this whole task is shaped around.

- [ ] **Step 10: Commit**

```bash
git commit --allow-empty -m "feat(greg): ask twice a day about what is already known, label every episode"
```

---

### Task 3b: a late answer must reach the agent, and must say what it answers

**Added mid-execution, 2026-08-13.** Not in the original plan — Task 3's review
traced a runtime defect that made Task 3's own central instruction false. Brief
and report at `.superpowers/sdd/2026-08-13-greg-graded-risk-and-labels/`.
Shipped in `39bc62f2`, reviewed clean.

`ask_user_question` is a blocking tool with a timeout. The host handled a late
tap correctly — it wrote the answer into the session's `inbound.db` and woke the
container. The container then threw it away: `poll-loop.ts` drops every
`kind: 'system'` row that is not a workout event, at both the initial-batch and
the mid-turn filter. The row was discarded on every poll, **never marked
completed, and stayed pending forever**. Nothing errored, nothing logged. The
container woke, did nothing, exited.

For these two cards that is not an edge case. The morning card is sent by a
headless 09:00 job with a 90-second timeout; the person is usually not holding
the phone in that window, so **the common path was the broken one** and the
labelling this phase exists for would have collected almost nothing.

Two changes, both reviewed:

- **The container lets an unclaimed question response through.** A registry of
  in-flight questionIds (`mcp-tools/awaiting-questions.ts`, a standalone module
  so no import cycle forms) decides ownership: whoever is awaiting a questionId
  owns it, and only rows nobody awaits become agent-facing. A time-based
  heuristic was rejected — it reintroduces the same race with a fuzzier edge.
  The predicate treats unparseable content as "not a question response" rather
  than throwing, because a bad row killing the poll loop would be worse than the
  bug being fixed.
- **The row now carries the card's `title`.** `questionId` is
  `msg-<epoch>-<random>` and encodes nothing, and Greg's daily cycle ends with
  `/clear`, so an agent receiving a late answer had no way to tell which question
  it answered — and both cards can be outstanding at once. `pending_questions`
  already stored the title; it simply was not passed on. The formatter renders
  the row readably instead of as raw JSON, without which the answer reached the
  agent as `<system_response action="unknown">null</system_response>` — arriving
  and still saying nothing.

`title` is appended as a trailing key on purpose: the in-flight poll finds its
row with a SQL `LIKE` on `%"questionId":"<id>"%`, so anything inserted before
that key would break the normal in-time path while fixing the late one.

---

## Phase 2 — The graded number

What can be built honestly today is not a probability. It is: how far today's physiology sits from this person's own recent normal, counting only movement in the direction illness goes, expressed as a percentile of his own past. That needs zero positive examples — it is calibrated entirely on his healthy history, of which there are 79 days.

Measured before writing this, on the one labelled episode: this number reads about the 80th percentile two days before onset and mid-pack the day before. It is weak. It is shipped anyway because a graded number is the right *shape* for load decisions, and because it is the thing the Phase 1 labels will eventually be able to validate or kill.

### Task 4: `illnessSignal`

**Files:**
- Modify: `groups/greg/scripts/analyze.js`
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: the module-level `median(xs)` helper already in `analyze.js`.
- Produces: `illnessSignalScore(rows, i): number | null` and `illnessSignal(rows): {score, pct, band, n} | null`, both exported. `band` is `"calm" | "elevated" | "high"`.

- [ ] **Step 1: Write the failing tests**

Append to `groups/greg/scripts/analyze.test.js`:

```javascript
describe("illnessSignal", () => {
  // A flat series with a controllable last day: 40 quiet days, then whatever
  // the caller wants on top.
  function series(n, over = {}) {
    const rows = [];
    for (let i = 0; i < n; i++) {
      const d = new Date(Date.UTC(2026, 5, 1) + i * 86400000).toISOString().slice(0, 10);
      rows.push({
        date: d, restingHeartRate: 55 + (i % 2), hrvMorning: 45 - (i % 2),
        respiratoryRate: 15 + (i % 2) * 0.1, awakeMin: 20 + (i % 2),
        wristTempDeviation: 35.5, spo2Min: 95, sleepHours: 7.5,
        deepMin: 60, remMin: 90, heartRate: 65,
      });
    }
    Object.assign(rows[rows.length - 1], over);
    return rows;
  }

  it("is null before there is enough baseline", () => {
    expect(illnessSignal(series(5))).toBeNull();
  });

  it("scores an ordinary day near zero", () => {
    const s = illnessSignal(series(45));
    expect(s.score).toBeLessThan(1);
    expect(s.band).toBe("calm");
  });

  it("scores a day that moves toward illness far above an ordinary one", () => {
    const quiet = illnessSignalScore(series(45), 44);
    const sick = illnessSignalScore(
      series(45, { restingHeartRate: 68, hrvMorning: 28, respiratoryRate: 17, awakeMin: 60 }), 44);
    expect(sick).toBeGreaterThan(quiet * 5);
  });

  it("ignores movement away from illness", () => {
    // A resting pulse far BELOW baseline is not a concern and must not score.
    const s = illnessSignalScore(series(45, { restingHeartRate: 40 }), 44);
    expect(s).toBeLessThan(1);
  });

  it("returns a null percentile when history is too short to rank against", () => {
    const s = illnessSignal(series(25));
    expect(s.score).not.toBeNull();
    expect(s.pct).toBeNull();
    expect(s.band).toBeNull();
  });

  it("puts a clearly abnormal day at the top of its own history", () => {
    const s = illnessSignal(series(60, { restingHeartRate: 70, hrvMorning: 25, respiratoryRate: 18, awakeMin: 80 }));
    expect(s.pct).toBeGreaterThanOrEqual(90);
    expect(s.band).toBe("high");
  });

  it("is null on a day with too few features present", () => {
    const rows = series(45);
    const last = rows[rows.length - 1];
    for (const f of ["hrvMorning", "respiratoryRate", "awakeMin", "wristTempDeviation", "spo2Min", "deepMin", "remMin"]) {
      delete last[f];
    }
    expect(illnessSignalScore(rows, rows.length - 1)).toBeNull();
  });
});
```

Add `illnessSignal` and `illnessSignalScore` to the import list at the top of `analyze.test.js`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd groups/greg/scripts && bun test analyze.test.js`
Expected: FAIL — `illnessSignal is not a function`.

- [ ] **Step 3: Implement**

Add to `groups/greg/scripts/analyze.js`, below `buildDerived`:

```javascript
// A graded "how far from your own normal, toward illness" number.
//
// NOT a probability. A calibrated P(illness) needs labelled positives and there
// is one labelled episode, so any percentage here would be invented. What this
// IS: today's robust z across ten features, counting only deviations in the
// direction illness moves, ranked against this person's own recent history.
// That calibrates on healthy days alone, of which there are plenty.
//
// Measured on the one labelled episode before shipping: ~80th percentile two
// days before onset, mid-pack the day before. Weak. It ships as a load-decision
// hint, not as a forecast, and the daily morning/day labels are what will
// eventually confirm or kill it.
const ILLNESS_FEATURES = [
  ["restingHeartRate", +1], ["hrvMorning", -1], ["respiratoryRate", +1],
  ["awakeMin", +1], ["wristTempDeviation", +1], ["spo2Min", -1],
  ["sleepHours", -1], ["deepMin", -1], ["remMin", -1], ["heartRate", +1],
];
const ILLNESS_BASELINE_DAYS = 14;   // same window the sick-day rule compares against
const ILLNESS_MIN_BASE = 8;         // per-feature: fewer readings than this and the MAD is noise
const ILLNESS_MIN_FEATURES = 5;     // half the list; below that the mean is one sensor's opinion
const ILLNESS_PCT_WINDOW = 60;      // days of his own history to rank today against
const ILLNESS_MIN_HISTORY = 20;     // fewer scored days than this and a percentile is theatre

function robustZ(today, base) {
  const vals = base.filter((v) => typeof v === "number" && Number.isFinite(v));
  if (typeof today !== "number" || !Number.isFinite(today) || vals.length < ILLNESS_MIN_BASE) return null;
  const m = median(vals);
  const dev = median(vals.map((v) => Math.abs(v - m)));
  // 1.4826 puts MAD on the same scale as a standard deviation.
  return (today - m) / (1.4826 * (dev || 1e-9));
}

export function illnessSignalScore(rows, i) {
  const base = rows.slice(Math.max(0, i - ILLNESS_BASELINE_DAYS), i);
  if (base.length < 10) return null;
  const zs = [];
  for (const [f, dir] of ILLNESS_FEATURES) {
    const z = robustZ(rows[i][f], base.map((r) => r[f]));
    if (z !== null) zs.push(z * dir);
  }
  if (zs.length < ILLNESS_MIN_FEATURES) return null;
  // Squared so one large move outweighs several small ones; only the concerning
  // side counts; averaged so a night missing wrist temperature is not scored
  // lower for missing it.
  const sum = zs.reduce((a, z) => a + Math.max(0, z) ** 2, 0);
  return Math.round((sum / zs.length) * 100) / 100;
}

export function illnessSignal(rows) {
  const i = rows.length - 1;
  if (i < 0) return null;
  const today = illnessSignalScore(rows, i);
  if (today === null) return null;

  const history = [];
  for (let j = Math.max(0, i - ILLNESS_PCT_WINDOW); j < i; j++) {
    const s = illnessSignalScore(rows, j);
    if (s !== null) history.push(s);
  }
  if (history.length < ILLNESS_MIN_HISTORY) return { score: today, pct: null, band: null, n: history.length };

  const pct = Math.round((history.filter((s) => s < today).length / history.length) * 100);
  // Bands come from his own distribution and nothing else: by construction
  // "elevated" happens one day in four and "high" one in ten, whatever his
  // physiology does. No episode was consulted.
  const band = pct >= 90 ? "high" : pct >= 75 ? "elevated" : "calm";
  return { score: today, pct, band, n: history.length };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd groups/greg/scripts && bun test`
Expected: PASS.

- [ ] **Step 5: Sanity-check the distribution on live data**

```bash
scp groups/greg/scripts/analyze.js root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/scripts/
ssh root@148.253.211.164 "cp /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/health.db /tmp/h.db && chmod 666 /tmp/h.db && docker run --rm --entrypoint bun -v /home/nanoclaw/nanoclaw/agents/greg/scripts:/s:ro -v /tmp:/w nanoclaw-agent-v2-16111809:latest -e \"
import { loadRows, illnessSignal, illnessSignalScore } from '/s/analyze.js';
const rows = loadRows('/w/h.db');
console.log('today', JSON.stringify(illnessSignal(rows)));
for (const d of ['2026-08-08','2026-08-09','2026-08-10','2026-08-11']) {
  const i = rows.findIndex(r => r.date === d);
  console.log(d, illnessSignalScore(rows, i));
}\""
```

Expected: onset day 2026-08-10 scores clearly above 08-08 and 08-09. Record the four numbers in the plan under this task. **If onset day does NOT come out highest of the four, stop and report** — the aggregate is wrong, not the data.

- [ ] **Step 6: Commit**

```bash
git commit --allow-empty -m "feat(greg): graded illness signal as a percentile of his own history"
```

---

### Task 5: The signal reaches `levels`

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (`computeLevels` + the normal-mode call site)
- Modify: `groups/greg/CLAUDE.md`
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: `illnessSignal(rows)` from Task 4; `computeLevels(rows, load, readiness, sick)` as it exists.
- Produces: `computeLevels(rows, load, readiness, sick, illness)` — a fifth parameter, defaulting to `null`; its return object gains `illness: number | null`. Normal-mode output gains a top-level `illness` object.

- [ ] **Step 1: Write the failing tests**

Append to the `describe("illnessSignal")` block in `analyze.test.js`:

```javascript
  it("puts the percentile into levels and leaves it null when unknown", () => {
    const rows = [{ date: "2026-08-14", recovery: 0.2, hrv: 40, restingHeartRate: 55, sleepHours: 7 }];
    const load = { ratio: 1.0 };
    expect(computeLevels(rows, load, null, null, { score: 3.2, pct: 88, band: "elevated", n: 60 }).illness).toBe(88);
    expect(computeLevels(rows, load, null, null, null).illness).toBeNull();
    expect(computeLevels(rows, load, null, null, { score: 1, pct: null, band: null, n: 4 }).illness).toBeNull();
  });
```

Add `computeLevels` to the import list if it is not already there.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd groups/greg/scripts && bun test analyze.test.js`
Expected: FAIL — `undefined` where `88` is expected.

- [ ] **Step 3: Implement**

Change the signature of `computeLevels`:

```javascript
export function computeLevels(rows, load, readiness, sick = null, illness = null) {
```

and its return object, after `readiness`:

```javascript
    // Percentile of his own history, never a percent chance — see illnessSignal.
    illness: illness && typeof illness.pct === "number" ? illness.pct : null,
```

In the normal-mode CLI block, score it once before `computeLevels` is called and thread it through:

```javascript
    const illness = illnessSignal(rows);
    const levels = computeLevels(rows, load, readiness, sick, illness);
```

Then use that `levels` local in the result object instead of the inline call, and add the full object beside it:

```javascript
      illness,
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd groups/greg/scripts && bun test`
Expected: PASS.

- [ ] **Step 5: Add the rule that stops it becoming a probability**

Add to `groups/greg/CLAUDE.md`, in the data dictionary:

```markdown
- **`illness.pct` / `levels.illness`** — насколько сегодняшняя физиология
  необычна **относительно твоей же истории**, в сторону болезни. Это
  **процентиль**, не вероятность. «82» значит «необычнее, чем 82% твоих
  последних дней», и НЕ значит «82% шанс заболеть». Называть это
  вероятностью, шансом или риском в процентах — запрещено: калибровать
  вероятность не на чем, размеченный эпизод один. Говори «выше обычного»,
  «спокойно», или называй процентиль вслух как процентиль. `band`: `calm` /
  `elevated` / `high` — по построению `elevated` выпадает раз в четыре дня,
  а `high` раз в десять, поэтому сам по себе он ничего не доказывает.
```

- [ ] **Step 6: Deploy, rebirth, verify**

```bash
scp groups/greg/scripts/analyze.js groups/greg/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/
```

Rebirth as in Task 3 Step 5 (CLAUDE.md changed). Then:

```bash
ssh root@148.253.211.164 "docker run --rm --entrypoint bun -v /home/nanoclaw/nanoclaw/agents/greg/scripts:/s:ro -v /tmp:/w nanoclaw-agent-v2-16111809:latest /s/analyze.js /w/h.db | grep -A 6 '\"levels\"'"
```

Expected: `levels` contains five keys including `illness`, and the top-level `illness` object carries `score`, `pct`, `band`, `n`.

- [ ] **Step 7: Commit**

```bash
git commit --allow-empty -m "feat(greg): thread the illness signal into levels"
```

---

## Phase 3 — On the face, not behind a tap

The numbers already exist and are already honest. What is wrong is that the home screen shows «Сводка · N дел» and everything else costs a tap, so they go unread. A number nobody reads is worth zero regardless of the mathematics under it.

### Task 6: The host carries `illness`

**Files:**
- Modify: `src/channels/ios-app/v2/profiles.ts:5-10` (the `Levels` interface) and `:27-38` (`parseInlineLevels`)
- Modify: `src/channels/ios-app/v2/http-handler.ts:383-388`
- Test: `src/channels/ios-app/v2/profiles.test.ts`

**Interfaces:**
- Consumes: `levels: {energy: N, stress: N, recovery: N, readiness: N}` frontmatter as written by Greg's publish skill.
- Produces: `Levels` gains `illness: number | null`; `GET /ios/state` `levels` object gains `illness`.

- [ ] **Step 1: Write the failing test**

In `src/channels/ios-app/v2/profiles.test.ts`, change the fixture's `levels:` line to include the new key and assert it:

```typescript
levels: {energy: 72, stress: 34, recovery: 81, readiness: 68, illness: 55}
```

```typescript
  it('parses the illness percentile and defaults it to null when absent', () => {
    const p = parseProfile('greg', `---\nlevels: {energy: 72, stress: 34, recovery: 81, readiness: 68, illness: 55}\n---\n`);
    expect(p.levels).toEqual({ energy: 72, stress: 34, recovery: 81, readiness: 68, illness: 55 });

    const old = parseProfile('greg', `---\nlevels: {energy: 72, stress: 34, recovery: 81, readiness: 68}\n---\n`);
    expect(old.levels).toEqual({ energy: 72, stress: 34, recovery: 81, readiness: 68, illness: null });
  });
```

The second assertion is the one that matters: a `health.md` written before this ships must still parse.

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm vitest run src/channels/ios-app/v2/profiles.test.ts`
Expected: FAIL — received object has no `illness` key.

- [ ] **Step 3: Implement**

In `profiles.ts`, add to the `Levels` interface:

```typescript
  illness: number | null;
```

In `parseInlineLevels`, add the lookup and include it in both the empty check and the return:

```typescript
  const energy = num('energy'),
    stress = num('stress'),
    recovery = num('recovery'),
    readiness = num('readiness'),
    illness = num('illness');
  if (energy === null && stress === null && recovery === null && readiness === null && illness === null) return null;
  return { energy, stress, recovery, readiness, illness };
```

In `http-handler.ts`, add to the `levels` object:

```typescript
        illness: greg?.levels?.illness ?? null,
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test` and `pnpm exec tsc --noEmit`
Expected: PASS, 0 type errors. If `tsc` reports a missing property on a stale declaration file, run `pnpm run build` first — `shared/` `.d.ts` artifacts shadow their sources.

- [ ] **Step 5: Commit**

```bash
git add src/channels/ios-app/v2/profiles.ts src/channels/ios-app/v2/profiles.test.ts src/channels/ios-app/v2/http-handler.ts
git commit -m "feat(ios-app): carry the illness percentile through levels"
```

---

### Task 7: Greg publishes it

**Files:**
- Modify: `groups/greg/skills/publish/SKILL.md:21` and its `levels` rule at `:54`

**Interfaces:**
- Consumes: `levels.illness` from `analyze.js` normal-mode output (Task 5).
- Produces: a `health.md` frontmatter line the host parser of Task 6 accepts.

- [ ] **Step 1: Extend the frontmatter template**

Change the `levels:` line in the template to:

```markdown
   levels: {energy: <levels.energy>, stress: <levels.stress>, recovery: <levels.recovery>, readiness: <levels.readiness>, illness: <levels.illness>}
```

- [ ] **Step 2: Extend the copy rule**

Change the `levels` bullet to:

```markdown
- `levels` — копируй из вывода analyze.js дословно; не считай руками. `illness`
  может быть `null` — так и пиши `null`, не пропускай ключ и не ставь ноль:
  ноль значит «спокойнее всех дней», а `null` значит «не из чего считать».
```

- [ ] **Step 3: Add the naming rule**

Append to the same skill, beside the existing «Числа во флагах» table:

```markdown
**`illness` — процентиль, не вероятность.** Если называешь его словами в тексте
карточки — «необычность выше обычного», «спокойный день». Никогда «шанс
заболеть N%». Причина в `CLAUDE.md`.
```

- [ ] **Step 4: Deploy and rebirth**

```bash
scp -r groups/greg/skills root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/
```

Rebirth as in Task 3 Step 5.

- [ ] **Step 5: Verify end to end**

Ask Greg to run publish. Then:

```bash
ssh root@148.253.211.164 "head -8 /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/memories/health.md"
```

Expected: the `levels:` line carries five keys.

- [ ] **Step 6: Commit**

```bash
git commit --allow-empty -m "feat(greg): publish the illness percentile in health.md frontmatter"
```

---

### Task 8: Three numbers on the home entry

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Models/StateModel.swift:4-7`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Components/SummaryEntryView.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift:114`
- Modify: `ios/JarvisApp/project.yml`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift`

**Interfaces:**
- Consumes: `StateModel.Levels` decoded from `GET /ios/state`.
- Produces: `SummaryEntryView(agents:levels:)`; `SummaryEntryView.tiles(_ levels:) -> [(String, String)]` — a pure static returning `(value, label)` pairs, so the layout is testable without a view host.

- [ ] **Step 1: Write the failing tests**

Append to `ios/JarvisApp/Sources/JarvisAppTests/AgentDashboardTests.swift`:

```swift
func testSummaryTilesShowStressIllnessRecovery() {
    let l = StateModel.Levels(energy: 70, stress: 34, recovery: 81, readiness: 68, illness: 55, updated: nil)
    let tiles = SummaryEntryView.tiles(l)
    XCTAssertEqual(tiles.map(\.1), ["стресс", "необычность", "восстановление"])
    XCTAssertEqual(tiles.map(\.0), ["34", "55", "81"])
}

func testSummaryTilesRenderMissingNumbersAsDash() {
    let l = StateModel.Levels(energy: nil, stress: nil, recovery: 81, readiness: nil, illness: nil, updated: nil)
    XCTAssertEqual(SummaryEntryView.tiles(l).map(\.0), ["—", "—", "81"])
}

func testLevelsDecodeWithoutIllness() throws {
    // A payload from a host that has not shipped Task 6 yet must still decode.
    let json = #"{"energy":70,"stress":34,"recovery":81,"readiness":68}"#.data(using: .utf8)!
    let l = try JSONDecoder().decode(StateModel.Levels.self, from: json)
    XCTAssertNil(l.illness)
    XCTAssertEqual(l.stress, 34)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `ios/JarvisApp/`:

```bash
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:JarvisAppTests/AgentDashboardTests 2>&1 | tail -20
```

Expected: compile error — `Levels` has no member `illness`, `SummaryEntryView` has no member `tiles`.

- [ ] **Step 3: Add the field**

In `StateModel.swift`:

```swift
        var energy: Int?; var stress: Int?; var recovery: Int?; var readiness: Int?
        var illness: Int?
        var updated: String?
```

`Int?` with a synthesized `Codable` decodes an absent key as `nil`, which is what the third test pins.

- [ ] **Step 4: Render the three numbers**

Replace the body of `SummaryEntryView.swift`:

```swift
import SwiftUI

/// Slim home-screen entry. Carries the three numbers the owner acts on —
/// stress, how unusual today is, recovery — because behind a tap they went
/// unread. Tapping still opens the full dashboard.
struct SummaryEntryView: View {
    let agents: [StateModel.AgentRow]
    let levels: StateModel.Levels

    private var count: Int { StateBoardView.actionableCount(agents) }

    /// (value, label) in reading order. Pure, so the copy is testable without a
    /// view host. `illness` is a percentile of his own history — the label says
    /// «необычность», never «риск», because there is nothing to calibrate a
    /// probability against.
    static func tiles(_ l: StateModel.Levels) -> [(String, String)] {
        let show: (Int?) -> String = { $0.map(String.init) ?? "—" }
        return [(show(l.stress), "стресс"), (show(l.illness), "необычность"), (show(l.recovery), "восстановление")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.scaled(8)) {
            HStack(spacing: 9) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundColor(Theme.accent)
                Text(count > 0 ? "Сводка · \(count) \(Self.plural(count))" : "Сводка")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: Theme.scaled(16)) {
                ForEach(Self.tiles(levels), id: \.1) { tile in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tile.0)
                            .font(.system(size: Theme.fontSubhead, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text(tile.1)
                            .font(.system(size: Theme.fontCaption))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, Theme.scaled(14))
        .padding(.vertical, Theme.scaled(11))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.scaled(18)))
        .accessibilityIdentifier("home-summary-entry")
    }

    /// Russian plural for "дело" (1 дело / 2 дела / 5 дел).
    static func plural(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "дело" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "дела" }
        return "дел"
    }
}
```

The capsule becomes a rounded rectangle because a two-line body no longer fits a capsule's geometry.

- [ ] **Step 5: Update the call site**

In `ios/JarvisApp/Sources/JarvisApp/Views/OrbHomeView.swift:114`:

```swift
                    SummaryEntryView(
                        agents: stateService.state?.agents ?? [],
                        levels: stateService.state?.levels ?? StateModel.Levels(
                            energy: nil, stress: nil, recovery: nil, readiness: nil, illness: nil, updated: nil))
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
xcodebuild test -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```

Expected: all tests pass, 0 failures.

- [ ] **Step 7: Bump the build and regenerate**

In `ios/JarvisApp/project.yml`, raise `MARKETING_VERSION` to `1.36.0` and `CURRENT_PROJECT_VERSION` to `112`. Then from `ios/JarvisApp/`:

```bash
xcodegen generate
```

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp
git commit -m "feat(ios): stress, unusualness and recovery on the home entry"
```

- [ ] **Step 9: Deploy the host and confirm**

```bash
git push origin main
ssh root@148.253.211.164 'sudo -u nanoclaw bash -lc "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/\$(id -u nanoclaw) systemctl --user restart nanoclaw"'
```

Install build 1.36.0 (112) and confirm the three numbers appear on the home screen without opening anything. **Until it is installed, nothing in Phase 3 is visible** — the same gate that held Task 17.

---

## What this plan does not claim

It does not predict illness. Three independent measurements say a pre-onset signal is not present in these features on the one episode available: raw HealthKit trajectory over ~100 nights, the interval buckets after backfill, and a separability probe that repaired every structural weakness of the current detector at once and still put the day before onset mid-pack.

What it does is make the system able to answer the question later. Phase 1 turns "healthy day" from an assumption into an observation and starts the only series that could lead the sensors. Phase 2 makes the output graded, which is the shape a load decision needs. Phase 3 makes it read.

The measurement to run in three months, once labels have accumulated: re-run `docs/superpowers/plans/probes/separability-probe.js` against the confirmed-healthy days rather than the assumed-healthy ones, and check whether a `morningState` of `off`/`bad` leads the hardware score. `morningState` is the one to test first — it is contemporaneous with the overnight signals the detector is built from, so if a human reading beats the sensors on the same night's evidence, that is the early-warning channel and it was never in the hardware. If it does not, the honest conclusion is written down and the question stops being reopened.
