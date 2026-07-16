# Agent Registry + a2a Naming Grounding — Design

**Date:** 2026-07-16
**Status:** Approved (brainstorming), pending implementation plan

## Goal

Give every agent a shared, structured registry of who the other agents are —
canonical `id → name + role + a2a contract` — distributed into every
container. Use it to (a) structurally ground agent names so relays stop
confabulating them, and (b) become the single source of truth for a2a
contracts, replacing the hand-copied prose in each agent's CLAUDE.md.

## Background — the bug this fixes

Jarvis relays Payne's workout reports to the owner. The a2a `workout_done`
payload Payne sends is pure JSON with **no sender name**
(`{"action":"workout_done","type":"Верх А",…}`). The coach's display name
(«Майор Пейн») was grounded **nowhere Jarvis reads at relay time**:
`profiles/payne.md` didn't exist, and Jarvis's CLAUDE.md named the coach only
by the lowercase routing id `payne`. Forced to supply the name from memory,
Sonnet confabulated **«Паулино»** (msgs 14–15 Jul), and it self-reinforced via
the SDK continuation → persisted across days.

A per-line CLAUDE.md anchor was deployed as an immediate patch. This design is
the structural fix: put the name (and contracts) in the **data**, so the model
never has to invent them.

## Existing infrastructure (reused, not reinvented)

| Concern | Where it lives today | Gap |
|---|---|---|
| Canonical display names («Майор Пейн») | `agent_groups.name` (central DB) | not distributed to peers |
| Outbound send targets | `destinations` (per-session, has `display_name`) | outbound only; never names an inbound sender |
| Who-can-talk-to-whom ACL | `agent_destinations` (central) | not surfaced to the agent as a registry |
| Freeform peer overview | `groups/<folder>/memories/public.md` → `groups/global/profiles/<folder>.md`, mounted RO at `/workspace/global/profiles/` | prose, not structured id→name |
| a2a contracts (accepted actions) | `memories/team.md`, hand-copied into each CLAUDE.md | duplicated, drifts |

**Key insight:** the display name is *already canonical* in
`agent_groups.name`. This is a **distribution** problem, not a
data-entry one.

**Field note (verified against the live DB):** `agent_groups` has columns
`id, name, folder, agent_provider, created_at` — there is **no `display_name`
column**; `name` *is* the human-facing name (`payne` → «Майор Пейн», `gordon` →
«Гордон Рамзи»), and the `AgentGroup` TS type already declares it. `name` is
therefore the single source for both the registry and the a2a sender stamp — no
second name field anywhere (that duplication is the drift problem being fixed).
Aside: `greg`/`scrooge`/`jarvis` currently carry English names ("Greg",
"Scrooge", "Jarvis") while chat uses Russian. If those should read «Грег»/
«Скрудж» in chat, the fix is a one-line data edit to `agent_groups.name` — out
of scope for this design, which faithfully distributes whatever `name` holds.

**Second key insight:** the container formatter already renders a `sender`
attribute from `content.sender` (`container/agent-runner/src/formatter.ts:222`,
the same path used for human senders like `sender="Alice"`). So stamping
`sender` onto an a2a inbound row is enough to make it render
`<message sender="Майор Пейн" …>` — no new formatter render path needed.

## Design

### 1. Per-agent descriptor: `agents/<folder>/agent.json`

