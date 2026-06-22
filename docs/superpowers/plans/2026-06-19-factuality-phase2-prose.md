# Factuality Gate — Phase 2 (Prose) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the factuality gate from numbers to **prose**: when an agent runs tools and then makes prose claims, an independent Haiku judge verifies those claims against the turn's tool outputs and bounces unsupported ones — without over-hedging parametric/common-knowledge prose.

**Architecture:** Reuses the entire Phase 1 skeleton (grounding accumulation, gate-at-result, bounce/regenerate with shared cap, `factualityGate` flag). Adds (1) `verification/judge.ts` — a one-shot raw Anthropic Messages API call to Haiku through the existing host credential proxy; (2) raw tool-output **text** accumulation alongside Phase 1's number set; (3) a `full`-mode branch in the poll-loop result handler that runs the judge after the deterministic number check passes. Flag value `full` already parses and materializes (Phase 1) — no new config work.

**Tech Stack:** Bun + TypeScript; `bun:test`; raw `fetch` to the Messages API (NOT the Claude Agent SDK — that spawns a Claude Code subprocess); model `claude-haiku-4-5`.

**Spec:** [docs/superpowers/specs/2026-06-19-factuality-phase2-prose-design.md](../specs/2026-06-19-factuality-phase2-prose-design.md). **Builds on:** Phase 1 (shipped — `verification/{numbers,gate,poll-gate}.ts`, flag-gated poll-loop, `tool_use_end.output`, migration 019).

---

## Environment notes

- Bun, NOT a pnpm workspace. After editing `container/agent-runner/`: `cd container/agent-runner && bun test` and `bun run typecheck`. Tests import from `bun:test`.
- Deploy: agent-runner `src/` is host-mounted → `git pull` + `ncl groups restart`, **no image rebuild**. No host (`src/`) changes in this phase (flag plumbing already done in Phase 1).
- Credential proxy (confirmed in `src/credential-proxy.ts`): **api-key mode** → proxy injects `x-api-key` on every request (send a placeholder). **oauth mode** → proxy swaps `Authorization: Bearer` when present (send `Bearer <placeholder>` + `anthropic-beta: oauth-2025-04-20`). `ANTHROPIC_BASE_URL` points at the proxy. Detect mode by presence of `process.env.ANTHROPIC_API_KEY`.

## File Structure

| Path | Responsibility | Action |
|------|----------------|--------|
| `container/agent-runner/src/verification/judge.ts` | Build judge request, parse JSON verdict, one-shot Haiku call via proxy | Create |
| `container/agent-runner/src/verification/judge.test.ts` | Unit tests: request build, response parse, judge w/ mock fetch | Create |
| `container/agent-runner/src/verification/prose-trigger.ts` | `shouldJudgeProse(mode, toolOutputText, messageText)` predicate | Create |
| `container/agent-runner/src/verification/prose-trigger.test.ts` | Unit tests for the trigger | Create |
| `container/agent-runner/src/poll-loop.ts` | Pass gate MODE; accumulate tool-output text; `full` judge branch at result | Modify |
| `container/agent-runner/src/poll-loop.factuality.test.ts` | (optional) integration assertions | — |

---

## Task 1: Judge request builder + response parser (pure)

**Files:**
- Create: `container/agent-runner/src/verification/judge.ts`
- Test: `container/agent-runner/src/verification/judge.test.ts`

- [ ] **Step 1: Write the failing test (pure parts only)**

```ts
import { test, expect } from 'bun:test';
import { buildJudgePrompt, parseJudgeVerdict } from './judge.js';

test('buildJudgePrompt embeds sources and reply, instructs ignore-general-knowledge', () => {
  const { system, user } = buildJudgePrompt('USDT is a stablecoin. Your Bybit balance is $953.', 'bybit total: 953 USD');
  expect(system).toContain('IGNORE general world knowledge');
  expect(user).toContain('USDT is a stablecoin');
  expect(user).toContain('bybit total: 953 USD');
});

test('parseJudgeVerdict reads a clean JSON object', () => {
  const v = parseJudgeVerdict('{"unsupported":[{"claim":"balance is $999","why":"sources say 953"}]}');
  expect(v.unsupported).toHaveLength(1);
  expect(v.unsupported[0].claim).toContain('999');
});

test('parseJudgeVerdict tolerates fenced/prefixed JSON', () => {
  const v = parseJudgeVerdict('Here:\n```json\n{"unsupported":[]}\n```');
  expect(v.unsupported).toEqual([]);
});

test('parseJudgeVerdict throws on unparseable text', () => {
  expect(() => parseJudgeVerdict('no json here')).toThrow();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/verification/judge.test.ts`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Implement the pure parts**

