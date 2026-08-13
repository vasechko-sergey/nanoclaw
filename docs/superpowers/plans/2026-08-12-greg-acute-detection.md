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

## Execution Phases — read this before the body

**Task numbers are stable identifiers, not an order.** They were assigned as the work was discovered, and Phase 0's measurements reordered the priorities substantially — three data-integrity bugs surfaced that were not visible when the body was written, and two speculative tasks were cut down or killed. The `# Phase N` headers further down are where each task is *written*, not when it is *done*.

This table is the schedule. Work it top to bottom.

### Phase A — Fix the data before tuning anything on it

Every threshold in this plan is calibrated against a series that has three known defects in it. Tuning a detector on a corrupted series bakes the corruption into the constants, so nothing here is optional and nothing after it should start first.

| # | Task | Why first |
|---|---|---|
| **20** | Wrist temperature on the wake day | 52/58 samples filed a day early. Cost the detector its temperature vote on the worst day of the reference illness |
| **22** | Record `tzOffsetMin`, rebase regularity | Three weeks of `warn`/`critical` came from a relocation the pipeline could not see. Also puts an absolute floor under `sleepRegularity`'s severity |
| **21** | Split naps from the night | One 72-minute nap became a `critical` circadian finding. Stage classification is the marker |

Gate: re-run `fp.js` and `backtest.js` after each. The false-alarm count must not rise, and the first fire must stay on 2026-08-10.

### Phase B — Make the detector see acute onset

| # | Task | Delivers |
|---|---|---|
| **1** | Sick-day rule: 5 signals, morning HRV | Onset-day detection instead of two days late |
| **2** | `z_today` / `shape` beside the window score | A +4.4σ day stops scoring 1.0 and vanishing |
| **3** | Drop `vo2max`, exclude sick days from the baseline | Removes stale noise and stops an illness diluting its own signal |
| **19** | Weight signals by their healthy-day noise | Same detection at 5% false alarms instead of 11%. **Its respiratory-rate change is load-bearing** — without it onset day is a day late |
| **4** | Deploy Phase B and verify live | — |

Note the dependency Phase 0 exposed: after Task 20 corrects the temperature, onset-day detection rests entirely on respiratory rate plus awake minutes, at a margin of 3.18 against 3.01. Task 19 Step 1 is not polish.

### Phase C — Stop saying it five times

**SHIPPED and live 2026-08-12** (`196d1075` + scp). Three deviations from the body below, each recorded at its task:

| # | Task | Delivers |
|---|---|---|
| **5** | Per-day sick-day fire guard | One wake per day unless the picture worsens, instead of five |
| **7** | One causal finding per day | One alarm to the human, not three metric-level ones 14 minutes apart |
| **16** | Report signals that could not be evaluated | "No temperature for a third night" said out loud, not scored around |
| **6** | Delete the stale orphan `analyze.js` | Local hygiene, two minutes |

### Phase D — Start accumulating what calibration needs

**SHIPPED and live 2026-08-12** (scp + seeded log). Two deviations, recorded at the task.

| # | Task | Delivers |
|---|---|---|
| **15** | Episode log — onset, label, resolution, false alarms | **The blocker for everything in Phase 5.** Until it exists, lead time is unmeasurable and no threshold is honestly tunable |

Start this as early as convenient — it costs almost nothing and only accrues value with time. It is placed after Phase C only because the others fix active defects.

The reference episode's lead time is now a computed value rather than a claim in this document: the deployed script emits `episode: {onset: "2026-08-10", lead_time_days: -2}` against live `health.db`.

**Phase A's last open item closed on the same day.** iOS build 1.33.0 (109) was installed and its rows landed: `tzOffsetMin` non-null on all 97 days, 08-10's nap split back out (`napMin: 72`, `sleepOnsetMin` −560 → −42), and `sleepRegularity` fell from 153.2 min of dispersion to **57.3**, dropping from `critical` to `info`. The fictional circadian finding Task 21 was written to kill is gone from real data, not just from tests.

### Phase E — Derived metrics from data already present

**SHIPPED and live 2026-08-13** (scp + rebirth). One deviation, recorded at Task 8.

| # | Task | Delivers |
|---|---|---|
| **8** | `hrPerKStep` | High pulse at zero activity — neither term is anomalous alone |
| **9** | `sleepPhaseShift` | The per-night event, distinct from the dispersion measure |
| **10** | `sleepDebt7`, `restorativeFrac`, `hrvCv7` | Leading indicators that cost nothing to compute |
| **11** | Sick-day verdict reaches `readiness` and `levels` | Stops the app publishing "stress 26" on a day with a fever |

Five metrics entering `METRICS` means five more candidates for the same MAD
detector that once held `sleepRegularity` at `critical` for three weeks, so the
whole phase was gated on a rolling backtest — walk the 98-row series day by day,
run the detector as of that day only, count `warn`+ fires per metric. Measured
over 68 evaluable days (60 with no sick-day verdict):

| Metric | warn+ | on healthy days | Read |
|---|---|---|---|
| `sleepPhaseShift` | 7/68 | 6/60 (10%) | Every fire ≥112 min of bedtime movement, against a p50 of 27. Not noise |
| `hrvCv7` | 7/68 | 7/60 (12%) | **One** contiguous late-June run reported seven days running, not seven events |
| `hrPerKStep` | 2/68 | 1/60 (2%) | Best of the five. On 08-11 it read 30.5 against a 9.7 baseline |
| `restorativeFrac` | 1/68 | 1/60 (2%) | Quiet |
| `sleepDebt7` | 0/68 | 0/60 | Never fires; the rolling sum is too smooth to deviate from its own MAD |

For scale, the incumbents on the same run: `sleepRegularity` 11/68, `awakeMin`
8/68, `fatMassKg` 6/68. Nothing new is noisier than what was already there.

**A floor for `sleepPhaseShift` was drafted and then thrown away, because the
measurement refuted it.** Its fires looked marginal by `recent_median` (20, 40,
46 min — one of them a `warn` while the window median had *fallen*), which is
exactly the pattern that earned `sleepRegularity` its 60-minute floor. Pulling
the day's own value instead showed all seven fires at 112, 126, 130, 140, 157,
176 and 326 minutes. The 3-day median was hiding the event, not revealing it.

`hrvCv7` ships **without** the plan's claim that it leads `hrvMorning`. On the
one labelled episode it never exceeded `info`, and one episode cannot measure a
lead — the same rule this plan applies to every other threshold. Greg's data
dictionary says so explicitly, and says that its seven-day run is one event.

Value side, measured on the reference illness: on 08-11 the two newcomers took 2
of the 8 top-K slots — `sleepPhaseShift` `critical` (bed 2h15m early) and
`hrPerKStep` `warn` (30.5). On 08-09, the day before onset, nothing new fired
above `info`. No pre-onset gain, consistent with the ban at the top of this plan.

### Phase F — New inputs, in value order

**Tasks 12–14 SHIPPED and live 2026-08-13** (`4d26f633`, `c61a646a`, `ff31700b` + scp).
**Task 18 SHIPPED earlier the same day** in `40b9af08`, alongside two other
pipeline defects found while chasing a wrong number on the dashboard card.
Task 17 remains open.

| # | Task | Delivers |
|---|---|---|
| **12–14** | HealthKit symptom types + `bodyTemperature` | The subjective channel. Highest value of what remains — Phase 5 needs it |
| **17** | Interval store, cut down | Keeps the `sleepHr` / `wakeRestHr` split, which fixes the whole-day `heartRate` conflation. Early-warning framing dropped, `hrvDeep` cut |
| **18** | Non-destructive upsert | Hardening. Exonerated as the cause of the temperature gaps, so no longer urgent |

**Four deviations from the body below, each recorded at its task.** The
substantive one is Task 14's: the two subjective signals do NOT join
`SIGNAL_WEIGHTS`. They are additive bonuses on top of the hardware score,
because pool membership would have loosened a threshold chosen from a measured
false-alarm budget — `score_threshold` scales by `availableWeight/TOTAL_WEIGHT`,
and `bodyTemperature` is absent on nearly every day, so as a pool member it
would permanently shrink that ratio. A test in both trees pins it: an empty
`symptoms` array must leave `score_threshold` byte-identical.

That choice also carries the property Task 13 depends on. iOS emits `[]` for a
day whose symptom queries ran and found nothing — a claim it cannot fully
prove, since HealthKit deliberately hides read authorization, so a denied
permission is indistinguishable from an honest zero. As an additive bonus the
uncertainty is harmless: a false `[]` can hide evidence, but can never
manufacture a healthy verdict. Were symptoms ever to subtract, that
degradation would become a silent false negative.

The weights themselves are **assumed, not measured** — neither column existed
before 2026-08-13, so there is no healthy-day rate to invert the way the other
five were derived. `symptom: 1.5` clears the 3.0 bar only alongside a clear
hardware signal; `fever: 3.0` makes a reading at or above 37.5 sufficient on
its own, it being the only direct measurement in a system otherwise built from
proxies. Fever exceedance is taken against a population normal of 36.6 rather
than this person's own median, because nobody reaches for a thermometer on a
day they feel fine — a "baseline" built from their readings is a baseline of
days they already suspected something.

Not yet observable on real data: build 1.34.0 (110) is committed but not
installed, so both columns read `null` on every live row and the detector
behaves exactly as it did yesterday. The host adds the two columns on the next
upload (`openHealthDb` runs per ingest and closes).

**Task 23 was added the same day, because the premise of 12–14 was wrong.**
Сергей's reaction to the shipped work: *«симптомы фиг кто будет заполнять в
приложении»*. He is right, and it invalidates the delivery mechanism without
invalidating the channel — every line of 12–14 stands, it just needed a source
that is not a form.

### Task 23: Greg asks, instead of waiting for a form

**SHIPPED and live 2026-08-13** (scp; `groups/` is not tracked).

HealthKit's symptom types will stay empty forever — nobody opens Health.app to
log a sore throat. But the person answers a question. Greg has had a direct
channel to him since 2026-06-08 (`greg|sergei-iphone`), so the whole loop fits
inside Greg with no relay: he asks in plain text, the answer wakes his session,
he maps it and appends a line.

*Free text, not an options card.* That was Сергей's second correction and it
settles a design question rather than just an ergonomic one: **whoever maps the
words owns the vocabulary.** Greg asks and Greg maps, against a closed
`SYMPTOM_KEYS` list mirroring `HealthManager.symptomTypes`. If Jarvis relayed
canonical keys instead of the raw sentence, `throat` and `soreThroat` would
never accumulate into one signal — the same drift that broke Payne's plan cards
twice. `health-relay` now carries the sentence verbatim in `sick_day_ack.note`.

