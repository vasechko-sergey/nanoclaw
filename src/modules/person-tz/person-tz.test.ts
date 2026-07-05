import { describe, it, expect, beforeEach } from 'vitest';
import Database from 'better-sqlite3';

import { runMigrations } from '../../db/migrations/index.js';

describe('migration 024 person_tz', () => {
  let db: Database.Database;
  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
  });

  it('creates the person_tz table', () => {
    const t = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='person_tz'").get();
    expect(t).toBeTruthy();
  });
});