```ts
// container/agent-runner/src/verification/judge.ts

export interface ProseVerdict {
  unsupported: { claim: string; why: string }[];
}

const JUDGE_SYSTEM = [
  'You are a fact-checker. You are given an assistant REPLY and the SOURCES it had',
  'available this turn (tool/script outputs). Find claims in the REPLY that draw on',
  'the SOURCES but are NOT supported by them (contradicted, or stated with specifics',
  'the sources do not contain).',
  '',
  'RULES:',
  '- Only judge claims that depend on the SOURCES. IGNORE general world knowledge not',
  '  derived from the sources (e.g. "USDT is a stablecoin") — do NOT list them.',
  '- A claim that accurately restates or summarizes the sources is supported.',
  '- If unsure whether a claim is source-derived, treat it as supported (do not list it).',
  '- Return JSON only: {"unsupported":[{"claim":"...","why":"..."}]}. Empty list if all',
  '  source-derived claims are supported.',
].join('\n');

export function buildJudgePrompt(replyText: string, sourcesText: string): { system: string; user: string } {
  const user = `SOURCES:\n${sourcesText || '(no tool output this turn)'}\n\nREPLY:\n${replyText}`;
  return { system: JUDGE_SYSTEM, user };
}

/** Extract the first JSON object from the model's text and validate the shape. */
export function parseJudgeVerdict(text: string): ProseVerdict {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end < start) throw new Error('judge: no JSON object in response');
  const obj = JSON.parse(text.slice(start, end + 1)) as { unsupported?: unknown };
  const list = Array.isArray(obj.unsupported) ? obj.unsupported : [];
  const unsupported = list
    .filter((x): x is { claim: string; why?: string } => !!x && typeof (x as { claim?: unknown }).claim === 'string')
    .map((x) => ({ claim: x.claim, why: typeof x.why === 'string' ? x.why : '' }));
  return { unsupported };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd container/agent-runner && bun test src/verification/judge.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/judge.ts container/agent-runner/src/verification/judge.test.ts
git commit -m "feat(agent-runner): prose judge prompt builder + verdict parser"
```

---

## Task 2: Judge network call (injectable fetch)

**Files:**
- Modify: `container/agent-runner/src/verification/judge.ts`
- Modify: `container/agent-runner/src/verification/judge.test.ts`

- [ ] **Step 1: Add the failing test (mock fetch)**

```ts
import { judgeProse } from './judge.js';

test('judgeProse posts to the proxy and returns the parsed verdict', async () => {
  let captured: { url: string; init: RequestInit } | null = null;
  const fakeFetch = (async (url: string, init: RequestInit) => {
    captured = { url, init };
    return new Response(JSON.stringify({ content: [{ type: 'text', text: '{"unsupported":[]}' }] }), { status: 200 });
  }) as unknown as typeof fetch;

  const env = { ANTHROPIC_BASE_URL: 'http://proxy:8080', ANTHROPIC_API_KEY: 'placeholder' };
  const v = await judgeProse('reply', 'sources', fakeFetch, env);
  expect(v.unsupported).toEqual([]);
  expect(captured!.url).toBe('http://proxy:8080/v1/messages');
  const headers = captured!.init.headers as Record<string, string>;
  expect(headers['x-api-key']).toBe('placeholder');
  expect(headers['anthropic-version']).toBe('2023-06-01');
});

test('judgeProse uses oauth headers when no api key', async () => {
  let headers: Record<string, string> = {};
  const fakeFetch = (async (_url: string, init: RequestInit) => {
    headers = init.headers as Record<string, string>;
    return new Response(JSON.stringify({ content: [{ type: 'text', text: '{"unsupported":[]}' }] }), { status: 200 });
  }) as unknown as typeof fetch;
  await judgeProse('r', 's', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', CLAUDE_CODE_OAUTH_TOKEN: 'tok' });
  expect(headers['authorization']).toBe('Bearer tok');
  expect(headers['anthropic-beta']).toBe('oauth-2025-04-20');
});

test('judgeProse throws on non-200', async () => {
  const fakeFetch = (async () => new Response('nope', { status: 500 })) as unknown as typeof fetch;
  await expect(judgeProse('r', 's', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' })).rejects.toThrow();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/verification/judge.test.ts`
