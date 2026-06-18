# Factual Discipline — Design

**Date:** 2026-06-17
**Status:** Approved (design), pending implementation plan

## Problem

Agents (Jarvis, Greg, Gordon, Payne, Scrooge) sometimes state facts that aren't
grounded — they answer from general knowledge, invent numbers, or skip a data
source they actually have. For a personal assistant that drives health, money,
and schedule decisions, a confident wrong answer is worse than "I don't know."

Three failure modes in scope (confirmed with the operator):

1. **World-facts** — general knowledge stated as fact (medication effects,
   exchange fees, how an API/function works) that may be wrong.
2. **Fabricated numbers / computation** — invented health/finance figures, or
   claiming a script ran / data was checked when it wasn't.
3. **No source check** — a source exists (health.db, memory file, script) but
   the agent answers from memory instead of consulting it.

Out of scope: false memory about the user (claiming the user said/did something
they didn't) — explicitly excluded by the operator.

## Decisions

| Question | Decision |
|----------|----------|
| Visibility | **Silent filter.** No confidence labels in output. Clean replies; uncertainty surfaces only as "не знаю / надо проверить". The discipline lives in `<internal>` reasoning. |
| Threshold | **Action-relevant only.** Verify/hedge when a fact drives a decision (health, money, schedule, irreversible). Casual chat and common knowledge are untouched. |
| Mechanism | **Rule + mandatory internal self-audit (option B).** A prompt rule plus a required `<internal>` source-check before any reply carrying an action-relevant fact. No verification subagent, no web-search reflex, no code. |
| Scope | **All 5 agents**, via one shared rule. Greg/Scrooge operate in always-action-relevant domains and get the strictness for free. No per-agent CLAUDE.md edits. |
| Deployment | **Eager, all 5.** scp the file, then kill container + delete continuation rows across each agent's sessions so the rule takes effect on the next message. |

## Artifact

One new top-level section in `groups/INSTRUCTIONS.md`, placed immediately after
`## Behavior defaults`. English, matching the file's voice. This is the entire
change — no other files.

```markdown
## Factual discipline (don't fabricate)

You routinely answer questions that drive the person's decisions — health,
money, schedule, anything irreversible. There, a confident wrong answer is
worse than "I don't know." This rule applies only to **action-relevant facts**:
a claim the person could act on. Casual chat and common knowledge ("столица
Франции") need none of it.

Before stating an action-relevant fact, classify it silently:

- **Grounded** — traces to a source you can point to *this turn*: a tool/script
  output, a file you just read (health.db, a memory file, profiles), or the
  person's own message. State it.
- **Guess** — anything else, including your own general knowledge. Do NOT
  present it as fact.

For a guess, pick one:
1. **Verify** — a source exists (your DB, a memory file, a script, a tool) →
   open/run it and answer from the result. Default when you *have* the source:
   don't answer from your head when the file is right there.
2. **Hedge** — a world-fact you can't cheaply check → say so plainly ("точно не
   уверен", "надо проверить"), don't state it flat.
3. **Drop** — adds nothing without certainty → omit it.

Hard lines:
- **Never invent a number, date, dose, fee, or computed result.** Report a
  number only if it came from an actual file/tool/run this turn.
- **Never claim a script ran, data was checked, or a step succeeded unless it
  did** (extends §Behavior defaults: don't reinterpret a tool error as success).
- **Source exists → consult it.** Having health.db / a memory file / a script
  and answering from memory instead is the failure this rule targets.

This is **silent**. Output stays clean — no confidence tags, no "✅ verified"
labels. The discipline lives in your reasoning (`<internal>`), not in what the
person reads.

**Self-check (mandatory when your reply carries an action-relevant fact).**
Before the `<message>`, do a one-line `<internal>` pass: each action-relevant
claim → its source. Anything sourceless: verify, hedge, or drop. Then write the
clean reply.
```

## Deployment plan

`groups/` is synced to the VDS by scp, not git. `INSTRUCTIONS.md` is loaded into
an agent's system prompt at **session birth** via the `@./INSTRUCTIONS.md` import
in its CLAUDE.md. A live SDK session resumes from `continuation:claude` in its
`outbound.db`, so a file edit is ignored until the session is reborn.

Eager rollout, all 5 agents:

1. Edit `groups/INSTRUCTIONS.md` locally (add the section).
2. scp the file to the VDS group path.
3. For each agent (jarvis, greg, gordon, payne, scrooge): kill the container and
   `DELETE` the `continuation:claude` row across all of its sessions
   (interactive Telegram, iOS, headless cron) so the next message rebirths the
   session with the new rule.
4. Trigger a message per agent (or wait for the next inbound) to rebirth.

Tradeoff accepted: wiping `continuation` drops in-flight conversation context for
those sessions. File-based memory survives; only the resumed SDK thread is lost.
Acceptable for a quality rule.

## Verification

No automated test exists for a prompt-discipline rule — stated honestly. Manual
probes after reload, one per failure mode:

- **Source exists** — Greg: "сколько глубокого сна было позавчера?" → must open
  health.db, not guess.
- **World-fact** — Scrooge: "комиссия Bybit за вывод USDT в сети TRC20?" → must
  hedge or check, not invent a number.
- **Fabricated number** — any agent → must not state a computed figure without an
  actual run.
- **Self-audit fires** — `<internal>` blocks are logged but not delivered (per
  §Internal thoughts). Find where the runtime records them (host logs or session
  DB — confirm at plan time) and check the source-check pass is present. Closest
  thing to evidence the audit step actually runs.

## Non-goals (YAGNI)

- No confidence labels or per-fact tags in user-facing output.
- No verification subagent, fact-check tool, or web-search reflex.
- No host/container code changes.
- No per-agent CLAUDE.md edits.
- No handling of false-memory-about-the-user (excluded by operator).
```
