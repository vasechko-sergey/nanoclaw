/**
 * Tests for the async deferred `request_context` MCP tool.
 *
 * The tool writes a `context_request` envelope to messages_out and returns
 * a Promise that the caller awaits. When the iOS device replies, the host
 * (Task 3.3) calls `onContextResponse` to resolve the promise. On timeout,
 * the promise rejects. Late responses after timeout are silently dropped.
 */
import { describe, it, expect, beforeEach, mock } from 'bun:test';
import { requestContextTool, onContextResponse, isIosChannel } from './request_context.js';

const writeMessageOut = mock(async () => {});
const ctx = { session_id: 'sess-1', writeMessageOut } as const;

beforeEach(() => writeMessageOut.mockClear());

describe('request_context tool', () => {
  it('writes messages_out with expires_at_ms = now + timeout_ms', async () => {
    const before = Date.now();
    const promise = requestContextTool.handler({ fields: ['device'] }, ctx as any);
    expect(writeMessageOut).toHaveBeenCalledTimes(1);
    const call = (writeMessageOut as any).mock.calls[0];
    expect(call[1].type).toBe('context_request');
    expect(call[1].payload.expires_at_ms).toBeGreaterThanOrEqual(before + 9_500);
    expect(call[1].payload.expires_at_ms).toBeLessThanOrEqual(Date.now() + 10_500);

    const req_id = call[1].payload.request_id;
    onContextResponse({ request_id: req_id, data: { device: { battery: 0.5 } } });
    expect(await promise).toEqual({ data: { device: { battery: 0.5 } }, errors: {} });
  });

  it('rejects on timeout', async () => {
    const promise = requestContextTool.handler(
      { fields: ['device'], timeout_ms: 1000 }, ctx as any,
    );
    await new Promise(r => setTimeout(r, 1100));
    await expect(promise).rejects.toThrow('[device offline / timeout]');
  });

  it('late context_response after timeout is silently dropped', async () => {
    const promise = requestContextTool.handler(
      { fields: ['device'], timeout_ms: 200 }, ctx as any,
    );
    await new Promise(r => setTimeout(r, 250));
    await expect(promise).rejects.toThrow();
    const call = (writeMessageOut as any).mock.calls[0];
    expect(() => onContextResponse({
      request_id: call[1].payload.request_id, data: { device: {} },
    })).not.toThrow();
  });

  it('rejects when only errors are present', async () => {
    const promise = requestContextTool.handler({ fields: ['health'] }, ctx as any);
    const call = (writeMessageOut as any).mock.calls[0];
    onContextResponse({
      request_id: call[1].payload.request_id,
      data: {},
      errors: { health: 'denied' },
    });
    await expect(promise).rejects.toThrow(/context error/);
  });
});

describe('isIosChannel registration gate', () => {
  it('accepts the legacy ios-app channel', () => {
    expect(isIosChannel('ios-app')).toBe(true);
  });
  it('accepts ios-app-v2 — the v2 sessions that were silently excluded', () => {
    expect(isIosChannel('ios-app-v2')).toBe(true);
  });
  it('rejects a non-iOS channel', () => {
    expect(isIosChannel('telegram')).toBe(false);
  });
  it('rejects the cli channel', () => {
    expect(isIosChannel('cli')).toBe(false);
  });
  it('rejects a null channel_type', () => {
    expect(isIosChannel(null)).toBe(false);
  });
});
