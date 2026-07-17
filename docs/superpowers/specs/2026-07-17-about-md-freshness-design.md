# about.md Freshness — Design

**Goal:** Jarvis keeps `/workspace/global/about.md` fresh so every agent reads current
durable facts about the owner — bounded (does not grow forever), curated (only
cross-agent-useful facts land there).

## Problem

`about.md` (the shared, read-only owner profile that 4 of 5 agents read at session
start) is a **frozen fork** of Jarvis's live private profile:

| | `global/about.md` (shared) | `jarvis/memories/self/profile.md` (Jarvis private) |
|---|---|---|
| lines | 129 | 136 |
| `updated:` | 2026-06-07 | 2026-07-06 |
| mtime | Jun 14 | Jul 16 |

`diff` = 15 lines of ~130. Same frontmatter, same `sources:`, same headings.
`about.md` is a June snapshot of `profile.md`.

**Root cause:** nothing writes `about.md`. `profile.md` is written constantly (session
start reads it, iOS geolocation updates the location line, user feedback appends). No
skill and no handler writes `about.md`. The `.writer`=`jarvis` + RW mount of
`/workspace/global` (`container-runner.ts:580`, `isGlobalMemoryWriter`) exists precisely
so the designated writer can maintain `about.md` directly — but the writer skill was
never built. The machinery is there; the hand is missing.

## Approach

Add the missing hand: a Jarvis skill `about-maintain` that curates the durable,
cross-agent subset of `profile.md` into a bounded `about.md`, written directly via the
existing RW mount. No host change (the projection alternative would re-architect a
working mechanism and add standing sweep machinery for a file that changes ~monthly).

### What belongs in about.md (curation contract)

Durable facts about the **person** that any agent benefits from:

- Личное (name, age, family, home base — NOT current location)
- Юридический статус
- Карьера, Образование, Сертификаты, Навыки
- Интересы и активности
- Предпочтения (еда, кофе, коворкинги, любимые места)
- Поездки (notable/planned — NOT "currently at")
- Личные отношения
- Форматы отчётов / новостные предпочтения

**Excluded:**
- Ephemeral state — current location, weather, today's events, mood.
- Jarvis-private — honorific mapping, tone calibration.
- **Peer-domain data** — health metrics (→ Greg's fragment), training program (→ Payne),
  finance figures (→ Scrooge). about.md is about identity, not domain metrics.

### Boundedness — "profile, not journal"

- **Fixed section skeleton** = the size ceiling. Same sections every rewrite.
- **Rewrite in full, never append.** A new fact that supersedes an old one *replaces* it;
  facts do not accumulate. Stale facts get dropped, not stacked.
- Per-section soft budget: a few lines each. If a section overflows, compress, don't grow.
- This mirrors the reader contract already deployed to greg/payne/scrooge CLAUDE.md
  (`## Старт сессии`: "профиль, не журнал").

### Mechanism

1. Skill reads `profile.md` (Jarvis's live baseline) + any fresh durable fact just filed.
2. Distills the curated subset above into the fixed skeleton.
3. Stamps `updated:` with the owner-local run date: `$(TZ="$OWNER_TZ" date +%F)`.
4. Writes atomically: `/workspace/global/about.md.tmp` → `mv` to `about.md`
   (rename is atomic on one filesystem; a peer reading the RW mount never sees a
   half-written file).

### Triggers

- **Event** — Jarvis learns a durable cross-agent fact (moved cities, new job, new legal
  status, new durable preference). After filing it to `profile.md`, refresh `about.md`.
- **Weekly reconcile** — a recurring `schedule_task` (cron, e.g. Sunday) re-distills
  `profile.md` → `about.md` so it can never silently drift stale again.

### Seed

First run regenerates `about.md` from the current `profile.md` (about.md is a month
stale). Triggered once on deploy.

## Files

- Create: `groups/jarvis/skills/about-maintain/SKILL.md` — the curation skill.
- Modify: `groups/jarvis/CLAUDE.md` — §Память (about.md discipline) + §Скилы (catalog).
- Modify: `groups/jarvis/skills/index.md` — catalog line.
- Deploy: scp `groups/jarvis/` → VDS `agents/jarvis/` + `groups/jarvis/`; kill container;
  DELETE continuation row (CLAUDE.md edit needs a fresh read). Then seed.

No host TypeScript, no host rebuild/restart.

## Out of scope

- Typed `about.md` contract / lint (like `publishes`) — possible later; not needed for v1.
- Touching `profile.md`'s own write paths (session start / geofence / feedback) — unchanged.
- Other persons' about.md — same skill applies per person; only owner has the data now.
