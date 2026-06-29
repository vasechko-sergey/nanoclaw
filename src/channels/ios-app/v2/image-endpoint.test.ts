import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openTransportDb, type TransportDb } from './transport-db.js';
import { HealthRequestsStore } from './health-requests-store.js';
import { ImageCache } from './image-cache.js';
import { createIosHttpHandler } from './http-handler.js';
import type { ChannelSetup } from '../../adapter.js';

const TOKEN = 'tok-img';
const PERSON = 'pi';
const PLATFORM_ID = 'ios-app-v2:pi';

interface RawResult {
  status: number;
  contentType: string | undefined;
  body: Buffer;
}

function fetchRaw(url: string, headers: Record<string, string> = {}): Promise<RawResult> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = http.request(
      { method: 'GET', hostname: u.hostname, port: u.port, path: u.pathname + u.search, headers },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c) => chunks.push(c as Buffer));
        res.on('end', () =>
          resolve({
            status: res.statusCode ?? 0,
            contentType: res.headers['content-type'],
            body: Buffer.concat(chunks),
          }),
        );
      },
    );
    req.on('error', reject);
    req.end();
  });
}

let server: http.Server;
let url: string;
let db: TransportDb;
let cacheDir: string;
let imageCache: ImageCache;

beforeEach(async () => {
  db = openTransportDb(':memory:');
  cacheDir = mkdtempSync(join(tmpdir(), 'ep-img-'));
  imageCache = new ImageCache(cacheDir);
  const handler = createIosHttpHandler({
    resolveToken: (raw) => (raw === TOKEN ? { platform_id: PLATFORM_ID, person_key: PERSON } : null),
    healthRequestsStore: new HealthRequestsStore(db),
    healthAgentFolder: 'greg',
    getChannelSetup: () => null as unknown as ChannelSetup,
    imageCache,
    listPending: () => [],
    log: () => {},
    logWarn: () => {},
  });
  server = http.createServer(handler);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

afterEach(async () => {
  await new Promise<void>((r) => server.close(() => r()));
  db.raw.close();
  rmSync(cacheDir, { recursive: true, force: true });
});

describe('GET /ios/image', () => {
  it('serves cached bytes for a valid authed request', async () => {
    const bytes = Buffer.from('FAKEPNGBYTES');
    imageCache.write('incline-db-press', 'abc123', bytes);
    const r = await fetchRaw(`${url}/ios/image?slug=incline-db-press&sha=abc123`, {
      Authorization: `Bearer ${TOKEN}`,
    });
    expect(r.status).toBe(200);
    expect(r.body.equals(bytes)).toBe(true);
  });

  it('404 when the slug/sha is not cached', async () => {
    const r = await fetchRaw(`${url}/ios/image?slug=nope&sha=zzz`, {
      Authorization: `Bearer ${TOKEN}`,
    });
    expect(r.status).toBe(404);
  });

  it('401 without a valid bearer token', async () => {
    imageCache.write('s', 'h', Buffer.from('x'));
    const r = await fetchRaw(`${url}/ios/image?slug=s&sha=h`, { Authorization: 'Bearer nope' });
    expect(r.status).toBe(401);
  });

  it('400 on a path-traversal slug (never escapes the cache dir)', async () => {
    const r = await fetchRaw(`${url}/ios/image?slug=..%2f..%2fetc%2fpasswd&sha=abc`, {
      Authorization: `Bearer ${TOKEN}`,
    });
    expect(r.status).toBe(400);
  });

  it('400 when slug or sha is missing', async () => {
    const r = await fetchRaw(`${url}/ios/image?slug=s`, { Authorization: `Bearer ${TOKEN}` });
    expect(r.status).toBe(400);
  });
});
