// Per-device pending health-fetch requests.
//
// Producer: `scanHealthRequestFiles` over the health agent's
// `health/requests/*.json` drop directory, drained by GET /ios/health/requests.
// Greg has written those files daily since June ("Освежение данных —
// ОБЯЗАТЕЛЬНО каждый прогон"); until 2026-08-13 nothing read them and this
// store had no producer at all, so the agent's mandatory refresh was a no-op
// and health.db was fed solely by the app's own background sync.
//
// Consumer: iOS app over HTTP — pulls the queue on foreground + on HealthKit
// background-delivery wake, services each request, POSTs the daily aggregates
// to /ios/health/upload which calls `clear(request_id)`.
import type { TransportDb } from './transport-db.js';

export interface HealthRequest {
  request_id: string;
  platform_id: string;
  /** Span of the window in days. Kept because the column is NOT NULL from the
   *  original schema; `from_date`/`to_date` are what the client actually uses. */
  days: number;
  from_date: string | null;
  to_date: string | null;
  created_at: number;
}

export class HealthRequestsStore {
  constructor(private db: TransportDb) {
    this.db.raw.exec(`
      CREATE TABLE IF NOT EXISTS health_requests (
        request_id TEXT PRIMARY KEY,
        platform_id TEXT NOT NULL,
        days INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_health_requests_pid ON health_requests (platform_id);
    `);
    // The original table predates the window columns and CREATE TABLE IF NOT
    // EXISTS no-ops on an existing file, so backfill additively — same pattern
    // as health-db.ts. SQLite has no IF NOT EXISTS for ADD COLUMN; probe first.
    const existing = new Set(
      (this.db.raw.prepare(`PRAGMA table_info(health_requests)`).all() as { name: string }[]).map((c) => c.name),
    );
    for (const col of ['from_date', 'to_date']) {
      if (!existing.has(col)) this.db.raw.exec(`ALTER TABLE health_requests ADD COLUMN ${col} TEXT`);
    }
  }

  /** Enqueue an explicit date window. `request_id` doubles as the drop-file
   *  basename so `clear` can delete the file that produced it — callers must
   *  pass one that survived `isSafeRequestId`. */
  enqueueWindow(platform_id: string, request_id: string, from: string, to: string): void {
    const span = Math.max(
      1,
      Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1,
    );
    this.db.raw
      .prepare(
        `INSERT OR IGNORE INTO health_requests
           (request_id, platform_id, days, from_date, to_date, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
      )
      .run(request_id, platform_id, span, from, to, Date.now());
  }

  listForDevice(platform_id: string): HealthRequest[] {
    return this.db.raw
      .prepare(`SELECT * FROM health_requests WHERE platform_id = ? ORDER BY created_at ASC`)
      .all(platform_id) as HealthRequest[];
  }

  clear(request_id: string): void {
    this.db.raw.prepare(`DELETE FROM health_requests WHERE request_id = ?`).run(request_id);
  }
}
