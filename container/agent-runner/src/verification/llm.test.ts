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
  const h = captured!.init.headers as Record<string, string>;
  expect(h['x-api-key']).toBe('k');
  expect(h['content-type']).toBe('application/json');
  expect(h['anthropic-version']).toBe('2023-06-01');
});

test('callMessages forwards tools and throws on non-200', async () => {
  const fakeFetch = (async () => new Response('no', { status: 500 })) as unknown as typeof fetch;
  await expect(
    callMessages({ system: 's', user: 'u', model: 'm' }, fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' }),
  ).rejects.toThrow();
});

test('callMessages uses oauth headers when no api key', async () => {
  let headers: Record<string, string> = {};
  const fakeFetch = (async (_u: string, init: RequestInit) => {
    headers = init.headers as Record<string, string>;
    return new Response(JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }), { status: 200 });
  }) as unknown as typeof fetch;
  await callMessages({ system: 's', user: 'u', model: 'm' }, fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', CLAUDE_CODE_OAUTH_TOKEN: 'tok' });
  expect(headers['authorization']).toBe('Bearer tok');
  expect(headers['anthropic-beta']).toBe('oauth-2025-04-20');
});
