# Payne Progress Picture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Payne answers `/progress` (and "покажи прогресс") with one PNG of overall training progress: each exercise against its own start, median overall and per muscle group, records, an exercise grid.

**Architecture:** A deterministic Bun script `groups/payne/scripts/progress.js` computes the progress JSON from Payne's sessions/program/cards (through `schema.js`); `render-progress.cjs` draws it with `@napi-rs/canvas`. The bare `/progress` command is served by the agent-runner without a model turn through a tiny Node shim in `container/skills/payne-progress/serve.cjs`; worded requests go through a new Payne skill `progress`; the weekly retro attaches the picture when a mesocycle closes.

**Tech Stack:** Bun (Payne scripts, `bun:test`), `@napi-rs/canvas` (in the agent image only), Node/TypeScript host (`src/commands.ts`, vitest), SSH/scp deploy to the VDS.

Spec: `docs/superpowers/specs/2026-10-26-payne-progress-picture-design.md`.

## Global Constraints

- Only Payne-native sessions count: file name `^\d{4}-\d{2}-\d{2}\.json$`; antitrainer imports (`-at-<id>`), `baseline*`, `.bak` never.
- Point = session's best **uncapped** e1RM over sets with weight `> 0` and reps `> 0`: `S.e1rm(s, Infinity)`. The capped `S.e1rm` stays for prescriptions — do not touch `schema.js`.
- Segment break: `|ln(b/a)| > ln 1.35` between neighbouring sessions of one slug. Start = median of the segment's first 3 points; now = max of segment points with `daysBetween(date, today) <= 28`; counted only if the segment has ≥ 4 points and ≥ 1 recent point.
- Overall/group = median change of counted exercises; flat band ±2% (`0.02`); weekly line skips weeks with < 3 counted; `enough` = counted ≥ 3.
- Record: segment already has ≥ 3 points and the session's point > segment best × 1.005.
- Grid: current-program slugs in `split` order, first occurrence, segment ≥ 3 points, max 12. Tile caption = last top set «212 кг × 10», never e1RM.
- Picture: 1080 wide, background `#0A0E14`, copper `#C68C4D`, font family `"Liberation Sans"` (the image maps `sans-serif` to Liberation Mono).
- Chat copy: plain Russian, no jargon (Payne's CLAUDE.md table): «запас», not RIR; «расчётный максимум» never shown in the picture.
- `groups/` is gitignored: Payne files are NOT committed; they deploy by scp to the VDS `agents/payne/`, after pulling the VDS copy down and diffing (Payne edits his own files: on 10-25 he changed `build-plan.js` — leave it alone).
- `docs/superpowers/` is gitignored; specs and plans are force-added (`git add -f`), as all 54 earlier specs were.
- Host commits: explicit paths only (a parallel session may share main); never stage `.claude/settings.local.json` or `deploy/vds/*` files. End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Direct push to main.
- VDS: `root@148.253.211.164`, service account `nanoclaw`, repo `/home/nanoclaw/nanoclaw`; Payne data `data/user-memory/owner/payne/`; Payne code `agents/payne/`. Agent image: `$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "nanoclaw-agent-v2-.*:latest" | head -1)`.
- Bun runs locally (`/opt/homebrew/bin/bun`); `@napi-rs/canvas` does not — render tests run in the agent image on the VDS.

## File Structure

| File | Responsibility |
|---|---|
| Create `groups/payne/scripts/progress.js` | Pure `computeProgress` + helpers, `loadProgressInputs(root)`, CLI (`--root`, `--today`, `--png`) |
| Create `groups/payne/scripts/progress.test.js` | bun tests for every rule above + the loader |
| Create `groups/payne/scripts/render-progress.cjs` | `renderProgress(data, outPath)` — the PNG |
| Create `groups/payne/scripts/render-progress.test.js` | PNG written, width 1080, sparse data doesn't crash (image only) |
| Create `container/skills/payne-progress/serve.cjs` | Runner-served `/progress`: runs `progress.js --png`, prints its last JSON line. No `SKILL.md` |
| Modify `src/commands.ts` | New Payne command `progress` with `serve` |
| Modify `src/commands.test.ts`, `src/command-gate.test.ts` | Catalogue + gate expectations for `/progress` |
| Create `groups/payne/skills/progress/SKILL.md` | Worded request: one script call, `send_photo`, comment from `summary` |
| Modify `groups/payne/skills/index.md` | Row for `progress` |
| Modify `groups/payne/skills/retro/SKILL.md` | Attach the picture when the retro closes a mesocycle |

---

### Task 1: progress.js — the numbers

**Files:**
- Create: `groups/payne/scripts/progress.test.js`
- Create: `groups/payne/scripts/progress.js`

**Interfaces:**
- Consumes: `./schema.js` — `S.workingSets(loggedEx)`, `S.setWeight(set)`, `S.topSet(loggedEx)`, `S.e1rm(set, cap)`, `S.SET.reps`, `S.parseSession(raw, {path})`, `S.parseProgram(raw, {path})`.
- Produces (used by Tasks 2–4):
  - `computeProgress({ sessions, program, programs, cards, today })` → `{ generated_at, era_start, sessions, cycles: [{name, short, start}], overall: {change_pct, counted, up, flat, down, weekly: [{week, end, value}]}, groups: [{key, name, change_pct, counted}], records: {month, count, prev_count, items: [{date, slug, name}]}, exercises: [{slug, name, group, points: [{date, e1rm, top}], last_top: {weight, reps}, change_pct}], bodyweight: [{slug, name, last_reps, base_reps}], enough, summary }`
  - `loadProgressInputs(root)` → `{ sessions, program, programs, cards }`
  - CLI: `bun progress.js [--root .] [--today YYYY-MM-DD] [--png <path>]`; with `--png` the last stdout line is `{"photo","summary"}`, or `{"summary"}` alone when `enough` is false. With `--png` it does `await import('./render-progress.cjs')` (Task 2) — only then.

- [ ] **Step 1: Write the failing tests**

Create `groups/payne/scripts/progress.test.js`:

```js
// bun test — progress.js pure functions + loader
import { describe, it, expect } from 'bun:test';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  isoWeek,
  weekEnd,
  isNativeSessionFile,
  collectPoints,
  lastSegment,
  exerciseChange,
  findRecords,
  programSlugs,
  cyclesOf,
  computeProgress,
  loadProgressInputs,
} from './progress.js';

// ---- fixtures ----
const set = (w, r, rir = 0) => ({ weight_kg: w, reps: r, reps_in_reserve: rir });
const sess = (date, exercises) => ({
  date,
  exercises: Object.entries(exercises).map(([exercise_slug, sets]) => ({ exercise_slug, sets })),
});
const pt = (date, e1rm) => ({ date, e1rm, top: { weight: e1rm, reps: 1 } });
// A loaded set whose uncapped e1RM is exactly `e`: w × (1 + 10/30) with reps 10, rir 0.
const e1 = (e) => set((e * 3) / 4, 10);

const program = {
  split: ['upper_a', 'lower_a'],
  weekly_intensity_pattern: [{ week: 1, label: 'лёгкая', weight_modifier: 1 }],
  days: {
    lower_a: { name: 'Ноги А', exercises: [{ exercise_slug: 'legpress' }, { exercise_slug: 'bench' }] },
    upper_a: { name: 'Верх А', exercises: [{ exercise_slug: 'warm' }, { exercise_slug: 'bench' }, { exercise_slug: 'row' }] },
  },
};
const cards = {
  bench: { name_ru: 'Жим', primary_muscle_groups: ['chest_middle'] },
  row: { name_ru: 'Тяга', primary_muscle_groups: ['back_lats'] },
  legpress: { name_ru: 'Жим ногами', primary_muscle_groups: ['legs_quads'] },
  crunch: { name_ru: 'Скручивания', primary_muscle_groups: ['core_abs'] },
};

describe('dates', () => {
  it('ISO week and its Sunday', () => {
    expect(isoWeek('2026-10-25')).toBe('2026-W43');
    expect(isoWeek('2026-01-01')).toBe('2026-W01');
    expect(weekEnd('2026-10-21')).toBe('2026-10-25');
    expect(weekEnd('2026-10-25')).toBe('2026-10-25');
  });
  it('only Payne-native session files count', () => {
    expect(isNativeSessionFile('2026-10-25.json')).toBe(true);
    expect(isNativeSessionFile('2026-05-26-at-210.json')).toBe(false);
    expect(isNativeSessionFile('baseline-from-antitrainer.json')).toBe(false);
    expect(isNativeSessionFile('2026-06-09.json.bak')).toBe(false);
  });
});

describe('collectPoints', () => {
  it('uses the uncapped e1RM, so growth by reps past 12 shows', () => {
    const { loaded } = collectPoints([
      sess('2026-07-01', { curl: [set(65, 12, 2)] }),
      sess('2026-07-03', { curl: [set(65, 15, 2)] }),
    ]);
    const [a, b] = loaded.get('curl');
    expect(b.e1rm).toBeGreaterThan(a.e1rm);
    expect(b.top).toEqual({ weight: 65, reps: 15 });
  });
  it('puts never-loaded exercises in body, drops warmups and timed sets', () => {
    const { loaded, body } = collectPoints([
      sess('2026-07-01', {
        pullup: [set(0, 10), set(0, 8)],
        walk: [{ weight_kg: null, reps: 0, duration_seconds: 300 }],
        plank: [{ weight_kg: 0, reps: 0, duration_seconds: 60 }],
      }),
      sess('2026-07-03', { pullup: [set(-5, 9)] }),
    ]);
    expect(body.get('pullup')).toEqual([
      { date: '2026-07-01', reps: 10 },
      { date: '2026-07-03', reps: 9 },
    ]);
    expect(loaded.size).toBe(0);
    expect(body.has('walk')).toBe(false);
    expect(body.has('plank')).toBe(false);
  });
  it('an exercise loaded even once is not an own-body one', () => {
    const { loaded, body } = collectPoints([
      sess('2026-07-01', { dip: [set(0, 10)] }),
      sess('2026-07-03', { dip: [set(10, 8)] }),
    ]);
    expect(body.has('dip')).toBe(false);
    expect(loaded.get('dip')).toHaveLength(1);
  });
});

describe('exercise change', () => {
  it('restarts the count after a jump past 35% (another machine)', () => {
    const seg = lastSegment([pt('a', 100), pt('b', 102), pt('c', 140), pt('d', 141)]);
    expect(seg.map((p) => p.e1rm)).toEqual([140, 141]);
  });
  it('start = median of the first three, now = best of the last 28 days', () => {
    const pts = [
      pt('2026-08-01', 100),
      pt('2026-08-05', 90),
      pt('2026-08-08', 110),
      pt('2026-09-20', 130), // older than 28 days on 10-26 — out of "now"
      pt('2026-10-16', 120),
      pt('2026-10-24', 99), // deload week — doesn't sink the result
    ];
    expect(exerciseChange(pts, '2026-10-26')).toBeCloseTo(0.2, 5);
  });
  it('not counted with fewer than 4 points or nothing in 28 days', () => {
    expect(exerciseChange([pt('2026-10-01', 100), pt('2026-10-05', 105), pt('2026-10-09', 110)], '2026-10-26')).toBeNull();
    const old = ['2026-07-01', '2026-07-05', '2026-07-09', '2026-07-13'].map((d) => pt(d, 100));
    expect(exerciseChange(old, '2026-10-26')).toBeNull();
  });
  it('only sees points up to asOf', () => {
    const pts = ['2026-09-01', '2026-09-05', '2026-09-09', '2026-09-13', '2026-10-20'].map((d, i) => pt(d, [100, 100, 100, 110, 150][i]));
    expect(exerciseChange(pts, '2026-09-30')).toBeCloseTo(0.1, 5);
  });
});

describe('findRecords', () => {
  it('needs 3 earlier sessions in the segment and +0.5%', () => {
    const loaded = new Map([['bench', [100, 101, 102, 105, 104, 105.3, 106].map((e, i) => pt(`2026-10-0${i + 1}`, e))]]);
    expect(findRecords(loaded).map((r) => r.date)).toEqual(['2026-10-04', '2026-10-07']);
  });
  it('a jump past 35% starts a new segment, weight-finding again', () => {
    const loaded = new Map([['press', [40, 41, 42, 60, 62, 63, 66].map((e, i) => pt(`2026-10-0${i + 1}`, e))]]);
    expect(findRecords(loaded).map((r) => r.date)).toEqual(['2026-10-07']);
  });
});

describe('program and cycles', () => {
  it('program slugs follow the split, first occurrence only', () => {
    expect(programSlugs(program)).toEqual(['warm', 'bench', 'row', 'legpress']);
  });
  it('cycles: short names, those ending before the era dropped', () => {
    const cycles = cyclesOf(
      [
        { name: 'Сила — мезоцикл 1', created_at: '2026-01-10' },
        { name: 'Гипертрофия — мезоцикл 1', created_at: '2026-06-01' },
        { name: 'Гипертрофия — мезоцикл 2', created_at: '2026-07-18T08:00:00Z' },
        { name: 'Без даты' },
      ],
      '2026-06-09',
      '2026-10-26',
    );
    expect(cycles).toEqual([
      { name: 'Гипертрофия — мезоцикл 1', short: 'Г-1', start: '2026-06-01' },
      { name: 'Гипертрофия — мезоцикл 2', short: 'Г-2', start: '2026-07-18' },
    ]);
  });
});

describe('computeProgress', () => {
  // Start in early September (out of the 28-day window on 10-26), then three October sessions.
  // bench +10%, row −5%, legpress +30%, crunch flat (core: overall only).
  const dates = ['2026-09-01', '2026-09-03', '2026-09-05', '2026-10-08', '2026-10-15', '2026-10-22'];
  const series = {
    bench: [100, 100, 100, 105, 108, 110],
    row: [80, 80, 80, 76, 76, 76],
    legpress: [200, 200, 200, 230, 250, 260],
    crunch: [20, 20, 20, 20, 20, 20],
  };
  const sessions = dates.map((d, i) =>
    sess(d, { ...Object.fromEntries(Object.entries(series).map(([slug, v]) => [slug, [e1(v[i])]])), pullup: [set(0, 8 + (i % 2))] }),
  );
  const programs = [{ name: 'Гипертрофия — мезоцикл 3', created_at: '2026-09-28' }];

  it('overall = median of exercises against their own start, with tally', () => {
    const p = computeProgress({ sessions, program, programs, cards, today: '2026-10-26' });
    expect(p.overall).toMatchObject({ change_pct: 5, counted: 4, up: 2, flat: 1, down: 1 });
    expect(p.enough).toBe(true);
    expect(p.era_start).toBe('2026-09-01');
    expect(p.sessions).toBe(6);
  });
  it('groups from cards, sorted, core only in the overall', () => {
    const p = computeProgress({ sessions, program, programs, cards, today: '2026-10-26' });
    expect(p.groups.map((g) => [g.name, g.change_pct])).toEqual([
      ['Ноги', 30],
      ['Грудь', 10],
      ['Спина', -5],
    ]);
  });
  it('grid = program exercises in split order, last top set and change', () => {
    const p = computeProgress({ sessions, program, programs, cards, today: '2026-10-26' });
    expect(p.exercises.map((e) => [e.slug, e.change_pct, e.group])).toEqual([
      ['bench', 10, 'Грудь'],
      ['row', -5, 'Спина'],
      ['legpress', 30, 'Ноги'],
    ]);
    expect(p.exercises[0].last_top).toEqual({ weight: 82.5, reps: 10 });
  });
  it('own body, records, summary', () => {
    const p = computeProgress({ sessions, program, programs, cards, today: '2026-10-26' });
    expect(p.bodyweight).toEqual([{ slug: 'pullup', name: 'pullup', last_reps: 9, base_reps: 8 }]);
    expect(p.records).toMatchObject({ month: '2026-10', count: 6, prev_count: 0 });
    expect(p.summary).toBe(
      'Прогресс +5% — медиана 4 упражнений к их старту: растут 2, стоят 1, падают 1. ' +
        'Ноги +30%, Грудь +10%, Спина −5%. Рекордов в октябре: 6.',
    );
  });
  it('the weekly line skips weeks with fewer than 3 counted exercises', () => {
    const p = computeProgress({ sessions, program, programs, cards, today: '2026-10-26' });
    expect(p.overall.weekly.map((w) => w.week)).toEqual(['2026-W41', '2026-W42', '2026-W43']);
  });
  it('too little data: not enough, honest summary', () => {
    const p = computeProgress({ sessions: sessions.slice(0, 3), program, programs, cards, today: '2026-10-26' });
    expect(p.enough).toBe(false);
    expect(p.summary).toStartWith('Считать прогресс рано: посчитано 0 упражнений');
  });
});

describe('loadProgressInputs', () => {
  it('reads native sessions, current + archived programs, cards; skips imports and dot files', () => {
    const root = mkdtempSync(join(tmpdir(), 'progress-'));
    mkdirSync(join(root, 'sessions'));
    mkdirSync(join(root, 'programs', 'archive'), { recursive: true });
    mkdirSync(join(root, 'exercises'));
    writeFileSync(join(root, 'sessions', '2026-10-01.json'), JSON.stringify(sess('2026-10-01', { bench: [set(60, 8)] })));
    writeFileSync(join(root, 'sessions', '2026-05-26-at-210.json'), JSON.stringify(sess('2026-05-26', { bench: [set(90, 8)] })));
    writeFileSync(join(root, 'sessions', 'baseline.json'), '{}');
    writeFileSync(join(root, 'programs', 'current.json'), JSON.stringify({ ...program, name: 'Г — мезоцикл 3', created_at: '2026-09-28' }));
    writeFileSync(join(root, 'programs', 'archive', 'old.json'), JSON.stringify({ name: 'С — мезоцикл 1', created_at: '2026-06-09' }));
    writeFileSync(join(root, 'programs', 'archive', '._old.json'), 'binary junk');
    writeFileSync(join(root, 'exercises', 'bench.json'), JSON.stringify(cards.bench));

    const inputs = loadProgressInputs(root);
    expect(inputs.sessions.map((s) => s.date)).toEqual(['2026-10-01']);
    expect(inputs.programs.map((p) => p.name).sort()).toEqual(['Г — мезоцикл 3', 'С — мезоцикл 1']);
    expect(inputs.cards).toEqual({ bench: cards.bench });
  });
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd groups/payne/scripts && bun test progress.test.js`
Expected: FAIL — `Cannot find module './progress.js'`.

- [ ] **Step 3: Write the implementation**

Create `groups/payne/scripts/progress.js`:

```js
// groups/payne/scripts/progress.js
//
// Deterministic overall progress — what the /progress picture shows. No LLM.
//
//   Exercise — each exercise against its own start: start = median of its first
//              three sessions, now = its best session of the last 28 days (a whole
//              wave, so a light or deload week doesn't sink it). A jump past ±35%
//              between neighbouring sessions means another machine or plate stack:
//              the count starts over from there.
//   Overall  — median change of the counted exercises + up/flat/down tally; per
//              muscle group the same median. Weekly line = overall as of each ISO
//              week's Sunday.
//   Records  — a session beating its segment's best by >0.5% once the segment
//              already has 3 sessions (the first ones are weight-finding).
//   Grid     — the current program's exercises with ≥3 sessions in their segment.
//   Own body — exercises never loaded: max reps now vs the first three sessions.
//
// Only Payne's own sessions (YYYY-MM-DD.json) count: the antitrainer imports come
// from other gyms and their weights don't compare.
//
// Not a week-to-week chained index: on real data a two-pair first week gave +19%
// and set nearly the whole +28% total (2026-10-26). Against its own start, an
// exercise's noise doesn't accumulate.
//
// Pure computeProgress() + thin CLI. Session/program fields go through ./schema.js.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import * as S from './schema.js';

const CALIBRATION = Math.log(1.35);
const WINDOW_DAYS = 28;
const FLAT_BAND = 0.02;
const RECORD_MARGIN = 1.005;
const MIN_SEGMENT = 4; // start = first three sessions, plus at least one after
const MIN_TILE = 3;
const MIN_COUNTED = 3;
const GRID_MAX = 12;
const DAY_MS = 864e5;

export const GROUPS = [
  { key: 'chest', name: 'Грудь', slugs: ['chest_upper', 'chest_middle', 'chest_lower'] },
  { key: 'back', name: 'Спина', slugs: ['back_lats', 'back_rhomboids', 'back_traps'] },
  { key: 'legs', name: 'Ноги', slugs: ['legs_quads', 'legs_hams', 'legs_glutes', 'legs_calves'] },
  { key: 'shoulders', name: 'Плечи', slugs: ['delts_front', 'delts_side', 'delts_rear'] },
  { key: 'arms', name: 'Руки', slugs: ['biceps', 'triceps', 'forearms'] },
];

const MONTHS_GEN = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
const MONTHS_PREP = ['январе', 'феврале', 'марте', 'апреле', 'мае', 'июне', 'июле', 'августе', 'сентябре', 'октябре', 'ноябре', 'декабре'];

// ---- small helpers --------------------------------------------------------

export function isNativeSessionFile(name) {
  return /^\d{4}-\d{2}-\d{2}\.json$/.test(name);
}

// ISO week key "2026-W43" of a YYYY-MM-DD date.
export function isoWeek(date) {
  const d = new Date(`${date}T00:00:00Z`);
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - day);
  const year = d.getUTCFullYear();
  const week = Math.ceil(((d - Date.UTC(year, 0, 1)) / DAY_MS + 1) / 7);
  return `${year}-W${String(week).padStart(2, '0')}`;
}

// Sunday of the ISO week holding `date`.
export function weekEnd(date) {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 7 - (d.getUTCDay() || 7));
  return d.toISOString().slice(0, 10);
}

const daysBetween = (a, b) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / DAY_MS);
const round1 = (x) => Math.round(x * 10) / 10;
const pct = (x) => Math.round(x * 100);
const signed = (n) => (n > 0 ? `+${n}` : n < 0 ? `−${-n}` : '0');

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// "9 июня"
export function dayMonth(date) {
  return `${Number(date.slice(8, 10))} ${MONTHS_GEN[Number(date.slice(5, 7)) - 1]}`;
}

// Genitive after a number: 1 упражнения, 3 упражнений, 15 упражнений.
const exercisesGen = (n) => (n % 10 === 1 && n % 100 !== 11 ? 'упражнения' : 'упражнений');

function push(map, key, value) {
  if (!map.has(key)) map.set(key, []);
  map.get(key).push(value);
}

// ---- points ---------------------------------------------------------------

/**
 * Per slug, oldest first:
 *   loaded — { date, e1rm, top: { weight, reps } } from sets with weight > 0 and reps > 0;
 *            e1rm is the session's best UNCAPPED estimate (the 12-rep cap would
 *            hide growth by reps: 65×12 and 65×15 read the same capped).
 *   body   — { date, reps } for slugs never loaded in these sessions (weight ≤ 0).
 * Timed sets and warmups have reps 0 and drop out.
 */
export function collectPoints(sessions) {
  const loaded = new Map();
  const body = new Map();
  const sorted = [...sessions].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  for (const session of sorted) {
    for (const lex of session.exercises || []) {
      const slug = lex.exercise_slug;
      const work = S.workingSets(lex).filter((s) => s[S.SET.reps] > 0);
      if (!slug || work.length === 0) continue;
      const heavy = work.filter((s) => S.setWeight(s) > 0);
      if (heavy.length > 0) {
        const top = S.topSet({ sets: heavy });
        push(loaded, slug, {
          date: session.date,
          e1rm: Math.max(...heavy.map((s) => S.e1rm(s, Infinity))),
          top: { weight: S.setWeight(top), reps: top[S.SET.reps] },
        });
      } else {
        push(body, slug, { date: session.date, reps: Math.max(...work.map((s) => s[S.SET.reps])) });
      }
    }
  }
  for (const slug of loaded.keys()) body.delete(slug);
  return { loaded, body };
}

// The points after the last jump past ±35% — the current machine/stack.
export function lastSegment(points) {
  let start = 0;
  for (let i = 1; i < points.length; i++) {
    if (Math.abs(Math.log(points[i].e1rm / points[i - 1].e1rm)) > CALIBRATION) start = i;
  }
  return points.slice(start);
}

/**
 * One exercise's change as of `asOf`, from points up to that day.
 * null = not counted: fewer than 4 points in the segment, or none in the last 28 days.
 */
export function exerciseChange(points, asOf) {
  const seg = lastSegment(points.filter((p) => p.date <= asOf));
  if (seg.length < MIN_SEGMENT) return null;
  const recent = seg.filter((p) => daysBetween(p.date, asOf) <= WINDOW_DAYS);
  if (recent.length === 0) return null;
  const start = median(seg.slice(0, 3).map((p) => p.e1rm));
  return Math.max(...recent.map((p) => p.e1rm)) / start - 1;
}

// Median change + tally over { slug, change } rows (change already non-null).
export function tally(rows) {
  const ch = rows.map((r) => r.change);
  return {
    change_pct: ch.length ? pct(median(ch)) : null,
    counted: ch.length,
    up: ch.filter((c) => c > FLAT_BAND).length,
    flat: ch.filter((c) => Math.abs(c) <= FLAT_BAND).length,
    down: ch.filter((c) => c < -FLAT_BAND).length,
  };
}

function changesAsOf(loaded, asOf) {
  const rows = [];
  for (const [slug, pts] of loaded) {
    const change = exerciseChange(pts, asOf);
    if (change != null) rows.push({ slug, change });
  }
  return rows;
}

export function groupOf(card) {
  const first = card?.primary_muscle_groups?.[0];
  return GROUPS.find((g) => g.slugs.includes(first)) || null;
}

// Records: once a segment has 3 sessions, a session > 0.5% above the segment's best.
export function findRecords(loaded) {
  const out = [];
  for (const [slug, pts] of loaded) {
    let segLen = 1;
    let best = pts[0].e1rm;
    for (let i = 1; i < pts.length; i++) {
      const p = pts[i];
      if (Math.abs(Math.log(p.e1rm / pts[i - 1].e1rm)) > CALIBRATION) {
        segLen = 1;
        best = p.e1rm;
        continue;
      }
      if (segLen >= 3 && p.e1rm > best * RECORD_MARGIN) out.push({ date: p.date, slug });
      best = Math.max(best, p.e1rm);
      segLen++;
    }
  }
  return out.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
}

// Program exercise slugs in split-day order, first occurrence only.
export function programSlugs(program) {
  const order = Array.isArray(program.split) && program.split.length ? program.split : Object.keys(program.days);
  const seen = new Set();
  const out = [];
  for (const key of order) {
    for (const ex of program.days[key]?.exercises || []) {
      const slug = ex.exercise_slug;
      if (slug && !seen.has(slug)) {
        seen.add(slug);
        out.push(slug);
      }
    }
  }
  return out;
}

// Mesocycles that overlap the era, oldest first. "Гипертрофия — мезоцикл 3" → "Г-3".
export function cyclesOf(programs, eraStart, today) {
  const all = programs
    .filter((p) => typeof p?.created_at === 'string' && typeof p?.name === 'string')
    .map((p) => {
      const num = (p.name.match(/(\d+)\s*$/) || [])[1];
      return { name: p.name, short: p.name.trim()[0].toUpperCase() + (num ? `-${num}` : ''), start: p.created_at.slice(0, 10) };
    })
    .filter((c) => c.start <= today)
    .sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
  return all.filter((c, i) => i === all.length - 1 || all[i + 1].start > eraStart);
}

// ---- assembly -------------------------------------------------------------

/**
 * @param sessions parsed native sessions (YYYY-MM-DD.json only)
 * @param program  parsed programs/current.json
 * @param programs every program with name + created_at (archive + current)
 * @param cards    { [slug]: exercise card }
 * @param today    YYYY-MM-DD in the owner's time zone
 */
export function computeProgress({ sessions, program, programs = [], cards = {}, today }) {
  const { loaded, body } = collectPoints(sessions);
  const dates = sessions.map((s) => s.date).sort();
  const eraStart = dates[0] || today;
  const nameOf = (slug) => cards[slug]?.name_ru || slug;

  const rows = changesAsOf(loaded, today);
  const overall = tally(rows);
  const enough = overall.counted >= MIN_COUNTED;

  const weekly = [];
  for (const end of [...new Set(dates.map(weekEnd))].sort()) {
    const asOf = end > today ? today : end;
    const wr = changesAsOf(loaded, asOf);
    if (wr.length >= MIN_COUNTED) weekly.push({ week: isoWeek(end), end: asOf, value: round1((1 + median(wr.map((r) => r.change))) * 100) });
  }

  const groups = [];
  for (const g of GROUPS) {
    const gr = rows.filter((r) => groupOf(cards[r.slug])?.key === g.key);
    if (gr.length) groups.push({ key: g.key, name: g.name, change_pct: tally(gr).change_pct, counted: gr.length });
  }
  groups.sort((a, b) => b.change_pct - a.change_pct);

  const month = today.slice(0, 7);
  const prevDate = new Date(`${month}-01T00:00:00Z`);
  prevDate.setUTCMonth(prevDate.getUTCMonth() - 1);
  const prevMonth = prevDate.toISOString().slice(0, 7);
  const allRecords = findRecords(loaded);
  const records = {
    month,
    count: allRecords.filter((r) => r.date.startsWith(month)).length,
    prev_count: allRecords.filter((r) => r.date.startsWith(prevMonth)).length,
    items: allRecords.filter((r) => r.date.startsWith(month)).map((r) => ({ ...r, name: nameOf(r.slug) })),
  };

  const exercises = [];
  for (const slug of programSlugs(program)) {
    const pts = loaded.get(slug);
    if (!pts) continue;
    const seg = lastSegment(pts);
    if (seg.length < MIN_TILE) continue;
    const change = exerciseChange(pts, today);
    exercises.push({
      slug,
      name: nameOf(slug),
      group: groupOf(cards[slug])?.name || null,
      points: seg.map((p) => ({ date: p.date, e1rm: round1(p.e1rm), top: p.top })),
      last_top: seg[seg.length - 1].top,
      change_pct: change == null ? null : pct(change),
    });
    if (exercises.length === GRID_MAX) break;
  }

  const bodyweight = [];
  for (const [slug, pts] of body) {
    if (pts.length < 2 || daysBetween(pts[pts.length - 1].date, today) > WINDOW_DAYS) continue;
    bodyweight.push({
      slug,
      name: nameOf(slug),
      last_reps: pts[pts.length - 1].reps,
      base_reps: Math.round(median(pts.slice(0, 3).map((p) => p.reps))),
    });
  }

  const cycles = cyclesOf(programs, eraStart, today);
  const monthName = MONTHS_PREP[Number(month.slice(5, 7)) - 1];
  const summary = enough
    ? `Прогресс ${signed(overall.change_pct)}% — медиана ${overall.counted} ${exercisesGen(overall.counted)} к их старту: ` +
      `растут ${overall.up}, стоят ${overall.flat}, падают ${overall.down}. ` +
      (groups.length ? groups.map((g) => `${g.name} ${signed(g.change_pct)}%`).join(', ') + '. ' : '') +
      `Рекордов в ${monthName}: ${records.count}.`
    : `Считать прогресс рано: посчитано ${overall.counted} ${exercisesGen(overall.counted)}, нужно хотя бы ${MIN_COUNTED}. ` +
      'Упражнению нужно 4 тренировки на одном тренажёре и одна за последние 4 недели.';

  return {
    generated_at: today,
    era_start: eraStart,
    sessions: sessions.length,
    cycles,
    overall: { ...overall, weekly },
    groups,
    records,
    exercises,
    bodyweight,
    enough,
    summary,
  };
}

// ---- loading --------------------------------------------------------------

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

/** Everything computeProgress needs, read from an agent home (`root`). */
export function loadProgressInputs(root) {
  const sessionsDir = join(root, 'sessions');
  const sessions = [];
  for (const f of readdirSync(sessionsDir).filter(isNativeSessionFile).sort()) {
    const path = join(sessionsDir, f);
    try {
      sessions.push(S.parseSession(readJson(path), { path }));
    } catch (e) {
      console.error('WARN skip: ' + e.message);
    }
  }
  const programPath = join(root, 'programs', 'current.json');
  const program = S.parseProgram(readJson(programPath), { path: programPath });
  const programs = [program];
  const archiveDir = join(root, 'programs', 'archive');
  if (existsSync(archiveDir)) {
    // Skip dot files: a macOS scp leaves ._<name>.json AppleDouble junk beside the real ones.
    for (const f of readdirSync(archiveDir).filter((x) => x.endsWith('.json') && !x.startsWith('.'))) {
      try {
        programs.push(readJson(join(archiveDir, f)));
      } catch (e) {
        console.error('WARN skip: ' + e.message);
      }
    }
  }
  const cards = {};
  for (const s of sessions) {
    for (const ex of s.exercises || []) {
      const slug = ex.exercise_slug;
      const path = join(root, 'exercises', `${slug}.json`);
      if (!slug || slug in cards || !existsSync(path)) continue;
      try {
        cards[slug] = readJson(path);
      } catch (e) {
        console.error('WARN skip: ' + e.message);
      }
    }
  }
  return { sessions, program, programs, cards };
}

export function ownerToday(tz = process.env.OWNER_TZ) {
  try {
    return new Intl.DateTimeFormat('en-CA', { timeZone: tz || undefined }).format(new Date());
  } catch {
    return new Date().toISOString().slice(0, 10);
  }
}

// ---- CLI ------------------------------------------------------------------

const HELP = `progress.js — суммарный прогресс: каждое упражнение к своему старту, медиана, рекорды

  bun progress.js [--root .] [--today YYYY-MM-DD] [--png /tmp/progress.png]

Без --png — полный JSON. С --png рисует картинку (render-progress.cjs) и печатает
последней строкой {"photo","summary"}; мало данных — только {"summary"}, картинки нет.
Корень — дом агента (sessions/, programs/, exercises/); по умолчанию текущая папка.`;

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) out[key] = true;
    else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

if (import.meta.main) {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || args.h) {
    console.log(HELP);
    process.exit(0);
  }
  const root = typeof args.root === 'string' ? args.root : '.';
  const today = typeof args.today === 'string' ? args.today : ownerToday();
  const progress = computeProgress({ ...loadProgressInputs(root), today });
  if (typeof args.png !== 'string') {
    console.log(JSON.stringify(progress, null, 2));
  } else if (!progress.enough) {
    console.log(JSON.stringify({ summary: progress.summary }));
  } else {
    const { renderProgress } = await import('./render-progress.cjs');
    renderProgress(progress, args.png);
    console.log(JSON.stringify({ photo: args.png, summary: progress.summary }));
  }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd groups/payne/scripts && bun test progress.test.js`
Expected: `20 pass, 0 fail`.

- [ ] **Step 5: Check the numbers on a copy of the real data**

```bash
SP=$(mktemp -d)
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw/data/user-memory/owner/payne && tar czf - sessions programs exercises' | tar xzf - -C "$SP"
cd groups/payne/scripts && bun progress.js --root "$SP" --today 2026-10-26 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['summary']); print(d['sessions'], [c['short'] for c in d['cycles']], len(d['exercises']))"
```

Expected (data as of 2026-10-26; later sessions shift it slightly):
`Прогресс +7% — медиана 15 упражнений к их старту: растут 10, стоят 2, падают 3. Ноги +40%, Руки +16%, Спина +9%, Плечи +2%, Грудь −9%. Рекордов в октябре: 9.` then `46 ['С-1', 'Г-1', 'Г-2', 'Г-3'] 10`.

- [ ] **Step 6: No commit**

`groups/` is gitignored; the files ship by scp in Task 5.

---

### Task 2: render-progress.cjs — the picture

**Files:**
- Create: `groups/payne/scripts/render-progress.test.js`
- Create: `groups/payne/scripts/render-progress.cjs`

**Interfaces:**
- Consumes: the `computeProgress` output shape from Task 1 (with `enough === true`).
- Produces: `renderProgress(data, outPath)` → writes a PNG, returns `outPath`. CommonJS (`module.exports`), required by `progress.js --png` through `await import('./render-progress.cjs')`.

- [ ] **Step 1: Write the failing test**

Create `groups/payne/scripts/render-progress.test.js`:

```js
// bun test — render-progress.cjs. Needs @napi-rs/canvas, which lives in the agent
// image only: run it there (docker run --entrypoint bun …), not on a bare host.
import { describe, it, expect } from 'bun:test';
import { readFileSync, rmSync, existsSync } from 'node:fs';
import { renderProgress } from './render-progress.cjs';

const point = (date, e1rm) => ({ date, e1rm, top: { weight: 60, reps: 10 } });
const full = {
  generated_at: '2026-10-26',
  era_start: '2026-06-09',
  sessions: 46,
  cycles: [
    { name: 'Гипертрофия — мезоцикл 2', short: 'Г-2', start: '2026-08-27' },
    { name: 'Гипертрофия — мезоцикл 3', short: 'Г-3', start: '2026-10-16' },
  ],
  overall: {
    change_pct: 7,
    counted: 15,
    up: 10,
    flat: 2,
    down: 3,
    weekly: [
      { week: '2026-W34', end: '2026-08-23', value: 104 },
      { week: '2026-W36', end: '2026-09-06', value: 115.7 },
      { week: '2026-W43', end: '2026-10-25', value: 107.1 },
    ],
  },
  groups: [
    { key: 'legs', name: 'Ноги', change_pct: 40, counted: 4 },
    { key: 'chest', name: 'Грудь', change_pct: -9, counted: 4 },
  ],
  records: { month: '2026-10', count: 2, prev_count: 11, items: [{ date: '2026-10-19', slug: 'a', name: 'Жим лежа в тренажере Хаммер' }, { date: '2026-10-21', slug: 'a', name: 'Жим лежа в тренажере Хаммер' }] },
  exercises: [
    { slug: 'a', name: 'Жим штанги лежа широким хватом', group: 'Грудь', points: [point('2026-10-01', 80), point('2026-10-08', 84), point('2026-10-15', 88)], last_top: { weight: 62.5, reps: 11 }, change_pct: 7 },
    { slug: 'b', name: 'Жим ногами', group: 'Ноги', points: [point('2026-10-01', 280), point('2026-10-08', 280), point('2026-10-15', 280)], last_top: { weight: 212, reps: 10 }, change_pct: null },
  ],
  bodyweight: [{ slug: 'p', name: 'Подтягивания параллельным хватом', last_reps: 8, base_reps: 9 }],
  enough: true,
  summary: '…',
};

function png(path) {
  const buf = readFileSync(path);
  expect(buf.subarray(1, 4).toString()).toBe('PNG');
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

describe('renderProgress', () => {
  it('writes a 1080-wide PNG whose height follows the content', () => {
    const out = '/tmp/progress-render-test.png';
    if (existsSync(out)) rmSync(out);
    expect(renderProgress(full, out)).toBe(out);
    const { width, height } = png(out);
    expect(width).toBe(1080);
    expect(height).toBeGreaterThan(1200);
    expect(height).toBeLessThan(4000);
  });
  it('survives empty groups, grid, records, own body and a one-week line', () => {
    const out = '/tmp/progress-render-empty.png';
    const sparse = {
      ...full,
      overall: { ...full.overall, weekly: [full.overall.weekly[0]] },
      groups: [],
      records: { month: '2026-10', count: 0, prev_count: 0, items: [] },
      exercises: [],
      bodyweight: [],
      cycles: [],
    };
    renderProgress(sparse, out);
    expect(png(out).width).toBe(1080);
  });
});
```

- [ ] **Step 2: Stage the scripts on the VDS and see it fail**

```bash
ssh root@148.253.211.164 'rm -rf /tmp/payne-stage && mkdir -p /tmp/payne-stage/scripts'
scp groups/payne/scripts/{schema.js,progress.js,progress.test.js,render-progress.test.js} root@148.253.211.164:/tmp/payne-stage/scripts/
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /tmp/payne-stage; IMG=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "nanoclaw-agent-v2-.*:latest" | head -1); sudo -u nanoclaw docker run --rm --entrypoint bash -v /tmp/payne-stage:/workspace/agent -w /workspace/agent/scripts $IMG -c "bun test render-progress.test.js 2>&1 | tail -5"'
```

Expected: FAIL — `Cannot find module './render-progress.cjs'`.

- [ ] **Step 3: Write the renderer**

Create `groups/payne/scripts/render-progress.cjs`:

```js
// groups/payne/scripts/render-progress.cjs
//
// Draws progress.js output as one PNG for the chat. Top: the overall change, its
// weekly line with mesocycle marks, muscle-group bars, records. Below: a grid of
// the program's exercises, the own-body line, the era footer. 1080 wide, height
// by content. Colors: the app's background, Payne's copper (AgentIdentity).
//
//   const { renderProgress } = require('./render-progress.cjs');
//   renderProgress(progressJson, '/tmp/progress.png');

const { createCanvas } = require('@napi-rs/canvas');
const fs = require('node:fs');

const W = 1080;
const PAD = 56;
const INNER = W - 2 * PAD;
const BG = '#0A0E14';
const CARD = '#141A23';
const COPPER = '#C68C4D';
const TEXT = '#F2F2F2';
const MUTED = '#8A93A0';
const RULE = '#232B36';
const RED = '#E06C5A';
const GRAY = '#6B7380';
// The image's fontconfig maps sans-serif to Liberation Mono — name the family.
const FONT = '"Liberation Sans"';
const MONTHS_GEN = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
const MONTHS_PREP = ['январе', 'феврале', 'марте', 'апреле', 'мае', 'июне', 'июле', 'августе', 'сентябре', 'октябре', 'ноябре', 'декабре'];

const signed = (n) => (n > 0 ? `+${n}` : n < 0 ? `−${-n}` : '0');
const tone = (p) => (p == null || Math.abs(p) < 2 ? GRAY : p > 0 ? COPPER : RED);
const dayMonth = (d) => `${Number(d.slice(8, 10))} ${MONTHS_GEN[Number(d.slice(5, 7)) - 1]}`;
const kg = (w) => `${String(w).replace('.', ',')} кг`;
// 1 тренировка, 3 тренировки, 46 тренировок
const plural = (n, one, few, many) => {
  const a = n % 100;
  const b = n % 10;
  return a > 10 && a < 20 ? many : b === 1 ? one : b >= 2 && b <= 4 ? few : many;
};

function font(ctx, px, bold = false) {
  ctx.font = `${bold ? 'bold ' : ''}${px}px ${FONT}`;
}

function fit(ctx, text, maxW) {
  if (ctx.measureText(text).width <= maxW) return text;
  let t = text;
  while (t.length > 1 && ctx.measureText(`${t}…`).width > maxW) t = t.slice(0, -1);
  return `${t.trimEnd()}…`;
}

// Greedy word wrap into at most maxLines; whatever doesn't fit ends the last line with "…".
function wrap(ctx, text, maxW, maxLines) {
  const words = text.split(/\s+/);
  const lines = [];
  let i = 0;
  while (i < words.length && lines.length < maxLines) {
    let line = words[i++];
    while (i < words.length && ctx.measureText(`${line} ${words[i]}`).width <= maxW) line += ` ${words[i++]}`;
    lines.push(line);
  }
  if (i < words.length) lines[lines.length - 1] = `${lines[lines.length - 1]} ${words.slice(i).join(' ')}`;
  return lines.map((l) => fit(ctx, l, maxW));
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function lines(ctx, list, x, y, lineH, color) {
  ctx.fillStyle = color;
  for (const l of list) {
    ctx.fillText(l, x, y);
    y += lineH;
  }
  return y;
}

// The weekly line: copper stroke + 15% fill, dashed 100 baseline, cycle marks.
function drawLine(ctx, weekly, cycles, x, y, w, h) {
  const vals = weekly.map((p) => p.value);
  const lo = Math.min(100, ...vals) - 3;
  const hi = Math.max(100, ...vals) + 3;
  const X = (i) => x + (weekly.length === 1 ? w / 2 : (i / (weekly.length - 1)) * w);
  const Y = (v) => y + h - ((v - lo) / (hi - lo)) * h;

  ctx.strokeStyle = RULE;
  ctx.lineWidth = 2;
  ctx.setLineDash([8, 8]);
  ctx.beginPath();
  ctx.moveTo(x, Y(100));
  ctx.lineTo(x + w, Y(100));
  ctx.stroke();
  font(ctx, 20);
  ctx.fillStyle = MUTED;
  ctx.fillText('старт', x, Y(100) - 8);

  font(ctx, 22);
  for (const c of cycles) {
    const i = weekly.findIndex((p) => p.end >= c.start);
    if (i <= 0) continue;
    ctx.strokeStyle = RULE;
    ctx.beginPath();
    ctx.moveTo(X(i), y);
    ctx.lineTo(X(i), y + h);
    ctx.stroke();
    ctx.fillStyle = MUTED;
    ctx.fillText(c.short, X(i) + 8, y + 22);
  }
  ctx.setLineDash([]);

  ctx.beginPath();
  weekly.forEach((p, i) => (i ? ctx.lineTo(X(i), Y(p.value)) : ctx.moveTo(X(i), Y(p.value))));
  ctx.lineTo(X(weekly.length - 1), y + h);
  ctx.lineTo(X(0), y + h);
  ctx.closePath();
  ctx.fillStyle = 'rgba(198, 140, 77, 0.15)';
  ctx.fill();

  ctx.beginPath();
  weekly.forEach((p, i) => (i ? ctx.lineTo(X(i), Y(p.value)) : ctx.moveTo(X(i), Y(p.value))));
  ctx.strokeStyle = COPPER;
  ctx.lineWidth = 4;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.stroke();

  const last = weekly[weekly.length - 1];
  ctx.beginPath();
  ctx.arc(X(weekly.length - 1), Y(last.value), 8, 0, 2 * Math.PI);
  ctx.fillStyle = COPPER;
  ctx.fill();
  ctx.lineWidth = 3;
  ctx.strokeStyle = BG;
  ctx.stroke();
}

function drawSpark(ctx, values, x, y, w, h) {
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const X = (i) => x + (values.length === 1 ? w / 2 : (i / (values.length - 1)) * w);
  const Y = (v) => (hi === lo ? y + h / 2 : y + h - ((v - lo) / (hi - lo)) * h);
  ctx.beginPath();
  values.forEach((v, i) => (i ? ctx.lineTo(X(i), Y(v)) : ctx.moveTo(X(i), Y(v))));
  ctx.strokeStyle = COPPER;
  ctx.lineWidth = 3;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.stroke();
  ctx.beginPath();
  ctx.arc(X(values.length - 1), Y(values[values.length - 1]), 6, 0, 2 * Math.PI);
  ctx.fillStyle = COPPER;
  ctx.fill();
}

function drawTile(ctx, ex, x, y, w, h) {
  roundRect(ctx, x, y, w, h, 16);
  ctx.fillStyle = CARD;
  ctx.fill();
  font(ctx, 22);
  lines(ctx, wrap(ctx, ex.name, w - 32, 2), x + 16, y + 34, 28, TEXT);
  drawSpark(ctx, ex.points.map((p) => p.e1rm), x + 16, y + 84, w - 40, 64);
  font(ctx, 26);
  ctx.fillStyle = TEXT;
  ctx.fillText(`${kg(ex.last_top.weight)} × ${ex.last_top.reps}`, x + 16, y + h - 22);
  const change = ex.change_pct == null ? '—' : `${signed(ex.change_pct)}%`;
  ctx.fillStyle = ex.change_pct == null ? GRAY : tone(ex.change_pct);
  ctx.fillText(change, x + w - 16 - ctx.measureText(change).width, y + h - 22);
}

/** Render `data` (progress.js output, enough === true) to a PNG at outPath. */
function renderProgress(data, outPath) {
  const canvas = createCanvas(W, 4000);
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = BG;
  ctx.fillRect(0, 0, W, 4000);
  let y = PAD + 28;

  font(ctx, 28);
  ctx.fillStyle = MUTED;
  ctx.fillText(`Прогресс · ${dayMonth(data.generated_at)}`, PAD, y);
  y += 132;

  const o = data.overall;
  font(ctx, 132, true);
  ctx.fillStyle = tone(o.change_pct) === GRAY ? TEXT : tone(o.change_pct);
  ctx.fillText(`${signed(o.change_pct)}%`, PAD, y);
  y += 52;
  font(ctx, 30);
  const sub = `медиана ${o.counted} ${o.counted % 10 === 1 && o.counted % 100 !== 11 ? 'упражнения' : 'упражнений'} к их старту · растут ${o.up}, стоят ${o.flat}, падают ${o.down}`;
  y = lines(ctx, wrap(ctx, sub, INNER, 2), PAD, y, 40, MUTED) + 24;

  if (o.weekly.length >= 2) {
    drawLine(ctx, o.weekly, data.cycles, PAD, y, INNER, 280);
    y += 280 + 56;
  }

  const maxAbs = Math.max(10, ...data.groups.map((g) => Math.abs(g.change_pct)));
  const trackX = PAD + 170;
  const trackW = INNER - 170 - 120;
  for (const g of data.groups) {
    font(ctx, 28);
    ctx.fillStyle = MUTED;
    ctx.fillText(g.name, PAD, y);
    roundRect(ctx, trackX, y - 22, trackW, 24, 12);
    ctx.fillStyle = CARD;
    ctx.fill();
    roundRect(ctx, trackX, y - 22, Math.max(24, (Math.abs(g.change_pct) / maxAbs) * trackW), 24, 12);
    ctx.fillStyle = tone(g.change_pct);
    ctx.fill();
    const v = `${signed(g.change_pct)}%`;
    ctx.fillStyle = TEXT;
    ctx.fillText(v, W - PAD - ctx.measureText(v).width, y);
    y += 56;
  }
  y += 8;

  const r = data.records;
  const counts = new Map();
  for (const it of r.items) counts.set(it.name, (counts.get(it.name) || 0) + 1);
  const list = [...counts].sort((a, b) => b[1] - a[1]).map(([n, c]) => (c > 1 ? `${n} ×${c}` : n)).join(', ');
  const monthIdx = Number(r.month.slice(5, 7)) - 1;
  const prevIdx = (monthIdx + 11) % 12;
  const rec = `Рекордов в ${MONTHS_PREP[monthIdx]}: ${r.count} (в ${MONTHS_PREP[prevIdx]} ${r.prev_count})${list ? ` — ${list}` : ''}`;
  font(ctx, 26);
  y = lines(ctx, wrap(ctx, rec, INNER, 2), PAD, y, 36, TEXT) + 20;

  ctx.fillStyle = RULE;
  ctx.fillRect(PAD, y, INNER, 2);
  y += 40;

  const gap = 16;
  const tileW = (INNER - 2 * gap) / 3;
  const tileH = 220;
  data.exercises.forEach((ex, i) => {
    drawTile(ctx, ex, PAD + (i % 3) * (tileW + gap), y + Math.floor(i / 3) * (tileH + gap), tileW, tileH);
  });
  if (data.exercises.length) y += Math.ceil(data.exercises.length / 3) * (tileH + gap) + 24;

  font(ctx, 26);
  if (data.bodyweight.length) {
    const own = `Свой вес, повторы: ${data.bodyweight.map((b) => `${b.name} ${b.last_reps} (было ${b.base_reps})`).join(', ')}`;
    y = lines(ctx, wrap(ctx, own, INNER, 3), PAD, y + 8, 36, TEXT) + 12;
  }
  font(ctx, 22);
  const n = data.cycles.length;
  const foot =
    `с ${dayMonth(data.era_start)} · ${n} ${plural(n, 'цикл', 'цикла', 'циклов')} · ` +
    `${data.sessions} ${plural(data.sessions, 'тренировка', 'тренировки', 'тренировок')} · ` +
    'старт упражнения — медиана первых трёх тренировок, сейчас — лучшая за 4 недели';
  y = lines(ctx, wrap(ctx, foot, INNER, 2), PAD, y + 8, 30, MUTED);

  const height = Math.ceil(y + PAD - 30);
  const out = createCanvas(W, height);
  out.getContext('2d').drawImage(canvas, 0, 0);
  fs.writeFileSync(outPath, out.toBuffer('image/png'));
  return outPath;
}

module.exports = { renderProgress };
```

- [ ] **Step 4: Run both test files in the image**

```bash
scp groups/payne/scripts/render-progress.cjs root@148.253.211.164:/tmp/payne-stage/scripts/
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /tmp/payne-stage; IMG=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "nanoclaw-agent-v2-.*:latest" | head -1); sudo -u nanoclaw docker run --rm --entrypoint bash -v /tmp/payne-stage:/workspace/agent -w /workspace/agent/scripts $IMG -c "bun test progress.test.js render-progress.test.js 2>&1 | tail -5"'
```

Expected: `22 pass, 0 fail`.

- [ ] **Step 5: Render the real data and look at it**

```bash
ssh root@148.253.211.164 'set -e; cd /home/nanoclaw/nanoclaw/data/user-memory/owner/payne; mkdir -p /tmp/payne-stage/data; cp -r sessions programs exercises /tmp/payne-stage/data/; chown -R nanoclaw:nanoclaw /tmp/payne-stage; IMG=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "nanoclaw-agent-v2-.*:latest" | head -1); sudo -u nanoclaw docker run --rm --entrypoint bash -v /tmp/payne-stage:/workspace/agent -w /workspace/agent $IMG -c "bun scripts/progress.js --root data --png /workspace/agent/out.png"'
scp root@148.253.211.164:/tmp/payne-stage/out.png /tmp/progress-real.png
```

Expected: last stdout line `{"photo":"/workspace/agent/out.png","summary":"Прогресс +7% …"}` and no `WARN skip`. Open `/tmp/progress-real.png` (Read tool) and check: proportional font (not monospace), hero `+7%` in copper, weekly line with Г-2/Г-3 marks, 5 group bars (Грудь red), records line, 10 tiles with names on up to two lines, own-body line, footer «с 9 июня · 4 цикла · 46 тренировок · …». No text runs off the right edge.

- [ ] **Step 6: No commit** (gitignored; scp in Task 5).

---

### Task 3: `/progress` served without the model

**Files:**
- Create: `container/skills/payne-progress/serve.cjs`
- Modify: `src/commands.ts` (the `AGENT_COMMANDS` array, after the Payne `workout` entry)
- Modify: `src/commands.test.ts`
- Modify: `src/command-gate.test.ts`

**Interfaces:**
- Consumes: `progress.js --png <path>` CLI contract from Task 1 (cwd `/workspace/agent`, last stdout line JSON).
- Produces: `AGENT_COMMANDS` entry `{ agent: 'payne', command: 'progress', description: 'Прогресс', prompt, serve: 'payne-progress/serve.cjs' }`. The runner (`container/agent-runner/src/command-serve.ts`, unchanged) runs `node /app/skills/payne-progress/serve.cjs` with cwd `/workspace/agent`; `{photo, summary}` → photo sent, summary kept as a `<served>` note; `{summary}` alone or a failure → the row goes to the model with `prompt`.

- [ ] **Step 1: Write the failing tests**

In `src/commands.test.ts` replace the first test and the serve test:

```ts
  it('gives every agent /new plus its own commands', () => {
    const forAgent = (agent: string): string[] =>
      appCommands()
        .filter((c) => c.agent_id === undefined || c.agent_id === agent)
        .map((c) => c.command);
    expect(forAgent('jarvis')).toEqual(['/new', '/surf']);
    expect(forAgent('payne')).toEqual(['/new', '/workout', '/progress']);
    expect(forAgent('gordon')).toEqual(['/new', '/food']);
    expect(forAgent('greg')).toEqual(['/new', '/health']);
    expect(forAgent('scrooge')).toEqual(['/new', '/money']);
  });
```

```ts
  it('names serve scripts the runner will run (<skill>/<name>.cjs under the skills mount)', () => {
    // Mirrors container/agent-runner/src/command-serve.ts SERVE_RE.
    const served = AGENT_COMMANDS.filter((c) => c.serve);
    expect(served.map((c) => c.command)).toEqual(['surf', 'progress']);
    for (const c of served) expect(c.serve).toMatch(/^[a-z0-9-]+\/[a-z0-9-]+\.cjs$/);
  });
```

In `src/command-gate.test.ts`, inside the same `describe` as the `/surf` serve test, add:

```ts
  it('hands a bare /progress to Payne\'s runner script, and /progress with words to the model', () => {
    const bare = gateCommand(msg('/progress'), null, 'payne', 'payne');
    expect(bare).toMatchObject({ action: 'agent_command', command: 'progress', serve: 'payne-progress/serve.cjs' });
    const worded = gateCommand(msg('/progress по ногам'), null, 'payne', 'payne');
    expect(worded.action).toBe('agent_command');
    if (worded.action !== 'agent_command') return;
    expect(worded.serve).toBeUndefined();
    expect(worded.text).toContain('скилл progress');
    expect(worded.text).toContain('по ногам');
  });
```

- [ ] **Step 2: Run them to see them fail**

Run: `pnpm exec vitest run src/commands.test.ts src/command-gate.test.ts`
Expected: FAIL — payne list lacks `/progress`; served list is `['surf']`; gate returns `pass` for `/progress`.

- [ ] **Step 3: Add the command**

In `src/commands.ts`, after the Payne `workout` entry:

```ts
  {
    agent: 'payne',
    command: 'progress',
    description: 'Прогресс',
    // A bare /progress is the picture from scripts/progress.js, served by the
    // runner without a model turn. Words after it, or too little data → this prompt.
    prompt: (args) => `Покажи прогресс — сразу скилл progress.${args ? ` ${args}` : ''}`,
    serve: 'payne-progress/serve.cjs',
  },
```

Create `container/skills/payne-progress/serve.cjs`:

```js
#!/usr/bin/env node
// Payne's /progress, answered by the runner without a model turn
// (src/commands.ts `serve` → container/agent-runner/src/command-serve.ts).
// The work lives in Payne's own scripts; this runs progress.js with --png and
// passes its last JSON line on: { photo, summary } normally, { summary } alone
// when there is too little data — then the runner hands the command to the
// model, which says so in Payne's voice.
// No SKILL.md here on purpose: container/skills is mounted for every agent, and
// this is no skill for them — only the runner calls it.
const { execFileSync } = require('node:child_process');

const photo = `/tmp/progress-${Date.now()}.png`;
const out = execFileSync('bun', ['/workspace/agent/scripts/progress.js', '--png', photo], {
  cwd: '/workspace/agent',
  encoding: 'utf8',
  timeout: 100_000,
});
const lines = out.trim().split('\n');
console.log(lines[lines.length - 1]);
```

- [ ] **Step 4: Run tests and the build**

Run: `pnpm exec vitest run src/commands.test.ts src/command-gate.test.ts && pnpm run build`
Expected: all pass; build clean.

- [ ] **Step 5: Run the whole host suite**

Run: `pnpm test`
Expected: no new failures.

- [ ] **Step 6: Commit**

```bash
git add src/commands.ts src/commands.test.ts src/command-gate.test.ts container/skills/payne-progress/serve.cjs
git commit -m "feat(payne): /progress — the progress picture, served without the model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(Push happens in Task 5, together with the deploy.)

---

### Task 4: Payne's skills

**Files:**
- Create: `groups/payne/skills/progress/SKILL.md`
- Modify: `groups/payne/skills/index.md` (table)
- Modify: `groups/payne/skills/retro/SKILL.md` (new section after «## Сообщение бойцу»)

**Interfaces:**
- Consumes: CLI from Task 1; `send_photo` MCP tool (`path`, optional `caption`); `scripts/cycle-status.js` → JSON with `cycle_complete`.

- [ ] **Step 1: Pull the live VDS copies and diff**

```bash
D=$(mktemp -d)
scp root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/payne/skills/index.md "$D/index.md"
scp root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/payne/skills/retro/SKILL.md "$D/retro.md"
diff "$D/index.md" groups/payne/skills/index.md; diff "$D/retro.md" groups/payne/skills/retro/SKILL.md
```

Expected: no diff. If the VDS copy differs (Payne edited it), copy the VDS version over the local one first and make the edits below on top of it.

- [ ] **Step 2: Create the skill**

Create `groups/payne/skills/progress/SKILL.md`:

```markdown
---
name: progress
description: Use when the owner asks how training progress is going overall, or asks to show or draw it ("прогресс", "как прогресс", "покажи прогресс", "что растёт, что стоит", "график прогресса"). Runs scripts/progress.js, sends the picture, comments from its summary. A bare /progress is answered by the runner without you — this skill is for the request in words.
---

# Прогресс — картинка

Один вызов. Считать в уме нельзя.

```bash
cd /workspace/agent && bun scripts/progress.js --png /tmp/progress.png
```

Последняя строка вывода — JSON:

- `{"photo": "/tmp/progress.png", "summary": "…"}` — отправь `send_photo` с `path` из `photo`, без подписи. Потом одно-два предложения своим голосом по `summary`: что растёт сильнее всего, что падает и что ты с этим делаешь. Цифры — только из `summary`.
- `{"summary": "Считать прогресс рано…"}` без `photo` — картинки нет. Скажи это бойцу своими словами по `summary`.

Нужны детали (какие упражнения падают, ряды по датам) — тот же скрипт без `--png` даёт полный JSON: `overall`, `groups`, `exercises[].change_pct`, `records.items`, `bodyweight`.

Если в начале хода есть `<served command="/progress">` — картинку уже отправил раннер. Повторно не шли, отвечай на вопрос по ней.

## Как считается (если спросят)

- Каждое упражнение — к своему старту. Старт = медиана первых трёх тренировок на этом тренажёре. Сейчас = лучшая тренировка за последние 4 недели: это целая волна, лёгкая и разгрузочная неделя итог не роняют.
- Общее и группы мышц — медиана по упражнениям. Растут / стоят / падают — порог ±2%.
- Скачок больше 35% между соседними тренировками = другой тренажёр или стек плит, отсчёт заново.
- Рекорд = лучше всех прошлых тренировок больше чем на 0,5%, когда на этом тренажёре уже есть три тренировки.
- Записи до 9 июня (импорт из антитренера) не входят: другие залы, веса несравнимы.
- Подтягивания и упражнения без веса — отдельно, по повторам.
```

- [ ] **Step 3: Index row**

In `groups/payne/skills/index.md`, after the `retro` row:

```markdown
| `progress` | Боец спрашивает про прогресс в целом или просит показать его («прогресс», «покажи прогресс», «что растёт»). Картинка из `scripts/progress.js`. Голую `/progress` раннер отдаёт без тебя. |
```

- [ ] **Step 4: Retro attaches the picture at the end of a cycle**

In `groups/payne/skills/retro/SKILL.md`, insert before «## Архив»:

```markdown
## Конец цикла — картинка прогресса

Если эта ретро закрывает мезоцикл (`cd /workspace/agent && bun scripts/cycle-status.js` → `cycle_complete: true`), после сообщения приложи картинку прогресса: скилл `progress`, один вызов `progress.js --png`, `send_photo`. Отдельный комментарий к ней не пиши — главное уже сказано в ретро.

```

- [ ] **Step 5: No commit** (gitignored; scp in Task 5).

---

### Task 5: Deploy and check live

- [ ] **Step 1: Make sure nothing on the VDS would be overwritten**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw/agents/payne && ls scripts/progress.js scripts/render-progress.cjs skills/progress 2>&1'
```

Expected: three «No such file or directory».

- [ ] **Step 2: Ship Payne's files**

```bash
scp groups/payne/scripts/{progress.js,progress.test.js,render-progress.cjs,render-progress.test.js} root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/payne/scripts/
ssh root@148.253.211.164 'mkdir -p /home/nanoclaw/nanoclaw/agents/payne/skills/progress'
scp groups/payne/skills/progress/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/payne/skills/progress/SKILL.md
scp groups/payne/skills/index.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/payne/skills/index.md
scp groups/payne/skills/retro/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/payne/skills/retro/SKILL.md
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw/agents/payne && chown -R nanoclaw:nanoclaw scripts skills && find . -name "._*" -print -delete'
```

- [ ] **Step 3: Bring the branch into main, push the host change and deploy it**

The host work lives on `feat/payne-progress` in the worktree `/Users/serg/git/nanoclaw-progress`; main is `/Users/serg/git/nanoclaw` (other sessions work there). Integrate by fast-forward only:

```bash
git -C /Users/serg/git/nanoclaw fetch origin && git -C /Users/serg/git/nanoclaw merge --ff-only feat/payne-progress
```

If main has moved and the fast-forward is refused, STOP and report: a rebase is NOT allowed here. Otherwise:

```bash
git -C /Users/serg/git/nanoclaw push origin main
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build" && systemctl --machine=nanoclaw@.host --user restart nanoclaw && ls /home/nanoclaw/nanoclaw/container/skills/payne-progress/'
```

Expected: pull shows the 4 files, build clean, `serve.cjs` listed.

- [ ] **Step 4: Run the shim the way the runner does, on live data**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw; IMG=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "nanoclaw-agent-v2-.*:latest" | head -1); sudo -u nanoclaw docker run --rm --entrypoint bash -v $PWD/container/skills:/app/skills:ro -v $PWD/agents/payne/scripts:/workspace/agent/scripts:ro -v $PWD/data/user-memory/owner/payne/sessions:/workspace/agent/sessions:ro -v $PWD/data/user-memory/owner/payne/programs:/workspace/agent/programs:ro -v $PWD/data/user-memory/owner/payne/exercises:/workspace/agent/exercises:ro -w /workspace/agent $IMG -c "node /app/skills/payne-progress/serve.cjs"'
```

Expected: one JSON line `{"photo":"/tmp/progress-<ts>.png","summary":"Прогресс …"}`.

- [ ] **Step 5: Run Payne's tests where they live**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw; IMG=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "nanoclaw-agent-v2-.*:latest" | head -1); sudo -u nanoclaw docker run --rm --entrypoint bash -v $PWD/agents/payne/scripts:/workspace/agent/scripts -w /workspace/agent/scripts $IMG -c "bun test 2>&1 | tail -4"'
```

