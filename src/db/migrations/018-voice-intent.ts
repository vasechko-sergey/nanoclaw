import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration018: Migration = {
  version: 18,
  name: 'voice-intent',
  up(db: Database.Database) {
    // voice_intent: computed per-session by the router from ios_context and the
    // messaging group's voice_mode. 1 = delivery should render a voice note for
    // this session's next reply, 0 = text only.
    db.prepare('ALTER TABLE sessions ADD COLUMN voice_intent INTEGER NOT NULL DEFAULT 0').run();
    // voice_mode: group-level flag. When 1, every reply to this messaging group
    // is rendered as a voice note (regardless of per-message ios_context).
    db.prepare('ALTER TABLE messaging_groups ADD COLUMN voice_mode INTEGER NOT NULL DEFAULT 0').run();
  },
};
