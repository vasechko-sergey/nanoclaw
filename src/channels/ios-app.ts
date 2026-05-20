import http from 'node:http';
import http2 from 'node:http2';
import { createSign, randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { readEnvFile } from '../env.js';
import { registerChannelAdapter } from './channel-registry.js';
import type { ChannelAdapter, ChannelSetup } from './adapter.js';

// APNs JWT — reused for 55 min then refreshed
let apnsJwt: { token: string; createdAt: number } | null = null;

interface ApnsConfig {
  keyId: string;
  teamId: string;
  key: string;
  bundleId: string;
}

function getApnsJwt(cfg: ApnsConfig): string {
  const now = Math.floor(Date.now() / 1000);
  if (apnsJwt && now - apnsJwt.createdAt < 55 * 60) return apnsJwt.token;

  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: cfg.keyId })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ iss: cfg.teamId, iat: now })).toString('base64url');
  const sign = createSign('SHA256');
  sign.update(`${header}.${payload}`);
  const sig = sign.sign(cfg.key, 'base64url');
  apnsJwt = { token: `${header}.${payload}.${sig}`, createdAt: now };
  return apnsJwt.token;
}

async function sendApnsPush(deviceToken: string, text: string, apns: ApnsConfig | null): Promise<void> {
  if (!apns) return;
  const jwt = getApnsJwt(apns);
  const bundleId = apns.bundleId;

  const body = JSON.stringify({ aps: { alert: { body: text }, sound: 'default' } });

  await new Promise<void>((resolve, reject) => {
    const client = http2.connect('https://api.push.apple.com');
    client.on('error', reject);
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      ':scheme': 'https',
      ':authority': 'api.push.apple.com',
      authorization: `bearer ${jwt}`,
      'apns-topic': bundleId,
      'apns-push-type': 'alert',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
    });
    req.setEncoding('utf8');
    let status = 0;
    req.on('response', (h) => {
      status = h[':status'] as number;
    });
    req.on('data', () => {});
    req.on('end', () => {
      client.close();
      status === 200 ? resolve() : reject(new Error(`APNs ${status}`));
    });
    req.end(body);
  });
}

