# Factuality Gate — Phase 2 (Prose) Design

**Date:** 2026-06-19
**Status:** Approved (design), pending implementation plan
**Parent:** [2026-06-17-factuality-architecture-design.md](2026-06-17-factuality-architecture-design.md) — this details Phase 2.
**Builds on:** [2026-06-17-factuality-phase1.md](../plans/2026-06-17-factuality-phase1.md) — shipped + verified in production (Scrooge gate bounced a fabricated fee draft and forced a real Bybit API fetch).

## Problem

Phase 1 grounds **numbers** deterministically. It does nothing for **prose** claims — "TRC20 is the cheapest network", "your balance is concentrated in Tbank", "the analysis shows you're recovering". A misstated prose claim drawn from a tool the agent actually ran is a real failure mode (the agent fetched data, then mischaracterized it).

## Scope (load-bearing constraint)

Phase 2 checks **only prose that is tool-derived** — claims that draw on this turn's tool outputs — using an independent LLM judge (entailment vs the outputs). It deliberately does **NOT** judge pure parametric prose (general knowledge with no source this turn, e.g. "USDT is a stablecoin"). 

Why: a naive "all prose must be grounded in this-turn output" judge flags *true common knowledge* as unsupported and forces needless hedging — the useless over-cautious agent. Parametric-prose coverage (CoVe + forced web-search) is **Phase 3**, not this. Phase 2 honestly does not catch confident-wrong parametric prose with no source.

So Phase 2 catches: **"the agent ran a tool and then said something its output doesn't support."** High precision, no over-hedge.

## Decisions (locked)

| Question | Decision |
|----------|----------|
| Flag | **One flag.** `factualityGate: 'full'` = Phase 1 numbers + Phase 2 prose judge. `'deterministic'` stays numbers-only. `'off'` unchanged. |
| Judge | **Haiku** (`claude-haiku-4-5-20251001`) via the existing host credential proxy. One call per qualifying message. The judge self-decomposes the reply into claims (no separate atomic extractor). Defaults to *supported* when unsure (under-flag, not over-flag). |
| Trigger (cost gate) | Judge runs only when: gate is `'full'` **AND** this turn produced ≥1 tool output **AND** the `<message>` has prose (text beyond a trivial number/ack). Greetings, no-tool turns, pure-number turns → no judge call. |
| Grounding | Accumulate this turn's **raw tool-output text** (extends Phase 1, which kept only extracted numbers), capped (~8 KB) to bound judge cost. This is the judge's evidence. |
| On catch | Reuse the Phase 1 skeleton: bounce the unsupported claims back to the agent (`query.push`), cap `FACTUALITY_MAX_RETRIES=2`, deliver a hedged version on exhaustion. |
| Fail-mode | Judge errors/times out → fail-closed-soft: deliver, append a blanket "facts not verified" hedge. Never silently ship; never hard-break. |
| Pilot | Scrooge on `'full'`; verify with a finance question that yields prose over tool data. |

## Architecture

Phase 2 adds one layer to the existing gate; everything else (gate-at-result, bounce/regenerate, flag plumbing, streaming suppression when gate on) is already built and unchanged.

```
result event, gate on
  │
[Phase 1] deterministic number provenance over <message> blocks
  │  ungrounded number → bounce (existing)
  │  numbers OK ▼
[Phase 2] gate === 'full' AND tool-output-this-turn AND prose present?
  │  no  → deliver (existing)
  │  yes → Haiku judge(message, toolOutputText)
  │         unsupported tool-derived claim(s) → bounce with the claims (cap 2 → hedge)
  │         supported → deliver
  ▼
writeMessageOut
```

Phase 1 and Phase 2 share the bounce/retry budget — a turn bounced for numbers then prose counts toward the same cap.

## Components

1. **`verification/judge.ts`** — `judgeProse(messageText, toolOutputText): Promise<{unsupported: {claim, why}[]}>`. Makes a **raw Anthropic Messages API call** — a single `POST ${ANTHROPIC_BASE_URL}/v1/messages` with model `claude-haiku-4-5-20251001` (the container already has `ANTHROPIC_BASE_URL` set and a placeholder key the host proxy swaps for the real one). **Not** the Claude Agent SDK `query()` — that spawns a Claude Code subprocess and is far too heavy for a one-shot judge. Parses the structured JSON from the response text, returns unsupported claims. On any error (network, non-200, unparseable) throws → caller applies fail-closed-soft. Consult the `claude-api` skill for exact request shape at plan time. Prompt contract below.

