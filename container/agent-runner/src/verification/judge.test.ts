import { test, expect } from 'bun:test';
import { buildJudgePrompt, parseJudgeVerdict, judgeProse } from './judge.js';

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

test('judgeProse passes an abort signal (timeout)', async () => {
  let sig: unknown;
  const fakeFetch = (async (_url: string, init: RequestInit) => {
    sig = init.signal;
    return new Response(JSON.stringify({ content: [{ type: 'text', text: '{"unsupported":[]}' }] }), { status: 200 });
  }) as unknown as typeof fetch;
  await judgeProse('r', 's', fakeFetch, { ANTHROPIC_BASE_URL: 'http://p', ANTHROPIC_API_KEY: 'k' });
  expect(sig).toBeInstanceOf(AbortSignal);
});