Expected: FAIL — `judgeProse` undefined.

- [ ] **Step 3: Implement `judgeProse`**

Append to `judge.ts`:
```ts
const HAIKU_MODEL = 'claude-haiku-4-5';

type EnvLike = Record<string, string | undefined>;

/**
 * One-shot prose-grounding judge. Raw Messages API call through the host
 * credential proxy (NOT the Agent SDK). fetchImpl + env are injectable for tests.
 * Throws on network error, non-200, or unparseable body — caller applies
 * fail-closed-soft.
 */
export async function judgeProse(
  replyText: string,
  sourcesText: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: EnvLike = process.env,
): Promise<ProseVerdict> {
  const base = env.ANTHROPIC_BASE_URL;
  if (!base) throw new Error('judge: ANTHROPIC_BASE_URL not set');
  const { system, user } = buildJudgePrompt(replyText, sourcesText);

  const headers: Record<string, string> = {
    'content-type': 'application/json',
    'anthropic-version': '2023-06-01',
  };
  if (env.ANTHROPIC_API_KEY) {
    headers['x-api-key'] = env.ANTHROPIC_API_KEY; // proxy re-injects the real key
  } else {
    headers['authorization'] = `Bearer ${env.CLAUDE_CODE_OAUTH_TOKEN ?? env.ANTHROPIC_AUTH_TOKEN ?? 'placeholder'}`;
    headers['anthropic-beta'] = 'oauth-2025-04-20'; // proxy swaps the Bearer token
  }

  const res = await fetchImpl(`${base}/v1/messages`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: HAIKU_MODEL,
      max_tokens: 1024,
      system,
      messages: [{ role: 'user', content: user }],
    }),
  });
  if (!res.ok) throw new Error(`judge: HTTP ${res.status}`);
  const data = (await res.json()) as { content?: { type: string; text?: string }[] };
  const text = (data.content ?? [])
    .filter((b) => b.type === 'text' && typeof b.text === 'string')
    .map((b) => b.text as string)
    .join('');
  return parseJudgeVerdict(text);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd container/agent-runner && bun test src/verification/judge.test.ts && bun run typecheck`
Expected: PASS (7 tests total), typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/judge.ts container/agent-runner/src/verification/judge.test.ts
git commit -m "feat(agent-runner): Haiku prose judge call via credential proxy"
```

---

## Task 3: Prose-judge trigger predicate (pure)

**Files:**
- Create: `container/agent-runner/src/verification/prose-trigger.ts`
- Test: `container/agent-runner/src/verification/prose-trigger.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { shouldJudgeProse } from './prose-trigger.js';

