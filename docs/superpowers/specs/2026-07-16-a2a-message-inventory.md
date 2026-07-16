# a2a Message Inventory — measured, not declared

**Date:** 2026-07-16
**Status:** Research input for the a2a protocol-normalization design. Not a design itself.

## How this was produced

Every `messages_in` row with `channel_type='agent'` across every session DB under
`data/v2-sessions/` on the production VDS was parsed and grouped by
(sender → target, discriminator, key set). **274 rows total.** This is measured
traffic, not what the agents' CLAUDE.md / team.md *claim* — the gap between the
two is the main finding.

Reproduce with a node script (`/usr/bin/node` on the VDS + the project's
`better-sqlite3`; `pnpm exec tsx scripts/q.ts` does NOT work there — the root
shell's Node 20 mismatches the service's Node 22 build).

## Headline: there is no protocol

**152 of 274 rows (55%) are freeform text, not JSON at all.** A `kind:"text"`
case is not an edge case — it is the majority of a2a traffic.

| Discriminator | Rows | Notes |
|---|---:|---|
| none — freeform text | **152** | payne→jarvis 39, greg→jarvis 33, jarvis→greg 24, payne→greg 21, jarvis→payne 17, greg→payne 16, jarvis→jarvis 2 |
| `action` | ~99 | ~16 distinct values |
| `severity`+`metric` | 10 | greg→jarvis `finding` — no `action` key at all |
| `operation` | 13 | reactions: `{operation:"reaction", messageId, emoji}` |
| none (bare object) | 3 | payne's `next_workout` reply `{day_name,duration_estimate_min,main_exercises,intensity}`; `{findings}` |

## Structured messages by `action`

| action | rows | route | key-set variants |
|---|---:|---|---:|
| `set_log` | 23 | jarvis→payne | 3 |
| `health_signal` | 20 | greg→payne | 2 |
| `workout_done` | 11 | payne→jarvis | 2 |
| `workout_done` | 11 | payne→greg | 2 (different payload than the jarvis one — `tonnage_kg` vs `type`) |
| `health_trend` | 8 | greg→jarvis | 1 |
| `health_signal_ack` | 7 | payne→greg | 4 |
| `ack` | 5 | jarvis→payne, greg→payne, jarvis→greg | 4 |
| `workout_ack` | 2 | greg→payne | 2 |
| `workout_done_ack` | 2 | greg→payne | 2 |
| `update_user_fact` | 1 | greg→jarvis | 1 |
| `update_confirmed` | 1 | jarvis→greg | 1 |
| `workout_cancel` | 1 | jarvis→payne | 1 |
| `workout_cancel_ack` | 1 | payne→jarvis | 1 |
| `workout_done_correction` | 1 | payne→greg | 1 |
| `query_finding` | 1 | jarvis→greg | 1 |
| `workout_start` | 1 | jarvis→payne | 1 |
| `next_session_estimate` | 1 | jarvis→payne | 1 |

## Findings that should drive the design

1. **Freeform text dominates (55%).** Any strict format must treat text as a
   first-class `kind`, not an escape hatch.
2. **Four different discriminator conventions coexist**: `action`, `kind`
   (`sick_day_ack`, per jarvis's team.md), `severity`/`metric` (`finding`), and
   `operation` (reactions). Plus bare objects with none.
3. **Five parallel ack shapes** — `ack`, `workout_ack`, `workout_done_ack`,
   `health_signal_ack`, `workout_cancel_ack` — the same concept spelled five ways,
   with 4 key-set variants for plain `ack` alone.
4. **Payload keys drift within a single action**: `set_log` has 3 key sets,
   `health_signal_ack` 4, `finding` 5, `workout_done` 2 (and a *different* payload
   depending on whether it goes to jarvis or greg under the same name).
5. **Most traffic is undeclared.** `set_log` (23 rows — the single most common
   structured message) appears in no contract doc. Also undeclared:
   `workout_start`, `next_session_estimate`, `update_user_fact`,
   `update_confirmed`, `workout_done_correction`, `query_finding`,
   `workout_cancel`.
6. **A retired contract is still live.** greg's CLAUDE.md states the routine daily
   `health_trend` a2a is retired ("в a2a больше НЕ шлёшь") — 8 rows exist. (Age
   not established; may predate the retirement. Verify before acting.)
7. **`finding` — the single most important greg→jarvis message — has no
   discriminator field**, and 5 distinct key sets.

## Consequence for the agent registry

The registry's `agent.json` descriptor currently models `a2a_in` as
`action → description`. That model fits roughly 40% of real traffic and would
actively mis-teach agents for the rest (an agent reading `recheck` as an action
would send `{"action":"recheck"}` where greg expects plain text). Descriptors and
the CLAUDE.md contract-trim were therefore **stopped** pending this
normalization — writing them against a schema that is about to change is waste.

`role` and `aka` are orthogonal to the wire format and survive any decision here.

## Already shipped and live (the original bug)

The naming bug this all started from is fixed independently of the protocol
question: the host stamps the source agent's canonical `agent_groups.name` onto
forwarded a2a content, the formatter renders `sender="Майор Пейн" agent="payne"`,
and the name registry publishes to every person. See
`2026-07-16-agent-registry-a2a-grounding-design.md`.
