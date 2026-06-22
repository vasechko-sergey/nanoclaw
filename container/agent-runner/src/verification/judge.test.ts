import { test, expect } from 'bun:test';
import { buildJudgePrompt, parseJudgeVerdict } from './judge.js';

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
