import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { initTestDb, closeDb, runMigrations, getDb } from '../../../db/index.js';
import { upsertIosToken, resolveIosToken, hashToken } from './token-registry.js';

describe('ios token registry', () => {
  beforeEach(() => {
    const db = initTestDb();
    runMigrations(db);
  });
  afterEach(() => closeDb());

  it('resolves a stored token to its platform_id + person_key', () => {
    upsertIosToken({ rawToken: 'secret-abc', platformId: 'ios-app-v2:p2', personKey: 'p2', label: 'anna phone' });
    expect(resolveIosToken('secret-abc')).toEqual({ platform_id: 'ios-app-v2:p2', person_key: 'p2' });
  });

  it('returns null for an unknown token', () => {
    expect(resolveIosToken('nope')).toBeNull();
  });

  it('stores only the hash of the token, never the raw value', () => {
    upsertIosToken({ rawToken: 'secret-abc', platformId: 'ios-app-v2:p2', personKey: 'p2', label: null });
    expect(hashToken('secret-abc')).toBe(hashToken('secret-abc'));
    expect(hashToken('secret-abc')).not.toBe('secret-abc');
    const row = getDb().prepare('SELECT * FROM ios_tokens WHERE platform_id = ?').get('ios-app-v2:p2') as Record<
      string,
      unknown
    >;
    expect(row.token_hash).toBe(hashToken('secret-abc'));
    expect(Object.values(row)).not.toContain('secret-abc');
  });

  it('upsert is idempotent on platform_id (re-mint updates the hash)', () => {
    upsertIosToken({ rawToken: 'old', platformId: 'ios-app-v2:p2', personKey: 'p2', label: null });
    upsertIosToken({ rawToken: 'new', platformId: 'ios-app-v2:p2', personKey: 'p2', label: null });
    expect(resolveIosToken('old')).toBeNull();
    expect(resolveIosToken('new')).toEqual({ platform_id: 'ios-app-v2:p2', person_key: 'p2' });
  });
});
