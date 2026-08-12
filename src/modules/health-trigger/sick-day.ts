/**
 * Host-side sick-day trigger.
 *
 * Called after `appendHealthHistory` writes new rows from the iOS app's
 * `POST /ios/health/upload`. We re-implement the five-threshold rule from
 * `groups/greg/scripts/analyze.js:sickDayDetect` (deliberately
 * duplicated — the host can't shell out to bun on the request path) and,
 * if 2 of 5 signals fire, write a one-shot wake message into Greg's
 * session inbound DB so he runs `--mode sick-day` on the next poll.
 *
 * Threshold constants stay in sync with analyze.js by convention. Keep them
 * here as plain numbers — if you change one, change both. The TS-side test
 * (sick-day.test.ts) and Bun-side test (analyze.test.js) both pin the
 * canonical values.
 */
import { writeSessionMessage, resolveSession, readSessionMessagesByPlatform } from '../../session-manager.js';
import { wakeContainer } from '../../container-runner.js';
import { getSessionsByAgentGroup } from '../../db/sessions.js';
import { OWNER_PERSON_KEY } from '../../config.js';
import { log } from '../../log.js';
import type { HealthUploadDay } from '../../../shared/ios-app-protocol/index.js';

export const SICK_DAY_THRESHOLDS = {
  rhrPct: 7,
  tempC: 0.4,
  hrvPct: 15,
  rrAbs: 0.9,
  awakeRatio: 2.0,
};

// Mirror of analyze.js:SIGNAL_WEIGHTS. Each signal weighted by how quiet it is
// on this person's healthy days, measured over the 74 pre-onset days in
// health.db (2026-06 .. 2026-08-09): rhr 3% | rr 5% | awake 12% | temp 16% |
// hrv 27%. Weight = 1/(rate + 0.05), normalised to mean 1.0. Counting these as
// equal votes is what produced an 11% false-alarm rate; morning HRV supplied
// most of it while being the least informative signal this person has.
export const SIGNAL_WEIGHTS = { rhr: 1.76, hrv: 0.42, temp: 0.65, rr: 1.38, awake: 0.79 };
const TOTAL_WEIGHT = Object.values(SIGNAL_WEIGHTS).reduce((a, b) => a + b, 0);

// Picked from a false-alarm budget, not by tuning to the one labelled episode:
// 5 alarms across 74 healthy days (7%), four of them clustered on a relocation
// week. Raising it to 3.5 costs the onset-day detection this rule exists for.
export const SICK_DAY_SCORE_T = 3.0;

function median(xs: number[]): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

interface Detection {
  date: string;
  matched: number;
  /** Weighted evidence total. This, not `matched`, is the fire decision. */
  score: number;
  /** `SICK_DAY_SCORE_T` scaled to the weight actually available tonight. */
  score_threshold: number;
  /** Signals with no baseline or no reading today — evidence that is missing,
   *  not evidence that is absent. */
  unavailable: string[];
  signal: {
    rhr_delta_pct: number | null;
    hrv_delta_pct: number | null;
    temp_delta_c: number | null;
    rr_delta_abs: number | null;
    awake_ratio: number | null;
  };
  fires: { rhr: boolean; hrv: boolean; temp: boolean; rr: boolean; awake: boolean };
}

