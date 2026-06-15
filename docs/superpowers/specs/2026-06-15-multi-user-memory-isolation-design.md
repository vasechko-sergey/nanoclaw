# Multi-user memory isolation (user-axis model)

**Date:** 2026-06-15
**Status:** Design — approved direction, pending spec review
**Goal:** Give a second human access to the same agents (Jarvis + Greg initially, all 5 eventually) with **complete memory isolation** — no agent of one person can read or write another person's memory. Design generalizes to N>1 users without cloning agents or drifting code.

---

## 1. Problem

Today the system is single-user (Sergei). Two structural facts make a second user share memory:

1. **Memory is keyed by agent group, not by sender.** `buildMounts` (`src/container-runner.ts:397`) mounts `groups/<folder>/` → `/workspace/agent` (RW) for *every* session of that agent group, regardless of who is talking. A second person wired to the same agent group mounts the same physical memory folder. Same for the shared `groups/global/` and cross-agent `groups/global/profiles/`.
2. **iOS cannot tell two people apart.** `validateToken` (`src/channels/ios-app/v2/index.ts:383`) compares against one shared `IOS_APP_TOKEN` and returns the constant `platform_id` `ios-app-v2:default` for every device. One token → one identity → one messaging group for all iPhones. (The code comment already flags this as a known limitation awaiting per-device tokens.)

Telegram already distinguishes senders (`telegram:<handle>` + per-DM messaging group), so the identity gap is iOS-specific. Greg needs iOS (HealthKit upload from the phone), so the iOS work is required for the chosen scope.

Two additional, pre-existing leak channels surface once a second person shares an agent group:

3. **`/home/node/.claude` is per-agent-group** (`<DATA_DIR>/v2-sessions/<agentGroupId>/.claude-shared`). Claude-side state (history, todos, cache) would be shared across two people's sessions of the same agent.
4. **Agents can self-edit behavior.** Per-group code (skills, scripts) is mounted RW and the `self-customize` skill lets an agent rewrite its own behavior files. Behavior must change only when the owner edits the files on the host — no agent (owner's or member's) should modify its own behavior.

---

## 2. Decisions (locked)

- **Scope (initial):** Jarvis + Greg for the second person. Design for N users × M agents.
- **Model:** **User-axis.** Agents stay as M shared agent groups (single source of persona/skills/scripts). The user is an orthogonal axis; each `(person, agent)` pair gets a private memory subtree. No per-user agent-group cloning.
- **Owner memory:** **Symmetric migration** — Sergei's memory moves into `user-memory/sergei/` so every person (including owner) uses one uniform mount path. Migration is backed up and dry-run on a copy first.
- **Agent self-modification:** Two distinct capabilities, treated differently:
  - **Behavior (agent files) — agents cannot change, ever.** Shared code (CLAUDE.md, `skills/`, `scripts/`, `agents/`, persona) is mounted **read-only for every session**, including the owner's. The `self-customize` skill is removed. Behavior changes only when the owner edits files on the host and redeploys (existing workflow).
  - **Packages / infra — kept.** `install_packages` / `add_mcp_server` stay, admin-approval-gated — installing a dependency is infrastructure, not behavior.
  - **`ncl` removed from all agents** (`cli_scope=disabled` everywhere). All admin/config/wiring/provisioning is done by the owner on the host.
- **Persona:** Shared code → the second person's Jarvis is still "Jarvis," same character, separate memory. Person-specific facts live in per-person global memory, not in shared code.

---

## 3. Person identity

Today `users` rows are per-channel (`telegram:<x>`, `ios-app-v2:<y>`). A single human spans channels (Sergei on Telegram **and** iOS) and those must share memory. So we need a stable per-human key above the channel handle.

- **`users.person_key`** (new nullable column). Default = the user id itself (each handle is its own person until mapped). Sergei's handles map to `sergei`; the second person's handles map to a neutral key (e.g. `p2` — the real label is chosen at provision time, no name baked into the design).
- **`sessions.owner_key`** (new column). Set at session creation in `resolveSession` (called from `deliverToAgent`, where `userId` is already resolved → look up `person_key`). For headless/cron sessions (`messaging_group_id = NULL`), `owner_key` is set explicitly when the task is created; default = owner.
- **Group chats** (multiple humans in one messaging group) are out of scope for private per-person memory. They fall back to a shared group memory keyed by the agent group (documented edge case, not built now).

---

## 4. Isolation invariant (single auditable point)

The entire guarantee lives in **`buildMounts`**:

