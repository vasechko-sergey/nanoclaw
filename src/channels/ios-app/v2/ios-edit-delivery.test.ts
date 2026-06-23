// The ios-app-v2 adapter turns an agent edit ({operation:'edit', messageId, text})
// into an `update` envelope (id in payload, fresh envelope id), enqueued for the
// device. Mirrors workout-outbound.test.ts: build the real adapter via
// createV2Adapter(), register a device row so seq allocation works, call
// deliver(), read the enqueued envelope back via OutboundQueue.list().
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

let tmpDir: string;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-edit-'));
  mockEnv.IOS_APP_TOKEN = 'tok';
  mockEnv.IOS_APP_V2_PORT = '4599';
  mockEnv.IOS_APP_V2_DB_PATH = path.join(tmpDir, 'transport.db');
  const db = initTestDb();
  runMigrations(db);
});

afterEach(() => {
  closeDb();
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

function registerDevice(platformId: string): void {
  const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
  tdb.upsertDevice(platformId, { capabilities: [] });
  tdb.raw.close();
}

describe('ios-app-v2 deliver() edit dispatch', () => {
  it('emits an update envelope with the target id in the payload', async () => {
    const platformId = 'ios-app-v2:default';
    registerDevice(platformId);
    const adapter = createV2Adapter()!;
    expect(adapter).not.toBeNull();

    await adapter.deliver(platformId, 'default', {
      kind: 'chat',
      content: { operation: 'edit', messageId: 'msg-123-abc', text: 'corrected text' },
    } as any);

    const queue = new OutboundQueue(openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!));
    const rows = queue.list(platformId);
    const update = rows.find((r) => r.type === 'update');
    expect(update).toBeTruthy();
    const payload = JSON.parse(update!.payload_json);
    expect(payload.id).toBe('msg-123-abc');
    expect(payload.text).toBe('corrected text');
    // The envelope's own id must NOT be the target id (else the device dedups
    // the edit as the original message and drops it).
    expect(update!.id).not.toBe('msg-123-abc');
  });

  it('drops an edit with no messageId (no update enqueued)', async () => {
    const platformId = 'ios-app-v2:default';
    registerDevice(platformId);
    const adapter = createV2Adapter()!;
    await adapter.deliver(platformId, 'default', {
      kind: 'chat',
      content: { operation: 'edit', text: 'no target' },
    } as any);
    const queue = new OutboundQueue(openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!));
    expect(queue.list(platformId).some((r) => r.type === 'update')).toBe(false);
  });
});