export function detect(rows: HealthUploadDay[], thresholds = SICK_DAY_THRESHOLDS): Detection | null {
  if (!rows || rows.length < 7) return null;
  const today = rows[rows.length - 1];
  const baseline = rows.slice(-15, -1);
  if (baseline.length < 6) return null;

  // Mirror of analyze.js:sickDayDetect. Morning HRV is the recovery-grade
  // signal and whole-day SDNN only the fallback — buildRecovery already prefers
  // it, and on 2026-08-11 that difference alone kept this rule silent.
  const hrvOf = (r: HealthUploadDay): number | null =>
    typeof r.hrvMorning === 'number' ? r.hrvMorning : typeof r.hrv === 'number' ? r.hrv : null;

  function medOf(pick: (r: HealthUploadDay) => number | null | undefined): number | null {
    const vs = baseline.map(pick).filter((v): v is number => typeof v === 'number' && Number.isFinite(v));
    return vs.length >= 4 ? median(vs) : null;
  }
  const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const r2 = (x: number) => Math.round(x * 100) / 100;
  const r1 = (x: number) => Math.round(x * 10) / 10;

  const rhrMed = medOf((r) => r.restingHeartRate);
  const hrvMed = medOf(hrvOf);
  const tempMed = medOf((r) => r.wristTempDeviation);
  const rrMed = medOf((r) => r.respiratoryRate);
  const awakeMed = medOf((r) => r.awakeMin);

  const todayRhr = num(today.restingHeartRate);
  const todayHrv = hrvOf(today);
  const todayTemp = num(today.wristTempDeviation);
  const todayRr = num(today.respiratoryRate);
  const todayAwake = num(today.awakeMin);

  const rhrDelta = rhrMed && todayRhr !== null ? ((todayRhr - rhrMed) / rhrMed) * 100 : null;
  const hrvDelta = hrvMed && todayHrv !== null ? ((todayHrv - hrvMed) / hrvMed) * 100 : null;
  const tempDelta = tempMed !== null && todayTemp !== null ? todayTemp - tempMed : null;
  const rrDelta = rrMed !== null && todayRr !== null ? todayRr - rrMed : null;
  const awakeRatio = awakeMed !== null && awakeMed > 0 && todayAwake !== null ? todayAwake / awakeMed : null;

  const fires = {
    rhr: rhrDelta !== null && rhrDelta >= thresholds.rhrPct,
    hrv: hrvDelta !== null && hrvDelta <= -thresholds.hrvPct,
    temp: tempDelta !== null && tempDelta >= thresholds.tempC,
    rr: rrDelta !== null && rrDelta >= thresholds.rrAbs,
    awake: awakeRatio !== null && awakeRatio >= thresholds.awakeRatio,
  };
  const matched = Object.values(fires).filter(Boolean).length;

  // The fire decision is the weighted score, not the vote count. `matched` and
  // `fires` survive as the human-readable evidence list — Greg quotes them.
  // Exceedance is 1.0 at threshold, clipped at 3 so one extreme reading cannot
  // carry the whole score. `awakeRatio` is already a ratio against its own 2.0
  // threshold, so it normalises the same way as the differences.
  const ex: Record<string, number | null> = {
    rhr: rhrDelta === null ? null : Math.max(0, rhrDelta / thresholds.rhrPct),
    hrv: hrvDelta === null ? null : Math.max(0, -hrvDelta / thresholds.hrvPct),
    temp: tempDelta === null ? null : Math.max(0, tempDelta / thresholds.tempC),
    rr: rrDelta === null ? null : Math.max(0, rrDelta / thresholds.rrAbs),
    awake: awakeRatio === null ? null : Math.max(0, awakeRatio / thresholds.awakeRatio),
  };
  const unavailable: string[] = [];
  let score = 0;
  let availableWeight = 0;
  for (const [k, w] of Object.entries(SIGNAL_WEIGHTS)) {
    const e = ex[k];
    if (e === null || e === undefined) {
      unavailable.push(k);
      continue;
    }
    availableWeight += w;
    score += w * Math.min(3, e);
  }
  // Scale the bar to the weight actually on the table. Without this, a night
  // missing wrist temperature silently needs more evidence than a complete one —
  // the detector would get quieter exactly when it is already partly blind.
  const scoreThreshold =
    availableWeight > 0
      ? Math.round(SICK_DAY_SCORE_T * (availableWeight / TOTAL_WEIGHT) * 100) / 100
      : SICK_DAY_SCORE_T;
  score = Math.round(score * 100) / 100;
  if (score < scoreThreshold) return null;

  return {
    date: today.date,
    matched,
    score,
    score_threshold: scoreThreshold,
    unavailable,
    signal: {
      rhr_delta_pct: rhrDelta !== null ? r1(rhrDelta) : null,
      hrv_delta_pct: hrvDelta !== null ? r1(hrvDelta) : null,
      temp_delta_c: tempDelta !== null ? r2(tempDelta) : null,
      rr_delta_abs: rrDelta !== null ? r2(rrDelta) : null,
      awake_ratio: awakeRatio !== null ? r2(awakeRatio) : null,
    },
    fires,
  };
}

export interface SickDayCheckArgs {
  /** Agent-group id to wake (`greg`; folder and id are now unified). The
   *  HTTP handler resolves
   *  this from env `SICK_DAY_TARGET_AGENT_GROUP_ID` (falls back to undefined,
   *  in which case this function is a no-op). */
  agentGroupId: string | undefined;
  /** Person performing the upload. Only their owned session will be woken.
   *  Uses OWNER_PERSON_KEY if not provided (single-user back-compat). */
  ownerKey: string;
  allRows: HealthUploadDay[]; // entire raw.jsonl decoded, oldest→newest
}

