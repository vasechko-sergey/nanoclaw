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

test('parseClaims returns [] on unparseable text', () => {
  expect(parseClaims('no json here', 6)).toEqual([]);
});

test('extractClaims posts to proxy and returns parsed claims', async () => {
  const fakeFetch = (async () =>
    new Response(JSON.stringify({ content: [{ type: 'text', text: '{"claims":[{"claim":"y","action_relevant":true}]}' }] }), { status: 200 })
  ) as unknown as typeof fetch;
  const out: ExtractedClaim[] = await extractClaims('reply text', 'tool output', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(out[0].claim).toBe('y');
  expect(out[0].action_relevant).toBe(true);
});
