/**
 * Gate-log module — durable, queryable telemetry for the `edit_message` gate.
 *
 * The container emits one `log_gate_event` system action per edit attempt
 * (container/agent-runner/src/mcp-tools/gate-events.ts). This handler stamps the
 * emitting agent group + session (which the container doesn't know) from the
 * session the message came in on, and inserts a row into the central
 * `gate_events` table (migration 023). Analysis via scripts/q.ts, e.g.
 *   SELECT decision, count(*), avg(change_ratio) FROM gate_events GROUP BY decision;
 *   SELECT * FROM gate_events WHERE decision='allowed' AND change_ratio > 0.5;  -- near-misses
 *
 * Best-effort: a logging failure must never break message delivery, so the
 * insert is wrapped and only warns.
 */
import { registerDeliveryAction } from '../../delivery.js';
import { getDb } from '../../db/connection.js';
import { log } from '../../log.js';
import type { Session } from '../../types.js';
import { insertGateEvent } from './db.js';

function numOrNull(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

function strOrNull(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

export async function handleLogGateEvent(content: Record<string, unknown>, session: Session): Promise<void> {
  try {
    insertGateEvent(getDb(), {
      created_at: new Date().toISOString(),
      agent_group_id: session.agent_group_id ?? null,
      session_id: session.id ?? null,
      seq: numOrNull(content.seq),
      decision: typeof content.decision === 'string' ? content.decision : 'unknown',
      omit_id: content.omitId ? 1 : 0,
      change_ratio: numOrNull(content.ratio),
      age_ms: numOrNull(content.ageMs),
      prev_len: numOrNull(content.prevLen),
      next_len: numOrNull(content.nextLen),
      prev_text: strOrNull(content.prev),
      next_text: strOrNull(content.next),
    });
  } catch (err) {
    log.warn('gate-log insert failed', { err });
  }
}

registerDeliveryAction('log_gate_event', handleLogGateEvent);
