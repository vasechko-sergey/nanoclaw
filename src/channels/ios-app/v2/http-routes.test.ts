// Unit tests for the v2 ios-app legacy-route HTTP handler.
//
// We mount the bare `createIosHttpHandler` factory on a stub `http.Server`
// bound to port 0 — no ws server, no env vars, no real DB. The handler is
// the same one `setup()` wires into the live adapter, so coverage here is
// representative of production behavior.
//
// Identity for every protected route comes from the bearer token via the
// `resolveToken` stub — `tok-p2` resolves to person `p2`, everything else is
// unknown (→ 401). Health uploads and /ios/state then resolve to that
// person's user-memory tree under the real DATA_DIR (repo `data/`), so the
// tests assert against `data/user-memory/p2/...` and clean it up in afterEach.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { DATA_DIR } from '../../../config.js';
import { userMemoryRoot, userGlobalRoot } from '../../../user-memory.js';
import { openTransportDb } from './transport-db.js';
import { HealthRequestsStore } from './health-requests-store.js';
import { OutboundQueue } from './outbound-queue.js';
import { createIosHttpHandler } from './http-handler.js';
import { openHealthDb, readHealthDays } from './health-db.js';
import type { ChannelSetup } from '../../adapter.js';

interface Harness {
  url: string;
  store: HealthRequestsStore;
  queue: OutboundQueue;
  inboundCalls: Array<{ pid: string; tid: string | null; msg: Record<string, unknown> }>;
  cfg: { current: ChannelSetup | null };
  close: () => Promise<void>;
}

// Bearer token → identity. Only `tok-p2` is known (person `p2`); anything
// else resolves to null (→ 401). Identity NEVER comes from body.platformId.
const TOKEN = 'tok-p2';
const PERSON = 'p2';
const PLATFORM_ID = 'ios-app-v2:p2';
const HEALTH_AGENT = 'greg';

async function bootHarness(): Promise<Harness> {
  const db = openTransportDb(':memory:');
  const store = new HealthRequestsStore(db);
  const queue = new OutboundQueue(db);
  // Register the test devices so enqueue can allocate seq numbers.
  db.upsertDevice(PLATFORM_ID, {});
  db.upsertDevice('ios-app-v2:someone-else', {});
  const inboundCalls: Harness['inboundCalls'] = [];
  const cfg: { current: ChannelSetup | null } = {
    current: {
      onInbound: async (pid: string, tid: string | null, msg: unknown) => {
        inboundCalls.push({ pid, tid, msg: msg as Record<string, unknown> });
      },
      onAction: () => {},
    } as unknown as ChannelSetup,
  };

  const handler = createIosHttpHandler({
    resolveToken: (raw) => (raw === TOKEN ? { platform_id: PLATFORM_ID, person_key: PERSON } : null),
    healthRequestsStore: store,
    healthAgentFolder: HEALTH_AGENT,
    getChannelSetup: () => cfg.current,
    listPending: (pid, since) => queue.listPendingNotify(pid, since),
    log: () => {},
    logWarn: () => {},
  });

  const server = http.createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    url: `http://127.0.0.1:${port}`,
    store,
    queue,
    inboundCalls,
    cfg,
    async close() {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      db.raw.close();
    },
  };
}

interface FetchResult {
  status: number;
  body: string;
  json: () => unknown;
}

function fetchJson(
  url: string,
  init: { method: string; headers?: Record<string, string>; body?: string } = { method: 'GET' },
): Promise<FetchResult> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = http.request(
      {
        method: init.method,
        hostname: u.hostname,
        port: u.port,
        path: u.pathname + u.search,
        headers: init.headers ?? {},
      },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (raw += c));
        res.on('end', () =>
          resolve({
            status: res.statusCode ?? 0,
            body: raw,
            json: () => JSON.parse(raw),
          }),
        );
      },
    );
    req.on('error', reject);
    if (init.body) req.write(init.body);
    req.end();
  });
}

const personRoot = join(DATA_DIR, 'user-memory', PERSON);

let h: Harness;
beforeEach(async () => {
  // Per-person paths are rooted at the real DATA_DIR (repo data/). Scrub the
  // person subtree both before and after so a crashed prior run can't leak
  // stale rows into this one, and so we never leave residue in the repo.
  rmSync(personRoot, { recursive: true, force: true });
  h = await bootHarness();
});
afterEach(async () => {
  await h.close();
  rmSync(personRoot, { recursive: true, force: true });
});

