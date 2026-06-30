// Unit tests for POST /ios/reply — the lock-screen reply endpoint. Mounts the
// bare createIosHttpHandler on a stub server with a routeReply spy; identity is
// the token's platform_id (tok-p2 → ios-app-v2:p2), never body.platformId.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { createIosHttpHandler } from './http-handler.js';
import type { HealthRequestsStore } from './health-requests-store.js';

const TOKEN = 'tok-p2';
const PLATFORM_ID = 'ios-app-v2:p2';

interface ReplyCall {
  platform_id: string;
  agentId: string;
  text: string;
}

async function boot() {
  const calls: ReplyCall[] = [];
  const handler = createIosHttpHandler({
    resolveToken: (raw) => (raw === TOKEN ? { platform_id: PLATFORM_ID, person_key: 'p2' } : null),
    healthRequestsStore: {} as unknown as HealthRequestsStore,
    healthAgentFolder: 'greg',
    getChannelSetup: () => null,
    listPending: () => [],
    defaultAgentSlug: 'jarvis',
    routeReply: (platform_id, agentId, text) => calls.push({ platform_id, agentId, text }),
    log: () => {},
    logWarn: () => {},
  });
  const server = http.createServer(handler);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}`,
    calls,
    close: () => new Promise<void>((r) => server.close(() => r())),
  };
}

function post(url: string, body: string, token?: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    const req = http.request(
      { method: 'POST', hostname: u.hostname, port: u.port, path: u.pathname, headers },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (raw += c));
        res.on('end', () => resolve({ status: res.statusCode ?? 0, body: raw }));
      },
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

let h: Awaited<ReturnType<typeof boot>>;
beforeEach(async () => {
  h = await boot();
});
afterEach(async () => {
  await h.close();
});

describe('POST /ios/reply', () => {
  it('401 without auth, routeReply not called', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: 'hi' }));
    expect(r.status).toBe(401);
    expect(h.calls).toHaveLength(0);
  });

  it('routes text to the named agent', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: 'hello', agent_id: 'greg' }), TOKEN);
    expect(r.status).toBe(200);
    expect(h.calls).toEqual([{ platform_id: PLATFORM_ID, agentId: 'greg', text: 'hello' }]);
  });

  it('defaults agent_id to jarvis', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: 'hi' }), TOKEN);
    expect(r.status).toBe(200);
    expect(h.calls[0].agentId).toBe('jarvis');
  });

  it('400 on empty text, routeReply not called', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: '   ' }), TOKEN);
    expect(r.status).toBe(400);
    expect(h.calls).toHaveLength(0);
  });

  it('400 on missing text', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ agent_id: 'greg' }), TOKEN);
    expect(r.status).toBe(400);
    expect(h.calls).toHaveLength(0);
  });

  it('400 on over-cap text', async () => {
    const r = await post(`${h.url}/ios/reply`, JSON.stringify({ text: 'x'.repeat(5000) }), TOKEN);
    expect(r.status).toBe(400);
    expect(h.calls).toHaveLength(0);
  });

  it('ignores body.platformId — routes by token identity', async () => {
    const r = await post(
      `${h.url}/ios/reply`,
      JSON.stringify({ text: 'x', platformId: 'ios-app-v2:someone-else' }),
      TOKEN,
    );
    expect(r.status).toBe(200);
    expect(h.calls[0].platform_id).toBe(PLATFORM_ID);
  });
});
