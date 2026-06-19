# Agent Factuality Architecture — Design

**Date:** 2026-06-17
**Status:** Approved (design), pending implementation plan
**Supersedes:** [2026-06-17-verification-gate-design.md](2026-06-17-verification-gate-design.md) (narrow LLM-judge view — now one layer of this).
**Subsumes:** [2026-06-17-factual-discipline-design.md](2026-06-17-factual-discipline-design.md) (the prompt rule — now Layer 0 "first line", not the enforcement).
**Research basis:** deep-research 2026-06-17 (28 sources, 25 adversarially-verified claims) — see memory `reference-hallucination-mitigation`.

## Problem

Agents fabricate facts and don't re-check, even on "minor" facts. The deployed prompt-only factual-discipline rule was **ignored on its first real test**: asked the Bybit USDT withdrawal fee, Scrooge produced a confident fabricated fee table (no source, no hedge) despite the rule being loaded. A prompt rule is soft — the model rationalizes past it. Verified by inspecting the reborn session's transcript: rule present in context, ignored anyway.

**Expanded threat model (key reframe):** the target is **ALL factual claims, not only "action-relevant" ones.** A fabricated fact — even in a casual reply — propagates into the agent's later reasoning and plans. So narrowing to high-stakes facts is insufficient.

## Honest guarantee & the structural limit

Research established a **hard, unavoidable trade-off** (structural result, not a literature gap):

- Methods needing **no external ground-truth** (SelfCheckGPT, semantic entropy, Chain-of-Verification) detect only **confabulations** — facts where re-sampling diverges (the model is unsure). They are **proven to MISS confident-but-consistently-wrong facts.**
- Methods that **catch confident-but-wrong** facts (FActScore, AlignScore, NeMo self-check-facts, provenance validators) all **require retrieved external evidence** — they cannot judge open-domain facts with no knowledge base.

**Coverage map (what is catchable):**

| Fact type | Model unsure (confabulation) | Confidently wrong |
|-----------|------------------------------|-------------------|
| Tool-derived (source visible this turn) | ✅ provenance | ✅ provenance |
| Parametric, verifiable (web/API exists) | ✅ force lookup | ✅ force lookup |
| Parametric, no source | ✅ CoVe / sampling | ❌ **irreducible without external truth** |

**The one uncatchable cell** = confident wrong about an open-domain fact with no available source. The only cure is to **give it a source** (tool-shaping) so the fact leaves that cell.

**Achievable guarantee:** *no tool-derived claim and no confabulated claim ships without an independent, harness-enforced check; "doesn't re-check" is closed by forced isolated re-verification.* **Not** *"always factually correct."* Confident-wrong open-domain-without-source is the residual, shrunk (not eliminated) by adding lookup tools.

## Goals / Non-goals