> For any session, the only RW mounts containing user data resolve under `user-memory/<owner_key>/…`, where `owner_key` comes **solely** from `session.owner_key`. No mount ever exposes another person's memory tree or Claude home state. Shared code is mounted **read-only for every session** (no agent edits behavior) and contains no memory.

Leakage is impossible not because routing is "correct," but because another person's directory is never passed to `docker -v` for this container.

---

## 5. On-disk layout

Split the contents currently merged under `groups/<folder>/` into **code** (shared) and **memory** (private):

```
# CODE — one source per agent, shared by all people, de-personalized
groups/<folder>/          CLAUDE.md, container.json, agents/, skills/, scripts/
groups/INSTRUCTIONS.md    (shared, de-personalized)

# MEMORY — private per person
data/user-memory/<person>/<folder>/   memories/  conversations/  health/  scratch/  .claude/
data/user-memory/<person>/global/     about-<person>.md  profiles/  .writer
```

`scratch/` and `.claude/` (Claude home state) move into the per-person tree. `agents/` (subagent definitions), `skills/`, `scripts/`, `CLAUDE.md`, `container.json` are code.

---

## 6. Mount mapping (per session: owner_key = P, agent folder = F)

Container paths stay identical to today; only the host source changes, so agent code referencing `/workspace/agent/memories/...` keeps working.

```
/workspace/agent               ← groups/F/                       code; RO for every session
/workspace/agent/memories      ← user-memory/P/F/memories         RW
/workspace/agent/conversations ← user-memory/P/F/conversations    RW
/workspace/agent/health        ← user-memory/P/F/health           RW
/workspace/agent/scratch       ← user-memory/P/F/scratch          RW
/workspace/global              ← user-memory/P/global             RW if P's jarvis is the writer, else RO
/home/node/.claude             ← user-memory/P/F/.claude          RW   (was per-agent-group .claude-shared)
```

- The shared code dir (`/workspace/agent`, including `CLAUDE.md`, `container.json`, `skills/`, `scripts/`, `agents/`) is mounted **read-only for every session** — owner and member alike. No agent edits its own behavior; the `self-customize` skill is removed. Behavior changes only when the owner edits files on the host and redeploys. (Today `CLAUDE.md` / `container.json` are already RO-nested; this extends RO to the rest of the code.)
- The session dir (`/workspace`: inbound.db, outbound.db, outbox/, inbox/) is already per-session and needs no change — each person's sessions have their own session dirs.
- Skill symlinks (`syncSkillSymlinks`) target container paths (`/app/skills/...`, `/workspace/agent/skills/...`) and are location-independent, so they are written into the per-person `.claude` dir without other changes.

---

## 7. Per-person global + profiles

`groups/global/` (shared facts about the user + cross-agent `profiles/`) becomes per-person:

- `user-memory/<person>/global/about-<person>.md` — personal facts.
- `user-memory/<person>/global/profiles/` — cross-agent profile publish/read for that person only.
- `user-memory/<person>/global/.writer` — names the person's writer agent (jarvis), same `isGlobalMemoryWriter` mechanism (`src/container-runner.ts:346`).

The morning-brief / profiles publish-read contract is unchanged in shape; it just operates inside one person's global dir.

---

## 8. iOS multi-user identity

**8.1 Per-person token registry.** Replace the single-token check with a registry lookup:

```
ios_tokens(token_hash, platform_id, person_key, label, created_at)   -- new table, central DB
validateToken(token) → sha256(token) → registry → platform_id | null
```

- A one-time backfill at startup inserts Sergei's existing `IOS_APP_TOKEN` as `sergei → ios-app-v2:default`, so his current iOS messaging group, wirings, and sessions are **untouched** (back-compat) without any manual step.
- The second person gets a fresh token → `p2 → ios-app-v2:p2` → her own messaging group.
- `ws-handler.ts` is **unchanged** — the token itself is the discriminator; `device_id` does not need to be threaded.

**8.2 Provisioning.** A host-side command/script mints a token for a person: generate token → store hash + platform_id + person_key in `ios_tokens` → hand the raw token to the person once. Owner-only, on the host.

**8.3 iOS Swift app (`ios/JarvisApp/`).** Add a field for the user's own token (and server URL / Tailscale endpoint if not already configurable). The second person installs the build on her iPhone, enters her token → authenticates as her `platform_id`. Her device's APNs token registers under her platform_id (verify push path delivers to the right device).

