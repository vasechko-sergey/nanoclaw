import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { initTestDb, closeDb, runMigrations } from './db/index.js';
import { upsertUser, setPersonKey } from './modules/permissions/db/users.js';
import { resolvePersonKey, OWNER_PERSON_KEY } from './person-key.js';

describe('resolvePersonKey', () => {
  beforeEach(() => {
    const db = initTestDb();
    runMigrations(db);
  });
  afterEach(() => closeDb());

  it('returns OWNER_PERSON_KEY when userId is null', () => {
    expect(resolvePersonKey(null)).toBe(OWNER_PERSON_KEY);
  });

  it('returns the handle itself when the user has no person_key', () => {
    upsertUser({
      id: 'telegram:111',
      kind: 'telegram',
      display_name: null,
      person_key: null,
      created_at: new Date().toISOString(),
    });
    expect(resolvePersonKey('telegram:111')).toBe('telegram:111');
  });

  it('returns the assigned person_key when set', () => {
    upsertUser({
      id: 'telegram:111',
      kind: 'telegram',
      display_name: null,
      person_key: null,
      created_at: new Date().toISOString(),
    });
    setPersonKey('telegram:111', 'sergei');
    expect(resolvePersonKey('telegram:111')).toBe('sergei');
  });

  it('returns the handle for an unknown user id', () => {
    expect(resolvePersonKey('telegram:999')).toBe('telegram:999');
  });

  it('upsertUser with null person_key does not overwrite an existing key', () => {
    upsertUser({
      id: 'telegram:111',
      kind: 'telegram',
      display_name: null,
      person_key: 'sergei',
      created_at: new Date().toISOString(),
    });
    upsertUser({
      id: 'telegram:111',
      kind: 'telegram',
      display_name: 'X',
      person_key: null,
      created_at: new Date().toISOString(),
    });
    expect(resolvePersonKey('telegram:111')).toBe('sergei');
  });
});
