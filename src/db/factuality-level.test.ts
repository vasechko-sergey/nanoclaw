import { describe, it, expect } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from './migrations/index.js';

describe('migration 020 factuality_level', () => {
  it('adds factuality_level to container_configs after a full migrate', () => {
    const db = new Database(':memory:');
    runMigrations(db);
    const cols = db.prepare('PRAGMA table_info(container_configs)').all() as { name: string }[];
    expect(cols.some((c) => c.name === 'factuality_level')).toBe(true);
  });

  it('backfill CASE maps gate string -> level int', () => {
    const db = new Database(':memory:');
    db.exec('CREATE TABLE t (g TEXT, lvl INTEGER NOT NULL DEFAULT 0)');
    db.prepare("INSERT INTO t (g) VALUES ('full'),('deterministic'),('off'),(NULL)").run();
    db.prepare("UPDATE t SET lvl = CASE g WHEN 'deterministic' THEN 1 WHEN 'full' THEN 2 ELSE 0 END").run();
    const rows = db.prepare('SELECT g, lvl FROM t').all() as { g: string | null; lvl: number }[];
    expect(rows.find((r) => r.g === 'full')!.lvl).toBe(2);
    expect(rows.find((r) => r.g === 'deterministic')!.lvl).toBe(1);
    expect(rows.find((r) => r.g === 'off')!.lvl).toBe(0);
    expect(rows.find((r) => r.g === null)!.lvl).toBe(0);
  });
});
