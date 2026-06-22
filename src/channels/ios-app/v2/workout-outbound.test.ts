// Task 3 — the ios-app-v2 adapter validates an outbound workout_plan's
// plan_json against the canonical PlanJsonSchema and, on mismatch, WARNS
// loudly but FORWARDS anyway. Validation must never block delivery, so a
// future schema drift surfaces in VDS logs instead of silently dying on iOS.
//
// This mirrors agent-routing.test.ts: build the real adapter via
// createV2Adapter(), seed a resolvable ios-app-v2 session so the workout
// outbound branch reaches WorkoutBridge, call deliver(), and read the
// enqueued envelope back via OutboundQueue.list() (it enqueues even with no
// live socket). Both off-canon and canonical plans must produce a
// workout_plan envelope on the queue.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'fs';
import path from 'path';
import os from 'os';
import net from 'node:net';
import { randomUUID } from 'node:crypto';

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
import { createMessagingGroup } from '../../../db/messaging-groups.js';
import { createSession } from '../../../db/sessions.js';
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
 * UPDATE…RETURNING it. The adapter normally upserts this on auth; here we go
 * straight to deliver() so we seed it ourselves.
 */
function registerDevice(platformId: string): void {
  const tdb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
  tdb.upsertDevice(platformId, { capabilities: [] });
  tdb.raw.close();
}

function nowIso(): string {
  return new Date().toISOString();
}

/**
 * Seed an agent group + an ios-app-v2 messaging group + an active session so
 * BOTH resolveSessionForPlatform(platformId) and resolvePlatformForSession()
 * succeed — that's what the workout outbound branch (and the WorkoutBridge it
 * delegates to) need in order to reach the enqueue.
 */
function seedResolvableSession(platformId: string): void {
  createAgentGroup({
    id: 'ag-payne',
    name: 'Payne',
    folder: 'payne',
    agent_provider: null,
    created_at: nowIso(),
  });
  const mgId = `mg-${randomUUID()}`;
  createMessagingGroup({
    id: mgId,
    channel_type: 'ios-app-v2',
    platform_id: platformId,
    name: 'iOS device',
    is_group: 0,
    unknown_sender_policy: 'strict',
    created_at: nowIso(),
  });
  createSession({
    id: `sess-${randomUUID()}`,
    agent_group_id: 'ag-payne',
    messaging_group_id: mgId,
    thread_id: null,
    owner_key: null,
    agent_provider: null,
    status: 'active',
    container_status: 'running',
    last_active: nowIso(),
    created_at: nowIso(),
  });
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
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'nanoclaw-ios-workout-outbound-'));
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

describe('ios-app-v2 workout_plan outbound validation', () => {
  it('forwards an off-canon workout_plan (warn, not block)', async () => {
    const platformId = 'ios-app:default';
    seedResolvableSession(platformId);

    const adapter = createV2Adapter();
    expect(adapter).not.toBeNull();
    if (!adapter) throw new Error('factory returned null');
    await adapter.setup(makeNoopSetup());
    registerDevice(platformId);

    // plan_json is OFF-canon: missing required `week` / `week_label`.
    await adapter.deliver(platformId, 'thread-x', {
      kind: 'chat',
      content: {
        type: 'workout_plan',
        plan_json: {
          day_name: 'X',
          exercises: [{ slug: 'a', target_sets: 3, target_reps: '8', reps_in_reserve: 2, rest_seconds: 90 }],
        },
        payload: {
          workout_id: 'w1',
          plan_json: {
            day_name: 'X',
            exercises: [{ slug: 'a', target_sets: 3, target_reps: '8', reps_in_reserve: 2, rest_seconds: 90 }],
          },
          image_manifest: [],
        },
      },
    });

    const transportDb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
    const queue = new OutboundQueue(transportDb);
    const rows = queue.list(platformId);
    // Validation WARNED but did not block: the workout_plan envelope is queued.
    expect(rows.some((r) => r.type === 'workout_plan')).toBe(true);
    transportDb.raw.close();

    await adapter.teardown();
  });

  it('forwards a canonical workout_plan', async () => {
    const platformId = 'ios-app:default';
    seedResolvableSession(platformId);

    const adapter = createV2Adapter();
    expect(adapter).not.toBeNull();
    if (!adapter) throw new Error('factory returned null');
    await adapter.setup(makeNoopSetup());
    registerDevice(platformId);

    const canonicalPlan = {
      day_name: 'Push A',
      week: 1,
      week_label: 'Week 1',
      exercises: [{ slug: 'bench', target_sets: 3, target_reps: '8', reps_in_reserve: 2, rest_seconds: 120 }],
    };

    await adapter.deliver(platformId, 'thread-x', {
      kind: 'chat',
      content: {
        type: 'workout_plan',
        plan_json: canonicalPlan,
        payload: {
          workout_id: 'w2',
          plan_json: canonicalPlan,
          image_manifest: [],
        },
      },
    });

    const transportDb = openTransportDb(mockEnv.IOS_APP_V2_DB_PATH!);
    const queue = new OutboundQueue(transportDb);
    const rows = queue.list(platformId);
    expect(rows.some((r) => r.type === 'workout_plan')).toBe(true);
    transportDb.raw.close();

    await adapter.teardown();
  });
});
