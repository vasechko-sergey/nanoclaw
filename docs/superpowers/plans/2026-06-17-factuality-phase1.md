# Factuality Gate — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the cheap deterministic core of the factuality gate — a harness-enforced check (outside the agent's prompt) that blocks any quantitative claim (numbers/currency/%) not grounded in this turn's tool outputs or the user's own message, forcing the agent to verify or hedge. Pilot on Scrooge.

**Architecture:** All enforcement lives in the agent-runner (`container/agent-runner/src/`, Bun). A pure verification module (number extraction + provenance check) is wired into the poll-loop's outbound path. When the per-agent `factualityGate` flag is `deterministic`, the loop suppresses mid-stream dispatch, accumulates this turn's tool outputs as a grounding set, gates the final `<message>` text, and on an ungrounded number pushes a correction back into the SDK to regenerate (cap 2 → fallback hedge). Flag default `off` → zero behavior change for every other agent. Pilot enablers: a tool-grounding nudge in the shared instructions (L0) and a Bybit-fee script for Scrooge (L1) so the gate yields a real answer, not just a hedge.

**Tech Stack:** Bun + TypeScript; tests `bun:test`; Claude Agent SDK; SQLite session DBs. Host plumbing in Node/pnpm (`src/`).

**Spec:** [docs/superpowers/specs/2026-06-17-factuality-architecture-design.md](../specs/2026-06-17-factuality-architecture-design.md) (this is Phase 1 of it).

---

## Environment notes

- Container runtime is **Bun**, NOT a pnpm workspace. After editing `container/agent-runner/`, run `cd container/agent-runner && bun test` and `bun run typecheck` (or `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit` from root). Tests import from `bun:test`, never `vitest`.
- Named-param SQL in the container uses `$name` in both SQL and JS keys (bun:sqlite does not strip the prefix).
- `groups/` is **gitignored** — Tasks 9-11 deploy via scp to the VDS, not git (see the factual-discipline plan for the scp/rebirth pattern). The agent-runner `src/` is host-mounted into the container, so Tasks 1-7 deploy by `git pull` + container restart, **no image rebuild**.
- Agent-runner host-mounted: a `git pull` + `ncl groups restart` picks up `src/` changes. Host (`src/`) changes need `pnpm run build` on the VDS.

## File Structure

| Path | Responsibility | Action |
|------|----------------|--------|
| `container/agent-runner/src/verification/numbers.ts` | Extract + normalize quantitative data-tokens from text | Create |
| `container/agent-runner/src/verification/numbers.test.ts` | Unit tests for extraction/normalization | Create |
| `container/agent-runner/src/verification/gate.ts` | `checkProvenance(body, grounding)` → grounded? + ungrounded list | Create |
| `container/agent-runner/src/verification/gate.test.ts` | Unit tests for the provenance decision | Create |
| `container/agent-runner/src/providers/types.ts` | Carry tool output text on `tool_use_end` | Modify |
| `container/agent-runner/src/providers/claude.ts` | Extract `tool_result` text → `output` | Modify |
| `container/agent-runner/src/providers/claude.test.ts` | Unit test the tool-result text extractor | Create |
| `container/agent-runner/src/config.ts` | Read `factualityGate` from container.json | Modify |
| `container/agent-runner/src/config.test.ts` | Unit test the flag parse + default | Create |
| `container/agent-runner/src/poll-loop.ts` | Grounding accumulation + gate-at-result + regenerate; flag-gated | Modify |
| `container/agent-runner/src/index.ts` | Pass `factualityGate` into the poll loop | Modify |
| `src/container-config.ts` | Materialize `factualityGate` into container.json (host) | Modify |
| `groups/INSTRUCTIONS.md` | L0 tool-grounding nudge (gitignored, scp) | Modify |
| `groups/scrooge/scripts/bybit-fees.js` | L1 Bybit withdrawal-fee lookup (gitignored, scp) | Create |

---

## Task 1: Number extraction + normalization (pure)

**Files:**
- Create: `container/agent-runner/src/verification/numbers.ts`
- Test: `container/agent-runner/src/verification/numbers.test.ts`

