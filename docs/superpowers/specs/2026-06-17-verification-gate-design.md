# Harness Verification Gate — Design

**Date:** 2026-06-17
**Status:** Approved (design), pending implementation plan
**Supersedes the enforcement approach in:** [2026-06-17-factual-discipline-design.md](2026-06-17-factual-discipline-design.md) (the prompt rule stays as a first line, but is no longer the enforcement mechanism)

## Problem

The prompt-only factual-discipline rule was deployed to all 5 agents and **ignored on its first real test**: asked for the Bybit USDT withdrawal fee, Scrooge produced a confident fabricated fee table with no source and no hedge — despite the rule being loaded into its session. A prompt rule is soft: the model can always rationalize past it. Fixing one agent is pointless; any agent will do the same.

We need enforcement the agent **cannot bypass**. The only place that is true is the **harness** (agent-runner), after generation, before delivery — the agent does not control it.

## Honest guarantee (expectation calibration)

- **Achievable:** no ungrounded action-relevant claim reaches the user without an independent, harness-enforced check first. The agent can't talk past it (a different component, not the agent, decides).
- **NOT achievable:** a perfect oracle. The judge is itself an LLM and is fallible. For a world-fact with no available source, the gate can only force a hedge ("надо проверить"), not confirm truth. Residual error remains.
- **The guarantee in one line:** *"no unverified action-fact ships without an independent check,"* not *"always correct."*

## Decisions (locked)

| Question | Decision |
|----------|----------|
| Mechanism | **Hybrid (C):** a cheap deterministic detector decides WHEN to invoke an independent LLM judge. Clean/grounded messages skip the judge (≈0 cost); only suspicious action-messages are judged. |
| On catch | **Block + regenerate.** Harness returns the judge's findings to the agent ("claim X has no source — verify via a tool or hedge") and the agent regenerates. Retry cap → on cap, fall back to a hedged/stripped version. Final output is the agent's own words. |
| Scope | **All 5 agents**, uniformly, at the harness level. Rollout: pilot on Scrooge first to validate, then fleet-wide. |
| Judge model | **Haiku** (`claude-haiku-4-5-20251001`) via the existing host credential proxy (`ANTHROPIC_BASE_URL` already set in the container). No new infra. |
| Grounding set | This turn's **tool outputs + files read this turn + the user's own message**. Parametric "from memory" knowledge does NOT count as grounding. |
| Fail-mode (judge errors/unavailable) | **Fail-closed-soft:** deliver the message but with a blanket hedge ("⚠️ факты не проверены — судья недоступен"). Never silently ship an ungrounded claim; never hard-break the assistant on an outage. |
| Streaming | Buffer each complete `<message>` block until it passes the gate, then dispatch. (Today the loop streams blocks immediately.) |

## Architecture

Everything lives in `container/agent-runner/src/` (Bun). The agent SDK turn runs as today; the gate intercepts at the **outbound dispatch** point.

```
SDK turn streams events
   │  (poll-loop tracks tool_use events this turn → grounding set)
   ▼
complete <message> block ready
   │
   ▼
[1] Action-relevance detector (cheap, deterministic)
   │  no action signals → dispatch unchanged (fast path, most messages)
   │  has action signals ▼
[2] Grounding-context collector
   │  gather this turn's tool outputs + file reads + user inbound
   ▼
[3] Independent judge (Haiku)  ── input: message + grounding set
   │  output: per-claim {text, grounded: bool, reason}
   │  all grounded → dispatch unchanged
   │  ungrounded action-claim(s) ▼
[4] Enforcement: block + regenerate
   │  inject judge findings as a correction turn → SDK regenerates
   │  re-run [1]-[3] on the new message
   │  retry cap (N=2) hit → fallback: strip/hedge flagged claims, dispatch
   ▼
writeMessageOut → host delivery
```

### Components

