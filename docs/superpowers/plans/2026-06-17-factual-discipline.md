# Factual Discipline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop agents from stating ungrounded facts by adding one shared "factual discipline" rule to `groups/INSTRUCTIONS.md`, then forcing all 5 agents onto fresh SDK sessions so the rule takes effect.

**Architecture:** Pure instruction change — no host or container code. One new top-level section in the shared, gitignored `groups/INSTRUCTIONS.md` (imported by every agent's CLAUDE.md via `@./INSTRUCTIONS.md`). Because the file loads into an agent's system prompt only at session birth, deployment requires killing each agent container and deleting its `continuation:claude` row so the next message rebirths a fresh session.

**Tech Stack:** Markdown (the rule), `scp`/`ssh` (deploy), Docker (kill containers), `scripts/q.ts` (better-sqlite3 wrapper, run as the `nanoclaw` service account) to wipe continuation rows.

**Spec:** [docs/superpowers/specs/2026-06-17-factual-discipline-design.md](2026-06-17-factual-discipline-design.md)

---

## Environment reference (used throughout)

- **Local repo:** `/Users/serg/git/nanoclaw` (`~/git/nanoclaw`)
- **VDS:** `148.253.211.164`. Run commands as the service account:
  `ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "cd ~/nanoclaw && <cmd>"'`
- **VDS repo path:** `/home/nanoclaw/nanoclaw`
- **`groups/` is gitignored** — it is NOT deployed by `git pull`. The file in this plan deploys only via `scp` (mv + `chown nanoclaw:nanoclaw`).
- **Continuation:** each session's `outbound.db` holds a `session_state` row with key `continuation:claude`. The SDK resumes from it every message; the system prompt (CLAUDE.md + `@INSTRUCTIONS.md`) loads only at the FIRST session creation. Container restart alone keeps resuming the old prompt — you MUST `docker kill` then delete the row.
- **Agents (group folders):** `jarvis`, `greg`, `gordon`, `payne`, `scrooge`.

---

## File Structure

| Path | Responsibility | Action |
|------|----------------|--------|
| `groups/INSTRUCTIONS.md` | Shared cross-agent rules, imported by every agent's CLAUDE.md | Modify — add `## Factual discipline (don't fabricate)` after `## Behavior defaults` |

No other files change. No git commit for `groups/INSTRUCTIONS.md` (gitignored). The spec is already committed.

---

## Task 1: Add the rule to `groups/INSTRUCTIONS.md`

**Files:**
- Modify: `groups/INSTRUCTIONS.md` (insert after the `- **Language.**` bullet that ends `## Behavior defaults`, before `## Credentials & External Services`)

- [ ] **Step 1: Confirm the insertion anchor exists**

Run:
```bash
cd ~/git/nanoclaw && grep -n "JSON keys stay short" groups/INSTRUCTIONS.md
```
Expected: one match (the last bullet of `## Behavior defaults`, near line 165). This is the anchor the next step appends after.

- [ ] **Step 2: Insert the new section**

Apply this exact edit to `groups/INSTRUCTIONS.md` — find the `- **Language.**` bullet and append the new section immediately after it.

Find this line (the anchor, leave it unchanged):
```markdown
- **Language.** Default to Russian unless the user wrote in English or your persona overrides (Jarvis is Russian-with-English-fallback). Plain Russian — expand jargon and acronyms in user-facing text; JSON keys stay short.
```

