/**
 * Host-side sick-day trigger.
 *
 * Called after `appendHealthHistory` writes new rows from the iOS app's
 * `POST /ios/health/upload`. We re-implement the three-threshold rule from
 * `groups/greg/scripts/analyze.js:sickDayDetect` (deliberately
 * duplicated — the host can't shell out to bun on the request path) and,
 * if 2 of 3 signals fire, write a one-shot wake message into Greg's
 * session inbound DB so he runs `--mode sick-day` on the next poll.
 *
 * Threshold constants stay in sync with analyze.js by convention. Keep them
 * here as plain numbers — if you change one, change both. The TS-side test
 * (sick-day.test.ts) and Bun-side test (analyze.test.js) both pin the
 * canonical 7%/0.4°C/15% values.
 */
import { writeSessionMessage, resolveSession } from '../../session-manager.js';
import { wakeContainer } from '../../container-runner.js';
import { getSessionsByAgentGroup } from '../../db/sessions.js';
import { OWNER_PERSON_KEY } from '../../config.js';
import { log } from '../../log.js';
import type { HealthUploadDay } from '../../../shared/ios-app-protocol/index.js';

export const SICK_DAY_THRESHOLDS = {
  rhrPct: 7,
  tempC: 0.4,
  hrvPct: 15,
};

function median(xs: number[]): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

interface Detection {
  date: string;
  matched: number;
  signal: {
    rhr_delta_pct: number | null;
    hrv_delta_pct: number | null;
    temp_delta_c: number | null;
  };
  fires: { rhr: boolean; hrv: boolean; temp: boolean };
}

export function detect(rows: HealthUploadDay[], thresholds = SICK_DAY_THRESHOLDS): Detection | null {
  if (!rows || rows.length < 7) return null;
  const today = rows[rows.length - 1];
  const baseline = rows.slice(-15, -1);
  if (baseline.length < 6) return null;

  function medOf(metric: keyof HealthUploadDay): number | null {
    const vs = baseline.map((r) => r[metric]).filter((v): v is number => typeof v === 'number' && Number.isFinite(v));
    return vs.length >= 4 ? median(vs) : null;
  }

  const rhrMed = medOf('restingHeartRate');
  const hrvMed = medOf('hrv');
  const tempMed = medOf('wristTempDeviation');

  const todayRhr = typeof today.restingHeartRate === 'number' ? today.restingHeartRate : null;
  const todayHrv = typeof today.hrv === 'number' ? today.hrv : null;
  const todayTemp = typeof today.wristTempDeviation === 'number' ? today.wristTempDeviation : null;

  const rhrDelta = rhrMed !== null && todayRhr !== null ? ((todayRhr - rhrMed) / rhrMed) * 100 : null;
  const hrvDelta = hrvMed !== null && todayHrv !== null ? ((todayHrv - hrvMed) / hrvMed) * 100 : null;
  const tempDelta = tempMed !== null && todayTemp !== null ? todayTemp - tempMed : null;

  const rhrFires = rhrDelta !== null && rhrDelta >= thresholds.rhrPct;
  const hrvFires = hrvDelta !== null && hrvDelta <= -thresholds.hrvPct;
  const tempFires = tempDelta !== null && tempDelta >= thresholds.tempC;

  const matched = [rhrFires, hrvFires, tempFires].filter(Boolean).length;
  if (matched < 2) return null;

  return {
    date: today.date,
    matched,
    signal: {
      rhr_delta_pct: rhrDelta !== null ? Math.round(rhrDelta * 10) / 10 : null,
      hrv_delta_pct: hrvDelta !== null ? Math.round(hrvDelta * 10) / 10 : null,
      temp_delta_c: tempDelta !== null ? Math.round(tempDelta * 100) / 100 : null,
    },
    fires: { rhr: rhrFires, hrv: hrvFires, temp: tempFires },
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
      detection: { date: detection.date, matched: detection.matched, fires: detection.fires },
      signal: detection.signal,
    }),
    sourceSessionId: null,
    a2aHops: 0,
  });

  log.info('sick-day trigger fired', { agentGroupId, sessionId: fresh.id, detection });
  await wakeContainer(fresh);
}
