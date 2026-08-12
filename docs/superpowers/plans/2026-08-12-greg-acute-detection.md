# Greg Acute-Illness Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Greg's health detector see acute illness *on the day it starts* instead of two days late, using data already in `health.db`, then widen the input set with symptom and confounder data from iOS. This plan does **not** deliver pre-symptomatic warning — see "What this plan does not buy" below for the measurement showing why that is out of reach at the current data resolution.

**Architecture:** Greg's numeric layer is a single Bun script `groups/greg/scripts/analyze.js` mounted into the container at `/workspace/agent/scripts/analyze.js`. It reads `health.db` (written by the host from iOS uploads) and emits `anomalies.json`, which the LLM interprets. A second, duplicated copy of the sick-day rule lives host-side in TypeScript (`src/modules/health-trigger/sick-day.ts`) because the host cannot shell out to Bun on the HTTP request path. Both copies must change together, and both have their own test suite. No new services; everything is script + contract + iOS reader changes.

**Tech Stack:** Bun (agent script + `bun:test`), Node/TypeScript + vitest (host), Zod (`shared/ios-app-protocol/v2.ts` wire contract), SQLite (`health_days` table), Swift/HealthKit (iOS reader).

## Global Constraints

- **Two copies of the sick-day rule, kept in sync by hand.** `groups/greg/scripts/analyze.js:SICK_DAY_THRESHOLDS` + `sickDayDetect` and `src/modules/health-trigger/sick-day.ts:SICK_DAY_THRESHOLDS` + `detect`. Every threshold change touches both, and both test suites pin the canonical values.
- **`groups/` is gitignored.** It ships to the VDS by `scp`, never by `git pull`. Host TypeScript under `src/` ships by `git pull` + `pnpm run build` + service restart.
- **`agents/<folder>/` is the live mounted copy on the VDS.** `groups/greg/scripts/analyze.js` is byte-identical to `agents/greg/scripts/analyze.js` as of 2026-08-12 — verify with `diff` before editing, and deploy to `agents/greg/scripts/`.
- **Container agent-runner source is host-mounted.** Changes to `groups/`/`agents/` need no image rebuild. Changes to `shared/` DO need an image rebuild.
- **Agent instruction reload requires rebirth.** Editing `groups/greg/CLAUDE.md` or a skill takes effect only after deleting the `continuation:claude` row from that session's `outbound.db` `session_state` table and killing the container.
- **Host DB queries:** no `bun` and no `sqlite3` binary on the VDS host. Use `/usr/bin/node` with `require('/home/nanoclaw/nanoclaw/node_modules/better-sqlite3')`, or `pnpm exec tsx scripts/q.ts` locally.
- **Contract vocabulary is canonical.** Any new health field must be added to `shared/ios-app-protocol/v2.ts:HealthUploadDay` FIRST, then the DB column, then the iOS writer, then `analyze.js`.
- **Test runners differ.** Agent script: `bun test groups/greg/scripts/analyze.test.js`. Host: `pnpm test`. Never import `vitest` in the Bun tree or `bun:test` in the Node tree.
- Commits end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Measured Baseline (real episode, ground truth known)

The plan is calibrated against one real illness in `health.db`. **Symptom onset was 2026-08-10, reported by Сергей.** That date is the anchor for every lead-time claim in this document — not the day he was asked, and not the day the old detector woke up.

| date | current detector (2-of-3) | target (2-of-5) |
|---|---|---|
| 08-03…08-09 (pre-onset) | silent | silent (max 1/5) |
| **08-10 — symptom onset** | silent | **FIRE** 2/5 temp, awake |
| 08-11 | silent | **FIRE** 4/5 hrv, temp, rr, awake |
| 08-12 (Сергей asked and confirmed) | FIRE 2/3 rhr, hrv | FIRE 4/5 rhr, hrv, rr, awake |

**Lead time against onset: current −2 days (two days late), target 0 days (same day).** The win here is removing a two-day lag, not gaining foresight. Two days of late detection is not cosmetic — Payne kept prescribing training through 08-10 and 08-11 and only cancelled on the 12th.

Day-level z-scores on 2026-08-12 that the anomaly detector currently drops entirely: `restingHeartRate` +4.38σ, `wristTempDeviation` +3.85σ, `respiratoryRate` +3.20σ.

### False-alarm cost, measured on the same data

Scored over the 74 pre-onset days in `health.db`:

| threshold | fires on | reading |
|---|---|---|
| 2-of-5 (planned) | 8 of 74 days — **11%** | the accepted cost |
| 1-of-5 | 32 of 74 days — **43%** | the price of chasing pre-onset |

11% is not zero, and an earlier draft of this plan wrongly claimed "no false positives" on the strength of one quiet week (08-03…08-09). Some of the 8 are probably genuine — an early-July sick-day episode sits inside the window — but they have no ground truth, so treat 11% as the ceiling to hold, not to grow. Task 1 pins it with a regression test.

## What this plan does not buy: pre-onset detection

Oura's Symptom Radar claims up to two days before a user tags an illness; TemPredict reported COVID a mean 2.75 days before diagnostic testing, at **82% sensitivity and 63% specificity**. Two measurements were run against this dataset to see whether that is reachable here.

**1. CuSum accumulation does not fire earlier.** The textbook answer to "detect earlier" is to accumulate sub-threshold deviations across nights rather than threshold each day. Run one-sided (k=0.5σ, h=4.0σ, 28-day trailing baseline) over all six signals:

| date | RR | temp | RHR | hrvMorning | awake | alarm |
|---|---|---|---|---|---|---|
| 08-02 | 0 | 0 | 0 | 0 | **5.18** | awakeMin — false |
| 08-08 | 0 | 0 | 0 | 0.96 | 1.06 | — |
| 08-09 | 0 | 0 | 0 | 1.28 | 0.43 | — |
| **08-10 onset** | 0.75 | 2.39 | 0 | 0 | **5.71** | awakeMin |
| 08-11 | 3.82 | **4.11** | 0.51 | 0.1 | **8.72** | temp, awake |
| 08-12 | **4.76** | *no data* | **5.63** | 0.45 | 3.58 | RR, RHR |

First true alarm lands on 08-10 — the same day as the plain 2-of-5 rule — plus one false alarm on 08-02. CuSum buys nothing here and is deliberately **not** in this plan.

**2. There is no pre-onset signal at daily-aggregate resolution.** The only deviation in the two days before onset is morning HRV: −42% on 08-08, −23% on 08-09. Both are single-signal days, and this person's healthy weeks contain the same dips (−22% on 08-05). Lowering the rule to 1-of-5 to catch them costs 43% alarm days — which is roughly Oura's own 37% false-positive rate. Their earliness is bought at exactly the price this dataset says it costs; it is a product decision, not a smarter algorithm, and for one person receiving direct messages it is the wrong trade.

Task 19's weighting makes this verdict sharper rather than softer. Morning HRV turns out to be the *noisiest* of the five signals for this person — it clears its threshold on 27% of healthy days — so once signals are weighted by how quiet they are when healthy, the apparent 08-08 bump collapses from 3.64 to 1.84 against an onset-day 4.65. The better detector says explicitly that the 08-08 "prodrome" was HRV noise. That is the right answer, and it is not one a vote-counting rule can give.

**3. What Oura has that no rewrite of `analyze.js` can supply.** In descending order of impact:

- ~~**Wear time.**~~ **Struck — measured and false for this user.** An earlier draft claimed wrist temperature was present on only 35 of 61 days and named wear time the primary limiter. That was a misread column. The real coverage over 2026-06-13…08-12: sleep tracked **61/61 nights**, `respiratoryRate` **61/61**, `hrvMorning` **61/61**, `spo2Avg` **61/61**, `wristTempDeviation` **55/61 (90%)**. Сергей sleeps in the watch and the data says so. Wear time is not the gap.
- **The six temperature gaps are not behavioural either.** 06-26, 07-03, 08-04, 08-05, 08-07, 08-12 — sleep 6.7–7.7 h, ordinary phases, ordinary onset, nothing short or fragmented. Every other overnight metric survived those same nights. So the loss is specific to `appleSleepingWristTemperature`, and Task 18 identifies one mechanism inside our own pipeline that can produce exactly this pattern.
- **Continuous temperature** versus one `appleSleepingWristTemperature` average per night. This one stands: Oura samples temperature continuously; Apple emits a single nightly figure, and when it does not emit one there is nothing to fall back on.
- **Sub-daily resolution — the one that is actually ours to fix.** Oura reasons over the night; we reason over one scalar per metric per day. HealthKit holds every sample and the iOS reader throws the resolution away before anything downstream can look. This is not a hardware gap, it is an aggregation decision, and Task 17 reverses it by storing 30-minute interval buckets tagged with sleep stage. Note also that the published algorithms this comparison keeps invoking — RHR-Diff, CuSum, NightSignal — all consume **hourly** data. We have been feeding daily data to daily-resolution reasoning and comparing ourselves to hourly-resolution results.

The honest position: same-day detection is achievable and this plan delivers it. Pre-onset may simply not be reachable from one aggregate row per night, whatever the wear time — and discovering that cleanly is an acceptable outcome, which is why Task 17 is framed as an experiment with a measurement rather than a feature with a promised result. Because HealthKit does not prune and `HealthHistory.fetch(from:to:)` already takes an arbitrary range, that experiment can be **backfilled onto the 2026-08-10 episode** rather than waiting for the next illness. What is *not* an acceptable outcome is losing resolution we already had, which is what Task 18 is about.

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `groups/greg/scripts/analyze.js` | All numeric work: anomaly detection, sick-day rule, recovery/readiness/levels, coverage | 1, 2, 3, 4 |
| `groups/greg/scripts/analyze.test.js` | Bun test suite for the above | 1, 2, 3, 4 |
| `src/modules/health-trigger/sick-day.ts` | Host-side duplicate of the sick-day rule + per-day fire guard | 1, 2 |
| `src/channels/ios-app/v2/health-db.ts` | `health_days` schema, column migration, non-destructive upsert, `health_intervals` store | 4 |
| `src/modules/health-trigger/sick-day.test.ts` | vitest suite for the host copy | 1, 2 |
| `groups/greg/CLAUDE.md` | Data dictionary Greg reads; must describe every new field | 1, 3, 4 |
| `groups/greg/skills/daily-cycle/SKILL.md` | Run loop; where findings get collapsed | 2 |
| `groups/greg/analyze.js` | **Stale orphan duplicate — deleted in Phase 2** | 2 |
| `shared/ios-app-protocol/v2.ts` | `HealthUploadDay` wire contract | 4 |
| `src/modules/health-trigger/health-history.ts` (or wherever `appendHealthHistory` writes) | `health_days` column set | 4 |
| `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` | HealthKit reader | 4 |
| `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift` | HealthKit authorization set | 4 |
| `<agent>/health/episodes.jsonl` (Greg-written, not in the repo) | Illness episode log — onset, label, resolution, false alarms. The ground truth every lead-time claim rests on | 4 |

---

# Phase 1 — Acute-onset detection

Zero new data sources. Highest return: on the reference episode the alert moves from two days late to onset day.

### Task 1: Sick-day rule — 5 signals, morning HRV

The rule currently reads whole-day `hrv` while `buildRecovery` prefers `hrvMorning`. On 2026-08-11 that difference alone is what kept the detector silent. Two new signals (`respiratoryRate`, `awakeMin`) are already in every row.

**Files:**
- Modify: `groups/greg/scripts/analyze.js:104-150` (`SICK_DAY_THRESHOLDS`, `sickDayDetect`)
- Modify: `src/modules/health-trigger/sick-day.ts:23-87` (`SICK_DAY_THRESHOLDS`, `Detection`, `detect`)
- Test: `groups/greg/scripts/analyze.test.js`
- Test: `src/modules/health-trigger/sick-day.test.ts`

**Interfaces:**
- Produces: `sickDayDetect(rows, thresholds?)` returns `{ date, matched, signal: { rhr_delta_pct, hrv_delta_pct, temp_delta_c, rr_delta_abs, awake_ratio }, fires: { rhr, hrv, temp, rr, awake } }` or `null`. Host `detect()` returns the identical shape. Task 5 consumes `matched` and `fires`.
- Produces: `SICK_DAY_THRESHOLDS = { rhrPct: 7, tempC: 0.4, hrvPct: 15, rrAbs: 1.0, awakeRatio: 2.0 }` — same object in both files.

- [ ] **Step 1: Write the failing test (Bun side)**

Append to `groups/greg/scripts/analyze.test.js`:

```javascript
import { sickDayDetect, SICK_DAY_THRESHOLDS } from "./analyze.js";

// 14 quiet days then one day with respiratory rate + fragmented sleep only.
// Neither RHR nor whole-day HRV moves — the old 3-signal rule sees nothing.
function quietDays(n) {
  const out = [];
  for (let i = 0; i < n; i++) {
    out.push({
      date: `2026-07-${String(i + 1).padStart(2, "0")}`,
      restingHeartRate: 61, hrv: 46, hrvMorning: 47,
      wristTempDeviation: 35.2, respiratoryRate: 15.9, awakeMin: 18,
    });
  }
  return out;
}

describe("sickDayDetect — 5 signals", () => {
  it("thresholds expose rrAbs and awakeRatio", () => {
    expect(SICK_DAY_THRESHOLDS.rrAbs).toBe(1.0);
    expect(SICK_DAY_THRESHOLDS.awakeRatio).toBe(2.0);
  });

  it("fires on respiratory rate + awake minutes with RHR and HRV flat", () => {
    const rows = quietDays(14);
    rows.push({
      date: "2026-07-15",
      restingHeartRate: 61, hrv: 46, hrvMorning: 47,
      wristTempDeviation: 35.2, respiratoryRate: 17.4, awakeMin: 60,
    });
    const d = sickDayDetect(rows);
    expect(d).not.toBeNull();
    expect(d.matched).toBe(2);
    expect(d.fires).toEqual({ rhr: false, hrv: false, temp: false, rr: true, awake: true });
    expect(d.signal.rr_delta_abs).toBe(1.5);
    expect(d.signal.awake_ratio).toBe(3.33);
  });

  it("prefers hrvMorning over whole-day hrv", () => {
    const rows = quietDays(14);
    rows.push({
      date: "2026-07-15",
      restingHeartRate: 61, hrv: 46, hrvMorning: 30,   // morning collapsed, day-average flat
      wristTempDeviation: 35.9, respiratoryRate: 15.9, awakeMin: 18,
    });
    const d = sickDayDetect(rows);
    expect(d).not.toBeNull();
    expect(d.fires.hrv).toBe(true);
    expect(d.fires.temp).toBe(true);
    expect(d.signal.hrv_delta_pct).toBe(-36.2);
  });

  it("stays silent on a quiet day", () => {
    const rows = quietDays(15);
    expect(sickDayDetect(rows)).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `SICK_DAY_THRESHOLDS.rrAbs` is `undefined`, and `fires` has three keys, not five.

- [ ] **Step 3: Implement in `analyze.js`**

Replace `SICK_DAY_THRESHOLDS` and the body of `sickDayDetect`:

```javascript
export const SICK_DAY_THRESHOLDS = {
  rhrPct: 7,        // RHR >= 7% above 14-day median
  tempC: 0.4,       // wrist temp >= +0.4 C above 14-day median
  hrvPct: 15,       // morning HRV >= 15% below 14-day median
  rrAbs: 1.0,       // respiratory rate >= +1.0 breaths/min above 14-day median
  awakeRatio: 2.0,  // nocturnal awake minutes >= 2x the 14-day median
};

export function sickDayDetect(rows, thresholds = SICK_DAY_THRESHOLDS) {
  if (!rows || rows.length < 7) return null;
  const today = rows[rows.length - 1];
  const baseline = rows.slice(-15, -1);
  if (baseline.length < 6) return null;

  // Morning HRV is the recovery-grade signal; whole-day SDNN is the fallback.
  // buildRecovery already prefers it — the sick-day rule must not disagree.
  const hrvOf = (r) => (typeof r.hrvMorning === "number" ? r.hrvMorning
                      : typeof r.hrv === "number" ? r.hrv : null);

  function medianOf(pick) {
    const vs = baseline.map(pick).filter((v) => typeof v === "number" && Number.isFinite(v));
    return vs.length >= 4 ? median(vs) : null;
  }
  const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
  const r2 = (x) => Math.round(x * 100) / 100;
  const r1 = (x) => Math.round(x * 10) / 10;

  const rhrMed = medianOf((r) => r.restingHeartRate);
  const hrvMed = medianOf(hrvOf);
  const tempMed = medianOf((r) => r.wristTempDeviation);
  const rrMed = medianOf((r) => r.respiratoryRate);
  const awakeMed = medianOf((r) => r.awakeMin);

  const todayRhr = num(today.restingHeartRate);
  const todayHrv = hrvOf(today);
  const todayTemp = num(today.wristTempDeviation);
  const todayRr = num(today.respiratoryRate);
  const todayAwake = num(today.awakeMin);

  const rhrDelta = rhrMed && todayRhr !== null ? ((todayRhr - rhrMed) / rhrMed) * 100 : null;
  const hrvDelta = hrvMed && todayHrv !== null ? ((todayHrv - hrvMed) / hrvMed) * 100 : null;
  const tempDelta = tempMed !== null && todayTemp !== null ? todayTemp - tempMed : null;
  const rrDelta = rrMed !== null && todayRr !== null ? todayRr - rrMed : null;
  const awakeRatio = awakeMed > 0 && todayAwake !== null ? todayAwake / awakeMed : null;

  const fires = {
    rhr:   rhrDelta !== null && rhrDelta >= thresholds.rhrPct,
    hrv:   hrvDelta !== null && hrvDelta <= -thresholds.hrvPct,
    temp:  tempDelta !== null && tempDelta >= thresholds.tempC,
    rr:    rrDelta !== null && rrDelta >= thresholds.rrAbs,
    awake: awakeRatio !== null && awakeRatio >= thresholds.awakeRatio,
  };
  const matched = Object.values(fires).filter(Boolean).length;
  if (matched < 2) return null;

  return {
    date: today.date,
    matched,
    signal: {
      rhr_delta_pct: rhrDelta !== null ? r1(rhrDelta) : null,
      hrv_delta_pct: hrvDelta !== null ? r1(hrvDelta) : null,
      temp_delta_c:  tempDelta !== null ? r2(tempDelta) : null,
      rr_delta_abs:  rrDelta !== null ? r2(rrDelta) : null,
      awake_ratio:   awakeRatio !== null ? r2(awakeRatio) : null,
    },
    fires,
  };
}
```

- [ ] **Step 4: Run the Bun test to verify it passes**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS, all suites green.

- [ ] **Step 5: Run the measured-episode backtest**

```bash
mkdir -p /tmp/greg-bt && scp root@148.253.211.164:/home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/health.db /tmp/greg-bt/health.db
```

Then create `/tmp/greg-bt/backtest.js`:

```javascript
import { loadRows, sickDayDetect } from "/Users/serg/git/nanoclaw/groups/greg/scripts/analyze.js";
const rows = loadRows("/tmp/greg-bt/health.db");
for (let i = rows.length - 10; i < rows.length; i++) {
  const d = sickDayDetect(rows.slice(0, i + 1));
  const hit = d ? Object.entries(d.fires).filter(([, v]) => v).map(([k]) => k).join(",") : "-";
  console.log(`${rows[i].date} ${d ? `FIRE ${d.matched}/5 ${hit}` : "silent"}`);
}
```

Run: `bun /tmp/greg-bt/backtest.js`
Expected: silent through `2026-08-09`; `2026-08-10 FIRE 2/5 temp,awake`; `2026-08-11 FIRE 4/5 hrv,temp,rr,awake`; `2026-08-12 FIRE 4/5 rhr,hrv,rr,awake`.

Onset was 08-10, so the first fire must land **on** 08-10. A fire on 08-11 means the rule regressed to one-day-late; a fire before 08-09 means a threshold is too loose — check it against the 11% ceiling in Step 5b before accepting it.

- [ ] **Step 5b: Pin the false-alarm ceiling**

The 2-of-5 rule fires on 8 of the 74 pre-onset days in this dataset. That is the accepted cost; it must not grow silently when thresholds are tuned later.

Create `/tmp/greg-bt/fp.js`:

```javascript
import { loadRows, sickDayDetect } from "/Users/serg/git/nanoclaw/groups/greg/scripts/analyze.js";
const rows = loadRows("/tmp/greg-bt/health.db");
const ONSET = "2026-08-10";   // ground truth, reported by Сергей
let scored = 0, fired = 0;
for (let i = 20; i < rows.length; i++) {
  if (rows[i].date >= ONSET) continue;
  scored++;
  if (sickDayDetect(rows.slice(0, i + 1))) fired++;
}
console.log(`pre-onset days ${scored}, fired ${fired} (${(100 * fired / scored).toFixed(0)}%)`);
```

Run: `bun /tmp/greg-bt/fp.js`
Expected: `pre-onset days 74, fired 8 (11%)`. A higher count means a threshold was loosened past what this dataset supports — revert it rather than accept the noise.

- [ ] **Step 6: Write the failing test (host side)**

Append to `src/modules/health-trigger/sick-day.test.ts`:

```typescript
import { detect, SICK_DAY_THRESHOLDS } from './sick-day.js';
import type { HealthUploadDay } from '../../../shared/ios-app-protocol/index.js';

