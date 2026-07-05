import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration024: Migration = {
  version: 24,
  name: 'person-tz',
  up(db: Database.Database) {
    // Last-known device timezone per person (person_key == session.owner_key ==
    // ios person_key). Populated from iOS requests that carry an IANA tz; read
    // by recurrence + the Сводка-ready detector so scheduled tasks fire on the
    // owner's current wall-clock. Separate from ios_tokens because token re-mint
    // DELETEs that row; this must survive it.
    db.prepare(
      `CREATE TABLE person_tz (
         person_key TEXT PRIMARY KEY,
         tz         TEXT NOT NULL,
         updated_at TEXT NOT NULL
       )`,
    ).run();
  },
};
