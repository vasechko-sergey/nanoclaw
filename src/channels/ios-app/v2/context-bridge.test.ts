import { describe, it, expect, beforeEach, vi } from 'vitest';
import { openTransportDb, type TransportDb } from './transport-db.js';
import { ContextBridge } from './context-bridge.js';

let db: TransportDb;
let bridge: ContextBridge;
const pid = 'ios-app:dev-1';
const session = 'sess-1';

const sendEnvelope = vi.fn();
const writeInbound = vi.fn();
const resolvePid = vi.fn(() => pid as string | null);

beforeEach(() => {
  db = openTransportDb(':memory:');
  db.upsertDevice(pid, {});
  sendEnvelope.mockReset();
  writeInbound.mockReset();
  resolvePid.mockReset();
  resolvePid.mockReturnValue(pid);
  bridge = new ContextBridge({
    db,
    resolvePlatformForSession: resolvePid,
    sendEnvelopeToDevice: sendEnvelope,
    writeInboundContextResponse: writeInbound,
  });
});

describe('ContextBridge', () => {
  it('registers pending row + sends envelope', () => {
    bridge.handleAgentRequest({
      session_id: session,
      request_id: 'r-1',
      fields: ['device'],
      params: {},
      expires_at_ms: Date.now() + 10_000,
    });
    const row = db.raw.prepare(`SELECT * FROM pending_context_requests`).get();
    expect(row).toBeTruthy();
    expect(sendEnvelope).toHaveBeenCalledTimes(1);
  });

  it('rejects when session has no ios-app device', () => {
    resolvePid.mockReturnValueOnce(null);
    bridge.handleAgentRequest({
      session_id: 'sess-X',
      request_id: 'r-2',
      fields: ['device'],
      params: {},
      expires_at_ms: Date.now() + 10_000,
    });
    expect(sendEnvelope).not.toHaveBeenCalled();
    expect(writeInbound).toHaveBeenCalledWith(
      expect.objectContaining({
        session_id: 'sess-X',
        request_id: 'r-2',
        errors: { scope: 'no ios-app device wired' },
      }),
    );
  });

  it('sweep expires stale requests', () => {
    bridge.handleAgentRequest({
      session_id: session,
      request_id: 'r-3',
      fields: ['device'],
      params: {},
      expires_at_ms: Date.now() - 100,
    });
    bridge.sweepExpired();
    expect(writeInbound).toHaveBeenCalledWith(
      expect.objectContaining({
        request_id: 'r-3',
        errors: { timeout: 'device offline / timeout' },
      }),
    );
    expect(db.raw.prepare(`SELECT COUNT(*) AS n FROM pending_context_requests`).get()).toEqual({ n: 0 });
  });

  it('removes pending row on incoming context_response', () => {
    bridge.handleAgentRequest({
      session_id: session,
      request_id: 'r-4',
      fields: ['device'],
      params: {},
      expires_at_ms: Date.now() + 10_000,
    });
    bridge.resolveDeviceResponse('r-4');
    expect(db.raw.prepare(`SELECT COUNT(*) AS n FROM pending_context_requests`).get()).toEqual({ n: 0 });
  });
});