function quiet(n: number): HealthUploadDay[] {
  return Array.from({ length: n }, (_, i) => ({
    date: `2026-07-${String(i + 1).padStart(2, '0')}`,
    restingHeartRate: 61, hrv: 46, hrvMorning: 47,
    wristTempDeviation: 35.2, respiratoryRate: 15.9, awakeMin: 18,
  }));
}

describe('detect — 5 signals', () => {
  it('exposes the two new thresholds', () => {
    expect(SICK_DAY_THRESHOLDS.rrAbs).toBe(1.0);
    expect(SICK_DAY_THRESHOLDS.awakeRatio).toBe(2.0);
  });

  it('fires on respiratory rate + awake minutes alone', () => {
    const rows = quiet(14);
    rows.push({
      date: '2026-07-15',
      restingHeartRate: 61, hrv: 46, hrvMorning: 47,
      wristTempDeviation: 35.2, respiratoryRate: 17.4, awakeMin: 60,
    });
    const d = detect(rows);
    expect(d).not.toBeNull();
    expect(d!.matched).toBe(2);
    expect(d!.fires).toEqual({ rhr: false, hrv: false, temp: false, rr: true, awake: true });
  });

  it('prefers hrvMorning over whole-day hrv', () => {
    const rows = quiet(14);
    rows.push({
      date: '2026-07-15',
      restingHeartRate: 61, hrv: 46, hrvMorning: 30,
      wristTempDeviation: 35.9, respiratoryRate: 15.9, awakeMin: 18,
    });
    const d = detect(rows);
    expect(d!.fires.hrv).toBe(true);
    expect(d!.fires.temp).toBe(true);
  });
});
```

- [ ] **Step 7: Run the host test to verify it fails**

Run: `pnpm test src/modules/health-trigger/sick-day.test.ts`
Expected: FAIL — `rrAbs` undefined.

- [ ] **Step 8: Port the same rule into `sick-day.ts`**

Replace `SICK_DAY_THRESHOLDS`, `Detection`, and `detect` with the TypeScript mirror of the Bun implementation from Step 3:

```typescript
export const SICK_DAY_THRESHOLDS = {
  rhrPct: 7,
  tempC: 0.4,
  hrvPct: 15,
  rrAbs: 1.0,
  awakeRatio: 2.0,
};

interface Detection {
  date: string;
  matched: number;
  signal: {
    rhr_delta_pct: number | null;
    hrv_delta_pct: number | null;
    temp_delta_c: number | null;
    rr_delta_abs: number | null;
    awake_ratio: number | null;
  };
  fires: { rhr: boolean; hrv: boolean; temp: boolean; rr: boolean; awake: boolean };
}

export function detect(rows: HealthUploadDay[], thresholds = SICK_DAY_THRESHOLDS): Detection | null {
  if (!rows || rows.length < 7) return null;
  const today = rows[rows.length - 1];
  const baseline = rows.slice(-15, -1);
  if (baseline.length < 6) return null;

  // Mirror of analyze.js:sickDayDetect. Morning HRV preferred, whole-day SDNN fallback.
  const hrvOf = (r: HealthUploadDay): number | null =>
    typeof r.hrvMorning === 'number' ? r.hrvMorning
    : typeof r.hrv === 'number' ? r.hrv : null;

  function medOf(pick: (r: HealthUploadDay) => number | null | undefined): number | null {
    const vs = baseline.map(pick).filter((v): v is number => typeof v === 'number' && Number.isFinite(v));
    return vs.length >= 4 ? median(vs) : null;
  }
  const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const r2 = (x: number) => Math.round(x * 100) / 100;
  const r1 = (x: number) => Math.round(x * 10) / 10;

  const rhrMed = medOf((r) => r.restingHeartRate);
  const hrvMed = medOf(hrvOf);
  const tempMed = medOf((r) => r.wristTempDeviation);
  const rrMed = medOf((r) => r.respiratoryRate);
  const awakeMed = medOf((r) => r.awakeMin);

  const todayRhr = num(today.restingHeartRate);
  const todayHrv = hrvOf(today);
  const todayTemp = num(today.wristTempDeviation);
  const todayRr = num(today.respiratoryRate);
  const todayAwake = num(today.awakeMin);

  const rhrDelta = rhrMed && todayRhr !== null ? ((todayRhr - rhrMed) / rhrMed) * 100 : null;
  const hrvDelta = hrvMed && todayHrv !== null ? ((todayHrv - hrvMed) / hrvMed) * 100 : null;
  const tempDelta = tempMed !== null && todayTemp !== null ? todayTemp - tempMed : null;
  const rrDelta = rrMed !== null && todayRr !== null ? todayRr - rrMed : null;
  const awakeRatio = awakeMed !== null && awakeMed > 0 && todayAwake !== null ? todayAwake / awakeMed : null;

  const fires = {
    rhr: rhrDelta !== null && rhrDelta >= thresholds.rhrPct,
    hrv: hrvDelta !== null && hrvDelta <= -thresholds.hrvPct,
    temp: tempDelta !== null && tempDelta >= thresholds.tempC,
    rr: rrDelta !== null && rrDelta >= thresholds.rrAbs,
    awake: awakeRatio !== null && awakeRatio >= thresholds.awakeRatio,
  };
  const matched = Object.values(fires).filter(Boolean).length;
  if (matched < 2) return null;

  return {
    date: today.date,
    matched,
    signal: {
      rhr_delta_pct: rhrDelta !== null ? r1(rhrDelta) : null,
      hrv_delta_pct: hrvDelta !== null ? r1(hrvDelta) : null,
      temp_delta_c: tempDelta !== null ? r2(tempDelta) : null,
      rr_delta_abs: rrDelta !== null ? r2(rrDelta) : null,
      awake_ratio: awakeRatio !== null ? r2(awakeRatio) : null,
    },
    fires,
  };
}
```

Also update the file's header comment: the rule is now five signals, not three.

- [ ] **Step 9: Run the host tests**

Run: `pnpm test src/modules/health-trigger/`
Expected: PASS.

- [ ] **Step 10: Update Greg's data dictionary**

In `groups/greg/CLAUDE.md`, under `## Данные`, replace the sick-day description with:

```markdown
- **sick-day правило — 5 сигналов, 2-из-5 запускает проверку** (порог считается от медианы за 14 дней, сравнение «сегодня против базы», не окно): пульс покоя ≥ +7%, утренняя вариабельность пульса ≤ −15%, температура запястья ≥ +0.4 °C, частота дыхания ≥ +1.0 вдоха/мин, минуты ночного бодрствования ≥ 2× базы. Вариабельность берётся утренняя (`hrvMorning`), дневная `hrv` — только фолбэк. Поле `fires` в `sick_day_check` перечисляет, какие именно сработали — цитируй их, не пересчитывай.
- **`wristTempDeviation` названо неверно — это НЕ отклонение.** iOS пишет туда абсолютную `appleSleepingWristTemperature` в °C: типичные значения 35.0–35.4, при недомогании 36.0+. Никогда не читай «36.19» как «+36 градусов к норме». Отклонение считает детектор сам, от медианы за 14 дней; в тексте человеку называй именно дельту («температура запястья на 0.97 °C выше обычного»), не сырое значение.
```

- [ ] **Step 11: Commit**

```bash
git add src/modules/health-trigger/sick-day.ts src/modules/health-trigger/sick-day.test.ts
git commit -m "feat(greg/sick-day): widen rule to 5 signals, prefer morning HRV

Respiratory rate and nocturnal awake minutes were already in every health_days
row but unused by the sick-day rule. Symptom onset in the reference episode was
2026-08-10: the 3-signal rule fired on the 12th, two days late, and Payne kept
prescribing training through both. The 5-signal rule fires on the 10th — same
day as onset, not before it. Costs 8 fires across 74 pre-onset days (11%).
Whole-day SDNN replaced by hrvMorning, matching buildRecovery.

This removes a two-day lag. It is not pre-symptomatic detection, and CuSum
accumulation was tested and does not reach earlier on this data.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

`groups/` is gitignored — the Bun script is deployed in Task 4's step, not committed here.

---

### Task 2: Day-level z alongside window z

`analyze` reduces the recent window to its median before scoring, and requires every day in the window to clear 1σ. A single +4.4σ day is invisible to both gates. Add a parallel day-level score that does not replace the trend logic.

**Files:**
- Modify: `groups/greg/scripts/analyze.js:433-469` (`analyze`)
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: every anomaly object gains `z_today` (number, signed, 2 decimals) and `shape` (`"acute"` | `"sustained"` | `"both"`). `analyze` now also emits anomalies where only the acute gate passes. Task 3 filters on these fields; the `daily-cycle` skill in Task 7 reads `shape`.

- [ ] **Step 1: Write the failing test**

Append to `groups/greg/scripts/analyze.test.js`:

```javascript
import { analyze } from "./analyze.js";

function flatSeries(metric, n, value) {
  return Array.from({ length: n }, (_, i) => ({
    date: `2026-06-${String(i + 1).padStart(2, "0")}`,
    [metric]: value + (i % 2),   // tiny jitter so MAD is non-zero
  }));
}

describe("analyze — acute step detection", () => {
  it("flags a single-day spike the window median would hide", () => {
    const rows = flatSeries("restingHeartRate", 30, 60);
    rows.push({ date: "2026-07-01", restingHeartRate: 60 });
    rows.push({ date: "2026-07-02", restingHeartRate: 61 });
    rows.push({ date: "2026-07-03", restingHeartRate: 78 });   // +4σ, one day only
    const out = analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 });
    const rhr = out.find((a) => a.metric === "restingHeartRate");
    expect(rhr).toBeDefined();
    expect(rhr.shape).toBe("acute");
    expect(rhr.z_today).toBeGreaterThan(3);
    expect(rhr.direction).toBe("up");
    expect(rhr.severity).toBe("warn");
  });

  it("marks a sustained shift as sustained, not acute", () => {
    const rows = flatSeries("restingHeartRate", 30, 60);
    for (const d of ["2026-07-01", "2026-07-02", "2026-07-03"]) {
      rows.push({ date: d, restingHeartRate: 72 });
    }
    const out = analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 });
    const rhr = out.find((a) => a.metric === "restingHeartRate");
    expect(rhr.shape).toBe("both");
  });

  it("stays silent on a flat series", () => {
    const rows = flatSeries("restingHeartRate", 33, 60);
    const out = analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 });
    expect(out.find((a) => a.metric === "restingHeartRate")).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `rhr` is `undefined` in the first case (the acute spike is dropped entirely).

- [ ] **Step 3: Implement the acute gate**

In `analyze`, replace the block from `const up = ...` through the `anomalies.push({...})` call:

```javascript
    const up = recentVals.every((v) => (v - med) / scale > 1);
    const down = recentVals.every((v) => (v - med) / scale < -1);
    const sustained = (up || down) && Math.abs(modz) >= 2;

    // Acute gate: illness is a step, not a trend. The window median plus the
    // every()-over-window test both dilute a 1-day jump — a +4σ day next to two
    // normal ones scores ~1σ and vanishes. Score the last day on its own too.
    const todayVal = vals[vals.length - 1];
    const zToday = scale ? (todayVal - med) / scale : 0;
    const acute = Math.abs(zToday) >= 3;

    if (!sustained && !acute) continue;

    const sl = slopePerDay(vals.slice(-(recent + baseline)));
    // Direction comes from whichever gate fired; the acute day wins when both do
    // and disagree, since a fresh step is the more actionable read.
    const direction = (acute ? zToday : modz) > 0 ? "up" : "down";
    const shape = sustained && acute ? "both" : acute ? "acute" : "sustained";
    const concerning = (direction === "up" && CONCERN_UP.has(metric)) ||
                       (direction === "down" && CONCERN_DOWN.has(metric));
    // Rank on the stronger of the two scores so an acute-only finding can reach
    // the top-K against long-running trend noise.
    const a = Math.max(Math.abs(modz), Math.abs(zToday));
    const severity = a >= 5 && concerning ? "critical" : a >= 3.5 ? "warn" : "info";
    anomalies.push({
      metric, severity, direction, shape,
      window: { from: s[s.length - recent][0], to: s[s.length - 1][0], days: recent },
      recent_median: Math.round(recentMed * 100) / 100,
      baseline_median: Math.round(med * 100) / 100,
      mod_z: Math.round(modz * 100) / 100,
      z_today: Math.round(zToday * 100) / 100,
      trend_per_day: Math.round(sl * 1000) / 1000,
      n: s.length,
    });
```

And change the final sort so ranking uses the same combined score:

```javascript
  const rank = (x) => Math.max(Math.abs(x.mod_z), Math.abs(x.z_today));
  anomalies.sort((x, y) => rank(y) - rank(x));
  return anomalies.slice(0, topK);
```

- [ ] **Step 4: Run the tests**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS.

- [ ] **Step 5: Verify against the real episode**

Create `/tmp/greg-bt/acute.js`:

```javascript
import { loadRows, analyze } from "/Users/serg/git/nanoclaw/groups/greg/scripts/analyze.js";
const rows = loadRows("/tmp/greg-bt/health.db");
for (const a of analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 })) {
  console.log(`${a.metric.padEnd(20)} ${a.severity.padEnd(9)} ${a.shape.padEnd(10)} mod_z=${a.mod_z} z_today=${a.z_today}`);
}
```

Run: `bun /tmp/greg-bt/acute.js`
Expected: `restingHeartRate` present with `shape=acute`, `z_today` ≈ 4.38, severity `warn`. Previously absent entirely.

- [ ] **Step 6: Document the new fields for Greg**

In `groups/greg/CLAUDE.md`, under `## Данные`, add:

```markdown
- **`shape` в каждой аномалии** — `acute` (ступенька: только сегодняшний день выбит, `z_today` ≥ 3), `sustained` (устойчивый сдвиг всего окна) или `both`. Трактуй по-разному: `acute` = «что-то случилось сегодня-вчера» (болезнь, недосып, алкоголь, перелёт), `sustained` = «дрейф режима». `z_today` — отклонение последнего дня от базы в сигмах; `mod_z` — то же для медианы окна.
```

- [ ] **Step 7: Commit the doc change**

`analyze.js` lives under gitignored `groups/`; only `CLAUDE.md` in that tree is also gitignored, so nothing to commit here. Record progress by proceeding — the deploy in Task 4 covers both files.

---

### Task 3: Drop vo2max, exclude sick days from the baseline

Two sources of noise. `vo2max` has 7 non-null days out of 61 and produced a `warn` today with a window from 26 June — a month-stale artifact occupying a top-K slot, on a metric `CLAUDE.md` already tells Greg to ignore. And the rolling baseline absorbs the illness itself, so by day three the anomaly self-cancels — the same mechanism that turned June–July's `sleepRegularity` critical into a month of silent dedup.

**Files:**
- Modify: `groups/greg/scripts/analyze.js:20-30` (`METRICS`), `:433-469` (`analyze`)
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: `sickDayDetect` from Task 1, `shape`/`z_today` from Task 2.
- Produces: `analyze(rows, opts)` accepts a new optional `excludeDates: Set<string>` in `opts`; days in that set are dropped from baseline computation but still scored as recent days. `runNormalMode` passes the set built from `sickDayDetect` over trailing days.

- [ ] **Step 1: Write the failing test**

