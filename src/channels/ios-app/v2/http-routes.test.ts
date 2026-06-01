// Unit tests for the v2 ios-app legacy-route HTTP handler.
//
// We mount the bare `createIosHttpHandler` factory on a stub `http.Server`
// bound to port 0 — no ws server, no env vars, no real DB. The handler is
// the same one `setup()` wires into the live adapter, so coverage here is
// representative of production behavior.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { openTransportDb } from './transport-db.js';
import { HealthRequestsStore } from './health-requests-store.js';
import { createIosHttpHandler } from './http-handler.js';
import type { ChannelSetup } from '../../adapter.js';

interface Harness {
  url: string;
  store: HealthRequestsStore;
  groupsDir: string;
  inboundCalls: Array<{ pid: string; tid: string | null; msg: Record<string, unknown> }>;
  cfg: { current: ChannelSetup | null };
  close: () => Promise<void>;
}

const TOKEN = 'test-token';

async function bootHarness(
  opts: {
    resolveAgentFolderForPlatform?: (pid: string) => string | null;
    healthOverrideDir?: string | null;
  } = {},
): Promise<Harness> {
  const db = openTransportDb(':memory:');
  const store = new HealthRequestsStore(db);
  const groupsDir = mkdtempSync(join(tmpdir(), 'ios-app-v2-routes-'));
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
    token: TOKEN,
    healthRequestsStore: store,
    resolveAgentFolderForPlatform:
      opts.resolveAgentFolderForPlatform ?? ((pid) => (pid === 'ios-app-v2:dev-1' ? 'jarvis' : null)),
    groupsDir,
    healthOverrideDir: opts.healthOverrideDir ?? null,
    getChannelSetup: () => cfg.current,
    log: () => {},
    logWarn: () => {},
  });

  const server = http.createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    url: `http://127.0.0.1:${port}`,
    store,
    groupsDir,
    inboundCalls,
    cfg,
    async close() {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      db.raw.close();
      rmSync(groupsDir, { recursive: true, force: true });
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

let h: Harness;
beforeEach(async () => {
  h = await bootHarness();
});
afterEach(async () => {
  await h.close();
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
    const r = await fetchJson(`${h.url}/ios/health/requests?platformId=ios-app-v2:dev-1`, {
      method: 'GET',
    });
    expect(r.status).toBe(401);
    expect((r.json() as { error: string }).error).toBe('unauthorized');
  });

  it('returns 401 when token is wrong', async () => {
    const r = await fetchJson(`${h.url}/ios/health/requests?platformId=ios-app-v2:dev-1`, {
      method: 'GET',
      headers: { Authorization: 'Bearer wrong' },
    });
    expect(r.status).toBe(401);
  });
});

describe('GET /ios/health/requests', () => {
  it('returns 400 when platformId is missing', async () => {
    const r = await fetchJson(`${h.url}/ios/health/requests`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(400);
  });

  it('returns empty list initially', async () => {
    const r = await fetchJson(`${h.url}/ios/health/requests?platformId=ios-app-v2:dev-1`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect(r.status).toBe(200);
    expect(r.json()).toEqual([]);
  });

  it('returns enqueued entries scoped to the requesting device', async () => {
    h.store.enqueue('ios-app-v2:dev-1', 'req-a', 7);
    h.store.enqueue('ios-app-v2:dev-1', 'req-b', 14);
    h.store.enqueue('ios-app-v2:dev-2', 'req-c', 30); // different device

    const r = await fetchJson(`${h.url}/ios/health/requests?platformId=ios-app-v2:dev-1`, {
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
  it('appends JSONL rows to the wired agent group folder and clears the request', async () => {
    h.store.enqueue('ios-app-v2:dev-1', 'req-1', 3);

    const body = JSON.stringify({
      platformId: 'ios-app-v2:dev-1',
      requestId: 'req-1',
      days: [
        { date: '2026-05-29', steps: 8000 },
        { date: '2026-05-30', steps: 9500, hr_resting: 58 },
      ],
    });
    const r = await fetchJson(`${h.url}/ios/health/upload`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body,
    });
    expect(r.status).toBe(200);
    expect(r.json()).toEqual({ ok: true });

    // File written under <groupsDir>/jarvis/health/raw.jsonl with one line per day.
    const jsonl = join(h.groupsDir, 'jarvis', 'health', 'raw.jsonl');
    expect(existsSync(jsonl)).toBe(true);
    const lines = readFileSync(jsonl, 'utf8').trim().split('\n');
    expect(lines).toHaveLength(2);
    expect(JSON.parse(lines[0])).toMatchObject({ date: '2026-05-29', steps: 8000 });
    expect(JSON.parse(lines[1])).toMatchObject({ date: '2026-05-30', steps: 9500, hr_resting: 58 });

    // Request cleared.
    expect(h.store.listForDevice('ios-app-v2:dev-1')).toHaveLength(0);
  });

  it('returns 404 when the device has no wired agent group', async () => {
    const body = JSON.stringify({
      platformId: 'ios-app-v2:unknown',
      requestId: 'req-x',
      days: [{ date: '2026-05-30', steps: 1 }],
    });
    const r = await fetchJson(`${h.url}/ios/health/upload`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body,
    });
    expect(r.status).toBe(404);
  });

  it('returns 400 when platformId is missing and no override is configured', async () => {
    const r = await fetchJson(`${h.url}/ios/health/upload`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ days: [] }),
    });
    expect(r.status).toBe(400);
  });

  it('accepts missing platformId when healthOverrideDir is set and writes to the override folder', async () => {
    await h.close();
    const overrideRoot = mkdtempSync(join(tmpdir(), 'ios-app-v2-override-'));
    const overrideDir = join(overrideRoot, 'health-analyzer', 'health');
    h = await bootHarness({ healthOverrideDir: overrideDir });

    const body = JSON.stringify({
      days: [
        { date: '2026-05-31', steps: 1234 },
        { date: '2026-06-01', steps: 5678, hr_resting: 60 },
      ],
    });
    const r = await fetchJson(`${h.url}/ios/health/upload`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body,
    });
    expect(r.status).toBe(200);

    const jsonl = join(overrideDir, 'raw.jsonl');
    expect(existsSync(jsonl)).toBe(true);
    const lines = readFileSync(jsonl, 'utf8').trim().split('\n');
    expect(lines).toHaveLength(2);
    expect(JSON.parse(lines[0])).toMatchObject({ date: '2026-05-31', steps: 1234 });

    rmSync(overrideRoot, { recursive: true, force: true });
  });
});

describe('POST /ios/proactive', () => {
  it('feeds an inbound message with the proactive marker', async () => {
    const body = JSON.stringify({
      platformId: 'ios-app-v2:dev-1',
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
    expect(call.pid).toBe('ios-app-v2:dev-1');
    expect(call.tid).toBeNull();
    const content = call.msg.content as { text: string; senderId: string };
    expect(content.senderId).toBe('ios-app-v2:dev-1');
    expect(content.text).toContain('[proactive trigger=geofence ts=2026-05-31T10:00:00Z tz=Europe/Berlin]');
    expect(content.text).toContain('region=home');
  });

  it('returns 400 when trigger is missing', async () => {
    const r = await fetchJson(`${h.url}/ios/proactive`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ platformId: 'ios-app-v2:dev-1' }),
    });
    expect(r.status).toBe(400);
  });

  it('returns 503 when the adapter has no ChannelSetup yet', async () => {
    h.cfg.current = null;
    const r = await fetchJson(`${h.url}/ios/proactive`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ platformId: 'ios-app-v2:dev-1', trigger: 'hk' }),
    });
    expect(r.status).toBe(503);
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