Each agent describes itself in a small JSON file in its code root, next to
`CLAUDE.md` (`agents/<folder>/` is the live, host-readable code root under the
shared-code-mount model; authored/mirrored in `groups/<folder>/agent.json` as
the source and scp'd to the VDS `agents/<folder>/`, exactly like `CLAUDE.md`).
Only the **host** reads it (to build the registry) — it is not mounted into the
container, and an agent reads the aggregated registry, not its own descriptor.

```json
{
  "role": "фитнес-тренер",
  "a2a_in": {
    "next_workout": "запрос плана на дату",
    "workout_done": "лог завершённой тренировки",
    "reschedule": "перенос тренировки"
  },
  "aka": ["Пейн", "тренер"]
}
```

- `role` — one-line what-this-agent-is.
- `a2a_in` — map of `action → human description` the agent accepts over a2a.
- `aka` (optional) — accepted aliases, informational.
- **Name is NOT here** — it is pulled from `agent_groups.name` at
  aggregation time (no duplication, no drift).

Maintained like `CLAUDE.md` — a static descriptor authored in the
`groups/<folder>/` source and deployed to `agents/<folder>/` (scp / git). Not
mounted into the container, so it is host-maintained, not self-edited by the
running agent.

### 2. Host aggregation + distribution: `src/agent-registry.ts`

A new module modeled on `src/public-profiles.ts`, invoked from
`src/host-sweep.ts` alongside the existing profile fan-out (and once at
startup). It:

1. Reads every `agents/<folder>/agent.json` (skips folders without one).
2. Joins each with `agent_groups.name` (by folder→agent_group).
3. Renders two artifacts (identical for everyone — the registry is
   person-independent):
   - `agents.json` — canonical structured registry (for future tooling / the
     "basis for a2a" goal).
   - `agents.md` — a rendered table (`id · name · role · accepted a2a
     actions`). **This is what agents read.**
4. Writes both into **every person's** global dir:
   `data/user-memory/<person>/global/agents.{json,md}` — iterating the person
   dirs under `data/user-memory/` exactly as `projectAllPublicProfiles` does.

The per-person `global/` dir is mounted at `/workspace/global/` in every
container (RW only for the designated global-memory writer, RO for the rest —
`container-runner.ts:578`), so the same `/workspace/global/agents.md` path
resolves for all agents. The host writes these files directly (host-side FS
access), so the container's RO mount is irrelevant; the writer agent must treat
`agents.{json,md}` as host-generated (do not hand-edit). Hash-gated writes
(same idiom as `public-profiles.ts`) → an unchanged registry costs one read,
not a write, per sweep. Regenerated every sweep and at startup.

`agents.json` shape:

```json
[
  { "id": "payne", "name": "Майор Пейн", "role": "фитнес-тренер",
    "a2a_in": { "next_workout": "...", "workout_done": "...", "reschedule": "..." } },
  { "id": "greg", "name": "Грег", "role": "аналитик здоровья",
    "a2a_in": { "finding": "...", "health_signal": "..." } }
]
```

### 3. a2a inbound sender stamping (the data-layer naming fix)

In `src/modules/agent-to-agent/agent-route.ts` (`routeAgentMessage`), when
building `forwardedContent` for the target's inbound row, stamp:

- `sender` = source agent's `agent_groups.name` («Майор Пейн»)
- `senderId` = source agent folder (`payne`)

The source agent is already known here (the row's `source_session_id` →
session → agent_group; this is the `from=` already printed in the
"Agent message routed" log at `agent-route.ts:260`). The name comes from
`agent_groups` directly — the registry *file* is not needed for this path.

Formatter change (small): also render `content.senderId` as an `agent="…"`
attribute, so an a2a inbound row renders:

```
<message sender="Майор Пейн" agent="payne">
  {"action":"workout_done", …}
</message>
```

Jarvis now **sees** the name and cannot invent one.

### 4. Contract discovery + team.md de-duplication

`agents.md` becomes the single "who accepts what" reference. Each agent's
CLAUDE.md §Команда section drops its hand-copied a2a contract prose and points
to `/workspace/global/agents.md` instead. This removes the drift vector that
`memories/team.md` copies created. The interim «Пейн» anchor added to Jarvis's
CLAUDE.md becomes redundant (the name now arrives in `sender=`); it is removed
in the trim pass (or kept as a belt-and-suspenders line — decided at trim
time).

## Out of scope (YAGNI)

- **No host-side contract enforcement.** The registry is descriptive; the host
  does not reject unknown a2a actions. (Possible later.)
- **No rewrite of outbound targeting.** `destinations` / `send_message to`
  stays as-is; the registry augments, it does not replace routing.
- **Registry content is global, not per-person.** Names and contracts are
  person-independent, so `agents.{json,md}` is identical in every person's
  `global/` (uniform content replicated per person) — unlike `profiles/`, whose
  content differs per person.
- **No `ncl` resource.** Files + scp/git, like everything else in `groups/`.
- **No DB migrations.** Reuses existing `agent_groups`.

## Data flow

```
agents/<folder>/agent.json  ─┐
                             ├─(host-sweep: agent-registry.ts)─▶ data/user-memory/<person>/global/agents.{json,md}
agent_groups.display_name  ──┘                                        │ (per-person, RO mount → /workspace/global)
                                                                      ▼
                                                            /workspace/global/agents.md  ◀── agents read (roles, contracts)

payne outbound (workout_done) ─▶ agent-route.ts: stamp sender=display_name, senderId=folder
                               ─▶ target inbound row ─▶ formatter ─▶ <message sender="Майор Пейн" agent="payne">
```

## Error handling

- Missing `agent.json` for a folder → skip that agent in the registry (log
  info, don't fail the sweep).
- Malformed `agent.json` (bad JSON) → skip + `log.warn`; the previous
  `agents.{json,md}` stays in place (never write a half-built registry).
- Source agent's `display_name` NULL/absent at stamp time → fall back to
  `senderId` (folder) as `sender`, so the row still names the sender by id
  rather than nothing.
- Registry generation is idempotent and side-effect-free beyond the two output
  files; a failed sweep iteration leaves the last good artifacts.

## Testing

- **Host aggregator** (`src/agent-registry.test.ts`): merges N `agent.json` +
  `display_name` from `agent_groups`; skips folders with no file; malformed
  JSON → skipped + warns, prior output untouched; rendered `agents.md` contains
  each agent's name/role/actions.
- **agent-route stamp** (`src/modules/agent-to-agent/agent-route.test.ts`):
  routed a2a inbound row carries `sender` = source display_name and `senderId`
  = folder; NULL display_name → `sender` falls back to folder id.
- **Formatter** (`container/agent-runner/src/formatter.test.ts`): a2a row with
  `content.sender` + `content.senderId` renders
  `sender="Майор Пейн" agent="payne"`.
- **End-to-end**: payne → jarvis `workout_done` → jarvis's inbound formats as
  `<message sender="Майор Пейн" agent="payne">…`.

## Rollout / deploy

1. **Host + container code** (TDD): `src/agent-registry.ts`, `host-sweep.ts`
   wiring, `agent-route.ts` stamp, `formatter.ts` `agent=` attribute →
   `pnpm run build` + restart host; container src is host-mounted (no image
   rebuild).
2. **Author descriptors**: write `agent.json` for all 5 agents (author in the
   `groups/<folder>/` source, scp to VDS `agents/<folder>/agent.json`) → the
   next sweep publishes `data/user-memory/<person>/global/agents.{json,md}`.
3. **Trim CLAUDE.md**: replace each §Команда a2a contract block with a pointer
   to `/workspace/global/agents.md` → scp to VDS `agents/<folder>/CLAUDE.md` →
   rebirth (kill container + clear continuation) so the change takes effect.

First agent picks up the registry on its next spawn; the sender-stamping fix is
live as soon as the host restarts.

## Files touched

- **Host:** `src/agent-registry.ts` (new), `src/host-sweep.ts` (wire),
  `src/modules/agent-to-agent/agent-route.ts` (stamp sender).
- **Container:** `container/agent-runner/src/formatter.ts` (`agent=` attr).
- **Agent files:** `agents/<folder>/agent.json` ×5 (new; source mirror in `groups/<folder>/`), `agents/<folder>/CLAUDE.md` ×5 (trim §Команда).
- **No DB migrations.**
