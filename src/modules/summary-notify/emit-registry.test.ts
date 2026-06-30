import { describe, it, expect, beforeEach } from 'vitest';
import { registerSummaryEmitter, getSummaryEmitter, __resetSummaryEmitter } from './emit-registry.js';

beforeEach(() => __resetSummaryEmitter());

describe('summary emit registry', () => {
  it('returns undefined when nothing registered', () => {
    expect(getSummaryEmitter()).toBeUndefined();
  });
  it('returns the registered emitter', () => {
    const calls: Array<{ p: string; c: number }> = [];
    registerSummaryEmitter((personKey, payload) => calls.push({ p: personKey, c: payload.count }));
    getSummaryEmitter()!('owner', { date: '2026-06-30', count: 5 });
    expect(calls).toEqual([{ p: 'owner', c: 5 }]);
  });
});
