# Phase A — Health-pull fix + legacy cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-enable the `request_context` MCP tool for all iOS agents (Greg, Gordon, …) by fixing a channel gate that only matched the removed v1 channel name, and refresh one stale legacy comment.

**Architecture:** The agent-runner registers `request_context` only when the session is on an iOS channel. The gate compares against the literal `'ios-app'` (v1, removed) but every live session is `'ios-app-v2'`, so the tool is silently never registered — health/context pull is dead for every v2 agent. Extract the gate into a small exported type-guard `isIosChannel` (testable, narrows `string | null → string`), switch it to `startsWith('ios-app')` so it matches both v1 and v2, and unit-test the regression. This is a container-source change, so it requires an **agent image rebuild** on the VDS, not just a host redeploy.

**Tech Stack:** Bun + TypeScript (agent-runner, `bun:test`), Node + pnpm (host build), Docker (`./container/build.sh`), systemd `--user` service on the VDS.

**Spec:** [`docs/superpowers/specs/2026-06-11-shared-profiles-and-bodycomp-design.md`](../specs/2026-06-11-shared-profiles-and-bodycomp-design.md) §A. This plan covers **Stream A only**. Streams B (profiles), C (body-comp), D (Gordon integration) each get their own plan.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `container/agent-runner/src/mcp-tools/request_context.ts` | Async `request_context` tool + registration gate | Add exported `isIosChannel` type-guard; rewrite the gate at line 236 to use it |
| `container/agent-runner/src/mcp-tools/request_context.test.ts` | `bun:test` coverage for the tool | Add a `describe('isIosChannel registration gate')` block |
| `src/channels/ios-app/v2/index.ts` | Host v2 iOS adapter registration | Refresh the stale doc-comment above `registerIosAppV2()` (legacy adapter is gone; comment claims it "can coexist") |

No group files, no scp, no iOS rebuild in this phase. Container source change → image rebuild on the VDS.

---

### Task 1: Fix the registration gate (extract testable `isIosChannel`, switch to `startsWith`)

**Files:**
- Modify: `container/agent-runner/src/mcp-tools/request_context.ts:231-244` (add type-guard above; rewrite gate at `:236`)
- Test: `container/agent-runner/src/mcp-tools/request_context.test.ts:10` (import) + append new describe block

- [ ] **Step 1: Write the failing test**

In `container/agent-runner/src/mcp-tools/request_context.test.ts`, change the import on line 10 from:

```typescript
import { requestContextTool, onContextResponse } from './request_context.js';
```

to:

```typescript
import { requestContextTool, onContextResponse, isIosChannel } from './request_context.js';
```

Then append this block at the end of the file (after the closing `});` of the existing `describe`):

```typescript
describe('isIosChannel registration gate', () => {
  it('accepts the legacy ios-app channel', () => {
    expect(isIosChannel('ios-app')).toBe(true);
  });
  it('accepts ios-app-v2 — the v2 sessions that were silently excluded', () => {
    expect(isIosChannel('ios-app-v2')).toBe(true);
  });
  it('rejects a non-iOS channel', () => {
    expect(isIosChannel('telegram')).toBe(false);
  });
  it('rejects the cli channel', () => {
    expect(isIosChannel('cli')).toBe(false);
  });
  it('rejects a null channel_type', () => {
    expect(isIosChannel(null)).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/mcp-tools/request_context.test.ts`
Expected: FAIL — import resolves but `isIosChannel` is `undefined` (not yet exported), so the five new assertions error (e.g. `TypeError: isIosChannel is not a function`). The 4 existing tests still pass.

- [ ] **Step 3: Write minimal implementation**

In `container/agent-runner/src/mcp-tools/request_context.ts`, insert the type-guard immediately **above** the existing `registerRequestContextTool` doc-comment (currently at line ~222). Add:

```typescript
/**
 * True when a session's channel_type is any iOS transport — both the legacy
 * `ios-app` (v1, removed) and the current `ios-app-v2`. The `request_context`
 * tool is gated on this.
 *
 * Bug history: this gate used to be `channel_type === 'ios-app'`, which
 * silently excluded every v2 session (`ios-app-v2`) and killed health/context
 * pull for Greg, Gordon, and any other iOS agent. `startsWith` matches both
 * and is future-proof for any later `ios-app-*` transport. Returns a type
 * predicate so callers narrow `string | null → string` past the guard.
 */
export function isIosChannel(channel_type: string | null): channel_type is string {
  return channel_type?.startsWith('ios-app') ?? false;
}
```

Then replace the gate body of `registerRequestContextTool`. Change:

