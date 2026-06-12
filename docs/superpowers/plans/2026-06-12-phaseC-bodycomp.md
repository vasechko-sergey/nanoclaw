# Phase C — Body-composition data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flow four HealthKit body-composition fields — `bodyMass`, `height`, `bodyFatPercentage`, `leanBodyMass` (from Sergei's smart scale) — through two paths: (C1) daily upload → Greg's `analyze.js` body-composition trend → `greg.md`; and (C2) the pull snapshot → Gordon's weight/height for intake.

**Architecture:** iOS already has a health-upload pipeline (daily aggregates → `HealthUploadDay` → host → Greg's `raw.jsonl`) and a pull-context pipeline (`request_context(["health"])` → `AppContextCoordinator.health()`). This phase adds the four fields to both. **The Zod `HealthUploadDay` schema (`shared/ios-app-protocol/v2.ts`) is the load-bearing gate** — it is *not* `.strict()`, so it silently strips any field not declared there; a body field added to the Swift struct but not the Zod schema never reaches `raw.jsonl`. Downstream is automatic: `health-ingest.ts` spreads `...d`, and `analyze.js` reads `r[metric]` generically. Greg gains a `buildBodyComp` synthetic (fat-mass / lean-mass + 28-day slopes) so recomposition is judged by **lean↑ / fat↓ at flat weight**, not by weight alone.

**Tech Stack:** Swift / HealthKit (iOS, Xcode), Zod + vitest (shared protocol, host), Bun (Greg `analyze.js`). iOS changes require a **device rebuild on Sergei's iPhone** (real scale data); host + Greg verify headlessly.

**Spec:** [`docs/superpowers/specs/2026-06-11-shared-profiles-and-bodycomp-design.md`](../specs/2026-06-11-shared-profiles-and-bodycomp-design.md) §C. Depends on **Phase A** (request_context gate — done) for C2. Feeds **Phase D** (Gordon recomp verdict reads `greg.md`).

---

## Field reference (units, both paths)

| Field | HK type | Unit read | Stored as | Path |
|-------|---------|-----------|-----------|------|
| `bodyMass` | `.bodyMass` | `gramUnit(with: .kilo)` | kg, 1 dp | upload + pull |
| `height` | `.height` | `meter()` | m, 2 dp | upload + pull |
| `bodyFatPercentage` | `.bodyFatPercentage` | `percent()` | **percent number** (×100 of the 0–1 fraction), 1 dp | upload only |
| `leanBodyMass` | `.leanBodyMass` | `gramUnit(with: .kilo)` | kg, 1 dp | upload only |

> The `percent()` unit yields a 0–1 fraction (HealthKit convention — see the SpO2 handling in `HealthHistory.swift`). Multiply by 100 to store a human percent (e.g. `18.5`). **Confirm against `reduceSpo2`/`spo2Min` storage when implementing** so bodyFat matches the existing percent convention.

All four are `Double?` and **optional** everywhere — older rows / days with no measurement omit them, and every consumer is null-safe.

---

## File Structure

| File | Change |
|------|--------|
| `ios/.../Protocol/V2.swift` | `HealthUpload.Day` struct: +4 fields (Task 1) |
| `shared/ios-app-protocol/v2.ts` | `HealthUploadDay` Zod: +4 fields (Task 1) **— the gate** |
| `shared/ios-app-protocol/fixtures/health/upload_sensors.json` + `fixtures.test.ts` | +body fields + assertion (Task 1) |
| `ios/.../Services/HealthHistory.swift` | +4 `collection(.discreteAverage)` reads → Day (Task 2) |
| `ios/.../Services/HealthSync.swift` | +4 sample types (background wake) (Task 2) |
| `ios/.../Services/HealthManager.swift` | auth types +4; pull props `bodyMass`/`height` + latest-sample queries (Task 3) |
| `ios/.../Services/AppContextCoordinator.swift` | `health()` +`body_mass_kg`/`height_m` (Task 3) |
| `groups/greg/scripts/analyze.js` | `buildBodyComp` + METRICS/CONCERN + `bodyComp` output + `latest` (Task 4) |
| `groups/greg/CLAUDE.md` | §Данные body-comp block (Task 4) |
| `groups/greg/skills/publish/SKILL.md` | greg.md gains a body-composition line (Task 4) |

`src/channels/ios-app/v2/health-ingest.ts` — **no change** (spreads `...d`).

---

### Task 1 — Protocol: add the 4 fields to the upload Day (struct + Zod gate + fixtures)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift` (`HealthUpload.Day`, ~line 637)
- Modify: `shared/ios-app-protocol/v2.ts` (`HealthUploadDay`, ~line 345)
- Modify: `shared/ios-app-protocol/fixtures/health/upload_sensors.json`
- Modify: `shared/ios-app-protocol/fixtures.test.ts`

- [ ] **Step 1: Add fields to the Swift struct**

In `V2.swift`, in `struct Day`, insert before `var workouts: [Workout]?`:

```swift
    // New 2026-06-12: body composition (smart scale).
    var bodyMass: Double?               // kg
    var height: Double?                 // m
    var bodyFatPercentage: Double?      // percent number, e.g. 18.5
    var leanBodyMass: Double?           // kg
```

- [ ] **Step 2: Add fields to the Zod schema (the gate)**

In `shared/ios-app-protocol/v2.ts`, in `HealthUploadDay`, insert before `workouts: z.array(Workout).optional(),`:

```typescript
  // New 2026-06-12: body composition (smart scale). bodyFatPercentage is a
  // percent number (e.g. 18.5), not a 0-1 fraction. All optional — days with
  // no scale measurement omit them.
  bodyMass: z.number().nonnegative().optional(),
  height: z.number().nonnegative().optional(),
  bodyFatPercentage: z.number().nonnegative().optional(),
  leanBodyMass: z.number().nonnegative().optional(),
```

- [ ] **Step 3: Update the sensors fixture**

In `shared/ios-app-protocol/fixtures/health/upload_sensors.json`, add the four fields to the day object (alongside the existing `spo2Min` etc.). Use realistic values:

```json
  "bodyMass": 78.4,
  "height": 1.82,
  "bodyFatPercentage": 18.5,
  "leanBodyMass": 63.9
```

(Read the file first to place them inside the correct day object with valid JSON commas.)

- [ ] **Step 4: Add a fixture assertion**

In `shared/ios-app-protocol/fixtures.test.ts`, in the block that asserts `upload_sensors.json` preserves named fields (the `deepMin`/`spo2Min` assertions ~lines 47-59), add:

```typescript
    expect(d.bodyMass).toBe(78.4);
    expect(d.height).toBe(1.82);
    expect(d.bodyFatPercentage).toBe(18.5);
    expect(d.leanBodyMass).toBe(63.9);
```

(Since the schema strips unknown fields silently, this assertion is what actually proves the Zod additions in Step 2 are correct — without it the round-trip passes either way.)

- [ ] **Step 5: Build protocol + run fixtures test**

Run: `pnpm run build` then `pnpm exec vitest run shared/ios-app-protocol/fixtures.test.ts`
Expected: build clean; fixtures test passes incl. the 4 new assertions. (If they fail, the Zod fields in Step 2 are missing/typo'd.)

- [ ] **Step 6: Commit**

```bash
git -C /Users/serg/git/nanoclaw add ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift shared/ios-app-protocol/v2.ts shared/ios-app-protocol/fixtures/health/upload_sensors.json shared/ios-app-protocol/fixtures.test.ts
git -C /Users/serg/git/nanoclaw commit -m "feat(protocol): add body-composition fields to health upload Day

bodyMass/height/bodyFatPercentage/leanBodyMass on HealthUpload.Day +
HealthUploadDay Zod gate (not strict — must be declared to survive parse) +
fixture assertion. Downstream (health-ingest ...d spread, analyze.js) picks
them up automatically.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2 — iOS upload: read body fields into the daily Day + background wake

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift` (add 4 reads near the wristTemp block ~line 231)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift` (`sampleTypes`, ~line 12)

- [ ] **Step 1: Add the four discrete-average reads in HealthHistory**

In `HealthHistory.swift`, mirror the `wristTempDeviation` block (which uses the `collection(_:start:end:options:)` helper with `.discreteAverage`). After that block, add:

```swift
        // Body composition (smart scale): discrete measurements, per measured day.
        group.enter()
        collection(.bodyMass, start: start, end: end, options: .discreteAverage) { stats in
            let kg = HKUnit.gramUnit(with: .kilo)
            for s in stats where s.averageQuantity() != nil {
                let v = (s.averageQuantity()!.doubleValue(for: kg) * 10).rounded() / 10
                mutate(bucketKey(s.startDate)) { $0.bodyMass = v }
            }
            group.leave()
        }
        group.enter()
        collection(.height, start: start, end: end, options: .discreteAverage) { stats in
            let m = HKUnit.meter()
            for s in stats where s.averageQuantity() != nil {
                let v = (s.averageQuantity()!.doubleValue(for: m) * 100).rounded() / 100
                mutate(bucketKey(s.startDate)) { $0.height = v }
            }
            group.leave()
        }
        group.enter()
        collection(.bodyFatPercentage, start: start, end: end, options: .discreteAverage) { stats in
            let frac = HKUnit.percent()  // 0..1 fraction; ×100 → percent number
            for s in stats where s.averageQuantity() != nil {
                let v = (s.averageQuantity()!.doubleValue(for: frac) * 1000).rounded() / 10
                mutate(bucketKey(s.startDate)) { $0.bodyFatPercentage = v }
            }
            group.leave()
        }
        group.enter()
        collection(.leanBodyMass, start: start, end: end, options: .discreteAverage) { stats in
            let kg = HKUnit.gramUnit(with: .kilo)
            for s in stats where s.averageQuantity() != nil {
                let v = (s.averageQuantity()!.doubleValue(for: kg) * 10).rounded() / 10
                mutate(bucketKey(s.startDate)) { $0.leanBodyMass = v }
            }
            group.leave()
        }
```

Note: `bodyFatPercentage` math is `frac * 1000 / 10` = `frac*100` rounded to 1 dp. Verify `bucketKey` and `collection` are in scope (they are — used by the wristTemp/vo2max blocks). If the helper requires the day-key form, mirror exactly how `wristTempDeviation` calls it.

- [ ] **Step 2: Add the 4 sample types to HealthSync (background-delivery wake)**

In `HealthSync.swift`, in `private static let sampleTypes: [HKSampleType]`, append:

```swift
    HKQuantityType(.bodyMass),
    HKQuantityType(.height),
    HKQuantityType(.bodyFatPercentage),
    HKQuantityType(.leanBodyMass),
```

So a new scale measurement triggers a re-upload.

- [ ] **Step 3: Compile-check (simulator) + Swift tests**

Run (via XcodeBuildMCP `build_sim`, scheme `JarvisApp`, an available iOS simulator) — confirm it compiles. Then run the Swift test target (`test_sim`). Expected: builds clean; tests pass. (No real scale data on the simulator, so this is a compile + unit gate only.)

- [ ] **Step 4: Commit**

```bash
git -C /Users/serg/git/nanoclaw add ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift ios/JarvisApp/Sources/JarvisApp/Services/HealthSync.swift
git -C /Users/serg/git/nanoclaw commit -m "feat(ios): upload body-composition daily aggregates

HealthHistory reads bodyMass/height/bodyFatPercentage/leanBodyMass per
measured day (discreteAverage); HealthSync observes them for background
re-upload on a new scale measurement.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3 — iOS pull: weight + height in the context snapshot (for Gordon intake)

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift` (props + auth + 2 latest-sample queries)
- Modify: `ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift` (`health()`)

- [ ] **Step 1: Add stored props + authorization in HealthManager**

In `HealthManager.swift`, add to the `@Observable` stored properties (near `var restingHeartRate: Int?`):

```swift
    var bodyMass: Double?   // kg, latest
    var height: Double?     // m, latest
```

In the `requestAndFetch()` `types: Set<HKObjectType>`, append (authorizes all four for both upload + pull reads):

```swift
            HKQuantityType(.bodyMass),
            HKQuantityType(.height),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.leanBodyMass),
```

- [ ] **Step 2: Add latest-sample queries in fetchToday**

In `fetchToday()`, after the `qRHR` block (mirroring the `qHR` latest-sample pattern), add:

```swift
        let qBodyMass = HKSampleQuery(
            sampleType: HKQuantityType(.bodyMass),
            predicate: nil, limit: 1, sortDescriptors: [sort]
        ) { [weak self] _, s, _ in
            if let s = s?.first as? HKQuantitySample {
                let kg = (s.quantity.doubleValue(for: HKUnit.gramUnit(with: .kilo)) * 10).rounded() / 10
                DispatchQueue.main.async { self?.bodyMass = kg }
            }
        }
        store.execute(qBodyMass)

        let qHeight = HKSampleQuery(
            sampleType: HKQuantityType(.height),
            predicate: nil, limit: 1, sortDescriptors: [sort]
        ) { [weak self] _, s, _ in
            if let s = s?.first as? HKQuantitySample {
                let m = (s.quantity.doubleValue(for: HKUnit.meter()) * 100).rounded() / 100
                DispatchQueue.main.async { self?.height = m }
            }
        }
        store.execute(qHeight)
```

(`sort` is the descriptor already declared above `qHR`.)

- [ ] **Step 2b: (verify) sample tables don't need a height/weight default**

`height` rarely changes; a `limit: 1` latest sample is correct. No predicate (all-time latest), same as `qHR`.

- [ ] **Step 3: Surface in the pull snapshot**

In `AppContextCoordinator.swift` `health()`, add reads + output entries. After `let exercise = await MainActor.run { h.exerciseMinutes }`:

```swift
    let bodyMass = await MainActor.run { h.bodyMass }
    let height = await MainActor.run { h.height }
```

And after `if let v = exercise { obj["exercise_minutes"] = .int(v) }`:

```swift
    if let v = bodyMass { obj["body_mass_kg"] = .double(v) }
    if let v = height { obj["height_m"] = .double(v) }
```

- [ ] **Step 4: Compile + tests + commit**

Run `build_sim` (scheme `JarvisApp`) + `test_sim`. Expected: clean.

```bash
git -C /Users/serg/git/nanoclaw add ios/JarvisApp/Sources/JarvisApp/Services/HealthManager.swift ios/JarvisApp/Sources/JarvisApp/Services/AppContextCoordinator.swift
git -C /Users/serg/git/nanoclaw commit -m "feat(ios): expose weight/height in the pull health snapshot

HealthManager reads latest bodyMass/height; AppContextCoordinator.health()
returns body_mass_kg/height_m so Gordon's intake can pull them via
request_context([\"health\"]) instead of asking.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4 — Greg: body-composition trend in analyze.js + publish it

**Files:**
- Modify: `groups/greg/scripts/analyze.js` (`buildBodyComp`, METRICS, CONCERN, `bodyComp` output, `latest`)
- Modify: `groups/greg/CLAUDE.md` (§Данные body-comp block)
- Modify: `groups/greg/skills/publish/SKILL.md` (greg.md body-composition line)
- Test: `groups/greg/scripts/*.test.js` (if a Bun test exists) — else a manual synthetic run

- [ ] **Step 1: Add `buildBodyComp` synthetic**

Read `analyze.js`'s existing `buildRecovery` (~line 151) to match the in-place-mutation pattern + any slope helper. Add a `buildBodyComp(rows)` that, for each row with `bodyMass` and `bodyFatPercentage`, writes synthetic fields:

```javascript
// Body composition: recomposition is judged by lean↑ / fat↓ at ~flat weight,
// not by bodyMass alone. Derive fat-mass + lean-mass per row from the scale
// fields; leave rows without a scale reading untouched (series() skips them).
export function buildBodyComp(rows) {
  for (const r of rows) {
    if (r.bodyMass == null || r.bodyFatPercentage == null) continue;
    r.fatMassKg = Math.round((r.bodyMass * r.bodyFatPercentage) / 100 * 10) / 10;
    r.leanMassKg =
      r.leanBodyMass != null
        ? r.leanBodyMass
        : Math.round((r.bodyMass - r.fatMassKg) * 10) / 10;
  }
}
```

Call it alongside the existing `buildRecovery(rows); buildSleepRegularity(rows);` (~line 470): add `buildBodyComp(rows);`.

- [ ] **Step 2: Register the metrics + concern direction**

In `METRICS`, append `"fatMassKg", "leanMassKg"` (NOT raw `bodyMass` — weight itself isn't a concern signal in a recomp). In `CONCERN_UP`, add `"fatMassKg"` (fat mass rising = concern). In `CONCERN_DOWN`, add `"leanMassKg"` (lean mass falling = concern). The generic `analyze()` loop then trend-flags them automatically.

- [ ] **Step 3: Add a `bodyComp` output block + extend `latest`**

In the result object, add a `bodyComp` summary next to `latest` (null when no scale data). Use the same slope approach the anomaly path uses for `trend_per_day` (read how `analyze()` computes it; if there's a `slope`/`trendPerDay` helper, reuse it over a 28-row window):

```javascript
bodyComp: (() => {
  const withMass = rows.filter((r) => r.bodyMass != null && r.fatMassKg != null);
  if (withMass.length === 0) return null;
  const lastBC = withMass[withMass.length - 1];
  const win = withMass.slice(-28);
  return {
    date: lastBC.date,
    bodyMass: lastBC.bodyMass,
    bodyFatPercentage: lastBC.bodyFatPercentage ?? null,
    fatMassKg: lastBC.fatMassKg,
    leanMassKg: lastBC.leanMassKg ?? null,
    fatSlopePerDay: slopePerDay(win, "fatMassKg"),   // reuse analyze's slope util
    leanSlopePerDay: slopePerDay(win, "leanMassKg"),
    windowDays: win.length,
  };
})(),
```

If `analyze.js` has no reusable slope helper, add a tiny one (`(last - first) / spanDays`) — read the file and pick the simplest correct fit; keep it null-safe. Also add to the `latest` object: `bodyMass: last.bodyMass ?? null`, `bodyFatPercentage: last.bodyFatPercentage ?? null`, `leanMassKg: last.leanMassKg ?? null`, `fatMassKg: last.fatMassKg ?? null`.

- [ ] **Step 4: Verify with a synthetic run (null-safe before data, correct after)**

```bash
cd /Users/serg/git/nanoclaw/groups/greg
# (a) no body data → bodyComp null, no crash
printf '{"date":"2026-06-10","sleepHours":7,"restingHeartRate":60}\n' > /tmp/rawA.jsonl
bun scripts/analyze.js --raw /tmp/rawA.jsonl 2>/dev/null | grep -q '"bodyComp":null' && echo "OK null-safe"
# (b) with body data → fatMassKg/leanMassKg derived
printf '{"date":"2026-05-20","bodyMass":80,"bodyFatPercentage":20}\n{"date":"2026-06-12","bodyMass":79,"bodyFatPercentage":18}\n' > /tmp/rawB.jsonl
bun scripts/analyze.js --raw /tmp/rawB.jsonl 2>/dev/null | grep -o '"bodyComp":{[^}]*}'
```
Expected: (a) prints `OK null-safe`; (b) prints a `bodyComp` block with `fatMassKg` ≈ 14.2 and `leanMassKg` ≈ 64.8 for the last day. (Confirm the `--raw` flag name against `analyze.js`'s arg parsing; the daily-cycle calls it as `analyze.js --out ...` reading the default raw path — use whatever flag sets the input, or drop a temp file at the default path.)

- [ ] **Step 5: Document in Greg's CLAUDE.md §Данные**

In `groups/greg/CLAUDE.md`, in `### Данные (read-only)`, add a block:

```markdown
- **Состав тела (2026-06-12, со «умных» весов):** `bodyMass` (кг), `height` (м), `bodyFatPercentage` (%, число вида 18.5), `leanBodyMass` (кг) — приходят в дни, когда Сергей вставал на весы (не каждый день). `analyze.js` считает синтетику `fatMassKg = bodyMass*bodyFat%/100` и `leanMassKg`, и блок `bodyComp` (последние значения + наклоны за ~28 дней). **Рекомп судится по сухая↑ / жир↓ при ровном весе** — не по `bodyMass` самому по себе (поэтому вес НЕ в METRICS, флагуются `fatMassKg`↑ / `leanMassKg`↓). Данных может не быть (весы не каждый день / до пересборки iOS) — тогда `bodyComp: null`, это норма.
```

- [ ] **Step 6: Greg publish skill — add the body-composition line to greg.md**

In `groups/greg/skills/publish/SKILL.md`, add a step reading `bodyComp` from the analyze output and a line in the fragment. After the `тренд:` line in the format block, add:

```
состав тела: <если bodyComp != null: вес <bodyMass>кг · жир <fatMassKg>кг (<bodyFatPercentage>%) · сухая <leanMassKg>кг; тренд за месяц: жир <↓/↑/ровно>, сухая <↑/↓/ровно> (по fatSlopePerDay/leanSlopePerDay). Если bodyComp == null — строку «состав тела» пропусти.>
```

And in the skill's Шаги, add: "Прочти также `bodyComp` из `/tmp/anomalies.json` (может быть `null` — тогда строку про состав тела не пиши)."

- [ ] **Step 7: Commit (Greg files are gitignored — no commit; they deploy via scp in Task 5)**

Greg's `scripts/`, `CLAUDE.md`, `skills/` are under `groups/` (gitignored). No git commit — they scp in Task 5. Just confirm the synthetic run (Step 4) passed.

---

### Task 5 — Build, deploy, verify

**Files:** none (build + deploy + verification)

iOS changes need a **device rebuild on Sergei's iPhone** — only there does real scale data exist. Host + Greg verify headlessly now; the body data flows after Sergei rebuilds.

- [ ] **Step 1: Push protocol + iOS commits**

```bash
git -C /Users/serg/git/nanoclaw push origin main
```

- [ ] **Step 2: Host build (shared protocol changed)**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && git pull --ff-only origin main && pnpm run build"'
```
Expected: clean. `health-ingest.ts` now passes body fields through (Zod accepts them). No restart strictly required (ingest reads the rebuilt shared module on next process start — restart to be safe):

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw && sleep 3 && sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user is-active nanoclaw'
```

- [ ] **Step 3: Deploy Greg (scp)**

```bash
cd /Users/serg/git/nanoclaw
scp groups/greg/scripts/analyze.js root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/scripts/analyze.js
scp groups/greg/CLAUDE.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/CLAUDE.md
scp groups/greg/skills/publish/SKILL.md root@148.253.211.164:/home/nanoclaw/nanoclaw/groups/greg/skills/publish/SKILL.md
ssh root@148.253.211.164 'chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/greg'
```
Note: `analyze.js` is live-mounted (Greg's next 08:45 publish + daily-cycle use the new version, no rebirth). The `CLAUDE.md` change only takes effect on Greg's next natural session rebirth — fine (the body-comp doc is reference; the publish skill drives the output).

- [ ] **Step 4: Headless verify on the VDS — analyze.js handles body fields**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw/groups/greg && printf %s\\\\n \"{\\\"date\\\":\\\"2026-06-12\\\",\\\"bodyMass\\\":79,\\\"bodyFatPercentage\\\":18,\\\"leanBodyMass\\\":64}\" > /tmp/bc.jsonl && bun scripts/analyze.js --raw /tmp/bc.jsonl 2>/dev/null | grep -o \"bodyComp[^}]*}\" ; rm -f /tmp/bc.jsonl"'
```
Expected: a `bodyComp` block with `fatMassKg`≈14.2, `leanMassKg`64. (Adjust the `--raw` flag to match analyze.js.)

- [ ] **Step 5: iOS device rebuild — hand off to Sergei**

The iOS changes (Tasks 1-3) require building the app onto Sergei's iPhone (same rebuild that adds "Ramzi" to the agent picker, pending since Phase 1). Tell Sergei: build + install `JarvisApp` on the device, grant the new HealthKit body-composition read permissions when prompted. After he stands on the scale once, the next health upload carries the body fields → `raw.jsonl` → Greg's next publish writes the `состав тела` line into `greg.md`.

- [ ] **Step 6: Post-device verification (after Sergei rebuilds + a scale reading)**

```bash
ssh root@148.253.211.164 'tail -1 /home/nanoclaw/nanoclaw/groups/greg/health/raw.jsonl | grep -o "bodyMass[^,]*" || echo "no body data yet"'
ssh root@148.253.211.164 'cat /home/nanoclaw/nanoclaw/groups/global/profiles/greg.md'
```
Expected (once data flows): `raw.jsonl` last row has `bodyMass`; `greg.md` shows a `состав тела:` line. Until then, "no body data yet" is the correct state.

- [ ] **Step 7: Update memory**

Update `project_gordon_agent.md`: Phase C shipped — 4 body fields plumbed (upload → Greg `bodyComp` trend in `greg.md`; pull → `body_mass_kg`/`height_m` for Gordon intake); the Zod-gate gotcha (not `.strict()`); iOS device-rebuild dependency. Mark C done pending Sergei's device build.

---

## Done criteria

- Protocol: 4 fields on Swift `Day` + Zod `HealthUploadDay`; fixtures test green (incl. body assertions).
- iOS compiles (sim) + Swift tests pass; upload + pull paths carry the fields.
- Greg `analyze.js`: `buildBodyComp` synthetic, `fatMassKg`/`leanMassKg` in METRICS/CONCERN, `bodyComp` output block, null-safe with no data; documented; publish skill emits a `состав тела` line.
- Host built with the protocol change; Greg deployed; analyze.js verified on synthetic body data.
- iOS device rebuild handed to Sergei; post-device check defined.

## Not in this phase

- **D** — Gordon's intake pulls `body_mass_kg`/`height_m` via `request_context(["health"])` (this phase provides them); Gordon reads `greg.md` (now with `состав тела`) for the recomp verdict; Gordon publishes `gordon.md` targets.
- Payne weekly-tonnage in `payne.md` (needs a `volume-report.js` CLI).
- **E** — retire `health_trend → self/health.md` a2a once fragments are confirmed; drop the morning-brief fallback.
