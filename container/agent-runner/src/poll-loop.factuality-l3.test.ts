import { test, expect } from 'bun:test';
import { runLevel3 } from './verification/level3.js';

// The poll-loop turns runLevel3().failed into a bounce. Guard that an
// action-relevant claim CoVe contradicts and web refutes surfaces as failed.
test('runLevel3 surfaces a refuted action-relevant claim as failed', async () => {
  let call = 0;
  const fakeFetch = (async (_u: string, init: RequestInit) => {
    call++;
    const body = JSON.parse(init.body as string);
    const isWeb = Array.isArray(body.tools);
    const text = call === 1
      ? '{"claims":[{"claim":"Aspirin safe dose is 50 pills/day","action_relevant":true}]}'
      : isWeb ? '{"verdict":"refuted","evidence":"max is far lower"}'
      : '{"verdict":"contradicted","why":"way too high"}';
    return new Response(JSON.stringify({ content: [{ type: 'text', text }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const r = await runLevel3('reply', 'sources', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(r.failed).toHaveLength(1);
});
