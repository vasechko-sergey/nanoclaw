// Task 2 (B1) — outbound `ask_question` content is rendered as a v2
// data:message envelope whose id == questionId and whose payload.actions[]
// are the options mapped to buttons. The envelope id == questionId so the
// device's action_response.action_id maps straight back to the pending
// question via the existing onAction router. A normal message carries NO
// actions.
//
// Mirrors agent-routing.test.ts: build the real adapter via createV2Adapter(),
// call adapter.deliver(...), then pull the enqueued row back out of the
// transport DB to inspect the payload sendEnvelopeToDevice produced.
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

import { initTestDb, closeDb } from '../../../db/index.js';
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

function readOnlyEnqueued(platformId: string): Record<string, unknown> {
  const transportDb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
  const queue = new OutboundQueue(transportDb);
  const rows = queue.list(platformId);
  expect(rows).toHaveLength(1);
  const env = {
    id: rows[0].id,
    type: rows[0].type,
    payload: JSON.parse(rows[0].payload_json) as Record<string, unknown>,
  };
  transportDb.raw.close();
  return env;
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
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'nanoclaw-ios-inline-actions-'));
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

describe('ios-app v2 adapter — ask_question outbound renders actions[] (Task 2)', () => {
  it('renders ask_question as a message envelope: id == questionId, options → actions[]', async () => {
    const adapter = createV2Adapter();
    expect(adapter).not.toBeNull();
    if (!adapter) throw new Error('factory returned null');
    await adapter.setup(makeNoopSetup());
    registerDevice('ios-app:default');

    await adapter.deliver('ios-app:default', 'thread-x', {
      kind: 'chat',
      content: {
        type: 'ask_question',
        questionId: 'q-1',
        title: 'T',
        question: 'Pick',
        options: [
          { label: 'Yes', selectedLabel: 'Yes', value: 'yes' },
          { label: 'No', selectedLabel: 'No', value: 'no' },
        ],
      },
    });

    const env = readOnlyEnqueued('ios-app:default');
    expect(env.id).toBe('q-1');
    expect(env.type).toBe('message');
    const payload = env.payload as { text: string; actions: unknown };
    expect(payload.text).toContain('Pick');
    expect(payload.actions).toEqual([
      { id: 'yes', label: 'Yes', style: 'primary' },
      { id: 'no', label: 'No', style: 'primary' },
    ]);

    await adapter.teardown();
  });

  it('a normal message carries no actions', async () => {
    const adapter = createV2Adapter();
    expect(adapter).not.toBeNull();
    if (!adapter) throw new Error('factory returned null');
    await adapter.setup(makeNoopSetup());
    registerDevice('ios-app:default');

    await adapter.deliver('ios-app:default', 'thread-x', {
      kind: 'chat',
      content: { text: 'hi' },
    });

    const env = readOnlyEnqueued('ios-app:default');
    const payload = env.payload as { actions?: unknown };
    expect(payload.actions).toBeUndefined();

    await adapter.teardown();
  });

  it('ask_question with empty options omits actions[] (never emits [])', async () => {
    // The wire schema is actions[].min(1).optional() — a present-but-empty
    // array fails device-side validation. With no options the field must be
    // absent (undefined), NOT an empty array.
    const adapter = createV2Adapter();
    expect(adapter).not.toBeNull();
    if (!adapter) throw new Error('factory returned null');
    await adapter.setup(makeNoopSetup());
    registerDevice('ios-app:default');

    await adapter.deliver('ios-app:default', 'thread-x', {
      kind: 'chat',
      content: {
        type: 'ask_question',
        questionId: 'q-empty',
        title: 'T',
        question: 'No options',
        options: [],
      },
    });

    const env = readOnlyEnqueued('ios-app:default');
    expect(env.id).toBe('q-empty');
    expect(env.type).toBe('message');
    const payload = env.payload as { text: string; actions?: unknown };
    expect(payload.text).toContain('No options');
    expect(payload.actions).toBeUndefined();

    await adapter.teardown();
  });
});
