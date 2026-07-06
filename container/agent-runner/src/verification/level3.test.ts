import { test, expect } from 'bun:test';
import { aggregateVerdicts, runLevel3, isToolGrounded, type ClaimOutcome } from './level3.js';

test('aggregateVerdicts: web refuted => fail', () => {
  const outcomes: ClaimOutcome[] = [{ claim: 'a', action_relevant: true, cove: 'contradicted', web: 'refuted' }];
  expect(aggregateVerdicts(outcomes).failed.map((f) => f.claim)).toEqual(['a']);
});

test('aggregateVerdicts: non-action contradicted (no web) => fail', () => {
  expect(aggregateVerdicts([{ claim: 'b', action_relevant: false, cove: 'contradicted', web: null }]).failed.map((f) => f.claim)).toEqual(['b']);
});

test('aggregateVerdicts: action uncertain but web unavailable => fail (degrade hedge)', () => {
  expect(aggregateVerdicts([{ claim: 'c', action_relevant: true, cove: 'uncertain', web: 'unavailable' }]).failed.map((f) => f.claim)).toEqual(['c']);
});

test('aggregateVerdicts: budget-exhausted action claim (web=null) still hedges, not silent pass', () => {
  const r = aggregateVerdicts([
    { claim: 'g', action_relevant: true, cove: 'contradicted', web: null }, // budget ran out
    { claim: 'h', action_relevant: true, cove: 'uncertain', web: null },
  ]);
  expect(r.failed.map((f) => f.claim).sort()).toEqual(['g', 'h']);
});

test('aggregateVerdicts: action supported (web=null) => pass', () => {
  expect(aggregateVerdicts([{ claim: 'i', action_relevant: true, cove: 'supported', web: null }]).failed).toHaveLength(0);
});

test('aggregateVerdicts: web supported / non-action uncertain / supported => pass', () => {
  const r = aggregateVerdicts([
    { claim: 'd', action_relevant: true, cove: 'contradicted', web: 'supported' },
    { claim: 'e', action_relevant: false, cove: 'uncertain', web: null },
    { claim: 'f', action_relevant: false, cove: 'supported', web: null },
  ]);
  expect(r.failed).toHaveLength(0);
  expect(r.escalated).toBe(1); // only 'd' had a web verdict
});

test('runLevel3: action+contradicted claim escalates to web and is failed when refuted', async () => {
  let call = 0;
  const fakeFetch = (async (_u: string, init: RequestInit) => {
    call++;
    const body = JSON.parse(init.body as string);
    const isWeb = Array.isArray(body.tools);
    const text = call === 1
      ? '{"claims":[{"claim":"Aspirin safe dose is 50 pills/day","action_relevant":true}]}'
      : isWeb ? '{"verdict":"refuted","evidence":"far lower"}'
      : '{"verdict":"contradicted","why":"too high"}';
    return new Response(JSON.stringify({ content: [{ type: 'text', text }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const r = await runLevel3('reply', 'sources', new Set(), fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.failed).toHaveLength(1);
  expect(r.escalated).toBe(1);
});

test('runLevel3: non-action claim never escalates to web', async () => {
  let webCalls = 0;
  const fakeFetch = (async (_u: string, init: RequestInit) => {
    const body = JSON.parse(init.body as string);
    if (Array.isArray(body.tools)) webCalls++;
    const isExtract = (body.messages[0].content as string).includes('REPLY:');
    const text = isExtract
      ? '{"claims":[{"claim":"Paris is in France","action_relevant":false}]}'
      : '{"verdict":"contradicted","why":"x"}';
    return new Response(JSON.stringify({ content: [{ type: 'text', text }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const r = await runLevel3('reply', 'sources', new Set(), fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(webCalls).toBe(0);            // non-action never hits web
  expect(r.failed).toHaveLength(1);    // but a non-action contradicted still fails (hedge)
});

test('runLevel3: a tool-grounded numeric claim skips CoVe + web (extract call only)', async () => {
  let calls = 0;
  const fakeFetch = (async () => {
    calls++; // any call past the first (extract) would be a CoVe/web escalation
    return new Response(
      JSON.stringify({ content: [{ type: 'text', text: '{"claims":[{"claim":"Оборот ₾49,324 за июнь","action_relevant":true}]}' }] }),
      { status: 200 },
    );
  }) as unknown as typeof fetch;
  const grounding = new Set(['49323.76']); // raw tool value; reply shows rounded 49,324
  const r = await runLevel3('reply', 'sources', grounding, fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(calls).toBe(1); // extract only — NO CoVe, NO web for a tool-grounded value
  expect(r.failed).toHaveLength(0); // grounded → supported
});

test('runLevel3: extractClaims failure surfaces error (checked=0 is NOT ambiguous)', async () => {
  const boom = (async () => { throw new Error('HTTP 401'); }) as unknown as typeof fetch;
  const r = await runLevel3('reply', 'sources', new Set(), boom, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.checked).toBe(0);
  expect(r.failed).toHaveLength(0);
  expect(r.error).toContain('extract:');
});

test('runLevel3: legit empty extraction has NO error (distinguishable from a swallowed failure)', async () => {
  const empty = (async () =>
    new Response(JSON.stringify({ content: [{ type: 'text', text: '{"claims":[]}' }] }), { status: 200 })) as unknown as typeof fetch;
  const r = await runLevel3('reply', 'sources', new Set(), empty, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.checked).toBe(0);
  expect(r.error).toBeUndefined();
});

test('isToolGrounded: numeric claim traces to sources (rounding-aware); no-number claim does not', () => {
  const g = new Set(['49323.76', '13975']);
  expect(isToolGrounded('Оборот ₾49,324', g)).toBe(true); // 49324 rounds to 49323.76
  expect(isToolGrounded('Поступление £13,975', g)).toBe(true); // exact
  expect(isToolGrounded('Оборот ₾50,000', g)).toBe(false); // no source rounds to 50000
  expect(isToolGrounded('Paris is in France', g)).toBe(false); // no numbers → never auto-grounded
  expect(isToolGrounded('₾49,324', new Set())).toBe(false); // empty grounding
});