**Goals:** non-bypassable (enforced in the harness, outside the agent's prompt); covers all fact *types* (per the map, with the stated residual); forces re-verification rather than only hedging; cheap enough to run every turn at NanoClaw volume.

**Non-goals:** a truth oracle; perfect open-domain coverage; trusting the model's own stated confidence or token-logprobs (research: unreliable / not exposed by the SDK); gating non-factual content (chat, opinion, acknowledgements).

## Why "prompt to force tool use" is not enough

Hardening the prompt to "always call tools" is the same soft mistake — the model still decides what needs a tool and skips when "sure" (Scrooge already proved it). Three strengths of "force tool use":
1. **Prompt "must call tools"** — soft, model decides, bypassable. Keep as a cheap nudge only.
2. **API `tool_choice` forcing** — structural (guarantees a tool *runs*), but doesn't guarantee the right tool, that the final text *uses* it, and it breaks trivial turns. Insufficient alone. (SDK per-turn exposure: confirm at plan time.)
3. **Harness provenance gate** — checks delivered facts actually trace to a tool output this turn; blocks otherwise. The non-bypassable version. **This is the enforcement.**

## Architecture — layered harness output-guard

Everything runs in `container/agent-runner/src/` (Bun), at the **outbound dispatch** point, **outside the agent's prompt** → the agent cannot skip it. The agent's only path to the user is through the gate.

```
SDK turn streams events
  │ poll-loop tracks tool_use / tool_result this turn → grounding set
  ▼
complete <message> block
  │
[L0] Prompt nudge already applied (raises tool-call rate; cached, ~free)
  ▼
[L2] Claim detector (deterministic, 0-token): factual claims present?
  │ none → dispatch (fast path: greetings, opinion, acks)
  │ present ▼
[L3] Provenance check
  │  structured value (number/currency/date) → DETERMINISTIC match vs this-turn tool outputs (0-token)
  │  fuzzy/prose claim → Haiku entailment vs this-turn tool outputs
  │  all grounded → dispatch
  │  ungrounded ▼
[L5] Parametric branch (no tool source this turn)
  │  verifiable (web/API tool exists) → force lookup → re-enter L3
  │  not cheaply verifiable → factored CoVe isolated re-check
  │       confirms → dispatch ; diverges/uncertain → hedge
  ▼
[L7] Enforcement: block + regenerate with findings (cap N=2 → fallback hedge/strip)
  ▼
writeMessageOut → host delivery
```

### Layers

- **L0 — Prompt hardening (first line, ~free).** Keep the factual-discipline rule + a tool-grounding nudge ("ground factual claims in a tool/script this turn; no source → say you're unsure; don't pad lists beyond what you know"). Part of the cached system prompt → near-zero marginal tokens. Raises baseline tool-call rate; NOT the enforcement.

- **L1 — Tool-shaping (the ENABLING layer, built first).** Per-agent skills/scripts for each agent's core recurring fact domains, returning **distilled** output (a number, not a dump). This is what converts facts from "parametric/uncatchable" to "tool-derived/checkable" AND makes the gate cheap (small evidence; often deterministically matchable). Examples: Scrooge → Bybit fee/balance script (returns "$0.80"); Greg → health.db (exists). Map each agent's top fact types → script them. Open-domain long tail → a shared web-search tool (Phase 3).

- **L2 — Claim detector (deterministic, 0-token).** Scan the `<message>` for factual/quantitative assertions (currency, %, numbers+units, dates, named claims). Subtract values already in the user's own inbound (avoid false positives). No signals → fast path, gate is silent. High recall (false positives only cost a check).

- **L3 — Provenance check.** For each detected claim, is it supported by this turn's tool outputs (the per-turn ground truth, already observable to the harness)? **Structured values → deterministic numeric/string match (0-token, ≈free).** Fuzzy/prose → Haiku (`claude-haiku-4-5-20251001`) entailment via the existing host credential proxy. This is the only layer that catches *confident-wrong* without a global KB.

- **L5 — Parametric branch (CoVe + forced lookup).** For claims with no tool source this turn: if a lookup tool exists (web-search/API), force it → claim becomes tool-derived → re-enter L3. Else factored Chain-of-Verification: re-ask the atomic claim in an *isolated* prompt that excludes the draft (prevents the model copying its own hallucination — research: ~17% longform vs ~70% isolated accuracy). Divergence/uncertainty → hedge. (Sampling/semantic-entropy triage optional, to pick which claims escalate and bound cost.)

- **L7 — Enforcement.** On ungrounded claims: return findings to the agent, regenerate (continue the SDK conversation). Cap at N=2; on cap, strip/hedge the flagged claim and dispatch so the user always gets a reply. Final output is the agent's own words.

- **Non-bypassability** comes from L2–L7 running in the runner, gating `writeMessageOut`, not in the agent's prompt.

## Token / cost economics

- **L0 prompt:** cached system prompt → ~free ongoing.
- **L2 detector:** deterministic → 0 tokens. Most chat/ack turns exit here.
- **L3 deterministic match:** 0 tokens (structured tool-derived facts — the common case once L1 scripts exist).
- **L3 Haiku judge:** only on fuzzy fact-messages; ~1–4k tokens on a cheap model.
- **Dominant cost is the verification *behavior*, not the gate:** extra tool calls + source content entering the main-model context + regeneration on catch. Distilled script output (L1) minimizes this and enables the 0-token deterministic path. Web-page-sized tool outputs on the main model are the real eaters → truncate evidence; prefer scripts over web where a domain is codifiable.
- **NanoClaw volume** (5 agents, few msgs/day): absolute cost small. Fact-heavy turn ≈ 1×→2–4× tokens (verification + possible regen); chat turn ≈ 1×.
- **Honest reframe:** the gate is cheap; *actually verifying* costs the work fabrication used to skip. Scripts (L1) make most high-value facts both correct and ≈free to gate.

## Platform constraints

- Claude Agent SDK (closed API) does **not** expose hidden states / token logprobs → Semantic Entropy Probes and logprob-classifier detectors are **out**; usable model-internal options are sampling-based (multiple calls) or judge-based. Don't trust verbalized self-confidence (research: unreliable).
- Runtime is Bun; tests via `bun:test`. Judge calls reuse the host credential proxy (`ANTHROPIC_BASE_URL` pre-set).
- **Streaming change (main risk):** today complete `<message>` blocks dispatch mid-stream; the gate requires buffering a block until it passes. Must preserve the existing watchdog/abort/fallback paths in `poll-loop.ts`.

## Phasing & rollout

**Phase 1 — Cheap core (highest impact, ≈free gate).** L0 prompt nudge + L1 tool-shaping for the pilot agent + L2 detector + **deterministic** L3 (numeric/currency/date match vs tool output) + L7 block/regenerate. Pilot on **Scrooge** with a Bybit-fee script: re-run the fee probe → must use the script or hedge, never fabricate. Covers structured/quantitative tool-derivable facts.

**Phase 2 — Prose fact analysis (committed next increment — coverage moves from numbers to facts).** This is where "fact-checking" actually lands; Phase 1 numbers are only the foundation. Reuses the Phase 1 skeleton (grounding set, claim detect, gate-at-result, regenerate, flag) and adds:
- **Judge-vs-tool-output (Haiku entailment):** for prose that *should* trace to a tool the agent ran this turn — verify the claim against that output; catches confident-wrong. Plus forced-tool enforcement (a checkable claim with no tool call → block).
- Extend L1 scripts to every agent's core domains; roll the gate to all 5.

**Phase 3 — Parametric prose + residual.** For prose with no this-turn source:
- **Factored CoVe is the PRIMARY mechanism, not the judge.** Re-asks the atomic claim in an isolated prompt: confabulated prose flips (→ hedge), true facts survive (→ keep).
- **Shared web-search tool** so high-stakes parametric prose becomes verifiable (→ tool-derived → judge).
- **Sampling triage** to bound cost (which claims escalate).
- Residual = confident-wrong open-domain prose with no source → hedge/abstain (structurally irreducible).

**Prose design constraint (load-bearing).** NEVER gate prose by "must be grounded in this-turn output" alone — that flags *all* parametric prose as ungrounded, including true common knowledge ("Париж — столица Франции"), and forces needless hedging/lookup (the useless over-cautious agent). Prose correctness = CoVe (catch the unsure) + judge (verify the tool-derived) + web-search (look up the high-stakes), never blanket tool-grounding. (Numbers in Phase 1 don't have this problem — a number either matches a source or is genuinely suspect.)

**Flag:** per-agent config `factuality_gate: off|deterministic|full` (default off), so rollout is staged and reversible.

## Verification

- **Unit (bun:test):** detector (signal/no-signal, user-number subtraction); deterministic provenance matcher; Haiku judge output parsing; enforcement retry+cap+fallback; CoVe isolated-prompt construction.
- **Integration (bun:test):** fabricated number + no tool → block → regenerate → hedge/real; grounded value matching tool output → passes 0-token; judge error → fail-closed-soft (deliver + blanket hedge).
- **Live probe:** Scrooge Bybit fee after Phase 1 — must use the script or hedge, never fabricate. Greg health numbers still pass cheaply (already tool-grounded).
- No automated test asserts open-domain truth (impossible) — that residual is documented, not tested.

## Open defaults (flagged for review)

- Retry cap N=2.
- Judge model Haiku (vs Sonnet for hard claims).
- Fail-mode = fail-closed-soft (deliver + blanket hedge on judge outage) vs hard-block.
- Pilot = Scrooge; Phase 1 deterministic-only before any LLM judge.
- Detector scope: quantitative/structured first (Phase 1), prose claims in Phase 2.
- Whether to use API `tool_choice` as an L1 assist (confirm SDK exposure first).

## References

- Research + sources: memory `reference-hallucination-mitigation`; key papers — Chain-of-Verification (arxiv 2309.11495), SelfCheckGPT (2303.08896), Semantic Entropy (Nature s41586-024-07421-0), FActScore (2305.14251), NeMo Guardrails / Guardrails AI provenance docs.
- Pipeline hooks: `container/agent-runner/src/poll-loop.ts` (dispatch + tool_use events), `formatter.ts` (`<message>` parsing), `providers/claude.ts` (SDK turn), `db/messages-out.ts` (`writeMessageOut`).