*Storage.* `health/subjective.jsonl`, merged onto the rows by `analyze.js`
before anything is derived. Not `health.db`: the host is that file's only
writer, and two writers across a bind mount is the one thing this architecture
does not do. Symptoms union across both channels; temperature takes the higher,
matching the day-max semantics. The raw sentence is stored beside the mapped
keys — the mapping is the only LLM step in the pipeline, and when the list has
no word for what he said («ломит спину») the note is the only record that
survives. `log-subjective.js` **rejects** an off-list key rather than dropping
it, so a bad mapping fails loudly at write time instead of evaporating at read.

*When to ask — measured, not chosen.* `sickDayDetect` was split into
`sickDayScore` (always returns) and the verdict, because a day that almost
fired is invisible through a null. Over 84 evaluable days of real history:

| score / threshold | days |
|---|---|
| ≥ 1.0, fired | 11 |
| 0.85–1.0 | 6 |
| 0.7–0.85 | 4 |

Fired days ask for free — a message is already going out. `SUBJECTIVE_ASK_FRAC
= 0.85` therefore costs 6 new interruptions in 84 days, one a fortnight. 0.7
would roughly double that, which is how a question stops being answered at all
and the channel dies the same death as the form. (11/84 is not a false-alarm
rate — different denominator from the 5% budget elsewhere in this plan; it
includes the real August episode.)

*Verified end to end* against a copy of the live `health.db`: on 2026-08-13,
a day where **not one** of the five hardware signals fires, a logged
`soreThroat,chills` + 37.9 produced `score 8.24` against a threshold of 3.0 and
fired the rule. That is precisely the gap the channel exists to close.
`ncl groups lint`: 0 errors. 115 container-side tests.

### Phase G — Diagnostician

Its own spec, gated on Phase D having accumulated episodes. See the section at the end of this document for what it inherits and the one constraint it must respect.

---

# Phase 0 — Pre-verification, before any code

### Task 0: Answer Task 17's question from an Apple Health export

Task 17 is ~400 lines of contract, storage, Swift and script changes written to *find out* whether sub-daily resolution helps. It does not have to be. The Health app exports every raw sample it holds, with timestamps, and that export answers the question on a laptop in an afternoon — no build, no deploy, no waiting.

**Do this before writing any of Phase 4.** It settles three things:

1. **Task 17's premise.** Does any intra-night feature move on 2026-08-08 / 08-09 — the two days before onset where every daily aggregate stayed flat except the noisiest signal? If nothing moves, Task 17 shrinks to "fix the whole-day `heartRate` conflation", which is worth doing on its own merits but is not an early-warning story.
2. **Task 18's cause.** Were the six missing wrist-temperature nights (06-26, 07-03, 08-04, 08-05, 08-07, 08-12) ever in HealthKit? Samples present in the export but null in `health_days` means our own writer destroyed them and the destructive upsert is confirmed. Samples absent from the export means Apple never emitted them, and Task 18 remains a correctness fix rather than the explanation.
3. **Whether the Task 17 design is even buildable as specified.** `hrvDeep` assumes several HRV samples land inside deep sleep each night. If the watch produces two or three HRV samples a night total, that metric is stillborn and should not be written. Same question for SpO₂ and respiratory-rate density, and for whether 30 minutes is the right bucket width.

**What Сергей does** (about two minutes, once): Health app → profile picture, top right → scroll to the bottom → **Export All Health Data** → Export → AirDrop to the Mac. It lands as `export.zip` containing `apple_health_export/export.xml`. The file can be large — hundreds of MB is normal for a couple of years of history — so AirDrop or a cable, not email.

The export is his complete health record. It stays on the Mac and is parsed locally; nothing about this task uploads it anywhere.

**Files:**
- Create: `/tmp/greg-bt/parse_export.py` (throwaway, not committed)

**Interfaces:**
- Produces: `/tmp/greg-bt/samples.jsonl` — one line per sample, `{metric, start, end, value}` — and `/tmp/greg-bt/sleep.jsonl` — `{stage, start, end}`. Both feed the analysis in Step 3 and, if the verdict is positive, the fixture for Task 17's tests.

- [ ] **Step 1: Extract the four metrics plus sleep stages**

`export.xml` runs to millions of records, so stream it rather than loading it.

```python
# /tmp/greg-bt/parse_export.py
import json, sys, xml.etree.ElementTree as ET

SRC = sys.argv[1]                 # .../apple_health_export/export.xml
FROM, TO = "2026-05-01", "2026-08-13"

WANT = {
    "HKQuantityTypeIdentifierHeartRate": "heartRate",
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "hrv",
    "HKQuantityTypeIdentifierRespiratoryRate": "respiratoryRate",
    "HKQuantityTypeIdentifierOxygenSaturation": "spo2",
    "HKQuantityTypeIdentifierAppleSleepingWristTemperature": "wristTemp",
    "HKQuantityTypeIdentifierBodyTemperature": "bodyTemperature",
}
SLEEP = "HKCategoryTypeIdentifierSleepAnalysis"
STAGE = {
    "HKCategoryValueSleepAnalysisAsleepDeep": "deep",
    "HKCategoryValueSleepAnalysisAsleepREM": "rem",
    "HKCategoryValueSleepAnalysisAsleepCore": "core",
    "HKCategoryValueSleepAnalysisAsleepUnspecified": "core",
    "HKCategoryValueSleepAnalysisAwake": "awake",
    "HKCategoryValueSleepAnalysisInBed": "inBed",
}

n_s = n_z = 0
with open("/tmp/greg-bt/samples.jsonl", "w") as fs, open("/tmp/greg-bt/sleep.jsonl", "w") as fz:
    for _, el in ET.iterparse(SRC, events=("end",)):
        if el.tag != "Record":
            continue
        t = el.get("type")
        start = (el.get("startDate") or "")[:19]
        if not (FROM <= start[:10] <= TO):
            el.clear(); continue
        if t in WANT:
            try:
                v = float(el.get("value"))
            except (TypeError, ValueError):
                el.clear(); continue
            fs.write(json.dumps({
                "metric": WANT[t], "start": start, "end": (el.get("endDate") or "")[:19], "value": v,
            }) + "\n")
            n_s += 1
        elif t == SLEEP:
            fz.write(json.dumps({
                "stage": STAGE.get(el.get("value"), "unknown"),
                "start": start, "end": (el.get("endDate") or "")[:19],
            }) + "\n")
            n_z += 1
        el.clear()
print(f"samples {n_s}  sleep intervals {n_z}")
```

Run: `python3 /tmp/greg-bt/parse_export.py ~/Downloads/apple_health_export/export.xml`
Expected: a five- to six-figure sample count. A count near zero means the date filter or the export path is wrong — check that `export.xml` is the large file, not `export_cda.xml`.

- [ ] **Step 2: Check sample density before designing around it**

```python
# /tmp/greg-bt/density.py
import json, collections
per = collections.Counter()
nights = collections.defaultdict(lambda: collections.Counter())
for line in open("/tmp/greg-bt/samples.jsonl"):
    r = json.loads(line)
    per[r["metric"]] += 1
    hh = int(r["start"][11:13])
    if hh < 9:                      # crude night window, enough for a density check
        nights[r["start"][:10]][r["metric"]] += 1
print("total samples per metric:", dict(per))
days = sorted(nights)[-14:]
print("\nnight-window samples per day (last 14):")
print("date        " + "".join(m[:9].ljust(11) for m in ["heartRate","hrv","respiratoryRate","spo2"]))
for d in days:
    print(d + "  " + "".join(str(nights[d][m]).ljust(11) for m in ["heartRate","hrv","respiratoryRate","spo2"]))
```

Run: `python3 /tmp/greg-bt/density.py`

Read the result against Task 17's assumptions:
- `heartRate` should be roughly 60–120 samples a night (Apple samples every few minutes at rest). Under ~20 and 30-minute buckets are too fine — widen to 60.
- `hrv` in the low single digits per night kills `hrvDeep`. Cut that metric from Task 17 rather than building something that will be null on most nights.
- `spo2` and `respiratoryRate` are typically sparse and may only support one figure a night, which is what we already store.

- [ ] **Step 3: Run the actual experiment**

```python
# /tmp/greg-bt/prodrome_export.py — the question Task 17 was written to answer
import json, collections, statistics as st
from datetime import datetime, timedelta

def parse(s): return datetime.fromisoformat(s)

sleep = [json.loads(l) for l in open("/tmp/greg-bt/sleep.jsonl")]
asleep = [z for z in sleep if z["stage"] in ("deep", "rem", "core")]
hr = [json.loads(l) for l in open("/tmp/greg-bt/samples.jsonl") if json.loads(l)["metric"] == "heartRate"]

# Attribute each sleep interval to its WAKE day, matching how hrvMorning is bucketed.
def wake_day(dt): return (dt - timedelta(hours=9)).date().isoformat() if dt.hour < 9 else (dt.date() + timedelta(days=1)).isoformat()

by_night = collections.defaultdict(list)
for z in asleep:
    by_night[wake_day(parse(z["start"]))].append((parse(z["start"]), parse(z["end"]), z["stage"]))

rows = {}
for night, intervals in by_night.items():
    if not intervals: continue
    lo, hi = min(i[0] for i in intervals), max(i[1] for i in intervals)
    vals = [(parse(s["start"]), s["value"]) for s in hr if lo <= parse(s["start"]) <= hi]
    if len(vals) < 20: continue
    vals.sort()
    mean = st.mean(v for _, v in vals)
    nadir_t, nadir_v = min(vals, key=lambda x: x[1])
    span = (hi - lo).total_seconds()
    rows[night] = {
        "n": len(vals),
        "sleepHr": round(mean, 1),
        "nightHrMin": round(nadir_v, 1),
        "nadirFrac": round((nadir_t - lo).total_seconds() / span, 2) if span else None,
        "dipPct": round((mean - nadir_v) / mean * 100, 1) if mean else None,
    }

ONSET = "2026-08-10"
print("night        n   sleepHr  nightHrMin  nadirFrac  dipPct")
for d in sorted(rows)[-20:]:
    r = rows[d]
    mark = "  <-- ONSET" if d == ONSET else ("  <-- pre-onset" if d in ("2026-08-08", "2026-08-09") else "")
    print(f"{d}  {r['n']:>3}  {r['sleepHr']:>7}  {r['nightHrMin']:>10}  {str(r['nadirFrac']):>9}  {str(r['dipPct']):>6}{mark}")

# Baseline is every night before the pre-onset window, so the episode cannot
# inflate the baseline it is being scored against.
base = [rows[d] for d in sorted(rows) if d < "2026-08-08"]
print("\nbaseline (nights before 08-08):")
for k in ("sleepHr", "nightHrMin", "nadirFrac", "dipPct"):
    vs = [r[k] for r in base if r[k] is not None]
    if len(vs) < 5: continue
    med, sd = st.median(vs), st.pstdev(vs) or 1
    print(f"  {k:<12} median {med:>7.2f}  sd {sd:>5.2f}   " + "  ".join(
        f"{d[5:]}:{(rows[d][k]-med)/sd:+.1f}σ" for d in ("2026-08-08","2026-08-09","2026-08-10") if d in rows and rows[d][k] is not None))
```

