import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { HealthUploadDay } from '../../../shared/ios-app-protocol/index.js';

// We mock the session-manager + container-runner imports so we can assert
// the trigger calls writeSessionMessage + wakeContainer when (and only when)
// the threshold rule fires.

const writeSessionMessage = vi.fn<(...args: unknown[]) => void>();
const wakeContainer = vi.fn<(...args: unknown[]) => Promise<void>>();
const getSessionsByAgentGroup = vi.fn<(...args: unknown[]) => unknown[]>();
const resolveSession = vi.fn<(...args: unknown[]) => { session: unknown; created: boolean }>();

vi.mock('../../session-manager.js', () => ({
  writeSessionMessage: (...args: unknown[]) => writeSessionMessage(...args),
  resolveSession: (...args: unknown[]) => resolveSession(...args),
}));
vi.mock('../../container-runner.js', () => ({
  wakeContainer: (...args: unknown[]) => wakeContainer(...args),
}));
vi.mock('../../db/sessions.js', () => ({
  getSessionsByAgentGroup: (...args: unknown[]) => getSessionsByAgentGroup(...args),
}));
vi.mock('../../config.js', () => ({
  OWNER_PERSON_KEY: 'owner',
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

// Default session for single-owner tests (owner_key null → falls back to OWNER_PERSON_KEY='owner')
const DEFAULT_SESSION = { id: 'sess-greg-1', agent_group_id: 'greg', status: 'active', owner_key: null };

describe('sickDayCheck', () => {
  beforeEach(() => {
    writeSessionMessage.mockReset();
    wakeContainer.mockReset();
    getSessionsByAgentGroup.mockReset();
    resolveSession.mockReset();
    getSessionsByAgentGroup.mockReturnValue([DEFAULT_SESSION]);
  });

  it('no signals → no write, no wake', async () => {
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: fourteenDays() });
    expect(writeSessionMessage).not.toHaveBeenCalled();
    expect(wakeContainer).not.toHaveBeenCalled();
  });

  it('1 of 3 signal → no write', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66 });
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    expect(writeSessionMessage).not.toHaveBeenCalled();
  });

  it('2 of 3 signals → writes sick_day_check message and wakes container', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5 });
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
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

  it('baseline missing temp + today has RHR + HRV → fires via 2 of 3 (temp branch null)', async () => {
    const rows = fourteenDays().map(({ wristTempDeviation, ...r }) => r as HealthUploadDay);
    rows[13] = { ...rows[13], restingHeartRate: 70, hrv: 40 };
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    expect(writeSessionMessage).toHaveBeenCalledOnce();
    const callArg = writeSessionMessage.mock.calls[0] as [string, string, { kind: string; content: string }];
    const content = JSON.parse(callArg[2].content);
    expect(content.signal.temp_delta_c).toBeNull();
    expect(wakeContainer).toHaveBeenCalledOnce();
  });

  it('baseline missing temp + today only has temp=0.6 → does NOT fire (1 of 3)', async () => {
    const rows = fourteenDays().map(({ wristTempDeviation, ...r }) => r as HealthUploadDay);
    rows[13] = { ...rows[13], wristTempDeviation: 0.6 };
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    expect(writeSessionMessage).not.toHaveBeenCalled();
    expect(wakeContainer).not.toHaveBeenCalled();
  });

  it('empty/falsy agentGroupId → no-op (no resolveSession, no wake)', async () => {
    getSessionsByAgentGroup.mockReturnValue([]);
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 70, hrv: 40, wristTempDeviation: 0.6 });
    await sickDayCheck({ agentGroupId: undefined, ownerKey: 'owner', allRows: rows });
    expect(resolveSession).not.toHaveBeenCalled();
    expect(writeSessionMessage).not.toHaveBeenCalled();
    expect(wakeContainer).not.toHaveBeenCalled();
  });

  it('configured agentGroupId but no owned active session → creates owner-stamped session and wakes it', async () => {
    // Simulate idle health agent: no active session exists for this person.
    getSessionsByAgentGroup.mockReturnValue([]);
    const createdSession = {
      id: 'sess-greg-new',
      agent_group_id: 'greg',
      status: 'active',
      owner_key: 'owner',
      created_at: new Date().toISOString(),
    };
    resolveSession.mockReturnValue({ session: createdSession, created: true });

    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 70, hrv: 40, wristTempDeviation: 0.6 });
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });

    // resolveSession must have been called to create the session
    expect(resolveSession).toHaveBeenCalledWith('greg', null, null, 'per-thread', 'owner');
    // Message must be written to the newly created session
    expect(writeSessionMessage).toHaveBeenCalledOnce();
    const callArg = writeSessionMessage.mock.calls[0] as [string, string, { kind: string; content: string }];
    expect(callArg[0]).toBe('greg');
    expect(callArg[1]).toBe('sess-greg-new');
    // Container must be woken for the created session
    expect(wakeContainer).toHaveBeenCalledOnce();
    const wakenSession = (wakeContainer.mock.calls[0] as [{ id: string }])[0];
    expect(wakenSession.id).toBe('sess-greg-new');
  });

  it('multi-user: p2 upload wakes only p2 session, not sergei session', async () => {
    // Two active sessions for the same agent group, different owners.
    const sergeiSession = { id: 'sess-greg-sergei', agent_group_id: 'greg', status: 'active', owner_key: 'sergei' };
    const p2Session = { id: 'sess-greg-p2', agent_group_id: 'greg', status: 'active', owner_key: 'p2' };
    getSessionsByAgentGroup.mockReturnValue([sergeiSession, p2Session]);

    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5 });

    // Upload is from p2 → only p2's session should be woken.
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'p2', allRows: rows });

    expect(writeSessionMessage).toHaveBeenCalledOnce();
    const callArg = writeSessionMessage.mock.calls[0] as [string, string, { kind: string; content: string }];
    // Must target p2's session, not sergei's.
    expect(callArg[1]).toBe('sess-greg-p2');
    expect(callArg[1]).not.toBe('sess-greg-sergei');

    expect(wakeContainer).toHaveBeenCalledOnce();
    // The session passed to wakeContainer must be p2's.
    const wakenSession = (wakeContainer.mock.calls[0] as [{ id: string }])[0];
    expect(wakenSession.id).toBe('sess-greg-p2');
  });
});