```typescript
export function registerRequestContextTool(opts: {
  session_id: string;
  channel_type: string | null;
  platform_id: string | null;
}): void {
  if (opts.channel_type !== 'ios-app') return;
  registerTools([
    buildRequestContextDefinition({
      session_id: opts.session_id,
      channel_type: opts.channel_type,
      platform_id: opts.platform_id,
    }),
  ]);
}
```

to:

```typescript
export function registerRequestContextTool(opts: {
  session_id: string;
  channel_type: string | null;
  platform_id: string | null;
}): void {
  if (!isIosChannel(opts.channel_type)) return;
  registerTools([
    buildRequestContextDefinition({
      session_id: opts.session_id,
      channel_type: opts.channel_type,
      platform_id: opts.platform_id,
    }),
  ]);
}
```

Note: `isIosChannel`'s `channel_type is string` predicate narrows `opts.channel_type` to `string` after the early-return, so the `channel_type: opts.channel_type` argument to `buildRequestContextDefinition` (which requires `string`) still typechecks — same as the old `!== 'ios-app'` literal narrowing did.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd container/agent-runner && bun test src/mcp-tools/request_context.test.ts`
Expected: PASS — `9 pass, 0 fail` (4 existing + 5 new).

- [ ] **Step 5: Typecheck the container tree**

