# Greg House Persona + Differential + Sick-Day — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three coordinated upgrades from `docs/superpowers/specs/2026-06-05-greg-house-persona-design.md` — House MD persona for Greg, two new analyze.js modes (differential + sick-day), and four new HealthKit scalars + workouts array threaded through the shared protocol.

**Architecture:** Schema and Swift mirror extended additively (zod `.optional`, Swift `var ...?`). Greg's `analyze.js` grows a `--mode` dispatcher (`normal`|`differential`|`sick-day`). Sick-day signals fire from a new host-side trigger module called from the existing iOS health upload HTTP handler. Persona ships as text-only rules in two `groups/*/CLAUDE.md` files (install-specific, not git-tracked).

**Tech Stack:**
- Host: Node + TypeScript, vitest, `better-sqlite3` (Mac/Linux), pnpm workspace
- Container agent-runner: Bun + TypeScript, bun:test, `bun:sqlite`
- iOS app: Swift + HealthKit, no test target today
- Shared protocol: zod schemas + JSON fixtures + Swift Codable mirror

---

## File structure

### Committed (git, push to main)

| File | Type | Purpose |
|---|---|---|
| `shared/ios-app-protocol/v2.ts` | modify | Extend `HealthUploadDay` with 4 scalars + `Workout` schema + `workouts` array |
| `shared/ios-app-protocol/fixtures/health/upload.json` | modify | Add example values for all new fields |
| `shared/ios-app-protocol/fixtures.test.ts` | no change | Round-trip already iterates all health/*.json |
| `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` | modify | Add `V2.HealthUpload.Workout` struct + new fields on `Day` |
| `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` | modify | HKQueries for 4 scalars + workouts |
| `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift` | modify | Permission types for 4 new HKQuantityTypes |
| `src/modules/health-trigger/sick-day.ts` | create | Threshold logic + `writeSessionMessage` wake call |
| `src/modules/health-trigger/sick-day.test.ts` | create | Threshold table tests + write-call mock |
| `src/channels/ios-app/v2/http-handler.ts` | modify | Call sick-day trigger after `appendHealthHistory` |

### Install-only (edit locally, scp to VDS, NOT committed)

| File | Type | Purpose |
|---|---|---|
| `groups/health-analyzer/CLAUDE.md` | modify | House persona section, `house_quote` field on contract, differential handler, sick-day handler |
| `groups/health-analyzer/scripts/analyze.js` | modify | `--mode` dispatcher, differential mode, sick-day mode, new metrics in `METRICS`+ `CONCERN_UP/DOWN`, recovery composite extension |
| `groups/health-analyzer/scripts/analyze.test.js` | create | Bun-native table tests for new modes |
| `groups/jarvis/CLAUDE.md` | modify | §9 verbatim quote rule + complaint pattern triggers + a2a routing format |

### Deployment

After each install-only change: `scp` updated file(s) to `root@148.253.211.164:/home/nanoclaw/nanoclaw/<path>`, then on VDS `ncl groups restart --id <gid>` for affected agent. After each committed code change: push to main, `git pull` on VDS, `pnpm run build`, systemd/launchd kickstart.

---

## Task 1: Persona text rules

**Why first:** Pure prompt change, smallest blast radius. Validates the `house_quote` field contract end-to-end before any code changes.

**Files:**
- Modify: `groups/health-analyzer/CLAUDE.md` (VDS-only, edit locally + scp)
- Modify: `groups/jarvis/CLAUDE.md` (VDS-only, edit locally + scp)

### Step 1.1 — Add House persona + `house_quote` field to Greg CLAUDE.md

Open `groups/health-analyzer/CLAUDE.md`. Insert a new section "Persona" after the existing "Дисклеймер" section. Insert this exact text:

```markdown
## Persona — Gregory House

Ты Грег. Сардоничный, проницательный, без сюсюканий. «Everybody lies» — если объективные данные противоречат отчётам Сергея, ты доверяешь данным. Ход мысли — differential: «два варианта, выбирай», «ставлю на X, если ошибся — проверь Y».

Тон полный House: яд, сарказм, ирония. Без хамства в личность — только в проблему. Без пустых одобрений («молодец»), без эвфемизмов. Если Сергей сказал «спал 8 часов», а HRV говорит обратное — называешь это прямо.

**Safety valve:** при `severity === 'critical'` сарказм приглушён до ≤30% от обычного, фокус на действии. Канон — House становится серьёзнее, когда жизнь на кону.

**Дисклеймер сохраняется:** ты НЕ ставишь диагнозы. Формулируешь через «ставлю на», «два варианта», «стоит проверить», «индикаторы мигают». Никогда «у тебя X».
```

Then update the existing "Finding-контракт" section. Replace it with:

```markdown
## Finding-контракт
```json
{
  "severity": "info|warn|critical",
  "metric": "...",
  "window": { "from": "...", "to": "...", "days": N },
  "observation": "человеческая формулировка наблюдения",
  "suggestion": "что стоит сделать",
  "house_quote": "1-2 предложения в характере House. Jarvis процитирует verbatim в формате «Грег сказал: «<это>»». Внутри ASCII-кавычки ОК, внешнее обрамление « » добавит Jarvis.",
  "mode": "anomaly",
  "generated_at": "ISO"
}
```

`house_quote` обязательно для каждого finding. Если не сгенерирован — Jarvis fallback-нёт на `observation`, что хуже по vibe. Сильный quote = ключевой инсайт в House-тоне. Не «у вас низкий HRV», а «HRV упал на четверть за неделю. Ставлю на накопленную усталость или начинающуюся инфекцию. Меньше героизма, больше сна.»

`mode` различает три типа finding'ов: `"anomaly"` (дневной sweep), `"differential"` (по жалобе), `"sick_day"` (триггер от хоста). Структура `hypotheses` для `differential` и `next_actions` для `sick_day` описаны ниже.
```

- [ ] **Step 1.1.1:** Open `groups/health-analyzer/CLAUDE.md` in editor.
- [ ] **Step 1.1.2:** Insert the Persona section after `## Дисклеймер`.
- [ ] **Step 1.1.3:** Replace the existing `## Finding-контракт` section with the updated one above.
- [ ] **Step 1.1.4:** Verify by re-reading the file: `head -200 groups/health-analyzer/CLAUDE.md`.

### Step 1.2 — Add verbatim quote rule to Jarvis CLAUDE.md

Open `groups/jarvis/CLAUDE.md`. Find §9 ("Когда зовёшь Грега" / "Recheck"). Insert a new sub-section "Рендеринг ответа Грега":

```markdown
### Рендеринг ответа Грега

Когда получаешь finding от Greg, ОБЯЗАТЕЛЬНО:

1. Найди поле `house_quote` в finding.
2. Покажи его юзеру в формате: `Грег сказал: «<house_quote>»` — точные кавычки « », ровно как написано в quote, без перефраза, без перевода, без сокращения.
3. Опционально добавь одну строку своего action layer: напомнить лечь раньше, предложить запланировать задачу, предложить recheck через N дней. Только то что относится к действию.

**Что НЕЛЬЗЯ:**
- Перепи́сывать `house_quote` своими словами
- Объединять несколько findings в один пересказ
- Опускать quote и пересказывать `observation` (только если `house_quote` отсутствует — fallback на `observation` с тем же префиксом «Грег сказал»).

**Структурные поля** (`severity`, `metric`, `window`, `hypotheses`, `next_actions`) — это твои данные для решения что делать, юзеру их не показываешь. Они нужны чтобы понять серьёзность, нужен ли follow-up, нужно ли запланировать task.

Пример рендера:
> Грег сказал: «HRV провалился на 18% за три дня. Не делал — не спал. Делал — недосыпай меньше.»
>
> Поставлю напоминание лечь до 23:00 сегодня?
```

- [ ] **Step 1.2.1:** Open `groups/jarvis/CLAUDE.md`.
- [ ] **Step 1.2.2:** Find §9. Insert "Рендеринг ответа Грега" sub-section.
- [ ] **Step 1.2.3:** Verify: `grep -A 5 'Рендеринг ответа Грега' groups/jarvis/CLAUDE.md`.

### Step 1.3 — Deploy to VDS

- [ ] **Step 1.3.1:** Copy Greg CLAUDE.md:

```bash
scp groups/health-analyzer/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/health-analyzer/CLAUDE.md
```

- [ ] **Step 1.3.2:** Copy Jarvis CLAUDE.md:

```bash
scp groups/jarvis/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/CLAUDE.md
```

- [ ] **Step 1.3.3:** Restart both agents on VDS so the next session loads new prompts:

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && pnpm exec tsx -e \"\
import { dispatch } from \\\"./src/cli/dispatch.ts\\\";\
await dispatch([\\\"groups\\\", \\\"restart\\\", \\\"--id\\\", \\\"greg\\\"]);\
await dispatch([\\\"groups\\\", \\\"restart\\\", \\\"--id\\\", \\\"ag-1778740750341-ru9i6e\\\"]);\
\""'
```

(Use `ncl` socket if available on VDS — equivalent.)

### Step 1.4 — Smoke test

- [ ] **Step 1.4.1:** Send Telegram message to Jarvis: "Грег, как я?". Expect Jarvis to say "Сейчас спрошу Грега" then a reply formatted `Грег сказал: «<house_quote>»`.
- [ ] **Step 1.4.2:** Inspect Greg's outbound DB on VDS to confirm finding JSON has `house_quote` field:

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && pnpm exec tsx scripts/q.ts data/v2-sessions/greg/<sess-id>/outbound.db "SELECT content FROM messages_out ORDER BY seq DESC LIMIT 1" | head -50'
```

Expected: JSON containing `"house_quote": "..."`.

- [ ] **Step 1.4.3:** If house_quote missing or Jarvis paraphrased, iterate on prompt and redeploy.

**No git commit for Task 1** — install-only.

---

## Task 2: Differential mode

**Files:**
- Create: `groups/health-analyzer/scripts/analyze.test.js`
- Modify: `groups/health-analyzer/scripts/analyze.js`
- Modify: `groups/health-analyzer/CLAUDE.md`
- Modify: `groups/jarvis/CLAUDE.md`

### Step 2.1 — Write failing tests for differential mode

Create `groups/health-analyzer/scripts/analyze.test.js`:

```js
// Bun test suite for analyze.js modes. Run from VDS or local Bun:
//   bun test groups/health-analyzer/scripts/analyze.test.js
import { describe, it, expect } from "bun:test";
import { differentialAnalyze, mapComplaintToMetrics } from "./analyze.js";

describe("mapComplaintToMetrics", () => {
  it("fatigue complaints → recovery cluster", () => {
    const m = mapComplaintToMetrics("устал");
    expect(m).toContain("recovery");
    expect(m).toContain("hrv");
    expect(m).toContain("sleepHours");
    expect(m).toContain("restingHeartRate");
  });
  it("sleep complaints → sleep cluster", () => {
    const m = mapComplaintToMetrics("не выспался");
    expect(m).toContain("sleepHours");
    expect(m).toContain("hrv");
  });
  it("headache complaints → headache cluster", () => {
    const m = mapComplaintToMetrics("болит голова");
    expect(m).toContain("sleepHours");
    expect(m).toContain("wristTempDeviation");
  });
  it("generic complaints → broad cluster", () => {
    const m = mapComplaintToMetrics("как я?");
    expect(m).toContain("recovery");
    expect(m.length).toBeGreaterThanOrEqual(5);
  });
});

describe("differentialAnalyze", () => {
  const baseRows = Array.from({ length: 14 }, (_, i) => ({
    date: `2026-06-${String(i + 1).padStart(2, "0")}`,
    hrv: 50,
    sleepHours: 7.5,
    restingHeartRate: 60,
    steps: 8000,
  }));
  it("returns empty hypotheses on stable data", () => {
    const out = differentialAnalyze(baseRows, "устал", 14);
    expect(out.top).toEqual([]);
  });
  it("flags hrv drop as top candidate for fatigue", () => {
    const rows = [
      ...baseRows.slice(0, 11),
      { ...baseRows[11], hrv: 30 },
      { ...baseRows[12], hrv: 28 },
      { ...baseRows[13], hrv: 26 },
    ];
    const out = differentialAnalyze(rows, "устал", 14);
    expect(out.top[0].metric).toBe("hrv");
    expect(out.top[0].direction).toBe("down");
  });
  it("ranks by combined deviation × persistence × directional match", () => {
    const rows = [
      ...baseRows.slice(0, 11),
      { ...baseRows[11], hrv: 30, restingHeartRate: 70 },
      { ...baseRows[12], hrv: 28, restingHeartRate: 72 },
      { ...baseRows[13], hrv: 26, restingHeartRate: 75 },
    ];
    const out = differentialAnalyze(rows, "устал", 14);
    expect(out.top.length).toBeGreaterThanOrEqual(2);
    expect(["hrv", "restingHeartRate"]).toContain(out.top[0].metric);
  });
});
```

- [ ] **Step 2.1.1:** Create the file with exactly the content above.
- [ ] **Step 2.1.2:** Run: `cd groups/health-analyzer/scripts && bun test analyze.test.js`
- [ ] **Step 2.1.3:** Expected: FAIL — `differentialAnalyze` and `mapComplaintToMetrics` not exported.

### Step 2.2 — Implement differential mode in analyze.js

At the **top** of `groups/health-analyzer/scripts/analyze.js`, after the existing imports, add:

```js
// Complaint → candidate metric map. Used by differential mode to narrow which
// metrics deserve scoring. Generic complaints fall back to a broad set.
const COMPLAINT_MAP = {
  fatigue: ["recovery", "hrv", "sleepHours", "restingHeartRate", "exerciseMinutes", "activeEnergy"],
  sleep:   ["sleepHours", "hrv", "respiratoryRate"],
  headache: ["sleepHours", "wristTempDeviation", "exerciseMinutes", "restingHeartRate"],
  generic: ["recovery", "hrv", "sleepHours", "restingHeartRate", "heartRate", "wristTempDeviation", "respiratoryRate"],
};

export function mapComplaintToMetrics(complaint) {
  const c = (complaint || "").toLowerCase();
  if (/устал|разбит|вымотан|нет сил/.test(c)) return COMPLAINT_MAP.fatigue;
  if (/не выспал|сон|плохо спал|просыпал/.test(c)) return COMPLAINT_MAP.sleep;
  if (/голов|мигрен/.test(c)) return COMPLAINT_MAP.headache;
  return COMPLAINT_MAP.generic;
}

// Differential mode: rank candidate metrics by (|mod_z| × persistence_days
// × directional_match). Returns top-5 sorted descending with evidence numbers.
// Greg's LLM step takes this output and produces 2-3 ranked hypotheses + house_quote.
export function differentialAnalyze(rows, complaint, windowDays = 14) {
  const candidates = mapComplaintToMetrics(complaint);
  if (rows.length < 7) return { complaint, window_days: windowDays, top: [] };
  const recent = Math.min(3, Math.max(1, Math.floor(windowDays / 5)));
  const baseline = windowDays;
  const scored = [];
  for (const metric of candidates) {
    const s = series(rows, metric);
    if (s.length < 7) continue;
    const vals = s.map(([, v]) => v);
    const recentVals = vals.slice(-recent);
    const baseVals = vals.slice(-(recent + baseline), -recent);
    if (baseVals.length < 3) continue;
    const med = median(baseVals);
    const m = mad(baseVals, med);
    const scale = m > 0 ? m * 1.4826 : (pstdev(baseVals) || 1);
    const recentMed = median(recentVals);
    const modz = scale ? (recentMed - med) / scale : 0;
    const direction = modz > 0 ? "up" : "down";
    const directional = (direction === "up" && CONCERN_UP.has(metric)) ||
                        (direction === "down" && CONCERN_DOWN.has(metric));
    const persistence = recentVals.filter((v) => Math.sign(v - med) === Math.sign(modz)).length;
    const score = Math.abs(modz) * persistence * (directional ? 1.5 : 0.5);
    if (Math.abs(modz) < 0.5) continue;
    scored.push({
      metric, direction, score: Math.round(score * 100) / 100,
      mod_z: Math.round(modz * 100) / 100,
      recent_median: Math.round(recentMed * 100) / 100,
      baseline_median: Math.round(med * 100) / 100,
      persistence_days: persistence,
      window: { from: s[s.length - recent][0], to: s[s.length - 1][0], days: recent },
    });
  }
  scored.sort((a, b) => b.score - a.score);
  return { complaint, window_days: windowDays, top: scored.slice(0, 5) };
}
```

Then **replace** the bottom invocation block (the `const opts = parseArgs(...); ...console.log(text);` lines) with a `--mode` dispatcher:

```js
function parseModeArgs(argv) {
  const o = { raw: "/workspace/agent/health/raw.jsonl", mode: "normal",
              recent: 3, baseline: 21, minN: 7, topK: 8, out: null,
              complaint: "", window: 14 };
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mode") o.mode = argv[++i];
    else if (a === "--complaint") o.complaint = argv[++i];
    else if (a === "--window") o.window = +argv[++i];
    else if (a === "--recent") o.recent = +argv[++i];
    else if (a === "--baseline") o.baseline = +argv[++i];
    else if (a === "--min-n") o.minN = +argv[++i];
    else if (a === "--top-k") o.topK = +argv[++i];
    else if (a === "--out") o.out = argv[++i];
    else pos.push(a);
  }
  if (pos.length) o.raw = pos[0];
  return o;
}

// Only run CLI dispatcher when invoked directly, not when imported by tests.
if (import.meta.main) {
  const opts = parseModeArgs(Bun.argv.slice(2));
  const rows = loadRows(opts.raw);
  buildRecovery(rows);
  let result;
  if (opts.mode === "differential") {
    result = {
      generated_at: rows.length ? rows[rows.length - 1].date : null,
      n_days: rows.length,
      mode: "differential",
      ...differentialAnalyze(rows, opts.complaint, opts.window),
      coverage: computeCoverage(rows),
    };
  } else {
    // normal mode (and sick-day will be added in Task 6)
    result = {
      generated_at: rows.length ? rows[rows.length - 1].date : null,
      n_days: rows.length,
      mode: "normal",
      anomalies: analyze(rows, opts),
      coverage: computeCoverage(rows),
    };
  }
  const text = JSON.stringify(result, null, 2);
  if (opts.out) writeFileSync(opts.out, text);
  console.log(text);
}
```

Also: replace the existing `function parseArgs` (it becomes dead code after dispatcher takes over) and remove the trailing top-level invocation.

- [ ] **Step 2.2.1:** Edit `analyze.js`: add `COMPLAINT_MAP`, `mapComplaintToMetrics`, `differentialAnalyze` exports at top after imports.
- [ ] **Step 2.2.2:** Replace `parseArgs` with `parseModeArgs` and wrap CLI dispatch in `if (import.meta.main)`.
- [ ] **Step 2.2.3:** Run: `bun test groups/health-analyzer/scripts/analyze.test.js`
- [ ] **Step 2.2.4:** Expected: PASS, all 7 cases.

### Step 2.3 — Add differential handler section to Greg CLAUDE.md

Insert after "Рабочий цикл (каждый прогон)" section:

```markdown
## Differential mode

Jarvis может прислать в a2a `{ "complaint": "<жалоба юзера>", "window_days": 14 }`. Это сигнал на differential — режим House «дай два варианта».

1. Запусти: `bun /workspace/agent/scripts/analyze.js --mode differential --complaint "<complaint>" --window 14 --out /tmp/diff.json`
2. Прочти `/tmp/diff.json` (там `top: [{metric, score, mod_z, direction, persistence_days, ...}]` — не более 5 кандидатов).
3. Сформируй **2-3 гипотезы**, ранжированные по силе. Для каждой:
   - `rank`: 1, 2, 3
   - `statement`: одно предложение, House-стиль («ставлю на накопленное переутомление: HRV в подвале три дня»)
   - `evidence`: какие метрики, какие числа, какое окно
   - `next_check`: что проверить/изменить — конкретно
4. Сгенерируй `house_quote`: 1-2 предложения суммирующих differential в House-тоне. Пример: «Два варианта: либо вы зажали восстановление тренировками, либо подцепили что-то лёгкое. Сон в норме — ставлю на первое. Снимите нагрузку на три дня.»
5. Отправь Jarvis ОДНО сообщение:

```json
{
  "severity": "warn|info|critical",
  "metric": "differential",
  "mode": "differential",
  "complaint": "<входящая жалоба>",
  "window": { "from": "...", "to": "...", "days": 14 },
  "observation": "differential по жалобе '<complaint>'",
  "suggestion": "<top next_check>",
  "hypotheses": [{ "rank": 1, "statement": "...", "evidence": "...", "next_check": "..." }, ...],
  "house_quote": "<2 предложения House>",
  "generated_at": "ISO"
}
```

**Терминально:** один ответ. Не пингаешь Jarvis обратно без новой жалобы. Hop-cap=5 защищает, но дисциплина важнее.
```

- [ ] **Step 2.3.1:** Insert section.
- [ ] **Step 2.3.2:** Verify: `grep -A 3 'Differential mode' groups/health-analyzer/CLAUDE.md`.

### Step 2.4 — Add complaint triggers to Jarvis CLAUDE.md §9

In §9, extend the "Когда зовёшь Грега" list with a third case:

```markdown
3. **Жалоба на самочувствие** (даже без явного «Грег, …»):
   - триггеры: «устал», «разбит», «вымотан», «нет сил», «не выспался», «плохо спал», «болит голова», «мигрень», «как я?», «что со мной?», «что с моим здоровьем»
   - действие: скажи юзеру «Сейчас спрошу Грега» и отправь `send_message(to="greg", { "complaint": "<точные слова юзера>", "window_days": 14 })`
   - окно: 14 дней по умолчанию. Для острых жалоб («сегодня плохо», «утром не встал») сократи до 7.
   - дальше Грег ответит finding'ом с `mode: "differential"` и `hypotheses` — пересказывай только `house_quote`.
```

- [ ] **Step 2.4.1:** Edit Jarvis CLAUDE.md §9. Insert the new case.

### Step 2.5 — Deploy and smoke test

- [ ] **Step 2.5.1:** Copy analyze.js + CLAUDE.md to VDS:

```bash
scp groups/health-analyzer/scripts/analyze.js root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/health-analyzer/scripts/analyze.js
scp groups/health-analyzer/scripts/analyze.test.js root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/health-analyzer/scripts/analyze.test.js
scp groups/health-analyzer/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/health-analyzer/CLAUDE.md
scp groups/jarvis/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/jarvis/CLAUDE.md
```

- [ ] **Step 2.5.2:** Run tests on VDS to confirm bun compatibility:

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw/groups/health-analyzer/scripts && bun test analyze.test.js'
```

Expected: PASS.

- [ ] **Step 2.5.3:** Restart greg + jarvis containers (same command as Step 1.3.3).

- [ ] **Step 2.5.4:** Smoke test: Telegram → Jarvis: "устал, разбит весь день". Expect Jarvis to say "Сейчас спрошу Грега" then reply with `Грег сказал: «...»` containing differential reasoning.

**No git commit for Task 2** — install-only.

---

## Task 3: Schema expansion (committed)

**Files:**
- Modify: `shared/ios-app-protocol/fixtures/health/upload.json`
- Modify: `shared/ios-app-protocol/v2.ts`
- No change: `shared/ios-app-protocol/fixtures.test.ts` (already iterates all health/*.json)

### Step 3.1 — Extend fixture first (TDD: make it fail)

Replace contents of `shared/ios-app-protocol/fixtures/health/upload.json` with:

```json
{
  "platformId": "ios-app-v2:default",
  "requestId": "req-2026-06-01-a",
  "days": [
    {
      "date": "2026-05-31",
      "steps": 6843,
      "activeEnergy": 875,
      "exerciseMinutes": 126,
      "heartRate": 79,
      "restingHeartRate": 64,
      "hrv": 53,
      "sleepHours": 6.1,
      "wristTempDeviation": 0.2,
      "respiratoryRate": 15,
      "walkingHeartRateAverage": 92,
      "vo2max": 41,
      "workouts": [
        {
          "type": "running",
          "startISO": "2026-05-31T07:15:00Z",
          "durationMin": 32,
          "energyKcal": 310,
          "avgHR": 148,
          "maxHR": 172
        }
      ]
    },
    {
      "date": "2026-06-01",
      "steps": 412,
      "activeEnergy": 38,
      "heartRate": 58,
      "hrv": 64,
      "sleepHours": 7.4,
      "wristTempDeviation": -0.1,
      "respiratoryRate": 14
    }
  ]
}
```

- [ ] **Step 3.1.1:** Overwrite the fixture file with the JSON above.
- [ ] **Step 3.1.2:** Run: `pnpm test -- ios-app-protocol/fixtures`
- [ ] **Step 3.1.3:** Expected: FAIL on `health/upload.json round-trips through HealthUploadBody` — zod strips unknown fields, so `reParsed` differs from `body` if zod silently dropped them, OR (with strict mode) zod errors. Either way: red.

### Step 3.2 — Extend v2.ts schema

In `shared/ios-app-protocol/v2.ts`, **before** `export const HealthUploadDay`, add the `Workout` schema:

```ts
export const Workout = z.object({
  type: z.string(),
  startISO: z.string(),
  durationMin: z.number().nonnegative(),
  energyKcal: z.number().nonnegative().optional(),
  avgHR: z.number().int().nonnegative().optional(),
  maxHR: z.number().int().nonnegative().optional(),
});
export type Workout = z.infer<typeof Workout>;
```

Then replace `HealthUploadDay` with:

```ts
export const HealthUploadDay = z.object({
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  steps: z.number().int().nonnegative().optional(),
  activeEnergy: z.number().int().nonnegative().optional(),
  exerciseMinutes: z.number().int().nonnegative().optional(),
  heartRate: z.number().int().nonnegative().optional(),
  restingHeartRate: z.number().int().nonnegative().optional(),
  hrv: z.number().int().nonnegative().optional(),
  sleepHours: z.number().nonnegative().optional(),
  // New in 2026-06-05 spec: sick-day + differential support.
  // wristTempDeviation is signed — HealthKit reports as ±°C around the
  // user's own sleeping baseline, so it can legitimately be negative.
  wristTempDeviation: z.number().optional(),
  respiratoryRate: z.number().nonnegative().optional(),
  walkingHeartRateAverage: z.number().int().nonnegative().optional(),
  vo2max: z.number().nonnegative().optional(),
  workouts: z.array(Workout).optional(),
});
export type HealthUploadDay = z.infer<typeof HealthUploadDay>;
```

- [ ] **Step 3.2.1:** Insert `Workout` schema before `HealthUploadDay`.
- [ ] **Step 3.2.2:** Replace `HealthUploadDay` definition with the extended version.
- [ ] **Step 3.2.3:** Run: `pnpm test -- ios-app-protocol/fixtures`
- [ ] **Step 3.2.4:** Expected: PASS.
- [ ] **Step 3.2.5:** Also run full host build to catch type errors elsewhere: `pnpm run build`
- [ ] **Step 3.2.6:** Expected: PASS.

### Step 3.3 — Commit

```bash
git add shared/ios-app-protocol/v2.ts shared/ios-app-protocol/fixtures/health/upload.json
git commit -m "$(cat <<'EOF'
shared/protocol: add 4 health scalars + Workout array

Extends HealthUploadDay with wristTempDeviation, respiratoryRate,
walkingHeartRateAverage, vo2max, and a workouts array. All optional —
older iOS builds keep uploading the existing 7 fields without error.

Foundation for Greg's sick-day early warning (needs wristTemp + RR)
and differential mode (uses workouts as evidence context).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3.3.1:** Stage + commit using the heredoc above.
- [ ] **Step 3.3.2:** Push: `git push origin main`.

---

## Task 4: Swift mirror (committed)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`

### Step 4.1 — Extend V2.swift HealthUpload extension

Find the existing `extension V2 { enum HealthUpload { ... } }` block at the bottom of `V2.swift`. Replace its contents with:

```swift
extension V2 {
    enum HealthUpload {
        struct Workout: Codable, Equatable {
            let type: String
            let startISO: String
            let durationMin: Double
            var energyKcal: Double?
            var avgHR: Int?
            var maxHR: Int?
        }

        struct Day: Codable, Equatable {
            let date: String
            var steps: Int?
            var activeEnergy: Int?
            var exerciseMinutes: Int?
            var heartRate: Int?
            var restingHeartRate: Int?
            var hrv: Int?
            var sleepHours: Double?
            // New in 2026-06-05 spec.
            var wristTempDeviation: Double?     // signed: ±°C from user baseline
            var respiratoryRate: Double?        // breaths/min
            var walkingHeartRateAverage: Int?   // bpm
            var vo2max: Double?                 // mL/kg/min
            var workouts: [Workout]?
        }

        struct Body: Codable, Equatable {
            var platformId: String?
            var requestId: String?
            var days: [Day]
        }
    }
}
```

- [ ] **Step 4.1.1:** Replace the extension block.
- [ ] **Step 4.1.2:** Build the iOS app to verify compilation:

```bash
cd ios/JarvisApp && xcodebuild -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
```

Or via XcodeBuildMCP `build_sim` if available. Expected: BUILD SUCCEEDED.

### Step 4.2 — Commit

```bash
git add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift
git commit -m "$(cat <<'EOF'
ios: mirror new HealthUpload fields in Swift Codable

Adds Workout struct and 4 new scalar fields (wristTempDeviation,
respiratoryRate, walkingHeartRateAverage, vo2max) plus a workouts
array to V2.HealthUpload.Day. Codable; encodes/decodes to the same
JSON shape as the TS zod schema.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 4.2.1:** Stage + commit + push.

---

## Task 5: iOS HealthKit queries (committed)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift` (permission set)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` (queries + bucketing)

### Step 5.1 — Add new permission types in HealthManager

In `HealthManager.swift`, find the `let types: Set<HKObjectType> = [...]` block (around line 16). Extend it:

```swift
let types: Set<HKObjectType> = [
    HKQuantityType(.stepCount),
    HKQuantityType(.heartRate),
    HKQuantityType(.activeEnergyBurned),
    HKCategoryType(.sleepAnalysis),
    HKQuantityType(.restingHeartRate),
    HKQuantityType(.appleExerciseTime),
    HKQuantityType(.heartRateVariabilitySDNN),
    // New in 2026-06-05 spec.
    HKQuantityType(.appleSleepingWristTemperature),
    HKQuantityType(.respiratoryRate),
    HKQuantityType(.walkingHeartRateAverage),
    HKQuantityType(.vo2Max),
    HKWorkoutType.workoutType(),
]
```

- [ ] **Step 5.1.1:** Edit the permission set.

### Step 5.2 — Extend HealthHistory.swift queries

In `HealthHistory.swift`, inside `static func fetch(...)`, just before the `group.notify(queue: .main)` block, add these four new query stanzas (one per new scalar) and the workouts query:

```swift
// New in 2026-06-05 spec: scalar metrics for sick-day detection + differential.

// Wrist temperature deviation — °C, signed. Daily average of HK's per-night
// deviation reading. Apple Watch S8+ only; older devices simply return no data.
group.enter()
collection(.appleSleepingWristTemperature, start: start, end: end, options: .discreteAverage) { stats in
    let degC = HKUnit.degreeCelsius()
    for s in stats {
        if let q = s.averageQuantity() {
            let k = bucketKey(s.startDate)
            let v = (q.doubleValue(for: degC) * 100).rounded() / 100   // 2-decimal precision
            mutate(k) { $0.wristTempDeviation = v }
        }
    }
    group.leave()
}

// Respiratory rate — breaths/min, sleep-window aggregate.
group.enter()
collection(.respiratoryRate, start: start, end: end, options: .discreteAverage) { stats in
    let rate = HKUnit(from: "count/min")
    for s in stats {
        if let q = s.averageQuantity() {
            let k = bucketKey(s.startDate)
            let v = (q.doubleValue(for: rate) * 10).rounded() / 10
            mutate(k) { $0.respiratoryRate = v }
        }
    }
    group.leave()
}

// Walking heart rate average — bpm. Early indicator of cardio drift.
group.enter()
collection(.walkingHeartRateAverage, start: start, end: end, options: .discreteAverage) { stats in
    let bpm2 = HKUnit(from: "count/min")
    for s in stats {
        if let q = s.averageQuantity() {
            let k = bucketKey(s.startDate)
            let v = Int(q.doubleValue(for: bpm2).rounded())
            mutate(k) { $0.walkingHeartRateAverage = v }
        }
    }
    group.leave()
}

// VO2max — mL/kg/min. Slow-moving fitness indicator; HK emits sporadically.
group.enter()
collection(.vo2Max, start: start, end: end, options: .discreteAverage) { stats in
    let vo2Unit = HKUnit(from: "ml/(kg*min)")
    for s in stats {
        if let q = s.averageQuantity() {
            let k = bucketKey(s.startDate)
            let v = (q.doubleValue(for: vo2Unit) * 10).rounded() / 10
            mutate(k) { $0.vo2max = v }
        }
    }
    group.leave()
}

// Workouts — array per day. Differential mode uses accumulated load as evidence.
group.enter()
let workoutQuery = HKSampleQuery(
    sampleType: HKWorkoutType.workoutType(),
    predicate: HKQuery.predicateForSamples(withStart: start, end: end),
    limit: HKObjectQueryNoLimit,
    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
) { _, samples, _ in
    let workouts = (samples as? [HKWorkout]) ?? []
    let isoFormatter = ISO8601DateFormatter()
    for w in workouts {
        let k = bucketKey(w.startDate)
        let energy = w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        let bpm3 = HKUnit(from: "count/min")
        let hrStats = w.statistics(for: HKQuantityType(.heartRate))
        let avg = hrStats?.averageQuantity()?.doubleValue(for: bpm3)
        let max = hrStats?.maximumQuantity()?.doubleValue(for: bpm3)
        let entry = V2.HealthUpload.Workout(
            type: String(describing: w.workoutActivityType),
            startISO: isoFormatter.string(from: w.startDate),
            durationMin: (w.duration / 60 * 10).rounded() / 10,
            energyKcal: energy.map { ($0 * 10).rounded() / 10 },
            avgHR: avg.map { Int($0.rounded()) },
            maxHR: max.map { Int($0.rounded()) }
        )
        mutate(k) {
            var list = $0.workouts ?? []
            list.append(entry)
            $0.workouts = list
        }
    }
    group.leave()
}
store.execute(workoutQuery)
```

- [ ] **Step 5.2.1:** Insert all five new query stanzas before `group.notify(queue: .main)`.
- [ ] **Step 5.2.2:** Build:

```bash
cd ios/JarvisApp && xcodebuild -scheme JarvisApp -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED.

### Step 5.3 — Manual device verification

This step requires the user's actual device — automation isn't feasible for HealthKit data.

- [ ] **Step 5.3.1:** Install the new build on user's device.
- [ ] **Step 5.3.2:** Accept the re-prompted HealthKit permissions (5 new types).
- [ ] **Step 5.3.3:** Trigger a manual upload via the app's existing "send to host" path (or wait for next background delivery).
- [ ] **Step 5.3.4:** On VDS, tail the raw.jsonl and confirm new fields are present:

```bash
ssh root@148.253.211.164 'tail -2 /home/nanoclaw/nanoclaw/groups/health-analyzer/health/raw.jsonl | python3 -m json.tool'
```

Expected: at least one of the new fields (`wristTempDeviation`, `respiratoryRate`, `walkingHeartRateAverage`, `vo2max`, or `workouts`) present in the latest day(s) the user has data for.

### Step 5.4 — Commit

```bash
git add ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift
git commit -m "$(cat <<'EOF'
ios: query 4 new HealthKit scalars + workouts array

Extends HealthHistory.fetch with appleSleepingWristTemperature,
respiratoryRate, walkingHeartRateAverage, vo2Max, and HKWorkoutType
queries. Permissions added in HealthManager.

Wires Greg's sick-day detector (needs wristTemp + RR) and the
differential mode's workout-load evidence. Devices that don't emit
some types (old watches, no sleep tracking) simply leave those
fields nil — schema is fully optional.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 5.4.1:** Stage + commit + push.

---

## Task 6: Sick-day mode in analyze.js (install-only)

**Files:**
- Modify: `groups/health-analyzer/scripts/analyze.js`
- Modify: `groups/health-analyzer/scripts/analyze.test.js`
- Modify: `groups/health-analyzer/CLAUDE.md`

### Step 6.1 — Write failing tests for sick-day detector

Append to `groups/health-analyzer/scripts/analyze.test.js`:

```js
import { sickDayDetect, SICK_DAY_THRESHOLDS } from "./analyze.js";

describe("sickDayDetect", () => {
  // 14 stable days: RHR 60, hrv 50, wristTempDeviation 0.0
  const baseline = Array.from({ length: 14 }, (_, i) => ({
    date: `2026-06-${String(i + 1).padStart(2, "0")}`,
    restingHeartRate: 60,
    hrv: 50,
    wristTempDeviation: 0.0,
  }));

  it("no signals → no trigger", () => {
    const today = { ...baseline[13] };
    expect(sickDayDetect([...baseline.slice(0, 13), today])).toBeNull();
  });

  it("only RHR up (1 of 3) → no trigger, info only", () => {
    const today = { ...baseline[13], restingHeartRate: 66 };  // +10%
    const out = sickDayDetect([...baseline.slice(0, 13), today]);
    expect(out).toBeNull();
  });

  it("RHR up + temp up (2 of 3) → trigger", () => {
    const today = { ...baseline[13], restingHeartRate: 66, wristTempDeviation: 0.5 };
    const out = sickDayDetect([...baseline.slice(0, 13), today]);
    expect(out).not.toBeNull();
    expect(out.matched).toBe(2);
  });

  it("all three signals → trigger with details", () => {
    const today = { ...baseline[13], restingHeartRate: 70, hrv: 40, wristTempDeviation: 0.6 };
    const out = sickDayDetect([...baseline.slice(0, 13), today]);
    expect(out).not.toBeNull();
    expect(out.matched).toBe(3);
    expect(out.signal.rhr_delta_pct).toBeGreaterThan(0);
    expect(out.signal.temp_delta_c).toBeGreaterThan(0);
    expect(out.signal.hrv_delta_pct).toBeLessThan(0);
  });

  it("missing wristTemp data → only RHR + hrv can fire", () => {
    const noTemp = baseline.map(({ wristTempDeviation, ...r }) => r);
    const today = { ...noTemp[13], restingHeartRate: 70, hrv: 40 };
    const out = sickDayDetect([...noTemp.slice(0, 13), today]);
    expect(out).not.toBeNull();
    expect(out.matched).toBe(2);
    expect(out.signal.temp_delta_c).toBeNull();
  });

  it("not enough baseline (<7 rows) → null", () => {
    expect(sickDayDetect([baseline[0]])).toBeNull();
  });
});
```

- [ ] **Step 6.1.1:** Append the block above to `analyze.test.js`.
- [ ] **Step 6.1.2:** Run: `cd groups/health-analyzer/scripts && bun test analyze.test.js`
- [ ] **Step 6.1.3:** Expected: FAIL on 6 new cases — `sickDayDetect` not exported.

### Step 6.2 — Implement sickDayDetect

In `analyze.js`, after `differentialAnalyze`, add:

```js
// Sick-day detector. Fires when 2 of 3 signals exceed their threshold for the
// most recent day's row, against a 14-day rolling baseline. The host's trigger
// module calls this on every health upload; Greg also calls it in `--mode sick-day`
// for the detailed downstream interpretation.
export const SICK_DAY_THRESHOLDS = {
  rhrPct: 7,       // RHR ≥ 7% above 14-day median = signal
  tempC: 0.4,      // wristTempDeviation ≥ +0.4°C = signal
  hrvPct: 15,      // HRV ≥ 15% below 14-day median = signal
};

export function sickDayDetect(rows, thresholds = SICK_DAY_THRESHOLDS) {
  if (!rows || rows.length < 7) return null;
  const today = rows[rows.length - 1];
  const baseline = rows.slice(-15, -1);  // up to 14 days excluding today
  if (baseline.length < 6) return null;

  function medianOf(metric) {
    const vs = baseline.map((r) => r[metric]).filter((v) => typeof v === "number" && Number.isFinite(v));
    return vs.length >= 4 ? median(vs) : null;
  }

  const rhrMed = medianOf("restingHeartRate");
  const hrvMed = medianOf("hrv");
  const tempMed = medianOf("wristTempDeviation");

  const todayRhr = typeof today.restingHeartRate === "number" ? today.restingHeartRate : null;
  const todayHrv = typeof today.hrv === "number" ? today.hrv : null;
  const todayTemp = typeof today.wristTempDeviation === "number" ? today.wristTempDeviation : null;

  const rhrDelta = (rhrMed !== null && todayRhr !== null) ? ((todayRhr - rhrMed) / rhrMed) * 100 : null;
  const hrvDelta = (hrvMed !== null && todayHrv !== null) ? ((todayHrv - hrvMed) / hrvMed) * 100 : null;
  const tempDelta = (tempMed !== null && todayTemp !== null) ? (todayTemp - tempMed) : todayTemp;

  const rhrFires = rhrDelta !== null && rhrDelta >= thresholds.rhrPct;
  const hrvFires = hrvDelta !== null && hrvDelta <= -thresholds.hrvPct;
  const tempFires = tempDelta !== null && tempDelta >= thresholds.tempC;

  const matched = [rhrFires, hrvFires, tempFires].filter(Boolean).length;
  if (matched < 2) return null;

  return {
    date: today.date,
    matched,
    signal: {
      rhr_delta_pct: rhrDelta !== null ? Math.round(rhrDelta * 10) / 10 : null,
      hrv_delta_pct: hrvDelta !== null ? Math.round(hrvDelta * 10) / 10 : null,
      temp_delta_c:  tempDelta !== null ? Math.round(tempDelta * 100) / 100 : null,
    },
    fires: { rhr: rhrFires, hrv: hrvFires, temp: tempFires },
  };
}
```

In the CLI dispatcher (Step 2.2 introduced `if (import.meta.main)`), add a `sick-day` branch before the `else`:

```js
  } else if (opts.mode === "sick-day") {
    const detection = sickDayDetect(rows);
    result = {
      generated_at: rows.length ? rows[rows.length - 1].date : null,
      n_days: rows.length,
      mode: "sick-day",
      detection,                              // null if no trigger, object otherwise
      recent_window: rows.slice(-5),          // last 5 days for context
      coverage: computeCoverage(rows, 7),
    };
  } else {
```

- [ ] **Step 6.2.1:** Add `SICK_DAY_THRESHOLDS` + `sickDayDetect` exports.
- [ ] **Step 6.2.2:** Add `sick-day` branch to the CLI dispatcher.
- [ ] **Step 6.2.3:** Run: `bun test groups/health-analyzer/scripts/analyze.test.js`
- [ ] **Step 6.2.4:** Expected: ALL 13 tests pass.

### Step 6.3 — Extend recovery composite with wristTempDeviation

Find `buildRecovery` in `analyze.js`. Change `comps` to:

```js
const comps = [["hrv", 1], ["restingHeartRate", -1], ["sleepHours", 1], ["wristTempDeviation", -1]];
```

The "≥2 of N" rule (`if (w >= 2)`) carries over unchanged — now it requires 2 of 4 components present, still safe.

- [ ] **Step 6.3.1:** Edit `comps` list.
- [ ] **Step 6.3.2:** Re-run tests: `bun test groups/health-analyzer/scripts/analyze.test.js`. Expected: still PASS (the existing recovery tests do not depend on temperature being absent).

### Step 6.4 — Add new metrics to METRICS + CONCERN sets

Find the `METRICS` constant and the `CONCERN_UP` / `CONCERN_DOWN` sets near the top of `analyze.js`. Update:

```js
const METRICS = [
  "steps", "activeEnergy", "exerciseMinutes",
  "heartRate", "restingHeartRate",
  "sleepHours", "hrv", "recovery",
  // New in 2026-06-05 spec.
  "wristTempDeviation", "respiratoryRate",
  "walkingHeartRateAverage", "vo2max",
];
const CONCERN_UP = new Set([
  "restingHeartRate", "heartRate",
  "wristTempDeviation", "respiratoryRate", "walkingHeartRateAverage",
]);
const CONCERN_DOWN = new Set([
  "sleepHours", "steps", "activeEnergy", "exerciseMinutes",
  "hrv", "recovery", "vo2max",
]);
```

- [ ] **Step 6.4.1:** Update METRICS, CONCERN_UP, CONCERN_DOWN.
- [ ] **Step 6.4.2:** Re-run tests: `bun test groups/health-analyzer/scripts/analyze.test.js`. Expected: PASS.

### Step 6.5 — Add sick-day handler section to Greg CLAUDE.md

Insert after the "Differential mode" section added in Task 2:

```markdown
## Sick-day mode

Host (не Jarvis) может прислать тебе wake-сообщение вида `{ "kind": "sick_day_check", "signal": { "rhr_delta_pct": ..., "temp_delta_c": ..., "hrv_delta_pct": ... } }`. Это означает: на последней upload-итерации сработали 2 из 3 признаков начинающегося заболевания.

1. Запусти: `bun /workspace/agent/scripts/analyze.js --mode sick-day --out /tmp/sick.json`
2. Прочти `/tmp/sick.json` — там `detection` (что именно сработало) и `recent_window` (5 последних дней для контекста).
3. **`severity: "critical"`** — автоматически. Срабатывает safety valve: сарказм приглушён, фокус на действие.
4. Проверь `memories/state.md` на suppress `sick_day until <ISO>`. Если активен И сигналы не ухудшились — молчи (не шли finding'а). Если ухудшились (один из дельт +50% сверх изначального) — шли с пометкой `worsening: true`.
5. Сформируй `next_actions`: 3-5 конкретных шагов (отдых, гидратация, измерить температуру вручную, отменить тренировку, и т.д.).
6. Сгенерируй `house_quote` в **серьёзном** House-стиле — без шуточек, ясно и плотно. Пример: «Два из трёх индикаторов мигают: RHR вверх, HRV вниз. Это инфекция в начале. Дома, чай, термометр. Не геройствуй.»
7. Запиши в `state.md` suppress на 24 часа.
8. Отправь Jarvis ОДНО сообщение:

```json
{
  "severity": "critical",
  "metric": "sick_day",
  "mode": "sick_day",
  "matched": 2,
  "signal": { "rhr_delta_pct": 9.2, "temp_delta_c": 0.5, "hrv_delta_pct": -18.0 },
  "observation": "2 of 3 sick-day indicators fired on 2026-06-05",
  "next_actions": ["отдохнуть", "гидратация", "..."],
  "house_quote": "<серьёзный House>",
  "generated_at": "ISO"
}
```

**Anti-spam:** suppress 24ч. Если юзер через Jarvis говорит «болею/болел» — Jarvis шлёт тебе `{ "kind": "sick_day_ack" }`, продлеваешь suppress до явного «уже ок». При «уже ок» снимаешь suppress.
```

- [ ] **Step 6.5.1:** Insert section.

### Step 6.6 — Deploy

- [ ] **Step 6.6.1:**

```bash
scp groups/health-analyzer/scripts/analyze.js root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/health-analyzer/scripts/analyze.js
scp groups/health-analyzer/scripts/analyze.test.js root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/health-analyzer/scripts/analyze.test.js
scp groups/health-analyzer/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/health-analyzer/CLAUDE.md
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw/groups/health-analyzer/scripts && bun test analyze.test.js'
```

Expected: 13 PASS.

- [ ] **Step 6.6.2:** Restart greg agent on VDS (same command as Step 1.3.3, but only `greg`).

**No git commit for Task 6** — install-only.

---

## Task 7: Host trigger (committed)

**Files:**
- Create: `src/modules/health-trigger/sick-day.ts`
- Create: `src/modules/health-trigger/sick-day.test.ts`
- Modify: `src/channels/ios-app/v2/http-handler.ts`

### Step 7.1 — Write failing test for sick-day trigger

Create `src/modules/health-trigger/sick-day.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { sickDayCheck } from './sick-day.js';
import type { HealthUploadDay } from '../../../shared/ios-app-protocol/index.js';

// We mock the session-manager + container-runner imports so we can assert
// the trigger calls writeSessionMessage + wakeContainer when (and only when)
// the threshold rule fires.

const writeSessionMessage = vi.fn();
const wakeContainer = vi.fn(async () => {});
const getSession = vi.fn();

vi.mock('../../session-manager.js', () => ({
  writeSessionMessage: (...args: unknown[]) => writeSessionMessage(...args),
  resolveSession: (groupId: string) => ({ session: { id: 'sess-greg-1', agent_group_id: groupId, status: 'active' } }),
}));
vi.mock('../../container-runner.js', () => ({
  wakeContainer: (...args: unknown[]) => wakeContainer(...args),
}));
vi.mock('../../db/sessions.js', () => ({
  getSession: (...args: unknown[]) => getSession(...args),
}));

function stableDay(date: string, overrides: Partial<HealthUploadDay> = {}): HealthUploadDay {
  return {
    date,
    restingHeartRate: 60,
    hrv: 50,
    wristTempDeviation: 0.0,
    ...overrides,
  };
}

function fourteenDays(): HealthUploadDay[] {
  return Array.from({ length: 14 }, (_, i) =>
    stableDay(`2026-06-${String(i + 1).padStart(2, '0')}`));
}

describe('sickDayCheck', () => {
  beforeEach(() => {
    writeSessionMessage.mockReset();
    wakeContainer.mockReset();
    getSession.mockReset();
    getSession.mockReturnValue({ id: 'sess-greg-1', agent_group_id: 'greg', status: 'active' });
  });

  it('no signals → no write, no wake', async () => {
    await sickDayCheck({ agentGroupId: 'greg', allRows: fourteenDays() });
    expect(writeSessionMessage).not.toHaveBeenCalled();
    expect(wakeContainer).not.toHaveBeenCalled();
  });

  it('1 of 3 signal → no write', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66 });
    await sickDayCheck({ agentGroupId: 'greg', allRows: rows });
    expect(writeSessionMessage).not.toHaveBeenCalled();
  });

  it('2 of 3 signals → writes sick_day_check message and wakes container', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5 });
    await sickDayCheck({ agentGroupId: 'greg', allRows: rows });
    expect(writeSessionMessage).toHaveBeenCalledOnce();
    const callArg = writeSessionMessage.mock.calls[0];
    // writeSessionMessage(agentGroupId, sessionId, msg)
    expect(callArg[0]).toBe('greg');
    expect(callArg[1]).toBe('sess-greg-1');
    expect(callArg[2].kind).toBe('chat');
    const content = JSON.parse(callArg[2].content);
    expect(content.kind).toBe('sick_day_check');
    expect(content.signal.rhr_delta_pct).toBeGreaterThan(0);
    expect(wakeContainer).toHaveBeenCalledOnce();
  });

  it('does not fire when agentGroupId has no active session', async () => {
    getSession.mockReturnValue(undefined);
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 70, hrv: 40, wristTempDeviation: 0.6 });
    await sickDayCheck({ agentGroupId: 'unknown-group', allRows: rows });
    expect(writeSessionMessage).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 7.1.1:** Create the file.
- [ ] **Step 7.1.2:** Run: `pnpm test -- src/modules/health-trigger/sick-day.test.ts`
- [ ] **Step 7.1.3:** Expected: FAIL — `./sick-day.js` does not exist.

### Step 7.2 — Implement sick-day.ts

Create `src/modules/health-trigger/sick-day.ts`:

```ts
/**
 * Host-side sick-day trigger.
 *
 * Called after `appendHealthHistory` writes new rows from the iOS app's
 * `POST /ios/health/upload`. We re-implement the three-threshold rule from
 * `groups/health-analyzer/scripts/analyze.js:sickDayDetect` (deliberately
 * duplicated — the host can't shell out to bun on the request path) and,
 * if 2 of 3 signals fire, write a one-shot wake message into Greg's
 * session inbound DB so he runs `--mode sick-day` on the next poll.
 *
 * Threshold constants stay in sync with analyze.js by convention. Keep them
 * here as plain numbers — if you change one, change both. The TS-side test
 * (sick-day.test.ts) and Bun-side test (analyze.test.js) both pin the
 * canonical 7%/0.4°C/15% values.
 */