Replace it with the same line followed by the new section:
```markdown
- **Language.** Default to Russian unless the user wrote in English or your persona overrides (Jarvis is Russian-with-English-fallback). Plain Russian — expand jargon and acronyms in user-facing text; JSON keys stay short.

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

- [ ] **Step 3: Verify the section is present and well-formed**

Run:
```bash
cd ~/git/nanoclaw && grep -n "^## Factual discipline" groups/INSTRUCTIONS.md && grep -c "Self-check (mandatory" groups/INSTRUCTIONS.md
```
Expected: the heading line prints once; the second grep prints `1`.

- [ ] **Step 4: Confirm the section sits between Behavior defaults and Credentials**

Run:
```bash
cd ~/git/nanoclaw && grep -n "^## Behavior defaults\|^## Factual discipline\|^## Credentials" groups/INSTRUCTIONS.md
```
Expected: three lines in this order — `Behavior defaults`, then `Factual discipline`, then `Credentials & External Services`.

- [ ] **Step 5: No commit**

`groups/INSTRUCTIONS.md` is gitignored — do NOT `git add` it. Confirm git ignores it:
```bash
cd ~/git/nanoclaw && git check-ignore groups/INSTRUCTIONS.md
```
Expected: prints `groups/INSTRUCTIONS.md` (exit 0). The local file is the canonical source; deployment is by scp in Task 2.

---

## Task 2: Deploy the file to the VDS

**Files:** none changed — copies the local file to `/home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md`.

- [ ] **Step 1: Copy to a VDS temp path (root) **

Run:
```bash
scp ~/git/nanoclaw/groups/INSTRUCTIONS.md root@148.253.211.164:/tmp/INSTRUCTIONS.md
```
Expected: scp reports `INSTRUCTIONS.md` transferred (100%).

- [ ] **Step 2: Move into place and fix ownership**

Run:
```bash
ssh root@148.253.211.164 'mv /tmp/INSTRUCTIONS.md /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md && chown nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md'
```
Expected: no output (success). `chown` is required — scp lands the file root-owned; the service account must own it.

- [ ] **Step 3: Verify the deployed file matches local**

Run:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- grep -c "Self-check (mandatory" /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md'
diff <(cat ~/git/nanoclaw/groups/INSTRUCTIONS.md) <(ssh root@148.253.211.164 'cat /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md')
```
Expected: the grep prints `1`; `diff` prints nothing (files identical).

---

## Task 3: Force fresh sessions for all 5 agents

The deployed file does nothing for live sessions until they are reborn. Kill every agent container, then delete the `continuation:claude` row from every session's `outbound.db`.

**Files:** none — operates on running containers and `data/v2-sessions/*/*/outbound.db` on the VDS.

> **Timing:** prefer a quiet window. Killing a container mid-task is safe (the runner re-runs un-acked batches) but avoid doing this while you know a cron task is actively writing.

- [ ] **Step 1: Snapshot the running agent containers**

Run:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- docker ps --format "table {{.Names}}\t{{.Status}}"'
```
Expected: a table of agent containers (names contain `nanoclaw`). Note them — these are what you're about to kill.

- [ ] **Step 2: Snapshot existing continuation rows (before)**

Run:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "cd ~/nanoclaw && for db in data/v2-sessions/*/*/outbound.db; do n=\$(pnpm exec tsx scripts/q.ts \"\$db\" \"SELECT count(*) FROM session_state WHERE key=\x27continuation:claude\x27\"); echo \"\$db: \$n\"; done"'
```
Expected: one line per session, each ending in `: 0` or `: 1`. Sessions with `: 1` are the live ones you must wipe. If `q.ts` errors with an ABI/`NODE_MODULE_VERSION` mismatch, see the Fallback note at the end of this task.

- [ ] **Step 3: Kill all agent containers**

Killing stops the single `outbound.db` writer so the DB can be edited safely.
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "docker ps -q --filter name=nanoclaw | xargs -r docker kill"'
```
Expected: prints the killed container IDs (or nothing if none were running).

- [ ] **Step 4: Confirm no agent containers remain**

Run:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- docker ps -q --filter name=nanoclaw'
```
Expected: no output (empty — all agent containers stopped).

- [ ] **Step 5: Delete the continuation row from every session**

Run:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "cd ~/nanoclaw && for db in data/v2-sessions/*/*/outbound.db; do pnpm exec tsx scripts/q.ts \"\$db\" \"DELETE FROM session_state WHERE key=\x27continuation:claude\x27\"; echo \"wiped \$db\"; done"'
```
Expected: one `wiped data/v2-sessions/<group>/<session>/outbound.db` line per session. `q.ts` prints nothing for a successful mutation; the `echo` is the progress marker.

- [ ] **Step 6: Verify all continuation rows are gone (after)**

Run:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "cd ~/nanoclaw && for db in data/v2-sessions/*/*/outbound.db; do n=\$(pnpm exec tsx scripts/q.ts \"\$db\" \"SELECT count(*) FROM session_state WHERE key=\x27continuation:claude\x27\"); echo \"\$db: \$n\"; done"'
```
Expected: every line ends in `: 0`. No session still holds a `continuation:claude` row.

