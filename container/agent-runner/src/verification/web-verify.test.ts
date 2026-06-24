import { test, expect } from 'bun:test';
import { parseWebVerdict, webVerify, resetWebPreflight } from './web-verify.js';

test('parseWebVerdict reads supported/refuted; junk/unknown → unavailable', () => {
  expect(parseWebVerdict('{"verdict":"refuted","evidence":"sources say 2"}').verdict).toBe('refuted');
  expect(parseWebVerdict('{"verdict":"supported","evidence":"x"}').verdict).toBe('supported');
  expect(parseWebVerdict('junk').verdict).toBe('unavailable');
  expect(parseWebVerdict('{"verdict":"maybe"}').verdict).toBe('unavailable');
});

test('webVerify returns unavailable (no-op) when the model rejects the web_search tool', async () => {
  resetWebPreflight();
  const fakeFetch = (async () => new Response('tool not supported', { status: 400 })) as unknown as typeof fetch;
  const r = await webVerify('some claim', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.verdict).toBe('unavailable');
});

test('after a failure, webVerify latches unavailable and stops calling', async () => {
  resetWebPreflight();
  let calls = 0;
  const failFetch = (async () => { calls++; return new Response('no', { status: 400 }); }) as unknown as typeof fetch;
  await webVerify('c1', failFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  await webVerify('c2', failFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(calls).toBe(1); // second call short-circuited by the latch
});

test('webVerify returns a verdict when the tool works', async () => {
  resetWebPreflight();
  let sentBody: any = null;
  const fakeFetch = (async (_u: string, init: RequestInit) => {
    sentBody = JSON.parse(init.body as string);
    return new Response(JSON.stringify({ content: [{ type: 'text', text: '{"verdict":"refuted","evidence":"e"}' }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const r = await webVerify('some claim', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.verdict).toBe('refuted');
  expect(Array.isArray(sentBody.tools)).toBe(true); // web_search tool was forwarded
});
