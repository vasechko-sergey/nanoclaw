/**
 * Edit-gate telemetry (container side).
 *
 * Every `edit_message` attempt that reaches the gate logic emits ONE event so
 * the thresholds (change-ratio 0.6, min-length 40, stale-age 60 min) can be
 * tuned against real traffic rather than guessed. The event rides the existing
 * system-action ferry: a `kind='system'` outbound row with
 * `{action:'log_gate_event', ...}`. The host's gate-log delivery handler stamps
 * the agent group + session and inserts it into the central `gate_events` table.
 *
 * Container logs are lost on `--rm`, so `console.error` would be useless for
 * later analysis — the DB ferry is the only durable, queryable sink.
 */
import { writeMessageOut } from '../db/messages-out.js';

/** Cap on stored prev/next text — enough to eyeball a false positive, not a whole essay. */
export const GATE_TEXT_CAP = 200;

function cap(s: string | null): string | null {
  if (s === null) return null;
  return s.length > GATE_TEXT_CAP ? s.slice(0, GATE_TEXT_CAP) : s;
}

export type GateDecision = 'allowed' | 'refused_replacement' | 'refused_stale' | 'refused_not_own';

export interface GateEvent {
  decision: GateDecision;
  /** Target message seq (the message being edited), or null when unresolved. */
  seq: number | null;
  /** Was `messageId` omitted ("edit my last") vs. explicitly targeted? */
  omitId: boolean;
  /** Change ratio from classifyReplacement; null when exempt (short/empty) or not evaluated. */
  ratio?: number | null;
  /** Age of the target for the stale gate; null when not evaluated. */
  ageMs?: number | null;
  /** Current text of the target (pre-edit); null when unavailable. */
  prev?: string | null;
  /** Proposed new text. */
  next: string;
}

/**
 * Emit one gate event as a system action. Best-effort: a logging failure must
 * never break the edit itself, so callers wrap this in a try/catch.
 */
export function emitGateEvent(ev: GateEvent): void {
  const prev = ev.prev ?? null;
  writeMessageOut({
    id: `gate-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    kind: 'system',
    content: JSON.stringify({
      action: 'log_gate_event',
      decision: ev.decision,
      seq: ev.seq,
      omitId: ev.omitId,
      ratio: ev.ratio ?? null,
      ageMs: ev.ageMs ?? null,
      prevLen: prev === null ? null : prev.length,
      nextLen: ev.next.length,
      prev: cap(prev),
      next: cap(ev.next) ?? '',
    }),
  });
}
