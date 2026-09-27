// An outbound message's attachments ride inline (base64) in ONE WebSocket
// frame, and the iOS app refuses a frame above its receive limit: the socket
// closes with 1009, the row is never acked, and every reconnect re-drains it
// first — the device never recovers (Lena, 2026-09-27: a recoloured 1.4 MB
// photo became a 1.9 MB frame against the app's old 1 MiB default). deliver()
// therefore caps the attachment bytes per message so every frame it can build
// provably fits the app's limit; a file that doesn't fit is named in the text.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'fs';
import path from 'path';
import os from 'os';

const { mockEnv } = vi.hoisted(() => ({ mockEnv: {} as Record<string, string> }));
vi.mock('../../../env.js', () => ({
  readEnvFile: vi.fn((keys: string[]) => {
    const out: Record<string, string> = {};
    for (const k of keys) if (mockEnv[k]) out[k] = mockEnv[k];
    return out;
  }),
}));

import { initTestDb, closeDb } from '../../../db/index.js';
import { runMigrations } from '../../../db/migrations/index.js';
import { openTransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { createV2Adapter } from './index.js';
import { CLIENT_MAX_FRAME_BYTES, MAX_ATTACHMENT_BYTES } from './types.js';

const platformId = 'ios-app-v2:lena';
let tmpDir: string;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-attach-'));
  mockEnv.IOS_APP_TOKEN = 'tok';
  mockEnv.IOS_APP_V2_PORT = '4598';
  mockEnv.IOS_APP_V2_DB_PATH = path.join(tmpDir, 'transport.db');
  runMigrations(initTestDb());
  const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH);
  tdb.upsertDevice(platformId, { capabilities: ['image_ref'] });
  tdb.raw.close();
});

afterEach(() => {
  closeDb();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

async function deliverFiles(text: string, files: Array<{ filename: string; data: Buffer }>) {
  const adapter = createV2Adapter()!;
  await adapter.deliver(platformId, 'default', { kind: 'chat', content: { text }, files } as any);
  const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
  const rows = new OutboundQueue(tdb).list(platformId);
  tdb.raw.close();
  expect(rows).toHaveLength(1);
  return { row: rows[0], payload: JSON.parse(rows[0].payload_json) };
}

/** The exact frame ws-handler writes for a queued row (drain / push / retry). */
function frameBytes(row: {
  kind: string;
  type: string;
  id: string;
  seq: number;
  created_at: number;
  payload_json: string;
}) {
  return Buffer.byteLength(
    JSON.stringify({
      v: 2,
      kind: row.kind,
      type: row.type,
      id: row.id,
      seq: row.seq,
      ts: new Date(row.created_at).toISOString(),
      payload: JSON.parse(row.payload_json),
    }),
  );
}

describe('ios-app-v2 deliver() attachment budget', () => {
  it('inlines a photo that fits the budget (Lena’s 1.4 MB recolour)', async () => {
    const photo = Buffer.alloc(1_448_000, 7);
    const { payload } = await deliverFiles('Готово', [{ filename: 'moto_blue.jpg', data: photo }]);
    expect(payload.text).toBe('Готово');
    expect(payload.attachments).toHaveLength(1);
    expect(payload.attachments[0].kind).toBe('image');
    expect(Buffer.from(payload.attachments[0].bytes_base64, 'base64').equals(photo)).toBe(true);
  });

  it('names a file over the budget in the text instead of inlining it', async () => {
    const { payload } = await deliverFiles('Вот видео', [
      { filename: 'ride.mov', data: Buffer.alloc(MAX_ATTACHMENT_BYTES + 1) },
    ]);
    expect(payload.attachments).toBeUndefined();
    expect(payload.text).toContain('Вот видео');
    expect(payload.text).toContain('ride.mov');
  });

  it('spends the budget per message, not per file', async () => {
    const half = Math.floor(MAX_ATTACHMENT_BYTES * 0.6);
    const { row, payload } = await deliverFiles('', [
      { filename: 'a.jpg', data: Buffer.alloc(half) },
      { filename: 'b.jpg', data: Buffer.alloc(half) },
    ]);
    expect(payload.attachments.map((a: { name: string }) => a.name)).toEqual(['a.jpg']);
    expect(payload.text).toContain('b.jpg');
    expect(frameBytes(row)).toBeLessThanOrEqual(CLIENT_MAX_FRAME_BYTES);
  });

  it('the biggest message deliver() can build still fits the app frame limit', async () => {
    const { row, payload } = await deliverFiles('x'.repeat(64 * 1024), [
      { filename: 'max.jpg', data: Buffer.alloc(MAX_ATTACHMENT_BYTES) },
    ]);
    expect(payload.attachments).toHaveLength(1);
    expect(frameBytes(row)).toBeLessThanOrEqual(CLIENT_MAX_FRAME_BYTES);
  });
});