**8.4 Health ingest → person path.** `resolveAgentFolderForPlatform(platformId)` already maps platform_id → wiring → folder. Make it person-aware: health writes to `user-memory/<person>/<folder>/health/health.db`. **Remove the `IOS_HEALTH_HISTORY_DIR` override** (it forces a single shared directory — under multi-user that would mix two people's health data). `GET /ios/state` (rings/state board) reads the requesting person's profiles from `user-memory/<person>/global/profiles/`, resolving person from the request's token/platform_id.

---

## 9. Access, ncl, self-mod, a2a, cron

- **Access.** The second person is a `member` of the jarvis + greg agent groups (`canAccessAgentGroup` already supports many users per group). Not owner/admin. Her sessions resolve to her `owner_key` → her memory.
- **ncl removed from agents.** `cli_scope=disabled` on all agent groups. The ncl instructions are excluded from CLAUDE.md (existing behavior at `disabled`), and host dispatch rejects any `cli_request`. This also changes Sergei's current Jarvis (was `global`) — those operations now run on the host. No per-owner cli gating is needed because there is no agent-side cli at all.
- **Behavior is immutable to agents.** Shared code is RO for every session and `self-customize` is removed (see §6). No agent — owner's or member's — changes its own behavior files; that happens only via host edits + redeploy.
- **Package self-mod kept.** `install_packages` / `add_mcp_server` stay, gated by admin (Sergei) approval — installing a dependency is infrastructure, not behavior. **Known shared-resource effect:** these rebuild the per-agent-group image, which is shared across all persons of that agent. Since each request is admin-approved, the owner sees and controls it. Documented, accepted.
- **a2a owner-scoping (isolation-critical).** Agent-to-agent destination resolution must be scoped by the source session's `owner_key`: the second person's Jarvis sending to "greg" must resolve to **her** Greg session, never Sergei's. `writeDestinations` / a2a routing keys the target session by `(agent_group, owner_key)`.
- **Cron per-person.** Headless cron sessions carry `owner_key` → run under that person's memory. Initially the second person's agents are on-request only (no cron); her brief / health-cycle can be added later.

---

## 10. De-personalization of shared code

Because code is shared, person-specific content must leave it:

- Audit all in-scope agents' `CLAUDE.md`, the shared `groups/INSTRUCTIONS.md`, and per-group `skills/` for hardcoded references to Sergei or his data (e.g. "operator Sergei", `about-sergei`, ncl usage).
- Move personal facts to per-person global (`about-<person>.md`).
- Make shared code person-neutral: it reads "the operator" facts from `/workspace/global/about-<person>.md`, which differs per session by `owner_key`.
- Remove any ncl usage baked into agent instructions/skills (agents no longer have ncl).

---

## 11. Migration (owner → symmetric layout)

One-time, on the VDS, owner-only:

1. **Back up** `groups/` and `data/` (per `reference_vds_workflow`).
2. **Dry-run on a copy** of the install; verify mounts + agent behavior unchanged.
3. For each agent folder F: move `groups/F/{memories,conversations,health,scratch}` → `user-memory/sergei/F/`, and the per-agent-group `.claude-shared` → `user-memory/sergei/F/.claude`.
4. Move `groups/global/{about-sergei.md,profiles,.writer}` → `user-memory/sergei/global/`.
5. Leave only code in `groups/F/`.
6. Restart; confirm Sergei's agents resume against the migrated memory with no behavior change (continuation rows, health.db reads, profiles publish, morning brief).

Migration is reversible from the backup.

---

## 12. Rollout phases

Order chosen so isolation is validated cheaply on Telegram (a second Telegram handle) **before** the expensive iOS work.

1. **Person identity + owner_key plumbing.** `users.person_key`, `sessions.owner_key`; `resolveSession` sets it; sender resolution maps handle → person. No behavior change (everything is `sergei`, mounts unchanged).
2. **Memory/code split + owner migration.** Separate code from memory; migrate Sergei → `user-memory/sergei/`; `buildMounts` resolves memory + `.claude` by `owner_key`; shared code mounted RO for every session; remove the `self-customize` skill; per-person global. **Isolation core.** Verify Sergei unchanged.
3. **De-personalize shared code.** Audit and move person facts to per-person global; strip ncl usage from instructions/skills.
4. **owner_key plumbing for a2a + cron.** a2a destinations owner-scoped; headless sessions carry owner_key. (cli gating not needed — ncl is off.)
5. **iOS multi-user.** `ios_tokens` registry, registry-backed `validateToken`, provision command, person-aware health ingest, person-scoped `/ios/state`, remove `IOS_HEALTH_HISTORY_DIR`.
6. **iOS Swift app.** Token/server field; build for the second person's iPhone.
7. **Provision the second person.** Mint token; add `users` row + `person_key`; member of jarvis + greg; wire her iOS + Telegram; create her `user-memory/` tree.

Phases 1–4 deliver working isolation on Telegram (testable with a second Telegram handle, no iOS). Phases 5–7 add iOS.

---

## 13. Testing strategy

- **Isolation (Telegram, before iOS):** register a second Telegram handle with `person_key=p2`, member of jarvis. Send facts to each person's Jarvis; assert each container mounts only its own `user-memory/<person>/`, that neither can read the other's `memories/`, `.claude/`, or `global/`, and that a2a from p2's Jarvis reaches p2's Greg (not Sergei's).
- **Owner regression (post-migration):** Sergei's agents behave identically — continuation, health.db, profiles publish, morning brief.
- **Mount-invariant unit test:** for a synthetic session with `owner_key=p2`, assert `buildMounts` produces no host path under another person's tree and no RW code mount.
- **iOS identity:** two tokens → two `platform_id`s → two messaging groups; health upload from each lands only in that person's `health.db`.

---

## 14. Out of scope (now) / open items

- Group chats with multiple humans (shared group memory) — not built; documented fallback.
- Per-person persona divergence (different name/tone per person) — shared code keeps one persona; revisit if needed via a per-person override later.
- The second person's cron (brief / health-cycle) — added after on-request usage is validated.
- Per-person secrets/credentials (OneCLI agent secret modes) — the second person's credentialed actions (if any) need their own OneCLI agent/secret scoping; out of scope for the memory-isolation work, flagged for when she uses credentialed tools.

---

## 15. Implementation findings (phase 1–4 → phase 5 seam)

Surfaced by the final holistic review after phases 1–4 landed. Both are forward-looking (phase 5 / deploy), not defects in 1–4 — the Telegram-scope isolation is complete and verified.

### 15.1 Session-creating paths that still need owner_key (phase 5)

Phase 3 wired `owner_key` through the router (`src/router.ts`). Two other session-creating paths do NOT yet pass it — benign while iOS is single-token (they default to `OWNER_PERSON_KEY`, correct for the sole owner), but **they become isolation holes the moment a second person is on iOS**, so phase 5 MUST include them:

- **`src/adapter-route.ts`** — the iOS inbound path. Its three `resolveSession(...)` calls omit the 5th `ownerKey` arg even though `userId` is resolved. Phase 5 must pass `resolvePersonKey(userId)` to all three, mirroring `router.ts`.
- **`src/modules/health-trigger/sick-day.ts`** — headless health-trigger session creation; needs owner-awareness if Greg ever serves more than one person.

Until then the spec §4 invariant ("owner_key comes solely from session.owner_key") is technically satisfied only because these paths' sessions resolve to the single owner.

### 15.2 Deploy-ordering — DO NOT migrate before iOS health-ingest is re-pathed

`scripts/migrate-owner-memory.ts` moves `groups/<folder>/health/` into `user-memory/<owner>/<folder>/health/` and `buildMounts` now mounts the group dir **read-only**. But the **host-side iOS health writer** (`src/channels/ios-app/v2/http-handler.ts` + `index.ts`, gated by `IOS_HEALTH_HISTORY_DIR`) still writes to the OLD `GROUPS_DIR/<folder>/health/health.db` — which the container no longer reads. **Consequence: after the migration, Greg stops receiving new HealthKit data until phase 5 re-paths the ingest** (spec §8.4: write to `user-memory/<person>/<folder>/health/`, remove `IOS_HEALTH_HISTORY_DIR`).

Therefore, on the VDS:
- **Do not deploy phases 1–4 and run `migrate-owner-memory.ts` until the iOS health-ingest re-path (phase 5, §8.4) is also ready** — otherwise the owner's own Greg health data silently stops flowing. (Deploying 1–4 *requires* running the migration in the same window, because `buildMounts` reads `user-memory/<owner>/…` which is empty until migrated — so "deploy 1–4 but skip migration" is not a safe option either.)
- Practically: since the second person needs iOS anyway, sequence the VDS rollout as **1–4 + 5 (at least §8.4 ingest re-path) together**, then migrate, then provision the second person.
- Migration preconditions remain: **stop the service first** (so `initUserMemory` can't race in and pre-create empty targets that cause whole-subdir SKIPs), and **back up** `groups/` + `data/` (the script MOVEs, not copies).
