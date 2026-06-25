import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration021: Migration = {
  version: 21,
  name: 'voice-only',
  up(db: Database.Database) {
    // voice_only: when 1, delivery holds the text behind a placeholder and
    // delivers it together with the rendered voice note (iOS voice-only mode).
    // Persisted per-session like voice_intent because delivery (outbound) can't
    // see the inbound ios_context that sets it.
    db.prepare('ALTER TABLE sessions ADD COLUMN voice_only INTEGER NOT NULL DEFAULT 0').run();
  },
};
