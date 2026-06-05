# Greg: House MD Persona + Differential + Sick-Day Detection

**Status:** Approved, ready for plan
**Date:** 2026-06-05
**Owner:** Sergei
**Related:** [Jarvis Phase 1](2026-06-01-jarvis-phase1-design.md), [iOS App Protocol v2](2026-05-31-ios-app-protocol-v2-design.md)

## Summary

Greg (the headless health-analyzer agent) gets three coordinated upgrades:

1. **Persona** — a full Gregory House voice, delivered verbatim through a new `house_quote` field on findings, with a safety valve that dampens sarcasm on critical-severity events.
2. **Use-cases** — two new modes: a *differential* triage when the user complains about how they feel, and a *sick-day early warning* trigger that fires sub-daily when infectious-illness signals stack up.
3. **Metrics** — four new scalar HealthKit fields (`wristTempDeviation`, `respiratoryRate`, `walkingHeartRateAverage`, `vo2max`) plus a workouts array, threaded end-to-end through the canonical shared protocol.

Greg stays headless. Jarvis remains the only user-facing voice but acts as a pass-through narrator for Greg, not a rewriter.

## Goals

- Make Greg's output feel like a character (not a JSON sieve) without compromising the structured-finding contract that Jarvis reasons over.
- Cut latency between an infectious-illness signal forming in the iOS data and a user seeing it: from up to 24 hours (next daily run) to minutes (event-driven).
- Give Greg enough data and a structured complaint-handling mode so that user questions like "почему я устал?" get a real differential, not a platitude.
- Keep every change additive at the schema layer (zod `.optional()`) so older iOS builds and the existing JSONL ride along without errors.

## Non-Goals

- Promoting Greg to a direct-DM agent that talks to the user without Jarvis in the middle. Routing stays a2a, voice ships through `house_quote`.
- Weekly trend report, pre-action readiness check, correlations engine, contextual annotation auto-ping. All explicitly deferred.
- New metrics beyond the four scalars + workouts (SpO2, audio exposure, mindful minutes, etc. — backlog).
- Any change to the OneCLI credential flow, container runtime, or a2a routing layer; the hop cap (5) and partition-by-source remain as-is.

## Architecture

```
iOS HealthKit
  └─► HealthHistory.swift queries [scalar types + workouts]
        └─► V2.HealthUpload.Body (Swift Codable mirror)
              └─► POST /api/health (existing http-handler)
                    ├─► appendHealthRows → raw.jsonl
                    └─► checkSickDayTrigger(rows)            ← NEW
                          └─► if 2-of-3 match:
                                writeSessionMessage(greg, {kind:'sick_day_check', signal:{...}})
                                wakeContainer(greg)
                                ─────────────────────────────────
Greg (per-session container, daily + on-demand)
  ├─► analyze.js --mode normal|differential|sick-day    ← NEW modes
  ├─► reads /tmp/<mode>.json (anomalies | hypotheses | sick-day report)
  ├─► writes finding {severity, metric, observation, suggestion,
  │                   house_quote,                    ← NEW field
  │                   mode: 'anomaly'|'differential'|'sick_day'}
  └─► send_message(to=jarvis, <finding>)
                                ─────────────────────────────────
Jarvis (user-facing)
  ├─► CLAUDE.md §9 expanded triggers (complaint patterns → a2a Greg, mode='differential')
  └─► on receiving Greg finding:
        render "Грег сказал: «<house_quote verbatim>»" + 1-line action layer
```

### Component boundaries

- **iOS app** owns HealthKit query expansion and Codable mirror. Its only contract with the rest of the system is `V2.HealthUpload.Body`.
- **Shared protocol** (`shared/ios-app-protocol/v2.ts`) is the single source of truth for the upload schema. Both sides depend on it through generated TS and a hand-mirrored Swift file kept in sync via the existing fixture round-trip test.
- **Host trigger module** (`src/modules/health-trigger/sick-day.ts`) is the only host-side code that reads health rows for analytical purposes. It does not parse anomalies; it runs three simple thresholds and decides whether to wake Greg.
- **`analyze.js`** does all numeric work. Greg (the LLM) never reads `raw.jsonl` directly — it interprets `/tmp/<mode>.json` only. This invariant is already in `health-analyzer/CLAUDE.md` and stays.
- **Greg CLAUDE.md** owns persona, mode dispatch, and finding shape.
- **Jarvis CLAUDE.md** owns trigger recognition (which user messages route to Greg) and the verbatim-quote rendering rule.

## Detailed Design

