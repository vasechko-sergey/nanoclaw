# a2a Protocol Normalization — Design

**Date:** 2026-07-16
**Status:** Approved by owner. Ready for an implementation plan.
**Grounded in:** [`2026-07-16-a2a-message-inventory.md`](2026-07-16-a2a-message-inventory.md) — 274 measured live messages.
**Builds on:** [`2026-07-16-agent-registry-a2a-grounding-design.md`](2026-07-16-agent-registry-a2a-grounding-design.md) — the shipped registry (`src/agent-registry.ts`).

## The problem, stated precisely

The a2a wire has no protocol. 55% of traffic is freeform text, four discriminators
(`action` / `kind` / `severity` / `operation`) coexist, one concept (`ack`) is
spelled six ways, and the single most common structured message (`set_log`, 23
rows) is declared nowhere.

**Why it got that way is the design constraint.** Contracts *did* exist — as prose
in each agent's CLAUDE.md. Nothing checked them. So: `set_log` grew undeclared,
greg kept emitting a `health_trend` its own CLAUDE.md calls retired, and five ack
spellings accumulated. The declaration and the reality were **different artifacts**,
so they drifted, and nothing made the drift visible.

A tidier convention that nothing checks decays exactly the same way from a tidier
start. **So the design goal is not "define a format" — it is "make the declaration
and the enforcement the same artifact."**

## Decisions (owner, 2026-07-16)

| Decision | Choice |
|---|---|
| Scope | Envelope + vocabulary cleanup. **No payload-schema validation.** |
| Envelope location | `kind="…"` attribute on the `<message>` block (option A) |
| Failure mode | **Bounce to sender** — reject + tell the sender what was wrong |
| Enforcement | **Two layers**: container in-turn + host authoritative |
| Migration | Big-bang code; per-agent arming via descriptor |
| `operation:reaction` over a2a | **Killed** — `add_reaction` errors on agent destinations |

## 1. Wire format

```
<message to="payne" kind="set_log">{"exercise":"жим лёжа","weight_kg":80,"reps":8}</message>
<message to="payne">норм, отдыхай сегодня</message>          ← kind omitted = text
<message to="family">Ужин в 8</message>                       ← channel: no kind, ever
```

- `kind` is optional and applies **only to agent destinations**. Channels never
  carry it.
- Omitted `kind` means `text`. **This is why 55% of traffic needs no migration.**
- `poll-loop` lifts it into the envelope written to `messages_out`:
  `content = {text: body, kind}` for agent destinations, `{text: body}` for channels.
- The host reads `content.kind` directly — one parse, no nested-string dig.
- The formatter renders inbound symmetrically:
  `<message kind="set_log" sender="Jarvis" agent="jarvis" from="jarvis">…</message>`.
  `kind="text"` is **not** printed — no noise on the majority path.

### Why symmetry is load-bearing

The agent sees `kind=` on every structured inbound, every turn. It does not have to
*remember* a convention from CLAUDE.md — the wire demonstrates the format
continuously. Memory of prose is exactly what failed before.

### The system prompt teaches it too — from the same artifact

`buildDestinationsSection()` (`container/agent-runner/src/destinations.ts`) already
generates the "## Sending messages" addendum from the live `destinations` table.
Since that table now carries `a2a_kinds`, the addendum lists **each agent
destination's legal kinds automatically, on every wake, from the same descriptor
the gate checks**:

```
- `payne` (Майор Пейн) — kind: set_log, health_signal, ack
- `family` (Семья)
```

This matters more than it looks. It means the contract an agent reads is *generated
from the enforced artifact* rather than hand-copied into prose — so the CLAUDE.md
rewrite in §5 is mostly deletion, not translation. Prose contracts are what rotted;
replacing them with generated ones is the point, and a hand-maintained duplicate in
CLAUDE.md would reintroduce exactly the drift being removed.

### Parsing contract

- `to="…"` remains **required** for a block to be dispatchable — unchanged.
- `kind="…"` is optional and accepted in **either order** relative to `to`.
- A `<message>` with no `to=` behaves exactly as today: not dispatched, falls
  through to the unwrapped-text nudge.

### The hole this format has, and the plug

