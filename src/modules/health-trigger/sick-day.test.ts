import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { HealthUploadDay } from '../../../shared/ios-app-protocol/index.js';

// We mock the session-manager + container-runner imports so we can assert
// the trigger calls writeSessionMessage + wakeContainer when (and only when)
// the threshold rule fires.

const writeSessionMessage = vi.fn<(...args: unknown[]) => void>();
const wakeContainer = vi.fn<(...args: unknown[]) => Promise<void>>();
const getSession = vi.fn<(...args: unknown[]) => unknown>();
const resolveSession = vi.fn<(...args: unknown[]) => unknown>();

vi.mock('../../session-manager.js', () => ({
  writeSessionMessage: (...args: unknown[]) => writeSessionMessage(...args),
  resolveSession: (...args: unknown[]) => resolveSession(...args),
}));
vi.mock('../../container-runner.js', () => ({
  wakeContainer: (...args: unknown[]) => wakeContainer(...args),
}));
vi.mock('../../db/sessions.js', () => ({
  getSession: (...args: unknown[]) => getSession(...args),
}));

// Import AFTER mocks so module-level imports inside sick-day.ts pick up the mocks.
const { sickDayCheck } = await import('./sick-day.js');

function stableDay(date: string, overrides: Partial<HealthUploadDay> = {}): HealthUploadDay {
  return {
    date,
    restingHeartRate: 60,
    hrv: 50,
    wristTempDeviation: 0.0,
    ...overrides,
  };
}

function fourteenDays(): HealthUploadDay[] {
  return Array.from({ length: 14 }, (_, i) => stableDay(`2026-06-${String(i + 1).padStart(2, '0')}`));
}

describe('sickDayCheck', () => {
  beforeEach(() => {
    writeSessionMessage.mockReset();
    wakeContainer.mockReset();
    getSession.mockReset();
    resolveSession.mockReset();
    resolveSession.mockReturnValue({
      session: { id: 'sess-greg-1', agent_group_id: 'greg', status: 'active' },
      created: false,
    });
    getSession.mockReturnValue({ id: 'sess-greg-1', agent_group_id: 'greg', status: 'active' });
  });

  it('no signals → no write, no wake', async () => {
    await sickDayCheck({ agentGroupId: 'greg', allRows: fourteenDays() });
    expect(writeSessionMessage).not.toHaveBeenCalled();
    expect(wakeContainer).not.toHaveBeenCalled();
  });

  it('1 of 3 signal → no write', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66 });
    await sickDayCheck({ agentGroupId: 'greg', allRows: rows });
    expect(writeSessionMessage).not.toHaveBeenCalled();
  });

  it('2 of 3 signals → writes sick_day_check message and wakes container', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5 });
    await sickDayCheck({ agentGroupId: 'greg', allRows: rows });
    expect(writeSessionMessage).toHaveBeenCalledOnce();
    const callArg = writeSessionMessage.mock.calls[0] as [string, string, { kind: string; content: string }];
    // writeSessionMessage(agentGroupId, sessionId, msg)
    expect(callArg[0]).toBe('greg');
    expect(callArg[1]).toBe('sess-greg-1');
    expect(callArg[2].kind).toBe('chat');
    const content = JSON.parse(callArg[2].content);
    expect(content.kind).toBe('sick_day_check');
    expect(content.signal.rhr_delta_pct).toBeGreaterThan(0);
    expect(wakeContainer).toHaveBeenCalledOnce();
  });

  it('does not fire when agentGroupId has no active session', async () => {
    getSession.mockReturnValue(undefined);
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 70, hrv: 40, wristTempDeviation: 0.6 });
    await sickDayCheck({ agentGroupId: 'unknown-group', allRows: rows });
    expect(writeSessionMessage).not.toHaveBeenCalled();
  });
});
