import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration016: Migration = {
  version: 16,
  name: 'multi-user-identity',
  up(db: Database.Database) {
    // person_key: stable per-human identity above per-channel users rows.
    // NULL → resolver falls back to the user id (each handle isolated) or,
    // for system/headless callers, OWNER_PERSON_KEY.
    db.prepare('ALTER TABLE users ADD COLUMN person_key TEXT').run();
    // owner_key: which person a session's memory belongs to. NULL on pre-
    // migration rows → buildMounts falls back to OWNER_PERSON_KEY.
    db.prepare('ALTER TABLE sessions ADD COLUMN owner_key TEXT').run();
  },
};
