import { test, expect } from 'bun:test';
import { parseCoveVerdict, coveCheck } from './cove.js';

test('parseCoveVerdict reads the three verdicts', () => {
  expect(parseCoveVerdict('{"verdict":"supported","why":"ok"}').verdict).toBe('supported');
  expect(parseCoveVerdict('{"verdict":"contradicted","why":"no"}').verdict).toBe('contradicted');
  expect(parseCoveVerdict('{"verdict":"uncertain","why":"hmm"}').verdict).toBe('uncertain');
});

test('parseCoveVerdict falls back to uncertain on unparseable or unknown verdict', () => {
  expect(parseCoveVerdict('garbage').verdict).toBe('uncertain');
  expect(parseCoveVerdict('{"verdict":"maybe"}').verdict).toBe('uncertain');
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
  expect(sentUser).not.toContain('REPLY'); // isolation: no original-answer scaffolding
});