### 1. Persona: voice channel

Findings get one new field:

```ts
house_quote: string  // 1-2 sentences, in character. Inner quotes ASCII OK;
                     // Jarvis wraps the whole thing in « » when rendering.
```

Greg generates `house_quote` per finding. Jarvis CLAUDE.md gets a rule: when relaying a Greg finding, render exactly as `Грег сказал: «<house_quote>»` followed by at most one line of Jarvis's own action layer (a reminder to drink water, a scheduled task offer, a recheck offer).

Jarvis does not paraphrase, summarize, or rewrite the quote. The structured fields (`observation`, `suggestion`, `severity`, `metric`, `window`) remain the basis for Jarvis's own decisions about what to do — schedule a follow-up, escalate, ask a clarifying question — but their text is never shown to the user. The user sees Greg's voice plus Jarvis's actions, never Jarvis-as-Greg.

**Tone:** Full House. Sardonic, "everybody lies" framing, distrustful of self-reports when objective metrics disagree. Differential-style reasoning ("two working hypotheses, pick one"). House idioms when natural; no forced pop culture.

**Safety valve:** when `severity === 'critical'`, the prompt instructs Greg to dampen sarcasm to ≤30% of usual and front-load actionable instruction. This is canon — House gets serious when life is on the line. Encoded as a rule in `health-analyzer/CLAUDE.md`.

**Medical disclaimer:** stays in place. Greg phrases findings as "ставлю на …" / "два варианта — выбирай" / "стоит проверить", never as "у тебя X". The persona does not override the existing disclaimer paragraph.

### 2. Use-case A: Differential on a complaint

**Trigger.** Jarvis CLAUDE.md §9 is extended with complaint patterns: "устал", "болит голова", "не выспался", "разбит", "как я?", "что со мной?" and similar. On match, Jarvis tells the user "Сейчас спрошу Грега" and sends a2a to Greg with content shape:

```json
{ "complaint": "<user's raw words>", "window_days": 14 }
```

Default window is 14 days. Jarvis may pick 7 for acute complaints if it judges so; the prompt allows discretion.

**Greg flow.**
1. Runs `bun analyze.js --mode differential --complaint "<text>" --window 14 --out /tmp/diff.json`.
2. `analyze.js` does the numeric work: per-metric deviation over the window relative to a longer baseline, ranking by *deviation magnitude × persistence × directional match to complaint*. Maps complaints to candidate metric sets:
   - "устал" / "разбит" → recovery, hrv, sleepHours, restingHeartRate, accumulated workout load
   - "не выспался" → sleepHours, sleep-quality proxies (hrv during sleep window, respiratoryRate if present)
   - "болит голова" → sleepHours, accumulated load, wristTempDeviation, hydration (no data → noted absent)
   - generic ("как я?", "что со мной?") → recovery composite + top-3 absolute deviations across all metrics
3. Output is a top-5 candidate list with numbers (current value, baseline, % deviation, persistence days).
4. Greg interprets: forms 2-3 ranked hypotheses, each with a one-line statement, the supporting evidence (which numbers, which window), and a `next_check` — what to look at next or change.
5. Sends finding back to Jarvis with `mode: "differential"`, `hypotheses: [{rank, statement, evidence, next_check}]`, and `house_quote` summarising the differential in House voice.

**Terminality.** Greg replies exactly once. The hop cap (5) and "терминально" rule in Greg's CLAUDE.md already prevent ping-pong. Jarvis does not auto-recheck on the same complaint without a new user signal.

### 3. Use-case B: Sick-day early warning

**Signal.** A composite of three thresholds against the user's own 14-day rolling baseline:
- `restingHeartRate` is ≥ 7% above the 14-day median, **and/or**
- `wristTempDeviation` is ≥ +0.4°C, **and/or**
- `hrv` is ≥ 15% below the 14-day median.

At least **2 of 3** must match in the same day's row to fire. Exactly 1 logs as `info` and does nothing. The thresholds and the 2-of-3 rule are tunable constants in one place in `sick-day.ts`.

**Trigger placement.** Host-side, event-driven. In `src/channels/ios-app/v2/http-handler.ts`, after `appendHealthRows` succeeds, call `checkSickDayTrigger(rows)`. If it returns a signal, the trigger module writes a one-shot wake message into Greg's session inbound DB:

```json
{ "kind": "sick_day_check",
  "signal": { "rhr_delta_pct": 9.2, "temp_delta_c": 0.5, "hrv_delta_pct": null } }
```