An agent that forgets `kind=` sends `{"exercise":…}` as `kind:"text"` → legal →
silently delivered as prose. That is precisely the silent-misclassification failure
that disqualified the alternative "kind inside the JSON string" design, so it must
not be tolerated here either.

**Plug:** `kind` omitted (or `text`) **AND** body parses as a JSON object → reject
and bounce. Prose that is incidentally a valid JSON object does not occur in
practice. A forgotten attribute becomes loud instead of silent.

**The plug is part of the gate and arms with it** (§3, "Gate arming"). It must NOT
fire when the target has no descriptor: before migration, *every* structured
message is exactly "JSON body, no kind attribute" — an always-on plug would bounce
all 122 structured rows the moment the code shipped, breaking the inert-ship
property the migration depends on.

### MCP `send_message` is text-only over a2a

`send_message` (`container/agent-runner/src/mcp-tools/core.ts`) writes
`content: {text}` with no `kind`, so it can only ever produce `kind:"text"` to an
agent. **This is deliberate and should be documented, not fixed:** structured a2a
has exactly one emit path (`<message kind=>`). The MCP tool stays what it is — a
mid-turn ack.

## 2. The single artifact

`agents/<folder>/agent.json` → `a2a_in`. **Zero descriptors are authored today** —
this is greenfield, no migration cost.

```json
{
  "role": "фитнес-тренер",
  "aka": ["Пейн", "Майор Пейн"],
  "a2a_in": {
    "set_log": "лог подхода: {exercise, weight_kg, reps}",
    "health_signal": "сигнал Грега о состоянии: {metric, severity}",
    "ack": "подтверждение приёма; в теле — id инбаунда, который подтверждается"
  }
}
```

This one file is simultaneously:

1. **What the registry publishes to peers** — rendered into
   `/workspace/global/agents.md` for every person (shipped, live).
2. **What the gate checks against** — the legal `kind` set for this agent's inbox.

**Nothing can drift.** Removing `health_trend` from greg's descriptor
simultaneously un-advertises it to peers *and* starts rejecting it at the
transport. One edit. There is no second place for reality to diverge into.

### Type impact: none

`AgentDescriptor.a2a_in` is already `Record<string, string>` (`src/agent-registry.ts:28`).
The **type is unchanged** — only the semantics (action → kind) and the wording in
`renderRegistryMarkdown` ("какие action агент принимает" → "какие kind") and the
doc comment on line 27.

### `text` is implicit

`text` is always legal and is **never declared** in a descriptor — otherwise every
descriptor carries the same boilerplate line, and boilerplate is what stops being
read.

### The friction is the feature

Adding a new `kind` now requires editing `agent.json`. An agent can no longer
quietly invent protocol — which is the exact mechanism by which `set_log` reached
23 live rows while appearing in no contract. Naming this explicitly because it is a
real cost: protocol evolution becomes a deliberate act, not an emergent one.

## 3. Enforcement — two layers, host authoritative

This is the codebase's own documented pattern, from the `destinations.ts` header:

> This table is BOTH the routing map and the container-visible ACL. The host
> re-validates on the delivery side against the central DB, so even if this table
> is stale the host's enforcement is authoritative.

### Layer 1 — container, in-turn (strong correction)

- Host adds an `a2a_kinds` column to the session `destinations` table: a JSON array
  of the kinds **that destination's target accepts** (from the target's own
  descriptor), or `NULL` when the target has no descriptor. The table is already
  rewritten on every wake and read live by the container — no new plumbing.
  `DestinationEntry` (`container/agent-runner/src/destinations.ts`) gains a matching
  `a2aKinds?: string[] | null`.
- `dispatchCompleteBlocks` (`poll-loop.ts:1162`) checks the kind before writing to
  `messages_out`. Illegal → **block is not written**; it is collected.
- At `result` time, one nudge per turn, in the established `unwrappedNudged` shape
  (`poll-loop.ts:1049`):
  ```
  <system>Не доставлено: kind="health_trend" — greg такой не принимает.
  Легальные для greg: finding, ack, query_finding, text. Перешли.</system>
  ```
- The agent fixes it in the same turn, with full context. This is the strongest
  correction available and it reuses proven machinery.

### Layer 2 — host, authoritative (the reason the gate is real)