describe('GET /ios/health', () => {
  it('returns 200 ok without auth', async () => {
    const r = await fetchJson(`${h.url}/ios/health`, { method: 'GET' });
    expect(r.status).toBe(200);
    expect(r.json()).toEqual({ ok: true });
  });
});

describe('Bearer auth gate', () => {
  it('returns 401 when token is missing on protected routes', async () => {
    const r = await fetchJson(`${h.url}/ios/health/requests`, { method: 'GET' });
    expect(r.status).toBe(401);
    expect((r.json() as { error: string }).error).toBe('unauthorized');
  });

  it('returns 401 when token is unknown', async () => {
    const r = await fetchJson(`${h.url}/ios/health/requests`, {
      method: 'GET',
      headers: { Authorization: 'Bearer nope' },
    });
    expect(r.status).toBe(401);
  });

  it('returns 401 on a malformed (non-Bearer) Authorization header', async () => {
    const r = await fetchJson(`${h.url}/ios/state`, {
      method: 'GET',
      headers: { Authorization: TOKEN },
    });
    expect(r.status).toBe(401);
  });
});

describe('GET /ios/health/requests', () => {
  it('returns empty list initially for the token-derived device', async () => {
    const r = await fetchJson(`${h.url}/ios/health/requests`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    expect(r.json()).toEqual([]);
  });

  it('scopes entries to the device derived from the token, ignoring any query param', async () => {
    h.store.enqueue(PLATFORM_ID, 'req-a', 7);
    h.store.enqueue(PLATFORM_ID, 'req-b', 14);
    h.store.enqueue('ios-app-v2:someone-else', 'req-c', 30); // different device

    // Even with a misleading ?platformId= for another device, the token's
    // platform_id is authoritative — we still get p2's two rows.
    const r = await fetchJson(`${h.url}/ios/health/requests?platformId=ios-app-v2:someone-else`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    const rows = r.json() as Array<{ requestId: string; days: number }>;
    expect(rows).toHaveLength(2);
    expect(rows.map((x) => x.requestId).sort()).toEqual(['req-a', 'req-b']);
    expect(rows.find((x) => x.requestId === 'req-a')?.days).toBe(7);
  });
});

describe('POST /ios/health/upload', () => {
  it("writes rows into the token-person's health agent health.db and clears the request", async () => {
    h.store.enqueue(PLATFORM_ID, 'req-1', 3);

    // body.platformId is deliberately a DIFFERENT id than the token's — it
    // must be ignored for routing (token identity wins).
    const body = JSON.stringify({
      platformId: 'ios-app-v2:client-local-id',
      requestId: 'req-1',
      days: [
        { date: '2026-05-29', steps: 8000 },
        { date: '2026-05-30', steps: 9500, restingHeartRate: 58 },
      ],
    });
    const r = await fetchJson(`${h.url}/ios/health/upload`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body,
    });
    expect(r.status).toBe(200);
    expect(r.json()).toEqual({ ok: true });

    // Rows land under data/user-memory/p2/greg/health/health.db, oldest→newest.
    const dbPath = join(userMemoryRoot(PERSON, HEALTH_AGENT), 'health', 'health.db');
    expect(dbPath).toBe(join(DATA_DIR, 'user-memory', PERSON, HEALTH_AGENT, 'health', 'health.db'));
    const db = openHealthDb(dbPath);
    const rows = readHealthDays(db);
    db.close();
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatchObject({ date: '2026-05-29', steps: 8000 });
    expect(rows[1]).toMatchObject({ date: '2026-05-30', steps: 9500, restingHeartRate: 58 });

    // Request cleared.
    expect(h.store.listForDevice(PLATFORM_ID)).toHaveLength(0);
  });

  it('accepts an upload with no body platformId (routing is by token)', async () => {
    const body = JSON.stringify({
      days: [{ date: '2026-06-02', steps: 4321 }],
    });
    const r = await fetchJson(`${h.url}/ios/health/upload`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body,
    });
    expect(r.status).toBe(200);

    const dbPath = join(userMemoryRoot(PERSON, HEALTH_AGENT), 'health', 'health.db');
    const db = openHealthDb(dbPath);
    const rows = readHealthDays(db);
    db.close();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ date: '2026-06-02', steps: 4321 });
  });

  it('returns 401 for an unknown bearer token', async () => {
    const body = JSON.stringify({ days: [{ date: '2026-05-30', steps: 1 }] });
    const r = await fetchJson(`${h.url}/ios/health/upload`, {
      method: 'POST',
      headers: { Authorization: 'Bearer nope', 'Content-Type': 'application/json' },
      body,
    });
    expect(r.status).toBe(401);
  });

  it('returns 400 on an invalid body', async () => {
    const r = await fetchJson(`${h.url}/ios/health/upload`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ days: 'not-an-array' }),
    });
    expect(r.status).toBe(400);
  });
});