import { resolveSession, writeSessionMessage } from '../../session-manager.js';
import { wakeContainer } from '../../container-runner.js';
import { getSession } from '../../db/sessions.js';
import { log } from '../../log.js';
import type { HealthUploadDay } from '../../../shared/ios-app-protocol/index.js';

export const SICK_DAY_THRESHOLDS = {
  rhrPct: 7,
  tempC: 0.4,
  hrvPct: 15,
};

function median(xs: number[]): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

interface Detection {
  date: string;
  matched: number;
  signal: {
    rhr_delta_pct: number | null;
    hrv_delta_pct: number | null;
    temp_delta_c: number | null;
  };
  fires: { rhr: boolean; hrv: boolean; temp: boolean };
}

export function detect(rows: HealthUploadDay[], thresholds = SICK_DAY_THRESHOLDS): Detection | null {
  if (!rows || rows.length < 7) return null;
  const today = rows[rows.length - 1];
  const baseline = rows.slice(-15, -1);
  if (baseline.length < 6) return null;

  function medOf(metric: keyof HealthUploadDay): number | null {
    const vs = baseline
      .map((r) => r[metric])
      .filter((v): v is number => typeof v === 'number' && Number.isFinite(v));
    return vs.length >= 4 ? median(vs) : null;
  }

  const rhrMed = medOf('restingHeartRate');
  const hrvMed = medOf('hrv');
  const tempMed = medOf('wristTempDeviation');

  const todayRhr = typeof today.restingHeartRate === 'number' ? today.restingHeartRate : null;
  const todayHrv = typeof today.hrv === 'number' ? today.hrv : null;
  const todayTemp = typeof today.wristTempDeviation === 'number' ? today.wristTempDeviation : null;

  const rhrDelta = rhrMed !== null && todayRhr !== null ? ((todayRhr - rhrMed) / rhrMed) * 100 : null;
  const hrvDelta = hrvMed !== null && todayHrv !== null ? ((todayHrv - hrvMed) / hrvMed) * 100 : null;
  const tempDelta = tempMed !== null && todayTemp !== null ? todayTemp - tempMed : todayTemp;

  const rhrFires = rhrDelta !== null && rhrDelta >= thresholds.rhrPct;
  const hrvFires = hrvDelta !== null && hrvDelta <= -thresholds.hrvPct;
  const tempFires = tempDelta !== null && tempDelta >= thresholds.tempC;

  const matched = [rhrFires, hrvFires, tempFires].filter(Boolean).length;
  if (matched < 2) return null;

  return {
    date: today.date,
    matched,
    signal: {
      rhr_delta_pct: rhrDelta !== null ? Math.round(rhrDelta * 10) / 10 : null,
      hrv_delta_pct: hrvDelta !== null ? Math.round(hrvDelta * 10) / 10 : null,
      temp_delta_c: tempDelta !== null ? Math.round(tempDelta * 100) / 100 : null,
    },
    fires: { rhr: rhrFires, hrv: hrvFires, temp: tempFires },
  };
}

