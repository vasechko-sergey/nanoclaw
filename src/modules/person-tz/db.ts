import type Database from 'better-sqlite3';

export interface PersonTzRow {
  person_key: string;
  tz: string;
  updated_at: string;
}

/**
 * Upsert a person's last-known tz. Last-writer-wins on the zone, but the
 * ON CONFLICT WHERE guard skips the UPDATE when the zone is unchanged, so
 * `updated_at` keeps its "here since" meaning.
 */
export function upsertPersonTz(db: Database.Database, personKey: string, tz: string, updatedAt: string): void {
  db.prepare(
    `INSERT INTO person_tz (person_key, tz, updated_at)
     VALUES (@person_key, @tz, @updated_at)
     ON CONFLICT(person_key) DO UPDATE SET tz = excluded.tz, updated_at = excluded.updated_at
       WHERE person_tz.tz <> excluded.tz`,
  ).run({ person_key: personKey, tz, updated_at: updatedAt });
}

/** Read a person's stored tz, or null. */
export function getPersonTz(db: Database.Database, personKey: string): string | null {
  const row = db.prepare('SELECT tz FROM person_tz WHERE person_key = ?').get(personKey) as { tz: string } | undefined;
  return row?.tz ?? null;
}
