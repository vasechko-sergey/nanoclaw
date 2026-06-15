import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration017: Migration = {
  version: 17,
  name: 'ios-tokens',
  up(db: Database.Database) {
    // Per-person iOS bearer tokens. token_hash = sha256(rawToken) hex — the
    // raw token is never stored. platform_id is the channel identity used for
    // the messaging_group; person_key stamps session.owner_key + per-person paths.
    db.exec(`
      CREATE TABLE IF NOT EXISTS ios_tokens (
        token_hash  TEXT PRIMARY KEY,
        platform_id TEXT NOT NULL UNIQUE,
        person_key  TEXT NOT NULL,
        label       TEXT,
        created_at  TEXT NOT NULL
      );
    `);
  },
};