- `routeAgentMessage` (`src/modules/agent-to-agent/agent-route.ts:235`) is the
  **single chokepoint** — every a2a message passes through it regardless of emit
  path. It already parses content (`stampSenderIdentity`, `forwardFileAttachments`).
- Catches what Layer 1 structurally cannot: the MCP `send_message` path (a separate
  subprocess writing `messages_out` directly), a container running older
  agent-runner code, and any future emit path.
- Illegal → do **not** route. Write a `<system>` note into the **sender's own**
  inbound and wake it. The `system` folder is already reserved for exactly this
  (`src/group-folder.ts`).

On the MCP path the only reachable violation is the JSON-body-without-kind plug —
`send_message` can only ever produce `kind:"text"`, which is always legal. That is
also the violation that matters most there: an agent quietly shipping structured
JSON as prose is the exact silent failure this design exists to make loud.

**Layer 2 should almost never fire in steady state — that is the point, not a sign
it is redundant.** Its value is not throughput, it is that the declaration becomes
*binding*. Without it, an agent that skips poll-loop is unchecked, and a gate with a
bypass is a document again — which is what we are replacing.

### Gate arming: `a2a_in` presence

**No `a2a_in` declaration → `a2a_kinds` is NULL → no gate → everything accepted.**

What arms the gate is an explicit `a2a_in`, not the presence of the `agent.json`
file. A descriptor carrying only a `role` (or `aka`) stays disarmed: agent.json
predates this gate and promises every field is optional, and saying nothing about
the wire is not the claim "I accept nothing but text". An explicit `"a2a_in": {}`
*is* that claim, and arms text-only. See `getLegalKinds` in `src/agent-registry.ts`.

This is not a compatibility layer; it is a switch. Consequences, all desirable:

- Code ships inert. Each `a2a_in` arms its own agent independently.
- Newly created agents (`create_agent`) keep working before anyone authors a
  descriptor.
- The registry can be populated (roles, aliases) ahead of, and independently of,
  arming any transport gate.
- A malformed descriptor fails the gate **open**, not closed — matching
  `readAgentDescriptor`'s existing contract ("a bad descriptor must never take the
  registry down"). A typo must not bounce all of an agent's traffic.

### Loop safety

- Layer 1: one nudge per turn (`unwrappedNudged` precedent). A second illegal kind
  in the same turn is dropped and logged, not re-nudged.
- Layer 2: never bounces a bounce. System notes are `kind='system'` and exempt.

### Folded in: the silent-drop bug

`dispatchCompleteBlocks` (`poll-loop.ts:1173`) today **silently drops** a block with
an unknown destination — no nudge, no bounce, agent never learns. Same rot channel,
same fix: route it through the new nudge.

### Folded in: `blockKey` comment/code mismatch

`blockKey` (`poll-loop.ts:1141`) is documented as using a NUL separator but the code
uses a space: `` `${toName} ${body.trim()}` ``. Since `kind` must join the dedupe key
(same body, different kind = a different message), fix the separator to match the
documented intent at the same time.

## 4. Vocabulary

Derived from the measured inventory. Payload keys are **descriptive only** — the
descriptor's prose, never validated.

| Today | Rows | Route | → kind | Decision |
|---|---:|---|---|---|
| freeform text | **152** | all pairs | `text` | implicit default, **no migration** |
| `action:set_log` | 23 | jarvis→payne | `set_log` | legalize (was undeclared) |
| `action:health_signal` | 20 | greg→payne | `health_signal` | survives |
| `operation:reaction` | 13 | — | — | **killed for a2a** (see below) |
| `action:workout_done` | 11 | payne→**jarvis** | `workout_done` | survives (payload `type`) |
| `action:workout_done` | 11 | payne→**greg** | `workout_summary` | **split** — different payload (`tonnage_kg`), different consumer |
| `severity`+`metric` | 10 | greg→jarvis | `finding` | gets a real discriminator |
| `action:health_trend` | 8 | greg→jarvis | — | **dies** — retired in greg's CLAUDE.md, still flying |
| `ack`, `health_signal_ack`, `workout_ack`, `workout_done_ack`, `workout_cancel_ack`, `update_confirmed` | 18 | 5 pairs | `ack` | **6 → 1** |
| bare `{day_name,…}` | 3 | payne→jarvis | `next_workout` | gets a kind |
| `workout_start`, `workout_cancel`, `workout_done_correction`, `query_finding`, `update_user_fact`, `next_session_estimate` | 6 | various | same name (`workout_done_correction` → `workout_correction`) | legalize (were undeclared) |

