// TDD test for Task 8: ios-app-v2 registers a summary_ready emitter on setup.
//
// Pattern mirrors ios-edit-delivery.test.ts: stub readEnvFile so createV2Adapter
// sees deterministic config without touching the real .env or binding a real port.
// After calling createV2Adapter() the emitter is registered; invoke it and assert
// a summary_ready row is enqueued for the device with the composed text body.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const { mockEnv } = vi.hoisted(() => ({ mockEnv: {} as Record<string, string> }));
vi.mock('../../../env.js', () => ({
  readEnvFile: vi.fn((keys: string[]) => {
    const out: Record<string, string> = {};
    for (const k of keys) if (mockEnv[k]) out[k] = mockEnv[k];
    return out;
  }),
}));

import { initTestDb, closeDb, getDb } from '../../../db/index.js';
import { runMigrations } from '../../../db/migrations/index.js';
import { openTransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { createV2Adapter } from './index.js';
import { getSummaryEmitter, __resetSummaryEmitter } from '../../../modules/summary-notify/emit-registry.js';

let tmpDir: string;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-summary-emit-'));
  mockEnv.IOS_APP_TOKEN = 'tok';
  mockEnv.IOS_APP_V2_PORT = '4599';
  mockEnv.IOS_APP_V2_DB_PATH = path.join(tmpDir, 'transport.db');
  const db = initTestDb();
  runMigrations(db);
});

afterEach(() => {
  __resetSummaryEmitter();
  closeDb();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

/**
 * Register a device row in the transport DB so seq allocation works.
 * Mirrors the helper in ios-edit-delivery.test.ts.
 */
function registerDevice(platformId: string): void {
  const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
  tdb.upsertDevice(platformId, { capabilities: [] });
  tdb.raw.close();
}

/**
 * Insert a users row into the central DB so getDevicePlatformIds can resolve
 * the person → device mapping.  The id must match the platformId used by the
 * device row, and kind must be 'ios-app-v2'.
 */
function registerUser(platformId: string, personKey: string): void {
  getDb()
    .prepare(
      `INSERT INTO users (id, kind, display_name, person_key, created_at)
       VALUES (?, 'ios-app-v2', NULL, ?, ?)
       ON CONFLICT(id) DO UPDATE SET person_key = excluded.person_key`,
    )
    .run(platformId, personKey, new Date().toISOString());
}

describe('ios-app-v2 summary emitter registration', () => {
  it('enqueues a summary_ready envelope with the composed text body to the person device', () => {
    const platformId = 'ios-app-v2:default';
    const personKey = 'owner';

    registerDevice(platformId);
    registerUser(platformId, personKey);

    // createV2Adapter() must register the summary emitter so getSummaryEmitter()
    // returns a defined function after this call.
    createV2Adapter();

    const emitter = getSummaryEmitter();
    expect(emitter, 'summary emitter should be registered after createV2Adapter()').toBeDefined();

    // Fire the emitter — it should look up the person's device via the central DB
    // and enqueue a summary_ready envelope via handler.sendEnvelopeToDevice.
    emitter!(personKey, { date: '2026-06-30', count: 5 });

    // Read the queue from the same transport DB the adapter used.
    const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
    const queue = new OutboundQueue(tdb);
    const rows = queue.listPendingNotify(platformId, 0);
    tdb.raw.close();

    const summary = rows.find((r) => r.type === 'summary_ready');
    expect(summary, 'a summary_ready row must be enqueued for the device').toBeTruthy();

    const payload = JSON.parse(summary!.payload_json) as {
      date: string;
      count: number;
      text: string;
      agent_id?: string;
    };
    expect(payload.date).toBe('2026-06-30');
    expect(payload.count).toBe(5);
    expect(payload.text).toContain('5');
    // The envelope id must be stable (same call = same id) so the device can dedup.
    expect(summary!.id).toBe(`summary-${personKey}-2026-06-30`);
  });

  it('does nothing when the person has no registered devices', () => {
    const personKey = 'ghost'; // no users row for this person

    createV2Adapter();

    const emitter = getSummaryEmitter();
    expect(emitter).toBeDefined();

    // Should not throw; queue stays empty.
    expect(() => emitter!(personKey, { date: '2026-06-30', count: 3 })).not.toThrow();

    // No rows for any platformId.
    const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
    const queue = new OutboundQueue(tdb);
    // No device registered, so nothing to query — count all summary_ready by
    // reading raw SQL.
    const count = tdb.raw.prepare(`SELECT COUNT(*) AS n FROM outbound_queue WHERE type = 'summary_ready'`).get() as {
      n: number;
    };
    tdb.raw.close();
    expect(count.n).toBe(0);
  });
});
