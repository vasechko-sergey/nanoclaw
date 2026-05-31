// Per-device pending health-fetch requests.
//
// Producer: agent MCP tool (request_health_history, future). Not wired up
// yet — this store exists so the iOS read/clear endpoints (GET
// /ios/health/requests + POST /ios/health/upload) can be served by the v2
// adapter without 404ing during the legacy → v2 cutover.
//
// Consumer: iOS app over HTTP — pulls the queue on foreground + on HealthKit
// background-delivery wake, services each request, POSTs the daily aggregates
// to /ios/health/upload which calls `clear(request_id)`.
import type { TransportDb } from './transport-db.js';

export interface HealthRequest {
  request_id: string;
  platform_id: string;
  days: number;
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
  }

  enqueue(platform_id: string, request_id: string, days: number): void {
    this.db.raw
      .prepare(
        `INSERT OR IGNORE INTO health_requests (request_id, platform_id, days, created_at)
         VALUES (?, ?, ?, ?)`,
      )
      .run(request_id, platform_id, days, Date.now());
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