describe('POST /ios/proactive', () => {
  it('feeds an inbound message with the proactive marker (routing by token, no body platformId needed)', async () => {
    const body = JSON.stringify({
      trigger: 'geofence',
      ts: '2026-05-31T10:00:00Z',
      tz: 'Europe/Berlin',
      payload: { region: 'home' },
    });
    const r = await fetchJson(`${h.url}/ios/proactive`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body,
    });
    expect(r.status).toBe(200);
    expect(r.json()).toEqual({ ok: true });

    expect(h.inboundCalls).toHaveLength(1);
    const call = h.inboundCalls[0];
    expect(call.pid).toBe(PLATFORM_ID);
    expect(call.tid).toBeNull();
    const content = call.msg.content as { text: string; senderId: string };
    expect(content.senderId).toBe(PLATFORM_ID);
    expect(content.text).toContain('[proactive trigger=geofence ts=2026-05-31T10:00:00Z tz=Europe/Berlin]');
    expect(content.text).toContain('region=home');
  });

  it('routes by the bearer token, ignoring a body platformId for another person (no cross-person injection)', async () => {
    // p2 (the authenticated caller) tries to spoof the owner's session by
    // putting the victim's platform id in the body. The handler must route to
    // p2's own platform id — both as the onInbound target AND as senderId —
    // so resolvePersonKey downstream resolves p2, never the victim.
    const body = JSON.stringify({
      platformId: 'ios-app-v2:default', // victim/owner — must be ignored
      trigger: 'geofence',
      text: 'pretend this came from the owner',
    });
    const r = await fetchJson(`${h.url}/ios/proactive`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body,
    });
    expect(r.status).toBe(200);

    expect(h.inboundCalls).toHaveLength(1);
    const call = h.inboundCalls[0];
    // The TOKEN's platform id — NOT the spoofed body.platformId. If someone
    // reverted to body-routing this would be 'ios-app-v2:default' and fail.
    expect(call.pid).toBe(PLATFORM_ID);
    expect(call.pid).not.toBe('ios-app-v2:default');
    const content = call.msg.content as { senderId: string };
    expect(content.senderId).toBe(PLATFORM_ID);
    expect(content.senderId).not.toBe('ios-app-v2:default');
  });

  it('returns 401 for an unknown bearer token', async () => {
    const r = await fetchJson(`${h.url}/ios/proactive`, {
      method: 'POST',
      headers: { Authorization: 'Bearer nope', 'Content-Type': 'application/json' },
      body: JSON.stringify({ trigger: 'hk' }),
    });
    expect(r.status).toBe(401);
  });

  it('returns 400 when trigger is missing', async () => {
    const r = await fetchJson(`${h.url}/ios/proactive`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });
    expect(r.status).toBe(400);
  });

  it('returns 503 when the adapter has no ChannelSetup yet', async () => {
    h.cfg.current = null;
    const r = await fetchJson(`${h.url}/ios/proactive`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ trigger: 'hk' }),
    });
    expect(r.status).toBe(503);
  });
});