### `ack` merge — the cost, stated

Six spellings collapse to one. The name `workout_done_ack` carried "what I am
acking"; that information moves into the body as the inbound's `id=` (the formatter
already prints it).

**The transport cannot carry this.** `in_reply_to` is "the id of the **first**
inbound in the batch" (`container/agent-runner/src/current-batch.ts:5`), not the
message being acked. With three inbounds in a batch, an ack of the second still
reports the first. So `ack` bodies reference the inbound `id=` explicitly. That is
a descriptor hint, not a validated schema.

### `reaction` — killed for a2a

`operation:reaction` is not an agent-designed protocol; it is an artifact of the
`add_reaction` MCP tool (`core.ts:409`), which mints `{operation:'reaction', …}` and
sends it to the session's `routing`. When the session is agent-typed, the reaction
lands in a peer's inbound — where **the host has no handling for it whatsoever**
(zero references in `delivery.ts` or `modules/agent-to-agent/`). It is JSON noise in
the peer's context: reactions are a platform affordance, and between agents there is
nothing to render them.

`add_reaction` returns an error when `routing` resolves to an agent destination.
This removes the fourth rival discriminator (`operation`) and 13 rows of noise.

## 5. Migration — big-bang code, per-agent arming

**Order matters.** The code is inert until descriptors land, so there is no window
where structured traffic bounces en masse.

1. Ship the code (envelope, both gate layers, `a2a_kinds` column, formatter). Zero
   descriptors exist → every gate is off → **behavior is unchanged**.
2. Author 5 `agent.json` descriptors. Then **delete** the hand-written a2a contract
   tables from the 5 CLAUDE.md files — the generated destinations addendum and
   `/workspace/global/agents.md` now carry that content from the descriptor. Keep
   in CLAUDE.md only what a descriptor cannot express (when to send what, and why).
   Re-stating the kind list there would recreate the hand-maintained duplicate this
   project exists to remove.
3. Rebirth all five together: kill containers + `DELETE FROM session_state WHERE key
   LIKE 'continuation:%'` — CLAUDE.md changes need both (see the
   instruction-reload rule).

### Session DB column

`destinations.a2a_kinds` uses the established idempotent pattern already in
`src/db/session-db.ts:302-344`: `PRAGMA table_info('destinations')` → conditional
`ALTER TABLE destinations ADD COLUMN a2a_kinds TEXT`. Existing session DBs get the
column on open; `CREATE TABLE IF NOT EXISTS` alone would not give it to them.

### In-flight rows at switchover

a2a rows already sitting in an `inbound.db` when the switch happens are old-format.
They are already **past** the gate, so they render as `text` with JSON in the body.
There are single digits of them. Switch during a quiet hour; do not build a
converter.

## 6. Explicitly out of scope

- **Payload-schema validation.** Owner ruled it out. Descriptor payload notes are
  prose for the agent, not a schema for the machine.
- **Renaming `agent_groups.name`** for greg/scrooge/jarvis (English names in a
  Russian chat). Separate one-row edits.
- **Blocking `<message to=>` for agent destinations** in favor of a typed MCP tool
  (design option C). Rejected: kills streaming, rebuilds the enum every wake, large
  blast radius.

## 7. Risks

| Risk | Mitigation |
|---|---|
| Bounce ↔ re-send loop | One nudge per turn; Layer 2 never bounces a `kind='system'` note |
| A typo'd descriptor bounces all of an agent's traffic | Malformed descriptor fails the gate **open** |
| Agent can no longer evolve protocol on its own | Intended. This is the friction whose absence produced the drift |
| Regex change alters unwrapped-nudge behavior | `to=` stays required for dispatch; a `<message>` without it must still reach the unwrapped path |
| Five simultaneous rebirths | Quiet hour; verify each agent's first turn post-rebirth |