Run: `python3 /tmp/greg-bt/prodrome_export.py`

The last block is the verdict: the sigma deviation of each intra-night feature on 08-08 and 08-09 against a baseline that excludes the episode. Remember what the daily aggregates did on those two days — everything flat except morning HRV, which is noise 27% of the time.

- [ ] **Step 4: Settle the wrist-temperature question while the data is open**

```bash
grep -o 'AppleSleepingWristTemperature[^/]*startDate="2026-08-0[4578][^"]*"[^/]*value="[^"]*"' \
  ~/Downloads/apple_health_export/export.xml | head
grep -c 'AppleSleepingWristTemperature' ~/Downloads/apple_health_export/export.xml
```

Compare against the six nights `health_days` has as null: 06-26, 07-03, 08-04, 08-05, 08-07, 08-12.

- Samples present in the export for those dates → **our writer lost them.** Task 18's destructive upsert is the confirmed cause; promote it to the front of Phase 4 and re-run the backfill afterwards to recover the values.
- Samples absent → Apple never produced them. Task 18 stays a correctness fix, and the six gaps are upstream and permanent.

- [ ] **Step 5: Write the verdicts into the plan and re-scope what follows**

Add an `## Pre-verification result` section under this task recording, with numbers:

- whether any intra-night feature separates 08-08/08-09 from baseline, and by how many sigma;
- per-metric night-time sample density, and what it means for bucket width and for `hrvDeep`;
- whether the wrist-temperature gaps are ours or Apple's.

Then re-scope. If nothing moves pre-onset, cut Task 17 down to the interval store plus the `heartRate` split, drop the experiment framing, and delete the backfill steps — the intervals are still worth having, just not as an early-warning bet. If something does move, Task 17 proceeds as written and the export doubles as the test fixture: a real night of samples beats the synthetic arrays in its unit tests.

Whatever the outcome, this task costs one afternoon and no deployed code. Task 17 costs a contract change, an image rebuild, an iOS release and a backfill. Doing them in that order is the whole point.

## Pre-verification result — run 2026-08-12

**Export was truncated.** `~/Downloads/export.zip`, 94,105,600 bytes — exactly 1436 × 64 KiB, and missing its end-of-central-directory record. Salvaged by inflating the raw deflate stream directly (`zlib.decompressobj(-15)`, ignoring the missing trailer), which recovered **3.04 GB of `export.xml`** before the stream ran out.

What survived, for 2026-05-01…08-13: `heartRate` 103,758 samples, `respiratoryRate` 4,786, `spo2` 1,128, `steps` 12,221. What did **not** survive the cut: `HeartRateVariabilitySDNN`, `AppleSleepingWristTemperature`, `RestingHeartRate`, `BodyTemperature`, and every `SleepAnalysis` interval — zero records of each. So questions 2 and 3 below are only partly answered and would need a complete re-export.

**Sample density — question 3, answered.** Heart rate lands ~120 samples per night in a 00:00–09:00 window, on every one of the last 16 nights and 102 nights overall. That is one sample every ~4.5 minutes: **30-minute buckets are the right width**, giving ~7 samples each. No need to widen to 60. `hrvDeep` remains unverified — no HRV samples in the recovered portion — but `hrvMorning` is non-null on 61/61 days in `health_days`, so the samples do exist and were simply past the truncation point.

**The pre-onset question — answered, negative.** Nocturnal heart-rate trajectory computed per night over 100 nights, two windows, baseline = nights 05-15…08-07 (MAD-based z):

Fixed 01:00–06:00 window, 81 baseline nights — assumption-free, does not depend on Apple's sleep attribution:

| feature | baseline | 08-08 | 08-09 | **08-10 onset** |
|---|---|---|---|---|
| mean HR | 58.0 | +0.3σ | −0.2σ | −0.7σ |
| min HR | 49.0 | +0.9σ | +0.2σ | −0.2σ |
| nadir position | 0.54 | +0.9σ | +1.1σ | −0.7σ |
| dip depth % | 15.4 | −0.8σ | −0.6σ | −0.9σ |
| slope | 0.00 | −0.5σ | −0.6σ | +0.1σ |

Nothing reaches 1.2σ anywhere — not on the two pre-onset days, and **not on onset day either**. The reconstructed-sleep-window variant does show movement on onset day (nadir position −2.2σ, slope +1.8σ, mean +1.5σ), but it cannot be trusted here: `sleepOnsetMin` for 08-10 is **−560**, meaning that "night" is an eight-hour block starting 14:40 the previous afternoon. The window being measured is not a night. And 08-08 scores +1.8σ on dip depth in that same variant — the same magnitude as the onset-day signals, which is what noise looks like at n=1.

**Verdict: intra-night heart-rate trajectory does not detect before onset, and in the trustworthy window does not clearly detect at onset either.** Task 17's early-warning premise does not survive contact with the data. Re-scoped accordingly — see the note at the head of that task.

**A defect found on the way.** `sleepOnsetMin = −560` with `sleepHours = 8.0` for 2026-08-10: our pipeline accepted an afternoon sleep block as that night's sleep, and `sleepRegularity` then produced mod_z 19.53 and a `critical` finding out of it. Either Apple merged a long nap with the night, or he genuinely went to bed at 14:40 on 08-09 — which would itself be a symptom worth naming rather than laundering into a regularity statistic. Neither reading is served by silently treating it as one night. Not yet a task; needs the `SleepAnalysis` intervals from a complete export to tell the two apart.

**Still open at that point:** intra-night HRV, and the wrist-temperature gaps. Both were closed by the second pass below.

## Pre-verification, second pass — targeted dump, 2026-08-12

Rather than re-attempt the multi-gigabyte Health export, the app grew a diagnostic that dumps only the sparse metrics over a chosen window (`HealthSampleDump`, Settings → Диагностика). Result: **759 KB** of JSONL covering 2026-06-13…08-12 — HRV SDNN 619, sleep intervals 1,734, respiratory rate 2,791, SpO₂ 677, resting HR 61, sleeping wrist temperature 58. Everything the truncated export had lost.

### Finding A — wrist temperature is filed one day early. Confirmed.

Attribution test over all 58 samples: **52/58 match the day sleep BEGAN, 2/58 match the wake day.** Every other overnight metric (`hrvMorning`, `spo2Avg/Min`, sleep phases) is filed on the **wake** day via `bucketOvernight`. Wrist temperature goes through `collection(.appleSleepingWristTemperature, …)` and is keyed on the statistics-interval start instead, so it sits one row above where it belongs.

This is worse than the gaps it explains:

| night measured | value | filed as | belongs to |
|---|---|---|---|
| 08-09 23:14 → 08-10 07:32 | 35.07 | 08-09 | 08-10 |
| 08-10 23:20 → 08-11 06:56 | **36.19** | 08-10 | **08-11** |
| 08-11 23:20 → 08-12 07:20 | **35.98** | 08-11 | **08-12** |

The fever peak was reported a day before it happened, and 08-12 — the worst day of the episode, the day the sick-day rule ran — was left null and scored `temp: false`. The value existed: +0.76 °C over baseline, comfortably past the 0.4 threshold.

The correction needs no timezone: `sleepOnsetMin` is already filed on the wake day, so `onset < 0` (bed before midnight) means the temperature landed on `wake_day − 1`, and `onset >= 0` means it landed correctly. Re-keying on that basis moves 44 values and lifts coverage from 55/61 to **58/61**.

**Task 18 is exonerated as the cause.** The six gaps were never destroyed data — they are days on which no sleep *started*. The `COALESCE` fix stays correct on its own merits, but it explains nothing here and its priority drops.

### Finding B — same-day detection survives the correction, narrowly, on different evidence

Re-run of the backtest against the corrected series:

| date | 2-of-5 votes | weighted / threshold |
|---|---|---|
| 08-08 | 1/5 hrv | 1.84 / 3.01 |
| 08-09 | 1/5 hrv | 0.88 / 3.01 |
| **08-10 onset** | **FIRE 2/5** rr, awake | **3.18 / 3.01** |
| 08-11 | FIRE 4/5 hrv, temp, rr, awake | 8.87 / 3.01 |
| 08-12 | **FIRE 5/5** all five | 9.93 / 3.01 |

False alarms unchanged: 8/74 for votes, 5/74 weighted.

Two things worth recording. Onset-day detection no longer rests on temperature at all — it rests on respiratory rate and awake minutes, and the margin is thin (3.18 against 3.01). And the "free" respiratory-rate tightening in Task 19 Step 1 turns out to be **load-bearing**: at the old +1.0 br/min threshold, 08-10 scores 0.95, drops to 1/5, and the whole thing becomes one-day-late. It is no longer an optional polish item.

On the day it mattered most, 08-12 goes from the 2-of-3 the live system actually reported to a full 5-of-5.

### Finding C — intra-night HRV is a dead end, and `hrvDeep` is stillborn

**3 to 5 HRV samples per night.** Not per hour — per night. Deep-sleep-restricted HRV gets 0–2 samples on a typical night, so `hrvDeep` would be null or meaningless almost always. **Cut it from Task 17.**

The trajectory question, against 51 baseline nights:

| feature | baseline | 08-08 | 08-09 | 08-10 onset |
|---|---|---|---|---|
| night mean | 61.5 | −1.6σ | −1.0σ | **+1.4σ** |
| night min | 35.5 | −0.4σ | −0.3σ | +1.0σ |
| first half | 44.5 | −1.0σ | −0.3σ | **+3.0σ** |
| second half | 71.4 | −1.1σ | −0.7σ | +0.4σ |

