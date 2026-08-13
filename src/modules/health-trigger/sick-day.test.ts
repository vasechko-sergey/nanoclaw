import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { HealthUploadDay } from '../../../shared/ios-app-protocol/index.js';

// We mock the session-manager + container-runner imports so we can assert
// the trigger calls writeSessionMessage + wakeContainer when (and only when)
// the threshold rule fires.

const writeSessionMessage = vi.fn<(...args: unknown[]) => void>();
const wakeContainer = vi.fn<(...args: unknown[]) => Promise<void>>();
const getSessionsByAgentGroup = vi.fn<(...args: unknown[]) => unknown[]>();
const resolveSession = vi.fn<(...args: unknown[]) => { session: unknown; created: boolean }>();
const readSessionMessagesByPlatform = vi.fn<(...args: unknown[]) => { id: string; content: string }[]>();

vi.mock('../../session-manager.js', () => ({
  writeSessionMessage: (...args: unknown[]) => writeSessionMessage(...args),
  resolveSession: (...args: unknown[]) => resolveSession(...args),
  readSessionMessagesByPlatform: (...args: unknown[]) => readSessionMessagesByPlatform(...args),
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
const {
  sickDayCheck,
  detect,
  SICK_DAY_THRESHOLDS,
  SIGNAL_WEIGHTS,
  SICK_DAY_SCORE_T,
  SUBJECTIVE_WEIGHTS,
  FEVER_NORMAL_C,
} = await import('./sick-day.js');

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
    readSessionMessagesByPlatform.mockReset();
    readSessionMessagesByPlatform.mockReturnValue([]);
    getSessionsByAgentGroup.mockReturnValue([DEFAULT_SESSION]);
  });

  it('no signals → no write, no wake', async () => {
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: fourteenDays() });
    expect(writeSessionMessage).not.toHaveBeenCalled();
    expect(wakeContainer).not.toHaveBeenCalled();
  });

  // Superseded 2026-08-12: under the old 2-of-3 vote a lone RHR rise wrote
  // nothing. The weighted score lets the quietest signal carry a day on its own
  // — resting heart rate clears its threshold on 3% of this person's healthy
  // days. A lone NOISY signal still cannot; see 'a lone noisy-signal day'.
  it('RHR alone → writes, because RHR is the quietest signal', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66 });
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    expect(writeSessionMessage).toHaveBeenCalledOnce();
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

  // -------------------------------------------------------------------------
  // Task 5: one wake per day unless the picture worsens. iOS uploads several
  // times a day; on 2026-08-12 that was five identical sick_day_check rows.
  // -------------------------------------------------------------------------

  function priorCheck(date: string, matched: number, fires: Record<string, boolean>, score?: number) {
    return [
      {
        id: 'sickday-prior',
        content: JSON.stringify({
          kind: 'sick_day_check',
          detection: { date, matched, fires, ...(score === undefined ? {} : { score }) },
          signal: {},
        }),
      },
    ];
  }

  it('does not re-fire for the same day when the picture is unchanged', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5 });
    readSessionMessagesByPlatform.mockReturnValue(
      priorCheck(rows[13].date, 2, { rhr: true, hrv: false, temp: true, rr: false, awake: false }),
    );
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    expect(writeSessionMessage).not.toHaveBeenCalled();
    expect(wakeContainer).not.toHaveBeenCalled();
  });

  it('re-fires for the same day when a new signal joins', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5, hrv: 40 });
    readSessionMessagesByPlatform.mockReturnValue(
      priorCheck(rows[13].date, 2, { rhr: true, hrv: false, temp: true, rr: false, awake: false }),
    );
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    expect(writeSessionMessage).toHaveBeenCalledOnce();
    const content = JSON.parse((writeSessionMessage.mock.calls[0] as [string, string, { content: string }])[2].content);
    expect(content.detection.matched).toBe(3);
  });

  it('fires normally when nothing was reported for this day', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.5 });
    readSessionMessagesByPlatform.mockReturnValue(priorCheck('2026-06-13', 2, { rhr: true, temp: true }));
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    expect(writeSessionMessage).toHaveBeenCalledOnce();
  });

  // Deviation from the plan's guard, which watched only `matched` and `fires`.
  // Task 19 made the weighted score the fire decision, so the same two signals
  // getting much louder is a real deterioration the vote count cannot see.
  it('re-fires when the same signals worsen enough to move the score', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 2.0 });
    readSessionMessagesByPlatform.mockReturnValue(
      priorCheck(rows[13].date, 2, { rhr: true, hrv: false, temp: true, rr: false, awake: false }, 3.33),
    );
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    expect(writeSessionMessage).toHaveBeenCalledOnce();
    const content = JSON.parse((writeSessionMessage.mock.calls[0] as [string, string, { content: string }])[2].content);
    // +10% RHR (1.76 × 1.43) + a temp exceedance clipped at 3× (0.65 × 3).
    expect(content.detection.score).toBeCloseTo(4.46, 2);
  });

  it('stays quiet when the score only drifts as the day fills in', async () => {
    const rows = fourteenDays();
    rows[13] = stableDay(rows[13].date, { restingHeartRate: 66, wristTempDeviation: 0.6 });
    readSessionMessagesByPlatform.mockReturnValue(
      priorCheck(rows[13].date, 2, { rhr: true, hrv: false, temp: true, rr: false, awake: false }, 3.33),
    );
    await sickDayCheck({ agentGroupId: 'greg', ownerKey: 'owner', allRows: rows });
    // Score moves 3.33 → 3.49, under one median-weight signal's worth.
    expect(writeSessionMessage).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// Task 1: five signals, morning HRV preferred. Mirror of analyze.test.js.
// ---------------------------------------------------------------------------

function quiet(n: number): HealthUploadDay[] {
  return Array.from({ length: n }, (_, i) => ({
    date: `2026-07-${String(i + 1).padStart(2, '0')}`,
    restingHeartRate: 61,
    hrv: 46,
    hrvMorning: 47,
    wristTempDeviation: 35.2,
    respiratoryRate: 15.9,
    awakeMin: 18,
  }));
}

describe('detect — 5 signals', () => {
  it('exposes the two new thresholds', () => {
    expect(SICK_DAY_THRESHOLDS.rrAbs).toBe(0.9);
    expect(SICK_DAY_THRESHOLDS.awakeRatio).toBe(2.0);
  });

  it('fires on respiratory rate + awake minutes alone', () => {
    const rows = quiet(14);
    rows.push({
      date: '2026-07-15',
      restingHeartRate: 61,
      hrv: 46,
      hrvMorning: 47,
      wristTempDeviation: 35.2,
      respiratoryRate: 17.4,
      awakeMin: 60,
    });
    const d = detect(rows);
    expect(d).not.toBeNull();
    expect(d!.matched).toBe(2);
    expect(d!.fires).toEqual({
      rhr: false,
      hrv: false,
      temp: false,
      rr: true,
      awake: true,
      symptom: false,
      fever: false,
    });
  });

  it('prefers hrvMorning over whole-day hrv', () => {
    const rows = quiet(14);
    rows.push({
      date: '2026-07-15',
      // RHR raised only so the day clears the weighted gate — morning HRV
      // carries a weight of 0.42 by design and cannot fire a day alone.
      restingHeartRate: 68,
      hrv: 46,
      hrvMorning: 30,
      wristTempDeviation: 35.9,
      respiratoryRate: 15.9,
      awakeMin: 18,
    });
    const d = detect(rows);
    expect(d!.fires.hrv).toBe(true);
    expect(d!.fires.temp).toBe(true);
  });
});

describe('detect — weighted score', () => {
  it('weights resting heart rate far above morning HRV', () => {
    expect(SIGNAL_WEIGHTS.rhr).toBeGreaterThan(SIGNAL_WEIGHTS.hrv * 3);
    expect(SICK_DAY_SCORE_T).toBe(3.0);
  });

  it('a lone noisy-signal day scores below threshold', () => {
    const rows = quiet(14);
    rows.push({
      date: '2026-07-15',
      restingHeartRate: 61,
      hrv: 46,
      hrvMorning: 28,
      wristTempDeviation: 35.2,
      respiratoryRate: 15.9,
      awakeMin: 18,
    });
    expect(detect(rows)).toBeNull();
  });

  it('normalises the threshold when a signal is unavailable', () => {
    const rows = quiet(14).map(({ wristTempDeviation, ...r }) => r);
    rows.push({
      date: '2026-07-15',
      restingHeartRate: 74,
      hrv: 46,
      hrvMorning: 47,
      respiratoryRate: 15.9,
      awakeMin: 18,
    });
    const d = detect(rows);
    expect(d).not.toBeNull();
    expect(d!.unavailable).toEqual(['temp']);
    expect(d!.score_threshold).toBeCloseTo((3.0 * (5.0 - 0.65)) / 5.0, 2);
  });
});

describe('detect — the subjective channel', () => {
  const withToday = (extra: Partial<HealthUploadDay>) => {
    const rows = quiet(14);
    rows.push({
      date: '2026-07-15',
      restingHeartRate: 61,
      hrv: 46,
      hrvMorning: 47,
      wristTempDeviation: 35.2,
      respiratoryRate: 15.9,
      awakeMin: 18,
      ...extra,
    });
    return detect(rows);
  };

  it('a logged symptom cannot fire a day on its own', () => {
    expect(withToday({ symptoms: ['soreThroat'] })).toBeNull();
  });

  it('a symptom plus one hardware signal fires where the signal alone would not', () => {
    expect(withToday({ respiratoryRate: 17.4 })).toBeNull();
    const d = withToday({ respiratoryRate: 17.4, symptoms: ['soreThroat'] });
    expect(d).not.toBeNull();
    expect(d!.fires.symptom).toBe(true);
    expect(d!.signal.symptoms).toEqual(['soreThroat']);
  });

  it('a measured fever fires on its own, wrist sensor silent', () => {
    const d = withToday({ bodyTemperature: 38.1 });
    expect(d).not.toBeNull();
    expect(d!.fires.fever).toBe(true);
    expect(d!.fires.temp).toBe(false);
    expect(d!.signal.body_temp_c).toBe(38.1);
  });

  it('a normal thermometer reading is not a fever signal', () => {
    expect(withToday({ bodyTemperature: 36.8 })).toBeNull();
  });

  it('an empty symptoms array does not lower the bar for the hardware signals', () => {
    // Guards the reason these live outside SIGNAL_WEIGHTS: bodyTemperature is
    // absent on nearly every day, so pool membership would permanently shrink
    // availableWeight/TOTAL_WEIGHT and loosen a measured threshold.
    const bare = withToday({ restingHeartRate: 74 });
    const logged = withToday({ restingHeartRate: 74, symptoms: [] });
    expect(logged!.score_threshold).toBe(bare!.score_threshold);
    expect(logged!.score).toBe(bare!.score);
    expect(logged!.fires.symptom).toBe(false);
    expect(logged!.signal.symptoms).toBeNull();
  });

  it('clips a very high fever like every other exceedance', () => {
    expect(withToday({ bodyTemperature: 42.0 })!.score).toBe(withToday({ bodyTemperature: 39.3 })!.score);
  });

  it('mirrors the container-side constants exactly', () => {
    expect(SICK_DAY_THRESHOLDS.feverC).toBe(37.5);
    expect(FEVER_NORMAL_C).toBe(36.6);
    expect(SUBJECTIVE_WEIGHTS).toEqual({ symptom: 1.5, fever: 3.0 });
  });
});