test('fires only on full + tool output + prose', () => {
  expect(shouldJudgeProse('full', 'tool said x', 'Your balance is concentrated in Tbank.')).toBe(true);
});
test('skips when not full mode', () => {
  expect(shouldJudgeProse('deterministic', 'tool said x', 'long enough prose here friend')).toBe(false);
  expect(shouldJudgeProse('off', 'tool said x', 'long enough prose here friend')).toBe(false);
});
test('skips when no tool output this turn', () => {
  expect(shouldJudgeProse('full', '', 'long enough prose here friend')).toBe(false);
});
test('skips trivial/number-only messages', () => {
  expect(shouldJudgeProse('full', 'tool', '$0.80')).toBe(false);
  expect(shouldJudgeProse('full', 'tool', 'ok')).toBe(false);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/verification/prose-trigger.test.ts`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement**

```ts
// container/agent-runner/src/verification/prose-trigger.ts
import type { FactualityGate } from '../config.js';

/**
 * Run the prose judge only when: gate is 'full', the turn produced tool output
 * (the judge's evidence), and the reply has enough prose to be worth judging
 * (≥ 6 words of letters — skips pure numbers, "ok", short acks).
 */
export function shouldJudgeProse(mode: FactualityGate, toolOutputText: string, messageText: string): boolean {
  if (mode !== 'full') return false;
  if (!toolOutputText.trim()) return false;
  const words = (messageText.match(/[A-Za-zА-Яа-яЁё]{2,}/g) ?? []).length;
  return words >= 6;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd container/agent-runner && bun test src/verification/prose-trigger.test.ts && bun run typecheck`
Expected: PASS (4 tests), typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/prose-trigger.ts container/agent-runner/src/verification/prose-trigger.test.ts
git commit -m "feat(agent-runner): prose-judge trigger predicate"
```

---

## Task 4: Wire the prose judge into the poll-loop (`full` mode)

**Files:**
- Modify: `container/agent-runner/src/poll-loop.ts`

The Phase 1 number gate stays for both `deterministic` and `full`. Phase 2 adds the judge **after** the number check passes, only in `full` mode. Reuses the existing bounce path + `factualityRetries` cap. `deterministic` and `off` are unchanged.

- [ ] **Step 1: Pass the gate MODE into processQuery (not just the boolean)**

Add imports at top of `poll-loop.ts` (next to the Phase 1 verification imports):
```ts
import { judgeProse } from './verification/judge.js';
import { shouldJudgeProse } from './verification/prose-trigger.js';
```

In `runPollLoop`, where Phase 1 computed `gateOn`, also derive the mode and capture tool-output text. Find:
```ts
    const gateOn = (config.factualityGate ?? 'off') !== 'off';
    const grounding = new Set<string>();
    if (gateOn) {
      for (const n of extractDataNumbers(prompt)) grounding.add(n);
    }
```
Replace with:
```ts
    const gateMode = config.factualityGate ?? 'off';
    const gateOn = gateMode !== 'off';
    const grounding = new Set<string>();
    const groundingText: string[] = []; // raw tool outputs this turn (Phase 2)
    if (gateOn) {
      for (const n of extractDataNumbers(prompt)) grounding.add(n);
    }
```
Update the `processQuery(...)` call to pass `gateMode` and `groundingText`:
```ts
      const result = await processQuery(query, routing, processingIds, config.providerName, gateOn, grounding, gateMode, groundingText);
```
Update the signature:
```ts
async function processQuery(
  query: AgentQuery,
  routing: RoutingContext,
  initialBatchIds: string[],
  providerName: string,
  gateOn = false,
  grounding: Set<string> = new Set(),
  gateMode: import('./config.js').FactualityGate = 'off',
  groundingText: string[] = [],
): Promise<QueryResult> {
```

- [ ] **Step 2: Accumulate raw tool-output text (capped)**

In the `tool_use_end` handler (Phase 1 added the number extraction here), also push the raw text, capped to ~8 KB total. Find:
```ts
        if (gateOn && event.output) {
          for (const n of extractDataNumbers(event.output)) grounding.add(n);
        }
```
Replace with:
```ts
        if (gateOn && event.output) {
          for (const n of extractDataNumbers(event.output)) grounding.add(n);
          if (gateMode === 'full') {
            const used = groundingText.reduce((a, s) => a + s.length, 0);
            if (used < 8000) groundingText.push(event.output.slice(0, 8000 - used));
          }
        }
```

- [ ] **Step 3: Add the judge to the result-branch (after the number check passes)**

> **CORRECTION (applied during execution, commits `d69dc9e9`/`9f8d35e1`):** the `break`-based version below is WRONG — `break` exits the `while(true)` event loop and silently drops the reply. The Phase 1 number-bounce does NOT break; it pushes + sets `resultReceived=false` in an `if`, with delivery in the sibling `else`, and lets the loop continue naturally. The implemented version mirrors that: restructure the delivery `else` block with `let proseBounced=false; let proseHedge=false;`, run the judge first, on unsupported prose set `proseBounced=true` (push correction + `resultReceived=false`, NO break), on judge throw set `proseHedge=true`; then guard delivery with `if (!proseBounced)` and fold the prose-hedge into `finalText`. Also: `judgeProse`'s fetch carries `signal: AbortSignal.timeout(20_000)` so a hung proxy fails into the fail-closed-soft hedge instead of parking the turn (the at-result `await` runs with the idle watchdog disarmed). Read poll-loop.ts for the exact final shape.

In the `result` event handler, Phase 1 runs `gateOutboundText` (numbers) and, when grounded, dispatches. Insert the prose judge between "numbers grounded" and "dispatch". Find the grounded path inside the `if (gateOn)` block — the branch that builds `finalText` when `verdict.grounded` is true. Replace the **grounded dispatch** portion:

```ts
              const finalText = verdict.grounded
                ? event.text
                : `${event.text}\n\n⚠️ Часть чисел выше я не смог подтвердить по источнику — перепроверь перед использованием.`;
              const { hasUnwrapped } = dispatchResultText(finalText, routing, dispatchedKeys);
              dispatchedKeys = new Set<string>();
```
with a version that runs the prose judge first when numbers are clean and mode is `full`:
```ts
              // Phase 2: prose judge (full mode). Runs only when numbers are
              // clean — a number bounce already happened above. Bounces share
              // the same factualityRetries budget.
              if (
                verdict.grounded &&
                shouldJudgeProse(gateMode, groundingText.join('\n'), event.text) &&
                factualityRetries < FACTUALITY_MAX_RETRIES
              ) {
                let prose: { unsupported: { claim: string; why: string }[] } | null = null;
                let judgeFailed = false;
                try {
                  prose = await judgeProse(event.text, groundingText.join('\n'));
                } catch (err) {
                  judgeFailed = true;
                  log(`Factuality judge error (fail-closed-soft): ${err instanceof Error ? err.message : String(err)}`);
                }
                if (prose && prose.unsupported.length > 0) {
                  factualityRetries++;
                  log(`Factuality judge: unsupported prose — bouncing (retry ${factualityRetries}/${FACTUALITY_MAX_RETRIES})`);
                  resultReceived = false;
                  query.push(
                    `<system>A fact-check found these claims in your reply unsupported by this turn's tool output: ` +
                      prose.unsupported.map((u) => `"${u.claim}" (${u.why})`).join('; ') +
                      `. Re-check the tool/script output and correct or remove them, then re-send your full reply.</system>`,
                  );
                  break; // leave the result handler; the regenerated turn re-gates
                }
                if (judgeFailed) {
                  const hedged = `${event.text}\n\n⚠️ Факты не проверены (проверяльщик недоступен).`;
                  dispatchResultText(hedged, routing, dispatchedKeys);
                  dispatchedKeys = new Set<string>();
                  break;
                }
              }
              const finalText = verdict.grounded
                ? event.text
                : `${event.text}\n\n⚠️ Часть чисел выше я не смог подтвердить по источнику — перепроверь перед использованием.`;
              const { hasUnwrapped } = dispatchResultText(finalText, routing, dispatchedKeys);
              dispatchedKeys = new Set<string>();
