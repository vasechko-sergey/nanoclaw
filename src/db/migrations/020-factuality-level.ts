import type Database from 'better-sqlite3';
import type { Migration } from './index.js';

export const migration020: Migration = {
  version: 20,
  name: 'factuality-level',
  up(db: Database.Database) {
    db.prepare('ALTER TABLE container_configs ADD COLUMN factuality_level INTEGER NOT NULL DEFAULT 0').run();
    db.prepare(
      'UPDATE container_configs SET factuality_level = CASE factuality_gate ' +
        "WHEN 'deterministic' THEN 1 WHEN 'full' THEN 2 ELSE 0 END",
    ).run();
  },
};
