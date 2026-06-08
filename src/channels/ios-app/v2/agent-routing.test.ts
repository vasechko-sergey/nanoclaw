// P1.T6 — outbound iOS-app envelopes carry agent_id so the device can
// route the reply into the right per-agent thread.
//
// The adapter receives `agentGroupId` on the OutboundMessage (plumbed
// through from delivery.ts), resolves it to the canonical folder slug via
// the central DB, and stamps `payload.agent_id` on the data:message
// envelope. When agentGroupId is absent (legacy path) or the lookup fails,
// agent_id is omitted and the device falls back to its default-agent slug.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'fs';
import path from 'path';
import os from 'os';
import net from 'node:net';

// Stub readEnvFile so createV2Adapter sees a deterministic config without
// touching the operator's .env. vi.hoisted is required because vi.mock is
// hoisted above all imports and runs during config.ts module load.
const { mockEnv } = vi.hoisted(() => ({ mockEnv: {} as Record<string, string> }));
vi.mock('../../../env.js', () => ({
  readEnvFile: vi.fn((keys: string[]) => {
    const out: Record<string, string> = {};
    for (const k of keys) if (mockEnv[k]) out[k] = mockEnv[k];
    return out;
  }),
}));

import { initTestDb, closeDb, createAgentGroup } from '../../../db/index.js';
import { runMigrations } from '../../../db/migrations/index.js';
import type { ChannelSetup } from '../../adapter.js';
import { openTransportDb } from './transport-db.js';
import { OutboundQueue } from './outbound-queue.js';
import { createV2Adapter } from './index.js';

function makeNoopSetup(): ChannelSetup {
  return {
    onInbound: () => {},
    onInboundEvent: () => {},
    onMetadata: () => {},
    onAction: () => {},
  };
}

/**
 * Register a device row in the transport DB so allocateInboundSeq can
 * UPDATE…RETURNING it. The adapter normally upserts this on auth; in this
 * test we go straight to deliver() so we have to seed it ourselves.
 */
function registerDevice(platformId: string): void {
  const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
  tdb.upsertDevice(platformId, { capabilities: [] });
  tdb.raw.close();
}

let tmpDir: string;
let port: number;

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, () => {
      const p = (srv.address() as { port: number }).port;
      srv.close(() => resolve(p));
    });
  });
}

beforeEach(async () => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'nanoclaw-ios-agent-routing-'));
  port = await freePort();
  mockEnv.IOS_APP_TOKEN = 'test-token';
  mockEnv.IOS_APP_V2_PORT = String(port);
  mockEnv.IOS_APP_V2_DB_PATH = path.join(tmpDir, 'transport.db');
  const db = initTestDb();
  runMigrations(db);
});

afterEach(() => {
  closeDb();
  fs.rmSync(tmpDir, { recursive: true, force: true });
  delete mockEnv.IOS_APP_TOKEN;
  delete mockEnv.IOS_APP_V2_PORT;
  delete mockEnv.IOS_APP_V2_DB_PATH;
});

function nowIso(): string {
  return new Date().toISOString();
}

describe('ios-app v2 adapter — outbound agent_id stamping (P1.T6)', () => {
  it('stamps agent_id from the agent_group folder when agentGroupId is set', async () => {
    createAgentGroup({
      id: 'ag-payne',
      name: 'Payne',
      folder: 'payne',
      agent_provider: null,
      created_at: nowIso(),
    });

    const adapter = createV2Adapter();
    expect(adapter).not.toBeNull();
    if (!adapter) throw new Error('factory returned null');
    await adapter.setup(makeNoopSetup());
    registerDevice('ios-app:default');

    // sendEnvelopeToDevice enqueues into the transport DB even with no
    // connected socket, so we can pull the row back to inspect the payload.
    await adapter.deliver('ios-app:default', 'thread-x', {
      kind: 'chat',
      content: { text: 'hello from payne' },
      agentGroupId: 'ag-payne',
    });

    const transportDb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
    const queue = new OutboundQueue(transportDb);
    const rows = queue.list('ios-app:default');
    expect(rows).toHaveLength(1);
    const payload = JSON.parse(rows[0].payload_json);
    expect(payload.agent_id).toBe('payne');
    expect(payload.text).toBe('hello from payne');
    expect(payload.thread_id).toBe('thread-x');
    transportDb.raw.close();

    await adapter.teardown();
  });

  it('omits agent_id when agentGroupId is absent (legacy single-agent path)', async () => {
    const adapter = createV2Adapter();
    expect(adapter).not.toBeNull();
    if (!adapter) throw new Error('factory returned null');
    await adapter.setup(makeNoopSetup());
    registerDevice('ios-app:default');

    await adapter.deliver('ios-app:default', 'thread-x', {
      kind: 'chat',
      content: { text: 'legacy reply' },
    });

    const transportDb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
    const queue = new OutboundQueue(transportDb);
    const rows = queue.list('ios-app:default');
    expect(rows).toHaveLength(1);
    const payload = JSON.parse(rows[0].payload_json);
    expect(payload.agent_id).toBeUndefined();
    expect(payload.text).toBe('legacy reply');
    transportDb.raw.close();

    await adapter.teardown();
  });

  it('omits agent_id when agentGroupId resolves to no known group', async () => {
    const adapter = createV2Adapter();
    expect(adapter).not.toBeNull();
    if (!adapter) throw new Error('factory returned null');
    await adapter.setup(makeNoopSetup());
    registerDevice('ios-app:default');

    await adapter.deliver('ios-app:default', 'thread-x', {
      kind: 'chat',
      content: { text: 'orphan reply' },
      agentGroupId: 'ag-does-not-exist',
    });

    const transportDb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
    const queue = new OutboundQueue(transportDb);
    const rows = queue.list('ios-app:default');
    expect(rows).toHaveLength(1);
    const payload = JSON.parse(rows[0].payload_json);
    expect(payload.agent_id).toBeUndefined();
    transportDb.raw.close();

    await adapter.teardown();
  });
});
