# Factuality Gate Phase 3 — Parametric Prose (CoVe → web) + Level Config — Design

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation plan
**Predecessors:** [Phase 1 numbers](2026-06-17-factuality-architecture-design.md), [Phase 2 prose](2026-06-19-factuality-phase2-prose-design.md)

## Problem

The factuality gate (harness-enforced, non-bypass) today catches two things in an agent's `<message>` output:
- **Phase 1 (numbers):** numeric claims must trace to this turn's tool output or the user's message.
- **Phase 2 (tool-prose):** a Haiku judge flags prose claims that *draw on this turn's tool output* but aren't supported by it.

Both only police facts that **should derive from this turn's tools**. Neither catches the agent stating a confident **parametric/world fact** (not from any tool) that is wrong — or simply **not re-verifying** a claim it could check. That confident-but-unchecked assertion is exactly the user's core complaint ("выдумывать … или не перепроверять"), and per the [hallucination research](../../../.claude/projects/-Users-serg-git-nanoclaw/memory/reference_hallucination_mitigation.md) it is structurally the hardest case: model-internal methods miss confident-consistent-wrong; only external evidence (web) gives ground truth.

Separately, the current config knob is a flat string `off|deterministic|full` — it doesn't express that the checks are an ordinal ladder, and has no slot for a third tier.

## Goal

1. Replace the string knob with an **ordinal integer level 0–3** (cumulative), giving a deterministic, extensible way to dial verification depth per agent.
2. Add **Level 3 = all-prose verification** for parametric/world claims: cheap **CoVe** triage on every checkable claim, escalating only the narrow **action-relevant ∧ uncertain** slice to a harness-side **web_search** check, reusing the existing bounce/hedge machinery.

## Decisions (locked in brainstorming)

