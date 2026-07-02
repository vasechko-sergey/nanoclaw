import type Database from 'better-sqlite3';

export interface GateEventRow {
  created_at: string;
  agent_group_id: string | null;
  session_id: string | null;
  seq: number | null;
  decision: string;
  omit_id: number;
  change_ratio: number | null;
  age_ms: number | null;
  prev_len: number | null;
  next_len: number | null;
  prev_text: string | null;
  next_text: string | null;
}

/** Insert one edit-gate telemetry row into the central `gate_events` table. */
export function insertGateEvent(db: Database.Database, row: GateEventRow): void {
  db.prepare(
    `INSERT INTO gate_events
       (created_at, agent_group_id, session_id, seq, decision, omit_id,
        change_ratio, age_ms, prev_len, next_len, prev_text, next_text)
     VALUES
       (@created_at, @agent_group_id, @session_id, @seq, @decision, @omit_id,
        @change_ratio, @age_ms, @prev_len, @next_len, @prev_text, @next_text)`,
  ).run(row);
}
