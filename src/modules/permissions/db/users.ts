import type { User } from '../../../types.js';
import { getDb } from '../../../db/connection.js';

export function createUser(user: User): void {
  getDb()
    .prepare(
      `INSERT INTO users (id, kind, display_name, person_key, created_at)
       VALUES (@id, @kind, @display_name, @person_key, @created_at)`,
    )
    .run(user);
}

export function upsertUser(user: User): void {
  getDb()
    .prepare(
      `INSERT INTO users (id, kind, display_name, person_key, created_at)
       VALUES (@id, @kind, @display_name, @person_key, @created_at)
       ON CONFLICT(id) DO UPDATE SET
         display_name = COALESCE(excluded.display_name, users.display_name),
         person_key   = COALESCE(excluded.person_key, users.person_key)`,
    )
    .run(user);
}

export function setPersonKey(userId: string, personKey: string): void {
  getDb().prepare('UPDATE users SET person_key = ? WHERE id = ?').run(personKey, userId);
}

export function getUser(id: string): User | undefined {
  return getDb().prepare('SELECT * FROM users WHERE id = ?').get(id) as User | undefined;
}

export function getAllUsers(): User[] {
  return getDb().prepare('SELECT * FROM users ORDER BY created_at').all() as User[];
}

export function updateDisplayName(id: string, displayName: string): void {
  getDb().prepare('UPDATE users SET display_name = ? WHERE id = ?').run(displayName, id);
}

export function deleteUser(id: string): void {
  getDb().prepare('DELETE FROM users WHERE id = ?').run(id);
}

/** Platform ids of a person's registered devices for a given channel kind. */
export function getDevicePlatformIds(personKey: string, kind: string): string[] {
  return (
    getDb().prepare('SELECT id FROM users WHERE person_key = ? AND kind = ?').all(personKey, kind) as { id: string }[]
  ).map((r) => r.id);
}