| Question | Decision |
|----------|----------|
| Config representation | Ordinal **integer level 0–3**, cumulative (level N runs every check ≤ N). New column `factuality_level`, backfilled from old `factuality_gate`. |
| L3 mechanism | **Hybrid: CoVe → web.** CoVe (factored, isolated re-verification) as cheap triage; escalate to web only where warranted. |
| Web escalation gate | A claim escalates to web **iff `action_relevant AND CoVe ∈ {uncertain, contradicted}`**. Non-action claims rely on CoVe alone (hedge). |
| Web source | **Harness-side Claude + Anthropic `web_search` server tool**, via the credential proxy (same architecture as the Phase-2 judge — NOT the agent's tools, so it stays non-bypass). |
| Verdict → action | Reuse Phase-1/2 bounce: refuted/contradicted → correction bounce to the agent (retry cap) → on cap, deliver with a hedge. |
| Failure posture | **Fail-soft:** any extraction/CoVe/web error never hard-blocks delivery (mirrors the Phase-2 judge). |

## Level model

| Level | Name | Runs |
|---|---|---|
| 0 | off | nothing — **byte-identical to today's `off` branch** |
| 1 | numbers | Phase-1 numeric provenance |
| 2 | tool-prose | + Phase-2 Haiku judge on tool-derived prose |
| 3 | all-prose | + Phase-3: claim extraction → CoVe triage → (action ∧ uncertain) web verify |

Cumulative: a level-3 agent runs levels 1+2+3. Levels 0–2 are the **current code unchanged** — Phase 3 only adds the `level>=3` branch plus the string→int representation swap.

## Background — current code (exact integration points)

Container (`container/agent-runner/src/`):
- `verification/numbers.ts` (`extractDataNumbers`, `normalizeNumber`), `verification/gate.ts` (`checkProvenance`), `verification/poll-gate.ts` (`gateOutboundText`) — Phase 1.
- `verification/judge.ts` (`buildJudgePrompt`, `parseJudgeVerdict`, `judgeProse`), `verification/prose-trigger.ts` (`shouldJudgeProse`) — Phase 2.
- `config.ts:13` `export type FactualityGate = 'off'|'deterministic'|'full'`; `parseFactualityGate` (16); `PollLoopConfig.factualityGate` (29).
- `poll-loop.ts`: `gateMode`/`gateOn` (291–292); per-turn `grounding: Set<string>` + `groundingText: string[]` (8KB cap, Phase 2); `processQuery(..., gateOn, grounding, gateMode, groundingText)` (322, sig 497–500); `factualityRetries`/`proseRetries` (641–642); result-event gate (~845–851).
- `providers/types.ts` (`tool_use_end.output?`), `providers/claude.ts` (`extractToolResultText`).

Host (`src/`):
- `db/migrations/019-factuality-gate.ts` (current `factuality_gate TEXT DEFAULT 'off'`).
- `types.ts:28` `factuality_gate: string`; `container-config.ts:46,67` `factualityGate`; `db/container-configs.ts:13,78` SCALAR_COLUMNS; `backfill-container-configs.ts:68`.

## Component 1 — Level config (string → ordinal int)

**Host:**
- New migration `0XX-factuality-level.ts`: `ALTER TABLE container_configs ADD COLUMN factuality_level INTEGER NOT NULL DEFAULT 0`, then backfill `UPDATE container_configs SET factuality_level = CASE factuality_gate WHEN 'deterministic' THEN 1 WHEN 'full' THEN 2 ELSE 0 END`. **Behavior is unchanged on migrate** (scrooge `full`→2, the four `deterministic`→1, rest 0). The old `factuality_gate` column is left in place but **deprecated/unused** (no SQLite DROP COLUMN — avoid the rewrite risk; remove in a later cleanup).
- `types.ts`: add `factuality_level: number`. `container-config.ts`: `factualityLevel?: number` + `configFromDb` reads `row.factuality_level ?? 0`. `db/container-configs.ts`: add `'factuality_level'` to SCALAR_COLUMNS + the update Pick. `backfill-container-configs.ts`: `factuality_level: 0`. Stop materializing the old `factualityGate` into container.json; materialize `factualityLevel`.

**Container:**
- `config.ts`: replace `FactualityGate` with `export type FactualityLevel = 0|1|2|3` + `parseFactualityLevel(raw): FactualityLevel` (clamp to 0–3, default 0). `PollLoopConfig.factualityLevel: FactualityLevel`.
- `poll-loop.ts`: `const level = config.factualityLevel ?? 0; const gateOn = level >= 1;`. Replace the `gateMode === 'full'` checks with `level >= 2` (Phase-2 prose) and add `level >= 3` (Phase-3). `processQuery` takes `level` instead of `gateMode` (thread through).

> Migration note: keep a one-release compatibility read — if `factuality_level` is absent (older container.json), fall back to mapping the legacy `factualityGate` string. Drop after the next deploy.

## Component 2 — Level-3 pipeline

New files under `container/agent-runner/src/verification/`:
- `claims.ts` — claim extraction.
- `cove.ts` — factored CoVe triage.
- `web-verify.ts` — harness-side web_search verification.
- `level3.ts` — orchestrates extract → CoVe → escalate → verdicts (the single entry the poll-loop calls).

Runs in `poll-loop.ts` at the `result` event, **after** the Phase-2 prose judge, guarded `if (level >= 3 && !numberBounced && !proseBounced)`, on each `<message>` block's text.

### 2a. Claim extraction (`claims.ts`)
One Haiku call (raw Messages API via the proxy, same auth branching as `judge.ts`). Input: the reply text + this turn's `groundingText` (tool outputs). Output JSON: `{ claims: [{ claim: string, action_relevant: boolean }] }`.
- Extract only **checkable factual assertions**. Skip: opinions/subjective, hedged statements, and claims **already supported by this turn's tool output** (Phase 2 owns those — avoid double-work).
- `action_relevant = true` for health / money / schedule / irreversible-action claims (the factual-discipline threshold).
- Cap: keep at most `L3_MAX_CLAIMS` (default 6); log if truncated.

### 2b. CoVe triage (`cove.ts`)
For each extracted claim, an **isolated** Haiku call: prompt contains ONLY the claim (no original-answer framing) → "Is this independently true? supported | uncertain | contradicted, one line why." Factored isolation is the mechanism — re-checking in a fresh context surfaces confabulations the model wouldn't catch re-reading its own answer.
- One call per claim (faithful to "factored"), capped at `L3_MAX_CLAIMS`.
- Returns `{ claim, verdict: 'supported'|'uncertain'|'contradicted', why }[]`.

### 2c. Web escalation (`web-verify.ts`)
For claims where `action_relevant && verdict ∈ {uncertain, contradicted}` (cap `L3_MAX_WEB`, default 3): a harness-side **Claude + `web_search` server tool** Messages call ("verify this claim against current sources: supported | refuted + 1-line evidence"). Returns `{ claim, web: 'supported'|'refuted', evidence }`.
- **Preflight (`web-verify.ts` self-check):** on first use per process, a throwaway probe confirms the proxy/account serves the `web_search` tool. If unavailable → `web-verify` no-ops (returns `unavailable`), the pipeline degrades to **CoVe-only**, and a warning logs once. No hard failure.

### 2d. Verdict → action (`level3.ts` + poll-loop)
Collect per-claim final verdicts:
- web `refuted` → **fail** (strongest signal).
- CoVe `contradicted`, non-action (no web escalation) → **fail** (hedge-worthy).
- web `supported`, or CoVe `supported`, or non-action CoVe `uncertain` → **pass**.
- **Degrade path** (web `unavailable`/error, but the claim *was* action-relevant ∧ uncertain/contradicted): treat as **fail** → hedge. We don't silently pass an action-relevant claim we flagged but couldn't verify; we soften/flag it. (Non-action `uncertain` still passes — that's the cost/scope threshold.)

If any claim **fails**: bounce a correction to the agent (reuse the Phase-1/2 flag-pattern — `query.push` a message naming the failed claim(s) + why, set `resultReceived=false`, **no `break`**), bounded by a dedicated `l3Retries` cap (default 2, separate from `factualityRetries`/`proseRetries` — the 2026-06-23 lesson: shared caps starve each other). On cap reached: deliver with a **hedge** suffix (soften/flag the unverified claim), consistent with Phases 1–2.

## Component 3 — Caps, observability, safety

- **Hard ceilings:** `L3_MAX_CLAIMS=6`, `L3_MAX_WEB=3` per turn. Bounds fan-out on a pathological reply.
- **Budgets:** `l3Retries` (default 2) separate from existing budgets.
- **Fires only** when `level>=3` AND the message has prose (reuse/extend `shouldJudgeProse`'s ≥6-letter-words gate) AND number/prose stages didn't already bounce. Number-only / short / no-prose turns skip the whole pipeline.
- **Timeouts:** every Messages call uses `AbortSignal.timeout` (reuse the judge's `JUDGE_TIMEOUT_MS`; web may need a longer `WEB_TIMEOUT_MS`, default 30s).
- **Observability:** one `Factuality L3:` log line per turn — claims extracted, CoVe verdict counts, web escalations, final action (pass/bounce/hedge) — mirrors the existing `Factuality judge:` line.
- **Fail-soft everywhere:** extraction/CoVe/web throw or time out → that claim is treated as `pass` (never hard-block); the turn delivers (with hedge only on a real fail). The gate must never silence a good answer on its own error.

## Component 4 — Testing + rollout

**Container (`bun:test`, fake-fetch injection like `judge.test.ts`):**
- `claims.test.ts` — parse extractor JSON; skips opinions/tool-derived; `action_relevant` tagging; claim cap.
- `cove.test.ts` — parse the three verdicts; isolated-prompt shape (no original answer leaked in).
- `web-verify.test.ts` — parse supported/refuted; preflight-unavailable → `unavailable` no-op; timeout → fail-soft.
- `level3.test.ts` — escalation gate (only action ∧ uncertain/contradicted hit web); verdict aggregation (web refuted → fail; CoVe contradicted non-action → fail; supported → pass); caps; fail-soft.
- `poll-loop` level branching — `level>=1/2/3` thresholds; L3 only after numbers+prose clean; bounce via flag-pattern (no `break`); `l3Retries` independent of other budgets; level 0 byte-identical to today's off.

**Host (`vitest`):**
- migration test — `factuality_level` backfill: `off→0`, `deterministic→1`, `full→2`, NULL→0; `configFromDb` reads the int.

**Pilot (live):** after migrate (behavior unchanged), flip **one** agent (scrooge) to level 3 via the q.ts/ncl path. Probe a parametric claim (e.g. a market/tax/world fact the agent would state from memory) and confirm CoVe catches an unchecked one and web refutes a wrong action-relevant one. Measure real per-turn cost + latency before any wider rollout.

**Deploy:** agent-runner is host-mounted → git pull + `pnpm run build` + restart (no image rebuild). Host migration runs on startup. web_search preflight gates the web stage. Per-agent level set via q.ts UPDATE + container restart (as in the Phase-1/2 rollout).

## Open risks

- **`web_search` availability** is the one hard external dependency. The preflight + CoVe-only degrade path means L3 still ships value (catches "didn't re-check") even if web is unavailable; the web slice lights up once the proxy/account serves the tool. The plan must verify availability early.
- **Structural limit (from research):** even with web, a confident claim that is *consistent and unverifiable-via-search* can pass. L3 narrows the gap; it does not close it. Honest scope: L3 targets unchecked + web-checkable action-relevant claims, not omniscience.
- **Cost/latency:** L3 adds 1 (extract) + ≤6 (CoVe) + ≤3 (web) Messages calls on qualifying turns. Deliberate per-agent rollout (pilot first) is the control; chatty agents (jarvis) stay at level ≤2 unless justified.

## Non-goals

- Verifying the user's own messages, or non-prose payloads (workout/cards/etc.).
- Closing the structural parametric-fact gap (impossible without a complete KB).
- Changing Phases 1–2 behavior (levels 0–2 are the current code, only the config representation changes).
- A logprob/uncertainty signal (the SDK doesn't expose logprobs — CoVe is the proxy for "uncertain").
- Exposing the level via `ncl` CLI (out of scope; q.ts UPDATE remains the rollout path, as today).