```

(The `break` exits the event loop; the pushed correction starts a fresh turn whose own `result` re-enters this branch — re-running numbers then prose. `resultReceived = false` re-arms the watchdog.)

- [ ] **Step 4: Typecheck + run all verification tests**

Run: `cd container/agent-runner && bun run typecheck && bun test src/verification/`
Expected: typecheck clean; all verification suites pass.

- [ ] **Step 5: Full container suite (confirm no regressions; 3 pre-existing failures unrelated)**

Run: `cd container/agent-runner && bun test 2>&1 | tail -4`
Expected: only the 3 known pre-existing `userFacingDispatchCount` isolation failures (documented in Phase 1); everything else passes. If a NEW failure appears, fix before committing.

- [ ] **Step 6: Commit**

```bash
git add container/agent-runner/src/poll-loop.ts
git commit -m "feat(agent-runner): prose judge in poll-loop full mode (Phase 2)"
```

---

## Task 5: Deploy + pilot on Scrooge

**Files:** none (deploy + config).

- [ ] **Step 1: Push + deploy the runner code (gate behavior unchanged until a flag flips to full)**

```bash
cd ~/git/nanoclaw && git push origin main
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build"'
```
Expected: pull + build clean. (agent-runner host-mounted; host restart not required for container src, but harmless. Scrooge is currently `deterministic` → still numbers-only until Step 2.)

- [ ] **Step 2: Flip Scrooge to `full`**

Set `factuality_gate='full'` for scrooge (mirror the Phase 1 set-gate pattern — a scp'd one-line `.sh` to avoid SQL-quote escaping through ssh):
```bash
# scripts/q.ts UPDATE container_configs SET factuality_gate='full' WHERE agent_group_id='scrooge'
```
Verify: `SELECT agent_group_id, factuality_gate FROM container_configs WHERE agent_group_id='scrooge'` → `scrooge|full`.

- [ ] **Step 3: Rebirth Scrooge**

Kill scrooge container + delete `continuation:claude` across its sessions (same find-based `.sh` as Phase 1's rebirth):
```bash
# docker ps -q --filter name=nanoclaw-v2-scrooge | xargs -r docker kill
# for each find data/v2-sessions/scrooge -name outbound.db → q.ts DELETE FROM session_state WHERE key='continuation:claude'
```

- [ ] **Step 4: Live probe — prose over tool data**

Send to Scrooge (Telegram/iOS): `Посмотри мои финансы и скажи где главная концентрация риска`. Expected: Scrooge runs its scripts (balance/analyze), and its prose claims about the data (which account dominates, where risk concentrates) match the tool output. A deliberately unsupportable prose ask (e.g. "и какие у меня там были крупные траты в Сингапуре?") should be hedged or corrected, not fabricated.

- [ ] **Step 5: Verify via logs**

```bash
# docker logs <scrooge container> | grep -i "Factuality judge"
# + dump messages_out for the session (Phase 1 dump pattern)
```
Expected: a `Factuality judge: unsupported prose — bouncing` line when it caught something; final delivered prose matches the tool outputs; no `⚠️ Факты не проверены` unless the judge call actually errored.

- [ ] **Step 6: Confirm other agents unaffected**

Greg/Gordon remain `off` (or `deterministic` if set) → no judge calls. Scrooge regression: a grounded prose answer delivers normally (one Haiku round-trip of latency on tool-turns).

---

## Self-Review (completed by plan author)

- **Spec coverage:** judge (Haiku via proxy, self-decompose, default-supported) = Tasks 1–2; trigger (full + tool-output + prose) = Task 3; grounding-text accumulation + cap = Task 4 Step 2; `full` branch with bounce/cap/fail-closed-soft = Task 4 Step 3; one-flag `full` = reused from Phase 1 (no config task); pilot Scrooge = Task 5. Non-goals (parametric prose, CoVe, web-search) excluded.
- **Placeholder scan:** all code complete; the two Task 5 ops steps reference the Phase 1 `.sh` patterns by name (set-gate, rebirth) rather than re-listing them — those exact scripts are in the Phase 1 execution history.
- **Type consistency:** `ProseVerdict`/`unsupported[]` consistent across judge.ts and poll-loop; `FactualityGate` mode threaded through `processQuery`; `judgeProse(reply, sources, fetchImpl?, env?)` signature matches its call site (defaults used in poll-loop); `shouldJudgeProse(mode, toolOutputText, messageText)` matches.
- **Shared cap:** Phase 1 number bounces and Phase 2 prose bounces both increment `factualityRetries` against `FACTUALITY_MAX_RETRIES` — a turn can't loop forever across both checks.
- **Risk:** the judge adds an `await` (network) inside the `result` handler. It runs only on `full` + tool-output + prose turns; `off`/`deterministic` paths never await the judge. Fail-closed-soft on judge error keeps the assistant responsive.