2. **Grounding text accumulation** — in `poll-loop.ts`, alongside the Phase 1 number set, accumulate `groundingText: string[]` from `tool_use_end.output`, capped. Reset per turn (same points as the number set). Phase 1 already surfaces `tool_use_end.output`; Phase 2 just also keeps the raw text.

3. **Poll-loop `full` branch** — after Phase 1's number check passes, if the trigger holds, call `judgeProse`; on unsupported, bounce (reusing the same correction-push + cap + hedge path).

### Judge prompt contract (the heart of Phase 2)

```
You are a fact-checker. Below is an assistant REPLY and the SOURCES it had
available this turn (tool/script outputs). Find claims in the REPLY that draw
on the SOURCES but are NOT supported by them (contradicted, or stated with
specifics the sources don't contain).

RULES:
- Only judge claims that depend on the SOURCES. IGNORE general world knowledge
  not derived from the sources (e.g. "USDT is a stablecoin") — those are out of
  scope, do NOT list them.
- A claim that restates or summarizes the sources accurately is supported.
- If you are unsure whether a claim is source-derived, treat it as supported
  (do not list it).
- Return JSON only: {"unsupported": [{"claim": "...", "why": "..."}]}. Empty
  list if everything source-derived is supported.

SOURCES:
<tool output text>

REPLY:
<message block bodies>
```

Default-to-supported + ignore-general-knowledge are what prevent over-hedging.

## Cost & latency

- One Haiku call per qualifying message (full + tool-output + prose). Greg's daily analyze turns and Scrooge's balance turns qualify; chat/no-tool turns don't.
- Haiku is ~10–20× cheaper than the main model; at NanoClaw volume (a few qualifying turns/day) → pennies/day.
- Latency: one Haiku round-trip (~1s) on qualifying turns; a full regeneration only when a claim is actually unsupported.
- Tool-output truncation (~8 KB) bounds the judge's input cost; note this can miss support buried in a truncated large output (rare for the target agents).

## Honest limits

- **No-tool prose is uncovered.** If the agent states prose with no tool call this turn, Phase 2 does nothing (no source to check; demanding one over-hedges). Confident-wrong parametric prose remains the residual → Phase 3 (CoVe + web-search).
- **The judge is an LLM** — fallible (can miss a subtle misstatement or, rarely, over-flag). Default-to-supported biases toward false negatives over false positives (an annoying false bounce is worse than a missed subtlety for a low-volume assistant). Tunable later.
- No published production precision/recall for this in-loop pattern — directional from offline benchmarks (see `reference-hallucination-mitigation`).

## Verification

- **Unit (bun:test):** `judgeProse` output parsing (valid JSON, empty list, malformed → throws); trigger predicate (full + tool-output + prose → true; off / no-tool / pure-number → false); grounding-text accumulation + cap.
- **Integration (bun:test):** mocked judge returning unsupported → poll-loop bounces then hedges on cap; supported → delivers; judge throws → fail-closed-soft (deliver + blanket hedge). Off/deterministic paths unchanged (no judge call).
- **Live probe:** Scrooge on `'full'`, ask a finance question that produces prose over tool data (e.g. "посмотри мои финансы и скажи где концентрация риска"). Expect: prose matches the script outputs; a deliberately unsupportable ask gets bounced/hedged, not confidently fabricated. Inspect logs for `Factuality judge:` lines + messages_out.

## Non-goals (→ Phase 3)

- Parametric/no-source prose coverage (CoVe).
- Forced web-search / external lookup to verify open-domain prose.
- Sampling/semantic-entropy triage.
- Per-claim citation rendering in user output (stays clean — silent gate).

## Open defaults (flagged for review)

- Tool-output cap ~8 KB.
- Judge model Haiku (vs Sonnet for harder entailment).
- Trigger requires ≥1 tool output (vs also judging no-tool prose — rejected as over-hedge).
- Shared retry cap (2) across Phase 1 + Phase 2 bounces.