Nothing distinguishes the pre-onset days, and on onset day HRV is *high*, not low. Combined with the heart-rate trajectory result from the first pass, sub-daily resolution does not deliver pre-onset warning here by any route tested.

### Finding E — `sleepRegularity`'s two-month run of criticals is mostly artifact

Сергей: "на Бали я как раз таки очень регулярно ложился в десять". Correct, and the data pins the relocation to **2026-07-01** — stored `sleepOnsetMin` matches UTC-derived night starts to 0 minutes under one candidate offset and to exactly 150 minutes under the other, every day, flipping cleanly on that date.

| period | offset | nights | bedtime | MAD |
|---|---|---|---|---|
| …–06-30 | +8:00 Bali | 15 | 22:43 | ±21 min |
| 07-01–… | +5:30 Sri Lanka | 43 | 23:46 | ±33 min |

Regular in both. The +63-minute step between them is a move, and nothing in the pipeline records the timezone, so a rolling window straddling 07-01 cannot read it as anything but a disintegrating routine.

**Corrected after implementing it (Task 22).** The relocation is a smaller contributor than this section first claimed. Centring each offset regime on its own median takes the July peak from 97 to **87** minutes — the move accounts for roughly ten of it, not most. July's irregularity was largely genuine: bedtimes really did range 21:34 to 03:37.

The dominant defect is the one next to it — **the severity ladder had no absolute floor.** Measured across the 61 days, 24 change severity once both fixes are in: **17 by the floor, 8 by the timezone softening**. The starkest is 22–28 July, which stood at `critical` on a spread of **36.7 minutes** — bed between 23:15 and 00:30 — for a week running. Scoring mod_z against a ~20-minute personal baseline is right in principle and useless in practice: any ordinary week doubles it.

A trap worth recording: Apple's export rewrites every timestamp in the device's *current* timezone, so the raw file shows a uniform `+0530` across a window that actually spans two offsets. The offset has to be captured on-device at the time, or it is gone. Task 22.

### Finding D — a 72-minute nap became a `critical` finding

The 2026-08-10 `sleepOnsetMin = −560` mystery, resolved from the real intervals. Three separate sleep blocks, all from the watch:

```
08-09 00:05 .. 08-09 06:58   night        15 intervals
08-09 14:39 .. 08-09 15:52   nap          2 intervals
08-09 23:17 .. 08-10 07:32   night        20 intervals
```

`sleepSamplesByWakeDay` groups everything on a wake day and takes `min(start)` / `max(end)`, so the afternoon nap and the following night merged into one eight-hour "sleep" beginning at 14:39. `sleepOnsetMin` took its value from the nap, `sleepRegularity` produced mod_z **19.53** out of it, and Greg sent Jarvis a `critical` finding about a circadian collapse that never happened.

The nap is plausibly the real signal — an unusual daytime sleep on the day before he reports the illness starting. The pipeline laundered it into a spurious alarm instead of naming it. New task below.

---

# Phase 1 — Acute-onset detection

> Scheduled as **Phase B**, after the data-integrity fixes in Phase A (Tasks 20, 22, 21). See Execution Phases at the top.

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
Expected: silent through `2026-08-10`; `2026-08-11 FIRE 4/5 hrv,temp,rr,awake`; `2026-08-12 FIRE 4/5 hrv,temp,rr,awake`.

**Corrected 2026-08-12 after Phase A ran** — this step originally expected `2026-08-10 FIRE 2/5 temp,awake`, measured before Task 20 re-keyed the temperature. On 08-10 the wrist temperature is −0.14 °C against baseline, not +1.00: the +1.00 belongs to 08-11 and Task 20 moved it there. The other four signals reproduce Task 19's table to two decimals (rhr 0.23, hrv −2.22, rr 0.95, awake 1.65 in threshold units), so only the temperature row moved.

The consequence is exactly what Task 19 Step 1 predicts: at `rrAbs: 1.0` the onset day scores 1/5 and this task alone leaves the detector one day late. **Task 1 does not deliver onset-day detection on its own — Task 19 Step 1 does.** Do not chase 08-10 by loosening a threshold here; the fire on 08-11 at this point in the phase is correct, and the 11% ceiling in Step 5b is the thing to hold.

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

Expected: at least one finding with `shape` of `acute` whose `|mod_z|` is below the sustained gate's 2.0 — that combination is only reachable through the new path.

**Corrected 2026-08-12 during execution** — this step originally expected `restingHeartRate` at `z_today ≈ 4.38`. That was measured while 08-12 was still in progress and its resting heart rate read 74; the finished day reads 65, giving `z_today` 1.35, and the metric correctly drops out. The observed acute-only finding is `fatMassKg` at `mod_z −1.01, z_today −3.04` — invisible to the window gate, which needs `|mod_z| ≥ 2`, and surfaced by the acute gate alone. Do not pin this verification to one metric: which day is anomalous changes as data arrives.

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

> Scheduled as **Phase C**, together with Task 16. See Execution Phases at the top.

Phase 1 makes Greg see more. Phase 2 stops him from saying it five times.

### Task 5: Per-day sick-day fire guard

On 2026-08-12 the host wrote five identical `sick_day_check` messages (03:16, 05:01 ×2, 05:02, 05:13) — one per health upload, with no memory of having already fired. Greg correctly deduplicated them, at the cost of four extra container wakes and four full LLM turns. The suppress rule lives in the agent's `state.md`; the host has never heard of it.