Run (from repo root): `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`
Expected: exit 0, no output. (Confirms the type-guard narrowing satisfies `buildRequestContextDefinition`'s `channel_type: string`.)

- [ ] **Step 6: Run the full container test suite (no regressions)**

Run: `cd container/agent-runner && bun test`
Expected: all suites pass.

- [ ] **Step 7: Commit**

```bash
git -C /Users/serg/git/nanoclaw add container/agent-runner/src/mcp-tools/request_context.ts container/agent-runner/src/mcp-tools/request_context.test.ts
git -C /Users/serg/git/nanoclaw commit -m "fix(agent-runner): register request_context for ios-app-v2 sessions

The registration gate compared channel_type against the literal 'ios-app'
(v1, removed). Every live session is 'ios-app-v2', so request_context was
silently never registered — health/context pull was dead for Greg, Gordon,
and every other iOS agent. Extract an isIosChannel(startsWith) type-guard
and unit-test the regression.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Refresh the stale legacy `ios-app` adapter comment

**Files:**
- Modify: `src/channels/ios-app/v2/index.ts:580-588` (doc-comment above `registerIosAppV2`)

The comment claims the legacy `ios-app` adapter "can coexist during the migration window" and that the default is "v2 is a no-op; legacy serves all iOS traffic." Both are false — `src/channels/index.ts:13` states the legacy adapter "has been removed." Refresh for accuracy (spec §A legacy-cleanup). No behavior change.

- [ ] **Step 1: Edit the comment**

Replace:

```typescript
/**
 * Register the v2 ios-app adapter with the channel registry.
 *
 * Registers under the distinct name `ios-app-v2` so the legacy `ios-app`
 * adapter (still bound to messaging_groups with channel_type='ios-app') can
 * coexist during the migration window. The factory itself short-circuits to
 * null unless `IOS_APP_V2_PORT` is set in the env, so the default behavior is
 * "v2 is a no-op; legacy serves all iOS traffic".
 */
```

with:

```typescript
/**
 * Register the v2 ios-app adapter with the channel registry.
 *
 * Registers under the name `ios-app-v2`. The legacy `ios-app` adapter has
 * been removed, so this is the only iOS transport — operators migrate any
 * remaining `channel_type='ios-app'` messaging-group rows to `'ios-app-v2'`.
 * The factory short-circuits to null unless `IOS_APP_V2_PORT` is set, so iOS
 * traffic is served only when that env var is configured.
 */
```

- [ ] **Step 2: Build the host (typecheck src/)**

Run (from repo root): `pnpm run build`
Expected: success, no errors. (Comment-only change; build confirms nothing else broke.)

- [ ] **Step 3: Commit**

```bash
git -C /Users/serg/git/nanoclaw add src/channels/ios-app/v2/index.ts
git -C /Users/serg/git/nanoclaw commit -m "docs(channels): refresh stale legacy ios-app coexistence comment

The legacy ios-app adapter was removed; the comment still claimed it
'can coexist' and 'serves all iOS traffic'. Match reality: ios-app-v2 is
the only iOS transport, gated on IOS_APP_V2_PORT.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Build the agent image, deploy to the VDS, verify health-pull is live

**Files:** none (deploy + verification only)

VDS facts: host `root@148.253.211.164`, service user `nanoclaw`, repo `/home/nanoclaw/nanoclaw`, service is a systemd `--user` unit `nanoclaw`. A container-source change requires rebuilding `nanoclaw-agent:latest` **on the VDS** and respawning containers so they boot from the new image. `request_context` registration runs at container boot (the `mcp-tools/index.ts` barrel), not at SDK-session birth — so a respawn from the new image is sufficient; no continuation-row surgery needed.

- [ ] **Step 1: Push to main**

```bash
git -C /Users/serg/git/nanoclaw push origin main
```
Expected: both commits land on `origin/main`.

- [ ] **Step 2: VDS — pull + host build**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && git pull --ff-only origin main && pnpm run build"'
```
Expected: fast-forward pulling both commits; `pnpm run build` succeeds.

- [ ] **Step 3: VDS — rebuild the agent container image**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd /home/nanoclaw/nanoclaw && ./container/build.sh"'
```
Expected: build completes, tags `nanoclaw-agent:latest`. The changed `request_context.ts` is in the COPY layer, so the build picks it up (content hash invalidates the layer). If a later verification shows the old behavior, the buildkit COPY cache is stale — prune the builder and re-run (`docker builder prune -f` then `./container/build.sh`); see CLAUDE.md "Container Build Cache".

- [ ] **Step 4: VDS — restart the service so containers respawn from the new image**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user restart nanoclaw'
```
Expected: clean restart. Host startup runs container-runtime orphan cleanup, so any still-running agent containers (old image) are killed; the next wake spawns them fresh from the rebuilt image.

- [ ] **Step 5: Verify image rebuilt + service active**

```bash
ssh root@148.253.211.164 'docker images nanoclaw-agent:latest --format "{{.Repository}}:{{.Tag}} {{.CreatedSince}}"'
ssh root@148.253.211.164 'sudo -u nanoclaw XDG_RUNTIME_DIR=/run/user/$(id -u nanoclaw) systemctl --user is-active nanoclaw'
```
Expected: image `CreatedSince` is seconds/minutes ago; `is-active` prints `active`.

- [ ] **Step 6: Verify the tool reaches an iOS agent (live)**

The deterministic guarantee is the Task 1 unit test (`isIosChannel('ios-app-v2') === true`). Confirm it end-to-end on the running system one of two ways:

**(a) Container-log check (headless, if a Greg/Gordon container is alive after a wake).** Send Greg any message to spawn a container, then:

```bash
ssh root@148.253.211.164 'cid=$(docker ps --format "{{.ID}} {{.Names}}" | grep -iE "greg|gordon" | awk "{print \$1}" | head -1); if [ -n "$cid" ]; then docker logs "$cid" 2>&1 | grep -m1 "MCP server started"; else echo "no live greg/gordon container — send one a message, then re-run"; fi'
```
Expected: a `MCP server started with N tools: …, request_context, …` line — `request_context` present confirms the gate now registers it for `ios-app-v2`.

**(b) Behavioral check (user-observable, authoritative).** From the iOS app, ask Greg to pull fresh phone data (e.g. "подтяни мои свежие данные с телефона"). Pre-fix Greg had no `request_context` tool and could not; post-fix he returns a live snapshot (steps / heart rate / sleep — the fields already wired in `AppContextCoordinator.health()`). Body-comp fields (weight/fat/lean) are **not** in the pull yet — those arrive in Phase C — so verify with the existing health fields, not weight.

- [ ] **Step 7: Update the project memory**

After verification passes, update `/Users/serg/.claude/projects/-Users-serg-git-nanoclaw/memory/project_gordon_agent.md`: mark the request_context blocker resolved (Phase A shipped + deployed), so later phases don't re-investigate it.

---

## Done criteria

- `bun test` green in `container/agent-runner/` (incl. the 5 `isIosChannel` cases).
- `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit` and `pnpm run build` both clean.
- Both commits on `origin/main`; VDS pulled, image rebuilt, service `active`.
- Greg (and Gordon) can call `request_context(["health"])` and get a live snapshot instead of the tool being absent.

## Not in this phase (separate plans)

- **B** — public profile fragments (`groups/global/profiles/`, host-sweep projection, INSTRUCTIONS §, per-agent `public.md` + ~08:30 publish, Jarvis morning-brief reads fragments). Host build + scp; no iOS.
- **C** — body-comp data (iOS `bodyMass`/`height`/`bodyFatPercentage`/`leanBodyMass` → upload + pull; Greg `analyze.js` trend). iOS rebuild.
- **D** — Gordon integration (intake pulls weight/height — depends on A+C; reads `greg.md`; publishes `gordon.md`). scp.