describe('GET /ios/state', () => {
  it("reads the token-person's profiles and returns levels + ordered agent rows", async () => {
    const profilesDir = join(userGlobalRoot(PERSON), 'profiles');
    mkdirSync(profilesDir, { recursive: true });
    writeFileSync(
      join(profilesDir, 'greg.md'),
      `---\nupdated: 2026-06-13\nsummary: Всё ок\nlevels: {energy: 72, stress: 34, recovery: 81, readiness: 68}\n---\nDetail text.`,
    );
    writeFileSync(join(profilesDir, 'gordon.md'), `---\nsummary: Рекомп идёт хорошо\n---\nGordon detail.`);

    const r = await fetchJson(`${h.url}/ios/state`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    const body = r.json() as { levels: Record<string, unknown>; agents: Array<{ key: string; summary: string }> };
    expect(body.levels.energy).toBe(72);
    expect(body.agents[0].key).toBe('greg');
    expect(body.agents.find((a) => a.key === 'gordon')?.summary).toContain('Рекомп');
  });

  it('requires bearer auth', async () => {
    const r = await fetchJson(`${h.url}/ios/state`, { method: 'GET' });
    expect(r.status).toBe(401);
  });

  it('orders agents by picker order and passes through metrics + action', async () => {
    const profilesDir = join(userGlobalRoot(PERSON), 'profiles');
    mkdirSync(profilesDir, { recursive: true });
    writeFileSync(
      join(profilesDir, 'greg.md'),
      `---\nupdated: 2026-06-13\nsummary: ok\naction: Лёгкий день\nmetrics: [{"v":"68","l":"готовность","t":"warn"},{"v":"6.2ч","l":"сон"}]\n---\nbody`,
    );
    writeFileSync(
      join(profilesDir, 'jarvis.md'),
      `---\nupdated: 2026-06-13\nsummary: focus\naction: 10:00 встреча\nmetrics: [{"v":"2","l":"события"}]\n---\nbody`,
    );

    const r = await fetchJson(`${h.url}/ios/state`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    const body = r.json() as {
      agents: Array<{ key: string; action?: string; metrics?: Array<{ v: string; l: string; t?: string }> }>;
    };
    expect(body.agents[0].key).toBe('jarvis');
    const greg = body.agents.find((a) => a.key === 'greg')!;
    expect(greg.action).toBe('Лёгкий день');
    expect(greg.metrics).toEqual([
      { v: '68', l: 'готовность', t: 'warn' },
      { v: '6.2ч', l: 'сон' },
    ]);
  });
});

describe('GET /ios/pending', () => {
  it('returns notification-worthy messages for the token device, parsed, oldest first', async () => {
    h.queue.enqueue(PLATFORM_ID, {
      id: 'm1',
      kind: 'data',
      type: 'message',
      payload: { text: 'hello', agent_id: 'jarvis' },
    });
    h.queue.enqueue(PLATFORM_ID, { id: 'w1', kind: 'data', type: 'workout_plan', payload: { x: 1 } });
    h.queue.enqueue(PLATFORM_ID, {
      id: 'm2',
      kind: 'data',
      type: 'message',
      payload: { text: 'second', agent_id: 'greg' },
    });
    h.queue.enqueue('ios-app-v2:someone-else', { id: 'mX', kind: 'data', type: 'message', payload: { text: 'leak' } });

    const r = await fetchJson(`${h.url}/ios/pending`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    const body = r.json() as { messages: Array<{ id: string; seq: number; agent_id: string | null; text: string }> };
    expect(body.messages.map((m) => m.id)).toEqual(['m1', 'm2']);
    expect(body.messages[0]).toMatchObject({ id: 'm1', agent_id: 'jarvis', text: 'hello' });
    expect(body.messages[1]).toMatchObject({ id: 'm2', agent_id: 'greg', text: 'second' });

    // The queue is NOT consumed by the pull.
    expect(h.queue.list(PLATFORM_ID)).toHaveLength(3);
  });

  it('honors ?since= and requires auth', async () => {
    const s1 = h.queue.enqueue(PLATFORM_ID, { id: 'm1', kind: 'data', type: 'message', payload: { text: 'a' } });
    h.queue.enqueue(PLATFORM_ID, { id: 'm2', kind: 'data', type: 'message', payload: { text: 'b' } });

    const r = await fetchJson(`${h.url}/ios/pending?since=${s1}`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    expect((r.json() as { messages: Array<{ id: string }> }).messages.map((m) => m.id)).toEqual(['m2']);

    const noAuth = await fetchJson(`${h.url}/ios/pending`, { method: 'GET' });
    expect(noAuth.status).toBe(401);
  });
});

describe('unknown routes', () => {
  it('returns 404 for unmatched paths', async () => {
    const r = await fetchJson(`${h.url}/ios/whatever`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(404);
  });
});
