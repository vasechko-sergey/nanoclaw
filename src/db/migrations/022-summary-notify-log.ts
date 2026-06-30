import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration022: Migration = {
  version: 22,
  name: 'summary-notify-log',
  up(db: Database.Database) {
    // One row per person: the last date (in the person's TZ) we fired the
    // "Сводка готова" notification. Prevents double-fire across host restarts
    // and re-sweeps within the same morning.
    db.prepare(
      `CREATE TABLE summary_notify_log (
         person_key TEXT PRIMARY KEY,
         last_notified_date TEXT NOT NULL
       )`,
    ).run();
  },
};