Expected: all pass (the existing suites + 35 new Payne tests: 30 in `progress.test.js`, 5 in `render-progress.test.js`).

- [ ] **Step 6: Live check**

Ask the owner to relaunch the app (the command catalogue comes with `auth_ok`) and tap `/progress` in Payne's chat. Then:

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && grep -h "progress" logs/containers.log | tail -5 && grep -ih "skill" logs/containers.log | grep -i "payne-progress\|SKILL.md" | tail -5'
```

Expected: `[command-serve] Served /progress without the model (progress-<ts>.png)`; the picture in the chat; no skill-loading error naming `payne-progress` (it has no `SKILL.md` on purpose). Then type «как прогресс по ногам?» — Payne answers from the `<served>` note without re-sending the picture.

- [ ] **Step 7: Clean the staging dir**

```bash
ssh root@148.253.211.164 'rm -rf /tmp/payne-stage'
```

---

### Task 6: Memory

- [ ] **Step 1:** Create `/Users/serg/.claude/projects/-Users-serg-git-nanoclaw/memory/project_payne_progress_picture.md` (type `project`): what shipped (files, `/progress` served path, skill, retro hook); the metric and why not the chained index (+28% artefact from a two-pair week → +7% honest); the 26.10 numbers; the font gotcha (`sans-serif` = Liberation Mono in the image → name `"Liberation Sans"`); cards fixed 26.10 with backup dir name; links `[[project_payne_weight_trend]]`, `[[project_agent_commands]]`, `[[feedback_agent_defs_vds_truth]]`.
- [ ] **Step 2:** Add one line to `MEMORY.md` under «## Agents»: `- [Payne Progress Picture](project_payne_progress_picture.md) — /progress served without the model; each exercise vs its own start, median; 2026-10-26: +7% (legs +40, chest −9)`.
