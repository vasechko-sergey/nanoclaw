import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration023: Migration = {
  version: 23,
  name: 'gate-events',
  up(db: Database.Database) {
    // One row per edit_message attempt that reaches the gate logic. The
    // container emits these as `log_gate_event` system actions; the gate-log
    // delivery handler stamps agent_group_id + session_id and inserts here.
    // Purpose: tune the gate thresholds (change_ratio 0.6, min-len 40,
    // stale-age 60 min) against real traffic — including near-misses (allowed
    // edits with a ratio just under the wall).
    db.prepare(
      `CREATE TABLE gate_events (
         id             INTEGER PRIMARY KEY AUTOINCREMENT,
         created_at     TEXT NOT NULL,
         agent_group_id TEXT,
         session_id     TEXT,
         seq            INTEGER,
         decision       TEXT NOT NULL,
         omit_id        INTEGER NOT NULL DEFAULT 0,
         change_ratio   REAL,
         age_ms         INTEGER,
         prev_len       INTEGER,
         next_len       INTEGER,
         prev_text      TEXT,
         next_text      TEXT
       )`,
    ).run();
    db.prepare('CREATE INDEX idx_gate_events_created ON gate_events(created_at)').run();
  },
};
