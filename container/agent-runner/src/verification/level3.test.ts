import { test, expect } from 'bun:test';
import { aggregateVerdicts, runLevel3, type ClaimOutcome } from './level3.js';

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
  const r = await runLevel3('reply', 'sources', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
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
  const r = await runLevel3('reply', 'sources', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(webCalls).toBe(0);            // non-action never hits web
  expect(r.failed).toHaveLength(1);    // but a non-action contradicted still fails (hedge)
});
