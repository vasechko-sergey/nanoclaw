import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import type { DeviceRow } from './types.js';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS devices (
  platform_id TEXT PRIMARY KEY,
  last_seen_outbound_seq INTEGER NOT NULL DEFAULT 0,
  last_emitted_inbound_seq INTEGER NOT NULL DEFAULT 0,
  capabilities_json TEXT,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS outbound_queue (
  platform_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  id TEXT NOT NULL,
  kind TEXT NOT NULL,
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (platform_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_outbound_id ON outbound_queue (platform_id, id);
CREATE INDEX IF NOT EXISTS idx_outbound_created ON outbound_queue (platform_id, created_at);

CREATE TABLE IF NOT EXISTS inbound_dedup (
  platform_id TEXT NOT NULL,
  id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (platform_id, id)
);
CREATE INDEX IF NOT EXISTS idx_inbound_dedup_received ON inbound_dedup (received_at);

CREATE TABLE IF NOT EXISTS pending_context_requests (
  request_id TEXT PRIMARY KEY,
  platform_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  fields_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pending_expires ON pending_context_requests (expires_at);
`;

export interface TransportDb {
  raw: Database.Database;
  upsertDevice(platform_id: string, opts: { capabilities?: string[] }): void;
  getDevice(platform_id: string): DeviceRow | undefined;
  advanceLastSeenOutbound(platform_id: string, seq: number): void;
  allocateInboundSeq(platform_id: string): number;
}

export function openTransportDb(path: string): TransportDb {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  // WAL is only meaningful for file-backed DBs; skip for in-memory.
  if (path !== ':memory:') {
    try {
      db.pragma('journal_mode = WAL');
    } catch {
      // ignore — fall back to default journal mode
    }
  }
  db.exec(SCHEMA);

  return {
    raw: db,
    upsertDevice(platform_id, opts) {
      db.prepare(
        `
        INSERT INTO devices (platform_id, capabilities_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(platform_id) DO UPDATE SET
          capabilities_json = excluded.capabilities_json,
          updated_at = excluded.updated_at
      `,
      ).run(platform_id, JSON.stringify(opts.capabilities ?? null), Date.now());
    },
    getDevice(platform_id) {
      return db.prepare(`SELECT * FROM devices WHERE platform_id = ?`).get(platform_id) as DeviceRow | undefined;
    },
    advanceLastSeenOutbound(platform_id, seq) {
      db.prepare(
        `
        UPDATE devices
        SET last_seen_outbound_seq = MAX(last_seen_outbound_seq, ?), updated_at = ?
        WHERE platform_id = ?
      `,
      ).run(seq, Date.now(), platform_id);
    },
    allocateInboundSeq(platform_id) {
      const row = db
        .prepare(
          `
        UPDATE devices
        SET last_emitted_inbound_seq = last_emitted_inbound_seq + 1, updated_at = ?
        WHERE platform_id = ?
        RETURNING last_emitted_inbound_seq AS seq
      `,
        )
        .get(Date.now(), platform_id) as { seq: number } | undefined;
      if (!row) throw new Error(`unknown platform_id: ${platform_id}`);
      return row.seq;
    },
  };
}
