import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration019: Migration = {
  version: 19,
  name: 'factuality-gate',
  up(db: Database.Database) {
    db.prepare("ALTER TABLE container_configs ADD COLUMN factuality_gate TEXT NOT NULL DEFAULT 'off'").run();
  },
};
