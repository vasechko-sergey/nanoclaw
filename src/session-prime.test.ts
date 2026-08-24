import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('./log.js', () => ({
  log: { info: vi.fn(), warn: vi.fn(), error: vi.fn(), debug: vi.fn() },
}));

const mockWriteSessionMessage = vi.fn();
vi.mock('./session-manager.js', () => ({
  writeSessionMessage: (...args: unknown[]) => mockWriteSessionMessage(...args),
}));

import { primeSessionAfterReset } from './session-prime.js';

beforeEach(() => {
  vi.clearAllMocks();
});

/**
 * `/new` drops the SDK continuation — that is its job. What it must NOT drop is
 * the memory that lives OUTSIDE the conversation: the shared owner profile and
 * the agent's own index. Reported 2026-08-24: after a reset, Scrooge answered a
 * budget question without opening `/workspace/global/about.md`, and called the
 * owner's girlfriend his ex-wife. The file said otherwise; nothing made the
 * fresh session look.
 */
describe('primeSessionAfterReset', () => {
  it('queues the durable-memory re-read for the next fresh container', () => {
    primeSessionAfterReset('scrooge', 's1');

    expect(mockWriteSessionMessage).toHaveBeenCalledTimes(1);
    const [agentGroupId, sessionId, msg] = mockWriteSessionMessage.mock.calls[0];
    expect(agentGroupId).toBe('scrooge');
    expect(sessionId).toBe('s1');
    const text = JSON.parse(msg.content).text as string;
    expect(text).toContain('/workspace/global/about.md');
    expect(text).toContain('memories/index.md');
  });

  it('rides the next real message instead of waking a container by itself', () => {
    // trigger=0 accumulates (no wake of its own); on_wake=1 means only a FRESH
    // container's first poll may consume it — a dying one cannot swallow it.
    primeSessionAfterReset('scrooge', 's1');

    const msg = mockWriteSessionMessage.mock.calls[0][2];
    expect(msg.trigger).toBe(0);
    expect(msg.onWake).toBe(1);
  });

  it('never throws into the reset path', () => {
    mockWriteSessionMessage.mockImplementation(() => {
      throw new Error('inbound.db locked');
    });

    expect(() => primeSessionAfterReset('scrooge', 's1')).not.toThrow();
  });
});