1. **Action-relevance detector** — `verification/detector.ts`. Deterministic scan of a `<message>` block for signals that it carries a claim the user could act on: currency amounts, percentages, numbers with units, dates, and keyword classes (fee/rate/price/dose/limit/комиссия/курс/etc.). Returns `{ suspicious: boolean, signals: string[] }`. Tuned for high recall (false positives just cost a judge call; false negatives skip the gate). Greetings, acknowledgements, pure opinion → not suspicious → fast path.

2. **Grounding-context collector** — `verification/grounding.ts`. The poll-loop already sees `tool_use`/`tool_result` ProviderEvents; this accumulates, per turn, the tool outputs, the paths/contents of files read, and the user's inbound text. Produces the ground-truth set handed to the judge. Reset per turn.

3. **Independent judge** — `verification/judge.ts`. One Haiku call. Prompt: "Here is an assistant reply and the ONLY sources available this turn. For each action-relevant factual claim, is it supported by a source? Return JSON `{claims: [{text, grounded, reason}]}`. Default to grounded=false if unsupported." Structured output. The generator's reasoning is NOT provided — the judge sees only the final text + sources, so it can't inherit rationalizations.

4. **Enforcement / retry** — in `poll-loop.ts` dispatch path. On ungrounded claims: build a correction message from the findings, continue the SDK conversation to regenerate, re-gate. Cap at N=2 regenerations; on cap, apply the fallback (strip the flagged claim or wrap it in a hedge) and dispatch so the user always gets a reply.

### Why it can't be bypassed

Steps 1–4 run in the runner, not in the agent's prompt. The agent cannot skip the detector, cannot see/avoid the judge, and cannot dispatch around the gate — `writeMessageOut` is only reached after the gate passes or the fallback fires. The agent's only path to the user is through the gate.

## Cost & latency

- Volume is low (5 agents, a few messages/day) → cost negligible.
- Fast path (no action signals) adds ~microseconds (string scan).
- Judged messages add one Haiku round-trip (~1s) + a full regeneration only when a claim is actually ungrounded. Acceptable for correctness on money/health facts.

## Streaming change (main risk)

Today complete `<message>` blocks are dispatched mid-stream. The gate requires buffering a block until it passes. This changes `poll-loop.ts` dispatch behavior and must preserve the existing watchdog/fallback paths (STREAM_IDLE_TIMEOUT, abort branch). This is the largest implementation surface and the main regression risk — covered by tests.

## Rollout

1. Build behind a per-agent flag (config: `verification_gate: on|off`, default off).
2. Enable on **Scrooge** only. Re-run the Bybit-fee probe → expect a hedge or a real API-sourced number, not a fabricated table.
3. Validate no regressions (Greg's grounded answers still pass cleanly, latency acceptable).
4. Flip the flag on for all 5.

## Verification

- **Unit (bun:test):** detector (signal/no-signal fixtures), judge output parsing, enforcement retry+cap+fallback logic, grounding collector.
- **Integration (bun:test):** a fabricated-number message → gate blocks → regenerate → hedge; a grounded message → passes untouched; judge-error → fail-closed-soft.
- **Live probe:** Scrooge Bybit fee after enabling — must NOT fabricate.

## Non-goals (YAGNI)

- Not a truth oracle — only catches ungrounded *claims*, forces verify-or-hedge.
- No web-search verification reflex (separate, later, if hedging proves too weak).
- No change to the prompt rule's wording — it stays as a cheap first line; the gate is the enforcement.
- No gate on non-action content (chat, opinions, acknowledgements).

## Open defaults flagged for review

These were set as sensible defaults, not user-chosen — adjust at spec review:
- Retry cap N=2.
- Judge model Haiku (vs Sonnet for harder claims).
- Fail-mode = fail-closed-soft (vs hard-block on judge outage).
- Rollout pilot = Scrooge first (vs all 5 at once).
- Detector keyword set (currency/%/units/dates/fee-rate-price-dose-limit).
