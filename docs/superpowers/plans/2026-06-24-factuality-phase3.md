# Factuality Gate Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add factuality verification Level 3 (parametric/world-fact prose: CoVe triage → action-relevant web_search verify) and replace the `off|deterministic|full` config string with an ordinal integer level 0–3.

**Architecture:** The gate runs in the container agent-runner's poll-loop at the turn's `result` event. Today it does Phase-1 (numbers) and Phase-2 (tool-prose judge). This plan (a) swaps the string mode for an integer `level` (0=off,1=numbers,2=tool-prose,3=all-prose; cumulative), and (b) adds a Level-3 pipeline: a Haiku call extracts checkable non-tool claims → an isolated Haiku "CoVe" call triages each → only `action_relevant ∧ uncertain/contradicted` claims escalate to a harness-side Claude+`web_search` call → failed claims bounce to the agent (capped) or deliver hedged. All new LLM calls go through the credential proxy exactly like the existing Phase-2 judge (non-bypass).

**Tech Stack:** Bun + TypeScript (container/agent-runner, `bun:test`); Node + TypeScript (host `src/`, `vitest`); raw Anthropic Messages API via the credential proxy.

**Spec:** `docs/superpowers/specs/2026-06-24-factuality-phase3-design.md`

---

## File structure

| File | Responsibility |
|------|----------------|
| `container/agent-runner/src/config.ts` (modify) | `FactualityLevel` type + `parseFactualityLevel` (reads int, falls back to legacy string); `RunnerConfig.factualityLevel` |
| `container/agent-runner/src/verification/llm.ts` (create) | Shared `callMessages()` (proxy auth + timeout) + `extractJsonObject()` for the new modules |
| `container/agent-runner/src/verification/claims.ts` (create) | `extractClaims()` — Haiku extracts checkable, non-tool, action-tagged claims |
| `container/agent-runner/src/verification/cove.ts` (create) | `coveTriage()` — isolated per-claim verdict supported/uncertain/contradicted |
| `container/agent-runner/src/verification/web-verify.ts` (create) | `webVerify()` + `webSearchAvailable()` preflight — harness-side Claude+web_search |
| `container/agent-runner/src/verification/level3.ts` (create) | `runLevel3()` — orchestrates extract → CoVe → escalate → aggregate verdicts |
| `container/agent-runner/src/poll-loop.ts` (modify) | `gateMode`→`level`; add the `level>=3` branch + `l3Retries` + hedge |
| `src/db/migrations/0XX-factuality-level.ts` (create) | `factuality_level INTEGER` column + backfill from `factuality_gate` |
| `src/db/migrations/index.ts` (modify) | register the new migration |
| `src/types.ts`, `src/container-config.ts`, `src/db/container-configs.ts`, `src/backfill-container-configs.ts` (modify) | host plumbing: read/write `factuality_level`, materialize `factualityLevel` into container.json |

Tasks 2–6 (new verification modules) are independent and can be built in any order. Task 1 (config) unblocks the poll-loop tasks; Task 7 (rename) precedes Task 8 (L3 wiring). Task 9 (host) is independent.

---

## Task 1: Container config — integer level (with legacy fallback)

**Files:**
- Modify: `container/agent-runner/src/config.ts`
- Test: `container/agent-runner/src/config.test.ts` (create if absent)

- [ ] **Step 1: Write the failing test**

Create/append `container/agent-runner/src/config.test.ts`:

```ts
import { test, expect } from 'bun:test';
import { parseFactualityLevel } from './config.js';

test('parseFactualityLevel reads an integer level', () => {
  expect(parseFactualityLevel(0)).toBe(0);
  expect(parseFactualityLevel(3)).toBe(3);
});
test('parseFactualityLevel clamps out-of-range / junk to 0..3', () => {
  expect(parseFactualityLevel(9)).toBe(3);
  expect(parseFactualityLevel(-1)).toBe(0);
  expect(parseFactualityLevel('x')).toBe(0);
  expect(parseFactualityLevel(undefined)).toBe(0);
});
test('parseFactualityLevel falls back to the legacy string mode', () => {
  expect(parseFactualityLevel(undefined, 'deterministic')).toBe(1);
  expect(parseFactualityLevel(undefined, 'full')).toBe(2);
  expect(parseFactualityLevel(undefined, 'off')).toBe(0);
});
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `cd container/agent-runner && bun test src/config.test.ts`
Expected: FAIL — `parseFactualityLevel` not exported.

- [ ] **Step 3: Implement**

In `container/agent-runner/src/config.ts`, replace the `FactualityGate` type + `parseFactualityGate` (lines 12–18) with:

```ts
/** Factuality verification level (see docs/superpowers/specs/2026-06-24-factuality-phase3-design.md).
 *  0=off, 1=numbers, 2=tool-prose, 3=all-prose. Cumulative. */
export type FactualityLevel = 0 | 1 | 2 | 3;

/**
 * Coerce container.json's value to a level 0..3. Prefer the integer
 * `factualityLevel`; if absent, map the legacy `factualityGate` string
 * (off→0, deterministic→1, full→2) for one-release back-compat.
 */