```javascript
describe("analyze — baseline hygiene", () => {
  it("never reports vo2max", () => {
    const rows = Array.from({ length: 40 }, (_, i) => ({
      date: `2026-06-${String((i % 30) + 1).padStart(2, "0")}`,
      vo2max: i > 35 ? 50 : 43,
    }));
    const out = analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 });
    expect(out.find((a) => a.metric === "vo2max")).toBeUndefined();
  });

  it("excluded dates do not enter the baseline", () => {
    // 25 quiet days at 60, then 3 sick days at 80. Without exclusion the third
    // sick day's baseline has already absorbed the first two and the z collapses.
    const rows = Array.from({ length: 25 }, (_, i) => ({
      date: `2026-06-${String(i + 1).padStart(2, "0")}`, restingHeartRate: 60 + (i % 2),
    }));
    rows.push({ date: "2026-07-01", restingHeartRate: 80 });
    rows.push({ date: "2026-07-02", restingHeartRate: 80 });
    rows.push({ date: "2026-07-03", restingHeartRate: 80 });

    const without = analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 });
    const with_ = analyze(rows, {
      recent: 3, baseline: 21, minN: 7, topK: 8,
      excludeDates: new Set(["2026-07-01", "2026-07-02"]),
    });
    const zw = with_.find((a) => a.metric === "restingHeartRate").z_today;
    const zo = without.find((a) => a.metric === "restingHeartRate").z_today;
    expect(zw).toBeGreaterThan(zo);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `vo2max` is still in `METRICS`, and `analyze` ignores `excludeDates` so both z values are equal.

- [ ] **Step 3: Implement**

Remove `"vo2max"` from `METRICS` and from `CONCERN_DOWN`, leaving a note:

```javascript
const METRICS = [
  "steps", "activeEnergy", "exerciseMinutes",
  "heartRate", "restingHeartRate",
  "sleepHours", "hrv", "recovery",
  "wristTempDeviation", "respiratoryRate",
  "walkingHeartRateAverage",
  // vo2max removed 2026-08-12: 7 non-null days out of 61. Strength work does not
  // generate cardio-fitness estimates, so the series is sparse enough that MAD is
  // meaningless — it produced a `warn` with a month-stale window. Re-add only if
  // coverage passes ~60%.
  "deepMin", "remMin", "awakeMin", "hrvMorning", "spo2Min", "sleepRegularity",
  "fatMassKg", "leanMassKg",
];
```

In `analyze`, accept and honour the exclusion set:

```javascript
export function analyze(rows, { recent, baseline, minN, topK, excludeDates }) {
  const skip = excludeDates instanceof Set ? excludeDates : new Set();
  const anomalies = [];
  for (const metric of METRICS) {
    const s = series(rows, metric);
    if (s.length < minN || s.length < recent + 3) continue;
    const vals = s.map(([, v]) => v);
    const recentVals = vals.slice(-recent);
    // Baseline must describe the person's normal, not the episode being scored.
    // Known-sick days are dropped so a multi-day illness cannot dilute its own
    // signal — the failure mode that turned sleepRegularity into a month of dedup.
    let baseVals = s.slice(-(recent + baseline), -recent)
      .filter(([d]) => !skip.has(d))
      .map(([, v]) => v);
    if (baseVals.length < 3) baseVals = s.slice(0, -recent).filter(([d]) => !skip.has(d)).map(([, v]) => v);
    if (baseVals.length < 3) continue;
```

Then in the `runNormalMode` call site, build the set from trailing sick-day detections:

```javascript
// Days already known to be sick get excluded from every baseline below.
function sickDates(rows, lookback = 10) {
  const out = new Set();
  for (let i = Math.max(7, rows.length - lookback); i < rows.length; i++) {
    const d = sickDayDetect(rows.slice(0, i + 1));
    if (d) out.add(d.date);
  }
  return out;
}
```

and pass `excludeDates: sickDates(rows)` into the `analyze(...)` call in the normal-mode entry point.

- [ ] **Step 4: Run the tests**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS.

- [ ] **Step 5: Re-run the real-data check**

Run: `bun /tmp/greg-bt/acute.js`
Expected: no `vo2max` row. `restingHeartRate` `z_today` at or above the pre-change 4.38 (the 08-10/08-11 sick days no longer soften the baseline).

- [ ] **Step 6: Update the data dictionary**

In `groups/greg/CLAUDE.md`, replace the `vo2max` bullet:

```markdown
- **vo2max** — исключён из детектора 2026-08-12 (покрытие 7 дней из 61). Не трактуй и не жди по нему аномалий.
- **База исключает больные дни.** Дни, на которых sick-day правило дало 2-из-5, не входят в 21-дневную базу. Поэтому на третий день болезни аномалия НЕ гаснет сама собой — если она пропала, это данные, а не адаптация базы.
```

- [ ] **Step 7: Commit**

Nothing under `src/` changed. Proceed to Task 4, which deploys Phase 1 as a unit.

---

### Task 4: Deploy Phase 1 and verify on the live install

**Files:**
- Deploy: `groups/greg/scripts/analyze.js` → `agents/greg/scripts/analyze.js` on the VDS
- Deploy: `groups/greg/CLAUDE.md` → `agents/greg/CLAUDE.md` on the VDS
- Deploy: `src/modules/health-trigger/sick-day.ts` via `git pull` + build + restart

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: a live install whose next health upload runs the 5-signal rule.

- [ ] **Step 1: Confirm no drift before overwriting**

```bash
ssh root@148.253.211.164 'cat /home/nanoclaw/nanoclaw/agents/greg/scripts/analyze.js' | diff - groups/greg/scripts/analyze.js
```

Expected: only your Phase-1 edits appear. Any *other* difference means the agent self-edited the live copy — stop and reconcile before overwriting.

- [ ] **Step 2: Ship the host change**

```bash
git push && ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/\$(id -u nanoclaw) systemctl --user restart nanoclaw"'
```

- [ ] **Step 3: Ship the agent script and instructions**

```bash
scp groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/scripts/
scp groups/greg/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/CLAUDE.md
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/agents/greg'
```

- [ ] **Step 4: Rebirth Greg so he reads the new instructions**

`CLAUDE.md` changes do not reach a live agent on restart — the SDK session resumes from the `continuation:claude` row.

```bash
ssh root@148.253.211.164 'bash -s' <<'REMOTE'
cd /home/nanoclaw/nanoclaw
cat > /tmp/wipe.cjs <<'EOF'
const Database = require('/home/nanoclaw/nanoclaw/node_modules/better-sqlite3');
const db = new Database(process.argv[2]);
console.log(db.prepare("DELETE FROM session_state WHERE key = 'continuation:claude'").run());
EOF
for f in data/v2-sessions/greg/sess-*/outbound.db; do echo "$f"; /usr/bin/node /tmp/wipe.cjs "$f"; done
docker ps --format '{{.Names}}' | grep '^nanoclaw-v2-greg' | xargs -r docker kill
REMOTE
```

- [ ] **Step 5: Verify the live script produces the new fields**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && grep -c "z_today\|awakeRatio" agents/greg/scripts/analyze.js'
```

Expected: a non-zero count. Then confirm the host binary carries the new rule:

```bash
ssh root@148.253.211.164 'grep -c awakeRatio /home/nanoclaw/nanoclaw/dist/modules/health-trigger/sick-day.js'
```

Expected: non-zero. A zero here means the build did not run — re-do Step 2.

- [ ] **Step 6: Watch the next real cycle**

After the next daily cycle (03:03 UTC), read what Greg actually emitted:

```bash
ssh root@148.253.211.164 '/usr/bin/node /tmp/q.cjs /home/nanoclaw/nanoclaw/data/v2-sessions/greg/sess-1779443246846-8lu1wa/outbound.db "SELECT timestamp, content FROM messages_out ORDER BY timestamp DESC LIMIT 3"'
```

Expected: the `health_signal` / `finding` payloads reference `shape` or the five-signal `fires` set. If Greg still narrates only `mod_z`, the rebirth in Step 4 did not take.

---

# Phase 2 — Signal hygiene

Phase 1 makes Greg see more. Phase 2 stops him from saying it five times.

### Task 5: Per-day sick-day fire guard

On 2026-08-12 the host wrote five identical `sick_day_check` messages (03:16, 05:01 ×2, 05:02, 05:13) — one per health upload, with no memory of having already fired. Greg correctly deduplicated them, at the cost of four extra container wakes and four full LLM turns. The suppress rule lives in the agent's `state.md`; the host has never heard of it.

**Files:**
- Modify: `src/modules/health-trigger/sick-day.ts:101-142` (`sickDayCheck`)
- Test: `src/modules/health-trigger/sick-day.test.ts`

**Interfaces:**
- Consumes: `detect()` from Task 1 (`matched`, `fires`).
- Produces: `sickDayCheck` writes at most one `sick_day_check` per `(session, detection.date)` unless the picture worsens. Worsening = `matched` increased, or a signal fired that had not fired before.
- Produces: a new `session-manager.ts` export `readSessionMessagesByPlatform(agentGroupId, sessionId, platformId): { id: string; content: string }[]`, oldest→newest.

- [ ] **Step 1: Add the reader to `session-manager.ts`**

The host is the sole writer of `inbound.db`, so reading its own rows back is safe. Place it next to `writeSessionMessage`:

```typescript
/**
 * Rows this host previously wrote into a session's inbound DB from one synthetic
 * platform (e.g. `host-sick-day`). Used by triggers that must not re-announce
 * something they already announced. Oldest→newest.
 */
export function readSessionMessagesByPlatform(
  agentGroupId: string,
  sessionId: string,
  platformId: string,
): { id: string; content: string }[] {
  const db = openInboundDb(agentGroupId, sessionId);
  try {
    return db
      .prepare('SELECT id, content FROM messages_in WHERE platform_id = ? ORDER BY seq ASC')
      .all(platformId) as { id: string; content: string }[];
  } finally {
    db.close();
  }
}
```

Match the surrounding `open…/try/finally close` convention exactly — check how `writeSessionMessage` at `src/session-manager.ts:262` closes its handle and mirror it.

- [ ] **Step 2: Write the failing test**

The existing suite mocks `../../session-manager.js` wholesale, so the new reader must be added to that mock. Extend the mock block at the top of `src/modules/health-trigger/sick-day.test.ts`:

```typescript
const readSessionMessagesByPlatform = vi.fn<(...args: unknown[]) => { id: string; content: string }[]>();

vi.mock('../../session-manager.js', () => ({
  writeSessionMessage: (...args: unknown[]) => writeSessionMessage(...args),
  resolveSession: (...args: unknown[]) => resolveSession(...args),
  readSessionMessagesByPlatform: (...args: unknown[]) => readSessionMessagesByPlatform(...args),
}));
```

Add `readSessionMessagesByPlatform.mockReset(); readSessionMessagesByPlatform.mockReturnValue([]);` to the existing `beforeEach`, then append:

```typescript
function priorCheck(date: string, matched: number, fires: Record<string, boolean>) {
  return [{
    id: 'sickday-prior',
    content: JSON.stringify({ kind: 'sick_day_check', detection: { date, matched, fires }, signal: {} }),
  }];
}

it('does not re-fire for the same day when the picture is unchanged', async () => {
  const rows = fourteenDays();
  rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5 });
  readSessionMessagesByPlatform.mockReturnValue(
    priorCheck(rows[13].date, 2, { rhr: true, hrv: false, temp: true, rr: false, awake: false }),
  );
  await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
  expect(writeSessionMessage).not.toHaveBeenCalled();
  expect(wakeContainer).not.toHaveBeenCalled();
});

it('re-fires for the same day when a new signal joins', async () => {
  const rows = fourteenDays();
  rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5, hrv: 40 });
  readSessionMessagesByPlatform.mockReturnValue(
    priorCheck(rows[13].date, 2, { rhr: true, hrv: false, temp: true, rr: false, awake: false }),
  );
  await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
  expect(writeSessionMessage).toHaveBeenCalledOnce();
  const content = JSON.parse(
    (writeSessionMessage.mock.calls[0] as [string, string, { content: string }])[2].content,
  );
  expect(content.detection.matched).toBe(3);
});

it('fires normally when nothing was reported for this day', async () => {
  const rows = fourteenDays();
  rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5 });
  readSessionMessagesByPlatform.mockReturnValue(priorCheck('2026-06-13', 2, { rhr: true, temp: true }));
  await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
  expect(writeSessionMessage).toHaveBeenCalledOnce();
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `pnpm test src/modules/health-trigger/sick-day.test.ts`
Expected: FAIL — the first case still writes, because nothing consults the prior row.

- [ ] **Step 4: Implement the guard**

In `sickDayCheck`, after resolving `fresh` and before writing:

```typescript
  // The host fires on every health upload; iOS uploads several times a day.
  // Without a guard that is one container wake and one full LLM turn per upload
  // for the same detection — five on 2026-08-12. Re-fire only when the picture
  // actually worsens, so a deteriorating day still reaches Greg immediately.
  const prior = readPriorSickDayCheck(agentGroupId, fresh.id, detection.date);
  if (prior) {
    const keys = Object.keys(detection.fires) as (keyof typeof detection.fires)[];
    const newSignal = keys.some((k) => detection.fires[k] && !prior.fires[k]);
    if (detection.matched <= prior.matched && !newSignal) {
      log.info('sick-day trigger suppressed (already reported, not worse)', {
        agentGroupId, date: detection.date, matched: detection.matched,
      });
      return;
    }
  }
```

And the helper, above `sickDayCheck`:

```typescript
/** Most recent sick_day_check already written into this session for `date`. */
function readPriorSickDayCheck(
  agentGroupId: string,
  sessionId: string,
  date: string,
): { matched: number; fires: Record<string, boolean> } | null {
  const rows = readSessionMessagesByPlatform(agentGroupId, sessionId, 'host-sick-day');
  for (let i = rows.length - 1; i >= 0; i--) {
    try {
      const c = JSON.parse(rows[i].content);
      if (c.kind === 'sick_day_check' && c.detection?.date === date) {
        return { matched: c.detection.matched, fires: c.detection.fires ?? {} };
      }
    } catch { /* non-JSON rows are not ours */ }
  }
  return null;
}
```

Add `readSessionMessagesByPlatform` to the existing `session-manager.js` import at the top of `sick-day.ts`.

- [ ] **Step 5: Run the tests**

Run: `pnpm test src/modules/health-trigger/`
Expected: PASS, including the four pre-existing cases.

- [ ] **Step 6: Commit**

```bash
git add src/modules/health-trigger/ src/session-manager.ts
git commit -m "fix(greg/sick-day): one wake per day unless the picture worsens

The host fired sick_day_check on every health upload with no memory of prior
fires — five identical messages on 2026-08-12, four wasted container wakes.
Guard on (session, detection date); re-fire only when matched increases or a
new signal joins, so deterioration still reaches Greg immediately.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Delete the stale orphan `analyze.js`

`groups/greg/analyze.js` (542 lines, June) is a dead duplicate of `groups/greg/scripts/analyze.js` (609 lines, current). It lacks the `health.db` reader and `computeLevels` entirely. Nothing loads it — the container runs `/workspace/agent/scripts/analyze.js`. It exists only to mislead the next reader into editing the wrong file.

**Files:**
- Delete: `groups/greg/analyze.js`

**Interfaces:** none.

- [ ] **Step 1: Prove nothing references it**

```bash
grep -rn "greg/analyze.js" --include='*.ts' --include='*.js' --include='*.md' . | grep -v 'scripts/analyze.js'
ssh root@148.253.211.164 'ls -la /home/nanoclaw/nanoclaw/agents/greg/'
```

Expected: no hits outside `scripts/`, and no `analyze.js` at the top level of the live `agents/greg/`.

- [ ] **Step 2: Delete it**

```bash
rm groups/greg/analyze.js
```

- [ ] **Step 3: Verify the test suite still runs**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS.

`groups/` is gitignored — no commit. The deletion is local hygiene; the live install never had the file.

---

### Task 7: Collapse one day's findings into one causal report

On 2026-08-12 Greg sent Jarvis three separate `finding` messages inside 14 minutes — `awakeMin` critical (03:04), `activeEnergy` warn (03:04), `sick_day` critical (03:18) — all describing one illness. Jarvis relayed two separate alarms to Сергей, at 03:05 and 03:19. The metric-level framing is what makes this happen: each anomaly is its own message because nothing above them names the shared cause.

**Files:**
- Modify: `groups/greg/skills/daily-cycle/SKILL.md`
- Modify: `groups/greg/skills/sick-day/SKILL.md`
- Modify: `groups/greg/skills/finding-contract/SKILL.md`

**Interfaces:**
- Consumes: `shape` and `z_today` from Task 2, `fires`/`matched` from Task 1.
- Produces: at most one `finding` per run, with a new optional field `related_metrics: string[]` naming the other anomalies folded into it. Jarvis's relay is unchanged — one message in, one alarm out.

- [ ] **Step 1: Read the current contract**

Run: `cat groups/greg/skills/finding-contract/SKILL.md`

Confirm the exact field list before editing so the new field is additive.

- [ ] **Step 2: Add the field to the contract**

In `groups/greg/skills/finding-contract/SKILL.md`, add to the schema:

```markdown
- `related_metrics` (опционально, массив строк) — метрики, свёрнутые в этот finding. Заполняй, когда несколько аномалий одного прогона объясняются одной причиной: одна причина = один finding, остальные метрики перечисляешь здесь, отдельных сообщений НЕ шлёшь.
```

- [ ] **Step 3: Add the collapse rule to the daily cycle**

In `groups/greg/skills/daily-cycle/SKILL.md`, in the step that emits findings:

```markdown
**Одна причина — один finding.** Прежде чем слать, посмотри на все новые аномалии прогона вместе. Если они правдоподобно объясняются одной причиной (типовой пример: `awakeMin` ↑ + `activeEnergy` ↓ + `restingHeartRate` ↑ + `respiratoryRate` ↑ = острое недомогание), шли ОДИН finding по ведущей метрике, а остальные перечисли в `related_metrics`. Отдельные finding'и — только для причинно несвязанных вещей.

**Если в этом же прогоне сработало sick-day** — отдельный finding по аномалиям НЕ шли вообще. Sick-day и есть тот самый causal-отчёт; аномалии уходят в его `related_metrics`.
```

- [ ] **Step 4: Mirror the rule in the sick-day skill**

In `groups/greg/skills/sick-day/SKILL.md`:

```markdown
Sick-day finding поглощает аномалии дня. Перечисли их в `related_metrics` и не шли по ним отдельных сообщений — Джарвис поднимет человеку одну тревогу, а не три.
```

- [ ] **Step 5: Deploy and rebirth**

```bash
scp -r groups/greg/skills root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/agents/greg'
```

Then repeat Task 4 Step 4 (continuation wipe + container kill).

- [ ] **Step 6: Verify on the next multi-anomaly day**

```bash
ssh root@148.253.211.164 '/usr/bin/node /tmp/q.cjs /home/nanoclaw/nanoclaw/data/v2-sessions/greg/sess-1779443246846-8lu1wa/outbound.db "SELECT timestamp, substr(content,1,120) FROM messages_out WHERE timestamp >= date(\"now\") ORDER BY timestamp"'
```

Expected: at most one `a2a_kind:"finding"` row per cycle, carrying `related_metrics`.

---

# Phase 3 — More signal from the same data

Derived metrics only. No new source, no contract change, no iOS work.

### Task 8: Heart-rate-over-steps efficiency

Illness shows as a high pulse doing nothing. Today's row: heart rate 64 at 1847 steps, against a normal 78 at ~8000. Neither number is anomalous alone; the ratio is. This is the HROS-AD feature (median 4 days to symptom onset in the published evaluation).

**Files:**
- Modify: `groups/greg/scripts/analyze.js` — add `hrPerKStep` to the derived-metric pass and to `METRICS` + `CONCERN_UP`
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: nothing.
- Produces: each row gains `hrPerKStep = heartRate / (steps / 1000)`, computed only when `steps >= 500` (below that the ratio explodes on rounding). Appears in `anomalies` like any other metric.

- [ ] **Step 1: Write the failing test**

```javascript
import { buildDerived } from "./analyze.js";

describe("hrPerKStep", () => {
  it("computes heart rate per thousand steps", () => {
    const rows = [{ date: "2026-08-01", heartRate: 78, steps: 8000 }];
    buildDerived(rows);
    expect(rows[0].hrPerKStep).toBeCloseTo(9.75, 2);
  });
  it("skips days below 500 steps", () => {
    const rows = [{ date: "2026-08-01", heartRate: 64, steps: 47 }];
    buildDerived(rows);
    expect(rows[0].hrPerKStep).toBeUndefined();
  });
  it("skips days with no heart rate", () => {
    const rows = [{ date: "2026-08-01", steps: 8000 }];
    buildDerived(rows);
    expect(rows[0].hrPerKStep).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `buildDerived` is not exported (or does not exist).

- [ ] **Step 3: Implement**

Add near `buildRecovery`:

```javascript
// Derived per-row metrics that need no baseline. Called once before analyze().
// hrPerKStep: cardiac cost of movement. A high pulse at near-zero activity is the
// HROS-AD signal — neither heartRate nor steps is anomalous alone on a sick day,
// but the ratio is. Below 500 steps the ratio is dominated by rounding, so skip.
export function buildDerived(rows) {
  for (const r of rows) {
    const hr = typeof r.heartRate === "number" ? r.heartRate : null;
    const st = typeof r.steps === "number" ? r.steps : null;
    if (hr !== null && st !== null && st >= 500) {
      r.hrPerKStep = Math.round((hr / (st / 1000)) * 100) / 100;
    }
  }
  return rows;
}
```

Add `"hrPerKStep"` to `METRICS` and to `CONCERN_UP`. Call `buildDerived(rows)` immediately before `buildRecovery(rows)` in the normal-mode entry point.

- [ ] **Step 4: Run the tests**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS.

- [ ] **Step 5: Document it**

In `groups/greg/CLAUDE.md` under `## Данные`:

```markdown
- **`hrPerKStep`** — пульс на тысячу шагов (синтетика). Растёт, когда сердце работает много при малом движении: болезнь, обезвоживание, жара, тревога. Считается только в дни с ≥500 шагов. Ни `heartRate`, ни `steps` по отдельности такой день не флагуют — только отношение.
```

- [ ] **Step 6: Commit**

Gitignored tree — no commit. Deploy with Task 10.

---

### Task 9: Absolute circadian shift

`sleepOnsetMin` is already collected but only feeds `sleepRegularity`, which is a dispersion measure. A one-off −560 min shift (2026-08-10) reads as "irregular" rather than as the large single-night phase jump it is — and dispersion keeps climbing for weeks afterwards, which is how `sleepRegularity` spent June and July pinned at critical while telling Greg nothing new.

**Files:**
- Modify: `groups/greg/scripts/analyze.js` — add `sleepPhaseShift` to `buildDerived`, `METRICS`, `CONCERN_UP`
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: `buildDerived` from Task 8.
- Produces: each row gains `sleepPhaseShift` = absolute minutes between this night's `sleepOnsetMin` and the median of the previous 7 nights. Requires ≥4 prior nights.

- [ ] **Step 1: Write the failing test**

```javascript
describe("sleepPhaseShift", () => {
  it("measures the jump from the trailing 7-night median", () => {
    const rows = Array.from({ length: 7 }, (_, i) => ({
      date: `2026-08-0${i + 1}`, sleepOnsetMin: -20,
    }));
    rows.push({ date: "2026-08-08", sleepOnsetMin: 100 });
    buildDerived(rows);
    expect(rows[7].sleepPhaseShift).toBe(120);
  });
  it("is undefined without enough history", () => {
    const rows = [
      { date: "2026-08-01", sleepOnsetMin: -20 },
      { date: "2026-08-02", sleepOnsetMin: 100 },
    ];
    buildDerived(rows);
    expect(rows[1].sleepPhaseShift).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `sleepPhaseShift` undefined in the first case.

- [ ] **Step 3: Implement**

Extend `buildDerived`:

```javascript
  // sleepPhaseShift: how far tonight's bedtime moved from the recent norm, in
  // minutes. sleepRegularity is a dispersion measure and stays elevated for weeks
  // after a single jump; this is the per-night event that caused it.
  for (let i = 0; i < rows.length; i++) {
    const onset = typeof rows[i].sleepOnsetMin === "number" ? rows[i].sleepOnsetMin : null;
    if (onset === null) continue;
    const prior = rows.slice(Math.max(0, i - 7), i)
      .map((r) => r.sleepOnsetMin)
      .filter((v) => typeof v === "number" && Number.isFinite(v));
    if (prior.length < 4) continue;
    rows[i].sleepPhaseShift = Math.round(Math.abs(onset - median(prior)));
  }
```

Add `"sleepPhaseShift"` to `METRICS` and `CONCERN_UP`.

- [ ] **Step 4: Run the tests**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS.

- [ ] **Step 5: Document it**

```markdown
- **`sleepPhaseShift`** — на сколько минут отход ко сну сдвинулся относительно медианы прошлых 7 ночей (синтетика, всегда ≥0). Это СОБЫТИЕ одной ночи, в отличие от `sleepRegularity` — та мера разброса и остаётся высокой неделями после одного скачка. Большой `sleepPhaseShift` = «вчера легли не как обычно», высокий `sleepRegularity` при малом `sleepPhaseShift` = «режим давно плавает».
```

- [ ] **Step 6: Commit**

Gitignored — deploy with Task 10.

---

### Task 10: Sleep debt, sleep-stage fractions, HRV variability

Three cheap derived metrics that the literature treats as leading indicators, all computable from columns already present.

**Files:**
- Modify: `groups/greg/scripts/analyze.js` — extend `buildDerived`, `METRICS`, `CONCERN_UP`/`CONCERN_DOWN`
- Modify: `groups/greg/CLAUDE.md`
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: `buildDerived` from Tasks 8–9.
- Produces: `sleepDebt7` (hours, ≥0), `restorativeFrac` (0–1), `hrvCv7` (0–1).

- [ ] **Step 1: Write the failing test**

```javascript
describe("derived recovery metrics", () => {
  it("sleepDebt7 sums the shortfall against a 7.5h target over 7 days", () => {
    const rows = Array.from({ length: 7 }, (_, i) => ({
      date: `2026-08-0${i + 1}`, sleepHours: 6.5,
    }));
    buildDerived(rows);
    expect(rows[6].sleepDebt7).toBeCloseTo(7.0, 1);   // 7 x 1.0h
  });

  it("sleepDebt7 floors at zero when oversleeping", () => {
    const rows = Array.from({ length: 7 }, (_, i) => ({
      date: `2026-08-0${i + 1}`, sleepHours: 9,
    }));
    buildDerived(rows);
    expect(rows[6].sleepDebt7).toBe(0);
  });

  it("restorativeFrac is deep+REM over total sleep", () => {
    const rows = [{ date: "2026-08-01", sleepHours: 8, deepMin: 60, remMin: 120 }];
    buildDerived(rows);
    expect(rows[0].restorativeFrac).toBeCloseTo(0.375, 3);   // 180 / 480
  });

  it("hrvCv7 is the coefficient of variation over 7 nights", () => {
    const rows = Array.from({ length: 7 }, (_, i) => ({
      date: `2026-08-0${i + 1}`, hrvMorning: [50, 50, 50, 50, 50, 50, 50][i],
    }));
    buildDerived(rows);
    expect(rows[6].hrvCv7).toBe(0);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — all three fields undefined.

- [ ] **Step 3: Implement**

Extend `buildDerived`:

```javascript
  const SLEEP_TARGET_H = 7.5;
  for (let i = 0; i < rows.length; i++) {
    // sleepDebt7: cumulative shortfall, floored at zero. A run of 6.5h nights is
    // invisible per-night (well inside normal variation) but compounds.
    const win = rows.slice(Math.max(0, i - 6), i + 1)
      .map((r) => r.sleepHours)
      .filter((v) => typeof v === "number" && Number.isFinite(v));
    if (win.length >= 5) {
      const debt = win.reduce((a, h) => a + Math.max(0, SLEEP_TARGET_H - h), 0);
      rows[i].sleepDebt7 = Math.round(debt * 10) / 10;
    }

    // restorativeFrac: deep+REM as a share of total sleep. Absolute minutes move
    // with sleep length; the fraction isolates quality from duration.
    const deep = typeof rows[i].deepMin === "number" ? rows[i].deepMin : null;
    const rem = typeof rows[i].remMin === "number" ? rows[i].remMin : null;
    const total = typeof rows[i].sleepHours === "number" ? rows[i].sleepHours * 60 : null;
    if (deep !== null && rem !== null && total !== null && total > 0) {
      rows[i].restorativeFrac = Math.round(((deep + rem) / total) * 1000) / 1000;
    }

    // hrvCv7: dispersion of morning HRV. Instability rises before the median
    // moves, so this leads the hrvMorning anomaly by a few days.
    const hv = rows.slice(Math.max(0, i - 6), i + 1)
      .map((r) => (typeof r.hrvMorning === "number" ? r.hrvMorning : r.hrv))
      .filter((v) => typeof v === "number" && Number.isFinite(v));
    if (hv.length >= 5) {
      const mean = hv.reduce((a, b) => a + b, 0) / hv.length;
      if (mean > 0) rows[i].hrvCv7 = Math.round((pstdev(hv) / mean) * 1000) / 1000;
    }
  }
```

Add to `METRICS`: `"sleepDebt7"`, `"restorativeFrac"`, `"hrvCv7"`.
Add to `CONCERN_UP`: `"sleepDebt7"`, `"hrvCv7"`.
Add to `CONCERN_DOWN`: `"restorativeFrac"`.

- [ ] **Step 4: Run the tests**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS.

- [ ] **Step 5: Sanity-check on real data**

Run: `bun /tmp/greg-bt/acute.js`
Expected: the run completes and any new metrics that appear carry plausible values. A `restorativeFrac` above 1.0 or a negative `sleepDebt7` means the units are wrong — fix before deploying.

- [ ] **Step 6: Document all three**

```markdown
- **`sleepDebt7`** — накопленный недосып за 7 дней в часах относительно цели 7.5 ч, снизу ограничен нулём. Неделя по 6.5 ч не флагуется по `sleepHours` (это в пределах нормы), но даёт долг 7 часов.
- **`restorativeFrac`** — доля глубокого + быстрого сна от общего (0–1). Абсолютные `deepMin`/`remMin` ходят вместе с длиной сна; доля отделяет качество от количества.
- **`hrvCv7`** — коэффициент вариации утренней вариабельности пульса за 7 ночей. Разброс растёт раньше, чем сдвигается медиана, — опережает аномалию по `hrvMorning` на несколько дней.
```

- [ ] **Step 7: Deploy Phase 3**

```bash
scp groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/scripts/
scp groups/greg/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/CLAUDE.md
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/agents/greg'
```

Then repeat Task 4 Step 4 (continuation wipe + container kill).

- [ ] **Step 8: Verify the live run**

```bash
ssh root@148.253.211.164 'cd /home/nanoclaw/nanoclaw && grep -c "hrPerKStep\|sleepDebt7\|hrvCv7\|sleepPhaseShift" agents/greg/scripts/analyze.js'
```

Expected: a count of at least 8 (each name appears in `buildDerived` and in `METRICS`).

---

### Task 11: Let the sick-day verdict reach readiness and levels

On 2026-08-12 — wrist temperature +0.97 °C, resting pulse +21%, 1847 steps — the script published `readiness: 60 yellow` and `levels.stress: 26`. Low stress. `sickDayDetect` runs in a different code path and nothing downstream consults it, so the two numbers the app shows and Payne gates training on both said "moderate day". Payne received `red` only because Greg's LLM layer overrode the script by hand.

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (`computeReadiness`, `computeLevels`, and their call site)
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: `sickDayDetect` from Task 1.
- Produces: `computeReadiness(rows, load, sick)` and `computeLevels(rows, load, readiness, sick)` — both gain a third/fourth optional parameter, the `sickDayDetect` result or `null`. When `sick` is non-null, readiness is capped at 45 (red band) and `levels.stress` is floored at 60. `computeReadiness` returns an extra field `sick_capped: boolean`. Call sites pass `sickDayDetect(rows)` once and reuse the value.

- [ ] **Step 1: Write the failing test**

```javascript
import { computeReadiness, computeLevels } from "./analyze.js";

describe("readiness and levels honour the sick-day verdict", () => {
  const load = { acute: 1, chronic: 2, ratio: 0.5 };
  const rows = [{
    date: "2026-08-12", recovery: -0.82, hrvMorning: 35, restingHeartRate: 74,
    sleepHours: 6.9, deepMin: 40, remMin: 78,
  }];
  const sick = { date: "2026-08-12", matched: 4, fires: { rhr: true, hrv: true, temp: false, rr: true, awake: true }, signal: {} };

  it("caps readiness into the red band", () => {
    const plain = computeReadiness(rows, load, null);
    expect(plain.band).toBe("yellow");
    expect(plain.sick_capped).toBe(false);

    const capped = computeReadiness(rows, load, sick);
    expect(capped.score).toBeLessThanOrEqual(45);
    expect(capped.band).toBe("red");
    expect(capped.sick_capped).toBe(true);
  });

  it("floors stress", () => {
    const plain = computeLevels(rows, load, computeReadiness(rows, load, null), null);
    expect(plain.stress).toBeLessThan(60);

    const raised = computeLevels(rows, load, computeReadiness(rows, load, sick), sick);
    expect(raised.stress).toBeGreaterThanOrEqual(60);
  });

  it("leaves a healthy day untouched", () => {
    const healthy = [{ date: "2026-08-03", recovery: 0.6, hrvMorning: 76, restingHeartRate: 61, sleepHours: 7.2, deepMin: 60, remMin: 96 }];
    const a = computeReadiness(healthy, load, null);
    const b = computeReadiness(healthy, load, undefined);
    expect(a.score).toBe(b.score);
    expect(a.sick_capped).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `sick_capped` undefined and the capped score still reads 60.

- [ ] **Step 3: Implement**

```javascript
// A sick-day verdict is a hard ceiling on both numbers. Without it the script
// published readiness 60 "yellow" and stress 26 on a day with a +0.97 C wrist
// temperature and a +21% resting pulse — the two values the app shows and Payne
// gates intensity on, both saying "moderate day". The recovery composite alone
// cannot see this: it has no temperature-vs-baseline term and no idea the person
// is ill.
const SICK_READINESS_CAP = 45;   // top of the red band
const SICK_STRESS_FLOOR = 60;

export function computeReadiness(rows, load, sick = null) {
  const last = rows.length ? rows[rows.length - 1] : null;
  if (!last || typeof last.recovery !== "number") return null;
  const INTERCEPT = 70, K = 12;
  const loadPenalty = load.ratio > 1.3 ? Math.min(10, (load.ratio - 1.3) * 12) : 0;
  let score = Math.max(0, Math.min(100, Math.round(INTERCEPT + K * last.recovery - loadPenalty)));
  const capped = Boolean(sick) && score > SICK_READINESS_CAP;
  if (sick) score = Math.min(score, SICK_READINESS_CAP);
  const band = score >= 70 ? "green" : score >= 50 ? "yellow" : "red";
  return { score, band, recovery_z: last.recovery, load_ratio: load.ratio, sick_capped: capped };
}
```

In `computeLevels`, take the extra parameter and apply the floor just before returning:

```javascript
export function computeLevels(rows, load, readiness, sick = null) {
  // ...existing body unchanged up to the return...
  return {
    energy,
    stress: sick ? Math.max(stress, SICK_STRESS_FLOOR) : stress,
    recovery: Math.round(recNorm(last.recovery) * 100),
    readiness: readiness ? readiness.score : null,
  };
}
```

At the normal-mode call site, compute the verdict once and thread it through:

```javascript
  const sick = sickDayDetect(rows);
  const readiness = computeReadiness(rows, load, sick);
  const levels = computeLevels(rows, load, readiness, sick);
```

- [ ] **Step 4: Run the tests**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS.

- [ ] **Step 5: Verify on the real sick day**

Run: `bun /tmp/greg-bt/acute.js` after extending it to print `readiness` and `levels`.
Expected: `readiness.score` ≤ 45 with `band: "red"` and `sick_capped: true`; `levels.stress` ≥ 60. Before the change these read 60/yellow and 26.

- [ ] **Step 6: Document it**

In `groups/greg/CLAUDE.md`, amend the readiness bullet:

```markdown
- **`readiness` при sick-day принудительно уходит в red (≤45), `levels.stress` — не ниже 60**, независимо от композита восстановления. Поле `sick_capped: true` означает именно это. Не спорь со скриптом в эту сторону и не «возвращай» готовность обратно в yellow: композит не видит температуру и не знает, что человек болен.
```

- [ ] **Step 7: Deploy with the rest of Phase 3**

Covered by Task 10 Step 7 if executed together; otherwise repeat that scp + rebirth sequence.

---

# Phase 4 — New inputs from iOS

Everything above squeezes the existing data. This phase widens it. The single highest-value addition is HealthKit's symptom category types: they are the subjective channel the diagnostician phase needs, and iOS already has permission infrastructure for them.

### Task 12: Wire contract and storage for symptoms and body temperature

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts:436-473` (`HealthUploadDay`)
- Modify: the `health_days` `CREATE TABLE` / migration in the host's health-history writer
- Test: `shared/ios-app-protocol/v2.test.ts`

**Interfaces:**
- Produces: `HealthUploadDay` gains `bodyTemperature?: number` (°C, manual thermometer) and `symptoms?: string[]` (HealthKit symptom identifier suffixes, e.g. `["fever","coughing"]`). `health_days` gains a `bodyTemperature REAL` column and a `symptoms TEXT` column holding a JSON array. Task 13 writes them; Task 14 reads them.

- [ ] **Step 1: Write the failing contract test**

Append to `shared/ios-app-protocol/v2.test.ts`:

```typescript
it('HealthUploadDay accepts bodyTemperature and symptoms', () => {
  const parsed = HealthUploadDay.parse({
    date: '2026-08-12',
    bodyTemperature: 37.8,
    symptoms: ['fever', 'coughing'],
  });
  expect(parsed.bodyTemperature).toBe(37.8);
  expect(parsed.symptoms).toEqual(['fever', 'coughing']);
});

it('HealthUploadDay rejects a non-array symptoms value', () => {
  expect(() => HealthUploadDay.parse({ date: '2026-08-12', symptoms: 'fever' })).toThrow();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm test shared/ios-app-protocol/v2.test.ts`
Expected: FAIL — unknown keys are stripped, so `parsed.bodyTemperature` is `undefined`.

- [ ] **Step 3: Extend the contract**

In `shared/ios-app-protocol/v2.ts`, inside `HealthUploadDay`, before `workouts`:

```typescript
  // New 2026-08-12. Subjective channel — the hardware signals say "something is
  // wrong", these say what it feels like. `symptoms` holds HealthKit symptom
  // identifier suffixes (HKCategoryTypeIdentifier.fever -> "fever"), only for
  // days the user actually logged one; absent means "not logged", never "none".
  // bodyTemperature is a manual thermometer reading in Celsius — distinct from
  // wristTempDeviation, which is a passive overnight sensor value.
  bodyTemperature: z.number().positive().optional(),
  symptoms: z.array(z.string()).optional(),
```

- [ ] **Step 4: Run the contract test**

Run: `pnpm test shared/ios-app-protocol/`
Expected: PASS.

- [ ] **Step 5: Add the columns — and the migration the table has never needed before**

`src/channels/ios-app/v2/health-db.ts` builds the schema with `CREATE TABLE IF NOT EXISTS` and no migration path. On the live DB the table already exists, so adding a name to `SCALARS` alone will make `upsertHealthDays` throw `SqliteError: table health_days has no column named bodyTemperature`. Add the column explicitly.

`bodyTemperature` is a scalar and joins `SCALARS`. `symptoms` is a JSON array and must be handled like `workouts`, not like a scalar.

In `src/channels/ios-app/v2/health-db.ts`:

```typescript
const SCALARS = [
  // ...existing entries unchanged...
  'leanBodyMass',
  'bodyTemperature',
] as const;

export function openHealthDb(path: string): Database.Database {
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma('journal_mode = DELETE');
  db.exec(
    `CREATE TABLE IF NOT EXISTS health_days (
       date TEXT PRIMARY KEY,
       ${SCALARS.map((c) => `${c} REAL`).join(', ')},
       symptoms TEXT,
       workouts TEXT,
       ingested_at INTEGER
     )`,
  );
  // The table predates every column added after its first release and there has
  // never been a migration path — CREATE TABLE IF NOT EXISTS silently no-ops on
  // an existing file, so a new SCALARS entry would blow up the next upsert.
  // Backfill additively; SQLite has no IF NOT EXISTS for ADD COLUMN, so probe.
  const existing = new Set(
    (db.prepare(`PRAGMA table_info(health_days)`).all() as { name: string }[]).map((c) => c.name),
  );
  for (const [col, type] of [...SCALARS.map((c) => [c, 'REAL'] as const), ['symptoms', 'TEXT'] as const]) {
    if (!existing.has(col)) db.exec(`ALTER TABLE health_days ADD COLUMN ${col} ${type}`);
  }
  return db;
}
```

In `upsertHealthDays`, add `symptoms` alongside `workouts`:

```typescript
  const cols = ['date', ...SCALARS, 'symptoms', 'workouts', 'ingested_at'];
```

and inside the transaction, next to the `workouts` line:

```typescript
      rec.symptoms = d.symptoms?.length ? JSON.stringify(d.symptoms) : null;
```

In `readHealthDays`, parse it back:

```typescript
      if (k === 'workouts') out.workouts = typeof v === 'string' ? JSON.parse(v) : undefined;
      else if (k === 'symptoms') out.symptoms = typeof v === 'string' ? JSON.parse(v) : undefined;
      else if (v !== null) out[k] = v;
```

- [ ] **Step 5b: Test the migration against a pre-existing table**

Add to the health-db test file:

```typescript
it('adds new columns to a table created before they existed', () => {
  const path = `${tmpdir()}/health-migrate-${Date.now()}.db`;
  const old = new Database(path);
  old.exec(`CREATE TABLE health_days (date TEXT PRIMARY KEY, steps REAL, workouts TEXT, ingested_at INTEGER)`);
  old.close();

  const db = openHealthDb(path);
  const names = new Set((db.prepare('PRAGMA table_info(health_days)').all() as { name: string }[]).map((c) => c.name));
  expect(names.has('bodyTemperature')).toBe(true);
  expect(names.has('symptoms')).toBe(true);

  upsertHealthDays(db, [{ date: '2026-08-12', bodyTemperature: 37.8, symptoms: ['fever'] }]);
  expect(readHealthDays(db)[0].symptoms).toEqual(['fever']);
});
```

Run: `pnpm test src/channels/ios-app/v2/`
Expected: PASS. If the file has no test yet, create `src/channels/ios-app/v2/health-db.test.ts` with this as its first case.

- [ ] **Step 6: Rebuild the container image**

`shared/` is baked into the image, so a contract change needs a rebuild:

```bash
./container/build.sh
```

- [ ] **Step 7: Run the full host suite**

Run: `pnpm test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add shared/ios-app-protocol/ src/
git commit -m "feat(health): add bodyTemperature and symptoms to the health upload contract

HealthKit exposes ~30 symptom category types and a manual bodyTemperature
quantity. Neither was collected, so Greg's every read was hardware-only —
he asks the user to take their temperature and has nowhere to put the answer.
Contract and storage first; the iOS reader lands next.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 13: Read symptoms and body temperature on iOS

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift` (authorization set)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` (readers)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` (`HealthUpload.Day`)
- Modify: `ios/JarvisApp/project.yml` (`CURRENT_PROJECT_VERSION` bump)
- Create: `ios/JarvisApp/Sources/JarvisAppTests/HealthSymptomsTests.swift`

**Interfaces:**
- Consumes: the contract from Task 12.
- Produces: uploaded days carry `bodyTemperature` and `symptoms` when HealthKit has them.

- [ ] **Step 1: Write the failing test**

Create `ios/JarvisApp/Sources/JarvisAppTests/HealthSymptomsTests.swift`. The module is `Jarvis`, not `JarvisApp` — `PRODUCT_NAME` is `Jarvis`, and `@testable import JarvisApp` will not compile.

```swift
import XCTest
import HealthKit
@testable import Jarvis

final class HealthSymptomsTests: XCTestCase {

func testSymptomIdentifierSuffixMapping() {
    XCTAssertEqual(HealthHistory.symptomKey(.fever), "fever")
    XCTAssertEqual(HealthHistory.symptomKey(.coughing), "coughing")
    XCTAssertEqual(HealthHistory.symptomKey(.shortnessOfBreath), "shortnessOfBreath")
}

func testDayEncodesSymptomsAndTemperature() throws {
    var day = V2.HealthUpload.Day(date: "2026-08-12")
    day.bodyTemperature = 37.8
    day.symptoms = ["fever", "coughing"]
    let json = try JSONEncoder().encode(day)
    let back = try JSONDecoder().decode(V2.HealthUpload.Day.self, from: json)
    XCTAssertEqual(back.bodyTemperature, 37.8)
    XCTAssertEqual(back.symptoms, ["fever", "coughing"])
}

}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd ios/JarvisApp && xcodegen generate
```

Then run the test scheme in the simulator (`mcp__XcodeBuildMCP__test_sim`, or `xcodebuild test` with the project's usual destination).
Expected: FAIL to compile — `symptomKey` does not exist and `Day` has no `symptoms`.

- [ ] **Step 3: Extend the Swift `Day` mirror**

In `Protocol/V2.swift`, add to `HealthUpload.Day`:

```swift
    var bodyTemperature: Double?
    var symptoms: [String]?
```

- [ ] **Step 4: Request authorization for the new types**

In `HealthManager.swift`, add to the read-types set:

```swift
    // Symptom category types — the subjective channel. Each is a separate
    // HKCategoryType; the user logs them in Health.app or on the watch.
    private static let symptomTypes: [HKCategoryTypeIdentifier] = [
        .fever, .chills, .coughing, .soreThroat, .runnyNose, .sinusCongestion,
        .shortnessOfBreath, .wheezing, .headache, .fatigue, .generalizedBodyAche,
        .nausea, .diarrhea, .lossOfSmell, .lossOfTaste, .dizziness, .nightSweats,
        .moodChanges, .sleepChanges, .appetiteChanges,
    ]
```

and include `symptomTypes.map { HKCategoryType($0) }` plus `HKQuantityType(.bodyTemperature)` in the authorization request.

- [ ] **Step 5: Read them in `HealthHistory`**

```swift
    /// HealthKit identifier -> the short key the wire contract uses.
    /// `HKCategoryTypeIdentifierFever` -> `fever`.
    static func symptomKey(_ id: HKCategoryTypeIdentifier) -> String {
        var s = id.rawValue
        if s.hasPrefix("HKCategoryTypeIdentifier") {
            s.removeFirst("HKCategoryTypeIdentifier".count)
        }
        return s.prefix(1).lowercased() + s.dropFirst()
    }

    // Manual thermometer readings — distinct from the passive wrist sensor.
    group.enter()
    collection(.bodyTemperature, start: start, end: end, options: .discreteAverage) { stats in
        let degC = HKUnit.degreeCelsius()
        for s in stats {
            if let q = s.averageQuantity() {
                let k = bucketKey(s.startDate)
                let v = (q.doubleValue(for: degC) * 100).rounded() / 100
                mutate(k) { $0.bodyTemperature = v }
            }
        }
        group.leave()
    }

    // Symptom samples: presence-only. A day with no logged symptom stays nil —
    // "not logged" is not the same claim as "no symptoms", and Greg must not
    // read an absent array as a negative finding.
    for id in HealthManager.symptomTypes {
        group.enter()
        let q = HKSampleQuery(
            sampleType: HKCategoryType(id),
            predicate: HKQuery.predicateForSamples(withStart: start, end: end),
            limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { _, samples, _ in
            let key = HealthHistory.symptomKey(id)
            for s in (samples as? [HKCategorySample]) ?? [] {
                let k = bucketKey(s.startDate)
                mutate(k) { day in
                    var list = day.symptoms ?? []
                    if !list.contains(key) { list.append(key) }
                    day.symptoms = list
                }
            }
            group.leave()
        }
        store.execute(q)
    }
```

- [ ] **Step 6: Bump the build number and regenerate**

In `ios/JarvisApp/project.yml`, increment `CURRENT_PROJECT_VERSION` and the marketing version. Then:

```bash
cd ios/JarvisApp && xcodegen generate
```

- [ ] **Step 7: Run the tests and a clean build**

Run the test scheme, then a clean simulator build.
Expected: PASS, no warnings on the new code paths.

- [ ] **Step 8: Commit**

```bash
git add ios/JarvisApp/
git commit -m "feat(ios/health): collect HealthKit symptom types and body temperature

Twenty symptom category types plus manual bodyTemperature. Symptoms are
presence-only: a day with nothing logged stays nil rather than an empty array,
so an absent value can never be read as 'no symptoms reported'.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 14: Feed symptoms into the sick-day rule and Greg's dictionary

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (`sickDayDetect`, `latest` block)
- Modify: `src/modules/health-trigger/sick-day.ts` (`detect`)
- Modify: `groups/greg/CLAUDE.md`
- Test: `groups/greg/scripts/analyze.test.js`, `src/modules/health-trigger/sick-day.test.ts`

**Interfaces:**
- Consumes: `symptoms` / `bodyTemperature` from Task 12, the 5-signal rule from Task 1.
- Produces: `fires.symptom` (sixth signal) and `signal.symptoms` (the day's list, or `null`). A logged symptom counts as one signal; a `bodyTemperature ≥ 37.5` counts as one, independent of `wristTempDeviation`.

- [ ] **Step 1: Write the failing test**

```javascript
describe("sickDayDetect — subjective signals", () => {
  it("a logged symptom counts as one signal", () => {
    const rows = quietDays(14);
    rows.push({
      date: "2026-07-15",
      restingHeartRate: 61, hrv: 46, hrvMorning: 47,
      wristTempDeviation: 35.2, respiratoryRate: 17.4, awakeMin: 18,
      symptoms: ["soreThroat"],
    });
    const d = sickDayDetect(rows);
    expect(d.matched).toBe(2);            // rr + symptom
    expect(d.fires.symptom).toBe(true);
    expect(d.signal.symptoms).toEqual(["soreThroat"]);
  });

  it("a measured fever counts even when the wrist sensor is silent", () => {
    const rows = quietDays(14);
    rows.push({
      date: "2026-07-15",
      restingHeartRate: 61, hrv: 46, hrvMorning: 47,
      wristTempDeviation: 35.2, respiratoryRate: 15.9, awakeMin: 60,
      bodyTemperature: 38.1,
    });
    const d = sickDayDetect(rows);
    expect(d.fires.fever).toBe(true);
    expect(d.matched).toBe(2);            // awake + fever
  });

  it("an absent symptoms array is not a negative finding", () => {
    const rows = quietDays(15);
    const d = sickDayDetect(rows);
    expect(d).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `fires.symptom` undefined.

- [ ] **Step 3: Implement in both copies**

Add to `SICK_DAY_THRESHOLDS` in `analyze.js` and `sick-day.ts`:

```javascript
  feverC: 37.5,     // measured body temperature at or above this = signal
```

and inside the `fires` object:

```javascript
    // Subjective and measured signals stand on their own. An absent symptoms
    // array means "nothing logged", never "nothing wrong" — so it can only ever
    // add a signal, never cancel one.
    symptom: Array.isArray(today.symptoms) && today.symptoms.length > 0,
    fever: num(today.bodyTemperature) !== null && today.bodyTemperature >= thresholds.feverC,
```

and to the returned `signal` object:

```javascript
      symptoms: Array.isArray(today.symptoms) && today.symptoms.length ? today.symptoms : null,
      body_temp_c: num(today.bodyTemperature),
```

Mirror all of it in the TypeScript `detect`, widening the `Detection` interface accordingly.

- [ ] **Step 4: Run both suites**

Run: `bun test groups/greg/scripts/analyze.test.js`
Run: `pnpm test src/modules/health-trigger/`
Expected: PASS.

- [ ] **Step 5: Update the dictionary**

```markdown
- **`symptoms`** (массив строк, опционально) — что человек сам залогировал в Health.app: `fever`, `coughing`, `soreThroat`, `headache`, `fatigue`, `lossOfSmell` и т.д. **Отсутствие массива = «ничего не отмечено», НЕ «симптомов нет».** Никогда не выводи из пустоты, что человек здоров — спроси.
- **`bodyTemperature`** — ручной замер градусником, °C. Это НЕ `wristTempDeviation` (пассивный ночной датчик запястья, абсолютное значение ~35 °C). ≥ 37.5 считается отдельным sick-day сигналом.
- **sick-day теперь 2-из-7**: пульс покоя, утренняя вариабельность, температура запястья, частота дыхания, ночное бодрствование, залогированный симптом, измеренная температура ≥ 37.5.
```

- [ ] **Step 6: Deploy and verify**

```bash
git push && ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build && XDG_RUNTIME_DIR=/run/user/\$(id -u nanoclaw) systemctl --user restart nanoclaw"'
scp groups/greg/scripts/analyze.js groups/greg/scripts/analyze.test.js root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/scripts/
scp groups/greg/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/agents/greg/CLAUDE.md
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/agents/greg'
```

Then repeat Task 4 Step 4 (continuation wipe + container kill).

- [ ] **Step 7: End-to-end check**

Log a symptom in Health.app on the phone, force a health upload, then:

```bash
ssh root@148.253.211.164 '/usr/bin/node /tmp/q.cjs /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/health.db "SELECT date, symptoms, bodyTemperature FROM health_days ORDER BY date DESC LIMIT 3"'
```

Expected: the logged symptom appears as a JSON array on today's row.

---

### Task 15: Episode log — the ground truth every lead-time claim needs

Today Сергей answers "болею", Jarvis emits `sick_day_ack`, and nothing records when it started, what it was, or when it ended. The onset date for the reference episode (2026-08-10) exists only because he was asked in conversation two days later. Without a stored onset date, lead time is unmeasurable — which means every threshold in this plan is untunable and Phase 5's calibration has no training signal.

The pattern already exists: `loadWorkoutsLog` reads a Greg-appended `workouts.jsonl` from his own writable agent dir. Mirror it.

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (add `loadEpisodes`, `leadTimeDays`; wire into the normal-mode output)
- Modify: `groups/greg/skills/sick-day/SKILL.md`
- Modify: `groups/greg/CLAUDE.md`
- Test: `groups/greg/scripts/analyze.test.js`

**Interfaces:**
- Consumes: `sickDayDetect` from Task 1.
- Produces: `loadEpisodes(path)` → `Map<string, Episode>` keyed by `onset`, where `Episode = { onset: string, confirmed: string|null, resolved: string|null, label: string|null, note: string|null }`. Default path `/workspace/agent/health/episodes.jsonl`.
- Produces: `leadTimeDays(detectionDate, episodes)` → `number | null` — signed days from the detection to the nearest episode onset within ±7 days. Negative = detected late. `0` = same day. Positive = detected before onset.
- Produces: the normal-mode JSON gains `episode: { onset, lead_time_days } | null` when a sick-day fires inside an episode window.

- [ ] **Step 1: Write the failing test**

```javascript
import { loadEpisodes, leadTimeDays } from "./analyze.js";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("episode log", () => {
  function withLog(lines) {
    const dir = mkdtempSync(join(tmpdir(), "greg-ep-"));
    const p = join(dir, "episodes.jsonl");
    writeFileSync(p, lines.map((l) => JSON.stringify(l)).join("\n"));
    return p;
  }

  it("reads episodes keyed by onset, last line per onset wins", () => {
    const p = withLog([
      { onset: "2026-08-10", confirmed: "2026-08-12", resolved: null, label: null },
      { onset: "2026-08-10", confirmed: "2026-08-12", resolved: "2026-08-15", label: "простуда" },
    ]);
    const eps = loadEpisodes(p);
    expect(eps.size).toBe(1);
    expect(eps.get("2026-08-10").resolved).toBe("2026-08-15");
    expect(eps.get("2026-08-10").label).toBe("простуда");
  });

  it("returns an empty map when the file is absent", () => {
    expect(loadEpisodes("/nonexistent/episodes.jsonl").size).toBe(0);
  });

  it("scores same-day detection as zero", () => {
    const eps = loadEpisodes(withLog([{ onset: "2026-08-10" }]));
    expect(leadTimeDays("2026-08-10", eps)).toBe(0);
  });

  it("scores late detection as negative", () => {
    const eps = loadEpisodes(withLog([{ onset: "2026-08-10" }]));
    expect(leadTimeDays("2026-08-12", eps)).toBe(-2);
  });

  it("scores early detection as positive", () => {
    const eps = loadEpisodes(withLog([{ onset: "2026-08-10" }]));
    expect(leadTimeDays("2026-08-08", eps)).toBe(2);
  });

  it("ignores episodes further than 7 days away", () => {
    const eps = loadEpisodes(withLog([{ onset: "2026-08-10" }]));
    expect(leadTimeDays("2026-09-01", eps)).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `loadEpisodes` is not exported.

- [ ] **Step 3: Implement**

Next to `loadWorkoutsLog`:

```javascript
// Illness episode log, appended by Greg when the person confirms or denies being
// ill: {onset, confirmed, resolved, label, note}. `onset` is the day symptoms
// STARTED, which is not the day Greg asked — on the reference episode those were
// 2026-08-10 and 2026-08-12. Without this file lead time cannot be measured and
// no threshold in the sick-day rule can be honestly tuned.
export function loadEpisodes(path) {
  let text; try { text = readFileSync(path, "utf8"); } catch { return new Map(); }
  const byOnset = new Map();
  for (const line of text.split("\n")) {
    const s = line.trim(); if (!s) continue;
    let r; try { r = JSON.parse(s); } catch { continue; }
    if (r && r.onset) {
      byOnset.set(r.onset, {
        onset: r.onset,
        confirmed: r.confirmed ?? null,
        resolved: r.resolved ?? null,
        label: r.label ?? null,
        note: r.note ?? null,
      });
    }
  }
  return byOnset;
}

// Signed days from a detection to the nearest onset within a week.
// Negative = late, 0 = same day, positive = ahead of symptoms.
export function leadTimeDays(detectionDate, episodes) {
  const day = 86400000;
  const d = Date.parse(`${detectionDate}T00:00:00Z`);
  if (Number.isNaN(d)) return null;
  let best = null;
  for (const onset of episodes.keys()) {
    const o = Date.parse(`${onset}T00:00:00Z`);
    if (Number.isNaN(o)) continue;
    const diff = Math.round((o - d) / day);
    if (Math.abs(diff) > 7) continue;
    if (best === null || Math.abs(diff) < Math.abs(best)) best = diff;
  }
  return best;
}
```

In the normal-mode entry point, after computing `sick`:

```javascript
  const episodes = loadEpisodes(opts.episodesLog ?? "/workspace/agent/health/episodes.jsonl");
  const lead = sick ? leadTimeDays(sick.date, episodes) : null;
  // ...include in the emitted JSON:
  //   episode: lead === null ? null : { onset: sick.date, lead_time_days: lead },
```

Add `--episodes-log FILE` to `parseModeArgs` alongside the existing `--workouts-log`.

- [ ] **Step 4: Run the tests**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS.

- [ ] **Step 5: Teach Greg to fill it**

In `groups/greg/skills/sick-day/SKILL.md`:

````markdown
## Журнал эпизодов

Файл `/workspace/agent/health/episodes.jsonl`, одна строка на эпизод, дописываешь через `>>`:

```json
{"onset":"2026-08-10","confirmed":"2026-08-12","resolved":null,"label":null,"note":"жалоб не спрашивали до 12-го"}
```

- **`onset` — день, когда началось САМОЧУВСТВИЕ, а не день, когда ты спросил.** Это разные даты: в эталонном эпизоде 10-е и 12-е. Спрашивай явно: «с какого дня накрыло?» — и записывай ответ, а не дату разговора.
- `confirmed` — день, когда человек подтвердил.
- `resolved` — заполняешь позже, когда он говорит что отпустило, или когда пульс покоя и вариабельность вернулись в базу на два дня подряд. Перезапиши строку целиком с тем же `onset` — читается последняя.
- `label` — чем оказалось, словами человека («простуда», «отравился», «просто недоспал»). Пусто — нормально.
- **Ложную тревогу тоже записывай**: если человек говорит «да нет, я в порядке» — строка с `label:"ложная тревога"` и `resolved` = тот же день. Без ложных срабатываний в журнале калибровать нечего.

Скрипт считает `lead_time_days` сам: 0 = поймали в день начала, отрицательное = опоздали. Не считай в уме.
````

- [ ] **Step 6: Add it to the data dictionary**

In `groups/greg/CLAUDE.md`:

```markdown
- **`episodes.jsonl`** — журнал эпизодов болезни, пишешь его ты (см. skill `sick-day`). Единственный источник истины по датам начала. Поле `episode.lead_time_days` в выводе скрипта: 0 = поймали в день начала симптомов, −2 = опоздали на два дня. Не выдумывай это число и не выводи из даты разговора.
```

- [ ] **Step 7: Seed the known episode**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "echo '"'"'{\"onset\":\"2026-08-10\",\"confirmed\":\"2026-08-12\",\"resolved\":null,\"label\":null,\"note\":\"onset reported retrospectively by Сергей 2026-08-12\"}'"'"' >> /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/episodes.jsonl"'
```

Verify:

```bash
ssh root@148.253.211.164 'cat /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/episodes.jsonl'
```

Expected: the one seeded line. Confirm the path matches the container's `/workspace/agent/health/` mount before writing — check `container.json` for the mount source if unsure.

---

### Task 16: Say when a signal is missing instead of scoring around it

`wristTempDeviation` is absent on 6 of 61 days — and one of those six is 2026-08-12, the peak of the episode. 90% coverage does not help when the missing 10% lands on the day that matters. `sickDayDetect` treats an absent signal as "did not fire", so that day was scored as a quiet 4-of-5 rather than a blind 4-of-4. Coverage is also the honest input to any future confidence number, so it needs to be a value, not a silence.

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (`sickDayDetect`, `computeCoverage`)
- Modify: `src/modules/health-trigger/sick-day.ts` (`detect`)
- Modify: `groups/greg/CLAUDE.md`
- Test: `groups/greg/scripts/analyze.test.js`, `src/modules/health-trigger/sick-day.test.ts`

**Interfaces:**
- Consumes: `sickDayDetect` / `detect` from Task 1 and Task 14.
- Produces: both add `unavailable: string[]` to their return value — the signal names that could not be evaluated today, either because today's value is missing or because the baseline had fewer than 4 points. `matched` keeps counting only real fires; `unavailable.length` is reported separately, never folded into it.
- Produces: `computeCoverage` tracks the sick-day signal set in addition to its current seven metrics.

- [ ] **Step 1: Write the failing test**

```javascript
it("names the signals it could not evaluate", () => {
  const rows = quietDays(14).map(({ wristTempDeviation, ...r }) => r);
  rows.push({
    date: "2026-07-15",
    restingHeartRate: 70, hrvMorning: 30,
    respiratoryRate: 17.4, awakeMin: 18,     // no temp anywhere in the series
  });
  const d = sickDayDetect(rows);
  expect(d.matched).toBe(3);
  expect(d.unavailable).toEqual(["temp"]);
});

it("reports an empty unavailable list when every signal is present", () => {
  const rows = quietDays(14);
  rows.push({
    date: "2026-07-15",
    restingHeartRate: 70, hrv: 46, hrvMorning: 30,
    wristTempDeviation: 35.9, respiratoryRate: 17.4, awakeMin: 60,
  });
  expect(sickDayDetect(rows).unavailable).toEqual([]);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `unavailable` undefined.

- [ ] **Step 3: Implement in both copies**

In `sickDayDetect`, alongside the `fires` object:

```javascript
  // A signal with no data today, or with too thin a baseline to compare against,
  // is NOT a signal that failed to fire — it is a signal we are blind to. Report
  // the two states separately: wrist temperature was missing on 2026-08-12, the
  // most diagnostic day of the reference episode, and nothing said so.
  const evaluable = {
    rhr: rhrDelta !== null, hrv: hrvDelta !== null, temp: tempDelta !== null,
    rr: rrDelta !== null, awake: awakeRatio !== null,
  };
  const unavailable = Object.keys(evaluable).filter((k) => !evaluable[k]);
```

Return it next to `fires`. Mirror the same block in the TypeScript `detect`, widening `Detection` with `unavailable: string[]`.

In `computeCoverage`, extend the tracked list:

```javascript
  const tracked = [
    "hrv", "sleepHours", "restingHeartRate", "heartRate", "steps", "activeEnergy", "exerciseMinutes",
    // The sick-day signal set. Sparse coverage here is not a cosmetic gap — it is
    // the detector going blind on exactly the metrics illness moves first.
    "hrvMorning", "wristTempDeviation", "respiratoryRate", "awakeMin",
  ];
```

- [ ] **Step 4: Run both suites**

Run: `bun test groups/greg/scripts/analyze.test.js`
Run: `pnpm test src/modules/health-trigger/`
Expected: PASS.

- [ ] **Step 5: Make Greg say it out loud**

In `groups/greg/CLAUDE.md`:

```markdown
- **`unavailable` в `sick_day_check` и в выводе скрипта** — сигналы, которые сегодня НЕ удалось оценить (нет данных за день или база тоньше 4 точек). Это не «сигнал не сработал», это «мы слепы». Называй это человеку вслух: «температуры запястья нет третью ночь — часы не на руке, оценка неполная». Никогда не подавай 2-из-3-доступных как 2-из-5.
```

- [ ] **Step 6: Commit the host side**

```bash
git add src/modules/health-trigger/
git commit -m "feat(greg/sick-day): report signals that could not be evaluated

An absent signal was indistinguishable from a signal that did not fire. Wrist
temperature was missing on 2026-08-12 — the peak of the reference episode — and
the detector reported a quiet 2-of-5 rather than a blind 2-of-4. Split the two
states so coverage can be spoken and, later, discount confidence.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 17: Store interval series instead of one number per night

The pipeline's deepest limitation is not which metrics it collects — coverage is 90–100% — but that it flattens each of them to **one scalar per day** before anything downstream can look. HealthKit holds every sample; `HealthHistory` reduces a whole day of heart rate to a single `discreteAverage`.

That flattening already produces wrong readings today. On 2026-08-12 `heartRate` was 64 and the detector reported it as *down, info* — read as cardio-adaptation. The man was in bed. A whole-day mean over sleeping, sitting and (absent) exercise heart rate is not a quantity anything can interpret, and no weighting scheme fixes a number that means several different things at once.

**Derive late, not early.** The version of this task in the first draft computed four scalars on-device (`nightHrMin`, `nightHrNadirFrac`, …) and discarded the curve. That repeats the original mistake one level down: every derivation baked into the iOS reader is irreversible, and a question asked in three months — "what was HRV during deep sleep only?" — would need a new field and another month of waiting. Storing the series makes every such question answerable retroactively, over all history, from the script side where it is cheap to change.

**Buckets, not raw samples.** Raw heart rate runs about one sample every five seconds during a workout — hundreds of thousands of rows a day, for no analytic gain. 30-minute buckets preserve exactly the resolution the published algorithms consume (RHR-Diff, CuSum and NightSignal all operate at hourly resolution or coarser) at roughly 1/1000 the volume: ~192 rows per day across four metrics, ~70k rows a year. Nadir position lands within ±15 minutes of an 8-hour night, which is 3% — ample.

**This can be answered now, not in a month.** `HealthHistory.fetch(from:to:)` already accepts an arbitrary date range and the refetch mechanism already drives it (`{"from":"2026-07-29","to":"2026-08-12"}`), and HealthKit does not prune samples. So the intervals for the 2026-08-10 episode can be **backfilled** — the pre-onset question gets tested against the one labelled episode we have, this week, instead of waiting for the next illness.

Still framed as an experiment: a negative result closes the question and gets written down, rather than leaving "we should try sub-daily" open forever.

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts` (`HealthUploadDay`)
- Modify: `src/channels/ios-app/v2/health-db.ts` (new `health_intervals` table + writer + prune)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift`
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`
- Modify: `groups/greg/scripts/analyze.js` (`loadIntervals`, derived night/day metrics)
- Create: `ios/JarvisApp/Sources/JarvisAppTests/IntervalBucketTests.swift`

**Interfaces:**
- Consumes: `HealthHistory.overnightWindowStart`, `sleepSamplesByWakeDay` (both already used by the morning-HRV and sleep-phase readers), and the non-destructive upsert from Task 18.
- Produces: `HealthUploadDay.intervals?: Interval[]` where `Interval = { metric: string, start: number (epoch ms), min: number (bucket width), n: number, mean: number, lo?: number, hi?: number, stage?: string }`.
- Produces: table `health_intervals(date, metric, bucket_start, bucket_min, n, mean, lo, hi, stage)` with primary key `(date, metric, bucket_start)`, in the same `health.db`.
- Produces: `loadIntervals(dbPath, { from, to })` in `analyze.js` → `Map<date, Interval[]>`.
- Produces: script-side derived metrics computed from the series, not from iOS — `sleepHr`, `wakeRestHr`, `nightHrMin`, `nightHrNadirFrac`, `nightHrDipPct`, `hrvDeep`. All become ordinary `METRICS` entries.

- [ ] **Step 1: Extend the contract**

In `shared/ios-app-protocol/v2.ts`, above `HealthUploadDay`:

```typescript
// New 2026-08-12. Sub-daily buckets, so downstream can ask questions the daily
// scalars foreclose. 30-minute width matches what the published wearable
// detection algorithms consume (RHR-Diff, CuSum, NightSignal all work at hourly
// resolution or coarser) without the volume of raw samples. `stage` is the
// dominant sleep stage over the bucket, or "awake" — it lets a consumer separate
// sleeping heart rate from sitting-at-a-desk heart rate, which the daily
// discreteAverage mixes into one uninterpretable number.
export const HealthInterval = z.object({
  metric: z.enum(['heartRate', 'hrv', 'respiratoryRate', 'spo2']),
  start: z.number().int(),        // epoch ms, bucket start
  min: z.number().int().positive(), // bucket width in minutes
  n: z.number().int().positive(),   // samples aggregated
  mean: z.number(),
  lo: z.number().optional(),
  hi: z.number().optional(),
  stage: z.enum(['awake', 'core', 'deep', 'rem', 'inBed']).optional(),
});
export type HealthInterval = z.infer<typeof HealthInterval>;
```

and inside `HealthUploadDay`, before `workouts`:

```typescript
  // Attributed to the same wake day as hrvMorning and spo2 — see bucketOvernight.
  intervals: z.array(HealthInterval).optional(),
```

- [ ] **Step 2: Write the failing contract test**

Append to `shared/ios-app-protocol/v2.test.ts`:

```typescript
it('HealthUploadDay carries interval buckets', () => {
  const parsed = HealthUploadDay.parse({
    date: '2026-08-12',
    intervals: [
      { metric: 'heartRate', start: 1786500000000, min: 30, n: 42, mean: 58.3, lo: 54, hi: 63, stage: 'deep' },
    ],
  });
  expect(parsed.intervals).toHaveLength(1);
  expect(parsed.intervals![0].stage).toBe('deep');
});

it('rejects an unknown interval metric', () => {
  expect(() => HealthUploadDay.parse({
    date: '2026-08-12',
    intervals: [{ metric: 'bloodPressure', start: 1, min: 30, n: 1, mean: 1 }],
  })).toThrow();
});
```

Run: `pnpm test shared/ios-app-protocol/`
Expected: FAIL — `intervals` is stripped.

- [ ] **Step 3: Implement the contract, then the store**

Add the schema from Step 1. Then in `src/channels/ios-app/v2/health-db.ts`:

```typescript
export function openHealthDb(path: string): Database.Database {
  // ...existing health_days create + ALTER probe unchanged...
  db.exec(
    `CREATE TABLE IF NOT EXISTS health_intervals (
       date         TEXT    NOT NULL,
       metric       TEXT    NOT NULL,
       bucket_start INTEGER NOT NULL,
       bucket_min   INTEGER NOT NULL,
       n            INTEGER NOT NULL,
       mean         REAL    NOT NULL,
       lo           REAL,
       hi           REAL,
       stage        TEXT,
       PRIMARY KEY (date, metric, bucket_start)
     )`,
  );
  db.exec(`CREATE INDEX IF NOT EXISTS idx_intervals_date ON health_intervals(date)`);
  return db;
}

/** Interval buckets for the given days. Replaces a day+metric wholesale — unlike
 *  health_days these arrive complete or not at all, so there is nothing to
 *  preserve and a re-upload should not leave orphaned buckets behind. */
export function upsertHealthIntervals(db: Database.Database, days: HealthUploadDay[]): void {
  const del = db.prepare(`DELETE FROM health_intervals WHERE date = ? AND metric = ?`);
  const ins = db.prepare(
    `INSERT INTO health_intervals (date, metric, bucket_start, bucket_min, n, mean, lo, hi, stage)
     VALUES (@date, @metric, @bucket_start, @bucket_min, @n, @mean, @lo, @hi, @stage)`,
  );
  const tx = db.transaction((rows: HealthUploadDay[]) => {
    for (const d of rows) {
      if (!d.intervals?.length) continue;
      for (const metric of new Set(d.intervals.map((i) => i.metric))) del.run(d.date, metric);
      for (const iv of d.intervals) {
        ins.run({
          date: d.date, metric: iv.metric, bucket_start: iv.start, bucket_min: iv.min,
          n: iv.n, mean: iv.mean, lo: iv.lo ?? null, hi: iv.hi ?? null, stage: iv.stage ?? null,
        });
      }
    }
  });
  tx(days);
}

/** Keep half a year. ~192 rows/day across four metrics, so this caps the table
 *  near 35k rows — small, but unbounded growth in a file the container reads on
 *  every run is not worth the nothing it would buy. */
export function pruneHealthIntervals(db: Database.Database, keepDays = 180): void {
  db.prepare(
    `DELETE FROM health_intervals
     WHERE date < date('now', ?)`,
  ).run(`-${keepDays} days`);
}
```

Call `upsertHealthIntervals` next to `upsertHealthDays` at the upload handler, and `pruneHealthIntervals` once per upload.

- [ ] **Step 4: Write the failing store test**

In `src/channels/ios-app/v2/health-db.test.ts`:

```typescript
it('stores interval buckets and replaces a metric wholesale on re-upload', () => {
  const db = openHealthDb(`${tmpdir()}/health-iv-${Date.now()}.db`);
  upsertHealthIntervals(db, [{
    date: '2026-08-12',
    intervals: [
      { metric: 'heartRate', start: 1000, min: 30, n: 10, mean: 60 },
      { metric: 'heartRate', start: 2800000, min: 30, n: 12, mean: 58, stage: 'deep' },
      { metric: 'hrv', start: 1000, min: 30, n: 3, mean: 44 },
    ],
  }]);
  // A re-upload with one fewer heartRate bucket must not leave the old one behind.
  upsertHealthIntervals(db, [{
    date: '2026-08-12',
    intervals: [{ metric: 'heartRate', start: 1000, min: 30, n: 11, mean: 61 }],
  }]);

  const hr = db.prepare(`SELECT * FROM health_intervals WHERE date=? AND metric='heartRate'`).all('2026-08-12');
  expect(hr).toHaveLength(1);
  expect(hr[0].mean).toBe(61);
  // hrv was absent from the second payload, so its buckets stand untouched.
  const hrv = db.prepare(`SELECT * FROM health_intervals WHERE date=? AND metric='hrv'`).all('2026-08-12');
  expect(hrv).toHaveLength(1);
});
```

Run: `pnpm test src/channels/ios-app/v2/`
Expected: PASS after Step 3.

- [ ] **Step 5: Write the failing iOS bucketing test**

Create `ios/JarvisApp/Sources/JarvisAppTests/IntervalBucketTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class IntervalBucketTests: XCTestCase {

    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: minutes * 60) }

    func testSamplesGroupIntoThirtyMinuteBuckets() {
        let samples = [
            (value: 60.0, date: at(0)), (value: 62.0, date: at(10)), (value: 58.0, date: at(29)),
            (value: 90.0, date: at(31)),
        ]
        let out = HealthHistory.bucketize(samples, metric: "heartRate", widthMin: 30, stageAt: { _ in nil })
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].n, 3)
        XCTAssertEqual(out[0].mean, 60, accuracy: 0.01)
        XCTAssertEqual(out[0].lo, 58)
        XCTAssertEqual(out[0].hi, 62)
        XCTAssertEqual(out[1].n, 1)
        XCTAssertEqual(out[1].mean, 90, accuracy: 0.01)
    }

    func testBucketStartIsAlignedToTheWidth() {
        let out = HealthHistory.bucketize(
            [(value: 60.0, date: at(47))], metric: "heartRate", widthMin: 30, stageAt: { _ in nil }
        )
        XCTAssertEqual(out[0].start, Int(at(30).timeIntervalSince1970 * 1000))
    }

    func testStageIsTakenFromTheBucketMidpoint() {
        let out = HealthHistory.bucketize(
            [(value: 55.0, date: at(5))], metric: "heartRate", widthMin: 30, stageAt: { _ in "deep" }
        )
        XCTAssertEqual(out[0].stage, "deep")
    }

    func testEmptyInputYieldsNoBuckets() {
        XCTAssertTrue(HealthHistory.bucketize([], metric: "hrv", widthMin: 30, stageAt: { _ in nil }).isEmpty)
    }
}
```

```bash
cd ios/JarvisApp && xcodegen generate
```

Run the test scheme.
Expected: FAIL to compile — `bucketize` does not exist.

- [ ] **Step 6: Implement bucketing and the four readers**

In `HealthHistory.swift`:

```swift
    /// Fold timestamped samples into fixed-width buckets aligned to the epoch.
    /// `stageAt` resolves the sleep stage covering a moment, or nil when awake or
    /// unknown. Alignment is absolute rather than relative to the first sample so
    /// buckets from different days and metrics line up.
    static func bucketize(
        _ samples: [(value: Double, date: Date)],
        metric: String,
        widthMin: Int,
        stageAt: (Date) -> String?
    ) -> [V2.HealthUpload.Interval] {
        guard !samples.isEmpty, widthMin > 0 else { return [] }
        let width = Double(widthMin) * 60
        var groups: [Double: [Double]] = [:]
        for s in samples {
            let bucket = (s.date.timeIntervalSince1970 / width).rounded(.down) * width
            groups[bucket, default: []].append(s.value)
        }
        return groups.keys.sorted().map { start in
            let vals = groups[start]!
            let mid = Date(timeIntervalSince1970: start + width / 2)
            return V2.HealthUpload.Interval(
                metric: metric,
                start: Int(start * 1000),
                min: widthMin,
                n: vals.count,
                mean: (vals.reduce(0, +) / Double(vals.count) * 100).rounded() / 100,
                lo: vals.min(),
                hi: vals.max(),
                stage: stageAt(mid)
            )
        }
    }
```

Then one sample query per metric over the same `sleepStart…end` range already used by the morning-HRV reader, each feeding `bucketize` and appending to the day's `intervals`. Build `stageAt` from the sleep intervals `sleepSamplesByWakeDay` already returns — it yields `SleepSampleInput { stage, start, end }`, so a linear scan for the interval containing a moment is enough at this volume.

The four metrics and their units: `.heartRate` (count/min), `.heartRateVariabilitySDNN` (ms), `.respiratoryRate` (count/min), `.oxygenSaturation` (percent × 100).

Attribute each bucket to the same wake day the existing overnight readers use, so `intervals` and `hrvMorning` never disagree about which night a row belongs to.

Add `Interval` to `V2.HealthUpload` in `Protocol/V2.swift`, mirroring the Zod shape field for field. Bump `CURRENT_PROJECT_VERSION`, `xcodegen generate`.

Run the test scheme.
Expected: PASS.

- [ ] **Step 7: Derive the metrics script-side, where they stay changeable**

In `groups/greg/scripts/analyze.js`:

```javascript
// Interval buckets, read from the same health.db. Everything below is derived
// HERE and not on the phone: a derivation baked into the iOS reader is permanent
// and answers only the question we thought to ask, while these can be rewritten
// and re-run over all stored history in an afternoon.
export function loadIntervals(path) {
  let db;
  try { db = new Database(path, { readonly: true }); } catch { return new Map(); }
  let rows;
  try {
    rows = db.query(
      `SELECT date, metric, bucket_start, bucket_min, n, mean, lo, hi, stage
       FROM health_intervals ORDER BY date, bucket_start`,
    ).all();
  } catch { db.close(); return new Map(); }
  db.close();
  const byDate = new Map();
  for (const r of rows) {
    if (!byDate.has(r.date)) byDate.set(r.date, []);
    byDate.get(r.date).push(r);
  }
  return byDate;
}

const ASLEEP = new Set(["core", "deep", "rem"]);

// Split the day's heart rate by what the body was actually doing. The daily
// discreteAverage mixes sleeping, sitting and exercising heart rate into one
// figure: on 2026-08-12 it read 64 and was flagged "down, info" as cardio
// adaptation while the person was in bed with a 21% elevated resting pulse.
export function deriveFromIntervals(rows, byDate) {
  for (const r of rows) {
    const ivs = byDate.get(r.date);
    if (!ivs) continue;
    const hr = ivs.filter((i) => i.metric === "heartRate");
    const asleep = hr.filter((i) => ASLEEP.has(i.stage));
    const awake = hr.filter((i) => i.stage === "awake" || i.stage == null);

    if (asleep.length >= 4) {
      const means = asleep.map((i) => i.mean);
      const nightMean = means.reduce((a, b) => a + b, 0) / means.length;
      const nadir = asleep.reduce((a, b) => (b.mean < a.mean ? b : a));
      const t0 = asleep[0].bucket_start;
      const span = asleep[asleep.length - 1].bucket_start - t0;
      r.sleepHr = Math.round(nightMean);
      r.nightHrMin = Math.round(nadir.mean);
      r.nightHrNadirFrac = span > 0
        ? Math.round(((nadir.bucket_start - t0) / span) * 100) / 100 : null;
      r.nightHrDipPct = nightMean > 0
        ? Math.round(((nightMean - nadir.mean) / nightMean) * 1000) / 10 : null;
    }
    // Awake resting pulse: the 20th percentile of awake buckets, which lands on
    // quiet moments and ignores walking and training without needing step data.
    if (awake.length >= 6) {
      const s = awake.map((i) => i.mean).sort((a, b) => a - b);
      r.wakeRestHr = Math.round(s[Math.floor(s.length * 0.2)]);
    }
    // HRV restricted to deep sleep — the cleanest autonomic window there is, and
    // a question the daily SDNN average cannot be asked at all.
    const deepHrv = ivs.filter((i) => i.metric === "hrv" && i.stage === "deep");
    if (deepHrv.length >= 2) {
      r.hrvDeep = Math.round(deepHrv.reduce((a, b) => a + b.mean, 0) / deepHrv.length);
    }
  }
  return rows;
}
```

Call `deriveFromIntervals(rows, loadIntervals(opts.raw))` immediately before `buildDerived`. Add `sleepHr`, `wakeRestHr`, `nightHrMin`, `nightHrNadirFrac`, `nightHrDipPct`, `hrvDeep` to `METRICS`; `sleepHr`, `wakeRestHr`, `nightHrMin` to `CONCERN_UP`; `nightHrDipPct` and `hrvDeep` to `CONCERN_DOWN`. `nightHrNadirFrac` belongs to neither — a shift either way is notable and the direction alone does not say which is worse.

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS — existing fixtures carry no intervals, so every new metric is simply absent.

- [ ] **Step 8: Ship, then backfill 90 days**

Deploy per the Deploy Reference — host plus `./container/build.sh` (the contract changed), then the agent script, then the iOS build.

Then drive the existing refetch mechanism over history, in the 15-day windows it already uses:

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c '"'"'
cd /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/requests
for r in 2026-05-15:2026-05-29 2026-05-30:2026-06-13 2026-06-14:2026-06-28 \
         2026-06-29:2026-07-13 2026-07-14:2026-07-28 2026-07-29:2026-08-12; do
  f=${r%%:*}; t=${r##*:}
  echo "{ \"from\": \"$f\", \"to\": \"$t\" }" > "backfill_${f}.json"
done
ls -la
'"'"''
```

The phone services one request per foreground sync. Verify the buckets land:

```bash
ssh root@148.253.211.164 '/usr/bin/node /tmp/q.cjs /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/health.db "SELECT date, metric, count(*) n FROM health_intervals GROUP BY date, metric ORDER BY date DESC LIMIT 20"'
```

Expected: roughly 16–48 `heartRate` buckets per day, fewer for `hrv` and `spo2` (sparser samplers). If a day shows one or two buckets, the sleep-window attribution is wrong — check it against that day's `hrvMorning`, which must belong to the same night.

- [ ] **Step 9: Run the experiment on the episode we already have**

This is why the backfill matters: the answer does not wait for the next illness.

```javascript
// /tmp/greg-bt/prodrome.js — did sub-daily resolution move before onset (08-10)
// on days where every daily aggregate stayed flat?
import { loadRows, loadIntervals, deriveFromIntervals, loadEpisodes }
  from "/Users/serg/git/nanoclaw/groups/greg/scripts/analyze.js";
const rows = deriveFromIntervals(loadRows("/tmp/greg-bt/health.db"), loadIntervals("/tmp/greg-bt/health.db"));
const M = ["sleepHr", "wakeRestHr", "nightHrMin", "nightHrNadirFrac", "nightHrDipPct", "hrvDeep",
           "restingHeartRate", "hrvMorning"];   // last two = the daily aggregates, for contrast
for (const onset of loadEpisodes("/tmp/greg-bt/episodes.jsonl").keys()) {
  const i = rows.findIndex((r) => r.date === onset);
  if (i < 6) continue;
  console.log(`--- onset ${onset}`);
  for (const m of M) {
    console.log(`  ${m.padEnd(18)} ` +
      rows.slice(i - 4, i + 2).map((r) => `${r.date.slice(5)}:${r[m] ?? "-"}`).join("  "));
  }
}
```

Run: `bun /tmp/greg-bt/prodrome.js`

Read it against the known shape of the episode: on 08-08 and 08-09 every daily aggregate was flat except morning HRV, which is this person's noisiest signal. The question is whether any interval-derived metric moved on those two days and stayed quiet across the healthy weeks.

- [ ] **Step 10: Write the verdict into this plan**

Add an `## Experiment result` section under Task 17 with one of two outcomes, and the numbers behind it:

- **Reachable** — an interval-derived metric separates 08-08/08-09 from the healthy baseline. Then run it through the same discipline as Task 19: measure its false-alarm rate across the pre-onset days, weight it accordingly, and only then let it into the rule. A metric that moves before onset *and* fires on a third of healthy days has bought nothing.
- **Not reachable** — nothing moves earlier than the daily aggregates already did. Then say so plainly here, and add a line to `groups/greg/CLAUDE.md` telling Greg he detects illness at onset and never before it, so he does not narrate a foresight he does not have. The intervals stay regardless: they fix the whole-day `heartRate` conflation, which was wrong on its own merits.

---

### Task 18: Stop partial re-uploads from erasing stored measurements

`upsertHealthDays` rebuilds every column on every write:

```typescript
for (const c of SCALARS) rec[c] = (d as Record<string, unknown>)[c] ?? null;
// ... ON CONFLICT(date) DO UPDATE SET <every column> = excluded.<column>
```

Every field of `HealthUploadDay` is optional, and the iOS client sends only what HealthKit had at query time. So **any** upload for a date overwrites that date's whole row, nulling every column the new payload happens to lack. A refetch that runs before Apple has materialised the night's sleeping wrist temperature does not leave the old value alone — it deletes it.

This is not hypothetical traffic. Every row in the store gets rewritten, often days after the fact, and `refresh_<date>.json` requests fire daily:

| date | last ingested | temp |
|---|---|---|
| 2026-08-04 | 2026-08-07 15:09 | **missing** |
| 2026-08-05 | 2026-08-08 18:22 | **missing** |
| 2026-08-06 | 2026-08-09 16:46 | present |
| 2026-08-07 | 2026-08-10 13:58 | **missing** |
| 2026-08-09…08-12 | 2026-08-12 06:06 (one bulk refetch) | 08-12 **missing** |

Three of the four August gaps sit on rows last written ~3 days after the date they describe. That is consistent with a late partial write clobbering a good value, though it does not prove it — Apple may also simply not have emitted those samples. The fix is correct either way, and it is one line: a re-upload should be able to add a measurement or correct one, never to erase one.

**Files:**
- Modify: `src/channels/ios-app/v2/health-db.ts` (`upsertHealthDays`)
- Test: `src/channels/ios-app/v2/health-db.test.ts` (created in Task 12 Step 5b)

**Interfaces:**
- Consumes: the `SCALARS` list and `symptoms` column from Task 12.
- Produces: `upsertHealthDays` becomes additive — a column already holding a value keeps it unless the incoming payload carries a non-null replacement. `date` and `ingested_at` still overwrite unconditionally.

- [ ] **Step 1: Write the failing test**

```typescript
it('a partial re-upload does not erase columns it omits', () => {
  const db = openHealthDb(`${tmpdir()}/health-partial-${Date.now()}.db`);
  upsertHealthDays(db, [{
    date: '2026-08-12',
    steps: 1847,
    restingHeartRate: 74,
    wristTempDeviation: 36.19,
    respiratoryRate: 16.7,
  }]);
  // A later refetch for the same date that HealthKit could not fully answer.
  upsertHealthDays(db, [{ date: '2026-08-12', steps: 1902 }]);

  const [row] = readHealthDays(db);
  expect(row.steps).toBe(1902);                 // present in the new payload → updated
  expect(row.wristTempDeviation).toBe(36.19);   // absent from it → preserved
  expect(row.respiratoryRate).toBe(16.7);
  expect(row.restingHeartRate).toBe(74);
});

it('still overwrites a value when the new payload carries one', () => {
  const db = openHealthDb(`${tmpdir()}/health-overwrite-${Date.now()}.db`);
  upsertHealthDays(db, [{ date: '2026-08-12', restingHeartRate: 74 }]);
  upsertHealthDays(db, [{ date: '2026-08-12', restingHeartRate: 68 }]);
  expect(readHealthDays(db)[0].restingHeartRate).toBe(68);
});

it('preserves symptoms and workouts across a partial re-upload', () => {
  const db = openHealthDb(`${tmpdir()}/health-json-${Date.now()}.db`);
  upsertHealthDays(db, [{ date: '2026-08-12', symptoms: ['fever'], steps: 100 }]);
  upsertHealthDays(db, [{ date: '2026-08-12', steps: 200 }]);
  expect(readHealthDays(db)[0].symptoms).toEqual(['fever']);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm test src/channels/ios-app/v2/health-db.test.ts`
Expected: FAIL — `row.wristTempDeviation` is `null`; `symptoms` is `undefined`.

- [ ] **Step 3: Make the upsert additive**

In `upsertHealthDays`, change only how `updates` is built:

```typescript
  // COALESCE, not plain assignment. Every HealthUploadDay field is optional and
  // iOS sends only what HealthKit had at query time, so a plain overwrite lets a
  // partial refetch delete measurements that were already stored — the row for a
  // date is rewritten repeatedly, sometimes days later. A re-upload may add a
  // value or replace one, never erase one. `ingested_at` is exempt: it must
  // always advance so the last-write time stays truthful.
  const updates = cols
    .filter((c) => c !== 'date')
    .map((c) => (c === 'ingested_at' ? `${c}=excluded.${c}` : `${c}=COALESCE(excluded.${c}, ${c})`))
    .join(', ');
```

Leave the `rec[c] = … ?? null` line alone — `excluded.<col>` being null is exactly what `COALESCE` needs to see in order to fall through to the stored value.

- [ ] **Step 4: Run the tests**

Run: `pnpm test src/channels/ios-app/v2/`
Expected: PASS, including Task 12's migration test.

- [ ] **Step 5: Check whether it explains the gaps**

Deploy, then watch whether new temperature gaps stop appearing:

```bash
ssh root@148.253.211.164 '/usr/bin/node /tmp/q.cjs /home/nanoclaw/nanoclaw/data/user-memory/owner/greg/health/health.db "SELECT count(*) days, count(wristTempDeviation) temp FROM health_days WHERE date >= date(\"now\",\"-14 days\")"'
```

Expected after two weeks: `temp` equals `days`. If gaps persist at a similar rate, the cause is upstream in HealthKit rather than in our writer — record that conclusion here, because it changes Task 17's read of what continuous temperature would buy.

- [ ] **Step 6: Commit**

```bash
git add src/channels/ios-app/v2/
git commit -m "fix(health): partial re-uploads must not erase stored measurements

Every HealthUploadDay field is optional and iOS sends only what HealthKit had
at query time, but the upsert rebuilt every column from the incoming payload
and nulled whatever it omitted. Rows are rewritten routinely — three of four
August wrist-temperature gaps sit on rows last written ~3 days after their own
date, and one of them is the peak day of a real illness episode.

COALESCE on update: a re-upload can add or correct a value, never delete one.
ingested_at still advances unconditionally.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 19: Weight signals by how quiet they are when healthy

> **Execute immediately after Task 4.** This depends only on Task 1 and supersedes its fire threshold. It is numbered last purely to avoid renumbering the rest of an approved plan.

Counting five signals as equal votes assumes they are equally trustworthy. Measured over the 74 pre-onset days in `health.db`, they are not — by a factor of nine:

| signal | fires on healthy days | value on onset day 08-10 |
|---|---|---|
| `rhr` | 2/74 — **3%** | 0.23 |
| `rr` | 3/62 — **5%** | 0.95 (just under) |
| `awake` | 7/57 — 12% | 1.65 — fires |
| `temp` | 9/57 — 16% | 2.50 — fires |
| `hrv` | 20/74 — **27%** | −2.22 (HRV was *high* that day) |

Morning HRV clears its threshold on more than a quarter of healthy days and contributes most of the plan's 11% false-alarm rate, while resting heart rate is almost silent when healthy. A vote-counting rule cannot express that. A weighted sum can, and the improvement is large:

| rule | false alarms | fires on onset |
|---|---|---|
| 2-of-5 vote (Task 1) | 8/74 — 11% | yes, 08-10 |
| weighted, T=3.0 | 4/74 — 5% | yes, 08-10 |
| weighted, T=3.5 | 1/74 — 1% | yes, 08-10 |
| **weighted, T=4.5** | **0/74 — 0%** | **yes, 08-10** |

Same-day detection at zero measured false alarms, against eleven percent. Note what is and is not supported by sample size: the weights and the false-alarm rates come from 74 healthy days and are reasonably solid; "fires on onset" rests on **one** episode. So set the threshold from a false-alarm budget, never by tuning until it hits 08-10 — that way round is overfitting to n=1.

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (`SICK_DAY_THRESHOLDS`, `sickDayDetect`)
- Modify: `src/modules/health-trigger/sick-day.ts` (`SICK_DAY_THRESHOLDS`, `detect`)
- Modify: `groups/greg/CLAUDE.md`
- Test: `groups/greg/scripts/analyze.test.js`, `src/modules/health-trigger/sick-day.test.ts`

**Interfaces:**
- Consumes: `fires` / `unavailable` from Tasks 1 and 16.
- Produces: both detectors gain `score` (number, 2 decimals) and `score_threshold` (number). `matched` and `fires` stay exactly as they are — they remain the human-readable evidence list, and Greg still quotes them. The fire decision moves from `matched >= 2` to `score >= score_threshold`.
- Produces: `SIGNAL_WEIGHTS = { rhr: 1.76, hrv: 0.42, temp: 0.65, rr: 1.38, awake: 0.79 }` and `SICK_DAY_SCORE_T = 3.0`, exported from both files.
- Produces: `rrAbs` drops from `1.0` to `0.9`.

- [ ] **Step 1: Take the free respiratory-rate fix first**

Respiratory rate scored 0.95 against a 1.0 threshold on onset day — it missed by five percent. Measured across the pre-onset days, tightening the threshold costs nothing:

| threshold | false alarms | onset day |
|---|---|---|
| +1.0 br/min | 3/62 — 5% | 0.95, silent |
| **+0.9 br/min** | **3/62 — 5%** | **1.06, fires** |
| +0.8 br/min | 4/62 — 6% | 1.19, fires |

Change `rrAbs: 1.0` to `rrAbs: 0.9` in both `SICK_DAY_THRESHOLDS` copies, and update the two doc lines in `groups/greg/CLAUDE.md` that quote "+1.0 вдоха/мин".

- [ ] **Step 2: Write the failing test**

```javascript
import { sickDayDetect, SIGNAL_WEIGHTS, SICK_DAY_SCORE_T } from "./analyze.js";

describe("weighted sick-day score", () => {
  it("weights resting heart rate far above morning HRV", () => {
    // Measured on 74 healthy days: rhr clears threshold on 3% of them, hrv on 27%.
    expect(SIGNAL_WEIGHTS.rhr).toBeGreaterThan(SIGNAL_WEIGHTS.hrv * 3);
    expect(SICK_DAY_SCORE_T).toBe(3.0);
  });

  it("a lone noisy-signal day scores below threshold", () => {
    // hrv -40% and nothing else: weight 0.42 x exceedance 2.67 = 1.12, well under 3.0.
    const rows = quietDays(14);
    rows.push({
      date: "2026-07-15",
      restingHeartRate: 61, hrv: 46, hrvMorning: 28,
      wristTempDeviation: 35.2, respiratoryRate: 15.9, awakeMin: 18,
    });
    const d = sickDayDetect(rows);
    expect(d).toBeNull();
  });

  it("a quiet-signal day clears threshold on less deviation", () => {
    // rhr +21% alone: weight 1.76 x exceedance 3.0 (clipped) = 5.28.
    const rows = quietDays(14);
    rows.push({
      date: "2026-07-15",
      restingHeartRate: 74, hrv: 46, hrvMorning: 47,
      wristTempDeviation: 35.2, respiratoryRate: 15.9, awakeMin: 18,
    });
    const d = sickDayDetect(rows);
    expect(d).not.toBeNull();
    expect(d.score).toBeGreaterThanOrEqual(SICK_DAY_SCORE_T);
    expect(d.fires.rhr).toBe(true);
  });

  it("normalises the threshold when a signal is unavailable", () => {
    // With temp absent, only 4.34 of the 5.00 total weight can contribute, so
    // demanding the full 3.0 would make a blind night quietly harder to flag.
    const rows = quietDays(14).map(({ wristTempDeviation, ...r }) => r);
    rows.push({
      date: "2026-07-15",
      restingHeartRate: 74, hrv: 46, hrvMorning: 47,
      respiratoryRate: 15.9, awakeMin: 18,
    });
    const d = sickDayDetect(rows);
    expect(d).not.toBeNull();
    expect(d.unavailable).toEqual(["temp"]);
    expect(d.score_threshold).toBeCloseTo(3.0 * (5.00 - 0.65) / 5.00, 2);
  });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: FAIL — `SIGNAL_WEIGHTS` is not exported.

- [ ] **Step 4: Implement**

```javascript
// Weight each signal by how quiet it is on this person's healthy days, measured
// over the 74 pre-onset days in health.db (2026-06 .. 2026-08-09):
//   rhr 3% | rr 5% | awake 12% | temp 16% | hrv 27%
// Weight = 1/(false_alarm_rate + 0.05), normalised to mean 1.0. Morning HRV
// clears its threshold on more than a quarter of healthy days and is worth a
// quarter of resting heart rate, which is nearly silent when healthy. Counting
// them as equal votes is what produced an 11% false-alarm rate.
//
// RECALIBRATE these against real data as episodes accumulate — they describe one
// person over ten weeks, not a population. The recipe is in Task 19 of the plan.
export const SIGNAL_WEIGHTS = { rhr: 1.76, hrv: 0.42, temp: 0.65, rr: 1.38, awake: 0.79 };
const TOTAL_WEIGHT = Object.values(SIGNAL_WEIGHTS).reduce((a, b) => a + b, 0);

// Chosen from a false-alarm budget, NOT by tuning until it hits a known episode:
// 3.0 costs 4 alarms across 74 healthy days (~5%, roughly one a month). Raising it
// to 3.5 gives 1%. Lead time is whatever falls out — do not tune it the other way,
// there is only one labelled episode and that way is overfitting.
export const SICK_DAY_SCORE_T = 3.0;

// Per-signal exceedance: 1.0 means exactly at threshold. Clipped at 3 so one
// extreme reading cannot carry the whole score on its own.
function exceedances(deltas, thresholds) {
  return {
    rhr:   deltas.rhr   === null ? null : Math.max(0, deltas.rhr / thresholds.rhrPct),
    hrv:   deltas.hrv   === null ? null : Math.max(0, -deltas.hrv / thresholds.hrvPct),
    temp:  deltas.temp  === null ? null : Math.max(0, deltas.temp / thresholds.tempC),
    rr:    deltas.rr    === null ? null : Math.max(0, deltas.rr / thresholds.rrAbs),
    awake: deltas.awake === null ? null : Math.max(0, deltas.awake / thresholds.awakeRatio),
  };
}
```

Inside `sickDayDetect`, after building `fires` and `unavailable`, replace the `if (matched < 2) return null;` gate:

```javascript
  const ex = exceedances(
    { rhr: rhrDelta, hrv: hrvDelta, temp: tempDelta, rr: rrDelta, awake: awakeRatio },
    thresholds,
  );
  let score = 0, availableWeight = 0;
  for (const k of Object.keys(SIGNAL_WEIGHTS)) {
    if (ex[k] === null) continue;
    availableWeight += SIGNAL_WEIGHTS[k];
    score += SIGNAL_WEIGHTS[k] * Math.min(3, ex[k]);
  }
  // Scale the bar to the weight actually on the table. Without this, a night
  // missing wrist temperature silently needs more evidence than a complete one —
  // the detector would get quieter exactly when it is already partly blind.
  const scoreThreshold = availableWeight > 0
    ? Math.round(SICK_DAY_SCORE_T * (availableWeight / TOTAL_WEIGHT) * 100) / 100
    : SICK_DAY_SCORE_T;
  score = Math.round(score * 100) / 100;
  if (score < scoreThreshold) return null;
```

Return `score` and `score_threshold` alongside `matched`, `fires`, `signal` and `unavailable`. Note the `awakeRatio` delta enters `exceedances` as a ratio, not a difference — it is already normalised against its own threshold of 2.0 in the same way.

Mirror the whole block into the TypeScript `detect`, widening `Detection` with `score: number` and `score_threshold: number`.

- [ ] **Step 5: Run both suites**

Run: `bun test groups/greg/scripts/analyze.test.js`
Run: `pnpm test src/modules/health-trigger/`
Expected: PASS. Task 1's own cases still pass — `matched` and `fires` are unchanged; only the gate moved.

- [ ] **Step 6: Re-measure both numbers on real data**

Run: `bun /tmp/greg-bt/fp.js`
Expected: `pre-onset days 74, fired 4 (5%)` — down from 8 (11%).

Run: `bun /tmp/greg-bt/backtest.js`
Expected: still first fires on `2026-08-10`. If it now fires later, the threshold is too high for the budget chosen — lower it and re-run `fp.js`, in that order.

- [ ] **Step 7: Give Greg the vocabulary**

In `groups/greg/CLAUDE.md`:

```markdown
- **Сигналы sick-day не равнозначны — у каждого свой вес**, измеренный по тому, насколько он тих в здоровые дни этого человека: пульс покоя 1.76, частота дыхания 1.38, ночное бодрствование 0.79, температура запястья 0.65, утренняя вариабельность 0.42. Утренняя HRV срабатывает вхолостую больше чем в четверти здоровых дней — **не строй на ней вывод в одиночку**. Пульс покоя почти не шумит: если он выбился, это весомо.
- **`score` и `score_threshold`** — решение принимает скрипт по ним, а не по `matched`. `matched` и `fires` остаются перечнем улик для человека: называй, что именно сработало, но не пересчитывай порог в уме.
- Порог подстраивается под доступные сигналы: если температуры нет, `score_threshold` пропорционально ниже. Слепая ночь не должна требовать больше улик, чем полная.
```

- [ ] **Step 8: Write down the recalibration recipe**

Add to the end of this task in the plan, so the weights do not silently rot:

> Re-derive the weights whenever `episodes.jsonl` (Task 15) gains a labelled episode. For each signal, compute the share of days *outside* any episode window on which it clears its own threshold; weight = 1/(rate + 0.05), normalised to mean 1.0. Then pick the threshold from the alarm budget, not from the episodes. Record the previous weights and the date in a comment above `SIGNAL_WEIGHTS` so drift is visible.

- [ ] **Step 9: Commit**

```bash
git add src/modules/health-trigger/
git commit -m "feat(greg/sick-day): weight signals by their healthy-day false-alarm rate

Five signals were counted as equal votes. Measured over 74 pre-onset days they
differ ninefold: resting heart rate clears its threshold on 3% of healthy days,
morning HRV on 27%. HRV supplied most of the rule's false alarms while being the
least informative signal this person has.

Weight = 1/(false-alarm rate + 0.05), normalised to mean 1.0, score clipped at
3x threshold per signal, bar scaled to the weight actually available so a night
missing wrist temperature does not silently need more evidence. Threshold picked
from an alarm budget rather than tuned to the one labelled episode: 5% of days
at T=3.0, against 11% for the vote rule, with the same onset-day detection.

Respiratory rate threshold 1.0 -> 0.9 br/min: it scored 0.95 on onset day and
the tightening costs no additional false alarms (3/62 either way).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Phase 5 — Diagnostician (separate spec required)

**Not planned here, and deliberately so.** Phases 1–4 change what Greg can *see*. Turning that into cause-level hypotheses with a stated confidence, plus calibration against outcomes and ingestion of lab documents, is a different piece of work with its own design questions — several of them still open from the half-finished brainstorm (confidence banding, where hypotheses are stored, how outcomes get captured).

What Phases 1–4 hand it, and what it must not be started without:

| Prerequisite | Delivered by |
|---|---|
| `shape` / `z_today` — distinguishes "happened today" from "drifting for weeks" | Task 2 |
| A 7-signal sick-day vector with a per-signal `fires` map — the natural evidence list behind a hypothesis | Tasks 1, 14 |
| Per-signal trust weights measured on healthy days — the first honest ingredient of a confidence number | Task 19 |
| Sub-daily interval series, so a future question can be asked of past data instead of waiting a month for a new field | Task 17 |
| Coverage as a first-class value — the honest input to a confidence number | Tasks 3, 16 |
| Cross-domain derived metrics (`hrPerKStep`, `sleepDebt7`, `hrvCv7`, `restorativeFrac`) | Tasks 8–10 |
| One score the app and Payne can trust on a sick day | Task 11 |
| A subjective symptom channel | Tasks 12–14 |
| **Outcome capture — onset, label, resolution, and false alarms** | Task 15 |
| One causal finding per day instead of three metric-level ones | Task 7 |

Task 15 closes what was the hard blocker: until an episode log exists there is no training signal, so a calibrated confidence number would be a number with nothing behind it. Note the log must record **false** alarms too — a calibration set of confirmed illnesses only will teach the model that every alarm is real.

The second thing that spec must inherit is a constraint, not a capability: **Greg must never claim early warning.** Measured lead time on the reference episode is 0 days, and the earliness/specificity trade is quantified above — 43% alarm days is what pre-onset would cost at this resolution. Whatever confidence language the diagnostician uses, "поймал до симптомов" is not available to it unless Task 17's experiment says otherwise.

---

## Verification Summary

| Phase | Command | Expected |
|---|---|---|
| 1 | `bun test groups/greg/scripts/analyze.test.js` | all green |
| 1 | `pnpm test src/modules/health-trigger/` | all green |
| 1 | `bun /tmp/greg-bt/backtest.js` | first FIRE **on** 2026-08-10 = onset day, silent 08-03…08-09 |
| 1 | `bun /tmp/greg-bt/fp.js` | `pre-onset days 74, fired 8 (11%)` — the ceiling, must not grow |
| 1 (after Task 19) | `bun /tmp/greg-bt/fp.js` | `fired 4 (5%)`, still first firing on 2026-08-10 |
| 1 | `bun /tmp/greg-bt/acute.js` | `restingHeartRate` present, `shape=acute`, `z_today` ≈ 4.38; no `vo2max` |
| 2 | `pnpm test src/modules/health-trigger/sick-day.test.ts` | unchanged day writes nothing; worsened day writes once |
| 3 | `bun test groups/greg/scripts/analyze.test.js` | all green |
| 3 | `bun /tmp/greg-bt/acute.js` | `readiness.score ≤ 45` band `red`, `levels.stress ≥ 60` on 2026-08-12 |
| 4 | `pnpm test src/channels/ios-app/v2/` | migration adds columns to a pre-existing table; partial re-upload preserves omitted ones |
| 4 | `pnpm test` | full host suite green |
| 4 | iOS test scheme + clean build | green |
| 4 | temp coverage over 14 days, two weeks after Task 18 | `temp` = `days`, or the cause recorded as upstream |
| 4 | interval count per day after the backfill | ~16–48 `heartRate` buckets/day; fewer for `hrv`/`spo2` |
| 4 | `bun /tmp/greg-bt/prodrome.js` (after backfill, not after 30 nights) | verdict recorded in the plan, either way |

## Measured Coverage (2026-06-13 … 08-12, 61 days)

Recorded here because an earlier draft got it wrong and built an argument on it.

| metric | present | note |
|---|---|---|
| sleep phases, `sleepOnsetMin` | 61/61 | the watch is worn every night |
| `respiratoryRate` | 61/61 | |
| `hrvMorning`, `spo2Avg` | 61/61 | |
| `wristTempDeviation` | 55/61 (90%) | gaps 06-26, 07-03, 08-04, 08-05, 08-07, 08-12 — one of them the episode peak |
| `bodyMass`, `bodyFatPercentage` | 35/61 | scale, not worn — sparse by nature, not a defect |
| `vo2max` | 7/61 | removed from the detector in Task 3 |

## Deploy Reference

Three deploy paths, never interchangeable:

| What changed | How it ships |
|---|---|
| `src/**` (host TypeScript) | `git push` → on VDS `git pull && pnpm run build && systemctl --user restart nanoclaw` |
| `shared/**` (wire contract) | the above, **plus** `./container/build.sh` — it is baked into the image |
| `groups/greg/**` (script, skills, CLAUDE.md) | `scp` into `agents/greg/`, `chown nanoclaw:nanoclaw`, then continuation wipe + container kill |
| `ios/**` | `xcodegen generate`, bump `CURRENT_PROJECT_VERSION`, build and install |

An instruction or skill change that skips the continuation wipe silently does nothing — the SDK session resumes from its stored transcript and never re-reads `CLAUDE.md`.
