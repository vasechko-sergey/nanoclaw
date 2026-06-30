import type Database from 'better-sqlite3';

export function getLastNotified(db: Database.Database, personKey: string): string | null {
  const row = db.prepare('SELECT last_notified_date FROM summary_notify_log WHERE person_key = ?').get(personKey) as
    | { last_notified_date: string }
    | undefined;
  return row?.last_notified_date ?? null;
}

export function setLastNotified(db: Database.Database, personKey: string, date: string): void {
  db.prepare(
    `INSERT INTO summary_notify_log (person_key, last_notified_date)
     VALUES (?, ?)
     ON CONFLICT(person_key) DO UPDATE SET last_notified_date = excluded.last_notified_date`,
  ).run(personKey, date);
}