export function parseFactualityLevel(raw: unknown, legacy?: unknown): FactualityLevel {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    const n = Math.max(0, Math.min(3, Math.trunc(raw)));
    return n as FactualityLevel;
  }
  if (legacy === 'deterministic') return 1;
  if (legacy === 'full') return 2;
  return 0;
}
```

Update `RunnerConfig` (line 29): replace `factualityGate: FactualityGate;` with `factualityLevel: FactualityLevel;`. Update `loadConfig()` (line 59): replace `factualityGate: parseFactualityGate(raw.factualityGate),` with `factualityLevel: parseFactualityLevel(raw.factualityLevel, raw.factualityGate),`.

- [ ] **Step 4: Run to verify it PASSES**

Run: `cd container/agent-runner && bun test src/config.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/config.ts container/agent-runner/src/config.test.ts
git commit -m "feat(factuality): integer level config with legacy string fallback"
```

> NOTE: this breaks `prose-trigger.ts` and `poll-loop.ts` which still import `FactualityGate`. Those are fixed in Task 7. Do NOT run the full container typecheck until Task 7. Per-file `bun test` works because bun is permissive about unrelated type errors at runtime; if `bun test src/config.test.ts` fails to load due to a cross-import, proceed — Task 7 restores the tree. (If you prefer a green tree per task, do Task 7 immediately after Task 1.)

---

## Task 2: Shared LLM helper

**Files:**
- Create: `container/agent-runner/src/verification/llm.ts`
- Test: `container/agent-runner/src/verification/llm.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { callMessages, extractJsonObject } from './llm.js';

test('extractJsonObject pulls a fenced object out of prose', () => {
  expect(extractJsonObject('hi ```json\n{"a":1}\n``` bye')).toBe('{"a":1}');
  expect(extractJsonObject('Result: {"a":[1,2]} done.')).toBe('{"a":[1,2]}');
  expect(extractJsonObject('no json')).toBeNull();
});