> **Measured at implementation time, 2026-08-12.** Counting the rows rather than the log lines: **seven** on 2026-08-12 (two more at 06:06 and 12:14), nine across 2026-07-03..04, and **about 230 on 2026-06-17 alone** — 244 `host-sick-day` rows in one session since June. The five-message figure above was an undercount taken from a partial log window; the defect is an order of magnitude larger than it reads.
>
> **Deviation, implemented:** the guard also re-fires when `score` climbs by ≥ 1.0 (one median-weight signal's worth of evidence). Task 19 made the weighted score the fire decision, so a fever going +0.4 °C → +2.0 °C worsens the picture without moving `matched` or adding a signal — the guard as written below would have swallowed exactly the deterioration its own comment promises to let through. Two tests pin both directions (`re-fires when the same signals worsen enough to move the score`, `stays quiet when the score only drifts as the day fills in`). Rows written before Phase B carry no `score`; the guard falls back to `matched`/`fires` for those.

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

> **Deviation, implemented 2026-08-12.** `sick-day/SKILL.md` still described the superseded 2-of-3 vote in its frontmatter `description`, its opening line, its suppress rule, its `house_quote` example and its payload example — Phase B changed the detector and left the skill behind, so Greg would have narrated a weighted five-signal score as "два из трёх индикаторов". Corrected in the same pass: five signals named, `score`/`score_threshold`/`unavailable` in the payload example, the agent-side suppress rule aligned with the host guard, and an instruction to name the signals in words rather than as "N из 5" (the count is not the threshold and means nothing to a human).

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

> Scheduled as **Phase E**. Nothing here fixes a defect, so it waits for the detector and the episode log. See Execution Phases at the top.

Derived metrics only. No new source, no contract change, no iOS work.

### Task 8: Heart-rate-over-steps efficiency

Illness shows as a high pulse doing nothing. Today's row: heart rate 64 at 1847 steps, against a normal 78 at ~8000. Neither number is anomalous alone; the ratio is. This is the HROS-AD feature (median 4 days to symptom onset in the published evaluation).

> **Shipped 2026-08-13 with one deviation: the step floor is 2000, not 500.**
> The 500 was written as a rounding guard, and as a rounding guard it is fine.
> What it does not guard against is the day that has not finished yet. The live
> run at 08:33 local on 2026-08-13 read 1149 steps against a full-day average
> pulse of 63 and scored `hrPerKStep` **54.8** against a baseline of 9.8 —
> `critical`, first line of the anomaly list, and it would have been there every
> morning for as long as the metric existed. The rolling backtest could not see
> this because it replays completed days only.
>
> The floor is measured, not guessed: across 97 completed days the minimum is
> **2164** steps, and that minimum *is* the reference illness's worst day, the
> one carrying the 30.5 this metric was added to catch. 2000 sits between the
> two with both margins known. The cost is stated in the code: a genuinely
> bedridden sub-2000-step day gets no ratio, and the temperature / resting-pulse
> / respiratory signals carry it instead.
>
> Note for whoever reads the morning output: `activeEnergy` and `exerciseMinutes`
> have the same partial-day artifact and predate this phase. They were left alone
> — fixing them changes the incumbent detector's behaviour and is not Phase E.

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

> **Shipped 2026-08-13, no deviations.** Re-measured on 08-12 after Phases A–B
> corrected the series, the pre-change numbers are **65 yellow / stress 17**, not
> the 60/26 above — same defect, slightly different arithmetic. With the cap:
> `{"score":45,"band":"red","sick_capped":true}` and `stress: 60`. On 08-13, with
> no sick verdict, both paths return identical values, so the healthy path is
> untouched. The call site now scores the verdict **once** and threads the same
> object into the episode lookup, `computeReadiness` and `computeLevels` — Task 15
> had left a second `sickDayDetect(rows)` inside the `episode` expression.

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

> **Split by the Phase 0 findings.** Tasks 20, 22 and 21 in this section are data-integrity fixes and run FIRST, as Phase A. Tasks 15 and 16 are pulled forward into Phases D and C. What remains here — Tasks 12–14, 17, 18 — is scheduled as Phase F. See Execution Phases at the top.

Everything above squeezes the existing data. This phase widens it. The single highest-value addition is HealthKit's symptom category types: they are the subjective channel the diagnostician phase needs, and iOS already has permission infrastructure for them.

### Task 12: Wire contract and storage for symptoms and body temperature

**SHIPPED 2026-08-13 — `4d26f633`. Two deviations.**

*The empty array is storable.* The body below serializes `symptoms` with
`d.symptoms?.length ? JSON.stringify(...) : null`, collapsing `[]` into `null`.
Under the COALESCE upsert that shipped in `40b9af08`, `null` means "this upload
is silent, keep what is stored" — so the collapse would make a symptom list
unclearable: delete a mis-logged fever in Health.app and the stored one
outlives it forever. Array columns now serialize `[]` as `'[]'`, a real value
that wins the COALESCE. `JSON_COLS` was introduced alongside so the schema, the
ALTER probe and the read path cannot drift apart the way `workouts` and the
`SCALARS` block once could.

*No image rebuild.* Step 6 says a `shared/` change needs one. Nothing in
`container/agent-runner/src/` references `HealthUploadDay` — Greg reads
`health.db` through `bun:sqlite` and bypasses the contract entirely — so the
rebuild would have changed no behaviour. `request_context.ts` does import the
module, but for `ContextFieldEnum`, which this task did not touch.

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

**SHIPPED 2026-08-13 — `c61a646a`, build 1.34.0 (110). Two deviations.**

*`bodyTemperature` is the day's max, not its average.* The body specifies
`.discreteAverage`. A fever's peak is the signal, and averaging 38.5 against a
normal morning reading produces a number that describes neither. The contract
comment in both `v2.ts` and `V2.swift` now states the semantic, because a
consumer that assumes "mean" would read the same field wrongly.

*Days with no symptoms are emitted as `[]`, not left `nil`.* The body is
presence-only, which leaves the deleted-symptom case unfixable — see Task 12's
first deviation. The backfill runs in `group.notify`, after every symptom query
has completed, and only fills days the queries did not touch. Its honest limit
is recorded in the source: read authorization is unknowable in HealthKit, so a
denied permission also produces `[]`. Safe only because Task 14 makes symptoms
purely additive.

One compile note worth keeping: `[...].union(...)` on the type-annotated set
literal makes it infer `[HKSampleType]` and drops the `Set<HKObjectType>`
annotation. Build the set, then `formUnion` in a separate statement.

456 iOS tests pass, 6 of them new.

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

**SHIPPED and live 2026-08-13 — `ff31700b` + scp. One substantive deviation,
written up in the Phase F header above: the subjective signals are additive
bonuses, not members of `SIGNAL_WEIGHTS`.**

The body's tests were written before Task 19 replaced the vote count with a
weighted score, so their `matched` arithmetic no longer describes the fire
decision. The shipped tests assert the property instead of the count: a symptom
alone does not fire (1.5 against a 3.0 bar), a symptom plus one hardware signal
fires where that signal alone does not, a measured fever fires alone with the
wrist sensor silent, and an empty `symptoms` array leaves both `score` and
`score_threshold` unchanged.

Two things the body did not call for and the shipped code has. `latest` carries
`symptoms` and `bodyTemperature` even on a day the rule does not fire — a
logged symptom is worth mentioning on its own, and it is the only field in the
whole set the person said rather than a sensor measured. And the `sick-day`
skill now states that `fires.fever` and `fires.temp` are different claims
(thermometer vs. passive wrist sensor) that must not be merged into one
sentence about temperature being up.

95 container-side tests, 988 host.

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

> **Shipped 2026-08-12 with two deviations from the steps below.**
>
> 1. **`onset: sick.date` in Step 3 is wrong** — that labels the detection date as the day symptoms started, which is the exact confusion this log exists to end. On the reference episode it would have written `onset: 2026-08-12` next to `lead_time_days: -2`, a self-contradicting record. Fixed by making `nearestEpisode(detectionDate, episodes)` the primitive: it returns `{onset, lead_time_days}` carried out of the lookup, and `leadTimeDays` is a thin wrapper over it so the two can never disagree. The plan's six tests are unchanged and pass; two more pin the onset and the nearest-of-several choice.
> 2. **Normal mode never computed `sick`.** Step 3 says "after computing `sick`", but the normal-mode entry point only called `sickDates(rows)` (which keeps dates, not the detection) — `sick` did not exist. Added the `sickDayDetect(rows)` call inside the `episode` field.
>
> One skill-level addition beyond Step 5: `lead_time_days` is an honest lead-time claim **only on an episode's first fire**. If the rule fires again on day three, `-3` means "the illness is three days old", not "we were three days late". Without that sentence Greg would report a fresh apology every morning of an illness.
>
> Verified live: 64 bun tests in the real agent image, and `--mode normal` against live `health.db` emits `episode: {onset: "2026-08-10", lead_time_days: -2}`.

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

> **Partly delivered early.** Task 19's weighted score needed the same "which signals can we even see tonight" split, so `unavailable` shipped in Phase B on both sides (`ccad4314`/`45e98927`) along with its threshold-normalisation test. What was left for Phase C, and is now done: the `computeCoverage` tracked list, the CLAUDE.md instruction to *say it out loud*, and the empty-list test. `computeCoverage` was also exported so the tracked list is pinned by tests in both directions rather than asserted by eye. Measured after deploy: wrist temperature present on 12 of the last 14 days (86%), so `sparse_metrics` is correctly empty — the 6-of-61 gaps are older than the window.

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

> **RE-SCOPED by Task 0's result, 2026-08-12.** The pre-check ran on a real Health export and the early-warning premise did not survive: over 100 nights, no intra-night heart-rate feature moves more than 1.2σ on either pre-onset day, or on onset day itself, in an assumption-free 01:00–06:00 window. So:
>
> - **Keep** the interval store, the 30-minute bucketing (confirmed as the right width — ~120 heart-rate samples a night, ~7 per bucket), and the `sleepHr` / `wakeRestHr` split. That split fixes a defect that is wrong on its own merits: whole-day `heartRate` read 64 on 2026-08-12 and was flagged as cardio adaptation while the person was in bed.
> - **Drop** the experiment framing, Step 9's `prodrome.js`, and Step 10's verdict section — the verdict is already in, recorded under Task 0.
> - **Keep the backfill**, but as history for the new metrics rather than as an experiment. Lower priority; the store earns its place going forward either way.
> - **`hrvDeep` is cut.** The targeted dump settled it: 3–5 HRV samples per *night*, 0–2 of them inside deep sleep. The metric would be null or meaningless almost always. Do not build it.
> - **Priority drops** below Tasks 15, 16, 20 and 21, which all deliver something certain.

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

**SHIPPED 2026-08-13 — `40b9af08`**, ahead of the rest of Phase F, because the
owner spotted a wrong number on the dashboard card and three separate pipeline
defects fell out of chasing it. The `COALESCE` change landed as written, with
`ingested_at` exempted so the write stamp still advances. It remained a latent
hazard to the end: no incident was ever traced to it. Task 12 later leaned on
its semantics — `null` means "this upload is silent" — which is why array
columns must serialize `[]` as a real value rather than collapsing it.

> **Exonerated as the cause of the temperature gaps, priority lowered.** Task 0 Finding A showed those six nights were never destroyed — they are days on which no sleep started, an artifact of the attribution bug Task 20 fixes. The `COALESCE` change below is still correct: the destructive overwrite is real and a partial re-upload can still erase a genuine value. It is now a hardening item, not an explanation. Read the evidence table below as motivation, not as diagnosis.

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
| **weighted, T=3.0** | **5/74 — 7%** | **yes, 08-10** |
| weighted, T=3.5 | 3/74 — 4% | no — 08-11, a day late |
| weighted, T=4.0 | 1/74 — 1% | no |
| weighted, T=5.0 | 0/74 — 0% | no |

**Re-measured 2026-08-12 after Phase A ran; the original table is struck.** It claimed 0% false alarms at T=4.5 *with* onset-day detection. That came entirely from the mis-filed wrist temperature: 08-10 was holding 36.19 °C, which belongs to 08-11 and which Task 20 moved there. With the temperature corrected, the onset day scores **3.16** — carried by respiratory rate (1.46) and awake minutes (1.29), with resting heart rate adding 0.41 and both temperature and HRV contributing nothing. There is no threshold on this data that buys both zero false alarms and same-day detection; the honest gain is **11% → 7% at the same detection day**.

T stays at **3.0**, chosen the way the rule below requires — from the budget, accepting that it is at the loose end of it. Raising it to meet 5% exactly would trade away the entire deliverable of Phase B.

Worth knowing before treating the remainder as noise: four of the five fire on **2026-07-03, 07-08, 07-11, 07-12, 07-13** — clustered on the Bali → Sri Lanka relocation (physical move 5 July). A travel week genuinely moves these signals, so the measured rate is an upper bound on how often the rule cries wolf during an ordinary week at home.

Note what is and is not supported by sample size: the weights and the false-alarm rates come from 74 healthy days and are reasonably solid; "fires on onset" rests on **one** episode. So set the threshold from a false-alarm budget, never by tuning until it hits 08-10 — that way round is overfitting to n=1.

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

- [ ] **Step 1: Take the respiratory-rate fix first — it is load-bearing, not free polish**

Respiratory rate scored 0.95 against a 1.0 threshold on onset day — it missed by five percent. Once Task 20 corrects the temperature attribution, onset-day detection rests entirely on respiratory rate plus awake minutes: at +1.0 the day scores 1/5 and the detector is a day late, at +0.9 it scores 2/5 and fires on the day symptoms started. Measured across the pre-onset days, the tightening costs nothing:

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
Expected: `pre-onset days 74, fired 5 (7%)` — down from 8 (11%). (Corrected from 4/5% — see the struck table above.)

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

### Task 20: File wrist temperature on the wake day, like every other overnight metric

> **Highest priority in Phase 4.** Found by Task 0 Finding A. This is not a refinement — it is a signal arriving on the wrong day, and it silently cost the detector its temperature vote on the worst day of a real illness.

`HealthHistory.swift:242` reads `.appleSleepingWristTemperature` through `collection(…)` and keys the result on `bucketKey(s.startDate)` — the calendar day the sleep interval began. `hrvMorning`, `spo2Avg/Min` and the sleep phases all go through `bucketOvernight`, which keys on the **wake** day. Temperature is the only overnight metric filed a day early, and 52 of 58 samples confirm it.

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift:239-252`
- Modify: `groups/greg/CLAUDE.md`
- Create: `ios/JarvisApp/Sources/JarvisAppTests/WristTempAttributionTests.swift`

**Interfaces:**
- Consumes: `HealthHistory.sleepWakeDay` / `bucketOvernight`, already used by three other readers.
- Produces: `wristTempDeviation` keyed on the wake day. No contract change — the field and its type are unchanged, only which row it lands in.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Jarvis

final class WristTempAttributionTests: XCTestCase {
    /// A sleep interval beginning 23:20 on the 11th and ending 07:20 on the 12th
    /// describes the night of the 12th, and must be filed there — that is where
    /// hrvMorning, spo2 and the sleep phases for the same night already go.
    func testOvernightIntervalIsFiledOnTheWakeDay() {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 23, minute: 20))!
        XCTAssertEqual(
            HealthHistory.sleepWakeDay(start: start, calendar: cal),
            cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: start)!)
        )
    }

    /// Bed after midnight: start day and wake day are already the same, so the
    /// correction must be a no-op rather than pushing it a further day out.
    func testAfterMidnightIntervalStaysOnItsOwnDay() {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 1, minute: 20))!
        XCTAssertEqual(
            HealthHistory.sleepWakeDay(start: start, calendar: cal),
            cal.startOfDay(for: start)
        )
    }
}
```

Run the test scheme.
Expected: check `sleepWakeDay`'s existing cutoff first (`HealthHistory.swift:419`) — if it already implements exactly this, these pass immediately and the bug is purely that the temperature reader does not call it.

- [ ] **Step 2: Route the temperature reader through the same bucketing**

Replace the `bucketKey(s.startDate)` line in the `.appleSleepingWristTemperature` block:

```swift
        // Wake-day attribution, matching hrvMorning / spo2 / sleep phases. Keying
        // on the interval's start files a 23:20 -> 07:20 night under the previous
        // date: measured 52 of 58 samples landing one day early, which cost the
        // sick-day rule its temperature vote on 2026-08-12 (the value was 35.98,
        // +0.76 C over baseline, and the row was null).
        let k = bucketKey(HealthHistory.sleepWakeDay(start: s.startDate, calendar: cal))
```

- [ ] **Step 3: Run the tests and a clean build**

Expected: PASS. Bump `CURRENT_PROJECT_VERSION`, `xcodegen generate`.

- [ ] **Step 4: Repair the stored history**

The fix only corrects new uploads. Re-key the 61 existing rows using `sleepOnsetMin`, which is already filed on the wake day — no timezone needed:

```javascript
// onset < 0 means bed before midnight, so that night's temperature was filed on
// wake_day - 1. onset >= 0 means bed after midnight and the row is already right.
const prev = (d) => new Date(Date.parse(d + 'T00:00:00Z') - 86400000).toISOString().slice(0, 10);
const rows = db.prepare('SELECT date, sleepOnsetMin, wristTempDeviation FROM health_days ORDER BY date').all();
const by = new Map(rows.map((r) => [r.date, r]));
const fixed = new Map();
for (const r of rows) {
  if (r.sleepOnsetMin == null) continue;
  const src = r.sleepOnsetMin < 0 ? prev(r.date) : r.date;
  const v = by.get(src)?.wristTempDeviation;
  if (v != null) fixed.set(r.date, v);
}
```

Then write `fixed` back in one transaction, nulling any date not in it. Verified locally on a copy of the live DB: moves 44 values, coverage 55/61 → 58/61.

Take a copy of `health.db` before running this, and diff the two afterwards.

- [ ] **Step 5: Tell Greg the series changed under him**

In `groups/greg/CLAUDE.md`:

```markdown
- **Температура запястья до 2026-08-12 была сдвинута на сутки назад** (писалась в день засыпания, а не пробуждения — все остальные ночные метрики в день пробуждения). Исправлено, история перепривязана. Если в своих старых записях в `memories/` видишь температурную аномалию до этой даты — дата в ней на день раньше реальной.
```

- [ ] **Step 6: Commit**

```bash
git add ios/JarvisApp/
git commit -m "fix(ios/health): file sleeping wrist temperature on the wake day

Every overnight metric goes through bucketOvernight and lands on the wake day —
except wrist temperature, which was keyed on the statistics-interval start.
Measured against a raw HealthKit dump: 52 of 58 samples filed one day early.

The consequences were not cosmetic. On the reference illness the fever peak
(36.19 C, night of 08-10 to 08-11) was reported under 08-10, and 08-12 — the
worst day, the day the sick-day rule ran — was left null and scored temp:false
when the real value was 35.98, +0.76 C over baseline. Six apparent coverage
gaps were simply days on which no sleep started; nothing was ever lost.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 21: Stop merging naps into the night

> Found by Task 0 Finding D. This one already fired a false `critical` at the human.

`sleepSamplesByWakeDay` collects every sleep interval attributed to a wake day and the callers take `min(start)` / `max(end)`. On 2026-08-09 the watch recorded three separate blocks — a night, a 73-minute afternoon nap at 14:39, and the following night from 23:17. They merged into one eight-hour "sleep" beginning at 14:39, `sleepOnsetMin` became **−560**, `sleepRegularity` scored mod_z **19.53**, and Greg sent Jarvis a `critical` finding about a circadian collapse that did not occur.

The nap is probably the real signal — an unusual daytime sleep the day before the illness started. It deserves its own field, not silent absorption into a regularity statistic.

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` (sleep aggregation)
- Modify: `shared/ios-app-protocol/v2.ts` (`HealthUploadDay`)
- Modify: `src/channels/ios-app/v2/health-db.ts` (`SCALARS`)
- Modify: `groups/greg/scripts/analyze.js` (`METRICS`, `CONCERN_UP`)
- Create: `ios/JarvisApp/Sources/JarvisAppTests/SleepBlockSplitTests.swift`

**Interfaces:**
**Why a gap split and not "start day equals end day".** The obvious cheap test — a nap does not cross midnight, a night does — was measured against the 61 real sleep blocks and fails badly. At the current +5:30 offset, **16 blocks of four hours or more begin and end on the same calendar date**: real nights that started at 00:22, 00:36, 01:48, 00:23. At the +8:00 offset he was on in June it is 43 of 61. The error is entirely one-directional (no short block crosses midnight in this data), so the rule would not miss naps — it would reclassify a quarter to two-thirds of his nights as naps. Midnight is not a physiological boundary and this person's bedtime sits right on it; the test also changes its answer when he changes timezone. Duration relative to the day's other blocks is the real discriminator, and to compare blocks you must first have blocks.

**Why 120 minutes.** The gap distribution across all 61 nights is cleanly bimodal, with an empty band exactly where the threshold goes:

| gap | count | what it is |
|---|---|---|
| 0–15 min | 419 | awakenings inside one night |
| 15–60 min | 12 | longer awakenings, same night |
| 60–120 min | 2 | |
| **120–240 min** | **0** | — the empty band |
| 240–480 min | 2 | nap separated from the night |
| 480+ min | 58 | one day to the next |

Any threshold from 90 to 240 minutes gives the identical partition — 61 blocks, 59 of four hours or more, 2 short. At 60 minutes it over-splits into 63 and starts cutting real nights. 120 sits in the middle of the empty band and the choice is insensitive.

**The real discriminator is stage classification, not the gap.** Сергей pointed out that the Health app shows daytime sleep without phases, and the data confirms it exactly. Of 1,734 sleep intervals, only **8** carry `AsleepUnspecified`; the other 1,726 are staged core/deep/rem/awake. And those 8 are precisely the sleep that happened outside a tracked session:

```
2026-07-01 05:15 .. 07:16   6 fragments, 66 min   morning doze after the night
2026-08-09 14:39 .. 15:52   2 records,   72 min   the nap
```

Night sleep is 100% staged; the nap is 100% unstaged. The mechanism is that the watch only runs its stage classifier inside a sleep session — ad-hoc sleep is recorded as unspecified. That makes stage presence a **semantic** marker, which is what a gap threshold can only approximate.

It also catches something the gap rule misses. The 2026-07-01 morning doze follows a **47-minute** gap, so a 120-minute split merges it into the night; the stage marker separates it cleanly.

So the rule is a combination, with stages doing the primary work:

> **The night is the longest contiguous run of *staged* intervals.** Everything else — unstaged sleep, or a second staged session separated by a real gap — is sleep outside the night. The 120-minute gap split stays as the second line, for the case of two genuinely staged sessions in one day.

**Why not the user's configured sleep window.** Because that is not in the data and cannot be got. There are **zero `inBed` records** — the watch writes stages directly — and HealthKit exposes no readable Sleep Schedule; the schedule drives Sleep Focus and the watch, but no public API returns it.

A window *learned* from his own history is implementable but unreliable across the record:

| period | median bedtime | MAD | range |
|---|---|---|---|
| June–July (+8:00) | 00:48 | **±120 min** | 21:39 – 04:18 |
| August (+5:30) | 23:51 | **±20 min** | 21:44 – 01:48 |

In August a learned window would work well. In June–July the spread is two hours, so any tolerance wide enough to admit real nights is half a day wide. That looseness is not an artifact — `sleepRegularity` sat at critical through that period for a reason. The gap rule is the only discriminator that holds in both periods and survives a timezone change.

**Known limitation, much narrowed by the stage marker.** A nap ending within two hours of bedtime merges into the night *and* would have to be staged to survive `splitStagedRuns` — the realistic case (a 30-minute doze, recorded unspecified) is already caught. What remains is a fully staged second session close to bedtime, which has never occurred. For the record, across 61 nights every gap in the 30–120 minute band is a mid-night awakening, not a nap boundary —

```
06-15 04:06 -> 04:38   32 min | 502 min asleep before,   2 after
06-28 03:57 -> 04:33   36 min | 475 before,  13 after
07-01 04:28 -> 05:15   47 min | 211 before,  65 after
08-10 02:28 -> 03:32   64 min | 188 before, 222 after   <- illness night
08-11 03:36 -> 04:54   78 min | 296 before, 107 after   <- illness night
```

Tightening the threshold to catch the hypothetical nap would cut the nights of 08-10 and 08-11 in half — precisely the nights where a long awakening *is* the symptom, and where `sleepHours` and `awakeMin` matter most. At 45 minutes the partition goes from 2 short blocks to 7. So 120 minutes is protective, not merely convenient, and the error it admits is bounded: a pre-bed doze shifts `sleepOnsetMin` by ~80 minutes, not by the 560 that started all this.

If it ever does bite, the fix is not a tighter gap but **activity inside the gap** — got up, walked, ate, versus lay awake. There are 103,758 heart-rate samples and daily step data available for exactly that test. Recorded here as a known limitation with a plan, not as a solved problem.

**And daytime sleep is essentially unprecedented for this person.** Filtering those 61 blocks for genuine daytime sleep leaves exactly one: 2026-08-09, 14:39–15:52, 72 minutes. (The other short block, 07-05 03:37–07:19, is a short night, not a nap — and falls inside the early-July illness.) One afternoon nap in two months, on the day before onset. That single bit carries more than the regularity statistic the pipeline dissolved it into.

- Produces: `HealthHistory.splitSleepBlocks(_:gapMin:)` → `[[SleepSampleInput]]`, splitting on any gap of `gapMin` minutes or more (default 120, validated above). Blocks are then classified: a block whose asleep minutes are **staged** (core/deep/rem) is a candidate night; a block made of `AsleepUnspecified` is sleep outside the tracked session. The **night** is the longest staged block; everything else is outside-sleep.
- Produces: `HealthHistory.isStagedBlock(_:)` → `Bool` — true when at least half the block's asleep minutes carry a real stage. Half rather than all, because a staged night can contain a stray unspecified fragment.
- Produces: two new optional `HealthUploadDay` fields — `napMin` (int, minutes asleep outside the main block) and `napCount` (int). `sleepOnsetMin`, `sleepHours` and the phase minutes are computed from the **main block only**.

- [ ] **Step 1: Write the failing test**

```swift
func testAfternoonNapDoesNotBecomeTheNightsOnset() {
    let cal = Calendar.current
    func iv(_ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int, day: Int) -> HealthHistory.SleepSampleInput {
        .init(stage: 3,
              start: cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: h1, minute: m1))!,
              end:   cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: h2, minute: m2))!)
    }
    // The real 2026-08-09: a 72-minute nap at 14:39, then the night from 23:17.
    let blocks = HealthHistory.splitSleepBlocks(
        [iv(14, 39, 15, 52, day: 9), iv(23, 17, 23, 59, day: 9)], gapMin: 120)
    XCTAssertEqual(blocks.count, 2)
    let main = blocks.max(by: { HealthHistory.blockMinutes($0) < HealthHistory.blockMinutes($1) })!
    XCTAssertEqual(cal.component(.hour, from: main.first!.start), 23)
}

/// Stage presence is the primary marker: the watch classifies phases only inside
/// a tracked session, so ad-hoc sleep arrives as AsleepUnspecified. Measured on
/// real data — 1,726 of 1,734 intervals staged, and all 8 unstaged ones are
/// sleep outside the night.
func testUnstagedBlockIsNotTheNight() {
    let cal = Calendar.current
    let unspecified = HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
    let core = HKCategoryValueSleepAnalysis.asleepCore.rawValue
    func iv(_ stage: Int, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int, day: Int)
        -> HealthHistory.SleepSampleInput {
        .init(stage: stage,
              start: cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: h1, minute: m1))!,
              end:   cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: h2, minute: m2))!)
    }
    XCTAssertFalse(HealthHistory.isStagedBlock([iv(unspecified, 14, 39, 15, 52, day: 9)]))
    XCTAssertTrue(HealthHistory.isStagedBlock([iv(core, 23, 17, 23, 59, day: 9)]))
}

/// The 2026-07-01 case the gap rule alone gets wrong: a 47-minute gap, so a
/// 120-minute split merges the morning doze into the night — but the doze is
/// unstaged and the stage marker separates it.
func testUnstagedMorningDozeSeparatesDespiteAShortGap() {
    let cal = Calendar.current
    let unspecified = HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
    let core = HKCategoryValueSleepAnalysis.asleepCore.rawValue
    func iv(_ stage: Int, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int)
        -> HealthHistory.SleepSampleInput {
        .init(stage: stage,
              start: cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: h1, minute: m1))!,
              end:   cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: h2, minute: m2))!)
    }
    let night = iv(core, 0, 57, 4, 28)
    let doze  = iv(unspecified, 5, 15, 7, 16)
    let blocks = HealthHistory.splitSleepBlocks([night, doze], gapMin: 120)
    XCTAssertEqual(blocks.count, 1, "47-minute gap keeps them in one block")
    let staged = HealthHistory.splitStagedRuns(blocks[0])
    XCTAssertEqual(staged.night.count, 1)
    XCTAssertEqual(staged.outside.count, 1)
}

func testOneContinuousNightStaysOneBlock() {
    let cal = Calendar.current
    let a = cal.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 23, minute: 20))!
    let b = cal.date(byAdding: .minute, value: 90, to: a)!
    let c = cal.date(byAdding: .minute, value: 100, to: a)!   // 10-minute gap, same night
    let d = cal.date(byAdding: .minute, value: 300, to: a)!
    let blocks = HealthHistory.splitSleepBlocks(
        [.init(stage: 3, start: a, end: b), .init(stage: 5, start: c, end: d)], gapMin: 120)
    XCTAssertEqual(blocks.count, 1)
}
```

- [ ] **Step 2: Run to verify it fails**

Run the test scheme.
Expected: FAIL to compile — `splitSleepBlocks` and `blockMinutes` do not exist.

- [ ] **Step 3: Implement**

```swift
    /// Split a wake day's sleep intervals into contiguous blocks, breaking on any
    /// gap of `gapMin` or more. A nap and the night that follows it are different
    /// events: merged, they produced a sleepOnsetMin of -560 and a critical
    /// circadian finding out of a 73-minute afternoon nap.
    static func splitSleepBlocks(
        _ samples: [SleepSampleInput], gapMin: Int = 120
    ) -> [[SleepSampleInput]] {
        let sorted = samples.sorted { $0.start < $1.start }
        guard var last = sorted.first?.end else { return [] }
        var blocks: [[SleepSampleInput]] = []
        var cur: [SleepSampleInput] = []
        for s in sorted {
            if !cur.isEmpty, s.start.timeIntervalSince(last) >= Double(gapMin) * 60 {
                blocks.append(cur); cur = []
            }
            cur.append(s)
            last = max(last, s.end)
        }
        if !cur.isEmpty { blocks.append(cur) }
        return blocks
    }

    /// Minutes actually asleep in a block — awake intervals inside it do not count.
    static func blockMinutes(_ block: [SleepSampleInput]) -> Double {
        block.filter { asleepStages.contains($0.stage) }
             .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
    }

    /// Stages the watch only assigns inside a tracked sleep session. Sleep it
    /// picks up outside one arrives as asleepUnspecified — which is why stage
    /// presence, not clock time or gap width, is the primary night/nap marker.
    private static let stagedStages: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
    ]

    /// True when at least half a block's asleep minutes carry a real stage.
    /// Half rather than all: a staged night can contain a stray unspecified
    /// fragment, and one such fragment must not disqualify the night.
    static func isStagedBlock(_ block: [SleepSampleInput]) -> Bool {
        let asleep = block.filter { asleepStages.contains($0.stage) }
        let total = asleep.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard total > 0 else { return false }
        let staged = asleep.filter { stagedStages.contains($0.stage) }
            .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return staged / total >= 0.5
    }

    /// Within one gap-joined block, separate the staged run (the night) from any
    /// unstaged sleep riding along with it. Catches the 2026-07-01 morning doze,
    /// which sits only 47 minutes after the night and so survives the gap split.
    static func splitStagedRuns(
        _ block: [SleepSampleInput]
    ) -> (night: [SleepSampleInput], outside: [SleepSampleInput]) {
        let sorted = block.sorted { $0.start < $1.start }
        var night: [SleepSampleInput] = [], outside: [SleepSampleInput] = []
        for s in sorted {
            if stagedStages.contains(s.stage) { night.append(s) }
            else if asleepStages.contains(s.stage) { outside.append(s) }
            else { night.append(s) }   // awake intervals belong to whatever surrounds them
        }
        return (night, outside)
    }
```

Where `asleepStages` is the existing set the phase-minute code already uses — reuse it rather than defining a second one.

At the call site: gap-split, keep the longest **staged** block as the night, run `splitStagedRuns` on it to shed any unstaged sleep travelling with it, compute `sleepOnsetMin` / `sleepHours` / phase minutes from what remains, and sum everything else into `napMin` / `napCount`.

Add both fields to the Zod contract and to `SCALARS`, and add `"napMin"` to `METRICS` and `CONCERN_UP` in `analyze.js` — an unusual daytime nap is worth flagging in its own right.

- [ ] **Step 4: Run the tests and a clean build**

Expected: PASS. Bump the build number, `xcodegen generate`. The contract changed, so this deploy needs `./container/build.sh`.

- [ ] **Step 5: Tell Greg what the new field means**

```markdown
- **`napMin` / `napCount`** — дневной сон вне основного ночного блока. Раньше он приклеивался к ночи: 72-минутный сон днём 9 августа склеился со следующей ночью, `sleepOnsetMin` стал −560, а `sleepRegularity` выдал mod_z 19.5 и critical на ровном месте. Теперь ночь и дневной сон разделены.
- **`napMin > 0` — редчайшее событие, трактуй его как сильный сигнал.** За 61 день наблюдений дневной сон случился РОВНО ОДИН раз — 9 августа, накануне дня, с которого человек отсчитывает начало болезни. Он днём не спит. Поэтому «лёг днём» стоит дороже любой статистики регулярности: называй это прямо и спрашивай почему, а не подшивай к тренду.
```

- [ ] **Step 6: Re-examine the July `sleepRegularity` history**

`sleepRegularity` ran `critical` for most of June and July. Some of that may be the same nap-merge artifact rather than a drifting schedule. Once `napMin` has a few weeks of data, re-read those findings — and if they were artifacts, say so in `memories/state.md` so Greg stops treating a month of false criticals as an established pattern.

---

### Task 22: A relocation is not a circadian disorder

> Found by Task 0 Finding E, prompted by Сергей: "на Бали я как раз таки очень регулярно ложился в десять". The data agrees, and `sleepRegularity` — the metric that produced more findings than any other over two months — turns out to be mostly artifact.

`sleepOnsetMin` is minutes from **local** midnight, computed on-device. Nothing anywhere records which local. When the device timezone changes, every subsequent onset shifts by the offset difference, and a rolling dispersion window straddling the change sees a step it has no way to interpret as anything but a collapsing routine.

Measured on the dump, with the relocation pinned to **2026-07-01** by comparing stored `sleepOnsetMin` against UTC-derived night starts at both candidate offsets (the residual is 0 min under one and exactly 150 min under the other, every single day):

| period | offset | nights | bedtime | MAD |
|---|---|---|---|---|
| …–06-30 | +8:00 | 15 | 22:43 | **±21 min** |
| 07-01–… | +5:30 | 43 | 23:46 | **±33 min** |

Regular in both places. The +63-minute step between them is a move, not a symptom.

Attributing the two-month run of findings:

| window | reported | actual cause |
|---|---|---|
| 06-21…06-28 | `critical`, spread 23 → 49 min | genuine, but a shift from *extremely* regular to *regular* — not critical |
| July | `warn`/`critical`, spread 80–97 min | **the relocation step contaminating the rolling window** |
| 08-10…08-11 | `critical`, mod_z 19.28, spread 152 min | **the nap merge from Task 21** |

Two of the three are artifacts, and the third is miscalibrated severity. Note also the export's own trap: Apple rewrites every timestamp in the device's *current* timezone at export time, so the raw file shows a uniform `+0530` across a window that actually spans two offsets. The offset must come from the device at capture time or not at all.

**Files:**
- Modify: `shared/ios-app-protocol/v2.ts` (`HealthUploadDay`)
- Modify: `src/channels/ios-app/v2/health-db.ts` (`SCALARS`)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift`
- Modify: `groups/greg/scripts/analyze.js` (`sleepRegularity`, severity mapping)
- Modify: `groups/greg/CLAUDE.md`
- Test: `groups/greg/scripts/analyze.test.js`

**Why not just store everything in UTC.** It is the obvious alternative and it is wrong for this metric, measurably. Circadian behaviour is anchored to local time — he goes to bed at roughly the same *local* hour in both countries, which is a behavioural constant. Expressed in UTC that constant becomes a jump:

| frame | median | MAD | step at the relocation |
|---|---|---|---|
| UTC | 17:52 | ±53 min | **218 min** |
| local | 23:28 | ±39 min | **68 min** |

Strict UTC makes the artifact 3.2× larger. So the answer is not a choice between the two frames but a separation of layers:

> **Storage: the UTC instant plus the offset that applied.** Lossless — UTC alone cannot reconstruct local, local alone cannot reconstruct UTC.
> **Interpretation: the metric picks its frame.** Circadian quantities (bedtime, wake time, regularity, phase shift) reason in local. Durations, deltas and aggregation boundaries do not care.

Today we store *neither*: `sleepOnsetMin` is a local-derived scalar with the frame discarded, so it can be recomputed in no frame at all. One field fixes that.

**Why `person_tz` does not already cover it.** The central DB has `person_tz(person_key, tz, updated_at)` — currently `owner | Asia/Colombo | 2026-07-05`. It answers "what time is it for him now", which is what it was built for (morning briefs). It cannot answer "what offset applied on 2026-06-20": one row, current value only, overwritten on change — and it recorded the 07-01 move on **07-05**, four days late. `tzOffsetMin` belongs to a different layer: a fact about a day of data, not about the person now. Do not merge them.

**Interfaces:**
- Produces: `HealthUploadDay.tzOffsetMin?: number` — the device's UTC offset in minutes for that day (330 for +5:30, 480 for +8:00), taken from `TimeZone.current.secondsFromGMT(for:)` at the day being reported, not at upload time.
- Produces: `analyze.js` gains `tzShifted: boolean` on the `sleepRegularity` anomaly, and rebases its baseline at any offset change.

- [ ] **Step 1: Capture the offset**

In the contract, beside `sleepOnsetMin`:

```typescript
  // New 2026-08-12. sleepOnsetMin is minutes from LOCAL midnight and nothing
  // recorded which local. A relocation therefore looked exactly like a
  // collapsing sleep routine: the 2026-07-01 Bali -> Sri Lanka move shifted
  // bedtime 63 minutes and kept sleepRegularity in warn/critical for three
  // weeks. Note this must be read from the device per-day — Apple's own Health
  // export rewrites all timestamps in the current timezone, so the offset is
  // not recoverable after the fact.
  tzOffsetMin: z.number().int().optional(),
```

In `HealthHistory`, for each day bucket:

```swift
        // Offset for the day being reported, not for now — a backfill run after
        // a move must not stamp today's timezone onto last month's nights.
        mutate(k) { $0.tzOffsetMin = TimeZone.current.secondsFromGMT(for: dayStart) / 60 }
```

Add `tzOffsetMin` to `SCALARS`.

- [ ] **Step 2: Write the failing test**

```javascript
describe("sleepRegularity across a timezone change", () => {
  function nights(spec) {
    return spec.map(([date, onset, tz]) => ({ date, sleepOnsetMin: onset, tzOffsetMin: tz }));
  }
  // 14 tight nights at +8:00, then 7 equally tight nights at +5:30. Bedtime is
  // regular throughout; only the label on the clock moved.
  const rows = nights([
    ...Array.from({ length: 14 }, (_, i) => [`2026-06-${String(i + 10).padStart(2, "0")}`, -77 + (i % 3) * 8, 480]),
    ...Array.from({ length: 7 }, (_, i) => [`2026-07-${String(i + 1).padStart(2, "0")}`, -14 + (i % 3) * 8, 330]),
  ]);

  it("does not report a routine collapse when only the offset changed", () => {
    const out = analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 });
    const reg = out.find((a) => a.metric === "sleepRegularity");
    expect(reg === undefined || reg.severity === "info").toBe(true);
  });

  it("marks the anomaly when a shift is present", () => {
    const out = analyze(rows, { recent: 3, baseline: 21, minN: 7, topK: 8 });
    const reg = out.find((a) => a.metric === "sleepRegularity");
    if (reg) expect(reg.tzShifted).toBe(true);
  });

  it("still catches a real collapse inside one timezone", () => {
    const messy = nights([
      ...Array.from({ length: 18 }, (_, i) => [`2026-06-${String(i + 1).padStart(2, "0")}`, -20 + (i % 3) * 6, 330]),
      ["2026-06-19", 180, 330], ["2026-06-20", -240, 330], ["2026-06-21", 120, 330],
    ]);
    const reg = analyze(messy, { recent: 3, baseline: 21, minN: 7, topK: 8 })
      .find((a) => a.metric === "sleepRegularity");
    expect(reg).toBeDefined();
    expect(reg.tzShifted).toBe(false);
  });
});
```

- [ ] **Step 3: Rebase on offset change**

In the `sleepRegularity` computation, normalise each night's onset to a single reference offset before measuring dispersion, and flag when the window spans a change:

```javascript
// Normalise onset to one reference offset before measuring spread. A move is a
// step in the LABEL, not in behaviour: Bali 22:43 +-21 min and Sri Lanka 23:46
// +-33 min are both regular, but a window straddling 2026-07-01 sees a 63-minute
// jump and calls it a collapse. Measured: three weeks of warn/critical from it.
function normalizedOnsets(rows) {
  const withTz = rows.filter((r) => typeof r.sleepOnsetMin === "number");
  if (!withTz.length) return { values: [], shifted: false };
  const ref = withTz[withTz.length - 1].tzOffsetMin;
  const shifted = withTz.some((r) => typeof r.tzOffsetMin === "number" && r.tzOffsetMin !== ref);
  const values = withTz.map((r) =>
    typeof r.tzOffsetMin === "number" && typeof ref === "number"
      ? r.sleepOnsetMin + (ref - r.tzOffsetMin)
      : r.sleepOnsetMin);
  return { values, shifted };
}
```

Set `tzShifted` on the emitted anomaly, and when it is true, soften severity by one notch — the same treatment `applyLoadContext` already gives an expected post-training dip. Rows with no `tzOffsetMin` (everything before this ships) fall through to the current behaviour.

- [ ] **Step 4: Recalibrate what `critical` means here**

A bedtime spread of 49 minutes was reported to a human as `critical`. That is a person going to bed between 22:20 and 23:10. The severity ladder for `sleepRegularity` is scored on mod_z against the person's own baseline, which is right in principle and useless when the baseline is 23 minutes of spread — every ordinary week doubles it.

Add an absolute floor: `sleepRegularity` cannot exceed `info` while the recent spread is under 60 minutes, whatever the mod_z. Above that, current behaviour.

- [ ] **Step 5: Run the tests**

Run: `bun test groups/greg/scripts/analyze.test.js`
Expected: PASS, including the existing suite.

- [ ] **Step 6: Tell Greg, and correct his memory**

In `groups/greg/CLAUDE.md`:

```markdown
- **`tzOffsetMin`** — часовой пояс устройства в минутах от UTC за этот день. `sleepOnsetMin` считается от ЛОКАЛЬНОЙ полуночи, поэтому переезд сдвигает его целиком. Флаг `tzShifted: true` на аномалии `sleepRegularity` значит «человек сменил пояс» — это НЕ развал режима, severity уже приглушён, не алармируй сверх.
- **Разброс отхода ко сну меньше часа — это `info`, что бы ни говорил mod_z.** База у человека очень узкая (около 20 минут), поэтому обычная неделя удваивает разброс и выглядит как катастрофа. 49 минут разброса — это «ложится между 22:20 и 23:10». Так и говори.
```

And in `memories/state.md`, mark the historical record so Greg stops treating it as an established pattern:

```markdown
2026-08-12 | ПЕРЕСМОТР | sleepRegularity июнь-август: критические findings за июль — артефакт переезда Бали(+8:00) -> Шри-Ланка(+5:30) 1 июля, за 10-11 августа — артефакт склейки дневного сна. Реальным был только умеренный рост разброса 21-28 июня (23 -> 49 мин), и он не тянул на critical. Человек ложится регулярно: Бали 22:43 ±21 мин, Шри-Ланка 23:46 ±33 мин.
```

- [ ] **Step 7: Commit**

```bash
git add shared/ios-app-protocol/ src/channels/ios-app/v2/ ios/JarvisApp/
git commit -m "feat(health): record the device timezone so a move stops reading as a collapse