Scope (Phase-1 heuristic to bound false positives): only treat a token as a **data number** if it carries a currency symbol, a `%`, a decimal point, or magnitude ≥ 100. Bare small integers (`2 варианта`, list counts) are ignored.

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { extractDataNumbers, normalizeNumber } from './numbers.js';

test('normalizeNumber strips currency, %, thousands separators', () => {
  expect(normalizeNumber('$1.60')).toBe('1.6');
  expect(normalizeNumber('0.10%')).toBe('0.1');
  expect(normalizeNumber('8,728')).toBe('8728');
  expect(normalizeNumber('1 600')).toBe('1600');
});

test('extractDataNumbers picks currency/%/decimal/large, skips small bare ints', () => {
  const got = extractDataNumbers('Комиссия $1.60 и 0.1%, остаток 8,728, было 2 варианта и 3 подхода');
  expect(got.has('1.6')).toBe(true);
  expect(got.has('0.1')).toBe(true);
  expect(got.has('8728')).toBe(true);
  expect(got.has('2')).toBe(false);
  expect(got.has('3')).toBe(false);
});

test('extractDataNumbers returns empty for prose with no data', () => {
  expect(extractDataNumbers('привет, как дела').size).toBe(0);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/verification/numbers.test.ts`
Expected: FAIL — module not found / functions undefined.

- [ ] **Step 3: Write minimal implementation**

```ts
// container/agent-runner/src/verification/numbers.ts

/** Strip currency symbols, %, spaces, and thousands separators; return a
 *  canonical numeric string (parseFloat round-trip). Returns '' if not numeric. */
export function normalizeNumber(token: string): string {
  const cleaned = token
    .replace(/[$€₽£¥]/g, '')
    .replace(/%/g, '')
    .replace(/\s/g, '')
    .replace(/,/g, '');
  if (!/^\d*\.?\d+$/.test(cleaned)) return '';
  const n = parseFloat(cleaned);
  if (Number.isNaN(n)) return '';
  return String(n);
}

const TOKEN_RE = /[$€₽£¥]?\s?\d[\d.,\s]*\d|\d+(?:\.\d+)?%?|\d/g;

/** Extract canonical data-numbers worth grounding. Phase-1 heuristic: keep a
 *  number only if it has a currency symbol, a %, a decimal point, or magnitude
 *  >= 100. Bare small integers (list counts, "2 варианта") are ignored. */
export function extractDataNumbers(text: string): Set<string> {
  const out = new Set<string>();
  const matches = text.match(TOKEN_RE) ?? [];
  for (const raw of matches) {
    const trimmed = raw.trim();
    const hasCurrency = /[$€₽£¥]/.test(trimmed);
    const hasPercent = /%/.test(trimmed);
    const hasDecimal = /\d\.\d/.test(trimmed);
    const norm = normalizeNumber(trimmed);
    if (!norm) continue;
    const magnitudeBig = Math.abs(parseFloat(norm)) >= 100;
    if (hasCurrency || hasPercent || hasDecimal || magnitudeBig) {
      out.add(norm);
    }
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd container/agent-runner && bun test src/verification/numbers.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/numbers.ts container/agent-runner/src/verification/numbers.test.ts
git commit -m "feat(agent-runner): data-number extraction for factuality gate"
```

---

## Task 2: Provenance decision (pure)

**Files:**
- Create: `container/agent-runner/src/verification/gate.ts`
- Test: `container/agent-runner/src/verification/gate.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { checkProvenance } from './gate.js';

test('grounded when every data-number appears in the grounding set', () => {
  const grounding = new Set(['1.6', '8728']);
  const r = checkProvenance('Комиссия $1.60, остаток 8,728', grounding);
  expect(r.grounded).toBe(true);
  expect(r.ungrounded).toEqual([]);
});

test('ungrounded number is flagged', () => {
  const grounding = new Set(['8728']);
  const r = checkProvenance('Комиссия TRC-20 ~$1.60', grounding);
  expect(r.grounded).toBe(false);
  expect(r.ungrounded).toContain('1.6');
});

test('no data-numbers → grounded (nothing to check)', () => {
  const r = checkProvenance('привет', new Set());
  expect(r.grounded).toBe(true);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/verification/gate.test.ts`
Expected: FAIL — `checkProvenance` undefined.

- [ ] **Step 3: Write minimal implementation**

```ts
// container/agent-runner/src/verification/gate.ts
import { extractDataNumbers } from './numbers.js';

export interface ProvenanceResult {
  grounded: boolean;
  /** Canonical numbers present in the message but absent from the grounding set. */
  ungrounded: string[];
}

/** A message body is grounded iff every data-number in it also appears in the
 *  grounding set (this turn's tool outputs ∪ the user's own message). */
export function checkProvenance(body: string, grounding: Set<string>): ProvenanceResult {
  const claimed = extractDataNumbers(body);
  const ungrounded: string[] = [];
  for (const n of claimed) {
    if (!grounding.has(n)) ungrounded.push(n);
  }
  return { grounded: ungrounded.length === 0, ungrounded };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd container/agent-runner && bun test src/verification/gate.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/verification/gate.ts container/agent-runner/src/verification/gate.test.ts
git commit -m "feat(agent-runner): provenance decision for factuality gate"
```

---

## Task 3: Carry tool output on the provider event

**Files:**
- Modify: `container/agent-runner/src/providers/types.ts:118`

- [ ] **Step 1: Change the event type**

Find:
```ts
  /** Pair of `tool_use_start`. See that event's docs. */
  | { type: 'tool_use_end'; id: string }
```
Replace with:
```ts
  /** Pair of `tool_use_start`. See that event's docs. `output` carries the
   *  tool_result text (when the provider can surface it) so the poll-loop can
   *  build a per-turn grounding set for the factuality gate. */
  | { type: 'tool_use_end'; id: string; output?: string }
```

- [ ] **Step 2: Typecheck**

Run: `cd container/agent-runner && bun run typecheck`
Expected: PASS (no usages break — `output` is optional).

- [ ] **Step 3: Commit**

```bash
git add container/agent-runner/src/providers/types.ts
git commit -m "feat(agent-runner): add optional output to tool_use_end event"
```

---

## Task 4: Extract tool_result text in the Claude provider

**Files:**
- Modify: `container/agent-runner/src/providers/claude.ts:351-365`
- Create: `container/agent-runner/src/providers/claude.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { extractToolResultText } from './claude.js';

test('extractToolResultText reads a string content block', () => {
  expect(extractToolResultText('TRC20 fee: 0.80 USDT')).toBe('TRC20 fee: 0.80 USDT');
});

test('extractToolResultText joins array text blocks', () => {
  const content = [{ type: 'text', text: 'fee 0.80' }, { type: 'text', text: ' net 0.1%' }];
  expect(extractToolResultText(content)).toBe('fee 0.80  net 0.1%');
});

test('extractToolResultText returns empty for unknown shapes', () => {
  expect(extractToolResultText(undefined)).toBe('');
  expect(extractToolResultText(42 as unknown)).toBe('');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/providers/claude.test.ts`
Expected: FAIL — `extractToolResultText` not exported.

- [ ] **Step 3: Add the exported helper and use it**

Add near the top of `claude.ts` (after the imports):
```ts
/** Pull plain text out of an SDK tool_result `content` field, which may be a
 *  string or an array of `{ type: 'text', text }` blocks. Used to feed the
 *  factuality gate's grounding set. */
export function extractToolResultText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((c) => (c && typeof c === 'object' && 'text' in c && typeof (c as { text?: unknown }).text === 'string' ? (c as { text: string }).text : ''))
      .join('');
  }
  return '';
}
```

Then in the `message.type === 'user'` branch (currently lines 351-365), replace:
```ts
              if (p.type === 'tool_result' && typeof p.tool_use_id === 'string' && p.tool_use_id.length > 0) {
                yield { type: 'tool_use_end', id: p.tool_use_id };
              }
```
with:
```ts
              if (p.type === 'tool_result' && typeof p.tool_use_id === 'string' && p.tool_use_id.length > 0) {
                const pr = p as { tool_use_id: string; content?: unknown };
                yield { type: 'tool_use_end', id: pr.tool_use_id, output: extractToolResultText(pr.content) };
              }
```
(Update the inline cast type `{ type?: string; tool_use_id?: string }` on the line above to also allow `content?: unknown` if the typecheck requires it.)

- [ ] **Step 4: Run test + typecheck**

Run: `cd container/agent-runner && bun test src/providers/claude.test.ts && bun run typecheck`
Expected: PASS (3 tests), typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/providers/claude.ts container/agent-runner/src/providers/claude.test.ts
git commit -m "feat(agent-runner): surface tool_result text on tool_use_end"
```

---

## Task 5: Read the `factualityGate` flag from config

**Files:**
- Modify: `container/agent-runner/src/config.ts:12-53`
- Create: `container/agent-runner/src/config.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { test, expect } from 'bun:test';
import { parseFactualityGate } from './config.js';

test('parseFactualityGate defaults to off', () => {
  expect(parseFactualityGate(undefined)).toBe('off');
  expect(parseFactualityGate('nonsense')).toBe('off');
});

test('parseFactualityGate accepts known modes', () => {
  expect(parseFactualityGate('deterministic')).toBe('deterministic');
  expect(parseFactualityGate('full')).toBe('full');
  expect(parseFactualityGate('off')).toBe('off');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd container/agent-runner && bun test src/config.test.ts`
Expected: FAIL — `parseFactualityGate` undefined.

- [ ] **Step 3: Implement the parser, field, and load**

Add the type + parser to `config.ts`:
```ts
export type FactualityGate = 'off' | 'deterministic' | 'full';

export function parseFactualityGate(raw: unknown): FactualityGate {
  return raw === 'deterministic' || raw === 'full' ? raw : 'off';
}
```
Add to the `RunnerConfig` interface (after `effort?`):
```ts
  factualityGate: FactualityGate;
```
Add to the `_config = { ... }` object in `loadConfig()` (after `effort:`):
```ts
    factualityGate: parseFactualityGate(raw.factualityGate),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd container/agent-runner && bun test src/config.test.ts && bun run typecheck`
Expected: PASS (2 tests), typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add container/agent-runner/src/config.ts container/agent-runner/src/config.test.ts
git commit -m "feat(agent-runner): factualityGate config flag (default off)"
```

---

## Task 6: Wire the gate into the poll loop (flag-gated)

**Files:**
- Modify: `container/agent-runner/src/poll-loop.ts` (`PollLoopConfig`, `processQuery`, dispatch paths)
- Test: `container/agent-runner/src/poll-loop.factuality.test.ts` (create)

The default (`off`) path must be byte-for-byte unchanged. All new logic is behind `config.factualityGate !== 'off'`.

- [ ] **Step 1: Add the flag to PollLoopConfig**

In `PollLoopConfig` (line 108) add:
```ts
  factualityGate?: import('./config.js').FactualityGate;
```

- [ ] **Step 2: Build the grounding set + thread it into processQuery**

In `runPollLoop`, before `const query = config.provider.query(...)` (line 274), seed grounding from the user prompt:
```ts
    const gateOn = (config.factualityGate ?? 'off') !== 'off';
    const grounding = new Set<string>();
    if (gateOn) {
      const { extractDataNumbers } = await import('./verification/numbers.js');
      for (const n of extractDataNumbers(prompt)) grounding.add(n);
    }
```
Change the `processQuery(...)` call (line 297) to pass `gateOn` and `grounding`:
```ts
      const result = await processQuery(query, routing, processingIds, config.providerName, gateOn, grounding);
```
Update the `processQuery` signature (line 446) to accept them:
```ts
async function processQuery(
  query: AgentQuery,
  routing: RoutingContext,
  initialBatchIds: string[],
  providerName: string,
  gateOn = false,
  grounding: Set<string> = new Set(),
): Promise<QueryResult> {
```

- [ ] **Step 3: Accumulate tool outputs into the grounding set**

In `processQuery`, where `tool_use_end` is handled (line 702), add output extraction:
```ts
      } else if (event.type === 'tool_use_end') {
        inFlightTools.delete(event.id);
        if (gateOn && event.output) {
          const { extractDataNumbers } = await import('./verification/numbers.js');
          for (const n of extractDataNumbers(event.output)) grounding.add(n);
        }
      }
```
On a follow-up `push` (line 542), also fold the follow-up prompt's numbers in. Immediately after `query.push(prompt);` add:
```ts
        if (gateOn) {
          const { extractDataNumbers } = await import('./verification/numbers.js');
          for (const n of extractDataNumbers(prompt)) grounding.add(n);
        }
```

- [ ] **Step 4: Suppress streaming dispatch when the gate is on**

Streaming dispatch sends blocks before the full message is known. When `gateOn`, buffer only — gate at `result`. In the `assistant_text` branch (line 731-733) change:
```ts
        streamBuffer += event.text;
        const remainder = dispatchCompleteBlocks(streamBuffer, routing, dispatchedKeys);
        streamBuffer = remainder;
```
to:
```ts
        streamBuffer += event.text;
        if (!gateOn) {
          const remainder = dispatchCompleteBlocks(streamBuffer, routing, dispatchedKeys);
          streamBuffer = remainder;
        }
```
(When `gateOn`, `streamBuffer` keeps growing and is handled at `result` — which already resets it before calling `dispatchResultText`.)

- [ ] **Step 5: Gate at the result path + regenerate on catch**

This is the core enforcement. Add a module-level constant near the others (line 42):
```ts
const FACTUALITY_MAX_RETRIES = 2;
```
Add per-turn retry state in `processQuery` (near `let resultReceived = false;`, line 583):
```ts
  let factualityRetries = 0;
```
In the `result` branch, the existing code (line 767-791) dispatches `event.text` via `dispatchResultText`. Wrap that dispatch so, when `gateOn`, the text is gated FIRST:
```ts
        if (event.text) {
          streamBuffer = '';
          if (gateOn) {
            const { gateOutboundText } = await import('./verification/poll-gate.js');
            const verdict = gateOutboundText(event.text, grounding);
            if (!verdict.grounded && factualityRetries < FACTUALITY_MAX_RETRIES) {
              factualityRetries++;
              resultReceived = false; // a correction starts a fresh turn
              query.push(
                `<system>Your reply asserted these numbers with no source this turn: ${verdict.ungrounded.join(', ')}. ` +
                  `Do not state a number you did not get from a tool/script output or the user this turn. ` +
                  `Call the right tool/script to verify, or remove/hedge the number, then re-send.</system>`,
              );
              continue;
            }
            // Grounded, or retry budget exhausted: on exhaustion, hedge.
            const finalText = verdict.grounded
              ? event.text
              : `${event.text}\n\n⚠️ Часть чисел выше я не смог проверить по источнику.`;
            const { hasUnwrapped } = dispatchResultText(finalText, routing, dispatchedKeys);
            dispatchedKeys = new Set<string>();
            void hasUnwrapped;
          } else {
            const { hasUnwrapped } = dispatchResultText(event.text, routing, dispatchedKeys);
            dispatchedKeys = new Set<string>();
            if (hasUnwrapped && !unwrappedNudged) {
              unwrappedNudged = true;
              const destinations = getAllDestinations();
              const names = destinations.map((d) => d.name).join(', ');
              resultReceived = false;
              query.push(
                `<system>Your response was not delivered — it was not wrapped in <message to="name">...</message> blocks. ` +
                  `All output must be wrapped: use <message to="name"> for content to send, or <internal> for scratchpad. ` +
                  `Your destinations: ${names}. ` +
                  `Please re-send your response with the correct wrapping.</system>`,
              );
            }
          }
        }
```
(The `off` branch is the original code verbatim — keep it identical so default behavior is unchanged.)

- [ ] **Step 6: Add the per-block gate helper**

Create `container/agent-runner/src/verification/poll-gate.ts`:
```ts
import { checkProvenance } from './gate.js';

const MESSAGE_BLOCK_RE = /<message\s+to="([^"]+)"\s*>([\s\S]*?)<\/message>/g;

export interface GateVerdict {
  grounded: boolean;
  ungrounded: string[];
}

/** Run provenance over every <message> block's body in the aggregated result
 *  text. Ungrounded across all blocks are merged. Text with no blocks (pure
 *  scratchpad) is treated as grounded — the no-wrap nudge handles that case. */
export function gateOutboundText(text: string, grounding: Set<string>): GateVerdict {
  MESSAGE_BLOCK_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  const ungrounded = new Set<string>();
  while ((match = MESSAGE_BLOCK_RE.exec(text)) !== null) {
    const r = checkProvenance(match[2], grounding);
    for (const n of r.ungrounded) ungrounded.add(n);
  }
  return { grounded: ungrounded.size === 0, ungrounded: [...ungrounded] };
}
```

- [ ] **Step 7: Write the integration test**

```ts
// container/agent-runner/src/verification/poll-gate.test.ts
import { test, expect } from 'bun:test';
import { gateOutboundText } from './poll-gate.js';

test('flags an ungrounded number inside a <message> block', () => {
  const text = '<message to="user">Комиссия TRC-20 ~$1.60</message>';
  const v = gateOutboundText(text, new Set(['8728']));
  expect(v.grounded).toBe(false);
  expect(v.ungrounded).toContain('1.6');
});

test('passes when the number is in the grounding set', () => {
  const text = '<message to="user">Комиссия $0.80 (из API)</message>';
  const v = gateOutboundText(text, new Set(['0.8']));
  expect(v.grounded).toBe(true);
});

test('scratchpad-only text is grounded', () => {
  expect(gateOutboundText('<internal>thinking 1.60</internal>', new Set()).grounded).toBe(true);
});
```

- [ ] **Step 8: Run tests + typecheck**

Run: `cd container/agent-runner && bun test src/verification/ && bun run typecheck`
Expected: PASS (numbers + gate + poll-gate suites), typecheck clean.

- [ ] **Step 9: Commit**

```bash
git add container/agent-runner/src/poll-loop.ts container/agent-runner/src/verification/poll-gate.ts container/agent-runner/src/verification/poll-gate.test.ts
git commit -m "feat(agent-runner): deterministic factuality gate in poll-loop (flag-gated)"
```

---

## Task 7: Pass the flag from entry into the loop

**Files:**
- Modify: `container/agent-runner/src/index.ts:98-103`

- [ ] **Step 1: Thread the config flag**

Change the `runPollLoop({...})` call to include the flag:
```ts
  await runPollLoop({
    provider,
    providerName,
    cwd: CWD,
    systemContext: { instructions },
    factualityGate: config.factualityGate,
  });
```

- [ ] **Step 2: Typecheck**

Run: `cd container/agent-runner && bun run typecheck`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add container/agent-runner/src/index.ts
git commit -m "feat(agent-runner): pass factualityGate from config into poll-loop"
```

---

## Task 8: Materialize the flag into container.json (host)

**Files:**
- Modify: `src/container-config.ts`

The host writes `/workspace/agent/container.json` from the `container_configs` row. The flag must be copied through so the runner can read it.

- [ ] **Step 1: Locate the materialization**

Run:
```bash
grep -n "agentGroupId\|assistantName\|JSON.stringify\|container.json\|maxMessagesPerPrompt" src/container-config.ts
```
Expected: the function that builds the container.json object (the same place `assistantName`, `model`, `mcpServers` are written).

- [ ] **Step 2: Write the failing test**

Add to the existing host test for container-config (find it: `grep -rl "container-config" src/*.test.ts`; if none, create `src/container-config.test.ts`):
```ts
import { test, expect } from 'vitest';
import { buildContainerJson } from './container-config.js'; // use the actual exported builder name found in Step 1

test('factualityGate passes through, defaults off', () => {
  const withFlag = buildContainerJson({ /* minimal cfg */ factualityGate: 'deterministic' } as any);
  expect(withFlag.factualityGate).toBe('deterministic');
  const without = buildContainerJson({} as any);
  expect(without.factualityGate ?? 'off').toBe('off');
});
```
(Adjust `buildContainerJson` to the real function name + minimal args discovered in Step 1.)

- [ ] **Step 3: Run test to verify it fails**

Run: `pnpm test src/container-config.test.ts`
Expected: FAIL — field absent.

- [ ] **Step 4: Add the field to the materialized object**

In the container.json object literal, add alongside `model`/`assistantName`:
```ts
    factualityGate: config.factualityGate ?? 'off',
```
(Source the value from the `container_configs` config blob. If the config type lacks the field, add `factualityGate?: 'off' | 'deterministic' | 'full'` to the host-side config type in `src/db/container-configs.ts`.)

- [ ] **Step 5: Run test + build**

Run: `pnpm test src/container-config.test.ts && pnpm run build`
Expected: PASS, build clean.

- [ ] **Step 6: Commit**

```bash
git add src/container-config.ts src/db/container-configs.ts src/container-config.test.ts
git commit -m "feat(host): materialize factualityGate into container.json"
```

---

## Task 9: L0 — tool-grounding nudge in shared instructions

**Files:**
- Modify: `groups/INSTRUCTIONS.md` (gitignored; deploy by scp)

- [ ] **Step 1: Append to the Factual discipline section**

After the `**Self-check (mandatory ...)**` paragraph in `## Factual discipline`, add:
```markdown

**Grounding (enforced).** For a quantitative claim (number, currency, %, fee,
rate, price), the value must come from a tool/script output or the user's
message *this turn*. The harness checks this and will reject a reply whose
numbers it cannot trace to a source — you'll be asked to verify via a tool or
drop the number. Prefer calling the right script/API over recalling a figure.
```

- [ ] **Step 2: Deploy + verify (scp)**

```bash
scp ~/git/nanoclaw/groups/INSTRUCTIONS.md root@148.253.211.164:/tmp/INSTRUCTIONS.md
ssh root@148.253.211.164 'mv /tmp/INSTRUCTIONS.md /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md && chown nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md'
diff <(cat ~/git/nanoclaw/groups/INSTRUCTIONS.md) <(ssh root@148.253.211.164 'cat /home/nanoclaw/nanoclaw/groups/INSTRUCTIONS.md')
```
Expected: `diff` empty. (Rebirth happens in Task 11.)

---

## Task 10: L1 — Bybit withdrawal-fee script for Scrooge

**Files:**
- Create: `groups/scrooge/scripts/bybit-fees.js` (gitignored; deploy by scp)

Gives Scrooge a real source so the gate yields a correct answer, not just a hedge. Bybit's public endpoint `GET /v5/asset/coin/query-info?coin=USDT` returns per-chain withdrawal fees.

- [ ] **Step 1: Write the script**

```js
// groups/scrooge/scripts/bybit-fees.js — usage: bun bybit-fees.js USDT
const coin = (process.argv[2] || 'USDT').toUpperCase();
const url = `https://api.bybit.com/v5/asset/coin/query-info?coin=${coin}`;
const r = await fetch(url);
const j = await r.json();
const rows = j?.result?.rows?.[0]?.chains ?? [];
if (!rows.length) { console.log(JSON.stringify({ error: 'no data', coin })); process.exit(0); }
const fees = rows.map((c) => ({ chain: c.chain, chainType: c.chainType, withdrawFee: c.withdrawFee, withdrawMin: c.withdrawMin }));
console.log(JSON.stringify({ coin, fees }, null, 2));
```

- [ ] **Step 2: Deploy + smoke-test (scp + run in a throwaway agent container)**

```bash
scp ~/git/nanoclaw/groups/scrooge/scripts/bybit-fees.js root@148.253.211.164:/tmp/bybit-fees.js
ssh root@148.253.211.164 'mkdir -p /home/nanoclaw/nanoclaw/groups/scrooge/scripts && mv /tmp/bybit-fees.js /home/nanoclaw/nanoclaw/groups/scrooge/scripts/bybit-fees.js && chown -R nanoclaw:nanoclaw /home/nanoclaw/nanoclaw/groups/scrooge/scripts'
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "IMG=\$(docker images --format {{.Repository}}:{{.Tag}} | grep -m1 nanoclaw-agent); docker run --rm --entrypoint bun -v /home/nanoclaw/nanoclaw/groups/scrooge/scripts:/s \$IMG /s/bybit-fees.js USDT"'
```
Expected: JSON with per-chain `withdrawFee` (e.g. a TRC20 row). If Bybit requires auth/region, note it and fall back to documenting the endpoint Scrooge should call via its existing Bybit credentials.

- [ ] **Step 3: Tell Scrooge about the script**

Add a one-line entry to `groups/scrooge/skills/index.md` (or its CLAUDE.md script index) pointing at `scripts/bybit-fees.js` for withdrawal-fee questions, then scp that file the same way. (Find the right index: `ssh ... 'ls /home/nanoclaw/nanoclaw/groups/scrooge/'`.)

---

## Task 11: Enable the pilot on Scrooge + verify

**Files:** none (config + ops).

- [ ] **Step 1: Deploy the runner code to the VDS**

```bash
ssh root@148.253.211.164 'sudo -u nanoclaw bash -c "cd ~/nanoclaw && git pull && pnpm run build" && systemctl --machine=nanoclaw@.host --user restart nanoclaw'
```
Expected: pull + build clean, service restarts. (agent-runner `src/` is host-mounted; no image rebuild.)

- [ ] **Step 2: Turn the flag on for Scrooge**

Set `factualityGate: "deterministic"` in Scrooge's container config:
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "cd ~/nanoclaw && ncl groups config update --id scrooge --set factualityGate=deterministic"'
```
(If `ncl groups config` does not accept the key, set it directly in the `container_configs` row for scrooge via `pnpm exec tsx scripts/q.ts data/v2.db \"UPDATE container_configs SET config=json_set(config,'$.factualityGate','deterministic') WHERE ...\"` — confirm the exact column/row in that task.)

- [ ] **Step 3: Rebirth Scrooge (kill + wipe continuation)**

Per the factual-discipline plan: kill Scrooge's container and delete `continuation:claude` from its session outbound.db so the new flag + instructions load fresh.
```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "docker ps -q --filter name=nanoclaw-v2-scrooge | xargs -r docker kill"'
# then wipe continuation for scrooge sessions (find via: find data/v2-sessions/scrooge -name outbound.db) using scripts/q.ts DELETE FROM session_state WHERE key='continuation:claude'
```

- [ ] **Step 4: Live probe — the original failure**

Send to Scrooge (Telegram/iOS): `Какая комиссия у Bybit за вывод USDT в сети TRC20?`
Expected: Scrooge either (a) runs `bybit-fees.js` and answers with the real fee from its output, or (b) hedges ("надо проверить") — but does **NOT** emit a fabricated fee number. Confirm by checking the session outbound.db `messages_out` (see the dump pattern from the factual-discipline verification).

- [ ] **Step 5: Regression probe — grounded answer passes**

Send to Scrooge a question it answers from its ledger/script (e.g. a balance it pulls via a script this turn). Expected: the number is delivered normally (it's in the tool output → grounded), no hedge, no extra latency beyond the tool call.

- [ ] **Step 6: Confirm other agents unaffected**

Message Greg/Gordon as usual. Expected: identical behavior to before (their `factualityGate` is `off` → default code path, streaming intact).

---

## Self-Review (completed by plan author)

- **Spec coverage (Phase 1 scope):** L0 nudge = Task 9; L1 tool-shaping = Task 10; L2 detector = Task 1; deterministic L3 = Tasks 2/6; L7 block+regenerate+hedge = Task 6 Step 5; flag/rollout = Tasks 5/7/8/11; pilot Scrooge = Task 11; "default off = no change" = Task 6 (off branch verbatim). Phases 2-3 (Haiku judge, CoVe, web-search) are explicitly out of this plan.
- **Placeholder scan:** code is complete for all pure modules and the poll-loop wiring; the two host-side "confirm exact name/row" notes (Task 8 builder name, Task 11 config column) are discovery steps with exact grep/commands, not hand-waves — acceptable because they depend on host internals not yet read in this plan.
- **Type consistency:** `FactualityGate` ('off'|'deterministic'|'full') defined in config.ts (Task 5), imported in PollLoopConfig (Task 6) and materialized host-side (Task 8); `extractDataNumbers`/`normalizeNumber` (Task 1) used by `checkProvenance` (Task 2) and grounding accumulation (Task 6); `gateOutboundText`→`ProvenanceResult` consistent; `tool_use_end.output` (Task 3) produced in claude.ts (Task 4) and consumed in poll-loop (Task 6).
- **Risk flag:** Task 6 is delicate surgery on the streaming loop. The `off` branch must stay identical; all new behavior is behind `gateOn`. The deterministic matcher has known false positives (numbers in prose, rounding mismatches $1.60 vs $1.6 handled by normalization, but $1.6 vs $1.64 not) — Phase-1-acceptable because catch → regenerate/hedge, piloted on finance-heavy Scrooge, flag-gated.