test('callMessages posts to the proxy with api-key auth and returns text', async () => {
  let captured: { url: string; init: RequestInit } | null = null;
  const fakeFetch = (async (url: string, init: RequestInit) => {
    captured = { url, init };
    return new Response(JSON.stringify({ content: [{ type: 'text', text: 'hello' }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const text = await callMessages(
    { system: 'sys', user: 'usr', model: 'claude-haiku-4-5' },
    fakeFetch,
    { ANTHROPIC_BASE_URL: 'http://proxy', ANTHROPIC_API_KEY: 'k' },
  );
  expect(text).toBe('hello');
  expect(captured!.url).toBe('http://proxy/v1/messages');
  expect((captured!.init.headers as Record<string, string>)['x-api-key']).toBe('k');
});

test('callMessages forwards tools and throws on non-200', async () => {
  const fakeFetch = (async () => new Response('no', { status: 500 })) as unknown as typeof fetch;
  await expect(
    callMessages({ system: 's', user: 'u', model: 'm' }, fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' }),
  ).rejects.toThrow();
});
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `cd container/agent-runner && bun test src/verification/llm.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `container/agent-runner/src/verification/llm.ts` (mirrors the proven auth/parse in `judge.ts`):

```ts
type EnvLike = Record<string, string | undefined>;

export interface MessagesCall {
  system: string;
  user: string;
  model: string;
  maxTokens?: number;
  tools?: unknown[];
  timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 20_000;

/** Pull the first balanced JSON object out of model text (fence-first, string-aware). */
export function extractJsonObject(text: string): string | null {
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const hay = fence ? fence[1] : text;
  const start = hay.indexOf('{');
  if (start === -1) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < hay.length; i++) {
    const ch = hay[i];
    if (inStr) { if (esc) esc = false; else if (ch === '\\') esc = true; else if (ch === '"') inStr = false; }
    else if (ch === '"') inStr = true;
    else if (ch === '{') depth++;
    else if (ch === '}') { depth--; if (depth === 0) return hay.slice(start, i + 1); }
  }
  return null;
}

/** One raw Messages API call through the credential proxy. Returns concatenated text blocks. */
export async function callMessages(
  call: MessagesCall,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: EnvLike = process.env,
): Promise<string> {
  const base = env.ANTHROPIC_BASE_URL;
  if (!base) throw new Error('llm: ANTHROPIC_BASE_URL not set');
  const headers: Record<string, string> = { 'content-type': 'application/json', 'anthropic-version': '2023-06-01' };
  if (env.ANTHROPIC_API_KEY) {
    headers['x-api-key'] = env.ANTHROPIC_API_KEY;
  } else {
    headers['authorization'] = `Bearer ${env.CLAUDE_CODE_OAUTH_TOKEN ?? env.ANTHROPIC_AUTH_TOKEN ?? 'placeholder'}`;
    headers['anthropic-beta'] = 'oauth-2025-04-20';
  }
  const body: Record<string, unknown> = {
    model: call.model,
    max_tokens: call.maxTokens ?? 1024,
    system: call.system,
    messages: [{ role: 'user', content: call.user }],
  };
  if (call.tools) body.tools = call.tools;
  const res = await fetchImpl(`${base}/v1/messages`, {
    method: 'POST',
    signal: AbortSignal.timeout(call.timeoutMs ?? DEFAULT_TIMEOUT_MS),
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`llm: HTTP ${res.status}`);
  const data = (await res.json()) as { content?: { type: string; text?: string }[] };
  return (data.content ?? []).filter((b) => b.type === 'text' && typeof b.text === 'string').map((b) => b.text as string).join('');
}
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `cd container/agent-runner && bun test src/verification/llm.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/llm.ts container/agent-runner/src/verification/llm.test.ts
git commit -m "feat(factuality): shared Messages-API helper for verification modules"
```

---

## Task 3: Claim extraction

**Files:**
- Create: `container/agent-runner/src/verification/claims.ts`
- Test: `container/agent-runner/src/verification/claims.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { parseClaims, extractClaims, type ExtractedClaim } from './claims.js';

test('parseClaims reads claim + action_relevant, caps to max', () => {
  const json = JSON.stringify({ claims: [
    { claim: 'Paris is the capital of France', action_relevant: false },
    { claim: 'Ibuprofen max daily dose is 1200mg OTC', action_relevant: true },
  ]});
  const out = parseClaims(json, 6);
  expect(out).toHaveLength(2);
  expect(out[1].action_relevant).toBe(true);
});

test('parseClaims tolerates fenced JSON and drops malformed entries', () => {
  const out = parseClaims('```json\n{"claims":[{"claim":"x","action_relevant":true},{"nope":1}]}\n```', 6);
  expect(out).toHaveLength(1);
  expect(out[0].claim).toBe('x');
});

test('parseClaims caps the list', () => {
  const claims = Array.from({ length: 10 }, (_, i) => ({ claim: `c${i}`, action_relevant: false }));
  expect(parseClaims(JSON.stringify({ claims }), 6)).toHaveLength(6);
});

test('extractClaims posts to proxy and returns parsed claims', async () => {
  const fakeFetch = (async () =>
    new Response(JSON.stringify({ content: [{ type: 'text', text: '{"claims":[{"claim":"y","action_relevant":true}]}' }] }), { status: 200 })
  ) as unknown as typeof fetch;
  const out: ExtractedClaim[] = await extractClaims('reply text', 'tool output', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(out[0].claim).toBe('y');
});
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `cd container/agent-runner && bun test src/verification/claims.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `container/agent-runner/src/verification/claims.ts`:

```ts
import { callMessages, extractJsonObject } from './llm.js';

export interface ExtractedClaim { claim: string; action_relevant: boolean; }

const MODEL = 'claude-haiku-4-5';
export const L3_MAX_CLAIMS = 6;

const SYSTEM = [
  'You extract checkable factual claims from an assistant REPLY for fact-checking.',
  'You are given the REPLY and the SOURCES (this turn\'s tool/script output).',
  'RULES:',
  '- List only CHECKABLE, falsifiable factual assertions (a fact about the world, a number+unit, a named entity attribute).',
  '- SKIP: opinions, plans, hedged/uncertain statements, questions, and anything already supported by SOURCES',
  '  (those are checked elsewhere — only surface claims that do NOT come from the sources).',
  '- Mark action_relevant=true when acting on the claim being wrong could harm: health/medical, money/finance,',
  '  schedule/time-critical, or an irreversible action. Otherwise false.',
  '- Return JSON ONLY: {"claims":[{"claim":"...","action_relevant":true|false}]}. Empty list if none.',
].join('\n');

export function parseClaims(text: string, max: number): ExtractedClaim[] {
  const json = extractJsonObject(text);
  if (json === null) return [];
  let obj: { claims?: unknown };
  try { obj = JSON.parse(json); } catch { return []; }
  const list = Array.isArray(obj.claims) ? obj.claims : [];
  return list
    .filter((c): c is { claim: string; action_relevant?: unknown } => !!c && typeof (c as { claim?: unknown }).claim === 'string')
    .map((c) => ({ claim: c.claim, action_relevant: c.action_relevant === true }))
    .slice(0, max);
}

export async function extractClaims(
  replyText: string,
  sourcesText: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<ExtractedClaim[]> {
  const user = `SOURCES:\n${sourcesText || '(none)'}\n\nREPLY:\n${replyText}`;
  const text = await callMessages({ system: SYSTEM, user, model: MODEL }, fetchImpl, env);
  return parseClaims(text, L3_MAX_CLAIMS);
}
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `cd container/agent-runner && bun test src/verification/claims.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/claims.ts container/agent-runner/src/verification/claims.test.ts
git commit -m "feat(factuality): L3 claim extraction (checkable, non-tool, action-tagged)"
```

---

## Task 4: CoVe triage

**Files:**
- Create: `container/agent-runner/src/verification/cove.ts`
- Test: `container/agent-runner/src/verification/cove.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { parseCoveVerdict, coveCheck } from './cove.js';

test('parseCoveVerdict reads the three verdicts', () => {
  expect(parseCoveVerdict('{"verdict":"supported","why":"ok"}').verdict).toBe('supported');
  expect(parseCoveVerdict('{"verdict":"contradicted","why":"no"}').verdict).toBe('contradicted');
  expect(parseCoveVerdict('garbage').verdict).toBe('uncertain'); // unparseable → uncertain (safe middle)
});

test('coveCheck asks in isolation (claim only, no original answer) and returns a verdict', async () => {
  let sentUser = '';
  const fakeFetch = (async (_url: string, init: RequestInit) => {
    sentUser = JSON.parse(init.body as string).messages[0].content as string;
    return new Response(JSON.stringify({ content: [{ type: 'text', text: '{"verdict":"uncertain","why":"unsure"}' }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const v = await coveCheck('The Eiffel Tower is 330m tall', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(v.verdict).toBe('uncertain');
  expect(sentUser).toContain('Eiffel');
});
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `cd container/agent-runner && bun test src/verification/cove.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `container/agent-runner/src/verification/cove.ts`:

```ts
import { callMessages, extractJsonObject } from './llm.js';

export type CoveVerdict = 'supported' | 'uncertain' | 'contradicted';
export interface CoveResult { verdict: CoveVerdict; why: string; }

const MODEL = 'claude-haiku-4-5';

// Factored CoVe: the claim is verified in ISOLATION — the prompt deliberately
// contains no surrounding answer/context, so the model can't just agree with
// its own earlier framing. This surfaces confabulations re-reading wouldn't.
const SYSTEM = [
  'You independently fact-check a single CLAIM using only your own knowledge.',
  'Do not assume the claim is true. Judge it on its own.',
  'Return JSON ONLY: {"verdict":"supported|uncertain|contradicted","why":"<short>"}.',
  '- supported: you are confident it is true.',
  '- contradicted: you are confident it is false or misleading.',
  '- uncertain: you cannot confidently judge (niche, ambiguous, time-sensitive).',
].join('\n');

export function parseCoveVerdict(text: string): CoveResult {
  const json = extractJsonObject(text);
  if (json !== null) {
    try {
      const o = JSON.parse(json) as { verdict?: unknown; why?: unknown };
      if (o.verdict === 'supported' || o.verdict === 'contradicted' || o.verdict === 'uncertain') {
        return { verdict: o.verdict, why: typeof o.why === 'string' ? o.why : '' };
      }
    } catch { /* fall through */ }
  }
  return { verdict: 'uncertain', why: 'unparseable' };
}

export async function coveCheck(
  claim: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<CoveResult> {
  const text = await callMessages({ system: SYSTEM, user: `CLAIM: ${claim}`, model: MODEL, maxTokens: 256 }, fetchImpl, env);
  return parseCoveVerdict(text);
}
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `cd container/agent-runner && bun test src/verification/cove.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/cove.ts container/agent-runner/src/verification/cove.test.ts
git commit -m "feat(factuality): L3 CoVe isolated per-claim triage"
```

---

## Task 5: Web verify + preflight

**Files:**
- Create: `container/agent-runner/src/verification/web-verify.ts`
- Test: `container/agent-runner/src/verification/web-verify.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { parseWebVerdict, webVerify, resetWebPreflight } from './web-verify.js';

test('parseWebVerdict reads supported/refuted/unavailable', () => {
  expect(parseWebVerdict('{"verdict":"refuted","evidence":"sources say 2"}').verdict).toBe('refuted');
  expect(parseWebVerdict('{"verdict":"supported","evidence":"x"}').verdict).toBe('supported');
  expect(parseWebVerdict('junk').verdict).toBe('unavailable'); // unparseable → unavailable (fail-soft)
});

test('webVerify returns unavailable (no-op) when the model rejects the web_search tool', async () => {
  resetWebPreflight();
  const fakeFetch = (async () => new Response('tool not supported', { status: 400 })) as unknown as typeof fetch;
  const r = await webVerify('some claim', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.verdict).toBe('unavailable');
});

test('webVerify returns a verdict when the tool works', async () => {
  resetWebPreflight();
  const fakeFetch = (async () =>
    new Response(JSON.stringify({ content: [{ type: 'text', text: '{"verdict":"refuted","evidence":"e"}' }] }), { status: 200 })
  ) as unknown as typeof fetch;
  const r = await webVerify('some claim', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.verdict).toBe('refuted');
});
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `cd container/agent-runner && bun test src/verification/web-verify.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `container/agent-runner/src/verification/web-verify.ts`:

```ts
import { callMessages, extractJsonObject } from './llm.js';

export type WebVerdict = 'supported' | 'refuted' | 'unavailable';
export interface WebResult { verdict: WebVerdict; evidence: string; }

const MODEL = 'claude-haiku-4-5';
const WEB_TIMEOUT_MS = 30_000;
const TOOLS = [{ type: 'web_search_20250305', name: 'web_search', max_uses: 3 }];

const SYSTEM = [
  'Verify the CLAIM against current web sources. Use the web_search tool.',
  'Return JSON ONLY at the end: {"verdict":"supported|refuted","evidence":"<one line + source>"}.',
  '- supported: sources confirm it.',
  '- refuted: sources contradict it or it cannot be substantiated.',
].join('\n');

// Process-wide preflight latch: once the tool is known unavailable, stop trying.
let preflightFailed = false;
export function resetWebPreflight(): void { preflightFailed = false; }

export function parseWebVerdict(text: string): WebResult {
  const json = extractJsonObject(text);
  if (json !== null) {
    try {
      const o = JSON.parse(json) as { verdict?: unknown; evidence?: unknown };
      if (o.verdict === 'supported' || o.verdict === 'refuted') {
        return { verdict: o.verdict, evidence: typeof o.evidence === 'string' ? o.evidence : '' };
      }
    } catch { /* fall through */ }
  }
  return { verdict: 'unavailable', evidence: '' };
}

/**
 * Harness-side web verification. If the proxy/account doesn't serve the
 * web_search tool (non-200 or a thrown error), latch unavailable and no-op
 * thereafter — the L3 pipeline degrades to CoVe-only.
 */
export async function webVerify(
  claim: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<WebResult> {
  if (preflightFailed) return { verdict: 'unavailable', evidence: '' };
  try {
    const text = await callMessages(
      { system: SYSTEM, user: `CLAIM: ${claim}`, model: MODEL, maxTokens: 1024, tools: TOOLS, timeoutMs: WEB_TIMEOUT_MS },
      fetchImpl, env,
    );
    return parseWebVerdict(text);
  } catch {
    preflightFailed = true;
    return { verdict: 'unavailable', evidence: '' };
  }
}
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `cd container/agent-runner && bun test src/verification/web-verify.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/web-verify.ts container/agent-runner/src/verification/web-verify.test.ts
git commit -m "feat(factuality): L3 harness-side web_search verify + preflight degrade"
```

---

## Task 6: Level-3 orchestrator

**Files:**
- Create: `container/agent-runner/src/verification/level3.ts`
- Test: `container/agent-runner/src/verification/level3.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { aggregateVerdicts, type ClaimOutcome } from './level3.js';

test('aggregateVerdicts: web refuted => fail', () => {
  const outcomes: ClaimOutcome[] = [{ claim: 'a', action_relevant: true, cove: 'contradicted', web: 'refuted' }];
  const r = aggregateVerdicts(outcomes);
  expect(r.failed.map((f) => f.claim)).toEqual(['a']);
});

test('aggregateVerdicts: non-action contradicted (no web) => fail', () => {
  const r = aggregateVerdicts([{ claim: 'b', action_relevant: false, cove: 'contradicted', web: null }]);
  expect(r.failed.map((f) => f.claim)).toEqual(['b']);
});

test('aggregateVerdicts: action uncertain but web unavailable => fail (degrade hedge)', () => {
  const r = aggregateVerdicts([{ claim: 'c', action_relevant: true, cove: 'uncertain', web: 'unavailable' }]);
  expect(r.failed.map((f) => f.claim)).toEqual(['c']);
});

test('aggregateVerdicts: web supported => pass; non-action uncertain => pass; supported => pass', () => {
  const r = aggregateVerdicts([
    { claim: 'd', action_relevant: true, cove: 'contradicted', web: 'supported' },
    { claim: 'e', action_relevant: false, cove: 'uncertain', web: null },
    { claim: 'f', action_relevant: false, cove: 'supported', web: null },
  ]);
  expect(r.failed).toHaveLength(0);
});
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `cd container/agent-runner && bun test src/verification/level3.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `container/agent-runner/src/verification/level3.ts`:

```ts
import { extractClaims, L3_MAX_CLAIMS, type ExtractedClaim } from './claims.js';
import { coveCheck, type CoveVerdict } from './cove.js';
import { webVerify, type WebVerdict } from './web-verify.js';

export const L3_MAX_WEB = 3;

export interface ClaimOutcome {
  claim: string;
  action_relevant: boolean;
  cove: CoveVerdict;
  web: WebVerdict | null; // null = not escalated
}

export interface Level3Result {
  failed: { claim: string; why: string }[]; // claims to bounce/hedge
  checked: number;
  escalated: number;
}

/** Pure verdict aggregation (unit-tested in isolation). */
export function aggregateVerdicts(outcomes: ClaimOutcome[]): Level3Result {
  const failed: { claim: string; why: string }[] = [];
  let escalated = 0;
  for (const o of outcomes) {
    if (o.web !== null) escalated++;
    if (o.web === 'refuted') { failed.push({ claim: o.claim, why: 'web sources refute it' }); continue; }
    if (o.web === 'unavailable' && (o.cove === 'uncertain' || o.cove === 'contradicted')) {
      failed.push({ claim: o.claim, why: 'action-relevant and could not be verified' }); continue;
    }
    if (o.web === null && !o.action_relevant && o.cove === 'contradicted') {
      failed.push({ claim: o.claim, why: 'independent check contradicts it' }); continue;
    }
    // web 'supported', cove 'supported', or non-action 'uncertain' → pass
  }
  return { failed, checked: outcomes.length, escalated };
}

/**
 * Full L3 pass: extract → CoVe each → escalate (action ∧ uncertain/contradicted)
 * to web (capped) → aggregate. fetchImpl/env injectable for tests. Any error in a
 * single stage degrades that claim toward 'pass' (fail-soft) — callers never block
 * delivery on an L3 error; they only act on `failed`.
 */
export async function runLevel3(
  replyText: string,
  sourcesText: string,
  fetchImpl: typeof fetch = globalThis.fetch,
  env: Record<string, string | undefined> = process.env,
): Promise<Level3Result> {
  let claims: ExtractedClaim[] = [];
  try { claims = await extractClaims(replyText, sourcesText, fetchImpl, env); }
  catch { return { failed: [], checked: 0, escalated: 0 }; }

  const outcomes: ClaimOutcome[] = [];
  let webBudget = L3_MAX_WEB;
  for (const c of claims.slice(0, L3_MAX_CLAIMS)) {
    let cove: CoveVerdict = 'uncertain';
    try { cove = (await coveCheck(c.claim, fetchImpl, env)).verdict; } catch { cove = 'uncertain'; }
    let web: WebVerdict | null = null;
    if (c.action_relevant && (cove === 'uncertain' || cove === 'contradicted') && webBudget > 0) {
      webBudget--;
      try { web = (await webVerify(c.claim, fetchImpl, env)).verdict; } catch { web = 'unavailable'; }
    }
    outcomes.push({ claim: c.claim, action_relevant: c.action_relevant, cove, web });
  }
  return aggregateVerdicts(outcomes);
}
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `cd container/agent-runner && bun test src/verification/level3.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/level3.ts container/agent-runner/src/verification/level3.test.ts
git commit -m "feat(factuality): L3 orchestrator (extract -> CoVe -> escalate -> aggregate)"
```

---

## Task 7: Poll-loop — string mode → integer level (behavior-preserving)

**Files:**
- Modify: `container/agent-runner/src/verification/prose-trigger.ts`
- Modify: `container/agent-runner/src/poll-loop.ts`
- Test: `container/agent-runner/src/verification/prose-trigger.test.ts` (update)

This task ONLY renames the knob; levels 0/1/2 must behave exactly as today.

- [ ] **Step 1: Update prose-trigger + its test**

In `container/agent-runner/src/verification/prose-trigger.ts` replace the file body with:

```ts
/**
 * Run the prose judge only when: level >= 2 (tool-prose), the turn produced
 * tool output (the judge's evidence), and the reply has enough prose to be
 * worth judging (≥ 6 words of letters — skips pure numbers, "ok", short acks).
 */
export function shouldJudgeProse(level: number, toolOutputText: string, messageText: string): boolean {
  if (level < 2) return false;
  if (!toolOutputText.trim()) return false;
  const words = (messageText.match(/[A-Za-zА-Яа-яЁё]{2,}/g) ?? []).length;
  return words >= 6;
}
```

In `prose-trigger.test.ts`, replace mode args with levels: calls that passed `'full'` now pass `2`; `'deterministic'`/`'off'` now pass `1`/`0`. Add: `expect(shouldJudgeProse(2, 'tool out', 'this is a long enough sentence here')).toBe(true)` and `expect(shouldJudgeProse(1, 'tool out', 'long sentence here now ok')).toBe(false)`.

- [ ] **Step 2: Update poll-loop to thread `level`**

In `container/agent-runner/src/poll-loop.ts`:

(a) Import: change `import { ... FactualityGate } from './config.js'` usages — replace the `factualityGate?: FactualityGate` field on the poll-loop config interface (line ~133) with `factualityLevel?: import('./config.js').FactualityLevel;`.

(b) Lines ~291–292: replace
```ts
    const gateMode = config.factualityGate ?? 'off';
    const gateOn = gateMode !== 'off';
```
with
```ts
    const level = config.factualityLevel ?? 0;
    const gateOn = level >= 1;
```

(c) The `processQuery(...)` call (line ~322) and its signature (lines ~497–500): replace the `gateMode: ... FactualityGate = 'off'` parameter with `level: number = 0`, and pass `level` at the call site instead of `gateMode`.

(d) Line ~767: replace `if (gateMode === 'full') {` with `if (level >= 2) {`.

(e) Line ~879: replace `shouldJudgeProse(gateMode, sources, event.text)` with `shouldJudgeProse(level, sources, event.text)`.

Leave all other gate logic (the number bounce, prose bounce, hedge text) unchanged.

- [ ] **Step 3: Run the verification + poll-loop tests + full container typecheck**

Run:
```bash
cd container/agent-runner && bun test src/verification/ && cd /Users/serg/git/nanoclaw && pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit
```
Expected: verification tests pass; typecheck clean (the Task-1 break is now resolved — no remaining `FactualityGate` references).

- [ ] **Step 4: Run the full container suite (behavior preserved)**

Run: `cd container/agent-runner && bun test`
Expected: green (modulo the 3 known cross-file `userFacingDispatchCount` flakies). Levels 0/1/2 behave as before.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/prose-trigger.ts container/agent-runner/src/verification/prose-trigger.test.ts container/agent-runner/src/poll-loop.ts
git commit -m "refactor(factuality): poll-loop uses integer level (0-2 behavior unchanged)"
```

---

## Task 8: Poll-loop — wire Level 3 into the result gate

**Files:**
- Modify: `container/agent-runner/src/poll-loop.ts`
- Test: `container/agent-runner/src/poll-loop.factuality-l3.test.ts` (create)

- [ ] **Step 1: Write the failing test (orchestrator wiring contract)**

The poll-loop is integration-heavy; unit-test the decision the wiring encodes by importing `runLevel3` with a fake fetch and asserting the bounce/hedge inputs. Create `container/agent-runner/src/poll-loop.factuality-l3.test.ts`:

```ts
import { test, expect } from 'bun:test';
import { runLevel3 } from './verification/level3.js';

// A reply with one action-relevant claim that CoVe contradicts and web refutes
// must surface as a failed claim (the poll-loop turns `failed` into a bounce).
test('runLevel3 surfaces a refuted action-relevant claim as failed', async () => {
  let call = 0;
  const fakeFetch = (async (_u: string, init: RequestInit) => {
    call++;
    const body = JSON.parse(init.body as string);
    const isWeb = Array.isArray(body.tools);
    const text = call === 1
      ? '{"claims":[{"claim":"Aspirin safe dose is 50 pills/day","action_relevant":true}]}' // extract
      : isWeb ? '{"verdict":"refuted","evidence":"max is far lower"}'                          // web
      : '{"verdict":"contradicted","why":"way too high"}';                                     // cove
    return new Response(JSON.stringify({ content: [{ type: 'text', text }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const r = await runLevel3('reply', 'sources', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.failed).toHaveLength(1);
});
```

- [ ] **Step 2: Run to verify it FAILS / PASSES**

Run: `cd container/agent-runner && bun test src/poll-loop.factuality-l3.test.ts`
Expected: PASS already (it tests Task-6 code). This test is the regression guard for the contract the wiring depends on; if it fails, fix Task 6 before wiring.

- [ ] **Step 3: Add `l3Retries` + the L3 branch in the result gate**

In `container/agent-runner/src/poll-loop.ts`:

(a) Add the import near the other verification imports:
```ts
import { runLevel3 } from './verification/level3.js';
```

(b) Next to `let proseRetries = 0;` (line ~642) add:
```ts
  let l3Retries = 0;
```

(c) Inside the result-event handler, in the `if (!proseBounced) { ... }` block (starts line ~902), insert an L3 stage BEFORE the `const finalText = ...` line. Replace:
```ts
              if (!proseBounced) {
                const finalText = !verdict.grounded
```
with:
```ts
              let l3Bounced = false;
              let l3Hedge: string[] = [];
              if (!proseBounced && level >= 3 && verdict.grounded) {
                const words = (event.text.match(/[A-Za-zА-Яа-яЁё]{2,}/g) ?? []).length;
                if (words >= 6) {
                  const l3 = await runLevel3(event.text, sources);
                  log(`Factuality L3: checked=${l3.checked} escalated=${l3.escalated} failed=${l3.failed.length}`);
                  if (l3.failed.length > 0 && l3Retries < FACTUALITY_MAX_RETRIES) {
                    l3Retries++;
                    resultReceived = false; // correction starts a fresh turn
                    query.push(
                      `<system>A fact-check could not confirm these claims in your reply: ` +
                        l3.failed.map((f) => `"${f.claim}" (${f.why})`).join('; ') +
                        `. Verify each with a tool/web/source, or remove/clearly hedge it, then re-send your full reply.</system>`,
                    );
                    l3Bounced = true;
                  } else if (l3.failed.length > 0) {
                    l3Hedge = l3.failed.map((f) => f.claim);
                  }
                }
              }
              if (!proseBounced && !l3Bounced) {
                const finalText = !verdict.grounded
```

(d) Extend the `finalText` hedge ternary to include the L3 hedge. Replace:
```ts
                const finalText = !verdict.grounded
                  ? `${event.text}\n\n⚠️ Часть чисел выше я не смог подтвердить по источнику — перепроверь перед использованием.`
                  : proseHedge
                    ? `${event.text}\n\n⚠️ Факты не проверены (проверяльщик недоступен).`
                    : event.text;
```
with:
```ts
                const finalText = !verdict.grounded
                  ? `${event.text}\n\n⚠️ Часть чисел выше я не смог подтвердить по источнику — перепроверь перед использованием.`
                  : proseHedge
                    ? `${event.text}\n\n⚠️ Факты не проверены (проверяльщик недоступен).`
                    : l3Hedge.length > 0
                      ? `${event.text}\n\n⚠️ Эти утверждения я не смог подтвердить — перепроверь: ${l3Hedge.join('; ')}.`
                      : event.text;
```

(e) The existing closing braces of the `if (!proseBounced)` block now match the new `if (!proseBounced && !l3Bounced)`. Verify the brace nesting compiles (Step 4).

- [ ] **Step 4: Typecheck + run**

Run:
```bash
cd /Users/serg/git/nanoclaw && pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit && cd container/agent-runner && bun test
```
Expected: typecheck clean; suite green (modulo known flakies). Level <3 paths untouched (no L3 calls fire).

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/poll-loop.ts container/agent-runner/src/poll-loop.factuality-l3.test.ts
git commit -m "feat(factuality): wire Level 3 (CoVe->web) into the result gate"
```

---

## Task 9: Host — `factuality_level` column + plumbing

**Files:**
- Create: `src/db/migrations/0XX-factuality-level.ts` (use the next free number — currently 020)
- Modify: `src/db/migrations/index.ts`, `src/types.ts`, `src/container-config.ts`, `src/db/container-configs.ts`, `src/backfill-container-configs.ts`
- Test: `src/db/db-v2.test.ts` (append a migration assertion) OR a new `src/db/factuality-level.test.ts`

- [ ] **Step 1: Write the failing migration test**

Create `src/db/factuality-level.test.ts`. The migration runner is `runMigrations(db: Database.Database)` exported from `./migrations/index.js` (confirmed: `src/db/migrations/index.ts:48`). Two assertions — the column exists after a full migrate, and the backfill `CASE` maps correctly (tested on a toy table so it doesn't depend on the `container_configs` column set):

```ts
import { describe, it, expect } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from './migrations/index.js';

describe('migration 020 factuality_level', () => {
  it('adds factuality_level to container_configs after a full migrate', () => {
    const db = new Database(':memory:');
    runMigrations(db);
    const cols = db.prepare('PRAGMA table_info(container_configs)').all() as { name: string }[];
    expect(cols.some((c) => c.name === 'factuality_level')).toBe(true);
  });

  it('backfill CASE maps gate string -> level int', () => {
    const db = new Database(':memory:');
    db.exec('CREATE TABLE t (g TEXT, lvl INTEGER NOT NULL DEFAULT 0)');
    db.prepare("INSERT INTO t (g) VALUES ('full'),('deterministic'),('off'),(NULL)").run();
    db.prepare("UPDATE t SET lvl = CASE g WHEN 'deterministic' THEN 1 WHEN 'full' THEN 2 ELSE 0 END").run();
    const rows = db.prepare('SELECT g, lvl FROM t').all() as { g: string | null; lvl: number }[];
    expect(rows.find((r) => r.g === 'full')!.lvl).toBe(2);
    expect(rows.find((r) => r.g === 'deterministic')!.lvl).toBe(1);
    expect(rows.find((r) => r.g === 'off')!.lvl).toBe(0);
    expect(rows.find((r) => r.g === null)!.lvl).toBe(0);
  });
});
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `pnpm exec vitest run src/db/factuality-level.test.ts`
Expected: FAIL — column `factuality_level` doesn't exist.

- [ ] **Step 3: Create the migration**

Create `src/db/migrations/020-factuality-level.ts`:

```ts
import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration020: Migration = {
  version: 20,
  name: 'factuality-level',
  up(db: Database.Database) {
    db.prepare('ALTER TABLE container_configs ADD COLUMN factuality_level INTEGER NOT NULL DEFAULT 0').run();
    db.prepare(
      "UPDATE container_configs SET factuality_level = CASE factuality_gate " +
        "WHEN 'deterministic' THEN 1 WHEN 'full' THEN 2 ELSE 0 END",
    ).run();
  },
};
```

Register it in `src/db/migrations/index.ts` (import + add to the ordered migrations array, after `migration019`).

- [ ] **Step 4: Plumb the field through host config**

- `src/types.ts:28` — add below `factuality_gate`: `factuality_level: number;`
- `src/container-config.ts:46` — add `factualityLevel?: number;` to the `ContainerConfig` interface. Line ~67 — add to `configFromDb`: `factualityLevel: typeof row.factuality_level === 'number' ? row.factuality_level : 0,`
- `src/db/container-configs.ts` — add `'factuality_level'` to `SCALAR_COLUMNS` (line ~13) and to the update Pick union (line ~78).
- `src/backfill-container-configs.ts:68` — add `factuality_level: 0,` to the inserted row literal.
- Wherever container.json is materialized from `ContainerConfig` (grep `factualityGate` in `src/container-runner.ts` / `src/container-config.ts`), write `factualityLevel` into the JSON (keep writing the legacy `factualityGate` too for one release so an old container image still works).

- [ ] **Step 5: Run the migration test + host build + suite**

Run:
```bash
pnpm exec vitest run src/db/factuality-level.test.ts && pnpm run build && pnpm test
```
Expected: migration test passes; build clean; suite green.

- [ ] **Step 6: Commit**

```bash
git add src/db/migrations/020-factuality-level.ts src/db/migrations/index.ts src/types.ts src/container-config.ts src/db/container-configs.ts src/backfill-container-configs.ts src/db/factuality-level.test.ts
git commit -m "feat(factuality): host factuality_level column + plumbing (backfill from gate)"
```

---

## Task 10: Deploy + pilot

**Files:** none (operational).

- [ ] **Step 1: Deploy host + agent-runner to VDS**

```bash
git push
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull --ff-only && pnpm run build && XDG_RUNTIME_DIR=/run/user/\$(id -u nanoclaw) systemctl --user restart nanoclaw && echo DEPLOY_OK"'
```
The migration runs on host startup (adds `factuality_level`, backfills). agent-runner is host-mounted — new code is live on next container spawn; no image rebuild.

- [ ] **Step 2: web_search preflight check (live)**

Probe whether the proxy/account serves the `web_search` tool, so you know if L3 will run full or degrade to CoVe-only. From a live agent container session (creds are runtime-injected — a throwaway container shows "no creds"), or check the first `Factuality L3:` log after enabling L3: a `webVerify` returning `unavailable` repeatedly ⇒ tool not wired (degrade path active). Document the result.

- [ ] **Step 3: Pilot — flip scrooge to level 3**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -s' <<'REMOTE'
cd ~/nanoclaw
pnpm exec tsx scripts/q.ts data/v2.db "UPDATE container_configs SET factuality_level=3 WHERE agent_group_id='scrooge'"
./bin/ncl groups restart --id scrooge
REMOTE
```

- [ ] **Step 4: Live probe**

Message scrooge a question that invites a parametric/world claim (e.g. a market/tax/world fact it would state from memory, action-relevant). Confirm in the VDS logs (`logs/nanoclaw.log` / docker logs while the container is alive): a `Factuality L3:` line with `checked>0`, and that a wrong action-relevant claim is bounced/hedged rather than delivered confidently. Measure added latency.

- [ ] **Step 5: Decide rollout**

Based on the pilot's cost/latency/accuracy: keep scrooge at 3, and decide per-agent (greg/gordon at 3? jarvis stays ≤2 for cost?) via the same q.ts UPDATE + `./bin/ncl groups restart`. No code change.

---

## Final verification (whole feature)

- [ ] Container: `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit && (cd container/agent-runner && bun test)` — green (modulo 3 known flakies).
- [ ] Host: `pnpm run build && pnpm test` — green.
- [ ] Levels 0–2 unchanged: a level-1 agent gates only numbers; a level-2 agent runs the prose judge; neither makes any L3 call (grep logs — no `Factuality L3:` line below level 3).
- [ ] Level 3 live (scrooge): `Factuality L3:` fires; action-relevant wrong claim bounced/hedged; non-action trivia not web-escalated.

---

## Self-review notes (coverage vs spec)

- Spec Component 1 (level config) → Task 1 (container) + Task 9 (host migration+plumbing). Legacy fallback in `parseFactualityLevel` + container.json dual-write = decoupled deploy order.
- Spec Component 2 (L3 pipeline: extract→CoVe→web→verdict) → Tasks 3,4,5,6 (modules) + Task 8 (wiring). Escalation gate (`action ∧ uncertain/contradicted`) lives in `runLevel3`; verdict aggregation (incl. degrade-path fail) in `aggregateVerdicts` (unit-tested).
- Spec Component 3 (caps/observability/fail-soft/preflight) → `L3_MAX_CLAIMS`/`L3_MAX_WEB`/`l3Retries`; `Factuality L3:` log; per-stage try/catch fail-soft; `web-verify` preflight latch.
- Spec Component 4 (testing/rollout) → per-task `bun test`/`vitest` + Task 10 pilot.
- Behavior-preservation for levels 0–2 is its own task (Task 7) with an explicit "behavior unchanged" gate.
