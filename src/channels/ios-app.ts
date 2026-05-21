import fs from 'node:fs';
import http from 'node:http';
import http2 from 'node:http2';
import path from 'node:path';
import { createSign, randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { BOT_COMMANDS } from '../commands.js';
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
  sandbox: boolean;
}

interface QueuedMessage {
  id: string;
  text: string;
  files: Array<{ data: Buffer; filename: string; mimeType?: string; size?: number }>;
  ts: string;
  conversationId?: string;
}

// Persist APNs device tokens across server restarts.
const TOKENS_FILE = path.join(process.cwd(), 'data', 'ios-apns-tokens.json');

function loadPersistedTokens(): Map<string, string> {
  try {
    const raw = fs.readFileSync(TOKENS_FILE, 'utf8');
    return new Map(Object.entries(JSON.parse(raw)));
  } catch {
    return new Map();
  }
}

function savePersistedTokens(tokens: Map<string, string>): void {
  const tmp = `${TOKENS_FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(Object.fromEntries(tokens)));
  fs.renameSync(tmp, TOKENS_FILE);
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
  const host = apns.sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
  const body = JSON.stringify({ aps: { alert: { body: text }, sound: 'default' } });

  await new Promise<void>((resolve, reject) => {
    const client = http2.connect(`https://${host}`);
    client.on('error', reject);
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      ':scheme': 'https',
      ':authority': host,
      authorization: `bearer ${jwt}`,
      'apns-topic': apns.bundleId,
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

function isImageFile(filename: string, mimeType?: string): boolean {
  if (mimeType?.startsWith('image/')) return true;
  return /\.(png|jpe?g|gif|webp|heic|svg|bmp|tiff?)$/i.test(filename);
}

function deliverViaSock(ws: WebSocket, msg: QueuedMessage): void {
  if (ws.readyState !== WebSocket.OPEN) return;
  if (msg.text)
    ws.send(
      JSON.stringify({
        type: 'message',
        id: msg.id,
        text: msg.text,
        conversationId: msg.conversationId,
        timestamp: msg.ts,
      }),
    );
  for (const file of msg.files) {
    if (isImageFile(file.filename, file.mimeType)) {
      // Legacy image type — backwards compatible
      ws.send(
        JSON.stringify({
          type: 'image',
          id: randomUUID(),
          data: file.data.toString('base64'),
          filename: file.filename,
          conversationId: msg.conversationId,
          timestamp: msg.ts,
        }),
      );
    } else {
      // New file type — non-image attachments
      ws.send(
        JSON.stringify({
          type: 'file',
          id: randomUUID(),
          name: file.filename,
          size: file.size ?? file.data.length,
          mimeType: file.mimeType ?? 'application/octet-stream',
          data: file.data.toString('base64'),
          conversationId: msg.conversationId,
          timestamp: msg.ts,
        }),
      );
    }
  }
}

function createIOSAdapter(): ChannelAdapter | null {
  const env = readEnvFile([
    'IOS_APP_TOKEN',
    'IOS_APP_PORT',
    'IOS_APNS_KEY_ID',
    'IOS_APNS_TEAM_ID',
    'IOS_APNS_BUNDLE_ID',
    'IOS_APNS_KEY',
    'IOS_APNS_ENV',
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
          sandbox: env.IOS_APNS_ENV === 'sandbox',
        }
      : null;

  const wsClients = new Map<string, Set<WebSocket>>();
  const apnsTokens = loadPersistedTokens();
  const pendingMessages = new Map<string, QueuedMessage[]>();
  let cfg: ChannelSetup | null = null;
  let httpServer: http.Server | null = null;
  let wss: WebSocketServer | null = null;

  function deliverTextAndFiles(
    platformId: string,
    threadId: string | null,
    text: string,
    files: Array<{ data: Buffer; filename: string; mimeType?: string; size?: number }>,
  ): string {
    const id = randomUUID();
    const ts = new Date().toISOString();
    const queued: QueuedMessage = { id, text, files, ts, conversationId: threadId ?? undefined };

    const set = wsClients.get(platformId);
    if (set && set.size > 0) {
      set.forEach((ws) => deliverViaSock(ws, queued));
    } else {
      pendingMessages.set(platformId, [...(pendingMessages.get(platformId) ?? []), queued]);
      const apnsToken = apnsTokens.get(platformId);
      if (apnsToken) {
        const preview = text ? text.slice(0, 80) : (files[0]?.filename ?? 'Новое сообщение');
        sendApnsPush(apnsToken, preview, apnsCfg).catch(() => {});
      }
    }
    return id;
  }

  function removeClient(pid: string, ws: WebSocket) {
    const s = wsClients.get(pid);
    if (!s) return;
    s.delete(ws);
    if (s.size === 0) wsClients.delete(pid);
  }

  return {
    name: 'ios-app',
    channelType: 'ios-app',
    supportsThreads: true,

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
              if (typeof msg.apnsToken === 'string' && msg.apnsToken) {
                apnsTokens.set(pid, msg.apnsToken);
                savePersistedTokens(apnsTokens);
              }
              ws.send(
                JSON.stringify({
                  type: 'auth_ok',
                  commands: BOT_COMMANDS.map((c) => ({ command: '/' + c.command, description: c.description })),
                }),
              );

              // Flush messages queued while app was closed
              const pending = pendingMessages.get(pid);
              if (pending?.length) {
                for (const p of pending) deliverViaSock(ws, p);
                pendingMessages.delete(pid);
              }
            } else {
              ws.close(4001);
            }
            return;
          }

          if (msg.type === 'apns_token' && typeof msg.token === 'string' && pid) {
            apnsTokens.set(pid, msg.token);
            savePersistedTokens(apnsTokens);
          }

          if (msg.type === 'message' && typeof msg.text === 'string' && pid) {
            const ctx = msg.context as Record<string, unknown> | undefined;
            const fullText = ctx ? buildCtx(ctx) + msg.text : msg.text;
            const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
            await cfg!.onInbound(pid, tid, {
              id: randomUUID(),
              kind: 'chat',
              content: { text: fullText, senderId: pid },
              timestamp: new Date().toISOString(),
            });
          }

          if (msg.type === 'feedback' && pid) {
            const positive = msg.value === true;
            const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
            const rated = typeof msg.messageText === 'string' ? msg.messageText.slice(0, 800) : '';
            const quoted = rated
              ? `\n> ${rated.replace(/\n/g, '\n> ')}`
              : typeof msg.messageId === 'string'
                ? ` (id ${msg.messageId})`
                : '';
            await cfg!.onInbound(pid, tid, {
              id: randomUUID(),
              kind: 'chat',
              content: {
                text: `[user feedback: ${positive ? '👍' : '👎'} on your previous message]${quoted}`,
                senderId: pid,
              },
              timestamp: new Date().toISOString(),
            });
          }

          // Health update — technical, silent unless anomaly detected by agent
          if (msg.type === 'health_update' && pid) {
            const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
            const healthData = msg.data as Record<string, unknown> | undefined;
            const lines: string[] = [];
            if (healthData) {
              if (healthData.steps) lines.push(`Steps: ${healthData.steps}`);
              if (healthData.heartRate) lines.push(`HR: ${healthData.heartRate} bpm`);
              if (healthData.activeEnergy) lines.push(`Active: ${healthData.activeEnergy} kcal`);
              if (healthData.sleepHours) lines.push(`Sleep: ${healthData.sleepHours}h`);
              if (healthData.restingHeartRate) lines.push(`RHR: ${healthData.restingHeartRate} bpm`);
              if (healthData.exerciseMinutes) lines.push(`Exercise: ${healthData.exerciseMinutes} min`);
            }
            if (lines.length) {
              await cfg!.onInbound(pid, tid, {
                id: randomUUID(),
                kind: 'chat',
                content: {
                  text: `[health update — technical, do not respond unless anomaly detected]\n🏃 ${lines.join(' | ')}`,
                  senderId: pid,
                },
                timestamp: new Date().toISOString(),
              });
            }
          }

          // Action response — user tapped a button on an action message
          if (msg.type === 'action_response' && pid) {
            const tid = typeof msg.conversationId === 'string' ? msg.conversationId : null;
            const buttonLabel = typeof msg.buttonLabel === 'string' ? msg.buttonLabel : '';
            const buttonId = typeof msg.buttonId === 'string' ? msg.buttonId : '';
            await cfg!.onInbound(pid, tid, {
              id: randomUUID(),
              kind: 'chat',
              content: {
                text: `[user selected: "${buttonLabel}" (id: ${buttonId})]`,
                senderId: pid,
              },
              timestamp: new Date().toISOString(),
            });
          }

          // New conversation — acknowledge (currently logged, not routed)
          if (msg.type === 'new_conversation' && pid) {
            // Acknowledge — the agent doesn't need to know about conversation switches
            // but we could use this for session tracking in the future.
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

    async deliver(platformId, threadId, message) {
      const c = message.content as Record<string, unknown>;
      const text = (c.markdown ?? c.text ?? '') as string;
      const files = (message.files ?? []) as Array<{
        data: Buffer;
        filename: string;
        mimeType?: string;
        size?: number;
      }>;
      const contentType = c.type as string | undefined;

      // Handle structured message types from agent
      if (contentType === 'ask_question' && c.questionId) {
        // Send as action message with buttons
        const title = (c.title ?? '') as string;
        const options = (c.options ?? []) as Array<Record<string, unknown>>;
        const buttons = options.map((opt, i) => ({
          id: (opt.id as string) ?? `opt_${i}`,
          label: (opt.label ?? opt.text ?? '') as string,
          style: (opt.style as string) ?? 'primary',
        }));

        const payload = JSON.stringify({
          type: 'action',
          id: (c.questionId as string) ?? randomUUID(),
          text: title,
          buttons,
          conversationId: threadId ?? undefined,
          timestamp: new Date().toISOString(),
        });

        const set = wsClients.get(platformId);
        if (set && set.size > 0) {
          set.forEach((ws) => {
            if (ws.readyState === WebSocket.OPEN) ws.send(payload);
          });
        }
        // Also deliver text version if present for offline/push
        if (text) {
          return deliverTextAndFiles(platformId, threadId, text, files);
        }
        return c.questionId as string;
      }

      // Status banner (renders as ──── icon text ──── divider on iOS)
      if (contentType === 'status') {
        const payload = JSON.stringify({
          type: 'status',
          id: randomUUID(),
          text: (c.text ?? '') as string,
          level: (c.level ?? 'info') as string,
          kind: (c.kind ?? 'system') as string,
          conversationId: threadId ?? undefined,
          timestamp: new Date().toISOString(),
        });
        const set = wsClients.get(platformId);
        if (set && set.size > 0) {
          set.forEach((ws) => {
            if (ws.readyState === WebSocket.OPEN) ws.send(payload);
          });
        }
        return randomUUID();
      }

      if (!text && files.length === 0) return undefined;
      return deliverTextAndFiles(platformId, threadId, text, files);
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
    if (h.sleepHours) p.push(`Sleep: ${h.sleepHours}h`);
    if (h.restingHeartRate) p.push(`RHR: ${h.restingHeartRate} bpm`);
    if (h.exerciseMinutes) p.push(`Exercise: ${h.exerciseMinutes} min`);
    if (p.length) lines.push(`🏃 ${p.join(' | ')}`);
  }
  if (!lines.length && !ctx.status) return '';

  // Use device-provided timestamp and timezone if available; fall back to server time in Moscow tz.
  const tz = (ctx.timezone as string | undefined) ?? 'Europe/Moscow';
  const tsOpts: Intl.DateTimeFormatOptions = { timeZone: tz, timeZoneName: 'longOffset' };
  const ts = ctx.timestamp
    ? new Date(ctx.timestamp as string).toLocaleString('ru-RU', tsOpts)
    : new Date().toLocaleString('ru-RU', tsOpts);

  const statusSuffix = ctx.status ? ` ${ctx.status}` : '';
  return `[iOS Context — ${ts}${statusSuffix}]\n${lines.join('\n')}${lines.length ? '\n' : ''}---\n`;
}

registerChannelAdapter('ios-app', { factory: createIOSAdapter });