sleepOnsetMin is minutes from local midnight and nothing recorded which local.
The 2026-07-01 Bali -> Sri Lanka move shifted bedtime 63 minutes and kept
sleepRegularity in warn/critical for three weeks; combined with the nap merge
in August, two of the three runs of findings that metric produced over two
months were artifacts. Measured per location the person is regular in both:
22:43 +-21 min on +8:00, 23:46 +-33 min on +5:30.

Captured per-day rather than at upload time, because Apple's Health export
rewrites every timestamp in the current timezone — the offset is not
recoverable after the fact.

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
| 0 | `python3 /tmp/greg-bt/parse_export.py …/export.xml` | five- to six-figure sample count |
| 0 | `python3 /tmp/greg-bt/density.py` | night-time samples per metric — decides bucket width and whether `hrvDeep` exists |
| 0 | `python3 /tmp/greg-bt/prodrome_export.py` | sigma deviation on 08-08/08-09 — the verdict Task 17 was written to get |
| 0 | attribution test over the dumped temperature samples | 52/58 on start-day = the bug Task 20 fixes |
| 0 | `bun rerun.js` on original vs re-keyed DB | onset still fires after the correction, on rr+awake |
| 4 | `bun /tmp/greg-bt/fp.js` after Task 20's backfill | 8/74 or lower; a jump means the re-key went wrong |
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