function createIOSAdapter(): ChannelAdapter | null {
  const env = readEnvFile([
    'IOS_APP_TOKEN',
    'IOS_APP_PORT',
    'IOS_APNS_KEY_ID',
    'IOS_APNS_TEAM_ID',
    'IOS_APNS_BUNDLE_ID',
    'IOS_APNS_KEY',
  ]);
  const token = env.IOS_APP_TOKEN;
  if (!token) return null;
  const port = parseInt(env.IOS_APP_PORT ?? '3001', 10);

  const apnsCfg: ApnsConfig | null =
    env.IOS_APNS_KEY_ID && env.IOS_APNS_TEAM_ID && env.IOS_APNS_KEY && env.IOS_APNS_BUNDLE_ID
      ? {
          keyId: env.IOS_APNS_KEY_ID,
          teamId: env.IOS_APNS_TEAM_ID,
          key: env.IOS_APNS_KEY,
          bundleId: env.IOS_APNS_BUNDLE_ID,
        }
      : null;

  const wsClients = new Map<string, Set<WebSocket>>();
  const apnsTokens = new Map<string, string>(); // platformId → APNs device token
  let cfg: ChannelSetup | null = null;
  let httpServer: http.Server | null = null;
  let wss: WebSocketServer | null = null;

  function removeClient(pid: string, ws: WebSocket) {
    const s = wsClients.get(pid);
    if (!s) return;
    s.delete(ws);
    if (s.size === 0) wsClients.delete(pid);
  }

  return {
    name: 'ios-app',
    channelType: 'ios-app',
    supportsThreads: false,

    async setup(config: ChannelSetup) {
      cfg = config;

      httpServer = http.createServer((req, res) => {
        if (req.method === 'GET' && req.url === '/ios/health')
          res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
        else res.writeHead(404).end();
      });

      wss = new WebSocketServer({ server: httpServer });

      wss.on('connection', (ws) => {
        let pid: string | null = null;
        let authed = false;
        const ping = setInterval(() => {
          if (ws.readyState === WebSocket.OPEN) ws.ping();
        }, 30_000);

        ws.on('message', async (data) => {
          let msg: Record<string, unknown>;
          try {
            msg = JSON.parse(data.toString());
          } catch {
            ws.close(1003);
            return;
          }

          if (!authed) {
            if (msg.type === 'auth' && msg.token === token && typeof msg.platformId === 'string') {
              authed = true;
              pid = msg.platformId;
              if (!wsClients.has(pid)) wsClients.set(pid, new Set());
              wsClients.get(pid)!.add(ws);
              if (typeof msg.apnsToken === 'string' && msg.apnsToken) apnsTokens.set(pid, msg.apnsToken);
              ws.send(JSON.stringify({ type: 'auth_ok' }));
            } else {
              ws.close(4001);
            }
            return;
          }

          if (msg.type === 'apns_token' && typeof msg.token === 'string' && pid) apnsTokens.set(pid, msg.token);

          if (msg.type === 'message' && typeof msg.text === 'string' && pid) {
            const ctx = msg.context as Record<string, unknown> | undefined;
            const fullText = ctx ? buildCtx(ctx) + msg.text : msg.text;
            await cfg!.onInbound(pid, null, {
              id: randomUUID(),
              kind: 'chat',
              content: { text: fullText, senderId: pid },
              timestamp: new Date().toISOString(),
            });
          }
        });

        ws.on('close', () => {
          clearInterval(ping);
          if (pid) removeClient(pid, ws);
        });
        ws.on('error', () => {
          clearInterval(ping);
          if (pid) removeClient(pid, ws);
        });
      });

      await new Promise<void>((ok, fail) => httpServer!.listen(port, '0.0.0.0', ok).on('error', fail));
    },

    async teardown() {
      wss?.close();
      await new Promise<void>((r) => httpServer?.close(() => r()));
    },

    isConnected() {
      return httpServer?.listening ?? false;
    },

    async deliver(platformId, _tid, message) {
      const c = message.content as Record<string, unknown>;
      const text = (c.markdown ?? c.text ?? '') as string;
      const files = message.files ?? [];

      if (!text && files.length === 0) return undefined;

      const id = randomUUID();
      const ts = new Date().toISOString();
      const set = wsClients.get(platformId);

      const sendTo = (ws: WebSocket) => {
        if (ws.readyState !== WebSocket.OPEN) return;
        if (text) ws.send(JSON.stringify({ type: 'message', id, text, timestamp: ts }));
        for (const file of files) {
          ws.send(
            JSON.stringify({
              type: 'image',
              id: randomUUID(),
              data: file.data.toString('base64'),
              filename: file.filename,
              timestamp: ts,
            }),
          );
        }
      };

      if (set && set.size > 0) {
        set.forEach(sendTo);
      } else {
        const apnsToken = apnsTokens.get(platformId);
        const preview = text || files[0]?.filename || 'Новое сообщение';
        if (apnsToken) sendApnsPush(apnsToken, preview, apnsCfg).catch(() => {});
      }
      return id;
    },
  };
}

function buildCtx(ctx: Record<string, unknown>): string {
  const lines: string[] = [];
  if (ctx.location) {
    const l = ctx.location as Record<string, unknown>;
    lines.push(`📍 ${l.city ?? ''} (${l.lat}, ${l.lon})`);
  }
  if (ctx.health) {
    const h = ctx.health as Record<string, unknown>;
    const p: string[] = [];
    if (h.steps) p.push(`Steps: ${h.steps}`);
    if (h.heartRate) p.push(`HR: ${h.heartRate} bpm`);
    if (h.activeEnergy) p.push(`Active: ${h.activeEnergy} kcal`);
    if (p.length) lines.push(`🏃 ${p.join(' | ')}`);
  }
  if (Array.isArray(ctx.custom) && ctx.custom.length) lines.push(`📝 ${(ctx.custom as string[]).join('; ')}`);
  if (!lines.length) return '';
  const ts = new Date().toLocaleString('ru-RU', { timeZone: 'Europe/Moscow' });
  return `[iOS Context — ${ts}]\n${lines.join('\n')}\n---\n`;
}

registerChannelAdapter('ios-app', { factory: createIOSAdapter });