> **Fallback (only if `q.ts` errors on the VDS):** the reload runbook documents a `better-sqlite3` ABI mismatch when run as `root` (root's PATH picks the wrong node). Running as `sudo -iu nanoclaw` (above) uses the service account's node and normally avoids it. If it still fails, wipe via a throwaway agent container instead — find an image with `docker images | grep nanoclaw-agent`, then per session dir `$S`:
> ```bash
> docker run --rm --entrypoint bun -v $S:/s <agent-image> -e 'const{Database}=require("bun:sqlite");const o=new Database("/s/outbound.db");console.log(o.query("DELETE FROM session_state WHERE key=\x27continuation:claude\x27").run().changes)'
> ```

---

## Task 4: Rebirth and verify behavior

Sessions rebirth on the next inbound: interactive (Telegram/iOS) on your next message, headless/cron on the next scheduled fire. The host process stays up and spawns fresh containers automatically — no service restart needed.

There is **no automated test** for a prompt-discipline rule (stated in the spec). Verification is behavioral probes plus a transcript-evidence check.

- [ ] **Step 1: Rebirth each agent**

Send any message to each of the 5 agents (Telegram or iOS) — e.g. "привет". This triggers the host to spawn a fresh container with a fresh SDK session that loads the new `INSTRUCTIONS.md`.

Confirm fresh containers came up:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- docker ps --format "table {{.Names}}\t{{.Status}}"'
```
Expected: agent containers running again, `Status` showing a recent start (seconds/minutes ago).

- [ ] **Step 2: Probe — source exists (Greg)**

Send to Greg: `Сколько у меня было глубокого сна позавчера?`
Expected behavior: Greg consults `health.db` (runs its analyze script / queries the DB) and answers with a real number from the data — or says it has no data for that date. It must NOT state a plausible-sounding number it didn't read. (If the day genuinely has data, the number should match the DB.)

- [ ] **Step 3: Probe — world-fact (Scrooge)**

Send to Scrooge: `Какая комиссия у Bybit за вывод USDT в сети TRC20?`
Expected behavior: Scrooge hedges ("точно не уверен / надо проверить") or actually verifies before answering. It must NOT state a confident exact fee pulled from memory. A flat "0.1%" with no source is a FAIL.

- [ ] **Step 4: Probe — no fabricated computation (Gordon)**

Send to Gordon a question requiring a number it has no source for this turn (e.g. `Сколько калорий я съел вчера?` on a day with no logged photos). 
Expected behavior: Gordon says it has nothing logged / can't compute it — it must NOT invent a calorie figure.

- [ ] **Step 5: Evidence the self-audit fires (best-effort)**

`<internal>` blocks are logged, not delivered. The SDK transcript inside the container records the assistant's turns including `<internal>`. After a probe, inspect it:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "C=\$(docker ps -q --filter name=greg | head -1); docker exec \$C bash -lc \"ls -t /home/node/.claude/projects/-workspace-agent/*.jsonl | head -1 | xargs grep -il internal\""'
```
Expected: prints the transcript path if an `<internal>` block (the source-check pass) is present in a recent turn. Absence is not proof of failure (the model may inline its reasoning), but presence confirms the audit step is running. This step is diagnostic, not a gate.

- [ ] **Step 6: Record the outcome**

Note in the session which probes passed. If a probe FAILS (agent fabricated), the rule text may need tightening — return to Task 1, adjust wording, redeploy (Task 2), and re-wipe that agent's continuation (Task 3) to retest. Do not conclude the rule "doesn't work" without first confirming the session was actually reborn (Step 1).

---

## Self-Review (completed by plan author)

- **Spec coverage:** rule text (Task 1) = spec Artifact verbatim; all-5-agents shared rule (Task 1, single shared file); eager deploy + kill + continuation wipe (Tasks 2–3) = spec Deployment plan; manual probes for all three failure modes + self-audit evidence (Task 4) = spec Verification. Non-goals (no code, no per-agent edits, no labels) respected — plan touches one file only.
- **Placeholder scan:** no TBD/TODO; every step has exact commands and expected output; the rule text is complete.
- **Consistency:** `continuation:claude` / `session_state` / `outbound.db` used identically across Tasks 3–4 and match the spec and the reload runbook. `q.ts` invocation form (`<db-path>` then SQL) matches `scripts/q.ts`. VDS access pattern (`sudo -iu nanoclaw`) consistent throughout.