export interface SickDayCheckArgs {
  /** Agent-group id to wake. NOT the on-disk folder — they may differ
   *  (e.g. folder `health-analyzer` ↔ id `greg`). The HTTP handler resolves
   *  this from env `SICK_DAY_TARGET_AGENT_GROUP_ID` (falls back to undefined,
   *  in which case this function is a no-op). */
  agentGroupId: string | undefined;
  allRows: HealthUploadDay[];   // entire raw.jsonl decoded, oldest→newest
}

export async function sickDayCheck({ agentGroupId, allRows }: SickDayCheckArgs): Promise<void> {
  if (!agentGroupId) return;     // not configured on this install
  const detection = detect(allRows);
  if (!detection) return;

  const { session } = resolveSession(agentGroupId, null, null, 'agent-shared');
  const fresh = getSession(session.id);
  if (!fresh || fresh.status !== 'active') {
    log.warn('sick-day trigger: target session not active, skipping wake', {
      agentGroupId,
      detected: detection,
    });
    return;
  }

  const msgId = `sickday-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  writeSessionMessage(agentGroupId, fresh.id, {
    id: msgId,
    kind: 'chat',
    timestamp: new Date().toISOString(),
    platformId: 'host-sick-day',
    channelType: 'system',
    threadId: null,
    content: JSON.stringify({
      kind: 'sick_day_check',
      detection: { date: detection.date, matched: detection.matched, fires: detection.fires },
      signal: detection.signal,
    }),
    sourceSessionId: null,
    a2aHops: 0,
  });

  log.info('sick-day trigger fired', { agentGroupId, sessionId: fresh.id, detection });
  await wakeContainer(fresh);
}
```

- [ ] **Step 7.2.1:** Create the file.
- [ ] **Step 7.2.2:** Run: `pnpm test -- src/modules/health-trigger/sick-day.test.ts`
- [ ] **Step 7.2.3:** Expected: ALL 4 tests pass.

### Step 7.3 — Wire trigger into http-handler

In `src/channels/ios-app/v2/http-handler.ts`:

1. Add the import at the top:

```ts
import { sickDayCheck } from '../../../modules/health-trigger/sick-day.js';
```

2. Add a helper near the top of the file (after imports) for reading the full raw.jsonl so we can pass `allRows` to the detector:

```ts
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import type { HealthUploadDay } from '../../../../shared/ios-app-protocol/index.js';

function loadAllHealthRows(groupsDir: string, agentFolder: string): HealthUploadDay[] {
  const path = join(groupsDir, agentFolder, 'health', 'raw.jsonl');
  if (!existsSync(path)) return [];
  const text = readFileSync(path, 'utf8');
  const byDate = new Map<string, HealthUploadDay>();
  for (const line of text.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try {
      const row = JSON.parse(s) as HealthUploadDay;
      if (row && row.date) byDate.set(row.date, row);
    } catch { /* skip malformed line */ }
  }
  return [...byDate.keys()].sort().map((d) => byDate.get(d)!);
}
```

3. In the `/ios/health/upload` POST handler (the block from line ~109), find this:

```ts
appendHealthHistory(writeRoot, writeFolder, days);
if (requestId) healthRequestsStore.clear(requestId);
log('health_history (http)', { ... });
res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
```

Replace with:

```ts
appendHealthHistory(writeRoot, writeFolder, days);
if (requestId) healthRequestsStore.clear(requestId);
log('health_history (http)', {
  platformId: pid,
  count: days.length,
  requestId: requestId ?? null,
});
// Fire-and-forget sick-day trigger. Failures here must not block the upload
// response — we log and move on. The trigger reads the full raw.jsonl
// (cheap, ~14 lines typical) and only does work if the rule fires.
// Install-specific: SICK_DAY_TARGET_AGENT_GROUP_ID must be set to the
// agent-group id (NOT folder name) of the health-analyzer agent (e.g. "greg").
// Unset = trigger is a no-op, safe default.
try {
  const allRows = loadAllHealthRows(writeRoot, writeFolder);
  void sickDayCheck({
    agentGroupId: process.env.SICK_DAY_TARGET_AGENT_GROUP_ID,
    allRows,
  }).catch((err) => {
    logWarn('sick-day trigger failed', { err: err instanceof Error ? err.message : String(err) });
  });
} catch (err) {
  logWarn('sick-day trigger setup failed', { err: err instanceof Error ? err.message : String(err) });
}
res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
```

Note: the target agent-group id comes from env var `SICK_DAY_TARGET_AGENT_GROUP_ID` because the folder name and the agent-group id may not match (e.g. folder `health-analyzer` ↔ id `greg` on the current VDS install). Unset env = no-op, safe default for installs without a health analyzer.

- [ ] **Step 7.3.1:** Add imports.
- [ ] **Step 7.3.2:** Add `loadAllHealthRows` helper.
- [ ] **Step 7.3.3:** Replace the post-`appendHealthHistory` block.
- [ ] **Step 7.3.4:** Run full host test suite to confirm nothing else broke:

```bash
pnpm test
```

Expected: ALL pass.

- [ ] **Step 7.3.5:** Verify build:

```bash
pnpm run build
```

Expected: PASS.

### Step 7.4 — Commit

```bash
git add src/modules/health-trigger/sick-day.ts src/modules/health-trigger/sick-day.test.ts src/channels/ios-app/v2/http-handler.ts
git commit -m "$(cat <<'EOF'
health: event-driven sick-day trigger after iOS uploads

Adds src/modules/health-trigger/sick-day.ts: three-threshold rule
(RHR ≥7% above 14-day median, wristTempDeviation ≥+0.4°C,
HRV ≥15% below median; 2-of-3 fires) on the most recent uploaded
day. When fired, writes a sick_day_check message into Greg's
session inbound DB and wakes the container.

Called fire-and-forget from the iOS health upload HTTP handler so
the upload response isn't blocked. Cuts sick-day signal latency
from up to 24h (next daily run) to seconds.

Constants and rule are duplicated in groups/health-analyzer/scripts/
analyze.js for the container-side sick-day mode — kept in sync by
test pins on both sides.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 7.4.1:** Stage + commit + push.

### Step 7.5 — Deploy and smoke test

- [ ] **Step 7.5.0:** Set the target agent-group env var on VDS (one-time):

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && grep -q "^SICK_DAY_TARGET_AGENT_GROUP_ID=" .env || echo "SICK_DAY_TARGET_AGENT_GROUP_ID=greg" >> .env'
```

- [ ] **Step 7.5.1:** Pull + build on VDS:

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && git pull && pnpm install --frozen-lockfile && pnpm run build && launchctl kickstart -k gui/$(id -u)/com.nanoclaw 2>/dev/null || systemctl --user restart nanoclaw'
```

- [ ] **Step 7.5.2:** Inject a synthetic raw.jsonl row that triggers sick-day to smoke-test end-to-end:

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && cat >> groups/health-analyzer/health/raw.jsonl <<EOF
{"date":"2099-01-01","restingHeartRate":75,"hrv":35,"wristTempDeviation":0.6,"sleepHours":6,"ingested_at":'$(date +%s)'000}
EOF
'
```

(Date `2099-01-01` ensures it's the most-recent row without colliding with real data.)

- [ ] **Step 7.5.3:** POST a no-op upload to trigger the handler:

```bash
ssh root@148.253.211.164 'curl -s -X POST http://127.0.0.1:<HOST_PORT>/ios/health/upload \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d "{\"platformId\":\"ios-app-v2:default\",\"days\":[]}"'
```

(Port + token from `.env`. Empty days means `appendHealthHistory` writes nothing new, but `loadAllHealthRows` will still see the synthetic row and the trigger will fire.)

- [ ] **Step 7.5.4:** Watch host log for "sick-day trigger fired":

```bash
ssh root@148.253.211.164 'tail -50 /home/nanoclaw/nanoclaw/logs/nanoclaw.log | grep sick'
```

Expected: a line `sick-day trigger fired` plus Greg container waking up.

- [ ] **Step 7.5.5:** Watch Greg's outbound for a `sick_day` finding being routed to Jarvis, then check user-side delivery in Telegram.

- [ ] **Step 7.5.6:** Clean up the synthetic row from raw.jsonl after verification.

```bash
ssh root@148.253.211.164 'sed -i.bak "/\"2099-01-01\"/d" /home/nanoclaw/nanoclaw/groups/health-analyzer/health/raw.jsonl && rm -f /home/nanoclaw/nanoclaw/groups/health-analyzer/health/raw.jsonl.bak'
```

---

## Verification end-to-end

After all 7 tasks complete:

- [ ] **V1:** Send Telegram "как я?" → expect Jarvis says "Сейчас спрошу Грега" → Jarvis replies with `Грег сказал: «<House quote>»` containing differential reasoning.
- [ ] **V2:** Wait for a real iOS health upload (or trigger one from the app) — confirm new fields (`wristTempDeviation`, `respiratoryRate`, etc.) land in raw.jsonl.
- [ ] **V3:** Inject sick-day synthetic row again (Step 7.5.2 procedure) — confirm critical-severity finding rendered in serious-House tone (less snark, focus on action).
- [ ] **V4:** Confirm no a2a loops: `grep -c 'Agent message routed' logs/nanoclaw.log` for the test window stays within expected hop counts (1-2 per Jarvis→Greg→Jarvis cycle).

---

## Spec self-review against this plan

Spec requirements vs plan tasks:

| Spec section | Implemented in |
|---|---|
| Persona: `house_quote` field, verbatim render | Task 1.1, 1.2 |
| Persona: safety valve at critical | Task 1.1 (in prompt) |
| Differential triggers + mapping | Task 2.1–2.5 |
| Sick-day signal (2 of 3, thresholds) | Task 6.1–6.4 (Greg) + Task 7.1–7.4 (host) |
| Anti-spam suppress 24h | Task 6.5 (Greg CLAUDE.md handler) |
| Schema expansion (4 scalars + Workout) | Task 3 |
| Swift mirror | Task 4 |
| HealthKit query expansion + permissions | Task 5 |
| Recovery composite extension | Task 6.3 |
| Concern directions for new metrics | Task 6.4 |

No gaps. No placeholders (every step has either exact code or exact commands). Method names match across tasks (`sickDayDetect` in Bun-side, `sickDayCheck` + `detect` on host-side — intentionally different because host has its own writer concern wrapping the pure detector).