and calls `wakeContainer(gregSession)`. This bypasses Greg's daily schedule entirely — the message lands on the next poll iteration, and a fresh container is spawned if none is up.

**Greg flow.**
1. On waking with `kind: sick_day_check`, runs `bun analyze.js --mode sick-day --out /tmp/sick.json`. The detailed run looks at all available metrics for the last 5 days, not just the three that fired the trigger.
2. Marks `severity: 'critical'` automatically — this engages the safety valve from §1, so `house_quote` is in serious-House mode, not snark mode.
3. Sends finding to Jarvis with `mode: "sick_day"`, plus a `next_actions` array (rest, hydration, take temperature manually, etc.) and a `house_quote` in serious tone.

**Anti-spam.** After the first sick-day finding, Greg writes a `suppress sick_day until <ISO+24h>` entry in `memories/state.md`. The host trigger still fires within that window (event-driven, can't easily check state.md without coupling), but Greg on waking checks the suppress and short-circuits without sending a new finding — except if the signal *worsens* (one of the deltas crosses a "worsening" secondary threshold). If the user replies "болею" / "болел" via Jarvis, Jarvis sends an `acknowledged` a2a, Greg extends suppression until an explicit "уже ок".

### 4. Metrics expansion

**Shared protocol (`shared/ios-app-protocol/v2.ts`).** Extend `HealthUploadDay`:

```ts
export const Workout = z.object({
  type: z.string(),                              // HKWorkoutActivityType raw name
  startISO: z.string(),                          // ISO timestamp
  durationMin: z.number().nonnegative(),
  energyKcal: z.number().nonnegative().optional(),
  avgHR: z.number().int().nonnegative().optional(),
  maxHR: z.number().int().nonnegative().optional(),
});

export const HealthUploadDay = z.object({
  // existing fields unchanged...
  wristTempDeviation: z.number().optional(),     // °C, signed; baseline is HealthKit's own
  respiratoryRate: z.number().nonnegative().optional(),
  walkingHeartRateAverage: z.number().int().nonnegative().optional(),
  vo2max: z.number().nonnegative().optional(),
  workouts: z.array(Workout).optional(),
});
```

Note: `wristTempDeviation` uses plain `z.number()` (not `nonnegative`) because the value is signed — HealthKit reports it as a deviation from the user's own sleeping wrist-temp baseline, not an absolute temperature.

**Fixture (`fixtures/health/upload.json`).** Add realistic example values for every new field so the round-trip test exercises them.

**Swift mirror (`ios/JarvisApp/Sources/JarvisApp/Protocol/V2.swift`).** Append `V2.HealthUpload.Workout` struct and extend `V2.HealthUpload.Day` with the four new optional scalar fields plus `workouts: [Workout]?`. Codable conformance + decoded round-trip test against the same fixture.

**HealthKit query expansion (`ios/JarvisApp/Sources/JarvisApp/Services/HealthHistory.swift`).** Add `HKQuery`s for each of:
- `HKQuantityTypeIdentifier.appleSleepingWristTemperature` (S8+; quietly absent on older watches)
- `HKQuantityTypeIdentifier.respiratoryRate` (sleep-window aggregate)
- `HKQuantityTypeIdentifier.walkingHeartRateAverage` (daily aggregate)
- `HKQuantityTypeIdentifier.vo2Max` (most recent daily reading)
- `HKWorkoutType.workoutType()` (all workouts that started in the day; aggregate per workout, not per sample)

Each query, when the data type is unavailable or permission is denied, leaves the corresponding field on the Day unset (`nil`). Zod `.optional()` on the host catches that without erroring.

**Info.plist / permissions.** The HealthKit usage description already exists. The new types need to be added to the `HKObjectType` set passed to `requestAuthorization`. iOS will re-prompt once after the app update — expected and fine.

**Detector (`groups/health-analyzer/scripts/analyze.js`).**
- Add the four new scalars to the `METRICS` list.
- Concern directions: `wristTempDeviation` → up is bad, `respiratoryRate` → up is bad, `walkingHeartRateAverage` → up is bad, `vo2max` → down is bad. Update `CONCERN_UP` / `CONCERN_DOWN` sets.
- Extend the recovery composite: add `wristTempDeviation` with negative sign (deviation up → recovery score down). Keep the "≥2 of N components present" rule, now over 4 components instead of 3.
- `workouts` is not a scalar and is **not** fed to the anomaly detector. It is used only as **context** in the differential mode — e.g. when ranking "устал" hypotheses, accumulated workout duration/energy over the window is one of the evidence inputs.
- Add `--mode normal|differential|sick-day` flag dispatcher. Default `normal` preserves today's behaviour (daily anomaly sweep). The two new modes produce their own output JSON shapes documented at the top of `analyze.js`.

## Data Flow

| Event | Path |
|---|---|
| iOS daily background upload | HealthKit → HealthHistory.swift → V2.HealthUpload.Body POST → http-handler → appendHealthRows + checkSickDayTrigger → (maybe) wake Greg with `sick_day_check` |
| Daily 09:00 UTC | scheduled wake → Greg → `analyze.js --mode normal` → findings → Jarvis → daily DM if anything new |
| User: "устал" / "что со мной?" | Jarvis recognises complaint → a2a Greg `{complaint, window_days}` → Greg `--mode differential` → finding with hypotheses → Jarvis renders `Грег сказал: «...»` + action |
| Sick-day trigger fires | Host writes `sick_day_check` to Greg inbound → Greg `--mode sick-day` → critical finding → Jarvis renders serious quote + immediate action |

## Errors & Edge Cases

- **HealthKit permission denied for new types** — Swift omits the field; zod accepts; detector skips that metric in computations. No crash, no warning to user.
- **Older iOS build uploading old schema** — zod `.optional()` accepts missing fields; recovery composite degrades to 3 components; new mode detectors gate on `typeof v === 'number'` and skip.
- **Sick-day false positive** — anti-spam suppress 24h, user can 👎 → permanent suppress for that signal combination (Greg adds to suppress rules in `state.md` as it already does for daily findings).
- **Greg container down when host trigger fires** — `writeSessionMessage` persists the row; next wake (the natural one or via host trigger retry on next ingest) picks it up. No loss.
- **Differential called with empty raw.jsonl** — Greg returns a finding with `mode: differential, hypotheses: []`, `house_quote: "Без данных я не Хаус, я гадалка. Дай неделю набрать."` Jarvis relays.
- **`house_quote` missing on finding** (Greg model misbehaviour) — Jarvis falls back to rendering the `observation` field verbatim with the same `Грег сказал: «...»` prefix, and logs a warning. Better degraded than silent.

## Testing

- **Schema round-trip** — extend `shared/ios-app-protocol/fixtures.test.ts` with the new fields and Workout array.
- **Swift Codable** — round-trip the same fixture in Swift; assert equality with TS-side encoding.
- **`analyze.js` unit tests** — table-driven cases for the sick-day detector: only RHR fires, only temp fires, only HRV fires (each should NOT trigger), 2-of-3 (should trigger), 3-of-3 (should trigger with stronger severity if we add a tier). Same approach for differential mapping: for each complaint pattern, assert the candidate-metric set is correct.
- **Host trigger** — new `src/modules/health-trigger/sick-day.test.ts`: mock a `raw.jsonl` state, run the trigger, assert `writeSessionMessage` is called with the expected payload shape on match and is NOT called on single-signal or no-signal cases.
- **Greg integration smoke test** — manual: inject a synthetic raw.jsonl row that triggers sick-day, watch the host log line, watch Greg wake and produce a critical finding, watch Jarvis render `Грег сказал: «...»`.

## Rollout

Six commits, each independently deployable on `main` (direct push). Each commit ships with its tests.

1. **Persona text rules** — `groups/jarvis/CLAUDE.md` verbatim rule, `groups/health-analyzer/CLAUDE.md` House persona + `house_quote` field on finding contract. Text only, no code.
2. **Differential mode** — `analyze.js --mode differential`, Greg differential handler section, Jarvis complaint-pattern triggers. Works immediately on existing metrics.
3. **Schema expansion** — `v2.ts` + `fixtures/health/upload.json` + Swift `V2.swift` + tests. Host accepts new shape; no behaviour change.
4. **iOS HealthKit query expansion** — `HealthHistory.swift` plus the Info.plist `HKObjectType` set update. Requires app rebuild + permission re-prompt on user's device.
5. **Sick-day detector** — `analyze.js --mode sick-day`. Runs against whatever the user has; gets full power once step 4 is live on the device.
6. **Host trigger** — `src/modules/health-trigger/sick-day.ts` + integration in `src/channels/ios-app/v2/http-handler.ts`. Closes the loop.

Out of scope for this spec, deferred to backlog:
- Weekly trend report
- Pre-action readiness check
- Correlations engine
- Contextual annotation (Jarvis auto-pings Greg on symptom mention in normal chat)
- Blood oxygen, audio exposure, mindful minutes metrics