/** Most recent sick_day_check already written into this session for `date`. */
function readPriorSickDayCheck(
  agentGroupId: string,
  sessionId: string,
  date: string,
): { matched: number; score: number | null; fires: Record<string, boolean> } | null {
  const rows = readSessionMessagesByPlatform(agentGroupId, sessionId, 'host-sick-day');
  for (let i = rows.length - 1; i >= 0; i--) {
    try {
      const c = JSON.parse(rows[i].content);
      if (c.kind === 'sick_day_check' && c.detection?.date === date) {
        return {
          matched: c.detection.matched,
          // Rows written before the weighted score shipped have no `score`.
          score: typeof c.detection.score === 'number' ? c.detection.score : null,
          fires: c.detection.fires ?? {},
        };
      }
    } catch {
      /* non-JSON rows are not ours */
    }
  }
  return null;
}

/**
 * One median-weight signal's worth of new evidence (weights are normalised to
 * mean 1.0, exceedance is 1.0 at threshold). Below this the score is drifting
 * as the day's readings fill in, not deteriorating.
 */
const SCORE_WORSENED_BY = 1.0;

export async function sickDayCheck({ agentGroupId, ownerKey, allRows }: SickDayCheckArgs): Promise<void> {
  if (!agentGroupId) return; // not configured on this install
  const detection = detect(allRows);
  if (!detection) return;

  // Find an active session for agentGroupId that belongs to this person.
  // Mirror the owner-scoping in agent-route.ts resolveTargetSession.
  let fresh = getSessionsByAgentGroup(agentGroupId)
    .filter((s) => s.status === 'active' && (s.owner_key || OWNER_PERSON_KEY) === ownerKey)
    .sort((a, b) => b.created_at.localeCompare(a.created_at))[0];

  if (!fresh) {
    // No active session for this person — create a fresh owner-stamped one.
    // Proactive sick-day must fire even when the health agent is idle.
    // 'per-thread' + null messagingGroupId skips all reuse branches and stamps owner_key.
    log.info('sick-day trigger: no active session for person, creating owner-stamped session', {
      agentGroupId,
      ownerKey,
    });
    fresh = resolveSession(agentGroupId, null, null, 'per-thread', ownerKey).session;
  }

  // The host fires on every health upload; iOS uploads several times a day.
  // Without a guard that is one container wake and one full LLM turn per upload
  // for the same detection — five on 2026-08-12. Re-fire only when the picture
  // actually worsens, so a deteriorating day still reaches Greg immediately.
  const prior = readPriorSickDayCheck(agentGroupId, fresh.id, detection.date);
  if (prior) {
    const keys = Object.keys(detection.fires) as (keyof typeof detection.fires)[];
    const newSignal = keys.some((k) => detection.fires[k] && !prior.fires[k]);
    // `matched` is no longer the fire decision — the weighted score is — so a
    // fever climbing from +0.4 °C to +2.0 °C worsens the picture without moving
    // the vote count or adding a signal. Watch the score too, or the guard
    // swallows exactly the deterioration it promises to let through.
    const scoreWorsened = prior.score !== null && detection.score >= prior.score + SCORE_WORSENED_BY;
    if (detection.matched <= prior.matched && !newSignal && !scoreWorsened) {
      log.info('sick-day trigger suppressed (already reported, not worse)', {
        agentGroupId,
        date: detection.date,
        matched: detection.matched,
        score: detection.score,
        priorScore: prior.score,
      });
      return;
    }
  }

  const msgId = `sickday-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  writeSessionMessage(agentGroupId, fresh.id, {
    id: msgId,
    kind: 'chat',
    timestamp: new Date().toISOString(),
    platformId: 'host-sick-day',
    channelType: 'system',
    threadId: null,
    content: JSON.stringify({
      kind: 'sick_day_check',
      detection: {
        date: detection.date,
        matched: detection.matched,
        score: detection.score,
        score_threshold: detection.score_threshold,
        fires: detection.fires,
        unavailable: detection.unavailable,
      },
      signal: detection.signal,
    }),
    sourceSessionId: null,
    a2aHops: 0,
  });

  log.info('sick-day trigger fired', { agentGroupId, sessionId: fresh.id, detection });
  await wakeContainer(fresh);
}
